import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show GlobalCupertinoLocalizations;
import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../data/store.dart';
import '../data/sync/sync_engine.dart';
import '../features/accounts/accounts_screens.dart';
import '../features/assistant/assistant_screen.dart';
import '../features/billing/paywall_screen.dart';
import '../features/capture/capture_screen.dart';
import '../features/home/home_screen.dart';
import '../features/household/household_screen.dart';
import '../features/insights/insights_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/plans/plans_screen.dart';
import '../features/review/review_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/smart_plan/smart_plan_screen.dart';
import '../features/transactions/transaction_detail_screen.dart';
import '../features/transactions/transactions_screen.dart';
import '../features/voice/voice_screen.dart';
import '../features/wealth/wealth_screen.dart';
import '../l10n/strings.dart';
import '../native/capture_bridge.dart';
import '../ui/theme/theme.dart';
import '../ui/widgets/common.dart';
import 'providers.dart';
import 'services.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final store = ref.read(storeProvider);
  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) async {
      final onboarded = (await store.getSetting(SettingKeys.onboarded)) == 'true';
      if (!onboarded && state.matchedLocation != '/onboarding' && !state.matchedLocation.startsWith('/capture') && !state.matchedLocation.startsWith('/accounts')) {
        return '/onboarding';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, __) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/wealth', builder: (_, __) => const WealthScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/plans', builder: (_, __) => const PlansScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/ask', builder: (_, __) => const AssistantScreen())]),
        ],
      ),
      GoRoute(path: '/transactions', builder: (_, __) => const TransactionsScreen()),
      GoRoute(path: '/transactions/:id', builder: (_, s) => TransactionDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/review', builder: (_, __) => const ReviewScreen()),
      GoRoute(path: '/smart-plan', builder: (_, st) => SmartPlanScreen(initialText: st.uri.queryParameters['q'])),
      GoRoute(path: '/accounts', builder: (_, __) => const AccountsScreen()),
      GoRoute(path: '/accounts/new', builder: (_, __) => const AccountFormScreen()),
      GoRoute(path: '/accounts/:id', builder: (_, s) => AccountDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/accounts/:id/edit', builder: (_, s) => AccountFormScreen(editId: s.pathParameters['id'])),
      GoRoute(path: '/accounts/:id/transactions', builder: (_, s) => TransactionsScreen(accountId: s.pathParameters['id'])),
      GoRoute(path: '/insights', builder: (_, __) => const InsightsScreen()),
      GoRoute(path: '/voice', builder: (_, __) => const VoiceScreen()),
      GoRoute(path: '/capture', builder: (_, __) => const CaptureScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(path: '/household', builder: (_, __) => const HouseholdScreen()),
      GoRoute(path: '/pro', builder: (_, __) => const PaywallScreen()),
    ],
  );
});

class FilsApp extends ConsumerStatefulWidget {
  const FilsApp({super.key});
  @override
  ConsumerState<FilsApp> createState() => _FilsAppState();
}

class _FilsAppState extends ConsumerState<FilsApp> with WidgetsBindingObserver {
  bool locked = false;
  bool _lockChecked = false;
  Timer? _syncTimer;
  Timer? _notifDebounce;
  StreamSubscription<void>? _dataSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onForeground(first: true));
    _syncTimer = Timer.periodic(const Duration(minutes: 10), (_) => _sync());
    // Recompute notifications whenever transactions, budgets or recurring items change.
    final db = ref.read(storeProvider).db;
    _dataSub = db.tableUpdates(TableUpdateQuery.onAllTables([db.transactions, db.budgets, db.recurrings])).listen((_) {
      _notifDebounce?.cancel();
      _notifDebounce = Timer(const Duration(seconds: 2), _reschedule);
    });
  }

  Future<void> _reschedule() async {
    try {
      final s = ref.read(settingsProvider);
      await ref.read(notificationSchedulerProvider).reschedule(arabic: s.ar, money: s.fmt.money);
    } catch (e) {
      debugPrint('notifications: reschedule failed (${e.runtimeType})');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _notifDebounce?.cancel();
    _dataSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onForeground();
    if (state == AppLifecycleState.paused && ref.read(settingsProvider).biometricLock) setState(() => locked = true);
  }

  Future<void> _onForeground({bool first = false}) async {
    final store = ref.read(storeProvider);
    if (first && !_lockChecked) {
      _lockChecked = true;
      if ((await store.getSetting(SettingKeys.biometricLock)) == 'true') setState(() => locked = true);
    }
    final capture = ref.read(captureServiceProvider);
    capture.start();
    try {
      await capture.drain();
    } catch (_) {}
    // Text shared into the app (Android share sheet)
    try {
      final shared = await ref.read(captureBridgeProvider).takeSharedText();
      if (shared != null && shared.trim().isNotEmpty) {
        final raw = await capture.ingestion.ingest(CaptureService.eventFromNative({'source': 'share', 'text': shared, 'receivedAt': DateTime.now().toUtc().toIso8601String()})!);
        debugPrint('share → ${raw.outcome}');
      }
    } catch (_) {}
    await store.purgeExpiredRawText();
    // Time zone / date may have changed while backgrounded: recompute absolute schedules.
    unawaited(_reschedule());
    unawaited(ref.read(billingProvider).start());
    _sync();
  }

  Future<void> _sync() async {
    final store = ref.read(storeProvider);
    if ((await store.getSetting(SyncKeys.enabled)) != 'true') return;
    if (ref.read(sessionProvider).value == null) return;
    await ref.read(syncEngineProvider).sync();
  }

  Future<void> _unlock() async {
    try {
      final ok = await LocalAuthentication().authenticate(localizedReason: S(ref.read(settingsProvider).ar).unlock);
      if (ok) setState(() => locked = false);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Fils',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      locale: settings.locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      routerConfig: router,
      builder: (context, child) {
        // Respect the user's text size but cap extreme scaling to keep layouts usable.
        final mq = MediaQuery.of(context);
        final scaled = MediaQuery(data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.6)), child: child!);
        if (!locked) return scaled;
        return Stack(children: [
          scaled,
          Positioned.fill(child: _LockOverlay(onUnlock: _unlock)),
        ]);
      },
    );
  }
}

class _LockOverlay extends StatelessWidget {
  final VoidCallback onUnlock;
  const _LockOverlay({required this.onUnlock});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Material(
      color: context.fp.canvas,
      child: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🔒', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            Text(s.locked, style: context.tt.titleLarge),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: onUnlock, icon: const Icon(Icons.fingerprint), label: Text(s.unlock)),
          ]),
        ),
      ),
    );
  }
}

class AppShell extends ConsumerWidget {
  final StatefulNavigationShell shell;
  const AppShell({super.key, required this.shell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    return Scaffold(
      extendBody: true,
      body: shell,
      bottomNavigationBar: GlassNavBar(
        index: shell.currentIndex,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        items: [
          NavItem(Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, s.navWallet),
          NavItem(Icons.show_chart_rounded, Icons.show_chart_rounded, s.navWealth),
          NavItem(Icons.event_repeat_outlined, Icons.event_repeat, s.navPlans),
          NavItem(Icons.auto_awesome_outlined, Icons.auto_awesome, s.navAsk),
        ],
      ),
    );
  }
}

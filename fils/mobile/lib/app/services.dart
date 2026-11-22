import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../core/assistant/local_assistant.dart';
import '../core/assistant/tools.dart';
import '../data/ai/cloud_ai.dart';
import '../data/api/api_client.dart';
import '../data/auth/auth_service.dart';
import '../data/billing/billing_service.dart';
import '../data/db/database.dart';
import '../data/household/household_sharing.dart';
import '../data/notifications/notification_service.dart';
import '../data/ingestion.dart';
import '../data/store.dart';
import '../data/sync/sync_engine.dart';
import '../data/voice/speech_service.dart';
import '../native/capture_bridge.dart';
import 'providers.dart';

final apiProvider = Provider<ApiClient>((ref) => ApiClient());
final authServiceProvider = Provider<AuthService>((ref) => AuthService(ref.watch(apiProvider)));

/// Cloud session state (signed in user json or null).
class SessionNotifier extends AsyncNotifier<Map<String, dynamic>?> {
  @override
  Future<Map<String, dynamic>?> build() => ref.watch(apiProvider).tokens.user();

  Future<void> set(Map<String, dynamic>? user) async => state = AsyncData(user);

  Future<void> signOut({bool wipeLocal = false}) async {
    try {
      await ref.read(authServiceProvider).signOut();
    } catch (_) {
      await ref.read(apiProvider).tokens.clear();
    }
    final store = ref.read(storeProvider);
    await store.setSetting(SyncKeys.enabled, 'false');
    if (wipeLocal) await store.wipeAll();
    state = const AsyncData(null);
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, Map<String, dynamic>?>(SessionNotifier.new);

final syncEngineProvider = Provider<SyncEngine>((ref) => SyncEngine(ref.watch(storeProvider), ApiSyncTransport(ref.watch(apiProvider))));

final billingProvider = Provider<BillingService>((ref) {
  final b = BillingService(ref.watch(apiProvider));
  ref.onDispose(b.dispose);
  return b;
});

final captureBridgeProvider = Provider<CaptureBridge>((ref) => CaptureBridge());

/// Ingestion with the consent-gated cloud AI fallback wired in.
final ingestionWithAiProvider = Provider<IngestionService>((ref) {
  final store = ref.watch(storeProvider);
  final api = ref.watch(apiProvider);
  return IngestionService(store, ai: CloudExtractor(api, () async => (await store.getSetting(SettingKeys.aiCloudEnabled)) == 'true'));
});

final captureServiceProvider = Provider<CaptureService>((ref) {
  final c = CaptureService(ref.watch(captureBridgeProvider), ref.watch(ingestionWithAiProvider), ref.watch(storeProvider));
  ref.onDispose(c.dispose);
  return c;
});

final speechProvider = Provider<SpeechProvider>((ref) {
  final s = ref.watch(settingsProvider);
  final api = ref.watch(apiProvider);
  if (s.raw[SettingKeys.voiceProvider] == 'azure' && api.configured) return AzureSpeech(api);
  return DeviceSpeech();
});

typedef Reader = T Function<T>(ProviderListenable<T> provider);

/// Snapshot of the current user's local data for the assistant tools.
FinanceSnapshot snapshotFrom(Reader read) {
  final s = read(settingsProvider);
  return FinanceSnapshot(
    txs: read(allTxProvider).value ?? const <TxRow>[],
    accounts: read(allAccountsProvider).value ?? const <AccountRow>[],
    balances: read(balancesProvider),
    recurring: read(recurringProvider).value ?? const <RecurringRow>[],
    goals: read(goalsProvider).value ?? const <GoalRow>[],
    contributions: read(contributionsProvider).value ?? const <GoalContributionRow>[],
    categories: read(categoryMapProvider),
    splits: read(splitsProvider).value ?? const {},
    baseCurrency: s.baseCurrency,
    cycleStartDay: s.cycleStartDay,
    now: read(nowProvider)(),
  );
}

final localAssistantProvider = Provider<LocalAssistant>((ref) {
  final s = ref.watch(settingsProvider);
  return LocalAssistant(arabic: s.ar, money: s.fmt.money);
});

final cloudAssistantProvider = Provider<CloudAssistant>((ref) => CloudAssistant(ref.watch(apiProvider), ref.watch(localAssistantProvider)));

final householdSharingProvider = Provider<HouseholdSharing>((ref) => HouseholdSharing(ref.watch(storeProvider)));
final householdsCacheProvider = StreamProvider<List<HouseholdInfo>>((ref) {
  final store = ref.watch(storeProvider);
  final sharing = ref.watch(householdSharingProvider);
  return store.watchSetting('households_cache').asyncMap((_) => sharing.cachedHouseholds());
});
final sharedOriginalsProvider = StreamProvider<Set<String>>((ref) => ref.watch(householdSharingProvider).watchSharedOriginals());

final notificationPortProvider = Provider<NotificationPort>((ref) => PluginNotificationPort());
final notificationSchedulerProvider = Provider<NotificationScheduler>((ref) => NotificationScheduler(ref.watch(storeProvider), ref.watch(notificationPortProvider)));

/// Securely queued captures not yet parsed into the ledger (native inbox).
final queuedCountProvider = FutureProvider.autoDispose<int>((ref) {
  ref.watch(settingsMapProvider); // refresh whenever a drain updates last-capture settings
  return ref.watch(captureBridgeProvider).inboxCount();
});

class CaptureCounts {
  final int posted, review, ignored, merged;
  const CaptureCounts(this.posted, this.review, this.ignored, this.merged);
}

/// Today's capture outcomes from the source-event log.
final captureCountsProvider = StreamProvider<CaptureCounts>((ref) {
  final store = ref.watch(storeProvider);
  final db = store.db;
  return db.select(db.sourceEvents).watch().map((rows) {
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 24));
    final r = rows.where((e) => e.receivedAt.isAfter(since));
    int c(String st) => r.where((e) => e.status == st).length;
    return CaptureCounts(c('posted'), c('review'), c('ignored') + c('duplicate'), c('merged'));
  });
});

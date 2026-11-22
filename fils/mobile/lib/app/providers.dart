import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ledger/ledger.dart';
import '../core/time/kuwait_time.dart';
import '../data/db/database.dart';
import '../data/ingestion.dart';
import '../data/store.dart';
import '../ui/format.dart';

/// Overridden in main() with the opened, encrypted store.
final storeProvider = Provider<FinanceStore>((ref) => throw UnimplementedError('storeProvider not overridden'));

final ingestionProvider = Provider<IngestionService>((ref) => IngestionService(ref.watch(storeProvider)));

final nowProvider = Provider<DateTime Function()>((ref) => () => DateTime.now().toUtc());

class AppSettings {
  final Locale locale;
  final ThemeMode themeMode;
  final bool arabicDigits;
  final int cycleStartDay;
  final String baseCurrency;
  final bool onboarded;
  final bool biometricLock;
  final bool demoMode;
  final bool aiCloud;
  final Map<String, String> raw;
  const AppSettings({
    required this.locale,
    required this.themeMode,
    required this.arabicDigits,
    required this.cycleStartDay,
    required this.baseCurrency,
    required this.onboarded,
    required this.biometricLock,
    required this.demoMode,
    required this.aiCloud,
    required this.raw,
  });

  bool get ar => locale.languageCode == 'ar';
  Fmt get fmt => Fmt(arabic: ar, arabicDigits: arabicDigits);
  CycleCalculator get cycle => CycleCalculator(startDay: cycleStartDay);

  factory AppSettings.from(Map<String, String> m, {Locale? deviceLocale}) => AppSettings(
        locale: Locale(m[SettingKeys.locale] ?? (deviceLocale?.languageCode == 'ar' ? 'ar' : 'en')),
        themeMode: switch (m[SettingKeys.themeMode]) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        arabicDigits: m['arabic_digits'] == 'true',
        cycleStartDay: int.tryParse(m[SettingKeys.cycleStartDay] ?? '') ?? 1,
        baseCurrency: m[SettingKeys.baseCurrency] ?? 'KWD',
        onboarded: m[SettingKeys.onboarded] == 'true',
        biometricLock: m[SettingKeys.biometricLock] == 'true',
        demoMode: m[SettingKeys.demoMode] == 'true',
        aiCloud: m[SettingKeys.aiCloudEnabled] == 'true',
        raw: m,
      );
}

final settingsMapProvider = StreamProvider<Map<String, String>>((ref) {
  final db = ref.watch(storeProvider).db;
  return db.select(db.settings).watch().map((rows) => {for (final r in rows) r.key: r.value});
});

final settingsProvider = Provider<AppSettings>((ref) {
  final m = ref.watch(settingsMapProvider).value ?? const {};
  return AppSettings.from(m, deviceLocale: WidgetsBinding.instance.platformDispatcher.locale);
});

final accountsProvider = StreamProvider<List<AccountRow>>((ref) => ref.watch(storeProvider).watchAccounts());
final allAccountsProvider =
    StreamProvider<List<AccountRow>>((ref) => ref.watch(storeProvider).watchAccounts(includeArchived: true));
final allTxProvider = StreamProvider<List<TxRow>>((ref) => ref.watch(storeProvider).watchAllEffective());
final categoriesProvider = StreamProvider<List<CategoryRow>>((ref) => ref.watch(storeProvider).watchCategories());
final budgetsProvider = StreamProvider<List<BudgetRow>>((ref) => ref.watch(storeProvider).watchBudgets());
final goalsProvider = StreamProvider<List<GoalRow>>((ref) => ref.watch(storeProvider).watchGoals());
final contributionsProvider = StreamProvider<List<GoalContributionRow>>((ref) => ref.watch(storeProvider).watchContributions());
final recurringProvider = StreamProvider<List<RecurringRow>>((ref) => ref.watch(storeProvider).watchRecurring());
final assetsProvider = StreamProvider<List<AssetRow>>((ref) => ref.watch(storeProvider).watchAssets());
final reviewCountProvider = StreamProvider<int>((ref) => ref.watch(storeProvider).watchReviewCount());
final splitsProvider = StreamProvider<Map<String, List<SplitRow>>>((ref) {
  final db = ref.watch(storeProvider).db;
  return db.select(db.transactionSplits).watch().map((rows) {
    final m = <String, List<SplitRow>>{};
    for (final r in rows) {
      m.putIfAbsent(r.transactionId, () => []).add(r);
    }
    return m;
  });
});

final categoryMapProvider = Provider<Map<String, CategoryRow>>((ref) {
  final cats = ref.watch(categoriesProvider).value ?? const [];
  return {for (final c in cats) c.id: c};
});

/// Calculated balances per account (opening balance + effects).
final balancesProvider = Provider<Map<String, int>>((ref) {
  final accts = ref.watch(allAccountsProvider).value ?? const [];
  final txs = ref.watch(allTxProvider).value ?? const [];
  final byAcct = <String, List<TxRow>>{};
  for (final t in txs) {
    byAcct.putIfAbsent(t.accountId, () => []).add(t);
    if (t.counterAccountId != null) byAcct.putIfAbsent(t.counterAccountId!, () => []).add(t);
  }
  return {for (final a in accts) a.id: calculatedBalance(a, byAcct[a.id] ?? const [])};
});

/// Home period selection.
enum PeriodKind { cycle, month, lastCycle, lastMonth, custom }

class PeriodSel {
  final PeriodKind kind;
  final Period? custom;
  const PeriodSel(this.kind, {this.custom});
}

class PeriodNotifier extends Notifier<PeriodSel> {
  @override
  PeriodSel build() => const PeriodSel(PeriodKind.cycle);
  void set(PeriodSel s) => state = s;
}

final periodSelProvider = NotifierProvider<PeriodNotifier, PeriodSel>(PeriodNotifier.new);

final selectedAccountProvider = NotifierProvider<SelectedAccountNotifier, String?>(SelectedAccountNotifier.new);

class SelectedAccountNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final periodProvider = Provider<Period>((ref) {
  final s = ref.watch(settingsProvider);
  final sel = ref.watch(periodSelProvider);
  final now = ref.watch(nowProvider)();
  final cyc = s.cycle;
  final month = calendarMonth(now);
  return switch (sel.kind) {
    PeriodKind.cycle => cyc.cycleFor(now),
    PeriodKind.lastCycle => cyc.previous(cyc.cycleFor(now)),
    PeriodKind.month => month,
    PeriodKind.lastMonth => calendarMonth(month.start.subtract(const Duration(seconds: 1))),
    PeriodKind.custom => sel.custom ?? cyc.cycleFor(now),
  };
});

final periodTotalsProvider = Provider<PeriodTotals>((ref) {
  final txs = ref.watch(allTxProvider).value ?? const [];
  final splits = ref.watch(splitsProvider).value ?? const {};
  final acct = ref.watch(selectedAccountProvider);
  return totalsFor(txs, ref.watch(periodProvider), splitsByTx: splits, accountIds: acct == null ? null : {acct});
});

/// Ledger rules: the single source of truth for how transactions affect balances and
/// spending.
///
/// Invariants (each covered by a test in test/core/ledger_test.dart):
///  I1  Declined, void and soft-deleted transactions have no effect on anything.
///  I2  A transfer between owned accounts nets to zero across those accounts (same
///      currency) and is neither income nor spending.
///  I3  An ATM withdrawal is a bank→cash transfer; its fee is a separate expense.
///  I4  A credit-card purchase is an expense on the card (liability grows). Repaying the
///      card is a transfer and is never a second expense.
///  I5  A refund reduces spending in the refunded category; it is not income.
///  I6  A pending authorization that later settles is one transaction: the ingestion
///      pipeline updates the pending row in place, so it can't be counted twice.
///  I7  Opening balances are applied once, from the account row, never from
///      transactions; imports that start after the opening date can't duplicate them.
///  I8  Amounts in different currencies are never summed together; totals are per currency.
///  I9  Reconciliation adjustments change balances but are excluded from income and spending.
library;

import '../../data/db/database.dart';
import '../time/kuwait_time.dart';

class TxKinds {
  static const expense = 'expense';
  static const income = 'income';
  static const transfer = 'transfer';
  static const refund = 'refund';
  static const adjustUp = 'adjust_up';
  static const adjustDown = 'adjust_down';
  static const all = {expense, income, transfer, refund, adjustUp, adjustDown};
}

class TxStatuses {
  static const posted = 'posted';
  static const pending = 'pending';
  static const declined = 'declined';
  static const voided = 'void';
}

bool isEffective(TxRow t) =>
    t.deletedAt == null && (t.status == TxStatuses.posted || t.status == TxStatuses.pending);

/// Signed balance effects per account, in each account's own currency.
/// Account balances are signed asset values: a credit card that owes money is negative.
Map<String, int> balanceEffects(TxRow t) {
  if (!isEffective(t)) return const {};
  switch (t.kind) {
    case TxKinds.expense:
    case TxKinds.adjustDown:
      return {t.accountId: -t.amountMinor};
    case TxKinds.income:
    case TxKinds.refund:
    case TxKinds.adjustUp:
      return {t.accountId: t.amountMinor};
    case TxKinds.transfer:
      final m = <String, int>{t.accountId: -t.amountMinor};
      if (t.counterAccountId != null) {
        // A cross-currency transfer uses the explicitly recorded counter amount.
        m[t.counterAccountId!] = (m[t.counterAccountId!] ?? 0) + (t.counterAmountMinor ?? t.amountMinor);
      }
      return m;
    default:
      throw StateError('Unknown transaction kind ${t.kind}');
  }
}

/// The calculated balance of [account]: opening balance plus every effect dated on or
/// after the opening date. Effects dated before the opening date are already in the
/// opening figure (I7).
int calculatedBalance(AccountRow account, Iterable<TxRow> txs) {
  var bal = account.openingBalanceMinor;
  for (final t in txs) {
    if (t.occurredAt.isBefore(account.openingBalanceDate)) continue;
    final e = balanceEffects(t)[account.id];
    if (e != null) bal += e;
  }
  return bal;
}

/// Portion of a transaction attributable to each category. Splits, when present,
/// replace the single category. Returns positive values for spending and negative
/// values for refunds.
Map<String, int> categorySpend(TxRow t, {List<SplitRow> splits = const []}) {
  if (!isEffective(t)) return const {};
  final sign = switch (t.kind) {
    TxKinds.expense => 1,
    TxKinds.refund => -1,
    _ => 0,
  };
  if (sign == 0) return const {};
  if (splits.isNotEmpty) {
    final m = <String, int>{};
    for (final s in splits) {
      m[s.categoryId] = (m[s.categoryId] ?? 0) + sign * s.amountMinor;
    }
    return m;
  }
  return {(t.categoryId ?? 'other'): sign * t.amountMinor};
}

class PeriodTotals {
  /// currency → spent (expenses minus refunds), in minor units
  final Map<String, int> spent;
  final Map<String, int> income;
  final Map<String, Map<String, int>> byCategory; // currency → category → net spent
  final Map<String, Map<String, int>> byMerchant; // currency → merchant → net spent
  final int transactionCount;
  const PeriodTotals(this.spent, this.income, this.byCategory, this.byMerchant, this.transactionCount);

  int spentIn(String currency) => spent[currency] ?? 0;
  int incomeIn(String currency) => income[currency] ?? 0;
}

/// Aggregate spending and income for [period]. Transfers and adjustments never count
/// (I2, I9). Refunds offset spending (I5). Results are kept per currency (I8).
PeriodTotals totalsFor(
  Iterable<TxRow> txs,
  Period period, {
  Map<String, List<SplitRow>> splitsByTx = const {},
  Set<String>? accountIds,
}) {
  final spent = <String, int>{};
  final income = <String, int>{};
  final byCat = <String, Map<String, int>>{};
  final byMerchant = <String, Map<String, int>>{};
  var count = 0;
  for (final t in txs) {
    if (!isEffective(t) || !period.contains(t.occurredAt)) continue;
    if (accountIds != null && !accountIds.contains(t.accountId)) continue;
    if (t.kind == TxKinds.income) {
      income[t.currency] = (income[t.currency] ?? 0) + t.amountMinor;
      count++;
      continue;
    }
    final cs = categorySpend(t, splits: splitsByTx[t.id] ?? const []);
    if (cs.isEmpty) continue;
    count++;
    final m = byCat.putIfAbsent(t.currency, () => {});
    var net = 0;
    cs.forEach((k, v) {
      m[k] = (m[k] ?? 0) + v;
      net += v;
    });
    spent[t.currency] = (spent[t.currency] ?? 0) + net;
    final mk = t.merchant ?? t.merchantRaw ?? '—';
    final mm = byMerchant.putIfAbsent(t.currency, () => {});
    mm[mk] = (mm[mk] ?? 0) + net;
  }
  return PeriodTotals(spent, income, byCat, byMerchant, count);
}

/// Sum of spending within [period] for one budget's scope (a category, or all
/// categories when null). Refunds in the category reduce usage; transfers don't count.
int budgetUsage(Iterable<TxRow> txs, Period period, String currency, String? categoryId,
    {Map<String, List<SplitRow>> splitsByTx = const {}}) {
  final t = totalsFor(txs.where((x) => x.currency == currency), period, splitsByTx: splitsByTx);
  if (categoryId == null) return t.spentIn(currency);
  return t.byCategory[currency]?[categoryId] ?? 0;
}

/// Net worth per currency: included accounts (calculated balances) plus manual assets,
/// minus liabilities. Assets linked to a tracked account are skipped to avoid counting
/// the same money twice.
Map<String, int> netWorth({
  required List<AccountRow> accounts,
  required Map<String, int> balances,
  required List<AssetRow> assets,
}) {
  final out = <String, int>{};
  final tracked = <String>{};
  for (final a in accounts) {
    if (a.deletedAt != null || !a.includeInNetWorth) continue;
    tracked.add(a.id);
    out[a.currency] = (out[a.currency] ?? 0) + (balances[a.id] ?? a.openingBalanceMinor);
  }
  for (final s in assets) {
    if (s.deletedAt != null) continue;
    if (s.linkedAccountId != null && tracked.contains(s.linkedAccountId)) continue;
    final v = s.isLiability ? -s.valueMinor : s.valueMinor;
    out[s.currency] = (out[s.currency] ?? 0) + v;
  }
  return out;
}

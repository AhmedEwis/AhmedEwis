import 'dart:convert';

import '../core/domain/categories.dart';
import '../core/import/csv_import.dart';
import '../core/ledger/ledger.dart';
import '../core/parsing/merchant_directory.dart';
import '../core/time/kuwait_time.dart';
import 'store.dart';

class CsvImportSummary {
  final int imported;
  final int duplicates;
  const CsvImportSummary(this.imported, this.duplicates);
}

/// Import statement rows into an account. A row is a duplicate when the same account
/// already has a non-deleted transaction with the same amount, direction, currency and
/// day, and a matching description or merchant. Repeated legitimate purchases on the same
/// day with different descriptions are kept.
Future<CsvImportSummary> importCsvRows(FinanceStore store, String accountId, List<CsvCandidate> rows) async {
  var imported = 0, dups = 0;
  final aliases = await store.merchantAliasMap();
  final existing = await store.transactionsForAccount(accountId);
  final seenInFile = <String>{};
  for (final r in rows) {
    final day = ReportingZone.kuwait.startOfDay(r.occurredAt);
    final mm = matchMerchant(r.description, userAliases: aliases);
    final kind = r.credit ? TxKinds.income : TxKinds.expense;
    final fileKey = '${day.toIso8601String()}|${r.amountMinor}|$kind|${r.description.toLowerCase()}|${r.line}';
    if (!seenInFile.add(fileKey)) continue;
    final dup = existing.any((t) {
      if (t.amountMinor != r.amountMinor || t.currency != r.currency) return false;
      if (ReportingZone.kuwait.startOfDay(t.occurredAt) != day) return false;
      final dir = t.kind == TxKinds.income || t.kind == TxKinds.refund ? TxKinds.income : TxKinds.expense;
      if (dir != kind) return false;
      final d = r.description.toLowerCase();
      return (t.merchantRaw ?? '').toLowerCase() == d || (t.merchant != null && mm != null && t.merchant == mm.name);
    });
    if (dup) {
      dups++;
      continue;
    }
    await store.addTransaction(
      accountId: accountId,
      kind: kind,
      amountMinor: r.amountMinor,
      currency: r.currency,
      occurredAt: r.occurredAt,
      source: 'csv',
      merchant: mm?.name,
      merchantRaw: r.description,
      categoryId: r.credit ? Cat.otherIncome : (mm?.category ?? Cat.other),
    );
    imported++;
  }
  return CsvImportSummary(imported, dups);
}

/// Full local export (JSON + CSV). CSV cells are protected against formula injection.
Future<Map<String, String>> exportAll(FinanceStore store) async {
  final db = store.db;
  final accounts = await db.select(db.accounts).get();
  final txs = await db.select(db.transactions).get();
  final cats = {for (final c in await store.categories()) c.id: c};
  final json = const JsonEncoder.withIndent('  ').convert({
    'exported_at': store.now.toIso8601String(),
    'format': 'fils-export-v1',
    'accounts': accounts.map((a) => a.toJson()).toList(),
    'transactions': txs.map((t) => t.toJson()).toList(),
    'budgets': (await db.select(db.budgets).get()).map((e) => e.toJson()).toList(),
    'goals': (await db.select(db.goals).get()).map((e) => e.toJson()).toList(),
    'goal_contributions': (await db.select(db.goalContributions).get()).map((e) => e.toJson()).toList(),
    'recurring': (await db.select(db.recurrings).get()).map((e) => e.toJson()).toList(),
    'assets': (await db.select(db.assets).get()).map((e) => e.toJson()).toList(),
    'categories': cats.values.map((e) => e.toJson()).toList(),
  });
  final acct = {for (final a in accounts) a.id: a.name};
  final b = StringBuffer('date,account,kind,status,amount,currency,merchant,category,note\n');
  String q(String v) => '"${csvSafe(v).replaceAll('"', '""')}"';
  for (final t in txs.where((t) => t.deletedAt == null)) {
    final w = ReportingZone.kuwait.toWall(t.occurredAt);
    final amt = (t.kind == TxKinds.expense || t.kind == TxKinds.adjustDown || t.kind == TxKinds.transfer) ? -t.amountMinor : t.amountMinor;
    final cur = t.currency;
    final exp = cur == 'KWD' || cur == 'BHD' || cur == 'OMR' ? 3 : 2;
    final f = exp == 3 ? 1000 : 100;
    final s = '${amt < 0 ? '-' : ''}${amt.abs() ~/ f}.${(amt.abs() % f).toString().padLeft(exp, '0')}';
    b.writeln([
      q('${w.year}-${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')}'),
      q(acct[t.accountId] ?? ''),
      q(t.kind),
      q(t.status),
      s,
      q(cur),
      q(t.merchant ?? t.merchantRaw ?? ''),
      q(cats[t.categoryId]?.nameEn ?? ''),
      q(t.note ?? ''),
    ].join(','));
  }
  return {'json': json, 'csv': b.toString()};
}

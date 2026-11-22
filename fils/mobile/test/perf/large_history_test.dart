import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/kuwait_parser.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

/// Performance targets (host machine, debug-mode test VM. Device numbers will differ):
///  - insert 20,000 transactions < 20 s
///  - full-history aggregation (cycle totals + balances) < 300 ms
///  - first page (60 rows) query < 100 ms
///  - parse 1,000 messages < 1 s
void main() {
  test('large local history', () async {
    final s = await newTestStore(now: DateTime.utc(2026, 11, 22));
    final a = await s.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD', openingBalanceDate: DateTime.utc(2023, 1, 1));
    final sw = Stopwatch()..start();
    await s.db.transaction(() async {
      for (var i = 0; i < 20000; i++) {
        await s.addTransaction(
          accountId: a.id,
          kind: i % 25 == 0 ? TxKinds.income : TxKinds.expense,
          amountMinor: 1000 + (i * 37) % 50000,
          currency: 'KWD',
          occurredAt: DateTime.utc(2023, 1, 1).add(Duration(minutes: i * 70)),
          source: 'sms',
          merchant: 'M${i % 300}',
          categoryId: const ['food', 'groceries', 'fuel', 'shopping'][i % 4],
        );
      }
    });
    final insertMs = sw.elapsedMilliseconds;
    final txs = await s.allTransactions();
    sw.reset();
    final p = const CycleCalculator(startDay: 25).cycleFor(DateTime.utc(2026, 11, 22));
    final tot = totalsFor(txs, p);
    final bal = calculatedBalance(a, txs);
    final aggMs = sw.elapsedMilliseconds;
    sw.reset();
    final page = await s.watchTransactions(limit: 60).first;
    final pageMs = sw.elapsedMilliseconds;
    sw.reset();
    const parser = KuwaitParser();
    for (var i = 0; i < 1000; i++) {
      parser.parse(RawEvent(text: 'Purchase of KWD ${i % 90}.250 at TALABAT using card ending 1234 on 22/11/2026 14:05', receivedAt: DateTime.utc(2026, 11, 22, 12), source: SourceKind.sms));
    }
    final parseMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('PERF insert20k=${insertMs}ms aggregate=${aggMs}ms page60=${pageMs}ms parse1k=${parseMs}ms rows=${txs.length} cycleSpent=${tot.spentIn('KWD')} bal=$bal');
    expect(txs.length, 20000);
    expect(page.length, 60);
    expect(insertMs, lessThan(20000));
    expect(aggMs, lessThan(300));
    expect(pageMs, lessThan(100));
    expect(parseMs, lessThan(1000));
  }, timeout: const Timeout(Duration(minutes: 3)));
}

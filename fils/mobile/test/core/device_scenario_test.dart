// Mirrors docs/device-acceptance.md Phase A with the exact synthetic messages, so the
// expected values in that checklist are proven on the host before a device run.
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/data/ingestion.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

void main() {
  test('Phase A expected values (synthetic)', () async {
    final s = await newTestStore(now: DateTime.utc(2026, 11, 22, 9, 30));
    final acct = await s.createAccount(name: 'Test NBK card', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234', openingBalanceMinor: 1000000);
    final ing = IngestionService(s);
    const m1 = '[SYNTHETIC] Purchase of KWD 5.250 at TALABAT card ending 1234. Available balance KWD 994.750';
    // On iOS the Shortcut's Sender is a phone number or short code, not a bank name.
    RawEvent sc(String t, String run, int min) =>
        RawEvent(text: t, receivedAt: DateTime.utc(2026, 11, 22, 9, 30 + min), source: SourceKind.shortcut, sourceId: run, sender: '+96550000000');
    final r1 = await ing.ingest(sc(m1, 'run-1', 0));
    expect(r1.outcome, IngestOutcome.posted); // A5
    final tx = (await s.transaction(r1.transactionId!))!;
    expect(tx.amountMinor, 5250); // A6
    expect(tx.categoryId, 'food');
    expect(tx.accountId, acct.id);
    expect(tx.status, TxStatuses.posted);
    expect(tx.needsReview, isFalse);
    expect(calculatedBalance((await s.account(acct.id))!, await s.transactionsForAccount(acct.id)), 994750);
    expect((await s.account(acct.id))!.reportedAvailableMinor, 994750);
    expect((await ing.ingest(sc(m1, 'run-2', 1))).outcome, IngestOutcome.possibleDuplicate); // A7: held, not counted
    const m2 = '[SYNTHETIC] Purchase of KWD 2.000 at TALABAT card ending 1234. Available balance KWD 992.750';
    expect((await ing.ingest(sc(m2, 'run-3', 5))).outcome, IngestOutcome.posted); // A8
    expect((await ing.ingest(sc(m2, 'run-4', 6))).outcome, IngestOutcome.possibleDuplicate); // A9
    final txs = await s.transactionsForAccount(acct.id);
    expect(txs.length, 2); // A10
    expect(calculatedBalance((await s.account(acct.id))!, txs), 992750);
  });
}

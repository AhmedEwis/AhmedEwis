import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/ingestion.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

RawEvent sms(String text, DateTime at, {String? sender, String? id, SourceKind src = SourceKind.sms, Map<String, String>? fields}) =>
    RawEvent(text: text, receivedAt: at, source: src, sender: sender, sourceId: id, fields: fields);

void main() {
  final t0 = DateTime.utc(2026, 11, 22, 11, 5);
  late FinanceStore s;
  late IngestionService ing;
  setUp(() async {
    s = await newTestStore(now: t0);
    ing = IngestionService(s);
  });

  test('vertical slice: SMS → parser → account auto-created → expense → totals', () async {
    final r = await ing.ingest(sms('Dear Customer, a purchase of KWD 5.250 was made on your card ending 1234 at TALABAT on 22/11/2026 14:05. Available balance KWD 1,234.567', t0, sender: 'NBK'));
    expect(r.outcome, IngestOutcome.posted);
    final tx = (await s.transaction(r.transactionId!))!;
    expect(tx.amountMinor, 5250);
    expect(tx.categoryId, 'food');
    final acct = (await s.account(tx.accountId))!;
    expect(acct.maskLast4, '1234');
    expect(acct.institutionId, 'nbk');
    expect(acct.reportedAvailableMinor, 1234567);
    final tot = totalsFor(await s.allTransactions(), calendarMonth(t0));
    expect(tot.spentIn('KWD'), 5250);
  });

  test('OTP is ignored and raw text never stored', () async {
    final r = await ing.ingest(sms('Your OTP for purchase of KWD 25.000 at AMAZON is 482913. Do not share it.', t0));
    expect(r.outcome, IngestOutcome.ignored);
    expect(await s.allTransactions(), isEmpty);
    final ev = await s.db.select(s.db.sourceEvents).getSingle();
    expect(ev.rawText, isNull);
    expect(ev.kind, 'otp');
  });

  test('replay with the same platform id is a duplicate', () async {
    final m = 'Purchase of KWD 3.000 at STARBUCKS card ending 1234';
    final a = await ing.ingest(sms(m, t0, id: 'run-1', src: SourceKind.shortcut));
    final b = await ing.ingest(sms(m, t0, id: 'run-1', src: SourceKind.shortcut));
    expect(a.outcome, IngestOutcome.posted);
    expect(b.outcome, IngestOutcome.duplicate);
    expect((await s.allTransactions()).length, 1);
  });

  test('same text via SMS and notification = one transaction', () async {
    final m = 'Purchase of KWD 3.000 at STARBUCKS card ending 1234';
    await ing.ingest(sms(m, t0, src: SourceKind.sms));
    final b = await ing.ingest(sms(m, t0.add(const Duration(seconds: 20)), src: SourceKind.notification, id: 'n1'));
    expect(b.outcome, IngestOutcome.merged);
    expect((await s.allTransactions()).length, 1);
  });

  test('two genuinely separate identical purchases are both kept (second flagged)', () async {
    final m = 'Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234';
    final a = await ing.ingest(sms(m, t0));
    final b = await ing.ingest(sms(m, t0.add(const Duration(seconds: 40))));
    expect(a.outcome, IngestOutcome.posted);
    expect(b.outcome, IngestOutcome.possibleDuplicate);
    final txs = await s.allTransactions();
    expect(txs.length, 2);
    expect(txs.where((t) => t.needsReview).length, 1);
  });

  test('same merchant+amount hours apart are separate (no amount+merchant-only dedupe)', () async {
    await ing.ingest(sms('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234 on 22/11/2026 08:00', t0));
    final b = await ing.ingest(sms('Purchase of KWD 1.500 at CARIBOU COFFEE card ending 1234 on 22/11/2026 13:00', t0.add(const Duration(hours: 5))));
    expect(b.outcome, IngestOutcome.posted);
    expect((await s.allTransactions()).length, 2);
  });

  test('Wallet + bank SMS of the same purchase merge', () async {
    await ing.ingest(sms('', t0, src: SourceKind.wallet, id: 'w1', fields: {'merchant': 'Talabat', 'amount': 'KWD 5.250', 'card': 'NBK Visa 1234'}));
    final b = await ing.ingest(sms('Purchase of KWD 5.250 at TALABAT card ending 1234', t0.add(const Duration(minutes: 1)), sender: 'NBK'));
    expect(b.outcome, IngestOutcome.merged);
    expect((await s.allTransactions()).length, 1);
  });

  test('pending authorization then settlement = one expense (I6)', () async {
    await ing.ingest(sms('Authorization of KWD 120.000 at JUMEIRAH HOTEL on card ending 1234 is pending', t0));
    final b = await ing.ingest(sms('Purchase of KWD 118.500 at JUMEIRAH HOTEL on card ending 1234', t0.add(const Duration(days: 2))));
    expect(b.outcome, IngestOutcome.settledPending);
    final txs = await s.allTransactions();
    expect(txs.length, 1);
    expect(txs.single.status, TxStatuses.posted);
    expect(txs.single.amountMinor, 118500);
  });

  test('reversal of pending voids it', () async {
    await ing.ingest(sms('Authorization of KWD 12.000 at OOREDOO KUWAIT on card ending 1234 is pending', t0));
    await ing.ingest(sms('Reversal of KWD 12.000 at OOREDOO KUWAIT on card ending 1234', t0.add(const Duration(hours: 1))));
    final txs = await s.allTransactions();
    expect(txs.single.status, TxStatuses.voided);
    expect(totalsFor(txs, calendarMonth(t0)).spentIn('KWD'), 0);
  });

  test('refund links to original and nets spending', () async {
    await ing.ingest(sms('Purchase of KWD 5.250 at TALABAT card ending 1234', t0));
    final r = await ing.ingest(sms('Refund of KWD 5.250 from TALABAT has been credited to your card ending 1234', t0.add(const Duration(days: 1))));
    final refund = (await s.transaction(r.transactionId!))!;
    expect(refund.kind, TxKinds.refund);
    expect(refund.refundOfId, isNotNull);
    expect(totalsFor(await s.allTransactions(), calendarMonth(t0)).spentIn('KWD'), 0);
  });

  test('declined does not change balances', () async {
    final r = await ing.ingest(sms('Transaction of KWD 30.000 at AMAZON.COM declined due to insufficient funds. Card XXXX1234', t0));
    final tx = (await s.transaction(r.transactionId!))!;
    expect(tx.status, TxStatuses.declined);
    final acct = (await s.account(tx.accountId))!;
    expect(calculatedBalance(acct, await s.allTransactions()), 0);
  });

  test('ATM creates bank→cash transfer, not spending', () async {
    await ing.ingest(sms('Cash withdrawal of KWD 50.000 from ATM SALMIYA using card ending 1234', t0, sender: 'NBK'));
    final txs = await s.allTransactions();
    expect(txs.single.kind, TxKinds.transfer);
    expect(totalsFor(txs, calendarMonth(t0)).spentIn('KWD'), 0);
    final cash = (await s.accounts()).firstWhere((a) => a.kind == 'cash');
    expect(calculatedBalance(cash, txs), 50000);
  });

  test('outgoing + incoming legs on two owned accounts merge into a transfer', () async {
    await ing.ingest(sms('Transfer of KWD 100.000 from your account XXXX5678 to account XXXX9012 was successful', t0, sender: 'NBK'));
    await ing.ingest(sms('You have received a transfer of KD 100.000 to your account XXXX9012', t0.add(const Duration(minutes: 2)), sender: 'KFH'));
    final txs = await s.allTransactions();
    expect(txs.length, 1);
    expect(txs.single.kind, TxKinds.transfer);
    final tot = totalsFor(txs, calendarMonth(t0));
    expect(tot.spentIn('KWD'), 0);
    expect(tot.incomeIn('KWD'), 0);
  });

  test('foreign currency keeps billed and original amounts', () async {
    final r = await ing.ingest(sms('Purchase of USD 25.00 (KWD 7.712) at AMAZON.COM with card ending 1234', t0));
    final tx = (await s.transaction(r.transactionId!))!;
    expect(tx.amountMinor, 7712);
    expect(tx.currency, 'KWD');
    expect(tx.originalAmountMinor, 2500);
    expect(tx.originalCurrency, 'USD');
    expect(tx.fxSource, 'bank_billed');
  });

  test('unknown format goes to review with raw text retained then purged', () async {
    final r = await ing.ingest(sms('A purchase was made on your card ending 1234 at TALABAT', t0));
    expect(r.outcome, IngestOutcome.review);
    var ev = await s.db.select(s.db.sourceEvents).getSingle();
    expect(ev.rawText, isNotNull);
    s.clock = () => t0.add(const Duration(days: 31));
    expect(await s.purgeExpiredRawText(), 1);
    ev = await s.db.select(s.db.sourceEvents).getSingle();
    expect(ev.rawText, isNull);
  });

  test('salary is income, card payment with payer account is a transfer', () async {
    final bank = await s.createAccount(name: 'Main', kind: 'bank', currency: 'KWD', institutionId: 'warba', maskLast4: '5678');
    await s.setSetting(SettingKeys.defaultPayerAccount, bank.id);
    await ing.ingest(sms('Your account XXXX5678 has been credited with KWD 1,500.000 SALARY', t0, sender: 'WarbaBank'));
    await ing.ingest(sms('Payment of KWD 200.000 received for your credit card ending 4321. Thank you.', t0));
    final txs = await s.allTransactions();
    final tot = totalsFor(txs, calendarMonth(t0));
    expect(tot.incomeIn('KWD'), 1500000);
    expect(tot.spentIn('KWD'), 0);
    expect(txs.where((t) => t.kind == TxKinds.transfer).length, 1);
  });

  test('outbox and audit records are written for captured transactions', () async {
    await ing.ingest(sms('Purchase of KWD 3.000 at STARBUCKS card ending 1234', t0));
    final outbox = await s.db.select(s.db.outbox).get();
    expect(outbox.map((o) => o.entity).toSet(), containsAll(['account', 'transaction']));
    final audit = await s.db.select(s.db.auditEvents).get();
    expect(audit, isNotEmpty);
  });
}

import 'package:fils/capture_main.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/data/ingestion.dart';
import 'package:fils/native/capture_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

/// In-memory native inbox: mimics the iOS App Group / Android files inbox.
class FakeBridge extends CaptureBridge {
  final inbox = <Map<String, dynamic>>[];
  bool crashBeforeAck = false;
  @override
  bool get supported => true;
  @override
  Future<List<Map<String, dynamic>>> drainInbox() async => [...inbox];
  @override
  Future<void> ack(List<String> ids) async {
    if (crashBeforeAck) {
      crashBeforeAck = false;
      throw StateError('process killed before ack');
    }
    inbox.removeWhere((m) => ids.contains(m['id']));
  }

  @override
  Future<int> inboxCount() async => inbox.length;
  @override
  Stream<void> get onNewEvents => const Stream.empty();
}

Map<String, dynamic> ev(String id, String text, {String source = 'shortcut', Map<String, String>? fields}) =>
    {'id': id, 'source': source, 'text': text, 'receivedAt': '2026-11-22T09:00:00Z', 'platformId': id, if (fields != null) 'fields': fields};

void main() {
  test('headless run posts, reviews and ignores; summary reports each stage', () async {
    final s = await newTestStore(now: DateTime.utc(2026, 11, 22, 9));
    final b = FakeBridge()
      ..inbox.addAll([
        ev('1', 'Purchase of KWD 5.250 at TALABAT card ending 1234'),
        ev('2', 'A purchase was made on your card ending 1234 at TALABAT'),
        ev('3', 'Your OTP is 482913. Do not share it.'),
      ]);
    final sum = await runHeadlessCapture(bridge: b, store: s);
    expect(sum['posted'], 1);
    expect(sum['review'], 1);
    expect(sum['ignored'], 1);
    expect(sum['queued'], 0);
    expect(sum['last'], 'KWD 5.250 · Talabat');
    expect((await s.allTransactions()).length, 1);
  });

  test('process killed after posting but before ack → replay does not double-post', () async {
    final s = await newTestStore(now: DateTime.utc(2026, 11, 22, 9));
    final b = FakeBridge()..inbox.add(ev('run-77', 'Purchase of KWD 3.000 at STARBUCKS card ending 1234'));
    b.crashBeforeAck = true;
    final svc = CaptureService(b, IngestionService(s), s);
    await expectLater(svc.drain(), throwsStateError);
    expect(b.inbox.length, 1, reason: 'still queued after crash');
    // "Restart": a fresh service drains the same inbox item again.
    final svc2 = CaptureService(b, IngestionService(s), s);
    await svc2.drain();
    expect(b.inbox, isEmpty);
    expect((await s.allTransactions()).length, 1);
  });

  test('Wallet: zero amount or blank merchant go to review, never a KWD 0 expense', () async {
    final s = await newTestStore(now: DateTime.utc(2026, 11, 22, 9));
    final b = FakeBridge()
      ..inbox.addAll([
        ev('w1', '', source: 'wallet', fields: {'merchant': ' ', 'amount': '0.0', 'card': 'Visa 1234'}),
        ev('w2', '', source: 'wallet', fields: {'merchant': ' ', 'amount': 'KWD 0.000'}),
        ev('w3', '', source: 'wallet', fields: {'merchant': '', 'name': 'Talabat', 'amount': 'KWD 2.500'}),
      ]);
    final sum = await runHeadlessCapture(bridge: b, store: s);
    expect(sum['review'], 2);
    expect(sum['posted'], 1);
    final txs = await s.allTransactions();
    expect(txs.single.amountMinor, 2500);
    expect(txs.single.merchant, 'Talabat');
  });

  test('unknown or ambiguous messages never silently create transactions', () async {
    final s = await newTestStore(now: DateTime.utc(2026, 11, 22, 9));
    final ing = IngestionService(s);
    final inputs = [
      'Dear customer, your statement is ready.',
      'Transaction alert: card 1234 used.',
      'تم استخدام بطاقتك المنتهية ب 1234',
      'Purchase at TALABAT for KWD',
      'Your limit has been updated to KWD 2,000.000',
      'مبلغ 5 تم',
    ];
    for (final t in inputs) {
      final r = await ing.ingest(RawEvent(text: t, receivedAt: DateTime.utc(2026, 11, 22, 9), source: SourceKind.sms));
      expect(r.outcome, isNot(IngestOutcome.posted), reason: t);
    }
    expect((await s.allTransactions()).where((t) => !t.needsReview), isEmpty);
  });
}

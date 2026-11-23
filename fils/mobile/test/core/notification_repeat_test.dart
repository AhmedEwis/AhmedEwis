// A bank app (or the Synthetic Notifier test tool) re-posting identical content under a
// new notification key, after Android restarted the Fils process (the listener's
// in-memory 10-minute filter is gone). Found while writing device-acceptance N6b.
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/time/kuwait_time.dart';
import 'package:fils/data/ingestion.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

const pkg = 'kw.fils.testtools.synthetic_notifier';
const txt = 'NBK\n[SYNTHETIC] Purchase of KWD 2.000 at TALABAT card ending 1234. Available balance KWD 992.750';
final t0 = DateTime.utc(2026, 11, 22, 9);

RawEvent n(DateTime at, String key, {String package = pkg, String sender = 'NBK', String text = txt}) =>
    RawEvent(text: text, receivedAt: at, source: SourceKind.notification, sender: sender, packageName: package, sourceId: '$key|h');

void main() {
  test('identical content, new key, within 10 minutes → held, not counted twice', () async {
    final s = await newTestStore(now: t0);
    final ing = IngestionService(s);
    expect((await ing.ingest(n(t0, 'k1'))).outcome, IngestOutcome.posted);
    final r = await ing.ingest(n(t0.add(const Duration(minutes: 2)), 'k2'));
    expect(r.outcome, IngestOutcome.possibleDuplicate);
    expect(r.transactionId, isNull);
    expect((await s.allTransactions()).length, 1);
    // Same transaction keeps one; the held item is resolved.
    final cand = (await (s.db.select(s.db.sourceEvents)..where((x) => x.id.equals(r.sourceEventId))).getSingle()).matchCandidates!;
    await ing.confirmSameTransaction(r.sourceEventId, cand);
    expect((await s.allTransactions()).length, 1);
    expect(totalsFor(await s.allTransactions(), calendarMonth(t0)).spentIn('KWD'), 2000);
  });

  test('Separate purchase on the held repeat counts it exactly once', () async {
    final s = await newTestStore(now: t0);
    final ing = IngestionService(s);
    await ing.ingest(n(t0, 'k1'));
    final r = await ing.ingest(n(t0.add(const Duration(minutes: 2)), 'k2'));
    await ing.confirmSeparate(r.sourceEventId);
    await ing.confirmSeparate(r.sourceEventId);
    expect(totalsFor(await s.allTransactions(), calendarMonth(t0)).spentIn('KWD'), 4000);
  });

  test('the same key again is a plain duplicate (unchanged)', () async {
    final s = await newTestStore(now: t0);
    final ing = IngestionService(s);
    await ing.ingest(n(t0, 'k1'));
    expect((await ing.ingest(n(t0.add(const Duration(minutes: 2)), 'k1'))).outcome, IngestOutcome.duplicate);
  });

  test('after 10 minutes, identical content is a new purchase', () async {
    final s = await newTestStore(now: t0);
    final ing = IngestionService(s);
    await ing.ingest(n(t0, 'k1'));
    expect((await ing.ingest(n(t0.add(const Duration(minutes: 11)), 'k2'))).outcome, IngestOutcome.posted);
    expect((await s.allTransactions()).length, 2);
  });

  test('identical text from a different app, or a different sender, is not a repeat', () async {
    final s = await newTestStore(now: t0);
    final ing = IngestionService(s);
    await ing.ingest(n(t0, 'k1'));
    expect((await ing.ingest(n(t0.add(const Duration(minutes: 1)), 'k2', package: 'com.example.otherbank'))).outcome, IngestOutcome.posted);
    expect((await ing.ingest(n(t0.add(const Duration(minutes: 2)), 'k3', sender: 'NBK Alerts'))).outcome, IngestOutcome.posted);
    expect((await s.allTransactions()).length, 3);
  });
}

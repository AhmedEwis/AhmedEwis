// The Synthetic Notifier test tool (fils/tools/synthetic_notifier) posts the exact
// notifications in its assets/messages.json. This test feeds those exact payloads, in
// the shape FilsNotificationListener + CaptureInbox produce, through the same Dart path
// the device uses (CaptureService.eventFromNative → ingestion). The expected values in
// docs/device-acceptance.md Part 2a therefore match what the tool posts.
import 'dart:convert';
import 'dart:io';

import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/data/ingestion.dart';
import 'package:fils/native/capture_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

const notifierPackage = 'kw.fils.testtools.synthetic_notifier';

void main() {
  final catalog = jsonDecode(File('../tools/synthetic_notifier/assets/messages.json').readAsStringSync()) as Map<String, dynamic>;
  final msgs = (catalog['messages'] as List).cast<Map<String, dynamic>>();

  test('the notifier package is allowed by the listener (not in BLOCKED_PACKAGES); messaging apps stay blocked', () {
    final kt = File('android/app/src/main/kotlin/kw/fils/fils/FilsNotificationListener.kt').readAsStringSync();
    final blocked = RegExp(r'"([a-z0-9_.]+)"').allMatches(kt.substring(kt.indexOf('BLOCKED_PACKAGES'), kt.indexOf(')', kt.indexOf('BLOCKED_PACKAGES')))).map((m) => m.group(1)).toSet();
    expect(blocked, isNot(contains(notifierPackage)));
    expect(blocked, containsAll(['com.google.android.apps.messaging', 'com.samsung.android.messaging', 'com.android.mms', 'com.android.messaging', 'com.whatsapp', 'org.telegram.messenger']));
  });

  test('every catalog message, delivered as the listener would deliver it, posts with the documented values', () async {
    final now = DateTime.utc(2026, 11, 22, 9, 30);
    final s = await newTestStore(now: now);
    final acct = await s.createAccount(name: 'Test NBK card', kind: 'card', currency: 'KWD', institutionId: 'nbk', maskLast4: '1234', openingBalanceMinor: 1000000);
    final ing = IngestionService(s);
    var n = 0;
    for (final m in msgs) {
      n++;
      expect(m['body'] as String, startsWith('[SYNTHETIC]'));
      // FilsNotificationListener: text = "$title\n$body", sender = title, package, platformId = "${sbn.key}|hash".
      final native = <String, dynamic>{
        'id': 'inbox-$n',
        'source': 'notification',
        'text': '${m['title']}\n${m['body']}',
        'sender': m['title'],
        'package': notifierPackage,
        'platformId': '0|$notifierPackage|$n|null|10123|hash$n',
        'receivedAt': now.add(Duration(minutes: n)).toIso8601String(),
      };
      final e = CaptureService.eventFromNative(native)!;
      final r = await ing.ingest(e);
      final exp = (m['expect'] as Map).cast<String, dynamic>();
      expect(r.outcome, IngestOutcome.posted, reason: m['id'] as String);
      final tx = (await s.transaction(r.transactionId!))!;
      expect(tx.amountMinor, exp['amount_minor']);
      expect(tx.categoryId, exp['category']);
      expect(tx.accountId, acct.id);
      expect(tx.status, TxStatuses.posted);
      expect((await s.account(acct.id))!.reportedAvailableMinor, exp['balance_minor']);
      // The same notification delivered again (same key) is a duplicate.
      expect((await ing.ingest(e)).outcome, IngestOutcome.duplicate);
    }
    final total = msgs.fold<int>(0, (a, m) => a + ((m['expect'] as Map)['amount_minor'] as int));
    expect(calculatedBalance((await s.account(acct.id))!, await s.transactionsForAccount(acct.id)), 1000000 - total);
  });
}

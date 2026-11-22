// Headless capture entrypoint, started by native code (iOS HeadlessCapture /
// Android HeadlessCaptureRunner) when a capture arrives while the UI isn't running.
// Runs the same deterministic pipeline against the same encrypted database, then reports
// a summary. No network calls happen here: cloud AI fallback only runs in the UI app,
// after consent.
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'core/money/money.dart';
import 'data/db/open.dart';
import 'data/ingestion.dart';
import 'data/store.dart';
import 'native/capture_bridge.dart';

@pragma('vm:entry-point')
Future<void> captureMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const done = MethodChannel('fils/capture/headless');
  try {
    final summary = await runHeadlessCapture();
    await done.invokeMethod('done', summary);
  } catch (e) {
    // Most commonly the Keychain is unavailable (device not unlocked since boot). Items
    // stay securely queued and are processed later.
    await done.invokeMethod('done', {'error': e.runtimeType.toString()});
  }
}

Future<Map<String, Object?>> runHeadlessCapture({CaptureBridge? bridge, FinanceStore? store}) async {
  final st = store ?? FinanceStore(await DatabaseOpener.open());
  await st.ensureSeeded();
  final svc = CaptureService(bridge ?? CaptureBridge(), IngestionService(st), st);
  final results = <IngestResult>[];
  final sub = svc.results.listen(results.add);
  await svc.drain();
  await Future<void>.delayed(Duration.zero);
  await sub.cancel();
  var posted = 0, review = 0, ignored = 0;
  String? last;
  for (final r in results) {
    switch (r.outcome) {
      case IngestOutcome.posted || IngestOutcome.merged || IngestOutcome.settledPending:
        posted++;
        final a = r.parsed?.amount;
        if (a != null) last = '${Money(a.minor, a.currency)}${r.parsed?.merchant != null ? ' · ${r.parsed!.merchant}' : ''}';
      case IngestOutcome.review || IngestOutcome.possibleDuplicate:
        review++;
      default:
        ignored++;
    }
  }
  final queued = await (bridge ?? CaptureBridge()).inboxCount();
  if (store == null) await st.db.close();
  return {'posted': posted, 'review': review, 'ignored': ignored, 'queued': queued, 'last': last};
}

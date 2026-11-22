import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/parsing/models.dart';
import '../data/ingestion.dart';
import '../data/store.dart';

/// Bridge to native capture adapters.
///
/// iOS: App Intents invoked by the user's personal Shortcuts automations write events to
/// an App Group inbox (file protection: until first user authentication). The app drains
/// the inbox when it becomes active and on the intent's "process now" signal.
///
/// Android: a NotificationListenerService writes allowlisted bank-app notifications to an
/// app-private inbox. The optional `sms` flavor adds an SMS receiver (only for builds
/// approved under Google Play's SMS policy).
class CaptureBridge {
  static const _ch = MethodChannel('fils/capture');
  static const _events = EventChannel('fils/capture/events');

  bool get supported => Platform.isIOS || Platform.isAndroid;

  Future<List<Map<String, dynamic>>> drainInbox() async {
    if (!supported) return const [];
    final list = await _ch.invokeListMethod<Map<dynamic, dynamic>>('drainInbox') ?? const [];
    return [for (final m in list) m.cast<String, dynamic>()];
  }

  Future<void> ack(List<String> ids) async {
    if (!supported || ids.isEmpty) return;
    await _ch.invokeMethod('ack', {'ids': ids});
  }

  /// Number of securely queued captures not yet processed into the ledger.
  Future<int> inboxCount() async => supported ? (await _ch.invokeMethod<int>('inboxCount') ?? 0) : 0;

  Stream<void> get onNewEvents => supported ? _events.receiveBroadcastStream().map((_) {}) : const Stream.empty();

  // ---- Android
  Future<bool> notificationAccessGranted() async => Platform.isAndroid && (await _ch.invokeMethod<bool>('notificationAccessGranted') ?? false);
  Future<void> openNotificationAccessSettings() => _ch.invokeMethod('openNotificationAccessSettings');
  Future<List<Map<String, String>>> launchableApps() async {
    final l = await _ch.invokeListMethod<Map<dynamic, dynamic>>('launchableApps') ?? const [];
    return [for (final m in l) m.cast<String, String>()];
  }

  Future<void> setMonitoredPackages(List<String> pkgs) => _ch.invokeMethod('setMonitoredPackages', {'packages': pkgs});
  Future<List<String>> monitoredPackages() async => (await _ch.invokeListMethod<String>('monitoredPackages')) ?? const [];
  Future<void> setSmsSenders(List<String> senders) => _ch.invokeMethod('setSmsSenders', {'senders': senders});
  Future<bool> smsCaptureAvailable() async => Platform.isAndroid && (await _ch.invokeMethod<bool>('smsCaptureAvailable') ?? false);
  Future<bool> ignoringBatteryOptimizations() async => Platform.isAndroid && (await _ch.invokeMethod<bool>('ignoringBatteryOptimizations') ?? false);
  Future<void> openBatterySettings() => _ch.invokeMethod('openBatterySettings');
  Future<void> requestRebind() => _ch.invokeMethod('requestRebind');
  Future<Map<String, dynamic>> listenerStatus() async => ((await _ch.invokeMapMethod<String, dynamic>('listenerStatus')) ?? const {});

  /// Text shared into the app (Android ACTION_SEND / iOS share extension inbox).
  Future<String?> takeSharedText() async => supported ? await _ch.invokeMethod<String>('takeSharedText') : null;

  // ---- iOS
  Future<void> openShortcutsApp() => _ch.invokeMethod('openShortcuts');
}

/// Drains native inboxes into the ingestion pipeline. Each event is acknowledged only
/// after it has been durably processed (posted, merged, queued for review or ignored),
/// so a crash mid-way replays it safely: replay protection dedupes by platform id.
class CaptureService {
  final CaptureBridge bridge;
  final IngestionService ingestion;
  final FinanceStore store;
  bool _running = false;
  StreamSubscription<void>? _sub;
  final _results = StreamController<IngestResult>.broadcast();

  CaptureService(this.bridge, this.ingestion, this.store);

  Stream<IngestResult> get results => _results.stream;

  void start() {
    _sub ??= bridge.onNewEvents.listen((_) => drain());
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _results.close();
  }

  Future<int> drain() async {
    if (_running) return 0;
    _running = true;
    var n = 0;
    try {
      final events = await bridge.drainInbox();
      final done = <String>[];
      for (final m in events) {
        final ev = eventFromNative(m);
        if (ev == null) {
          done.add(m['id'] as String? ?? '');
          continue;
        }
        if ((m['kind'] as String?) == 'test') {
          await store.setSetting(SettingKeys.shortcutTestReceivedAt, DateTime.now().toUtc().toIso8601String());
          done.add(m['id'] as String);
          continue;
        }
        try {
          final r = await ingestion.ingest(ev);
          _results.add(r);
          done.add(m['id'] as String);
          n++;
        } catch (_) {
          // Ingestion is atomic: a failure leaves no partial state. The event stays in the
          // native inbox (not acked) and is retried on the next drain; others continue.
        }
      }
      await bridge.ack(done);
    } finally {
      _running = false;
    }
    return n;
  }

  static RawEvent? eventFromNative(Map<String, dynamic> m) {
    final src = switch (m['source']) {
      'shortcut' => SourceKind.shortcut,
      'wallet' => SourceKind.wallet,
      'notification' => SourceKind.notification,
      'sms' => SourceKind.sms,
      'share' => SourceKind.share,
      _ => null,
    };
    if (src == null) return null;
    final ts = DateTime.tryParse(m['receivedAt'] as String? ?? '')?.toUtc() ?? DateTime.now().toUtc();
    final fields = (m['fields'] as Map?)?.cast<String, String>();
    return RawEvent(
      text: (m['text'] as String?) ?? '',
      sender: m['sender'] as String?,
      packageName: m['package'] as String?,
      receivedAt: ts,
      source: src,
      sourceId: m['platformId'] as String?,
      fields: fields,
    );
  }
}

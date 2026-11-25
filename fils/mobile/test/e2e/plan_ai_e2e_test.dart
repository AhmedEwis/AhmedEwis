// Device CloudPlanner ↔ live local backend. The local server has no AI provider
// configured, so the honest outcome is "provider off": this proves auth, consent and
// the gateway path end to end, NOT that a live model works.
import 'dart:io';

import 'package:fils/data/api/api_client.dart';
import 'package:fils/data/planner/cloud_planner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_sync_e2e_test.dart' show MemoryTokenStore;

void main() {
  final base = Platform.environment['FILS_E2E_API'];
  test('consent gate, then provider-not-configured, through the real gateway', () async {
    final api = ApiClient(baseUrl: base, tokens: MemoryTokenStore());
    await api.demoSession();
    final planner = CloudPlanner(api, () async => true);
    Future<AiUnavailable> reason() async {
      try {
        await planner.understand('عايز أوفر 150 دينار الشهر ده', arabic: true, today: DateTime.utc(2026, 11, 10), cycleStartDay: 1);
      } on PlannerAiException catch (e) {
        return e.reason;
      }
      fail('a live answer was not expected from a server without an AI provider');
    }

    expect(await reason(), AiUnavailable.consentOff, reason: 'server refuses before consent is recorded');
    await api.recordConsent('cloud_ai', true, '2026-11-10');
    expect(await reason(), AiUnavailable.providerOff);
  }, skip: base == null ? 'set FILS_E2E_API to run against a live backend' : null);
}

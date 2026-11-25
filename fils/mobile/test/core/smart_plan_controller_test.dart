import 'dart:convert';

import 'package:fils/data/api/api_client.dart';
import 'package:fils/data/planner/cloud_planner.dart';
import 'package:fils/data/planner/plan_service.dart';
import 'package:fils/features/smart_plan/smart_plan_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../e2e/backend_sync_e2e_test.dart' show MemoryTokenStore;
import '../support/planner_fixtures.dart';
import '../support/test_db.dart';

const headline = 'عايز أوفر 150 دينار الشهر ده، بس ما تقللش الجيم ولا مصاريف البيت.';

Future<ApiClient> fakeApi(Map<String, dynamic> Function(Map<String, dynamic> body) reply) async {
  final t = MemoryTokenStore();
  await t.save({'access_token': 'a', 'refresh_token': 'r', 'access_expires_at': DateTime.now().add(const Duration(hours: 1)).toIso8601String()});
  return ApiClient(
    baseUrl: 'https://api.example',
    tokens: t,
    client: MockClient((r) async => http.Response(jsonEncode(reply(jsonDecode(r.body) as Map<String, dynamic>)), 200, headers: {'content-type': 'application/json; charset=utf-8'})),
  );
}

Map<String, dynamic> intentReply() => {
      'status': 'ok',
      'intent': {'target_minor': 150000, 'target_evidence': '150 دينار', 'currency': 'KWD', 'deadline': 'this_cycle', 'protected_categories': ['fitness', 'housing', 'bills', 'groceries']},
    };

Future<SmartPlanController> controller(CloudPlanner? cloud) async {
  final s = await newTestStore(now: planNow);
  await seedHistory(s, fitness: true);
  final c = SmartPlanController(store: s, service: PlanService(s), cloud: cloud, arabic: true, baseCurrency: 'KWD', cycleStartDay: 1, now: () => planNow);
  await c.load();
  return c;
}

void main() {
  test('live AI path: understanding and explanation labelled live; amounts identical to the local plan', () async {
    final api = await fakeApi((b) => b['stage'] == 'understand'
        ? intentReply()
        : {'status': 'ok', 'explanation': {'summary': 'هدفك {fact:target} ممكن بتعديل واحد.', 'actions': [{'id': 'cut:food', 'why': 'مصروفك المعتاد {fact:avg:food}.'}]}});
    final live = await controller(CloudPlanner(api, () async => true));
    await live.understand(headline);
    expect(live.understanding, Understanding.liveAi);
    expect(live.explanationIsLive, isTrue);
    expect(live.aiReason, isNull);

    final local = await controller(null);
    await local.understand(headline);
    expect(local.understanding, Understanding.local);
    expect(local.explanationIsLive, isFalse);
    // The model can't move a single fils: same actions and figures either way.
    expect(live.proposal!.actions.map((a) => [a.categoryId, a.limitMinor, a.impactMinor]).toList(),
        local.proposal!.actions.map((a) => [a.categoryId, a.limitMinor, a.impactMinor]).toList());
    expect(live.proposal!.amount(live.proposal!.projectedSavingsFactId), local.proposal!.amount(local.proposal!.projectedSavingsFactId));
  });

  test('a live explanation with a fabricated number falls back to the local explanation (not labelled live)', () async {
    final api = await fakeApi((b) => b['stage'] == 'understand' ? intentReply() : {'status': 'ok', 'explanation': {'summary': 'Move 500 KWD to savings today.', 'actions': []}});
    final c = await controller(CloudPlanner(api, () async => true));
    await c.understand(headline);
    expect(c.understanding, Understanding.liveAi);
    expect(c.explanationIsLive, isFalse);
    expect(c.explanation!.live, isFalse);
    expect(c.aiReason, AiUnavailable.invalidOutput);
  });

  test('consent off: basic local planner, with the reason; no request made', () async {
    var calls = 0;
    final api = await fakeApi((b) {
      calls++;
      return intentReply();
    });
    final c = await controller(CloudPlanner(api, () async => false));
    await c.understand(headline);
    expect(c.understanding, Understanding.local);
    expect(c.aiReason, AiUnavailable.consentOff);
    expect(calls, 0);
    expect(c.proposal, isNotNull);
  });

  test('remembered protections are applied only after the user asks to remember them', () async {
    final c = await controller(null);
    await c.understand('اوفر 200 دينار الشهر ده بس ما تقللش المطاعم');
    expect(c.intent!.protectedCategories, {'food'});
    await c.understand('اوفر 200 دينار الشهر ده');
    expect(c.intent!.protectedCategories, isEmpty, reason: 'nothing remembered yet');
    await c.understand('اوفر 200 دينار الشهر ده بس ما تقللش المطاعم');
    await c.rememberProtected();
    await c.understand('اوفر 200 دينار الشهر ده');
    expect(c.intent!.protectedCategories, {'food'});
    await c.resetMemory();
    await c.understand('اوفر 200 دينار الشهر ده');
    expect(c.intent!.protectedCategories, isEmpty);
  });
}

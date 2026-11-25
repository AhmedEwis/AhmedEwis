/// Cloud AI for "My Smart Plan": understanding and explanations only, through the backend
/// AI gateway (credentials stay on the server). Requires explicit cloud-AI consent.
///
/// What leaves the device:
/// - understand: the user's request (sanitized: card/account-like digit runs masked),
///   the list of category ids, locale, today's date and the cycle start day;
/// - explain: computed facts as {id, short category-level label, formatted amount,
///   source}, the proposed action ids, the plan status and limitation codes.
/// Never: transactions, merchant names, account or card identifiers, raw bank messages,
/// household data. Every model output is validated here again before use.
library;

import 'package:uuid/uuid.dart';

import '../../core/domain/categories.dart';
import '../../core/money/money.dart';
import '../../core/parsing/sanitizer.dart';
import '../../core/planner/goal_parser.dart';
import '../../core/planner/plan_models.dart';
import '../api/api_client.dart';

enum AiUnavailable { consentOff, notConfigured, signedOut, providerOff, quota, network, invalidOutput }

class PlannerAiException implements Exception {
  final AiUnavailable reason;
  const PlannerAiException(this.reason);
  @override
  String toString() => 'PlannerAiException($reason)';
}

/// A validated explanation: text with {fact:ID} references, rendered from facts.
class PlanExplanation {
  final String summary;
  final Map<String, String> whyByAction;
  final bool live; // true only when it came from the live AI provider and passed validation
  const PlanExplanation(this.summary, this.whyByAction, {required this.live});
  Map<String, Object?> toJson() => {'summary': summary, 'why': whyByAction, 'live': live};
}

final _factRef = RegExp(r'\{fact:([a-z_]{1,24}(?::[a-z_*]{1,32})?)\}');
final _digits = RegExp(r'[0-9٠-٩۰-۹]');

/// A narrative is acceptable only if every number in it is a {fact:ID} reference to a
/// computed fact. A digit the model wrote itself (fabricated amount) rejects it.
bool narrativeOk(String text, Set<String> factIds) {
  if (text.isEmpty || text.length > 600) return false;
  for (final m in _factRef.allMatches(text)) {
    if (!factIds.contains(m.group(1))) return false;
  }
  final stripped = text.replaceAll(_factRef, '');
  if (_digits.hasMatch(stripped)) return false;
  final l = stripped.toLowerCase();
  return !l.contains('http') && !l.contains('www.');
}

/// Replaces {fact:ID} with the authoritative amount from the plan's facts.
String renderNarrative(String text, Map<String, Fact> facts, String Function(Money) money) =>
    text.replaceAllMapped(_factRef, (m) {
      final f = facts[m.group(1)];
      return f == null ? '' : money(Money(f.amountMinor, f.currency));
    });

/// Validates `explain_plan` output against the plan (device-side, in addition to the server).
PlanExplanation? validateExplanation(Map<String, Object?> args, PlanProposal p) {
  final ids = p.facts.keys.toSet();
  final summary = args['summary'];
  if (summary is! String || !narrativeOk(summary, ids)) return null;
  final actionIds = {for (final a in p.actions) a.id};
  final why = <String, String>{};
  final list = args['actions'] ?? const [];
  if (list is! List || list.length > 3) return null;
  for (final w in list) {
    if (w is! Map) return null;
    final id = w['id'], text = w['why'];
    if (id is! String || !actionIds.contains(id) || text is! String || text.length > 300 || !narrativeOk(text, ids)) return null;
    why[id] = text;
  }
  return PlanExplanation(summary, why, live: true);
}

/// The minimum the model needs to explain the plan. Labels are category-level only.
Map<String, Object?> buildExplainPayload(PlanProposal p, {required bool arabic}) {
  final wanted = <String>{
    for (final id in [p.targetFactId, p.incomeFactId, p.baselineSpendFactId, p.baselineSavingsFactId, p.projectedSavingsFactId, p.gapFactId]) ?id,
    for (final a in p.actions) ...[a.baselineFactId, ...a.whyFactIds],
  };
  final facts = [
    for (final id in wanted)
      if (p.facts[id] != null && p.facts[id]!.currency.length == 3)
        {
          'id': id,
          'label': (arabic ? p.facts[id]!.labelAr : p.facts[id]!.labelEn).characters80(),
          'amount': '${Money(p.facts[id]!.amountMinor, p.facts[id]!.currency).toDecimalString()} ${p.facts[id]!.currency}',
          'source': p.facts[id]!.source.name,
        }
  ];
  return {
    'stage': 'explain',
    'conversation_id': const Uuid().v4(),
    'locale': arabic ? 'ar' : 'en',
    'status': switch (p.status) {
      PlanStatus.needsInput => 'needs_input',
      PlanStatus.onTrack => 'on_track',
      PlanStatus.feasible => 'feasible',
      PlanStatus.infeasible => 'infeasible',
    },
    'facts': facts,
    'actions': [for (final a in p.actions) {'id': a.id, 'category': a.categoryId}],
    'limitations': [for (final l in p.limitations) _snake(l.name)],
  };
}

Map<String, Object?> buildUnderstandPayload(String text, {required bool arabic, required DateTime today, required int cycleStartDay}) => {
      'stage': 'understand',
      'conversation_id': const Uuid().v4(),
      'locale': arabic ? 'ar' : 'en',
      'text': sanitizeMessage(text).text,
      'categories': [for (final c in systemCategories) if (!c.income && c.id != Cat.transfers) c.id],
      'today': today.toIso8601String().substring(0, 10),
      'cycle_start_day': cycleStartDay,
    };

String _snake(String s) => s.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}');

extension on String {
  String characters80() => length <= 80 ? this : substring(0, 80);
}

class CloudPlanner {
  final ApiClient api;
  final Future<bool> Function() consented;
  CloudPlanner(this.api, this.consented);

  Future<void> _guard() async {
    if (!api.configured) throw const PlannerAiException(AiUnavailable.notConfigured);
    if (!await consented()) throw const PlannerAiException(AiUnavailable.consentOff);
    if (await api.tokens.access() == null) throw const PlannerAiException(AiUnavailable.signedOut);
  }

  Future<Map<String, dynamic>> _call(Map<String, Object?> body) async {
    try {
      return await api.assistantPlan(body.cast<String, dynamic>());
    } on ApiException catch (e) {
      if (e.code == 'consent_required') throw const PlannerAiException(AiUnavailable.consentOff);
      if (e.code == 'quota_exceeded' || e.status == 429) throw const PlannerAiException(AiUnavailable.quota);
      if (e.isAuth) throw const PlannerAiException(AiUnavailable.signedOut);
      if (e.notConfigured || e.status >= 500) throw const PlannerAiException(AiUnavailable.providerOff);
      throw const PlannerAiException(AiUnavailable.invalidOutput);
    } catch (e) {
      if (e is PlannerAiException) rethrow;
      throw const PlannerAiException(AiUnavailable.network);
    }
  }

  /// Understands the request with the live model. The result is re-validated against
  /// the user's own words; anything unverifiable throws (→ local parser).
  Future<PlanIntent> understand(String text, {required bool arabic, required DateTime today, required int cycleStartDay}) async {
    await _guard();
    final res = await _call(buildUnderstandPayload(text, arabic: arabic, today: today, cycleStartDay: cycleStartDay));
    if (res['status'] != 'ok' || res['intent'] is! Map) throw const PlannerAiException(AiUnavailable.invalidOutput);
    final intent = validateAiIntent((res['intent'] as Map).cast<String, Object?>(), text, knownCategories: {for (final c in systemCategories) c.id});
    if (intent == null) throw const PlannerAiException(AiUnavailable.invalidOutput);
    return intent;
  }

  Future<PlanExplanation> explain(PlanProposal p, {required bool arabic}) async {
    await _guard();
    final res = await _call(buildExplainPayload(p, arabic: arabic));
    if (res['status'] != 'ok' || res['explanation'] is! Map) throw const PlannerAiException(AiUnavailable.invalidOutput);
    final e = validateExplanation((res['explanation'] as Map).cast<String, Object?>(), p);
    if (e == null) throw const PlannerAiException(AiUnavailable.invalidOutput);
    return e;
  }
}

/// Deterministic explanation used when live AI isn't available (consent off, offline,
/// provider not configured, invalid output). Clearly labelled as the basic local planner.
PlanExplanation localExplanation(PlanProposal p, {required bool arabic}) {
  String cat(String id) => id == '*'
      ? (arabic ? 'كل المصروف' : 'overall spending')
      : (systemCategories.where((c) => c.id == id).map((c) => arabic ? c.ar : c.en).firstOrNull ?? id);
  final s = switch (p.status) {
    PlanStatus.onTrack => arabic
        ? 'على وضعك الحالي ستوفر {fact:projected_savings}، وهذا يحقق هدفك {fact:${p.targetFactId}} بدون تغييرات.'
        : 'At your current pace you would save {fact:projected_savings}, which already meets your goal of {fact:${p.targetFactId}}.',
    PlanStatus.feasible => arabic
        ? 'بدون تغيير ستوفر {fact:baseline_savings}. مع ${p.actions.length} ${p.actions.length == 1 ? 'تعديل' : 'تعديلات'} يصبح التوفير المتوقع {fact:projected_savings} لهدف {fact:${p.targetFactId}}.'
        : 'Without changes you would save {fact:baseline_savings}. With ${p.actions.length == 1 ? 'one change' : '${p.actions.length} changes'} the projected savings become {fact:projected_savings} for a goal of {fact:${p.targetFactId}}.',
    PlanStatus.infeasible => arabic
        ? 'الهدف {fact:${p.targetFactId}} أكبر من الممكن هذه الدورة بدون المساس بما طلبت حمايته. أقصى توفير واقعي الآن {fact:projected_savings}. شوف البدائل تحت.'
        : 'A goal of {fact:${p.targetFactId}} is more than this cycle allows without touching what you protected. The most that looks realistic is {fact:projected_savings}. See the alternatives below.',
    PlanStatus.needsInput => arabic ? 'أحتاج بعض المعلومات قبل أن أقترح خطة.' : 'A few details are needed before a plan can be proposed.',
  };
  // The templates contain counts (action numbers) but those are not amounts; render as-is.
  final why = <String, String>{};
  for (final a in p.actions) {
    final hasAvg = p.facts.containsKey('avg:${a.categoryId}');
    why[a.id] = arabic
        ? '${hasAvg ? 'مصروفك المعتاد على ${cat(a.categoryId)} {fact:avg:${a.categoryId}}' : 'المتوقع على ${cat(a.categoryId)} {fact:${a.baselineFactId}}'}، وصرفت هذه الدورة {fact:${a.spentFactId}}. الحد المقترح لا يقل عن المصروف فعلاً، وأقصى تخفيض {fact:cap:${a.categoryId}}.'
        : '${hasAvg ? 'You usually spend {fact:avg:${a.categoryId}} on ${cat(a.categoryId)}' : 'Expected ${cat(a.categoryId)} spending is {fact:${a.baselineFactId}}'}, and {fact:${a.spentFactId}} so far this cycle. The limit never goes below what is already spent, and the cut is at most {fact:cap:${a.categoryId}}.';
  }
  return PlanExplanation(s, why, live: false);
}

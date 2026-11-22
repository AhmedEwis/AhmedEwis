import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/assistant/local_assistant.dart';
import '../../core/assistant/tools.dart';
import '../../core/money/money.dart';
import '../../core/parsing/kuwait_parser.dart';
import '../../core/parsing/models.dart';
import '../../core/parsing/sanitizer.dart';
import '../api/api_client.dart';
import '../ingestion.dart';

/// Cloud assistant: the LLM chooses tools; the DEVICE runs them and returns only their
/// aggregate results. The model never receives raw transactions, never runs SQL, and its
/// numbers are never trusted. The final answer is composed from tool results by the same
/// deterministic templates when possible.
class CloudAssistant {
  final ApiClient api;
  final LocalAssistant local;
  CloudAssistant(this.api, this.local);

  Future<AssistantAnswer> answer(String question, FinanceSnapshot snap, {required bool arabic, List<Map<String, dynamic>> history = const []}) async {
    final messages = <Map<String, dynamic>>[...history, {'role': 'user', 'content': question}];
    final results = <ToolResult>[];
    final convo = const Uuid().v4();
    for (var turn = 0; turn < 4; turn++) {
      final res = await api.assistantTurn({
        'conversation_id': convo,
        'locale': arabic ? 'ar' : 'en',
        'messages': messages,
        'tools': assistantToolSchemas,
        'context': {
          'currency': snap.baseCurrency,
          'timezone': 'Asia/Kuwait',
          'today': snap.now.toIso8601String().substring(0, 10),
          'cycle_start_day': snap.cycleStartDay,
        },
      });
      final msg = (res['message'] as Map).cast<String, dynamic>();
      final calls = (msg['tool_calls'] as List?)?.cast<Map>() ?? const [];
      if (calls.isEmpty) {
        final text = (msg['content'] as String?) ?? '';
        // Prefer deterministic phrasing of tool results; append model narrative only when
        // no tool was used (e.g. a general money tip), clearly without new numbers.
        if (results.isNotEmpty) {
          return AssistantAnswer(results.map(local.compose).join('\n\n'), results, onDevice: false);
        }
        return AssistantAnswer(text, results, onDevice: false, understood: text.isNotEmpty);
      }
      messages.add({'role': 'assistant', 'content': msg['content'], 'tool_calls': calls});
      for (final c in calls) {
        final name = c['name'] as String;
        final rawArgs = c['arguments'];
        final args = rawArgs is String ? (jsonDecode(rawArgs.isEmpty ? '{}' : rawArgs) as Map).cast<String, Object?>() : (rawArgs as Map? ?? {}).cast<String, Object?>();
        final r = runTool(name, args, snap); // authorization: local snapshot = this user only
        results.add(r);
        messages.add({'role': 'tool', 'tool_call_id': c['id'], 'content': jsonEncode(r.data)});
      }
    }
    return AssistantAnswer(results.map(local.compose).join('\n\n'), results, onDevice: false);
  }
}

/// Consent-gated AI fallback for messages the deterministic parser can't read. Text is
/// sanitized on the device first. The server validates evidence substrings, and we
/// re-validate here: the amount must parse from text present in the original message.
/// Results always go to the review inbox.
class CloudExtractor implements AiExtractor {
  final ApiClient api;
  final Future<bool> Function() consented;
  CloudExtractor(this.api, this.consented);

  @override
  Future<ParsedEvent?> extract(RawEvent e) async {
    if (!api.configured || !await consented()) return null;
    final clean = sanitizeMessage(e.text).text;
    final res = await api.extract(clean, sender: e.sender);
    if (res['status'] != 'extracted' && res['status'] != 'ambiguous') return null;
    final r = (res['result'] as Map?)?.cast<String, dynamic>();
    if (r == null) return null;
    final ev = (r['evidence'] as Map?)?.cast<String, dynamic>() ?? const {};
    final amountEv = ev['amount'] as String?;
    final cur = r['currency'] as String?;
    final norm = normalizeForMatch(e.text);
    Money? amount;
    if (amountEv != null && cur != null && norm.contains(normalizeForMatch(amountEv))) {
      final m = Money.parse(amountEv.replaceAll(RegExp(r'[^0-9.,٠-٩٫]'), ''), cur);
      if (m != null && m.minor == (r['amount_minor'] as num?)?.toInt()) amount = m;
    }
    if (amount == null) return null; // never accept an unevidenced amount
    final kind = TxKind.values.where((k) => k.name == _kindMap(r['kind'] as String?)).firstOrNull ?? TxKind.unknown;
    final merchantEv = ev['merchant'] as String?;
    return ParsedEvent(
      kind: kind == TxKind.unknown ? TxKind.purchase : kind,
      amount: amount,
      merchant: merchantEv != null && norm.contains(normalizeForMatch(merchantEv)) ? (r['merchant'] as String?) : null,
      merchantRaw: merchantEv,
      cardLast4: r['card_last4'] as String?,
      confidence: 0.5, // always below the auto-post threshold → review inbox
      parserId: 'cloud-ai',
      parserVersion: (res['model'] as String?) ?? 'unknown',
      notes: const ['Extracted by cloud AI; please confirm.'],
      evidence: {'amount': amountEv!},
    );
  }

  String _kindMap(String? k) => switch (k) {
        'purchase' => 'purchase',
        'income' => 'income',
        'transfer_in' => 'transferIn',
        'transfer_out' => 'transferOut',
        'atm_withdrawal' => 'atmWithdrawal',
        'fee' => 'fee',
        'refund' => 'refund',
        'reversal' => 'reversal',
        'card_payment' => 'cardPayment',
        'installment' => 'installment',
        'declined' => 'declined',
        _ => 'unknown',
      };
}

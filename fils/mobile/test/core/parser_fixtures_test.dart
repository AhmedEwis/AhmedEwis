import 'dart:convert';
import 'dart:io';

import 'package:fils/core/domain/categories.dart';
import 'package:fils/core/parsing/kuwait_parser.dart';
import 'package:fils/core/parsing/merchant_directory.dart';
import 'package:fils/core/parsing/models.dart';
import 'package:fils/core/parsing/sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Every fixture file is tested: synthetic sets and (when added) real sanitized samples.
  final files = Directory('../fixtures/messages/v1').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    _runFile(file);
  }
}

void _runFile(File file) {
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final defaultReceived = DateTime.parse(data['received_at_default'] as String);
  const parser = KuwaitParser();
  final provenance = data['provenance'] as String;
  final real = provenance.startsWith('REAL-SAMPLE');

  test('${file.uri.pathSegments.last}: provenance is labeled SYNTHETIC or REAL-SAMPLE', () {
    expect(provenance.startsWith('SYNTHETIC') || real, isTrue);
    if (real) expect((data['consent_ref'] as String?)?.isNotEmpty, isTrue, reason: 'real samples need a consent reference');
  });

  for (final c in (data['cases'] as List).cast<Map<String, dynamic>>()) {
    test('fixture ${c['id']}', () {
      final r = parser.parse(RawEvent(
        text: c['text'] as String,
        sender: c['sender'] as String?,
        receivedAt: c['received_at'] != null ? DateTime.parse(c['received_at'] as String) : defaultReceived,
        source: SourceKind.sms,
      ));
      final e = (c['expect'] as Map).cast<String, dynamic>();
      final why = 'case ${c['id']} → $r notes=${r.notes}';
      expect(r.kind.name, e['kind'], reason: why);
      if (e.containsKey('status')) expect(r.status.name, e['status'], reason: why);
      if (e.containsKey('amount')) expect(r.amount.toString(), e['amount'], reason: why);
      if (e.containsKey('original')) expect(r.originalAmount.toString(), e['original'], reason: why);
      if (e.containsKey('balance')) expect(r.balance.toString(), e['balance'], reason: why);
      if (e.containsKey('available')) expect(r.available.toString(), e['available'], reason: why);
      if (e.containsKey('merchant')) expect(r.merchant, e['merchant'], reason: why);
      if (e.containsKey('processor')) expect(r.processor, e['processor'], reason: why);
      if (e.containsKey('card_last4')) expect(r.cardLast4, e['card_last4'], reason: why);
      if (e.containsKey('account_last4')) expect(r.accountLast4, e['account_last4'], reason: why);
      if (e.containsKey('bank')) expect(r.bankId, e['bank'], reason: why);
      if (e.containsKey('occurred_at')) expect(r.occurredAt?.toIso8601String(), DateTime.parse(e['occurred_at'] as String).toIso8601String(), reason: why);
      if (e.containsKey('needs_review')) expect(r.needsReview || r.kind == TxKind.unknown, e['needs_review'], reason: why);
      if (e.containsKey('category')) {
        final m = matchMerchant(r.merchantRaw ?? r.merchant);
        expect(m?.category ?? Cat.other, e['category'], reason: why);
      }
      if (real) {
        // Real samples must already be sanitized: re-sanitizing changes nothing.
        expect(sanitizeMessage(c['text'] as String).removed, isEmpty, reason: 'unsanitized data in ${c['id']}');
      }
      // Evidence invariant: every evidence value is a substring of the (digit-normalized) input.
      final norm = normalizeForMatch(c['text'] as String);
      for (final v in r.evidence.values) {
        expect(norm.contains(normalizeForMatch(v)), isTrue, reason: 'evidence "$v" not in text');
      }
    });
  }
}

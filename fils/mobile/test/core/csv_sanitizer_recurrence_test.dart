import 'package:fils/core/analytics/recurrence.dart';
import 'package:fils/core/import/csv_import.dart';
import 'package:fils/core/ledger/ledger.dart';
import 'package:fils/core/parsing/sanitizer.dart';
import 'package:fils/data/import_export.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_db.dart';

void main() {
  group('CSV import', () {
    const csvSigned = 'Date,Description,Amount,Balance\n'
        '20/11/2026,TALABAT KUWAIT,-5.250,994.750\n'
        '21/11/2026,SALARY NOV,1500.000,2494.750\n'
        '21/11/2026,"LULU, SALMIYA",-12.500,2482.250\n';
    test('signed amount layout; balance column never used as amount', () {
      final r = parseCsvStatement(csvSigned);
      expect(r.errors, isEmpty);
      expect(r.rows.map((e) => e.amountMinor).toList(), [5250, 1500000, 12500]);
      expect(r.rows.map((e) => e.credit).toList(), [false, true, false]);
      expect(r.rows[2].description, 'LULU, SALMIYA');
    });
    test('debit/credit columns + Arabic digits', () {
      final r = parseCsvStatement('التاريخ,البيان,مدين,دائن\n٢٠/١١/٢٠٢٦,طلبات,٥٫٢٥٠,\n2026-11-21,راتب,,950.000\n');
      expect(r.rows.map((e) => (e.amountMinor, e.credit)).toList(), [(5250, false), (950000, true)]);
    });
    test('re-importing the same file creates no duplicates; same-day different purchases kept', () async {
      final s = await newTestStore();
      final a = await s.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
      final rows = parseCsvStatement(csvSigned).rows;
      final first = await importCsvRows(s, a.id, rows);
      final second = await importCsvRows(s, a.id, rows);
      expect(first.imported, 3);
      expect(second.imported, 0);
      expect(second.duplicates, 3);
      final more = parseCsvStatement('Date,Description,Amount\n20/11/2026,CARIBOU,-1.500\n20/11/2026,STARBUCKS,-1.500\n').rows;
      expect((await importCsvRows(s, a.id, more)).imported, 2);
    });
    test('export neutralizes formula injection', () async {
      expect(csvSafe('=HYPERLINK("x")'), "'=HYPERLINK(\"x\")");
      expect(csvSafe('+cmd'), "'+cmd");
      expect(csvSafe('Talabat'), 'Talabat');
      final s = await newTestStore();
      final a = await s.createAccount(name: 'NBK', kind: 'bank', currency: 'KWD');
      await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 1000, currency: 'KWD', occurredAt: DateTime.utc(2026, 11, 1), source: 'manual', merchant: '=cmd|calc');
      final out = await exportAll(s);
      expect(out['csv'], contains("\"'=cmd|calc\""));
      expect(out['csv'], contains('-1.000'));
    });
  });

  group('sanitizer', () {
    test('removes OTP, card/account numbers, phone, IBAN, names; keeps amounts', () {
      final r = sanitizeMessage('Dear Ahmed Ali, your OTP is 482913. Card 4111 1111 1111 1234 debited KWD 5.250 at TALABAT. '
          'Call 96512345 or +96522223333. IBAN KW81CBKU0000000000001234560101 عزيزي أحمد، رصيدك 100.000 د.ك');
      expect(r.text, isNot(contains('482913')));
      expect(r.text, isNot(contains('4111 1111')));
      expect(r.text, contains('XXXX1234'));
      expect(r.text, isNot(contains('96512345')));
      expect(r.text, isNot(contains('KW81CBKU')));
      expect(r.text, isNot(contains('Ahmed')));
      expect(r.text, isNot(contains('أحمد')));
      expect(r.text, contains('KWD 5.250'));
      expect(r.text, contains('TALABAT'));
      expect(r.text, contains('100.000'));
      expect(r.removed, containsAll(['otp', 'card_or_account_number', 'phone', 'iban', 'name']));
    });
  });

  group('recurrence', () {
    test('detects monthly subscription; ignores irregular', () async {
      final s = await newTestStore();
      final a = await s.createAccount(name: 'Card', kind: 'card', currency: 'KWD', openingBalanceDate: DateTime.utc(2026, 1, 1));
      for (var m = 7; m <= 11; m++) {
        await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 3500, currency: 'KWD', occurredAt: DateTime.utc(2026, m, 4), source: 'sms', merchant: 'Netflix', categoryId: 'subscriptions');
      }
      for (final d in [1, 3, 17, 40, 41]) {
        await s.addTransaction(accountId: a.id, kind: TxKinds.expense, amountMinor: 2000 + d * 37, currency: 'KWD', occurredAt: DateTime.utc(2026, 9, 1).add(Duration(days: d)), source: 'sms', merchant: 'Talabat', categoryId: 'food');
      }
      final sug = detectRecurring(await s.allTransactions(), now: DateTime.utc(2026, 11, 22));
      expect(sug.map((e) => e.merchant), ['Netflix']);
      expect(sug.single.cadence, 'monthly');
      expect(sug.single.nextDate, DateTime.utc(2026, 12, 4));
      // Already tracked → no suggestion.
      expect(detectRecurring(await s.allTransactions(), alreadyTracked: {'netflix'}, now: DateTime.utc(2026, 11, 22)), isEmpty);
    });
    test('addCadence clamps month ends', () {
      expect(addCadence(DateTime.utc(2026, 1, 31), 'monthly', 1), DateTime.utc(2026, 2, 28));
      expect(addCadence(DateTime.utc(2028, 2, 29), 'yearly', 1), DateTime.utc(2029, 2, 28));
    });
  });
}

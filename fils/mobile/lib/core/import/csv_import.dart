/// CSV statement import (on-device). Detects common column layouts:
///  date | description | amount (signed)
///  date | description | debit | credit
///  optional currency / balance columns (balance is never treated as an amount).
library;

import 'package:csv/csv.dart';

import '../money/money.dart';
import '../time/kuwait_time.dart';

class CsvCandidate {
  final DateTime occurredAt; // UTC
  final String description;
  final int amountMinor; // positive
  final bool credit;
  final String currency;
  final int line;
  const CsvCandidate(this.occurredAt, this.description, this.amountMinor, this.credit, this.currency, this.line);
}

class CsvImportResult {
  final List<CsvCandidate> rows;
  final List<String> errors;
  const CsvImportResult(this.rows, this.errors);
}

int? _col(List<String> h, List<String> names) {
  for (var i = 0; i < h.length; i++) {
    final c = h[i].toLowerCase().trim();
    if (names.any((n) => c == n || c.contains(n))) return i;
  }
  return null;
}

DateTime? _date(String s, ReportingZone z) {
  final t = normalizeDigits(s.trim());
  var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(t);
  if (m != null) return z.fromWall(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), 12);
  m = RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})').firstMatch(t);
  if (m != null) {
    var y = int.parse(m[3]!);
    if (y < 100) y += 2000;
    var d = int.parse(m[1]!), mo = int.parse(m[2]!);
    if (mo > 12 && d <= 12) {
      final x = d;
      d = mo;
      mo = x;
    }
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return z.fromWall(y, mo, d, 12);
  }
  return null;
}

CsvImportResult parseCsvStatement(String content, {String defaultCurrency = 'KWD', ReportingZone zone = ReportingZone.kuwait}) {
  final rows = Csv(lineDelimiter: '\n').decode(content.replaceAll('\r\n', '\n').replaceFirst('\uFEFF', ''));
  if (rows.isEmpty) return const CsvImportResult([], ['empty file']);
  final header = rows.first.map((e) => '$e').toList();
  final iDate = _col(header, ['date', 'تاريخ', 'posting', 'value date']);
  final iDesc = _col(header, ['description', 'details', 'narrative', 'merchant', 'البيان', 'الوصف', 'التفاصيل']);
  final iAmount = _col(header, ['amount', 'المبلغ']);
  final iDebit = _col(header, ['debit', 'withdrawal', 'مدين', 'سحب']);
  final iCredit = _col(header, ['credit', 'deposit', 'دائن', 'ايداع', 'إيداع']);
  final iCur = _col(header, ['currency', 'العملة']);
  final errors = <String>[];
  if (iDate == null || iDesc == null || (iAmount == null && iDebit == null && iCredit == null)) {
    return const CsvImportResult([], ['Could not find date, description and amount columns']);
  }
  final out = <CsvCandidate>[];
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r].map((e) => '$e').toList();
    if (row.every((c) => c.trim().isEmpty)) continue;
    String cell(int? i) => i == null || i >= row.length ? '' : row[i].trim();
    final d = _date(cell(iDate), zone);
    if (d == null) {
      errors.add('line ${r + 1}: bad date');
      continue;
    }
    final cur = (cell(iCur).isEmpty ? defaultCurrency : cell(iCur)).toUpperCase();
    final exp = Currency.of(cur).exponent;
    int? minor;
    bool credit;
    if (iAmount != null && cell(iAmount).isNotEmpty) {
      var a = cell(iAmount).replaceAll(RegExp(r'[^\d.,\-()٠-٩٫]'), '');
      final neg = a.startsWith('-') || (a.startsWith('(') && a.endsWith(')'));
      a = a.replaceAll(RegExp(r'[()\-]'), '');
      minor = Money.parseMinor(a, exp);
      credit = !neg;
    } else {
      final db = cell(iDebit).replaceAll(RegExp(r'[^\d.,٠-٩٫]'), '');
      final cr = cell(iCredit).replaceAll(RegExp(r'[^\d.,٠-٩٫]'), '');
      if (db.isNotEmpty && (Money.parseMinor(db, exp) ?? 0) > 0) {
        minor = Money.parseMinor(db, exp);
        credit = false;
      } else {
        minor = Money.parseMinor(cr, exp);
        credit = true;
      }
    }
    if (minor == null || minor == 0) {
      errors.add('line ${r + 1}: bad amount');
      continue;
    }
    out.add(CsvCandidate(d, cell(iDesc), minor.abs(), credit, cur, r + 1));
  }
  return CsvImportResult(out, errors);
}

/// Neutralize spreadsheet formula injection when exporting user-controlled text.
String csvSafe(String v) {
  if (v.isEmpty) return v;
  const danger = ['=', '+', '-', '@', '\t', '\r'];
  return danger.contains(v[0]) ? "'$v" : v;
}

import 'package:intl/intl.dart';

import '../core/money/money.dart';

/// Locale-aware money and date formatting. KWD always shows 3 decimals; minor units are
/// formatted with integer math, never through a double.
class Fmt {
  final bool arabic;
  final bool arabicDigits;
  const Fmt({this.arabic = false, this.arabicDigits = false});

  String digits(String s) {
    if (!arabicDigits) return s;
    const ar = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final c = ch.codeUnitAt(0);
      if (c >= 48 && c <= 57) {
        b.write(ar[c - 48]);
      } else if (ch == '.') {
        b.write('٫');
      } else if (ch == ',') {
        b.write('٬');
      } else {
        b.write(ch);
      }
    }
    return b.toString();
  }

  /// "1,234.567" for KWD. [compact] gives "69.2k"-style short values for chart centers.
  String amount(int minor, String currency, {bool compact = false, bool signed = false, bool trimZeroFraction = false}) {
    final cur = Currency.of(currency);
    final neg = minor < 0;
    final a = minor.abs();
    String body;
    if (compact && a >= cur.factor * 1000) {
      final whole = a ~/ cur.factor;
      if (whole >= 1000000) {
        body = '${(whole / 1000000).toStringAsFixed(whole >= 10000000 ? 0 : 1)}M';
      } else {
        body = '${(whole / 1000).toStringAsFixed(whole >= 100000 ? 0 : 1)}k';
      }
    } else {
      final ip = a ~/ cur.factor;
      final fp = cur.exponent == 0 ? '' : (a % cur.factor).toString().padLeft(cur.exponent, '0');
      final grouped = NumberFormat('#,##0', 'en').format(ip);
      body = (fp.isEmpty || (trimZeroFraction && int.parse(fp) == 0)) ? grouped : '$grouped.$fp';
    }
    final sign = neg ? '-' : (signed && minor > 0 ? '+' : '');
    return digits('$sign$body');
  }

  String symbol(String currency) => arabic ? Currency.of(currency).symbolAr : Currency.of(currency).code;

  /// Full money string: "KWD 5.250" in English, "5.250 د.ك" in Arabic.
  String money(int minor, String currency, {bool compact = false, bool signed = false}) {
    final a = amount(minor, currency, compact: compact, signed: signed);
    return arabic ? '$a ${symbol(currency)}' : '${symbol(currency)} $a';
  }

  String m(Money v, {bool signed = false}) => money(v.minor, v.currency, signed: signed);

  String _loc() => arabic ? 'ar' : 'en';

  String dayMonth(DateTime wall) => digits(DateFormat('d MMM', _loc()).format(wall));
  String dayMonthYear(DateTime wall) => digits(DateFormat('d MMM yyyy', _loc()).format(wall));
  String monthYear(DateTime wall) => digits(DateFormat('MMMM yyyy', _loc()).format(wall));
  String time(DateTime wall) => digits(DateFormat('h:mm a', _loc()).format(wall));
  String weekdayShort(DateTime wall) => DateFormat('EEE', _loc()).format(wall);
  String percent(double v) => digits('${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)}%');
  String integer(int v) => digits(NumberFormat('#,##0', 'en').format(v));
}

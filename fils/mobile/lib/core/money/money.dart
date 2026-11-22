/// Exact money representation using integer minor units.
///
/// Never use `double` for stored money. KWD uses 3 decimal places (1 KWD = 1000 fils).
library;

import 'package:meta/meta.dart';

/// Currency metadata. Exponent = number of minor-unit digits.
class Currency {
  final String code;
  final int exponent;
  final String symbolEn;
  final String symbolAr;
  const Currency(this.code, this.exponent, this.symbolEn, this.symbolAr);

  static const Map<String, Currency> _known = {
    'KWD': Currency('KWD', 3, 'KWD', 'د.ك'),
    'BHD': Currency('BHD', 3, 'BHD', 'د.ب'),
    'OMR': Currency('OMR', 3, 'OMR', 'ر.ع'),
    'JOD': Currency('JOD', 3, 'JOD', 'د.أ'),
    'TND': Currency('TND', 3, 'TND', 'د.ت'),
    'IQD': Currency('IQD', 3, 'IQD', 'د.ع'),
    'LYD': Currency('LYD', 3, 'LYD', 'د.ل'),
    'SAR': Currency('SAR', 2, 'SAR', 'ر.س'),
    'AED': Currency('AED', 2, 'AED', 'د.إ'),
    'QAR': Currency('QAR', 2, 'QAR', 'ر.ق'),
    'EGP': Currency('EGP', 2, 'EGP', 'ج.م'),
    'USD': Currency('USD', 2, 'USD', 'دولار'),
    'EUR': Currency('EUR', 2, 'EUR', 'يورو'),
    'GBP': Currency('GBP', 2, 'GBP', 'جنيه إسترليني'),
    'INR': Currency('INR', 2, 'INR', 'روبية'),
    'PKR': Currency('PKR', 2, 'PKR', 'روبية باكستانية'),
    'PHP': Currency('PHP', 2, 'PHP', 'بيزو'),
    'TRY': Currency('TRY', 2, 'TRY', 'ليرة تركية'),
    'CHF': Currency('CHF', 2, 'CHF', 'فرنك'),
    'CAD': Currency('CAD', 2, 'CAD', 'دولار كندي'),
    'AUD': Currency('AUD', 2, 'AUD', 'دولار أسترالي'),
    'CNY': Currency('CNY', 2, 'CNY', 'يوان'),
    'THB': Currency('THB', 2, 'THB', 'بات'),
    'LKR': Currency('LKR', 2, 'LKR', 'روبية سريلانكية'),
    'JPY': Currency('JPY', 0, 'JPY', 'ين'),
    'KRW': Currency('KRW', 0, 'KRW', 'وون'),
  };

  static Currency of(String code) {
    final c = code.toUpperCase();
    return _known[c] ?? Currency(c, 2, c, c);
  }

  static bool isKnown(String code) => _known.containsKey(code.toUpperCase());
  static Iterable<Currency> get all => _known.values;

  int get factor {
    var f = 1;
    for (var i = 0; i < exponent; i++) {
      f *= 10;
    }
    return f;
  }
}

/// Thrown when combining amounts of different currencies.
class CurrencyMismatch implements Exception {
  final String a, b;
  CurrencyMismatch(this.a, this.b);
  @override
  String toString() => 'CurrencyMismatch($a vs $b)';
}

@immutable
class Money implements Comparable<Money> {
  final int minor;
  final String currency;
  const Money(this.minor, this.currency);
  const Money.zero(this.currency) : minor = 0;

  Currency get cur => Currency.of(currency);

  Money operator +(Money o) {
    _check(o);
    return Money(minor + o.minor, currency);
  }

  Money operator -(Money o) {
    _check(o);
    return Money(minor - o.minor, currency);
  }

  Money operator -() => Money(-minor, currency);
  Money abs() => Money(minor.abs(), currency);
  bool get isZero => minor == 0;
  bool get isNegative => minor < 0;

  void _check(Money o) {
    if (o.currency != currency) throw CurrencyMismatch(currency, o.currency);
  }

  /// Parse a decimal string like "5.250", "1,234.5", "٥٫٢٥٠" exactly (no floats).
  /// Returns null if the string is not a valid amount or has more fraction digits
  /// than the currency supports (unless [allowRounding] is true, which rounds half-up).
  static Money? parse(String raw, String currency, {bool allowRounding = false}) {
    final minor = parseMinor(raw, Currency.of(currency).exponent, allowRounding: allowRounding);
    return minor == null ? null : Money(minor, currency.toUpperCase());
  }

  static int? parseMinor(String raw, int exponent, {bool allowRounding = false}) {
    var s = normalizeDigits(raw).trim();
    if (s.isEmpty) return null;
    var negative = false;
    if (s.startsWith('-')) {
      negative = true;
      s = s.substring(1);
    }
    // Arabic decimal separator ٫ and thousands separator ٬ are normalized by normalizeDigits.
    s = s.replaceAll(',', '').replaceAll(' ', '');
    if (!RegExp(r'^\d+(\.\d+)?$|^\.\d+$').hasMatch(s)) return null;
    final parts = s.split('.');
    final intPart = parts[0].isEmpty ? '0' : parts[0];
    var frac = parts.length > 1 ? parts[1] : '';
    var roundUp = false;
    if (frac.length > exponent) {
      if (!allowRounding) {
        // Accept trailing zeros beyond precision (e.g. "5.2500" KWD).
        final extra = frac.substring(exponent);
        if (RegExp(r'^0+$').hasMatch(extra)) {
          frac = frac.substring(0, exponent);
        } else {
          return null;
        }
      } else {
        roundUp = int.parse(frac[exponent]) >= 5;
        frac = frac.substring(0, exponent);
      }
    }
    frac = frac.padRight(exponent, '0');
    if (intPart.length > 15) return null; // guard overflow
    var v = int.parse(intPart + frac);
    if (roundUp) v += 1;
    return negative ? -v : v;
  }

  /// Plain decimal string with full currency precision, e.g. "5.250".
  String toDecimalString() {
    final e = cur.exponent;
    final neg = minor < 0;
    final a = minor.abs();
    if (e == 0) return '${neg ? '-' : ''}$a';
    final f = cur.factor;
    final ip = a ~/ f;
    final fp = (a % f).toString().padLeft(e, '0');
    return '${neg ? '-' : ''}$ip.$fp';
  }

  @override
  int compareTo(Money other) {
    _check(other);
    return minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;
  @override
  int get hashCode => Object.hash(minor, currency);
  @override
  String toString() => '$currency ${toDecimalString()}';
}

/// Converts Arabic-Indic (٠-٩) and Extended Arabic-Indic / Persian (۰-۹) digits to ASCII,
/// and Arabic decimal/thousands separators to '.' and ','.
String normalizeDigits(String input) {
  final b = StringBuffer();
  for (final r in input.runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else if (r == 0x066B) {
      b.write('.');
    } else if (r == 0x066C) {
      b.write(',');
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// Sums a list of money values grouped by currency, never mixing currencies.
Map<String, int> sumByCurrency(Iterable<Money> items) {
  final out = <String, int>{};
  for (final m in items) {
    out[m.currency] = (out[m.currency] ?? 0) + m.minor;
  }
  return out;
}

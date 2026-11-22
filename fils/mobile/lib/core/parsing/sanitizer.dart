/// On-device sanitization. It runs before any text leaves the device (AI fallback or
/// opt-in sample submission) and before optional raw-text retention.
///
/// It removes OTP codes, full card and account numbers, IBANs, phone numbers, emails and
/// greeting names. It keeps amounts, currencies, merchant descriptors, last-4 digits and
/// sentence structure, so the parser can still be improved from the sample.
library;

import '../money/money.dart';

class SanitizeResult {
  final String text;
  final List<String> removed; // kinds of data removed, for the review screen
  const SanitizeResult(this.text, this.removed);
}

SanitizeResult sanitizeMessage(String input) {
  var s = normalizeDigits(input);
  final removed = <String>{};

  // IBAN (Kuwait: KW + 28 chars) and generic IBANs
  s = s.replaceAllMapped(RegExp(r'\b[A-Z]{2}\d{2}[A-Z0-9 ]{11,30}\b'), (m) {
    final compact = m[0]!.replaceAll(' ', '');
    if (compact.length < 15) return m[0]!;
    removed.add('iban');
    return '[IBAN]';
  });

  // OTP-like codes near OTP words
  final otpRe = RegExp(
      r'((?:otp|code|password|passcode|pin|رمز|كلمة المرور|الرمز)[^\d\n]{0,25})(\d{4,8})',
      caseSensitive: false);
  s = s.replaceAllMapped(otpRe, (m) {
    removed.add('otp');
    return '${m[1]}[CODE]';
  });

  // Emails
  s = s.replaceAllMapped(RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'), (m) {
    removed.add('email');
    return '[EMAIL]';
  });

  // Kuwaiti and international phone numbers (+965 / 00965 / 8-digit numbers starting 5, 6 or 9)
  s = s.replaceAllMapped(RegExp(r'(?:\+|00)\d{8,15}|(?<![\d.,])[569]\d{7}(?![\d.,])'), (m) {
    removed.add('phone');
    return '[PHONE]';
  });

  // Long digit runs (card or account numbers), possibly masked or space-separated:
  // keep the last 4.
  s = s.replaceAllMapped(RegExp(r'(?<![\d.,])(?:\d[ -]?){8,19}(?![\d.,])'), (m) {
    final digits = m[0]!.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length < 8) return m[0]!;
    removed.add('card_or_account_number');
    return 'XXXX${digits.substring(digits.length - 4)}';
  });

  // Greeting names: "Dear Ahmed," / "عزيزي أحمد،" (keep generic "Dear Customer")
  s = s.replaceAllMapped(
      RegExp(r'\b(Dear|Hi|Hello)\s+(?!customer|client|cardholder|member)([A-Za-z][A-Za-z.\- ]{1,40}?)(?=[,،:\n])', caseSensitive: false),
      (m) {
    removed.add('name');
    return '${m[1]} [NAME]';
  });
  s = s.replaceAllMapped(RegExp(r'(عزيزي|عزيزتي|السيد|السيدة)\s+(?!العميل|عميل|المتعامل)([؀-ۿ]{2,20}(?:\s[؀-ۿ]{2,20})?)(?=[,،:\n])'), (m) {
    removed.add('name');
    return '${m[1]} [NAME]';
  });

  return SanitizeResult(s, removed.toList()..sort());
}

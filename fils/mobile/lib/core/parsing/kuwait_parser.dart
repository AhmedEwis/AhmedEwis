/// Deterministic parser for Kuwaiti bank transaction messages (English and Arabic).
///
/// Design rules:
/// - Never invent values. Every extracted field must come from a substring of the input,
///   recorded in [ParsedEvent.evidence].
/// - OTPs, promotions and balance-only notices are classified and never become
///   transactions.
/// - Balance, available-credit and limit amounts are never mistaken for the transaction
///   amount.
/// - Message text is data only, never instructions.
library;

import '../money/money.dart';
import '../time/kuwait_time.dart';
import 'bank_registry.dart';
import 'merchant_directory.dart';
import 'models.dart';

const kParserId = 'kw-generic';
const kParserVersion = '1.0.0';

class _Amount {
  final int start, end;
  final String currency;
  final String numText;
  final String fullText;
  final int minor;
  String role = 'tx'; // tx | balance | available | fee | limit
  _Amount(this.start, this.end, this.currency, this.numText, this.fullText, this.minor);
}

/// Currency tokens mapped to ISO codes. Order matters: longer tokens first.
const _currencyTokens = <String, String>{
  'دينار كويتي': 'KWD',
  'دنانير': 'KWD',
  'دينار': 'KWD',
  'د.ك.': 'KWD',
  'د.ك': 'KWD',
  'د ك': 'KWD',
  'دك': 'KWD',
  'k.d.': 'KWD',
  'k.d': 'KWD',
  'kwd': 'KWD',
  'kd': 'KWD',
  'دولار': 'USD',
  'usd': 'USD',
  'us\$': 'USD',
  '\$': 'USD',
  'eur': 'EUR',
  '€': 'EUR',
  'يورو': 'EUR',
  'gbp': 'GBP',
  '£': 'GBP',
  'aed': 'AED',
  'درهم': 'AED',
  'sar': 'SAR',
  'ريال سعودي': 'SAR',
  'qar': 'QAR',
  'bhd': 'BHD',
  'omr': 'OMR',
  'egp': 'EGP',
  'جنيه': 'EGP',
  'inr': 'INR',
  'try': 'TRY',
  'jpy': 'JPY',
  'chf': 'CHF',
  'cad': 'CAD',
  'aud': 'AUD',
  'php': 'PHP',
  'pkr': 'PKR',
  'lkr': 'LKR',
  'thb': 'THB',
  'jod': 'JOD',
  'cny': 'CNY',
};

final _numRe = r'(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)';

String _escapeToken(String t) => RegExp.escape(t);

final RegExp _amountRe = () {
  final toks = _currencyTokens.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  final alt = toks.map(_escapeToken).join('|');
  // Currency before or after the number. Latin-letter currency tokens need boundaries.
  return RegExp(
    '(?<cur1>$alt)\\s?$_numRe|$_numRe\\s?(?<cur2>$alt)(?![a-z])',
    caseSensitive: false,
  );
}();

// Keyword groups, matched on normalized lowercase text.
const _otpWords = [
  'otp', 'one time password', 'one-time password', 'verification code', 'activation code',
  'passcode', 'security code', 'رمز التحقق', 'رمز التفعيل', 'كلمة المرور لمرة واحدة', 'كلمة السر المؤقتة',
  'الرمز السري', 'رمز المرور', 'do not share', 'لا تشارك', 'never share',
];
const _declinedWords = [
  'declined', 'rejected', 'unsuccessful', 'failed', 'insufficient', 'not approved', 'was denied',
  'مرفوضة', 'مرفوض', 'رفض', 'تم رفض', 'لم تتم', 'غير ناجحة', 'فشلت', 'الرصيد غير كاف',
];
const _reversalWords = ['reversal', 'reversed', 'عكس العملية', 'تم عكس', 'إلغاء العملية', 'الغاء العملية'];
const _refundWords = ['refund', 'refunded', 'credited back', 'returned', 'استرداد', 'استرجاع', 'مرتجع', 'ارجاع'];
const _cardPaymentWords = [
  'credit card payment', 'card payment received', 'payment received', 'payment of', 'thank you for your payment',
  'سداد بطاقة', 'سداد البطاقة', 'تم استلام دفعة', 'تم سداد',
];
const _atmWords = ['atm', 'cash withdrawal', 'withdrawn', 'سحب نقدي', 'صراف', 'سحب من'];
const _salaryWords = ['salary', 'payroll', 'راتب', 'الراتب', 'رواتب'];
const _installmentWords = ['installment', 'instalment', 'emi', 'قسط', 'أقساط', 'اقساط'];
const _feeWords = ['fee', 'fees', 'charge', 'charges', 'commission', 'رسوم', 'عمولة'];
const _transferWords = ['transfer', 'transferred', 'wamd', 'remittance', 'تحويل', 'حوالة', 'حواله', 'ومض'];
const _debitWords = [
  'purchase', 'pos', 'spent', 'debited', 'paid', 'payment at', 'payment of', 'knet', 'approved', 'transaction at', 'used at', 'apple pay',
  'online payment', 'e-commerce', 'شراء', 'عملية شراء', 'خصم', 'مدين', 'دفع', 'سحب', 'مشتريات', 'استخدام بطاقة',
];
const _creditWords = [
  'credited', 'deposit', 'deposited', 'received', 'incoming', 'added to', 'إيداع', 'ايداع', 'اضافة', 'إضافة',
  'دائن', 'وارد', 'واردة', 'استلام',
];
const _pendingWords = ['authorization', 'authorisation', 'pending', 'on hold', 'hold', 'pre-auth', 'معلقة', 'حجز', 'قيد المعالجة'];
const _promoWords = ['offer', 'discount', 'win', 'promo', 'cashback offer', 'عرض', 'خصم خاص', 'اربح', 'فرصة'];
const _balanceWords = ['balance', 'bal', 'bal.', 'avl', 'الرصيد', 'رصيد', 'remaining', 'المتبقي'];
const _availableWords = ['available', 'avail', 'avl', 'المتاح', 'متاح'];
const _limitWords = ['limit', 'credit limit', 'الحد', 'حد الائتمان'];

bool _hasAny(String t, List<String> words) {
  for (final w in words) {
    if (_wordHit(t, w)) return true;
  }
  return false;
}

/// Latin words match on boundaries; Arabic phrases match as substrings.
bool _wordHit(String t, String w) {
  if (RegExp(r'^[a-z .\-]+$').hasMatch(w)) {
    return RegExp('(^|[^a-z])${RegExp.escape(w)}([^a-z]|\$)').hasMatch(t);
  }
  return t.contains(w);
}

int _lastHitBefore(String t, int pos, List<String> words) {
  var best = -1;
  final window = t.substring(0, pos);
  for (final w in words) {
    final latin = RegExp(r'^[a-z .\-]+$').hasMatch(w);
    final re = latin ? RegExp('(^|[^a-z])(${RegExp.escape(w)})([^a-z]|\$)') : RegExp(RegExp.escape(w));
    for (final m in re.allMatches(window)) {
      final s = latin ? m.start + (m.group(1)?.length ?? 0) : m.start;
      if (s > best) best = s;
    }
  }
  return best;
}

/// Normalize text for matching: ASCII digits, unified Arabic letter forms, lowercase,
/// collapsed spaces. Character positions stay aligned with the digit-normalized
/// original, so evidence can be cut from it.
String normalizeForMatch(String s) {
  final d = normalizeDigits(s);
  final b = StringBuffer();
  for (final r in d.runes) {
    switch (r) {
      case 0x0623: // أ
      case 0x0625: // إ
      case 0x0622: // آ
        b.writeCharCode(0x0627); // ا
      case 0x0640: // tatweel
        b.write(' ');
      case 0x00A0:
      case 0x200F:
      case 0x200E:
      case 0x202A:
      case 0x202B:
      case 0x202C:
        b.write(' ');
      default:
        b.writeCharCode(r);
    }
  }
  return b.toString().toLowerCase();
}

class KuwaitParser {
  /// Default account currency used to pick the billed amount for foreign transactions.
  final String homeCurrency;
  final ReportingZone zone;
  final Map<String, (String, String?)> userAliases;
  const KuwaitParser({this.homeCurrency = 'KWD', this.zone = ReportingZone.kuwait, this.userAliases = const {}});

  ParsedEvent parse(RawEvent e) {
    if (e.source == SourceKind.wallet && e.fields != null) return _parseWallet(e);
    final t = normalizeForMatch(e.text);
    var original = normalizeDigits(e.text);
    // Evidence is cut from [original] by positions found in [t]; fall back to [t] if
    // lowercasing changed the length (rare Unicode cases).
    if (original.length != t.length) original = t;
    final notes = <String>[];
    final evidence = <String, String>{};
    final bankId = detectBank(sender: e.sender, text: e.text);

    ParsedEvent mk(TxKind k, double conf, {List<String>? n}) => ParsedEvent(
          kind: k,
          confidence: conf,
          parserId: kParserId,
          parserVersion: kParserVersion,
          bankId: bankId,
          notes: n ?? notes,
        );

    // 1. One-time passwords are rejected first, even when they mention an amount.
    if (_hasAny(t, _otpWords) || RegExp(r'(code|رمز)[^\d]{0,20}\d{4,8}').hasMatch(t) && !_hasAny(t, _debitWords)) {
      return mk(TxKind.otp, 0.95, n: ['OTP or verification message: ignored and never stored as a transaction.']);
    }

    final amounts = _findAmounts(original, t);
    _labelAmounts(amounts, t);
    final txAmounts = amounts.where((a) => a.role == 'tx').toList();
    final balanceAmt = amounts.where((a) => a.role == 'balance').firstOrNull;
    final availAmt = amounts.where((a) => a.role == 'available').firstOrNull;
    final feeAmt = amounts.where((a) => a.role == 'fee').firstOrNull;

    final hasTxVerb = _hasAny(t, _debitWords) ||
        _hasAny(t, _creditWords) ||
        _hasAny(t, _transferWords) ||
        _hasAny(t, _atmWords) ||
        _hasAny(t, _refundWords) ||
        _hasAny(t, _declinedWords);

    if (txAmounts.isEmpty) {
      if (balanceAmt != null || availAmt != null) {
        return ParsedEvent(
          kind: TxKind.balanceOnly,
          balance: balanceAmt == null ? null : Money(balanceAmt.minor, balanceAmt.currency),
          available: availAmt == null ? null : Money(availAmt.minor, availAmt.currency),
          bankId: bankId,
          confidence: 0.7,
          parserId: kParserId,
          parserVersion: kParserVersion,
          notes: ['Balance-only message: updates the bank-reported balance only.'],
        );
      }
      if (_hasAny(t, _promoWords) && !hasTxVerb) return mk(TxKind.promo, 0.8);
      if (hasTxVerb) {
        return mk(TxKind.unknown, 0.3, n: ['Looks financial but no amount with a currency was found. Sent to review.']);
      }
      return mk(TxKind.unknown, 0.1, n: ['Not recognized as a transaction message.']);
    }
    if (_hasAny(t, _promoWords) && !hasTxVerb) return mk(TxKind.promo, 0.7);

    // 2. Pick the transaction amount, preferring the billed home-currency amount when a
    //    foreign amount is also present.
    _Amount primary = txAmounts.first;
    _Amount? foreign;
    final distinctCur = txAmounts.map((a) => a.currency).toSet();
    if (distinctCur.length > 1) {
      final home = txAmounts.where((a) => a.currency == homeCurrency).firstOrNull;
      final other = txAmounts.where((a) => a.currency != homeCurrency).firstOrNull;
      if (home != null && other != null) {
        primary = home;
        foreign = other;
        notes.add('Foreign-currency transaction: billed ${home.currency} amount kept; original amount preserved.');
      }
    } else if (primary.currency != homeCurrency) {
      notes.add('Amount is in ${primary.currency}; the billed $homeCurrency amount is not in the message.');
    }
    if (txAmounts.length > (foreign == null ? 1 : 2)) {
      notes.add('Multiple amounts found; the first transaction amount was used.');
    }
    evidence['amount'] = primary.fullText;

    // 3. Classify.
    var kind = TxKind.unknown;
    var status = TxStatus.posted;
    var kindConf = 0.2;
    if (_hasAny(t, _declinedWords)) {
      kind = TxKind.declined;
      status = TxStatus.declined;
      kindConf = 0.3;
    } else if (_hasAny(t, _reversalWords)) {
      kind = TxKind.reversal;
      kindConf = 0.3;
    } else if (_hasAny(t, _refundWords)) {
      kind = TxKind.refund;
      kindConf = 0.3;
    } else if (_hasAny(t, _cardPaymentWords) &&
        (t.contains('credit card') || t.contains('بطاقة الائتمان') || t.contains('البطاقة الائتمانية') ||
            RegExp(r'(for|to) your (credit )?card').hasMatch(t) || t.contains('سداد')) &&
        !_hasAny(t, ['purchase', 'شراء', 'at', 'لدى'])) {
      kind = TxKind.cardPayment;
      kindConf = 0.25;
    } else if (_hasAny(t, _atmWords)) {
      kind = TxKind.atmWithdrawal;
      kindConf = 0.3;
    } else if (_hasAny(t, _salaryWords) && _hasAny(t, _creditWords)) {
      kind = TxKind.salary;
      kindConf = 0.3;
    } else if (_hasAny(t, _installmentWords)) {
      kind = TxKind.installment;
      kindConf = 0.25;
    } else if (_hasAny(t, _transferWords)) {
      final inbound = _hasAny(t, ['received', 'credited', 'incoming', 'وارد', 'واردة', 'ايداع', 'استلام', 'to your account', 'الى حسابك']);
      final outbound = _hasAny(t, ['sent', 'debited', 'outgoing', 'صادرة', 'صادر', 'خصم', 'مدين', 'from your account', 'من حسابك']);
      kind = inbound && !outbound ? TxKind.transferIn : TxKind.transferOut;
      kindConf = inbound == outbound ? 0.15 : 0.3;
      if (inbound == outbound) notes.add('Transfer direction unclear; assumed outgoing.');
    } else if (_hasAny(t, _debitWords)) {
      kind = TxKind.purchase;
      kindConf = 0.3;
    } else if (_hasAny(t, _creditWords)) {
      kind = TxKind.income;
      kindConf = 0.3;
    } else if (_hasAny(t, _feeWords)) {
      kind = TxKind.fee;
      kindConf = 0.25;
    }
    if (kind != TxKind.declined && _hasAny(t, _pendingWords)) {
      status = TxStatus.pending;
      // A card authorization with no other verb is a pending purchase.
      if (kind == TxKind.unknown) {
        kind = TxKind.purchase;
        kindConf = 0.2;
      }
    }

    // 4. Merchant
    String? merchantRaw;
    if (const {TxKind.purchase, TxKind.refund, TxKind.reversal, TxKind.declined, TxKind.installment, TxKind.fee}
        .contains(kind)) {
      merchantRaw = _extractMerchant(original, t, kind);
    }
    MerchantMatch? mm;
    if (merchantRaw != null) {
      evidence['merchant'] = merchantRaw;
      mm = matchMerchant(merchantRaw, userAliases: userAliases);
    } else {
      // A known merchant anywhere in the text (e.g. "طلبات") still helps categorization.
      for (final r in merchantRules) {
        for (final p in r.patterns) {
          if (p.length >= 4 && t.contains(p) && !_isBankWord(p)) {
            mm = MerchantMatch(r.name, r.category, null, p);
            break;
          }
        }
        if (mm != null) break;
      }
    }

    // 5. Card / account
    final ids = _extractIdentifiers(t);
    if (ids.$1 != null) evidence['card_last4'] = ids.$1!;
    if (ids.$2 != null) evidence['account_last4'] = ids.$2!;

    // 6. Date
    final occurred = _extractDate(t, e.receivedAt, notes);

    var conf = 0.3 + 0.3 + kindConf;
    if (mm != null || kind == TxKind.salary || kind == TxKind.transferIn || kind == TxKind.transferOut || kind == TxKind.atmWithdrawal || kind == TxKind.cardPayment) {
      conf += 0.1;
    }
    if (bankId != null || ids.$1 != null || ids.$2 != null) conf += 0.05;
    if (kind == TxKind.unknown) conf = 0.35;
    if (txAmounts.length > (foreign == null ? 1 : 2)) conf -= 0.15;
    if (conf > 0.98) conf = 0.98;

    return ParsedEvent(
      kind: kind,
      status: status,
      amount: Money(primary.minor, primary.currency),
      originalAmount: foreign == null ? null : Money(foreign.minor, foreign.currency),
      fee: feeAmt == null ? null : Money(feeAmt.minor, feeAmt.currency),
      balance: balanceAmt == null ? null : Money(balanceAmt.minor, balanceAmt.currency),
      available: availAmt == null ? null : Money(availAmt.minor, availAmt.currency),
      merchant: mm?.name,
      merchantRaw: merchantRaw,
      processor: mm?.processor,
      cardLast4: ids.$1,
      accountLast4: ids.$2,
      bankId: bankId,
      occurredAt: occurred,
      confidence: conf,
      parserId: kParserId,
      parserVersion: kParserVersion,
      notes: notes,
      evidence: evidence,
    );
  }

  bool _isBankWord(String p) => const ['الوطني', 'بيتك', 'وربة', 'بوبيان'].contains(p);

  /// Wallet automations give structured fields: merchant, amount, card/pass name.
  ParsedEvent _parseWallet(RawEvent e) {
    final f = e.fields!;
    final notes = <String>['Captured from an Apple Wallet transaction automation.'];
    final rawAmount = f['amount'] ?? '';
    final amounts = _findAmounts(normalizeDigits(rawAmount), normalizeForMatch(rawAmount));
    Money? amount;
    if (amounts.isNotEmpty && amounts.first.minor > 0) {
      amount = Money(amounts.first.minor, amounts.first.currency);
    } else if (amounts.isNotEmpty) {
      notes.add('Wallet reported a zero amount (a known intermittent Shortcuts issue); sent to review.');
    } else {
      // The amount might come as a bare number; the currency then comes from a separate
      // field or is left unknown.
      final cur = (f['currency'] ?? '').toUpperCase();
      if (cur.length == 3) {
        final m = Money.parse(rawAmount.replaceAll(RegExp(r'[^\d.,٠-٩٫]'), ''), cur);
        if (m != null && m.minor > 0) amount = m;
      }
      if (amount == null) notes.add('Wallet amount "$rawAmount" had no recognizable currency; sent to review.');
    }
    final merchantText = (f['merchant'] ?? '').trim().isEmpty ? f['name'] : f['merchant'];
    final mm = matchMerchant(merchantText, userAliases: userAliases);
    final card = RegExp(r'(\d{4})\s*$').firstMatch(f['card'] ?? '')?.group(1);
    return ParsedEvent(
      kind: TxKind.purchase,
      amount: amount,
      merchant: mm?.name,
      merchantRaw: f['merchant'],
      processor: 'Apple Pay',
      cardLast4: card,
      occurredAt: null,
      confidence: amount == null ? 0.4 : 0.85,
      parserId: 'ios-wallet',
      parserVersion: kParserVersion,
      notes: notes,
      evidence: {if (amount != null) 'amount': rawAmount, if (f['merchant'] != null) 'merchant': f['merchant']!},
    );
  }

  List<_Amount> _findAmounts(String original, String t) {
    final out = <_Amount>[];
    for (final m in _amountRe.allMatches(t)) {
      final curTok = (m.namedGroup('cur1') ?? m.namedGroup('cur2'))!;
      final num = m.group(2) ?? m.group(3)!;
      // Latin currency tokens must not be glued to letters before them (e.g. "backd 5").
      if (m.start > 0 && RegExp(r'[a-z]').hasMatch(t[m.start - 1]) && RegExp(r'^[a-z]').hasMatch(curTok)) continue;
      final code = _currencyTokens[curTok.toLowerCase()] ?? curTok.toUpperCase();
      final minor = Money.parseMinor(num, Currency.of(code).exponent, allowRounding: false);
      if (minor == null) continue;
      out.add(_Amount(m.start, m.end, code, num, original.substring(m.start, m.end), minor));
    }
    return out;
  }

  void _labelAmounts(List<_Amount> amounts, String t) {
    for (final a in amounts) {
      final windowStart = a.start - 60 < 0 ? 0 : a.start - 60;
      final local = t.substring(windowStart, a.start);
      final bal = _lastHitBefore(local, local.length, _balanceWords);
      final avl = _lastHitBefore(local, local.length, _availableWords);
      final lim = _lastHitBefore(local, local.length, _limitWords);
      final fee = _lastHitBefore(local, local.length, _feeWords);
      // Nearest transaction verb in the same window: a closer verb wins over a farther
      // balance word ("Balance: KD 10. Purchase of KD 5").
      final tx = _lastHitBefore(local, local.length, [..._debitWords, ..._creditWords, ..._transferWords, ..._atmWords, ..._refundWords, 'amount', 'مبلغ', 'بمبلغ', 'of']);
      final sentenceBreak = local.lastIndexOf(RegExp(r'[.;\n،]\s'));
      int eff(int p) => p > sentenceBreak ? p : -1;
      final cands = <String, int>{
        'balance': eff(bal),
        'available': eff(avl),
        'limit': eff(lim),
        'fee': eff(fee),
        'tx': eff(tx),
      };
      var role = 'tx';
      var best = -1;
      cands.forEach((k, v) {
        if (v > best) {
          best = v;
          role = k;
        }
      });
      // "available balance" means available.
      if (role == 'balance' && cands['available']! >= 0 && (cands['balance']! - cands['available']!).abs() < 12) role = 'available';
      if (role == 'limit') role = 'available';
      a.role = role;
    }
  }

  String? _extractMerchant(String original, String t, TxKind kind) {
    final patterns = <RegExp>[
      RegExp(r'(?:merchant|التاجر)\s*[:\-]\s*(.+?)(?=\s*(?:\n|[,;،]|\.\s|$))', caseSensitive: false),
      RegExp(
          r'(?:\bat\b|@)\s+(.+?)(?=\s+(?:on|using|with|via|by|dated|date|ref|has|was|is|from|for|card|txn|trx)\b|\s*[,;،\n]|\.\s|\.$|\s+\d{1,2}[/\-.]\d{1,2}|\s+\d{1,2}:\d{2}|$)',
          caseSensitive: false),
      RegExp(r'(?:لدى|لدي|عند)\s+(.+?)(?=\s+(?:بتاريخ|بطاقة|بطاقتك|باستخدام|رقم|في تاريخ|الساعة|من بطاقة|في\s+\d)|\s*[,;،\n]|\.\s|\.$|\s+\d{1,2}[/\-.]\d{1,2}|$)'),
      if (kind == TxKind.refund || kind == TxKind.reversal)
        RegExp(r'\bfrom\s+(?!your|card|a/c|account)(.+?)(?=\s+(?:on|to|has|was|is|credited)\b|\s*[,;،\n]|\.\s|\.$|$)', caseSensitive: false),
      if (kind == TxKind.refund || kind == TxKind.reversal)
        RegExp(r'من\s+(?!بطاق|حساب|رصيد)(.+?)(?=\s+(?:الى|إلى|بتاريخ|في)|\s*[,;،\n]|\.\s|\.$|$)'),
      RegExp(r'\bfor\s+(?!your|card|a/c|account|kwd|kd|usd)([a-z][^\n,;]{2,40}?)(?=\s+(?:on|using|with|has|was|is)\b|\s*[,;\n]|\.\s|\.$|$)', caseSensitive: false),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(t);
      if (m == null) continue;
      // Group 1 always ends the match (lookaheads are not consumed).
      final g = m.group(1)!;
      var s = original.substring(m.end - g.length, m.end).trim();
      s = s.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'[.\-:*]+$'), '').trim();
      // Reject captures that are amounts, card references or dates.
      final ls = normalizeForMatch(s);
      if (s.length < 2 || s.length > 60) continue;
      if (RegExp(r'^(kwd|kd|usd|\d|x{2,}|\*)').hasMatch(ls)) continue;
      if (RegExp(r'^(your|card|account|a/c|بطاق|حساب|رصيد)').hasMatch(ls)) continue;
      return s;
    }
    return null;
  }

  (String?, String?) _extractIdentifiers(String t) {
    String? card, acct;
    final re = RegExp(
        r'(card|بطاقة|بطاقتك|بطاقه|a/c|acct|account|حساب|حسابك|حسابكم)[^\d\n]{0,40}?(?:[x*•#.]{2,}\s?|ending(?: with| in)?\s*|ends with\s*|no\.?\s*|number\s*|رقم\s*|المنتهية\s*ب\s*(?:ـ|رقم)?\s*|تنتهي\s*ب\s*)?(\d{4})(?!\d)');
    for (final m in re.allMatches(t)) {
      final w = m.group(1)!;
      final d = m.group(2)!;
      // Skip years that belong to a date ("card on 22/11/2026").
      final ds = m.end - 4; // group 2 is the final 4 digits of the match
      final before = ds - 1 < 0 ? '' : t.substring(ds - 1, ds);
      if (before == '/' || before == '-') continue;
      if (w.startsWith('card') || w.startsWith('بطاق')) {
        card ??= d;
      } else {
        acct ??= d;
      }
    }
    // A bare masked sequence such as "XXXX1234" with no label is assumed to be a card.
    if (card == null && acct == null) {
      final m = RegExp(r'[x*•#]{3,}\s?(\d{4})(?!\d)').firstMatch(t);
      if (m != null) card = m.group(1);
    }
    return (card, acct);
  }

  DateTime? _extractDate(String t, DateTime receivedAt, List<String> notes) {
    int? y, mo, d, hh, mi, ss;
    final dm = RegExp(r'(?<!\d)(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})(?!\d)').firstMatch(t);
    final iso = RegExp(r'(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)').firstMatch(t);
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final named = RegExp(r'(?<!\d)(\d{1,2})[\s\-]?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[\s\-,]*(\d{2,4})').firstMatch(t);
    if (iso != null) {
      y = int.parse(iso.group(1)!);
      mo = int.parse(iso.group(2)!);
      d = int.parse(iso.group(3)!);
    } else if (dm != null) {
      d = int.parse(dm.group(1)!);
      mo = int.parse(dm.group(2)!);
      y = int.parse(dm.group(3)!);
      if (y < 100) y += 2000;
      if (mo > 12 && d <= 12) {
        // Unambiguously month-first (mm/dd); Kuwaiti banks normally use dd/mm.
        final tmp = d;
        d = mo;
        mo = tmp;
        notes.add('Date looked month-first; swapped.');
      }
    } else if (named != null) {
      d = int.parse(named.group(1)!);
      mo = months[named.group(2)!];
      y = int.parse(named.group(3)!);
      if (y < 100) y += 2000;
    }
    final tm = RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm|ص|م)?(?![\d])').firstMatch(t);
    if (tm != null) {
      hh = int.parse(tm.group(1)!);
      mi = int.parse(tm.group(2)!);
      ss = tm.group(3) == null ? 0 : int.parse(tm.group(3)!);
      final ap = tm.group(4);
      if ((ap == 'pm' || ap == 'م') && hh < 12) hh += 12;
      if ((ap == 'am' || ap == 'ص') && hh == 12) hh = 0;
      if (hh > 23 || mi > 59) hh = mi = null;
    }
    if (y == null || mo == null || d == null) {
      if (hh != null) {
        // Only a time: assume the received day in the reporting zone.
        final w = zone.toWall(receivedAt);
        final c = zone.fromWall(w.year, w.month, w.day, hh, mi!, ss!);
        return c.isAfter(receivedAt.add(const Duration(minutes: 5))) ? c.subtract(const Duration(days: 1)) : c;
      }
      return null;
    }
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final c = zone.fromWall(y, mo, d, hh ?? 12, mi ?? 0, ss ?? 0);
    final diff = c.difference(receivedAt);
    if (diff.inDays > 2 || diff.inDays < -400) {
      notes.add('Message date is implausible relative to the received time; the received time is used.');
      return null;
    }
    return c;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

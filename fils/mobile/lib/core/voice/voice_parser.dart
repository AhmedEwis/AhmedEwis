/// Turns a spoken expense phrase (Arabic: Gulf, Egyptian or MSA; English; or mixed) into
/// a draft. Amounts use exact integer minor units. Dinar/fils phrasing, quarters, halves
/// and "إلا ربع" are supported. Nothing is guessed: if no amount is found, the draft has
/// none and the UI asks for it.
library;

import '../domain/categories.dart';
import '../money/money.dart';
import '../parsing/merchant_directory.dart';

class VoiceDraft {
  final int? amountMinor;
  final String currency;
  final String? merchant;
  final String? categoryId;
  final bool income;
  final List<String> notes;
  final String transcript;
  const VoiceDraft({this.amountMinor, required this.currency, this.merchant, this.categoryId, this.income = false, this.notes = const [], required this.transcript});
  bool get complete => amountMinor != null && amountMinor! > 0;
  @override
  String toString() => 'VoiceDraft(${amountMinor == null ? '-' : Money(amountMinor!, currency)} merchant=$merchant cat=$categoryId income=$income)';
}

String _normAr(String s) {
  var t = normalizeDigits(s).toLowerCase();
  t = t
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll(RegExp('[ً-ْـ]'), '') // diacritics + tatweel
      .replaceAll(RegExp(r'[،,؟?!.]+(?!\d)'), ' ');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

const Map<String, int> _arNums = {
  'صفر': 0,
  'واحد': 1, 'واحده': 1, 'وحده': 1,
  'اثنين': 2, 'اثنان': 2, 'ثنين': 2, 'اتنين': 2, 'اثنتين': 2,
  'ثلاث': 3, 'ثلاثه': 3, 'تلات': 3, 'تلاته': 3, 'ثلاثة': 3,
  'اربع': 4, 'اربعه': 4,
  'خمس': 5, 'خمسه': 5,
  'ست': 6, 'سته': 6, 'سِت': 6,
  'سبع': 7, 'سبعه': 7,
  'ثمان': 8, 'ثماني': 8, 'ثمانيه': 8, 'تمنيه': 8, 'تمانيه': 8, // not 'ثمن'/'تمن' (= "price")
  'تسع': 9, 'تسعه': 9,
  'عشر': 10, 'عشره': 10,
  'احدعش': 11, 'حدعش': 11, 'حداشر': 11, 'احداشر': 11,
  'اثنعش': 12, 'ثنعش': 12, 'اطناشر': 12, 'اتناشر': 12,
  'ثلطعش': 13, 'تلتاشر': 13, 'ثلاثطعش': 13,
  'اربعطعش': 14, 'اربعتاشر': 14, 'اربعتعش': 14,
  'خمسطعش': 15, 'خمستاشر': 15, 'خمستعش': 15,
  'ستعش': 16, 'سطاشر': 16, 'سطعش': 16, 'ستاشر': 16,
  'سبعطعش': 17, 'سبعتاشر': 17, 'سبعتعش': 17,
  'ثمنطعش': 18, 'تمنتاشر': 18, 'ثمانتعش': 18,
  'تسعطعش': 19, 'تسعتاشر': 19, 'تسعتعش': 19,
  'عشرين': 20, 'ثلاثين': 30, 'تلاتين': 30, 'اربعين': 40, 'خمسين': 50, 'ستين': 60, 'سبعين': 70,
  'ثمانين': 80, 'تمانين': 80, 'تسعين': 90,
  'ميتين': 200, 'مئتين': 200, 'مائتين': 200, 'ميتان': 200,
  'ثلاثميه': 300, 'تلتميه': 300, 'ثلثميه': 300,
  'اربعميه': 400, 'ربعميه': 400,
  'خمسميه': 500, 'خمسمائه': 500, 'خمسمية': 500,
  'ستميه': 600, 'سبعميه': 700, 'ثمانميه': 800, 'تمنميه': 800, 'تسعميه': 900,
  'الفين': 2000,
};
const _arHundred = {'ميه', 'مائه', 'مئه', 'مية', 'ميت'};
const _arThousand = {'الف', 'الاف', 'آلاف'};
const _arDinar = {'دينار', 'دنانير', 'دينار كويتي', 'kd', 'kwd', 'د.ك', 'دك'};
const _arDinarDual = {'دينارين'};
const _arFils = {'فلس', 'فلسات'};
const _arQuarter = {'ربع'};
const _arHalf = {'نص', 'نصف'};
const _arThird = {'ثلث', 'تلت'};
const _arExcept = {'الا', 'غير'};

const Map<String, int> _enNums = {
  'zero': 0, 'one': 1, 'a': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9,
  'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15, 'sixteen': 16,
  'seventeen': 17, 'eighteen': 18, 'nineteen': 19, 'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50,
  'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90,
};
const _enDinar = {'dinar', 'dinars', 'kd', 'kwd', 'kuwaiti'};
const _enFils = {'fils', 'fil'};

const Map<String, String> _categoryWords = {
  'بنزين': Cat.fuel, 'وقود': Cat.fuel, 'petrol': Cat.fuel, 'fuel': Cat.fuel, 'gas': Cat.fuel,
  'غدا': Cat.food, 'غداء': Cat.food, 'عشا': Cat.food, 'عشاء': Cat.food, 'فطور': Cat.food, 'مطعم': Cat.food, 'قهوه': Cat.food,
  'كوفي': Cat.food, 'اكل': Cat.food, 'lunch': Cat.food, 'dinner': Cat.food, 'breakfast': Cat.food, 'coffee': Cat.food, 'food': Cat.food, 'restaurant': Cat.food,
  'جمعيه': Cat.groceries, 'بقاله': Cat.groceries, 'خضار': Cat.groceries, 'groceries': Cat.groceries, 'grocery': Cat.groceries, 'supermarket': Cat.groceries,
  'تاكسي': Cat.transport, 'مواصلات': Cat.transport, 'taxi': Cat.transport, 'uber': Cat.transport, 'careem': Cat.transport,
  'صيدليه': Cat.health, 'دكتور': Cat.health, 'دوا': Cat.health, 'دواء': Cat.health, 'pharmacy': Cat.health, 'doctor': Cat.health, 'medicine': Cat.health,
  'ايجار': Cat.housing, 'rent': Cat.housing,
  'صدقه': Cat.charity, 'زكاه': Cat.charity, 'charity': Cat.charity,
  'ملابس': Cat.shopping, 'هدوم': Cat.shopping, 'clothes': Cat.shopping, 'shopping': Cat.shopping,
  'رصيد': Cat.telecom, 'شحن': Cat.telecom, 'انترنت': Cat.telecom, 'internet': Cat.telecom,
  'كهربا': Cat.bills, 'كهرباء': Cat.bills, 'فاتوره': Cat.bills, 'bill': Cat.bills,
  'سينما': Cat.entertainment, 'cinema': Cat.entertainment, 'movie': Cat.entertainment,
  'حلاق': Cat.personalCare, 'صالون': Cat.personalCare, 'barber': Cat.personalCare,
  'مدرسه': Cat.education, 'school': Cat.education, 'course': Cat.education,
};

const _incomeWords = ['استلمت', 'قبضت', 'نزل الراتب', 'نزل راتبي', 'جاني', 'وصلني', 'حولولي', 'received', 'got paid', 'salary', 'income', 'earned'];
const _merchantPreps = ['على', 'علي', 'عند', 'في', 'من', 'ل', 'at', 'on', 'for', 'from', 'in'];

class _NumResult {
  final int? minor;
  final bool sawCurrency;
  final Set<int> consumed; // token indexes used by the amount
  _NumResult(this.minor, this.sawCurrency, this.consumed);
}

class VoiceParser {
  final String currency;
  const VoiceParser({this.currency = 'KWD'});

  VoiceDraft parse(String transcript) {
    final t = _normAr(transcript);
    final notes = <String>[];
    final income = _incomeWords.any((w) => t.contains(w));
    final num = _amount(t);
    final tokens = t.split(' ');

    // Merchant: the longest known merchant name in the text, else the words after a
    // preposition that aren't part of the amount.
    String? merchant;
    String? category;
    final m = _knownMerchant(t);
    if (m != null) {
      merchant = m.name;
      category = m.category;
    } else {
      for (var i = 0; i < tokens.length; i++) {
        var tok = tokens[i];
        var prep = _merchantPreps.contains(tok);
        // Arabic prefixed preposition: "لطلبات" / "عالجمعيه"
        if (!prep && (tok.startsWith('عال') || tok.startsWith('ع ال'))) {
          prep = true;
        }
        if (prep && !num.consumed.contains(i)) {
          final rest = <String>[];
          for (var j = i + 1; j < tokens.length && rest.length < 4; j++) {
            if (num.consumed.contains(j) || _merchantPreps.contains(tokens[j])) break;
            rest.add(tokens[j]);
          }
          if (rest.isNotEmpty) {
            final cand = rest.join(' ');
            final catHit = _categoryWords[rest.first] ?? _categoryWords[cand];
            if (catHit != null) {
              category ??= catHit;
            } else {
              merchant = transcript.contains(cand) ? cand : _restoreOriginal(transcript, cand) ?? cand;
            }
            break;
          }
        }
      }
    }
    if (category == null) {
      for (final tok in tokens) {
        final c = _categoryWords[tok] ?? _categoryWords[tok.startsWith('ال') ? tok.substring(2) : tok];
        if (c != null) {
          category = c;
          break;
        }
      }
    }
    if (merchant != null && category == null) {
      final mm = matchMerchant(merchant);
      if (mm != null && mm.category != Cat.other) category = mm.category;
    }
    if (num.minor == null) notes.add('no_amount');
    return VoiceDraft(
      amountMinor: num.minor,
      currency: currency,
      merchant: merchant,
      categoryId: income ? (t.contains('راتب') || t.contains('salary') ? Cat.salary : Cat.otherIncome) : category,
      income: income,
      notes: notes,
      transcript: transcript,
    );
  }

  String? _restoreOriginal(String original, String normalized) => null;

  MerchantRule? _knownMerchant(String t) {
    MerchantRule? best;
    var bestLen = 0;
    for (final r in merchantRules) {
      for (final p in [...r.patterns, r.name.toLowerCase(), if (r.nameAr != null) _normAr(r.nameAr!)]) {
        final pn = _normAr(p).trim();
        if (pn.length < 3) continue;
        if (RegExp('(^|\\s|ل|ب|عال)${RegExp.escape(pn)}(\\s|\$)').hasMatch(t) && pn.length > bestLen) {
          best = r;
          bestLen = pn.length;
        }
      }
    }
    return best;
  }

  _NumResult _amount(String t) {
    final exp = Currency.of(currency).exponent;
    final factor = Currency.of(currency).factor;
    final tokens = t.split(' ');

    // 1. Explicit digits, e.g. "5.250", "5 دينار و 250 فلس" or "250 فلس".
    final digitRe = RegExp(r'(\d+(?:[.,]\d+)?)');
    final digitMatches = digitRe.allMatches(t).toList();
    if (digitMatches.isNotEmpty) {
      final consumed = <int>{};
      for (var i = 0; i < tokens.length; i++) {
        if (digitRe.hasMatch(tokens[i])) consumed.add(i);
      }
      final first = digitMatches.first.group(1)!.replaceAll(',', '.');
      final after = t.substring(digitMatches.first.end).trimLeft();
      final isFils = _arFils.any(after.startsWith) || _enFils.any(after.startsWith);
      var minor = isFils ? int.tryParse(first.split('.').first) : Money.parseMinor(first, exp, allowRounding: true);
      if (minor != null && !isFils && digitMatches.length > 1) {
        // "5 دينار و 250 فلس"
        final second = digitMatches[1];
        final after2 = t.substring(second.end).trimLeft();
        if (_arFils.any(after2.startsWith) || _enFils.any(after2.startsWith)) {
          minor += int.tryParse(second.group(1)!) ?? 0;
        }
      }
      if (minor != null) {
        // "5 ونص" (five and a half)
        if (RegExp(r'\d\s*(دينار|دنانير)?\s*و\s*نص').hasMatch(t)) minor += factor ~/ 2;
        if (RegExp(r'\d\s*(دينار|دنانير)?\s*و\s*ربع').hasMatch(t)) minor += factor ~/ 4;
        final sawCur = _arDinar.any(t.contains) || _enDinar.any((w) => RegExp('\\b$w\\b').hasMatch(t));
        return _NumResult(minor, sawCur, consumed);
      }
    }

    // 2. Number words
    var dinars = 0;
    var fils = 0;
    var total = 0;
    var current = 0;
    var frac = 0; // in minor units
    var sawNumber = false;
    var sawCurrency = false;
    var except = false;
    var pointMode = false;
    var pointDigits = '';
    final consumed = <int>{};

    int? numVal(String w) {
      if (_arNums.containsKey(w)) return _arNums[w];
      if (_enNums.containsKey(w)) return _enNums[w];
      return null;
    }

    for (var i = 0; i < tokens.length; i++) {
      var w = tokens[i];
      if (w == 'و' || w == 'and') {
        if (sawNumber) consumed.add(i);
        continue;
      }
      // Strip the Arabic conjunction prefix "و" when the rest is a number word.
      if (w.length > 2 && w.startsWith('و')) {
        final rest = w.substring(1);
        if (numVal(rest) != null || _arQuarter.contains(rest) || _arHalf.contains(rest) || _arHundred.contains(rest) || _arThird.contains(rest) || _arDinar.contains(rest) || _arFils.contains(rest)) {
          w = rest;
        }
      }
      // English "a" counts only as "a quarter" / "a half".
      if (w == 'a' && !(i + 1 < tokens.length && (tokens[i + 1] == 'quarter' || tokens[i + 1] == 'half'))) continue;

      if (pointMode) {
        final v = numVal(w);
        if (v != null && v < 10) {
          pointDigits += '$v';
          consumed.add(i);
          continue;
        }
        pointMode = false;
      }
      if (w == 'point' || w == 'فاصله' || w == 'فاصل') {
        if (sawNumber) {
          pointMode = true;
          consumed.add(i);
        }
        continue;
      }
      final v = numVal(w);
      if (v != null) {
        if (w == 'a') {
          consumed.add(i);
          continue;
        }
        current += v;
        sawNumber = true;
        consumed.add(i);
        if (v >= 1000) {
          total += current;
          current = 0;
        }
        continue;
      }
      if (_arHundred.contains(w) || w == 'hundred') {
        current = (current == 0 ? 1 : current) * 100;
        sawNumber = true;
        consumed.add(i);
        continue;
      }
      if (_arThousand.contains(w) || w == 'thousand') {
        total += (current == 0 ? 1 : current) * 1000;
        current = 0;
        sawNumber = true;
        consumed.add(i);
        continue;
      }
      if (_arDinarDual.contains(w)) {
        dinars += (total + current) == 0 ? 2 : total + current;
        total = current = 0;
        sawCurrency = true;
        sawNumber = true;
        consumed.add(i);
        continue;
      }
      if (_arDinar.contains(w) || _enDinar.contains(w)) {
        dinars += (total + current) == 0 ? (sawNumber ? 0 : 1) : total + current;
        if (!sawNumber) sawNumber = true;
        total = current = 0;
        sawCurrency = true;
        consumed.add(i);
        continue;
      }
      if (_arFils.contains(w) || _enFils.contains(w)) {
        fils += total + current;
        total = current = 0;
        sawCurrency = true;
        consumed.add(i);
        continue;
      }
      if (_arExcept.contains(w) && sawNumber) {
        except = true;
        consumed.add(i);
        continue;
      }
      if (_arQuarter.contains(w) || w == 'quarter') {
        frac += (except ? -1 : 1) * factor ~/ 4;
        except = false;
        sawNumber = true;
        consumed.add(i);
        continue;
      }
      if (_arHalf.contains(w) || w == 'half') {
        frac += (except ? -1 : 1) * factor ~/ 2;
        except = false;
        sawNumber = true;
        consumed.add(i);
        continue;
      }
      if (_arThird.contains(w)) {
        frac += (except ? -1 : 1) * factor ~/ 3;
        except = false;
        sawNumber = true;
        consumed.add(i);
        continue;
      }
    }
    if (!sawNumber) return _NumResult(null, false, consumed);
    var whole = total + current;
    int minor;
    if (pointDigits.isNotEmpty) {
      final s = '${dinars + whole}.$pointDigits';
      minor = Money.parseMinor(s, exp, allowRounding: true) ?? 0;
      return _NumResult(minor + fils + frac, sawCurrency, consumed);
    }
    if (sawCurrency && dinars > 0 && whole > 0 && whole < 1000 && fils == 0) {
      // "خمس دنانير و ميتين وخمسين" with an unit-less remainder after the dinar word: fils.
      fils += whole;
      whole = 0;
    }
    minor = (dinars + whole) * factor + fils + frac;
    if (minor <= 0) return _NumResult(null, sawCurrency, consumed);
    return _NumResult(minor, sawCurrency, consumed);
  }
}

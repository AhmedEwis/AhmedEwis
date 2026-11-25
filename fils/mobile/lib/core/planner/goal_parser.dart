/// Local (on-device) understanding of savings goals, in Arabic (Gulf/Kuwaiti, Egyptian,
/// MSA) and English. It's the "basic local planner" path and works with no cloud AI.
/// The cloud path produces the same [PlanIntent], validated by [validateAiIntent].
library;

import '../domain/categories.dart';
import '../money/money.dart';
import 'plan_models.dart';

/// Normalizes Arabic for matching: digits → ASCII, alef/ta-marbuta/ya variants, no harakat.
String normalizePlanText(String s) => normalizeDigits(s)
    .toLowerCase()
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp('[ً-ْـ]'), '')
    .replaceAll('’', "'");

/// Phrases that stand for several categories. Shown to the user as an editable assumption.
const groupedPhraseCategories = <String, List<String>>{
  'مصاريف البيت': [Cat.housing, Cat.bills, Cat.groceries],
  'مصروف البيت': [Cat.housing, Cat.bills, Cat.groceries],
  'البيت': [Cat.housing, Cat.bills, Cat.groceries],
  'المنزل': [Cat.housing, Cat.bills, Cat.groceries],
  'household': [Cat.housing, Cat.bills, Cat.groceries],
  'home expenses': [Cat.housing, Cat.bills, Cat.groceries],
  'house expenses': [Cat.housing, Cat.bills, Cat.groceries],
};

/// Category words (normalized). Matched on word boundaries, with Arabic prefixes.
const planCategoryKeywords = <String, List<String>>{
  Cat.fitness: ['جيم', 'الجيم', 'نادي رياضي', 'النادي', 'رياضه', 'gym', 'fitness', 'sports club'],
  Cat.food: ['مطاعم', 'مطعم', 'اكل برا', 'اكل', 'طلبات', 'قهوه', 'كافيهات', 'restaurants', 'restaurant', 'eating out', 'dining', 'food', 'coffee', 'talabat'],
  Cat.groceries: ['جمعيه', 'بقاله', 'سوبرماركت', 'groceries', 'grocery', 'supermarket'],
  Cat.fuel: ['بنزين', 'وقود', 'fuel', 'petrol'],
  Cat.transport: ['مواصلات', 'تاكسي', 'اوبر', 'transport', 'taxi', 'uber'],
  Cat.shopping: ['تسوق', 'ملابس', 'هدوم', 'shopping', 'clothes'],
  Cat.entertainment: ['ترفيه', 'سينما', 'خروجات', 'طلعات', 'entertainment', 'cinema', 'outings'],
  Cat.travel: ['سفر', 'سفريات', 'travel', 'trips'],
  Cat.subscriptions: ['اشتراكات', 'اشتراك', 'subscriptions', 'subscription', 'netflix'],
  Cat.telecom: ['اتصالات', 'انترنت', 'نت', 'موبايل', 'telecom', 'internet', 'phone bill'],
  Cat.health: ['صحه', 'دكتور', 'علاج', 'ادويه', 'health', 'medical', 'doctor', 'medicine'],
  Cat.education: ['تعليم', 'مدارس', 'مدرسه', 'جامعه', 'دراسه', 'education', 'school', 'tuition'],
  Cat.family: ['العيله', 'العائله', 'الاهل', 'اهلي', 'family', 'parents'],
  Cat.charity: ['صدقه', 'زكاه', 'خيري', 'charity', 'zakat'],
  Cat.installments: ['قسط', 'اقساط', 'installment', 'installments', 'loan'],
  Cat.housing: ['ايجار', 'سكن', 'rent', 'housing'],
  Cat.bills: ['فواتير', 'كهربا', 'كهرباء', 'مويه', 'bills', 'utilities'],
  Cat.personalCare: ['صالون', 'حلاق', 'personal care', 'salon'],
};

const _protectMarkers = [
  'ما تقلل', 'ماتقلل', 'متقللش', 'ما تقللش', 'لا تقلل', 'لا تنقص', 'ما تنقص', 'ما تلمس', 'متلمسش', 'لا تلمس', 'ما تقرب', 'متقربش', 'لا تقرب', 'لا تقربون', 'لا تمسون', 'ما تمس',
  'ما عدا', 'ماعدا', 'بدون ما', 'خلي', 'سيب', 'خل ', 'لا تمس', 'ثابت', 'ثابته',
  "don't cut", 'dont cut', 'do not cut', "don't touch", 'dont touch', 'do not touch', "don't reduce", 'do not reduce', 'except', 'keep', 'without cutting', 'not cutting', 'leave',
];
const _targetMarkers = ['اوفر', 'وفر', 'ادخر', 'احوش', 'اجمع', 'توفير', 'ادخار', 'احط على جنب', 'save', 'saving', 'put aside', 'set aside'];
const _incomeMarkers = ['راتبي', 'راتب', 'الراتب', 'دخلي', 'الدخل', 'معاشي', 'باخد', 'بقبض', 'اقبض', 'salary', 'income', 'i earn', 'earn', 'paid'];
const _commitMarkers = <String, String>{
  'قسط': Cat.installments, 'اقساط': Cat.installments, 'قرض': Cat.installments, 'installment': Cat.installments, 'loan': Cat.installments,
  'ايجار': Cat.housing, 'rent': Cat.housing,
};
const _thisPeriod = ['الشهر ده', 'الشهر دا', 'الشهر دى', 'هالشهر', 'هذا الشهر', 'الشهر هذا', 'الشهر الحالي', 'اخر الشهر', 'نهايه الشهر', 'اخر هالشهر', 'this month', 'end of the month', 'end of month', 'by month end', 'this cycle'];

const _numberWords = <String, int>{
  'واحد': 1, 'اثنين': 2, 'اتنين': 2, 'ثلاث': 3, 'ثلاثه': 3, 'تلات': 3, 'تلاته': 3, 'تلت': 3, 'اربع': 4, 'اربعه': 4, 'خمس': 5, 'خمسه': 5,
  'ست': 6, 'سته': 6, 'سبع': 7, 'سبعه': 7, 'ثمان': 8, 'ثمانيه': 8, 'تمن': 8, 'تمانيه': 8, 'تسع': 9, 'تسعه': 9, 'عشر': 10, 'عشره': 10,
  'عشرين': 20, 'ثلاثين': 30, 'تلاتين': 30, 'اربعين': 40, 'خمسين': 50, 'ستين': 60, 'سبعين': 70, 'ثمانين': 80, 'تمانين': 80, 'تسعين': 90,
  'ميه': 100, 'مية': 100, 'مائه': 100, 'ميت': 100, 'ميتين': 200, 'مئتين': 200, 'مائتين': 200, 'تلتميه': 300, 'ثلاثمائه': 300, 'ثلاثميه': 300,
  'ربعميه': 400, 'اربعمائه': 400, 'اربعميه': 400, 'خمسميه': 500, 'خمسمائه': 500, 'ستميه': 600, 'سبعميه': 700, 'تمنميه': 800, 'تسعميه': 900,
  'الف': 1000, 'الفين': 2000,
};
const _monthWords = <String, int>{'شهر': 1, 'شهرين': 2, 'month': 1, 'months': 1};

/// An amount found in the text, with the exact source span (for evidence checks).
class FoundAmount {
  final int minor;
  final String? currency; // null when no currency word was attached
  final int start;
  final int end;
  final String text;
  const FoundAmount(this.minor, this.currency, this.start, this.end, this.text);
}

final _currencyAfter = RegExp(r'^\s*(دينار|دنانير|د\.?\s?ك|كويتي|kd|kwd|dinars?|دولار|usd|\$|ريال|sar)');
final _currencyBefore = RegExp(r'(kd|kwd|د\.?\s?ك|usd|\$)\s*$');

String? _currencyOf(String w) {
  final x = w.replaceAll(RegExp(r'\s'), '');
  if (RegExp(r'^(دينار|دنانير|د\.?ك|كويتي|kd|kwd|dinars?)$').hasMatch(x)) return 'KWD';
  if (RegExp(r'^(دولار|usd|\$)$').hasMatch(x)) return 'USD';
  if (RegExp(r'^(ريال|sar)$').hasMatch(x)) return 'SAR';
  return null;
}

/// Finds amounts written in digits ("150", "1,200.500") or common Arabic number words
/// ("مية وخمسين"), with any currency word directly attached. Text must be normalized.
List<FoundAmount> findAmounts(String t) {
  final out = <FoundAmount>[];
  for (final m in RegExp(r'(?<![\d.])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,3}))?(?![\d])').allMatches(t)) {
    final whole = int.parse(m.group(1)!.replaceAll(',', ''));
    final frac = m.group(2);
    final minor = whole * 1000 + (frac == null ? 0 : int.parse(frac.padRight(3, '0')));
    final after = _currencyAfter.firstMatch(t.substring(m.end));
    final before = _currencyBefore.firstMatch(t.substring(0, m.start));
    final cur = after != null ? _currencyOf(after.group(1)!) : (before != null ? _currencyOf(before.group(1)!) : null);
    out.add(FoundAmount(minor, cur, m.start, m.end, m.group(0)!));
  }
  // Arabic number words: a run of number words joined by "و".
  final words = RegExp(r'[ء-ي]+').allMatches(t).toList();
  var i = 0;
  while (i < words.length) {
    final w = words[i].group(0)!;
    final bare = w.startsWith('و') && _numberWords.containsKey(w.substring(1)) ? w.substring(1) : w;
    if (!_numberWords.containsKey(bare)) {
      i++;
      continue;
    }
    var total = 0, j = i, end = words[i].end;
    while (j < words.length) {
      final x = words[j].group(0)!;
      final b = x.startsWith('و') && _numberWords.containsKey(x.substring(1)) ? x.substring(1) : x;
      final v = _numberWords[b];
      if (v == null) break;
      // Words must be adjacent (only spaces between them).
      if (j > i && t.substring(words[j - 1].end, words[j].start).trim().isNotEmpty) break;
      total = (v == 1000 || v == 2000) && total > 0 && total < 1000 ? total * 1000 : total + v;
      end = words[j].end;
      j++;
    }
    // Skip month counts ("تلت شهور") and bare small numbers without a currency word.
    final after = _currencyAfter.firstMatch(t.substring(end));
    final cur = after != null ? _currencyOf(after.group(1)!) : null;
    if (total >= 10 || cur != null) out.add(FoundAmount(total * 1000, cur, words[i].start, end, t.substring(words[i].start, end)));
    i = j;
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

const _arPrefixes = ['', 'ال', 'و', 'وال', 'بال', 'لل', 'ب', 'ل', 'فال', 'ف'];

/// Whole-word match of [kw] in [t], allowing Arabic prefixes. Returns the start index or -1.
int findKeyword(String t, String kw) {
  for (final p in _arPrefixes) {
    final pat = RegExp('(?<![\\p{L}\\p{N}])${RegExp.escape('$p$kw')}(?![\\p{L}\\p{N}])', unicode: true);
    final m = pat.firstMatch(t);
    if (m != null) return m.start;
  }
  return -1;
}

bool _hasAny(String t, List<String> ws) => ws.any((w) => findKeyword(t, w) >= 0 || (w.contains(' ') && t.contains(w)));

/// Splits on sentence punctuation and on contrast words ("بس", "لكن", "but"), which
/// separate the goal from its conditions. "و"/"ولا" lists stay together.
List<String> _clauses(String t) => t
    .split(RegExp(r'[،,.;؛!?\n]|(?<![\p{L}])(بس|لكن|بشرط|but|however|as long as)(?![\p{L}])', unicode: true))
    .map((c) => c.trim())
    .where((c) => c.isNotEmpty)
    .toList();

/// Parses a planning request. Never guesses a number that isn't in the text.
PlanIntent parseGoal(String input, {required String baseCurrency}) {
  final t = normalizePlanText(input);
  int? target;
  String? currency;
  int? income;
  final commitments = <StatedCommitment>[];
  final protected = <String>{};
  final grouped = <String, List<String>>{};
  final unmatched = <String>[];

  for (final clause in _clauses(t)) {
    final amounts = findAmounts(clause);
    final isProtect = _protectMarkers.any(clause.contains);
    for (final a in amounts) {
      final before = clause.substring(0, a.start);
      final after = clause.substring(a.end);
      // The nearest cue before the amount decides what it is ("راتبي 900 وعندي قسط 120":
      // 900 is income, 120 a commitment). A cue right after it counts when none precede.
      int lastPos(List<String> ws) => ws.map((w) => before.lastIndexOf(w)).fold(-1, (m, x) => x > m ? x : m);
      final incPos = lastPos(_incomeMarkers);
      var comPos = -1;
      String? commitCat;
      _commitMarkers.forEach((k, v) {
        final x = before.lastIndexOf(k);
        if (x > comPos) {
          comPos = x;
          commitCat = v;
        }
      });
      final tgtPos = lastPos(_targetMarkers);
      final head = after.length > 16 ? after.substring(0, 16) : after;
      String kind;
      if (comPos > incPos && comPos > tgtPos) {
        kind = 'commit';
      } else if (incPos > comPos && incPos > tgtPos) {
        kind = 'income';
      } else if (tgtPos >= 0) {
        kind = 'target';
      } else if (_hasAny(head, _incomeMarkers)) {
        kind = 'income';
      } else {
        String? c2;
        _commitMarkers.forEach((k, v) => c2 ??= findKeyword(head, k) >= 0 ? v : null);
        if (c2 != null) {
          commitCat = c2;
          kind = 'commit';
        } else {
          kind = a.currency != null ? 'target' : 'none';
        }
      }
      if (kind == 'income') {
        income ??= a.minor;
      } else if (kind == 'commit' && commitCat != null) {
        commitments.add(StatedCommitment(commitCat!, a.minor));
      } else if (kind == 'target' && target == null) {
        target = a.minor;
        currency = a.currency;
      }
    }
    if (isProtect) {
      // Grouped phrases first ("مصاريف البيت"), so their words don't double-match.
      var rest = clause;
      for (final e in groupedPhraseCategories.entries) {
        if (findKeyword(rest, e.key) >= 0) {
          grouped[e.key] = e.value;
          protected.addAll(e.value);
          rest = rest.replaceAll(e.key, ' ');
        }
      }
      planCategoryKeywords.forEach((cat, kws) {
        if (kws.any((k) => findKeyword(rest, k) >= 0)) protected.add(cat);
      });
    }
  }
  if (protected.isEmpty && _protectMarkers.any(t.contains)) {
    // A protection marker with nothing recognizable after it: keep the words to ask about.
    final m = RegExp(r'(ما تقلل\S*|متقللش|don.?t cut|do not cut|except|keep)\s+(.{1,30})').firstMatch(t);
    if (m != null) unmatched.add(m.group(2)!.trim());
  }

  DeadlineKind? deadline;
  var months = 1;
  if (_thisPeriod.any(t.contains)) {
    deadline = DeadlineKind.thisCycle;
  } else {
    final m = RegExp(r'(?:خلال|في|بعد|within|in|over)\s+(\d+|[ء-ي]+)\s*(شهور|اشهر|شهر|months?)').firstMatch(t);
    if (m != null) {
      final n = int.tryParse(m.group(1)!) ?? _numberWords[m.group(1)!];
      if (n != null && n >= 1 && n <= 36) {
        months = n;
        deadline = n == 1 ? DeadlineKind.thisCycle : DeadlineKind.months;
      }
    } else {
      for (final e in _monthWords.entries) {
        if (e.value > 1 && findKeyword(t, e.key) >= 0) {
          months = e.value;
          deadline = DeadlineKind.months;
        }
      }
    }
  }

  return PlanIntent(
    targetMinor: target,
    currency: currency ?? (target != null ? null : null),
    deadline: deadline,
    months: months,
    protectedCategories: protected,
    groupedPhrases: grouped,
    incomeMinor: income,
    commitments: commitments,
    unmatchedProtected: unmatched,
    understoodBy: 'local',
  );
}

/// Validates a cloud-AI intent against the user's own words. The model can't invent an
/// amount: each amount must be given with the exact text it came from, that text must
/// appear in what the user said, and it must parse to the same value. Categories must
/// be known ids. Returns null when anything fails (→ local parser is used instead).
PlanIntent? validateAiIntent(Map<String, Object?> args, String userText, {required Set<String> knownCategories}) {
  final t = normalizePlanText(userText);
  final found = findAmounts(t);

  int? checked(Object? evidence, Object? claimedMinor) {
    if (evidence == null && claimedMinor == null) return null;
    if (evidence is! String || claimedMinor is! int) throw const FormatException('amount without evidence');
    final ev = normalizePlanText(evidence).trim();
    if (ev.isEmpty || !t.contains(ev)) throw const FormatException('evidence not in user text');
    final inEv = findAmounts(ev);
    if (inEv.isEmpty || inEv.first.minor != claimedMinor) throw const FormatException('evidence does not parse to the claimed amount');
    if (!found.any((f) => f.minor == claimedMinor)) throw const FormatException('amount not in user text');
    return claimedMinor;
  }

  try {
    final target = checked(args['target_evidence'], args['target_minor']);
    final income = checked(args['income_evidence'], args['income_minor']);
    final cur = args['currency'];
    if (cur != null && (cur is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(cur))) return null;
    final deadline = switch (args['deadline']) {
      'this_cycle' => DeadlineKind.thisCycle,
      'months' => DeadlineKind.months,
      null => null,
      _ => throw const FormatException('deadline'),
    };
    final months = args['months'] ?? 1;
    if (months is! int || months < 1 || months > 36) return null;
    final prot = args['protected_categories'] ?? const [];
    if (prot is! List || prot.length > 12) return null;
    final protected = <String>{};
    for (final c in prot) {
      if (c is! String || !knownCategories.contains(c)) return null;
      protected.add(c);
    }
    final commitments = <StatedCommitment>[];
    final cs = args['commitments'] ?? const [];
    if (cs is! List || cs.length > 8) return null;
    for (final c in cs) {
      if (c is! Map) return null;
      final cat = c['category_id'];
      if (cat is! String || !knownCategories.contains(cat)) return null;
      final amt = checked(c['evidence'], c['amount_minor']);
      if (amt == null) return null;
      commitments.add(StatedCommitment(cat, amt));
    }
    return PlanIntent(
      targetMinor: target,
      currency: cur as String?,
      deadline: deadline,
      months: deadline == DeadlineKind.months ? months : 1,
      protectedCategories: protected,
      incomeMinor: income,
      commitments: commitments,
      understoodBy: 'ai',
    );
  } on FormatException {
    return null;
  }
}

/// On-device assistant: a deterministic intent router (Arabic Gulf/Egyptian/MSA plus
/// English) over the typed tools, with templated answers. It works offline and without any
/// cloud AI. The cloud path (assistant_client.dart) reuses the same tools.
library;

import '../domain/categories.dart';
import '../money/money.dart';
import '../parsing/merchant_directory.dart';
import '../voice/voice_parser.dart';
import 'tools.dart';

class AssistantAnswer {
  final String text;
  final List<ToolResult> results;
  final bool onDevice;
  final bool understood;
  const AssistantAnswer(this.text, this.results, {this.onDevice = true, this.understood = true});
}

class Intent {
  final String tool;
  final Map<String, Object?> args;
  const Intent(this.tool, this.args);
}

String _n(String s) => normalizeDigits(s)
    .toLowerCase()
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp('[ً-ْ]'), '');

bool _any(String t, List<String> ws) => ws.any(t.contains);

const _catKeywords = <String, List<String>>{
  Cat.food: ['مطاعم', 'مطعم', 'اكل', 'اكلات', 'اكل برا', 'restaurant', 'food', 'dining', 'eating out', 'قهوه', 'coffee'],
  Cat.groceries: ['جمعيه', 'بقاله', 'سوبرماركت', 'groceries', 'grocery', 'supermarket'],
  Cat.fuel: ['بنزين', 'وقود', 'fuel', 'petrol', 'gas'],
  Cat.transport: ['مواصلات', 'تاكسي', 'transport', 'taxi', 'rides'],
  Cat.shopping: ['تسوق', 'ملابس', 'shopping', 'clothes'],
  Cat.health: ['صحه', 'صيدليه', 'دكتور', 'health', 'pharmacy', 'medical'],
  Cat.subscriptions: ['اشتراكات', 'subscriptions'],
  Cat.telecom: ['اتصالات', 'انترنت', 'telecom', 'internet', 'phone bill'],
  Cat.entertainment: ['ترفيه', 'سينما', 'entertainment', 'movies'],
  Cat.travel: ['سفر', 'travel', 'flights'],
  Cat.housing: ['ايجار', 'rent', 'housing'],
};

String? detectPeriod(String t) {
  if (_any(t, ['اليوم', 'النهارده', 'today'])) return 'today';
  if (_any(t, ['امس', 'yesterday'])) return 'last_7_days';
  if (_any(t, ['الشهر الماضي', 'الشهر اللي فات', 'الشهر السابق', 'last month', 'previous month'])) return 'last_month';
  if (_any(t, ['الدوره الماضيه', 'الراتب اللي فات', 'last cycle', 'previous cycle'])) return 'last_cycle';
  if (_any(t, ['هالاسبوع', 'الاسبوع ده', 'هذا الاسبوع', 'الاسبوع', 'this week'])) return 'this_week';
  if (_any(t, ['هالسنه', 'السنه', 'this year'])) return 'this_year';
  if (_any(t, ['هالشهر', 'الشهر ده', 'هذا الشهر', 'الشهر', 'this month', 'month'])) return 'this_month';
  if (_any(t, ['الدوره', 'cycle', 'من الراتب'])) return 'this_cycle';
  return null;
}

Intent? routeIntent(String question, {List<String> knownMerchants = const []}) {
  final t = _n(question);
  final period = detectPeriod(t);

  if (_any(t, ['لين الراتب', 'لحد الراتب', 'حتي الراتب', 'قبل الراتب', 'باقي لي', 'فاضل لي', 'فاضلي', 'until payday', 'left until', 'till payday', 'before payday', 'left to spend', 'what\'s left'])) {
    return const Intent('left_until_payday', {});
  }
  if (_any(t, ['اشتراك', 'متكرر', 'اقساط', 'قسط', 'recurring', 'subscription', 'installment', 'bills'])) {
    return const Intent('recurring_list', {});
  }
  if (_any(t, ['ليش زاد', 'ليه زاد', 'ليه المصروف', 'ليش المصروف', 'زاد المصروف', 'why did', 'why is my spending', 'went up', 'increase', 'compare', 'مقارنه', 'قارن'])) {
    return Intent('compare_periods', {'period': _any(t, ['cycle', 'دوره', 'راتب']) ? 'cycle' : 'month'});
  }
  if (_any(t, ['هدف', 'اهداف', 'goal', 'اوصل', 'reach', 'وفرت', 'save '])) {
    final amount = const VoiceParser().parse(question).amountMinor;
    return Intent('goal_projection', {if (amount != null) 'monthly_amount_minor': amount});
  }
  if (_any(t, ['رصيد', 'رصيدي', 'balance', 'how much do i have', 'كم عندي', 'حساباتي'])) {
    return const Intent('account_balances', {});
  }
  // Merchant-specific spending
  String? merchant;
  for (final r in merchantRules) {
    for (final p in [...r.patterns, r.name.toLowerCase()]) {
      final pn = _n(p).trim();
      if (pn.length >= 3 && t.contains(pn)) {
        merchant = r.name;
        break;
      }
    }
    if (merchant != null) break;
  }
  if (merchant == null) {
    for (final m in knownMerchants) {
      if (m.length >= 3 && t.contains(_n(m))) {
        merchant = m;
        break;
      }
    }
  }
  String? category;
  _catKeywords.forEach((k, ws) {
    if (category == null && _any(t, ws)) category = k;
  });
  final spendingQ = _any(t, ['صرفت', 'مصروف', 'مصاريف', 'راحت فلوسي', 'فلوسي', 'spent', 'spend', 'spending', 'where did my money', 'how much', 'كم', 'كام']);
  if (spendingQ || merchant != null || category != null) {
    return Intent('spending_summary', {'period': period ?? 'this_month', if (merchant != null) 'merchant': merchant, if (category != null && merchant == null) 'category_id': category});
  }
  return null;
}

class LocalAssistant {
  final bool arabic;
  final String Function(int minor, String currency) money;
  const LocalAssistant({required this.arabic, required this.money});

  AssistantAnswer answer(String question, FinanceSnapshot snap) {
    final merchants = snap.txs.map((t) => t.merchant).whereType<String>().toSet().toList();
    final intent = routeIntent(question, knownMerchants: merchants);
    if (intent == null) {
      return AssistantAnswer('', const [], understood: false);
    }
    final r = runTool(intent.tool, intent.args, snap);
    return AssistantAnswer(compose(r), [r]);
  }

  String _periodText(Map p) => arabic ? 'من ${p['start']} إلى ما قبل ${p['end_exclusive']}' : 'from ${p['start']} to before ${p['end_exclusive']}';

  String compose(ToolResult r) {
    final d = r.data;
    final cur = (d['currency'] as String?) ?? 'KWD';
    String m(Object? v) => money((v as num?)?.toInt() ?? 0, cur);
    if (d['error'] == 'no_goals') return arabic ? 'ما عندك أهداف بعد. أنشئ هدفاً من تبويب الخطط.' : "You don't have any goals yet. Create one in Plans.";
    switch (r.tool) {
      case 'spending_summary':
        final b = StringBuffer();
        final who = d['merchant'] != null ? (arabic ? ' على ${d['merchant']}' : ' on ${d['merchant']}') : (d['category_id'] != null ? (arabic ? ' على ${categoryDef(d['category_id'] as String)?.ar ?? d['category_id']}' : ' on ${categoryDef(d['category_id'] as String)?.en ?? d['category_id']}') : '');
        b.writeln(arabic
            ? 'صرفت${who} ${m(d['spent_minor'])} (${d['transaction_count']} عملية) ${_periodText(d['period'] as Map)}.'
            : 'You spent ${m(d['spent_minor'])}$who across ${d['transaction_count']} transactions, ${_periodText(d['period'] as Map)}.');
        final top = (d['top_categories'] as List).cast<Map>();
        if (d['merchant'] == null && d['category_id'] == null && top.isNotEmpty) {
          b.writeln(arabic ? 'أعلى الفئات:' : 'Top categories:');
          for (final c in top.take(5)) {
            b.writeln('• ${arabic ? c['name_ar'] : c['name_en']} — ${m(c['spent_minor'])} (${((c['share'] as num) * 100).toStringAsFixed(1)}%)');
          }
        }
        final other = (d['other_currencies'] as Map);
        if (other.isNotEmpty) {
          b.writeln(arabic
              ? 'ومصروف بعملات أخرى غير مدمج: ${other.entries.map((e) => money((e.value as num).toInt(), e.key as String)).join('، ')}.'
              : 'Also spent in other currencies (not combined): ${other.entries.map((e) => money((e.value as num).toInt(), e.key as String)).join(', ')}.');
        }
        b.write(arabic ? 'يشمل كل الحسابات بعملة $cur، بدون التحويلات بين حساباتك.' : 'Includes all accounts in $cur; transfers between your own accounts are excluded.');
        return b.toString();
      case 'left_until_payday':
        return arabic
            ? 'المتبقي حتى الراتب تقريباً ${m(d['available_minor'])} خلال ${d['days_until_payday']} يوم (≈ ${m(d['per_day_minor'])} يومياً).\n'
                'الرصيد القابل للصرف ${m(d['spendable_balance_minor'])} ناقص التزامات مؤكدة ${m(d['confirmed_due_before_payday_minor'])}.\n'
                'الأرصدة محسوبة من عملياتك وليست أرصدة مباشرة من البنك.'
            : 'About ${m(d['available_minor'])} left for the next ${d['days_until_payday']} days (≈ ${m(d['per_day_minor'])}/day).\n'
                'Spendable balance ${m(d['spendable_balance_minor'])} minus confirmed bills ${m(d['confirmed_due_before_payday_minor'])} before payday.\n'
                'Balances are calculated from your transactions, not live bank balances.';
      case 'recurring_list':
        final active = (d['active'] as List).cast<Map>();
        final sug = (d['suggested_unconfirmed'] as List).cast<Map>();
        final b = StringBuffer(arabic ? 'التزاماتك المتكررة: ${m(d['monthly_total_minor'])} شهرياً.\n' : 'Your recurring commitments: ${m(d['monthly_total_minor'])} per month.\n');
        for (final a in active) {
          b.writeln('• ${a['name']} — ${money((a['amount_minor'] as num).toInt(), a['currency'] as String)} (${a['next_due']})');
        }
        if (active.isEmpty) b.writeln(arabic ? 'لا توجد التزامات مؤكدة بعد.' : 'No confirmed commitments yet.');
        if (sug.isNotEmpty) {
          b.writeln(arabic ? 'ولاحظنا تكراراً (غير مؤكد):' : 'Possibly recurring (not confirmed):');
          for (final x in sug) {
            b.writeln('• ${x['merchant']} ≈ ${m(x['typical_amount_minor'])} ×${x['occurrences']}');
          }
        }
        return b.toString().trimRight();
      case 'compare_periods':
        final changes = (d['category_changes'] as List).cast<Map>().where((c) => (c['delta_minor'] as int) > 0).take(3);
        final diff = (d['current_spent_minor'] as int) - (d['previous_same_span_spent_minor'] as int);
        final b = StringBuffer(arabic
            ? 'خلال أول ${d['elapsed_days']} يوم: صرفت ${m(d['current_spent_minor'])} مقابل ${m(d['previous_same_span_spent_minor'])} في نفس المدة من الفترة السابقة (${diff >= 0 ? '+' : '-'}${m(diff.abs())}).\n'
            : 'In the first ${d['elapsed_days']} days you spent ${m(d['current_spent_minor'])} vs ${m(d['previous_same_span_spent_minor'])} in the same span of the previous period (${diff >= 0 ? '+' : '-'}${m(diff.abs())}).\n');
        if (changes.isNotEmpty) {
          b.writeln(arabic ? 'أكبر الزيادات:' : 'Biggest increases:');
          for (final c in changes) {
            b.writeln('• ${arabic ? c['name_ar'] ?? c['category_id'] : c['name_en'] ?? c['category_id']}: +${m(c['delta_minor'])}');
          }
        }
        return b.toString().trimRight();
      case 'goal_projection':
        if (d['months_needed'] == null) {
          return arabic
              ? 'هدف "${d['goal']}": مدخر ${m(d['saved_minor'])} من ${m(d['target_minor'])}. حدد مبلغاً شهرياً لأحسب لك المدة.'
              : 'Goal "${d['goal']}": ${m(d['saved_minor'])} saved of ${m(d['target_minor'])}. Tell me a monthly amount and I will estimate the time.';
        }
        return arabic
            ? 'لو وفرت ${m(d['monthly_minor'])} شهرياً، توصل لهدف "${d['goal']}" بعد ${d['months_needed']} شهر تقريباً (${d['estimated_month']}). المتبقي ${m(d['remaining_minor'])}.\nالافتراض: مبلغ شهري ثابت بدون عوائد أو سحوبات.'
            : 'Saving ${m(d['monthly_minor'])} a month, you reach "${d['goal']}" in about ${d['months_needed']} months (${d['estimated_month']}). Remaining: ${m(d['remaining_minor'])}.\nAssumes a constant monthly amount, no returns and no withdrawals.';
      case 'account_balances':
        final b = StringBuffer();
        for (final a in (d['accounts'] as List).cast<Map>()) {
          b.writeln('• ${a['name']}: ${money((a['calculated_balance_minor'] as num).toInt(), a['currency'] as String)}');
        }
        b.write(arabic ? 'هذه أرصدة محسوبة من عملياتك، وليست أرصدة مباشرة من البنك.' : 'These are calculated from your transactions, not live bank balances.');
        return b.toString();
    }
    return '';
  }
}

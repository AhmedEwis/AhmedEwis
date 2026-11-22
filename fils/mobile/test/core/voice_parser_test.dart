import 'package:fils/core/voice/voice_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const p = VoiceParser();
  final cases = <String, (int?, String?, String?)>{
    'دفعت خمسة دنانير وربع على طلبات': (5250, 'Talabat', 'food'),
    'دفعت خمسة وعشرين دينار بنزين': (25000, null, 'fuel'),
    'ميتين وخمسين فلس قهوة': (250, null, 'food'),
    'دينار ونص تاكسي': (1500, null, 'transport'),
    'عشرة الا ربع على الجمعية': (9750, null, 'groceries'),
    'صرفت 12.5 على كاريبو': (12500, 'Caribou Coffee', 'food'),
    'دفعت ٣٫٧٥٠ د.ك في لولو': (3750, 'Lulu Hypermarket', 'groceries'),
    'دينارين صيدلية': (2000, null, 'health'),
    'خمس دنانير و ميتين وخمسين فلس': (5250, null, null),
    'twenty five KD at starbucks': (25000, 'Starbucks', 'food'),
    'five dinars and a quarter for lunch': (5250, null, 'food'),
    'three point seven five dinars on fuel': (3750, null, 'fuel'),
    'paid 7 KD and 500 fils at carrefour': (7500, 'Carrefour', 'groceries'),
    'ألف ومية دينار ايجار': (1100000, null, 'housing'),
    'دفعت ثمن الغدا ثلاثة دنانير': (3000, null, 'food'),
    'دفعت على طلبات': (null, 'Talabat', 'food'),
  };
  cases.forEach((text, exp) {
    test(text, () {
      final d = p.parse(text);
      expect(d.amountMinor, exp.$1, reason: '$d');
      if (exp.$2 != null) expect(d.merchant, exp.$2, reason: '$d');
      if (exp.$3 != null) expect(d.categoryId, exp.$3, reason: '$d');
    });
  });

  test('income phrasing', () {
    final d = p.parse('نزل الراتب ألف ومية دينار');
    expect(d.income, isTrue);
    expect(d.amountMinor, 1100000);
    expect(d.categoryId, 'salary');
  });
}

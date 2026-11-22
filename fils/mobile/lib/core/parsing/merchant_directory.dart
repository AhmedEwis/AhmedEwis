import '../domain/categories.dart';

/// Local merchant recognition for Kuwait. Patterns are lowercase substrings matched on
/// normalized descriptors. This is our own curated list of public business names. It
/// isn't affiliated with these companies and uses no logos.
class MerchantRule {
  final String name;
  final String? nameAr;
  final String category;
  final List<String> patterns;
  const MerchantRule(this.name, this.category, this.patterns, {this.nameAr});
}

/// Payment processors and gateways that appear as prefixes or descriptors.
/// They aren't the merchant. When one prefixes a descriptor (`MYFATOORAH*SHOP`), the part
/// after the separator is the merchant.
const paymentProcessors = <String, String>{
  'myfatoorah': 'MyFatoorah',
  'tap payments': 'Tap Payments',
  'tap*': 'Tap Payments',
  'upayments': 'UPayments',
  'hesabe': 'Hesabe',
  'knet': 'KNET',
  'checkout.com': 'Checkout.com',
  'paypal': 'PayPal',
  'sq *': 'Square',
  'sumup': 'SumUp',
  'apple pay': 'Apple Pay',
};

const merchantRules = <MerchantRule>[
  // Delivery and food
  MerchantRule('Talabat', Cat.food, ['talabat', 'طلبات'], nameAr: 'طلبات'),
  MerchantRule('Deliveroo', Cat.food, ['deliveroo', 'ديليفرو']),
  MerchantRule('Keeta', Cat.food, ['keeta', 'كيتا']),
  MerchantRule('Cari', Cat.food, ['cari ', 'cari.com']),
  MerchantRule('Starbucks', Cat.food, ['starbucks', 'ستاربكس']),
  MerchantRule('Caribou Coffee', Cat.food, ['caribou', 'كاريبو']),
  MerchantRule('Tim Hortons', Cat.food, ['tim hortons', 'تيم هورتنز']),
  MerchantRule('%Arabica', Cat.food, ['arabica']),
  MerchantRule("McDonald's", Cat.food, ['mcdonald', 'ماكدونالدز']),
  MerchantRule('KFC', Cat.food, ['kfc', 'كنتاكي']),
  MerchantRule('Burger King', Cat.food, ['burger king']),
  MerchantRule('Shake Shack', Cat.food, ['shake shack']),
  MerchantRule('Pizza Hut', Cat.food, ['pizza hut']),
  MerchantRule("Johnny Rockets", Cat.food, ['johnny rockets']),
  MerchantRule('Slider Station', Cat.food, ['slider station']),
  // Cooperatives and supermarkets
  MerchantRule('Co-op', Cat.groceries, ['co-op', 'coop', 'co op', 'جمعية', 'cooperative', 'coop soc'],
      nameAr: 'جمعية تعاونية'),
  MerchantRule('The Sultan Center', Cat.groceries, ['sultan center', 'sultan centre', 'tsc ', 'مركز سلطان']),
  MerchantRule('Lulu Hypermarket', Cat.groceries, ['lulu', 'لولو']),
  MerchantRule('Carrefour', Cat.groceries, ['carrefour', 'كارفور']),
  MerchantRule('City Centre', Cat.groceries, ['city centre', 'city center', 'سيتي سنتر']),
  MerchantRule('Oncost', Cat.groceries, ['oncost', 'أونكوست']),
  MerchantRule('Gulfmart', Cat.groceries, ['gulfmart', 'gulf mart']),
  MerchantRule('Grand Hyper', Cat.groceries, ['grand hyper']),
  // Fuel
  MerchantRule('KNPC', Cat.fuel, ['knpc', 'البترول الوطنية']),
  MerchantRule('Oula Fuel', Cat.fuel, ['oula', 'أولى']),
  MerchantRule('Soor Fuel', Cat.fuel, ['soor fuel', 'alsoor', 'al soor', 'السور']),
  MerchantRule('Petrol station', Cat.fuel, ['petrol', 'fuel station', 'محطة وقود', 'بنزين']),
  // Telecom
  MerchantRule('Zain', Cat.telecom, ['zain', 'زين']),
  MerchantRule('Ooredoo', Cat.telecom, ['ooredoo', 'أوريدو', 'اوريدو']),
  MerchantRule('stc', Cat.telecom, ['stc kuwait', 'stc ', 'viva', 'اس تي سي']),
  // Transport
  MerchantRule('Careem', Cat.transport, ['careem', 'كريم']),
  MerchantRule('Uber', Cat.transport, ['uber']),
  MerchantRule('Kuwait Airways', Cat.travel, ['kuwait airways', 'الخطوط الجوية الكويتية']),
  MerchantRule('Jazeera Airways', Cat.travel, ['jazeera airways', 'طيران الجزيرة']),
  // Shopping
  MerchantRule('Amazon', Cat.shopping, ['amazon', 'amzn']),
  MerchantRule('X-cite', Cat.shopping, ['x-cite', 'xcite', 'اكسايت']),
  MerchantRule('Eureka', Cat.shopping, ['eureka', 'يوريكا']),
  MerchantRule('IKEA', Cat.shopping, ['ikea', 'ايكيا']),
  MerchantRule('The Avenues', Cat.shopping, ['avenues', 'الافنيوز']),
  MerchantRule('Noon', Cat.shopping, ['noon.com', 'noon ']),
  MerchantRule('Shein', Cat.shopping, ['shein']),
  // Subscriptions and apps
  MerchantRule('Netflix', Cat.subscriptions, ['netflix']),
  MerchantRule('Spotify', Cat.subscriptions, ['spotify']),
  MerchantRule('Apple Services', Cat.subscriptions, ['apple.com/bill', 'itunes', 'apple.com']),
  MerchantRule('Google Services', Cat.subscriptions, ['google *', 'google play']),
  MerchantRule('OSN+', Cat.subscriptions, ['osn']),
  MerchantRule('Shahid', Cat.subscriptions, ['shahid']),
  // Bills and government
  MerchantRule('Ministry of Electricity & Water', Cat.bills, ['mew ', 'electricity', 'كهرباء']),
  MerchantRule('Sahel / Government', Cat.bills, ['sahel', 'ministry', 'وزارة']),
  // Health
  MerchantRule('Pharmacy', Cat.health, ['pharmacy', 'صيدلية']),
  MerchantRule('Hospital / Clinic', Cat.health, ['hospital', 'clinic', 'مستشفى', 'عيادة']),
  // Buy now, pay later (these are installment providers)
  MerchantRule('Tabby', Cat.installments, ['tabby', 'تابي']),
  MerchantRule('Taly', Cat.installments, ['taly', 'تالي']),
  MerchantRule('Deema', Cat.installments, ['deema', 'ديمة']),
];

class MerchantMatch {
  final String name;
  final String category;
  final String? processor;
  final String descriptor;
  const MerchantMatch(this.name, this.category, this.processor, this.descriptor);
}

/// Resolve a raw descriptor to a merchant and category, separating out processors.
/// User aliases (pattern → merchant/category) take priority over built-in rules.
MerchantMatch? matchMerchant(String? descriptor, {Map<String, (String, String?)> userAliases = const {}}) {
  if (descriptor == null || descriptor.trim().isEmpty) return null;
  var d = descriptor.trim();
  String? processor;
  final lower = d.toLowerCase();
  for (final e in paymentProcessors.entries) {
    if (lower.startsWith(e.key)) {
      processor = e.value;
      // Strip the processor prefix and any separator such as "*", "-" or ":".
      d = d.substring(e.key.length).replaceFirst(RegExp(r'^[\s*:\-_/]+'), '').trim();
      break;
    }
  }
  final key = d.toLowerCase();
  for (final a in userAliases.entries) {
    if (key.contains(a.key.toLowerCase())) {
      return MerchantMatch(a.value.$1, a.value.$2 ?? Cat.other, processor, descriptor);
    }
  }
  final padded = ' $key ';
  for (final r in merchantRules) {
    for (final p in r.patterns) {
      if (padded.contains(p)) return MerchantMatch(r.name, r.category, processor, descriptor);
    }
  }
  if (d.isEmpty) return processor == null ? null : MerchantMatch(processor, Cat.other, processor, descriptor);
  return MerchantMatch(_titleCase(d), Cat.other, processor, descriptor);
}

String _titleCase(String s) {
  // Leave Arabic and mixed text untouched; title-case only all-caps Latin descriptors.
  if (RegExp(r'[؀-ۿ]').hasMatch(s)) return s;
  if (s != s.toUpperCase()) return s;
  return s
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

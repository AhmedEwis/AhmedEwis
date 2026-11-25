/// System categories. IDs are stable strings used across devices and sync.
class CategoryDef {
  final String id;
  final String en;
  final String ar;
  final String icon; // emoji, matching the reference's emoji-tile style
  final int color; // ARGB
  final bool income;
  const CategoryDef(this.id, this.en, this.ar, this.icon, this.color, {this.income = false});
}

class Cat {
  static const food = 'food';
  static const groceries = 'groceries';
  static const transport = 'transport';
  static const fuel = 'fuel';
  static const shopping = 'shopping';
  static const bills = 'bills';
  static const telecom = 'telecom';
  static const health = 'health';
  static const education = 'education';
  static const entertainment = 'entertainment';
  static const travel = 'travel';
  static const housing = 'housing';
  static const installments = 'installments';
  static const subscriptions = 'subscriptions';
  static const fees = 'fees';
  static const charity = 'charity';
  static const family = 'family';
  static const personalCare = 'personal_care';
  static const fitness = 'fitness';
  static const cash = 'cash';
  static const other = 'other';
  static const transfers = 'transfers';
  static const salary = 'salary';
  static const otherIncome = 'other_income';
}

const systemCategories = <CategoryDef>[
  CategoryDef(Cat.food, 'Food & Dining', 'مطاعم وأكل', '🍔', 0xFFF59E0B),
  CategoryDef(Cat.groceries, 'Groceries', 'بقالة وجمعية', '🛒', 0xFF22C55E),
  CategoryDef(Cat.transport, 'Transport', 'مواصلات', '🚕', 0xFF3B82F6),
  CategoryDef(Cat.fuel, 'Fuel', 'بنزين', '⛽', 0xFF10B981),
  CategoryDef(Cat.shopping, 'Shopping', 'تسوق', '🛍️', 0xFF06B6D4),
  CategoryDef(Cat.bills, 'Bills & Utilities', 'فواتير', '💡', 0xFF8B5CF6),
  CategoryDef(Cat.telecom, 'Telecom & Internet', 'اتصالات وإنترنت', '📱', 0xFF6366F1),
  CategoryDef(Cat.health, 'Health', 'صحة', '💊', 0xFFEF4444),
  CategoryDef(Cat.education, 'Education', 'تعليم', '🎓', 0xFF0EA5E9),
  CategoryDef(Cat.entertainment, 'Entertainment', 'ترفيه', '🎬', 0xFFEC4899),
  CategoryDef(Cat.travel, 'Travel', 'سفر', '✈️', 0xFF14B8A6),
  CategoryDef(Cat.housing, 'Rent & Housing', 'إيجار وسكن', '🏠', 0xFF0A7EA4),
  CategoryDef(Cat.installments, 'Installments', 'أقساط', '🔁', 0xFF7C3AED),
  CategoryDef(Cat.subscriptions, 'Subscriptions', 'اشتراكات', '📺', 0xFFDB2777),
  CategoryDef(Cat.fees, 'Bank Fees', 'رسوم بنكية', '🏦', 0xFF64748B),
  CategoryDef(Cat.charity, 'Charity & Zakat', 'صدقة وزكاة', '🤲', 0xFF059669),
  CategoryDef(Cat.family, 'Family', 'العائلة', '👨‍👩‍👧', 0xFFF97316),
  CategoryDef(Cat.personalCare, 'Personal Care', 'عناية شخصية', '💈', 0xFFA855F7),
  CategoryDef(Cat.fitness, 'Fitness & Gym', 'رياضة وجيم', '🏋️', 0xFF0F766E),
  CategoryDef(Cat.cash, 'Cash', 'كاش', '💵', 0xFF84CC16),
  CategoryDef(Cat.transfers, 'Transfers to others', 'تحويلات لآخرين', '↗️', 0xFF0891B2),
  CategoryDef(Cat.other, 'Other', 'أخرى', '📦', 0xFF94A3B8),
  CategoryDef(Cat.salary, 'Salary', 'راتب', '💰', 0xFF16A34A, income: true),
  CategoryDef(Cat.otherIncome, 'Other Income', 'دخل آخر', '💸', 0xFF0D9488, income: true),
];

CategoryDef? categoryDef(String? id) {
  for (final c in systemCategories) {
    if (c.id == id) return c;
  }
  return null;
}

/// Kuwait bank adapter registry.
///
/// IMPORTANT: these are *target* banks. Sender IDs and Android package names below are
/// **unverified hints** unless their `evidence` says otherwise. They are only used to
/// suggest a bank for a message or to pre-select apps; the user always confirms which
/// apps or senders to monitor. Update `validation` only with real, consented evidence.
library;

enum ValidationStatus {
  /// Adapter code exists and runs on clearly labeled synthetic fixtures only.
  syntheticTested,

  /// Tested against real, sanitized, consented sample messages.
  realSampleTested,

  /// Verified end to end on a real device with a real account.
  deviceVerified,
}

class EvidencedValue {
  final String value;

  /// Where this value came from: `assumption`, `user-sample`, `public-doc:<url>`, or similar.
  final String evidence;
  const EvidencedValue(this.value, this.evidence);
}

class BankAdapter {
  final String id;
  final String nameEn;
  final String nameAr;
  final String shortCode;
  final int brandColor; // ARGB, our own neutral rendition; not an official logo
  final List<EvidencedValue> smsSenders;
  final List<EvidencedValue> androidPackages;
  final List<String> textHints; // lowercase substrings that suggest this bank
  final List<String> languages;
  final String formatVersion;
  final Set<String> supportedKinds;
  final String fixtureProvenance;
  final String? lastVerified; // ISO date or null
  final ValidationStatus validation;
  final List<String> knownLimitations;

  const BankAdapter({
    required this.id,
    required this.nameEn,
    required this.nameAr,
    required this.shortCode,
    required this.brandColor,
    required this.smsSenders,
    required this.androidPackages,
    required this.textHints,
    this.languages = const ['en', 'ar'],
    this.formatVersion = 'generic-kw-1',
    this.supportedKinds = const {
      'purchase', 'income', 'salary', 'transfer', 'atm', 'refund', 'reversal', 'declined',
      'fee', 'card_payment', 'installment', 'pending', 'foreign_currency',
    },
    this.fixtureProvenance = 'synthetic',
    this.lastVerified,
    this.validation = ValidationStatus.syntheticTested,
    this.knownLimitations = const [
      'No real sample messages verified yet; the parser uses the generic Kuwait engine.',
      'Sender IDs and package names are unverified assumptions.',
    ],
  });
}

const _assume = 'assumption: not verified against real messages';

const kuwaitBanks = <BankAdapter>[
  BankAdapter(
    id: 'warba',
    nameEn: 'Warba Bank',
    nameAr: 'بنك وربة',
    shortCode: 'WB',
    brandColor: 0xFF5B2C83,
    smsSenders: [EvidencedValue('WarbaBank', _assume), EvidencedValue('Warba', _assume)],
    androidPackages: [],
    textHints: ['warba', 'وربة'],
  ),
  BankAdapter(
    id: 'kfh',
    nameEn: 'Kuwait Finance House',
    nameAr: 'بيت التمويل الكويتي',
    shortCode: 'KFH',
    brandColor: 0xFF0B7A3E,
    smsSenders: [EvidencedValue('KFH', _assume)],
    androidPackages: [],
    textHints: ['kfh', 'بيتك', 'بيت التمويل'],
  ),
  BankAdapter(
    id: 'nbk',
    nameEn: 'National Bank of Kuwait',
    nameAr: 'بنك الكويت الوطني',
    shortCode: 'NBK',
    brandColor: 0xFF0A3D7A,
    smsSenders: [EvidencedValue('NBK', _assume)],
    androidPackages: [],
    textHints: ['nbk', 'الوطني'],
    knownLimitations: [
      'No real sample messages verified yet; the parser uses the generic Kuwait engine.',
      'Sender IDs and package names are unverified assumptions.',
      'NBK is moving customers to in-app push notifications: capture via Android notifications; iOS cannot read other apps\' notifications.',
    ],
  ),
  BankAdapter(
    id: 'boubyan',
    nameEn: 'Boubyan Bank',
    nameAr: 'بنك بوبيان',
    shortCode: 'BBY',
    brandColor: 0xFFB0005A,
    smsSenders: [EvidencedValue('Boubyan', _assume), EvidencedValue('BoubyanBank', _assume)],
    androidPackages: [],
    textHints: ['boubyan', 'بوبيان'],
    knownLimitations: [
      'No real sample messages verified yet; the parser uses the generic Kuwait engine.',
      'Sender IDs and package names are unverified assumptions.',
      'Alerts may arrive via Apple Messages for Business; whether the Shortcuts Message trigger fires for them is unverified.',
    ],
  ),
  BankAdapter(
    id: 'gulfbank',
    nameEn: 'Gulf Bank',
    nameAr: 'بنك الخليج',
    shortCode: 'GB',
    brandColor: 0xFF0067B1,
    smsSenders: [EvidencedValue('GulfBank', _assume), EvidencedValue('Gulf Bank', _assume)],
    androidPackages: [],
    textHints: ['gulf bank', 'gulfbank', 'بنك الخليج'],
  ),
  BankAdapter(
    id: 'cbk',
    nameEn: 'Commercial Bank of Kuwait',
    nameAr: 'البنك التجاري الكويتي',
    shortCode: 'CBK',
    brandColor: 0xFFC8102E,
    smsSenders: [EvidencedValue('CBK', _assume)],
    androidPackages: [],
    textHints: ['commercial bank', 'cbk', 'التجاري'],
  ),
];

BankAdapter? bankById(String? id) {
  if (id == null) return null;
  for (final b in kuwaitBanks) {
    if (b.id == id) return b;
  }
  return null;
}

/// Best-effort bank detection from sender plus text. Returns null when unsure.
String? detectBank({String? sender, String? text}) {
  final s = (sender ?? '').toLowerCase().replaceAll(' ', '');
  if (s.isNotEmpty) {
    for (final b in kuwaitBanks) {
      for (final id in b.smsSenders) {
        if (s == id.value.toLowerCase().replaceAll(' ', '')) return b.id;
      }
    }
  }
  final t = (text ?? '').toLowerCase();
  String? hit;
  for (final b in kuwaitBanks) {
    for (final h in b.textHints) {
      // Short hints such as 'cbk' or 'nbk' must match a whole word.
      final re = RegExp('(^|[^a-z])${RegExp.escape(h)}([^a-z]|\$)');
      if (h.length <= 4 ? re.hasMatch(t) : t.contains(h)) {
        if (hit != null && hit != b.id) return null; // ambiguous
        hit = b.id;
      }
    }
  }
  return hit;
}

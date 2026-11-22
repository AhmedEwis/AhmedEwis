import '../money/money.dart';

/// Where a raw event came from.
enum SourceKind { sms, notification, shortcut, wallet, paste, share, csv, pdf, image, voice, manual }

/// A raw inbound event before parsing.
class RawEvent {
  final String text;
  final String? sender; // SMS sender id, notification title, or app package
  final String? packageName; // Android package of the notifying app
  final DateTime receivedAt; // UTC
  final SourceKind source;
  final String? sourceId; // platform id, e.g. notification key or shortcut run id
  /// Structured fields from Wallet automations; these are not free text.
  final Map<String, String>? fields;

  RawEvent({
    required this.text,
    required this.receivedAt,
    required this.source,
    this.sender,
    this.packageName,
    this.sourceId,
    this.fields,
  });
}

/// Financial meaning of a parsed event.
enum TxKind {
  purchase,
  income,
  salary,
  transferIn,
  transferOut,
  atmWithdrawal,
  fee,
  refund,
  reversal,
  cardPayment,
  installment,
  declined,
  otp,
  balanceOnly,
  promo,
  unknown,
}

enum TxStatus { posted, pending, declined }

class ParsedEvent {
  final TxKind kind;
  final TxStatus status;
  final Money? amount; // amount charged to the account, in the account currency when known
  final Money? originalAmount; // foreign-currency amount, when different from [amount]
  final Money? fee;
  final Money? balance; // bank-reported balance after the transaction
  final Money? available; // available balance or credit
  final String? merchant; // canonical merchant name
  final String? merchantRaw; // descriptor as written in the message
  final String? processor; // payment processor, e.g. MyFatoorah or KNET
  final String? cardLast4;
  final String? accountLast4;
  final String? bankId;
  final DateTime? occurredAt; // UTC, from message text
  final double confidence; // 0..1
  final String parserId;
  final String parserVersion;
  final List<String> notes; // explainability / limitations
  final Map<String, String> evidence; // field -> substring of source text

  const ParsedEvent({
    required this.kind,
    this.status = TxStatus.posted,
    this.amount,
    this.originalAmount,
    this.fee,
    this.balance,
    this.available,
    this.merchant,
    this.merchantRaw,
    this.processor,
    this.cardLast4,
    this.accountLast4,
    this.bankId,
    this.occurredAt,
    required this.confidence,
    required this.parserId,
    required this.parserVersion,
    this.notes = const [],
    this.evidence = const {},
  });

  bool get isFinancial =>
      kind != TxKind.otp && kind != TxKind.promo && kind != TxKind.balanceOnly && kind != TxKind.unknown;

  /// Whether the event should go to the review inbox instead of the ledger.
  bool get needsReview => isFinancial && (amount == null || confidence < 0.6);

  ParsedEvent copyWith({String? merchant, String? bankId, double? confidence, List<String>? notes}) =>
      ParsedEvent(
        kind: kind,
        status: status,
        amount: amount,
        originalAmount: originalAmount,
        fee: fee,
        balance: balance,
        available: available,
        merchant: merchant ?? this.merchant,
        merchantRaw: merchantRaw,
        processor: processor,
        cardLast4: cardLast4,
        accountLast4: accountLast4,
        bankId: bankId ?? this.bankId,
        occurredAt: occurredAt,
        confidence: confidence ?? this.confidence,
        parserId: parserId,
        parserVersion: parserVersion,
        notes: notes ?? this.notes,
        evidence: evidence,
      );

  @override
  String toString() =>
      'ParsedEvent($kind/$status amount=$amount orig=$originalAmount merchant=$merchant card=$cardLast4 bal=$balance conf=${confidence.toStringAsFixed(2)})';
}

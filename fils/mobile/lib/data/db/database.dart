import 'package:drift/drift.dart';

part 'database.g.dart';

/// Columns shared by every synced entity.
mixin SyncColumns on Table {
  IntColumn get version => integer().withDefault(const Constant(0))(); // last known server version
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()(); // soft delete / tombstone
}

@DataClassName('AccountRow')
class Accounts extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // bank|card|cash|wallet|loan|savings
  TextColumn get institutionId => text().nullable()();
  TextColumn get currency => text().withLength(min: 3, max: 3)();
  TextColumn get maskLast4 => text().nullable()();
  BoolColumn get isLiability => boolean().withDefault(const Constant(false))();
  IntColumn get creditLimitMinor => integer().nullable()();
  IntColumn get openingBalanceMinor => integer().withDefault(const Constant(0))();
  DateTimeColumn get openingBalanceDate => dateTime()();
  IntColumn get reportedBalanceMinor => integer().nullable()();
  IntColumn get reportedAvailableMinor => integer().nullable()();
  DateTimeColumn get reportedBalanceAt => dateTime().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  IntColumn get color => integer().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  BoolColumn get includeInNetWorth => boolean().withDefault(const Constant(true))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TxRow')
class Transactions extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get accountId => text().references(Accounts, #id)();
  TextColumn get kind => text()(); // expense|income|transfer|refund|adjustment
  TextColumn get status => text()(); // posted|pending|declined|void
  IntColumn get amountMinor => integer()(); // always >= 0; direction comes from kind
  TextColumn get currency => text().withLength(min: 3, max: 3)();
  TextColumn get counterAccountId => text().nullable().references(Accounts, #id)();
  IntColumn get counterAmountMinor => integer().nullable()();
  IntColumn get originalAmountMinor => integer().nullable()();
  TextColumn get originalCurrency => text().nullable()();
  TextColumn get fxRate => text().nullable()(); // decimal string
  TextColumn get fxSource => text().nullable()(); // bank_billed|manual|provider:<name>
  TextColumn get merchant => text().nullable()();
  TextColumn get merchantRaw => text().nullable()();
  TextColumn get processor => text().nullable()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get receivedAt => dateTime().nullable()();
  TextColumn get source => text()();
  TextColumn get sourceEventId => text().nullable()();
  TextColumn get refundOfId => text().nullable()();
  TextColumn get transferGroupId => text().nullable()();
  TextColumn get recurringId => text().nullable()();
  TextColumn get parserId => text().nullable()();
  TextColumn get parserVersion => text().nullable()();
  RealColumn get confidence => real().nullable()(); // diagnostic only, never money
  BoolColumn get needsReview => boolean().withDefault(const Constant(false))();
  TextColumn get householdId => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SplitRow')
class TransactionSplits extends Table {
  TextColumn get id => text()();
  TextColumn get transactionId => text().references(Transactions, #id)();
  TextColumn get categoryId => text()();
  IntColumn get amountMinor => integer()();
  TextColumn get note => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

/// Raw inbound events (SMS, notifications, shortcuts and so on) with provenance.
/// Raw text is stored only while it needs review, and only encrypted (the database file is
/// encrypted). It is purged after [purgeAfter].
@DataClassName('SourceEventRow')
class SourceEvents extends Table {
  TextColumn get id => text()();
  TextColumn get source => text()();
  TextColumn get sender => text().nullable()();
  TextColumn get packageName => text().nullable()();
  TextColumn get platformId => text().nullable()();
  TextColumn get textHash => text()(); // sha256 of normalized text
  TextColumn get rawText => text().nullable()(); // only kept for review/retention window
  DateTimeColumn get receivedAt => dateTime()();
  TextColumn get status => text()(); // posted|review|ignored|duplicate|failed|queued|merged
  TextColumn get kind => text().nullable()();
  TextColumn get parserId => text().nullable()();
  TextColumn get parserVersion => text().nullable()();
  TextColumn get transactionId => text().nullable()();
  TextColumn get bankId => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get purgeAfter => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CategoryRow')
class Categories extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get nameEn => text()();
  TextColumn get nameAr => text()();
  TextColumn get icon => text()();
  IntColumn get color => integer()();
  TextColumn get kind => text()(); // expense|income
  TextColumn get parentId => text().nullable()();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MerchantAliasRow')
class MerchantAliases extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get pattern => text()();
  TextColumn get merchant => text()();
  TextColumn get categoryId => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('BudgetRow')
class Budgets extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get categoryId => text().nullable()(); // null = overall budget
  IntColumn get amountMinor => integer()();
  TextColumn get currency => text()();
  TextColumn get period => text()(); // cycle|monthly|weekly
  BoolColumn get rollover => boolean().withDefault(const Constant(false))();
  TextColumn get alertThresholds => text().withDefault(const Constant('80,100'))();
  DateTimeColumn get startDate => dateTime()();
  TextColumn get householdId => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('GoalRow')
class Goals extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get emoji => text().nullable()();
  IntColumn get targetMinor => integer()();
  TextColumn get currency => text()();
  DateTimeColumn get targetDate => dateTime().nullable()();
  TextColumn get accountId => text().nullable()();
  IntColumn get plannedMonthlyMinor => integer().nullable()();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('GoalContributionRow')
class GoalContributions extends Table {
  TextColumn get id => text()();
  TextColumn get goalId => text().references(Goals, #id)();
  IntColumn get amountMinor => integer()(); // negative = withdrawal
  DateTimeColumn get date => dateTime()();
  TextColumn get note => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('RecurringRow')
class Recurrings extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // subscription|rent|installment|bill|salary|other
  IntColumn get amountMinor => integer()();
  TextColumn get currency => text()();
  TextColumn get accountId => text().nullable()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get cadence => text()(); // weekly|monthly|yearly
  IntColumn get interval => integer().withDefault(const Constant(1))();
  DateTimeColumn get anchorDate => dateTime()();
  DateTimeColumn get nextDueDate => dateTime()();
  IntColumn get totalOccurrences => integer().nullable()();
  IntColumn get completedOccurrences => integer().withDefault(const Constant(0))();
  TextColumn get merchantPattern => text().nullable()();
  TextColumn get status => text()(); // suggested|active|paused|ended
  IntColumn get reminderDaysBefore => integer().withDefault(const Constant(1))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AssetRow')
class Assets extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // gold|property|vehicle|investment|deposit|cash|other|loan
  BoolColumn get isLiability => boolean().withDefault(const Constant(false))();
  IntColumn get valueMinor => integer()();
  TextColumn get currency => text()();
  DateTimeColumn get valuationDate => dateTime()();
  TextColumn get valuationSource => text().withDefault(const Constant('manual'))();
  TextColumn get linkedAccountId => text().nullable()();
  TextColumn get note => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

/// Durable sync outbox: one row per local change awaiting upload.
@DataClassName('OutboxRow')
class Outbox extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  TextColumn get state => text().withDefault(const Constant('pending'))(); // pending|conflict
}

/// Local audit trail for corrections, undo and imports.
@DataClassName('AuditRow')
class AuditEvents extends Table {
  IntColumn get seq => integer().autoIncrement()();
  DateTimeColumn get at => dateTime()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get action => text()(); // create|update|delete|restore|merge|import
  TextColumn get beforeJson => text().nullable()();
  TextColumn get afterJson => text().nullable()();
}

@DataClassName('ConsentRow')
class LocalConsents extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  BoolColumn get granted => boolean()();
  TextColumn get policyVersion => text()();
  DateTimeColumn get at => dateTime()();
  BoolColumn get uploaded => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('FxRateRow')
class FxRates extends Table {
  TextColumn get base => text()();
  TextColumn get quote => text()();
  TextColumn get rate => text()(); // decimal string: 1 base = rate quote
  DateTimeColumn get asOf => dateTime()();
  TextColumn get source => text()(); // manual|bank_billed|provider:<name>
  @override
  Set<Column> get primaryKey => {base, quote, asOf};
}

@DriftDatabase(tables: [
  Accounts,
  Transactions,
  TransactionSplits,
  SourceEvents,
  Categories,
  MerchantAliases,
  Budgets,
  Goals,
  GoalContributions,
  Recurrings,
  Assets,
  Settings,
  Outbox,
  AuditEvents,
  LocalConsents,
  FxRates,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement('CREATE INDEX idx_tx_occurred ON transactions(occurred_at)');
          await customStatement('CREATE INDEX idx_tx_account ON transactions(account_id, occurred_at)');
          await customStatement('CREATE INDEX idx_tx_review ON transactions(needs_review)');
          await customStatement('CREATE UNIQUE INDEX idx_src_platform ON source_events(source, platform_id) WHERE platform_id IS NOT NULL');
          await customStatement('CREATE INDEX idx_src_hash ON source_events(text_hash)');
          await customStatement('CREATE INDEX idx_outbox_entity ON outbox(entity, entity_id)');
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

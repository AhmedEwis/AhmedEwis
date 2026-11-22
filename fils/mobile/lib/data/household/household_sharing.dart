/// Household sharing: explicit, per-record, revocable.
///
/// Privacy model:
/// - Nothing is shared automatically. The user picks a transaction or budget, sees exactly
///   which fields will be shared, and confirms.
/// - A share is a *copy* scoped to the household. It holds only date, amount, currency,
///   merchant, category and (opt-in) note, and points to a per-member household placeholder
///   account ("<name>'s shared items"). The real account, card digits, raw message text,
///   balances, parser data and source ids are never shared.
/// - Copies live in [SharedRecords], separate from the personal ledger, so sharing never
///   changes personal balances or totals.
/// - Revoking tombstones the copy on the server (members' devices delete it on next pull).
///   Leaving a household or being removed purges its records locally.
/// - Viewers can read but not share. The server enforces this too.
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/ledger/ledger.dart';
import '../db/database.dart';
import '../store.dart';

class SharedEntities {
  static const account = 'shared_account';
  static const transaction = 'shared_transaction';
  static const budget = 'shared_budget';

  /// Sync envelope entity for a shared outbox entity.
  static String serverEntity(String outboxEntity) => outboxEntity.replaceFirst('shared_', '');
  static bool isShared(String outboxEntity) => outboxEntity.startsWith('shared_');
}

class HouseholdInfo {
  final String id;
  final String name;
  final String myRole; // owner | member | viewer
  const HouseholdInfo(this.id, this.name, this.myRole);
  bool get canShare => myRole == 'owner' || myRole == 'member';
}

/// The exact fields a transaction share exposes (shown in the consent dialog and tested).
Map<String, dynamic> sharedTransactionPayload({
  required String id,
  required String accountId,
  required TxRow t,
  required bool includeNote,
}) =>
    {
      'id': id,
      'account_id': accountId,
      'kind': t.kind == TxKinds.refund ? TxKinds.refund : (t.kind == TxKinds.income ? TxKinds.income : TxKinds.expense),
      'status': t.status == TxStatuses.pending ? TxStatuses.pending : TxStatuses.posted,
      'amount_minor': t.amountMinor,
      'currency': t.currency,
      'merchant': t.merchant,
      'category_id': t.categoryId,
      'note': includeNote ? t.note : null,
      'occurred_at': t.occurredAt.toUtc().toIso8601String(),
      'source': 'manual',
      'needs_review': false,
      'splits': <Map<String, dynamic>>[],
    };

class HouseholdSharing {
  final FinanceStore store;
  HouseholdSharing(this.store);

  AppDatabase get db => store.db;

  Future<void> _enqueue(String entity, String id) async {
    final exists = await (db.select(db.outbox)..where((o) => o.entity.equals(entity) & o.entityId.equals(id) & o.state.equals('pending'))).getSingleOrNull();
    if (exists == null) await db.into(db.outbox).insert(OutboxCompanion.insert(entity: entity, entityId: id, createdAt: store.now));
  }

  /// Cache of the user's households (refreshed from the API by the UI).
  Future<List<HouseholdInfo>> cachedHouseholds() async {
    final raw = await store.getSetting('households_cache');
    if (raw == null) return const [];
    return [for (final h in (jsonDecode(raw) as List).cast<Map>()) HouseholdInfo(h['id'] as String, h['name'] as String? ?? '', h['my_role'] as String? ?? 'viewer')];
  }

  /// Save the latest membership list and purge local copies of households the user no
  /// longer belongs to (left or removed).
  Future<int> updateMemberships(List<HouseholdInfo> households) async {
    await store.setSetting('households_cache', jsonEncode([for (final h in households) {'id': h.id, 'name': h.name, 'my_role': h.myRole}]));
    final valid = households.map((h) => h.id).toSet();
    final stale = await (db.select(db.sharedRecords)..where((r) => r.householdId.isNotIn(valid))).get();
    for (final r in stale) {
      await (db.delete(db.sharedRecords)..where((x) => x.id.equals(r.id))).go();
      await (db.delete(db.outbox)..where((o) => o.entityId.equals(r.id))).go();
    }
    return stale.length;
  }

  /// My placeholder account inside a household (created once per household).
  Future<SharedRow> _placeholderAccount(String householdId, String displayName) async {
    final mine = await (db.select(db.sharedRecords)
          ..where((r) => r.householdId.equals(householdId) & r.entity.equals('account') & r.ownerUserId.isNull() & r.deletedAt.isNull()))
        .getSingleOrNull();
    if (mine != null) return mine;
    final id = newId();
    final payload = {
      'id': id,
      'name': '$displayName — shared items',
      'kind': 'wallet',
      'currency': await store.baseCurrency(),
      'is_liability': false,
      'opening_balance_minor': 0,
      'opening_balance_date': store.now.toIso8601String().substring(0, 10),
      'archived': false,
      'sort_order': 0,
      'is_default': false,
      'include_in_net_worth': false,
    };
    await db.into(db.sharedRecords).insert(SharedRecordsCompanion.insert(id: id, entity: 'account', householdId: householdId, payloadJson: jsonEncode(payload), updatedAt: store.now));
    await _enqueue(SharedEntities.account, id);
    return (await (db.select(db.sharedRecords)..where((r) => r.id.equals(id))).getSingle());
  }

  Future<SharedRow?> existingShare(String originalId, String householdId) => (db.select(db.sharedRecords)
        ..where((r) => r.originalId.equals(originalId) & r.householdId.equals(householdId) & r.deletedAt.isNull()))
      .getSingleOrNull();

  Future<SharedRow> shareTransaction(String txId, HouseholdInfo household, {required bool includeNote, String displayName = 'Member'}) async {
    if (!household.canShare) throw StateError('viewers cannot share');
    final t = await store.transaction(txId);
    if (t == null || t.deletedAt != null) throw StateError('transaction not found');
    if (t.kind == TxKinds.transfer || t.kind == TxKinds.adjustUp || t.kind == TxKinds.adjustDown) {
      throw ArgumentError('transfers and adjustments cannot be shared');
    }
    final prior = await existingShare(txId, household.id);
    if (prior != null) return prior; // idempotent
    final acct = await _placeholderAccount(household.id, displayName);
    final id = newId();
    final payload = sharedTransactionPayload(id: id, accountId: acct.id, t: t, includeNote: includeNote);
    await db.into(db.sharedRecords).insert(SharedRecordsCompanion.insert(
          id: id,
          entity: 'transaction',
          householdId: household.id,
          originalId: Value(txId),
          payloadJson: jsonEncode(payload),
          updatedAt: store.now,
        ));
    await _enqueue(SharedEntities.transaction, id);
    return (await (db.select(db.sharedRecords)..where((r) => r.id.equals(id))).getSingle());
  }

  Future<SharedRow> shareBudget(String budgetId, HouseholdInfo household) async {
    if (!household.canShare) throw StateError('viewers cannot share');
    final b = await (db.select(db.budgets)..where((x) => x.id.equals(budgetId))).getSingleOrNull();
    if (b == null) throw StateError('budget not found');
    final prior = await existingShare(budgetId, household.id);
    if (prior != null) return prior;
    final id = newId();
    final payload = {
      'id': id,
      'category_id': b.categoryId,
      'amount_minor': b.amountMinor,
      'currency': b.currency,
      'period': b.period == 'cycle' ? 'monthly' : b.period, // salary cycles are personal
      'rollover': false,
      'alert_thresholds': b.alertThresholds.split(',').map(int.tryParse).whereType<int>().toList(),
      'start_date': store.now.toIso8601String().substring(0, 10),
    };
    await db.into(db.sharedRecords).insert(SharedRecordsCompanion.insert(
          id: id, entity: 'budget', householdId: household.id, originalId: Value(budgetId), payloadJson: jsonEncode(payload), updatedAt: store.now));
    await _enqueue(SharedEntities.budget, id);
    return (await (db.select(db.sharedRecords)..where((r) => r.id.equals(id))).getSingle());
  }

  /// Revoke a share I created: tombstone locally and on the server.
  Future<void> revoke(String sharedId) async {
    final r = await (db.select(db.sharedRecords)..where((x) => x.id.equals(sharedId))).getSingleOrNull();
    if (r == null) return;
    if (r.ownerUserId != null) throw StateError('only the creator can revoke a share');
    await (db.update(db.sharedRecords)..where((x) => x.id.equals(sharedId))).write(SharedRecordsCompanion(deletedAt: Value(store.now), updatedAt: Value(store.now)));
    await _enqueue('shared_${r.entity}', sharedId);
  }

  Stream<List<SharedRow>> watch(String householdId) => (db.select(db.sharedRecords)
        ..where((r) => r.householdId.equals(householdId) & r.deletedAt.isNull())
        ..orderBy([(r) => OrderingTerm(expression: r.updatedAt, mode: OrderingMode.desc)]))
      .watch();

  Stream<Set<String>> watchSharedOriginals() =>
      (db.select(db.sharedRecords)..where((r) => r.deletedAt.isNull() & r.originalId.isNotNull())).watch().map((rows) => rows.map((r) => r.originalId!).toSet());

  /// Spending total of a household's shared transactions, per currency, for a period.
  static Map<String, int> householdSpending(List<SharedRow> rows, DateTime from, DateTime to, {String? categoryId}) {
    final out = <String, int>{};
    for (final r in rows.where((r) => r.entity == 'transaction' && r.deletedAt == null)) {
      final p = jsonDecode(r.payloadJson) as Map<String, dynamic>;
      final at = DateTime.parse(p['occurred_at'] as String);
      if (at.isBefore(from) || !at.isBefore(to)) continue;
      if (categoryId != null && p['category_id'] != categoryId) continue;
      final sign = p['kind'] == 'refund' ? -1 : (p['kind'] == 'expense' ? 1 : 0);
      final cur = p['currency'] as String;
      out[cur] = (out[cur] ?? 0) + sign * (p['amount_minor'] as num).toInt();
    }
    return out;
  }
}

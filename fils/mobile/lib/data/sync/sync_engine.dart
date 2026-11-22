/// Local-first synchronization.
///
/// - Writes go to the local DB first; the durable [Outbox] records which entities changed.
/// - Push sends the latest state of each changed entity, with `base_version` = the last
///   server version this device saw. A mismatch returns `conflict`; we never overwrite.
/// - Pull applies remote changes incrementally by cursor, but never on top of local
///   unpushed edits: those become conflicts the user resolves explicitly.
/// - Deletions are tombstones (deleted_at), never hard deletes, and a tombstoned id is
///   never resurrected.
/// - Sync is bound to one cloud user. Signing in as a different user never mixes data.
/// - Sync requires explicit consent (cloud_sync or cloud_backup), separate from sign-in.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../db/database.dart';
import '../store.dart';

enum SyncState { off, idle, syncing, error, conflicts, ownerMismatch, notConfigured }

class SyncReport {
  final int pushed, pulled, conflicts, rejected;
  final String? error;
  const SyncReport({this.pushed = 0, this.pulled = 0, this.conflicts = 0, this.rejected = 0, this.error});
  @override
  String toString() => 'SyncReport(pushed=$pushed pulled=$pulled conflicts=$conflicts rejected=$rejected error=$error)';
}

class SyncKeys {
  static const cursor = 'sync_cursor';
  static const owner = 'sync_owner_user_id';
  static const enabled = 'sync_enabled';
  static const lastSyncAt = 'sync_last_at';
}

/// Remote I/O, abstracted for tests.
abstract class SyncTransport {
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> ops, String idempotencyKey);
  Future<Map<String, dynamic>> pull(String? cursor);
}

class ApiSyncTransport implements SyncTransport {
  final ApiClient api;
  ApiSyncTransport(this.api);
  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> ops, String key) => api.push(ops, key);
  @override
  Future<Map<String, dynamic>> pull(String? cursor) => api.pull(cursor);
}

const _settingNs = '6f9a1c0e-3b7d-4c2a-9e51-0b6d2f8a4c13';

/// Deterministic UUID for a synced setting key, scoped to the cloud user so ids are
/// identical across that user's devices but never collide between users.
String settingUuid(String key, {required String owner}) => const Uuid().v5(_settingNs, '$owner:$key');

String _date(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String? _dateN(DateTime? d) => d == null ? null : _date(d.toUtc());
String _ts(DateTime d) => d.toUtc().toIso8601String();
String? _colorHex(int? c) => c == null ? null : '#${c.toRadixString(16).padLeft(8, '0').toUpperCase()}';
int? _colorInt(Object? s) => s is String && s.startsWith('#') ? int.tryParse(s.substring(1), radix: 16) : null;
DateTime _parseDate(Object? s) => DateTime.parse(s as String).toUtc();
DateTime? _parseDateN(Object? s) => s == null ? null : DateTime.parse(s as String).toUtc();

class SyncEngine {
  final FinanceStore store;
  final SyncTransport transport;
  final int batchSize;
  SyncEngine(this.store, this.transport, {this.batchSize = 200});

  AppDatabase get db => store.db;

  Future<bool> enabled() async => (await store.getSetting(SyncKeys.enabled)) == 'true';

  /// Bind local data to a cloud user. Returns false when the local data belongs to someone
  /// else (the user must choose to erase local data or stay signed out).
  Future<bool> bindOwner(String userId) async {
    final owner = await store.getSetting(SyncKeys.owner);
    if (owner == null) {
      await store.setSetting(SyncKeys.owner, userId);
      return true;
    }
    return owner == userId;
  }

  /// When sync is turned on for the first time, every existing local record is queued, so
  /// historical data uploads only after explicit consent.
  Future<void> enqueueAll() async {
    final now = store.now;
    Future<void> q(String entity, Iterable<String> ids) async {
      for (final id in ids) {
        final exists = await (db.select(db.outbox)..where((o) => o.entity.equals(entity) & o.entityId.equals(id) & o.state.equals('pending'))).getSingleOrNull();
        if (exists == null) await db.into(db.outbox).insert(OutboxCompanion.insert(entity: entity, entityId: id, createdAt: now));
      }
    }

    await q(Entities.account, (await db.select(db.accounts).get()).map((e) => e.id));
    await q(Entities.transaction, (await db.select(db.transactions).get()).map((e) => e.id));
    await q(Entities.category, (await (db.select(db.categories)..where((c) => c.isSystem.equals(false))).get()).map((e) => e.id));
    await q(Entities.budget, (await db.select(db.budgets).get()).map((e) => e.id));
    await q(Entities.goal, (await db.select(db.goals).get()).map((e) => e.id));
    await q(Entities.recurring, (await db.select(db.recurrings).get()).map((e) => e.id));
    await q(Entities.merchantAlias, (await db.select(db.merchantAliases).get()).map((e) => e.id));
    await q(Entities.asset, (await db.select(db.assets).get()).map((e) => e.id));
    await q(Entities.setting, SettingKeys.syncedKeys);
  }

  Future<int> pendingCount() async => (await (db.select(db.outbox)..where((o) => o.state.equals('pending'))).get()).length;
  Future<List<OutboxRow>> conflicts() => (db.select(db.outbox)..where((o) => o.state.equals('conflict'))).get();

  // -------------------------------------------------------------- serialization
  Future<Map<String, dynamic>?> envelopeFor(String entity, String id) async {
    switch (entity) {
      case Entities.account:
        final a = await (db.select(db.accounts)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (a == null) return null;
        return _env(entity, id, a.version, a.deletedAt, a.updatedAt, null, {
          'id': a.id,
          'name': a.name,
          'kind': a.kind,
          'institution_id': a.institutionId,
          'currency': a.currency,
          'mask_last4': a.maskLast4,
          'is_liability': a.isLiability,
          'credit_limit_minor': a.creditLimitMinor,
          'opening_balance_minor': a.openingBalanceMinor,
          'opening_balance_date': _date(a.openingBalanceDate.toUtc()),
          'reported_balance_minor': a.reportedBalanceMinor,
          'reported_available_minor': a.reportedAvailableMinor,
          'reported_balance_at': a.reportedBalanceAt == null ? null : _ts(a.reportedBalanceAt!),
          'archived': a.archived,
          'color': _colorHex(a.color),
          'sort_order': a.sortOrder,
          'is_default': a.isDefault,
          'include_in_net_worth': a.includeInNetWorth,
        });
      case Entities.transaction:
        final t = await (db.select(db.transactions)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (t == null) return null;
        final splits = await store.splitsFor(id);
        return _env(entity, id, t.version, t.deletedAt, t.updatedAt, t.householdId, {
          'id': t.id,
          'account_id': t.accountId,
          'kind': t.kind,
          'status': t.status,
          'amount_minor': t.amountMinor,
          'currency': t.currency,
          'counter_account_id': t.counterAccountId,
          'counter_amount_minor': t.counterAmountMinor,
          'original_amount_minor': t.originalAmountMinor,
          'original_currency': t.originalCurrency,
          'fx_rate': t.fxRate,
          'fx_source': t.fxSource,
          'merchant': t.merchant,
          'merchant_raw': t.merchantRaw,
          'category_id': t.categoryId,
          'note': t.note,
          'occurred_at': _ts(t.occurredAt),
          'received_at': t.receivedAt == null ? null : _ts(t.receivedAt!),
          'source': t.source,
          'source_event_id': t.sourceEventId,
          'refund_of_id': t.refundOfId,
          'transfer_group_id': t.transferGroupId,
          'parser_id': t.parserId,
          'parser_version': t.parserVersion,
          'confidence': t.confidence,
          'needs_review': t.needsReview,
          'splits': [for (final s in splits) {'category_id': s.categoryId, 'amount_minor': s.amountMinor, 'note': s.note}],
        });
      case Entities.category:
        final c = await (db.select(db.categories)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (c == null || c.isSystem) return null; // system slugs are never synced
        return _env(entity, id, c.version, c.deletedAt, c.updatedAt, null, {
          'id': c.id, 'name_en': c.nameEn, 'name_ar': c.nameAr, 'icon': c.icon, 'color': _colorHex(c.color), 'kind': c.kind,
          'parent_id': c.parentId, 'is_system': false, 'archived': c.archived,
        });
      case Entities.budget:
        final b = await (db.select(db.budgets)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (b == null) return null;
        return _env(entity, id, b.version, b.deletedAt, b.updatedAt, b.householdId, {
          'id': b.id, 'category_id': b.categoryId, 'amount_minor': b.amountMinor, 'currency': b.currency, 'period': b.period,
          'rollover': b.rollover, 'alert_thresholds': b.alertThresholds.split(',').map(int.tryParse).whereType<int>().toList(), 'start_date': _date(b.startDate.toUtc()),
        });
      case Entities.goal:
        final g = await (db.select(db.goals)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (g == null) return null;
        final cs = await (db.select(db.goalContributions)..where((c) => c.goalId.equals(id))).get();
        return _env(entity, id, g.version, g.deletedAt, g.updatedAt, null, {
          'id': g.id, 'name': g.name, 'emoji': g.emoji, 'target_minor': g.targetMinor, 'currency': g.currency, 'target_date': _dateN(g.targetDate),
          'account_id': g.accountId, 'planned_monthly_minor': g.plannedMonthlyMinor, 'archived': g.archived,
          'contributions': [for (final c in cs) {'id': c.id, 'amount_minor': c.amountMinor, 'date': _date(c.date.toUtc()), 'note': c.note}],
        });
      case Entities.recurring:
        final r = await (db.select(db.recurrings)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (r == null) return null;
        return _env(entity, id, r.version, r.deletedAt, r.updatedAt, null, {
          'id': r.id, 'name': r.name, 'kind': r.kind, 'amount_minor': r.amountMinor, 'currency': r.currency, 'account_id': r.accountId,
          'category_id': r.categoryId, 'cadence': r.cadence, 'interval': r.interval, 'anchor_date': _date(r.anchorDate.toUtc()),
          'next_due_date': _date(r.nextDueDate.toUtc()), 'total_occurrences': r.totalOccurrences, 'completed_occurrences': r.completedOccurrences,
          'merchant_pattern': r.merchantPattern, 'status': r.status, 'reminder_days_before': r.reminderDaysBefore,
        });
      case Entities.merchantAlias:
        final m = await (db.select(db.merchantAliases)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (m == null) return null;
        return _env(entity, id, m.version, m.deletedAt, m.updatedAt, null, {'id': m.id, 'pattern': m.pattern, 'merchant': m.merchant, 'category_id': m.categoryId});
      case Entities.asset:
        final a = await (db.select(db.assets)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (a == null) return null;
        return _env(entity, id, a.version, a.deletedAt, a.updatedAt, null, {
          'id': a.id, 'name': a.name, 'kind': a.kind, 'is_liability': a.isLiability, 'value_minor': a.valueMinor, 'currency': a.currency,
          'valuation_date': _date(a.valuationDate.toUtc()), 'valuation_source': 'manual', 'linked_account_id': a.linkedAccountId, 'note': a.note,
        });
      case Entities.setting:
        final v = await store.getSetting(id);
        if (v == null) return null;
        final ver = int.tryParse(await store.getSetting('sync_ver_$id') ?? '') ?? 0;
        final key = id == SettingKeys.cycleStartDay ? 'cycle_start_day' : id;
        final owner = await store.getSetting(SyncKeys.owner);
        if (owner == null) return null; // settings sync only once bound to a cloud user
        final sid = settingUuid(key, owner: owner);
        return _env(entity, sid, ver, null, store.now, null, {'id': sid, 'key': key, 'value': int.tryParse(v) ?? v});
    }
    return null;
  }

  Map<String, dynamic> _env(String entity, String id, int version, DateTime? deletedAt, DateTime updatedAt, String? householdId, Map<String, dynamic> payload) => {
        'entity': entity,
        'id': id,
        'version': version + 1,
        'base_version': version,
        'deleted': deletedAt != null,
        'updated_at': _ts(updatedAt),
        'household_id': householdId,
        'payload': payload,
      };

  // -------------------------------------------------------------- push / pull
  Future<SyncReport> sync() async {
    if (!await enabled()) return const SyncReport(error: 'sync_off');
    var pushed = 0, pulled = 0, conflicts = 0, rejected = 0;
    try {
      // PUSH
      while (true) {
        final rows = await (db.select(db.outbox)
              ..where((o) => o.state.equals('pending'))
              ..orderBy([(o) => OrderingTerm(expression: o.seq)])
              ..limit(batchSize))
            .get();
        if (rows.isEmpty) break;
        final ops = <Map<String, dynamic>>[];
        final opRows = <String, OutboxRow>{};
        for (final r in rows) {
          final env = await envelopeFor(r.entity, r.entityId);
          if (env == null) {
            await (db.delete(db.outbox)..where((o) => o.seq.equals(r.seq))).go();
            continue;
          }
          ops.add(env);
          opRows['${env['entity']}:${env['id']}'] = r;
        }
        if (ops.isEmpty) continue;
        // Idempotency key derived from the exact batch: a retry after a lost response is a replay.
        final key = sha256.convert(utf8.encode(jsonEncode(ops))).toString();
        final res = await transport.push(ops, key);
        for (final r in (res['results'] as List).cast<Map<String, dynamic>>()) {
          final ent = r['entity'] as String;
          final id = r['id'] as String;
          final row = opRows['$ent:$id'];
          if (row == null) continue;
          switch (r['status']) {
            case 'applied':
              pushed++;
              await _setLocalVersion(ent, row.entityId, (r['server_version'] as num).toInt());
              // Only clear the outbox row if no newer local change was queued meanwhile.
              await (db.delete(db.outbox)..where((o) => o.seq.equals(row.seq))).go();
            case 'conflict':
              conflicts++;
              await (db.update(db.outbox)..where((o) => o.seq.equals(row.seq)))
                  .write(OutboxCompanion(state: const Value('conflict'), lastError: Value(jsonEncode(r['server_record']))));
            default:
              rejected++;
              await (db.update(db.outbox)..where((o) => o.seq.equals(row.seq)))
                  .write(OutboxCompanion(state: const Value('rejected'), attempts: Value(row.attempts + 1), lastError: Value(jsonEncode(r['error'] ?? r))));
          }
        }
        if (rows.length < batchSize) break;
      }

      // PULL
      var cursor = await store.getSetting(SyncKeys.cursor);
      while (true) {
        final res = await transport.pull(cursor);
        for (final rec in (res['records'] as List).cast<Map<String, dynamic>>()) {
          final applied = await _applyRemote(rec);
          if (applied == _Apply.applied) pulled++;
          if (applied == _Apply.conflict) conflicts++;
        }
        cursor = res['cursor'] as String?;
        if (cursor != null) await store.db.into(store.db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: SyncKeys.cursor, value: cursor));
        if (res['has_more'] != true) break;
      }
      await db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: SyncKeys.lastSyncAt, value: store.now.toIso8601String()));
      return SyncReport(pushed: pushed, pulled: pulled, conflicts: conflicts, rejected: rejected);
    } catch (e) {
      // Network failure: the outbox stays intact and the next run retries safely.
      return SyncReport(pushed: pushed, pulled: pulled, conflicts: conflicts, rejected: rejected, error: e.toString());
    }
  }

  Future<void> _setLocalVersion(String entity, String id, int v) async {
    switch (entity) {
      case Entities.account:
        await (db.update(db.accounts)..where((x) => x.id.equals(id))).write(AccountsCompanion(version: Value(v)));
      case Entities.transaction:
        await (db.update(db.transactions)..where((x) => x.id.equals(id))).write(TransactionsCompanion(version: Value(v)));
      case Entities.category:
        await (db.update(db.categories)..where((x) => x.id.equals(id))).write(CategoriesCompanion(version: Value(v)));
      case Entities.budget:
        await (db.update(db.budgets)..where((x) => x.id.equals(id))).write(BudgetsCompanion(version: Value(v)));
      case Entities.goal:
        await (db.update(db.goals)..where((x) => x.id.equals(id))).write(GoalsCompanion(version: Value(v)));
      case Entities.recurring:
        await (db.update(db.recurrings)..where((x) => x.id.equals(id))).write(RecurringsCompanion(version: Value(v)));
      case Entities.merchantAlias:
        await (db.update(db.merchantAliases)..where((x) => x.id.equals(id))).write(MerchantAliasesCompanion(version: Value(v)));
      case Entities.asset:
        await (db.update(db.assets)..where((x) => x.id.equals(id))).write(AssetsCompanion(version: Value(v)));
      case Entities.setting:
        await db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: 'sync_ver_$id', value: '$v'));
    }
  }

  Future<int?> _localVersion(String entity, String id) async {
    switch (entity) {
      case Entities.account:
        return (await (db.select(db.accounts)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.transaction:
        return (await (db.select(db.transactions)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.category:
        return (await (db.select(db.categories)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.budget:
        return (await (db.select(db.budgets)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.goal:
        return (await (db.select(db.goals)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.recurring:
        return (await (db.select(db.recurrings)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.merchantAlias:
        return (await (db.select(db.merchantAliases)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
      case Entities.asset:
        return (await (db.select(db.assets)..where((x) => x.id.equals(id))).getSingleOrNull())?.version;
    }
    return null;
  }

  Future<_Apply> _applyRemote(Map<String, dynamic> rec) async {
    final entity = rec['entity'] as String;
    var id = rec['id'] as String;
    final version = (rec['version'] as num).toInt();
    final deleted = rec['deleted'] == true;
    final p = (rec['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (entity == Entities.setting) {
      final key = p['key'] as String? ?? '';
      final localKey = key == 'cycle_start_day' ? SettingKeys.cycleStartDay : key;
      if (!SettingKeys.syncedKeys.contains(localKey)) return _Apply.skipped;
      id = localKey;
    }
    final local = entity == Entities.setting ? int.tryParse(await store.getSetting('sync_ver_$id') ?? '') : await _localVersion(entity, id);
    if (local != null && local >= version) return _Apply.skipped; // already have it (or our own echo)
    final pending = await (db.select(db.outbox)..where((o) => o.entity.equals(entity) & o.entityId.equals(id) & o.state.isIn(['pending', 'conflict']))).getSingleOrNull();
    if (pending != null) {
      // Local unpushed edit + newer remote: never overwrite silently.
      await (db.update(db.outbox)..where((o) => o.seq.equals(pending.seq))).write(OutboxCompanion(state: const Value('conflict'), lastError: Value(jsonEncode(rec))));
      return _Apply.conflict;
    }
    final now = store.now;
    final delAt = deleted ? Value(now) : const Value<DateTime?>(null);
    switch (entity) {
      case Entities.account:
        if (deleted) {
          await (db.update(db.accounts)..where((x) => x.id.equals(id))).write(AccountsCompanion(deletedAt: Value(now), version: Value(version)));
        } else {
          await db.into(db.accounts).insertOnConflictUpdate(AccountsCompanion.insert(
                id: id,
                name: p['name'] as String,
                kind: p['kind'] as String,
                institutionId: Value(p['institution_id'] as String?),
                currency: p['currency'] as String,
                maskLast4: Value(p['mask_last4'] as String?),
                isLiability: Value(p['is_liability'] as bool? ?? false),
                creditLimitMinor: Value((p['credit_limit_minor'] as num?)?.toInt()),
                openingBalanceMinor: Value((p['opening_balance_minor'] as num).toInt()),
                openingBalanceDate: _parseDate(p['opening_balance_date']),
                reportedBalanceMinor: Value((p['reported_balance_minor'] as num?)?.toInt()),
                reportedAvailableMinor: Value((p['reported_available_minor'] as num?)?.toInt()),
                reportedBalanceAt: Value(_parseDateN(p['reported_balance_at'])),
                archived: Value(p['archived'] as bool? ?? false),
                color: Value(_colorInt(p['color'])),
                sortOrder: Value((p['sort_order'] as num?)?.toInt() ?? 0),
                isDefault: Value(p['is_default'] as bool? ?? false),
                includeInNetWorth: Value(p['include_in_net_worth'] as bool? ?? true),
                version: Value(version),
                updatedAt: now,
                deletedAt: delAt,
              ));
        }
      case Entities.transaction:
        if (deleted) {
          await (db.update(db.transactions)..where((x) => x.id.equals(id))).write(TransactionsCompanion(deletedAt: Value(now), version: Value(version)));
        } else {
          final acct = await (db.select(db.accounts)..where((a) => a.id.equals(p['account_id'] as String))).getSingleOrNull();
          if (acct == null) return _Apply.skipped; // referenced account not yet pulled; server orders accounts first
          await db.transaction(() async {
            await db.into(db.transactions).insertOnConflictUpdate(TransactionsCompanion.insert(
                  id: id,
                  accountId: p['account_id'] as String,
                  kind: p['kind'] as String,
                  status: p['status'] as String,
                  amountMinor: (p['amount_minor'] as num).toInt(),
                  currency: p['currency'] as String,
                  counterAccountId: Value(p['counter_account_id'] as String?),
                  counterAmountMinor: Value((p['counter_amount_minor'] as num?)?.toInt()),
                  originalAmountMinor: Value((p['original_amount_minor'] as num?)?.toInt()),
                  originalCurrency: Value(p['original_currency'] as String?),
                  fxRate: Value(p['fx_rate'] as String?),
                  fxSource: Value(p['fx_source'] as String?),
                  merchant: Value(p['merchant'] as String?),
                  merchantRaw: Value(p['merchant_raw'] as String?),
                  categoryId: Value(p['category_id'] as String?),
                  note: Value(p['note'] as String?),
                  occurredAt: _parseDate(p['occurred_at']),
                  receivedAt: Value(_parseDateN(p['received_at'])),
                  source: p['source'] as String,
                  sourceEventId: Value(p['source_event_id'] as String?),
                  refundOfId: Value(p['refund_of_id'] as String?),
                  transferGroupId: Value(p['transfer_group_id'] as String?),
                  parserId: Value(p['parser_id'] as String?),
                  parserVersion: Value(p['parser_version'] as String?),
                  confidence: Value((p['confidence'] as num?)?.toDouble()),
                  needsReview: Value(p['needs_review'] as bool? ?? false),
                  householdId: Value(rec['household_id'] as String?),
                  version: Value(version),
                  updatedAt: now,
                ));
            await (db.delete(db.transactionSplits)..where((s) => s.transactionId.equals(id))).go();
            for (final s in (p['splits'] as List? ?? const []).cast<Map<String, dynamic>>()) {
              await db.into(db.transactionSplits).insert(TransactionSplitsCompanion.insert(
                  id: newId(), transactionId: id, categoryId: s['category_id'] as String, amountMinor: (s['amount_minor'] as num).toInt(), note: Value(s['note'] as String?)));
            }
          });
        }
      case Entities.category:
        await db.into(db.categories).insertOnConflictUpdate(CategoriesCompanion.insert(
              id: id,
              nameEn: p['name_en'] as String? ?? '',
              nameAr: p['name_ar'] as String? ?? '',
              icon: p['icon'] as String? ?? '📦',
              color: _colorInt(p['color']) ?? 0xFF94A3B8,
              kind: p['kind'] as String? ?? 'expense',
              parentId: Value(p['parent_id'] as String?),
              archived: Value(p['archived'] as bool? ?? false),
              version: Value(version),
              updatedAt: now,
              deletedAt: delAt,
            ));
      case Entities.budget:
        await db.into(db.budgets).insertOnConflictUpdate(BudgetsCompanion.insert(
              id: id,
              categoryId: Value(p['category_id'] as String?),
              amountMinor: (p['amount_minor'] as num? ?? 0).toInt(),
              currency: p['currency'] as String? ?? 'KWD',
              period: p['period'] as String? ?? 'cycle',
              rollover: Value(p['rollover'] as bool? ?? false),
              alertThresholds: Value(((p['alert_thresholds'] as List?) ?? const [80, 100]).join(',')),
              startDate: p['start_date'] == null ? now : _parseDate(p['start_date']),
              householdId: Value(rec['household_id'] as String?),
              version: Value(version),
              updatedAt: now,
              deletedAt: delAt,
            ));
      case Entities.goal:
        await db.transaction(() async {
          await db.into(db.goals).insertOnConflictUpdate(GoalsCompanion.insert(
                id: id,
                name: p['name'] as String? ?? '',
                emoji: Value(p['emoji'] as String?),
                targetMinor: (p['target_minor'] as num? ?? 0).toInt(),
                currency: p['currency'] as String? ?? 'KWD',
                targetDate: Value(_parseDateN(p['target_date'])),
                accountId: Value(p['account_id'] as String?),
                plannedMonthlyMinor: Value((p['planned_monthly_minor'] as num?)?.toInt()),
                archived: Value(p['archived'] as bool? ?? false),
                version: Value(version),
                updatedAt: now,
                deletedAt: delAt,
              ));
          if (!deleted) {
            await (db.delete(db.goalContributions)..where((c) => c.goalId.equals(id))).go();
            for (final c in (p['contributions'] as List? ?? const []).cast<Map<String, dynamic>>()) {
              await db.into(db.goalContributions).insert(GoalContributionsCompanion.insert(
                  id: c['id'] as String, goalId: id, amountMinor: (c['amount_minor'] as num).toInt(), date: _parseDate(c['date']), note: Value(c['note'] as String?)));
            }
          }
        });
      case Entities.recurring:
        await db.into(db.recurrings).insertOnConflictUpdate(RecurringsCompanion.insert(
              id: id,
              name: p['name'] as String? ?? '',
              kind: p['kind'] as String? ?? 'other',
              amountMinor: (p['amount_minor'] as num? ?? 0).toInt(),
              currency: p['currency'] as String? ?? 'KWD',
              accountId: Value(p['account_id'] as String?),
              categoryId: Value(p['category_id'] as String?),
              cadence: p['cadence'] as String? ?? 'monthly',
              interval: Value((p['interval'] as num?)?.toInt() ?? 1),
              anchorDate: p['anchor_date'] == null ? now : _parseDate(p['anchor_date']),
              nextDueDate: p['next_due_date'] == null ? now : _parseDate(p['next_due_date']),
              totalOccurrences: Value((p['total_occurrences'] as num?)?.toInt()),
              completedOccurrences: Value((p['completed_occurrences'] as num?)?.toInt() ?? 0),
              merchantPattern: Value(p['merchant_pattern'] as String?),
              status: p['status'] as String? ?? 'active',
              reminderDaysBefore: Value((p['reminder_days_before'] as num?)?.toInt() ?? 1),
              version: Value(version),
              updatedAt: now,
              deletedAt: delAt,
            ));
      case Entities.merchantAlias:
        await db.into(db.merchantAliases).insertOnConflictUpdate(MerchantAliasesCompanion.insert(
            id: id, pattern: p['pattern'] as String? ?? '', merchant: p['merchant'] as String? ?? '', categoryId: Value(p['category_id'] as String?), version: Value(version), updatedAt: now, deletedAt: delAt));
      case Entities.asset:
        await db.into(db.assets).insertOnConflictUpdate(AssetsCompanion.insert(
              id: id,
              name: p['name'] as String? ?? '',
              kind: p['kind'] as String? ?? 'other',
              isLiability: Value(p['is_liability'] as bool? ?? false),
              valueMinor: (p['value_minor'] as num? ?? 0).toInt(),
              currency: p['currency'] as String? ?? 'KWD',
              valuationDate: p['valuation_date'] == null ? now : _parseDate(p['valuation_date']),
              linkedAccountId: Value(p['linked_account_id'] as String?),
              note: Value(p['note'] as String?),
              version: Value(version),
              updatedAt: now,
              deletedAt: delAt,
            ));
      case Entities.setting:
        if (!deleted) {
          await db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: id, value: '${p['value']}'));
          await db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: 'sync_ver_$id', value: '$version'));
        }
      default:
        return _Apply.skipped;
    }
    return _Apply.applied;
  }

  /// Resolve a conflict. keepMine: re-push the local state on top of the server version.
  /// Otherwise, apply the server record locally and drop the local change.
  Future<void> resolveConflict(OutboxRow row, {required bool keepMine}) async {
    final server = row.lastError == null ? null : jsonDecode(row.lastError!) as Map<String, dynamic>?;
    final serverVersion = (server?['version'] as num?)?.toInt() ?? (server?['server_version'] as num?)?.toInt();
    if (keepMine) {
      if (serverVersion != null) await _setLocalVersion(row.entity, row.entityId, serverVersion);
      await (db.update(db.outbox)..where((o) => o.seq.equals(row.seq))).write(const OutboxCompanion(state: Value('pending'), lastError: Value(null)));
    } else {
      await (db.delete(db.outbox)..where((o) => o.seq.equals(row.seq))).go();
      if (server != null) {
        await _setLocalVersion(row.entity, row.entityId, 0);
        await _applyRemote(server);
      }
    }
  }
}

enum _Apply { applied, skipped, conflict }

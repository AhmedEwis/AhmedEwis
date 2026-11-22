import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/store.dart';

/// In-memory encrypted-capable database for tests (sqlite3mc build via hooks).
Future<FinanceStore> newTestStore({DateTime? now}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final db = AppDatabase(NativeDatabase.memory());
  var clock = now ?? DateTime.utc(2026, 11, 22, 12);
  final store = FinanceStore(db, clock: () => clock);
  await store.ensureSeeded();
  return store;
}

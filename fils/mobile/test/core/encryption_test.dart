import 'dart:io';

import 'package:drift/native.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

/// Proves the bundled SQLite build is SQLite3MultipleCiphers and that the database file
/// is unreadable without the key (encryption at rest).
void main() {
  test('database file is encrypted and needs the key', () async {
    final dir = await Directory.systemTemp.createTemp('fils_enc');
    final file = File('${dir.path}/fils.db');
    const key = 'test-key-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final db = AppDatabase(NativeDatabase(file, setup: (d) => d.execute("PRAGMA key = '$key'")));
    final store = FinanceStore(db);
    await store.ensureSeeded();
    await store.createAccount(name: 'SECRET-ACCOUNT-NAME', kind: 'bank', currency: 'KWD');
    await db.close();

    // 1. Cipher library present.
    final probe = s3.sqlite3.openInMemory();
    final cipher = probe.select('PRAGMA cipher').firstOrNull;
    probe.dispose();
    expect(cipher, isNotNull, reason: 'sqlite3mc not bundled');

    // 2. Plaintext never appears in the file bytes.
    final bytes = await file.readAsBytes();
    expect(String.fromCharCodes(bytes).contains('SECRET-ACCOUNT-NAME'), isFalse);
    expect(String.fromCharCodes(bytes.take(16)).startsWith('SQLite format 3'), isFalse);

    // 3. Opening without the key or with a wrong key fails.
    final noKey = s3.sqlite3.open(file.path);
    expect(() => noKey.select('SELECT count(*) FROM accounts'), throwsA(isA<s3.SqliteException>()));
    noKey.dispose();
    final wrong = s3.sqlite3.open(file.path)..execute("PRAGMA key = 'wrong'");
    expect(() => wrong.select('SELECT count(*) FROM accounts'), throwsA(isA<s3.SqliteException>()));
    wrong.dispose();

    // 4. Correct key reads the data.
    final ok = s3.sqlite3.open(file.path)..execute("PRAGMA key = '$key'");
    expect(ok.select('SELECT name FROM accounts').single['name'], 'SECRET-ACCOUNT-NAME');
    ok.dispose();
    await dir.delete(recursive: true);
  });
}

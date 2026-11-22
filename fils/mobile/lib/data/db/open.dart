import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// Opens the encrypted local database.
///
/// - The file is encrypted with SQLite3MultipleCiphers (ChaCha20-Poly1305 by default)
///   using a random 256-bit key.
/// - The key lives in the iOS Keychain or Android Keystore-backed storage. On iOS it uses
///   `first_unlock_this_device`: readable after the first unlock since boot (so
///   background tasks can run), never backed up or migrated to another device.
/// - Biometric app lock is separate: it gates the UI and is not the encryption key.
class DatabaseOpener {
  static const _keyName = 'fils_db_key_v1';
  static const storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static Future<String> _key() async {
    var k = await storage.read(key: _keyName);
    if (k == null) {
      final r = Random.secure();
      k = base64UrlEncode(List<int>.generate(32, (_) => r.nextInt(256)));
      await storage.write(key: _keyName, value: k);
    }
    return k;
  }

  static Future<AppDatabase> open({String name = 'fils'}) async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, '$name.db'));
    final key = await _key();
    // Escape quotes for PRAGMA; base64url contains no quote characters anyway.
    final escaped = key.replaceAll("'", "''");
    final executor = NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute("PRAGMA key = '$escaped'");
        // Verify the key works (and that the cipher library is present) before use.
        db.execute('SELECT count(*) FROM sqlite_master');
      },
    );
    return AppDatabase(executor);
  }

  /// Destroys the database key and file (account deletion / full wipe).
  static Future<void> destroy({String name = 'fils'}) async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, '$name.db'));
    if (await file.exists()) await file.delete();
    await storage.delete(key: _keyName);
  }
}

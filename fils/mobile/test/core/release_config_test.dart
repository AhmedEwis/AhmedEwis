import 'dart:io';

import 'package:fils/app/config.dart';
import 'package:fils/app/release_guards.dart';
import 'package:flutter_test/flutter_test.dart';

String read(String p) => File(p).readAsStringSync();

void main() {
  group('release guards', () {
    test('production: no demo session, no dev unlock, demo data only by explicit flag', () {
      expect(ReleaseGuards.demoSessionAllowed('production'), isFalse);
      expect(ReleaseGuards.devUnlock('production'), isFalse);
      expect(ReleaseGuards.demoDataAllowed('production'), isFalse);
      expect(ReleaseGuards.demoDataAllowed('production', explicitFlag: true), isTrue);
      expect(ReleaseGuards.devUnlock('staging'), isTrue);
      expect(ReleaseGuards.demoSessionAllowed('development'), isTrue);
    });
    test('missing production configuration fails loudly', () {
      expect(ReleaseGuards.productionConfigProblems(env: 'production', apiBaseUrl: '', googleServerClientId: ''), hasLength(2));
      expect(ReleaseGuards.productionConfigProblems(env: 'production', apiBaseUrl: 'http://x', googleServerClientId: 'g'), ['FILS_API_BASE_URL must be https']);
      expect(ReleaseGuards.productionConfigProblems(env: 'production', apiBaseUrl: 'https://api.fils.example', googleServerClientId: 'g'), isEmpty);
      expect(ReleaseGuards.productionConfigProblems(env: 'development', apiBaseUrl: '', googleServerClientId: ''), isEmpty);
    });
    test('this test build is development (dev unlock), not production', () {
      expect(AppConfig.isProduction, isFalse);
    });
  });

  group('platform configuration (static checks)', () {
    test('Android play manifest has no restricted SMS permissions; sms flavor matches implementation', () {
      final main = read('android/app/src/main/AndroidManifest.xml');
      for (final p in ['READ_SMS', 'RECEIVE_SMS', 'SEND_SMS', 'RECEIVE_MMS', 'READ_CALL_LOG']) {
        expect(main.contains('android.permission.$p'), isFalse, reason: p);
      }
      final sms = read('android/app/src/sms/AndroidManifest.xml');
      expect(RegExp(r'uses-permission android:name="android\.permission\.(\w+)"').allMatches(sms).map((m) => m[1]).toSet(), {'RECEIVE_SMS'});
      expect(sms, contains('.SmsReceiver'));
      expect(File('android/app/src/sms/kotlin/kw/fils/fils/SmsReceiver.kt').existsSync(), isTrue);
      expect(main, contains('android.permission.BIND_NOTIFICATION_LISTENER_SERVICE'));
      expect(main, contains('android:allowBackup="false"'));
    });

    test('identifiers are consistent across iOS, Android, Dart and backend', () {
      final pbx = read('ios/Runner.xcodeproj/project.pbxproj');
      expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = kw.fils.fils;'));
      expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = kw.fils.fils.ShareExtension;'));
      const group = 'group.kw.fils';
      expect(read('ios/Runner/Runner.entitlements'), contains(group));
      expect(read('ios/ShareExtension/ShareExtension.entitlements'), contains(group));
      expect(read('ios/Runner/CaptureInbox.swift'), contains('"$group"'));
      expect(read('android/app/build.gradle.kts'), contains('applicationId = "kw.fils.fils"'));
      final env = read('../backend/.env.example');
      expect(env, contains('FILS_APPLE_BUNDLE_ID=kw.fils.fils'));
      expect(env, contains('FILS_GOOGLE_PACKAGE_NAME=kw.fils.fils'));
      expect(env, contains(AppConfig.proMonthlyProductId));
      expect(env, contains(AppConfig.proYearlyProductId));
      expect(env, contains(AppConfig.googleSubscriptionId));
    });

    test('no raw message text, tokens or audio paths are printed by app code', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (RegExp(r'^\s*print\(').hasMatch(l)) offenders.add('${f.path}:${i + 1} print');
          if (l.contains('debugPrint(') && RegExp(r'text|token|rawText|body|path|transcript|sms', caseSensitive: false).hasMatch(l.substring(l.indexOf('debugPrint(')))) {
            offenders.add('${f.path}:${i + 1} debugPrint with sensitive field');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}

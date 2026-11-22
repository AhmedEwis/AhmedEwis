// Renders real screens with synthetic demo data into PNGs for design review.
// Opt-in (~15 s per variant): FILS_SCREENSHOTS=1 flutter test test/screenshots --update-goldens
// Output: test/screenshots/goldens/*.png (copied to fils/docs/screenshots by CI/docs).
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fils/app/app.dart';
import 'package:fils/app/providers.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/demo/demo_seed.dart';
import 'package:fils/data/store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' show SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final bytes = f.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  final now = DateTime.utc(2026, 11, 22, 9, 30);
  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    await _loadFont('IBMPlexSansArabic', [
      for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/IBMPlexSansArabic-$w.ttf',
    ]);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    final emoji = Platform.environment['FILS_EMOJI_FONT'];
    if (emoji != null) await _loadFont('Noto Color Emoji', [emoji]);
  });

  final screens = <(String, String)>[
    ('home', '/'),
    ('wealth', '/wealth'),
    ('plans_budgets', '/plans'),
    ('ask', '/ask'),
    ('insights', '/insights'),
    ('transactions', '/transactions'),
    ('review', '/review'),
    ('capture', '/capture'),
    ('settings', '/settings'),
    ('accounts', '/accounts'),
  ];

  for (final locale in ['en', 'ar']) {
    for (final theme in ['light', 'dark']) {
      testWidgets('screens $locale $theme', skip: Platform.environment['FILS_SCREENSHOTS'] == null, (tester) async {
        tester.view.physicalSize = const Size(780, 1688); // 390x844 @2x
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        late FinanceStore store;
        final sw = Stopwatch()..start();
        void mark(String m) => debugPrint('[shot ${sw.elapsedMilliseconds}ms] $m');
        await tester.runAsync(() async {
          store = FinanceStore(AppDatabase(NativeDatabase.memory()), clock: () => now);
          await store.ensureSeeded();
          await DemoSeeder(store).seed(now: now);
          await store.setSetting(SettingKeys.locale, locale);
          await store.setSetting(SettingKeys.themeMode, theme);
          await store.setSetting(SettingKeys.lastCaptureAt, now.subtract(const Duration(minutes: 12)).toIso8601String());
          await store.setSetting(SettingKeys.lastCaptureSource, 'sms');
        });
        mark('seeded');
        final container = ProviderContainer(overrides: [
          storeProvider.overrideWithValue(store),
          nowProvider.overrideWithValue(() => now),
        ]);
        await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const FilsApp()));
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
            await tester.pump(const Duration(milliseconds: 300));
          }
        }

        await settle();
        final only = Platform.environment['FILS_SCREENSHOT_ONLY']?.split(',');
        for (final (name, route) in screens.where((e) => only == null || only.contains(e.$1))) {
          container.read(routerProvider).go(route);
          await settle();
          mark('settled $name');
          await expectLater(find.byType(FilsApp), matchesGoldenFile('goldens/${name}_${locale}_$theme.png'));
          mark('golden $name');
        }
        // Root cause of the earlier 10-minute hangs: closing the database while the app
        // (with live drift stream queries) was still mounted. Unmount first, then dispose
        // the provider container, then close the database.
        mark('closing');
        await tester.pumpWidget(const SizedBox.shrink());
        mark('unmounted');
        await tester.pump(const Duration(milliseconds: 100));
        container.dispose();
        mark('disposed');
        // Drift schedules stream-cancellation work on the fake-async clock; flush it so the
        // close() below can complete instead of waiting on timers that never fire.
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(seconds: 1));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        }
        mark('flushed');
        await tester.runAsync(() => store.db.close());
        mark('closed');
      }, timeout: const Timeout(Duration(minutes: 3)) /* ~15 s measured per variant; generous margin for slow CI */);
    }
  }
}

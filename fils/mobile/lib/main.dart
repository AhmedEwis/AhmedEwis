import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'app/config.dart';
import 'app/release_guards.dart';
import 'app/providers.dart';
import 'data/db/open.dart';
import 'data/store.dart';
// Keeps the headless capture entrypoint in the AOT snapshot.
export 'capture_main.dart' show captureMain;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Refuse to run a misconfigured production build instead of silently degrading.
  final problems = ReleaseGuards.productionConfigProblems(
      env: AppConfig.environment, apiBaseUrl: AppConfig.apiBaseUrl, googleServerClientId: AppConfig.googleServerClientId);
  if (problems.isNotEmpty) throw StateError('Invalid production configuration: ${problems.join('; ')}');
  await initializeDateFormatting('ar');
  await initializeDateFormatting('en');
  final db = await DatabaseOpener.open();
  final store = FinanceStore(db);
  await store.ensureSeeded();
  runApp(ProviderScope(
    overrides: [storeProvider.overrideWithValue(store)],
    child: const FilsApp(),
  ));
}

// The Smart Plan vertical slice through the real app UI: text → understanding → plan →
// adjust → preview → confirm → applied budgets → progress card → undo.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show FontLoader, ByteData;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fils/app/app.dart';
import 'package:fils/app/providers.dart';
import 'package:fils/data/db/database.dart';
import 'package:fils/data/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';

import '../support/planner_fixtures.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
  }
  await loader.load();
}

const headline = 'عايز أوفر 150 دينار الشهر ده، بس ما تقللش الجيم ولا مصاريف البيت.';

Future<void> runFlow(WidgetTester tester, String locale, Future<void> Function(FinanceStore store, Future<void> Function() settle) body) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  await initializeDateFormatting('ar');
  await initializeDateFormatting('en');
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  late FinanceStore store;
  await tester.runAsync(() async {
    store = FinanceStore(AppDatabase(NativeDatabase.memory()), clock: () => planNow);
    await store.ensureSeeded();
    await seedHistory(store, fitness: true);
    await store.setSetting(SettingKeys.locale, locale);
    await store.setSetting(SettingKeys.onboarded, 'true');
  });
  final container = ProviderContainer(overrides: [storeProvider.overrideWithValue(store), nowProvider.overrideWithValue(() => planNow)]);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const FilsApp()));
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  await settle();
  container.read(routerProvider).go('/smart-plan');
  await settle();
  await body(store, settle);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  container.dispose();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.runAsync(() => store.db.close());
}

/// Opt-in flow frames (FILS_SCREENSHOTS=1 … --update-goldens): one per step, assembled
/// into docs/screenshots/smart_plan_flow.gif.
Future<void> shot(WidgetTester t, String name) async {
  if (Platform.environment['FILS_SCREENSHOTS'] == null) return;
  await expectLater(find.byType(FilsApp), matchesGoldenFile('../screenshots/goldens/flow_$name.png'));
}

Future<List<BudgetRow>> budgets(WidgetTester t, FinanceStore s) async =>
    (await t.runAsync(() => (s.db.select(s.db.budgets)..where((b) => b.deletedAt.isNull())).get()))!;

void main() {
  setUpAll(() async {
    // Real fonts (as in the screenshot suite): the default test font draws every glyph
    // as a wide box, which makes ordinary rows overflow.
    await _loadFont('IBMPlexSansArabic', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/IBMPlexSansArabic-$w.ttf']);
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    final emoji = Platform.environment['FILS_EMOJI_FONT'];
    if (emoji != null) await _loadFont('Noto Color Emoji', [emoji]);
  });

  testWidgets('English: plan → adjust → preview → confirm → applied → undo', (tester) async {
    await runFlow(tester, 'en', (store, settle) async {
      expect(find.text('My Smart Plan'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('plan_input')), headline);
      await tester.pump();
      await shot(tester, '1_request');
      await tester.tap(find.byKey(const Key('plan_go')));
      await settle();
      await shot(tester, '2_understood');
      // No server in this build: honestly labelled.
      expect(find.text('Basic local planner'), findsOneWidget);
      expect(find.text('Live AI'), findsNothing);
      expect(find.byKey(const Key('protected_fitness')), findsOneWidget);
      expect(find.byKey(const Key('protected_housing')), findsOneWidget);
      // Income 1,000.000, expected spending 858.333 → 141.667 saved; 8.333 more is needed and
      // the planner takes it from the category with the most room that isn't protected: food.
      const firstKey = 'food';
      await tester.scrollUntilVisible(find.byKey(const Key('action_$firstKey')), 300, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      expect(find.byKey(const Key('action_$firstKey')), findsOneWidget);
      // "Why this suggestion?" shows supporting facts with their source.
      await tester.ensureVisible(find.byKey(Key('why_$firstKey')));
      await tester.tap(find.byKey(Key('why_$firstKey')));
      await settle();
      await shot(tester, '3_why');
      expect(find.text('Observed', skipOffstage: false), findsWidgets);
      expect(find.text('Assumption', skipOffstage: false), findsWidgets);
      // Adjust a limit: recalculated immediately and marked as the user's edit.
      await tester.ensureVisible(find.byKey(Key('plus_$firstKey')));
      await tester.tap(find.byKey(Key('plus_$firstKey')));
      await settle();
      expect(find.text('Your edit', skipOffstage: false), findsOneWidget);
      final before = jsonEncode((await budgets(tester, store)).map((b) => [b.categoryId, b.amountMinor]).toList());
      // Preview writes nothing.
      await tester.scrollUntilVisible(find.byKey(const Key('plan_preview')), 300, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(const Key('plan_preview')));
      await settle();
      expect(find.text('Preview: what will change'), findsOneWidget);
      await shot(tester, '4_preview');
      expect(jsonEncode((await budgets(tester, store)).map((b) => [b.categoryId, b.amountMinor]).toList()), before);
      await tester.tap(find.byKey(const Key('plan_confirm')));
      await settle();
      final after = await budgets(tester, store);
      expect(after.where((b) => b.categoryId == firstKey), hasLength(1));
      expect(after.any((b) => ['fitness', 'housing', 'bills', 'groceries'].contains(b.categoryId)), isFalse, reason: 'protected categories never get a cut budget');
      final plans = (await tester.runAsync(() => store.db.select(store.db.smartPlans).get()))!;
      expect(plans.single.status, 'applied');
      expect(plans.single.understoodBy, 'local');
      // Progress card for the accepted plan, then undo.
      expect(find.byKey(const Key('active_plan')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // let the "applied" snackbar pass
      await settle();
      await shot(tester, '5_applied');
      await tester.ensureVisible(find.byKey(const Key('plan_undo')));
      await tester.tap(find.byKey(const Key('plan_undo')));
      await settle();
      expect(await budgets(tester, store), isEmpty);
      await shot(tester, '6_undone');
      expect((await tester.runAsync(() => store.db.select(store.db.smartPlans).get()))!.single.status, 'undone');
      // Transactions were never touched.
      final txs = (await tester.runAsync(() => store.allTransactions()))!;
      expect(totalsCount(txs), greaterThan(0));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });
  });

  testWidgets('Arabic RTL: home entry point and the plan render right-to-left', (tester) async {
    await runFlow(tester, 'ar', (store, settle) async {
      expect(find.text('خطتي الذكية'), findsWidgets);
      expect(Directionality.of(tester.element(find.byKey(const Key('plan_input')))), TextDirection.rtl);
      await tester.enterText(find.byKey(const Key('plan_input')), headline);
      await tester.tap(find.byKey(const Key('plan_go')));
      await settle();
      expect(find.text('مخطط محلي أساسي'), findsOneWidget);
      expect(find.text('فهمت التالي'), findsOneWidget);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });
  });
}

int totalsCount(List<TxRow> txs) => txs.length;


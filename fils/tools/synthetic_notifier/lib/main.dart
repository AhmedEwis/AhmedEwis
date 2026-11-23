// Fils Synthetic Notifier: a TEST TOOL, not part of the Fils app.
//
// It posts fixed, clearly labeled [SYNTHETIC] bank-style notifications from its own
// package (kw.fils.testtools.synthetic_notifier). That package is a normal launchable
// app, so it appears in Fils' "Choose apps" picker, unlike messaging apps, which the
// Fils notification listener deliberately blocks. Nothing here talks to a bank or
// the network.
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final _plugin = FlutterLocalNotificationsPlugin();
const _channelId = 'synthetic_bank_alerts';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
  final catalog = jsonDecode(await rootBundle.loadString('assets/messages.json')) as Map<String, dynamic>;
  runApp(NotifierApp(catalog: catalog));
}

class NotifierApp extends StatelessWidget {
  final Map<String, dynamic> catalog;
  const NotifierApp({super.key, required this.catalog});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Fils Synthetic Notifier',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: _Home(catalog: catalog),
      );
}

class _Home extends StatefulWidget {
  final Map<String, dynamic> catalog;
  const _Home({required this.catalog});
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  int _nextId = 1;
  final _log = <String>[];

  Future<void> _post(Map<String, dynamic> m, {Duration delay = Duration.zero}) async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    final id = _nextId++;
    setState(() => _log.insert(0, '${m['id']} #$id ${delay == Duration.zero ? 'posted' : 'posting in ${delay.inSeconds}s'}'));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final body = m['body'] as String;
    await _plugin.show(
      id: id,
      title: m['title'] as String,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(_channelId, widget.catalog['channel'] as String,
            importance: Importance.high, priority: Priority.high, styleInformation: BigTextStyleInformation(body)),
      ),
    );
    if (mounted && delay > Duration.zero) setState(() => _log.insert(0, '${m['id']} #$id posted'));
  }

  @override
  Widget build(BuildContext context) {
    final msgs = (widget.catalog['messages'] as List).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: const Text('Fils Synthetic Notifier')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('TEST TOOL. Posts fixed [SYNTHETIC] bank-style notifications. Not real bank data.',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        for (final m in msgs)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${m['id']} · ${m['title']}', style: Theme.of(context).textTheme.titleMedium),
                Text(m['body'] as String),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  FilledButton(key: Key('post_${m['id']}'), onPressed: () => _post(m), child: const Text('Post now')),
                  OutlinedButton(
                      key: Key('delay_${m['id']}'),
                      onPressed: () => _post(m, delay: const Duration(seconds: 20)),
                      child: const Text('Post in 20 s')),
                ]),
              ]),
            ),
          ),
        const SizedBox(height: 12),
        for (final l in _log) Text(l, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

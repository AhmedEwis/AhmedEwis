import 'dart:async';
import 'dart:io';

import 'package:fils/data/voice/azure_tts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeSink implements AudioSink {
  final played = <String>[];
  int stops = 0;
  final _done = StreamController<void>.broadcast();
  @override
  Future<void> playFile(String path) async => played.add(path);
  @override
  Future<void> stop() async => stops++;
  @override
  Stream<void> get onComplete => _done.stream;
  void finish() => _done.add(null);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('tts'));
  tearDown(() => tmp.delete(recursive: true));

  AzureTts make(http.Client c, FakeSink sink, List<String> fb, {Duration delay = Duration.zero}) => AzureTts(
        token: () async => (token: 'tok', region: 'uaenorth'),
        fallback: (t, l) async => fb.add('$l:$t'),
        sink: sink,
        client: c,
        tempDir: () async => tmp,
      );

  test('SSML escapes user text (no markup injection) and picks the Kuwaiti voice', () {
    final x = AzureTts.ssml('<voice name="evil">Tom & "Jerry"</voice>', 'ar-KW', 'ar-KW-NouraNeural');
    expect(x, contains('&lt;voice name=&quot;evil&quot;&gt;Tom &amp; &quot;Jerry&quot;&lt;/voice&gt;'));
    expect(x, contains('<voice name="ar-KW-NouraNeural">'));
    expect(x, contains('xml:lang="ar-KW"'));
  });

  test('plays Azure audio with bearer token; temp file deleted after completion', () async {
    late http.Request seen;
    final c = MockClient((r) async {
      seen = r;
      return http.Response.bytes(List.filled(2048, 7), 200);
    });
    final sink = FakeSink();
    final fb = <String>[];
    final tts = make(c, sink, fb);
    expect(await tts.speak('صرفت 10 دنانير', locale: 'ar-KW'), TtsOutcome.azure);
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.url.host, 'uaenorth.tts.speech.microsoft.com');
    expect(fb, isEmpty);
    expect(File(sink.played.single).existsSync(), isTrue);
    sink.finish();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(File(sink.played.single).existsSync(), isFalse);
  });

  test('HTTP error, network error or missing token → device fallback', () async {
    final sink = FakeSink();
    final fb = <String>[];
    expect(await make(MockClient((_) async => http.Response('nope', 401)), sink, fb).speak('hi', locale: 'en-US'), TtsOutcome.fallback);
    expect(await make(MockClient((_) async => throw const SocketException('down')), sink, fb).speak('hi', locale: 'en-US'), TtsOutcome.fallback);
    final noTok = AzureTts(token: () async => throw StateError('503 provider_not_configured'), fallback: (t, l) async => fb.add(t), sink: sink, client: MockClient((_) async => http.Response('', 200)), tempDir: () async => tmp);
    expect(await noTok.speak('hi', locale: 'en-US'), TtsOutcome.fallback);
    expect(fb.length, 3);
    expect(sink.played, isEmpty);
  });

  test('stop() during synthesis cancels: nothing plays, no fallback, no leftover file', () async {
    final gate = Completer<void>();
    final c = MockClient((_) async {
      await gate.future;
      return http.Response.bytes(List.filled(2048, 7), 200);
    });
    final sink = FakeSink();
    final fb = <String>[];
    final tts = make(c, sink, fb);
    final f = tts.speak('long answer', locale: 'en-US');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tts.stop();
    gate.complete();
    expect(await f, TtsOutcome.cancelled);
    expect(sink.played, isEmpty);
    expect(fb, isEmpty);
    expect(tmp.listSync(), isEmpty);
  });

  test('empty text does nothing', () async {
    final sink = FakeSink();
    expect(await make(MockClient((_) async => http.Response('', 200)), sink, []).speak('   ', locale: 'en'), TtsOutcome.empty);
  });
}

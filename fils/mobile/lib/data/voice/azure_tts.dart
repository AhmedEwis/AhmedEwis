import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Audio output port (real: audioplayers; tests: fake).
abstract class AudioSink {
  Future<void> playFile(String path);
  Future<void> stop();
  Stream<void> get onComplete;
}

class PlayerAudioSink implements AudioSink {
  final _p = AudioPlayer();
  @override
  Future<void> playFile(String path) => _p.play(DeviceFileSource(path));
  @override
  Future<void> stop() => _p.stop();
  @override
  Stream<void> get onComplete => _p.onPlayerComplete;
}

typedef TokenProvider = Future<({String token, String region})> Function();
typedef FallbackSpeaker = Future<void> Function(String text, String locale);

enum TtsOutcome { azure, fallback, cancelled, empty }

/// Azure AI Speech neural TTS over REST, authorized with the short-lived token issued by
/// the backend (no long-lived key on the device).
/// - Cancellation: [stop] invalidates in-flight requests (generation counter) and stops
///   playback. A response arriving after stop is discarded.
/// - Errors (no token, network, 4xx/5xx, bad audio) fall back to device TTS.
/// - The synthesized clip is written to a temp file and deleted after playback or stop.
class AzureTts {
  final TokenProvider token;
  final FallbackSpeaker fallback;
  final AudioSink sink;
  final http.Client client;
  final Future<Directory> Function() tempDir;
  final Map<String, String> voices; // 'ar' / 'en' → voice name
  int _gen = 0;
  File? _current;

  AzureTts({
    required this.token,
    required this.fallback,
    AudioSink? sink,
    http.Client? client,
    Future<Directory> Function()? tempDir,
    this.voices = const {'ar': 'ar-KW-NouraNeural', 'en': 'en-US-AvaNeural'},
  })  : sink = sink ?? PlayerAudioSink(),
        client = client ?? http.Client(),
        tempDir = tempDir ?? getTemporaryDirectory;

  static String escapeXml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

  static String ssml(String text, String locale, String voice) {
    final lang = locale.startsWith('ar') ? 'ar-KW' : 'en-US';
    return '<speak version="1.0" xml:lang="$lang"><voice name="$voice">${escapeXml(text)}</voice></speak>';
  }

  Future<TtsOutcome> speak(String text, {required String locale}) async {
    final t = text.trim();
    if (t.isEmpty) return TtsOutcome.empty;
    await stop();
    final gen = ++_gen;
    final clipped = t.length > 1500 ? t.substring(0, 1500) : t;
    try {
      final tok = await token();
      if (gen != _gen) return TtsOutcome.cancelled;
      final voice = voices[locale.startsWith('ar') ? 'ar' : 'en']!;
      final res = await client
          .post(
            Uri.parse('https://${tok.region}.tts.speech.microsoft.com/cognitiveservices/v1'),
            headers: {
              'Authorization': 'Bearer ${tok.token}',
              'Content-Type': 'application/ssml+xml',
              'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
              'User-Agent': 'fils-app',
            },
            body: ssml(clipped, locale, voice),
          )
          .timeout(const Duration(seconds: 12));
      if (gen != _gen) return TtsOutcome.cancelled;
      if (res.statusCode != 200 || res.bodyBytes.length < 64) throw HttpException('tts ${res.statusCode}');
      final dir = await tempDir();
      final f = File('${dir.path}/fils_tts_$gen.mp3');
      await f.writeAsBytes(res.bodyBytes, flush: true);
      if (gen != _gen) {
        await f.delete();
        return TtsOutcome.cancelled;
      }
      _current = f;
      unawaited(sink.onComplete.first.then((_) => _cleanup(f)));
      await sink.playFile(f.path);
      return TtsOutcome.azure;
    } catch (_) {
      if (gen != _gen) return TtsOutcome.cancelled;
      await fallback(clipped, locale);
      return TtsOutcome.fallback;
    }
  }

  Future<void> _cleanup(File f) async {
    if (await f.exists()) await f.delete();
    if (_current?.path == f.path) _current = null;
  }

  Future<void> stop() async {
    _gen++;
    await sink.stop();
    final f = _current;
    if (f != null) await _cleanup(f);
  }
}

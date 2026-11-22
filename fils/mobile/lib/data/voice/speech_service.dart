import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api/api_client.dart';

/// Speech provider abstraction: speech-to-text plus text-to-speech, with a text-only
/// fallback. Implementations:
///  - [DeviceSpeech]: platform recognizers (iOS Speech / Android SpeechRecognizer) and
///    platform TTS. No Fils credentials needed.
///  - [AzureSpeech]: Azure AI Speech REST. The app gets a ~10-minute token from the
///    backend (no long-lived key on device), records a short push-to-talk clip, and
///    sends it for recognition. Audio is deleted right after the request.
abstract class SpeechProvider {
  String get id;
  Future<bool> available();
  Future<bool> requestPermission();

  /// Push-to-talk: start capturing; returns when [stop] or [cancel] is called.
  Future<void> start({required String locale, void Function(String partial)? onPartial});
  Future<SpeechResult> stop();
  Future<void> cancel();
  Future<void> speak(String text, {required String locale});
  Future<void> stopSpeaking();
}

class SpeechResult {
  final String text;
  final String? error; // no_speech | permission | network | provider_not_configured | unavailable
  const SpeechResult(this.text, {this.error});
}

class DeviceSpeech implements SpeechProvider {
  final _stt = SpeechToText();
  final _tts = FlutterTts();
  bool _init = false;
  String _last = '';
  Completer<void>? _done;

  @override
  String get id => 'device';

  @override
  Future<bool> available() async {
    if (!_init) {
      _init = await _stt.initialize(onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && !(_done?.isCompleted ?? true)) _done?.complete();
      }, onError: (_) {
        if (!(_done?.isCompleted ?? true)) _done?.complete();
      });
    }
    return _init;
  }

  @override
  Future<bool> requestPermission() => available();

  @override
  Future<void> start({required String locale, void Function(String partial)? onPartial}) async {
    _last = '';
    _done = Completer<void>();
    if (!await available()) throw StateError('unavailable');
    // Kuwaiti Arabic first; the platform falls back to generic Arabic if unsupported.
    final locales = await _stt.locales();
    final want = locale.startsWith('ar') ? ['ar_KW', 'ar_SA', 'ar_AE', 'ar_EG', 'ar'] : ['en_US', 'en_GB', 'en'];
    String? pick;
    for (final w in want) {
      final hit = locales.where((l) => l.localeId.replaceAll('-', '_').toLowerCase().startsWith(w.toLowerCase()));
      if (hit.isNotEmpty) {
        pick = hit.first.localeId;
        break;
      }
    }
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: pick,
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (r) {
        _last = r.recognizedWords;
        onPartial?.call(_last);
      },
    );
  }

  @override
  Future<SpeechResult> stop() async {
    await _stt.stop();
    await Future.any([_done?.future ?? Future.value(), Future.delayed(const Duration(milliseconds: 800))]);
    return _last.trim().isEmpty ? const SpeechResult('', error: 'no_speech') : SpeechResult(_last.trim());
  }

  @override
  Future<void> cancel() => _stt.cancel();

  @override
  Future<void> speak(String text, {required String locale}) async {
    await _tts.setLanguage(locale.startsWith('ar') ? 'ar' : 'en-US');
    await _tts.speak(text);
  }

  @override
  Future<void> stopSpeaking() => _tts.stop();
}

class AzureSpeech implements SpeechProvider {
  final ApiClient api;
  final _rec = AudioRecorder();
  final _tts = FlutterTts(); // playback of synthesized speech falls back to device TTS
  String? _token;
  String? _region;
  DateTime? _exp;
  String? _path;
  AzureSpeech(this.api);

  @override
  String get id => 'azure';

  @override
  Future<bool> available() async => api.configured;

  @override
  Future<bool> requestPermission() => _rec.hasPermission();

  Future<void> _ensureToken() async {
    if (_token != null && _exp != null && _exp!.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 30)))) return;
    final t = await api.voiceToken();
    _token = t['token'] as String;
    _region = t['region'] as String;
    _exp = DateTime.tryParse(t['expires_at'] as String? ?? '')?.toUtc() ?? DateTime.now().toUtc().add(const Duration(minutes: 9));
  }

  @override
  Future<void> start({required String locale, void Function(String partial)? onPartial}) async {
    if (!await _rec.hasPermission()) throw StateError('permission');
    _locale = locale.startsWith('ar') ? 'ar-KW' : 'en-US';
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/fils_ptt_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: _path!);
    unawaited(_ensureToken().catchError((_) {}));
  }

  String _locale = 'ar-KW';

  @override
  Future<SpeechResult> stop() async {
    final path = await _rec.stop();
    if (path == null) return const SpeechResult('', error: 'no_speech');
    final f = File(path);
    try {
      await _ensureToken();
      final bytes = await f.readAsBytes();
      if (bytes.length < 8000) return const SpeechResult('', error: 'no_speech');
      final uri = Uri.parse('https://$_region.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=$_locale&format=simple');
      final res = await http
          .post(uri, headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000', 'Accept': 'application/json'}, body: bytes)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return SpeechResult('', error: 'network_${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['RecognitionStatus'] != 'Success') return const SpeechResult('', error: 'no_speech');
      return SpeechResult((j['DisplayText'] as String? ?? '').trim());
    } on ApiException catch (e) {
      return SpeechResult('', error: e.notConfigured ? 'provider_not_configured' : e.code);
    } on SocketException {
      return const SpeechResult('', error: 'network');
    } finally {
      // Raw audio is never persisted beyond the request.
      if (await f.exists()) await f.delete();
    }
  }

  @override
  Future<void> cancel() async {
    final p = await _rec.stop();
    if (p != null && await File(p).exists()) await File(p).delete();
  }

  @override
  Future<void> speak(String text, {required String locale}) async {
    await _tts.setLanguage(locale.startsWith('ar') ? 'ar' : 'en-US');
    await _tts.speak(text);
  }

  @override
  Future<void> stopSpeaking() => _tts.stop();
}

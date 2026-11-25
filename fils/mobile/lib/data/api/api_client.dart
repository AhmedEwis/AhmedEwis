import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../app/config.dart';

class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  ApiException(this.status, this.code, this.message, [this.details]);
  bool get isAuth => status == 401;
  bool get notConfigured => code == 'provider_not_configured' || code == 'billing_not_configured' || code == 'cloud_not_configured';
  @override
  String toString() => 'ApiException($status $code: $message)';
}

/// Session tokens in Keychain/Keystore. Access tokens are short-lived; refresh tokens
/// rotate on every use (the server revokes the whole family on reuse).
class TokenStore {
  static const _s = FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device));
  static const _kAccess = 'fils_access', _kRefresh = 'fils_refresh', _kAccessExp = 'fils_access_exp', _kUser = 'fils_user', _kDevice = 'fils_device_id';
  final FlutterSecureStorage storage;
  TokenStore({FlutterSecureStorage? storage}) : storage = storage ?? _s;

  Future<String?> access() => storage.read(key: _kAccess);
  Future<String?> refresh() => storage.read(key: _kRefresh);
  Future<DateTime?> accessExpiry() async => DateTime.tryParse(await storage.read(key: _kAccessExp) ?? '');
  Future<Map<String, dynamic>?> user() async {
    final u = await storage.read(key: _kUser);
    return u == null ? null : jsonDecode(u) as Map<String, dynamic>;
  }

  Future<void> save(Map<String, dynamic> auth) async {
    await storage.write(key: _kAccess, value: auth['access_token'] as String);
    await storage.write(key: _kRefresh, value: auth['refresh_token'] as String);
    await storage.write(key: _kAccessExp, value: auth['access_expires_at'] as String);
    if (auth['user'] != null) await storage.write(key: _kUser, value: jsonEncode(auth['user']));
  }

  Future<void> saveUser(Map<String, dynamic> u) => storage.write(key: _kUser, value: jsonEncode(u));

  Future<void> clear() async {
    for (final k in [_kAccess, _kRefresh, _kAccessExp, _kUser]) {
      await storage.delete(key: k);
    }
  }

  Future<String> deviceId() async {
    var d = await storage.read(key: _kDevice);
    if (d == null) {
      d = const Uuid().v4();
      await storage.write(key: _kDevice, value: d);
    }
    return d;
  }
}

class ApiClient {
  final String baseUrl;
  final TokenStore tokens;
  final http.Client _http;
  final Duration timeout;
  Completer<void>? _refreshing;
  void Function()? onSessionExpired;

  ApiClient({String? baseUrl, TokenStore? tokens, http.Client? client, this.timeout = const Duration(seconds: 20)})
      : baseUrl = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        tokens = tokens ?? TokenStore(),
        _http = client ?? http.Client();

  bool get configured => baseUrl.isNotEmpty;

  Future<Map<String, dynamic>> deviceInfo() async => {
        'device_id': await tokens.deviceId(),
        'platform': Platform.isIOS ? 'ios' : 'android',
        'app_version': const String.fromEnvironment('FILS_APP_VERSION', defaultValue: '0.1.0'),
      };

  Uri _u(String path, [Map<String, String>? q]) => Uri.parse('$baseUrl$path').replace(queryParameters: q);

  Future<void> _ensureFresh() async {
    final exp = await tokens.accessExpiry();
    if (exp == null || exp.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 60)))) return;
    await refreshSession();
  }

  Future<void> refreshSession() async {
    if (_refreshing != null) return _refreshing!.future;
    _refreshing = Completer<void>();
    try {
      final rt = await tokens.refresh();
      if (rt == null) throw ApiException(401, 'no_session', 'Not signed in');
      final res = await _http.post(_u('/v1/auth/refresh'), headers: {'content-type': 'application/json'}, body: jsonEncode({'refresh_token': rt})).timeout(timeout);
      if (res.statusCode != 200) {
        await tokens.clear();
        onSessionExpired?.call();
        throw _err(res);
      }
      await tokens.save(jsonDecode(res.body) as Map<String, dynamic>);
      _refreshing!.complete();
    } catch (e) {
      _refreshing!.completeError(e);
      rethrow;
    } finally {
      _refreshing = null;
    }
  }

  ApiException _err(http.Response r) {
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final e = (j['error'] ?? j) as Map<String, dynamic>;
      return ApiException(r.statusCode, (e['code'] ?? 'http_${r.statusCode}').toString(), (e['message'] ?? e['detail'] ?? '').toString(), e['details'] as Map<String, dynamic>?);
    } catch (_) {
      return ApiException(r.statusCode, 'http_${r.statusCode}', r.reasonPhrase ?? '');
    }
  }

  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
    String? idempotencyKey,
    String? reauthToken,
    int retries = 2,
  }) async {
    if (!configured) throw ApiException(0, 'cloud_not_configured', 'Backend URL not configured');
    for (var attempt = 0;; attempt++) {
      try {
        if (auth) await _ensureFresh();
        final headers = <String, String>{'content-type': 'application/json', 'accept': 'application/json'};
        if (auth) {
          final at = await tokens.access();
          if (at == null) throw ApiException(401, 'no_session', 'Not signed in');
          headers['authorization'] = 'Bearer $at';
        }
        if (idempotencyKey != null) headers['idempotency-key'] = idempotencyKey;
        if (reauthToken != null) headers['x-reauth'] = reauthToken;
        final req = http.Request(method, _u(path, query))..headers.addAll(headers);
        if (body != null) req.body = jsonEncode(body);
        final streamed = await _http.send(req).timeout(timeout);
        final res = await http.Response.fromStream(streamed);
        if (res.statusCode == 401 && auth && attempt == 0) {
          await refreshSession();
          continue;
        }
        if (res.statusCode >= 500 && attempt < retries) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (1 << attempt)));
          continue;
        }
        if (res.statusCode == 204) return null;
        if (res.statusCode >= 400) throw _err(res);
        return res.body.isEmpty ? null : jsonDecode(res.body);
      } on SocketException {
        if (attempt >= retries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 500 * (1 << attempt)));
      } on TimeoutException {
        if (attempt >= retries) rethrow;
      }
    }
  }

  // ---- auth
  Future<String> nonce() async => (await request('POST', '/v1/auth/nonce', auth: false))['nonce'] as String;

  Future<Map<String, dynamic>> signInApple({required String identityToken, required String nonce, String? authorizationCode, String? fullName}) async {
    final r = await request('POST', '/v1/auth/apple', auth: false, body: {
      'identity_token': identityToken,
      'nonce': nonce,
      if (authorizationCode != null) 'authorization_code': authorizationCode,
      if (fullName != null) 'full_name': fullName,
      'device': await deviceInfo(),
    }) as Map<String, dynamic>;
    await tokens.save(r);
    return r;
  }

  Future<Map<String, dynamic>> signInGoogle({required String idToken, required String nonce}) async {
    final r = await request('POST', '/v1/auth/google', auth: false, body: {'id_token': idToken, 'nonce': nonce, 'device': await deviceInfo()}) as Map<String, dynamic>;
    await tokens.save(r);
    return r;
  }

  Future<Map<String, dynamic>> demoSession() async {
    final r = await request('POST', '/v1/demo/session', auth: false, body: await deviceInfo()) as Map<String, dynamic>;
    await tokens.save(r);
    return r;
  }

  Future<void> logout() async {
    final rt = await tokens.refresh();
    try {
      if (rt != null) await request('POST', '/v1/auth/logout', body: {'refresh_token': rt}, retries: 0);
    } finally {
      await tokens.clear();
    }
  }

  Future<String> reauth({required String provider, required String token, required String nonce}) async =>
      (await request('POST', '/v1/auth/reauth', body: {'provider': provider, 'token': token, 'nonce': nonce}))['reauth_token'] as String;

  Future<Map<String, dynamic>> me() async {
    final u = await request('GET', '/v1/me') as Map<String, dynamic>;
    await tokens.saveUser(u);
    return u;
  }

  Future<List<dynamic>> sessions() async => await request('GET', '/v1/me/sessions') as List<dynamic>;
  Future<void> revokeSession(String id) => request('DELETE', '/v1/me/sessions/$id');

  // ---- consent / lifecycle
  Future<void> recordConsent(String kind, bool granted, String policyVersion) =>
      request('POST', '/v1/me/consents', body: {'kind': kind, 'granted': granted, 'policy_version': policyVersion, 'source': 'app'}, idempotencyKey: const Uuid().v4());
  Future<Map<String, dynamic>> consents() async => await request('GET', '/v1/me/consents') as Map<String, dynamic>;
  Future<Map<String, dynamic>> requestExport(String reauthToken) async => await request('POST', '/v1/me/export', reauthToken: reauthToken, idempotencyKey: const Uuid().v4()) as Map<String, dynamic>;
  Future<Map<String, dynamic>> job(String id) async => await request('GET', '/v1/jobs/$id') as Map<String, dynamic>;
  Future<Map<String, dynamic>?> deleteAccount(String reauthToken) async => await request('DELETE', '/v1/me', reauthToken: reauthToken) as Map<String, dynamic>?;

  // ---- sync
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> ops, String idempotencyKey) async =>
      await request('POST', '/v1/sync/push', body: {'device_id': await tokens.deviceId(), 'ops': ops}, idempotencyKey: idempotencyKey) as Map<String, dynamic>;
  Future<Map<String, dynamic>> pull(String? cursor, {int limit = 500}) async =>
      await request('GET', '/v1/sync/pull', query: {if (cursor != null) 'cursor': cursor, 'limit': '$limit'}) as Map<String, dynamic>;

  // ---- AI / voice / samples
  Future<Map<String, dynamic>> extract(String text, {String? sender, String? localeHint}) async =>
      await request('POST', '/v1/ingest/extract', body: {'text': text, if (sender != null) 'sender': sender, if (localeHint != null) 'locale_hint': localeHint}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> assistantTurn(Map<String, dynamic> body) async => await request('POST', '/v1/assistant/turn', body: body, retries: 0) as Map<String, dynamic>;
  Future<Map<String, dynamic>> assistantPlan(Map<String, dynamic> body) async => await request('POST', '/v1/assistant/plan', body: body, retries: 0) as Map<String, dynamic>;
  Future<Map<String, dynamic>> voiceToken() async => await request('POST', '/v1/voice/token') as Map<String, dynamic>;
  Future<Map<String, dynamic>> voiceConfig() async => await request('GET', '/v1/voice/config') as Map<String, dynamic>;
  Future<Map<String, dynamic>> submitSample(Map<String, dynamic> body) async => await request('POST', '/v1/samples', body: body, idempotencyKey: const Uuid().v4()) as Map<String, dynamic>;

  /// Upload a statement (PDF/CSV/image ≤ 10 MB) for server-side extraction. Returns a Job;
  /// poll [job] until `status` is succeeded/failed. The server deletes the file after
  /// extraction.
  Future<Map<String, dynamic>> uploadDocument(List<int> bytes, String filename) async {
    if (!configured) throw ApiException(0, 'cloud_not_configured', 'Backend URL not configured');
    await _ensureFresh();
    final req = http.MultipartRequest('POST', _u('/v1/ingest/document'))
      ..headers['authorization'] = 'Bearer ${await tokens.access()}'
      ..headers['idempotency-key'] = const Uuid().v4()
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 60)));
    if (res.statusCode >= 400) throw _err(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ---- households
  Future<List<dynamic>> households() async => await request('GET', '/v1/households') as List<dynamic>;
  Future<Map<String, dynamic>> createHousehold(String name) async => await request('POST', '/v1/households', body: {'name': name}, idempotencyKey: const Uuid().v4()) as Map<String, dynamic>;
  Future<Map<String, dynamic>> invite(String householdId, String role) async =>
      await request('POST', '/v1/households/$householdId/invitations', body: {'role': role}, idempotencyKey: const Uuid().v4()) as Map<String, dynamic>;
  Future<Map<String, dynamic>> joinHousehold(String code) async => await request('POST', '/v1/households/join', body: {'code': code}) as Map<String, dynamic>;
  Future<void> removeMember(String householdId, String userId) => request('DELETE', '/v1/households/$householdId/members/$userId');

  // ---- billing
  Future<Map<String, dynamic>> billingProducts() async => await request('GET', '/v1/billing/products') as Map<String, dynamic>;
  Future<Map<String, dynamic>> verifyApple(String signedTransaction) async => await request('POST', '/v1/billing/apple/verify', body: {'signed_transaction': signedTransaction}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> verifyGoogle(String productId, String token) async =>
      await request('POST', '/v1/billing/google/verify', body: {'product_id': productId, 'purchase_token': token}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> restore(String platform, {List<String> signed = const [], List<String> tokens = const []}) async =>
      await request('POST', '/v1/billing/restore', body: {'platform': platform, 'signed_transactions': signed, 'purchase_tokens': tokens}) as Map<String, dynamic>;
}

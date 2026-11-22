import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../app/config.dart';
import '../api/api_client.dart';

/// Sign-in with Apple / Google. The provider ID token is verified **server-side** (issuer,
/// audience, signature via provider JWKS, expiry and a single-use server nonce). The app
/// only forwards it. Signing in doesn't enable sync: that is a separate consent.
class AuthService {
  final ApiClient api;
  AuthService(this.api);

  bool get available => api.configured;

  static String _sha256(String s) => sha256.convert(utf8.encode(s)).toString();

  Future<Map<String, dynamic>> signInWithApple() async {
    final nonce = await api.nonce();
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: const [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      nonce: _sha256(nonce), // Apple embeds this hash in the identity token
    );
    final token = cred.identityToken;
    if (token == null) throw ApiException(0, 'apple_no_token', 'Apple did not return an identity token');
    final name = [cred.givenName, cred.familyName].whereType<String>().join(' ').trim();
    return api.signInApple(identityToken: token, nonce: nonce, authorizationCode: cred.authorizationCode, fullName: name.isEmpty ? null : name);
  }

  bool _googleInit = false;
  Future<void> _initGoogle(String nonceHash) async {
    // google_sign_in 7.x: initialize once with the server client id whose audience the
    // backend verifies, then authenticate.
    if (!_googleInit) {
      await GoogleSignIn.instance.initialize(
        clientId: AppConfig.googleIosClientId.isEmpty ? null : AppConfig.googleIosClientId,
        serverClientId: AppConfig.googleServerClientId.isEmpty ? null : AppConfig.googleServerClientId,
        nonce: nonceHash,
      );
      _googleInit = true;
    }
  }

  Future<Map<String, dynamic>> signInWithGoogle() async {
    final nonce = await api.nonce();
    await _initGoogle(_sha256(nonce));
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) throw ApiException(0, 'google_no_token', 'Google did not return an ID token');
    return api.signInGoogle(idToken: idToken, nonce: nonce);
  }

  /// Re-authenticate for sensitive operations (export, delete account, link identity).
  Future<String> reauthenticate(String provider) async {
    final nonce = await api.nonce();
    if (provider == 'apple') {
      final cred = await SignInWithApple.getAppleIDCredential(scopes: const [], nonce: _sha256(nonce));
      return api.reauth(provider: 'apple', token: cred.identityToken!, nonce: nonce);
    }
    await _initGoogle(_sha256(nonce));
    final account = await GoogleSignIn.instance.authenticate();
    return api.reauth(provider: 'google', token: account.authentication.idToken!, nonce: nonce);
  }

  Future<void> signOut() async {
    await api.logout();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}

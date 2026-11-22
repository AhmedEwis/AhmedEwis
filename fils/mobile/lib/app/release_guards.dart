/// Release-mode policy as pure functions (unit-tested), used by [AppConfig] consumers.
class ReleaseGuards {
  /// Demo *server sessions* are never offered in production (the server also returns 404).
  static bool demoSessionAllowed(String env) => env != 'production';

  /// Local synthetic demo data: on by default outside production. In production it needs
  /// an explicit FILS_ALLOW_DEMO=true build flag (store-review builds), and is always
  /// labeled "Demo data" in the UI.
  static bool demoDataAllowed(String env, {bool? explicitFlag}) => explicitFlag ?? env != 'production';

  /// All features unlocked only in development/staging. Production relies on verified
  /// store entitlements.
  static bool devUnlock(String env) => env == 'development' || env == 'staging';

  /// Problems that must block a production build. Empty = OK.
  static List<String> productionConfigProblems({required String env, required String apiBaseUrl, required String googleServerClientId}) {
    if (env != 'production') return const [];
    final p = <String>[];
    if (apiBaseUrl.isEmpty) p.add('FILS_API_BASE_URL is required');
    if (apiBaseUrl.isNotEmpty && !apiBaseUrl.startsWith('https://')) p.add('FILS_API_BASE_URL must be https');
    if (googleServerClientId.isEmpty) p.add('FILS_GOOGLE_SERVER_CLIENT_ID is required');
    return p;
  }
}

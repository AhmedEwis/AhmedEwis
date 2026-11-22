import 'release_guards.dart';

/// Build-time configuration via `--dart-define` (or `--dart-define-from-file=env/<env>.json`).
/// No secrets belong here: everything below is safe to ship in the app binary.
class AppConfig {
  static const appNameEn = String.fromEnvironment('FILS_APP_NAME_EN', defaultValue: 'Fils');
  static const appNameAr = String.fromEnvironment('FILS_APP_NAME_AR', defaultValue: 'فلس');

  /// development | staging | production
  static const environment = String.fromEnvironment('FILS_ENV', defaultValue: 'development');
  static bool get isProduction => environment == 'production';

  /// Backend base URL, e.g. https://api.staging.fils.example. Empty = cloud not configured.
  static const apiBaseUrl = String.fromEnvironment('FILS_API_BASE_URL', defaultValue: '');
  static bool get cloudConfigured => apiBaseUrl.isNotEmpty;

  /// Google Sign-In: the server client id (web OAuth client) whose audience the backend verifies.
  static const googleServerClientId = String.fromEnvironment('FILS_GOOGLE_SERVER_CLIENT_ID', defaultValue: '');
  static const googleIosClientId = String.fromEnvironment('FILS_GOOGLE_IOS_CLIENT_ID', defaultValue: '');

  /// In-app purchase product ids (configured in App Store Connect / Play Console).
  /// Must match the backend's FILS_APPLE_PRODUCT_IDS / FILS_GOOGLE_PRODUCT_IDS.
  static const proMonthlyProductId = String.fromEnvironment('FILS_IAP_MONTHLY', defaultValue: 'kw.fils.premium.monthly');
  static const proYearlyProductId = String.fromEnvironment('FILS_IAP_YEARLY', defaultValue: 'kw.fils.premium.yearly');
  /// Google Play: one subscription product with monthly/yearly base plans.
  static const googleSubscriptionId = String.fromEnvironment('FILS_IAP_GOOGLE', defaultValue: 'kw.fils.premium');

  /// Android build flavor: `play` (no SMS permission) or `sms` (SMS permission build for
  /// distribution only after Google Play's SMS permission declaration is approved).
  static const androidFlavor = String.fromEnvironment('FILS_ANDROID_FLAVOR', defaultValue: 'play');

  /// Demo mode with synthetic data is available outside production builds, and in
  /// production only as the clearly labeled store-review demo.
  static const _allowDemoSet = bool.hasEnvironment('FILS_ALLOW_DEMO');
  static const _allowDemoFlag = bool.fromEnvironment('FILS_ALLOW_DEMO');
  static bool get allowDemo => ReleaseGuards.demoDataAllowed(environment, explicitFlag: _allowDemoSet ? _allowDemoFlag : null);
  static bool get allowDemoSession => ReleaseGuards.demoSessionAllowed(environment);
  static bool get devUnlock => ReleaseGuards.devUnlock(environment);

  static const privacyPolicyUrl = String.fromEnvironment('FILS_PRIVACY_URL', defaultValue: 'https://fils.example/privacy');
  static const supportUrl = String.fromEnvironment('FILS_SUPPORT_URL', defaultValue: 'https://fils.example/support');
  static const policyVersion = '2026-11-22';
}

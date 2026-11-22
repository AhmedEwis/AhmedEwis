import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';

import '../../app/config.dart';
import '../api/api_client.dart';

enum Plan { free, premium }

class Entitlements {
  final Plan plan;
  final String source; // dev_unlocked | apple | google | none
  final DateTime? expiresAt;
  final bool inGracePeriod;
  const Entitlements(this.plan, this.source, {this.expiresAt, this.inGracePeriod = false});

  static const devUnlocked = Entitlements(Plan.premium, 'dev_unlocked');
  static const free = Entitlements(Plan.free, 'none');

  factory Entitlements.fromJson(Map<String, dynamic> j) => Entitlements(
        j['plan'] == 'premium' ? Plan.premium : Plan.free,
        j['source'] as String? ?? 'none',
        expiresAt: DateTime.tryParse(j['expires_at'] as String? ?? ''),
        inGracePeriod: j['in_grace_period'] == true,
      );

  bool get isPremium => plan == Plan.premium;
}

/// Platform billing (StoreKit / Google Play Billing) with server-side verification.
/// Entitlements are granted only after the backend verifies the signed transaction or
/// purchase token. The app never self-grants a purchase. Development and staging builds
/// unlock everything.
class BillingService {
  final ApiClient api;
  final InAppPurchase _iap;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final _ent = StreamController<Entitlements>.broadcast();
  Entitlements current = AppConfig.isProduction ? Entitlements.free : Entitlements.devUnlocked;

  BillingService(this.api, {InAppPurchase? iap}) : _iap = iap ?? InAppPurchase.instance;

  Stream<Entitlements> get entitlements => _ent.stream;

  Future<void> start() async {
    if (!AppConfig.isProduction) return; // dev/staging: unlocked, no store calls
    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
  }

  Future<void> dispose() async => _sub?.cancel();

  Future<bool> storeAvailable() async => AppConfig.isProduction && await _iap.isAvailable();

  Future<List<ProductDetails>> products() async {
    if (!await storeAvailable()) return const [];
    final r = await _iap.queryProductDetails({AppConfig.proMonthlyProductId, AppConfig.proYearlyProductId});
    return r.productDetails;
  }

  /// [accountToken]: user id (Apple appAccountToken) / sha256(user id) (Google obfuscated
  /// account id). The server checks it, so one purchase can't be claimed by another account.
  Future<void> buy(ProductDetails p, {required String accountToken}) async {
    final param = PurchaseParam(productDetails: p, applicationUserName: accountToken);
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  Future<void> restore() async {
    if (!await storeAvailable()) return;
    await _iap.restorePurchases();
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      if (p.status == PurchaseStatus.pending) continue;
      if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) {
        try {
          final res = Platform.isIOS
              ? await api.verifyApple(p.verificationData.serverVerificationData)
              : await api.verifyGoogle(p.productID, p.verificationData.serverVerificationData);
          current = Entitlements.fromJson(res);
          _ent.add(current);
        } catch (_) {
          // Unverified purchase: leave entitlement unchanged. Retried on next launch/restore.
          continue;
        }
      }
      if (p.pendingCompletePurchase) await _iap.completePurchase(p);
    }
  }

  Future<void> refreshFromServer() async {
    if (!AppConfig.isProduction || !api.configured) return;
    try {
      final me = await api.me();
      if (me['entitlements'] is Map) {
        current = Entitlements.fromJson((me['entitlements'] as Map).cast<String, dynamic>());
        _ent.add(current);
      }
    } catch (_) {}
  }
}

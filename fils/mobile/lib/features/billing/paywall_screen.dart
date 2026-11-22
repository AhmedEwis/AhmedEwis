import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../app/config.dart';
import '../../app/services.dart';
import '../../l10n/strings.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/common.dart';
import '../auth/sign_in_sheet.dart';

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});
  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  List<ProductDetails> products = const [];
  bool loading = true;
  bool storeOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = ref.read(billingProvider);
    final ok = await b.storeAvailable().catchError((_) => false);
    final ps = ok ? await b.products().catchError((_) => <ProductDetails>[]) : <ProductDetails>[];
    if (mounted) setState(() {
      storeOk = ok;
      products = ps;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = context.fp;
    final billing = ref.watch(billingProvider);
    final ent = billing.current;
    final session = ref.watch(sessionProvider).value;
    final features = s.ar
        ? ['التقاط تلقائي غير محدود', 'أسئلة ذكية غير محدودة', 'الإدخال الصوتي', 'المشاركة العائلية', 'التصدير والنسخ السحابي']
        : ['Unlimited auto-capture', 'Unlimited AI questions', 'Voice entry', 'Household sharing', 'Export & cloud backup'];
    return Scaffold(
      appBar: AppBar(title: Text(s.proTitle)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Center(child: Text('👑', style: TextStyle(fontSize: 56))),
        Center(child: Text(s.proTitle, style: context.tt.headlineMedium)),
        const SizedBox(height: 6),
        Center(child: Text(s.proBody, textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: p.inkSecondary))),
        const SizedBox(height: 20),
        FCard(child: Column(children: [for (final f in features) ListTile(dense: true, leading: Icon(Icons.check_circle, color: p.positive), title: Text(f))])),
        const SizedBox(height: 16),
        FCard(
          child: Row(children: [
            Text(s.currentPlan, style: context.tt.bodyMedium),
            const Spacer(),
            Pill(ent.isPremium ? s.planPremium : s.planFree, bg: ent.isPremium ? p.positiveBg : null, fg: ent.isPremium ? p.positive : null),
          ]),
        ),
        if (ent.source == 'dev_unlocked') Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.devUnlocked, textAlign: TextAlign.center, style: TextStyle(color: p.warning))),
        const SizedBox(height: 16),
        if (loading) const Center(child: CircularProgressIndicator()),
        if (!loading && AppConfig.isProduction && !storeOk) Text(s.storeUnavailable, textAlign: TextAlign.center),
        for (final prod in products)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: FilledButton(
              onPressed: session == null
                  ? () => showSignInSheet(context, ref)
                  : () {
                      final uid = session['id'] as String;
                      // Apple: appAccountToken = user id (UUID). Google: sha256(user id).
                      final token = Platform.isIOS ? uid : sha256.convert(utf8.encode(uid)).toString();
                      billing.buy(prod, accountToken: token);
                    },
              child: Text('${prod.title} · ${prod.price}'),
            ),
          ),
        if (AppConfig.isProduction) TextButton(onPressed: () => billing.restore(), child: Text(s.restorePurchases)),
        const SizedBox(height: 8),
        Text(
          s.ar
              ? 'الاشتراك يتجدد تلقائياً ويُدار من إعدادات ${Platform.isIOS ? 'Apple ID' : 'Google Play'}. الأسعار تأتي من المتجر.'
              : 'Subscriptions renew automatically and are managed in your ${Platform.isIOS ? 'Apple ID' : 'Google Play'} settings. Prices come from the store.',
          textAlign: TextAlign.center,
          style: context.tt.bodySmall?.copyWith(color: p.inkSecondary),
        ),
      ]),
    );
  }
}

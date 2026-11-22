import 'package:flutter/widgets.dart';

import '../app/config.dart';

/// Typed, bilingual UI strings. Arabic is written in neutral Gulf-friendly Modern
/// Standard Arabic, with Kuwaiti phrasing where it reads naturally.
class S {
  final bool ar;
  const S(this.ar);

  static S of(BuildContext context) => S(Localizations.localeOf(context).languageCode == 'ar');

  String _(String en, String arabic) => ar ? arabic : en;

  // App
  String get appName => ar ? AppConfig.appNameAr : AppConfig.appNameEn;
  String get demoBadge => _('Demo data', 'بيانات تجريبية');

  // Navigation
  String get navWallet => _('Wallet', 'المحفظة');
  String get navWealth => _('Wealth', 'الثروة');
  String get navPlans => _('Plans', 'الخطط');
  String get navAsk => _('Ask', 'اسأل');

  // Home
  String get spent => _('Spent', 'المصروف');
  String get income => _('Income', 'الدخل');
  String todayAmount(String a) => _('$a today', '$a اليوم');
  String get allAccounts => _('All Accounts', 'كل الحسابات');
  String get balance => _('Balance', 'الرصيد');
  String youOwe(String a) => _('You owe $a', 'عليك $a');
  String get add => _('Add', 'إضافة');
  String get voice => _('Voice', 'صوت');
  String get import => _('Import', 'استيراد');
  String get more => _('More', 'المزيد');
  String get accounts => _('Accounts', 'الحسابات');
  String get seeAll => _('See all', 'عرض الكل');
  String get recentTransactions => _('Recent Transactions', 'آخر العمليات');
  String viewAll(int n) => _('View all $n', 'عرض الكل ($n)');
  String get leftUntilPayday => _('Left until payday', 'المتبقي حتى الراتب');
  String daysLeft(int d) => _(d == 1 ? '1 day' : '$d days', d == 1 ? 'يوم واحد' : (d == 2 ? 'يومين' : '$d أيام'));
  String get budgetThisCycle => _('Budget this cycle', 'ميزانية هذه الدورة');
  String get captureStatus => _('Auto-capture', 'الالتقاط التلقائي');
  String lastCaptured(String when) => _('Last captured $when', 'آخر التقاط $when');
  String get neverCaptured => _('Not set up yet', 'لم يتم الإعداد بعد');
  String get setUp => _('Set up', 'إعداد');
  String reviewPending(int n) => _('$n to review', '$n بانتظار المراجعة');
  String get calculatedBalanceNote => _('Calculated from your transactions, not a live bank balance.', 'محسوب من عملياتك، وليس رصيداً مباشراً من البنك.');
  String bankReported(String a, String when) => _('Bank said $a · $when', 'حسب البنك $a · $when');

  // Periods
  String get thisCycle => _('This cycle', 'هذه الدورة');
  String get thisMonth => _('This month', 'هذا الشهر');
  String get lastMonth => _('Last month', 'الشهر الماضي');
  String get custom => _('Custom', 'مخصص');
  String get today => _('Today', 'اليوم');
  String get yesterday => _('Yesterday', 'أمس');

  // Transactions
  String get transactions => _('Transactions', 'العمليات');
  String get search => _('Search', 'بحث');
  String get searchHint => _('Search merchant or note', 'ابحث عن تاجر أو ملاحظة');
  String get filters => _('Filters', 'تصفية');
  String get noTransactions => _('No transactions yet', 'لا توجد عمليات بعد');
  String get noTransactionsBody => _('Set up auto-capture or add one by voice.', 'فعّل الالتقاط التلقائي أو أضف عملية بصوتك.');
  String get reviewInbox => _('Review inbox', 'صندوق المراجعة');
  String get reviewEmpty => _('Nothing to review. Nice!', 'لا يوجد شيء للمراجعة 👌');
  String get needsReview => _('Needs review', 'بحاجة لمراجعة');
  String get pending => _('Pending', 'معلقة');
  String get declined => _('Declined', 'مرفوضة');
  String get voided => _('Voided', 'ملغاة');
  String get transfer => _('Transfer', 'تحويل');
  String get refund => _('Refund', 'استرداد');
  String get adjustment => _('Adjustment', 'تسوية');
  String get expense => _('Expense', 'مصروف');
  String get incomeKind => _('Income', 'دخل');
  String get amount => _('Amount', 'المبلغ');
  String get merchant => _('Merchant', 'التاجر');
  String get category => _('Category', 'الفئة');
  String get account => _('Account', 'الحساب');
  String get toAccount => _('To account', 'إلى حساب');
  String get date => _('Date', 'التاريخ');
  String get note => _('Note', 'ملاحظة');
  String get save => _('Save', 'حفظ');
  String get cancel => _('Cancel', 'إلغاء');
  String get delete => _('Delete', 'حذف');
  String get undo => _('Undo', 'تراجع');
  String get done => _('Done', 'تم');
  String get edit => _('Edit', 'تعديل');
  String get confirm => _('Confirm', 'تأكيد');
  String get retry => _('Retry', 'إعادة المحاولة');
  String get close => _('Close', 'إغلاق');
  String get next => _('Next', 'التالي');
  String get back => _('Back', 'رجوع');
  String get skip => _('Skip', 'تخطي');
  String get deleted => _('Deleted', 'تم الحذف');
  String get saved => _('Saved', 'تم الحفظ');
  String get split => _('Split', 'تقسيم');
  String get splitTransaction => _('Split transaction', 'تقسيم العملية');
  String get splitsMustMatch => _('Splits must add up to the total.', 'يجب أن يساوي مجموع الأجزاء المبلغ الكلي.');
  String get recordRefund => _('Record refund', 'تسجيل استرداد');
  String get linkTransfer => _('Link as transfer', 'ربط كتحويل');
  String get linkTransferBody => _('Pick the matching incoming transaction on another account.', 'اختر العملية الواردة المطابقة في حساب آخر.');
  String get rememberCategory => _('Always use this category for this merchant', 'استخدم هذه الفئة دائماً لهذا التاجر');
  String get source => _('Source', 'المصدر');
  String get parser => _('Parser', 'المحلل');
  String get confidence => _('Confidence', 'الثقة');
  String get originalAmount => _('Original amount', 'المبلغ الأصلي');
  String get fxRateLabel => _('Exchange rate', 'سعر الصرف');
  String get billedByBank => _('Billed amount from bank message', 'المبلغ المحسوب من رسالة البنك');
  String get receivedAt => _('Received', 'وقت الاستلام');
  String get occurredAt => _('Transaction time', 'وقت العملية');
  String get markReviewed => _('Looks right', 'صحيحة');
  String get selectMultiple => _('Select', 'تحديد');
  String nSelected(int n) => _('$n selected', 'تم تحديد $n');
  String get changeCategory => _('Change category', 'تغيير الفئة');
  String get sourceLabelSms => _('Bank SMS', 'رسالة البنك');
  String get sourceLabelNotification => _('App notification', 'إشعار تطبيق');
  String get sourceLabelShortcut => _('iPhone Shortcut', 'اختصار آيفون');
  String get sourceLabelWallet => _('Apple Pay (Wallet)', 'Apple Pay (المحفظة)');
  String get sourceLabelManual => _('Added manually', 'إضافة يدوية');
  String get sourceLabelVoice => _('Voice', 'صوت');
  String get sourceLabelImport => _('Import', 'استيراد');
  String get sourceLabelPaste => _('Pasted text', 'نص ملصق');

  // Accounts
  String get addAccount => _('Add account', 'إضافة حساب');
  String get accountName => _('Account name', 'اسم الحساب');
  String get bank => _('Bank', 'البنك');
  String get otherBank => _('Other / none', 'أخرى / بدون');
  String get accountType => _('Type', 'النوع');
  String get typeBank => _('Bank account', 'حساب بنكي');
  String get typeCard => _('Card', 'بطاقة');
  String get typeCash => _('Cash wallet', 'محفظة كاش');
  String get typeSavings => _('Savings', 'توفير');
  String get typeWallet => _('E-wallet', 'محفظة إلكترونية');
  String get typeLoan => _('Loan', 'قرض');
  String get last4 => _('Last 4 digits', 'آخر 4 أرقام');
  String get last4Help => _('Used to route captured messages to this account. Never enter the full number.', 'تُستخدم لتوجيه الرسائل لهذا الحساب. لا تدخل الرقم كاملاً.');
  String get currency => _('Currency', 'العملة');
  String get openingBalance => _('Opening balance', 'الرصيد الافتتاحي');
  String get openingBalanceDate => _('Balance as of', 'الرصيد بتاريخ');
  String get creditCardLiability => _('Credit card (money owed)', 'بطاقة ائتمانية (مبلغ مستحق)');
  String get creditLimit => _('Credit limit', 'الحد الائتماني');
  String get archive => _('Archive', 'أرشفة');
  String get unarchive => _('Unarchive', 'إلغاء الأرشفة');
  String get reconcile => _('Reconcile', 'مطابقة الرصيد');
  String get reconcileBody => _('Enter the balance your bank shows now. We will add an adjustment that does not count as spending.', 'أدخل الرصيد الظاهر في البنك الآن. سنضيف تسوية لا تُحسب كمصروف.');
  String get actualBalance => _('Actual balance', 'الرصيد الفعلي');
  String get calculatedBalance => _('Calculated balance', 'الرصيد المحسوب');
  String get lastBankBalance => _('Last bank-reported balance', 'آخر رصيد من البنك');
  String get availableBalance => _('Available', 'المتاح');
  String get defaultAccount => _('Default', 'افتراضي');
  String get setAsPayer => _('Pays my credit cards', 'يسدد بطاقاتي الائتمانية');

  // Budgets / plans
  String get budgets => _('Budgets', 'الميزانيات');
  String get goals => _('Goals', 'الأهداف');
  String get recurring => _('Recurring', 'المتكررة');
  String get installments => _('Installments', 'الأقساط');
  String get subscriptions => _('Subscriptions', 'الاشتراكات');
  String get addBudget => _('Add budget', 'إضافة ميزانية');
  String get overallBudget => _('Overall', 'إجمالي');
  String get limit => _('Limit', 'الحد');
  String get rollover => _('Roll over unused amount', 'ترحيل المبلغ غير المستخدم');
  String get alertsAt => _('Alert at', 'تنبيه عند');
  String left(String a) => _('$a left', 'متبقي $a');
  String over(String a) => _('$a over', 'تجاوز $a');
  String get budgetsEmpty => _('No budgets yet. Set a limit for any category.', 'لا توجد ميزانيات. حدد سقفاً لأي فئة.');
  String get budgetNote => _('Refunds reduce usage; transfers between your accounts never count.', 'المبالغ المستردة تقلل الاستخدام، والتحويلات بين حساباتك لا تُحسب.');
  String get addGoal => _('Create goal', 'إنشاء هدف');
  String get goalName => _('Goal name', 'اسم الهدف');
  String get targetAmount => _('Target amount', 'المبلغ المستهدف');
  String get targetDate => _('Target date', 'التاريخ المستهدف');
  String get plannedMonthly => _('Planned monthly contribution', 'المساهمة الشهرية المخططة');
  String get addMoney => _('Add money', 'إضافة مبلغ');
  String get takeOut => _('Take out', 'سحب');
  String get totalSaved => _('Total saved', 'إجمالي المدخر');
  String needsPerMonth(String a) => _('Needs $a a month to make it', 'تحتاج $a شهرياً لتحقيقه');
  String reachBy(String d) => _('At this pace: $d', 'بهذا المعدل: $d');
  String get goalsEmpty => _('Create a goal and track every dinar towards it.', 'أنشئ هدفاً وتابع كل دينار نحوه.');
  String get goalAssumption => _('Estimate assumes your planned contribution stays constant and no returns.', 'التقدير يفترض ثبات المساهمة الشهرية وبدون عوائد.');
  String get addRecurring => _('Add recurring', 'إضافة التزام متكرر');
  String get perMonth => _('Per month', 'شهرياً');
  String activeN(int n) => _('$n active', '$n نشطة');
  String get upcoming => _('Coming up', 'القادمة');
  String inDays(int d) => _(d == 0 ? 'today' : 'in ${d}d', d == 0 ? 'اليوم' : 'بعد $d يوم');
  String get suggested => _('Suggested', 'مقترحة');
  String get suggestedBody => _('We noticed these repeat. Confirm to track them, nothing is posted automatically.', 'لاحظنا أنها تتكرر. أكّد لتتبعها، ولن يُسجل شيء تلقائياً.');
  String get confirmRecurring => _('Track it', 'تتبّع');
  String get dismiss => _('Dismiss', 'تجاهل');
  String get cadenceMonthly => _('Monthly', 'شهري');
  String get cadenceWeekly => _('Weekly', 'أسبوعي');
  String get cadenceYearly => _('Yearly', 'سنوي');
  String get kindSubscription => _('Subscription', 'اشتراك');
  String get kindRent => _('Rent', 'إيجار');
  String get kindInstallment => _('Installment', 'قسط');
  String get kindBill => _('Bill', 'فاتورة');
  String get kindSalary => _('Salary', 'راتب');
  String get kindOther => _('Other', 'أخرى');
  String paymentsProgress(int a, int b) => _('$a of $b payments', '$a من $b دفعات');
  String get remindDaysBefore => _('Remind me (days before)', 'ذكرني (قبل بأيام)');
  String get nextDue => _('Next due', 'الاستحقاق القادم');
  String get recurringEmpty => _('Track rent, installments, bills and subscriptions.', 'تابع الإيجار والأقساط والفواتير والاشتراكات.');
  String get markPaid => _('Mark as paid', 'تحديد كمدفوع');

  // Analytics
  String get insights => _('Insights', 'التحليلات');
  String get byCategory => _('By category', 'حسب الفئة');
  String get byMerchant => _('Top merchants', 'أعلى التجار');
  String get cashFlow => _('Cash flow', 'التدفق النقدي');
  String get comparePrevious => _('vs previous', 'مقارنة بالسابقة');
  String get spentByCategory => _('SPENT BY CATEGORY', 'المصروف حسب الفئة');
  String get total => _('Total', 'الإجمالي');
  String showAllN(int n) => _('Show all $n', 'عرض الكل ($n)');
  String get net => _('Net', 'الصافي');
  String get dailySpending => _('Daily spending', 'المصروف اليومي');
  String get noDataPeriod => _('No spending in this period.', 'لا يوجد مصروف في هذه الفترة.');
  String otherCurrencies(String s) => _('Also spent: $s (not combined)', 'مصروف آخر: $s (غير مدمج)');

  // Wealth
  String get wealth => _('Wealth', 'الثروة');
  String get netWorth => _('Net worth', 'صافي الثروة');
  String get assets => _('Assets', 'الأصول');
  String get debt => _('Debt', 'الديون');
  String get addAsset => _('Add asset or debt', 'إضافة أصل أو دين');
  String get spendable => _('SPENDABLE', 'قابل للصرف');
  String get valuationDate => _('Valued on', 'تاريخ التقييم');
  String get manualValue => _('Manual value', 'قيمة يدوية');
  String get wealthNote => _('Asset values are what you entered; we do not fetch live prices.', 'قيم الأصول كما أدخلتها، ولا نجلب أسعاراً مباشرة.');
  String get linkedToAccount => _('Already tracked as an account (not double-counted)', 'متتبع كحساب (لا يُحسب مرتين)');
  String get assetGold => _('Gold & silver', 'ذهب وفضة');
  String get assetProperty => _('Property', 'عقار');
  String get assetVehicle => _('Vehicle', 'سيارة');
  String get assetInvestment => _('Investments', 'استثمارات');
  String get assetDeposit => _('Deposit / certificate', 'وديعة');
  String get assetOther => _('Other', 'أخرى');
  String get assetLoan => _('Loan / debt', 'قرض / دين');

  // Assistant
  String get askTitle => _('Ask Fils', 'اسأل فلس');
  String get askHint => _('Ask anything about your money…', 'اسأل أي شيء عن فلوسك…');
  String get askSuggest1 => _('Where did my money go this month?', 'وين راحت فلوسي هالشهر؟');
  String get askSuggest2 => _("What's left until payday?", 'كم باقي لي لين الراتب؟');
  String get askSuggest3 => _('How much did I spend on Talabat?', 'كم صرفت على طلبات؟');
  String get askSuggest4 => _('What are my recurring payments?', 'شنو اشتراكاتي المتكررة؟');
  String get askSuggest5 => _('Why did spending go up this month?', 'ليش زاد المصروف هالشهر؟');
  String get askSuggest6 => _('If I save 50 KD a month, when do I reach my goal?', 'لو وفرت ٥٠ دينار بالشهر متى أوصل لهدفي؟');
  String get assistantOffline => _('Answered on your device.', 'تمت الإجابة على جهازك.');
  String get assistantCloud => _('Answered with cloud AI using totals only.', 'تمت الإجابة بالذكاء السحابي باستخدام الإجماليات فقط.');
  String get assistantCloudOff => _('Cloud AI is off. Common questions are answered on your device.', 'الذكاء السحابي متوقف. الأسئلة الشائعة تُجاب على جهازك.');
  String get assistantDidNotUnderstand => _("I couldn't answer that on the device. Try one of the suggestions, or turn on cloud AI in Settings.", 'لم أستطع الإجابة على الجهاز. جرّب أحد الاقتراحات أو فعّل الذكاء السحابي من الإعدادات.');
  String get newChat => _('New chat', 'محادثة جديدة');

  // Voice
  String get voiceTitle => _('Just say it', 'قلها بس');
  String get voiceHint => _('e.g. "دفعت خمسة دنانير وربع على طلبات"', 'مثال: "دفعت خمسة دنانير وربع على طلبات"');
  String get listening => _('Listening…', 'أسمعك…');
  String get tapToSpeak => _('Hold to talk', 'اضغط مطولاً للتحدث');
  String get processing => _('Understanding…', 'جاري الفهم…');
  String get voiceMicDenied => _('Microphone access is off. Enable it in Settings to use voice.', 'الوصول للميكروفون متوقف. فعّله من الإعدادات لاستخدام الصوت.');
  String get voiceNoSpeech => _("I didn't catch that. Try again.", 'ما سمعتك زين، حاول مرة ثانية.');
  String get voiceUnavailable => _('Speech recognition is not available on this device. Type instead.', 'التعرف على الكلام غير متاح على هذا الجهاز. اكتب بدلاً من ذلك.');
  String get voiceDraft => _('Check and save', 'راجع واحفظ');
  String get transcript => _('What I heard', 'ما سمعته');
  String get typeInstead => _('Type instead', 'اكتب بدلاً من ذلك');
  String get voiceAmountMissing => _('I could not find an amount. Please enter it.', 'لم أجد المبلغ، يرجى إدخاله.');
  String get stop => _('Stop', 'إيقاف');
  String get recordingIndicator => _('Recording', 'جاري التسجيل');

  // Capture setup
  String get captureSetup => _('Auto-capture setup', 'إعداد الالتقاط التلقائي');
  String get iosShortcutTitle => _('Bank SMS via Shortcuts', 'رسائل البنك عبر الاختصارات');
  String get iosShortcutBody => _(
      'iPhone apps cannot read your messages. You create a personal automation once: when a message arrives from your bank, Shortcuts sends its text to Fils.',
      'تطبيقات الآيفون لا تستطيع قراءة رسائلك. ستنشئ أتمتة شخصية مرة واحدة: عند وصول رسالة من البنك، يرسل تطبيق الاختصارات نصها إلى فلس.');
  String get iosWalletTitle => _('Apple Pay via Wallet automation', 'Apple Pay عبر أتمتة المحفظة');
  String get iosWalletBody => _(
      'Optional: a Transaction automation sends merchant and amount when you tap to pay. It does not cover every card or every purchase.',
      'اختياري: أتمتة "المعاملة" ترسل التاجر والمبلغ عند الدفع. لا تغطي كل البطاقات أو كل المشتريات.');
  String get androidNotifTitle => _('Bank app notifications', 'إشعارات تطبيقات البنوك');
  String get androidNotifBody => _(
      'Allow Fils to read notifications from the bank apps you choose. Everything else is ignored and never stored.',
      'اسمح لفلس بقراءة إشعارات تطبيقات البنوك التي تختارها فقط. يتم تجاهل أي شيء آخر ولا يُخزن.');
  String get androidSmsTitle => _('Bank SMS (direct)', 'رسائل البنك (مباشرة)');
  String get androidSmsUnavailable => _('Not available in this build (Google Play SMS policy). Use bank app notifications or paste.', 'غير متاحة في هذا الإصدار (سياسة رسائل Google Play). استخدم إشعارات تطبيق البنك أو اللصق.');
  String get pasteTitle => _('Paste a message', 'لصق رسالة');
  String get pasteBody => _('Paste one or more bank messages to import them.', 'الصق رسالة بنكية أو أكثر لاستيرادها.');
  String get importFileTitle => _('Import CSV or statement', 'استيراد CSV أو كشف حساب');
  String get sendTest => _('Send a test message', 'إرسال رسالة تجريبية');
  String get testReceived => _('Test received! Capture works.', 'تم استلام الرسالة التجريبية! الالتقاط يعمل.');
  String get waitingForTest => _('Waiting for the test from Shortcuts…', 'بانتظار الرسالة التجريبية من الاختصارات…');
  String get openShortcuts => _('Open Shortcuts', 'افتح الاختصارات');
  String get troubleshooting => _('Troubleshooting', 'حل المشاكل');
  String get permissionGranted => _('Permission granted', 'تم منح الإذن');
  String get permissionMissing => _('Permission not granted', 'لم يُمنح الإذن');
  String get openSettings => _('Open settings', 'افتح الإعدادات');
  String get chooseBankApps => _('Choose bank apps', 'اختر تطبيقات البنوك');
  String get monitoring => _('Monitoring', 'قيد المراقبة');
  String get notMonitoring => _('Not monitoring', 'غير مفعّل');
  String get batteryTip => _('If captures stop, exclude Fils from battery optimization.', 'إذا توقف الالتقاط، استثنِ فلس من تحسين البطارية.');
  String get sampleSubmitTitle => _('Help improve bank support', 'ساعد في تحسين دعم البنوك');
  String get sampleSubmitBody => _('Send a sanitized copy of a message we could not read. You review it before sending.', 'أرسل نسخة منقحة من رسالة لم نتمكن من قراءتها. ستراجعها قبل الإرسال.');
  String get sanitizedPreview => _('This is exactly what will be sent:', 'هذا بالضبط ما سيتم إرساله:');
  String get send => _('Send', 'إرسال');
  String get bankCoverage => _('Bank coverage', 'تغطية البنوك');
  String get coverageSynthetic => _('Synthetic-tested', 'مختبر ببيانات اصطناعية');
  String get coverageReal => _('Real-sample tested', 'مختبر بعينات حقيقية');
  String get coverageDevice => _('Device verified', 'موثق على جهاز');
  String get coverageNote => _('No bank has been verified with real messages yet. Formats are handled by a general Kuwait parser.', 'لم يتم التحقق من أي بنك برسائل حقيقية بعد. يتم التعامل مع الصيغ بمحلل عام للكويت.');

  // Settings
  String get settings => _('Settings', 'الإعدادات');
  String get language => _('Language', 'اللغة');
  String get theme => _('Appearance', 'المظهر');
  String get themeSystem => _('System', 'النظام');
  String get themeLight => _('Light', 'فاتح');
  String get themeDark => _('Dark', 'داكن');
  String get arabicDigits => _('Arabic-Indic digits (٠١٢)', 'أرقام هندية (٠١٢)');
  String get salaryDay => _('Salary day (cycle start)', 'يوم الراتب (بداية الدورة)');
  String get baseCurrencyLabel => _('Main currency', 'العملة الرئيسية');
  String get notifications => _('Notifications', 'الإشعارات');
  String get privacy => _('Privacy', 'الخصوصية');
  String get security => _('Security', 'الأمان');
  String get biometricLock => _('Lock with Face ID / fingerprint', 'القفل ببصمة الوجه / الإصبع');
  String get biometricNote => _('App lock hides the app; your data is separately encrypted on the device.', 'قفل التطبيق يخفيه؛ وبياناتك مشفرة بشكل منفصل على الجهاز.');
  String get syncBackup => _('Backup & sync', 'النسخ والمزامنة');
  String get cloudBackup => _('Cloud backup', 'نسخ احتياطي سحابي');
  String get cloudSync => _('Sync across devices', 'مزامنة بين الأجهزة');
  String get cloudAi => _('Cloud AI for questions & unreadable messages', 'ذكاء سحابي للأسئلة والرسائل غير المقروءة');
  String get cloudVoice => _('Cloud speech recognition', 'تعرف سحابي على الكلام');
  String get cloudConsentNote => _('Off by default. Signing in never uploads your data by itself.', 'متوقف افتراضياً. تسجيل الدخول وحده لا يرفع بياناتك.');
  String get rawRetention => _('Keep unreadable messages for review', 'الاحتفاظ بالرسائل غير المقروءة للمراجعة');
  String daysN(int n) => _('$n days', '$n يوم');
  String get exportData => _('Export my data', 'تصدير بياناتي');
  String get importData => _('Import', 'استيراد');
  String get deleteAccount => _('Delete account', 'حذف الحساب');
  String get deleteAccountBody => _('This deletes your Fils account, cloud data and all data on this device. It cannot be undone.', 'سيتم حذف حساب فلس والبيانات السحابية وكل البيانات على هذا الجهاز. لا يمكن التراجع.');
  String get wipeLocal => _('Erase data on this device', 'مسح البيانات من هذا الجهاز');
  String get subscription => _('Fils Pro', 'فلس برو');
  String get support => _('Help & support', 'المساعدة والدعم');
  String get about => _('About', 'حول');
  String get signIn => _('Sign in', 'تسجيل الدخول');
  String get signOut => _('Sign out', 'تسجيل الخروج');
  String get signedInAs => _('Signed in', 'تم تسجيل الدخول');
  String get notSignedIn => _('Not signed in (local only)', 'غير مسجل (محلي فقط)');
  String get signInWithApple => _('Continue with Apple', 'المتابعة مع Apple');
  String get signInWithGoogle => _('Continue with Google', 'المتابعة مع Google');
  String get continueWithoutAccount => _('Continue without an account', 'المتابعة بدون حساب');
  String get tryDemo => _('Explore with demo data', 'جرّب ببيانات تجريبية');
  String get devices => _('Devices & sessions', 'الأجهزة والجلسات');
  String get household => _('Household', 'العائلة');
  String get categories => _('Categories', 'الفئات');
  String get dataAndCapture => _('Capture & data', 'الالتقاط والبيانات');
  String get backendNotConfigured => _('Cloud services are not configured in this build.', 'الخدمات السحابية غير مهيأة في هذا الإصدار.');
  String get syncStatus => _('Sync status', 'حالة المزامنة');
  String pendingChanges(int n) => _('$n changes waiting', '$n تغييرات بالانتظار');
  String get upToDate => _('Up to date', 'محدّث');
  String get syncOff => _('Sync is off', 'المزامنة متوقفة');
  String get syncNow => _('Sync now', 'زامن الآن');
  String get conflicts => _('Conflicts to resolve', 'تعارضات للحل');

  // Onboarding
  String get obTitle1 => _('Every transaction.', 'كل عملية.');
  String get obTitle2 => _('Auto-saved.', 'تُحفظ تلقائياً.');
  String get obSubtitle => _('Bank SMS, app notifications, Apple Pay and your voice. Built for Kuwait.', 'رسائل البنك، إشعارات التطبيقات، Apple Pay وصوتك. مصمم للكويت.');
  String get getStarted => _('Get Started', 'ابدأ الآن');
  String get obPrivacyTitle => _('Your data stays on your phone', 'بياناتك تبقى على جوالك');
  String get obPrivacyBody => _(
      'Fils works fully offline. We never ask for your bank password. Cloud backup, sync and cloud AI are optional and off until you turn them on.',
      'فلس يعمل بالكامل بدون إنترنت. لا نطلب كلمة سر البنك أبداً. النسخ السحابي والمزامنة والذكاء السحابي اختيارية ومتوقفة حتى تفعلها.');
  String get obAccountsTitle => _('Add your accounts', 'أضف حساباتك');
  String get obAccountsBody => _('Add the banks you use. Captured messages also create accounts automatically.', 'أضف البنوك التي تستخدمها. الرسائل الملتقطة تنشئ حسابات تلقائياً أيضاً.');
  String get obSalaryTitle => _('When do you get paid?', 'متى ينزل راتبك؟');
  String get obSalaryBody => _('Your budget cycle runs from payday to payday.', 'دورة ميزانيتك من راتب إلى راتب.');
  String get obCaptureTitle => _('Turn on auto-capture', 'فعّل الالتقاط التلقائي');
  String get obDone => _("You're all set", 'كل شيء جاهز');
  String dayOfMonth(int d) => _('Day $d of each month', 'يوم $d من كل شهر');

  // Household
  String get householdBody => _('Share chosen budgets with the people you live with. Personal transactions stay private unless you share them.', 'شارك ميزانيات محددة مع من تعيش معهم. عملياتك الشخصية تبقى خاصة إلا إذا شاركتها.');
  String get createHousehold => _('Create household', 'إنشاء عائلة');
  String get joinHousehold => _('Join with a code', 'الانضمام برمز');
  String get inviteMember => _('Invite member', 'دعوة عضو');
  String get inviteCode => _('Invite code', 'رمز الدعوة');
  String get members => _('Members', 'الأعضاء');
  String get leave => _('Leave', 'مغادرة');
  String get remove => _('Remove', 'إزالة');
  String get requiresSignInSync => _('Requires sign-in and sync.', 'يتطلب تسجيل الدخول والمزامنة.');

  // Billing
  String get proTitle => _('Fils Pro', 'فلس برو');
  String get proBody => _('Unlimited auto-capture, AI questions, voice and household sharing.', 'التقاط تلقائي غير محدود، أسئلة ذكية، صوت ومشاركة عائلية.');
  String get restorePurchases => _('Restore purchases', 'استعادة المشتريات');
  String get devUnlocked => _('All features unlocked (development build)', 'كل الميزات مفتوحة (إصدار تطوير)');
  String get storeUnavailable => _('The store is not available on this device.', 'المتجر غير متاح على هذا الجهاز.');
  String get manageSubscription => _('Manage subscription', 'إدارة الاشتراك');
  String get currentPlan => _('Current plan', 'الخطة الحالية');
  String get planFree => _('Free', 'مجاني');
  String get planPremium => _('Pro', 'برو');

  // Errors / states
  String get offline => _("You're offline. Everything still works locally.", 'أنت غير متصل. كل شيء يعمل محلياً.');
  String get genericError => _('Something went wrong. Please try again.', 'حدث خطأ، يرجى المحاولة مرة أخرى.');
  String get loading => _('Loading…', 'جاري التحميل…');
  String get required => _('Required', 'مطلوب');
  String get invalidAmount => _('Enter a valid amount', 'أدخل مبلغاً صحيحاً');
  String get locked => _('Fils is locked', 'فلس مقفل');
  String get unlock => _('Unlock', 'فتح القفل');
}

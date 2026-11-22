# Fils Privacy Notice (draft)

> Draft for local legal review before publication. Policy version: 2026-11-22. It describes the app
> as built. Update it whenever behavior changes.

## English

**Who we are.** Fils ("we") makes the Fils personal finance app. Contact: privacy@fils.example
(placeholder).

**The short version**
- Fils works fully on your phone, without an account and without internet.
- We never ask for your bank username, password or card PIN, and Fils cannot move money.
- Cloud backup, sync across devices, cloud AI and cloud speech recognition are **off** until you
  turn each one on. Signing in does not upload your data by itself.

**What stays on your device**
- **Transactions, accounts, budgets, goals and settings** are stored in a database encrypted with
  SQLite3MultipleCiphers. The encryption key is random, kept in the iOS Keychain or Android Keystore,
  and never leaves the device or its backups.
- **Bank messages and notifications.** Fils reads only the text you send it through your Shortcuts
  automation (iPhone), or notifications from the bank apps you choose (Android). It extracts the
  amount, merchant, card's last 4 digits and time, then discards the message text.
  - If a message can't be read reliably, its text is kept, encrypted, for **up to 30 days** so you
    can review it, then deleted automatically. You can shorten this in Settings.
  - **One-time passwords (OTPs) are recognized and never stored.**
- **Voice.** Audio is used only to transcribe what you said. It is not stored.

**What leaves your device, only if you turn it on**

| Feature (consent) | What is sent | Why |
|---|---|---|
| Sign in with Apple or Google | Your Apple/Google account identifier, plus email and name if the provider shares them | Create your Fils account |
| Cloud backup / sync (`cloud_backup`, `cloud_sync`) | Your accounts, transactions, budgets, goals, recurring items, assets and selected settings | Restore and sync across devices and with your household |
| Cloud AI (`cloud_ai`) | Your question, plus **totals computed on your device** (for example "food: KWD 45.250"). For a message Fils couldn't read: the message after on-device removal of OTPs, card and account numbers, phone numbers, emails and names | Answer questions in natural language; read unusual message formats |
| Cloud speech (`cloud_voice`) | Your voice recording, sent directly to Microsoft Azure Speech using a short-lived token | Speech recognition |
| Sample submission (`sample_submission`) | A message we couldn't read, sanitized on your device and shown to you before sending | Improve bank support |

**Security.** Data in transit uses TLS. Cloud data is stored in Microsoft Azure and encrypted at
rest. Cloud sync is **not end-to-end encrypted**: our servers can read synced data in order to sync
it. Access is restricted and logged, and logs exclude message text and tokens.

**Processors.** Microsoft Azure (hosting, database, Azure OpenAI, Azure Speech, Document
Intelligence), Apple and Google (sign-in, in-app purchases). Hosting region: to be confirmed (see
`kuwait-regulatory.md`).

**Your choices and rights.** You can turn any cloud feature off at any time; turning sync off stops
uploads. You can export your data (Settings → Export) and delete your account (Settings → Delete
account). Deletion revokes all sessions immediately and permanently removes your cloud data, normally
within minutes. Database backups are overwritten within the backup retention window (up to 35 days).
Your consent history is kept and shown in Settings.

**Children.** Fils is not intended for children under 13.

**Changes.** We will notify you in the app before material changes take effect.

---

## العربية

**من نحن.** "فلس" هو تطبيق لإدارة المصاريف الشخصية. للتواصل: privacy@fils.example (عنوان مؤقت).

**باختصار**
- يعمل فلس بالكامل على جوالك، بدون حساب وبدون إنترنت.
- لا نطلب أبداً اسم المستخدم أو كلمة السر الخاصة بالبنك أو الرقم السري للبطاقة، ولا يستطيع فلس تحويل أي أموال.
- النسخ الاحتياطي السحابي والمزامنة والذكاء السحابي والتعرف السحابي على الكلام **متوقفة** حتى تفعّل كل ميزة بنفسك. تسجيل الدخول وحده لا يرفع بياناتك.

**ما يبقى على جهازك**
- **العمليات والحسابات والميزانيات والأهداف والإعدادات:** محفوظة في قاعدة بيانات مشفرة (SQLite3MultipleCiphers). مفتاح التشفير عشوائي ومحفوظ في سلسلة مفاتيح iOS أو مخزن مفاتيح Android، ولا يغادر جهازك أو نسخه الاحتياطية.
- **رسائل وإشعارات البنوك:** يقرأ فلس فقط النص الذي ترسله عبر أتمتة الاختصارات (آيفون)، أو إشعارات تطبيقات البنوك التي تختارها (أندرويد). يستخرج المبلغ والتاجر وآخر 4 أرقام من البطاقة والوقت، ثم يتخلص من نص الرسالة.
  - إذا تعذرت قراءة رسالة بدقة، يُحتفظ بنصها مشفراً **لمدة أقصاها 30 يوماً** لتراجعها، ثم يُحذف تلقائياً.
  - **رموز التحقق لمرة واحدة (OTP) يتم التعرف عليها ولا تُخزن أبداً.**
- **الصوت:** يُستخدم فقط لتحويل كلامك إلى نص، ولا يُخزن.

**ما يغادر جهازك، فقط إذا فعّلته**

| الميزة (الموافقة) | ما يُرسل | السبب |
|---|---|---|
| تسجيل الدخول عبر Apple أو Google | معرّف حسابك لدى Apple/Google، والبريد والاسم إذا شاركهما المزود | إنشاء حسابك في فلس |
| النسخ الاحتياطي / المزامنة | حساباتك وعملياتك وميزانياتك وأهدافك والتزاماتك المتكررة وأصولك وإعدادات مختارة | الاستعادة والمزامنة بين أجهزتك ومع عائلتك |
| الذكاء السحابي | سؤالك، مع **إجماليات محسوبة على جهازك** فقط. أما الرسائل غير المقروءة فتُرسل بعد إزالة رموز التحقق وأرقام البطاقات والحسابات والهواتف والبريد والأسماء على جهازك | الإجابة على الأسئلة وقراءة الصيغ غير المعتادة |
| التعرف السحابي على الكلام | تسجيلك الصوتي، يُرسل مباشرة إلى Microsoft Azure Speech برمز مؤقت | التعرف على الكلام |
| إرسال عينات | رسالة لم نتمكن من قراءتها، منقحة على جهازك، وتُعرض عليك قبل الإرسال | تحسين دعم البنوك |

**الأمان.** البيانات أثناء النقل محمية عبر TLS، والبيانات السحابية محفوظة في Microsoft Azure ومشفرة أثناء التخزين. المزامنة السحابية **ليست مشفرة من طرف إلى طرف**: خوادمنا تستطيع قراءة البيانات المتزامنة لتنفيذ المزامنة. الوصول مقيد ومسجل، والسجلات لا تتضمن نصوص الرسائل أو الرموز.

**معالجو البيانات.** Microsoft Azure (الاستضافة وقاعدة البيانات وAzure OpenAI وAzure Speech)، وApple وGoogle (تسجيل الدخول والمشتريات داخل التطبيق).

**خياراتك وحقوقك.** يمكنك إيقاف أي ميزة سحابية في أي وقت. يمكنك تصدير بياناتك (الإعدادات ← تصدير) وحذف حسابك (الإعدادات ← حذف الحساب). الحذف يلغي كل الجلسات فوراً ويزيل بياناتك السحابية نهائياً، وتُستبدل النسخ الاحتياطية خلال فترة الاحتفاظ (حتى 35 يوماً). يُحفظ سجل موافقاتك ويظهر في الإعدادات.

**الأطفال.** التطبيق غير موجه لمن هم دون 13 عاماً.

**التغييرات.** سنبلغك داخل التطبيق قبل سريان أي تغيير جوهري.

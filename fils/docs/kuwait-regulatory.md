# Kuwait regulatory notes (research, not legal advice)

> Researched 2026-11-22 from public sources. **Nothing here constitutes regulatory approval, and no
> approval has been sought.** Every item marked "needs legal review" must be confirmed by a
> Kuwait-licensed lawyer before public launch. Secondary sources conflict on several points, so treat
> the official texts as authoritative.

## 1. Data protection: CITRA Data Privacy Protection Regulation (Resolution No. 26 of 2024)

**Confirmed by multiple sources (verify against the official CITRA text):**
- Kuwait has no single comprehensive data protection statute. The main instrument is a CITRA
  regulation, Resolution/Decision No. 26 of 2024, which replaced the 2021 regulation.
  ([Al Tamimi](https://www.tamimi.com/news/communications-and-information-technology-regulatory-authority-has-issued-new-data-privacy-regulations/),
  [DLA Piper](https://www.dlapiperdataprotection.com/guide.pdf?c=KW),
  [Michalsons](https://www.michalsons.com/blog/kuwait-data-protection-regulation-2024-update/72816))
- Scope: service providers **licensed by CITRA** that collect, process or store personal data and
  user content, including processing outside Kuwait.
  ([Al Tamimi](https://www.tamimi.com/news/communications-and-information-technology-regulatory-authority-has-issued-new-data-privacy-regulations/))
- Commonly cited obligations: explicit consent before collection, purpose limitation, data subject
  rights, breach notification to CITRA, and transfers abroad only with adequate protection.
  ([dig.watch](https://dig.watch/resource/kuwaits-data-privacy-protection-regulation),
  [Michalsons](https://www.michalsons.com/blog/kuwait-data-protection-regulation-2024-update/72816))

**Conflicting or unclear in the sources:**
- Breach notification deadline: some sources say 24 hours, others 72 hours. The plan assumes **24
  hours** (the stricter figure) until confirmed.
- One source describes a "Personal Data Protection Law No. 26/2024" covering banks and all sectors
  ([Signzy](https://www.signzy.com/regulation-glossary/personal-data-protection-law-2024-CITRA)). It
  conflicts with the law-firm sources; disregard it unless confirmed.

**Needs legal review:**
1. Whether Fils, an app publisher that is not a telecom licensee, falls directly within the CITRA
   regulation's scope. Regardless, the design follows its principles: consent per cloud feature with
   append-only consent history, purpose limitation, export, deletion, and minimal data.
2. The cross-border transfer basis for hosting outside Kuwait (the default Azure region placeholder
   is `uaenorth`). Is consent sufficient, is the region "adequate", or is in-country hosting
   expected? Check whether an in-country Azure region is available at launch (not
   verified here).
3. Whether a registered DPO or contact must be designated.

## 2. Central Bank of Kuwait: Open Banking Regulatory Framework

**Confirmed:**
- CBK published a draft Open Banking Regulatory Framework in June 2025 for consultation.
  ([CBK press release](https://www.cbk.gov.kw/en/cbk-news/announcements-and-press-releases/press-releases/2025/06/202506040800-cbk-issues-draft-open-banking-regulatory-framework))
- CBK's site lists a press release dated 11 November 2026, "CBK Issues Open Banking Regulatory
  Framework", announcing the final version.
  ([CBK home](https://www.cbk.gov.kw/en), [CBK Open Banking page](https://www.cbk.gov.kw/en/supervision/open-banking),
  [Times Kuwait](https://timeskuwait.com/kuwait-opens-door-to-banking-revolution-as-cbk-issues-final-open-banking-framework/))
- The framework covers banks sharing data through APIs with **CBK-licensed** providers (account
  information and payment initiation), under consent management and technical standards.

**Unverified (single secondary source):** capital requirements of KD 100,000 for account information
providers and KD 500,000 for payment initiation providers
([Ali Bahbahani blog](https://www.alibahbahani.com/blogs/open-banking-kuwait-beyond-wamd)).

**How Fils relates:**
- Fils **does not** connect to bank APIs, use bank credentials, or initiate payments. It processes
  messages and notifications that the user's bank already sent to the user, which the user chooses
  to forward to the app, and data the user enters.
- **Needs legal review:** whether this "user-forwarded data" model falls outside CBK licensing.
  Expected answer: likely outside the framework's licensed activities, but this must be confirmed.
  Also confirm whether any CBK consumer-protection or outsourcing rules apply indirectly.
- If Fils later uses bank APIs (open banking), it would need a CBK licence as an account information
  service provider, or a partnership with a licensed provider. This is a separate future workstream.

## 3. Digital commerce and consumer protection

**Confirmed (law-firm and news coverage; verify against the Official Gazette):**
- **Decree-Law No. 10 of 2026 on Digital Commerce**, published 1 March 2026. It covers goods and
  services offered fully or partly through electronic means, including apps. It requires
  registration in a Ministry of Commerce and Industry register, mandatory disclosures, and consumer
  protection in electronic contracts. It takes effect after its Executive Regulations are issued.
  ([Chambers](https://chambers.com/articles/kuwait-s-new-digital-commerce-law-what-businesses-need-to-know),
  [HFW April 2026](https://www.hfw.com/insights/hfw-kuwait-law-update-april-2026/))
- **Consumer Protection Law No. 39 of 2014** remains applicable.
  ([UNESCWA summary](https://unescwa.org/sites/default/files/inline-files/ABLF-2023-consumer-CP-Kuwait-english.pdf))

**Needs legal review:**
1. Whether selling Fils Pro subscriptions through the App Store and Google Play (Apple and Google
   are the merchants of record) requires Fils' own registration in the digital commerce register,
   and whether the Executive Regulations are in force yet.
2. Subscription disclosure, renewal and cancellation requirements, plus Arabic-language terms. The
   app shows store-managed terms and a "Manage subscription" link.
3. Commercial registration of the operating entity in Kuwait (or abroad) and tax treatment.

## 4. Product decisions taken because of this research

- Every cloud feature is opt-in and consent-recorded with a policy version (backend
  `consent_records`, append-only).
- There is no bank credential handling, no payment initiation and no bank API integration, which
  keeps Fils outside open banking licensing pending legal confirmation.
- Bank coverage is never claimed as "verified" without real, consented evidence. Bank names are
  shown without official logos, and Fils is not presented as affiliated with any bank.
- The hosting region stays a deployment parameter until the data residency question is answered.

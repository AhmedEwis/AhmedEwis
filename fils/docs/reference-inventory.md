# Reference inventory: SAY (sayapp.net)

**Sources actually inspected (2026-11-22):**
- The public website https://www.sayapp.net/: full HTML, CSS, and its four phone screenshots (`/screens/en/home.png`, `say-ai.png`, `wealth.png`, `banks.png`).
- The App Store listing https://apps.apple.com/kw/app/say-hands-free-budget-app/id6746735689 (US storefront HTML): description text, 8 iPhone screenshots and 4 iPad screenshots.

**Not inspected:** authenticated screens, the installed app, real device behavior, the Android app and onboarding beyond the welcome screen. Nothing below claims knowledge of screens that weren't visible in those images.

The rest of this document is split into what was **observed** and what Fils **assumed or designed**.

## 1. Observed screen hierarchy and navigation

| Observed screen | Source | Key elements |
|---|---|---|
| Welcome / "Every transaction. Auto-saved." | site `banks.png`, store #2 | Language pill at top left, large two-line headline with the second line in teal, subtitle, horizontally scrolling rows of bank "chips" (logo and name), "500+ banks" check line, black pill "Get Started" button, friend-code link |
| Home ("Wallet" tab) | site `home.png`, store #1 | Teal gradient hero fading to white. Top row: avatar circle with notification dot, date-range pill with chevron, chart icon circle. "Spent" label, huge amount, "⌙ X today", "All Accounts ▾", "Balance X", "You owe X". Four translucent circle actions: Add / Voice / Pay bill (Soon) / More. "Accounts" section with "See all ›" and horizontal account cards (logo, name, amount). "Recent Transactions" with "View all N ›" and a card list of rows |
| Transaction row | home | Pastel emoji tile on the left. Merchant (bold), category, colored dot plus account name. On the right: bold amount and "Today, 5:18 PM". Income is shown green with a "+" |
| Bottom navigation | home, wealth | Floating, rounded, frosted bar with 4 tabs: Wallet, Wealth, Installments, Ask. The selected tab has a grey pill behind it and a teal icon and label |
| Say AI chat ("Ask") | site `say-ai.png`, store #3 | Back button, title, history and new-chat icons. User bubble (teal, right-aligned). Collapsible "Summary · View" and "Top categories · Hide" chips. Inline card "SPENT BY CATEGORY · THIS MONTH" with a donut (center "SPENT 69.2k") and legend percentages, "Show all 8 ⌄", and a Total row. Plain-text bullet answer. Bottom input "Ask anything about your money…" with a send button |
| Wealth | site `wealth.png`, store #4 | Large "Wealth" title with "+". Segmented control Net worth / Assets / Debt. Huge amount. Green pill "▲ +X (7.8%)" plus "this year". "X available now". Area line chart with a tooltip (value, date, event), event dots, and a segmented 1M / 3M / 1Y / All. Stacked allocation bar with legend (Spendable / Investments / Property / Vehicles / Gold & silver / Bank certificates). "SPENDABLE" section listing accounts (logo, name, masked number, amount, chevron) |
| Installments | store #5 | Purple gradient header "Monthly installments X", "Drops to X in 7mo", Active / Remaining stat boxes. "Coming up" card. "Your installments" list with a colored left bar, provider, "7 of 18 payments", amount and "in 6d". Detail view with progress, next payment, actions (Ask Say, Edit, Record Payment) |
| Subscriptions | store #6 | Sheet with Mo / Yr toggle, "Per month X", "7 active", list of services with logos, amount and next date |
| Goals | store #7 | "Total saved X" with a progress bar. "Your goals" with circular progress icons. Goal detail: big amount, "of X · N days to go", red "Add money" and outlined "Take out", "Needs X a month to make it", "MONEY YOU'VE ADDED" step chart, "BACKED BY" (gold), contributions list |
| Marketing extras | store #8, site | "Budgets. Household. Insights. Export." Paywall on the website ("SAY Pro … one payment, doesn't renew", Paymob) |
| Older iPad UI (v1, voice-first) | store iPad set | Month selector chips, "My expenses in June", recent expenses, record button with a waveform, edit-expense sheet with a category grid, currency picker |

## 2. Observed visual language

- **Typography:** the app UI looks like SF Pro with heavy weights for amounts. The website uses DM Sans and DM Serif Display.
- **Colors (from the site CSS):** `#0a7ea4` / `#086F8A` teal accent, `#11181C` ink, `#687076` secondary text, `#94A3B8` tertiary, `#E2E8F0` / `#DDE3E7` borders, `#f4f8fa` canvas. The hero gradient runs from deep blue-teal to white.
- **Surfaces:** white cards with large radii (about 20 to 24 pt), very soft shadows, grey canvas, pill-shaped chips and segmented controls.
- **Icons:** emoji in pastel rounded-square tiles for categories, real bank logos for accounts, outline icons in the navigation.
- **Charts:** donut with a thick ring and center label, area line chart with a gradient fill, stacked horizontal allocation bar.
- **Primary actions:** black pill buttons (Get Started) and translucent circles on the hero.
- **States:** only "Soon" badges and the "Demo"/empty states were not visible. Loading, offline and error states weren't observable.

## 3. How Fils maps it (original implementation, own identity)

| Reference element | Fils implementation | File |
|---|---|---|
| Hero gradient home, period pill, spent, today, balance, owe, 4 circle actions | `HomeScreen`. The actions are Add / Voice / Import / More, because "Pay bill" isn't offered: Fils does not initiate payments | `mobile/lib/features/home/home_screen.dart` |
| Accounts carousel, transaction rows | `AccountMiniCard`, `TxTile` | `features/accounts/account_widgets.dart`, `ui/widgets/tx_tile.dart` |
| Floating frosted 4-tab bar | `GlassNavBar`: Wallet / Wealth / **Plans** / Ask. Plans groups Budgets, Recurring (installments and subscriptions) and Goals | `ui/widgets/common.dart`, `app/app.dart` |
| Chat with inline donut card | `AssistantScreen` plus `CategoryDonut`, deterministic tools | `features/assistant/`, `features/insights/insights_screen.dart` |
| Wealth (segmented, area chart, ranges, allocation bar, spendable list) | `WealthScreen` | `features/wealth/wealth_screen.dart` |
| Purple installments header, coming-up list | `RecurringView` | `features/plans/plans_screen.dart` |
| Goals list and detail with Add money / Take out | `GoalsView`, `GoalDetail` | same |
| Welcome headline plus bank chips plus black pill CTA | `OnboardingScreen` step 0 (our own monogram badges, not bank logos) | `features/onboarding/onboarding_screen.dart` |
| Category grid sheet | `CategoryGrid` | `features/transactions/add_transaction_sheet.dart` |

**Differences on purpose:**
- Fils uses its own name and teal palette (`#0B7A8F`).
- Fils draws its own monogram bank badges. It uses no bank logos or trademarks.
- The font is IBM Plex Sans Arabic for both scripts, for consistent mixed Arabic and English text.
- KWD always shows 3 decimals.
- Calculated and bank-reported balances are labeled separately.

## 4. Screens designed by Fils (assumptions, not replicas)

None of these were visible in the reference, so they were designed in the same visual language. They are **not** claimed to match SAY:

- Review inbox
- Auto-capture setup (iOS Shortcuts and Android notification guides)
- Transaction detail with source provenance
- Split and refund editors
- Account detail with reconciliation
- Budgets list and form
- Recurring form
- Insights (daily bars, cash flow)
- Settings and consents
- Household
- Paywall
- Biometric lock overlay
- Voice push-to-talk screen
- All empty, offline and error states
- Dark mode

## 5. Design verification

Screenshots rendered from the real widget tree with synthetic demo data are in `fils/docs/screenshots/`, generated by `mobile/test/screenshots/screens_test.dart`. They cover EN and AR, light and dark. Issues found and fixed during review:

- **Missing glyphs (▲ ▼ ⌙):** IBM Plex Sans Arabic doesn't include them. Replaced with icons.
- **Inflated net-worth change:** the history series started before any account existed. It now starts from the earliest opening balance or valuation.

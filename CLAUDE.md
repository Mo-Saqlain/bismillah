# Orientation for AI assistants

Short notes that complement [README.md](README.md), [TECHNICAL.md](TECHNICAL.md)
and [USER_MANUAL.md](USER_MANUAL.md). Read those first — this file
captures the load-bearing decisions and the things that look weird
but are deliberate.

> **This file alone is not a rebuild spec.** It is the *why* layer.
> To recreate the app from scratch you need, in order:
> [TECHNICAL.md](TECHNICAL.md) (data model, schema §12, account chart,
> recognition math), [README.md](README.md) (feature scope + stack),
> [USER_MANUAL.md](USER_MANUAL.md) (intended behaviour), and then this
> file to avoid re-introducing the bugs already designed out. Skip any
> one of them and you will rebuild the shape but miss the invariants.

---

## What this project is

A Flutter + SQLite double-entry construction-accounting app for a
**single operator** (no auth, no roles, no multi-tenant logic inside
the app). The whole user model is "one person running multiple
construction projects". Offline-first; optional Supabase cloud sync
for multi-device use.

**Repo layout:** the Flutter app lives at the **repository root** —
`lib/`, `android/`, `test/`, `pubspec.yaml` are all top-level. (It used
to sit in a nested `bismillah_constructions/` folder; that was flattened
away.) The only shipped platform is **Android** — `ios/`, `macos/`,
`linux/`, `web/`, `windows/` were removed. `flutter create . --platforms=…`
regenerates any of them if ever needed.

---

## Load-bearing invariants — break these and the app stops working

1. **Every ledger write goes through `LedgerRepository._post()`.** Two
   rows per transaction, sharing a `transaction_id`. Direct DB writes
   to `journal_entries` are forbidden. `_post` also writes the
   `change_log` "create" audit row (see invariant 6) inside the same
   transaction.
2. **`incomeFigures()` is the only source of truth for P&L.** The
   dashboard, Income Statement, BvA banner and Monthly P&L Trend all
   consume it. Changing recognition logic here changes the whole app.
3. **Soft delete via `is_deleted = 1`**, then mirror on
   `material_inventory` rows that share the `transaction_id` (v13
   linkage). The Material Price Trend and Budget vs Actual rely on
   that mirror. Since v17, `material_inventory.quantity` / `.rate`
   are nullable (a buy can be logged without a quantity); rows with
   a null quantity are excluded from the Material Price Trend.
4. **Time-of-day boundary handling.** Date filters use
   `created_at >= from` and `created_at < (to + 1 day)` everywhere —
   `<= to` would exclude everything after midnight on the `to` day.
   If you add a new windowed query, copy the pattern (see
   `accountBalance`).
5. **`postLabourPayment` smart settle.** Pays the outstanding wage
   credit first before booking a new direct labour cost. Don't
   "simplify" this — without it, paying a worker after recording
   credit double-counts the cost.
6. **`change_log` records creation too, not just edits/deletes.**
   `_post` logs a `ChangeAction.create` for every transaction;
   `createProject/createSupplier/createBank` log one for the entity.
   The payload lives in `new_data`. The Activity Log screen decodes
   `original_data ?? new_data`. Any exhaustive `switch` over
   `ChangeAction` must handle `create` (there are three:
   `constants.dart` label, and `_iconFor`/`_tintFor` in
   `change_log_screen.dart`).

---

## Non-obvious design decisions

- **PoC cost-recovery, not percentage-of-completion proper.** For
  active With-Material projects, revenue = `min(received, costs)`
  not `costs / budget × contract`. The cost-recovery variant is
  conservative — zero gross profit until close, no "fake profit"
  from advance payments.
- **Net Worth balance sheet, no equity plug.** `Assets − Liabilities
  = Net Worth`. Cumulative recognized profit is a cross-check memo,
  not an equity line. Net Worth and Accumulated Profit can diverge
  while projects are in progress and converge as they close.
- **`agingProjectReceivables` is FIFO over the entire ledger**, not a
  per-invoice table. We walk costs and revenue credits in time order
  per project, banking prepayments to consume later costs before they
  queue as "owed". That's why dropping the Customer entity was viable.
- **Monthly P&L Trend uses cumulative deltas, not per-month windows.**
  A window-only `min(received-in-month, costs-in-month)` collapses to
  0 in most months. Cumulative-delta keeps PoC's "match revenue to
  costs" intact across the project's whole life; the per-month bucket
  is the delta. `closeAsOf` is passed so a project archived this week
  doesn't retroactively change what February looked like.
- **Labour-Rate service fee is either a percentage OR a fixed amount.**
  `ServiceFeeType.{percent,fixed}` on the project. **`Project.serviceFeeOn(totalSpent)`
  is the single source of truth for the fee math** — fixed returns the
  flat `serviceFeeAmount` regardless of spend; percent returns
  `serviceFeePercent%` of spend. `labourRateCloseSummary` mirrors it.
  A fixed fee can leave the customer owing the shortfall (fee + costs >
  received); the LR archive gate (`ledgerNet == 0`) still enforces
  settlement, unchanged, because the fee is posted the same way (Dr
  Project Revenue / Cr Service Fee Income).
- **WhatsApp-on-transaction is a deep link, not an API.** After a
  transaction saves, `_maybePromptWhatsApp` offers to open WhatsApp
  (`wa.me/<number>?text=…` via `url_launcher`) pre-filled to the
  **counterparty** — the supplier (its `phone`) for material/labour/
  supplier-pay, or the project (its `whatsapp`) for a receipt. No
  counterparty (transfer, personal draw, counter purchase) → no
  prompt. No number on file → silently skipped (the number is
  *optional*, not mandatory). There is no WhatsApp Business API and no
  auto-send — the operator taps send in WhatsApp. Number normalization
  (`core/whatsapp.dart`) defaults to Pakistan (+92).
- **Cloud sync is last-write-wins; Supabase is the source of truth.**
  Pull upserts by id: a new id inserts; an existing id is overwritten
  only when the server row's `updated_at` is strictly newer
  (`serverTimestampIsNewer` — parses both sides to instants because
  server rows use `+00:00`/micros and local rows use `Z`/millis). So
  edits and soft-deletes propagate across devices, and it's still fully
  offline-capable. `updated_at` is **client-authoritative** — the
  server-side auto-bump trigger is dropped (migration 0005) so a
  re-pushed pulled row can't ping-pong its timestamp. Trade-off: the
  same record edited on two devices while both are offline resolves to
  whichever syncs with the later timestamp (the other edit is lost) —
  acceptable for a single operator; bulletproofing would need per-field
  merge / a dirty flag, which is overkill here.
- **Tenant identity is baked into the build (`SUPABASE_TENANT_ID`).**
  `ensureTenantId()` returns the build-time `SupabaseConfig.tenantId`
  when set, so **every install of the operator's APK shares one tenant**
  and sync works from first launch — no login, no per-install random
  tenant, no manual Tenant-ID copying. Only when the define is empty
  (e.g. tests) does it fall back to generate-a-random-UUID-once.
  Historically the random-per-install behaviour caused **tenant
  fragmentation** (reinstalling orphaned data under a new tenant) — the
  #1 support issue the baked tenant fixes. Settings → Cloud Sync → **Sync
  diagnostics** (`SyncService.diagnostics()`) shows per-table `local /
  cloud(this tenant) / all(every tenant)` counts to spot any legacy
  fragmentation, and **Re-pull everything** (`fullRepull()` →
  `resetPullCursors()`) safely re-downloads under the current tenant. To
  merge legacy fragmented data, re-tag every synced table's `tenant_id`
  on the server to the one baked value.
- **Operational-memory layer (v14) sits beside the ledger, not in it.**
  `notes` and `follow_ups` never post journal entries — they never
  touch P&L or the balance sheet. `change_log` is backward-looking
  audit (now including creates).
- **Cash Runway is a derived signal, not a stored value.** `days =
  liquid cash ÷ average daily burn` over the active spending window;
  green ≥ 30d, yellow 15–30d, red < 15d. Recomputed live off
  `ledgerVersionProvider`.
- **OS text scale is clamped to 1.3×** in `app.dart`'s `MaterialApp.builder`
  so a phone set to a large font / display size can't blow fixed rows
  and cards out of shape. The New Transaction / Manage / Reports tiles
  are also intentionally single-line (no descriptive subtitle) for the
  same reason.

---

## Things that are deliberately missing

- **No customer entity.** v16 removed it. Projects are the only
  counterparty, and "receivables" means under-funded projects (FIFO
  over the cost queue), not customer invoices.
- **No user accounts / login.** Single operator. Supabase sync scopes
  data by a fixed `tenant_id` baked into the build (`SUPABASE_TENANT_ID`),
  not a per-user JWT. RLS is open; the APK's privacy is the security
  boundary. (A real login — Supabase Auth keyed to `auth.uid()` — is the
  upgrade path if data ever needs actual protection or multiple users.)
- **No automatic crash reporting.** `core/error_reporter.dart` keeps
  the last 100 errors in memory and surfaces them via Settings →
  Recent Errors. The user copy-pastes them into WhatsApp.
- **No invoicing / quotes / payslips.** This is an accounting app for
  the owner, not a customer-facing system. The WhatsApp prompt sends a
  plain-text confirmation, not a formatted invoice.

---

## Where things live

- **Chart of accounts** — `lib/core/constants.dart` → `Accounts`.
  Also holds the `ServiceFeeType` and `ChangeAction` enums.
- **Single ledger writer** — `lib/data/repositories/ledger_repository.dart`.
- **Result classes** — same file's `part` — `ledger_repository_models.dart`
  (`LabourRateClose` carries `feeType`).
- **Provider barrel** — `lib/providers/providers.dart` re-exports every
  provider. Always import the barrel, not the split files.
- **AccountSummary** — `lib/providers/account_summary.dart`. Every
  derived dashboard number.
- **Cash Runway** — `lib/providers/cash_runway.dart`.
- **Entities + operational memory** — `entity_repository.dart` owns
  suppliers, banks, projects (incl. `whatsapp`, `serviceFeeType`,
  `serviceFeeAmount`), material/labour type defs, counter entities,
  notes, follow-ups, the `change_log` writer (`logChange`), and the
  cloud-sync cursors (incl. `resetPullCursors`).
- **WhatsApp deep-link helper** — `lib/core/whatsapp.dart`
  (`normalizeWhatsAppNumber`, `launchWhatsApp`). The post-transaction
  prompt lives in `transaction_form_screen.dart`.
- **Backup / restore** — `lib/data/services/backup_service.dart`; UI in
  `settings/backups_list_screen.dart` and `common/restore_gateway.dart`.
- **Migrations** — `lib/data/db/local_db.dart` `_migrate`. v1..v19.
- **Cloud sync** — `lib/data/sync/sync_service.dart` (`syncNow`,
  `fullRepull`, `diagnostics`, `SyncTableDiag`). Settings UI in
  `settings/settings_screen.dart`.
- **Supabase schema** — `supabase/migrations/` (`0001_initial.sql` +
  `0002_material_quantity_optional.sql` + `0003_service_fee_fixed.sql`
  + `0004_project_whatsapp.sql`); apply order matters.
- **Run-with-cloud helper** — `scripts/run_with_supabase.ps1` injects
  the Supabase URL/key as `--dart-define`s (from `secrets/dart_defines.json`).

---

## Coding conventions

- Repositories never import `package:flutter/*`. Pure Dart so they run
  under `sqflite_common_ffi` in tests with no mocks.
- Comments reserved for the *why*. Don't document what the code does.
- Money is stored as `REAL` (double), formatted via `fmtMoney` /
  `fmtSignedMoney` / `fmtCompactMoney`. PKR, no decimals in the UI.
- Times stored as ISO-8601 UTC; displayed via `fmtDate` / `fmtDateTime`
  in local time.
- Positive/negative colouring uses `BalanceColors.signed(context, value)`
  — never hard-coded `Colors.green` / `Colors.red`.
- After any mutation, `bumpLedger(ref)` invalidates the
  `ledgerVersionProvider` so dependent screens refetch.

---

## Test-running notes

- `flutter test` runs everything (currently 113 tests).
- Tests use `sqflite_common_ffi` with an in-memory or temp-file DB.
  Schema is applied via `LocalDb.applySchemaForTests` so production
  migrations are exercised on every run.
- `flutter analyze --no-fatal-infos` is expected to come back clean.
- No mocks. If a test reaches for one, prefer a real fixture.

---

## When changing recognition logic

1. Decide whether to put it in `incomeFigures()` (one source of truth)
   or layer on top. Almost always: in `incomeFigures()`.
2. Add a test in `business_logic_test.dart` that pins the new
   behaviour with explicit numbers.
3. Check Monthly P&L Trend: cumulative deltas mean a change flows
   automatically — but verify the trend chart still looks sane.
4. Update the Income Statement narrative if the user-visible story
   changed.

---

## When changing the schema

1. Bump the `version: N` constant in `local_db.dart` **and** the
   `applySchemaForTests` argument.
2. Add a migration block to `_migrate` covering N-1 → N.
3. Update `_onCreate` so a fresh install gets the new state in one
   shot — don't rely on migrations being walked on first launch.
4. If the table is synced, add a **new** numbered file under
   `supabase/migrations/` (don't edit `0001_initial.sql`) and remember
   the user must apply it in their Supabase project (SQL Editor) before
   the next sync — the app never runs DDL against Supabase.
5. Add the version to TECHNICAL.md §12.

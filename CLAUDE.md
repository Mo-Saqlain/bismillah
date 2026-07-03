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

---

## Load-bearing invariants — break these and the app stops working

1. **Every ledger write goes through `LedgerRepository._post()`.** Two
   rows per transaction, sharing a `transaction_id`. Direct DB writes
   to `journal_entries` are forbidden.
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
   Two breakdown helpers had this bug and were fixed; if you add a
   new windowed query, copy the pattern (see `accountBalance`).
5. **`postLabourPayment` smart settle.** Pays the outstanding wage
   credit first before booking a new direct labour cost. Don't
   "simplify" this — without it, paying a worker after recording
   credit double-counts the cost.

---

## Non-obvious design decisions

- **PoC cost-recovery, not percentage-of-completion proper.** For
  active With-Material projects, revenue = `min(received, costs)`
  not `costs / budget × contract`. The cost-recovery variant is
  conservative — zero gross profit until close, no "fake profit"
  from advance payments.
- **Net Worth balance sheet, no equity plug.** The business holds no
  contributed capital; `Assets − Liabilities = Net Worth`.
  Cumulative recognized profit is shown as a cross-check memo, not
  an equity line. Net Worth and Accumulated Profit can diverge while
  projects are in progress (the BS counts unfunded WM costs as
  `projectReceivables` while the P&L defers recognition); they
  converge as projects close.
- **`agingProjectReceivables` is FIFO over the entire ledger**, not
  a per-invoice table. We walk costs and revenue credits in time
  order per project, banking customer prepayments to consume later
  costs before they queue as "owed". That's why dropping the
  Customer entity was viable.
- **Monthly P&L Trend uses cumulative deltas, not per-month
  windows.** A window-only `min(received-in-month, costs-in-month)`
  collapses to 0 in most months because payment timing and cost
  timing don't align. Cumulative-delta keeps PoC's "match revenue
  to costs" intact across the project's whole life, and the
  per-month bucket is just the delta. `closeAsOf` is passed so a
  project archived this week doesn't retroactively change what
  February looked like.
- **Cloud sync is INSERT OR IGNORE.** Pulled rows that exist locally
  are skipped. The server is a mirror of every device's writes; it
  never overwrites a local row. If you change this, document why —
  every other safety rail in sync depends on this not happening.
- **Operational-memory layer (v14) sits beside the ledger, not in
  it.** `notes` (free-text, pinnable, attached to a project or
  supplier) and `follow_ups` (forward-looking payment-promise /
  recovery tracking) are separate from `change_log` (backward-looking
  audit). None of them post journal entries — they never touch P&L or
  the balance sheet.
- **Cash Runway is a derived signal, not a stored value.** `days =
  liquid cash ÷ average daily burn` over the active spending window;
  the banner colours green ≥ 30d, yellow 15–30d, red < 15d. Recomputed
  live off `ledgerVersionProvider`.

---

## Things that are deliberately missing

- **No customer entity.** v16 removed it. Projects are the only
  counterparty, and "receivables" means under-funded projects (FIFO
  over the cost queue), not customer invoices.
- **No user accounts / login.** Single operator. Supabase sync uses
  a tenant id baked into the install, not a per-user JWT.
- **No automatic crash reporting.** `core/error_reporter.dart` keeps
  the last 100 errors in memory and surfaces them via Settings →
  Recent Errors. The user copy-pastes them into WhatsApp.
- **No invoicing / quotes / payslips.** This is an accounting app
  for the owner, not a customer-facing system.

---

## Where things live

- **Chart of accounts** — `lib/core/constants.dart` → `Accounts`.
- **Single ledger writer** — `lib/data/repositories/ledger_repository.dart`.
- **Result classes** — same file's `part` —
  `ledger_repository_models.dart`.
- **Provider barrel** — `lib/providers/providers.dart` re-exports
  every provider. Always import the barrel, not the split files.
- **AccountSummary** — `lib/providers/account_summary.dart`. Holds
  every derived dashboard number including `customerDeposits`,
  `projectReceivables`, `supplierOverpayments`, `lossProvision`.
- **Cash Runway** — `lib/providers/cash_runway.dart`.
- **Entities + operational memory** — `entity_repository.dart` owns
  suppliers, banks, projects, material/labour type defs, counter
  entities, **notes** and **follow-ups**. UI: `notes/notes_panel.dart`,
  `followups/followups_screen.dart`, `projects/site_snapshot_screen.dart`.
- **Backup / restore** — `lib/data/services/backup_service.dart`
  (raw `.db` file copy); UI in `settings/backups_list_screen.dart`
  and `common/restore_gateway.dart`.
- **Migrations** — `lib/data/db/local_db.dart` `_migrate`. v1..v17.
- **Cloud sync** — `lib/data/sync/sync_service.dart`.
- **Supabase schema** — `supabase/migrations/` (`0001_initial.sql`
  + `0002_material_quantity_optional.sql`); apply order matters.
- **Run-with-cloud helper** — `scripts/run_with_supabase.ps1` injects
  the Supabase URL/key as `--dart-define`s so sync works in `flutter run`.

---

## Coding conventions

- Repositories never import `package:flutter/*`. Pure Dart so they
  run under `sqflite_common_ffi` in tests with no mocks.
- Comments reserved for the *why*. Don't document what the code
  does — the code already does that.
- Money is stored as `REAL` (double), formatted via `fmtMoney` /
  `fmtSignedMoney` / `fmtCompactMoney`. PKR, no decimals in the UI.
- Times stored as ISO-8601 UTC; displayed via `fmtDate` /
  `fmtDateTime` in local time.
- Positive/negative colouring uses
  `BalanceColors.signed(context, value)` — never hard-coded
  `Colors.green` / `Colors.red`.
- After any mutation, `bumpLedger(ref)` invalidates the
  `ledgerVersionProvider` so dependent screens refetch.

---

## Test-running notes

- `flutter test` runs everything (currently 107 tests).
- Tests use `sqflite_common_ffi` with an in-memory or temp-file DB.
  Schema is applied via `LocalDb.applySchemaForTests` so production
  migrations are exercised on every run.
- `flutter analyze --no-fatal-infos` is expected to come back clean.
- No mocks. If a test reaches for one, prefer a real fixture.

---

## When changing recognition logic

1. Decide whether to put it in `incomeFigures()` (one source of
   truth) or layer on top. Almost always: in `incomeFigures()`.
2. Add a test in `business_logic_test.dart` that pins the new
   behaviour with explicit numbers.
3. Check Monthly P&L Trend: cumulative deltas mean a change to
   `incomeFigures` flows automatically — but verify the trend chart
   still looks sane.
4. Update the Income Statement narrative if the user-visible story
   changed.

---

## When changing the schema

1. Bump the `version: N` constant in `local_db.dart`.
2. Add a migration block to `_migrate` covering N-1 → N.
3. Update `_onCreate` so a fresh install gets the new state in one
   shot — don't rely on migrations being walked on first launch.
4. If the table is synced, add a **new** numbered file under
   `supabase/migrations/` (don't edit `0001_initial.sql` — it's the
   baseline) and remember the user has to apply it in their Supabase
   project before the next sync.
5. Add the version to TECHNICAL.md §12.

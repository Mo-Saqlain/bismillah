# Bismillah Constructions ERP — Technical Reference

Engineering documentation for the Flutter + SQLite construction-accounting
app. For end-user help, see [USER_MANUAL.md](USER_MANUAL.md).

---

## 1. Tech stack

| Concern              | Choice                                              |
| -------------------- | --------------------------------------------------- |
| Language / runtime   | Dart 3.11.5+, Flutter 3.x                           |
| State management     | `flutter_riverpod` 2.x                              |
| Local DB             | `sqflite` + `sqflite_common_ffi` (desktop / tests)  |
| Charts               | `fl_chart` 0.68+                                    |
| PDF reports          | `pdf` + `printing`                                  |
| Sharing / file pick  | `share_plus` + `file_picker`                        |
| File paths           | `path` + `path_provider`                            |
| IDs                  | `uuid` v4                                           |
| Collections          | `collection` (firstWhereOrNull, etc.)               |
| Tests                | `flutter_test` + `sqflite_common_ffi` in-memory DB  |
| Cloud sync (opt-in)  | `supabase_flutter` 2.x (PostgREST + RLS)            |

Fully offline-first; cloud sync is opt-in and only activates when
`SUPABASE_URL` / `SUPABASE_ANON_KEY` are supplied at build time. No
analytics, no auth flows — a single shared tenant id underlies the
multi-device model.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          UI (Flutter widgets)                        │
│                                                                      │
│  Dashboard · Manage · Reports · Settings · Transactions · Projects   │
│                                                                      │
└────────────────────────────┬─────────────────────────────────────────┘
                             │   ConsumerWidget / WidgetRef
                             ▼
┌──────────────────────────────────────────────────────────────────────┐
│                  Riverpod providers  (lib/providers/)                │
│                                                                      │
│  db_providers · sync_providers · entity_providers · theme_provider   │
│  ledger_read_providers · account_summary · cash_runway               │
└──────────┬───────────────────────────────┬───────────────────────────┘
           │                               │
           ▼                               ▼
┌──────────────────────┐       ┌───────────────────────┐
│    Repositories      │       │     Services          │
│                      │       │                       │
│  LedgerRepository    │       │  BackupService        │
│  EntityRepository    │       │  ErrorReporter        │
└──────────┬───────────┘       └───────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     Local SQLite  (LocalDb)                          │
│       — single source of truth, double-entry general ledger —        │
└──────────────────────────────────────────────────────────────────────┘
```

### Architectural rules

1. **Local DB is the only source of truth.** No data is read from any
   external service at runtime.
2. **All ledger writes go through `LedgerRepository`.** This is the only
   class that writes to `journal_entries`. Direct DB access from screens
   is forbidden.
3. **All audit events go through `change_log`.** Every soft delete,
   restore, archive or unarchive writes a `ChangeLog` row stamped with
   `device_id`.
4. **Repository-layer validation.** `_assertNonEmpty` guards all required
   FK fields (`projectId`, `supplierId`) before any `_post()` call.
5. **One source of truth for P&L.** `LedgerRepository.incomeFigures()`
   computes recognized revenue, costs, deposits and loss provision once;
   the dashboard, Income Statement and BvA all consume it.

---

## 3. Project layout

```
bismillah_constructions/
├── lib/
│   ├── main.dart                              # entry, error handlers, ProviderScope
│   ├── app.dart                               # MaterialApp + boot watchers
│   ├── core/
│   │   ├── app_restart.dart                   # ValueNotifier that rebuilds the tree
│   │   ├── constants.dart                     # Chart of Accounts, enums, settings keys
│   │   ├── error_reporter.dart                # global error log + SnackBar surface
│   │   ├── formatters.dart                    # fmtMoney, fmtCompactMoney, fmtDate
│   │   ├── theme.dart                         # Indigo/Navy theme + BalanceColors
│   │   └── export/
│   │       ├── csv_export.dart                # RFC-4180 CSV builder + share
│   │       └── pdf_generator.dart             # PDF report builder
│   ├── data/
│   │   ├── db/
│   │   │   └── local_db.dart                  # sqflite open + schema v17 + migrations
│   │   ├── models/                            # Plain Dart structs + toMap/fromMap
│   │   ├── repositories/
│   │   │   ├── ledger_repository.dart         # journal_entries writes + reads + reports
│   │   │   ├── ledger_repository_models.dart  # part of — result classes
│   │   │   ├── entity_repository.dart         # projects / parties / banks / settings
│   │   │   ├── notes_repository.dart          # operational notes (v14)
│   │   │   └── followups_repository.dart      # recovery follow-ups (v14)
│   │   ├── services/
│   │   │   └── backup_service.dart            # local file backup, atomic copy
│   │   └── sync/
│   │       └── sync_service.dart              # Supabase push + INSERT-only pull
│   ├── providers/                             # split barrel — providers.dart re-exports
│   │   ├── providers.dart                     # barrel
│   │   ├── db_providers.dart                  # db, repos, ledgerVersion, bumpLedger
│   │   ├── sync_providers.dart                # sync, backup, boot hooks
│   │   ├── theme_provider.dart                # ThemeModeNotifier
│   │   ├── entity_providers.dart              # projects/suppliers/banks/types lists
│   │   ├── ledger_read_providers.dart         # entries, daily spend, change log
│   │   ├── account_summary.dart               # AccountSummary class + provider
│   │   └── cash_runway.dart                   # CashRunway class + provider
│   └── features/
│       ├── home/                              # Pill-nav shell + back stack
│       ├── dashboard/                         # Treasury, runway, daily spend, at-risk
│       ├── manage/                            # Projects/Suppliers/Banks tile, types screens
│       ├── transactions/                      # Picker, form, history (date-grouped)
│       ├── projects/                          # List, reconciliation/archive, site snapshot
│       ├── notes/                             # Project + supplier notes panel (v14)
│       ├── followups/                         # Recovery follow-ups (v14)
│       ├── reports/                           # All reports + charts
│       ├── common/                            # async_view, date_range_bar, ledger_view, restore_gateway
│       └── settings/                          # Theme, backup, sync, audit, errors, types
└── test/
    ├── invariants_test.dart                   # engine invariants
    ├── business_logic_test.dart               # PoC, labour-payment, archive gate
    ├── backup_blackbox_test.dart              # backup/restore/persistence
    ├── project_breakdown_test.dart            # per-supplier + per-material roll-ups
    ├── user_journeys_blackbox_test.dart       # end-to-end flows
    └── widget_test.dart                       # constants/enums
```

Total automated tests: **106**, all passing under `flutter test`.

---

## 4. Data model

The local SQLite schema is at **version 17**. Migrations are forward-only
and additive (with one drop-column in v16). See section
[12](#12-schema-migration-history) for the full migration history.

### 4.1 `journal_entries` — the ledger

| column          | type      | notes                                                    |
| --------------- | --------- | -------------------------------------------------------- |
| id              | TEXT PK   | uuid v4                                                  |
| transaction_id  | TEXT      | groups the two rows of a single posting                  |
| account_id      | TEXT      | matches an `Account.id` from the Chart of Accounts       |
| project_id      | TEXT?     | FK → projects(id), nullable                              |
| supplier_id     | TEXT?     | FK → suppliers(id), nullable                             |
| debit, credit   | REAL      | exactly one is non-zero per row                          |
| description     | TEXT?     | free text                                                |
| created_at      | TEXT      | ISO-8601 UTC                                             |
| synced          | INT       | 0/1 — committed locally                                  |
| is_deleted      | INT       | soft-delete flag                                         |
| deleted_at      | TEXT?     | set when soft-deleted                                    |

Every business transaction inserts **exactly two rows** sharing the same
`transaction_id` (one debit + one credit, equal amounts).
`LedgerRepository._post()` is the only entry point for writes.

v11 added `REFERENCES projects(id)` / `REFERENCES suppliers(id)` FK
constraints. The migration nulls out orphans before recreating the table.
v16 dropped the legacy `customer_id` column (the Customer entity was
removed; the project is now the only counterparty).

### 4.2 `change_log` — audit trail

`{id, entity_type, entity_id, action, original_data (JSON), new_data (JSON), note, device_id, timestamp}`

Recorded for: soft delete, restore, archive, unarchive, hard delete.
`device_id` is a stable per-install UUID generated on first run and
stored in `app_settings`.

### 4.3 Other tables

| Table               | Purpose                                                                 |
| ------------------- | ----------------------------------------------------------------------- |
| `projects`          | name, model (`withMaterial`/`labourRate`), status, client_name, site_address, budget, project_manager, service_fee_percent, archival fields |
| `suppliers`         | name, phone, category, tax_status, bank_details, archival fields        |
| `banks`             | user-defined wallets/bank accounts; archival supported                  |
| `counter_entities`  | external receivables/payables not tracked transactionally               |
| `material_inventory`| per-purchase rows used for BvA + price-trend                            |
| `material_types`    | user-defined material catalog (name, UoM, coverage rate, waste, lead-d) |
| `labour_types`      | user-defined labour categories (name, description, default daily rate)  |
| `notes`             | free-text operational notes attached to a project or supplier (v14)     |
| `follow_ups`        | recovery / billing reminders with expected_date, priority, status (v14) |
| `app_settings`      | opaque `{key, value}` — theme, last_backup_at, device_id, tenant_id, last_pull_at_* |

### 4.4 Chart of Accounts (`core/constants.dart` → `Accounts`)

| Type      | Account ID           | Display name          | Notes                                    |
| --------- | -------------------- | --------------------- | ---------------------------------------- |
| Asset     | `CASH`               | Cash                  | Physical cash on hand                    |
| Asset     | `SUPERVISOR_FLOAT`   | Supervisor Float      | Site petty-cash float                    |
| Asset     | *(bank row id)*      | *(bank name)*         | Each row in the `banks` table is a cash-like account dynamically |
| Liability | `SUPPLIER_PAY`       | Supplier Payables     | Bills incurred, not yet settled          |
| Income    | `PROJECT_REV`        | Project Revenue       | Money received from client               |
| Income    | `SERVICE_FEE`        | Service Fee Income    | Contractor's earned fee (LR projects)    |
| Expense   | `MATERIAL_COSTS`     | Material Costs        | Raw material purchases                   |
| Expense   | `LABOUR_COSTS`       | Labour Costs          | Worker wages (cash or accrued)           |
| Expense   | `PERSONAL_DRAW`      | Personal / Daily Draw | Owner drawings not tied to a project     |
| Equity    | `OWNERS_EQUITY`      | Owner's Equity        | Opening balances                         |

`Accounts.systemCashLike` (Cash + Supervisor Float) plus every row in the
`banks` table form the set of **cash-like accounts**. `liquidCash` is the
sum of all of them.

---

## 5. Transaction kinds

Each `postXxx` method on `LedgerRepository` maps to one debit/credit
pair. The repository validates `amount > 0`, required FK fields, and
that source accounts are cash-like where required.

| Method                    | Debit               | Credit              | Notes                                         |
| ------------------------- | ------------------- | ------------------- | --------------------------------------------- |
| `postMaterialBuy`         | Material Costs      | Supplier Payables   | project_id + supplier_id required             |
| `postLabourPayment`       | *smart, see below*  | Cash / Bank         | project_id + supplier_id required             |
| `postLabourCredit`        | Labour Costs        | Supplier Payables   | Wages incurred, not yet paid                  |
| `postSupplierPay`         | Supplier Payables   | Cash / Bank         | Settles an outstanding payable                |
| `postReceiveFromProject`  | Cash / Bank         | Project Revenue     | Client payment in — project_id required       |
| `postWalletTransfer`      | Dest wallet         | Src wallet          | Both must be cash-like; src ≠ dest            |
| `postPersonalDraw`        | Personal Draw       | Cash / Bank         | Owner withdrawal, not linked to a project     |
| `postServiceFee`          | Cash / Bank         | Service Fee Income  | Interim fee receipt — project_id required     |
| `postProjectServiceFee`   | Project Revenue     | Service Fee Income  | LR close: reclassifies fee; no cash movement  |
| `postOpeningBalance`      | Bank / Wallet       | Owner's Equity      | Initial balance for a new account             |
| `postReversal`            | mirror of original  | mirror              | Offsetting entry; original remains in ledger  |

### 5.1 `postLabourPayment` smart settlement

If the worker has an outstanding wage credit (booked earlier via
`postLabourCredit`), the payment **settles the existing payable first**
rather than creating a new direct cost. Three branches:

- `payment ≤ owed`: posts `Dr Supplier Payables / Cr Cash` only — no
  new cost line.
- `payment > owed`: settles the existing payable in full, then books
  the excess as a fresh `Dr Labour Costs / Cr Cash`. Two transactions
  share the description.
- no outstanding credit: posts `Dr Labour Costs / Cr Cash` directly,
  matching the original behaviour.

This avoids the double-counting bug where labour costs would be doubled
and the payable left untouched.

---

## 6. Reporting engine

All financial calculations are SQL aggregates over `journal_entries`
(always excluding `is_deleted = 1` rows).

### 6.1 `incomeFigures()` — single source of truth

`LedgerRepository.incomeFigures({from, to, projectId, closeAsOf})` returns
the canonical P&L bundle used by both the Income Statement and the
dashboard's Net Profit. It implements **Percentage-of-Completion
(cost-recovery variant)**:

- **With-Material, in-progress** (not archived):
  `revenue = min(received, costs_to_date)`. Excess sits as a
  customer-deposit liability.
- **With-Material, closed** (archived):
  `revenue = min(received, budget)`. Anything received over budget is a
  refund-able deposit.
- **Loss provision** (FASB/IFRS): if `costs > budget` on any project,
  `costs - budget` is recognized as an immediate cost line.
- **Labour-Rate**: service fees only as earned income; everything else
  is a customer-deposit liability.
- **Projects at risk**: every project ≥ 80% of budget is flagged for
  the dashboard warning panel, sorted with over-budget jobs first.

`closeAsOf` is used by [`monthlyIncome`](#65-monthly-pl-trend) to ask
"was this project closed at *that* moment?" — when supplied, the
"closed" check compares `archived_at` against the snapshot date instead
of reading the live `is_archived` flag. Without it, the live flag is
used (this is what every other caller wants).

### 6.2 Dashboard snapshot — `accountSummaryProvider`

```
liquidCash     = Cash + Supervisor Float + Σ(bank balances)
netLiquidity   = liquidCash − supplierPayables
netPosition    = counterReceivables − (payables + counterPayables)
totalNetWorth  = liquidCash + netPosition
netProfit      = revenue + serviceFee − (matCosts + labCosts + personalDraw + lossProvision)
```

`AccountSummary` also carries `customerDeposits` and the
`projectsAtRisk` list straight from `incomeFigures()`.

### 6.3 `cashRunwayProvider`

```
avgDailyBurn  = Σ(material+labour costs in last 30 days) / distinct_active_days
runwayDays    = liquidCash / avgDailyBurn
```

The active-days denominator (instead of dividing by a fixed 30) means a
single high-spend day yields a meaningful daily rate immediately, not a
diluted "1700-day runway" artefact.

### 6.4 Other statements

- **Balance Sheet** — Net Worth model: `Assets − Liabilities = Net Worth`.
  No equity plug; cumulative recognized profit appears as a cross-check
  memo. Assets include cash, banks, counter receivables, project
  receivables (under-funded projects) and supplier advances; liabilities
  include supplier payables, counter payables, customer deposits and
  the loss provision.
- **Cash Flow** — `monthlyCashFlow(monthsBack=12)` bucketed by operating /
  financing / other.
- **Aging Analysis** — FIFO open-balance matcher, bucketed
  0-30 / 31-60 / 61-90 / 90+ days. Payables aging goes per supplier;
  receivables aging splits across `agingProjectReceivables` (under-funded
  projects) and `agingSupplierOverpayment` (advances we paid out).
- **Budget vs Actual** — actual spend per material type (from
  `material_inventory`) + labour vs `Project.budget`. Overrun banner
  when `costs > budget`.
- **Project Profitability** — one row per project: received, spent, net.
  Net profit chart with bold zero line.
- **Wage Register** — labour debits grouped by supplier (worker), with
  payment count and last-paid date.
- **Supplier-wise Spending** — total material + labour by supplier,
  filterable by period (all-time / 90 days / 30 days).
- **Supplier / Bank / Project Ledger** — running balance for one party,
  project-filterable, date-filterable. Trial-balance header (opening /
  debits / credits / closing) on every ledger; the project ledger also
  shows per-supplier and per-material breakdowns.

### 6.5 Monthly P&L Trend

`LedgerRepository.monthlyIncome(monthsBack=12)` returns one
`MonthlyIncome` per month, oldest → newest. Each month is the **delta
of two cumulative `incomeFigures` snapshots** taken at the
month-end boundaries — a naive per-month window would systematically
under-recognize PoC revenue because the in-progress
`min(received, costs)` rule only converges when applied to lifetime
cumulative totals. Each cumulative snapshot is computed with
`closeAsOf = monthEnd` so projects archived later don't retroactively
rewrite earlier months as "closed". A baseline snapshot at the day
before the window start anchors the deltas so the oldest month
doesn't absorb every prior-history recognition event.

### 6.6 Charts

| Chart                                       | Screen           | Data source                                                |
| ------------------------------------------- | ---------------- | ---------------------------------------------------------- |
| Budget allocation pie                       | BvA              | Material vs Labour vs Remaining                            |
| Material breakdown pie                      | BvA              | `bva.materialByType` + `bva.otherMaterial`                 |
| Spending over time (Day/Week/Month toggle)  | BvA              | `projectDailySpend(projectId)` aggregated in-widget        |
| Net profit bar                              | Profitability    | `net` per project; emerald above zero, rose below          |
| 7-day spending bar                          | Dashboard        | `overallDailySpend(daysBack: 7)` aggregated to the day     |
| Monthly P&L trend (income/cost/net lines)   | Income Trend     | `monthlyIncome(monthsBack: 12)` cumulative deltas          |

All charts use `fmtCompactMoney` for axis labels (Rs 1.5L, Rs 250k, etc.)
with auto-picked "nice" intervals (1/2/5/10 × 10ⁿ).

### 6.7 Exports

- **PDF** — `core/export/pdf_generator.dart` (Income Statement, Balance
  Sheet, Supplier Ledger, Wage Register).
- **CSV** — `core/export/csv_export.dart` (RFC-4180 quoted; temp file →
  `share_plus`). Available on every statement screen and the Monthly P&L
  Trend.

---

## 7. Backup architecture

All data lives exclusively in the local SQLite database. The backup
system makes file copies of that database to user-visible storage.

### 7.1 `BackupService`

- **Output directory**:
  - Android: `<ExternalDocuments>/Bismillah_Backups/` — survives app
    uninstall on devices that preserve `Android/data/<package>/files/`.
  - Desktop / iOS fallback: `<AppDocuments>/Bismillah_Backups/`.
- **Two files written each run**:
  - `solo_con_<UTC-stamp>.db` — timestamped snapshot.
  - `solo_con_latest.db` — always overwrites; one-tap share target.
- **Atomic copy**: writes to `<dest>.tmp` then renames. A crash during
  copy leaves only an orphaned `.tmp`, never a corrupted destination
  file. Stale `.tmp` from a previous crashed run is deleted before each
  fresh copy.
- **Retention**: the last 30 timestamped snapshots are kept; older ones
  pruned automatically. The latest pointer is protected from deletion.
- `maybeRunSilentBackup()` gates on `last_backup_at` setting (≥ 6 h).
- `shareBackup()` triggers the system share sheet (WhatsApp, Gmail,
  Drive).
- `importBackup(path)` — validates the SQLite header, saves a
  `.before_import` rollback copy, then atomically overwrites the live
  DB.
- `rollbackLastImport()` — reinstates the `.before_import` file and
  preserves the now-old "current" as `.before_rollback` for forward
  rollback.

### 7.2 Auto-restore on first launch

`RestoreGateway` (in `features/common/`) runs before HomeScreen on every
cold boot. Logic:

1. Open the DB at the standard internal path.
2. If it has rows in `projects` or `journal_entries` → straight to
   HomeScreen (normal case).
3. If empty AND `solo_con_latest.db` exists in the backup folder →
   silently copy it over the internal DB, restart the provider tree, go
   to HomeScreen with the restored data.
4. If empty AND no backup exists → HomeScreen with empty data.

A static `_autoRestoreAttempted` flag survives the `restartApp()`
ProviderScope rebuild so a corrupt backup file cannot loop the spinner.

### 7.3 Validation contract

`validateBackupFile(path)` rejects:
- non-existent files
- files smaller than 100 B
- files whose first 16 bytes don't match the SQLite magic header
  (`'SQLite format 3 '`)

This is used by `importBackup` and exposed for unit tests.

---

## 8. Audit & traceability

Permissions are flat (single-operator app), so **the audit log is the
only forensic trail**.

- Every `softDeleteTransaction`, `restoreTransaction`,
  `hardDeleteTransaction`, `archiveProject`, `unarchiveProject` writes
  a row to `change_log`.
- Each row carries the install's stable `device_id` (UUID v4, generated
  on first run, stored in `app_settings`).
- Settings → **Change Log** lists every event newest-first with a CSV
  export.

---

## 9. Error reporting

Designed for the trial-week phase: framework, async and widget-build
errors are surfaced immediately, not silently swallowed.

### 9.1 `core/error_reporter.dart`

- Singleton holding the last 100 errors in
  `ValueNotifier<List<ErrorRecord>>`.
- `ErrorReporter.report(error, stack, source)` is callable from
  anywhere.
- Each report:
  - prepends an `ErrorRecord` to the in-memory ring buffer
  - pops a red SnackBar via a `GlobalKey<ScaffoldMessengerState>`
    (no BuildContext required, so async error handlers work)
  - the SnackBar has a "Details" action that opens a dialog with the
    full message and stack trace in monospace.

### 9.2 Wiring (`main.dart`)

```dart
FlutterError.onError = (details) {
  FlutterError.presentError(details);
  ErrorReporter.report(details.exceptionAsString(),
      stack: details.stack, source: 'FlutterError');
};

PlatformDispatcher.instance.onError = (error, stack) {
  ErrorReporter.report(error, stack: stack, source: 'Async');
  return true; // mark handled so the app doesn't crash
};

ErrorWidget.builder = (details) {
  ErrorReporter.report(details.exceptionAsString(),
      stack: details.stack, source: 'ErrorWidget');
  return _ErrorCard(message: details.exceptionAsString());
};
```

### 9.3 Surface in app

Settings → Audit → **Recent Errors** opens
`features/settings/recent_errors_screen.dart`:

- Lists each `ErrorRecord` with timestamp, source and first-line preview.
- ExpansionTile reveals full message + stack.
- "Copy full report" button bundles timestamp + source + message + stack
  into the clipboard for sharing via WhatsApp / email.

---

## 10. Boot sequence

1. `main.dart` — `WidgetsFlutterBinding.ensureInitialized()`, install
   `FlutterError.onError` / `PlatformDispatcher.onError` /
   `ErrorWidget.builder`, then conditionally
   `Supabase.initialize(...)` if `SupabaseConfig.configured`, then
   `runApp(...)`.
2. `app.dart` builds `MaterialApp` with `scaffoldMessengerKey:
   ErrorReporter.messengerKey` and **eagerly watches** three boot
   providers:
   - `syncServiceFutureProvider` — starts the sync service.
   - `backupBootCheckProvider` — runs the silent local backup if ≥ 6 h
     since last.
   - `commitSyncWiringProvider` — wires every successful ledger commit
     to `sync.syncNow()`.
3. `RestoreGateway.initState()` decides whether to silently restore
   from `solo_con_latest.db` or proceed straight to HomeScreen (see
   section 7.2).
4. `LocalDb.instance.open()` runs migrations to schema version 20.

---

## 10A. Cloud sync

Sync is opt-in: it only activates when `SUPABASE_URL` and
`SUPABASE_ANON_KEY` are baked into the build via `--dart-define`. With
no credentials, `SupabaseConfig.configured` is false and `SyncService`
no-ops.

### 10A.1 Wire-up

- `commitSyncWiringProvider` registers a listener on `LedgerRepository`
  that calls `sync.syncNow()` after every successful commit. The
  listener is debounced inside `SyncService` so a burst of writes
  results in one push, not N.
- `tenant_id` lives in `app_settings`. First sync generates a UUID v4
  and stamps every outgoing row with it. Bringing up a second device
  with the same tenant id (e.g. by importing a backup) is how
  multi-device works.

### 10A.2 Push

Each push reads `synced = 0` rows from every domain table and
`upsert`s them into the corresponding Supabase table tagged with
`tenant_id`. On success, the local row's `synced` flag is set to 1.

### 10A.3 Pull

Pull is **INSERT OR IGNORE** by design — a row that already exists
locally is skipped, so local writes are never overwritten by the
server. A per-table cursor (`last_pull_at_<table>` in `app_settings`)
narrows the query to rows with `updated_at > cursor`. Tables are
pulled in FK-safe order: projects / suppliers / banks /
counter_entities / material_types / labour_types first, then
journal_entries / material_inventory / notes / follow_ups.

### 10A.4 Schema

The Postgres mirror lives in [supabase/migrations/0001_initial.sql](supabase/migrations/0001_initial.sql).
Every table has `tenant_id uuid NOT NULL` and `updated_at timestamptz
NOT NULL DEFAULT now()` with an `AFTER UPDATE` trigger
(`bump_updated_at`) so the cursor query works without per-write hooks.
RLS is open within the project: anyone with the anon key sees
everything in the project, matching the no-auth single-operator design.

---

## 11. Test infrastructure

**106 automated tests across 6 files**, all passing under `flutter test`:

| File                              | Coverage                                         |
| --------------------------------- | ------------------------------------------------ |
| `invariants_test.dart`            | Engine invariants — double-entry, reconciliation, soft delete, aging, audit, banks |
| `business_logic_test.dart`        | PoC revenue recognition, labour-payment smart settlement, budget-mismatch gate, burn rate active-days, supplier-payable balance, end-to-end regressions |
| `backup_blackbox_test.dart`       | `validateBackupFile`, atomic copy, backup→restore round-trip, DB persistence, import rollback, corruption handling |
| `project_breakdown_test.dart`     | Per-supplier + per-material spend roll-ups, project filtering, soft-delete exclusion |
| `user_journeys_blackbox_test.dart`| Full user flows from project creation to archive |
| `widget_test.dart`                | Account ID uniqueness, transaction kinds have label + blurb |

All tests use `sqflite_common_ffi` to drive a real SQLite engine
(in-memory or temp-file) — no mocks. Schema is applied via
`LocalDb.applySchemaForTests` so the production migration code is
exercised on every test run.

Run:
```bash
flutter test                                  # all tests
flutter test test/backup_blackbox_test.dart   # one file
flutter analyze --no-fatal-infos              # static analysis
```

---

## 12. Schema migration history

| Version | Changes |
| ------- | ------- |
| v1      | Initial schema: customers, suppliers, projects, journal_entries, change_log, app_settings |
| v2      | ntn_cnic / address / credit_limit on customers; category / tax_status / bank_details on suppliers; customer_id / site_address / budget / project_manager on projects; banks + counter_entities + material_inventory tables |
| v3      | Soft delete (is_deleted / deleted_at) on journal_entries; service_fee_percent / is_archived / archived_at on projects; change_log + app_settings |
| v4      | device_id on change_log |
| v5      | client_name (free-text) on projects; seeded legacy hardcoded bank ids if referenced |
| v6      | is_archived / archived_at on suppliers and banks |
| v7      | material_types table (user-defined catalog, empty on fresh install) |
| v8      | Procurement metadata on material_types (uom_typ, uom, cov_rate, waste_f, lead_d, dims) |
| v9      | Removed seeded built-in material types — user defines every type from scratch |
| v10     | labour_types table |
| v11     | Added `REFERENCES projects(id)` and `REFERENCES suppliers(id)` FK constraints on journal_entries via table recreation; orphaned references nulled before migration |
| v12     | `completion_percent` column on projects (0..100, driver for the Site Snapshot's projected-cost forecast) |
| v13     | `transaction_id` denormalised onto material_inventory + soft-delete linkage so Material Price Trend / Budget vs Actual exclude deleted purchases |
| v14     | Operational memory: `notes` and `follow_ups` tables — pinnable per-entity notes, recovery reminders with priority + status; `updated_at` columns on all soft-delete tables |
| v15     | Cloud-sync plumbing: `synced` flag on every domain table, `tenant_id` + `last_pull_at_*` in app_settings, `updated_at` defaults applied across schema |
| v16     | Removed the Customer entity: dropped `customers` table, dropped `customer_id` column from projects + journal_entries (DROP COLUMN requires SQLite ≥ 3.35; guarded with try/catch). Project is now the only counterparty |
| v17     | Made `material_inventory.quantity` / `.rate` nullable (table recreated; bump-on-update trigger reinstated) so a material buy can be logged without a quantity. Quantity-less rows carry a null rate and are excluded from the Material Price Trend — their detail lives in the memo |
| v18     | `service_fee_type` (`'percent'` / `'fixed'`, default `'percent'`) + `service_fee_amount` on projects, so a Labour-Rate service fee can be a flat rupee amount instead of a percentage |
| v19     | `whatsapp` (client number) on projects, for the post-transaction WhatsApp confirmation. Suppliers reuse their existing `phone` column |
| v20     | `pending_pull` table — a **local-only** retry buffer (not synced to Supabase) for pulled rows whose FK parent isn't present yet. The pull buffers such orphans; every sync re-attempts them after pulling parents, so a child synced before/without its parent self-heals once the parent arrives |

---

## 13. Build & run

### 13.1 Prerequisites

- Flutter SDK 3.x with Dart 3.11.5+
- Android SDK 34 (`compileSdk` pinned in `android/build.gradle.kts`)
- For desktop: Visual Studio 2022 build tools (Windows)

### 13.2 Quick start

```bash
flutter pub get
flutter run                  # connected phone / emulator
flutter run -d windows       # Windows desktop
```

### 13.3 Release builds

```bash
# Android APK (universal)
flutter build apk --release

# Smaller per-ABI APKs
flutter build apk --release --split-per-abi

# AAB for Play Store
flutter build appbundle --release

# Windows desktop
flutter build windows --release

# With cloud sync — credentials baked in, not committed
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://<project>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable-anon-key>
```

Signed APK lands at `build/app/outputs/flutter-apk/app-release.apk`.

Before the first cloud-sync build, apply
[supabase/migrations/0001_initial.sql](supabase/migrations/0001_initial.sql)
in the Supabase Dashboard → SQL Editor → New Query.

### 13.4 Build-output relocation (Windows + OneDrive)

If your project lives inside a OneDrive-synced folder, the Android build
can fail with a permission error. Set `BISMILLAH_BUILD_DIR` to a path
outside OneDrive before building:

```powershell
$env:BISMILLAH_BUILD_DIR = "C:\bismillah-build"
flutter build apk --release
```

`android/build.gradle.kts` honours this env var.

---

## 14. Coding conventions

- Repositories never import `package:flutter/*`. Pure Dart — easy to
  unit-test with `sqflite_common_ffi`.
- Models are plain classes with `toMap()` / `fromMap()` / `const`
  constructors. No code generation.
- Screens use `ConsumerWidget` / `ConsumerStatefulWidget`. State that
  triggers data re-fetch goes through `ledgerVersionProvider`
  (`bumpLedger(ref)` after any mutation).
- Money is stored as `REAL` (double) in SQLite and formatted via
  `fmtMoney` / `fmtSignedMoney` / `fmtCompactMoney`. PKR, no decimal
  digits in the UI.
- Times are stored as ISO-8601 UTC strings; converted to local time for
  display via `fmtDate` / `fmtDateTime`.
- Positive/negative coloring uses `BalanceColors.signed(context, value)`
  — never hard-coded `Colors.green` / `Colors.red`.
- Comments reserved for the *why* (constraints, invariants, surprising
  behavior) — never the *what*.
- Theme palette: indigo (CTAs/buttons), deep navy (AppBar), cool gray
  (light scaffold), Material-3-derived surface (dark scaffold), emerald
  (positive financial), rose (negative financial). Red/green strictly
  reserved for financial gain/loss per the design spec.

---

## 15. License

Internal — © Bismillah Constructions.

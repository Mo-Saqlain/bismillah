# Bismillah Constructions ERP

Offline-first, double-entry construction-project ledger built in Flutter
for **Android**. Designed for a single operator running multiple sites:
cash, banks, suppliers, materials, labour, project P&L — all in one
place, with a local backup that survives app uninstall on most Android
devices and optional cloud sync to Supabase for multi-device use.

> **Repo layout:** the Flutter app lives at the **repository root**
> (`lib/`, `android/`, `test/`, `pubspec.yaml`). Android is the only
> shipped platform.

---

## What this app does

Bismillah records every rupee that moves through a construction
business and turns those entries into the reports an owner-operator
actually uses day-to-day.

### Two contract models

Pick one per project — the choice changes how revenue and profit are
recognized.

- **With Material** — you buy the materials and pay labour, customer
  pays a fixed contract price. Profit = received − costs.
- **Labour Rate** — you handle labour only and earn a service fee on
  the work. The fee is **either a percentage of total spend or a fixed
  rupee amount** (e.g. a flat Rs 500,000 regardless of spend), chosen
  per project. Customer money is pass-through; the service fee is the
  only revenue.

### The transaction picker

Every entry is a balanced double-entry pair. The New Transaction picker
exposes seven kinds:

1. **Material Buy** — supplier credit purchase. A **Counter purchase**
   toggle switches it to a cash buy at a shop (no supplier credit).
2. **Labour Payment** — smart-settle: if the worker has an outstanding
   wage credit, the payment clears it first instead of double-booking
   the cost.
3. **Labour on Credit** — wages incurred, not yet paid.
4. **Supplier Payment** — settle an outstanding payable.
5. **Receive from Project** — money in from the customer.
6. **Wallet Transfer** — move between your own cash / bank accounts.
7. **Personal / Owner Draw** — non-construction outflow.

Material purchases take an **optional** quantity — when provided it
powers the Material Price Trend report; when omitted the buy is tracked
by its memo alone. The Labour-Rate **service fee is not a manual entry**
— it's configured on the project (percentage or fixed) and posted
automatically as a reclassification when the project is reconciled/closed.

A single supplier can be tagged **Labour**, **Materials**, or **Both** —
a labour contractor who also supplies material on credit is one party,
not two. Their material and labour credit accumulate on one running
balance (payables are tracked per supplier, not per category), and a
**Both** party shows up in every relevant picker and ledger.

### WhatsApp confirmation on each transaction

After a transaction is saved, the app offers to open **WhatsApp**
pre-filled with a confirmation message to the transaction's
**counterparty** — the supplier for material/labour/supplier payments,
or the project's client for money received. You tap send in WhatsApp
(there's no automated sending). Suppliers use their existing phone
number; projects have a dedicated WhatsApp field. If the party has no
number on file the prompt is simply skipped.

### Percentage-of-Completion revenue recognition

Customer prepayments don't inflate profit. While a With-Material
project is in progress, revenue is recognized only up to costs
incurred (`min(received, costs)`); the rest sits as a customer-deposit
liability. Real profit appears at close. For Labour-Rate projects,
the service fee is the only earned revenue — everything else is
pass-through.

### Loss provision (FASB / IFRS)

The moment a project's costs exceed its budget, the overrun is booked
immediately as a separate cost line on the Income Statement — even if
the project hasn't closed yet. No hiding losses until reconciliation.

### Asymmetric archive gates

- **With-Material** projects need all supplier payables cleared, and
  an informational dialog opens if customer-received is below budget
  so you can decide whether to record the missing payment or edit the
  budget down.
- **Labour-Rate** projects need their pass-through ledger to net to
  zero after service-fee reclassification — refund or collect the
  residual before archiving. (With a fixed fee, this can mean the
  customer still owes fee + cost shortfall.)

### Operational memory

State that lives next to the money so site decisions aren't lost
between visits:

- **Notes** — pinnable free-text notes attached to a project or
  supplier; surface in their detail screens.
- **Site Snapshot** — one-screen aggregate per project: budget vs
  spent, customer deposit, supplier payables, projected remaining
  cost (driven by an owner-entered completion% slider), projected
  cash gap and projected final profit. Risk band (green/amber/red).
- **Closure Assistant** — gated walkthrough of what's still wrong
  before a project can be archived.
- **Follow-Ups** — recovery / billing reminders with expected date,
  priority, amount estimate; overdue tile on the dashboard.

### Dashboard

- **Treasury** — Net Liquidity, Net Position, Net Worth in one card,
  with a "Profit Illusion" insight explaining how much cash is
  earmarked for unpaid bills.
- **Wallets & Banks** grid — Cash plus every user-defined bank /
  wallet tile, tappable into its ledger.
- **Payables / Receivables** and **Customer Deposits** tiles.
- **Projects at Risk** — projects ≥ 80% of budget, over-budget first.
- **Overdue Follow-Ups**, **Cash Runway** traffic-light card, and a
  **7-Day Spending** bar chart.
- **Recent Activity** — last few transactions; "See all" opens the
  full history. A tap-to-sync cloud indicator sits in the app bar.

### Reports

Grouped so the ledgers come first, then formal statements, aging,
operations and project analysis.

**Ledgers** (each with a trial-balance header): Material Supplier
Ledger, Labour Supplier Ledger, Bank / Wallet Ledger, Project Ledger
(with supplier and material breakdowns).

**Financial Statements**: Income Statement (P&L, CSV + PDF), Balance
Sheet (Net Worth model, CSV + PDF), Cash Flow Statement, Monthly P&L
Trend (cumulative-delta bucketing).

**Aging**: FIFO open-balance matcher, 0-30 / 31-60 / 61-90 / 90+ buckets
— Payables (per supplier) and Receivables (under-funded projects +
supplier overpayments).

**Operations**: Supplier-wise Spending.

**Project Analysis**: Budget vs Actual, Project Profitability, Material
Price Trend.

### Local backup that survives uninstall

- **Automatic** silent backup on cold boot every 6 hours.
- **Atomic file copy** (`<dest>.tmp` then rename) — a crash mid-copy
  can never corrupt the destination.
- **Retention** — last 30 timestamped snapshots plus a
  `solo_con_latest.db` pointer.
- **Location** — Android external Documents folder, preserved on
  uninstall on most OEMs (some strict Android 14+ / One UI 6+ wipe it;
  share off-device first).
- **Manual**: Run backup now, Share latest backup, Import backup (with
  SQLite header check), Undo last import, Backup history, folder probe.
- **Auto-restore** on reinstall from `solo_con_latest.db`.

### Cloud sync (optional)

Push every domain row to Supabase Postgres for cloud backup and
multi-device use.

- **Push** every local write within seconds of commit; **pull** on
  start and on demand, using an `updated_at` cursor per table.
- **INSERT-only** conflict resolution — a local write is never
  overwritten by the server. The cloud mirrors every device's writes.
- **Tenant id** — a single fixed UUID **baked into the build**
  (`SUPABASE_TENANT_ID` in `secrets/dart_defines.json`). Every install
  of your APK uses it, so a fresh install / new phone syncs your data
  from the first launch — no login and no manual Tenant-ID copying.
  (Leave the define empty to fall back to the legacy random-per-install
  tenant.)
- **Sync diagnostics** (Settings → Cloud Sync) shows per-table
  `here / cloud / all-tenants` row counts so you can see exactly what
  is and isn't synced, and **Re-pull everything** safely re-downloads
  every row for your tenant (never overwrites local data).
- **Self-healing pull** — a pulled child row whose parent isn't present
  yet (a child synced before/without its project or supplier) is
  buffered and retried on every sync instead of aborting the sync or
  being lost; the moment the parent arrives, the child inserts
  automatically.
- **Re-push everything** — force-re-upload every row from this phone.
  Use on the device that created a project/supplier which never reached
  the cloud, so its transactions stop orphaning on other devices.
- **Build-time credentials** — `SUPABASE_URL` and `SUPABASE_ANON_KEY`
  are baked into the APK via `--dart-define`; no secrets are committed.
  Apply every file in [supabase/migrations/](supabase/migrations/)
  (`0001` → `0004`) in the Supabase SQL Editor, in order, before
  syncing. The app never runs DDL against Supabase — migrations are
  applied by hand.

### Audit & error reporting

- **Activity Log (Change Log)** — records **new transactions and new
  projects/suppliers/banks** as well as every edit, delete, restore and
  archive, with timestamps, JSON payload, note and a stable per-install
  device id. CSV export.
- **Recent Errors** — in-app log of framework / async / widget-build
  errors caught during the session, each with a one-tap
  "Copy full report" for forwarding via WhatsApp.

### Theme & UI

- **Light, Dark, System** modes (Indigo accent, neutral AppBar).
- Positive financial values in emerald, negative in rose — always via
  `BalanceColors.signed()`, never hard-coded.
- **Pill navigation bar** at the bottom of Home.
- **Type-ahead pickers**: every project / supplier / wallet / material /
  labour-type selector in the New Transaction form and report filters
  filters as you type; the entity-management screens (Projects,
  Suppliers, Banks, Material Types, Labour Types) and the ledger pickers
  each have a search box. Supplier search also matches phone number.
- **Zoom-safe**: the OS font/display scale is clamped so a phone set to
  a large display size stays legible; the New Transaction / Manage /
  Reports lists use compact single-line tiles.
- Charts render with compact money labels (Rs 1.5L, Rs 250k).

### Settings

Appearance · Backup & Export · Cloud Sync (status, last-sync, Sync
diagnostics, Re-pull everything, Sync now, Tenant ID) · Audit (Activity
Log, Recent Errors) · Catalogs (Material Types, Labour Types).

### 122 automated tests

All passing under `flutter test`, driving a real SQLite engine via
`sqflite_common_ffi` (no mocks); production migrations run on every
test. Suites: `invariants_test`, `business_logic_test`,
`service_fee_whatsapp_test` (fixed-vs-% fee + WhatsApp number
normalization), `backup_blackbox_test`, `project_breakdown_test`,
`operational_memory_test`, `cloud_sync_test`, `user_journeys_blackbox_test`,
`widget_test`.

---

## Documentation

- **[USER_MANUAL.md](USER_MANUAL.md)** — for the operator.
- **[TECHNICAL.md](TECHNICAL.md)** — for engineers: stack, data model,
  schema (v20), repositories, reporting engine, backup, cloud-sync
  design, migration history.
- **[CLAUDE.md](CLAUDE.md)** — orientation for AI assistants / future
  maintainers: load-bearing invariants, non-obvious decisions, where
  things live.

---

## Quick start

Run from the repository root:

```bash
flutter pub get
flutter run                          # connected Android phone / emulator
flutter test                         # 122 automated tests
flutter analyze --no-fatal-infos
```

### Release builds

```bash
flutter build apk --release                   # universal APK
flutter build apk --release --split-per-abi   # per-ABI APKs
flutter build appbundle --release             # Play Store AAB
```

Release signing is configured via `android/key.properties` +
`android/app/bismillah-release.jks` (both gitignored — keep them safe;
losing the keystore means you can't update the published app).

### Builds with cloud sync

Supabase credentials live in `secrets/dart_defines.json` (gitignored;
copy `secrets/dart_defines.example.json` and fill in your URL + anon
key). Easiest path — the helper script injects them:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_with_supabase.ps1 -Action build-apk
# or:  -Action run   (to run on a connected device)
```

Or pass them directly:

```bash
flutter build apk --release --dart-define-from-file=secrets/dart_defines.json
```

The signed APK lands at `build/app/outputs/flutter-apk/app-release.apk`.

For full deployment details, see
[TECHNICAL.md §13 Build & run](TECHNICAL.md#13-build--run).

---

## Privacy

- All data is stored locally on the device.
- Local backups are written to user-visible storage on the same device.
- Cloud sync is **opt-in** — only active when `SUPABASE_URL` and
  `SUPABASE_ANON_KEY` are baked into the build. Without those the app
  runs fully offline and no data leaves the device.
- No analytics, no telemetry, no crash-reporting service.

---

## License

Internal — © Bismillah Constructions.

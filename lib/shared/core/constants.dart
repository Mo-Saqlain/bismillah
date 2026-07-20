/// Account IDs and types — the Chart of Accounts.
library;

enum AccountType { asset, liability, income, expense, equity }

class Account {
  final String id;
  final String name;
  final AccountType type;
  const Account(this.id, this.name, this.type);
}

/// System (built-in) accounts. Banks / wallets defined by the user are loaded
/// at runtime from the `banks` table and joined onto these for the cash-like
/// list — see [cashLikeAccountsProvider].
///
/// "Supervisor Float" used to live here as a system wallet; it was removed
/// per user request — every cash-like account is now user-defined via the
/// banks table. The Cash account stays as a single fallback wallet.
class Accounts {
  // Assets — system
  static const cash = Account('CASH', 'Cash', AccountType.asset);
  static const externalWallet =
      Account('EXTERNAL_WALLET', 'External Wallet', AccountType.asset);

  // Liabilities
  static const supplierPayables =
      Account('SUPPLIER_PAY', 'Supplier Payables', AccountType.liability);

  // Income
  static const projectRevenue =
      Account('PROJECT_REV', 'Project Revenue', AccountType.income);
  static const serviceFeeIncome =
      Account('SERVICE_FEE', 'Service Fee Income', AccountType.income);

  // Expenses
  static const materialCosts =
      Account('MATERIAL_COSTS', 'Material Costs', AccountType.expense);
  static const labourCosts =
      Account('LABOUR_COSTS', 'Labour Costs', AccountType.expense);
  static const personalDraw =
      Account('PERSONAL_DRAW', 'Personal / Daily Draw', AccountType.expense);

  // Equity
  static const ownersEquity =
      Account('OWNERS_EQUITY', "Owner's Equity", AccountType.equity);

  /// All built-in accounts (does not include user-defined banks). Legacy
  /// `Supervisor Float` rows in old databases still resolve to a usable
  /// label via [byId]'s fallback.
  static const all = <Account>[
    cash,
    externalWallet,
    supplierPayables,
    projectRevenue,
    serviceFeeIncome,
    materialCosts,
    labourCosts,
    personalDraw,
    ownersEquity,
  ];

  static Account byId(String id) {
    // Legacy rows from before Supervisor Float was removed still reference
    // its account id — surface a friendly label so historical ledgers stay
    // readable even though the account is no longer in [all].
    if (id == 'SUPERVISOR_FLOAT') {
      return const Account('SUPERVISOR_FLOAT', 'Supervisor Float (legacy)',
          AccountType.asset);
    }
    return all.firstWhere((a) => a.id == id,
        orElse: () => Account(id, id, AccountType.asset));
  }

  /// System cash-like wallet ALWAYS available (just Cash). User-defined
  /// banks are appended at runtime via `cashLikeAccountsProvider`.
  static const systemCashLike = <Account>[cash];
}

enum ProjectModel { withMaterial, labourRate }

extension ProjectModelX on ProjectModel {
  String get label => switch (this) {
        ProjectModel.withMaterial => 'With Material',
        ProjectModel.labourRate => 'Labour Rate',
      };
  String get db => name;
  static ProjectModel fromDb(String s) =>
      ProjectModel.values.firstWhere((v) => v.name == s,
          orElse: () => ProjectModel.withMaterial);
}

/// How a Labour-Rate project's service fee (the contractor's earnings) is
/// calculated: a percentage of everything spent, or a flat rupee amount
/// agreed up front regardless of spend.
enum ServiceFeeType { percent, fixed }

extension ServiceFeeTypeX on ServiceFeeType {
  String get label => switch (this) {
        ServiceFeeType.percent => 'Percentage of spend',
        ServiceFeeType.fixed => 'Fixed amount',
      };
  String get db => name;
  static ServiceFeeType fromDb(String? s) =>
      ServiceFeeType.values.firstWhere((v) => v.name == s,
          orElse: () => ServiceFeeType.percent);
}

enum ProjectStatus { active, closed }

extension ProjectStatusX on ProjectStatus {
  String get label => switch (this) {
        ProjectStatus.active => 'Active',
        ProjectStatus.closed => 'Closed',
      };
  String get db => name;
  static ProjectStatus fromDb(String s) =>
      ProjectStatus.values.firstWhere((v) => v.name == s,
          orElse: () => ProjectStatus.active);
}

/// `both` is for a party who provides *both* labour and materials — e.g. a
/// labour contractor who also supplies material on credit. It carries no
/// ledger consequence (payables are scoped by `supplier_id`, never by
/// category) and needs no schema change (`suppliers.category` is a free TEXT
/// column locally and on Supabase); it only widens which transaction pickers
/// the party appears in. A `null`/uncategorized supplier still appears in
/// every picker (legacy).
enum SupplierCategory { labor, material, both }

extension SupplierCategoryX on SupplierCategory {
  String get label => switch (this) {
        SupplierCategory.labor => 'Labour',
        SupplierCategory.material => 'Materials',
        SupplierCategory.both => 'Both',
      };

  /// True when a supplier of this category should appear in the material /
  /// supplier-pay picker. `null` category also matches — handled at the call
  /// site so legacy rows stay visible everywhere.
  bool get suppliesMaterial =>
      this == SupplierCategory.material || this == SupplierCategory.both;

  /// True when a supplier of this category should appear in the labour picker.
  bool get suppliesLabour =>
      this == SupplierCategory.labor || this == SupplierCategory.both;

  String get db => name;
  static SupplierCategory fromDb(String s) =>
      SupplierCategory.values.firstWhere((v) => v.name == s,
          orElse: () => SupplierCategory.material);
}

enum CounterEntityType { receivable, payable }

extension CounterEntityTypeX on CounterEntityType {
  String get label => switch (this) {
        CounterEntityType.receivable => 'Receivable (Asset)',
        CounterEntityType.payable => 'Payable (Liability)',
      };
  String get db => name;
  static CounterEntityType fromDb(String s) =>
      CounterEntityType.values.firstWhere((v) => v.name == s,
          orElse: () => CounterEntityType.receivable);
}

/// Material categories are now user-defined (see the `material_types` table
/// and Settings → Material Types). The enum was removed in v7 — the column
/// stores a free-form string keyed off `material_types.name`.

/// Legacy unit retained for schema compatibility. New entries record `lump`
/// because the UI only collects a price (quantity goes in the memo).
enum MaterialUnit { lump, pcs, bag, kg, piece }

extension MaterialUnitX on MaterialUnit {
  String get label => switch (this) {
        MaterialUnit.lump => 'Lump-sum',
        MaterialUnit.pcs => 'Pcs (count)',
        MaterialUnit.bag => 'Bag',
        MaterialUnit.kg => 'KG',
        MaterialUnit.piece => 'Piece',
      };
  String get db => name;
  static MaterialUnit fromDb(String s) =>
      MaterialUnit.values.firstWhere((v) => v.name == s,
          orElse: () => MaterialUnit.lump);
}

enum MaterialTxnType { purchase, consumption }

extension MaterialTxnTypeX on MaterialTxnType {
  String get db => name;
  static MaterialTxnType fromDb(String s) =>
      MaterialTxnType.values.firstWhere((v) => v.name == s,
          orElse: () => MaterialTxnType.purchase);
}

/// Canonical transaction types — money flows in or out of a project.
enum TxnKind {
  materialBuy,         // Dr Material Costs / Cr Supplier Payables (project mandatory)
  materialCounter,     // Dr Material Costs / Cr Cash|Bank (counter purchase, no supplier)
  labourPayment,       // Dr Labour Costs / Cr Cash|Bank  (project mandatory)
  labourCredit,        // Dr Labour Costs / Cr Supplier Payables (wages incurred but not yet paid)
  supplierPay,         // Dr Supplier Payables / Cr Cash|Bank
  receiveFromProject,  // Dr Cash|Bank / Cr Project Revenue (direct receipt — no receivable phase)
  walletTransfer,      // Dr destination wallet / Cr source wallet
  personalDraw,        // Dr Personal Draw / Cr Cash|Bank (does NOT touch payables)
  serviceFee,          // Dr Cash|Bank / Cr Service Fee Income (labour-rate model)
}

extension TxnKindX on TxnKind {
  String get label => switch (this) {
        TxnKind.materialBuy => 'Material Buy (Credit)',
        TxnKind.materialCounter => 'Material Buy (Counter Purchase)',
        TxnKind.labourPayment => 'Labour Payment',
        TxnKind.labourCredit => 'Labour on Credit',
        TxnKind.supplierPay => 'Supplier Payment',
        TxnKind.receiveFromProject => 'Receive from Project',
        TxnKind.walletTransfer => 'Wallet Transfer',
        TxnKind.personalDraw => 'Personal / Owner Draw',
        TxnKind.serviceFee => 'Service Fee Logged',
      };
  String get blurb => switch (this) {
        TxnKind.materialBuy =>
          'Buy material on credit from a supplier (project required)',
        TxnKind.materialCounter =>
          'Pay for material on the spot from cash or bank — no supplier credit; project required',
        TxnKind.labourPayment =>
          'Pay a labour provider for a project (project required)',
        TxnKind.labourCredit =>
          'Record wages owed to labour but not yet paid — count of workers + total pay',
        TxnKind.supplierPay =>
          'Settle a payable to a material or labour supplier from cash or bank',
        TxnKind.receiveFromProject =>
          'Receive money from the project — booked as project revenue',
        TxnKind.walletTransfer =>
          'Move cash between bank / cash / supervisor wallets',
        TxnKind.personalDraw =>
          'Money leaving cash, a wallet or a bank for non-construction use (personal expenses, transfers out, owner draw)',
        TxnKind.serviceFee =>
          'Log service fee earned (% of project spend, labour-rate model)',
      };
}

/// Action recorded in the change log.
enum ChangeAction { create, delete, restore, archive, unarchive, edit }

extension ChangeActionX on ChangeAction {
  String get label => switch (this) {
        ChangeAction.create => 'Created',
        ChangeAction.delete => 'Deleted',
        ChangeAction.restore => 'Restored',
        ChangeAction.archive => 'Archived',
        ChangeAction.unarchive => 'Unarchived',
        ChangeAction.edit => 'Edited',
      };
  String get db => name;
  static ChangeAction fromDb(String s) =>
      ChangeAction.values.firstWhere((v) => v.name == s,
          orElse: () => ChangeAction.edit);
}

/// App-wide settings keys (stored in `app_settings` table).
class SettingsKeys {
  static const themeMode = 'theme_mode'; // 'light' | 'dark' | 'system'
  static const lastBackupAt = 'last_backup_at';
  static const deviceId = 'device_id';

  /// Optional user-chosen backup folder (desktop "edit backup path"). When
  /// set, backups are written to / read from here instead of the default
  /// Documents\Bismillah_Backups. Empty/unset → default location.
  static const backupDir = 'backup_dir';

  // v15: cloud-sync state.
  /// UUID identifying this operator's data scope on Supabase. Generated
  /// once on first sync; copy it from one device to a second so they
  /// share the same dataset.
  static const tenantId = 'tenant_id';

  /// '1' / '0' — user opt-in to cloud sync. Defaults to '1' when
  /// SupabaseConfig is configured (matches the existing auto-start
  /// behaviour); user can disable from Settings → Cloud Sync.
  static const cloudSyncEnabled = 'cloud_sync_enabled';

  /// ISO-8601 cursor for the **pull** stream — server rows with
  /// `updated_at > this` are candidates for a pull. Keyed per table
  /// (e.g. `cloud_pull_at:journal_entries`).
  static String pullCursor(String table) => 'cloud_pull_at:$table';

  /// ISO-8601 cursor for the **push** stream — local rows with
  /// `updated_at > this` are candidates for a push.
  static String pushCursor(String table) => 'cloud_push_at:$table';
}

class SupabaseConfig {
  static const url = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const anonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// Optional fixed tenant id baked into the build. When set, every install
  /// of this APK shares this one tenant, so cloud sync "just works" from the
  /// first launch — no per-install random tenant, no manual Tenant-ID copying
  /// on reinstall. Fits the single-operator model (the APK is private to the
  /// operator; the anon key is already baked in, so this adds no new
  /// exposure). Leave empty to fall back to the legacy
  /// generate-a-random-tenant-once-per-install behaviour.
  static const tenantId =
      String.fromEnvironment('SUPABASE_TENANT_ID', defaultValue: '');

  static bool get configured => url.isNotEmpty && anonKey.isNotEmpty;
}

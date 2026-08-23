import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/models/change_log.dart';
import 'package:bismillah_constructions/shared/data/models/journal_entry.dart';
import 'package:bismillah_constructions/shared/data/models/material_escalation.dart';
import 'package:bismillah_constructions/shared/data/models/material_item.dart' show resolveMaterialLabel;

// Result classes (CashFlowSummary, IncomeFigures, AgingReport, etc.)
// live in this part file so the main repository file stays focused on
// behaviour, not data shapes. Importers continue to use a single
// `import 'ledger_repository.dart';` and get every related type.
part 'ledger_repository_models.dart';

const _uuid = Uuid();

/// Single mediator for *all* writes to `journal_entries`.
///
/// Posts are double-entry (one debit row + one credit row sharing a
/// `transaction_id`). Soft-deletes set `is_deleted = 1`; corrections via
/// reversal post a *new* offsetting transaction.
class LedgerRepository {
  LedgerRepository(this._db);
  final Database _db;

  /// Read-only escape hatch for callers (like [SyncService]) that need
  /// to issue raw queries against the same underlying database. Keep
  /// usages narrow — almost everything should go through the typed
  /// methods on this class.
  Database get db => _db;

  /// Hooks: callers can attach listeners to know when a write happened so
  /// they can fire a cloud sync. Kept on the repo (not the DB) so background
  /// cron writes don't trigger spurious uploads.
  final List<void Function()> _commitListeners = [];

  void addCommitListener(void Function() listener) =>
      _commitListeners.add(listener);
  void removeCommitListener(void Function() listener) =>
      _commitListeners.remove(listener);
  void _fireCommit() {
    for (final fn in List.of(_commitListeners)) {
      try {
        fn();
      } catch (_) {/* listener errors must not affect the write path */}
    }
  }

  /// Stable per-install identifier, recorded on every audit row for traceability
  /// in a flat-permissions setup. Cached after first read.
  String? _cachedDeviceId;
  Future<String?> _deviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId;
    final rows = await _db.query('app_settings',
        where: 'key = ?', whereArgs: ['device_id'], limit: 1);
    final v = rows.isEmpty ? null : rows.first['value'] as String?;
    _cachedDeviceId = v;
    return v;
  }

  // -------------------- Validation helpers --------------------

  /// Throws [ArgumentError] if [value] is null or blank. Used to catch
  /// programming mistakes where a required FK field is passed as an empty
  /// string instead of a valid UUID.
  static void _assertNonEmpty(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      throw ArgumentError('$fieldName must not be null or empty.');
    }
  }

  // -------------------- Posting helpers --------------------

  Future<String> _post({
    required Account debitAccount,
    required Account creditAccount,
    required double amount,
    String? projectId,
    String? supplierId,
    String? description,
  }) async {
    if (amount <= 0) {
      throw ArgumentError('Amount must be positive (got $amount).');
    }
    final txnId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final dev = await _deviceId();

    await _db.transaction((txn) async {
      final debitRow = JournalEntry(
        id: _uuid.v4(),
        transactionId: txnId,
        accountId: debitAccount.id,
        projectId: projectId,
        supplierId: supplierId,
        debit: amount,
        credit: 0,
        description: description,
        createdAt: now,
      ).toMap();
      final creditRow = JournalEntry(
        id: _uuid.v4(),
        transactionId: txnId,
        accountId: creditAccount.id,
        projectId: projectId,
        supplierId: supplierId,
        debit: 0,
        credit: amount,
        description: description,
        createdAt: now,
      ).toMap();
      await txn.insert('journal_entries', debitRow);
      await txn.insert('journal_entries', creditRow);
      // Audit the creation so the Activity Log reflects normal use, not just
      // edits/deletes. Every ledger write funnels through _post, so this is
      // the single place that captures "a transaction was added". Payload
      // lives in new_data (the row's initial state).
      await txn.insert(
          'change_log',
          ChangeLog(
            id: _uuid.v4(),
            entityType: 'journal_entry',
            entityId: txnId,
            action: ChangeAction.create,
            newData: jsonEncode([debitRow, creditRow]),
            deviceId: dev,
            timestamp: now,
          ).toMap());
    });

    _fireCommit();
    return txnId;
  }

  // -------------------- Canonical transactions --------------------

  Future<String> postMaterialBuy({
    required double amount,
    required String projectId,
    required String supplierId,
    String? description,
  }) {
    _assertNonEmpty(projectId, 'projectId');
    _assertNonEmpty(supplierId, 'supplierId');
    return _post(
      debitAccount: Accounts.materialCosts,
      creditAccount: Accounts.supplierPayables,
      amount: amount,
      projectId: projectId,
      supplierId: supplierId,
      description: description,
    );
  }

  /// Counter purchase: pay for material on the spot, no supplier credit.
  /// Dr Material Costs / Cr Cash|Bank, tagged to a project but with no
  /// supplier_id. The corresponding `material_inventory` row carries the
  /// quantity / unit / rate the user enters, which feeds the price-trend
  /// report — so even for counter buys we don't lose the unit-price data.
  Future<String> postMaterialCounter({
    required double amount,
    required String projectId,
    required Account paidFrom,
    String? description,
  }) async {
    _assertNonEmpty(projectId, 'projectId');
    await _assertCashLike(paidFrom);
    return _post(
      debitAccount: Accounts.materialCosts,
      creditAccount: paidFrom,
      amount: amount,
      projectId: projectId,
      // supplier_id intentionally null — counter buys are anonymous.
      description: description,
    );
  }

  /// Pay a labour worker. If the worker already has wages on credit
  /// (recorded earlier via [postLabourCredit]), this payment **settles the
  /// outstanding payable first** rather than booking a brand-new cost. Only
  /// any excess beyond what is owed becomes a new direct labour cost.
  ///
  /// Without this rule, paying a worker after recording their wages on
  /// credit would double-count: Labour Costs would jump to 3000 and the
  /// payable would still sit at 1500, when the user expects 1500/0.
  Future<String> postLabourPayment({
    required double amount,
    required String projectId,
    required String supplierId,
    required Account paidFrom,
    String? description,
  }) async {
    _assertNonEmpty(projectId, 'projectId');
    _assertNonEmpty(supplierId, 'supplierId');
    await _assertCashLike(paidFrom);

    final owed = await supplierPayableBalance(supplierId);

    // Full settlement: payment ≤ what we owe. One transaction settling the
    // payable, no new cost (cost was booked at credit time).
    if (owed >= amount - 0.01) {
      return _post(
        debitAccount: Accounts.supplierPayables,
        creditAccount: paidFrom,
        amount: amount,
        projectId: projectId,
        supplierId: supplierId,
        description: description,
      );
    }

    // Partial: settle the existing credit, then book the remainder as a
    // fresh direct labour cost. Two posts under the same description so the
    // ledger view shows a coherent payment.
    if (owed > 0.01) {
      await _post(
        debitAccount: Accounts.supplierPayables,
        creditAccount: paidFrom,
        amount: owed,
        projectId: projectId,
        supplierId: supplierId,
        description: description,
      );
      return _post(
        debitAccount: Accounts.labourCosts,
        creditAccount: paidFrom,
        amount: amount - owed,
        projectId: projectId,
        supplierId: supplierId,
        description: description,
      );
    }

    // No outstanding credit — direct labour cost like before.
    return _post(
      debitAccount: Accounts.labourCosts,
      creditAccount: paidFrom,
      amount: amount,
      projectId: projectId,
      supplierId: supplierId,
      description: description,
    );
  }

  /// Net amount we currently owe a single supplier (credits − debits on
  /// the Supplier Payables account, scoped to this supplier id). Positive
  /// = we still owe them; zero = settled; negative = we overpaid.
  Future<double> supplierPayableBalance(String supplierId) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(credit), 0) - COALESCE(SUM(debit), 0) AS bal '
      'FROM journal_entries '
      'WHERE account_id = ? AND supplier_id = ? AND is_deleted = 0',
      [Accounts.supplierPayables.id, supplierId],
    );
    return ((rows.first['bal'] as num?) ?? 0).toDouble();
  }

  /// Wages incurred but not yet paid. Posts Dr Labour Costs / Cr Supplier
  /// Payables — symmetric to [postMaterialBuy] but for labour.
  ///
  /// The cost hits the project ledger immediately (via Labour Costs); the
  /// payable to the worker shows up on their supplier ledger and is settled
  /// later by [postSupplierPay] when cash actually leaves.
  Future<String> postLabourCredit({
    required double amount,
    required String projectId,
    required String supplierId,
    String? description,
  }) {
    _assertNonEmpty(projectId, 'projectId');
    _assertNonEmpty(supplierId, 'supplierId');
    return _post(
      debitAccount: Accounts.labourCosts,
      creditAccount: Accounts.supplierPayables,
      amount: amount,
      projectId: projectId,
      supplierId: supplierId,
      description: description,
    );
  }

  Future<String> postSupplierPay({
    required double amount,
    required String supplierId,
    required Account paidFrom,
    String? projectId,
    String? description,
  }) async {
    _assertNonEmpty(supplierId, 'supplierId');
    await _assertCashLike(paidFrom);
    return _post(
      debitAccount: Accounts.supplierPayables,
      creditAccount: paidFrom,
      amount: amount,
      supplierId: supplierId,
      projectId: projectId,
      description: description,
    );
  }

  /// Direct receipt from project — no receivable phase. Money moves from the
  /// client into a cash/bank account and is booked as project revenue at the
  /// same time. The project_id is mandatory because the user removed the
  /// separate Customer entity and the project is the only counterparty.
  Future<String> postReceiveFromProject({
    required double amount,
    required String projectId,
    required Account receivedInto,
    String? description,
  }) async {
    _assertNonEmpty(projectId, 'projectId');
    await _assertCashLike(receivedInto);
    return _post(
      debitAccount: receivedInto,
      creditAccount: Accounts.projectRevenue,
      amount: amount,
      projectId: projectId,
      description: description,
    );
  }

  /// Inter-wallet transfer. Does NOT touch payables (spec section 1).
  Future<String> postWalletTransfer({
    required double amount,
    required Account from,
    required Account to,
    String? description,
  }) async {
    await _assertCashLike(from);
    await _assertCashLike(to);
    if (from.id == to.id) {
      throw ArgumentError('Source and destination wallet must differ.');
    }
    return _post(
      debitAccount: to,
      creditAccount: from,
      amount: amount,
      description: description ?? 'Transfer ${from.name} → ${to.name}',
    );
  }

  /// Personal / daily expense draw. Reduces liquid cash but leaves supplier
  /// payables intact (spec section 1).
  Future<String> postPersonalDraw({
    required double amount,
    required Account paidFrom,
    String? description,
  }) async {
    await _assertCashLike(paidFrom);
    return _post(
      debitAccount: Accounts.personalDraw,
      creditAccount: paidFrom,
      amount: amount,
      description: description,
    );
  }

  /// Opening balance for a freshly-created bank/wallet. Posts
  /// Dr Bank / Cr Owner's Equity so the asset is properly recognized in the
  /// double-entry books.
  Future<String?> postOpeningBalance({
    required Account bankAccount,
    required double amount,
  }) async {
    if (amount <= 0) return null;
    return _post(
      debitAccount: bankAccount,
      creditAccount: Accounts.ownersEquity,
      amount: amount,
      description: 'Opening balance',
    );
  }

  /// Service fee for Labour-Rate model (spec section 2 / interim fees).
  Future<String> postServiceFee({
    required double amount,
    required String projectId,
    required Account receivedInto,
    String? description,
  }) async {
    _assertNonEmpty(projectId, 'projectId');
    await _assertCashLike(receivedInto);
    return _post(
      debitAccount: receivedInto,
      creditAccount: Accounts.serviceFeeIncome,
      amount: amount,
      projectId: projectId,
      description: description,
    );
  }

  /// Returns true if [accountId] is a system cash-like account (Cash /
  /// Supervisor Float) OR a user-defined bank/wallet (row in `banks`).
  Future<bool> _isCashLikeId(String accountId) async {
    if (Accounts.systemCashLike.any((a) => a.id == accountId)) return true;
    final rows = await _db.rawQuery(
      'SELECT 1 FROM banks WHERE id = ? LIMIT 1', [accountId]);
    return rows.isNotEmpty;
  }

  Future<void> _assertCashLike(Account a) async {
    if (!await _isCashLikeId(a.id)) {
      throw ArgumentError('Account ${a.id} is not a cash/bank account.');
    }
  }

  /// Snapshot of cash-like account ids at a point in time. Used by
  /// aggregations like [monthlyCashFlow] that need to filter by a fixed set.
  Future<List<String>> cashLikeAccountIds() async {
    final banks = await _db.query('banks');
    return [
      ...Accounts.systemCashLike.map((a) => a.id),
      ...banks.map((r) => r['id'] as String),
    ];
  }

  // -------------------- Reversal & soft delete --------------------

  Future<String> postReversal(String originalTxnId, {String? note}) async {
    final rows = await _db.query('journal_entries',
        where: 'transaction_id = ?', whereArgs: [originalTxnId]);
    if (rows.length != 2) {
      throw StateError(
          'Expected 2 rows for txn $originalTxnId, found ${rows.length}');
    }
    final pair = rows.map(JournalEntry.fromMap).toList();
    final debitRow = pair.firstWhere((r) => r.debit > 0);
    final creditRow = pair.firstWhere((r) => r.credit > 0);
    final amount = debitRow.debit;
    final desc = note ?? 'Reversal of txn $originalTxnId';

    final newTxnId = _uuid.v4();
    final now = DateTime.now().toUtc();
    await _db.transaction((txn) async {
      await txn.insert(
          'journal_entries',
          JournalEntry(
            id: _uuid.v4(),
            transactionId: newTxnId,
            accountId: debitRow.accountId,
            projectId: debitRow.projectId,
            supplierId: debitRow.supplierId,
            debit: 0,
            credit: amount,
            description: desc,
            createdAt: now,
          ).toMap());
      await txn.insert(
          'journal_entries',
          JournalEntry(
            id: _uuid.v4(),
            transactionId: newTxnId,
            accountId: creditRow.accountId,
            projectId: creditRow.projectId,
            supplierId: creditRow.supplierId,
            debit: amount,
            credit: 0,
            description: desc,
            createdAt: now,
          ).toMap());
    });
    _fireCommit();
    return newTxnId;
  }

  /// Soft-delete a transaction (both rows). Removed from active balance,
  /// kept visible in archive view. Logged in `change_log`.
  Future<void> softDeleteTransaction(String transactionId,
      {String? note}) async {
    final rows = await _db.query('journal_entries',
        where: 'transaction_id = ? AND is_deleted = 0',
        whereArgs: [transactionId]);
    if (rows.isEmpty) return;
    final original = rows.map(JournalEntry.fromMap).toList();
    final now = DateTime.now().toUtc();
    final dev = await _deviceId();

    await _db.transaction((txn) async {
      await txn.update(
        'journal_entries',
        {'is_deleted': 1, 'deleted_at': now.toIso8601String()},
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );
      // Mirror the deletion on material_inventory so price-trend and
      // BvA stop counting the deleted purchase. v13 added the column.
      await txn.update(
        'material_inventory',
        {'is_deleted': 1, 'deleted_at': now.toIso8601String()},
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );
      await txn.insert(
          'change_log',
          ChangeLog(
            id: _uuid.v4(),
            entityType: 'journal_entry',
            entityId: transactionId,
            action: ChangeAction.delete,
            originalData: jsonEncode(original.map((e) => e.toMap()).toList()),
            note: note,
            deviceId: dev,
            timestamp: now,
          ).toMap());
    });
    _fireCommit();
  }

  /// Permanently remove both rows of a transaction. The original payload is
  /// preserved in `change_log` for audit. Use this when the user wants the
  /// transaction *gone* from history (soft delete keeps it visible in
  /// "Show deleted" mode).
  Future<void> hardDeleteTransaction(String transactionId,
      {String? note}) async {
    final rows = await _db.query('journal_entries',
        where: 'transaction_id = ?', whereArgs: [transactionId]);
    if (rows.isEmpty) return;
    final original = rows.map(JournalEntry.fromMap).toList();
    final now = DateTime.now().toUtc();
    final dev = await _deviceId();

    await _db.transaction((txn) async {
      await txn.delete('journal_entries',
          where: 'transaction_id = ?', whereArgs: [transactionId]);
      // Hard-deleting the journal txn must also drop the inventory row
      // for the same transaction, otherwise the Material Price Trend
      // and Budget vs Actual keep showing the orphaned purchase.
      await txn.delete('material_inventory',
          where: 'transaction_id = ?', whereArgs: [transactionId]);
      await txn.insert(
          'change_log',
          ChangeLog(
            id: _uuid.v4(),
            entityType: 'journal_entry',
            entityId: transactionId,
            action: ChangeAction.delete,
            originalData: jsonEncode(original.map((e) => e.toMap()).toList()),
            note: note ?? 'hard delete',
            deviceId: dev,
            timestamp: now,
          ).toMap());
    });
    _fireCommit();
  }

  /// Restore a soft-deleted transaction.
  Future<void> restoreTransaction(String transactionId,
      {String? note}) async {
    final rows = await _db.query('journal_entries',
        where: 'transaction_id = ? AND is_deleted = 1',
        whereArgs: [transactionId]);
    if (rows.isEmpty) return;
    final now = DateTime.now().toUtc();
    final dev = await _deviceId();

    await _db.transaction((txn) async {
      await txn.update(
        'journal_entries',
        {'is_deleted': 0, 'deleted_at': null},
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );
      // Mirror restore on the inventory side.
      await txn.update(
        'material_inventory',
        {'is_deleted': 0, 'deleted_at': null},
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
      );
      await txn.insert(
          'change_log',
          ChangeLog(
            id: _uuid.v4(),
            entityType: 'journal_entry',
            entityId: transactionId,
            action: ChangeAction.restore,
            note: note,
            deviceId: dev,
            timestamp: now,
          ).toMap());
    });
    _fireCommit();
  }

  /// Completely wipe all transaction and activity data from the database.
  Future<void> wipeAllData() async {
    await _db.transaction((txn) async {
      await txn.delete('journal_entries');
      await txn.delete('material_inventory');
      await txn.delete('change_log');
      await txn.delete('pending_pull');
      await txn.delete('counter_entities');
    });
    _fireCommit();
  }

  // -------------------- Reads --------------------

  /// Live entries — excludes soft-deleted by default.
  Future<List<JournalEntry>> recentEntries({int limit = 50}) async {
    final rows = await _db.query('journal_entries',
        where: 'is_deleted = 0',
        orderBy: 'created_at DESC',
        limit: limit);
    return rows.map(JournalEntry.fromMap).toList();
  }

  Future<List<JournalEntry>> allEntries({bool includeDeleted = false}) async {
    final rows = await _db.query('journal_entries',
        where: includeDeleted ? null : 'is_deleted = 0',
        orderBy: 'created_at DESC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  Future<List<JournalEntry>> deletedEntries() async {
    final rows = await _db.query('journal_entries',
        where: 'is_deleted = 1', orderBy: 'deleted_at DESC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  Future<List<JournalEntry>> entriesForSupplier(String supplierId,
      {String? projectId,
      DateTime? from,
      DateTime? to,
      bool includeDeleted = false}) async {
    final where = StringBuffer('supplier_id = ?');
    final args = <Object>[supplierId];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      // Inclusive upper bound: bump to next-day midnight so transactions
      // dated on `to` itself are included regardless of their time-of-day.
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    if (!includeDeleted) where.write(' AND is_deleted = 0');
    final rows = await _db.query('journal_entries',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'created_at ASC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  /// Every journal row that touches a specific account (typically a bank /
  /// wallet id), oldest → newest. Used by the bank ledger report to build a
  /// running balance. Optional [from]/[to] filters narrow to a date window
  /// inclusive on both ends.
  Future<List<JournalEntry>> entriesForAccount(String accountId,
      {DateTime? from,
      DateTime? to,
      bool includeDeleted = false}) async {
    final where = StringBuffer('account_id = ?');
    final args = <Object>[accountId];
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    if (!includeDeleted) where.write(' AND is_deleted = 0');
    final rows = await _db.query('journal_entries',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'created_at ASC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  /// Project ledger feed.
  ///
  /// `_post` tags BOTH legs of a balanced txn with the same `project_id`, so
  /// a naïve "where project_id = ?" returns the offsetting cash/payables row
  /// alongside the actual project leg — and the ledger view ends up
  /// double-counting (and rendering revenue as a fake debit). We filter to
  /// only the four accounts that actually represent project economics:
  ///
  ///   * Material Costs / Labour Costs — cost side (natural debit)
  ///   * Project Revenue / Service Fee Income — income side (natural credit)
  ///
  /// Consequences:
  ///   * Supplier Pay no longer appears in the project ledger (the cost was
  ///     already booked at Material Buy time; the payment is a cash-side
  ///     settlement, not a project cost event).
  ///   * Receive From Project / Service Fee land in the credit column and
  ///     properly reduce the project's net cost-side position.
  Future<List<JournalEntry>> entriesForProject(String projectId,
      {DateTime? from,
      DateTime? to,
      bool includeDeleted = false}) async {
    const projectAccountIds = <String>[
      'MATERIAL_COSTS',
      'LABOUR_COSTS',
      'PROJECT_REV',
      'SERVICE_FEE',
    ];
    final where = StringBuffer(
        'project_id = ? AND account_id IN (${projectAccountIds.map((_) => '?').join(', ')})');
    final args = <Object>[projectId, ...projectAccountIds];
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    if (!includeDeleted) where.write(' AND is_deleted = 0');
    final rows = await _db.query('journal_entries',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'created_at ASC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  /// Wage ledger feed: every Labour Costs debit charged against this
  /// supplier (worker). Mirrors [entriesForProject]'s account-filter
  /// approach so payments to other suppliers don't leak in.
  Future<List<JournalEntry>> entriesForWorker(String supplierId,
      {DateTime? from,
      DateTime? to,
      bool includeDeleted = false}) async {
    final where = StringBuffer(
        'supplier_id = ? AND account_id = ? AND debit > 0');
    final args = <Object>[supplierId, Accounts.labourCosts.id];
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    if (!includeDeleted) where.write(' AND is_deleted = 0');
    final rows = await _db.query('journal_entries',
        where: where.toString(),
        whereArgs: args,
        orderBy: 'created_at ASC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  /// Comprehensive cash flow summary across every cash-like account
  /// (Cash + Supervisor Float + every user bank). Bucketed into operating
  /// vs financing activities so the report follows the FBR-style indirect
  /// cash-flow layout. Optional [from]/[to] window applies to all cash
  /// movements; the opening balance is the cash position right before
  /// [from] (or zero if no `from` is set).
  ///
  /// Categorisation rule (driven by the OTHER side of each cash leg):
  ///   * Operating inflow  ← Project Revenue, Service Fee Income credits
  ///   * Operating outflow ← Material Costs / Labour Costs debits, Supplier
  ///     Payables debits (settlements of trade liabilities)
  ///   * Financing outflow ← Personal / Daily Draw debits
  ///   * Other             ← anything else (opening balances etc.)
  /// Wallet transfers are ignored — the cash leaves one cash-like account
  /// and lands in another, so the consolidated cash position doesn't move.
  Future<CashFlowSummary> cashFlowSummary({DateTime? from, DateTime? to}) async {
    final cashIds = await cashLikeAccountIds();
    if (cashIds.isEmpty) return CashFlowSummary.empty;

    final placeholders = cashIds.map((_) => '?').join(', ');

    Future<double> openingBalance() async {
      if (from == null) return 0;
      final r = await _db.rawQuery(
        'SELECT COALESCE(SUM(debit),0) - COALESCE(SUM(credit),0) AS bal '
        'FROM journal_entries '
        'WHERE is_deleted = 0 AND account_id IN ($placeholders) '
        'AND created_at < ?',
        [...cashIds, from.toUtc().toIso8601String()],
      );
      return ((r.first['bal'] as num?) ?? 0).toDouble();
    }

    // Pull every cash-leg row in the period and read its sibling on the same
    // transaction_id to discover what the cash exchanged for.
    final whereClauses = <String>[
      'is_deleted = 0',
      'account_id IN ($placeholders)',
    ];
    final args = <Object>[...cashIds];
    if (from != null) {
      whereClauses.add('created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      whereClauses.add('created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final cashRows = await _db.rawQuery(
      'SELECT transaction_id, debit, credit FROM journal_entries '
      'WHERE ${whereClauses.join(' AND ')}',
      args,
    );

    // Per-category buckets. Aggregate `opIn / opOut / finOut` are sums of
    // these so the legacy getters still work.
    double projectInflow = 0;
    double serviceFeeInflow = 0;
    double materialOutflow = 0;
    double labourOutflow = 0;
    double supplierPayOutflow = 0;
    double personalDrawOutflow = 0;
    double equityInflow = 0;
    double equityOutflow = 0;
    double other = 0;

    for (final row in cashRows) {
      final txnId = row['transaction_id'] as String;
      final dr = (row['debit'] as num).toDouble();
      final cr = (row['credit'] as num).toDouble();
      final delta = dr - cr; // + = cash in, − = cash out

      // Find the sibling (the non-cash leg of this transaction).
      final sibling = await _db.rawQuery(
        'SELECT account_id FROM journal_entries '
        'WHERE transaction_id = ? AND account_id NOT IN ($placeholders) '
        'AND is_deleted = 0 LIMIT 1',
        [txnId, ...cashIds],
      );
      if (sibling.isEmpty) {
        // Wallet transfer — both legs are cash-like, so consolidated cash
        // is unchanged. Skip entirely; surfacing them on the cash flow
        // statement was just noise.
        continue;
      }
      final otherAccount = sibling.first['account_id'] as String;

      switch (otherAccount) {
        case 'PROJECT_REV':
          projectInflow += delta;
        case 'SERVICE_FEE':
          serviceFeeInflow += delta;
        case 'MATERIAL_COSTS':
          materialOutflow += -delta;
        case 'LABOUR_COSTS':
          labourOutflow += -delta;
        case 'SUPPLIER_PAY':
          supplierPayOutflow += -delta;
        case 'PERSONAL_DRAW':
          personalDrawOutflow += -delta;
        case 'OWNERS_EQUITY':
          // Opening balance for a bank: counts as equity inflow if cash
          // came in, or equity outflow if money was drawn against equity.
          if (delta >= 0) {
            equityInflow += delta;
          } else {
            equityOutflow += -delta;
          }
        default:
          other += delta;
      }
    }

    final opening = await openingBalance();
    return CashFlowSummary(
      openingCash: opening,
      // Aggregate fields kept for backwards-compat with any caller that
      // still reads the high-level totals. Equity inflow rolls into
      // operating inflow as before (it's customer-money arriving via an
      // initial deposit), and equity outflow into financing.
      operatingInflow: projectInflow + serviceFeeInflow + equityInflow,
      operatingOutflow:
          materialOutflow + labourOutflow + supplierPayOutflow,
      financingOutflow: personalDrawOutflow + equityOutflow,
      otherNet: other,
      projectInflow: projectInflow,
      serviceFeeInflow: serviceFeeInflow,
      materialOutflow: materialOutflow,
      labourOutflow: labourOutflow,
      supplierPayOutflow: supplierPayOutflow,
      personalDrawOutflow: personalDrawOutflow,
      equityInflow: equityInflow,
      equityOutflow: equityOutflow,
    );
  }

  /// Single source of truth for revenue / cost figures used by both the
  /// Income Statement and the dashboard's Net Profit. Implements
  /// **Percentage-of-Completion (cost-recovery variant)** so a project
  /// payment received before the matching costs are incurred does **not**
  /// inflate profit — it sits as a customer-deposit liability instead.
  ///
  /// Recognition rules:
  ///   * **With-Material, in-progress** (not archived):
  ///       revenue_recognized = min(received, costs_to_date)
  ///       deposit_owed       = max(received - costs_to_date, 0)
  ///     i.e. cost-recovery — zero gross profit recognized until the project
  ///     is closed. This is conservative and avoids "fake profit" from
  ///     advance payments.
  ///   * **With-Material, closed** (archived): the contract is delivered,
  ///     so revenue = min(received, budget); any received over budget is a
  ///     deposit owed back to the customer.
  ///   * **Loss provision** (GAAP/IFRS rule): if costs exceed budget on any
  ///     project (active or closed), the excess is recognized **immediately**
  ///     as a separate cost line. Future losses must be booked the moment
  ///     they become probable, not deferred.
  ///   * **Labour-Rate**: unchanged — service fees are the only earned
  ///     income; everything else received sits as a deposit.
  ///
  /// Returns [IncomeFigures] including a list of projects flagged as
  /// at-risk (costs ≥ 80% of budget) so the UI can render loss warnings.
  Future<IncomeFigures> incomeFigures({
    DateTime? from,
    DateTime? to,
    String? projectId,
    DateTime? closeAsOf,
  }) async {
    // ── Load projects in scope ────────────────────────────────────────────
    final projWhere = projectId != null ? 'WHERE id = ?' : '';
    final projArgs = projectId != null ? <Object>[projectId] : <Object>[];
    final projRows = await _db.rawQuery(
      'SELECT id, name, model, budget, is_archived, archived_at '
      'FROM projects $projWhere',
      projArgs,
    );

    double wmRevenue = 0;
    double wmDeposit = 0;
    double matCosts = 0;
    double labCosts = 0;
    double lossProvision = 0;
    double lrDeposit = 0;
    final atRisk = <ProjectAtRisk>[];

    for (final r in projRows) {
      final pid = r['id'] as String;
      final pname = (r['name'] as String?) ?? '';
      final pmodel = (r['model'] as String?) ?? '';
      final budget = (r['budget'] as num?)?.toDouble() ?? 0;
      // Time-aware close check: when `closeAsOf` is supplied (used by
      // Monthly P&L Trend cumulative snapshots), treat the project as
      // closed only if it was archived on or before that moment. Without
      // it, fall back to the live `is_archived` flag — which is what
      // every other caller wants.
      final archivedAt = (r['archived_at'] as String?) != null
          ? DateTime.parse(r['archived_at'] as String)
          : null;
      final closed = closeAsOf != null
          ? (archivedAt != null && !archivedAt.isAfter(closeAsOf))
          : ((r['is_archived'] as int?) ?? 0) == 1;

      final received = await creditBalance(Accounts.projectRevenue.id,
          projectId: pid, from: from, to: to);
      final mat = await accountBalance(Accounts.materialCosts.id,
          projectId: pid, from: from, to: to);
      final lab = await accountBalance(Accounts.labourCosts.id,
          projectId: pid, from: from, to: to);
      final costs = mat + lab;

      matCosts += mat;
      labCosts += lab;

      // Match the enum's db getter (which returns `name`) — `withMaterial`,
      // not `with_material`. Earlier the wrong identifier here caused the
      // WM branch to silently never run, surfacing as zero revenue and zero
      // deposit on the dashboard / income statement.
      if (pmodel == ProjectModel.withMaterial.db) {
        if (closed) {
          // Project complete → recognize full contract.
          if (budget > 0 && received > budget) {
            wmRevenue += budget;
            wmDeposit += received - budget;
          } else {
            wmRevenue += received;
          }
        } else {
          // PoC cost-recovery: only recognize revenue matched by costs.
          final recognized = received < costs ? received : costs;
          wmRevenue += recognized;
          if (received > recognized) wmDeposit += received - recognized;
        }
      } else {
        // Labour-Rate — existing logic: residual after service-fee
        // reclassification and customer-funded costs is deposit owed back.
        final net = received - costs;
        if (net > 0) lrDeposit += net;
      }

      // Loss provision — applies to every project model. If we've spent
      // more on this job than the budget allows, the excess is a loss
      // already in the bag, recognized immediately per FASB/IFRS.
      if (budget > 0 && costs > budget) {
        lossProvision += costs - budget;
      }

      // At-risk flag for the dashboard warning panel.
      if (budget > 0 && costs > 0) {
        final pct = costs / budget * 100;
        if (pct >= 80) {
          atRisk.add(ProjectAtRisk(
            projectId: pid,
            projectName: pname,
            budget: budget,
            costsToDate: costs,
            pctConsumed: pct,
            isOverBudget: costs > budget,
          ));
        }
      }
    }

    // Service fees are project-tagged, but the existing code summed them
    // globally when no project filter was active. Match that behaviour.
    final serviceFees = await creditBalance(Accounts.serviceFeeIncome.id,
        projectId: projectId, from: from, to: to);

    final personalDraw = projectId == null
        ? await accountBalance(Accounts.personalDraw.id, from: from, to: to)
        : 0.0;

    // Sort at-risk projects by severity (over-budget first, then by % consumed).
    atRisk.sort((a, b) {
      if (a.isOverBudget != b.isOverBudget) return a.isOverBudget ? -1 : 1;
      return b.pctConsumed.compareTo(a.pctConsumed);
    });

    return IncomeFigures(
      wmRevenue: wmRevenue,
      serviceFees: serviceFees,
      matCosts: matCosts,
      labCosts: labCosts,
      personalDraw: personalDraw,
      lrDeposit: lrDeposit,
      wmDeposit: wmDeposit,
      lossProvision: lossProvision,
      projectsAtRisk: atRisk,
    );
  }

  /// Material costs grouped by `material_type`, suitable as a P&L
  /// breakdown. Sourced from `material_inventory` so each type rolls up
  /// every purchase (counter + credit). Soft- or hard-deleted entries
  /// are excluded automatically (v13 linkage).
  ///
  /// Returns a `(byType, untracked)` tuple — `untracked` is any
  /// material-costs spend in `journal_entries` that has no
  /// corresponding `material_inventory` row (legacy data, or unusual
  /// posting paths) so the breakdown reconciles with the total.
  Future<({Map<String, double> byType, double untracked})>
      materialCostsByType({
    DateTime? from,
    DateTime? to,
    String? projectId,
  }) async {
    final where = StringBuffer(
        'txn_type = ? AND is_deleted = 0');
    final args = <Object>[MaterialTxnType.purchase.db];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT material_type, SUM(total_cost) AS s '
      'FROM material_inventory '
      'WHERE ${where.toString()} '
      'GROUP BY material_type',
      args,
    );
    final byType = <String, double>{};
    for (final r in rows) {
      final label = resolveMaterialLabel(r['material_type'] as String);
      byType[label] =
          (byType[label] ?? 0) + ((r['s'] as num?) ?? 0).toDouble();
    }
    // Reconcile against the journal aggregate so a missing inventory
    // row doesn't make the breakdown silently understate total spend.
    final journalTotal = await accountBalance(
      Accounts.materialCosts.id,
      projectId: projectId,
      from: from,
      to: to,
    );
    final tracked = byType.values.fold<double>(0, (a, b) => a + b);
    final untracked = (journalTotal - tracked).clamp(0, double.infinity);
    return (byType: byType, untracked: untracked.toDouble());
  }

  /// Labour costs grouped by supplier (worker), suitable as a P&L
  /// breakdown. Each entry is `(supplierId, totalDebit)`. Soft-deleted
  /// rows are excluded.
  Future<Map<String, double>> labourCostsBySupplier({
    DateTime? from,
    DateTime? to,
    String? projectId,
  }) async {
    final where = StringBuffer(
        'account_id = ? AND debit > 0 AND is_deleted = 0 '
        'AND supplier_id IS NOT NULL');
    final args = <Object>[Accounts.labourCosts.id];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT supplier_id, SUM(debit) AS s FROM journal_entries '
      'WHERE ${where.toString()} '
      'GROUP BY supplier_id',
      args,
    );
    return {
      for (final r in rows)
        (r['supplier_id'] as String): ((r['s'] as num?) ?? 0).toDouble(),
    };
  }

  /// Sum(debit) - sum(credit). Always excludes soft-deleted rows. Optional
  /// [from]/[to] window applies inclusively to `created_at`.
  Future<double> accountBalance(String accountId,
      {String? projectId, DateTime? from, DateTime? to}) async {
    final where = StringBuffer('account_id = ? AND is_deleted = 0');
    final args = <Object>[accountId];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(debit),0) - COALESCE(SUM(credit),0) AS bal '
      'FROM journal_entries WHERE ${where.toString()}',
      args,
    );
    return ((rows.first['bal'] as num?) ?? 0).toDouble();
  }

  Future<double> creditBalance(String accountId,
      {String? projectId, DateTime? from, DateTime? to}) async {
    final bal = await accountBalance(accountId,
        projectId: projectId, from: from, to: to);
    return -bal;
  }

  /// Sum of debits to a specific account, optionally filtered by project
  /// and/or date window.
  Future<double> sumDebits(String accountId,
      {String? projectId, DateTime? from, DateTime? to}) async {
    final where = StringBuffer('account_id = ? AND is_deleted = 0');
    final args = <Object>[accountId];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(debit),0) AS s FROM journal_entries WHERE ${where.toString()}',
      args,
    );
    return ((rows.first['s'] as num?) ?? 0).toDouble();
  }

  Future<double> sumCredits(String accountId,
      {String? projectId, DateTime? from, DateTime? to}) async {
    final where = StringBuffer('account_id = ? AND is_deleted = 0');
    final args = <Object>[accountId];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(credit),0) AS s FROM journal_entries WHERE ${where.toString()}',
      args,
    );
    return ((rows.first['s'] as num?) ?? 0).toDouble();
  }

  /// Project reconciliation snapshot.
  ///
  /// New rule (post-customer-removal): a With-Material project is "reconciled"
  /// when supplier payables for that project are zero. Money received from the
  /// project is booked directly as revenue, so the cash-vs-cost balance is
  /// `revenue - costs = savings` (positive = profit).
  Future<ProjectReconciliation> reconcileProject(String projectId) async {
    final projectInflow =
        await sumCredits(Accounts.projectRevenue.id, projectId: projectId);

    final supplierPaid =
        await sumDebits(Accounts.supplierPayables.id, projectId: projectId);

    final credits = await sumCredits(Accounts.supplierPayables.id,
        projectId: projectId);
    final supplierPayables = credits - supplierPaid;

    return ProjectReconciliation(
      projectInflow: projectInflow,
      supplierPaid: supplierPaid,
      supplierPayables: supplierPayables,
    );
  }

  /// Same numbers `archiveProject`'s gate checks, exposed publicly so the
  /// reconciliation screen can render the "what's still wrong" message
  /// without duplicating the SQL.
  Future<({double supplierPayables, double ledgerNet, double serviceFeeBooked})>
      projectArchiveStatus(String projectId) async {
    Future<double> sum(String column, String accountId) async {
      final rows = await _db.rawQuery(
        'SELECT COALESCE(SUM($column),0) AS s FROM journal_entries '
        'WHERE account_id = ? AND project_id = ? AND is_deleted = 0',
        [accountId, projectId],
      );
      return ((rows.first['s'] as num?) ?? 0).toDouble();
    }

    final supplierPaid = await sum('debit', Accounts.supplierPayables.id);
    final supplierCredits = await sum('credit', Accounts.supplierPayables.id);
    final supplierPayables = supplierCredits - supplierPaid;

    final materialDr = await sum('debit', Accounts.materialCosts.id);
    final labourDr = await sum('debit', Accounts.labourCosts.id);
    final revenueCr = await sum('credit', Accounts.projectRevenue.id);
    final feeCr = await sum('credit', Accounts.serviceFeeIncome.id);
    final ledgerNet = (materialDr + labourDr) - (revenueCr + feeCr);

    return (
      supplierPayables: supplierPayables,
      ledgerNet: ledgerNet,
      // The screen uses serviceFeeBooked to know whether the
      // labour-rate fee reclassification has already been posted.
      serviceFeeBooked: feeCr,
    );
  }

  /// Total project outflow = material costs + labour costs for project.
  Future<double> projectOutflow(String projectId) async {
    final mat =
        await sumDebits(Accounts.materialCosts.id, projectId: projectId);
    final lab = await sumDebits(Accounts.labourCosts.id, projectId: projectId);
    return mat + lab;
  }

  /// Per-supplier spend roll-up for a project. Sums material- and
  /// labour-cost debits tagged with the given project + supplier, optionally
  /// scoped to a date window. The result is sorted highest-spend first so
  /// the trial-balance breakdown card can render it directly.
  ///
  /// Returns rows of `(supplierId, total)`. Counter-purchase material
  /// (no supplier) is bucketed under an empty-string supplierId — the
  /// caller can resolve that to a display label.
  Future<List<({String supplierId, double total})>>
      projectSupplierBreakdown(
    String projectId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final where = StringBuffer(
        'project_id = ? AND account_id IN (?, ?) AND is_deleted = 0');
    final args = <Object>[
      projectId,
      Accounts.materialCosts.id,
      Accounts.labourCosts.id,
    ];
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      // Inclusive upper bound — bump to next-day midnight to match the
      // boundary handling everywhere else in this repo.
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT COALESCE(supplier_id, \'\') AS sid, '
      'COALESCE(SUM(debit), 0) AS total '
      'FROM journal_entries '
      'WHERE ${where.toString()} '
      'GROUP BY supplier_id '
      'ORDER BY total DESC',
      args,
    );
    return rows
        .map((r) => (
              supplierId: r['sid'] as String,
              total: ((r['total'] as num?) ?? 0).toDouble(),
            ))
        .where((r) => r.total > 0)
        .toList();
  }

  /// Per-material-type spend roll-up for a project. Reads
  /// `material_inventory` rather than `journal_entries` because the
  /// material type is denormalised there (the ledger only carries the
  /// rupee amount). Soft-deleted rows are excluded via the v13 linkage.
  Future<List<({String materialType, double total})>>
      projectMaterialBreakdown(
    String projectId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final where = StringBuffer('project_id = ? AND is_deleted = 0');
    final args = <Object>[projectId];
    if (from != null) {
      where.write(' AND created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      // Inclusive upper bound — matches accountBalance / sumDebits /
      // sumCredits boundary handling so the date-windowed breakdown
      // agrees with the trial-balance header above it.
      where.write(' AND created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }
    final rows = await _db.rawQuery(
      'SELECT material_type AS mat, '
      'COALESCE(SUM(total_cost), 0) AS total '
      'FROM material_inventory '
      'WHERE ${where.toString()} '
      'GROUP BY material_type '
      'ORDER BY total DESC',
      args,
    );
    return rows
        .map((r) => (
              materialType: (r['mat'] as String?) ?? 'Other',
              total: ((r['total'] as num?) ?? 0).toDouble(),
            ))
        .where((r) => r.total > 0)
        .toList();
  }

  /// Material Trial Balance: project-wise quantity + amount spent on each
  /// material type (or with each supplier), sourced from `material_inventory`
  /// so quantities are available (the journal has none). Pass [projectId] to
  /// scope to one project, or null for every project. Rows are ordered by
  /// project name, then amount descending.
  Future<List<MaterialTrialRow>> materialTrialBalance({
    String? projectId,
    MaterialTrialGroupBy groupBy = MaterialTrialGroupBy.material,
    DateTime? from,
    DateTime? to,
  }) async {
    final where = StringBuffer('mi.is_deleted = 0');
    final args = <Object>[];
    if (projectId != null) {
      where.write(' AND mi.project_id = ?');
      args.add(projectId);
    }
    if (from != null) {
      where.write(' AND mi.created_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.write(' AND mi.created_at < ?');
      args.add(to.add(const Duration(days: 1)).toUtc().toIso8601String());
    }

    late final String sql;
    if (groupBy == MaterialTrialGroupBy.material) {
      // Group by material type. `unit` collapses to 'mixed' when a type was
      // bought in more than one unit so the column stays meaningful.
      sql = 'SELECT mi.project_id AS pid, '
          "COALESCE(p.name, '(unknown project)') AS pname, "
          "COALESCE(mi.material_type, 'Other') AS label, "
          "CASE WHEN COUNT(DISTINCT mi.unit) > 1 THEN 'mixed' "
          "     ELSE COALESCE(MAX(mi.unit), '') END AS unit, "
          'COALESCE(SUM(mi.quantity), 0) AS qty, '
          'COALESCE(SUM(mi.total_cost), 0) AS amt '
          'FROM material_inventory mi '
          'LEFT JOIN projects p ON p.id = mi.project_id '
          'WHERE ${where.toString()} '
          'GROUP BY mi.project_id, mi.material_type '
          'ORDER BY pname ASC, amt DESC';
    } else {
      sql = 'SELECT mi.project_id AS pid, '
          "COALESCE(p.name, '(unknown project)') AS pname, "
          "COALESCE(s.name, 'Counter purchase (no supplier)') AS label, "
          "'' AS unit, "
          'COALESCE(SUM(mi.quantity), 0) AS qty, '
          'COALESCE(SUM(mi.total_cost), 0) AS amt '
          'FROM material_inventory mi '
          'LEFT JOIN projects p ON p.id = mi.project_id '
          'LEFT JOIN suppliers s ON s.id = mi.supplier_id '
          'WHERE ${where.toString()} '
          'GROUP BY mi.project_id, mi.supplier_id '
          'ORDER BY pname ASC, amt DESC';
    }

    final rows = await _db.rawQuery(sql, args);
    return rows
        .map((r) => MaterialTrialRow(
              projectId: (r['pid'] as String?) ?? '',
              projectName: (r['pname'] as String?) ?? '(unknown project)',
              label: (r['label'] as String?) ?? 'Other',
              unit: (r['unit'] as String?) ?? '',
              quantity: ((r['qty'] as num?) ?? 0).toDouble(),
              amount: ((r['amt'] as num?) ?? 0).toDouble(),
            ))
        .where((r) => r.amount != 0 || r.quantity != 0)
        .toList();
  }

  /// One-screen aggregate for the Site Snapshot + Closure Assistant.
  ///
  /// Everything here is derived from existing ledger queries — this method
  /// just bundles them so the UI doesn't have to fire half a dozen async
  /// calls in sequence. Nothing here writes; safe to call from any read
  /// surface.
  ///
  /// `expectedRemainingCost` and `expectedRemainingReceivable` come from
  /// the project row itself (caller-provided budget + received deltas);
  /// the snapshot adds them in so the projected close P&L is meaningful
  /// for projects that aren't done yet.
  Future<ProjectSnapshot> projectSnapshot(String projectId) async {
    final received =
        await sumCredits(Accounts.projectRevenue.id, projectId: projectId);
    final matCosts =
        await sumDebits(Accounts.materialCosts.id, projectId: projectId);
    final labCosts =
        await sumDebits(Accounts.labourCosts.id, projectId: projectId);
    final spent = matCosts + labCosts;

    final supplierPaid =
        await sumDebits(Accounts.supplierPayables.id, projectId: projectId);
    final supplierCredits =
        await sumCredits(Accounts.supplierPayables.id, projectId: projectId);
    final supplierPayables = supplierCredits - supplierPaid;

    final feeCr =
        await sumCredits(Accounts.serviceFeeIncome.id, projectId: projectId);

    // Pull the project's budget for the over/under math.
    final projRows = await _db.rawQuery(
      'SELECT budget, model, completion_percent FROM projects WHERE id = ? LIMIT 1',
      [projectId],
    );
    final budget = projRows.isEmpty
        ? 0.0
        : ((projRows.first['budget'] as num?)?.toDouble() ?? 0.0);
    final model = projRows.isEmpty
        ? null
        : projRows.first['model'] as String?;
    final completionPercent = projRows.isEmpty
        ? 0
        : ((projRows.first['completion_percent'] as num?)?.toInt() ?? 0);

    // Customer deposit = money received that hasn't been earned yet under
    // PoC. For With-Material that's `max(received − spent, 0)`; for LR
    // it's the residual after costs.
    final customerDeposit = (received - spent).clamp(0.0, double.infinity);

    // Forecast remaining cost using the completion% slider — when the
    // owner says we're 60% done with Rs 600k spent, projected cost to
    // complete is Rs 1m. Falls back to budget vs spent when completion is
    // 0 (no estimate yet).
    double projectedRemainingCost;
    if (completionPercent >= 100) {
      projectedRemainingCost = 0;
    } else if (completionPercent > 0 && spent > 0) {
      final projectedTotal = spent * 100 / completionPercent;
      projectedRemainingCost = (projectedTotal - spent).clamp(0.0, double.infinity);
    } else {
      // No completion% supplied → budget headroom is the best we have.
      projectedRemainingCost = (budget - spent).clamp(0.0, double.infinity);
    }

    final projectedReceivable = (budget - received).clamp(0.0, double.infinity);
    final projectedCashGap =
        (projectedRemainingCost - projectedReceivable).clamp(
      -double.infinity,
      double.infinity,
    );

    // Realized profit so far — for closed projects this is the actual
    // bottom line; for active projects it's a snapshot showing how much
    // recognized revenue exceeds spend (cost-recovery PoC means this is
    // typically 0 mid-project for WM, and ~serviceFee for LR).
    final realizedProfit = (received - spent) - customerDeposit;

    // Final-profit forecast = budget − projected total cost − any
    // already-recognized service fee bundled into received. For WM the
    // expression simplifies to `budget − (spent + projectedRemainingCost)`,
    // showing whether the contract is heading for a loss.
    final projectedFinalCost = spent + projectedRemainingCost;
    final projectedFinalProfit =
        budget > 0 ? budget - projectedFinalCost : received - projectedFinalCost;

    return ProjectSnapshot(
      projectId: projectId,
      model: model,
      budget: budget,
      received: received,
      spent: spent,
      materialCosts: matCosts,
      labourCosts: labCosts,
      serviceFeeBooked: feeCr,
      supplierPayables: supplierPayables,
      customerDeposit: customerDeposit,
      realizedProfit: realizedProfit,
      completionPercent: completionPercent,
      projectedRemainingCost: projectedRemainingCost,
      projectedReceivable: projectedReceivable,
      projectedCashGap: projectedCashGap,
      projectedFinalProfit: projectedFinalProfit,
    );
  }

  /// Closing snapshot for a Labour-Rate project.
  ///
  /// In the labour-rate model the contractor is a pass-through:
  ///   * `customerPaid`  — total `Project Revenue` credits (cash from
  ///     customer over the life of the project).
  ///   * `totalSpent`    — total Material + Labour cost debits (what we
  ///     spent on the customer's behalf).
  ///   * `serviceFee`    — `totalSpent × feePercent / 100`, the contractor's
  ///     earnings on this job.
  ///   * `netToSettle`   — `(customerPaid − serviceFee) − totalSpent`.
  ///       positive → refund customer the surplus
  ///       negative → customer owes us the deficit (already includes fee)
  /// The service fee is either a percentage of spend or a flat amount,
  /// decided by [feeType] — see [Project.serviceFeeOn], which this mirrors.
  Future<LabourRateClose> labourRateCloseSummary(
    String projectId, {
    ServiceFeeType feeType = ServiceFeeType.percent,
    double feePercent = 0,
    double feeAmount = 0,
  }) async {
    final customerPaid =
        await sumCredits(Accounts.projectRevenue.id, projectId: projectId);
    final totalSpent = await projectOutflow(projectId);
    final serviceFee = feeType == ServiceFeeType.fixed
        ? feeAmount
        : totalSpent * feePercent / 100;
    final customerFundsAvail = customerPaid - serviceFee;
    final netToSettle = customerFundsAvail - totalSpent;
    return LabourRateClose(
      customerPaid: customerPaid,
      totalSpent: totalSpent,
      feeType: feeType,
      feePercent: feePercent,
      serviceFee: serviceFee,
      netToSettle: netToSettle,
    );
  }

  /// Posts the labour-rate service fee at project close as a non-cash
  /// reclassification: Dr Project Revenue / Cr Service Fee Income, both
  /// tagged with `projectId`. Cash position is unaffected — the fee just
  /// re-buckets a slice of recognized customer revenue into the
  /// contractor's own income line so the Income Statement separates
  /// "money handled for the customer" from "earnings".
  Future<String> postProjectServiceFee({
    required String projectId,
    required double amount,
    String? description,
  }) {
    _assertNonEmpty(projectId, 'projectId');
    return _post(
      debitAccount: Accounts.projectRevenue,
      creditAccount: Accounts.serviceFeeIncome,
      amount: amount,
      projectId: projectId,
      description: description ?? 'Service fee on project close',
    );
  }

  // -------------------- Aging Analysis --------------------

  /// Aging buckets across 0-30 / 31-60 / 61-90 / 90+ days for the Supplier
  /// Payables account — outstanding amounts we owe each supplier, FIFO-matched
  /// against payments so the bucket reflects the oldest unmatched bill's age.
  ///
  /// Since the Customer entity was removed there is no receivables-by-customer
  /// aging; project receivables (under-funded projects) live in their own
  /// FIFO aggregator at [agingProjectReceivables].
  Future<AgingReport> aging({
    required String partyAccountId,
    DateTime? asOf,
  }) async {
    final now = (asOf ?? DateTime.now()).toUtc();
    final rows = await _db.query(
      'journal_entries',
      where: 'account_id = ? AND is_deleted = 0',
      whereArgs: [partyAccountId],
      orderBy: 'created_at ASC',
    );
    // Payables: credits = bill incurred, debits = payment made.
    final byParty = <String, List<JournalEntry>>{};
    for (final row in rows) {
      final je = JournalEntry.fromMap(row);
      final partyId = je.supplierId;
      if (partyId == null) continue;
      byParty.putIfAbsent(partyId, () => []).add(je);
    }

    final lines = <AgingLine>[];
    byParty.forEach((partyId, entries) {
      // FIFO open-balance queue: each invoice contributes to the queue, each
      // payment consumes from the head.
      final open = <_OpenInvoice>[];
      for (final e in entries) {
        final amt = e.credit - e.debit;
        if (amt > 0) {
          open.add(_OpenInvoice(date: e.createdAt, remaining: amt));
        } else if (amt < 0) {
          var pay = -amt;
          while (pay > 0 && open.isNotEmpty) {
            final head = open.first;
            if (head.remaining <= pay) {
              pay -= head.remaining;
              open.removeAt(0);
            } else {
              head.remaining -= pay;
              pay = 0;
            }
          }
        }
      }
      var b0 = 0.0, b30 = 0.0, b60 = 0.0, b90 = 0.0;
      for (final inv in open) {
        final days = now.difference(inv.date).inDays;
        if (days <= 30) {
          b0 += inv.remaining;
        } else if (days <= 60) {
          b30 += inv.remaining;
        } else if (days <= 90) {
          b60 += inv.remaining;
        } else {
          b90 += inv.remaining;
        }
      }
      final total = b0 + b30 + b60 + b90;
      if (total > 0.005) {
        lines.add(AgingLine(
          partyId: partyId,
          bucket0_30: b0,
          bucket31_60: b30,
          bucket61_90: b60,
          bucket90Plus: b90,
        ));
      }
    });
    lines.sort((a, b) => b.total.compareTo(a.total));
    return AgingReport(asOf: now, lines: lines);
  }

  /// Aging — projects that have not paid us yet. For each project we walk
  /// the journal in chronological order:
  ///   * Material/Labour Costs debits (project_id) = "we spent on the
  ///     customer's behalf" → contributes to the open balance owed.
  ///   * Project Revenue credits (project_id) = "customer paid" → consumes
  ///     the open balance FIFO.
  /// Whatever is left after the FIFO match is bucketed by age. Mirrors
  /// `aging()` so the screen can render with the same widgets.
  Future<AgingReport> agingProjectReceivables({DateTime? asOf}) async {
    final now = (asOf ?? DateTime.now()).toUtc();
    // Pull every cost & revenue row tagged with a project, in time order.
    final rows = await _db.rawQuery(
      'SELECT project_id, account_id, debit, credit, created_at '
      'FROM journal_entries '
      'WHERE is_deleted = 0 AND project_id IS NOT NULL '
      'AND account_id IN (?, ?, ?) '
      'ORDER BY created_at ASC',
      [
        Accounts.materialCosts.id,
        Accounts.labourCosts.id,
        Accounts.projectRevenue.id,
      ],
    );

    final byProject = <String, List<_OpenInvoice>>{};
    // Customer prepayment per project. When revenue arrives before any
    // cost is incurred (advance payment), the excess used to be silently
    // dropped — then a later cost would be treated as "we are owed", even
    // though the customer's prepayment had already covered it. We now
    // bank the surplus here and consume it from later costs before they
    // hit the queue.
    final prepaid = <String, double>{};
    for (final r in rows) {
      final projectId = r['project_id'] as String;
      final accountId = r['account_id'] as String;
      final debit = (r['debit'] as num).toDouble();
      final credit = (r['credit'] as num).toDouble();
      final created = DateTime.parse(r['created_at'] as String);

      final queue = byProject.putIfAbsent(projectId, () => []);
      if (accountId == Accounts.materialCosts.id ||
          accountId == Accounts.labourCosts.id) {
        if (debit > 0) {
          var remaining = debit;
          // First, absorb any unmatched customer prepayment for this
          // project — that money already covered work like this.
          final bank = prepaid[projectId] ?? 0;
          if (bank > 0) {
            final used = remaining <= bank ? remaining : bank;
            remaining -= used;
            prepaid[projectId] = bank - used;
          }
          // Whatever's left is genuinely unfunded work → customer owes
          // us this much.
          if (remaining > 0) {
            queue.add(_OpenInvoice(date: created, remaining: remaining));
          }
        }
      } else if (accountId == Accounts.projectRevenue.id) {
        // Customer paid → consume open balance FIFO.
        var pay = credit;
        while (pay > 0 && queue.isNotEmpty) {
          final head = queue.first;
          if (head.remaining <= pay) {
            pay -= head.remaining;
            queue.removeAt(0);
          } else {
            head.remaining -= pay;
            pay = 0;
          }
        }
        // Anything left over is a customer prepayment — banked so the
        // next cost incurred consumes it before it gets queued as
        // "owed".
        if (pay > 0) {
          prepaid[projectId] = (prepaid[projectId] ?? 0) + pay;
        }
      }
    }

    final lines = <AgingLine>[];
    byProject.forEach((projectId, queue) {
      var b0 = 0.0, b30 = 0.0, b60 = 0.0, b90 = 0.0;
      for (final inv in queue) {
        final days = now.difference(inv.date).inDays;
        if (days <= 30) {
          b0 += inv.remaining;
        } else if (days <= 60) {
          b30 += inv.remaining;
        } else if (days <= 90) {
          b60 += inv.remaining;
        } else {
          b90 += inv.remaining;
        }
      }
      final total = b0 + b30 + b60 + b90;
      if (total > 0.005) {
        lines.add(AgingLine(
          partyId: projectId,
          bucket0_30: b0,
          bucket31_60: b30,
          bucket61_90: b60,
          bucket90Plus: b90,
        ));
      }
    });
    lines.sort((a, b) => b.total.compareTo(a.total));
    return AgingReport(asOf: now, lines: lines);
  }

  /// Aging — suppliers we have OVERPAID (negative payable). For each
  /// supplier:
  ///   * Supplier Payables debits = payments to the supplier (advance) →
  ///     contributes to "they owe us".
  ///   * Supplier Payables credits = bills incurred → consume the advance
  ///     FIFO.
  /// What's left is the unmatched advance, bucketed by age. The standard
  /// payables aging already covers the opposite direction.
  Future<AgingReport> agingSupplierOverpayment({DateTime? asOf}) async {
    final now = (asOf ?? DateTime.now()).toUtc();
    final rows = await _db.query(
      'journal_entries',
      where: 'account_id = ? AND is_deleted = 0',
      whereArgs: [Accounts.supplierPayables.id],
      orderBy: 'created_at ASC',
    );

    final bySupplier = <String, List<_OpenInvoice>>{};
    // Unmatched bills per supplier — when a credit (supplier billed us)
    // arrives before any debit (we paid them), the credit used to be
    // silently dropped, and a later payment would then show up as a
    // false overpayment. We now bank the unmatched bill here so a later
    // payment consumes it before being queued as "they hold our money".
    final unmatchedBill = <String, double>{};
    for (final row in rows) {
      final je = JournalEntry.fromMap(row);
      final supplierId = je.supplierId;
      if (supplierId == null) continue;
      final queue = bySupplier.putIfAbsent(supplierId, () => []);
      if (je.debit > 0) {
        var remaining = je.debit;
        // First, settle any unmatched bill that arrived earlier — this
        // payment is what cancels it out.
        final bill = unmatchedBill[supplierId] ?? 0;
        if (bill > 0) {
          final used = remaining <= bill ? remaining : bill;
          remaining -= used;
          unmatchedBill[supplierId] = bill - used;
        }
        // Anything left really is money the supplier holds.
        if (remaining > 0) {
          queue.add(_OpenInvoice(date: je.createdAt, remaining: remaining));
        }
      } else if (je.credit > 0) {
        var pay = je.credit;
        while (pay > 0 && queue.isNotEmpty) {
          final head = queue.first;
          if (head.remaining <= pay) {
            pay -= head.remaining;
            queue.removeAt(0);
          } else {
            head.remaining -= pay;
            pay = 0;
          }
        }
        // Bill exceeds prior payments → bank as unmatched so the next
        // payment cancels it instead of being mis-counted as overpayment.
        if (pay > 0) {
          unmatchedBill[supplierId] = (unmatchedBill[supplierId] ?? 0) + pay;
        }
      }
    }

    final lines = <AgingLine>[];
    bySupplier.forEach((supplierId, queue) {
      var b0 = 0.0, b30 = 0.0, b60 = 0.0, b90 = 0.0;
      for (final inv in queue) {
        final days = now.difference(inv.date).inDays;
        if (days <= 30) {
          b0 += inv.remaining;
        } else if (days <= 60) {
          b30 += inv.remaining;
        } else if (days <= 90) {
          b60 += inv.remaining;
        } else {
          b90 += inv.remaining;
        }
      }
      final total = b0 + b30 + b60 + b90;
      if (total > 0.005) {
        lines.add(AgingLine(
          partyId: supplierId,
          bucket0_30: b0,
          bucket31_60: b30,
          bucket61_90: b60,
          bucket90Plus: b90,
        ));
      }
    });
    lines.sort((a, b) => b.total.compareTo(a.total));
    return AgingReport(asOf: now, lines: lines);
  }

  /// Sum of grand totals across project-side and supplier-side
  /// receivables — exposed for the dashboard tile so it doesn't have to
  /// re-run the FIFO calc just to show one number.
  Future<({double projectsOwed, double suppliersOverpaid})>
      receivablesTotals() async {
    final p = await agingProjectReceivables();
    final s = await agingSupplierOverpayment();
    return (
      projectsOwed: p.grandTotal,
      suppliersOverpaid: s.grandTotal,
    );
  }

  // -------------------- Cash Flow --------------------

  /// Monthly delta-cash per cash-like account, oldest -> newest, capped at
  /// `monthsBack`. Each row is [month, perAccountDelta]. The account id list
  /// is built dynamically from system cash + the user-defined `banks` table.
  Future<List<MonthlyCashFlow>> monthlyCashFlow({int monthsBack = 12}) async {
    final now = DateTime.now().toUtc();
    final start =
        DateTime.utc(now.year, now.month - (monthsBack - 1), 1);
    final ids = await cashLikeAccountIds();
    if (ids.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.rawQuery(
      'SELECT account_id, debit, credit, created_at '
      'FROM journal_entries '
      'WHERE is_deleted = 0 '
      "AND account_id IN ($placeholders) "
      'AND created_at >= ?',
      [...ids, start.toIso8601String()],
    );

    final byMonth = <String, Map<String, double>>{};
    for (final r in rows) {
      final ts = DateTime.parse(r['created_at'] as String).toUtc();
      final key =
          '${ts.year}-${ts.month.toString().padLeft(2, '0')}';
      final acc = r['account_id'] as String;
      final delta =
          ((r['debit'] as num).toDouble()) - ((r['credit'] as num).toDouble());
      byMonth
          .putIfAbsent(key, () => {})
          .update(acc, (v) => v + delta, ifAbsent: () => delta);
    }
    final out = <MonthlyCashFlow>[];
    for (var i = 0; i < monthsBack; i++) {
      final m = DateTime.utc(start.year, start.month + i, 1);
      final key = '${m.year}-${m.month.toString().padLeft(2, '0')}';
      out.add(MonthlyCashFlow(month: m, perAccount: byMonth[key] ?? const {}));
    }
    return out;
  }

  /// Per-month recognized P&L for the last [monthsBack] months, oldest →
  /// newest. Recognition basis matches the Income Statement (cost-recovery
  /// PoC for With-Material, service fees for Labour-Rate).
  ///
  /// Implementation note: each month's bucket is the **delta** of two
  /// cumulative [incomeFigures] snapshots taken at the month-end
  /// boundaries. A naive per-month window doesn't work for PoC: the
  /// in-progress `min(received, costs)` rule only converges when applied
  /// to lifetime cumulative totals, so window-only buckets would
  /// systematically under-recognize revenue mid-project (most months show
  /// only costs, then a one-time revenue spike at close). The cumulative
  /// snapshot also passes `closeAsOf = monthEnd` so projects archived
  /// later don't retroactively rewrite earlier months as "closed".
  Future<List<MonthlyIncome>> monthlyIncome({int monthsBack = 12}) async {
    final now = DateTime.now().toUtc();
    final monthStarts = <DateTime>[];
    final snapshots = <IncomeFigures>[];
    for (var i = monthsBack - 1; i >= 0; i--) {
      final mStart = DateTime.utc(now.year, now.month - i, 1);
      // Last calendar day of the month — accountBalance treats `to` as an
      // inclusive day boundary, so this captures the whole month.
      final mEnd = DateTime.utc(mStart.year, mStart.month + 1, 1)
          .subtract(const Duration(days: 1));
      monthStarts.add(mStart);
      snapshots.add(await incomeFigures(to: mEnd, closeAsOf: mEnd));
    }
    final out = <MonthlyIncome>[];
    double prevIncome = 0, prevMat = 0, prevLab = 0, prevDraw = 0;
    // Baseline: cumulative-as-of-day-before-the-window-start. Without it
    // the oldest month would absorb every recognition event from the
    // project's whole prior history, making it spike artificially.
    if (monthStarts.isNotEmpty) {
      final baselineEnd =
          monthStarts.first.subtract(const Duration(days: 1));
      final baseline =
          await incomeFigures(to: baselineEnd, closeAsOf: baselineEnd);
      prevIncome = baseline.totalIncome;
      prevMat = baseline.matCosts;
      prevLab = baseline.labCosts;
      prevDraw = baseline.personalDraw;
    }
    for (var i = 0; i < snapshots.length; i++) {
      final f = snapshots[i];
      out.add(MonthlyIncome(
        month: monthStarts[i],
        income: f.totalIncome - prevIncome,
        materialCosts: f.matCosts - prevMat,
        labourCosts: f.labCosts - prevLab,
        personalDraw: f.personalDraw - prevDraw,
      ));
      prevIncome = f.totalIncome;
      prevMat = f.matCosts;
      prevLab = f.labCosts;
      prevDraw = f.personalDraw;
    }
    return out;
  }

  // -------------------- Budget vs Actual --------------------

  /// Per-category actual spend on a project, suitable for comparing against
  /// `Project.budget`. Returns material costs split by [MaterialType] plus a
  /// labour bucket and an "other" bucket for personal draws against project.
  Future<ProjectBva> projectBva(String projectId) async {
    final material =
        await sumDebits(Accounts.materialCosts.id, projectId: projectId);
    final labour =
        await sumDebits(Accounts.labourCosts.id, projectId: projectId);

    // Split material by type via material_inventory totals.
    // `is_deleted = 0` keeps the breakdown in sync with the ledger when
    // a material buy is soft-deleted (v13 linkage).
    final matRows = await _db.rawQuery(
      'SELECT material_type, SUM(total_cost) AS s '
      'FROM material_inventory '
      'WHERE project_id = ? AND txn_type = ? AND is_deleted = 0 '
      'GROUP BY material_type',
      [projectId, MaterialTxnType.purchase.db],
    );
    final byMaterial = <String, double>{};
    for (final r in matRows) {
      final label = resolveMaterialLabel(r['material_type'] as String);
      byMaterial[label] = (byMaterial[label] ?? 0) + (r['s'] as num).toDouble();
    }
    // Reconcile rounding: any material posted via journals that isn't in
    // material_inventory ends up under "other material".
    final invSum = byMaterial.values.fold<double>(0, (a, b) => a + b);
    final otherMaterial = (material - invSum).clamp(0, double.infinity);

    return ProjectBva(
      materialByType: byMaterial,
      otherMaterial: otherMaterial.toDouble(),
      labour: labour,
    );
  }

  // -------------------- Price Trend --------------------

  /// Time-series of unit rates per material label from `material_inventory`,
  /// for the last `monthsBack` months. Each entry is `(date, rate)`.
  Future<Map<String, List<PricePoint>>> priceTrend(
      {int monthsBack = 12}) async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: 30 * monthsBack));
    // `is_deleted = 0` keeps the trend in sync with the ledger after a
    // material buy is soft- or hard-deleted (v13 linkage). `rate IS NOT NULL`
    // drops quantity-less buys (v17): without a quantity there is no real
    // per-unit rate to plot — that purchase is tracked via its memo instead.
    final rows = await _db.rawQuery(
      'SELECT material_type, rate, created_at '
      'FROM material_inventory '
      'WHERE txn_type = ? AND created_at >= ? AND is_deleted = 0 '
      'AND rate IS NOT NULL '
      'ORDER BY created_at ASC',
      [MaterialTxnType.purchase.db, cutoff.toIso8601String()],
    );
    final out = <String, List<PricePoint>>{};
    for (final r in rows) {
      final label = resolveMaterialLabel(r['material_type'] as String);
      out
          .putIfAbsent(label, () => [])
          .add(PricePoint(
            date: DateTime.parse(r['created_at'] as String),
            rate: (r['rate'] as num).toDouble(),
          ));
    }
    return out;
  }

  // -------------------- Material Price Escalation --------------------

  /// Calculates material price escalation and extra inflation surcharge
  /// claimable for [projectId].
  ///
  /// For each material type purchased on this project:
  ///   - Initial Baseline Rate is determined by the rate of the FIRST purchase
  ///     or by [customBaselines] if explicitly provided.
  ///   - For every subsequent purchase, rate increase over baseline is calculated
  ///     and multiplied by quantity to yield the extra escalation amount.
  Future<ProjectEscalationSummary> projectEscalationSummary(
    String projectId, {
    Map<String, double>? customBaselines,
  }) async {
    final projRows = await _db.query('projects',
        columns: ['name', 'client_name', 'whatsapp'],
        where: 'id = ?',
        whereArgs: [projectId],
        limit: 1);
    final projectName =
        projRows.isNotEmpty ? (projRows.first['name'] as String) : 'Project';
    final clientName = projRows.isNotEmpty
        ? (projRows.first['client_name'] as String?)
        : null;
    final clientWhatsApp = projRows.isNotEmpty
        ? (projRows.first['whatsapp'] as String?)
        : null;

    final rows = await _db.rawQuery(
      '''
      SELECT m.id, m.material_type, m.unit, m.quantity, m.rate, m.total_cost,
             m.created_at, m.supplier_id, s.name AS supplier_name
      FROM material_inventory m
      LEFT JOIN suppliers s ON m.supplier_id = s.id
      WHERE m.project_id = ? AND m.txn_type = ? AND m.is_deleted = 0
        AND m.rate IS NOT NULL AND m.quantity IS NOT NULL AND m.quantity > 0
      ORDER BY m.created_at ASC
      ''',
      [projectId, MaterialTxnType.purchase.db],
    );

    final grouped = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final matType = r['material_type'] as String;
      grouped.putIfAbsent(matType, () => []).add(r);
    }

    final items = <MaterialEscalationItem>[];

    for (final entry in grouped.entries) {
      final matType = entry.key;
      final matRows = entry.value;
      if (matRows.isEmpty) continue;

      final unit = matRows.first['unit'] as String? ?? 'unit';
      final firstRate = (matRows.first['rate'] as num).toDouble();
      final baselineRate = customBaselines?[matType] ?? firstRate;

      double latestRate = firstRate;
      double maxRate = firstRate;
      double totalQty = 0.0;
      double totalCost = 0.0;
      final purchases = <MaterialEscalationPurchase>[];

      for (final r in matRows) {
        final id = r['id'] as String;
        final date = DateTime.parse(r['created_at'] as String);
        final rate = (r['rate'] as num).toDouble();
        final qty = (r['quantity'] as num).toDouble();
        final cost = (r['total_cost'] as num).toDouble();
        final suppId = r['supplier_id'] as String?;
        final suppName = r['supplier_name'] as String?;

        latestRate = rate;
        if (rate > maxRate) maxRate = rate;
        totalQty += qty;
        totalCost += cost;

        purchases.add(MaterialEscalationPurchase(
          id: id,
          date: date,
          supplierId: suppId,
          supplierName: suppName,
          quantity: qty,
          rate: rate,
          totalCost: cost,
          baselineRate: baselineRate,
        ));
      }

      items.add(MaterialEscalationItem(
        materialType: matType,
        unit: unit,
        baselineRate: baselineRate,
        latestRate: latestRate,
        maxRate: maxRate,
        totalQuantity: totalQty,
        totalActualCost: totalCost,
        purchases: purchases,
      ));
    }

    return ProjectEscalationSummary(
      projectId: projectId,
      projectName: projectName,
      clientName: clientName,
      clientWhatsApp: clientWhatsApp,
      items: items,
    );
  }

  // -------------------- Cash Runway --------------------

  /// Average daily material + labour spend over the last [daysBack] days.
  /// Returns 0 when there is no spending history (avoids divide-by-zero at
  /// the call site).
  /// Average burn rate over the last [daysBack] days, computed across the
  /// **days that actually had cost activity** rather than all calendar days
  /// in the window. This is the more common professional approach: it
  /// reflects what you spend on a typical spending day, instead of getting
  /// dragged toward zero by inactive days.
  ///
  /// Example: Rs 18,000 spent on a single day in the last 30 →
  /// burn = 18,000 / 1 = Rs 18,000/day (was 600/day under the old
  /// total ÷ 30 formula).
  Future<double> averageDailyExpense({int daysBack = 30}) async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: daysBack))
        .toIso8601String();
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(debit), 0) AS total, '
      'COUNT(DISTINCT DATE(created_at)) AS days '
      'FROM journal_entries '
      'WHERE is_deleted = 0 AND account_id IN (?, ?) AND debit > 0 '
      'AND created_at >= ?',
      [Accounts.materialCosts.id, Accounts.labourCosts.id, cutoff],
    );
    final total = ((rows.first['total'] as num?) ?? 0).toDouble();
    final activeDays = ((rows.first['days'] as num?) ?? 0).toInt();
    if (activeDays == 0) return 0;
    return total / activeDays;
  }

  // -------------------- Supplier-wise Spending --------------------

  /// Total material + labour costs grouped by supplier, sorted highest first.
  /// Optional [daysBack] restricts to the last N days.
  Future<List<SupplierSpend>> supplierSpending({int? daysBack}) async {
    final args = <Object>[Accounts.materialCosts.id, Accounts.labourCosts.id];
    final where = StringBuffer(
      'account_id IN (?, ?) AND is_deleted = 0 AND debit > 0 AND supplier_id IS NOT NULL',
    );
    if (daysBack != null) {
      final cutoff = DateTime.now()
          .toUtc()
          .subtract(Duration(days: daysBack))
          .toIso8601String();
      where.write(' AND created_at >= ?');
      args.add(cutoff);
    }
    final rows = await _db.rawQuery(
      'SELECT supplier_id, SUM(debit) AS total FROM journal_entries '
      'WHERE ${where.toString()} GROUP BY supplier_id ORDER BY total DESC',
      args,
    );
    return rows
        .map((r) => SupplierSpend(
              supplierId: r['supplier_id'] as String,
              total: (r['total'] as num).toDouble(),
            ))
        .toList();
  }

  // -------------------- Daily Spend --------------------

  /// Material + labour costs for a project grouped by calendar day (UTC date),
  /// ordered oldest → newest. Covers the full project lifetime.
  Future<List<DailySpend>> projectDailySpend(String projectId) async {
    final rows = await _db.rawQuery(
      'SELECT DATE(created_at) AS day, SUM(debit) AS total '
      'FROM journal_entries '
      'WHERE is_deleted = 0 AND project_id = ? '
      'AND account_id IN (?, ?) AND debit > 0 '
      'GROUP BY day ORDER BY day ASC',
      [projectId, Accounts.materialCosts.id, Accounts.labourCosts.id],
    );
    return rows
        .map((r) => DailySpend(
              date: DateTime.parse(r['day'] as String),
              amount: (r['total'] as num).toDouble(),
            ))
        .toList();
  }

  /// Material + labour costs across ALL projects grouped by calendar day (UTC),
  /// covering the last [daysBack] days. Used by the dashboard spending strip.
  Future<List<DailySpend>> overallDailySpend({int daysBack = 7}) async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: daysBack))
        .toIso8601String();
    final rows = await _db.rawQuery(
      'SELECT DATE(created_at) AS day, SUM(debit) AS total '
      'FROM journal_entries '
      'WHERE is_deleted = 0 '
      'AND account_id IN (?, ?) AND debit > 0 '
      'AND created_at >= ? '
      'GROUP BY day ORDER BY day ASC',
      [Accounts.materialCosts.id, Accounts.labourCosts.id, cutoff],
    );
    return rows
        .map((r) => DailySpend(
              date: DateTime.parse(r['day'] as String),
              amount: (r['total'] as num).toDouble(),
            ))
        .toList();
  }

  // -------------------- Sync helpers --------------------

  Future<List<JournalEntry>> unsyncedEntries() async {
    final rows = await _db.query('journal_entries',
        where: 'synced = 0', orderBy: 'created_at ASC');
    return rows.map(JournalEntry.fromMap).toList();
  }

  Future<void> markSynced(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE journal_entries SET synced = 1 WHERE id IN ($placeholders)',
      ids.toList(),
    );
  }
}

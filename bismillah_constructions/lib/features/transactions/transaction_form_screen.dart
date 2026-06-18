import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/labour_type_def.dart';
import '../../data/models/party.dart';
import '../../data/models/project.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../manage/labour_types_screen.dart';
import '../manage/material_types_screen.dart';

class TransactionFormScreen extends ConsumerStatefulWidget {
  const TransactionFormScreen({super.key, required this.kind});
  final TxnKind kind;

  @override
  ConsumerState<TransactionFormScreen> createState() =>
      _TransactionFormScreenState();
}

class _TransactionFormScreenState
    extends ConsumerState<TransactionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _workerCountCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController();

  String? _projectId;
  String? _supplierId;
  Account? _cashLike;
  Account? _transferTo;
  String? _materialType;
  String? _labourTypeName;
  bool _saving = false;

  /// When the user ticks "Counter purchase" on the Material Buy form, the
  /// posting switches from `postMaterialBuy` (Dr Material Costs / Cr
  /// Supplier Payables) to `postMaterialCounter` (Dr Material Costs / Cr
  /// Cash|Bank). No supplier is attached; the cash-like account is asked
  /// for instead.
  bool _counterPurchase = false;

  TxnKind get _k => widget.kind;
  bool get _isMaterialBuy => _k == TxnKind.materialBuy;
  bool get _isWalletTransfer => _k == TxnKind.walletTransfer;
  bool get _isPersonalDraw => _k == TxnKind.personalDraw;
  bool get _isLabourCredit => _k == TxnKind.labourCredit;
  bool get _isLabourPayment => _k == TxnKind.labourPayment;
  bool get _isLabourTxn => _isLabourCredit || _isLabourPayment;

  bool get _needsProject => switch (_k) {
        TxnKind.materialBuy ||
        TxnKind.labourPayment ||
        TxnKind.labourCredit ||
        TxnKind.receiveFromProject ||
        TxnKind.serviceFee =>
          true,
        _ => false,
      };

  bool get _needsOptionalProject => _k == TxnKind.supplierPay;

  bool get _needsSupplier {
    // Counter purchases skip the supplier — no credit relationship.
    if (_isMaterialBuy && _counterPurchase) return false;
    return switch (_k) {
      TxnKind.materialBuy ||
      TxnKind.supplierPay ||
      TxnKind.labourPayment ||
      TxnKind.labourCredit =>
        true,
      _ => false,
    };
  }

  bool get _needsCashLike {
    // Counter purchases pay directly from cash/bank — ask for the source.
    if (_isMaterialBuy && _counterPurchase) return true;
    return switch (_k) {
      TxnKind.labourPayment ||
      TxnKind.supplierPay ||
      TxnKind.receiveFromProject ||
      TxnKind.walletTransfer ||
      TxnKind.personalDraw ||
      TxnKind.serviceFee =>
        true,
      _ => false,
    };
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descCtrl.dispose();
    _workerCountCtrl.dispose();
    _quantityCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isWalletTransfer &&
        _cashLike != null &&
        _cashLike!.id == _transferTo?.id) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Source and destination must differ.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final ledger = await ref.read(ledgerRepoProvider.future);
      final desc =
          _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim();
      final amount = double.parse(_amountCtrl.text.replaceAll(',', ''));

      String txnId;
      switch (_k) {
        case TxnKind.materialBuy:
          if (_materialType == null) {
            throw StateError('Pick a material type first.');
          }
          final types = await ref.read(materialTypesProvider.future);
          final selType =
              types.firstWhereOrNull((t) => t.name == _materialType);
          final uom = selType?.uom ?? '';
          // Quantity is optional. When given, it feeds the price-trend
          // report and is echoed into the memo as "qty @ unit price".
          // When omitted, the buy is tracked by its memo alone.
          final qtyText = _quantityCtrl.text.trim();
          final qty = qtyText.isEmpty ? null : double.tryParse(qtyText);
          // Strip a trailing ".0" so "100.0 bag" reads as "100 bag".
          String trimZero(double v) {
            final s = v.toStringAsFixed(2);
            return s.endsWith('.00')
                ? s.substring(0, s.length - 3)
                : (s.endsWith('0') ? s.substring(0, s.length - 1) : s);
          }
          // Build the qty / unit-price memo fragments only when a quantity
          // was entered. A quantity-less buy reads e.g.
          //   "Cement · for foundation"
          // while a quantified one reads e.g.
          //   "Cement · 100 bag · @ Rs 1,000/bag · for foundation".
          String? qtyStr;
          String? unitPriceStr;
          if (qty != null && qty > 0) {
            final unitPrice = amount / qty;
            qtyStr = '${trimZero(qty)}${uom.isNotEmpty ? ' $uom' : ''}';
            unitPriceStr = uom.isNotEmpty
                ? '@ Rs ${trimZero(unitPrice)}/$uom'
                : '@ Rs ${trimZero(unitPrice)}';
          }
          final fullMemo =
              [_materialType!, ?qtyStr, ?unitPriceStr, ?desc].join(' · ');

          // Branch on the counter-purchase toggle. Both paths book the
          // cost against Material Costs + log the inventory row with the
          // quantity / per-unit rate the user entered. The difference is
          // just the credit side: Supplier Payables (credit) vs Cash/Bank
          // (counter purchase).
          if (_counterPurchase) {
            txnId = await ledger.postMaterialCounter(
                amount: amount,
                projectId: _projectId!,
                paidFrom: _cashLike!,
                description: fullMemo);
          } else {
            txnId = await ledger.postMaterialBuy(
                amount: amount,
                projectId: _projectId!,
                supplierId: _supplierId!,
                description: fullMemo);
          }
          final entityRepo = await ref.read(entityRepoProvider.future);
          await entityRepo.logMaterialPurchase(
            projectId: _projectId!,
            supplierId: _counterPurchase ? null : _supplierId,
            transactionId: txnId,
            materialType: _materialType!,
            price: amount,
            quantity: qty,
            unit: selType?.uom != null
                ? MaterialUnitX.fromDb(selType!.uom!)
                : null,
          );
        case TxnKind.materialCounter:
          // Not picker-exposed today (counter purchases come in via the
          // Material Buy form with the toggle on), but keep a stub here
          // so the switch exhaustiveness check stays happy and a future
          // direct entry point can land cleanly.
          throw StateError(
              'Use Material Buy with the counter-purchase toggle.');
        case TxnKind.labourPayment:
          final memo = [
            if (_labourTypeName != null && _labourTypeName!.isNotEmpty)
              _labourTypeName!,
            ?desc,
          ].join(' · ');
          txnId = await ledger.postLabourPayment(
              amount: amount,
              projectId: _projectId!,
              supplierId: _supplierId!,
              paidFrom: _cashLike!,
              description: memo.isEmpty ? null : memo);
        case TxnKind.labourCredit:
          final n = int.tryParse(_workerCountCtrl.text.trim());
          final memo = [
            if (_labourTypeName != null && _labourTypeName!.isNotEmpty)
              _labourTypeName!,
            if (n != null && n > 0) '$n worker${n == 1 ? '' : 's'}',
            ?desc,
          ].join(' · ');
          txnId = await ledger.postLabourCredit(
              amount: amount,
              projectId: _projectId!,
              supplierId: _supplierId!,
              description: memo.isEmpty ? null : memo);
        case TxnKind.supplierPay:
          txnId = await ledger.postSupplierPay(
              amount: amount,
              supplierId: _supplierId!,
              paidFrom: _cashLike!,
              projectId: _projectId,
              description: desc);
        case TxnKind.receiveFromProject:
          txnId = await ledger.postReceiveFromProject(
              amount: amount,
              projectId: _projectId!,
              receivedInto: _cashLike!,
              description: desc);
        case TxnKind.walletTransfer:
          txnId = await ledger.postWalletTransfer(
              amount: amount,
              from: _cashLike!,
              to: _transferTo!,
              description: desc);
        case TxnKind.personalDraw:
          txnId = await ledger.postPersonalDraw(
              amount: amount,
              paidFrom: _cashLike!,
              description: desc);
        case TxnKind.serviceFee:
          txnId = await ledger.postServiceFee(
              amount: amount,
              projectId: _projectId!,
              receivedInto: _cashLike!,
              description: desc);
      }
      assert(txnId.isNotEmpty);

      bumpLedger(ref);
      final svc = await ref.read(syncServiceFutureProvider.future);
      // ignore: unawaited_futures
      svc.syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_k.label} saved')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(activeProjectsProvider);
    final suppliers = ref.watch(suppliersProvider);
    final cashLike = ref.watch(cashLikeAccountsProvider);
    final materialTypes = ref.watch(materialTypesProvider);
    final labourTypes = ref.watch(labourTypesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(_k.label)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RoutingSummary(kind: _k),
              const SizedBox(height: 16),

              // ── Material type + quantity ──────────────────────────────────
              if (_isMaterialBuy) ...[
                _MaterialTypePicker(
                  current: _materialType,
                  onChanged: (v) => setState(() => _materialType = v),
                ),
                const SizedBox(height: 12),
                // Quantity is optional — when given it feeds the price-trend
                // report (which needs a real per-unit rate); when left blank
                // the buy is tracked by its memo alone. The label adapts to
                // the selected type's unit of measure.
                materialTypes.when(
                  loading: () => const SizedBox.shrink(),
                  error: (e, st) => const SizedBox.shrink(),
                  data: (types) {
                    final sel = types.firstWhereOrNull(
                        (t) => t.name == _materialType);
                    final uom = sel?.uom;
                    final hasUom = uom != null && uom.isNotEmpty;
                    return TextFormField(
                      controller: _quantityCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]')),
                      ],
                      decoration: InputDecoration(
                        labelText: hasUom
                            ? 'Quantity ($uom)'
                            : 'Quantity',
                        helperText: hasUom
                            ? 'Optional — how many $uom purchased '
                              '(enables price trend)'
                            : 'Optional — set a unit of measure in '
                              'Manage → Material Types to track price trend',
                      ),
                      validator: (v) {
                        // Optional: blank is fine. Only a non-empty value
                        // must parse to a positive number.
                        if (v == null || v.trim().isEmpty) return null;
                        final n = double.tryParse(v.trim());
                        if (n == null || n <= 0) {
                          return 'Must be greater than zero';
                        }
                        return null;
                      },
                    );
                  },
                ),
                const SizedBox(height: 12),
                // Counter-purchase toggle — paid from cash/bank, no
                // supplier credit.
                Card(
                  margin: EdgeInsets.zero,
                  child: SwitchListTile(
                    title: const Text('Counter purchase'),
                    subtitle: const Text(
                        'Paid on the spot from cash or bank — no supplier credit'),
                    value: _counterPurchase,
                    onChanged: (v) => setState(() {
                      _counterPurchase = v;
                      if (v) {
                        // Clear the supplier so leftover state doesn't
                        // leak into the post.
                        _supplierId = null;
                      } else {
                        // And clear the cash-like account when switching
                        // back to credit, otherwise stale state confuses
                        // _save().
                        _cashLike = null;
                      }
                    }),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // ── Labour type ───────────────────────────────────────────────
              if (_isLabourTxn) ...[
                _LabourTypePicker(
                  current: _labourTypeName,
                  labourTypes: labourTypes,
                  onChanged: (name, type) => setState(() {
                    _labourTypeName = name;
                    // Pre-fill amount hint when a default rate is set.
                    if (type?.defaultDailyRate != null &&
                        _amountCtrl.text.isEmpty) {
                      _amountCtrl.text = fmtMoney(type!.defaultDailyRate!);
                    }
                  }),
                ),
                const SizedBox(height: 12),
              ],

              // ── Worker count (labour on credit only) ──────────────────────
              if (_isLabourCredit) ...[
                TextFormField(
                  controller: _workerCountCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Number of Workers',
                    helperText:
                        'How many labourers showed up for this period',
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // ── Amount ───────────────────────────────────────────────────
              TextFormField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  _ThousandsSeparatorFormatter(),
                ],
                style: const TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  labelText: 'Amount (Rs)',
                  prefixText: 'Rs ',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Enter an amount';
                  final n = double.tryParse(v.replaceAll(',', ''));
                  if (n == null || n <= 0) return 'Must be a positive number';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              if (_needsProject)
                AsyncView<List<Project>>(
                  value: projects,
                  data: (list) => DropdownButtonFormField<String>(
                    initialValue: _projectId,
                    decoration:
                        const InputDecoration(labelText: 'Project *'),
                    items: list
                        .map((p) => DropdownMenuItem(
                            value: p.id, child: Text(p.name)))
                        .toList(),
                    onChanged: (v) => setState(() => _projectId = v),
                    validator: (v) =>
                        v == null ? 'Project is required' : null,
                  ),
                ),

              if (_needsOptionalProject) ...[
                const SizedBox(height: 12),
                AsyncView<List<Project>>(
                  value: projects,
                  data: (list) => DropdownButtonFormField<String>(
                    initialValue: _projectId,
                    decoration: const InputDecoration(
                        labelText:
                            'Project (optional — links payment to project)'),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('— None —')),
                      ...list.map((p) => DropdownMenuItem(
                          value: p.id, child: Text(p.name))),
                    ],
                    onChanged: (v) => setState(() => _projectId = v),
                  ),
                ),
              ],

              if (_needsSupplier) ...[
                const SizedBox(height: 12),
                AsyncView<List<Party>>(
                  value: suppliers,
                  data: (list) {
                    final filtered = switch (_k) {
                      TxnKind.labourPayment ||
                      TxnKind.labourCredit =>
                        list
                            .where((s) =>
                                s.category == null ||
                                s.category == SupplierCategory.labor)
                            .toList(),
                      TxnKind.supplierPay || TxnKind.materialBuy => list
                          .where((s) =>
                              s.category == null ||
                              s.category == SupplierCategory.material)
                          .toList(),
                      _ => list,
                    };
                    if (filtered.isEmpty) {
                      return Text(
                        _k == TxnKind.labourPayment ||
                                _k == TxnKind.labourCredit
                            ? 'No labour-category suppliers. Add one in Suppliers.'
                            : 'No material-category suppliers. Add one in Suppliers.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      );
                    }
                    if (_supplierId != null &&
                        !filtered.any((s) => s.id == _supplierId)) {
                      _supplierId = null;
                    }
                    return DropdownButtonFormField<String>(
                      initialValue: _supplierId,
                      decoration: InputDecoration(
                        labelText: _k == TxnKind.labourPayment ||
                                _k == TxnKind.labourCredit
                            ? 'Labour Provider *'
                            : 'Material Supplier *',
                      ),
                      items: filtered
                          .map((s) => DropdownMenuItem(
                              value: s.id, child: Text(s.name)))
                          .toList(),
                      onChanged: (v) => setState(() => _supplierId = v),
                      validator: (v) =>
                          v == null ? 'Select a supplier' : null,
                    );
                  },
                ),
              ],

              if (_needsCashLike) ...[
                const SizedBox(height: 12),
                AsyncView<List<Account>>(
                  value: cashLike,
                  data: (accounts) {
                    if (accounts.isEmpty) {
                      return const Text(
                          'No banks/wallets defined. Add one from Settings.');
                    }
                    _cashLike ??= accounts.first;
                    return DropdownButtonFormField<Account>(
                      initialValue: _cashLike,
                      decoration: InputDecoration(
                        labelText: switch (_k) {
                          TxnKind.receiveFromProject => 'Receive Into',
                          TxnKind.serviceFee => 'Receive Into',
                          TxnKind.walletTransfer => 'From Wallet',
                          _ => 'Pay From',
                        },
                      ),
                      items: accounts
                          .map((a) => DropdownMenuItem(
                              value: a, child: Text(a.name)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _cashLike = v ?? _cashLike),
                    );
                  },
                ),
              ],

              if (_isWalletTransfer) ...[
                const SizedBox(height: 12),
                AsyncView<List<Account>>(
                  value: cashLike,
                  data: (accounts) {
                    if (accounts.length < 2) {
                      return const Text(
                          'Add at least 2 banks/wallets to transfer between them.');
                    }
                    _transferTo ??= accounts.firstWhere(
                        (a) => a.id != _cashLike?.id,
                        orElse: () => accounts.first);
                    return DropdownButtonFormField<Account>(
                      initialValue: _transferTo,
                      decoration:
                          const InputDecoration(labelText: 'To Wallet'),
                      items: accounts
                          .map((a) => DropdownMenuItem(
                              value: a, child: Text(a.name)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _transferTo = v ?? _transferTo),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'Note: Inter-wallet movement does not reduce supplier payables.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],

              if (_isPersonalDraw) ...[
                const SizedBox(height: 8),
                Text(
                  'Recorded as a Personal/Daily Draw. Project liabilities remain intact.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],

              const SizedBox(height: 12),
              TextFormField(
                controller: _descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description / Memo (optional)',
                ),
                maxLines: 3,
                minLines: 2,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(_saving ? 'Saving…' : 'Save Transaction'),
              ),
              const SizedBox(height: 12),
              const _OfflineNote(),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutingSummary extends StatelessWidget {
  const _RoutingSummary({required this.kind});
  final TxnKind kind;

  ({String dr, String cr}) _route() => switch (kind) {
        TxnKind.materialBuy => (
            dr: Accounts.materialCosts.name,
            cr: Accounts.supplierPayables.name
          ),
        TxnKind.materialCounter => (
            dr: Accounts.materialCosts.name,
            cr: 'Cash / Bank'
          ),
        TxnKind.labourPayment => (
            dr: Accounts.labourCosts.name,
            cr: 'Cash / Bank'
          ),
        TxnKind.labourCredit => (
            dr: Accounts.labourCosts.name,
            cr: Accounts.supplierPayables.name
          ),
        TxnKind.supplierPay => (
            dr: Accounts.supplierPayables.name,
            cr: 'Cash / Bank'
          ),
        TxnKind.receiveFromProject => (
            dr: 'Cash / Bank',
            cr: Accounts.projectRevenue.name
          ),
        TxnKind.walletTransfer => (
            dr: 'Destination Wallet',
            cr: 'Source Wallet'
          ),
        TxnKind.personalDraw => (
            dr: Accounts.personalDraw.name,
            cr: 'Cash / Bank'
          ),
        TxnKind.serviceFee => (
            dr: 'Cash / Bank',
            cr: Accounts.serviceFeeIncome.name
          ),
      };

  @override
  Widget build(BuildContext context) {
    final r = _route();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Posting',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text('Dr  ${r.dr}'),
          Text('     Cr  ${r.cr}'),
        ],
      ),
    );
  }
}

class _OfflineNote extends ConsumerWidget {
  const _OfflineNote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text(
      'Saved locally first. Cloud sync runs automatically when online.',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// Dropdown of every material category from `material_types`, plus a
/// "+ Manage…" button to add new types without leaving the form.
class _MaterialTypePicker extends ConsumerWidget {
  const _MaterialTypePicker({required this.current, required this.onChanged});

  final String? current;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(materialTypesProvider);
    return typesAsync.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load material types: $e'),
      data: (types) {
        if (types.isEmpty) {
          return _ManageRow(empty: true, isLabour: false);
        }
        final selected =
            types.any((t) => t.name == current) ? current : types.first.name;
        if (selected != current) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onChanged(selected);
          });
        }
        return Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: selected,
                decoration:
                    const InputDecoration(labelText: 'Material Type *'),
                items: types
                    .map((t) => DropdownMenuItem(
                        value: t.name, child: Text(t.name)))
                    .toList(),
                onChanged: onChanged,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Pick a material type' : null,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Manage material types',
              icon: const Icon(Icons.tune),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const MaterialTypesScreen()),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Dropdown of every labour category from `labour_types`, with a
/// detail card showing skill description and default daily rate.
class _LabourTypePicker extends StatelessWidget {
  const _LabourTypePicker({
    required this.current,
    required this.labourTypes,
    required this.onChanged,
  });

  final String? current;
  final AsyncValue<List<LabourTypeDef>> labourTypes;
  final void Function(String? name, LabourTypeDef? type) onChanged;

  @override
  Widget build(BuildContext context) {
    return labourTypes.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text('Could not load labour types: $e'),
      data: (types) {
        if (types.isEmpty) {
          return _ManageRow(empty: true, isLabour: true);
        }
        final selType =
            types.firstWhereOrNull((t) => t.name == current);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: current,
                    decoration:
                        const InputDecoration(labelText: 'Labour Type (optional)'),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('— None —')),
                      ...types.map((t) => DropdownMenuItem(
                          value: t.name, child: Text(t.name))),
                    ],
                    onChanged: (v) {
                      final t = types.firstWhereOrNull((t) => t.name == v);
                      onChanged(v, t);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Manage labour types',
                  icon: const Icon(Icons.tune),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const LabourTypesScreen()),
                  ),
                ),
              ],
            ),
            // Detail card shown when a type with metadata is selected.
            if (selType != null &&
                (selType.description != null ||
                    selType.defaultDailyRate != null)) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selType.description != null) ...[
                      Text(selType.description!,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                    if (selType.defaultDailyRate != null)
                      Text(
                        'Default daily rate: ${fmtMoney(selType.defaultDailyRate!)}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ThousandsSeparatorFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    if (raw.isEmpty) return newValue;

    final cursor = newValue.selection.baseOffset.clamp(0, raw.length);
    var digitsBeforeCursor = 0;
    for (var i = 0; i < cursor; i++) {
      final ch = raw[i];
      if (ch != ',' && ch != '.') digitsBeforeCursor++;
    }

    final stripped = raw.replaceAll(',', '');
    final dotIdx = stripped.indexOf('.');
    final intPart = dotIdx == -1 ? stripped : stripped.substring(0, dotIdx);
    final fracPart = dotIdx == -1 ? '' : stripped.substring(dotIdx);

    final grouped = _groupThousands(intPart);
    final formatted = '$grouped$fracPart';

    var newCursor = formatted.length;
    var seen = 0;
    for (var i = 0; i < formatted.length; i++) {
      final ch = formatted[i];
      if (ch != ',' && ch != '.') seen++;
      if (seen >= digitsBeforeCursor) {
        newCursor = i + 1;
        break;
      }
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  static String _groupThousands(String digits) {
    if (digits.isEmpty) return '';
    final buf = StringBuffer();
    final n = digits.length;
    for (var i = 0; i < n; i++) {
      final fromRight = n - i;
      buf.write(digits[i]);
      if (fromRight > 1 && fromRight % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({this.empty = false, required this.isLabour});
  final bool empty;
  final bool isLabour;

  @override
  Widget build(BuildContext context) {
    final typeLabel = isLabour ? 'labour' : 'material';
    final message = empty
        ? 'No $typeLabel types defined. Add one to continue.'
        : 'Manage your $typeLabel categories.';

    // Column layout ensures the message always has full width and is never
    // squeezed into a narrow column that causes per-character line breaks.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.add),
            label: Text('Add $typeLabel type'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => isLabour
                    ? const LabourTypesScreen()
                    : const MaterialTypesScreen(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

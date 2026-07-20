import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/core/money_input.dart';
import 'package:bismillah_constructions/shared/core/whatsapp.dart';
import 'package:bismillah_constructions/shared/data/models/labour_type_def.dart';
import 'package:bismillah_constructions/shared/data/models/party.dart';
import 'package:bismillah_constructions/shared/data/models/project.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/mobile/features/common/async_view.dart';
import 'package:bismillah_constructions/mobile/features/common/searchable_dropdown.dart';
import 'package:bismillah_constructions/mobile/features/manage/labour_types_screen.dart';
import 'package:bismillah_constructions/mobile/features/manage/material_types_screen.dart';

class TransactionFormScreen extends ConsumerStatefulWidget {
  const TransactionFormScreen({super.key, required this.kind, this.onSaved});
  final TxnKind kind;

  /// When provided (desktop embeds the form as an inline sub-tab rather than
  /// a pushed route), this is called after a successful save INSTEAD of
  /// popping the route — so the host can reset the form for another entry
  /// instead of closing it. Null on mobile → the form pops itself as before.
  final VoidCallback? onSaved;

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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_k.label} saved')),
      );
      // Offer to WhatsApp a confirmation to the counterparty (supplier for
      // material/labour/supplier-pay, the project's client for receipts).
      // Silently skipped when that party has no number on file.
      await _maybePromptWhatsApp(amount: amount, description: desc);
      if (!mounted) return;
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
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

  /// After a save, if the transaction's counterparty has a WhatsApp number,
  /// offer to open WhatsApp with a pre-filled confirmation. Counterparty =
  /// the supplier for material/labour/supplier-pay, or the project's client
  /// for a receipt. Transfers, personal draws and counter purchases have no
  /// counterparty, so nothing is prompted. Missing number → skipped.
  Future<void> _maybePromptWhatsApp({
    required double amount,
    String? description,
  }) async {
    final entityRepo = await ref.read(entityRepoProvider.future);

    final supplierFacing = (_isMaterialBuy && !_counterPurchase) ||
        _k == TxnKind.labourPayment ||
        _k == TxnKind.labourCredit ||
        _k == TxnKind.supplierPay;

    String? number;
    String? recipientName;
    if (supplierFacing && _supplierId != null) {
      final s = await entityRepo.supplier(_supplierId!);
      number = s?.phone;
      recipientName = s?.name;
    } else if (_k == TxnKind.receiveFromProject && _projectId != null) {
      final p = await entityRepo.project(_projectId!);
      number = p?.whatsapp;
      recipientName = p?.name;
    }
    if (number == null || number.trim().isEmpty) return; // skip if missing

    String? projectName;
    if (_projectId != null) {
      projectName = (await entityRepo.project(_projectId!))?.name;
    }
    final msg = _whatsAppMessage(
        amount: amount, description: description, projectName: projectName);

    if (!mounted) return;
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.chat, color: Color(0xFF25D366)),
        title: Text('Send WhatsApp to ${recipientName ?? 'contact'}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To: $number'),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(msg),
            ),
            const SizedBox(height: 8),
            Text(
              'Opens WhatsApp with this message pre-filled — you tap send there.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Skip')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.send),
              label: const Text('Send')),
        ],
      ),
    );
    if (send == true) {
      final ok = await launchWhatsApp(number: number, message: msg);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not open WhatsApp on this device.')));
      }
    }
  }

  String _whatsAppMessage({
    required double amount,
    String? description,
    String? projectName,
  }) {
    final lines = <String>[
      'Bismillah Constructions',
      '',
      '${_k.label}: ${fmtMoney(amount)}',
      if (projectName != null) 'Project: $projectName',
      'Date: ${fmtDate(DateTime.now())}',
      if (description != null && description.isNotEmpty) description,
    ];
    return lines.join('\n');
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
                  const ThousandsSeparatorInputFormatter(),
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
                  data: (list) => SearchableDropdown<String>(
                    value: _projectId,
                    items: list.map((p) => p.id).toList(),
                    labelOf: (id) =>
                        list.firstWhere((p) => p.id == id).name,
                    labelText: 'Project *',
                    hintText: 'Search projects…',
                    onChanged: (v) => setState(() => _projectId = v),
                    validator: (v) =>
                        v == null ? 'Project is required' : null,
                  ),
                ),

              if (_needsOptionalProject) ...[
                const SizedBox(height: 12),
                AsyncView<List<Project>>(
                  value: projects,
                  data: (list) => SearchableDropdown<String?>(
                    value: _projectId,
                    items: [null, ...list.map((p) => p.id)],
                    labelOf: (id) => id == null
                        ? '— None —'
                        : list.firstWhere((p) => p.id == id).name,
                    labelText:
                        'Project (optional — links payment to project)',
                    hintText: 'Search projects…',
                    onChanged: (v) => setState(() => _projectId = v),
                  ),
                ),
              ],

              if (_needsSupplier) ...[
                const SizedBox(height: 12),
                AsyncView<List<Party>>(
                  value: suppliers,
                  data: (list) {
                    // A `null`/uncategorized party matches either side (legacy);
                    // a `both` party (v20) is a labour provider who also
                    // supplies materials on credit, so it shows up in both the
                    // labour and the material/supplier-pay pickers.
                    final isLabourPick = _k == TxnKind.labourPayment ||
                        _k == TxnKind.labourCredit;
                    final filtered = switch (_k) {
                      TxnKind.labourPayment ||
                      TxnKind.labourCredit =>
                        list
                            .where((s) =>
                                s.category == null ||
                                s.category!.suppliesLabour)
                            .toList(),
                      TxnKind.supplierPay || TxnKind.materialBuy => list
                          .where((s) =>
                              s.category == null ||
                              s.category!.suppliesMaterial)
                          .toList(),
                      _ => list,
                    };
                    if (filtered.isEmpty) {
                      return Text(
                        isLabourPick
                            ? 'No labour providers. Add one in Suppliers.'
                            : 'No material suppliers. Add one in Suppliers.',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      );
                    }
                    if (_supplierId != null &&
                        !filtered.any((s) => s.id == _supplierId)) {
                      _supplierId = null;
                    }
                    return SearchableDropdown<String>(
                      value: _supplierId,
                      items: filtered.map((s) => s.id).toList(),
                      labelOf: (id) =>
                          filtered.firstWhere((s) => s.id == id).name,
                      searchOf: (id) =>
                          filtered.firstWhere((s) => s.id == id).phone ?? '',
                      labelText:
                          isLabourPick ? 'Labour Provider *' : 'Material Supplier *',
                      hintText: 'Search by name or phone…',
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
                    return SearchableDropdown<Account>(
                      value: _cashLike,
                      items: accounts,
                      labelOf: (a) => a.name,
                      labelText: switch (_k) {
                        TxnKind.receiveFromProject => 'Receive Into',
                        TxnKind.serviceFee => 'Receive Into',
                        TxnKind.walletTransfer => 'From Wallet',
                        _ => 'Pay From',
                      },
                      hintText: 'Search wallets…',
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
                    return SearchableDropdown<Account>(
                      value: _transferTo,
                      items: accounts,
                      labelOf: (a) => a.name,
                      labelText: 'To Wallet',
                      hintText: 'Search wallets…',
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
              child: SearchableDropdown<String>(
                value: selected,
                items: types.map((t) => t.name).toList(),
                labelOf: (name) => name,
                labelText: 'Material Type *',
                hintText: 'Search material types…',
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
                  child: SearchableDropdown<String?>(
                    value: current,
                    items: [null, ...types.map((t) => t.name)],
                    labelOf: (name) => name ?? '— None —',
                    labelText: 'Labour Type (optional)',
                    hintText: 'Search labour types…',
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

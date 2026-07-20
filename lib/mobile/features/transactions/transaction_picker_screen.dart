import 'package:flutter/material.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/mobile/features/transactions/transaction_form_screen.dart';

class TransactionPickerScreen extends StatelessWidget {
  const TransactionPickerScreen({super.key});

  /// Service Fee was removed from the picker — for Labour-Rate projects the
  /// fee is configured on the project itself (`Project.serviceFeePercent`)
  /// and posted automatically when the project is closed/reconciled, so a
  /// manual fee transaction is no longer a meaningful thing for the user
  /// to add.
  ///
  /// Personal / Owner Draw is back in the picker — it's the canonical way
  /// to record cash leaving the construction system from any cash-like
  /// account (Cash, Wallet, Bank). Use it whenever money leaves a wallet
  /// or bank for non-construction purposes.
  static const _visibleKinds = <TxnKind>[
    TxnKind.materialBuy,
    TxnKind.labourPayment,
    TxnKind.labourCredit,
    TxnKind.supplierPay,
    TxnKind.receiveFromProject,
    TxnKind.walletTransfer,
    TxnKind.personalDraw,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Transaction')),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _visibleKinds.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final kind = _visibleKinds[i];
          final color = _colorFor(kind);
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                // Soft tinted background + saturated foreground icon, same
                // pattern as the Reports and Manage tiles so the New
                // Transaction list is scannable at a glance.
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(_iconFor(kind), color: color),
              ),
              title: Text(kind.label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              // Descriptive blurb dropped so the list stays compact under
              // large font/display scaling.
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TransactionFormScreen(kind: kind),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _iconFor(TxnKind k) => switch (k) {
        TxnKind.materialBuy => Icons.inventory_2,
        // materialCounter isn't in _visibleKinds (it's accessed via the
        // Material Buy form's counter-purchase toggle), but the switch
        // has to be exhaustive over the enum.
        TxnKind.materialCounter => Icons.point_of_sale,
        TxnKind.labourPayment => Icons.engineering,
        TxnKind.labourCredit => Icons.handyman,
        TxnKind.supplierPay => Icons.payments,
        TxnKind.receiveFromProject => Icons.account_balance_wallet,
        TxnKind.walletTransfer => Icons.swap_horiz,
        TxnKind.personalDraw => Icons.shopping_bag,
        TxnKind.serviceFee => Icons.percent,
      };

  /// Per-kind accent so each row is visually distinct. Grouped intuitively:
  /// material → orange/amber tones, labour → blue tones, money-in → green,
  /// settlement/transfer → indigo/teal, draw → red (because cash leaving
  /// the business for non-construction use is worth a visual flag).
  Color _colorFor(TxnKind k) => switch (k) {
        TxnKind.materialBuy => Colors.deepOrange,
        TxnKind.materialCounter => Colors.amber.shade800,
        TxnKind.labourPayment => Colors.blue.shade700,
        TxnKind.labourCredit => Colors.indigo,
        TxnKind.supplierPay => Colors.teal.shade700,
        TxnKind.receiveFromProject => Colors.green.shade700,
        TxnKind.walletTransfer => Colors.cyan.shade700,
        TxnKind.personalDraw => Colors.red.shade700,
        TxnKind.serviceFee => Colors.purple,
      };
}

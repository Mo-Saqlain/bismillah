import 'package:flutter/material.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/mobile/features/parties/parties_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/aging_analysis_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/supplier_ledger_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/supplier_spending_screen.dart';
import 'package:bismillah_constructions/mobile/features/transactions/transaction_form_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

class SuppliersTab extends StatelessWidget {
  const SuppliersTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.payments_outlined, 'Supplier Payment',
            (reset) =>
                TransactionFormScreen(kind: TxnKind.supplierPay, onSaved: reset)),
        SubScreen(Icons.people_alt_outlined, 'All Suppliers',
            (_) => const SuppliersScreen()),
        SubScreen(Icons.menu_book_outlined, 'Supplier Ledger',
            (_) => const SupplierLedgerPickerScreen()),
        SubScreen(Icons.bar_chart_outlined, 'Supplier Spending',
            (_) => const SupplierSpendingScreen()),
        SubScreen(Icons.hourglass_bottom_outlined, 'Payables Aging',
            (_) => const AgingAnalysisScreen()),
      ],
    );
  }
}

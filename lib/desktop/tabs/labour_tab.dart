import 'package:flutter/material.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/mobile/features/manage/labour_types_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/wage_ledger_screen.dart';
import 'package:bismillah_constructions/mobile/features/transactions/transaction_form_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

class LabourTab extends StatelessWidget {
  const LabourTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.payments_outlined, 'Labour Payment',
            (reset) => TransactionFormScreen(
                kind: TxnKind.labourPayment, onSaved: reset)),
        SubScreen(Icons.schedule_outlined, 'Labour on Credit',
            (reset) =>
                TransactionFormScreen(kind: TxnKind.labourCredit, onSaved: reset)),
        SubScreen(Icons.badge_outlined, 'Labour Types',
            (_) => const LabourTypesScreen()),
        SubScreen(Icons.menu_book_outlined, 'Wage Ledger',
            (_) => const WageLedgerPickerScreen()),
      ],
    );
  }
}

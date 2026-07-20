import 'package:flutter/material.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/mobile/features/parties/banks_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/bank_ledger_screen.dart';
import 'package:bismillah_constructions/mobile/features/transactions/transaction_form_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

class WalletsTab extends StatelessWidget {
  const WalletsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.swap_horiz_outlined, 'Wallet Transfer',
            (reset) => TransactionFormScreen(
                kind: TxnKind.walletTransfer, onSaved: reset)),
        SubScreen(Icons.logout_outlined, 'Personal / Owner Draw',
            (reset) =>
                TransactionFormScreen(kind: TxnKind.personalDraw, onSaved: reset)),
        SubScreen(Icons.account_balance_outlined, 'Wallets & Banks',
            (_) => const BanksScreen()),
        SubScreen(Icons.menu_book_outlined, 'Account Ledger',
            (_) => const BankLedgerPickerScreen()),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/mobile/features/projects/projects_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/aging_receivables_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/project_bva_picker_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/project_ledger_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/project_profitability_screen.dart';
import 'package:bismillah_constructions/mobile/features/transactions/transaction_form_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

class ProjectsTab extends StatelessWidget {
  const ProjectsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.south_west, 'Receive from Project',
            (reset) => TransactionFormScreen(
                kind: TxnKind.receiveFromProject, onSaved: reset)),
        SubScreen(Icons.list_alt, 'All Projects', (_) => const ProjectsScreen()),
        SubScreen(Icons.percent_outlined, 'Service Fee',
            (reset) =>
                TransactionFormScreen(kind: TxnKind.serviceFee, onSaved: reset)),
        SubScreen(Icons.menu_book_outlined, 'Project Ledger',
            (_) => const ProjectLedgerPickerScreen()),
        SubScreen(Icons.donut_large_outlined, 'Budget vs Actual',
            (_) => const ProjectBvaPickerScreen()),
        SubScreen(Icons.leaderboard_outlined, 'Profitability',
            (_) => const ProjectProfitabilityScreen()),
        SubScreen(Icons.request_quote_outlined, 'Receivables',
            (_) => const AgingReceivablesScreen()),
      ],
    );
  }
}

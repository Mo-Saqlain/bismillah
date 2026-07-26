import 'package:flutter/material.dart';

import 'package:bismillah_constructions/mobile/features/reports/balance_sheet_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/cash_flow_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/income_statement_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/income_trend_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/trial_balance_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

/// Cross-cutting financial statements only. Entity-specific reports/ledgers
/// (supplier/wage/bank/project ledgers, aging, spending, BvA, profitability,
/// price trend) live in their own tabs — kept out of here to avoid duplication.
class ReportsTab extends StatelessWidget {
  const ReportsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.receipt_long_outlined, 'Income Statement',
            (_) => const IncomeStatementScreen()),
        SubScreen(Icons.balance_outlined, 'Balance Sheet',
            (_) => const BalanceSheetScreen()),
        SubScreen(Icons.waterfall_chart_outlined, 'Cash Flow',
            (_) => const CashFlowScreen()),
        SubScreen(Icons.timeline_outlined, 'Monthly P&L Trend',
            (_) => const IncomeTrendScreen()),
        SubScreen(Icons.balance, 'Trial Balance',
            (_) => const TrialBalanceScreen()),
      ],
    );
  }
}

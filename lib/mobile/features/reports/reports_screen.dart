import 'package:flutter/material.dart';

import 'package:bismillah_constructions/mobile/features/home/home_screen.dart' show kPillNavReservedHeight;
import 'package:bismillah_constructions/mobile/features/reports/aging_analysis_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/aging_receivables_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/balance_sheet_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/bank_ledger_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/cash_flow_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/income_statement_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/income_trend_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/material_price_trend_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/project_bva_picker_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/project_ledger_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/project_profitability_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/supplier_ledger_picker_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/supplier_spending_screen.dart';
import 'package:bismillah_constructions/mobile/features/reports/wage_ledger_screen.dart';

/// Reports landing page. Tiles are grouped into sections so the list stays
/// scannable as more reports get added:
///   * **Financial Statements** — the big-three numbers a small business
///     looks at first (P&L, Balance Sheet, Cash Flow).
///   * **Ledgers** — per-party / per-account statements of activity.
///   * **Aging** — what's owed and how stale it is.
///   * **Project** — project-specific reports.
///
/// Each tile is a compact single-line row (icon + name). The longer
/// descriptions were removed so the list doesn't wrap into tall blocks on
/// phones set to a large font / display size.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(
        // Bottom padding clears the floating pill nav.
        padding: const EdgeInsets.fromLTRB(
            12, 12, 12, 12 + kPillNavReservedHeight),
        children: [
          _SectionTitle('Ledgers'),
          _ReportTile(
            icon: Icons.receipt_long,
            color: Colors.teal,
            title: 'Material Supplier Ledger',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SupplierLedgerPickerScreen())),
          ),
          _ReportTile(
            icon: Icons.engineering,
            color: Colors.purple,
            title: 'Labour Supplier Ledger',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const WageLedgerPickerScreen())),
          ),
          _ReportTile(
            icon: Icons.account_balance_wallet,
            color: Colors.cyan,
            title: 'Bank / Wallet Ledger',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const BankLedgerPickerScreen())),
          ),
          _ReportTile(
            icon: Icons.foundation,
            color: Colors.indigo,
            title: 'Project Ledger',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ProjectLedgerPickerScreen())),
          ),
          _SectionTitle('Financial Statements'),
          _ReportTile(
            icon: Icons.trending_up,
            color: Colors.green,
            title: 'Income Statement (P&L)',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const IncomeStatementScreen())),
          ),
          _ReportTile(
            icon: Icons.account_balance,
            color: Colors.blue,
            title: 'Balance Sheet',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const BalanceSheetScreen())),
          ),
          _ReportTile(
            icon: Icons.swap_vert,
            color: Colors.deepPurple,
            title: 'Cash Flow Statement',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const CashFlowScreen())),
          ),
          _ReportTile(
            icon: Icons.timeline,
            color: Colors.lightGreen,
            title: 'Monthly P&L Trend',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const IncomeTrendScreen())),
          ),
          _SectionTitle('Aging'),
          _ReportTile(
            icon: Icons.hourglass_bottom,
            color: Colors.red,
            title: 'Aging — Payables',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AgingAnalysisScreen())),
          ),
          _ReportTile(
            icon: Icons.hourglass_top,
            color: Colors.amber,
            title: 'Aging — Receivables',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AgingReceivablesScreen())),
          ),
          _SectionTitle('Operations'),
          _ReportTile(
            icon: Icons.bar_chart,
            color: Colors.deepOrange,
            title: 'Supplier-wise Spending',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SupplierSpendingScreen())),
          ),
          _SectionTitle('Project Analysis'),
          _ReportTile(
            icon: Icons.assessment,
            color: Colors.pink,
            title: 'Budget vs Actual',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ProjectBvaPickerScreen())),
          ),
          _ReportTile(
            icon: Icons.leaderboard,
            color: Colors.brown,
            title: 'Project Profitability',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ProjectProfitabilityScreen())),
          ),
          _ReportTile(
            icon: Icons.show_chart,
            color: Colors.indigo,
            title: 'Material Price Trend',
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const MaterialPriceTrendScreen())),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}

class _ReportTile extends StatelessWidget {
  const _ReportTile(
      {required this.icon,
      required this.color,
      required this.title,
      required this.onTap});
  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          foregroundColor: color,
          child: Icon(icon),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/formatters.dart';
import '../../data/models/journal_entry.dart';

class IncomeStatementData {
  final String? projectName;
  /// Revenue from With-Material projects (capped at budget per project).
  final double wmRevenue;
  /// Service fees earned (Labour-Rate close fees + standalone service fees).
  final double serviceFees;
  final double materialCosts;
  final double labourCosts;
  final double personalDraw;
  /// Customer deposit owed back from Labour-Rate projects.
  final double lrDeposit;
  /// Customer deposit owed back from over-budget With-Material payments.
  final double wmDeposit;
  final DateTime generatedAt;
  /// Human-readable period label ("All dates", "1 Jan 2025 → 31 Mar 2025").
  final String period;

  IncomeStatementData({
    this.projectName,
    this.wmRevenue = 0,
    this.serviceFees = 0,
    required this.materialCosts,
    required this.labourCosts,
    this.personalDraw = 0,
    this.lrDeposit = 0,
    this.wmDeposit = 0,
    required this.generatedAt,
    this.period = 'All dates',
  });

  double get totalIncome => wmRevenue + serviceFees;
  double get totalCosts => materialCosts + labourCosts + personalDraw;
  double get net => totalIncome - totalCosts;
  double get totalDeposit => lrDeposit + wmDeposit;
}

class BalanceSheetData {
  final double cash;
  /// (name, balance) pairs for each user-defined bank/wallet.
  final List<(String, double)> bankRows;
  final double counterReceivables;
  /// Money owed to us by under-funded projects (spent beyond received).
  final double projectReceivables;
  /// Net advances sitting with suppliers (we paid more than we were billed).
  final double supplierAdvances;
  final double payables;
  final double counterPayables;
  /// Project money received but not yet earned — a refundable advance.
  final double customerDeposits;
  /// Provision for anticipated losses on over-budget projects.
  final double lossProvision;
  /// Cumulative recognized net profit from the P&L — a memo cross-check.
  /// This business holds no contributed owner capital, so net worth is
  /// profit retained in the business.
  final double accumulatedProfit;
  final DateTime generatedAt;
  BalanceSheetData({
    required this.cash,
    required this.bankRows,
    required this.counterReceivables,
    required this.projectReceivables,
    required this.supplierAdvances,
    required this.payables,
    required this.counterPayables,
    required this.customerDeposits,
    required this.lossProvision,
    required this.accumulatedProfit,
    required this.generatedAt,
  });
  double get totalBanks =>
      bankRows.fold<double>(0, (a, r) => a + r.$2);
  double get assets =>
      cash +
      totalBanks +
      counterReceivables +
      projectReceivables +
      supplierAdvances;
  double get liabilities =>
      payables + counterPayables + customerDeposits + lossProvision;
  double get netWorth => assets - liabilities;
}

class SupplierLedgerData {
  final String supplierName;
  final List<JournalEntry> rows;
  final DateTime generatedAt;
  /// Human-readable period label ("All dates", "1 Jan 2025 → 31 Mar 2025").
  /// Surfaced under the title on the printed PDF so the report is unambiguous
  /// about what window of activity it covers (FBR audits expect this).
  final String period;
  /// Optional party identification (NTN / CNIC / category) — printed in the
  /// header for FBR-style ledgers. Pass an empty string to omit.
  final String partyMeta;
  SupplierLedgerData({
    required this.supplierName,
    required this.rows,
    required this.generatedAt,
    this.period = 'All dates',
    this.partyMeta = '',
  });
}

class BankLedgerData {
  final String bankName;
  final List<JournalEntry> rows;
  final DateTime generatedAt;
  final String period;
  BankLedgerData({
    required this.bankName,
    required this.rows,
    required this.generatedAt,
    this.period = 'All dates',
  });
}

class ProjectLedgerData {
  final String projectName;
  final List<JournalEntry> rows;
  final DateTime generatedAt;
  final String period;
  ProjectLedgerData({
    required this.projectName,
    required this.rows,
    required this.generatedAt,
    this.period = 'All dates',
  });
}

class WorkerLedgerData {
  final String workerName;
  final List<JournalEntry> rows;
  final DateTime generatedAt;
  final String period;
  WorkerLedgerData({
    required this.workerName,
    required this.rows,
    required this.generatedAt,
    this.period = 'All dates',
  });
}

class PdfGenerator {
  static Future<void> previewIncomeStatement(IncomeStatementData d) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) => _buildIncomeStatement(d),
      name: 'Income Statement',
    );
  }

  static Future<void> previewBalanceSheet(BalanceSheetData d) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) => _buildBalanceSheet(d),
      name: 'Balance Sheet',
    );
  }

  static Future<void> previewSupplierLedger(SupplierLedgerData d) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) => _buildSupplierLedger(d),
      name: 'Material Supplier Ledger — ${d.supplierName}',
    );
  }

  static Future<void> previewBankLedger(BankLedgerData d) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) => _buildBankLedger(d),
      name: 'Bank Ledger — ${d.bankName}',
    );
  }

  static Future<void> previewProjectLedger(ProjectLedgerData d) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat f) => _buildProjectLedger(d),
      name: 'Project Ledger — ${d.projectName}',
    );
  }

  // ---- Builders ----

  static pw.Widget _header(String title, String subtitle) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Bismillah',
              style: pw.TextStyle(
                  fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 2),
          pw.Text(title,
              style: pw.TextStyle(
                  fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.Text(subtitle,
              style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.Divider(),
        ],
      );

  static pw.Widget _line(String label, double v, {bool bold = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label,
                style: pw.TextStyle(
                    fontWeight:
                        bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
            pw.Text(fmtMoney(v),
                style: pw.TextStyle(
                    fontWeight:
                        bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ],
        ),
      );

  static Future<Uint8List> _buildIncomeStatement(
      IncomeStatementData d) async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _header(
              'Income Statement',
              'Project: ${d.projectName ?? "All Projects"}  ·  '
                  'Period: ${d.period}  ·  '
                  'Generated ${fmtDateTime(d.generatedAt)}'),
          pw.SizedBox(height: 12),
          // ── Income ──────────────────────────────────────────────────────
          if (d.wmRevenue > 0)
            _line('Contract Revenue (With-Material)', d.wmRevenue),
          if (d.serviceFees > 0)
            _line('Service Fees', d.serviceFees),
          _line('Total Income', d.totalIncome, bold: true),
          pw.SizedBox(height: 8),
          // ── Costs ────────────────────────────────────────────────────────
          pw.Text('Costs & Draws',
              style: pw.TextStyle(
                  fontSize: 12, fontWeight: pw.FontWeight.bold)),
          _line('  Material Costs', d.materialCosts),
          _line('  Labour Costs', d.labourCosts),
          if (d.personalDraw > 0)
            _line('  Personal Draw', d.personalDraw),
          _line('  Total Costs', d.totalCosts, bold: true),
          pw.Divider(),
          _line('Net Profit / (Loss)', d.net, bold: true),
          // ── Customer Deposits (informational) ────────────────────────────
          if (d.totalDeposit > 0) ...[
            pw.SizedBox(height: 10),
            pw.Divider(),
            pw.Text('Customer Deposits (owed back)',
                style: pw.TextStyle(
                    fontSize: 11, fontWeight: pw.FontWeight.bold)),
            if (d.lrDeposit > 0)
              _line('  Labour-Rate projects', -d.lrDeposit),
            if (d.wmDeposit > 0)
              _line('  Over-budget (With-Material)', -d.wmDeposit),
            _line('  Total deposits owed', -d.totalDeposit, bold: true),
          ],
        ],
      ),
    ));
    return doc.save();
  }

  static Future<Uint8List> _buildBalanceSheet(BalanceSheetData d) async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _header('Balance Sheet',
              'As of ${fmtDateTime(d.generatedAt)}'),
          pw.SizedBox(height: 12),
          pw.Text('Assets',
              style: pw.TextStyle(
                  fontSize: 14, fontWeight: pw.FontWeight.bold)),
          _line('  Cash', d.cash),
          for (final r in d.bankRows) _line('  ${r.$1}', r.$2),
          if (d.counterReceivables != 0)
            _line('  Counter Receivables', d.counterReceivables),
          if (d.projectReceivables != 0)
            _line('  Project Receivables (under-funded)',
                d.projectReceivables),
          if (d.supplierAdvances != 0)
            _line('  Supplier Advances', d.supplierAdvances),
          _line('Total Assets', d.assets, bold: true),
          pw.SizedBox(height: 12),
          pw.Text('Liabilities',
              style: pw.TextStyle(
                  fontSize: 14, fontWeight: pw.FontWeight.bold)),
          _line('  Supplier Payables', d.payables),
          if (d.counterPayables != 0)
            _line('  Counter Payables', d.counterPayables),
          if (d.customerDeposits != 0)
            _line('  Customer Advances (unearned)', d.customerDeposits),
          if (d.lossProvision != 0)
            _line('  Provision for Project Losses', d.lossProvision),
          _line('Total Liabilities', d.liabilities, bold: true),
          pw.SizedBox(height: 12),
          pw.Divider(),
          _line('Net Worth (retained in business)', d.netWorth, bold: true),
          pw.SizedBox(height: 14),
          pw.Text('Memo',
              style: pw.TextStyle(
                  fontSize: 11, fontWeight: pw.FontWeight.bold)),
          _line('  Accumulated profit to date (P&L)', d.accumulatedProfit),
          pw.SizedBox(height: 4),
          pw.Text(
            'This business holds no contributed owner capital — net worth is '
            'profit retained from completed and in-progress work. Net worth '
            'and accumulated profit can differ by externally-tracked counter '
            'receivables/payables and any opening cash entered directly.',
            style:
                const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    ));
    return doc.save();
  }

  static Future<Uint8List> _buildBankLedger(BankLedgerData d) async {
    final doc = pw.Document();
    double running = 0;
    final tableRows = <List<String>>[
      ['Date', 'Particulars', 'Debit (in)', 'Credit (out)', 'Balance'],
    ];
    for (final r in d.rows) {
      running += r.debit - r.credit;
      tableRows.add([
        fmtDate(r.createdAt),
        r.description ?? '—',
        r.debit > 0 ? fmtMoney(r.debit) : '',
        r.credit > 0 ? fmtMoney(r.credit) : '',
        fmtMoney(running),
      ]);
    }
    doc.addPage(pw.MultiPage(
      build: (ctx) => [
        _header('Bank / Wallet Ledger',
            '${d.bankName}  ·  Period: ${d.period}  ·  Generated ${fmtDateTime(d.generatedAt)}'),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          headerDecoration:
              const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerLeft,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight,
          },
          data: tableRows,
        ),
        pw.SizedBox(height: 16),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Net Balance: ${fmtMoney(running)}',
              style: pw.TextStyle(
                  fontSize: 14, fontWeight: pw.FontWeight.bold)),
        ),
      ],
    ));
    return doc.save();
  }

  static Future<Uint8List> _buildProjectLedger(ProjectLedgerData d) async {
    final doc = pw.Document();
    double running = 0;
    final tableRows = <List<String>>[
      ['Date', 'Particulars', 'Debit', 'Credit', 'Running'],
    ];
    // The repository already filtered to project-attributable rows
    // (Material/Labour costs as debits, Project Revenue / Service Fee as
    // credits), so we render them in order without trying to pair sides.
    for (final r in d.rows) {
      running += r.debit - r.credit;
      tableRows.add([
        fmtDate(r.createdAt),
        r.description ?? '—',
        r.debit > 0 ? fmtMoney(r.debit) : '',
        r.credit > 0 ? fmtMoney(r.credit) : '',
        fmtMoney(running),
      ]);
    }
    doc.addPage(pw.MultiPage(
      build: (ctx) => [
        _header('Project Ledger',
            '${d.projectName}  ·  Period: ${d.period}  ·  Generated ${fmtDateTime(d.generatedAt)}'),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          headerDecoration:
              const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerLeft,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight,
          },
          data: tableRows,
        ),
      ],
    ));
    return doc.save();
  }

  static Future<Uint8List> _buildSupplierLedger(
      SupplierLedgerData d) async {
    final doc = pw.Document();
    double running = 0;
    final tableRows = <List<String>>[
      ['Date', 'Particulars', 'Debit', 'Credit', 'Balance'],
    ];
    for (final r in d.rows) {
      // For supplier payables: credits increase, debits decrease.
      running += r.credit - r.debit;
      tableRows.add([
        fmtDate(r.createdAt),
        r.description ?? '—',
        r.debit > 0 ? fmtMoney(r.debit) : '',
        r.credit > 0 ? fmtMoney(r.credit) : '',
        fmtMoney(running),
      ]);
    }

    final subtitle = StringBuffer(d.supplierName);
    if (d.partyMeta.isNotEmpty) subtitle.write('  ·  ${d.partyMeta}');
    subtitle
      ..write('  ·  Period: ${d.period}')
      ..write('  ·  Generated ${fmtDateTime(d.generatedAt)}');

    doc.addPage(pw.MultiPage(
      build: (ctx) => [
        _header('Material Supplier Ledger', subtitle.toString()),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          headerDecoration:
              const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerLeft,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
            4: pw.Alignment.centerRight,
          },
          data: tableRows,
        ),
        pw.SizedBox(height: 16),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Net Outstanding: ${fmtMoney(running)}',
              style: pw.TextStyle(
                  fontSize: 14, fontWeight: pw.FontWeight.bold)),
        ),
      ],
    ));
    return doc.save();
  }

  // ---------------- Wage Ledger ----------------

  static Future<void> previewWorkerLedger(WorkerLedgerData d) =>
      Printing.layoutPdf(
        onLayout: (PdfPageFormat f) => _buildWorkerLedger(d),
        name: 'Wage Ledger — ${d.workerName}',
      );

  static Future<Uint8List> _buildWorkerLedger(WorkerLedgerData d) async {
    final doc = pw.Document();
    double running = 0;
    final tableRows = <List<String>>[
      ['Date', 'Particulars', 'Debit (Wages)', 'Balance'],
    ];
    for (final r in d.rows) {
      running += r.debit;
      tableRows.add([
        fmtDate(r.createdAt),
        r.description ?? '—',
        fmtMoney(r.debit),
        fmtMoney(running),
      ]);
    }
    doc.addPage(pw.MultiPage(
      build: (ctx) => [
        _header('Wage Ledger',
            '${d.workerName}  ·  Period: ${d.period}  ·  Generated ${fmtDateTime(d.generatedAt)}'),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          headerDecoration:
              const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerLeft,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
          },
          data: tableRows,
        ),
        pw.SizedBox(height: 16),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Total Wages: ${fmtMoney(running)}',
              style: pw.TextStyle(
                  fontSize: 14, fontWeight: pw.FontWeight.bold)),
        ),
      ],
    ));
    return doc.save();
  }
}

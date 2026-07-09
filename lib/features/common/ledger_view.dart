import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';

/// One row in a ledger table. The screen calling [LedgerView] is responsible
/// for computing [balance] (the sign convention varies by ledger — debits
/// increase a bank balance but credits increase a supplier payable).
class LedgerRow {
  final DateTime date;
  final String memo;
  final double debit;
  final double credit;
  final double balance;

  const LedgerRow({
    required this.date,
    required this.memo,
    required this.debit,
    required this.credit,
    required this.balance,
  });
}

/// Shared ledger presenter. Used by the supplier, bank/wallet and project
/// ledger screens so the layout is identical.
///
/// The caller renders any custom header (subtitle, filter pills, etc.) via
/// [headerBelowTitle]; the table + total card are rendered by this widget.
class LedgerView extends StatelessWidget {
  const LedgerView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.rows,
    required this.totalLabel,
    required this.totalValue,
    this.particularsHeader = 'Particulars',
    this.debitHeader = 'Debit',
    this.creditHeader = 'Credit',
    this.balanceHeader = 'Balance',
    this.emptyMessage = 'No transactions yet.',
    this.signedTotal = false,
    this.invertColorSign = false,
    this.headerBelowTitle,
  });

  /// Column header for the memo / description column. Defaults to
  /// "Particulars" — the FBR ledger convention.
  final String particularsHeader;

  /// Big page heading.
  final String title;

  /// Smaller line under the title (e.g. "Material · Acct ABC").
  final String subtitle;

  /// Optional widgets between the title block and the table (filter, etc.).
  final Widget? headerBelowTitle;

  final List<LedgerRow> rows;

  /// Footer card label (e.g. "Net Outstanding", "Net Balance").
  final String totalLabel;

  /// Footer card value.
  final double totalValue;

  /// When true, the total is rendered with a +/- prefix and tinted
  /// emerald/rose. Use for ledgers where the sign of the total is
  /// meaningful (project net debit position, bank balance, supplier
  /// payable balance).
  final bool signedTotal;

  /// When true, colors are picked using the **inverse** sign of the value
  /// — i.e. a positive balance is rendered as a "negative" (red) and a
  /// negative balance is rendered as "positive" (green).
  ///
  /// Required for ledgers where the raw arithmetic sign is the *opposite*
  /// of what's good for the business owner. A supplier ledger is the
  /// canonical example: `balance = credits − debits` is positive when we
  /// owe the supplier (a liability — bad for us, should look red), and
  /// negative when we have overpaid them (an asset — good for us, should
  /// look green). Without this flag the colors would imply the
  /// opposite of the business meaning.
  final bool invertColorSign;

  final String debitHeader;
  final String creditHeader;
  final String balanceHeader;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        if (subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle, style: theme.textTheme.bodySmall),
          ),
        if (headerBelowTitle != null) ...[
          const SizedBox(height: 12),
          headerBelowTitle!,
        ],
        const SizedBox(height: 12),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(emptyMessage)),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      const _H('Date', flex: 3),
                      _H(particularsHeader, flex: 4),
                      _H(debitHeader, flex: 2, right: true),
                      _H(creditHeader, flex: 2, right: true),
                      _H(balanceHeader, flex: 3, right: true),
                    ],
                  ),
                  const Divider(),
                  ...rows.map((r) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            _C(fmtDate(r.date), flex: 3),
                            _C(r.memo, flex: 4),
                            _C(r.debit > 0 ? fmtMoney(r.debit) : '',
                                flex: 2, right: true),
                            _C(r.credit > 0 ? fmtMoney(r.credit) : '',
                                flex: 2, right: true),
                            _C(
                              signedTotal
                                  ? fmtSignedMoney(r.balance)
                                  : fmtMoney(r.balance),
                              flex: 3,
                              right: true,
                              bold: true,
                              color: signedTotal
                                  ? BalanceColors.signed(context,
                                      invertColorSign ? -r.balance : r.balance)
                                  : null,
                            ),
                          ],
                        ),
                      )),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(totalLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                signedTotal ? fmtSignedMoney(totalValue) : fmtMoney(totalValue),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: signedTotal
                      ? BalanceColors.signed(context,
                          invertColorSign ? -totalValue : totalValue)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _H extends StatelessWidget {
  const _H(this.text, {required this.flex, this.right = false});
  final String text;
  final int flex;
  final bool right;
  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        child: Text(text,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
      );
}

class _C extends StatelessWidget {
  const _C(this.text,
      {required this.flex,
      this.right = false,
      this.bold = false,
      this.color});
  final String text;
  final int flex;
  final bool right;
  final bool bold;
  final Color? color;
  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        child: Text(text,
            textAlign: right ? TextAlign.right : TextAlign.left,
            style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
      );
}

/// PDF + CSV action buttons for an AppBar.
///
/// Pressing always does something — when [enabled] is false the button
/// surfaces a snackbar instead of going dead, so the user always sees
/// feedback. The icons render with the AppBar's `onPrimary` color (white on
/// the primary blue) and are slightly upsized so they "pop" without the
/// filled-tonal pill that previously wrapped them.
class LedgerExportActions extends StatelessWidget {
  const LedgerExportActions({
    super.key,
    required this.onExportPdf,
    required this.onExportCsv,
    this.enabled = true,
    this.disabledMessage = 'Nothing to export yet.',
  });

  final Future<void> Function() onExportPdf;
  final Future<void> Function() onExportCsv;
  final bool enabled;
  final String disabledMessage;

  void _notify(BuildContext context) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(disabledMessage)),
      );

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onPrimary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Export PDF',
        icon: const Icon(Icons.picture_as_pdf, size: 26),
        color: fg,
        onPressed: enabled ? onExportPdf : () => _notify(context),
      ),
      IconButton(
        tooltip: 'Export CSV',
        icon: const Icon(Icons.file_download, size: 26),
        color: fg,
        onPressed: enabled ? onExportCsv : () => _notify(context),
      ),
      const SizedBox(width: 4),
    ]);
  }
}

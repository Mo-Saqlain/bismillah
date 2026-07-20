import 'package:intl/intl.dart';

final _money = NumberFormat.currency(
  locale: 'en_PK',
  symbol: 'Rs ',
  decimalDigits: 0,
);

String fmtMoney(num? v) {
  if (v == null) return '—';
  return _money.format(v);
}

String fmtSignedMoney(num v) {
  final s = fmtMoney(v.abs());
  return v < 0 ? '-$s' : s;
}

/// Compact money formatter for chart axis labels — keeps the rupee symbol
/// but collapses thousands/lakhs/millions into 1k / 1.2L / 1.5M shorthand
/// so axis labels never overflow.
String fmtCompactMoney(num v) {
  final neg = v < 0;
  final abs = v.abs();
  String body;
  if (abs >= 1e7) {
    body = '${(abs / 1e7).toStringAsFixed(abs >= 1e8 ? 0 : 1)}Cr';
  } else if (abs >= 1e5) {
    body = '${(abs / 1e5).toStringAsFixed(abs >= 1e6 ? 0 : 1)}L';
  } else if (abs >= 1e3) {
    body = '${(abs / 1e3).toStringAsFixed(abs >= 1e4 ? 0 : 1)}k';
  } else {
    body = abs.toStringAsFixed(0);
  }
  return '${neg ? '-' : ''}Rs $body';
}

final _date = DateFormat('dd MMM yyyy');
final _dateTime = DateFormat('dd MMM yyyy · hh:mm a');

String fmtDate(DateTime d) => _date.format(d.toLocal());
String fmtDateTime(DateTime d) => _dateTime.format(d.toLocal());

import 'package:flutter/services.dart';

/// Live thousands-separator formatter for money entry fields (e.g. turns
/// `1000000` into `1,000,000` as the user types), preserving the caret
/// position and any decimal part. Used by every rupee input in the app so
/// large amounts stay readable. Read the value back with
/// `double.tryParse(controller.text.replaceAll(',', ''))`.
class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  const ThousandsSeparatorInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    if (raw.isEmpty) return newValue;

    final cursor = newValue.selection.baseOffset.clamp(0, raw.length);
    var digitsBeforeCursor = 0;
    for (var i = 0; i < cursor; i++) {
      final ch = raw[i];
      if (ch != ',' && ch != '.') digitsBeforeCursor++;
    }

    final stripped = raw.replaceAll(',', '');
    final dotIdx = stripped.indexOf('.');
    final intPart = dotIdx == -1 ? stripped : stripped.substring(0, dotIdx);
    final fracPart = dotIdx == -1 ? '' : stripped.substring(dotIdx);

    final grouped = groupThousands(intPart);
    final formatted = '$grouped$fracPart';

    var newCursor = formatted.length;
    var seen = 0;
    for (var i = 0; i < formatted.length; i++) {
      final ch = formatted[i];
      if (ch != ',' && ch != '.') seen++;
      if (seen >= digitsBeforeCursor) {
        newCursor = i + 1;
        break;
      }
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: newCursor),
    );
  }

  static String groupThousands(String digits) {
    if (digits.isEmpty) return '';
    final buf = StringBuffer();
    final n = digits.length;
    for (var i = 0; i < n; i++) {
      final fromRight = n - i;
      buf.write(digits[i]);
      if (fromRight > 1 && fromRight % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }
}

/// Initial text for a money field, comma-grouped, so a prefilled amount
/// (e.g. an existing budget) shows formatted before the user touches it.
/// Drops a trailing `.0` so `1000000.0` reads as `1,000,000`. Returns `''`
/// for null.
String moneyInputText(num? value) {
  if (value == null) return '';
  var s = value.toString();
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  final dotIdx = s.indexOf('.');
  final intPart = dotIdx == -1 ? s : s.substring(0, dotIdx);
  final fracPart = dotIdx == -1 ? '' : s.substring(dotIdx);
  return '${ThousandsSeparatorInputFormatter.groupThousands(intPart)}$fracPart';
}

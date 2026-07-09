import 'package:url_launcher/url_launcher.dart';

/// WhatsApp deep-linking for the post-transaction "send a confirmation"
/// prompt. There is no WhatsApp Business API here — we open WhatsApp with a
/// pre-filled message via a `wa.me` link and let the operator tap send.
///
/// Numbers are entered locally (e.g. `0300 1234567`) but `wa.me` needs the
/// full international form with no `+` and no leading `0`. We default the
/// country code to Pakistan (92) since the app is PKR / Pakistan-based; a
/// number already carrying a country code is passed through untouched.
String? normalizeWhatsAppNumber(String? raw, {String defaultCountryCode = '92'}) {
  if (raw == null) return null;
  var d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return null;
  // 0092xxxxxxxxxx → strip the international-access 00.
  if (d.startsWith('00')) d = d.substring(2);
  // Already starts with the country code → assume full international form.
  if (d.startsWith(defaultCountryCode) &&
      d.length >= defaultCountryCode.length + 10) {
    return d;
  }
  // Local trunk form 03xxxxxxxxx → drop the 0, prepend country code.
  if (d.startsWith('0')) return '$defaultCountryCode${d.substring(1)}';
  // 10-digit mobile without the trunk 0 (3xxxxxxxxx) → prepend country code.
  if (d.length == 10 && d.startsWith('3')) return '$defaultCountryCode$d';
  // Anything else: assume it already includes a country code.
  return d;
}

/// Opens WhatsApp (app or web) with [message] pre-filled to [number].
/// Returns false if the number is unusable or no handler could be launched.
Future<bool> launchWhatsApp({
  required String number,
  required String message,
}) async {
  final n = normalizeWhatsAppNumber(number);
  if (n == null) return false;
  final uri = Uri.parse('https://wa.me/$n?text=${Uri.encodeComponent(message)}');
  if (!await canLaunchUrl(uri)) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

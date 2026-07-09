import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Lightweight CSV emitter + share helper. RFC 4180 quoting for any field
/// containing comma / quote / newline.
class CsvExport {
  static String build({
    required List<String> headers,
    required List<List<Object?>> rows,
  }) {
    final sb = StringBuffer()
      ..writeln(headers.map(_escape).join(','));
    for (final row in rows) {
      sb.writeln(row.map((v) => _escape(v?.toString() ?? '')).join(','));
    }
    return sb.toString();
  }

  /// Writes `csv` to a temp file under the system cache and triggers the
  /// platform share sheet so the user can save / send it anywhere.
  static Future<void> share({
    required String fileName,
    required String csv,
    String? subject,
  }) async {
    final dir = await getTemporaryDirectory();
    final safe = fileName.replaceAll(RegExp(r'[^\w\-]+'), '_');
    final path = p.join(dir.path, '$safe.csv');
    await File(path).writeAsString(csv, flush: true);
    await Share.shareXFiles([XFile(path)], subject: subject ?? safe);
  }

  static String _escape(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }
}

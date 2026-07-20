import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
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

  /// On mobile, writes `csv` to a temp file and opens the platform share
  /// sheet. On desktop (Windows/Linux/macOS) there is no share sheet, so a
  /// native "Save As" dialog is shown instead and the file is written to the
  /// location the user picks. Returns silently if the user cancels the dialog.
  static Future<void> share({
    required String fileName,
    required String csv,
    String? subject,
  }) async {
    final safe = fileName.replaceAll(RegExp(r'[^\w\-]+'), '_');

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: subject ?? 'Save CSV',
        fileName: '$safe.csv',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        // Some Windows builds of file_picker require the bytes up front.
        bytes: Uint8List.fromList(csv.codeUnits),
      );
      if (path == null) return; // user cancelled
      // saveFile with `bytes` already writes the file on desktop; guard for
      // platforms where it only returns the chosen path.
      final f = File(path);
      if (!await f.exists() || (await f.length()) == 0) {
        await f.writeAsString(csv, flush: true);
      }
      return;
    }

    final dir = await getTemporaryDirectory();
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

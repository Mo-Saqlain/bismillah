import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/error_reporter.dart';
import '../../core/formatters.dart';

/// Shows the in-memory error log captured by [ErrorReporter] during this
/// app session. Designed for the trial week so the user can collect
/// failures and forward the details (long-press to copy) without needing
/// adb / logcat / devtools.
///
/// Cleared on every cold start since the buffer is in-memory only.
class RecentErrorsScreen extends StatelessWidget {
  const RecentErrorsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recent Errors'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear error log?'),
                  content: const Text(
                      'Removes every entry from the in-memory list. '
                      'This does not affect your accounting data.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Clear')),
                  ],
                ),
              );
              if (ok == true) ErrorReporter.clear();
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<List<ErrorRecord>>(
        valueListenable: ErrorReporter.recent,
        builder: (context, errors, _) {
          if (errors.isEmpty) {
            return const _Empty();
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: errors.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => _ErrorTile(record: errors[i]),
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('No errors recorded this session.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Framework crashes, async errors and broken widget builds will '
              'appear here as they happen.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile({required this.record});
  final ErrorRecord record;

  @override
  Widget build(BuildContext context) {
    final firstLine = record.message.split('\n').first;
    return ExpansionTile(
      leading: Icon(Icons.error_outline,
          color: Theme.of(context).colorScheme.error),
      title: Text(
        firstLine,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Text(
        '${fmtDateTime(record.timestamp)}'
        '${record.source != null ? '  ·  ${record.source}' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (record.message.contains('\n')) ...[
          const _SectionLabel('Message'),
          SelectableText(
            record.message,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 8),
        ],
        if (record.stack != null) ...[
          const _SectionLabel('Stack'),
          SelectableText(
            record.stack!,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy full report'),
            onPressed: () {
              final buf = StringBuffer()
                ..writeln('Time: ${record.timestamp.toIso8601String()}')
                ..writeln('Source: ${record.source ?? '-'}')
                ..writeln()
                ..writeln(record.message);
              if (record.stack != null) {
                buf
                  ..writeln()
                  ..writeln('Stack:')
                  ..writeln(record.stack);
              }
              Clipboard.setData(ClipboardData(text: buf.toString()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Error report copied')),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

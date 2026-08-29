import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/data/models/bank.dart';
import 'package:bismillah_constructions/shared/data/models/change_log.dart';
import 'package:bismillah_constructions/shared/data/models/party.dart';
import 'package:bismillah_constructions/shared/data/models/project.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/mobile/features/common/async_view.dart';

/// Plain-language activity log.
///
/// The earlier screen displayed each row as `Deleted · journal_entry · Entity:
/// {uuid}` which was unreadable. This rewrite resolves IDs against the live
/// project/supplier/bank tables, parses transaction payloads to extract the
/// amount and account names, and groups entries into "Today / Yesterday /
/// Earlier this week / Older" sections so the user can scan recent activity
/// at a glance. The raw JSON is still accessible by tapping an entry, for
/// when an audit trail is needed.
class ChangeLogScreen extends ConsumerWidget {
  const ChangeLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUser = ref.watch(currentUserProvider);
    final isSuperuser = currentUser?.isAdmin == true;

    if (!isSuperuser) {
      return Scaffold(
        appBar: AppBar(title: const Text('Activity Log')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outlined, size: 64, color: Colors.red),
              SizedBox(height: 16),
              Text(
                'Access Restricted',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.red),
              ),
              SizedBox(height: 8),
              Text(
                'Only the superuser (admin) has access to the Change Log.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    final bundle = ref.watch(_changeLogBundleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity Log'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.download, size: 26),
            onPressed: () async {
              final b = await ref.read(_changeLogBundleProvider.future);
              await _exportCsv(b);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AsyncView<_LogBundle>(
        value: bundle,
        data: (b) {
          if (b.entries.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'Nothing here yet. New transactions, edits, deletions '
                    'and archives will show up here.'),
              ),
            );
          }
          final groups = _groupByDate(b.entries);
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: groups.length,
            itemBuilder: (_, i) => _DateSection(
              title: groups[i].title,
              entries: groups[i].entries,
              bundle: b,
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- export

  Future<void> _exportCsv(_LogBundle b) async {
    final buf = StringBuffer();
    buf.writeln('timestamp,action,what,details,note,device');
    for (final c in b.entries) {
      final summary = _humanize(c, b);
      buf.writeln([
        _csv(c.timestamp.toIso8601String()),
        _csv(c.action.label),
        _csv(summary.title),
        _csv(summary.subtitle),
        _csv(c.note ?? ''),
        _csv(c.deviceId ?? ''),
      ].join(','));
    }
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final file = File(p.join(dir.path, 'activity_log_$stamp.csv'));
    await file.writeAsString(buf.toString());
    await Share.shareXFiles([XFile(file.path)],
        text: 'Bismillah activity log');
  }

  String _csv(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  // -------------------------------------------------------------- grouping

  List<_DateGroup> _groupByDate(List<ChangeLog> entries) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekAgo = today.subtract(const Duration(days: 7));

    final tToday = <ChangeLog>[];
    final tYesterday = <ChangeLog>[];
    final tWeek = <ChangeLog>[];
    final tOlder = <ChangeLog>[];

    for (final e in entries) {
      final local = e.timestamp.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (day == today) {
        tToday.add(e);
      } else if (day == yesterday) {
        tYesterday.add(e);
      } else if (day.isAfter(weekAgo)) {
        tWeek.add(e);
      } else {
        tOlder.add(e);
      }
    }

    return [
      if (tToday.isNotEmpty) _DateGroup('Today', tToday),
      if (tYesterday.isNotEmpty) _DateGroup('Yesterday', tYesterday),
      if (tWeek.isNotEmpty) _DateGroup('Earlier this week', tWeek),
      if (tOlder.isNotEmpty) _DateGroup('Older', tOlder),
    ];
  }
}

/// Lazily-resolved bundle: every change-log row plus the entity tables we
/// need to translate ids → names. Loaded as a single FutureProvider so the
/// UI only repaints once everything is available.
class _LogBundle {
  final List<ChangeLog> entries;
  final Map<String, Project> projects;
  final Map<String, Party> suppliers;
  final Map<String, Bank> banks;

  const _LogBundle({
    required this.entries,
    required this.projects,
    required this.suppliers,
    required this.banks,
  });
}

final _changeLogBundleProvider = FutureProvider<_LogBundle>((ref) async {
  ref.watch(ledgerVersionProvider);
  final entityRepo = await ref.watch(entityRepoProvider.future);
  // Pull EVERY row (including archived) so a "Project: <name>" lookup
  // resolves even after the project itself has been archived.
  final entries = await entityRepo.changeLog();
  final projects = await entityRepo.projects(includeArchived: true);
  final suppliers = await entityRepo.suppliers(includeArchived: true);
  final banks = await entityRepo.banks(includeArchived: true);
  return _LogBundle(
    entries: entries,
    projects: {for (final p in projects) p.id: p},
    suppliers: {for (final s in suppliers) s.id: s},
    banks: {for (final b in banks) b.id: b},
  );
});

class _DateGroup {
  final String title;
  final List<ChangeLog> entries;
  const _DateGroup(this.title, this.entries);
}

class _DateSection extends StatelessWidget {
  const _DateSection({
    required this.title,
    required this.entries,
    required this.bundle,
  });

  final String title;
  final List<ChangeLog> entries;
  final _LogBundle bundle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Text(title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700)),
        ),
        for (final e in entries) _LogTile(entry: e, bundle: bundle),
      ],
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry, required this.bundle});
  final ChangeLog entry;
  final _LogBundle bundle;

  @override
  Widget build(BuildContext context) {
    final summary = _humanize(entry, bundle);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor:
                summary.tint?.withValues(alpha: 0.15) ?? scheme.surfaceContainerHighest,
            child: Icon(summary.icon,
                color: summary.tint ?? scheme.onSurfaceVariant),
          ),
          title: Text(summary.title,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (summary.subtitle.isNotEmpty) Text(summary.subtitle),
              Text(_relativeTime(entry.timestamp),
                  style: Theme.of(context).textTheme.bodySmall),
              if (entry.note != null && entry.note!.isNotEmpty)
                Text('Note: ${entry.note}',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          isThreeLine: entry.note != null && entry.note!.isNotEmpty,
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _showDetail(context, entry, summary),
        ),
      ),
    );
  }

  String _relativeTime(DateTime ts) {
    final now = DateTime.now();
    final diff = now.difference(ts.toLocal());
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return fmtDateTime(ts);
  }

  void _showDetail(BuildContext context, ChangeLog c, _Summary summary) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(summary.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(summary.subtitle),
              const SizedBox(height: 8),
              Text('Action: ${c.action.label}'),
              Text('When: ${fmtDateTime(c.timestamp)}'),
              if (c.note != null && c.note!.isNotEmpty)
                Text('Note: ${c.note}'),
              if (c.deviceId != null)
                Text('Device: ${c.deviceId!.substring(0, 8)}…'),
              if (c.originalData != null) ...[
                const SizedBox(height: 12),
                const Text('Before:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _RawJson(raw: c.originalData!),
              ],
              if (c.newData != null) ...[
                const SizedBox(height: 12),
                const Text('After:',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _RawJson(raw: c.newData!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _RawJson extends StatelessWidget {
  const _RawJson({required this.raw});
  final String raw;

  String _pretty() {
    try {
      final parsed = jsonDecode(raw);
      const pp = JsonEncoder.withIndent('  ');
      return pp.convert(parsed);
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(_pretty(),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
    );
  }
}

// ------------------------------------------------------------- humanizing

class _Summary {
  final IconData icon;
  final Color? tint;
  /// First line — what entity, what name. e.g. `Deleted project: Plot 17`.
  final String title;
  /// Second line — extra context (amount, accounts, etc.).
  final String subtitle;
  const _Summary({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
  });
}

_Summary _humanize(ChangeLog c, _LogBundle b) {
  final action = c.action;
  final actionWord = switch (action) {
    ChangeAction.create => 'Added',
    ChangeAction.delete => 'Deleted',
    ChangeAction.restore => 'Restored',
    ChangeAction.archive => 'Archived',
    ChangeAction.unarchive => 'Unarchived',
    ChangeAction.edit => 'Edited',
  };

  // Per-entity formatting. We resolve the friendly name from the bundle
  // tables; if the entity is gone (e.g. hard-deleted), we surface the id
  // truncated so it's still recognisable in the audit trail.
  switch (c.entityType) {
    case 'project':
      final name = b.projects[c.entityId]?.name ?? 'Project ${_short(c.entityId)}';
      return _Summary(
        icon: _iconFor(action, fallback: Icons.foundation),
        tint: _tintFor(action),
        title: '$actionWord project: $name',
        subtitle: _projectExtra(c, b),
      );
    case 'supplier':
      final name = b.suppliers[c.entityId]?.name ?? 'Supplier ${_short(c.entityId)}';
      return _Summary(
        icon: _iconFor(action, fallback: Icons.local_shipping),
        tint: _tintFor(action),
        title: '$actionWord supplier: $name',
        subtitle: '',
      );
    case 'bank':
      final name = b.banks[c.entityId]?.name ?? 'Bank ${_short(c.entityId)}';
      return _Summary(
        icon: _iconFor(action, fallback: Icons.account_balance),
        tint: _tintFor(action),
        title: '$actionWord bank/wallet: $name',
        subtitle: '',
      );
    case 'journal_entry':
      // Creation stores the payload in new_data; edits/deletes store the
      // prior state in original_data — decode whichever is present.
      final txn = _decodeTxn(c.originalData ?? c.newData);
      return _Summary(
        icon: _iconFor(action, fallback: Icons.receipt_long),
        tint: _tintFor(action),
        title: '$actionWord transaction'
            '${txn.amount > 0 ? ' (Rs ${txn.amount.toStringAsFixed(0)})' : ''}',
        subtitle: txn.summary,
      );
    default:
      return _Summary(
        icon: _iconFor(action, fallback: Icons.history),
        tint: _tintFor(action),
        title: '$actionWord ${c.entityType}',
        subtitle: 'ID: ${_short(c.entityId)}',
      );
  }
}

String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);

IconData _iconFor(ChangeAction action, {required IconData fallback}) {
  return switch (action) {
    ChangeAction.create => Icons.add_circle_outline,
    ChangeAction.delete => Icons.delete_outline,
    ChangeAction.restore => Icons.restore,
    ChangeAction.archive => Icons.archive_outlined,
    ChangeAction.unarchive => Icons.unarchive_outlined,
    ChangeAction.edit => fallback,
  };
}

Color? _tintFor(ChangeAction action) {
  // Returns null = neutral. Creations are green (new), destructive actions
  // red, restorative ones blue (per the app's blue palette convention).
  return switch (action) {
    ChangeAction.create => Colors.green.shade600,
    ChangeAction.delete => Colors.red.shade400,
    ChangeAction.archive => Colors.orange.shade600,
    ChangeAction.restore || ChangeAction.unarchive => Colors.blue.shade600,
    ChangeAction.edit => null,
  };
}

String _projectExtra(ChangeLog c, _LogBundle b) {
  // For project edits, surface the model + status if we have it on hand.
  final p = b.projects[c.entityId];
  if (p == null) return '';
  return '${p.model.label} · ${p.status.label}';
}

class _TxnSummary {
  final double amount;
  final String summary;
  const _TxnSummary({required this.amount, required this.summary});
}

/// Pulls the amount and a short human description out of the JSON payload
/// stored on a transaction's change-log entry. The payload is either a list
/// (soft/hard delete writes a list of both rows) or a single map. Failures
/// fall back to an empty summary so the UI still renders.
_TxnSummary _decodeTxn(String? raw) {
  if (raw == null || raw.isEmpty) {
    return const _TxnSummary(amount: 0, summary: '');
  }
  try {
    final parsed = jsonDecode(raw);
    final rows = parsed is List
        ? parsed.cast<Map<String, dynamic>>()
        : [parsed as Map<String, dynamic>];
    if (rows.isEmpty) return const _TxnSummary(amount: 0, summary: '');

    // Pick the debit row (debit > 0) so we name the cost-side account.
    final dr = rows.firstWhere(
      (r) => ((r['debit'] as num?) ?? 0) > 0,
      orElse: () => rows.first,
    );
    final amount = ((dr['debit'] as num?) ?? (dr['credit'] as num?) ?? 0)
        .toDouble();
    final accountId = dr['account_id'] as String?;
    final desc = dr['description'] as String?;
    final accountName =
        accountId == null ? null : Accounts.byId(accountId).name;

    final parts = <String>[
      ?accountName,
      if (desc != null && desc.isNotEmpty) desc,
    ];
    return _TxnSummary(amount: amount, summary: parts.join(' · '));
  } catch (_) {
    return const _TxnSummary(amount: 0, summary: '');
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/export/csv_export.dart';
import 'package:bismillah_constructions/shared/core/export/pdf_generator.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/data/models/project.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

/// Key for the trial-balance query family: which project (null = all) and
/// how to group.
@immutable
class _TbKey {
  const _TbKey(this.projectId, this.groupBy);
  final String? projectId;
  final MaterialTrialGroupBy groupBy;

  @override
  bool operator ==(Object other) =>
      other is _TbKey &&
      other.projectId == projectId &&
      other.groupBy == groupBy;

  @override
  int get hashCode => Object.hash(projectId, groupBy);
}

final _tbProvider =
    FutureProvider.family<List<MaterialTrialRow>, _TbKey>((ref, key) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.materialTrialBalance(
      projectId: key.projectId, groupBy: key.groupBy);
});

String _qtyText(MaterialTrialRow r) {
  if (r.quantity == 0) return '—';
  final q = r.quantity;
  final s = q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);
  return r.unit.isEmpty ? s : '$s ${r.unit}';
}

/// Material Trial Balance: project-wise quantity + amount spent on each
/// material (or supplier). Exports to CSV / PDF.
class TrialBalanceScreen extends ConsumerStatefulWidget {
  const TrialBalanceScreen({super.key});

  @override
  ConsumerState<TrialBalanceScreen> createState() => _TrialBalanceScreenState();
}

class _TrialBalanceScreenState extends ConsumerState<TrialBalanceScreen> {
  String? _projectId; // null = all projects
  MaterialTrialGroupBy _groupBy = MaterialTrialGroupBy.material;

  String _scopeLabel(List<Project> projects) {
    if (_projectId == null) return 'All projects';
    for (final p in projects) {
      if (p.id == _projectId) return p.name;
    }
    return 'Selected project';
  }

  Future<void> _exportCsv(List<MaterialTrialRow> rows, String scope) async {
    final keyHeader =
        _groupBy == MaterialTrialGroupBy.material ? 'Material' : 'Supplier';
    final total = rows.fold<double>(0, (a, r) => a + r.amount);
    final csv = CsvExport.build(
      headers: ['Project', keyHeader, 'Unit', 'Quantity', 'Amount'],
      rows: [
        for (final r in rows)
          [
            r.projectName,
            r.label,
            r.unit,
            r.quantity == 0 ? '' : r.quantity,
            r.amount,
          ],
        ['', '', '', 'TOTAL', total],
      ],
    );
    await CsvExport.share(
        fileName: 'trial_balance_$scope', csv: csv, subject: 'Trial Balance');
  }

  Future<void> _exportPdf(List<MaterialTrialRow> rows, String scope) async {
    await PdfGenerator.previewTrialBalance(
      scope: scope,
      groupBy: _groupBy,
      rows: rows,
      generatedAt: DateTime.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsProvider);
    final projects = projectsAsync.asData?.value ?? const <Project>[];
    final data = ref.watch(_tbProvider(_TbKey(_projectId, _groupBy)));
    final scope = _scopeLabel(projects);
    final byMaterial = _groupBy == MaterialTrialGroupBy.material;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trial Balance'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.table_view_outlined),
            onPressed: () {
              final rows = data.asData?.value;
              if (rows != null && rows.isNotEmpty) _exportCsv(rows, scope);
            },
          ),
          IconButton(
            tooltip: 'Export PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: () {
              final rows = data.asData?.value;
              if (rows != null && rows.isNotEmpty) _exportPdf(rows, scope);
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _controls(projects),
          const Divider(height: 1),
          Expanded(
            child: data.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Failed to load: $e')),
              data: (rows) => rows.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No material purchases recorded for this scope yet.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : _table(rows, byMaterial),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(List<Project> projects) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 20,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Project: ', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              DropdownButton<String?>(
                value: _projectId,
                onChanged: (v) => setState(() => _projectId = v),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All projects')),
                  for (final p in projects)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Group by: ',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              SegmentedButton<MaterialTrialGroupBy>(
                segments: const [
                  ButtonSegment(
                    value: MaterialTrialGroupBy.material,
                    label: Text('Material'),
                    icon: Icon(Icons.category_outlined),
                  ),
                  ButtonSegment(
                    value: MaterialTrialGroupBy.supplier,
                    label: Text('Supplier'),
                    icon: Icon(Icons.handshake_outlined),
                  ),
                ],
                selected: {_groupBy},
                onSelectionChanged: (s) => setState(() => _groupBy = s.first),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _table(List<MaterialTrialRow> rows, bool byMaterial) {
    // rows already ordered by project name then amount desc — group in order.
    final grouped = <String, List<MaterialTrialRow>>{};
    for (final r in rows) {
      grouped.putIfAbsent(r.projectName, () => []).add(r);
    }
    final grandTotal = rows.fold<double>(0, (a, r) => a + r.amount);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        for (final entry in grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 4),
            child: Row(
              children: [
                Icon(Icons.apartment_outlined, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(entry.key,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                Text(
                  fmtMoney(entry.value.fold<double>(0, (a, r) => a + r.amount)),
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: scheme.primary),
                ),
              ],
            ),
          ),
          _headerRow(byMaterial),
          for (final r in entry.value) _dataRow(r),
          const Divider(),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text('Grand total: ${fmtMoney(grandTotal)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _headerRow(bool byMaterial) {
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text(byMaterial ? 'MATERIAL' : 'SUPPLIER', style: style)),
          Expanded(
              flex: 2,
              child: Text('QUANTITY', style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('AMOUNT', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _dataRow(MaterialTrialRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text(r.label, overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 2,
              child: Text(_qtyText(r), textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text(fmtMoney(r.amount),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

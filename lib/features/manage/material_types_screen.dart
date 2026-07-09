import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/material_type_def.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';

/// Lets the user manage the categories that appear in the Buy Material
/// transaction form, plus their procurement metadata (UOM class, unit,
/// coverage rate, physical dimensions).
///
/// Built-in rows (the original five seeded by the v7 migration) can be
/// renamed and have their metadata edited but cannot be deleted —
/// historical inventory references their label and we don't want a
/// dropdown that silently drops legacy data.
class MaterialTypesScreen extends ConsumerWidget {
  const MaterialTypesScreen({super.key});

  Future<void> _addOrEdit(
      BuildContext context, WidgetRef ref, MaterialTypeDef? existing) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<MaterialTypeDef>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MaterialTypeForm(initial: existing),
    );
    if (result == null) return;
    final repo = await ref.read(entityRepoProvider.future);
    try {
      if (existing == null) {
        await repo.addMaterialType(
          result.name,
          uomType: result.uomType,
          uom: result.uom,
          coverageRate: result.coverageRate,
          dims: result.dims,
        );
      } else {
        await repo.updateMaterialType(
          existing.id,
          name: result.name,
          uomType: result.uomType,
          uom: result.uom,
          coverageRate: result.coverageRate,
          dims: result.dims,
        );
      }
      bumpLedger(ref);
      messenger.showSnackBar(SnackBar(
          content:
              Text(existing == null ? 'Added "${result.name}".' : 'Saved.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, MaterialTypeDef row) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${row.name}"?'),
        content: const Text(
            'This removes the option from the Buy Material dropdown. '
            'Past purchases keep the label they were saved with.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final repo = await ref.read(entityRepoProvider.future);
    await repo.deleteMaterialType(row.id);
    bumpLedger(ref);
    messenger.showSnackBar(SnackBar(content: Text('Deleted "${row.name}".')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(materialTypesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Material Types'),
        actions: [
          IconButton(
            tooltip: 'Add type',
            icon: const Icon(Icons.add, size: 26),
            onPressed: () => _addOrEdit(context, ref, null),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AsyncView<List<MaterialTypeDef>>(
        value: typesAsync,
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No material types yet. Tap + to add one (e.g. "Sand").'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final r = rows[i];
              return Card(
                child: ListTile(
                  isThreeLine: r.uomType != null || r.uom != null,
                  leading: const CircleAvatar(
                    child: Icon(Icons.category_outlined),
                  ),
                  title: Text(r.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: _SubtitleSummary(row: r),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _addOrEdit(context, ref, r),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(context, ref, r),
                      ),
                    ],
                  ),
                  onTap: () => _addOrEdit(context, ref, r),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add type'),
      ),
    );
  }
}

/// Compact one-liner under the title — gives a procurement-fingerprint at
/// a glance. Spelled out: "Built-in · Surface · Square Feet · coverage 4.0".
class _SubtitleSummary extends StatelessWidget {
  const _SubtitleSummary({required this.row});
  final MaterialTypeDef row;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (row.uomType != null) row.uomType!.label,
      if (row.uom != null && row.uom!.isNotEmpty) row.uom!,
      if (row.coverageRate != null) 'coverage ${row.coverageRate}',
    ];
    if (parts.isEmpty) return const Text('No measurement details');
    return Text(parts.join(' · '),
        maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}

/// Bottom-sheet form. Gathers a return value (a [MaterialTypeDef] used purely
/// as a transport record — `id`, `isBuiltin`, `sortOrder`, `createdAt` are
/// placeholders the caller ignores when updating an existing row).
class _MaterialTypeForm extends StatefulWidget {
  const _MaterialTypeForm({this.initial});
  final MaterialTypeDef? initial;

  @override
  State<_MaterialTypeForm> createState() => _MaterialTypeFormState();
}

class _MaterialTypeFormState extends State<_MaterialTypeForm> {
  late final TextEditingController _name;
  late final TextEditingController _uom;
  late final TextEditingController _cov;
  late final TextEditingController _dimL;
  late final TextEditingController _dimW;
  late final TextEditingController _dimH;
  late final TextEditingController _dimUnit;

  UomType? _uomType;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _name = TextEditingController(text: r?.name ?? '');
    _uom = TextEditingController(text: r?.uom ?? '');
    _cov = TextEditingController(
        text: r?.coverageRate?.toString() ?? '');
    _dimL = TextEditingController(text: r?.dims?.length?.toString() ?? '');
    _dimW = TextEditingController(text: r?.dims?.width?.toString() ?? '');
    _dimH = TextEditingController(text: r?.dims?.height?.toString() ?? '');
    _dimUnit = TextEditingController(text: r?.dims?.unit ?? '');
    _uomType = r?.uomType;
  }

  @override
  void dispose() {
    for (final c in [_name, _uom, _cov, _dimL, _dimW, _dimH, _dimUnit]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Defensive parser: blank → null, junk → null. Keeps the form forgiving.
  double? _parseDouble(TextEditingController c) =>
      double.tryParse(c.text.trim());

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;

    MaterialDims? dims;
    if (_uomType == UomType.discrete) {
      final l = _parseDouble(_dimL);
      final w = _parseDouble(_dimW);
      final h = _parseDouble(_dimH);
      final u = _dimUnit.text.trim();
      if (l != null || w != null || h != null || u.isNotEmpty) {
        dims = MaterialDims(
            length: l, width: w, height: h, unit: u.isEmpty ? null : u);
      }
    }

    Navigator.pop(
      context,
      MaterialTypeDef(
        id: widget.initial?.id ?? '',
        name: name,
        isBuiltin: widget.initial?.isBuiltin ?? false,
        sortOrder: widget.initial?.sortOrder ?? 0,
        createdAt: widget.initial?.createdAt ?? DateTime.now().toUtc(),
        uomType: _uomType,
        uom: _uom.text.trim().isEmpty ? null : _uom.text.trim(),
        coverageRate:
            _uomType == UomType.surface ? _parseDouble(_cov) : null,
        dims: dims,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSurface = _uomType == UomType.surface;
    final isDiscrete = _uomType == UomType.discrete;
    final initial = widget.initial;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(initial == null ? 'New Material Type' : 'Edit Material Type',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name *',
                hintText: 'e.g. Sand, Tiles, Paint',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<UomType?>(
              initialValue: _uomType,
              decoration: const InputDecoration(
                labelText: 'Unit of Measurement Class',
                helperText: 'How this material is measured',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('— None —')),
                ...UomType.values.map((t) => DropdownMenuItem(
                    value: t, child: Text(t.label))),
              ],
              onChanged: (v) => setState(() {
                _uomType = v;
                // Picking a class suggests a default unit if the field
                // was blank — keeps data entry quick without overwriting
                // an existing custom value.
                if (v != null && _uom.text.trim().isEmpty) {
                  _uom.text = v.defaultUoms.first;
                }
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _uom,
              decoration: InputDecoration(
                labelText: 'Unit of Measurement',
                hintText: _uomType == null
                    ? 'Each, Square Feet, Cubic Yards, Pounds, …'
                    : _uomType!.defaultUoms.join(', '),
              ),
            ),
            if (isSurface) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _cov,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Coverage rate',
                  helperText:
                      'Units required per unit of area (Surface only)',
                ),
              ),
            ],
            if (isDiscrete) ...[
              const SizedBox(height: 16),
              Text('Dimensions (optional)',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _DimField(label: 'Length', controller: _dimL)),
                const SizedBox(width: 8),
                Expanded(child: _DimField(label: 'Width', controller: _dimW)),
                const SizedBox(width: 8),
                Expanded(child: _DimField(label: 'Height', controller: _dimH)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _dimUnit,
                    decoration: const InputDecoration(
                      labelText: 'Unit',
                      hintText: 'inch',
                    ),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submit,
              child: Text(initial == null ? 'Create' : 'Save'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _DimField extends StatelessWidget {
  const _DimField({required this.label, required this.controller});
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(labelText: label),
    );
  }
}

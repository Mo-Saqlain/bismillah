import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/money_input.dart';
import '../../data/models/project.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import 'project_reconciliation_screen.dart';
import 'site_snapshot_screen.dart';

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final projects = _showArchived
        ? ref.watch(archivedProjectsProvider)
        : ref.watch(projectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived ? 'Archived Projects' : 'Projects'),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show active' : 'Show archived',
            icon: Icon(_showArchived ? Icons.unarchive : Icons.archive_outlined),
            onPressed: () =>
                setState(() => _showArchived = !_showArchived),
          ),
        ],
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showProjectForm(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New Project'),
            ),
      body: AsyncView(
        value: projects,
        data: (list) {
          if (list.isEmpty) {
            return _Empty(
              icon: Icons.foundation,
              title:
                  _showArchived ? 'No archived projects' : 'No projects yet',
              hint: _showArchived
                  ? 'Archived projects are kept for legal evidence.'
                  : 'Tap "New Project" to add your first construction site.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final p = list[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: p.archived
                        ? Colors.brown.shade100
                        : (p.status == ProjectStatus.active
                            ? Colors.blue.shade100
                            : Colors.grey.shade300),
                    child: Icon(
                      p.archived
                          ? Icons.archive
                          : (p.status == ProjectStatus.active
                              ? Icons.engineering
                              : Icons.lock_outline),
                      color: p.archived
                          ? Colors.brown.shade800
                          : (p.status == ProjectStatus.active
                              ? Colors.blue.shade800
                              : Colors.grey.shade700),
                    ),
                  ),
                  title: Text(p.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration: p.archived
                            ? TextDecoration.lineThrough
                            : null,
                      )),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${p.model.label} · ${p.status.label}'
                          '${p.archived ? ' · ARCHIVED' : ''}'),
                      if (p.clientName != null)
                        Text('Client: ${p.clientName}',
                            style: const TextStyle(fontSize: 12)),
                      if (p.siteAddress != null)
                        Text(p.siteAddress!,
                            style: const TextStyle(fontSize: 12)),
                      if (p.budget != null)
                        Text('Budget: ${fmtMoney(p.budget!)}',
                            style: const TextStyle(fontSize: 12)),
                      if (p.model == ProjectModel.labourRate &&
                          (p.serviceFeeType == ServiceFeeType.fixed
                              ? p.serviceFeeAmount != null
                              : p.serviceFeePercent != null))
                        Text(
                            p.serviceFeeType == ServiceFeeType.fixed
                                ? 'Service Fee: ${fmtMoney(p.serviceFeeAmount ?? 0)} (fixed)'
                                : 'Service Fee: ${p.serviceFeePercent!.toStringAsFixed(2)}%',
                            style: const TextStyle(fontSize: 12)),
                      if (p.whatsapp != null && p.whatsapp!.isNotEmpty)
                        Text('WhatsApp: ${p.whatsapp}',
                            style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                  isThreeLine:
                      p.siteAddress != null || p.budget != null,
                  trailing: Text(fmtDate(p.createdAt),
                      style: Theme.of(context).textTheme.bodySmall),
                  onTap: () => _showProjectActions(context, ref, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showProjectActions(BuildContext context, WidgetRef ref, project) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.dashboard_outlined),
              title: const Text('Open snapshot'),
              subtitle: const Text(
                  'Budget vs spend, forecast, completion, notes, follow-ups'),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SiteSnapshotScreen(project: project)),
                );
              },
            ),
            if (!project.archived)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _showProjectEditForm(context, ref, project);
                },
              ),
            if (!project.archived)
              ListTile(
                leading: Icon(project.status == ProjectStatus.active
                    ? Icons.lock
                    : Icons.lock_open),
                title: Text(project.status == ProjectStatus.active
                    ? 'Mark as Closed'
                    : 'Reopen'),
                onTap: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.updateProjectStatus(
                      project.id,
                      project.status == ProjectStatus.active
                          ? ProjectStatus.closed
                          : ProjectStatus.active);
                  bumpLedger(ref);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
              ),
            if (!project.archived)
              ListTile(
                leading: const Icon(Icons.balance),
                title: const Text('Reconcile & Archive'),
                subtitle: const Text(
                    'Run reconciliation check, then archive (preserves data)'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProjectReconciliationScreen(project: project),
                    ),
                  );
                },
              ),
            if (project.archived)
              ListTile(
                leading: const Icon(Icons.unarchive),
                title: const Text('Unarchive'),
                onTap: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.unarchiveProject(project.id);
                  bumpLedger(ref);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
              ),
          ],
        ),
      ),
    );
  }

}

void _showProjectForm(BuildContext context, WidgetRef ref) {
  final nameCtrl = TextEditingController();
  final clientCtrl = TextEditingController();
  final siteCtrl = TextEditingController();
  final budgetCtrl = TextEditingController();
  final managerCtrl = TextEditingController();
  final whatsappCtrl = TextEditingController();
  final serviceFeeCtrl = TextEditingController();
  final feeAmountCtrl = TextEditingController();
  ProjectModel model = ProjectModel.withMaterial;
  ServiceFeeType feeType = ServiceFeeType.percent;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: StatefulBuilder(
        builder: (ctx, setSheetState) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('New Project',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration:
                      const InputDecoration(labelText: 'Project name *'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ProjectModel>(
                  initialValue: model,
                  decoration: const InputDecoration(labelText: 'Model'),
                  items: ProjectModel.values
                      .map((m) =>
                          DropdownMenuItem(value: m, child: Text(m.label)))
                      .toList(),
                  onChanged: (v) => setSheetState(() => model = v ?? model),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: clientCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Client name (optional)',
                      helperText:
                          'Free text — there is no separate client/customer entity'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: siteCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Site address (optional)'),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: budgetCtrl,
                  decoration: InputDecoration(
                    // With-Material projects rely on budget for PoC revenue
                    // recognition, loss provision, the at-risk threshold,
                    // BvA reports and the archive gate — so it's required.
                    // Labour-Rate doesn't need it (the customer's deposits
                    // fund the spend, no contract cap).
                    labelText: model == ProjectModel.withMaterial
                        ? 'Contract value (budget) *'
                        : 'Budget (optional)',
                    prefixText: 'Rs ',
                    helperText: model == ProjectModel.withMaterial
                        ? 'Required: what the customer has agreed to pay'
                        : 'Optional planning ceiling',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    const ThousandsSeparatorInputFormatter(),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: managerCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Project manager (optional)'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: whatsappCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Client WhatsApp number (optional)',
                    helperText:
                        'Used to send a confirmation on money received from this project',
                    prefixIcon: Icon(Icons.chat_outlined),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                if (model == ProjectModel.labourRate) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Service Fee (Labour-Rate)',
                        style: Theme.of(ctx).textTheme.labelLarge),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<ServiceFeeType>(
                    segments: const [
                      ButtonSegment(
                          value: ServiceFeeType.percent,
                          label: Text('Percentage'),
                          icon: Icon(Icons.percent)),
                      ButtonSegment(
                          value: ServiceFeeType.fixed,
                          label: Text('Fixed'),
                          icon: Icon(Icons.payments_outlined)),
                    ],
                    selected: {feeType},
                    onSelectionChanged: (s) =>
                        setSheetState(() => feeType = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (feeType == ServiceFeeType.percent)
                    TextField(
                      controller: serviceFeeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Service Fee %',
                        suffixText: '%',
                        helperText: 'Profit = % of total project spend',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                    )
                  else
                    TextField(
                      controller: feeAmountCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Fixed Service Fee',
                        prefixText: 'Rs ',
                        helperText:
                            'Flat fee earned regardless of how much is spent',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                        const ThousandsSeparatorInputFormatter(),
                      ],
                    ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final budget = double.tryParse(budgetCtrl.text.replaceAll(',', ''));
                    // Hard validation: With-Material projects can't function
                    // accounting-wise without a contract value.
                    if (model == ProjectModel.withMaterial &&
                        (budget == null || budget <= 0)) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text(
                            'With-Material projects need a contract value '
                            '(budget) greater than zero.'),
                      ));
                      return;
                    }
                    final repo =
                        await ref.read(entityRepoProvider.future);
                    await repo.createProject(
                      name: name,
                      model: model,
                      clientName: clientCtrl.text.trim().isEmpty
                          ? null
                          : clientCtrl.text.trim(),
                      siteAddress: siteCtrl.text.trim().isEmpty
                          ? null
                          : siteCtrl.text.trim(),
                      budget: budget,
                      projectManager: managerCtrl.text.trim().isEmpty
                          ? null
                          : managerCtrl.text.trim(),
                      whatsapp: whatsappCtrl.text.trim().isEmpty
                          ? null
                          : whatsappCtrl.text.trim(),
                      serviceFeePercent: model == ProjectModel.labourRate &&
                              feeType == ServiceFeeType.percent
                          ? double.tryParse(serviceFeeCtrl.text)
                          : null,
                      serviceFeeType: feeType,
                      serviceFeeAmount: model == ProjectModel.labourRate &&
                              feeType == ServiceFeeType.fixed
                          ? double.tryParse(feeAmountCtrl.text.replaceAll(',', ''))
                          : null,
                    );
                    bumpLedger(ref);
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  },
                  child: const Text('Create'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// Edit-form variant of [_showProjectForm] — prefilled from `existing` and
/// hits [EntityRepository.updateProjectFields] instead of `createProject`.
void _showProjectEditForm(
    BuildContext context, WidgetRef ref, Project existing) {
  final nameCtrl = TextEditingController(text: existing.name);
  final clientCtrl = TextEditingController(text: existing.clientName ?? '');
  final siteCtrl = TextEditingController(text: existing.siteAddress ?? '');
  final budgetCtrl =
      TextEditingController(text: moneyInputText(existing.budget));
  final managerCtrl =
      TextEditingController(text: existing.projectManager ?? '');
  final whatsappCtrl = TextEditingController(text: existing.whatsapp ?? '');
  final serviceFeeCtrl = TextEditingController(
      text: existing.serviceFeePercent?.toString() ?? '');
  final feeAmountCtrl = TextEditingController(
      text: moneyInputText(existing.serviceFeeAmount));
  ServiceFeeType feeType = existing.serviceFeeType;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: StatefulBuilder(
        builder: (ctx, setSheetState) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit Project',
                style: Theme.of(sheetCtx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
                'Model (${existing.model.label}) is fixed once a project '
                'is created — change other fields freely.',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration:
                  const InputDecoration(labelText: 'Project name *'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: clientCtrl,
              decoration:
                  const InputDecoration(labelText: 'Client name (optional)'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: siteCtrl,
              decoration: const InputDecoration(
                  labelText: 'Site address (optional)'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: budgetCtrl,
              decoration: InputDecoration(
                labelText: existing.model == ProjectModel.withMaterial
                    ? 'Contract value (budget) *'
                    : 'Budget (optional)',
                prefixText: 'Rs ',
                helperText: existing.model == ProjectModel.withMaterial
                    ? 'Required: what the customer has agreed to pay'
                    : 'Optional planning ceiling',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                const ThousandsSeparatorInputFormatter(),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: managerCtrl,
              decoration: const InputDecoration(
                  labelText: 'Project manager (optional)'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: whatsappCtrl,
              decoration: const InputDecoration(
                labelText: 'Client WhatsApp number (optional)',
                helperText:
                    'Used to send a confirmation on money received from this project',
                prefixIcon: Icon(Icons.chat_outlined),
              ),
              keyboardType: TextInputType.phone,
            ),
            if (existing.model == ProjectModel.labourRate) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Service Fee (Labour-Rate)',
                    style: Theme.of(sheetCtx).textTheme.labelLarge),
              ),
              const SizedBox(height: 6),
              SegmentedButton<ServiceFeeType>(
                segments: const [
                  ButtonSegment(
                      value: ServiceFeeType.percent,
                      label: Text('Percentage'),
                      icon: Icon(Icons.percent)),
                  ButtonSegment(
                      value: ServiceFeeType.fixed,
                      label: Text('Fixed'),
                      icon: Icon(Icons.payments_outlined)),
                ],
                selected: {feeType},
                onSelectionChanged: (s) =>
                    setSheetState(() => feeType = s.first),
              ),
              const SizedBox(height: 12),
              if (feeType == ServiceFeeType.percent)
                TextField(
                  controller: serviceFeeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Service Fee %',
                    suffixText: '%',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                )
              else
                TextField(
                  controller: feeAmountCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Fixed Service Fee',
                    prefixText: 'Rs ',
                    helperText:
                        'Flat fee earned regardless of how much is spent',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    const ThousandsSeparatorInputFormatter(),
                  ],
                ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final budget = double.tryParse(budgetCtrl.text.replaceAll(',', ''));
                if (existing.model == ProjectModel.withMaterial &&
                    (budget == null || budget <= 0)) {
                  ScaffoldMessenger.of(sheetCtx).showSnackBar(const SnackBar(
                    content: Text(
                        'With-Material projects need a contract value '
                        '(budget) greater than zero.'),
                  ));
                  return;
                }
                final repo = await ref.read(entityRepoProvider.future);
                await repo.updateProjectFields(
                  existing.id,
                  name: name,
                  clientName: clientCtrl.text,
                  siteAddress: siteCtrl.text,
                  budget: budget,
                  projectManager: managerCtrl.text,
                  whatsapp: whatsappCtrl.text,
                  serviceFeePercent: existing.model == ProjectModel.labourRate &&
                          feeType == ServiceFeeType.percent
                      ? double.tryParse(serviceFeeCtrl.text)
                      : null,
                  serviceFeeType: existing.model == ProjectModel.labourRate
                      ? feeType
                      : null,
                  serviceFeeAmount: existing.model == ProjectModel.labourRate &&
                          feeType == ServiceFeeType.fixed
                      ? double.tryParse(feeAmountCtrl.text)
                      : null,
                );
                bumpLedger(ref);
                if (sheetCtx.mounted) Navigator.pop(sheetCtx);
              },
              child: const Text('Save'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.hint});
  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(hint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

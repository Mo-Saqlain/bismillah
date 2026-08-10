import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/core/theme.dart';
import 'package:bismillah_constructions/shared/core/whatsapp.dart';
import 'package:bismillah_constructions/shared/data/models/material_escalation.dart';
import 'package:bismillah_constructions/shared/data/models/project.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/mobile/features/common/async_view.dart';
import 'package:bismillah_constructions/mobile/features/common/searchable_dropdown.dart';

/// Screen to calculate and report Inflation & Material Price Escalation claims
/// per project for "With-Material" contracts.
class MaterialEscalationScreen extends ConsumerStatefulWidget {
  const MaterialEscalationScreen({super.key, this.initialProject});
  final Project? initialProject;

  @override
  ConsumerState<MaterialEscalationScreen> createState() =>
      _MaterialEscalationScreenState();
}

class _MaterialEscalationScreenState
    extends ConsumerState<MaterialEscalationScreen> {
  Project? _selectedProject;
  final Map<String, double> _customBaselines = {};

  @override
  void initState() {
    super.initState();
    _selectedProject = widget.initialProject;
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Material Price Escalation Claim'),
      ),
      body: AsyncView<List<Project>>(
        value: projectsAsync,
        data: (projects) {
          final withMaterialProjects = projects
              .where((p) => p.model == ProjectModel.withMaterial)
              .toList();

          if (withMaterialProjects.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No "With-Material" projects found. Price escalation is tracked for With-Material projects.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          _selectedProject ??= withMaterialProjects.first;
          final currentProject = _selectedProject!;

          final summaryAsync = ref.watch(projectEscalationProvider((
            projectId: currentProject.id,
            customBaselines: _customBaselines.isEmpty ? null : _customBaselines,
          )));

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // Project Picker
              SearchableDropdown<Project>(
                value: currentProject,
                items: withMaterialProjects,
                labelOf: (p) => p.name,
                labelText: 'Select Project',
                hintText: 'Search projects…',
                onChanged: (p) {
                  if (p != null) {
                    setState(() {
                      _selectedProject = p;
                      _customBaselines.clear();
                    });
                  }
                },
              ),
              const SizedBox(height: 16),

              summaryAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (summary) {
                  if (summary.items.isEmpty) {
                    return _NoMaterialPurchasesCard(project: currentProject);
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Hero Claim Card
                      _HeroClaimCard(
                        summary: summary,
                        onWhatsAppTap: () => _sendWhatsAppClaim(summary),
                        onAdjustBaselinesTap: () =>
                            _showBaselineAdjustmentSheet(context, summary),
                      ),
                      const SizedBox(height: 16),

                      // Section Header
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          'Material-wise Escalation Breakdown',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // List of Material Escalation Cards
                      ...summary.items.map(
                        (item) => _MaterialEscalationCard(item: item),
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _sendWhatsAppClaim(ProjectEscalationSummary summary) {
    final buffer = StringBuffer();
    buffer.writeln('📋 *MATERIAL PRICE ESCALATION CLAIM*');
    buffer.writeln('Project: *${summary.projectName}*');
    if (summary.clientName != null && summary.clientName!.isNotEmpty) {
      buffer.writeln('Client: ${summary.clientName}');
    }
    buffer.writeln('Date: ${fmtDate(DateTime.now())}');
    buffer.writeln();
    buffer.writeln(
        'Due to market price inflation, per our agreement, below is the itemized rate escalation claim breakdown:');
    buffer.writeln();

    for (var i = 0; i < summary.items.length; i++) {
      final item = summary.items[i];
      final sign = item.percentageIncrease >= 0 ? '+' : '';
      buffer.writeln('${i + 1}. *${item.materialLabel}* (${item.unit})');
      buffer.writeln(
          '   • Baseline Rate: Rs ${fmtMoney(item.baselineRate)}/${item.unit}');
      buffer.writeln(
          '   • Latest Rate: Rs ${fmtMoney(item.latestRate)}/${item.unit} ($sign${item.percentageIncrease.toStringAsFixed(1)}%)');
      buffer.writeln(
          '   • Total Qty Used: ${fmtMoney(item.totalQuantity)} ${item.unit}');
      buffer.writeln('   • Total Spent: Rs ${fmtMoney(item.totalActualCost)}');
      buffer.writeln(
          '   • *Extra Inflation Claim*: Rs ${fmtMoney(item.escalationClaim)}');
      buffer.writeln();
    }

    buffer.writeln('-----------------------------------');
    buffer.writeln(
        '💰 *TOTAL EXTRA CLAIMABLE*: Rs ${fmtMoney(summary.totalEscalationClaim)}');
    buffer.writeln('-----------------------------------');
    buffer.writeln('Please review and arrange the price difference payment. Thank you!');

    final num = summary.clientWhatsApp;
    launchWhatsApp(number: num ?? '', message: buffer.toString());
  }

  void _showBaselineAdjustmentSheet(
      BuildContext context, ProjectEscalationSummary summary) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final controllers = <String, TextEditingController>{};
        for (final item in summary.items) {
          controllers[item.materialType] = TextEditingController(
            text: item.baselineRate.toStringAsFixed(0),
          );
        }

        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Adjust Agreed Baseline Rates',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Set the agreed baseline purchase rates for each material. Rate increases above this baseline will be claimed from the client.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: summary.items.map((item) {
                    final ctrl = controllers[item.materialType]!;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText:
                              '${item.materialLabel} Baseline (Rs / ${item.unit})',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() => _customBaselines.clear());
                      Navigator.pop(ctx);
                    },
                    child: const Text('Reset to Initial'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      for (final entry in controllers.entries) {
                        final val = double.tryParse(entry.value.text);
                        if (val != null && val > 0) {
                          _customBaselines[entry.key] = val;
                        }
                      }
                      setState(() {});
                      Navigator.pop(ctx);
                    },
                    child: const Text('Apply Baselines'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeroClaimCard extends StatelessWidget {
  const _HeroClaimCard({
    required this.summary,
    required this.onWhatsAppTap,
    required this.onAdjustBaselinesTap,
  });
  final ProjectEscalationSummary summary;
  final VoidCallback onWhatsAppTap;
  final VoidCallback onAdjustBaselinesTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 2,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'EXTRA CLAIMABLE FROM CLIENT',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: scheme.onPrimaryContainer.withOpacity(0.8),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_suggest, size: 20),
                  tooltip: 'Set baseline rates',
                  onPressed: onAdjustBaselinesTap,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Rs ${fmtMoney(summary.totalEscalationClaim)}',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: BalanceColors.positive(context),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatColumn(
                    label: 'Actual Spend',
                    value: 'Rs ${fmtMoney(summary.totalActualCost)}',
                  ),
                ),
                Expanded(
                  child: _StatColumn(
                    label: 'Baseline Spend',
                    value: 'Rs ${fmtMoney(summary.totalBaselineCost)}',
                  ),
                ),
                Expanded(
                  child: _StatColumn(
                    label: 'Purchases',
                    value: '${summary.purchaseCount} txns',
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onWhatsAppTap,
                icon: const Icon(Icons.send),
                label: const Text('Share Claim via WhatsApp'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class _MaterialEscalationCard extends StatelessWidget {
  const _MaterialEscalationCard({required this.item});
  final MaterialEscalationItem item;

  @override
  Widget build(BuildContext context) {
    final hasEscalation = item.escalationClaim > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        title: Text(
          item.materialLabel,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'Baseline: Rs ${fmtMoney(item.baselineRate)} · Latest: Rs ${fmtMoney(item.latestRate)} / ${item.unit}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'Rs ${fmtMoney(item.escalationClaim)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: hasEscalation
                    ? BalanceColors.negative(context)
                    : Colors.grey,
              ),
            ),
            Text(
              '${item.percentageIncrease >= 0 ? '+' : ''}${item.percentageIncrease.toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 11,
                color: item.percentageIncrease > 0
                    ? Colors.red
                    : (item.percentageIncrease < 0 ? Colors.green : Colors.grey),
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Total Qty: ${fmtMoney(item.totalQuantity)} ${item.unit}'),
                    Text('Total Spent: Rs ${fmtMoney(item.totalActualCost)}'),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Purchase History:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                const SizedBox(height: 4),
                ...item.purchases.map((p) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              fmtDate(p.date),
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              '${fmtMoney(p.quantity)} ${item.unit} @ Rs ${fmtMoney(p.rate)}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '+Rs ${fmtMoney(p.extraCost)}',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: p.extraCost > 0
                                    ? Colors.red
                                    : Colors.grey,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoMaterialPurchasesCard extends StatelessWidget {
  const _NoMaterialPurchasesCard({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.info_outline, size: 40, color: Colors.amber),
            const SizedBox(height: 12),
            Text(
              'No Material Purchases Recorded',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'There are no material inventory purchases with per-unit rates logged for "${project.name}" yet. Record material buys with quantity & unit rate to track price escalation.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

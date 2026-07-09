import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import 'project_bva_screen.dart';

class ProjectBvaPickerScreen extends ConsumerWidget {
  const ProjectBvaPickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Budget vs Actual — Pick Project')),
      body: AsyncView(
        value: projects,
        data: (list) {
          final eligible =
              list.where((p) => (p.budget ?? 0) > 0).toList();
          if (eligible.isEmpty) {
            return const Center(
                child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                  'Set a budget on a project to see Budget vs Actual.'),
            ));
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final p in eligible)
                Card(
                  child: ListTile(
                    title: Text(p.name),
                    subtitle: Text(
                        'Budget: ${fmtMoney(p.budget)} · ${p.model.label}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ProjectBvaScreen(project: p)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

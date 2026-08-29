import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/mobile/features/followups/followups_screen.dart';
import 'package:bismillah_constructions/mobile/features/home/home_screen.dart' show kPillNavReservedHeight;
import 'package:bismillah_constructions/mobile/features/parties/banks_screen.dart';
import 'package:bismillah_constructions/mobile/features/parties/parties_screen.dart';
import 'package:bismillah_constructions/mobile/features/projects/projects_screen.dart';
import 'package:bismillah_constructions/mobile/features/manage/labour_types_screen.dart';
import 'package:bismillah_constructions/mobile/features/manage/material_types_screen.dart';
import 'package:bismillah_constructions/mobile/features/manage/user_management_screen.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

/// "Manage" tab — landing page that gathers entity-management screens
/// (Projects, Suppliers, Wallets/Banks, Material/Labour Types, Follow-ups, and User Management).
class ManageScreen extends ConsumerWidget {
  const ManageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final pendingCount = ref.watch(pendingRequestsCountProvider).valueOrNull ?? 0;
    final isAdmin = user == null || user.isAdmin;

    return Scaffold(
      appBar: AppBar(title: const Text('Manage')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            12, 12, 12, 12 + kPillNavReservedHeight),
        children: [
          if (isAdmin)
            _ManageCard(
              icon: Icons.admin_panel_settings,
              color: Colors.blueAccent,
              title: 'User Management & Access',
              badgeCount: pendingCount,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const UserManagementScreen()),
              ),
            ),
          _ManageCard(
            icon: Icons.foundation,
            color: Colors.indigo,
            title: 'Projects',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProjectsScreen()),
            ),
          ),
          _ManageCard(
            icon: Icons.local_shipping,
            color: Colors.deepOrange,
            title: 'Suppliers',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SuppliersScreen()),
            ),
          ),
          _ManageCard(
            icon: Icons.account_balance,
            color: Colors.teal,
            title: 'Wallets & Banks',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BanksScreen()),
            ),
          ),
          _ManageCard(
            icon: Icons.category,
            color: Colors.brown,
            title: 'Material Types',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MaterialTypesScreen()),
            ),
          ),
          _ManageCard(
            icon: Icons.engineering,
            color: Colors.purple,
            title: 'Labour Types',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LabourTypesScreen()),
            ),
          ),
          _ManageCard(
            icon: Icons.pending_actions,
            color: Colors.deepPurple,
            title: 'Recovery Follow-ups',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FollowUpsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManageCard extends StatelessWidget {
  const _ManageCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.15),
          child: Icon(icon, color: color),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badgeCount > 0) ...[
              Badge(
                label: Text('$badgeCount'),
                backgroundColor: Colors.orange,
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.chevron_right, color: scheme.outline),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

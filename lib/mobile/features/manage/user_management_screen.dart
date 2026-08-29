import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/data/models/access_request.dart';
import 'package:bismillah_constructions/shared/data/models/app_user.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

class UserManagementScreen extends ConsumerStatefulWidget {
  const UserManagementScreen({super.key});

  @override
  ConsumerState<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends ConsumerState<UserManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.read(userVersionProvider.notifier).state++;
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = ref.watch(pendingRequestsCountProvider).valueOrNull ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management & Access'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Access Requests'),
                  if (pendingCount > 0) ...[
                    const SizedBox(width: 6),
                    Badge(
                      label: Text('$pendingCount'),
                      backgroundColor: Colors.orange,
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: 'App Users'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _AccessRequestsTab(onActionComplete: _refresh),
          _AppUsersTab(onActionComplete: _refresh),
        ],
      ),
    );
  }
}

// ── Tab 1: Access Requests ──────────────────────────────────────────────────

class _AccessRequestsTab extends ConsumerWidget {
  const _AccessRequestsTab({required this.onActionComplete});
  final VoidCallback onActionComplete;

  Future<void> _approveRequest(
      BuildContext context, WidgetRef ref, AccessRequest req) async {
    final passCtrl = TextEditingController();
    String selectedRole = 'user';

    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Approve Request: ${req.username}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (req.fullName != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.badge),
                  title: Text(req.fullName!),
                  subtitle: const Text('Full Name'),
                ),
              if (req.phoneOrEmail != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.contact_phone),
                  title: Text(req.phoneOrEmail!),
                  subtitle: const Text('Contact Details'),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Assign Temporary Password *',
                  hintText: 'Enter password for this user',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedRole,
                decoration: const InputDecoration(
                  labelText: 'Assigned Role',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'user', child: Text('User (Standard)')),
                  DropdownMenuItem(value: 'admin', child: Text('Admin (Full Control)')),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => selectedRole = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                if (passCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password cannot be empty')),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              icon: const Icon(Icons.check_circle),
              label: const Text('Approve & Create Account'),
            ),
          ],
        ),
      ),
    );

    if (approved != true) return;

    try {
      final repo = await ref.read(userRepoProvider.future);
      final entityRepo = await ref.read(entityRepoProvider.future);
      final tenantId = await entityRepo.tenantIdOrNull();

      // Create user account
      await repo.createUser(
        username: req.username,
        password: passCtrl.text.trim(),
        role: selectedRole,
        tenantId: tenantId,
      );

      // Update access request status
      await repo.updateAccessRequestStatus(req.id, 'approved');

      // Sync if configured
      try {
        final syncSvc = await ref.read(syncServiceFutureProvider.future);
        await syncSvc.syncNow(force: true);
      } catch (_) {}

      onActionComplete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('User "${req.username}" approved & account created ✓'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  Future<void> _rejectRequest(
      BuildContext context, WidgetRef ref, AccessRequest req) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject Request from ${req.username}?'),
        content: const Text(
          'This will decline the access request. The requester will not be able to log in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject Request'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final repo = await ref.read(userRepoProvider.future);
      await repo.updateAccessRequestStatus(req.id, 'rejected');

      onActionComplete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Access request rejected.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reject: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(userVersionProvider);
    final requestsFuture = ref.watch(userRepoProvider.future).then((r) => r.getAccessRequests());

    return FutureBuilder<List<AccessRequest>>(
      future: requestsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final requests = snapshot.data ?? [];
        if (requests.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mark_email_read_outlined, size: 64, color: Colors.grey),
                SizedBox(height: 12),
                Text('No access requests found',
                    style: TextStyle(fontSize: 16, color: Colors.grey)),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: requests.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final req = requests[i];
            final isPending = req.isPending;

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: isPending
                      ? Colors.amber.shade100
                      : req.status == 'approved'
                          ? Colors.green.shade100
                          : Colors.red.shade100,
                  child: Icon(
                    isPending
                        ? Icons.pending
                        : req.status == 'approved'
                            ? Icons.check
                            : Icons.close,
                    color: isPending
                        ? Colors.amber.shade900
                        : req.status == 'approved'
                            ? Colors.green.shade900
                            : Colors.red.shade900,
                  ),
                ),
                title: Text(
                  req.username,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (req.fullName != null) Text('Name: ${req.fullName}'),
                    if (req.phoneOrEmail != null) Text('Contact: ${req.phoneOrEmail}'),
                    Text(
                      'Requested: ${req.createdAt.split('T').first}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
                trailing: isPending
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.check_circle, color: Colors.green),
                            tooltip: 'Approve',
                            onPressed: () => _approveRequest(context, ref, req),
                          ),
                          IconButton(
                            icon: const Icon(Icons.cancel, color: Colors.red),
                            tooltip: 'Reject',
                            onPressed: () => _rejectRequest(context, ref, req),
                          ),
                        ],
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: req.status == 'approved'
                              ? Colors.green.withOpacity(0.15)
                              : Colors.red.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          req.status.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: req.status == 'approved' ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
              ),
            );
          },
        );
      },
    );
  }
}

// ── Tab 2: App Users List ───────────────────────────────────────────────────

class _AppUsersTab extends ConsumerWidget {
  const _AppUsersTab({required this.onActionComplete});
  final VoidCallback onActionComplete;

  Future<void> _createNewUser(BuildContext context, WidgetRef ref) async {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String selectedRole = 'user';

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create New User Account'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: userCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Username *',
                    hintText: 'e.g. manager1',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password *',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'user', child: Text('User (Standard)')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin (Full Access)')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => selectedRole = val);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () {
                if (userCtrl.text.trim().isEmpty || passCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Username and Password are required.')),
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              icon: const Icon(Icons.person_add),
              label: const Text('Create User'),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;

    try {
      final repo = await ref.read(userRepoProvider.future);
      final entityRepo = await ref.read(entityRepoProvider.future);
      final tenantId = await entityRepo.tenantIdOrNull();

      await repo.createUser(
        username: userCtrl.text.trim(),
        password: passCtrl.text.trim(),
        role: selectedRole,
        tenantId: tenantId,
      );

      // Sync if configured
      try {
        final syncSvc = await ref.read(syncServiceFutureProvider.future);
        await syncSvc.syncNow(force: true);
      } catch (_) {}

      onActionComplete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('User "${userCtrl.text.trim()}" created successfully ✓'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create user: $e')),
        );
      }
    }
  }

  Future<void> _toggleUserStatus(
      BuildContext context, WidgetRef ref, AppUser user) async {
    final nextStatus = user.status == 'active' ? 'revoked' : 'active';
    final verb = nextStatus == 'revoked' ? 'Revoke' : 'Restore';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$verb access for ${user.username}?'),
        content: Text(
          nextStatus == 'revoked'
              ? 'This user will be blocked from logging into the app on any device.'
              : 'This user will be granted active access to log in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: nextStatus == 'revoked' ? Colors.red : Colors.green,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('$verb Access'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final repo = await ref.read(userRepoProvider.future);
      await repo.updateUserStatus(user.id, nextStatus);

      // Sync
      try {
        final syncSvc = await ref.read(syncServiceFutureProvider.future);
        await syncSvc.syncNow(force: true);
      } catch (_) {}

      onActionComplete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('User access set to $nextStatus')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Operation failed: $e')),
        );
      }
    }
  }

  Future<void> _resetPassword(
      BuildContext context, WidgetRef ref, AppUser user) async {
    final passCtrl = TextEditingController();

    final reset = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset Password for ${user.username}'),
        content: TextField(
          controller: passCtrl,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New Password *',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (passCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Save Password'),
          ),
        ],
      ),
    );

    if (reset != true) return;

    try {
      final repo = await ref.read(userRepoProvider.future);
      await repo.updateUserPassword(user.id, passCtrl.text.trim());

      onActionComplete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Password updated for ${user.username} ✓')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(userVersionProvider);
    final usersFuture = ref.watch(userRepoProvider.future).then((r) => r.getUsers());
    final currentUser = ref.watch(currentUserProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createNewUser(context, ref),
        icon: const Icon(Icons.person_add),
        label: const Text('New User'),
      ),
      body: FutureBuilder<List<AppUser>>(
        future: usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final users = snapshot.data ?? [];
          if (users.isEmpty) {
            return const Center(child: Text('No users registered'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: users.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final u = users[i];
              final isCurrent = currentUser?.id == u.id;
              final isRevoked = u.status == 'revoked';

              return Card(
                color: isRevoked ? Colors.grey.shade100 : null,
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: u.isAdmin ? Colors.indigo : Colors.blueGrey,
                    child: Icon(
                      u.isAdmin ? Icons.admin_panel_settings : Icons.person,
                      color: Colors.white,
                    ),
                  ),
                  title: Row(
                    children: [
                      Text(
                        u.username,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          decoration: isRevoked ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'YOU',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    'Role: ${u.role.toUpperCase()} • Status: ${u.status.toUpperCase()}',
                    style: TextStyle(
                      fontSize: 12,
                      color: isRevoked ? Colors.red : Colors.grey.shade700,
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (val) {
                      if (val == 'toggle') {
                        _toggleUserStatus(context, ref, u);
                      } else if (val == 'reset') {
                        _resetPassword(context, ref, u);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'toggle',
                        enabled: !isCurrent, // Can't revoke self
                        child: Row(
                          children: [
                            Icon(
                              isRevoked ? Icons.check_circle_outline : Icons.block,
                              color: isRevoked ? Colors.green : Colors.red,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(isRevoked ? 'Grant Access' : 'Revoke Access'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'reset',
                        child: Row(
                          children: [
                            Icon(Icons.lock_reset, size: 20),
                            SizedBox(width: 8),
                            Text('Reset Password'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

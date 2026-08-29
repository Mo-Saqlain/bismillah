import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/providers/providers.dart';

class RequestAccessDialog extends ConsumerStatefulWidget {
  const RequestAccessDialog({super.key});

  @override
  ConsumerState<RequestAccessDialog> createState() => _RequestAccessDialogState();
}

class _RequestAccessDialogState extends ConsumerState<RequestAccessDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _nameCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    try {
      final repo = await ref.read(userRepoProvider.future);
      final entityRepo = await ref.read(entityRepoProvider.future);
      final tenantId = await entityRepo.tenantIdOrNull();

      await repo.createAccessRequest(
        username: _usernameCtrl.text.trim(),
        fullName: _nameCtrl.text.trim(),
        phoneOrEmail: _contactCtrl.text.trim(),
        tenantId: tenantId,
      );

      // Trigger cloud sync if connected
      try {
        final syncSvc = await ref.read(syncServiceFutureProvider.future);
        await syncSvc.syncNow(force: true);
      } catch (_) {}

      // Bump pending count
      ref.read(userVersionProvider.notifier).state++;

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Access request submitted! Administrator will review your request.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit request: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.person_add_outlined, color: scheme.primary),
          const SizedBox(width: 10),
          const Text('Request Access'),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Submit your details below. The administrator will be notified to review and grant you account access.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _usernameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Desired Username *',
                  hintText: 'e.g. supervisor1',
                  prefixIcon: Icon(Icons.person),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Username is required';
                  if (v.trim().length < 3) return 'Username must be at least 3 characters';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Full Name (Optional)',
                  hintText: 'e.g. Ali Khan',
                  prefixIcon: Icon(Icons.badge),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _contactCtrl,
                decoration: const InputDecoration(
                  labelText: 'Phone or Email (Optional)',
                  hintText: 'e.g. 0300-1234567',
                  prefixIcon: Icon(Icons.contact_phone),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.send),
          label: const Text('Submit Request'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'package:bismillah_constructions/mobile/features/settings/backups_list_screen.dart';
import 'package:bismillah_constructions/mobile/features/settings/change_log_screen.dart';
import 'package:bismillah_constructions/mobile/features/settings/recent_errors_screen.dart';
import 'package:bismillah_constructions/desktop/widgets/tab_screen_host.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return TabScreenHost(
      screens: [
        SubScreen(Icons.backup_outlined, 'Backups',
            (_) => const BackupsListScreen()),
        SubScreen(Icons.bug_report_outlined, 'Error Log',
            (_) => const RecentErrorsScreen()),
        SubScreen(Icons.history_outlined, 'Audit / Activity Log',
            (_) => const ChangeLogScreen()),
      ],
    );
  }
}

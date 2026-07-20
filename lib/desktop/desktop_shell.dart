import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/desktop/tabs/dashboard_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/labour_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/materials_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/projects_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/reports_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/settings_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/suppliers_tab.dart';
import 'package:bismillah_constructions/desktop/tabs/wallets_tab.dart';

class _TabDef {
  const _TabDef(this.label, this.icon, this.selectedIcon, this.builder);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() builder;
}

/// The desktop application shell: a slim global top bar, a retractable
/// left [NavigationRail] with eight destinations, and an [IndexedStack] of
/// per-tab [Navigator]s so each tab keeps its own back-stack and state.
class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({super.key});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  int _index = 0;
  bool _railExtended = true;

  late final List<_TabDef> _tabs = [
    _TabDef('Dashboard', Icons.dashboard_outlined, Icons.dashboard,
        () => const DashboardTab()),
    _TabDef('Projects', Icons.apartment_outlined, Icons.apartment,
        () => const ProjectsTab()),
    _TabDef('Suppliers', Icons.handshake_outlined, Icons.handshake,
        () => const SuppliersTab()),
    _TabDef('Materials', Icons.inventory_2_outlined, Icons.inventory_2,
        () => const MaterialsTab()),
    _TabDef('Labour', Icons.engineering_outlined, Icons.engineering,
        () => const LabourTab()),
    _TabDef('Wallets & Banks', Icons.account_balance_wallet_outlined,
        Icons.account_balance_wallet, () => const WalletsTab()),
    _TabDef('Reports', Icons.assessment_outlined, Icons.assessment,
        () => const ReportsTab()),
    _TabDef('Settings', Icons.settings_outlined, Icons.settings,
        () => const SettingsTab()),
  ];

  late final List<GlobalKey<NavigatorState>> _navKeys =
      List.generate(_tabs.length, (_) => GlobalKey<NavigatorState>());

  void _select(int i) {
    if (i == _index) {
      // Re-tapping the active tab pops it back to its root screen.
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _index = i);
    }
  }

  void _toggleTheme() {
    final mode = ref.read(themeModeProvider);
    final isDark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    ref
        .read(themeModeProvider.notifier)
        .setMode(isDark ? ThemeMode.light : ThemeMode.dark);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final isDark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            title: _tabs[_index].label,
            railExtended: _railExtended,
            isDark: isDark,
            onToggleRail: () =>
                setState(() => _railExtended = !_railExtended),
            onToggleTheme: _toggleTheme,
          ),
          Expanded(
            child: Row(
              children: [
                _buildRail(scheme),
                VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      for (var i = 0; i < _tabs.length; i++)
                        Navigator(
                          key: _navKeys[i],
                          onGenerateRoute: (settings) => MaterialPageRoute(
                            builder: (_) => _tabs[i].builder(),
                            settings: settings,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRail(ColorScheme scheme) {
    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height - 52,
        ),
        child: IntrinsicHeight(
          child: NavigationRail(
            extended: _railExtended,
            minWidth: 64,
            minExtendedWidth: 208,
            selectedIndex: _index,
            onDestinationSelected: _select,
            labelType: _railExtended ? null : NavigationRailLabelType.none,
            destinations: [
              for (final t in _tabs)
                NavigationRailDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.selectedIcon),
                  label: Text(t.label),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Slim, flat global chrome bar: rail toggle · app + tab title · theme toggle.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.railExtended,
    required this.isDark,
    required this.onToggleRail,
    required this.onToggleTheme,
  });

  final String title;
  final bool railExtended;
  final bool isDark;
  final VoidCallback onToggleRail;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).cardColor,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: railExtended ? 'Collapse menu' : 'Expand menu',
              icon: const Icon(Icons.menu),
              onPressed: onToggleRail,
            ),
            const SizedBox(width: 4),
            Text('Bismillah',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: 0.2,
                )),
            const SizedBox(width: 10),
            Container(width: 1, height: 20, color: scheme.outlineVariant),
            const SizedBox(width: 10),
            Text(title,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                )),
            const Spacer(),
            IconButton(
              tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
              icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              onPressed: onToggleTheme,
            ),
          ],
        ),
      ),
    );
  }
}

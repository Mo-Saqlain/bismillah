import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../dashboard/dashboard_screen.dart';
import '../manage/manage_screen.dart';
import '../reports/reports_screen.dart';
import '../settings/settings_screen.dart';

/// Total vertical space the floating pill reserves at the bottom of
/// the screen (pill height + bottom margin). Tab screens with a FAB
/// pad their FAB up by this amount so it doesn't disappear behind
/// the pill — see [DashboardScreen].
const double kPillNavReservedHeight = 76 + 14;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Order: Home, Manage, Reports, Settings.
  static const _homeIndex = 0;
  int _index = _homeIndex;

  late final PageController _pageController =
      PageController(initialPage: _homeIndex);

  /// Visited-tab history with the current tab at the tail. Capped at 4
  /// entries — pushing a 5th drops the oldest. Back press pops the tail
  /// and navigates to the new tail. When only Home remains, back exits.
  static const int _historyCapacity = 4;
  final List<int> _history = [_homeIndex];

  /// Set true when we're driving a tab change from a back press, so the
  /// resulting [PageController] page-change callback does not re-record the
  /// transition into history.
  bool _navigatingBack = false;

  /// While doing a multi-step jump (silent jump-to-adjacent + animate),
  /// this holds the final destination index. Intermediate page-change
  /// notifications are ignored for history purposes until we land here.
  int? _animatingToFinalIndex;

  static const _tabs = <Widget>[
    DashboardScreen(),
    ManageScreen(),
    ReportsScreen(),
    SettingsScreen(),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Tab tap from the bottom NavigationBar.
  ///
  /// Adjacent jumps animate normally — a 240ms slide is fast and feels
  /// natural. Non-adjacent jumps silently jump to the page right next to
  /// the target, then animate that last step. The user sees exactly one
  /// slide regardless of the distance — no "flash through the middle tabs"
  /// like a raw [PageController.jumpToPage] would produce.
  void _goToTab(int i) {
    if (i == _index) return;
    final diff = (i - _index).abs();
    const dur = Duration(milliseconds: 240);

    if (diff > 1) {
      // Park one page short of the target, then animate the final hop.
      final adjacent = i > _index ? i - 1 : i + 1;
      _animatingToFinalIndex = i;
      _pageController.jumpToPage(adjacent);
      // Schedule the animation after the jump's frame settles, otherwise
      // they collide and PageController falls back to an instant jump.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _pageController.animateToPage(i,
            duration: dur, curve: Curves.easeInOut);
      });
    } else {
      _pageController.animateToPage(i,
          duration: dur, curve: Curves.easeInOut);
    }
  }

  void _onPageChanged(int newIndex) {
    setState(() => _index = newIndex);
    if (_navigatingBack) {
      _navigatingBack = false;
      return;
    }
    // Mid-flight intermediate page from a multi-step jump — don't record
    // it; we're still on our way to the real destination.
    if (_animatingToFinalIndex != null &&
        newIndex != _animatingToFinalIndex) {
      return;
    }
    _animatingToFinalIndex = null;
    // Skip recording a no-op transition (e.g. settling animation reporting
    // the same page twice).
    if (_history.isNotEmpty && _history.last == newIndex) return;
    _history.add(newIndex);
    if (_history.length > _historyCapacity) {
      _history.removeAt(0);
    }
  }

  /// Returns true if we handled the back gesture by navigating within the
  /// tab history. Returns false to let the system pop happen (which exits
  /// the app from Home).
  bool _handleBack() {
    if (_history.length <= 1) {
      // Only the current tab is left in history. If it's Home, let the
      // pop go through (system exits). If we're somehow on a non-Home
      // tab with no history, fall back to Home rather than exiting.
      if (_index != _homeIndex) {
        _navigatingBack = true;
        _history
          ..clear()
          ..add(_homeIndex);
        _pageController.jumpToPage(_homeIndex);
        return true;
      }
      return false;
    }

    // Pop the current tab from history; the new tail is the destination.
    _history.removeLast();
    final destination = _history.last;
    _navigatingBack = true;
    if ((destination - _index).abs() > 1) {
      _pageController.jumpToPage(destination);
    } else {
      _pageController.animateToPage(
        destination,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeInOut,
      );
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final canExit = _index == _homeIndex && _history.length <= 1;
    return PopScope(
      canPop: canExit,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        // Let the PageView paint behind the floating pill bar so it reads as
        // a detached capsule rather than a docked bar.
        extendBody: true,
        body: PageView(
          controller: _pageController,
          onPageChanged: _onPageChanged,
          children: _tabs.map((w) => _KeepAlivePage(child: w)).toList(),
        ),
        bottomNavigationBar: _PillNavBar(
          selectedIndex: _index,
          onSelected: _goToTab,
          items: const [
            _PillItem(
                icon: Icons.dashboard_outlined,
                selectedIcon: Icons.dashboard,
                label: 'Home'),
            _PillItem(
                icon: Icons.tune_outlined,
                selectedIcon: Icons.tune,
                label: 'Manage'),
            _PillItem(
                icon: Icons.assessment_outlined,
                selectedIcon: Icons.assessment,
                label: 'Reports'),
            _PillItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: 'Settings'),
          ],
        ),
      ),
    );
  }
}

/// Wraps a tab page in [AutomaticKeepAliveClientMixin] so PageView does not
/// rebuild it when the user swipes away — preserves scroll position, form
/// input, etc. across tab transitions.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});
  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Data for a single destination in [_PillNavBar]. `label` is no
/// longer painted (icons-only nav for less visual noise), but kept
/// for semantics — passed to [Semantics] so screen readers and
/// long-press tooltips still announce each destination.
class _PillItem {
  const _PillItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// A floating, pill-shaped bottom navigation bar.
///
/// Renders a detached stadium-shaped capsule near the bottom edge. The
/// active destination expands into its own filled pill that reveals its
/// label; inactive destinations collapse to an icon only. Keeps the same
/// [selectedIndex] / onSelected contract as the Material [NavigationBar] it
/// replaced, so [HomeScreen]'s tab logic is unchanged.
class _PillNavBar extends StatelessWidget {
  const _PillNavBar({
    required this.selectedIndex,
    required this.onSelected,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<_PillItem> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        // Slightly less side margin so the pill has more room to breathe
        // its larger destinations — keeps the tap targets generous on a
        // 360-dp phone for users with big hands.
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        child: Container(
          height: 76,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.large),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < items.length; i++)
                _PillDestination(
                  item: items[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillDestination extends StatelessWidget {
  const _PillDestination({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _PillItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Inner destination radius sits between [Radii.small] and
    // [Radii.medium] — slightly softer than a card so it still reads
    // as a tap target inside the rounded tray, but not a stadium.
    const innerRadius = 18.0;
    return Semantics(
      label: item.label,
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(innerRadius),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          // Fixed-size tap target so the bar's spacing doesn't shift
          // when the active destination changes — the only thing that
          // animates is the background colour.
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(innerRadius),
          ),
          child: Icon(
            selected ? item.selectedIcon : item.icon,
            size: 26,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

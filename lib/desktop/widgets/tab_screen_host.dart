import 'package:flutter/material.dart';

/// One entry in a tab's Windows-10-style sub-tab strip.
///
/// [builder] receives a `resetSelf` callback: an embedded transaction form
/// calls it (via its `onSaved`) after a successful save so the host swaps in
/// a fresh, blank form instead of the screen trying to pop a route.
class SubScreen {
  const SubScreen(this.icon, this.label, this.builder);
  final IconData icon;
  final String label;
  final Widget Function(VoidCallback resetSelf) builder;
}

/// Hosts a set of screens behind a horizontal sub-tab strip. Clicking a tab
/// swaps the body inline (no route push). Screens are built lazily on first
/// visit and kept alive (state preserved) via an [IndexedStack].
class TabScreenHost extends StatefulWidget {
  const TabScreenHost({super.key, required this.screens, this.initialIndex = 0});
  final List<SubScreen> screens;
  final int initialIndex;

  @override
  State<TabScreenHost> createState() => _TabScreenHostState();
}

class _TabScreenHostState extends State<TabScreenHost> {
  late int _selected = widget.initialIndex;
  final Map<int, Widget> _cache = {};

  /// Per-index build generation. Bumping it (via resetSelf) discards the
  /// cached instance and mounts a fresh one — used to reset embedded forms.
  final Map<int, int> _gen = {};

  Widget _build(int i) {
    final gen = _gen[i] ?? 0;
    return KeyedSubtree(
      key: ValueKey('sub_${i}_$gen'),
      child: widget.screens[i].builder(() {
        if (!mounted) return;
        setState(() {
          _gen[i] = gen + 1;
          _cache.remove(i);
        });
      }),
    );
  }

  void _select(int i) {
    if (i == _selected) return;
    setState(() => _selected = i);
  }

  @override
  Widget build(BuildContext context) {
    // Ensure the visible screen is materialised this frame.
    _cache.putIfAbsent(_selected, () => _build(_selected));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SubTabStrip(
          screens: widget.screens,
          selected: _selected,
          onSelect: _select,
        ),
        Expanded(
          child: IndexedStack(
            index: _selected,
            children: [
              for (var i = 0; i < widget.screens.length; i++)
                _cache[i] ?? const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }
}

class _SubTabStrip extends StatelessWidget {
  const _SubTabStrip({
    required this.screens,
    required this.selected,
    required this.onSelect,
  });
  final List<SubScreen> screens;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            for (var i = 0; i < screens.length; i++)
              _SubTab(
                screen: screens[i],
                selected: i == selected,
                onTap: () => onSelect(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _SubTab extends StatelessWidget {
  const _SubTab({
    required this.screen,
    required this.selected,
    required this.onTap,
  });
  final SubScreen screen;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          // Windows-10 "pivot" look: a solid accent underline on the
          // selected tab, flat everywhere else.
          border: Border(
            bottom: BorderSide(
              color: selected ? scheme.primary : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(screen.icon, size: 17, color: fg),
            const SizedBox(width: 7),
            Text(
              screen.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

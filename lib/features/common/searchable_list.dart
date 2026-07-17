import 'package:flutter/material.dart';

/// A search box pinned above a filtered [ListView], for the entity-picker
/// screens (project / supplier / bank / BvA ledger pickers). Each screen keeps
/// its own `itemBuilder` so the cards render exactly as before; this only adds
/// the type-to-filter box on top and narrows the list by [searchOf].
///
/// Expects to be given a bounded height (e.g. as a `Scaffold.body`), which the
/// pinned field + `Expanded` list needs.
class SearchableList<T> extends StatefulWidget {
  const SearchableList({
    super.key,
    required this.items,
    required this.searchOf,
    required this.itemBuilder,
    this.hintText = 'Search…',
    this.padding = const EdgeInsets.all(12),
  });

  final List<T> items;

  /// Text matched against the query (case-insensitive, substring).
  final String Function(T) searchOf;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String hintText;
  final EdgeInsets padding;

  @override
  State<SearchableList<T>> createState() => _SearchableListState<T>();
}

class _SearchableListState<T> extends State<SearchableList<T>> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.items
        : widget.items
            .where((it) => widget.searchOf(it).toLowerCase().contains(q))
            .toList();

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              widget.padding.left, widget.padding.top, widget.padding.right, 0),
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: widget.hintText,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No matches for “$_query”.'),
                  ),
                )
              : ListView.separated(
                  padding: widget.padding,
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => widget.itemBuilder(ctx, filtered[i]),
                ),
        ),
      ],
    );
  }
}

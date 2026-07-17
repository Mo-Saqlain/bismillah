import 'package:flutter/material.dart';

/// A type-ahead replacement for `DropdownButtonFormField`.
///
/// Wraps Material 3's [DropdownMenu] (a text field + filterable popup) so the
/// operator can type to narrow a long list of projects / suppliers / wallets /
/// material types instead of scrolling. Kept generic over `T` so the same
/// widget serves id-string pickers and object pickers (e.g. `Account`).
///
/// Two things [DropdownMenu] doesn't give us on its own, added here:
///   * **Form integration** — the field is wrapped in a [FormField] so the
///     enclosing `Form.validate()` still enforces required selections exactly
///     as the old dropdowns did (`validator`).
///   * **External-value sync** — when the selection is changed from *outside*
///     (e.g. the supplier is cleared because the transaction kind switched and
///     the previously-picked supplier is no longer in the filtered list), the
///     text field is re-synced in [didUpdateWidget]. [DropdownMenu] alone only
///     honours `initialSelection` on first build.
///
/// [searchOf] supplies extra text to match against beyond the visible label —
/// e.g. a supplier's phone number — so typing a number also finds the party.
class SearchableDropdown<T> extends StatefulWidget {
  const SearchableDropdown({
    super.key,
    required this.items,
    required this.value,
    required this.labelOf,
    required this.onChanged,
    required this.labelText,
    this.searchOf,
    this.validator,
    this.hintText,
    this.enabled = true,
    this.leadingIconOf,
  });

  final List<T> items;
  final T? value;
  final String Function(T) labelOf;

  /// Optional extra searchable text (not shown), matched alongside the label.
  final String Function(T)? searchOf;
  final ValueChanged<T?> onChanged;
  final String labelText;
  final String? Function(T?)? validator;
  final String? hintText;
  final bool enabled;

  /// Optional per-entry leading icon shown in the popup.
  final IconData Function(T)? leadingIconOf;

  @override
  State<SearchableDropdown<T>> createState() => _SearchableDropdownState<T>();
}

class _SearchableDropdownState<T> extends State<SearchableDropdown<T>> {
  late final TextEditingController _controller;
  final _fieldKey = GlobalKey<FormFieldState<T>>();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _labelFor(widget.value));
  }

  @override
  void didUpdateWidget(covariant SearchableDropdown<T> old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      final text = _labelFor(widget.value);
      if (_controller.text != text) _controller.text = text;
      // Keep the FormField's value in step so validate() sees the real
      // selection after an external change.
      _fieldKey.currentState?.didChange(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _labelFor(T? v) {
    if (v != null) return widget.labelOf(v);
    // `null` is a real, selectable option only for nullable pickers that
    // include a "— None —" / "All …" entry (i.e. null is in `items`); there
    // its label should show. Otherwise null means "nothing picked" → blank.
    if (widget.items.contains(null)) return widget.labelOf(null as T);
    return '';
  }

  String _searchText(T item) {
    final extra = widget.searchOf?.call(item);
    final base = widget.labelOf(item);
    return extra == null || extra.isEmpty ? base : '$base $extra';
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.items
        .map((it) => DropdownMenuEntry<T>(
              value: it,
              label: widget.labelOf(it),
              leadingIcon: widget.leadingIconOf == null
                  ? null
                  : Icon(widget.leadingIconOf!(it)),
            ))
        .toList();

    return FormField<T>(
      key: _fieldKey,
      initialValue: widget.value,
      validator: widget.validator,
      builder: (state) => DropdownMenu<T>(
        controller: _controller,
        enabled: widget.enabled,
        initialSelection: widget.value,
        enableFilter: true,
        requestFocusOnTap: true,
        expandedInsets: EdgeInsets.zero,
        label: Text(widget.labelText),
        hintText: widget.hintText,
        errorText: state.errorText,
        dropdownMenuEntries: entries,
        filterCallback: (list, text) {
          final q = text.trim().toLowerCase();
          if (q.isEmpty) return list;
          return list
              .where((e) => _searchText(e.value).toLowerCase().contains(q))
              .toList();
        },
        onSelected: (v) {
          state.didChange(v);
          widget.onChanged(v);
        },
      ),
    );
  }
}

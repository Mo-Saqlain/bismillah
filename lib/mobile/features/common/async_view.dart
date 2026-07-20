import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Renders an [AsyncValue] with sensible defaults for loading/error states.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.data,
    this.loading,
    this.error,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final WidgetBuilder? loading;
  final Widget Function(Object error, StackTrace? st)? error;

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: data,
      loading: () =>
          loading?.call(context) ??
          const Center(child: CircularProgressIndicator()),
      error: (e, st) =>
          error?.call(e, st) ??
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Something went wrong:\n$e',
                  textAlign: TextAlign.center),
            ),
          ),
    );
  }
}

import 'package:flutter/material.dart';

/// Mixin that provides safe setState functionality
/// Prevents setState calls on disposed widgets
mixin SafeStateMixin<T extends StatefulWidget> on State<T> {
  /// Safely calls setState only if the widget is still mounted
  /// Use this instead of setState() in async callbacks to prevent
  /// "setState() called after dispose()" errors
  void safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }
}

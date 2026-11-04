import 'package:flutter/foundation.dart';

/// Tracks how long the app stayed in the background so the vault can lock
/// itself on return. System pickers are guarded because the app is paused
/// while they are open.
class AppLock {
  AppLock._();

  static const Duration grace = Duration(seconds: 60);

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static int _guards = 0;
  static DateTime? _pausedAt;

  static Future<T> guardExternal<T>(Future<T> Function() action) async {
    _guards++;
    try {
      return await action();
    } finally {
      _guards--;
      _pausedAt = null;
    }
  }

  static void markPaused() {
    if (_guards > 0) return;
    _pausedAt ??= clock();
  }

  static bool takeExpired() {
    final since = _pausedAt;
    _pausedAt = null;
    if (since == null) return false;
    return clock().difference(since) >= grace;
  }

  @visibleForTesting
  static void reset() {
    _guards = 0;
    _pausedAt = null;
    clock = DateTime.now;
  }
}

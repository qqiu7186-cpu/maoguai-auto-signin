import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Serializes network side effects with an iOS App Intent running in a
/// different process. Platforms without the native bridge retain the existing
/// SQLite claim as their durable duplicate guard.
abstract interface class CrossProcessExecutionLock {
  Future<bool> tryAcquire();
  Future<void> release();
}

class NativeCrossProcessExecutionLock implements CrossProcessExecutionLock {
  NativeCrossProcessExecutionLock([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('maoguai/native_background');

  final MethodChannel _channel;

  @override
  Future<bool> tryAcquire() async {
    if (!Platform.isIOS) return true;
    try {
      return await _channel.invokeMethod<bool>('tryAcquireExecutionLock') ??
          true;
    } catch (_) {
      // The durable SQLite claim still protects a single Flutter execution.
      // Do not make Android, test isolates, or plugin registration failure
      // appear logged out.
      return true;
    }
  }

  @override
  Future<void> release() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('releaseExecutionLock');
    } catch (_) {
      // The native lock is process-scoped and eventually released on exit.
    }
  }
}

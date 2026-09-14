import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../domain/sign_in_models.dart';
import 'background_entrypoint.dart';
import 'background_scheduler.dart';

abstract interface class WorkmanagerPort {
  Future<void> initialize(void Function() dispatcher);
  Future<void> cancelByUniqueName(String uniqueName);
  Future<void> schedule(
    String uniqueName, {
    required Duration initialDelay,
    required Constraints constraints,
  });
}

class WorkmanagerScheduler implements BackgroundScheduler {
  WorkmanagerScheduler({
    WorkmanagerPort? platform,
    DateTime Function()? clock,
    bool completingTask = false,
  }) : _platform =
           platform ?? NativeWorkmanagerPort(completingTask: completingTask),
       _completingTask = completingTask,
       _clock = clock ?? DateTime.now;

  static const uniqueTaskName = 'maoguai_daily_signin';
  final WorkmanagerPort _platform;
  final DateTime Function() _clock;
  final bool _completingTask;

  Future<void> initialize() => _platform.initialize(callbackDispatcher);

  @override
  Future<void> schedule(DailyPlan plan) async {
    final delay = plan.plannedAt.difference(_clock());
    // Cancelling the active Android worker destroys its headless engine before
    // tomorrow's task can be enqueued. Its completion appends a successor.
    if (!_completingTask) await cancel();
    await _platform.schedule(
      uniqueTaskName,
      initialDelay: delay.isNegative ? Duration.zero : delay,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  @override
  Future<void> cancel() => _platform.cancelByUniqueName(uniqueTaskName);
}

class NativeWorkmanagerPort implements WorkmanagerPort {
  NativeWorkmanagerPort({
    Workmanager? workmanager,
    TargetPlatform? targetPlatform,
    this._completingTask = false,
  }) : _workmanager = workmanager ?? Workmanager(),
       _targetPlatform = targetPlatform ?? defaultTargetPlatform;

  static const iosTaskIdentifier = 'com.qqiu7186.maoguai-signin.daily';
  final Workmanager _workmanager;
  final TargetPlatform _targetPlatform;
  final bool _completingTask;

  @override
  Future<void> initialize(void Function() dispatcher) =>
      _workmanager.initialize(dispatcher);

  @override
  Future<void> cancelByUniqueName(String uniqueName) =>
      _workmanager.cancelByUniqueName(_nativeName(uniqueName));

  String _nativeName(String uniqueName) =>
      _targetPlatform == TargetPlatform.iOS &&
          uniqueName == WorkmanagerScheduler.uniqueTaskName
      ? iosTaskIdentifier
      : uniqueName;

  @override
  Future<void> schedule(
    String uniqueName, {
    required Duration initialDelay,
    required Constraints constraints,
  }) {
    if (_targetPlatform == TargetPlatform.iOS) {
      // BGProcessingTask's earliestBeginDate is only a hint. iOS may delay or
      // omit execution; callbacks use the same idempotent sign-in flow.
      return _workmanager.registerProcessingTask(
        _nativeName(uniqueName),
        uniqueName,
        initialDelay: initialDelay,
        constraints: constraints,
      );
    }
    return _workmanager.registerOneOffTask(
      uniqueName,
      uniqueName,
      initialDelay: initialDelay,
      constraints: constraints,
      // Workmanager 0.10's update maps to Android APPEND_OR_REPLACE.
      existingWorkPolicy: _completingTask
          ? ExistingWorkPolicy.update
          : ExistingWorkPolicy.replace,
    );
  }
}

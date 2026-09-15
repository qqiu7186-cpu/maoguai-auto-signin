import 'dart:async';
import 'dart:io' show Platform;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import '../domain/sign_in_models.dart';
import 'background_scheduler.dart';
import 'workmanager_scheduler.dart';

abstract interface class AndroidAlarmPort {
  Future<bool> initialize();
  Future<bool> canScheduleExactAlarms();
  Future<bool> openExactAlarmSettings();
  Future<bool> scheduleAt(
    DateTime time, {
    required bool exact,
    required bool allowWhileIdle,
    required bool wakeup,
    required bool rescheduleOnReboot,
  });
  Future<bool> cancel();
}

class AndroidAlarmScheduler
    implements
        BackgroundScheduler,
        InitializableBackgroundScheduler,
        BackgroundSchedulerSettings {
  AndroidAlarmScheduler({
    AndroidAlarmPort? alarms,
    required this.fallback,
    this.fallbackDelay = const Duration(minutes: 15),
  }) : _alarms = alarms ?? NativeAndroidAlarmPort();

  final AndroidAlarmPort _alarms;
  final BackgroundScheduler fallback;
  final Duration fallbackDelay;

  @override
  Future<void> initialize() async {
    await _alarms.initialize();
    final fallbackScheduler = fallback;
    if (fallbackScheduler
        case final InitializableBackgroundScheduler initializable) {
      await initializable.initialize();
    }
  }

  @override
  Future<BackgroundScheduleStatus> status() async {
    try {
      return await _alarms.canScheduleExactAlarms()
          ? BackgroundScheduleStatus.exact
          : BackgroundScheduleStatus.permissionNeeded;
    } catch (_) {
      return BackgroundScheduleStatus.fallbackOnly;
    }
  }

  @override
  Future<bool> openSystemSettings() => _alarms.openExactAlarmSettings();

  @override
  Future<void> schedule(DailyPlan plan) async {
    await fallback.schedule(
      plan.copyWith(plannedAt: plan.plannedAt.add(fallbackDelay)),
    );
    await _alarms.scheduleAt(
      plan.plannedAt,
      // The plugin silently drops an exact alarm when Android has revoked the
      // special access. Always request the exact trigger and keep the
      // independently registered WorkManager fallback above.
      exact: true,
      allowWhileIdle: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );
  }

  @override
  Future<void> cancel() async {
    Object? firstError;
    try {
      await _alarms.cancel();
    } catch (error) {
      firstError = error;
    }
    try {
      await fallback.cancel();
    } catch (error) {
      firstError ??= error;
    }
    if (firstError != null) throw firstError;
  }
}

@pragma('vm:entry-point')
void androidAlarmCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(
    enqueueAndroidDueWork().catchError((_) {
      // The separately scheduled delayed worker remains available if this
      // immediate handoff fails.
    }),
  );
}

Future<void> enqueueAndroidDueWork({WorkmanagerPort? workmanager}) =>
    (workmanager ?? NativeWorkmanagerPort()).schedule(
      WorkmanagerScheduler.uniqueTaskName,
      initialDelay: Duration.zero,
      constraints: Constraints(networkType: NetworkType.connected),
    );

class NativeAndroidAlarmPort implements AndroidAlarmPort {
  NativeAndroidAlarmPort({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('maoguai/exact_alarm');

  static const alarmId = 2550505;
  final MethodChannel _channel;

  @override
  Future<bool> initialize() => AndroidAlarmManager.initialize();

  @override
  Future<bool> canScheduleExactAlarms() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canScheduleExactAlarms') ?? false;
  }

  @override
  Future<bool> openExactAlarmSettings() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('openExactAlarmSettings') ?? false;
  }

  @override
  Future<bool> scheduleAt(
    DateTime time, {
    required bool exact,
    required bool allowWhileIdle,
    required bool wakeup,
    required bool rescheduleOnReboot,
  }) => AndroidAlarmManager.oneShotAt(
    time,
    alarmId,
    androidAlarmCallback,
    exact: exact,
    allowWhileIdle: allowWhileIdle,
    wakeup: wakeup,
    rescheduleOnReboot: rescheduleOnReboot,
  );

  @override
  Future<bool> cancel() => AndroidAlarmManager.cancel(alarmId);
}

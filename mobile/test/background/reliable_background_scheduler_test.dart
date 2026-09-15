import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/app_state.dart';
import 'package:maoguai_signin/background/android_alarm_scheduler.dart';
import 'package:maoguai_signin/background/background_scheduler.dart';
import 'package:maoguai_signin/background/workmanager_scheduler.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:workmanager/workmanager.dart';

void main() {
  final plan = DailyPlan(
    day: '2026-09-15',
    startMinute: 480,
    endMinute: 600,
    plannedAt: DateTime(2026, 9, 15, 8, 37),
    status: DailyPlanStatus.planned,
  );

  test('Android schedules an exact wakeup and a delayed fallback', () async {
    final alarms = RecordingAlarmPort(exactPermission: true);
    final fallback = RecordingScheduler();
    final scheduler = AndroidAlarmScheduler(alarms: alarms, fallback: fallback);

    await scheduler.initialize();
    await scheduler.schedule(plan);

    expect(alarms.initialized, isTrue);
    expect(alarms.scheduledAt, plan.plannedAt);
    expect(alarms.exact, isTrue);
    expect(alarms.allowWhileIdle, isTrue);
    expect(alarms.wakeup, isTrue);
    expect(alarms.rescheduleOnReboot, isTrue);
    expect(fallback.scheduledPlan!.plannedAt, DateTime(2026, 9, 15, 8, 52));
    expect(scheduler, isA<InitializableBackgroundScheduler>());
  });

  test(
    'Android without exact access still requests exact and installs fallback',
    () async {
      final alarms = RecordingAlarmPort(exactPermission: false);
      final fallback = RecordingScheduler();
      final scheduler = AndroidAlarmScheduler(
        alarms: alarms,
        fallback: fallback,
      );

      await scheduler.initialize();
      await scheduler.schedule(plan);

      expect(alarms.scheduledAt, plan.plannedAt);
      expect(alarms.exact, isTrue);
      expect(alarms.allowWhileIdle, isTrue);
      expect(fallback.scheduledPlan, isNotNull);
      expect(
        await scheduler.status(),
        BackgroundScheduleStatus.permissionNeeded,
      );
    },
  );

  test('Android cancels both exact wakeup and fallback', () async {
    final alarms = RecordingAlarmPort(exactPermission: true);
    final fallback = RecordingScheduler();
    final scheduler = AndroidAlarmScheduler(alarms: alarms, fallback: fallback);

    await scheduler.cancel();

    expect(alarms.cancelled, isTrue);
    expect(fallback.cancelled, isTrue);
  });

  test('production dependencies select the Android exact scheduler', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(
      AppDependencies.production().scheduler,
      isA<AndroidAlarmScheduler>(),
    );
  });

  test('Android alarm callback is synchronous for reliable job handoff', () {
    expect(androidAlarmCallback is Future<void> Function(), isFalse);
  });

  test(
    'Android alarm hands due work to a network-constrained worker',
    () async {
      final worker = RecordingWorkmanagerPort();

      await enqueueAndroidDueWork(workmanager: worker);

      expect(worker.uniqueName, WorkmanagerScheduler.uniqueTaskName);
      expect(worker.delay, Duration.zero);
      expect(worker.constraints?.networkType, NetworkType.connected);
    },
  );
}

class RecordingAlarmPort implements AndroidAlarmPort {
  RecordingAlarmPort({required this.exactPermission});

  final bool exactPermission;
  bool initialized = false;
  bool cancelled = false;
  DateTime? scheduledAt;
  bool? exact;
  bool? allowWhileIdle;
  bool? wakeup;
  bool? rescheduleOnReboot;

  @override
  Future<bool> initialize() async {
    initialized = true;
    return true;
  }

  @override
  Future<bool> canScheduleExactAlarms() async => exactPermission;

  @override
  Future<bool> scheduleAt(
    DateTime time, {
    required bool exact,
    required bool allowWhileIdle,
    required bool wakeup,
    required bool rescheduleOnReboot,
  }) async {
    scheduledAt = time;
    this.exact = exact;
    this.allowWhileIdle = allowWhileIdle;
    this.wakeup = wakeup;
    this.rescheduleOnReboot = rescheduleOnReboot;
    return true;
  }

  @override
  Future<bool> cancel() async {
    cancelled = true;
    return true;
  }

  @override
  Future<bool> openExactAlarmSettings() async => true;
}

class RecordingScheduler implements BackgroundScheduler {
  DailyPlan? scheduledPlan;
  bool cancelled = false;

  @override
  Future<void> schedule(DailyPlan plan) async => scheduledPlan = plan;

  @override
  Future<void> cancel() async => cancelled = true;
}

class RecordingWorkmanagerPort implements WorkmanagerPort {
  String? uniqueName;
  Duration? delay;
  Constraints? constraints;

  @override
  Future<void> initialize(void Function() dispatcher) async {}

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {}

  @override
  Future<void> schedule(
    String uniqueName, {
    required Duration initialDelay,
    required Constraints constraints,
  }) async {
    this.uniqueName = uniqueName;
    delay = initialDelay;
    this.constraints = constraints;
  }
}

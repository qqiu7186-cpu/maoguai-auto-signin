import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:maoguai_signin/background/background_entrypoint.dart';
import 'package:maoguai_signin/background/background_scheduler.dart';
import 'package:maoguai_signin/background/scheduled_task_runner.dart';
import 'package:maoguai_signin/background/workmanager_scheduler.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/notifications/sign_in_notifications.dart';
import 'package:maoguai_signin/schedule/daily_plan_service.dart';
import 'package:maoguai_signin/signin/maoguai_sign_in_client.dart';
import 'package:maoguai_signin/signin/sign_in_coordinator.dart';
import 'package:maoguai_signin/storage/app_database.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workmanager/workmanager.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late TestDatabaseBundle bundle;
  setUp(() async {
    bundle = await openTestDatabase();
    await bundle.repository.saveSettings(
      ScheduleSettings(
        enabled: true,
        notificationsEnabled: true,
        startMinute: 480,
        endMinute: 600,
      ),
    );
  });
  tearDown(() => bundle.database.close());

  test(
    'background cleanup leaves same-path foreground repository usable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'signin-connection-',
      );
      final previousFactory = sqflite.databaseFactoryOrNull;
      final previousPath = await databaseFactoryFfi.getDatabasesPath();
      sqflite.databaseFactoryOrNull = databaseFactoryFfi;
      await databaseFactoryFfi.setDatabasesPath(directory.path);
      addTearDown(() async {
        sqflite.databaseFactoryOrNull = previousFactory;
        await databaseFactoryFfi.setDatabasesPath(previousPath);
        await directory.delete(recursive: true);
      });
      final foreground = await AppDatabase.open();
      addTearDown(foreground.close);
      final repository = SqliteSignInRepository(foreground);
      await repository.activateAccount();
      await repository.upsertPlan(planAt(9, 20));
      final background = await BackgroundDependencies.create();
      expect(background.gateway, isA<MaoguaiSignInClient>());
      expect(
        await background.repository.planForDay('2026-09-09'),
        planAt(9, 20),
      );
      await background.close!();
      await repository.saveSettings(
        ScheduleSettings(
          enabled: false,
          notificationsEnabled: false,
          startMinute: 600,
          endMinute: 660,
        ),
      );
      expect((await repository.loadSettings()).enabled, isFalse);
      expect(await repository.planForDay('2026-09-09'), planAt(9, 20));
    },
  );

  for (final hour in [0, 10]) {
    test(
      'callback delayed to next day at $hour resolves that day before advancing',
      () async {
        await bundle.repository.upsertPlan(planAt(9, 20));
        final executor = FakeSignInExecutor();
        final scheduler = FakeScheduler();
        final plans = DailyPlanService(
          bundle.repository,
          chooseSecond: (_, _) => 1200,
        );
        expect(
          await executeBackgroundTask(
            clock: () => DateTime(2026, 9, 10, hour, 20),
            createDependencies: () async => BackgroundDependencies(
              runner: ScheduledTaskRunner(
                notifications: FakeNotificationService(),
                executor: executor,
                repository: bundle.repository,
              ),
              repository: bundle.repository,
              planService: plans,
              scheduler: scheduler,
            ),
          ),
          isTrue,
        );
        final today = await bundle.repository.planForDay('2026-09-10');
        expect(today, isNotNull);
        expect(today!.plannedAt, DateTime(2026, 9, 10, 8, 20));
        expect(executor.calls, hour == 0 ? 0 : 1);
        expect(scheduler.plan!.day, hour == 0 ? '2026-09-10' : '2026-09-11');
      },
    );
  }

  test(
    'explicit replaced same-day snapshot never runs against a later plan',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      final plans = DailyPlanService(
        bundle.repository,
        chooseSecond: (_, _) => 1800,
      );
      final replacement = await plans.updateSettings(
        (await bundle.repository.loadSettings()).copyWith(
          startMinute: 660,
          endMinute: 720,
        ),
        DateTime(2026, 9, 9, 10),
      );
      final executor = FakeSignInExecutor();
      final events = <String>[];
      await ScheduledTaskRunner(
        notifications: FakeNotificationService(events: events),
        executor: executor,
        repository: bundle.repository,
      ).runScheduled(now: DateTime(2026, 9, 9, 10, 20), plan: planAt(9, 20));
      expect(replacement.plannedAt, DateTime(2026, 9, 9, 11, 30));
      expect(executor.calls, 0);
      expect(events, isEmpty);
    },
  );

  for (final disable in [false, true]) {
    test(
      'execution boundary rechecks ${disable ? 'enablement' : 'plan identity'} after late notice',
      () async {
        await bundle.repository.upsertPlan(planAt(9, 20));
        final plans = DailyPlanService(
          bundle.repository,
          chooseSecond: (_, _) => 1800,
        );
        final executor = FakeSignInExecutor();
        final notifications = FakeNotificationService(
          onLate: () async {
            final settings = await bundle.repository.loadSettings();
            await plans.updateSettings(
              disable
                  ? settings.copyWith(enabled: false)
                  : settings.copyWith(startMinute: 660, endMinute: 720),
              DateTime(2026, 9, 9, 10, 20),
            );
          },
        );
        await ScheduledTaskRunner(
          notifications: notifications,
          executor: executor,
          repository: bundle.repository,
        ).runScheduled(now: DateTime(2026, 9, 9, 10, 20));
        expect(notifications.events, ['notify']);
        expect(executor.calls, 0);
        expect(await bundle.repository.recordsForDay('2026-09-09'), isEmpty);
      },
    );
  }

  test(
    'callback retains a due replacement after notification race skips old plan',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      final plans = DailyPlanService(
        bundle.repository,
        chooseSecond: (_, _) => 600,
      );
      final scheduler = FakeScheduler();
      final executor = FakeSignInExecutor();
      final notifications = FakeNotificationService(
        onLate: () async {
          await plans.updateSettings(
            (await bundle.repository.loadSettings()).copyWith(
              startMinute: 600,
              endMinute: 660,
            ),
            DateTime(2026, 9, 9, 10, 20),
          );
        },
      );
      await executeBackgroundTask(
        clock: () => DateTime(2026, 9, 9, 10, 20),
        createDependencies: () async => BackgroundDependencies(
          runner: ScheduledTaskRunner(
            notifications: notifications,
            executor: executor,
            repository: bundle.repository,
          ),
          repository: bundle.repository,
          planService: plans,
          scheduler: scheduler,
        ),
      );
      expect(executor.calls, 0);
      expect(scheduler.plan!.day, '2026-09-09');
      expect(scheduler.plan!.plannedAt, DateTime(2026, 9, 9, 10, 10));
    },
  );

  test(
    'completion scheduling does not cancel its own running worker',
    () async {
      final platform = FakeWorkmanagerPort();
      await WorkmanagerScheduler(
        platform: platform,
        completingTask: true,
        clock: () => DateTime(2026, 9, 9, 7),
      ).schedule(planAt(9, 20));
      expect(platform.events, ['schedule']);
    },
  );

  test(
    'native Android completion appends while settings changes replace',
    () async {
      final workmanager = Workmanager();
      final previous = WorkmanagerPlatform.instance;
      final platform = FakeNativeWorkmanager();
      WorkmanagerPlatform.instance = platform;
      addTearDown(() => WorkmanagerPlatform.instance = previous);
      final constraints = Constraints(networkType: NetworkType.connected);
      await NativeWorkmanagerPort(
        workmanager: workmanager,
        targetPlatform: TargetPlatform.android,
      ).schedule(
        'maoguai_daily_signin',
        initialDelay: Duration.zero,
        constraints: constraints,
      );
      expect(platform.policy, ExistingWorkPolicy.replace);
      await NativeWorkmanagerPort(
        workmanager: workmanager,
        targetPlatform: TargetPlatform.android,
        completingTask: true,
      ).schedule(
        'maoguai_daily_signin',
        initialDelay: Duration.zero,
        constraints: constraints,
      );
      expect(platform.policy, ExistingWorkPolicy.update);
      expect(platform.kind, 'oneOff');
    },
  );

  test(
    'native iOS uses processing task with earliest delay and network',
    () async {
      final workmanager = Workmanager();
      final previous = WorkmanagerPlatform.instance;
      final platform = FakeNativeWorkmanager();
      WorkmanagerPlatform.instance = platform;
      addTearDown(() => WorkmanagerPlatform.instance = previous);
      await NativeWorkmanagerPort(
        workmanager: workmanager,
        targetPlatform: TargetPlatform.iOS,
      ).schedule(
        'maoguai_daily_signin',
        initialDelay: const Duration(hours: 2),
        constraints: Constraints(networkType: NetworkType.connected),
      );
      expect(platform.kind, 'processing');
      expect(platform.uniqueName, 'com.qqiu7186.maoguai-signin.daily');
      expect(platform.taskName, 'maoguai_daily_signin');
      expect(platform.delay, const Duration(hours: 2));
      expect(platform.constraints!.networkType, NetworkType.connected);
      await NativeWorkmanagerPort(
        workmanager: workmanager,
        targetPlatform: TargetPlatform.iOS,
      ).cancelByUniqueName('maoguai_daily_signin');
      expect(platform.cancelled, 'com.qqiu7186.maoguai-signin.daily');
    },
  );

  test('schedule cancels then replaces one network constrained task', () async {
    final platform = FakeWorkmanagerPort();
    final scheduler = WorkmanagerScheduler(
      platform: platform,
      clock: () => DateTime(2026, 9, 9, 7),
    );
    await scheduler.schedule(planAt(9, 20));
    expect(platform.events, ['cancel', 'schedule']);
    expect(platform.cancelledUniqueName, 'maoguai_daily_signin');
    expect(platform.uniqueName, 'maoguai_daily_signin');
    expect(platform.lastInitialDelay, const Duration(hours: 2, minutes: 20));
    expect(platform.constraints!.networkType, NetworkType.connected);
    await scheduler.cancel();
    expect(platform.events, ['cancel', 'schedule', 'cancel']);
  });

  test('past plans use zero delay rather than a negative duration', () async {
    final platform = FakeWorkmanagerPort();
    await WorkmanagerScheduler(
      platform: platform,
      clock: () => DateTime(2026, 9, 9, 11),
    ).schedule(planAt(9, 20));
    expect(platform.lastInitialDelay, Duration.zero);
  });

  test('late task notifies before executor and then shows result', () async {
    final events = <String>[];
    final executor = FakeSignInExecutor(
      onRun: () async {
        events.add('sign');
        return const SignInResult.success();
      },
    );
    final runner = ScheduledTaskRunner(
      notifications: FakeNotificationService(events: events),
      executor: executor,
    );
    await runner.runScheduled(
      now: DateTime(2026, 9, 9, 10, 20),
      plan: planAt(9, 20),
    );
    expect(events, ['notify', 'sign', 'result']);
    expect(executor.source, TriggerSource.lateCatchUp);
  });

  test('at planned time executes scheduled without late notice', () async {
    final events = <String>[];
    final executor = FakeSignInExecutor();
    await ScheduledTaskRunner(
      notifications: FakeNotificationService(events: events),
      executor: executor,
    ).runScheduled(now: DateTime(2026, 9, 9, 9, 20), plan: planAt(9, 20));
    expect(events, ['result']);
    expect(executor.source, TriggerSource.scheduled);
  });

  test('headless runner loads today persisted plan', () async {
    await bundle.repository.upsertPlan(planAt(9, 20));
    final executor = FakeSignInExecutor();
    final events = <String>[];
    await ScheduledTaskRunner(
      notifications: FakeNotificationService(events: events),
      executor: executor,
      repository: bundle.repository,
    ).runScheduled(now: DateTime(2026, 9, 9, 10, 20));
    expect(executor.source, TriggerSource.lateCatchUp);
    expect(events, ['notify', 'result']);
  });

  test('missing, stale and early plans never execute sign in', () async {
    final executor = FakeSignInExecutor();
    final runner = ScheduledTaskRunner(
      notifications: FakeNotificationService(),
      executor: executor,
      repository: bundle.repository,
    );
    await runner.runScheduled(now: DateTime(2026, 9, 9, 10));
    await runner.runScheduled(
      now: DateTime(2026, 9, 10, 10),
      plan: planAt(9, 20),
    );
    await runner.runScheduled(
      now: DateTime(2026, 9, 9, 8),
      plan: planAt(9, 20),
    );
    expect(executor.calls, 0);
  });

  test(
    'notification failure never prevents executor record persistence',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      final executor = FakeSignInExecutor(
        onRun: () async {
          final record = await bundle.repository.insertRecord(
            SignInRecord(
              day: '2026-09-09',
              occurredAt: DateTime(2026, 9, 9, 10, 20),
              source: TriggerSource.lateCatchUp,
              status: SignInRecordStatus.success,
              title: '签到成功',
              detail: '已完成今日签到。',
            ),
          );
          return SignInResult.success(record: record);
        },
      );
      final notifications = FakeNotificationService(fail: true);
      final result = await ScheduledTaskRunner(
        notifications: notifications,
        executor: executor,
        repository: bundle.repository,
      ).runScheduled(now: DateTime(2026, 9, 9, 10, 20));
      expect(result.status, SignInRecordStatus.success);
      expect(await bundle.repository.recordsForDay('2026-09-09'), [
        result.record,
      ]);
      expect(notifications.permissionRequests, 0);
    },
  );

  test(
    'disabled automation prevents stale queued work and cancels next task',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      await bundle.repository.saveSettings(
        (await bundle.repository.loadSettings()).copyWith(enabled: false),
      );
      final executor = FakeSignInExecutor();
      final scheduler = FakeScheduler();
      expect(
        await executeBackgroundTask(
          clock: () => DateTime(2026, 9, 9, 10, 20),
          createDependencies: () async => BackgroundDependencies(
            runner: ScheduledTaskRunner(
              notifications: FakeNotificationService(),
              executor: executor,
              repository: bundle.repository,
            ),
            repository: bundle.repository,
            planService: DailyPlanService(bundle.repository),
            scheduler: scheduler,
          ),
        ),
        isTrue,
      );
      expect(executor.calls, 0);
      expect(scheduler.cancelled, isTrue);
      expect(scheduler.plan, isNull);
    },
  );

  test(
    'failed execution is recorded once and next day scheduled without retry',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      final executor = FakeSignInExecutor(
        onRun: () async => throw StateError('secret-response'),
      );
      final scheduler = FakeScheduler();
      var closed = false;
      final result = await executeBackgroundTask(
        clock: () => DateTime(2026, 9, 9, 10, 20),
        createDependencies: () async => BackgroundDependencies(
          runner: ScheduledTaskRunner(
            notifications: FakeNotificationService(),
            executor: executor,
            repository: bundle.repository,
          ),
          repository: bundle.repository,
          planService: DailyPlanService(bundle.repository),
          scheduler: scheduler,
          close: () async {
            closed = true;
          },
        ),
      );
      expect(result, isTrue);
      expect(executor.calls, 1);
      expect(scheduler.plan!.day, '2026-09-10');
      expect(closed, isTrue);
      final records = await bundle.repository.recordsForDay('2026-09-09');
      expect(records, hasLength(1));
      expect(records.single.status, SignInRecordStatus.failed);
      expect(records.single.detail, isNot(contains('secret-response')));
    },
  );

  test(
    'unexpected failure after atomic claim preserves unknown and attempt',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      final attemptedAt = DateTime(2026, 9, 9, 10, 20);
      await bundle.repository.claimAttempt(
        day: '2026-09-09',
        attemptedAt: attemptedAt,
        lateExecution: true,
      );
      final executor = FakeSignInExecutor(
        onRun: () async => throw StateError('lost result'),
      );
      final result = await ScheduledTaskRunner(
        notifications: FakeNotificationService(),
        executor: executor,
        repository: bundle.repository,
      ).runScheduled(now: attemptedAt);
      expect(result.status, SignInRecordStatus.unknown);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        attemptedAt,
      );
      expect(executor.calls, 1);
    },
  );

  test(
    'an early callback retains today task instead of skipping to tomorrow',
    () async {
      await bundle.repository.upsertPlan(planAt(9, 20));
      final executor = FakeSignInExecutor();
      final scheduler = FakeScheduler();
      await executeBackgroundTask(
        clock: () => DateTime(2026, 9, 9, 8),
        createDependencies: () async => BackgroundDependencies(
          runner: ScheduledTaskRunner(
            notifications: FakeNotificationService(),
            executor: executor,
            repository: bundle.repository,
          ),
          repository: bundle.repository,
          planService: DailyPlanService(bundle.repository),
          scheduler: scheduler,
        ),
      );
      expect(executor.calls, 0);
      expect(scheduler.plan, planAt(9, 20));
    },
  );

  test(
    'dependency initialization failure returns success to avoid blind retry',
    () async {
      expect(
        await executeBackgroundTask(
          createDependencies: () async =>
              throw StateError('storage unavailable'),
        ),
        isTrue,
      );
    },
  );
}

DailyPlan planAt(int hour, int minute) => DailyPlan(
  day: '2026-09-09',
  startMinute: 480,
  endMinute: 600,
  plannedAt: DateTime(2026, 9, 9, hour, minute),
  status: DailyPlanStatus.planned,
);

class FakeWorkmanagerPort implements WorkmanagerPort {
  final events = <String>[];
  String? cancelledUniqueName;
  String? uniqueName;
  Duration? lastInitialDelay;
  Constraints? constraints;
  @override
  Future<void> initialize(void Function() dispatcher) async {}
  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    events.add('cancel');
    cancelledUniqueName = uniqueName;
  }

  @override
  Future<void> schedule(
    String uniqueName, {
    required Duration initialDelay,
    required Constraints constraints,
  }) async {
    events.add('schedule');
    this.uniqueName = uniqueName;
    lastInitialDelay = initialDelay;
    this.constraints = constraints;
  }
}

class FakeNotificationService implements NotificationService {
  FakeNotificationService({
    List<String>? events,
    this.fail = false,
    this.onLate,
  }) : events = events ?? [];
  final Future<void> Function()? onLate;
  final List<String> events;
  final bool fail;
  int permissionRequests = 0;
  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return false;
  }

  @override
  Future<bool> openNotificationSettings() async => false;

  @override
  Future<void> showLateCatchUp(
    DailyPlan plan,
    DateTime actualAt, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) async {
    events.add('notify');
    await onLate?.call();
    if (fail) throw StateError('permission denied');
  }

  @override
  Future<void> showResult(
    SignInResult result, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) async {
    if (isCurrent != null && !await isCurrent()) return;
    events.add('result');
    if (fail) throw StateError('permission denied');
  }
}

class FakeSignInExecutor implements SignInExecutor {
  FakeSignInExecutor({this.onRun});
  final Future<SignInResult> Function()? onRun;
  TriggerSource? source;
  int calls = 0;
  @override
  Stream<DailyPlanStatus> get statusChanges => const Stream.empty();
  @override
  Future<SignInResult> run({
    required TriggerSource source,
    required DateTime now,
    int? generation,
    DailyPlan? expectedPlan,
  }) async {
    calls++;
    this.source = source;
    return onRun == null ? const SignInResult.success() : await onRun!();
  }

  @override
  Future<SignInResult> confirmUnknown(DateTime now, {int? generation}) =>
      throw UnimplementedError();
}

class FakeScheduler implements BackgroundScheduler {
  DailyPlan? plan;
  bool cancelled = false;
  @override
  Future<void> schedule(DailyPlan plan) async {
    this.plan = plan;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class FakeNativeWorkmanager extends WorkmanagerPlatform {
  String? kind;
  String? uniqueName;
  String? taskName;
  Duration? delay;
  Constraints? constraints;
  ExistingWorkPolicy? policy;
  String? cancelled;
  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelled = uniqueName;
  }

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async {
    kind = 'oneOff';
    this.uniqueName = uniqueName;
    this.taskName = taskName;
    delay = initialDelay;
    this.constraints = constraints;
    policy = existingWorkPolicy;
  }

  @override
  Future<void> registerProcessingTask(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
    Map<String, dynamic>? inputData,
    Constraints? constraints,
  }) async {
    kind = 'processing';
    this.uniqueName = uniqueName;
    this.taskName = taskName;
    delay = initialDelay;
    this.constraints = constraints;
  }
}

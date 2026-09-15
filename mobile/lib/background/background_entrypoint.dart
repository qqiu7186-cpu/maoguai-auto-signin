import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../auth/credential_store.dart';
import '../auth/session_store.dart';
import '../domain/sign_in_models.dart';
import '../notifications/sign_in_notifications.dart';
import '../schedule/daily_plan_service.dart';
import '../signin/maoguai_sign_in_client.dart';
import '../signin/sign_in_coordinator.dart';
import '../signin/sign_in_gateway.dart';
import '../storage/app_database.dart';
import '../storage/sign_in_repository.dart';
import 'background_scheduler.dart';
import 'production_background_scheduler.dart';
import 'scheduled_task_runner.dart';
import 'workmanager_scheduler.dart';

class BackgroundDependencies {
  BackgroundDependencies({
    required this.runner,
    required this.repository,
    required this.planService,
    required this.scheduler,
    this.gateway,
    this.close,
  });

  final ScheduledTaskRunner runner;
  final SignInRepository repository;
  final DailyPlanService planService;
  final BackgroundScheduler scheduler;
  final SignInGateway? gateway;
  final Future<void> Function()? close;

  static Future<BackgroundDependencies> create({
    bool completingWorkmanagerTask = false,
  }) async {
    // Own this connection while sharing the foreground's durable database.
    // A singleInstance handle could close the foreground connection in the
    // plugin's main-engine callback path when this task finishes.
    final database = await AppDatabase.open(singleInstance: false);
    final repository = SqliteSignInRepository(database);
    final plans = DailyPlanService(repository);
    const credentials = SecureCredentialStore();
    final sessions = GuardedSessionStore(
      delegate: const SecureSessionStore(),
      credentials: credentials,
      repository: repository,
    );
    final notifications = SignInNotifications(
      enabled: () async =>
          (await repository.loadSettings()).notificationsEnabled,
    );
    final gateway = MaoguaiSignInClient(sessionStore: sessions);
    final executor = SignInCoordinator(
      gateway: gateway,
      credentialStore: credentials,
      sessionStore: sessions,
      repository: repository,
      planService: plans,
    );
    return BackgroundDependencies(
      runner: ScheduledTaskRunner(
        notifications: notifications,
        executor: executor,
        repository: repository,
      ),
      repository: repository,
      planService: plans,
      scheduler: createProductionBackgroundScheduler(
        completingWorkmanagerTask: completingWorkmanagerTask,
      ),
      gateway: gateway,
      close: database.close,
    );
  }
}

/// Always acknowledge work: Workmanager retry could replay an accepted POST.
Future<bool> executeBackgroundTask({
  Future<BackgroundDependencies> Function()? createDependencies,
  DateTime Function()? clock,
  bool completingWorkmanagerTask = false,
}) async {
  BackgroundDependencies? dependencies;
  try {
    dependencies =
        await (createDependencies ??
            () => BackgroundDependencies.create(
              completingWorkmanagerTask: completingWorkmanagerTask,
            ))();
    final readClock = clock ?? DateTime.now;
    final now = readClock();
    final generation = await dependencies.repository.activeGeneration();
    if (generation == null) return true;
    final repository = dependencies.repository.forGeneration(generation);
    final scheduledPlan = await dependencies.planService.ensureTodayPlan(
      now,
      generation: generation,
    );
    final outcome = await dependencies.runner.runScheduledWithOutcome(
      now: now,
      plan: scheduledPlan,
    );
    if (await repository.planForDay(scheduledPlan.day) == null) {
      // Logout removed the execution's day. Do not recreate settings or plans.
      return true;
    }
    if (!(await repository.loadSettings()).enabled) {
      await repository.withGeneration(
        generation,
        () => dependencies!.scheduler.cancel(),
      );
    } else {
      // Settings or the local date may change while the task is executing.
      // A skipped/replaced plan must not consume the new current-day plan.
      final finishedAt = readClock();
      final today = await dependencies.planService.ensureTodayPlan(
        finishedAt,
        generation: generation,
      );
      final terminal = const {
        DailyPlanStatus.success,
        DailyPlanStatus.done,
        DailyPlanStatus.failed,
        DailyPlanStatus.unknown,
      }.contains(today.status);
      final completedToday =
          outcome.executed &&
          ScheduledTaskRunner.samePlanIdentity(scheduledPlan, today);
      final nextPlan = completedToday || terminal
          ? await dependencies.planService.nextPlanAfterCompletion(
              finishedAt,
              generation: generation,
            )
          : today;
      if (await repository.activeGeneration() == null) return true;
      await repository.withGeneration(
        generation,
        () => dependencies!.scheduler.schedule(nextPlan),
      );
    }
  } catch (_) {
    // Coordinator/runner persist execution failures when storage is available.
    // Initialization, storage and scheduling failures cannot justify a retry.
  } finally {
    try {
      await dependencies?.close?.call();
    } catch (_) {
      /* Best effort close. */
    }
  }
  return true;
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task != WorkmanagerScheduler.uniqueTaskName &&
        task != NativeWorkmanagerPort.iosTaskIdentifier &&
        task != Workmanager.iOSBackgroundTask) {
      return true;
    }
    return executeBackgroundTask(completingWorkmanagerTask: true);
  });
}

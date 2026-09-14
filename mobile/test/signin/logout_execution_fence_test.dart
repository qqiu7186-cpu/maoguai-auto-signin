import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/app_state.dart';
import 'package:maoguai_signin/auth/credential_store.dart';
import 'package:maoguai_signin/auth/session_store.dart';
import 'package:maoguai_signin/background/background_entrypoint.dart';
import 'package:maoguai_signin/background/background_scheduler.dart';
import 'package:maoguai_signin/background/scheduled_task_runner.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/notifications/sign_in_notifications.dart';
import 'package:maoguai_signin/shortcuts/native_background_results.dart';
import 'package:maoguai_signin/schedule/daily_plan_service.dart';
import 'package:maoguai_signin/signin/sign_in_coordinator.dart';
import 'package:maoguai_signin/signin/sign_in_gateway.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';
import '../support/test_dependencies.dart';
import '../notifications/sign_in_notifications_test.dart'
    show FakeNotificationPort;

void main() {
  setUpAll(sqfliteFfiInit);
  late TestDatabaseBundle bundle;
  late TestDependencies fakes;
  late _SqliteDependencies dependencies;
  late SignInAppController controller;

  setUp(() async {
    bundle = await openTestDatabase();
    fakes = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 9, 9),
      settings: testSettings(),
    );
    dependencies = _SqliteDependencies(fakes, bundle.repository);
    controller = SignInAppController(dependencies);
    await controller.initialize();
    fakes.gateway.submitCompleter = Completer<void>();
    fakes.gateway.restoreSessionOnSubmit = true;
    fakes.scheduler.scheduledPlans.clear();
  });
  tearDown(() async {
    controller.dispose();
    await bundle.database.close();
  });

  Future<void> waitForClaim() async {
    while (fakes.gateway.submitCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
      (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
      isNotNull,
    );
  }

  Future<void> expectCleared() async {
    expect(await fakes.credentials.read(), isNull);
    expect(await fakes.sessions.read(), isNull);
    for (final table in [
      'schedule_settings',
      'daily_plans',
      'sign_in_records',
    ]) {
      expect(
        await bundle.database.database.query(table),
        isEmpty,
        reason: table,
      );
    }
  }

  test('logout during notification initialization suppresses platform delivery and defaults', () async {
    await controller.setNotificationsEnabled(true);
    final port = FakeNotificationPort()..initialization = Completer<void>();
    final notifications = SignInNotifications(
      platform: port,
      enabled: () async =>
          (await dependencies.repository.loadSettings()).notificationsEnabled,
    );
    final background = executeBackgroundTask(
      clock: dependencies.now,
      createDependencies: () async => BackgroundDependencies(
        runner: ScheduledTaskRunner(
          notifications: notifications,
          executor: dependencies.executor,
          repository: dependencies.repository,
        ),
        repository: dependencies.repository,
        planService: dependencies.planService,
        scheduler: dependencies.scheduler,
      ),
    );
    await port.initializationStarted.future;
    await controller.logout();
    port.initialization!.complete();
    await background;
    await expectCleared();
    expect(port.titles, isEmpty);
    expect(fakes.gateway.submitCalls, 0);
    expect(fakes.scheduler.scheduledPlans, isEmpty);
  });

  test('logout while successor planning awaits cannot recreate account defaults or schedules', () async {
    final plans = _PausedSuccessorPlans(dependencies.repository);
    fakes.gateway.submitCompleter!.complete();
    final background = executeBackgroundTask(
      clock: dependencies.now,
      createDependencies: () async => BackgroundDependencies(
        runner: ScheduledTaskRunner(
          notifications: dependencies.notifications,
          executor: dependencies.executor,
          repository: dependencies.repository,
        ),
        repository: dependencies.repository,
        planService: plans,
        scheduler: dependencies.scheduler,
      ),
    );
    await plans.entered.future;
    await controller.logout();
    plans.resume.complete();
    await background;
    await expectCleared();
    expect(fakes.scheduler.scheduledPlans, isEmpty);
  });

  test(
    'late account A result cannot enter a same-day account B login',
    () async {
      final background = executeBackgroundTask(
        clock: dependencies.now,
        createDependencies: () async => BackgroundDependencies(
          runner: ScheduledTaskRunner(
            notifications: dependencies.notifications,
            executor: dependencies.executor,
            repository: dependencies.repository,
          ),
          repository: dependencies.repository,
          planService: dependencies.planService,
          scheduler: dependencies.scheduler,
        ),
      );
      await waitForClaim();
      await controller.logout();
      await controller.login('account-B', 'password-B');
      final bPlan = controller.state.plan;
      fakes.gateway.submitCompleter!.complete();
      await background;
      await controller.refreshLocalState();
      expect((await fakes.credentials.read())!.username, 'account-B');
      expect(controller.state.plan, bPlan);
      expect(controller.state.records, isEmpty);
      expect(await bundle.repository.recordsForDay('2026-09-09'), isEmpty);
      expect(fakes.notifications.results, isEmpty);
    },
  );

  test(
    'a late session response cannot survive a pause between logout stages',
    () async {
      final background = executeBackgroundTask(
        clock: dependencies.now,
        createDependencies: () async => BackgroundDependencies(
          runner: ScheduledTaskRunner(
            notifications: dependencies.notifications,
            executor: dependencies.executor,
            repository: dependencies.repository,
          ),
          repository: dependencies.repository,
          planService: dependencies.planService,
          scheduler: dependencies.scheduler,
        ),
      );
      await waitForClaim();
      final sessionCleared = Completer<void>();
      final finishLogout = Completer<void>();
      fakes.sessions.afterClear = () async {
        sessionCleared.complete();
        await finishLogout.future;
      };
      final logout = controller.logout();
      await sessionCleared.future;
      fakes.gateway.submitCompleter!.complete();
      await background;
      finishLogout.complete();
      await logout;
      fakes.sessions.afterClear = null;
      await expectCleared();
    },
  );

  test('logout fences an independent background run paused after its durable claim', () async {
    final background = executeBackgroundTask(
      clock: dependencies.now,
      createDependencies: () async => BackgroundDependencies(
        runner: ScheduledTaskRunner(
          notifications: dependencies.notifications,
          executor: dependencies.executor,
          repository: dependencies.repository,
        ),
        repository: dependencies.repository,
        planService: dependencies.planService,
        scheduler: dependencies.scheduler,
      ),
    );
    await waitForClaim();
    await controller.logout();
    await expectCleared();
    fakes.gateway.submitCompleter!.complete();
    expect(await background, isTrue);
    await expectCleared();
    expect(controller.state.isLoggedIn, isFalse);
    expect(controller.state.records, isEmpty);
    expect(fakes.notifications.results, isEmpty);
    expect(fakes.scheduler.scheduledPlans, isEmpty);
    expect(fakes.gateway.submitCalls, 1);
  });

  test(
    'foreground drops its result if another execution clears the account',
    () async {
      final run = controller.runManualSignIn();
      await waitForClaim();
      await fakes.credentials.clear();
      await fakes.sessions.clear();
      await bundle.repository.clearAccountData();
      fakes.gateway.submitCompleter!.complete();
      await run;
      await expectCleared();
      expect(controller.state.isLoggedIn, isFalse);
      expect(controller.state.plan, isNull);
      expect(controller.state.records, isEmpty);
      expect(fakes.notifications.results, isEmpty);
    },
  );
}

class _PausedSuccessorPlans extends DailyPlanService {
  _PausedSuccessorPlans(super.repository)
    : super(chooseSecond: (min, max) => min);
  final entered = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<DailyPlan> nextPlanAfterCompletion(
    DateTime now, {
    int? generation,
  }) async {
    entered.complete();
    await resume.future;
    return super.nextPlanAfterCompletion(now, generation: generation);
  }
}

class _SqliteDependencies implements AppDependencies {
  _SqliteDependencies(this.fakes, this.repository) {
    planService = DailyPlanService(repository, chooseSecond: (min, max) => min);
    executor = SignInCoordinator(
      gateway: gateway,
      credentialStore: credentials,
      sessionStore: sessions,
      repository: repository,
      planService: planService,
      clock: now,
      sleep: (_) async {},
      chooseSecond: (min, max) => min,
    );
  }
  final TestDependencies fakes;
  @override
  final SignInRepository repository;
  @override
  late final DailyPlanService planService;
  @override
  late final SignInExecutor executor;
  @override
  CredentialStore get credentials => fakes.credentials;
  @override
  SessionStore get sessions => fakes.sessions;
  @override
  SignInGateway get gateway => fakes.gateway;
  @override
  BackgroundScheduler get scheduler => fakes.scheduler;
  @override
  NotificationService get notifications => fakes.notifications;
  @override
  NativeBackgroundResultPort get nativeBackgroundResults =>
      fakes.nativeBackgroundResults;
  @override
  DateTime now() => fakes.now();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> dispose() async {}
}

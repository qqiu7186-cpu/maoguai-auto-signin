import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/app_state.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/shortcuts/native_background_results.dart';

import 'support/test_dependencies.dart';

void main() {
  late TestDependencies deps;
  late SignInAppController controller;
  setUp(() {
    deps = TestDependencies(now: DateTime(2026, 9, 9, 7));
    controller = SignInAppController(deps);
  });
  tearDown(() => controller.dispose());
  Future<void> authenticate() async {
    await controller.initialize();
    await controller.login('student123', 'password');
  }

  test('fresh screen never claims notification permission', () {
    expect(controller.state.settings.notificationsEnabled, isFalse);
    expect(deps.notifications.permissionRequests, 0);
  });

  test('legacy secure data logs out before production bootstrap', () async {
    final legacyDeps = productionLikeDependenciesWithLegacySecureValues();
    final legacyController = SignInAppController(legacyDeps);
    addTearDown(legacyController.dispose);

    await legacyController.initialize();

    expect(legacyController.state.isLoggedIn, isFalse);
    expect(await legacyDeps.repository.activeGeneration(), isNull);
    expect(legacyDeps.scheduler.cancelled, isTrue);
  });

  test('range edits cannot enable notifications without permission', () async {
    await authenticate();
    await controller.setNotificationsEnabled(false);
    await controller.updateSchedule(testSettings(notificationsEnabled: true));
    expect(controller.state.settings.notificationsEnabled, isFalse);
    expect(deps.repository.settings.notificationsEnabled, isFalse);
    expect(deps.notifications.permissionRequests, 0);
  });

  test(
    'startup cannot reactivate credentials left during durable logout cleanup',
    () async {
      controller.dispose();
      deps = await TestDependencies.authenticated(
        now: DateTime(2026, 9, 9, 7),
        settings: testSettings(),
      );
      await deps.repository.clearAccountData();
      controller = SignInAppController(deps);
      await controller.initialize();
      expect(controller.state.isLoggedIn, isFalse);
      expect(await deps.repository.activeGeneration(), isNull);
      expect(deps.credentials.saved, isNull);
      expect(deps.sessions.saved, isNull);
      expect(deps.scheduler.scheduledPlans, isEmpty);
    },
  );

  test(
    'a stale controller refresh cannot adopt a newer account lifetime',
    () async {
      await authenticate();
      await deps.repository.clearAccountData();
      final generation = await deps.repository.activateAccount();
      final bPlan = await deps.planService.ensureTodayPlan(
        deps.now(),
        generation: generation,
      );
      await expectLater(
        controller.refreshLocalState(),
        throwsA(isA<SignInError>()),
      );
      expect(controller.state.isLoggedIn, isFalse);
      expect(controller.state.plan, isNull);
      expect(await deps.repository.planForDay(bPlan.day), bPlan);
    },
  );

  test('failed durable invalidation cannot claim logout or clear current credentials', () async {
    await authenticate();
    deps.repository.clearError = StateError('database unavailable');
    await expectLater(controller.logout(), throwsA(isA<SignInError>()));
    expect(controller.state.isLoggedIn, isTrue);
    expect(controller.state.error, isNotNull);
    expect(deps.credentials.saved, isNotNull);
    expect(deps.sessions.saved, isNotNull);
    expect(await deps.repository.activeGeneration(), isNotNull);
  });

  test('login validates remotely before secure save', () async {
    await controller.initialize();
    deps.gateway.authenticateCompleter = Completer<void>();
    final future = controller.login(' student123 ', 'password');
    await Future<void>.delayed(Duration.zero);
    expect(deps.gateway.authenticateCalls, 1);
    expect(deps.credentials.saved, isNull);
    expect(controller.state.isLoggedIn, isFalse);
    deps.gateway.authenticateCompleter!.complete();
    await future;
    expect(deps.credentials.saved!.username, 'student123');
    expect(deps.sessions.saved, isNotNull);
    expect(controller.state.maskedUsername, 'st******23');
    expect(controller.state.isLoggedIn, isTrue);
    expect(deps.gateway.submitCalls, 0);
  });
  test('failed login does not save credentials or create records', () async {
    deps.gateway.authenticateError = const SignInError(
      SignInErrorKind.invalidCredentials,
    );
    await controller.initialize();
    await expectLater(
      controller.login('bad', 'bad'),
      throwsA(isA<SignInError>()),
    );
    expect(deps.credentials.saved, isNull);
    expect(deps.sessions.saved, isNull);
    expect(controller.state.isLoggedIn, isFalse);
    expect(controller.state.records, isEmpty);
    expect(deps.repository.records, isEmpty);
  });
  test('credential save failure removes the newly persisted session', () async {
    deps.credentials.saveError = StateError('secure storage unavailable');
    await controller.initialize();
    await expectLater(
      controller.login('student', 'password'),
      throwsA(
        isA<SignInError>().having(
          (error) => error.kind,
          'kind',
          SignInErrorKind.localStorage,
        ),
      ),
    );
    expect(deps.sessions.saved, isNull);
    expect(deps.sessions.cleared, isTrue);
    expect(deps.credentials.saved, isNull);
    expect(controller.state.isLoggedIn, isFalse);
    expect(deps.scheduler.scheduledPlans, isEmpty);
  });
  test('greeting follows the clock and refreshes on resume', () async {
    deps.clock.now = DateTime(2026, 9, 9, 15);
    await controller.initialize();
    expect(controller.state.greeting, '下午好');
    deps.clock.now = DateTime(2026, 9, 9, 19);
    controller.refreshGreeting();
    expect(controller.state.greeting, '晚上好');
  });
  test('all greeting ranges use local time', () {
    for (final (time, greeting) in [
      (DateTime(2026, 9, 9, 4, 59), '夜深了'),
      (DateTime(2026, 9, 9, 5), '早上好'),
      (DateTime(2026, 9, 9, 11, 29), '早上好'),
      (DateTime(2026, 9, 9, 11, 30), '中午好'),
      (DateTime(2026, 9, 9, 13, 59), '中午好'),
      (DateTime(2026, 9, 9, 14), '下午好'),
      (DateTime(2026, 9, 9, 17, 59), '下午好'),
      (DateTime(2026, 9, 9, 18), '晚上好'),
    ]) {
      expect(greetingFor(time), greeting);
      expect(greetingFor(time.toUtc()), greeting);
    }
  });
  test(
    'initialize restores local credentials and schedules without network',
    () async {
      controller.dispose();
      deps = await TestDependencies.authenticated(
        now: DateTime(2026, 9, 9, 7),
        settings: testSettings(),
      );
      controller = SignInAppController(deps);
      await Future.wait([controller.initialize(), controller.initialize()]);
      expect(deps.initializeCalls, 1);
      expect(controller.state.isLoggedIn, isTrue);
      expect(controller.state.maskedUsername, 'us****34');
      expect(deps.scheduler.scheduledPlans, hasLength(1));
      expect(deps.gateway.authenticateCalls, 0);
      expect(deps.gateway.validateCalls, 0);
      expect(deps.gateway.fetchCalls, 0);
      expect(deps.gateway.submitCalls, 0);
      expect(deps.notifications.permissionRequests, 0);
      expect(controller.state.records, isEmpty);
    },
  );
  test('imports a matching native background result exactly once', () async {
    deps = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 9, 7),
      settings: testSettings(),
    );
    final credentials = await deps.credentials.read();
    deps.nativeBackgroundResults.pending.add(
      NativeBackgroundResult(
        resultId: 'native-result-1',
        credentialInstanceId: credentials!.instanceId!,
        record: SignInRecord(
          day: '2026-09-09',
          occurredAt: DateTime(2026, 9, 9, 6, 30),
          source: TriggerSource.shortcutBackground,
          status: SignInRecordStatus.done,
          title: '今日已签到',
          detail: '已跳过重复提交。',
        ),
      ),
    );
    controller.dispose();
    controller = SignInAppController(deps);

    await controller.initialize();
    await controller.refreshLocalState();

    expect(deps.repository.records, hasLength(1));
    expect(
      deps.repository.records.single.source,
      TriggerSource.shortcutBackground,
    );
    expect(deps.nativeBackgroundResults.acknowledged, hasLength(1));
  });

  test('drops a native result from an earlier login lifetime', () async {
    deps = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 9, 7),
      settings: testSettings(),
    );
    deps.nativeBackgroundResults.pending.add(
      NativeBackgroundResult(
        resultId: 'stale-native-result',
        credentialInstanceId: 'other-login',
        record: SignInRecord(
          day: '2026-09-09',
          occurredAt: DateTime(2026, 9, 9, 6, 30),
          source: TriggerSource.shortcutBackground,
          status: SignInRecordStatus.done,
          title: '今日已签到',
          detail: '已跳过重复提交。',
        ),
      ),
    );
    controller.dispose();
    controller = SignInAppController(deps);

    await controller.initialize();

    expect(deps.repository.records, isEmpty);
    expect(deps.nativeBackgroundResults.acknowledged.single, {
      'stale-native-result',
    });
  });

  test('native connection check remains a read-only native action', () async {
    await authenticate();
    deps.nativeBackgroundResults.connection = const NativeConnectionCheck(
      title: '连接正常',
      detail: '今日待签到。',
    );

    final check = await controller.checkNativeConnection();

    expect(check.title, '连接正常');
    expect(deps.gateway.authenticateCalls, 1);
    expect(deps.gateway.fetchCalls, 0);
    expect(deps.gateway.submitCalls, 0);
  });
  test(
    'logout clears all account data and resets immutable UI state',
    () async {
      await authenticate();
      await controller.runManualSignIn();
      final signedInState = controller.state;
      expect(signedInState.records, hasLength(1));
      expect(() => signedInState.records.clear(), throwsUnsupportedError);
      await controller.logout();
      expect(deps.credentials.cleared, isTrue);
      expect(deps.sessions.cleared, isTrue);
      expect(deps.repository.accountDataCleared, isTrue);
      expect(deps.scheduler.cancelled, isTrue);
      expect(controller.state.isLoggedIn, isFalse);
      expect(controller.state.maskedUsername, isEmpty);
      expect(controller.state.plan, isNull);
      expect(controller.state.records, isEmpty);
      expect(signedInState.records, hasLength(1));
    },
  );
  test(
    'manual execution exposes every coordinator state and stored result',
    () async {
      await authenticate();
      final states = <DailyPlanStatus>[];
      controller.addListener(() => states.add(controller.state.planStatus));
      await controller.runManualSignIn();
      expect(
        states,
        containsAllInOrder([
          DailyPlanStatus.checking,
          DailyPlanStatus.jittering,
          DailyPlanStatus.submitting,
          DailyPlanStatus.confirming,
          DailyPlanStatus.success,
        ]),
      );
      expect(deps.gateway.submitCalls, 1);
      expect(
        controller.state.records.single.status,
        SignInRecordStatus.success,
      );
      expect(controller.state.records.single, deps.repository.records.single);
      expect(controller.state.isRunning, isFalse);
      expect(deps.scheduler.scheduledPlans.last.day, '2026-09-10');
    },
  );
  test(
    'foreground state retains only the latest five records for today',
    () async {
      await authenticate();
      final generation = controller.state.plan!.generation;
      final repository = deps.repository.forGeneration(generation);
      for (var minute = 0; minute < 8; minute++) {
        await repository.insertRecord(
          SignInRecord(
            day: '2026-09-09',
            generation: generation,
            occurredAt: DateTime(2026, 9, 9, 8, minute),
            source: TriggerSource.manual,
            status: SignInRecordStatus.success,
            title: '签到成功',
            detail: '',
          ),
        );
      }

      await controller.refreshLocalState();

      expect(controller.state.records, hasLength(5));
      expect(controller.state.records.first.occurredAt.minute, 7);
      expect(controller.state.records.last.occurredAt.minute, 3);
    },
  );
  test('failed execution cannot generate a synthetic success', () async {
    await authenticate();
    deps.gateway.fetchError = const SignInError(
      SignInErrorKind.networkUnavailable,
    );
    await controller.runManualSignIn();
    expect(controller.state.planStatus, DailyPlanStatus.failed);
    expect(controller.state.records.single.status, SignInRecordStatus.failed);
    expect(
      controller.state.records.where(
        (record) =>
            record.status == SignInRecordStatus.success ||
            record.status == SignInRecordStatus.done,
      ),
      isEmpty,
    );
    expect(deps.gateway.submitCalls, 0);
  });
  test('simultaneous manual actions share one execution', () async {
    await authenticate();
    await Future.wait([
      controller.runManualSignIn(),
      controller.runManualSignIn(),
    ]);
    expect(deps.gateway.submitCalls, 1);
    expect(deps.repository.records, hasLength(1));
  });
  test(
    'logout waits for active execution before clearing account data',
    () async {
      await authenticate();
      deps.gateway.submitCompleter = Completer<void>();
      final run = controller.runManualSignIn();
      while (deps.gateway.submitCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final logout = controller.logout();
      deps.gateway.submitCompleter!.complete();
      await Future.wait([run, logout]);
      expect(controller.state.isLoggedIn, isFalse);
      expect(deps.repository.records, isEmpty);
      expect(deps.repository.plans, isEmpty);
      expect(deps.sessions.saved, isNull);
    },
  );
  test(
    'schedule range change persists and reschedules the unsigned day',
    () async {
      await authenticate();
      deps.scheduler.scheduledPlans.clear();
      await controller.updateSchedule(
        testSettings(startMinute: 600, endMinute: 720),
      );
      expect(controller.state.settings.startMinute, 600);
      expect(deps.repository.settings.endMinute, 720);
      expect(deps.scheduler.scheduledPlans.single.startMinute, 600);
      expect(deps.scheduler.scheduledPlans.single.endMinute, 720);
      expect(controller.state.plan!.rangeRegenerated, isTrue);
    },
  );
  test('disabling automation cancels the pending schedule', () async {
    await authenticate();
    await controller.setAutomationEnabled(false);
    expect(deps.scheduler.cancelled, isTrue);
    expect(deps.repository.settings.enabled, isFalse);
    expect(controller.state.settings.enabled, isFalse);
  });
  test(
    'notifications request permission only from their visible settings action',
    () async {
      await authenticate();
      await controller.updateSchedule(
        testSettings(startMinute: 600, endMinute: 720),
      );
      await controller.setNotificationsEnabled(false);
      expect(deps.notifications.permissionRequests, 0);
      deps.notifications.permissionGranted = false;
      await controller.setNotificationsEnabled(true);
      expect(deps.notifications.permissionRequests, 1);
      expect(controller.state.settings.notificationsEnabled, isFalse);
      expect(deps.repository.settings.notificationsEnabled, isFalse);
      deps.notifications.permissionGranted = true;
      await controller.setNotificationsEnabled(true);
      expect(controller.state.settings.notificationsEnabled, isTrue);
      expect(deps.repository.settings.notificationsEnabled, isTrue);
    },
  );
  test('logged-out manual actions cannot touch the gateway', () async {
    await controller.initialize();
    await expectLater(
      controller.runManualSignIn(),
      throwsA(isA<SignInError>()),
    );
    expect(deps.gateway.fetchCalls, 0);
    expect(deps.gateway.submitCalls, 0);
  });

  test(
    'unavailable background scheduling does not block foreground login',
    () async {
      deps.scheduler.cancelError = UnsupportedError('background unavailable');
      deps.scheduler.scheduleError = UnsupportedError('background unavailable');
      await controller.initialize();
      await controller.login('student', 'password');
      expect(controller.state.isLoggedIn, isTrue);
      expect(deps.credentials.saved?.username, 'student');
      expect(controller.state.error, isNotNull);
      expect(deps.gateway.submitCalls, 0);
    },
  );

  test('resume refresh restores background results without network and rolls over dates', () async {
    await authenticate();
    final plan = controller.state.plan!;
    await deps.repository.upsertPlan(
      plan.copyWith(status: DailyPlanStatus.done),
    );
    await deps.repository.insertRecord(
      SignInRecord(
        generation: plan.generation,
        day: '2026-09-09',
        occurredAt: DateTime(2026, 9, 9, 8),
        source: TriggerSource.scheduled,
        status: SignInRecordStatus.done,
        title: '今日已签到',
        detail: '已确认',
      ),
    );
    await controller.refreshLocalState();
    expect(controller.state.planStatus, DailyPlanStatus.done);
    expect(controller.state.records.single.source, TriggerSource.scheduled);
    deps.clock.now = DateTime(2026, 9, 10, 7);
    await controller.refreshLocalState();
    expect(controller.state.plan!.day, '2026-09-10');
    expect(controller.state.planStatus, DailyPlanStatus.planned);
    expect(deps.gateway.fetchCalls, 0);
    expect(deps.gateway.submitCalls, 0);
  });

  test(
    'confirm unknown uses status sync without issuing another POST',
    () async {
      await authenticate();
      await deps.repository.upsertPlan(
        controller.state.plan!.copyWith(
          status: DailyPlanStatus.unknown,
          attemptedAt: DateTime(2026, 9, 9, 7),
        ),
      );
      await controller.confirmUnknown();
      expect(controller.state.planStatus, DailyPlanStatus.unknown);
      expect(controller.state.records.single.source, TriggerSource.statusSync);
      expect(deps.gateway.submitCalls, 0);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/shortcuts/native_background_results.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

final defaultSettings = ScheduleSettings(
  enabled: true,
  notificationsEnabled: false,
  startMinute: 480,
  endMinute: 600,
);

DailyPlan planAt(
  int hour,
  int minute, {
  DailyPlanStatus status = DailyPlanStatus.planned,
}) => DailyPlan(
  day: '2026-09-09',
  startMinute: 480,
  endMinute: 600,
  plannedAt: DateTime(2026, 9, 9, hour, minute),
  status: status,
);

SignInRecord recordAt(
  DateTime occurredAt, {
  String day = '2026-09-09',
  SignInErrorKind? errorKind,
}) => SignInRecord(
  day: day,
  plannedAt: DateTime(2026, 9, 9, 9, 17),
  occurredAt: occurredAt,
  source: TriggerSource.manual,
  status: errorKind == null
      ? SignInRecordStatus.success
      : SignInRecordStatus.failed,
  title: errorKind == null ? '签到成功' : '签到失败',
  detail: '签到状态已确认',
  errorKind: errorKind,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late TestDatabaseBundle bundle;

  setUp(() async {
    bundle = await openTestDatabase();
  });

  tearDown(() => bundle.database.close());

  test(
    'fresh settings keep notifications disabled before permission',
    () async {
      expect(
        (await bundle.repository.loadSettings()).notificationsEnabled,
        isFalse,
      );
    },
  );

  test(
    'a busy error after native callback entry never replays its effect',
    () async {
      var calls = 0;
      await expectLater(
        bundle.repository.withGeneration<void>(1, () async {
          calls++;
          throw _BusyAfterEntry();
        }),
        throwsA(isA<_BusyAfterEntry>()),
      );
      expect(calls, 1);
    },
  );

  test(
    'loadSettings persists the required defaults only when settings are absent',
    () async {
      expect(await bundle.repository.loadSettings(), defaultSettings);
      expect(
        await bundle.database.database.query('schedule_settings'),
        hasLength(1),
      );
    },
  );

  test('saveSettings replaces the single persisted settings row', () async {
    final saved = ScheduleSettings(
      enabled: false,
      notificationsEnabled: false,
      startMinute: 540,
      endMinute: 660,
    );

    await bundle.repository.saveSettings(saved);

    expect(await bundle.repository.loadSettings(), saved);
  });

  test('importing one native result twice creates one record', () async {
    final result = NativeBackgroundResult.fromMap({
      'resultId': 'swift-result-1',
      'credentialInstanceId': 'credential-1',
      'day': '2026-09-14',
      'occurredAt': '2026-09-14T08:05:00+08:00',
      'status': 'done',
      'title': '今日已签到',
      'detail': '已跳过重复提交。',
    });

    await bundle.repository.importNativeResult(result);
    await bundle.repository.importNativeResult(result);

    expect(await bundle.repository.recordsForDay('2026-09-14'), hasLength(1));
  });

  test(
    'upsertPlan preserves one row per day and durable attempt fields',
    () async {
      final original = planAt(9, 17).copyWith(
        attemptedAt: DateTime(2026, 9, 9, 9, 18),
        actualAt: DateTime(2026, 9, 9, 9, 19),
        rangeRegenerated: true,
        lateExecution: true,
      );
      final replacement = original.copyWith(
        plannedAt: DateTime(2026, 9, 9, 9, 25),
        attemptedAt: null,
        actualAt: null,
        status: DailyPlanStatus.done,
      );

      await bundle.repository.upsertPlan(original);
      await bundle.repository.upsertPlan(replacement);

      expect(await bundle.repository.planForDay('2026-09-09'), original);
      expect(await bundle.database.database.query('daily_plans'), hasLength(1));
    },
  );

  test('concurrent attempt claims produce only one winner', () async {
    await bundle.repository.upsertPlan(planAt(8, 30));

    final claims = await Future.wait(
      List.generate(
        8,
        (index) => bundle.repository.claimAttempt(
          day: '2026-09-09',
          attemptedAt: DateTime(2026, 9, 9, 9, 0, index),
          lateExecution: true,
        ),
      ),
    );

    expect(claims.where((claim) => claim.claimed), hasLength(1));
    final winner = claims.singleWhere((claim) => claim.claimed).plan;
    expect(claims.map((claim) => claim.plan), everyElement(winner));
    expect(winner.status, DailyPlanStatus.submitting);
    expect(winner.attemptedAt, isNotNull);
    expect(winner.actualAt, winner.attemptedAt);
    expect(winner.lateExecution, isTrue);
    expect(await bundle.repository.planForDay('2026-09-09'), winner);
  });

  test('attempt claims cannot reopen attempted or completed plans', () async {
    for (final status in [
      DailyPlanStatus.success,
      DailyPlanStatus.done,
      DailyPlanStatus.unknown,
    ]) {
      final protected = planAt(8, 30, status: status).copyWith(
        attemptedAt: status == DailyPlanStatus.unknown
            ? DateTime(2026, 9, 9, 8, 31)
            : null,
      );
      await bundle.database.database.delete('daily_plans');
      await bundle.repository.upsertPlan(protected);

      final claim = await bundle.repository.claimAttempt(
        day: '2026-09-09',
        attemptedAt: DateTime(2026, 9, 9, 9),
        lateExecution: false,
      );

      expect(claim.claimed, isFalse);
      expect(claim.plan, protected);
    }
  });

  test('stale upsert cannot erase or downgrade a completed plan', () async {
    final completed = planAt(8, 30, status: DailyPlanStatus.success);
    await bundle.repository.upsertPlan(completed);

    await bundle.repository.upsertPlan(
      planAt(9, 30, status: DailyPlanStatus.failed),
    );

    expect(await bundle.repository.planForDay('2026-09-09'), completed);
  });

  test('same attempt advances status but changed markers and stale snapshots cannot', () async {
    await bundle.repository.upsertPlan(planAt(8, 30));
    final claim = await bundle.repository.claimAttempt(
      day: '2026-09-09',
      attemptedAt: DateTime(2026, 9, 9, 9),
      lateExecution: true,
    );
    final confirming = claim.plan.copyWith(status: DailyPlanStatus.confirming);
    await bundle.repository.upsertPlan(confirming);
    expect(await bundle.repository.planForDay('2026-09-09'), confirming);

    for (final stale in [
      planAt(9, 15, status: DailyPlanStatus.failed),
      confirming.copyWith(
        status: DailyPlanStatus.failed,
        attemptedAt: DateTime(2026, 9, 9, 9, 1),
      ),
      confirming.copyWith(status: DailyPlanStatus.checking),
    ]) {
      await bundle.repository.upsertPlan(stale);
      expect(await bundle.repository.planForDay('2026-09-09'), confirming);
    }
    final unknown = confirming.copyWith(status: DailyPlanStatus.unknown);
    await bundle.repository.upsertPlan(unknown);
    expect(await bundle.repository.planForDay('2026-09-09'), unknown);
    final success = unknown.copyWith(status: DailyPlanStatus.success);
    await bundle.repository.upsertPlan(success);
    await bundle.repository.upsertPlan(unknown);
    expect(await bundle.repository.planForDay('2026-09-09'), success);
  });

  for (final status in [
    DailyPlanStatus.confirming,
    DailyPlanStatus.unknown,
    DailyPlanStatus.failed,
    DailyPlanStatus.success,
    DailyPlanStatus.done,
  ]) {
    test('original claim cannot replace later $status state', () async {
      await bundle.repository.upsertPlan(planAt(8, 30));
      final claim = await bundle.repository.claimAttempt(
        day: '2026-09-09',
        attemptedAt: DateTime(2026, 9, 9, 9),
        lateExecution: false,
      );
      final advanced = claim.plan.copyWith(status: status);
      await bundle.repository.upsertPlan(advanced);

      await bundle.repository.upsertPlan(claim.plan);

      expect(await bundle.repository.planForDay('2026-09-09'), advanced);
    });
  }

  for (final status in [DailyPlanStatus.unknown, DailyPlanStatus.failed]) {
    test('stale confirmation cannot replace terminal $status state', () async {
      await bundle.repository.upsertPlan(planAt(8, 30));
      final claim = await bundle.repository.claimAttempt(
        day: '2026-09-09',
        attemptedAt: DateTime(2026, 9, 9, 9),
        lateExecution: false,
      );
      final terminal = claim.plan.copyWith(status: status);
      await bundle.repository.upsertPlan(terminal);

      await bundle.repository.upsertPlan(
        claim.plan.copyWith(status: DailyPlanStatus.confirming),
      );

      expect(await bundle.repository.planForDay('2026-09-09'), terminal);
    });
  }

  for (final completed in [DailyPlanStatus.success, DailyPlanStatus.done]) {
    for (final stale in [
      SignInRecordStatus.unknown,
      SignInRecordStatus.failed,
    ]) {
      test(
        'finalization keeps durable $completed authoritative over stale $stale',
        () async {
          await bundle.repository.upsertPlan(planAt(8, 30));
          final claim = await bundle.repository.claimAttempt(
            day: '2026-09-09',
            attemptedAt: DateTime(2026, 9, 9, 9),
            lateExecution: false,
          );
          final winner = claim.plan.copyWith(status: completed);
          await bundle.repository.finalizeExecution(
            plan: winner,
            record: recordAt(DateTime(2026, 9, 9, 9, 0, 1)).copyWith(
              status: completed == DailyPlanStatus.success
                  ? SignInRecordStatus.success
                  : SignInRecordStatus.done,
            ),
          );

          final accepted = await bundle.repository.finalizeExecution(
            plan: claim.plan.copyWith(
              status: stale == SignInRecordStatus.unknown
                  ? DailyPlanStatus.unknown
                  : DailyPlanStatus.failed,
            ),
            record: recordAt(DateTime(2026, 9, 9, 9, 0, 2)).copyWith(
              status: stale,
              title: '结果待确认',
              detail: '旧查询尚未确认',
              errorKind: SignInErrorKind.resultUnknown,
            ),
          );

          expect(accepted.plan, winner);
          expect(accepted.record.status, SignInRecordStatus.done);
          expect(accepted.record.title, '今日已签到');
          expect(accepted.record.errorKind, isNull);
          expect(accepted.record.detail, isNot(contains('旧查询')));
          expect(await bundle.repository.planForDay('2026-09-09'), winner);
          expect(
            (await bundle.repository.latestRecordsForDay('2026-09-09')).first,
            accepted.record,
          );
        },
      );
    }
  }

  test(
    'finalization rolls back terminal plan when record insertion fails',
    () async {
      await bundle.repository.upsertPlan(planAt(8, 30));
      final claim = await bundle.repository.claimAttempt(
        day: '2026-09-09',
        attemptedAt: DateTime(2026, 9, 9, 9),
        lateExecution: false,
      );
      await bundle.database.database.execute('''
      CREATE TEMP TRIGGER reject_record BEFORE INSERT ON sign_in_records
      BEGIN SELECT RAISE(ABORT, 'record fault'); END
    ''');

      await expectLater(
        bundle.repository.finalizeExecution(
          plan: claim.plan.copyWith(status: DailyPlanStatus.success),
          record: recordAt(DateTime(2026, 9, 9, 9, 0, 1)),
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await bundle.repository.planForDay('2026-09-09'), claim.plan);
      expect(await bundle.repository.recordsForDay('2026-09-09'), isEmpty);
    },
  );

  test('resolveDailyPlan atomically returns one persisted plan to concurrent callers', () async {
    final candidates = List.generate(8, (index) => planAt(8, index));

    final resolved = await Future.wait(
      candidates.map(bundle.repository.resolveDailyPlan),
    );
    final persisted = await bundle.repository.planForDay('2026-09-09');

    expect(persisted, isNotNull);
    expect(resolved, everyElement(persisted));
    expect(resolved.map((plan) => plan.plannedAt).toSet(), hasLength(1));
  });

  test('resolveDailyPlan retains completed or attempted plans during concurrent resolution', () async {
    final protectedPlans = [
      planAt(
        7,
        15,
        status: DailyPlanStatus.done,
      ).copyWith(startMinute: 0, endMinute: 1),
      planAt(7, 16, status: DailyPlanStatus.submitting).copyWith(
        startMinute: 0,
        endMinute: 1,
        attemptedAt: DateTime(2026, 9, 9, 7, 17),
      ),
    ];

    for (final protected in protectedPlans) {
      await bundle.database.database.delete('daily_plans');
      await bundle.repository.upsertPlan(protected);

      final resolved = await Future.wait(
        List.generate(4, (index) {
          return bundle.repository.resolveDailyPlan(planAt(8, index));
        }),
      );

      expect(resolved, everyElement(protected));
      expect(await bundle.repository.planForDay('2026-09-09'), protected);
    }
  });

  test(
    'insertRecord assigns an id and round-trips nullable record fields',
    () async {
      final inserted = await bundle.repository.insertRecord(
        recordAt(
          DateTime(2026, 9, 9, 9, 18),
          errorKind: SignInErrorKind.networkUnavailable,
        ),
      );

      expect(inserted.id, isNotNull);
      expect(await bundle.repository.recordsForDay('2026-09-09'), [inserted]);
    },
  );

  test(
    'latestRecordsForDay returns newest five but full history is uncapped',
    () async {
      for (var index = 0; index < 6; index++) {
        await bundle.repository.insertRecord(
          recordAt(DateTime(2026, 9, 9, 8, index)),
        );
      }

      final latest = await bundle.repository.latestRecordsForDay(
        '2026-09-09',
        limit: 5,
      );
      final requestedSix = await bundle.repository.latestRecordsForDay(
        '2026-09-09',
        limit: 6,
      );

      expect(latest, hasLength(5));
      expect(latest.first.occurredAt, DateTime(2026, 9, 9, 8, 5));
      expect(requestedSix, hasLength(5));
      expect(await bundle.repository.recordsForDay('2026-09-09'), hasLength(6));
    },
  );

  test(
    'recordsForMonth isolates the requested month and keeps newest first',
    () async {
      final september = await bundle.repository.insertRecord(
        recordAt(DateTime(2026, 9, 30, 10), day: '2026-09-30'),
      );
      await bundle.repository.insertRecord(
        recordAt(DateTime(2026, 10, 1, 10), day: '2026-10-01'),
      );
      final earlierSeptember = await bundle.repository.insertRecord(
        recordAt(DateTime(2026, 9, 1, 10), day: '2026-09-01'),
      );

      expect(await bundle.repository.recordsForMonth('2026-09'), [
        september,
        earlierSeptember,
      ]);
    },
  );

  test('clearAccountData invalidates the account and read paths cannot recreate defaults', () async {
    await bundle.repository.saveSettings(defaultSettings);
    await bundle.repository.upsertPlan(planAt(9, 17));
    await bundle.repository.insertRecord(recordAt(DateTime(2026, 9, 9, 9)));

    await bundle.repository.clearAccountData();

    expect(await bundle.database.database.query('schedule_settings'), isEmpty);
    expect(await bundle.repository.activeGeneration(), isNull);
    await expectLater(
      bundle.repository.planForDay('2026-09-09'),
      throwsA(isA<AccountDataCleared>()),
    );
    await expectLater(
      bundle.repository.recordsForDay('2026-09-09'),
      throwsA(isA<AccountDataCleared>()),
    );
    await expectLater(
      bundle.repository.loadSettings(),
      throwsA(isA<AccountDataCleared>()),
    );
  });

  test(
    'a new lifetime rejects every stale same-day read, claim and write',
    () async {
      final old = bundle.repository.forGeneration(1);
      await old.upsertPlan(planAt(8, 30));
      final claim = await old.claimAttempt(
        day: '2026-09-09',
        attemptedAt: DateTime(2026, 9, 9, 9),
        lateExecution: false,
      );
      await bundle.repository.clearAccountData();
      final generation = await bundle.repository.activateAccount();
      final current = bundle.repository.forGeneration(generation);
      final currentPlan = planAt(9, 30).copyWith(generation: generation);
      await current.upsertPlan(currentPlan);
      final currentRecord = await current.insertRecord(
        recordAt(DateTime(2026, 9, 9, 9, 31)).copyWith(generation: generation),
      );
      for (final action in <Future<Object?> Function()>[
        old.loadSettings,
        () => old.planForDay('2026-09-09'),
        () => old.recordsForDay('2026-09-09'),
        () => old.claimAttempt(
          day: '2026-09-09',
          attemptedAt: DateTime(2026, 9, 9, 9, 32),
          lateExecution: false,
        ),
        () => old.upsertPlan(claim.plan),
        () => old.finalizeExecution(
          plan: claim.plan.copyWith(status: DailyPlanStatus.success),
          record: recordAt(DateTime(2026, 9, 9, 9, 33)),
        ),
        () => bundle.repository.finalizeExecution(
          plan: claim.plan.copyWith(status: DailyPlanStatus.success),
          record: recordAt(DateTime(2026, 9, 9, 9, 33)),
        ),
        () => bundle.repository.insertRecord(
          recordAt(DateTime(2026, 9, 9, 9, 34)),
        ),
      ]) {
        await expectLater(action(), throwsA(isA<AccountDataCleared>()));
      }
      expect(await current.planForDay('2026-09-09'), currentPlan);
      expect(await current.recordsForDay('2026-09-09'), [currentRecord]);
      expect(await bundle.database.database.query('account_state'), [
        {'id': 1, 'generation': generation, 'active': 1},
      ]);
    },
  );
}

class _BusyAfterEntry extends DatabaseException {
  _BusyAfterEntry() : super('database is locked');
  @override
  int getResultCode() => 5;
  @override
  Object? get result => null;
}

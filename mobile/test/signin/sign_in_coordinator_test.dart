import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/auth/auth_models.dart';
import 'package:maoguai_signin/auth/credential_store.dart';
import 'package:maoguai_signin/auth/session_store.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/schedule/daily_plan_service.dart';
import 'package:maoguai_signin/signin/async_lock.dart';
import 'package:maoguai_signin/signin/sign_in_coordinator.dart';
import 'package:maoguai_signin/signin/sign_in_gateway.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

final _now = DateTime(2026, 9, 9, 9);
const _session = SessionData(
  token: 'secret-token',
  uid: 'secret-uid',
  cookies: {'session': 'secret-cookie'},
  userAgent: 'test-user-agent',
);

void main() {
  setUpAll(sqfliteFfiInit);
  late TestDatabaseBundle bundle;
  late _Gateway gateway;
  late _Credentials credentials;
  late _Sessions sessions;
  late SignInCoordinator coordinator;
  late DateTime clock;
  late List<Duration> delays;

  SignInCoordinator build({
    Future<void> Function(Duration)? sleep,
    int Function(int, int)? chooseSecond,
    SignInRepository? repository,
  }) => SignInCoordinator(
    gateway: gateway,
    credentialStore: credentials,
    sessionStore: sessions,
    repository: repository ?? bundle.repository,
    planService: DailyPlanService(
      bundle.repository,
      chooseSecond: (_, _) => 1800,
    ),
    clock: () => clock,
    chooseSecond: chooseSecond ?? (_, _) => 1,
    sleep:
        sleep ??
        (duration) async {
          delays.add(duration);
          clock = clock.add(duration);
        },
  );

  setUp(() async {
    bundle = await openTestDatabase();
    sessions = _Sessions();
    credentials = _Credentials();
    gateway = _Gateway(sessions);
    clock = _now;
    delays = [];
    coordinator = build();
  });
  tearDown(() => bundle.database.close());

  test('automatic execution cannot claim before planned time', () async {
    clock = DateTime(2026, 9, 9, 8);
    await expectLater(
      coordinator.run(source: TriggerSource.scheduled, now: clock),
      throwsA(isA<AutomaticPlanObsolete>()),
    );
    expect(gateway.submitCalls, 0);
    expect(
      (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
      isNull,
    );
  });

  test(
    'manual execution remains allowed before due time with automation disabled',
    () async {
      clock = DateTime(2026, 9, 9, 8);
      final settings = await bundle.repository.loadSettings();
      await bundle.repository.saveSettings(settings.copyWith(enabled: false));
      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: clock,
      );
      expect(result.status, SignInRecordStatus.success);
      expect(gateway.submitCalls, 1);
    },
  );

  for (final change in ['replace', 'disable']) {
    test('automatic claim rejects $change during jitter', () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      coordinator = build(
        sleep: (_) async {
          entered.complete();
          await resume.future;
        },
      );
      final run = coordinator.run(source: TriggerSource.scheduled, now: _now);
      await entered.future;
      final original = (await bundle.repository.planForDay('2026-09-09'))!;
      if (change == 'replace') {
        await bundle.repository.upsertPlan(
          original.copyWith(
            startMinute: 600,
            endMinute: 660,
            plannedAt: DateTime(2026, 9, 9, 10, 30),
          ),
        );
      } else {
        final settings = await bundle.repository.loadSettings();
        await bundle.repository.saveSettings(settings.copyWith(enabled: false));
      }
      final expected = await bundle.repository.planForDay(original.day);
      final rejected = expectLater(run, throwsA(isA<AutomaticPlanObsolete>()));
      resume.complete();
      await rejected;
      expect(gateway.submitCalls, 0);
      expect(await bundle.repository.planForDay(original.day), expected);
      expect(await bundle.repository.recordsForDay(original.day), isEmpty);
    });
  }

  test(
    'already signed short-circuits without submit and records done',
    () async {
      gateway.status = RemoteSignInState.done;

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.done);
      expect(result.title, '今日已签到');
      expect(gateway.calls, ['validate', 'status']);
      expect(delays, isEmpty);
      expect(await bundle.repository.recordsForDay('2026-09-09'), [
        result.record,
      ]);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        isNull,
      );
    },
  );

  test(
    'attempt marker is durable after jitter and before one submit',
    () async {
      gateway.beforeSubmit = () async {
        final durable = await bundle.repository.planForDay('2026-09-09');
        expect(durable!.status, DailyPlanStatus.submitting);
        expect(durable.attemptedAt, DateTime(2026, 9, 9, 9, 0, 1));
        expect(durable.actualAt, DateTime(2026, 9, 9, 9, 0, 1));
      };

      final result = await coordinator.run(
        source: TriggerSource.scheduled,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.success);
      expect(gateway.calls, ['validate', 'status', 'submit', 'status']);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.status,
        DailyPlanStatus.success,
      );
      expect(await bundle.repository.recordsForDay('2026-09-09'), [
        result.record,
      ]);
    },
  );

  test(
    'uncertain submit only confirms and never resubmits after restart',
    () async {
      gateway.submitError = const SignInError(
        SignInErrorKind.networkUnavailable,
      );
      gateway.statusAfterSubmit = RemoteSignInState.pending;

      final first = await coordinator.run(
        source: TriggerSource.scheduled,
        now: _now,
      );
      final attemptedAt = (await bundle.repository.planForDay('2026-09-09'))!
          .attemptedAt;
      gateway.calls.clear();
      final second = await build().run(source: TriggerSource.manual, now: _now);

      expect(first.status, SignInRecordStatus.unknown);
      expect(second.status, SignInRecordStatus.unknown);
      expect(first.title, '结果待确认');
      expect(gateway.calls, ['status']);
      expect(gateway.submitCalls, 1);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        attemptedAt,
      );
      expect(await bundle.repository.recordsForDay('2026-09-09'), hasLength(2));
    },
  );

  test('lost submit response can still confirm success', () async {
    gateway.submitError = const SignInError(SignInErrorKind.networkUnavailable);

    final result = await coordinator.run(
      source: TriggerSource.manual,
      now: _now,
    );

    expect(result.status, SignInRecordStatus.success);
    expect(result.record!.errorKind, isNull);
    expect(gateway.submitCalls, 1);
  });

  test(
    'rejected submit that is already signed records a skipped completion',
    () async {
      gateway.submitError = const SignInError(SignInErrorKind.businessRejected);

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.done);
      expect(result.title, '今日已签到');
      expect(result.detail, '检测到今日已签到，已跳过重复提交。');
      expect(gateway.calls, ['validate', 'status', 'submit', 'status']);
      expect(gateway.submitCalls, 1);
    },
  );

  test('failed business rejection records the safe server reason', () async {
    gateway.submitError = const SignInError(
      SignInErrorKind.businessRejected,
      detail: '今日签到通道尚未开放，请在 08:00 后重试。',
    );
    gateway.statusAfterSubmit = RemoteSignInState.pending;

    final result = await coordinator.run(
      source: TriggerSource.manual,
      now: _now,
    );

    expect(result.status, SignInRecordStatus.failed);
    expect(result.detail, '今日签到通道尚未开放，请在 08:00 后重试。');
    expect(result.record!.detail, result.detail);
  });

  test('successful submit with pending confirmation remains unknown', () async {
    gateway.statusAfterSubmit = RemoteSignInState.pending;

    final result = await coordinator.run(
      source: TriggerSource.manual,
      now: _now,
    );

    expect(result.status, SignInRecordStatus.unknown);
    expect(result.record!.errorKind, SignInErrorKind.resultUnknown);
  });

  test(
    'confirmation after restart resolves unknown using only status',
    () async {
      gateway.statusAfterSubmit = RemoteSignInState.pending;
      await coordinator.run(source: TriggerSource.manual, now: _now);
      gateway.calls.clear();
      gateway.status = RemoteSignInState.done;

      final result = await build().confirmUnknown(_now);

      expect(result.status, SignInRecordStatus.done);
      expect(result.record!.source, TriggerSource.statusSync);
      expect(gateway.calls, ['status']);
      expect(gateway.submitCalls, 1);
    },
  );

  test(
    'attempted plan never validates or relogs even when status expires',
    () async {
      await bundle.repository.upsertPlan(_attemptedPlan());
      gateway.statusError = const SignInError(SignInErrorKind.authExpired);

      final result = await coordinator.run(
        source: TriggerSource.scheduled,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.unknown);
      expect(gateway.calls, ['status']);
      expect(sessions.clears, 0);
      expect(result.record!.errorKind, SignInErrorKind.authExpired);
    },
  );

  for (final source in [TriggerSource.statusSync, null]) {
    test('read-only confirmation $source never creates an attempt', () async {
      final result = source == null
          ? await coordinator.confirmUnknown(_now)
          : await coordinator.run(source: source, now: _now);

      expect(result.status, SignInRecordStatus.unknown);
      expect(gateway.calls, ['status']);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        isNull,
      );
    });
  }

  for (final kind in [
    SignInErrorKind.networkUnavailable,
    SignInErrorKind.rateLimited,
    SignInErrorKind.serverUnavailable,
    SignInErrorKind.invalidResponse,
  ]) {
    test(
      'preflight $kind preserves session and creates a safe failed record',
      () async {
        gateway.validationError = SignInError(
          kind,
          detail: 'secret-token secret-password raw-response',
        );

        final result = await coordinator.run(
          source: TriggerSource.manual,
          now: _now,
        );

        expect(result.status, SignInRecordStatus.failed);
        expect(result.title, '签到失败');
        expect(result.record!.errorKind, kind);
        expect(result.detail, isNot(contains('secret')));
        expect(
          result.record!.toMap().toString(),
          isNot(contains('raw-response')),
        );
        expect(gateway.calls, ['validate']);
        expect(sessions.value, _session);
        expect(sessions.clears, 0);
        expect(await bundle.repository.recordsForDay('2026-09-09'), [
          result.record,
        ]);
      },
    );
  }

  test(
    'explicit validation expiry permits exactly one reauthentication',
    () async {
      gateway.sessionState = RemoteSessionState.expired;

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.success);
      expect(gateway.calls, [
        'validate',
        'authenticate',
        'status',
        'submit',
        'status',
      ]);
      expect(gateway.receivedCredentials, same(credentials.value));
      expect(sessions.clears, 0);
    },
  );

  test(
    'status expiry reauthenticates once then queries status again',
    () async {
      gateway.statusError = const SignInError(SignInErrorKind.authExpired);
      gateway.clearStatusErrorOnAuth = true;
      gateway.status = RemoteSignInState.done;

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.done);
      expect(gateway.calls, ['validate', 'status', 'authenticate', 'status']);
    },
  );

  test(
    'second explicit expiry terminates without another login or submit',
    () async {
      gateway.statusError = const SignInError(SignInErrorKind.authExpired);

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.failed);
      expect(result.title, '登录已失效');
      expect(gateway.calls, ['validate', 'status', 'authenticate', 'status']);
      expect(sessions.clears, 1);
    },
  );

  test('status expiry after validation rotation publishes against the rotated session', () async {
    gateway.afterValidation = () async {
      await sessions.save(
        const SessionData(
          token: 'rotated-token',
          uid: 'secret-uid',
          cookies: {'sid': 'rotated'},
          userAgent: 'test-user-agent',
        ),
      );
    };
    gateway.statusError = const SignInError(SignInErrorKind.authExpired);
    gateway.clearStatusErrorOnAuth = true;
    gateway.status = RemoteSignInState.done;
    final result = await coordinator.run(
      source: TriggerSource.manual,
      now: _now,
    );
    expect(result.status, SignInRecordStatus.done);
    expect(gateway.calls, ['validate', 'status', 'authenticate', 'status']);
  });

  test(
    'missing credentials after explicit expiry records login expired',
    () async {
      gateway.sessionState = RemoteSessionState.expired;
      credentials.value = null;

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.title, '登录已失效');
      expect(result.record!.errorKind, SignInErrorKind.authExpired);
      expect(gateway.calls, ['validate']);
      expect(sessions.clears, 1);
    },
  );

  test(
    'network error during reauthentication does not erase session',
    () async {
      gateway.sessionState = RemoteSessionState.expired;
      gateway.authError = const SignInError(SignInErrorKind.networkUnavailable);

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.failed);
      expect(gateway.calls, ['validate', 'authenticate']);
      expect(sessions.value, _session);
      expect(sessions.clears, 0);
    },
  );

  test(
    'concurrent foreground background and confirmation share one result',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      coordinator = build(
        sleep: (_) async {
          entered.complete();
          await release.future;
        },
      );
      final first = coordinator.run(source: TriggerSource.manual, now: _now);
      await entered.future;
      final second = build().run(source: TriggerSource.scheduled, now: _now);
      final third = coordinator.confirmUnknown(_now);
      release.complete();

      final results = await Future.wait([first, second, third]);

      expect(results[1], same(results[0]));
      expect(results[2], same(results[0]));
      expect(gateway.submitCalls, 1);
      expect(await bundle.repository.recordsForDay('2026-09-09'), hasLength(1));
    },
  );

  for (final seconds in [1, 2]) {
    test(
      'injected $seconds second jitter precedes any durable attempt',
      () async {
        coordinator = build(
          chooseSecond: (minimum, maximum) {
            expect([minimum, maximum], [1, 2]);
            return seconds;
          },
          sleep: (duration) async {
            expect(duration, Duration(seconds: seconds));
            final before = (await bundle.repository.planForDay('2026-09-09'))!;
            expect(before.attemptedAt, isNull);
            expect(gateway.submitCalls, 0);
          },
        );

        expect(
          (await coordinator.run(
            source: TriggerSource.manual,
            now: _now,
          )).status,
          SignInRecordStatus.success,
        );
      },
    );
  }

  test(
    'late execution retains planned timestamp and records actual timestamp',
    () async {
      clock = DateTime(2026, 9, 9, 10, 40);

      final result = await coordinator.run(
        source: TriggerSource.lateCatchUp,
        now: clock,
      );

      expect(result.status, SignInRecordStatus.success);
      expect(result.title, '系统延迟补签');
      expect(result.record!.source, TriggerSource.lateCatchUp);
      expect(result.record!.plannedAt, DateTime(2026, 9, 9, 8, 30));
      expect(result.record!.occurredAt, DateTime(2026, 9, 9, 10, 40, 1));
      final plan = (await bundle.repository.planForDay('2026-09-09'))!;
      expect(plan.actualAt, DateTime(2026, 9, 9, 10, 40, 1));
      expect(plan.lateExecution, isTrue);
    },
  );

  test('broadcast progress emits each phase and terminal status', () async {
    final first = <DailyPlanStatus>[];
    final second = <DailyPlanStatus>[];
    final a = coordinator.statusChanges.listen(first.add);
    final b = coordinator.statusChanges.listen(second.add);

    await coordinator.run(source: TriggerSource.manual, now: _now);
    await Future<void>.delayed(Duration.zero);

    expect(first, [
      DailyPlanStatus.checking,
      DailyPlanStatus.jittering,
      DailyPlanStatus.submitting,
      DailyPlanStatus.confirming,
      DailyPlanStatus.success,
    ]);
    expect(second, first);
    await a.cancel();
    await b.cancel();
  });

  test(
    'success committed after a losing status read overrides its unknown result',
    () async {
      final attempted = _attemptedPlan().copyWith(
        status: DailyPlanStatus.submitting,
      );
      await bundle.repository.upsertPlan(attempted);
      final statusRead = Completer<void>();
      final releaseStatus = Completer<void>();
      gateway.afterStatusRead = () async {
        statusRead.complete();
        await releaseStatus.future;
      };
      final progress = <DailyPlanStatus>[];
      final subscription = coordinator.statusChanges.listen(progress.add);

      final losingExecution = coordinator.confirmUnknown(_now);
      await statusRead.future;
      final success = attempted.copyWith(status: DailyPlanStatus.success);
      await bundle.repository.finalizeExecution(
        plan: success,
        record: SignInRecord(
          day: '2026-09-09',
          plannedAt: attempted.plannedAt,
          occurredAt: DateTime(2026, 9, 9, 9, 0, 1),
          source: TriggerSource.scheduled,
          status: SignInRecordStatus.success,
          title: '签到成功',
          detail: '已完成今日签到。',
        ),
      );
      clock = DateTime(2026, 9, 9, 9, 0, 2);
      releaseStatus.complete();
      final result = await losingExecution;
      await Future<void>.delayed(Duration.zero);

      expect(result.status, SignInRecordStatus.done);
      expect(result.title, '今日已签到');
      expect(result.record!.errorKind, isNull);
      expect(progress.last, DailyPlanStatus.done);
      expect(await bundle.repository.planForDay('2026-09-09'), success);
      final records = await bundle.repository.latestRecordsForDay('2026-09-09');
      expect(records, hasLength(2));
      expect(records.first, result.record);
      expect(records.map((record) => record.status), [
        SignInRecordStatus.done,
        SignInRecordStatus.success,
      ]);
      expect(gateway.calls, ['status']);
      await subscription.cancel();
    },
  );

  test(
    'another isolate claiming during jitter forces read-only confirmation',
    () async {
      coordinator = build(
        sleep: (_) async {
          final other = await bundle.repository.claimAttempt(
            day: '2026-09-09',
            attemptedAt: DateTime(2026, 9, 9, 9, 0, 1),
            lateExecution: false,
          );
          expect(other.claimed, isTrue);
        },
      );

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.unknown);
      expect(gateway.calls, ['validate', 'status', 'status']);
      expect(gateway.submitCalls, 0);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        DateTime(2026, 9, 9, 9, 0, 1),
      );
    },
  );

  test(
    'clock crossing midnight during jitter must not submit for yesterday',
    () async {
      clock = DateTime(2026, 9, 9, 23, 59, 59);
      coordinator = build(chooseSecond: (_, _) => 2);

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: clock,
      );

      expect(result.status, SignInRecordStatus.failed);
      expect(gateway.submitCalls, 0);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        isNull,
      );
      expect(result.detail, contains('日期'));
    },
  );

  test(
    'terminal plan write failure still saves a sanitized result record',
    () async {
      await bundle.database.database.execute('''
        CREATE TEMP TRIGGER reject_terminal_plan BEFORE UPDATE ON daily_plans
        WHEN NEW.status = 'success'
        BEGIN SELECT RAISE(ABORT, 'secret local file path'); END
      ''');

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.success);
      expect(result.record!.errorKind, SignInErrorKind.localStorage);
      expect(result.detail, contains('本地'));
      expect(result.detail, isNot(contains('secret')));
      expect(await bundle.repository.recordsForDay('2026-09-09'), [
        result.record,
      ]);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        isNotNull,
      );
    },
  );

  test(
    'record storage failure is sanitized and releases lock for confirmation',
    () async {
      final statuses = <DailyPlanStatus>[];
      await bundle.database.database.execute('''
        CREATE TEMP TRIGGER reject_record BEFORE INSERT ON sign_in_records
        BEGIN SELECT RAISE(ABORT, 'secret database contents'); END
      ''');
      final subscription = coordinator.statusChanges.listen(statuses.add);

      await expectLater(
        coordinator.run(source: TriggerSource.manual, now: _now),
        throwsA(
          isA<SignInError>()
              .having(
                (error) => error.kind,
                'kind',
                SignInErrorKind.localStorage,
              )
              .having((error) => error.detail, 'detail', isNull),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(statuses.last, DailyPlanStatus.failed);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.status,
        DailyPlanStatus.submitting,
      );
      expect(await bundle.repository.recordsForDay('2026-09-09'), isEmpty);
      await bundle.database.database.execute('DROP TRIGGER reject_record');
      gateway.calls.clear();
      final recovered = await build().confirmUnknown(_now);

      expect(recovered.status, SignInRecordStatus.done);
      expect(gateway.calls, ['status']);
      expect(gateway.submitCalls, 1);
      await subscription.cancel();
    },
  );

  test('single-flight lock releases after a synchronous exception', () async {
    final lock = AsyncLock<int>();
    await expectLater(
      lock.run(() => throw StateError('test')),
      throwsStateError,
    );

    expect(await lock.run(() async => 7), 7);
  });

  test(
    'explicit submit rejection records failure and keeps attempt marker',
    () async {
      gateway.submitError = const SignInError(
        SignInErrorKind.businessRejected,
        detail: 'raw secret server message',
      );
      gateway.statusAfterSubmit = RemoteSignInState.pending;

      final first = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );
      await build().run(source: TriggerSource.manual, now: _now);

      expect(first.status, SignInRecordStatus.failed);
      expect(first.title, '签到失败');
      expect(first.record!.errorKind, SignInErrorKind.businessRejected);
      expect(first.detail, isNot(contains('secret')));
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        isNotNull,
      );
      expect(gateway.submitCalls, 1);
    },
  );

  test(
    'failed durable marker prevents submit and creates storage failure record',
    () async {
      coordinator = build(
        repository: _RejectAttemptRepository(bundle.repository),
      );

      final result = await coordinator.run(
        source: TriggerSource.manual,
        now: _now,
      );

      expect(result.status, SignInRecordStatus.failed);
      expect(result.record!.errorKind, SignInErrorKind.localStorage);
      expect(gateway.submitCalls, 0);
      expect(
        (await bundle.repository.planForDay('2026-09-09'))!.attemptedAt,
        isNull,
      );
      expect(await bundle.repository.recordsForDay('2026-09-09'), [
        result.record,
      ]);
    },
  );

  for (final status in [DailyPlanStatus.success, DailyPlanStatus.done]) {
    test(
      'completed $status plan without marker never reopens for submit',
      () async {
        await bundle.repository.upsertPlan(
          _attemptedPlan().copyWith(attemptedAt: null, status: status),
        );

        final result = await coordinator.run(
          source: TriggerSource.manual,
          now: _now,
        );

        expect(result.status, SignInRecordStatus.done);
        expect(gateway.submitCalls, 0);
        expect(
          (await bundle.repository.planForDay('2026-09-09'))!.status,
          status,
        );
      },
    );
  }
}

DailyPlan _attemptedPlan() => DailyPlan(
  day: '2026-09-09',
  startMinute: 480,
  endMinute: 600,
  plannedAt: DateTime(2026, 9, 9, 8, 30),
  attemptedAt: DateTime(2026, 9, 9, 8, 31),
  actualAt: DateTime(2026, 9, 9, 8, 31),
  status: DailyPlanStatus.unknown,
);

class _Credentials implements CredentialStore {
  StoredCredentials? value = const StoredCredentials(
    username: 'test-account',
    password: 'secret-password',
  );
  @override
  Future<StoredCredentials?> read() async => value;
  @override
  Future<StoredCredentials?> peek() async => value;
  @override
  Future<void> save(StoredCredentials credentials) async => value = credentials;
  @override
  Future<void> clear() async => value = null;
}

class _Sessions implements SessionStore {
  SessionData? value = _session;
  int clears = 0;
  @override
  Future<SessionData?> read() async => value;
  @override
  Future<SessionData?> peek() async => value;
  @override
  Future<void> save(SessionData session) async => value = session;
  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }
}

class _Gateway implements SignInGateway {
  _Gateway(this.sessions);
  final _Sessions sessions;
  final calls = <String>[];
  RemoteSessionState sessionState = RemoteSessionState.valid;
  RemoteSignInState status = RemoteSignInState.pending;
  RemoteSignInState statusAfterSubmit = RemoteSignInState.done;
  SignInError? validationError;
  SignInError? statusError;
  SignInError? authError;
  SignInError? submitError;
  StoredCredentials? receivedCredentials;
  bool clearStatusErrorOnAuth = false;
  int submitCalls = 0;
  Future<void> Function()? beforeSubmit;
  Future<void> Function()? afterStatusRead;
  Future<void> Function()? afterValidation;

  @override
  Future<SessionData> authenticate(StoredCredentials credentials) async {
    calls.add('authenticate');
    receivedCredentials = credentials;
    if (authError != null) throw authError!;
    if (clearStatusErrorOnAuth) statusError = null;
    return _session;
  }

  @override
  Future<RemoteSessionState> validateSession({int? generation}) async {
    calls.add('validate');
    if (validationError != null) throw validationError!;
    await afterValidation?.call();
    return sessionState;
  }

  @override
  Future<RemoteSignInState> fetchStatus({int? generation}) async {
    calls.add('status');
    if (statusError != null) throw statusError!;
    final snapshot = status;
    await afterStatusRead?.call();
    return snapshot;
  }

  @override
  Future<void> submitSignIn({int? generation}) async {
    await beforeSubmit?.call();
    calls.add('submit');
    submitCalls++;
    status = statusAfterSubmit;
    if (submitError != null) throw submitError!;
  }
}

class _RejectAttemptRepository implements SignInRepository {
  _RejectAttemptRepository(this.delegate);
  final SignInRepository delegate;
  @override
  Future<int?> activeGeneration() => delegate.activeGeneration();
  @override
  SignInRepository forGeneration(int generation) =>
      _RejectAttemptRepository(delegate.forGeneration(generation));
  @override
  Future<({DailyPlan plan, bool claimed})> claimAttempt({
    required String day,
    required DateTime attemptedAt,
    required bool lateExecution,
    DailyPlan? expectedAutomaticPlan,
  }) async => throw StateError('secret storage path');
  @override
  Future<({DailyPlan? plan, SignInRecord record})> finalizeExecution({
    required DailyPlan? plan,
    required SignInRecord record,
  }) => delegate.finalizeExecution(plan: plan, record: record);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

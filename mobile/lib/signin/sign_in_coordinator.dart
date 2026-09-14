import 'dart:async';
import 'dart:math';

import '../auth/credential_store.dart';
import '../auth/session_store.dart';
import '../domain/sign_in_errors.dart';
import '../domain/sign_in_models.dart';
import '../schedule/daily_plan_service.dart';
import '../storage/sign_in_repository.dart';
import 'async_lock.dart';
import 'cross_process_execution_lock.dart';
import 'sign_in_gateway.dart';

abstract interface class SignInExecutor {
  Stream<DailyPlanStatus> get statusChanges;
  Future<SignInResult> run({
    required TriggerSource source,
    required DateTime now,
    int? generation,
    DailyPlan? expectedPlan,
  });
  Future<SignInResult> confirmUnknown(DateTime now, {int? generation});
}

class SignInCoordinator implements SignInExecutor {
  SignInCoordinator({
    required this._gateway,
    required this._credentialStore,
    required this._sessionStore,
    required this._repository,
    required this._planService,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
    SecondChooser? chooseSecond,
    CrossProcessExecutionLock? crossProcessLock,
  }) : _clock = clock ?? DateTime.now,
       _sleep = sleep ?? Future<void>.delayed,
       _chooseSecond = chooseSecond ?? _randomSecond,
       _crossProcessLock =
           crossProcessLock ?? NativeCrossProcessExecutionLock();

  final SignInGateway _gateway;
  final CredentialStore _credentialStore;
  final SessionStore _sessionStore;
  final SignInRepository _repository;
  final DailyPlanService _planService;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;
  final SecondChooser _chooseSecond;
  final CrossProcessExecutionLock _crossProcessLock;

  // Foreground and background entry points may construct separate coordinators
  // in the same isolate. They still share the execution and its progress.
  static final _locks = <int, AsyncLock<SignInResult>>{};
  int? _statusGeneration;
  static final _changes = StreamController<(int, DailyPlanStatus)>.broadcast();

  @override
  Stream<DailyPlanStatus> get statusChanges => _changes.stream
      .where((event) => event.$1 == _statusGeneration)
      .map((event) => event.$2);

  @override
  Future<SignInResult> run({
    required TriggerSource source,
    required DateTime now,
    int? generation,
    DailyPlan? expectedPlan,
  }) async {
    generation ??= await _repository.activeGeneration();
    if (generation == null ||
        generation != await _repository.activeGeneration()) {
      throw const AccountDataCleared();
    }
    final capturedGeneration = generation;
    _statusGeneration = generation;
    return _locks.putIfAbsent(generation, () => AsyncLock<SignInResult>()).run(
      () async {
        if (!await _crossProcessLock.tryAcquire()) {
          return const SignInResult(
            status: SignInRecordStatus.done,
            title: '已有任务执行中',
            detail: '未发起重复签到请求。',
          );
        }
        try {
          return await _execute(source, now, capturedGeneration, expectedPlan);
        } finally {
          await _crossProcessLock.release();
        }
      },
    );
  }

  @override
  Future<SignInResult> confirmUnknown(DateTime now, {int? generation}) =>
      run(source: TriggerSource.statusSync, now: now, generation: generation);

  Future<SignInResult> _execute(
    TriggerSource source,
    DateTime now,
    int generation,
    DailyPlan? expectedPlan,
  ) async {
    final repository = _repository.forGeneration(generation);
    final plans = _planService.forGeneration(generation);
    DailyPlan? plan;
    late _Outcome outcome;
    try {
      plan = await _storage<DailyPlan>(() => plans.ensureTodayPlan(now));
      if (plan.attemptedAt != null || source == TriggerSource.statusSync) {
        outcome = await _confirm(plan);
      } else if (_completed(plan)) {
        outcome = const _Outcome(SignInRecordStatus.done);
      } else {
        _changes.add((generation, DailyPlanStatus.checking));
        final status = await _preflight(generation);
        if (status == RemoteSignInState.done) {
          outcome = const _Outcome(SignInRecordStatus.done);
        } else {
          _changes.add((generation, DailyPlanStatus.jittering));
          final seconds = _chooseSecond(1, 2);
          if (seconds < 1 || seconds > 2) {
            throw const SignInError(SignInErrorKind.invalidResponse);
          }
          await _sleep(Duration(seconds: seconds));

          // Do not write any stale preflight snapshot before this transaction.
          // Only the winner may send the non-idempotent request.
          final day = plan.day;
          final attemptedAt = _clock();
          if (_localDay(attemptedAt) != day) throw const _DateChanged();
          final claim = await _storage(
            () => repository.claimAttempt(
              day: day,
              attemptedAt: attemptedAt,
              lateExecution: source == TriggerSource.lateCatchUp,
              expectedAutomaticPlan:
                  source == TriggerSource.scheduled ||
                      source == TriggerSource.lateCatchUp
                  ? expectedPlan ?? plan
                  : null,
            ),
          );
          plan = claim.plan;
          if (!claim.claimed) {
            outcome = await _confirm(plan);
          } else {
            _changes.add((generation, DailyPlanStatus.submitting));
            SignInError? submitError;
            try {
              await _gateway.submitSignIn(generation: generation);
            } catch (error) {
              submitError = _safeError(error);
            }
            outcome = await _confirm(
              plan,
              submitted: true,
              submitError: submitError,
            );
          }
        }
      }
    } on AutomaticPlanObsolete {
      rethrow;
    } on AccountDataCleared {
      rethrow;
    } catch (error) {
      outcome = _Outcome(
        plan?.attemptedAt == null
            ? SignInRecordStatus.failed
            : SignInRecordStatus.unknown,
        error: error is _DateChanged
            ? const SignInError(SignInErrorKind.businessRejected)
            : _safeError(error),
        detail: error is _DateChanged ? '日期已变化，请重新发起今日签到。' : null,
      );
    }
    return _record(repository, generation, plan, source, now, outcome);
  }

  Future<RemoteSignInState> _preflight(int generation) async {
    if (await _repository.activeGeneration() != generation) {
      throw const AccountDataCleared();
    }
    var expectedSession = await _sessionStore.peek();
    var sessionToInvalidate = expectedSession;
    try {
      if (await _gateway.validateSession(generation: generation) ==
          RemoteSessionState.expired) {
        throw const SignInError(SignInErrorKind.authExpired);
      }
      expectedSession = await _sessionStore.peek();
      sessionToInvalidate = expectedSession;
      return await _gateway.fetchStatus(generation: generation);
    } on SignInError catch (error) {
      if (error.kind != SignInErrorKind.authExpired) rethrow;
    }

    // Only explicit expiry permits reauthentication. Publish the candidate by
    // comparing against the initiating session, retaining it on network failure.
    try {
      final credentials = await _storage(_credentialStore.peek);
      if (credentials == null) {
        throw const SignInError(SignInErrorKind.authExpired);
      }
      if (await _repository.activeGeneration() != generation) {
        throw const AccountDataCleared();
      }
      final candidate = await _gateway.authenticate(credentials);
      if (await _repository.activeGeneration() != generation) {
        throw const AccountDataCleared();
      }
      final currentCredentials = await _credentialStore.peek();
      if (currentCredentials == null ||
          currentCredentials.instanceId != credentials.instanceId ||
          currentCredentials.username != credentials.username ||
          currentCredentials.password != credentials.password) {
        throw const AccountDataCleared();
      }
      if (!await _sessionStore.saveIfCurrent(
        expectedSession,
        candidate.forAccount(generation, credentials.instanceId),
      )) {
        throw const AccountDataCleared();
      }
      sessionToInvalidate = candidate.forAccount(
        generation,
        credentials.instanceId,
      );
      return await _gateway.fetchStatus(generation: generation);
    } on SignInError catch (error) {
      if (error.kind == SignInErrorKind.authExpired ||
          error.kind == SignInErrorKind.invalidCredentials) {
        await _storage(() => _sessionStore.clearIfCurrent(sessionToInvalidate));
      }
      rethrow;
    }
  }

  Future<_Outcome> _confirm(
    DailyPlan plan, {
    bool submitted = false,
    SignInError? submitError,
  }) async {
    if (await _repository.forGeneration(plan.generation).activeGeneration() ==
        null) {
      throw const AccountDataCleared();
    }
    _changes.add((plan.generation, DailyPlanStatus.confirming));
    SignInError? confirmationError;
    try {
      if (await _gateway.fetchStatus(generation: plan.generation) ==
          RemoteSignInState.done) {
        final wasAlreadySigned =
            submitError?.kind == SignInErrorKind.businessRejected ||
            submitError?.kind == SignInErrorKind.invalidResponse;
        return _Outcome(
          submitted && !wasAlreadySigned
              ? SignInRecordStatus.success
              : SignInRecordStatus.done,
          detail: wasAlreadySigned ? '检测到今日已签到，已跳过重复提交。' : null,
        );
      }
    } catch (error) {
      confirmationError = _safeError(error);
    }
    // A delayed/pending remote read must not erase a known completion.
    if (_completed(plan)) return const _Outcome(SignInRecordStatus.done);
    if (submitError?.kind == SignInErrorKind.businessRejected ||
        submitError?.kind == SignInErrorKind.authExpired ||
        submitError?.kind == SignInErrorKind.invalidCredentials) {
      return _Outcome(SignInRecordStatus.failed, error: submitError);
    }
    return _Outcome(
      SignInRecordStatus.unknown,
      error:
          confirmationError ??
          submitError ??
          const SignInError(SignInErrorKind.resultUnknown),
    );
  }

  Future<SignInResult> _record(
    SignInRepository repository,
    int generation,
    DailyPlan? plan,
    TriggerSource source,
    DateTime now,
    _Outcome outcome,
  ) async {
    final status = switch (outcome.status) {
      SignInRecordStatus.success => DailyPlanStatus.success,
      SignInRecordStatus.done => DailyPlanStatus.done,
      SignInRecordStatus.failed => DailyPlanStatus.failed,
      SignInRecordStatus.unknown => DailyPlanStatus.unknown,
    };
    // All visible text is local. Exception details may contain credentials or
    // raw responses and must never enter a result, SQLite record, or stream.
    final title = switch (outcome.status) {
      SignInRecordStatus.success =>
        source == TriggerSource.lateCatchUp ? '系统延迟补签' : '签到成功',
      SignInRecordStatus.done => '今日已签到',
      SignInRecordStatus.unknown => '结果待确认',
      SignInRecordStatus.failed =>
        outcome.error?.kind == SignInErrorKind.authExpired ||
                outcome.error?.kind == SignInErrorKind.invalidCredentials
            ? '登录已失效'
            : '签到失败',
    };
    final detail = switch (outcome.status) {
      SignInRecordStatus.success =>
        source == TriggerSource.lateCatchUp ? '系统延迟后已完成今日补签。' : '已完成今日签到。',
      SignInRecordStatus.done => outcome.detail ?? '今日签到状态已确认。',
      SignInRecordStatus.failed =>
        outcome.detail ??
            outcome.error?.detail ??
            outcome.error?.userMessage ??
            '签到未完成，请稍后重试。',
      SignInRecordStatus.unknown =>
        outcome.error?.detail ?? '签到结果暂未确认，请稍后同步状态。',
    };
    late SignInRecord record;
    try {
      final accepted = await _storage(
        () => repository.finalizeExecution(
          plan: plan?.copyWith(status: status),
          record: SignInRecord(
            generation: generation,
            day: plan?.day ?? _localDay(now),
            plannedAt: plan?.plannedAt,
            occurredAt: _clock(),
            source: source,
            status: outcome.status,
            title: title,
            detail: detail,
            errorKind: outcome.error?.kind,
          ),
        ),
      );
      record = accepted.record;
    } on AccountDataCleared {
      // The obsolete lifetime cannot publish data or clear a newer session.
      _changes.add((generation, DailyPlanStatus.failed));
      rethrow;
    } on SignInError {
      // An unavailable record store cannot durably log its own failure. Surface
      // a sanitized storage error and a terminal phase, retaining the claim.
      _changes.add((generation, DailyPlanStatus.failed));
      rethrow;
    }
    _changes.add((
      generation,
      DailyPlanStatus.values.byName(record.status.name),
    ));
    return SignInResult(
      status: record.status,
      title: record.title,
      detail: record.detail,
      record: record,
    );
  }

  static bool _completed(DailyPlan plan) =>
      plan.status == DailyPlanStatus.success ||
      plan.status == DailyPlanStatus.done;

  static SignInError _safeError(Object error) => error is SignInError
      ? SignInError(error.kind, detail: SignInError.safeDetail(error.detail))
      : const SignInError(SignInErrorKind.invalidResponse);

  static Future<T> _storage<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on AutomaticPlanObsolete {
      rethrow;
    } on AccountDataCleared {
      rethrow;
    } catch (_) {
      throw const SignInError(SignInErrorKind.localStorage);
    }
  }

  static int _randomSecond(int minimum, int maximum) =>
      minimum + Random().nextInt(maximum - minimum + 1);

  static String _localDay(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

class _Outcome {
  const _Outcome(this.status, {this.error, this.detail});
  final SignInRecordStatus status;
  final SignInError? error;
  final String? detail;
}

class _DateChanged implements Exception {
  const _DateChanged();
}

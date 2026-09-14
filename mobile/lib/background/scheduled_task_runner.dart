import '../domain/sign_in_errors.dart';
import '../domain/sign_in_models.dart';
import '../notifications/sign_in_notifications.dart';
import '../signin/sign_in_coordinator.dart';
import '../storage/sign_in_repository.dart';

class ScheduledTaskRunner {
  ScheduledTaskRunner({
    required this.notifications,
    required this.executor,
    this.repository,
  });

  final NotificationService notifications;
  final SignInExecutor executor;
  final SignInRepository? repository;

  Future<SignInResult> runScheduled({
    required DateTime now,
    DailyPlan? plan,
  }) async => (await runScheduledWithOutcome(now: now, plan: plan)).result;

  /// The callback needs to distinguish a skipped snapshot from an executed
  /// attempt before it chooses whether to schedule today or tomorrow.
  Future<({SignInResult result, bool executed})> runScheduledWithOutcome({
    required DateTime now,
    DailyPlan? plan,
  }) async {
    final root = repository;
    final generation = plan?.generation ?? await root?.activeGeneration();
    if (root != null && generation == null) throw const AccountDataCleared();
    final store = generation == null ? null : root?.forGeneration(generation);
    if (store != null && !(await store.loadSettings()).enabled) {
      return _skipped('自动签到已关闭');
    }
    if (store != null) {
      final authoritative = await store.planForDay(localDay(now));
      if (authoritative == null ||
          (plan != null && !samePlanIdentity(plan, authoritative))) {
        return _skipped('签到计划已变化');
      }
      plan = authoritative;
    }
    if (plan == null || plan.day != localDay(now)) return _skipped('今日没有待执行计划');
    if (now.isBefore(plan.plannedAt)) return _skipped('尚未到计划时间');

    final late = now.isAfter(plan.plannedAt);
    final source = late ? TriggerSource.lateCatchUp : TriggerSource.scheduled;
    if (late) {
      await _notify(
        () => notifications.showLateCatchUp(
          plan!,
          now,
          isEnabled: store == null
              ? null
              : () async => (await store.loadSettings()).notificationsEnabled,
          deliverIfCurrent: store == null
              ? null
              : (action) => store.withGeneration(generation!, action),
          isCurrent: () async =>
              store == null || await store.activeGeneration() != null,
        ),
      );
    }
    if (store != null) {
      // Notification delivery yields control to settings/account actions.
      // Revalidate after it, immediately before entering the executor.
      if (!(await store.loadSettings()).enabled) return _skipped('自动签到已关闭');
      final authoritative = await store.planForDay(localDay(now));
      if (authoritative == null || !samePlanIdentity(plan, authoritative)) {
        return _skipped('签到计划已变化');
      }
      if (now.isBefore(authoritative.plannedAt)) return _skipped('尚未到计划时间');
      plan = authoritative;
    }
    late SignInResult result;
    try {
      // The coordinator owns atomic claiming, query-before-submit and durable
      // records. A background wakeup must never introduce its own POST retry.
      result = await executor.run(
        source: source,
        now: now,
        generation: plan.generation,
        expectedPlan: plan,
      );
    } on AutomaticPlanObsolete {
      return _skipped('签到计划已变化或已关闭');
    } on AccountDataCleared {
      rethrow;
    } catch (_) {
      result = await _recordFailure(plan, source, now);
    }
    if (store != null && await store.planForDay(plan.day) == null) {
      throw const AccountDataCleared();
    }
    await _notify(
      () => notifications.showResult(
        result,
        isEnabled: store == null
            ? null
            : () async => (await store.loadSettings()).notificationsEnabled,
        deliverIfCurrent: store == null
            ? null
            : (action) => store.withGeneration(generation!, action),
        isCurrent: () async =>
            store == null || await store.activeGeneration() != null,
      ),
    );
    if (store != null && await store.activeGeneration() == null) {
      throw const AccountDataCleared();
    }
    return (result: result, executed: true);
  }

  static bool samePlanIdentity(DailyPlan first, DailyPlan second) =>
      first.generation == second.generation &&
      first.day == second.day &&
      first.startMinute == second.startMinute &&
      first.endMinute == second.endMinute &&
      first.plannedAt == second.plannedAt;

  Future<SignInResult> _recordFailure(
    DailyPlan plan,
    TriggerSource source,
    DateTime now,
  ) async {
    var result = const SignInResult(
      status: SignInRecordStatus.failed,
      title: '签到失败',
      detail: '本地后台任务未完成，请打开应用查看。',
    );
    try {
      final store = repository?.forGeneration(plan.generation);
      if (store == null) return result;
      final latest = await store.planForDay(plan.day) ?? plan;
      final unknown = latest.attemptedAt != null;
      result = result.copyWith(
        status: unknown
            ? SignInRecordStatus.unknown
            : SignInRecordStatus.failed,
        title: unknown ? '结果待确认' : '签到失败',
        detail: unknown ? '签到结果暂未确认，请打开应用同步状态。' : result.detail,
      );
      final persisted = await store.finalizeExecution(
        plan: latest.copyWith(
          status: unknown ? DailyPlanStatus.unknown : DailyPlanStatus.failed,
        ),
        record: SignInRecord(
          generation: plan.generation,
          day: latest.day,
          plannedAt: latest.plannedAt,
          occurredAt: now,
          source: source,
          status: result.status,
          title: result.title,
          detail: result.detail,
          errorKind: SignInErrorKind.localStorage,
        ),
      );
      return SignInResult(
        status: persisted.record.status,
        title: persisted.record.title,
        detail: persisted.record.detail,
        record: persisted.record,
      );
    } on AccountDataCleared {
      rethrow;
    } catch (_) {
      // An inaccessible database cannot durably log its own failure. Do not
      // discard an existing attemptedAt claim or request worker resubmission.
      return result;
    }
  }

  static ({SignInResult result, bool executed}) _skipped(String title) => (
    result: SignInResult(
      status: SignInRecordStatus.done,
      title: title,
      detail: '未发起签到请求。',
    ),
    executed: false,
  );

  static Future<void> _notify(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      /* Best effort; records remain durable. */
    }
  }

  static String localDay(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}

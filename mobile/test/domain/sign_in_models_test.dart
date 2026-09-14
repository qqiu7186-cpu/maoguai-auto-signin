import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';

void main() {
  test('schedule requires start before end', () {
    expect(
      () => ScheduleSettings(
        enabled: true,
        notificationsEnabled: true,
        startMinute: 600,
        endMinute: 480,
      ),
      throwsArgumentError,
    );
  });

  test('daily plan preserves planned and actual timestamps', () {
    final plan = DailyPlan(
      day: '2026-09-09',
      startMinute: 480,
      endMinute: 600,
      plannedAt: DateTime(2026, 9, 9, 9, 17),
      status: DailyPlanStatus.planned,
      attemptedAt: DateTime(2026, 9, 9, 9, 18),
      actualAt: DateTime(2026, 9, 9, 9, 19),
    );

    expect(DailyPlan.fromMap(plan.toMap()), plan);
  });

  test('daily plan uses SQLite integers and clears attempt timestamps', () {
    final plan = DailyPlan(
      day: '2026-09-09',
      startMinute: 480,
      endMinute: 600,
      plannedAt: DateTime(2026, 9, 9, 9, 17),
      status: DailyPlanStatus.done,
      attemptedAt: DateTime(2026, 9, 9, 9, 18),
      actualAt: DateTime(2026, 9, 9, 9, 19),
      rangeRegenerated: true,
      lateExecution: true,
    );
    final sqliteMap = plan.toMap();

    expect(sqliteMap['rangeRegenerated'], 1);
    expect(sqliteMap['lateExecution'], 1);
    expect(DailyPlan.fromMap(sqliteMap), plan);

    final cleared = plan.copyWith(attemptedAt: null, actualAt: null);
    expect(cleared.attemptedAt, isNull);
    expect(cleared.actualAt, isNull);
  });

  test('sign-in record preserves a safe explicit error kind', () {
    final record = SignInRecord(
      id: 8,
      day: '2026-09-09',
      plannedAt: DateTime(2026, 9, 9, 9, 17),
      occurredAt: DateTime(2026, 9, 9, 9, 18),
      source: TriggerSource.scheduled,
      status: SignInRecordStatus.failed,
      title: '签到失败',
      detail: '请稍后重试',
      errorKind: SignInErrorKind.networkUnavailable,
    );

    expect(SignInRecord.fromMap(record.toMap()), record);
  });

  test('success result supplies the successful record status', () {
    const result = SignInResult.success();

    expect(result.status, SignInRecordStatus.success);
    expect(SignInResult.fromMap(result.toMap()), result);
  });

  test('sign-in errors preserve the safe user message', () {
    const error = SignInError(
      SignInErrorKind.invalidCredentials,
      detail: '账号或密码无效',
    );

    expect(error.userMessage, '账号或密码不正确，请检查后重试。');
    expect(SignInError.fromMap(error.toMap()), error);
  });

  test('malformed service responses explain the safe failure boundary', () {
    const error = SignInError(SignInErrorKind.invalidResponse);

    expect(error.userMessage, '服务端返回的数据格式不符合已知协议，未能确认签到结果。');
  });

  test('copyWith can clear nullable record, result, and error fields', () {
    final record = SignInRecord(
      id: 8,
      day: '2026-09-09',
      plannedAt: DateTime(2026, 9, 9, 9, 17),
      occurredAt: DateTime(2026, 9, 9, 9, 18),
      source: TriggerSource.scheduled,
      status: SignInRecordStatus.failed,
      title: '签到失败',
      detail: '请稍后重试',
      errorKind: SignInErrorKind.networkUnavailable,
    );
    final clearedRecord = record.copyWith(
      id: null,
      plannedAt: null,
      errorKind: null,
    );
    final result = SignInResult(
      status: SignInRecordStatus.failed,
      title: '签到失败',
      detail: '请稍后重试',
      record: record,
    );
    const error = SignInError(
      SignInErrorKind.networkUnavailable,
      detail: '网络不可用',
    );

    expect(clearedRecord.id, isNull);
    expect(clearedRecord.plannedAt, isNull);
    expect(clearedRecord.errorKind, isNull);
    expect(result.copyWith(record: null).record, isNull);
    expect(error.copyWith(detail: null).detail, isNull);
  });
}

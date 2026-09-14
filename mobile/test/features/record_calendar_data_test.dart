import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/features/logs/record_calendar_data.dart';

import '../support/test_dependencies.dart';

void main() {
  test('calendar distinguishes no record, planned, success and problems', () {
    final plan = DailyPlan(
      day: '2026-09-09',
      startMinute: 480,
      endMinute: 600,
      plannedAt: DateTime(2026, 9, 9, 8),
      status: DailyPlanStatus.planned,
    );
    final failed = SignInRecord(
      day: plan.day,
      occurredAt: plan.plannedAt,
      source: TriggerSource.manual,
      status: SignInRecordStatus.failed,
      title: '失败',
      detail: '',
    );
    expect(calendarStatus([], null), CalendarDayStatus.empty);
    expect(calendarStatus([], plan), CalendarDayStatus.planned);
    expect(calendarStatus([failed], plan), CalendarDayStatus.problem);
    expect(
      calendarStatus([
        failed.copyWith(status: SignInRecordStatus.unknown),
      ], null),
      CalendarDayStatus.problem,
    );
    expect(
      calendarStatus([], plan.copyWith(status: DailyPlanStatus.unknown)),
      CalendarDayStatus.problem,
    );
    expect(
      calendarStatus([], plan.copyWith(status: DailyPlanStatus.done)),
      CalendarDayStatus.success,
    );
    expect(
      calendarStatus([
        failed,
        failed.copyWith(status: SignInRecordStatus.success),
      ], plan),
      CalendarDayStatus.success,
    );
  });

  test(
    'repository overview spans month boundary and excludes failed counts',
    () async {
      final deps = TestDependencies();
      for (final (day, status) in [
        ('2026-08-31', SignInRecordStatus.success),
        ('2026-09-01', SignInRecordStatus.success),
        ('2026-09-02', SignInRecordStatus.failed),
        ('2026-09-03', SignInRecordStatus.done),
      ]) {
        await deps.repository.insertRecord(
          SignInRecord(
            day: day,
            occurredAt: DateTime.parse(day),
            source: TriggerSource.manual,
            status: status,
            title: '',
            detail: '',
          ),
        );
      }
      final data = await RecordCalendarData.load(
        deps.repository.forGeneration(1),
        DateTime(2026, 8, 28),
        DateTime(2026, 9, 3),
      );
      expect(data.successCountForMonth('2026-09'), 2);
      expect(data.statusForDay('2026-08-31'), CalendarDayStatus.success);
      expect(data.statusForDay('2026-09-02'), CalendarDayStatus.problem);
      await deps.repository.clearAccountData();
      await expectLater(
        RecordCalendarData.load(
          deps.repository.forGeneration(1),
          DateTime(2026, 9, 1),
          DateTime(2026, 9, 3),
        ),
        throwsA(anything),
      );
    },
  );

  test('monthly success count counts each successful calendar day once', () {
    final data = RecordCalendarData([
      SignInRecord(
        day: '2026-09-09',
        occurredAt: DateTime(2026, 9, 9, 8, 5),
        source: TriggerSource.scheduled,
        status: SignInRecordStatus.success,
        title: '签到成功',
        detail: '',
      ),
      SignInRecord(
        day: '2026-09-09',
        occurredAt: DateTime(2026, 9, 9, 8, 6),
        source: TriggerSource.manual,
        status: SignInRecordStatus.done,
        title: '今日已签到',
        detail: '',
      ),
      SignInRecord(
        day: '2026-09-10',
        occurredAt: DateTime(2026, 9, 10, 8, 5),
        source: TriggerSource.scheduled,
        status: SignInRecordStatus.success,
        title: '签到成功',
        detail: '',
      ),
      SignInRecord(
        day: '2026-09-11',
        occurredAt: DateTime(2026, 9, 11, 8, 5),
        source: TriggerSource.scheduled,
        status: SignInRecordStatus.failed,
        title: '签到失败',
        detail: '',
      ),
    ], const {});

    expect(data.successCountForMonth('2026-09'), 2);
  });
}

import '../../domain/sign_in_models.dart';
import '../../storage/sign_in_repository.dart';

enum CalendarDayStatus { empty, planned, success, problem }

CalendarDayStatus calendarStatus(List<SignInRecord> records, DailyPlan? plan) {
  if (plan?.status == DailyPlanStatus.success ||
      plan?.status == DailyPlanStatus.done ||
      records.any((r) => isSuccessfulRecord(r.status))) {
    return CalendarDayStatus.success;
  }
  if (plan?.status == DailyPlanStatus.failed ||
      plan?.status == DailyPlanStatus.unknown ||
      records.isNotEmpty) {
    return CalendarDayStatus.problem;
  }
  return plan == null ? CalendarDayStatus.empty : CalendarDayStatus.planned;
}

bool isSuccessfulRecord(SignInRecordStatus status) =>
    status == SignInRecordStatus.success || status == SignInRecordStatus.done;

String calendarStatusLabel(CalendarDayStatus status) => switch (status) {
  CalendarDayStatus.empty => '暂无记录',
  CalendarDayStatus.planned => '已计划',
  CalendarDayStatus.success => '签到成功',
  CalendarDayStatus.problem => '失败或待确认',
};

String calendarDayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class RecordCalendarData {
  RecordCalendarData(this.records, this.plans);
  final List<SignInRecord> records;
  final Map<String, DailyPlan> plans;

  List<SignInRecord> recordsForDay(String day) =>
      records.where((record) => record.day == day).toList()
        ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  CalendarDayStatus statusForDay(String day) =>
      calendarStatus(recordsForDay(day), plans[day]);

  int successCountForMonth(String month) => records
      .where((r) => r.day.startsWith('$month-') && isSuccessfulRecord(r.status))
      .map((r) => r.day)
      .toSet()
      .length;

  /// The caller supplies an account-generation-scoped repository. Every query
  /// and the final fence fail if logout invalidates that account lifetime.
  static Future<RecordCalendarData> load(
    SignInRepository repository,
    DateTime start,
    DateTime end,
  ) async {
    final days = <DateTime>[];
    for (
      var day = start;
      !day.isAfter(end);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      days.add(day);
    }
    final months = days.map((d) => calendarDayKey(d).substring(0, 7)).toSet();
    final records = (await Future.wait(months.map(repository.recordsForMonth)))
        .expand((r) => r)
        .toList();
    final plans = await Future.wait(
      days.map((day) => repository.planForDay(calendarDayKey(day))),
    );
    if (await repository.activeGeneration() == null) {
      throw const AccountDataCleared();
    }
    return RecordCalendarData(records, {
      for (final plan in plans.whereType<DailyPlan>()) plan.day: plan,
    });
  }
}

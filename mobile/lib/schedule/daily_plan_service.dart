import 'dart:math';

import '../domain/sign_in_models.dart';
import '../storage/sign_in_repository.dart';

typedef SecondChooser = int Function(int minimum, int maximum);

class DailyPlanService {
  DailyPlanService(this._repository, {SecondChooser? chooseSecond})
    : _chooseSecond = chooseSecond ?? _randomSecond;

  final SignInRepository _repository;
  final SecondChooser _chooseSecond;

  DailyPlanService forGeneration(int generation) => DailyPlanService(
    _repository.forGeneration(generation),
    chooseSecond: _chooseSecond,
  );

  Future<DailyPlan> ensureTodayPlan(DateTime now, {int? generation}) async {
    final scoped = forGeneration(generation ?? await _requireGeneration());
    final settings = await scoped._repository.loadSettings();
    return scoped._resolvePlanForDay(_startOfLocalDay(now), settings);
  }

  Future<int> _requireGeneration() async =>
      await _repository.activeGeneration() ??
      (throw const AccountDataCleared());

  Future<DailyPlan> updateSettings(
    ScheduleSettings settings,
    DateTime now, {
    int? generation,
  }) async {
    final scoped = forGeneration(generation ?? await _requireGeneration());
    final today = _startOfLocalDay(now);
    final existing = await scoped._repository.planForDay(_dayString(today));
    await scoped._repository.saveSettings(settings);
    return scoped._resolvePlanForDay(
      today,
      settings,
      rangeRegenerated: existing != null && _rangeChanged(existing, settings),
    );
  }

  Future<DailyPlan> nextPlanAfterCompletion(
    DateTime now, {
    int? generation,
  }) async {
    final scoped = forGeneration(generation ?? await _requireGeneration());
    final settings = await scoped._repository.loadSettings();
    final localNow = now.toLocal();
    final tomorrow = DateTime(localNow.year, localNow.month, localNow.day + 1);
    return scoped._resolvePlanForDay(tomorrow, settings);
  }

  Future<DailyPlan> _resolvePlanForDay(
    DateTime day,
    ScheduleSettings settings, {
    bool rangeRegenerated = false,
  }) async {
    final spanSeconds = (settings.endMinute - settings.startMinute) * 60;
    final offsetSeconds = _chooseSecond(0, spanSeconds);
    if (offsetSeconds < 0 || offsetSeconds > spanSeconds) {
      throw ArgumentError.value(
        offsetSeconds,
        'offsetSeconds',
        'Must be inside the configured range',
      );
    }

    final candidate = DailyPlan(
      generation: await _requireGeneration(),
      day: _dayString(day),
      startMinute: settings.startMinute,
      endMinute: settings.endMinute,
      plannedAt: day.add(
        Duration(minutes: settings.startMinute, seconds: offsetSeconds),
      ),
      status: DailyPlanStatus.planned,
      rangeRegenerated: rangeRegenerated,
    );
    return _repository.resolveDailyPlan(candidate);
  }

  static int _randomSecond(int minimum, int maximum) =>
      minimum + Random().nextInt(maximum - minimum + 1);

  static DateTime _startOfLocalDay(DateTime now) {
    final local = now.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static String _dayString(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static bool _rangeChanged(DailyPlan plan, ScheduleSettings settings) =>
      plan.startMinute != settings.startMinute ||
      plan.endMinute != settings.endMinute;
}

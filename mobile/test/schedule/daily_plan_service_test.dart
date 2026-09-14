import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/schedule/daily_plan_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';

final _initialSettings = ScheduleSettings(
  enabled: true,
  notificationsEnabled: true,
  startMinute: 480,
  endMinute: 600,
);

final _changedSettings = ScheduleSettings(
  enabled: true,
  notificationsEnabled: true,
  startMinute: 600,
  endMinute: 720,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late TestDatabaseBundle bundle;

  setUp(() async {
    bundle = await openTestDatabase();
  });

  tearDown(() => bundle.database.close());

  test('existing valid plan is reused after restart', () async {
    await bundle.repository.saveSettings(_initialSettings);
    final service = DailyPlanService(
      bundle.repository,
      chooseSecond: (_, _) => 3600,
    );

    final first = await service.ensureTodayPlan(DateTime(2026, 9, 9, 7));
    final second = await service.ensureTodayPlan(DateTime(2026, 9, 9, 8));

    expect(second.plannedAt, first.plannedAt);
  });

  test('unsigned day regenerates after range change', () async {
    await bundle.repository.saveSettings(_initialSettings);
    final service = DailyPlanService(
      bundle.repository,
      chooseSecond: (_, _) => 0,
    );
    await service.ensureTodayPlan(DateTime(2026, 9, 9, 7));

    final changed = await service.updateSettings(
      _changedSettings,
      DateTime(2026, 9, 9, 7, 30),
    );

    expect(changed.plannedAt, DateTime(2026, 9, 9, 10));
    expect(changed.rangeRegenerated, isTrue);
  });

  test(
    'invalid incomplete plan is replaced using the current local range',
    () async {
      await bundle.repository.saveSettings(_initialSettings);
      final invalidPlans = [
        DailyPlan(
          day: '2026-09-09',
          startMinute: 480,
          endMinute: 600,
          plannedAt: DateTime(2026, 9, 9, 7),
          status: DailyPlanStatus.planned,
        ),
        DailyPlan(
          day: '2026-09-09',
          startMinute: 0,
          endMinute: 1,
          plannedAt: DateTime(2026, 9, 9, 8),
          status: DailyPlanStatus.planned,
        ),
      ];

      for (final invalid in invalidPlans) {
        await bundle.database.database.delete('daily_plans');
        await bundle.repository.upsertPlan(invalid);

        final resolved = await DailyPlanService(
          bundle.repository,
          chooseSecond: (_, _) => 0,
        ).ensureTodayPlan(DateTime(2026, 9, 9, 7));

        expect(resolved.startMinute, 480);
        expect(resolved.endMinute, 600);
        expect(resolved.plannedAt, DateTime(2026, 9, 9, 8));
        expect(await bundle.repository.planForDay('2026-09-09'), resolved);
      }
    },
  );

  test('attempted plan is retained after a settings range change', () async {
    await bundle.repository.saveSettings(_initialSettings);
    final attempted = DailyPlan(
      day: '2026-09-09',
      startMinute: 480,
      endMinute: 600,
      plannedAt: DateTime(2026, 9, 9, 8, 30),
      status: DailyPlanStatus.submitting,
      attemptedAt: DateTime(2026, 9, 9, 8, 31),
    );
    await bundle.repository.upsertPlan(attempted);

    final resolved = await DailyPlanService(
      bundle.repository,
      chooseSecond: (_, _) => 0,
    ).updateSettings(_changedSettings, DateTime(2026, 9, 9, 9));

    expect(resolved, attempted);
    expect(await bundle.repository.planForDay('2026-09-09'), attempted);
  });

  for (final offset in [0, 7200]) {
    test('random offset $offset stays inside the inclusive window', () async {
      await bundle.repository.saveSettings(_initialSettings);

      final plan = await DailyPlanService(
        bundle.repository,
        chooseSecond: (_, _) => offset,
      ).ensureTodayPlan(DateTime(2026, 9, 9, 7));

      expect(
        plan.plannedAt,
        DateTime(2026, 9, 9, 8).add(Duration(seconds: offset)),
      );
    });
  }

  test('range change after success keeps today and applies tomorrow', () async {
    await bundle.repository.saveSettings(_initialSettings);
    final service = DailyPlanService(
      bundle.repository,
      chooseSecond: (_, _) => 0,
    );
    final original = await service.ensureTodayPlan(DateTime(2026, 9, 9, 7));
    await bundle.repository.upsertPlan(
      original.copyWith(status: DailyPlanStatus.success),
    );

    await service.updateSettings(_changedSettings, DateTime(2026, 9, 9, 12));

    expect(
      await bundle.repository.planForDay('2026-09-09'),
      original.copyWith(status: DailyPlanStatus.success),
    );
    final tomorrow = await service.nextPlanAfterCompletion(
      DateTime(2026, 9, 9, 12),
    );
    expect(tomorrow.day, '2026-09-10');
    expect(tomorrow.plannedAt, DateTime(2026, 9, 10, 10));
  });

  test('disabled automation keeps a plan for display', () async {
    await bundle.repository.saveSettings(
      ScheduleSettings(
        enabled: false,
        notificationsEnabled: true,
        startMinute: 480,
        endMinute: 600,
      ),
    );

    final plan = await DailyPlanService(
      bundle.repository,
      chooseSecond: (_, _) => 0,
    ).ensureTodayPlan(DateTime(2026, 9, 9, 7));

    expect(plan.plannedAt, DateTime(2026, 9, 9, 8));
  });
}

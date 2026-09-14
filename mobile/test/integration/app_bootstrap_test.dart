import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/app.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';

import '../support/test_dependencies.dart';

void main() {
  testWidgets('cold start restores the saved random plan without submitting', (
    tester,
  ) async {
    final dependencies = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 9, 7),
      settings: testSettings(),
    );
    await dependencies.repository.upsertPlan(
      DailyPlan(
        day: '2026-09-09',
        startMinute: 480,
        endMinute: 600,
        plannedAt: DateTime(2026, 9, 9, 9, 17, 32),
        status: DailyPlanStatus.planned,
      ),
    );

    await tester.pumpWidget(SignInApp(dependencies: dependencies));
    await tester.pumpAndSettle();

    expect(find.text('今日随机时间'), findsOneWidget);
    expect(dependencies.scheduler.scheduledPlans, hasLength(1));
    expect(
      dependencies.scheduler.scheduledPlans.single.plannedAt,
      DateTime(2026, 9, 9, 9, 17, 32),
    );
    expect(dependencies.gateway.submitCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

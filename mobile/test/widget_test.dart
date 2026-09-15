import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/app.dart';
import 'package:maoguai_signin/app_state.dart';
import 'package:maoguai_signin/features/logs/history_calendar_page.dart';
import 'package:maoguai_signin/features/logs/logs_page.dart';
import 'package:maoguai_signin/features/settings/settings_page.dart';
import 'package:maoguai_signin/features/logs/record_detail_page.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';

import 'support/test_dependencies.dart';

Future<void> enterLogin(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('login-username')),
    'user1234',
  );
  await tester.enterText(
    find.byKey(const ValueKey('login-password')),
    'secret',
  );
  await tester.ensureVisible(find.text('登录'));
  await tester.tap(find.text('登录'));
}

void main() {
  testWidgets('Android settings exposes exact alarm access status', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final deps = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 15, 7),
      settings: testSettings(),
    );
    final controller = SignInAppController(deps);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('精确闹钟权限'), findsOneWidget);
    expect(find.text('系统仅能延迟补签'), findsOneWidget);
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('records overview shows durable monthly and seven-day status', (
    tester,
  ) async {
    final deps = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 3, 7),
      settings: testSettings(),
    );
    for (final (day, status) in [
      ('2026-08-31', SignInRecordStatus.success),
      ('2026-09-01', SignInRecordStatus.success),
      ('2026-09-02', SignInRecordStatus.failed),
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
    final controller = SignInAppController(deps);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本月成功次数'), findsOneWidget);
    expect(find.bySemanticsLabel('本月成功次数，1'), findsOneWidget);
    expect(find.text('今日待签到'), findsOneWidget);
    expect(find.text('最近7天'), findsOneWidget);
    expect(find.bySemanticsLabel('8月31日，签到成功'), findsOneWidget);
    expect(find.bySemanticsLabel('9月2日，失败或待确认'), findsOneWidget);
    expect(find.text('9月3日'), findsOneWidget);
    expect(
      (tester.getTopLeft(find.text('9月3日')).dy -
              tester.getTopLeft(find.text('查看全部历史')).dy)
          .abs(),
      lessThan(24),
    );
    await controller.logout();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('本月成功次数，1'), findsNothing);
    controller.dispose();
  });

  testWidgets(
    'calendar dates communicate different statuses visually and semantically',
    (tester) async {
      final deps = await TestDependencies.authenticated(
        now: DateTime(2026, 9, 9, 7),
        settings: testSettings(),
      );
      final controller = SignInAppController(deps);
      await controller.initialize();
      final plan = controller.state.plan!;
      for (final (day, status) in [
        (7, SignInRecordStatus.success),
        (8, SignInRecordStatus.unknown),
      ]) {
        await deps.repository.insertRecord(
          SignInRecord(
            day: '2026-09-0$day',
            occurredAt: DateTime(2026, 9, day),
            source: TriggerSource.manual,
            status: status,
            title: '',
            detail: '',
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: HistoryCalendarPage(
            controller: controller,
            generation: plan.generation,
            initialDay: deps.now(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (day, label, icon) in [
        (6, '暂无记录', Icons.circle_outlined),
        (7, '签到成功', Icons.check_circle),
        (8, '失败或待确认', Icons.error_outline),
        (9, '已计划', Icons.schedule),
      ]) {
        expect(
          find.bySemanticsLabel(
            '9月$day日，$label，${day == 7 || day == 8 ? 1 : 0}条记录',
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(ValueKey('calendar-day-2026-9-$day')),
            matching: find.byIcon(icon),
          ),
          findsOneWidget,
        );
      }
      controller.dispose();
    },
  );

  for (final status in [
    DailyPlanStatus.planned,
    DailyPlanStatus.success,
    DailyPlanStatus.done,
  ]) {
    testWidgets(
      'range save feedback for $status reflects preserved successful day',
      (tester) async {
        final deps = await TestDependencies.authenticated(
          now: DateTime(2026, 9, 9, 7),
          settings: testSettings(),
        );
        final controller = SignInAppController(deps);
        await controller.initialize();
        final original = controller.state.plan!;
        await deps.repository.upsertPlan(original.copyWith(status: status));
        await controller.refreshLocalState();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SettingsPage(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('开始时间'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.keyboard_outlined));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '09');
        await tester.enterText(find.byType(TextField).last, '00');
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        final succeeded = status != DailyPlanStatus.planned;
        expect(find.text(succeeded ? '新范围将从明天生效' : '签到范围已更新'), findsOneWidget);
        expect(
          controller.state.plan!.plannedAt,
          succeeded ? original.plannedAt : DateTime(2026, 9, 9, 9),
        );
        controller.dispose();
      },
    );
  }

  Future<TestDependencies> authenticated(WidgetTester tester) async {
    final deps = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 9, 15),
      settings: testSettings(),
    );
    for (var i = 0; i < 7; i++) {
      await deps.repository.insertRecord(
        SignInRecord(
          day: '2026-09-09',
          occurredAt: DateTime(2026, 9, 9, 8, i),
          source: TriggerSource.manual,
          status: SignInRecordStatus.success,
          title: '签到成功 $i',
          detail: '真实记录 $i',
        ),
      );
    }
    await tester.pumpWidget(SignInApp(dependencies: deps));
    await tester.pumpAndSettle();
    return deps;
  }

  testWidgets('home uses current greeting, generated time and range', (
    tester,
  ) async {
    await authenticated(tester);
    expect(find.text('最近记录'), findsNothing);
    expect(find.text('下午好'), findsOneWidget);
    expect(find.textContaining('08:00–10:00'), findsOneWidget);
    expect(find.text('今日随机时间'), findsOneWidget);
    expect(find.text('预览'), findsNothing);
    expect(find.text('立即签到'), findsOneWidget);
  });

  testWidgets(
    'records show newest five and direct detail, calendar is uncapped',
    (tester) async {
      await authenticated(tester);
      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('查看记录详情')), findsNWidgets(5));
      expect(find.text('签到成功 0'), findsNothing);
      expect(find.text('签到成功 6'), findsOneWidget);
      await tester.tap(find.text('签到成功 6'));
      await tester.pumpAndSettle();
      expect(find.text('记录详情'), findsOneWidget);
      expect(find.text('真实记录 6'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('查看全部历史'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('查看全部历史'))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      await tester.ensureVisible(find.text('查看全部历史'));
      await tester.tap(find.text('查看全部历史'));
      await tester.pumpAndSettle();
      expect(find.text('9月9日 · 7条记录'), findsOneWidget);
      expect(find.text('签到成功 0'), findsOneWidget);
      await tester.tap(find.byTooltip('上个月'));
      await tester.pumpAndSettle();
      expect(find.text('2026年8月'), findsOneWidget);
      expect(find.text('当天暂无记录'), findsOneWidget);
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$platform uses native navigation and synchronizes rapid taps/swipes',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await authenticated(tester);
        expect(
          find.byType(CupertinoTabBar),
          platform == TargetPlatform.iOS ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('设置'));
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.text('首页'));
        await tester.pumpAndSettle();
        expect(find.text('下午好'), findsOneWidget);
        await tester.drag(find.byType(PageView), const Offset(-500, 0));
        await tester.pumpAndSettle();
        expect(find.text('签到记录'), findsOneWidget);
        if (platform == TargetPlatform.iOS) {
          expect(
            tester
                .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
                .currentIndex,
            1,
          );
        } else {
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            1,
          );
        }
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'settings persists range and notifications only after visible action',
    (tester) async {
      final deps = await authenticated(tester);
      expect(deps.notifications.permissionRequests, 0);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('us****34'), findsOneWidget);
      expect(find.text('开始时间'), findsOneWidget);
      expect(find.text('结束时间'), findsOneWidget);
      await tester.tap(find.text('开始时间'));
      await tester.pumpAndSettle();
      expect(find.text('选择开始时间'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '09');
      await tester.enterText(find.byType(TextField).last, '00');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(deps.repository.settings.startMinute, 540);
      expect(deps.repository.settings.endMinute, 600);
      await tester.tap(find.text('结束时间'));
      await tester.pumpAndSettle();
      expect(find.text('选择结束时间'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '08');
      await tester.enterText(find.byType(TextField).last, '00');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('开始时间必须早于结束时间'), findsOneWidget);
      expect(deps.repository.settings.endMinute, 600);
      final toggle = find.byKey(const ValueKey('notification-switch'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(deps.repository.settings.notificationsEnabled, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(deps.notifications.permissionRequests, 1);
      expect(deps.repository.settings.notificationsEnabled, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      deps.notifications.permissionGranted = false;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(deps.repository.settings.notificationsEnabled, isFalse);
    },
  );

  testWidgets(
    'notification permission denial explains how to enable it in system settings',
    (tester) async {
      final deps = await authenticated(tester);
      deps.notifications.permissionGranted = false;

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('notification-switch'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.text('通知权限未开启'), findsOneWidget);
      expect(find.text('前往系统设置'), findsOneWidget);
      expect(deps.repository.settings.notificationsEnabled, isFalse);
      await tester.tap(find.text('前往系统设置'));
      await tester.pumpAndSettle();
      expect(deps.notifications.settingsRequests, 1);
    },
  );

  testWidgets('old history and detail never adopt a newly logged-in account', (
    tester,
  ) async {
    final deps = await TestDependencies.authenticated(
      now: DateTime(2026, 9, 9, 15),
      settings: testSettings(),
    );
    final controller = SignInAppController(deps);
    await controller.initialize();
    final generation = controller.state.plan!.generation;
    final record = await deps.repository.insertRecord(
      SignInRecord(
        day: '2026-09-09',
        generation: generation,
        occurredAt: deps.now(),
        source: TriggerSource.manual,
        status: SignInRecordStatus.failed,
        title: '旧账号失败记录',
        detail: '旧账号详情',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryCalendarPage(
          controller: controller,
          generation: generation,
          initialDay: deps.now(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧账号失败记录'), findsOneWidget);
    await controller.logout();
    await controller.login('newuser', 'newsecret');
    await deps.repository.insertRecord(
      record.copyWith(
        generation: controller.state.plan!.generation,
        title: '新账号记录',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧账号失败记录'), findsNothing);
    expect(find.text('新账号记录'), findsNothing);
    expect(find.text('账号已退出，请返回登录'), findsOneWidget);
    // A route captured before logout may only mount after the next login.
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryCalendarPage(
          key: const ValueKey('stale-history'),
          controller: controller,
          generation: generation,
          initialDay: deps.now(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新账号记录'), findsNothing);
    expect(find.text('账号已退出，请返回登录'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordDetailPage(controller: controller, record: record),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧账号详情'), findsNothing);
    expect(find.text('账号已退出，请返回登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('manual sign-in disables duplicate action while running', (
    tester,
  ) async {
    final deps = await authenticated(tester);
    deps.gateway.submitCompleter = Completer<void>();
    await tester.tap(find.text('立即签到'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('签到中…'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton).first);
    expect(button.onPressed, isNull);
    deps.gateway.submitCompleter!.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('今日已签到'), findsOneWidget);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'compact layout at ${width}dp keeps status background and pages readable',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
        addTearDown(tester.view.reset);
        await authenticated(tester);
        expect(
          tester
              .getTopLeft(find.byKey(const ValueKey('scenic-status-surface')))
              .dy,
          0,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('scenic-header'))).dy,
          0,
        );
        expect(tester.getTopLeft(find.text('今日随机时间')).dy, lessThan(230));
        for (final title in ['记录', '设置']) {
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
  testWidgets(
    'startup storage failure is visible and a later login retries initialization',
    (tester) async {
      final deps = TestDependencies()
        ..initializeError = StateError('database unavailable');
      await tester.pumpWidget(SignInApp(dependencies: deps));
      await tester.pumpAndSettle();
      expect(
        find.text(const SignInError(SignInErrorKind.localStorage).userMessage),
        findsOneWidget,
      );
      deps.initializeError = null;
      await enterLogin(tester);
      await tester.pumpAndSettle();
      expect(find.text('首页'), findsOneWidget);
      expect(deps.gateway.authenticateCalls, 1);
    },
  );

  testWidgets(
    'new install shows centered blue-white login without native dependencies',
    (tester) async {
      final deps = TestDependencies();
      await tester.pumpWidget(SignInApp(dependencies: deps));
      await tester.pumpAndSettle();
      expect(find.text('签到助手'), findsOneWidget);
      expect(find.byKey(const ValueKey('login-brand-icon')), findsOneWidget);
      expect(find.byKey(const ValueKey('login-card')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(deps.gateway.authenticateCalls, 0);
      expect(deps.notifications.permissionRequests, 0);
      expect(
        (tester.getCenter(find.text('签到助手')).dx -
                tester.getCenter(find.byType(Scaffold)).dx)
            .abs(),
        lessThan(2),
      );
    },
  );
  testWidgets(
    'login waits for remote validation and logout clears the account',
    (tester) async {
      final deps = TestDependencies();
      deps.gateway.authenticateCompleter = Completer<void>();
      await tester.pumpWidget(SignInApp(dependencies: deps));
      await tester.pumpAndSettle();
      await enterLogin(tester);
      await tester.pump();
      expect(deps.credentials.saved, isNull);
      expect(find.text('首页'), findsNothing);
      deps.gateway.authenticateCompleter!.complete();
      await tester.pumpAndSettle();
      expect(deps.credentials.saved?.username, 'user1234');
      expect(find.text('首页'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('us****34'), findsOneWidget);
      await tester.ensureVisible(find.text('退出登录'));
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(deps.credentials.saved, isNotNull);
      await tester.tap(find.text('确认退出'));
      await tester.pumpAndSettle();
      expect(deps.credentials.saved, isNull);
      expect(deps.sessions.saved, isNull);
      expect(deps.repository.accountDataCleared, isTrue);
      expect(deps.scheduler.cancelled, isTrue);
      expect(find.text('登录'), findsOneWidget);
      expect(find.text('首页'), findsNothing);
    },
  );
  testWidgets('login groups username and password for system autofill', (
    tester,
  ) async {
    final deps = TestDependencies();
    await tester.pumpWidget(SignInApp(dependencies: deps));
    await tester.pumpAndSettle();

    expect(find.byType(AutofillGroup), findsOneWidget);
    final fields = tester.widgetList<EditableText>(find.byType(EditableText));
    expect(fields.elementAt(0).autofillHints, contains(AutofillHints.username));
    expect(fields.elementAt(1).autofillHints, contains(AutofillHints.password));
  });
  for (final kind in [
    SignInErrorKind.invalidCredentials,
    SignInErrorKind.networkUnavailable,
    SignInErrorKind.serverUnavailable,
  ]) {
    testWidgets('login presents safe user message for ${kind.name}', (
      tester,
    ) async {
      final deps = TestDependencies();
      final error = SignInError(kind, detail: 'sensitive upstream details');
      deps.gateway.authenticateError = error;
      await tester.pumpWidget(SignInApp(dependencies: deps));
      await tester.pumpAndSettle();
      await enterLogin(tester);
      await tester.pumpAndSettle();
      expect(find.text(error.userMessage), findsOneWidget);
      expect(find.textContaining('sensitive upstream'), findsNothing);
      expect(find.text('首页'), findsNothing);
      expect(deps.credentials.saved, isNull);
    });
  }
  testWidgets('invalid form never authenticates', (tester) async {
    final deps = TestDependencies();
    await tester.pumpWidget(SignInApp(dependencies: deps));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(deps.gateway.authenticateCalls, 0);
    expect(find.byType(TextFormField), findsNWidgets(2));
  });
}

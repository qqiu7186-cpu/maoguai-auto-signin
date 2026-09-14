import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/notifications/sign_in_notifications.dart';

void main() {
  test('account-scoped notification settings never use the unscoped default loader', () async {
    var unscopedReads = 0;
    final port = FakeNotificationPort();
    final notifications = SignInNotifications(
      platform: port,
      enabled: () async {
        unscopedReads++;
        return true;
      },
    );
    await notifications.showResult(
      const SignInResult.success(),
      isEnabled: () async => false,
    );
    expect(unscopedReads, 0);
    expect(port.titles, isEmpty);
    expect(port.settings, isNull);
  });
  test(
    'logout during notification initialization suppresses its delivery',
    () async {
      var active = true;
      final port = FakeNotificationPort()..initialization = Completer<void>();
      final notification = SignInNotifications(
        platform: port,
        enabled: () async => active,
      );
      final showing = notification.showResult(const SignInResult.success());
      await Future<void>.delayed(Duration.zero);
      active = false;
      port.initialization!.complete();
      await showing;
      expect(port.titles, isEmpty);
    },
  );
  test(
    'headless initialization configures channels without asking permission',
    () async {
      final port = FakeNotificationPort();
      final notifications = SignInNotifications(platform: port);
      await notifications.showResult(const SignInResult.success());
      expect(port.requests, 0);
      expect(port.settings!.iOS!.requestAlertPermission, isFalse);
      expect(port.settings!.iOS!.requestBadgePermission, isFalse);
      expect(port.settings!.iOS!.requestSoundPermission, isFalse);
      expect(port.channel!.id, 'signin_results');
      expect(port.channel!.importance, Importance.high);
      expect(port.details!.iOS, isNotNull);
      expect(port.details!.android!.channelId, 'signin_results');
    },
  );

  test('permission denial and platform failure are harmless', () async {
    final port = FakeNotificationPort()..fail = true;
    final notifications = SignInNotifications(platform: port);
    expect(await notifications.requestPermission(), isFalse);
    await notifications.showResult(const SignInResult.success());
  });

  test('permission is requested only by explicit permission action', () async {
    final port = FakeNotificationPort();
    final notifications = SignInNotifications(platform: port);
    expect(await notifications.requestPermission(), isFalse);
    expect(port.requests, 1);
  });

  test('disabled notifications do not post or initialize platform', () async {
    final port = FakeNotificationPort();
    await SignInNotifications(
      platform: port,
      enabled: () async => false,
    ).showResult(const SignInResult.success());
    expect(port.settings, isNull);
    expect(port.titles, isEmpty);
  });

  test(
    'result states produce distinct locally controlled notifications',
    () async {
      final port = FakeNotificationPort();
      final notifications = SignInNotifications(platform: port);
      for (final status in SignInRecordStatus.values) {
        await notifications.showResult(
          SignInResult(
            status: status,
            title: 'remote-secret',
            detail: 'remote-secret',
          ),
        );
      }
      expect(port.titles, ['签到成功', '今日已签到', '签到失败', '结果待确认']);
      expect(port.bodies.join(), isNot(contains('remote-secret')));
    },
  );

  test(
    'late notice gives planned and actual times without implying completion',
    () async {
      final port = FakeNotificationPort();
      await SignInNotifications(platform: port).showLateCatchUp(
        DailyPlan(
          day: '2026-09-09',
          startMinute: 480,
          endMinute: 600,
          plannedAt: DateTime(2026, 9, 9, 9, 20),
          status: DailyPlanStatus.planned,
        ),
        DateTime(2026, 9, 9, 10, 20),
      );
      expect(port.titles, ['系统延迟，准备补签']);
      expect(port.bodies.single, contains('09:20'));
      expect(port.bodies.single, contains('10:20'));
      expect(port.bodies.single, isNot(contains('已完成')));
    },
  );
}

class FakeNotificationPort implements NotificationPort {
  InitializationSettings? settings;
  AndroidNotificationChannel? channel;
  NotificationDetails? details;
  final titles = <String>[];
  final bodies = <String>[];
  int requests = 0;
  bool fail = false;
  Completer<void>? initialization;
  final initializationStarted = Completer<void>();
  @override
  Future<void> initialize({
    required InitializationSettings settings,
    required AndroidNotificationChannel channel,
  }) async {
    if (!initializationStarted.isCompleted) initializationStarted.complete();
    await initialization?.future;
    if (fail) throw StateError('platform unavailable');
    this.settings = settings;
    this.channel = channel;
  }

  @override
  Future<bool> requestPermission() async {
    requests++;
    return false;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
  }) async {
    if (fail) throw StateError('permission denied');
    titles.add(title);
    bodies.add(body);
    this.details = details;
  }
}

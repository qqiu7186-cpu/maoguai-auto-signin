import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/sign_in_errors.dart';
import '../domain/sign_in_models.dart';
import 'system_notification_settings.dart';

abstract interface class NotificationService {
  /// Invoke only from a visible settings action, never from a headless task.
  Future<bool> requestPermission();

  /// Opens the operating system's notification settings from a visible action.
  Future<bool> openNotificationSettings();
  Future<void> showLateCatchUp(
    DailyPlan plan,
    DateTime actualAt, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  });
  Future<void> showResult(
    SignInResult result, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  });
}

abstract interface class NotificationPort {
  Future<void> initialize({
    required InitializationSettings settings,
    required AndroidNotificationChannel channel,
  });
  Future<bool> requestPermission();
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
  });
}

class SignInNotifications implements NotificationService {
  SignInNotifications({
    NotificationPort? platform,
    NotificationSettingsPort? settingsPort,
    this._enabled,
  }) : _platform = platform ?? NativeNotificationPort(),
       _settingsPort = settingsPort ?? NativeNotificationSettingsPort();

  final NotificationPort _platform;
  final NotificationSettingsPort _settingsPort;
  final Future<bool> Function()? _enabled;
  bool _initialized = false;
  static const _channel = AndroidNotificationChannel(
    'signin_results',
    '签到结果',
    importance: Importance.high,
  );
  static const _darwinSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'signin_results',
      '签到结果',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  Future<void> _initialize() async {
    if (_initialized) return;
    await _platform.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: _darwinSettings,
      ),
      channel: _channel,
    );
    _initialized = true;
  }

  @override
  Future<bool> requestPermission() async {
    try {
      await _initialize();
      return await _platform.requestPermission();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openNotificationSettings() =>
      _settingsPort.openNotificationSettings();

  @override
  Future<void> showLateCatchUp(
    DailyPlan plan,
    DateTime actualAt, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) => _show(
    1,
    '系统延迟，准备补签',
    '计划时间 ${_time(plan.plannedAt)}，实际唤醒 ${_time(actualAt)}，现在检查今日签到状态。',
    isCurrent: isCurrent,
    isEnabled: isEnabled,
    deliverIfCurrent: deliverIfCurrent,
  );

  @override
  Future<void> showResult(
    SignInResult result, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) {
    final authExpired =
        result.record?.errorKind == SignInErrorKind.authExpired ||
        result.record?.errorKind == SignInErrorKind.invalidCredentials;
    final (title, body) = switch (result.status) {
      SignInRecordStatus.success => ('签到成功', '已完成今日签到。'),
      SignInRecordStatus.done => ('今日已签到', '今日签到状态已确认。'),
      SignInRecordStatus.failed when authExpired => ('登录已失效', '请打开应用重新登录。'),
      SignInRecordStatus.failed => ('签到失败', '请打开应用查看本地记录。'),
      SignInRecordStatus.unknown => ('结果待确认', '请打开应用同步状态，避免重复提交。'),
    };
    return _show(
      2,
      title,
      body,
      isCurrent: isCurrent,
      isEnabled: isEnabled,
      deliverIfCurrent: deliverIfCurrent,
    );
  }

  Future<void> _show(
    int id,
    String title,
    String body, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) async {
    try {
      if (isCurrent != null && !await isCurrent()) return;
      if (!(await (isEnabled ?? _enabled)?.call() ?? true)) return;
      if (isCurrent != null && !await isCurrent()) return;
      await _initialize();
      if (isCurrent != null && !await isCurrent()) return;
      if (!(await (isEnabled ?? _enabled)?.call() ?? true)) return;
      if (isCurrent != null && !await isCurrent()) return;
      Future<void> deliver() =>
          _platform.show(id: id, title: title, body: body, details: _details);
      if (deliverIfCurrent != null) {
        await deliverIfCurrent(deliver);
      } else {
        await deliver();
      }
    } catch (_) {
      // Notification availability/permission never determines sign-in outcome.
    }
  }

  static String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class NativeNotificationPort implements NotificationPort {
  NativeNotificationPort({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> initialize({
    required InitializationSettings settings,
    required AndroidNotificationChannel channel,
  }) async {
    await _plugin.initialize(settings: settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  @override
  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
  }) => _plugin.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: details,
  );
}

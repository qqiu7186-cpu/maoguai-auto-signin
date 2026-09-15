import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../background/background_scheduler.dart';
import '../../domain/sign_in_errors.dart';
import '../../domain/sign_in_models.dart';
import '../../ui/scenic_page.dart';

class SettingsPage extends StatefulWidget {
  // Retain the non-const production controller constructor from Task 8.
  // ignore: prefer_const_constructors_in_immutables
  SettingsPage({required this.controller, super.key});
  final SignInAppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  bool _busy = false;
  BackgroundScheduleStatus? _backgroundScheduleStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      _refreshBackgroundScheduleStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        defaultTargetPlatform == TargetPlatform.android) {
      _refreshBackgroundScheduleStatus();
    }
  }

  Future<void> _refreshBackgroundScheduleStatus() async {
    try {
      final status = await widget.controller.backgroundScheduleStatus();
      if (mounted) setState(() => _backgroundScheduleStatus = status);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _backgroundScheduleStatus = BackgroundScheduleStatus.fallbackOnly,
        );
      }
    }
  }

  Future<void> _openBackgroundScheduleSettings() async {
    final opened = await widget.controller.openBackgroundScheduleSettings();
    if (!mounted) return;
    if (!opened) {
      _showMessage('无法打开系统闹钟权限设置');
      return;
    }
    await _refreshBackgroundScheduleStatus();
  }

  String get _backgroundScheduleStatusText =>
      switch (_backgroundScheduleStatus) {
        BackgroundScheduleStatus.exact => '已允许准时唤醒',
        BackgroundScheduleStatus.permissionNeeded => '需要允许“闹钟和提醒”权限',
        BackgroundScheduleStatus.fallbackOnly => '系统仅能延迟补签',
        null => '正在检查系统权限…',
      };

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _showMessage(error is SignInError ? error.userMessage : '操作失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime({required bool start}) async {
    final settings = widget.controller.state.settings;
    final minute = start ? settings.startMinute : settings.endMinute;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
      helpText: start ? '选择开始时间' : '选择结束时间',
      cancelText: '取消',
      confirmText: '确定',
      hourLabelText: '小时',
      minuteLabelText: '分钟',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (!mounted || selected == null) return;
    final value = selected.hour * 60 + selected.minute;
    if ((start && value >= settings.endMinute) ||
        (!start && value <= settings.startMinute)) {
      _showMessage('开始时间必须早于结束时间');
      return;
    }
    await _perform(() async {
      await widget.controller.updateSchedule(
        settings.copyWith(
          startMinute: start ? value : null,
          endMinute: start ? null : value,
        ),
      );
      if (!mounted || !widget.controller.state.isLoggedIn) return;
      final plan = widget.controller.state.plan;
      final successfulToday =
          plan != null &&
          plan.day == dayKey(widget.controller.state.now) &&
          (plan.status == DailyPlanStatus.success ||
              plan.status == DailyPlanStatus.done);
      _showMessage(successfulToday ? '新范围将从明天生效' : '签到范围已更新');
    });
  }

  Future<void> _setNotificationsEnabled(bool enabled) async {
    await _perform(() => widget.controller.setNotificationsEnabled(enabled));
    if (!mounted ||
        !enabled ||
        widget.controller.state.settings.notificationsEnabled) {
      return;
    }
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('通知权限未开启'),
        content: const Text('请在系统设置中允许“签到助手”发送通知，返回后再开启此开关。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('前往系统设置'),
          ),
        ],
      ),
    );
    if (mounted && openSettings == true) {
      await _perform(widget.controller.openNotificationSettings);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录？'),
        content: const Text('退出后将停止自动签到并清除当前账号记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await _perform(widget.controller.logout);
  }

  Future<void> _checkShortcutConnection() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final check = await widget.controller.checkNativeConnection();
      if (mounted) _showMessage('${check.title}：${check.detail}');
    } catch (error) {
      if (mounted) {
        _showMessage(error is SignInError ? error.userMessage : '连接检查失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final disabled = _busy || state.isRunning;
    return ScenicScrollPage(
      showArtwork: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ScenicPageHeader(title: '账号与计划'),
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(
                state.maskedUsername,
                key: const ValueKey('masked-username'),
              ),
              subtitle: const Text('账号已登录'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  title: const Text('自动签到'),
                  value: state.settings.enabled,
                  onChanged: disabled
                      ? null
                      : (value) => _perform(
                          () => widget.controller.setAutomationEnabled(value),
                        ),
                ),
                ListTile(
                  title: const Text('开始时间'),
                  trailing: Text(formatMinute(state.settings.startMinute)),
                  onTap: disabled ? null : () => _pickTime(start: true),
                ),
                ListTile(
                  title: const Text('结束时间'),
                  trailing: Text(formatMinute(state.settings.endMinute)),
                  onTap: disabled ? null : () => _pickTime(start: false),
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('notification-switch'),
                  title: const Text('通知提醒'),
                  value: state.settings.notificationsEnabled,
                  onChanged: disabled ? null : _setNotificationsEnabled,
                ),
              ],
            ),
          ),
          if (defaultTargetPlatform == TargetPlatform.iOS) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.shortcut_outlined),
                title: const Text('快捷指令后台签到'),
                subtitle: const Text('在“快捷指令”添加“执行签到”，再设置每日自动化。'),
                trailing: TextButton(
                  onPressed: disabled ? null : _checkShortcutConnection,
                  child: const Text('检查连接'),
                ),
              ),
            ),
          ],
          if (defaultTargetPlatform == TargetPlatform.android) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                key: const ValueKey('exact-alarm-status'),
                leading: const Icon(Icons.alarm_on_outlined),
                title: const Text('精确闹钟权限'),
                subtitle: Text(_backgroundScheduleStatusText),
                trailing: TextButton(
                  onPressed: disabled
                      ? null
                      : _backgroundScheduleStatus ==
                            BackgroundScheduleStatus.exact
                      ? _refreshBackgroundScheduleStatus
                      : _openBackgroundScheduleSettings,
                  child: Text(
                    _backgroundScheduleStatus == BackgroundScheduleStatus.exact
                        ? '重新检查'
                        : '去开启',
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.touch_app_outlined),
              title: const Text('手动签到'),
              trailing: const Icon(Icons.chevron_right),
              subtitle: state.isRunning ? const Text('签到中…') : null,
              onTap: disabled
                  ? null
                  : () => _perform(widget.controller.runManualSignIn),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: disabled ? null : _logout,
              icon: const Icon(Icons.logout),
              label: const Text('退出登录'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ),
        ],
      ),
    );
  }
}

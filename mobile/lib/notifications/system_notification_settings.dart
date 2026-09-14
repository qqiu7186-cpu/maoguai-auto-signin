import 'package:flutter/services.dart';

abstract interface class NotificationSettingsPort {
  Future<bool> openNotificationSettings();
}

class NativeNotificationSettingsPort implements NotificationSettingsPort {
  static const _channel = MethodChannel('maoguai/notification_settings');

  @override
  Future<bool> openNotificationSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openNotificationSettings') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

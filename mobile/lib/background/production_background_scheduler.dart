import 'package:flutter/foundation.dart';

import 'android_alarm_scheduler.dart';
import 'background_scheduler.dart';
import 'workmanager_scheduler.dart';

BackgroundScheduler createProductionBackgroundScheduler({
  TargetPlatform? targetPlatform,
  bool completingWorkmanagerTask = false,
}) {
  final platform = targetPlatform ?? defaultTargetPlatform;
  final fallback = WorkmanagerScheduler(
    completingTask: completingWorkmanagerTask,
  );
  if (platform == TargetPlatform.android) {
    return AndroidAlarmScheduler(fallback: fallback);
  }
  return fallback;
}

import '../domain/sign_in_models.dart';

abstract interface class BackgroundScheduler {
  Future<void> schedule(DailyPlan plan);
  Future<void> cancel();
}

abstract interface class InitializableBackgroundScheduler {
  Future<void> initialize();
}

enum BackgroundScheduleStatus { exact, permissionNeeded, fallbackOnly }

abstract interface class BackgroundSchedulerSettings {
  Future<BackgroundScheduleStatus> status();
  Future<bool> openSystemSettings();
}

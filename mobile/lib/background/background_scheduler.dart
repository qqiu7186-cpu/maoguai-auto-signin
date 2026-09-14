import '../domain/sign_in_models.dart';

abstract interface class BackgroundScheduler {
  Future<void> schedule(DailyPlan plan);
  Future<void> cancel();
}

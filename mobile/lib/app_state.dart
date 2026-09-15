import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/credential_store.dart';
import 'auth/session_store.dart';
import 'background/background_scheduler.dart';
import 'background/production_background_scheduler.dart';
import 'domain/sign_in_errors.dart';
import 'domain/sign_in_models.dart';
import 'notifications/sign_in_notifications.dart';
import 'schedule/daily_plan_service.dart';
import 'signin/maoguai_sign_in_client.dart';
import 'signin/sign_in_coordinator.dart';
import 'signin/sign_in_gateway.dart';
import 'storage/app_database.dart';
import 'storage/sign_in_repository.dart';
import 'shortcuts/native_background_results.dart';

abstract interface class AppDependencies {
  factory AppDependencies.production() = _ProductionDependencies;

  CredentialStore get credentials;
  SessionStore get sessions;
  SignInRepository get repository;
  SignInGateway get gateway;
  DailyPlanService get planService;
  SignInExecutor get executor;
  BackgroundScheduler get scheduler;
  NotificationService get notifications;
  NativeBackgroundResultPort get nativeBackgroundResults;
  DateTime now();
  Future<void> initialize();
  Future<void> dispose();
}

class _ProductionDependencies implements AppDependencies {
  _ProductionDependencies();
  AppDatabase? _database;
  @override
  final CredentialStore credentials = const SecureCredentialStore();
  @override
  late final SessionStore sessions;
  @override
  late final SignInRepository repository;
  @override
  late final SignInGateway gateway;
  @override
  late final DailyPlanService planService;
  @override
  late final SignInExecutor executor;
  @override
  final BackgroundScheduler scheduler = createProductionBackgroundScheduler();
  @override
  late final NotificationService notifications;
  @override
  final NativeBackgroundResultPort nativeBackgroundResults =
      NativeBackgroundResultChannel();
  @override
  DateTime now() => DateTime.now();
  @override
  Future<void> initialize() async {
    if (_database != null) return;
    final database = await AppDatabase.open(singleInstance: false);
    _database = database;
    repository = SqliteSignInRepository(database);
    sessions = GuardedSessionStore(
      delegate: const SecureSessionStore(),
      credentials: credentials,
      repository: repository,
    );
    gateway = MaoguaiSignInClient(sessionStore: sessions);
    planService = DailyPlanService(repository);
    executor = SignInCoordinator(
      gateway: gateway,
      credentialStore: credentials,
      sessionStore: sessions,
      repository: repository,
      planService: planService,
      clock: now,
    );
    notifications = SignInNotifications(
      enabled: () async =>
          (await repository.loadSettings()).notificationsEnabled,
    );
    try {
      final scheduler = this.scheduler;
      if (scheduler case final InitializableBackgroundScheduler initializable) {
        await initializable.initialize();
      }
    } catch (_) {
      // Foreground login and manual execution also work without background support.
    }
  }

  @override
  Future<void> dispose() async {
    await _database?.close();
  }
}

String greetingFor(DateTime value) {
  final local = value.toLocal();
  final minute = local.hour * 60 + local.minute;
  if (minute < 300) return '夜深了';
  if (minute < 690) return '早上好';
  if (minute < 840) return '中午好';
  if (minute < 1080) return '下午好';
  return '晚上好';
}

const _notProvided = Object();

@immutable
class SignInAppViewState {
  SignInAppViewState({
    required this.now,
    this.isInitializing = true,
    this.isLoggedIn = false,
    this.isLoggingIn = false,
    this.isRunning = false,
    this.maskedUsername = '',
    ScheduleSettings? settings,
    this.plan,
    this.nextPlan,
    this.planStatus = DailyPlanStatus.planned,
    List<SignInRecord> records = const [],
    this.error,
  }) : settings =
           settings ??
           ScheduleSettings(
             enabled: true,
             notificationsEnabled: false,
             startMinute: 480,
             endMinute: 600,
           ),
       records = List.unmodifiable(records);

  final DateTime now;
  final bool isInitializing;
  final bool isLoggedIn;
  final bool isLoggingIn;
  final bool isRunning;
  final String maskedUsername;
  final ScheduleSettings settings;
  final DailyPlan? plan;
  final DailyPlan? nextPlan;
  final DailyPlanStatus planStatus;
  final List<SignInRecord> records;
  final SignInError? error;
  String get greeting => greetingFor(now);
  String? get errorMessage => error?.userMessage;

  SignInAppViewState copyWith({
    DateTime? now,
    bool? isInitializing,
    bool? isLoggedIn,
    bool? isLoggingIn,
    bool? isRunning,
    String? maskedUsername,
    ScheduleSettings? settings,
    Object? plan = _notProvided,
    Object? nextPlan = _notProvided,
    DailyPlanStatus? planStatus,
    List<SignInRecord>? records,
    Object? error = _notProvided,
  }) => SignInAppViewState(
    now: now ?? this.now,
    isInitializing: isInitializing ?? this.isInitializing,
    isLoggedIn: isLoggedIn ?? this.isLoggedIn,
    isLoggingIn: isLoggingIn ?? this.isLoggingIn,
    isRunning: isRunning ?? this.isRunning,
    maskedUsername: maskedUsername ?? this.maskedUsername,
    settings: settings ?? this.settings,
    plan: identical(plan, _notProvided) ? this.plan : plan as DailyPlan?,
    nextPlan: identical(nextPlan, _notProvided)
        ? this.nextPlan
        : nextPlan as DailyPlan?,
    planStatus: planStatus ?? this.planStatus,
    records: records ?? this.records,
    error: identical(error, _notProvided) ? this.error : error as SignInError?,
  );
}

class SignInAppController extends ChangeNotifier {
  SignInAppController(this.dependencies)
    : _state = SignInAppViewState(now: dependencies.now());
  final AppDependencies dependencies;
  SignInAppViewState _state;
  SignInAppViewState get state => _state;

  Future<void> _pending = Future.value();
  Future<void>? _initialization;
  Future<void>? _manualExecution;
  int? _accountGeneration;
  bool _disposed = false;

  Future<void> initialize() async {
    final initialization = _initialization ??= _serialize(() async {
      _emit(state.copyWith(isInitializing: true, error: null));
      try {
        await dependencies.initialize();
        var credentials = await dependencies.credentials.read();
        if (credentials != null && credentials.instanceId == null) {
          credentials = StoredCredentials.create(
            username: credentials.username,
            password: credentials.password,
          );
          await dependencies.credentials.save(credentials);
        }
        await dependencies.sessions.read();
        final generation = await dependencies.repository.activeGeneration();
        if (credentials == null || generation == null) {
          // Remove orphaned account data before a different account can login.
          await _clearAccountData(requireScheduleCancellation: false);
          _emit(
            SignInAppViewState(now: dependencies.now(), isInitializing: false),
          );
        } else {
          _accountGeneration = generation;
          await dependencies.nativeBackgroundResults
              .setActiveCredentialInstance(credentials.instanceId);
          _emit(
            state.copyWith(
              isLoggedIn: true,
              maskedUsername: maskUsername(credentials.username),
            ),
          );
          await _importNativeBackgroundResults(credentials);
          await _reloadAccount();
        }
      } catch (error) {
        _emit(
          SignInAppViewState(
            now: dependencies.now(),
            isInitializing: false,
            error: _safeError(error),
          ),
        );
        rethrow;
      }
    });
    try {
      await initialization;
    } catch (_) {
      if (identical(_initialization, initialization)) _initialization = null;
      rethrow;
    }
  }

  Future<void> login(String username, String password) => _ready(() async {
    if (state.isLoggedIn) {
      throw const SignInError(SignInErrorKind.businessRejected);
    }
    final credentials = StoredCredentials.create(
      username: username.trim(),
      password: password,
    );
    if (credentials.username.isEmpty || password.isEmpty) {
      throw const SignInError(SignInErrorKind.invalidCredentials);
    }
    _emit(state.copyWith(isLoggingIn: true, error: null));
    try {
      // A successful remote response is a candidate until secure credentials and
      // the fresh account lifetime have been installed.
      final candidate = await dependencies.gateway.authenticate(credentials);
      try {
        await dependencies.credentials.save(credentials);
        final generation = await dependencies.repository.activateAccount();
        await dependencies.sessions.save(
          candidate.forAccount(generation, credentials.instanceId),
        );
        _accountGeneration = generation;
        await dependencies.nativeBackgroundResults.setActiveCredentialInstance(
          credentials.instanceId,
        );
      } catch (_) {
        // A split secure-store write can leave a username or password behind.
        await _clearAccountData();
        throw const SignInError(SignInErrorKind.localStorage);
      }
      _emit(
        state.copyWith(
          isLoggedIn: true,
          maskedUsername: maskUsername(credentials.username),
        ),
      );
      await _reloadAccount();
    } finally {
      _emit(state.copyWith(isLoggingIn: false));
    }
  });

  Future<void> logout() => _ready(() async {
    try {
      // Serialized after an active foreground run, so it cannot repopulate
      // records or credentials after logout has finished.
      await _clearAccountData();
    } finally {
      // If durable invalidation failed, retain the logged-in UI with an error;
      // it must not claim logout while the previous lifetime remains active.
      if (_accountGeneration == null) {
        _emit(
          SignInAppViewState(now: dependencies.now(), isInitializing: false),
        );
      }
    }
  });

  Future<void> runManualSignIn() => _startExecution(confirmOnly: false);
  Future<void> confirmUnknown() => _startExecution(confirmOnly: true);

  Future<void> _startExecution({
    required bool confirmOnly,
  }) => _manualExecution ??= _ready(() async {
    _requireAccount();
    final generation = _accountGeneration!;
    _emit(
      state.copyWith(isRunning: true, now: dependencies.now(), error: null),
    );
    // Subscribe before run: the executor broadcasts all intermediate states.
    final subscription = dependencies.executor.statusChanges.listen((status) {
      _emit(state.copyWith(planStatus: status));
    });
    try {
      final result = confirmOnly
          ? await dependencies.executor.confirmUnknown(
              dependencies.now(),
              generation: generation,
            )
          : await dependencies.executor.run(
              source: TriggerSource.manual,
              now: dependencies.now(),
              generation: generation,
            );
      if (await dependencies.repository.activeGeneration() != generation) {
        throw const AccountDataCleared();
      }
      _emit(
        state.copyWith(
          planStatus: DailyPlanStatus.values.byName(result.status.name),
        ),
      );
      await _reloadAccount();
      if (state.settings.notificationsEnabled) {
        try {
          await dependencies.notifications.showResult(
            result,
            isEnabled: () async =>
                (await dependencies.repository
                        .forGeneration(generation)
                        .loadSettings())
                    .notificationsEnabled,
            deliverIfCurrent: result.record == null
                ? null
                : (action) => dependencies.repository.withGeneration(
                    result.record!.generation,
                    action,
                  ),
            isCurrent: () async =>
                result.record != null &&
                result.record!.generation ==
                    await dependencies.repository.activeGeneration(),
          );
        } catch (_) {
          // Optional notification failure does not change the stored result.
        }
      }
    } on AccountDataCleared {
      _accountGeneration = null;
      _emit(SignInAppViewState(now: dependencies.now(), isInitializing: false));
    } finally {
      await subscription.cancel();
      _emit(state.copyWith(isRunning: false));
    }
  }).whenComplete(() => _manualExecution = null);

  Future<void> updateSchedule(ScheduleSettings settings) => _ready(() async {
    _requireAccount();
    final current = await dependencies.repository
        .forGeneration(_accountGeneration!)
        .loadSettings();
    await dependencies.planService.updateSettings(
      settings.copyWith(notificationsEnabled: current.notificationsEnabled),
      dependencies.now(),
      generation: _accountGeneration!,
    );
    await _reloadAccount();
  });

  Future<void> setAutomationEnabled(bool enabled) => _ready(() async {
    _requireAccount();
    final generation = _accountGeneration!;
    final settings = await dependencies.repository
        .forGeneration(generation)
        .loadSettings();
    await dependencies.planService.updateSettings(
      settings.copyWith(enabled: enabled),
      dependencies.now(),
      generation: generation,
    );
    await _reloadAccount();
  });

  /// Call only from the visible settings toggle. Startup and background
  /// execution must never prompt for notification permission.
  Future<void> setNotificationsEnabled(bool enabled) => _ready(() async {
    _requireAccount();
    final repository = dependencies.repository.forGeneration(
      _accountGeneration!,
    );
    final permitted =
        enabled && await dependencies.notifications.requestPermission();
    final settings = await repository.loadSettings();
    await dependencies.nativeBackgroundResults.setNotificationsEnabled(
      permitted,
    );
    try {
      await repository.saveSettings(
        settings.copyWith(notificationsEnabled: permitted),
      );
    } catch (_) {
      await dependencies.nativeBackgroundResults.setNotificationsEnabled(false);
      rethrow;
    }
    _emit(
      state.copyWith(
        settings: settings.copyWith(notificationsEnabled: permitted),
        error: null,
      ),
    );
  });

  Future<void> openNotificationSettings() => _ready(() async {
    _requireAccount();
    await dependencies.notifications.openNotificationSettings();
  });

  Future<BackgroundScheduleStatus> backgroundScheduleStatus() async {
    late BackgroundScheduleStatus result;
    await _ready(() async {
      final scheduler = dependencies.scheduler;
      result = switch (scheduler) {
        final BackgroundSchedulerSettings configurable =>
          await configurable.status(),
        _ => BackgroundScheduleStatus.fallbackOnly,
      };
    });
    return result;
  }

  Future<bool> openBackgroundScheduleSettings() async {
    var opened = false;
    await _ready(() async {
      final scheduler = dependencies.scheduler;
      if (scheduler case final BackgroundSchedulerSettings configurable) {
        opened = await configurable.openSystemSettings();
      }
    });
    return opened;
  }

  /// Uses the native client's read-only signed-status endpoint. It never
  /// authenticates or submits a sign-in request.
  Future<NativeConnectionCheck> checkNativeConnection() async {
    late NativeConnectionCheck check;
    await _ready(() async {
      _requireAccount();
      check = await dependencies.nativeBackgroundResults.checkConnection();
    });
    return check;
  }

  void refreshGreeting() => _emit(state.copyWith(now: dependencies.now()));

  /// Reload durable background results and a new day's plan without networking.
  Future<void> refreshLocalState() => _ready(() async {
    refreshGreeting();
    if (state.isLoggedIn) {
      final credentials = await dependencies.credentials.read();
      if (credentials == null) throw const AccountDataCleared();
      await _importNativeBackgroundResults(credentials);
      await _reloadAccount();
    }
  });

  Future<void> _importNativeBackgroundResults(
    StoredCredentials credentials,
  ) async {
    final instanceId = credentials.instanceId;
    if (instanceId == null || instanceId.isEmpty) return;
    final results = await dependencies.nativeBackgroundResults.readPending();
    for (final result in results) {
      // Results from an old login must never enter the current account's log.
      // Acknowledging a stale result is safe because it cannot be useful after
      // its credential lifetime has been deliberately invalidated.
      if (result.credentialInstanceId != instanceId) {
        await dependencies.nativeBackgroundResults.acknowledge({
          result.resultId,
        });
        continue;
      }
      await dependencies.repository.importNativeResult(result);
      // Only ACK after the SQLite transaction committed. If this call fails,
      // the idempotency table makes the next import a harmless no-op.
      await dependencies.nativeBackgroundResults.acknowledge({result.resultId});
    }
  }

  Future<void> _reloadAccount() async {
    final now = dependencies.now();
    final generation = _accountGeneration;
    if (generation == null) throw const AccountDataCleared();
    final repository = dependencies.repository.forGeneration(generation);
    final settings = await repository.loadSettings();
    await dependencies.nativeBackgroundResults.setNotificationsEnabled(
      settings.notificationsEnabled,
    );
    final plan = await dependencies.planService.ensureTodayPlan(
      now,
      generation: generation,
    );
    // The visible record list is capped at five entries for today. History and
    // monthly statistics query SQLite on demand, so keeping a whole month here
    // needlessly retains records while the app is backgrounded.
    final records = await repository.latestRecordsForDay(_day(now));
    final terminal = switch (plan.status) {
      DailyPlanStatus.success ||
      DailyPlanStatus.done ||
      DailyPlanStatus.failed ||
      DailyPlanStatus.unknown => true,
      _ => false,
    };
    final nextPlan = terminal
        ? await dependencies.planService.nextPlanAfterCompletion(
            now,
            generation: generation,
          )
        : plan;
    if (await repository.activeGeneration() == null) {
      throw const AccountDataCleared();
    }
    _emit(
      state.copyWith(
        now: now,
        isInitializing: false,
        settings: settings,
        plan: plan,
        nextPlan: nextPlan,
        planStatus: plan.status,
        records: records,
        error: null,
      ),
    );
    // Scheduler availability is independent of login/session validity.
    try {
      if (settings.enabled) {
        if (await repository.activeGeneration() == null) {
          throw const AccountDataCleared();
        }
        await repository.withGeneration(
          generation,
          () => dependencies.scheduler.schedule(nextPlan),
        );
      } else {
        await repository.withGeneration(
          generation,
          dependencies.scheduler.cancel,
        );
      }
    } on AccountDataCleared {
      rethrow;
    } catch (_) {
      _emit(
        state.copyWith(error: const SignInError(SignInErrorKind.localStorage)),
      );
    }
  }

  Future<void> _clearAccountData({
    bool requireScheduleCancellation = true,
  }) async {
    Object? firstError;
    // Invalidate durably before any native cleanup can yield to late responses.
    await dependencies.repository.clearAccountData();
    _accountGeneration = null;
    for (final action in <Future<void> Function()>[
      () => dependencies.nativeBackgroundResults.setActiveCredentialInstance(
        null,
      ),
      dependencies.credentials.clear,
      () async {
        try {
          await dependencies.scheduler.cancel();
        } catch (_) {
          if (requireScheduleCancellation) rethrow;
        }
      },
      dependencies.sessions.clear,
    ]) {
      try {
        await action();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw const SignInError(SignInErrorKind.localStorage);
    }
  }

  Future<void> _ready(Future<void> Function() action) async {
    await initialize();
    return _serialize(action);
  }

  Future<void> _serialize(Future<void> Function() action) {
    if (_disposed) {
      return Future.error(StateError('Controller has been disposed'));
    }
    final result = _pending.then((_) async {
      try {
        await action();
      } on AccountDataCleared {
        _accountGeneration = null;
        _emit(
          SignInAppViewState(now: dependencies.now(), isInitializing: false),
        );
        throw const SignInError(SignInErrorKind.authExpired);
      } catch (error) {
        final safe = _safeError(error);
        _emit(state.copyWith(error: safe));
        throw safe;
      }
    });
    _pending = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _requireAccount() {
    if (!state.isLoggedIn || _accountGeneration == null) {
      throw const SignInError(SignInErrorKind.authExpired);
    }
  }

  void _emit(SignInAppViewState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  static SignInError _safeError(Object error) => error is SignInError
      ? SignInError(error.kind)
      : const SignInError(SignInErrorKind.localStorage);

  @override
  void dispose() {
    _disposed = true;
    // The database is foreground-owned. Let a claimed run finish before close.
    unawaited(
      _pending.then((_) => dependencies.dispose()).catchError((Object _) {}),
    );
    super.dispose();
  }

  static String _day(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

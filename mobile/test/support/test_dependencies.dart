import 'dart:async';

import 'package:maoguai_signin/app_state.dart';
import 'package:maoguai_signin/auth/auth_models.dart';
import 'package:maoguai_signin/auth/credential_store.dart';
import 'package:maoguai_signin/auth/session_store.dart';
import 'package:maoguai_signin/background/background_scheduler.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/notifications/sign_in_notifications.dart';
import 'package:maoguai_signin/shortcuts/native_background_results.dart';
import 'package:maoguai_signin/schedule/daily_plan_service.dart';
import 'package:maoguai_signin/signin/sign_in_coordinator.dart';
import 'package:maoguai_signin/signin/sign_in_gateway.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';

ScheduleSettings testSettings({
  bool enabled = true,
  bool notificationsEnabled = true,
  int startMinute = 480,
  int endMinute = 600,
}) => ScheduleSettings(
  enabled: enabled,
  notificationsEnabled: notificationsEnabled,
  startMinute: startMinute,
  endMinute: endMinute,
);

ProductionLikeDependencies productionLikeDependenciesWithLegacySecureValues() {
  final backend = _MemorySecureBackend({
    'signin_username': 'legacy-user',
    'signin_password': 'legacy-password',
    'signin_credential_instance': 'legacy-instance',
  });
  return ProductionLikeDependencies(backend);
}

class ProductionLikeDependencies implements AppDependencies {
  ProductionLikeDependencies(SecureBackend backend)
    : credentials = SecureCredentialStore(backend),
      sessions = SecureSessionStore(backend),
      repository = MemorySignInRepository(testSettings()),
      clock = TestClock(DateTime(2026, 9, 9, 7)) {
    gateway = TestGateway(sessions);
    planService = DailyPlanService(repository, chooseSecond: (min, max) => min);
    executor = SignInCoordinator(
      gateway: gateway,
      credentialStore: credentials,
      sessionStore: sessions,
      repository: repository,
      planService: planService,
      clock: now,
      sleep: (_) async {},
      chooseSecond: (min, max) => min,
    );
  }

  final TestClock clock;
  @override
  final SecureCredentialStore credentials;
  @override
  final SecureSessionStore sessions;
  @override
  final MemorySignInRepository repository;
  @override
  late final TestGateway gateway;
  @override
  late final DailyPlanService planService;
  @override
  late final SignInExecutor executor;
  @override
  final TestScheduler scheduler = TestScheduler();
  @override
  final TestNotifications notifications = TestNotifications();
  @override
  final TestNativeBackgroundResults nativeBackgroundResults =
      TestNativeBackgroundResults();
  @override
  DateTime now() => clock.now;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> dispose() async {}
}

class _MemorySecureBackend implements SecureBackend {
  _MemorySecureBackend(Map<String, String> initialValues)
    : _values = {...initialValues};

  final Map<String, String> _values;

  @override
  Future<void> delete({required String key}) async => _values.remove(key);

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }
}

class TestDependencies implements AppDependencies {
  TestDependencies({DateTime? now, ScheduleSettings? settings})
    : clock = TestClock(now ?? DateTime(2026, 9, 9, 7)),
      repository = MemorySignInRepository(settings ?? testSettings()) {
    gateway = TestGateway(sessions);
    planService = DailyPlanService(repository, chooseSecond: (min, max) => min);
    executor = SignInCoordinator(
      gateway: gateway,
      credentialStore: credentials,
      sessionStore: sessions,
      repository: repository,
      planService: planService,
      clock: this.now,
      sleep: (_) async {},
      chooseSecond: (min, max) => min,
    );
  }
  static Future<TestDependencies> authenticated({
    required DateTime now,
    required ScheduleSettings settings,
  }) async {
    final deps = TestDependencies(now: now, settings: settings);
    await deps.credentials.save(
      StoredCredentials.create(username: 'user1234', password: 'secret'),
    );
    await deps.sessions.save(TestGateway.session);
    return deps;
  }

  final TestClock clock;
  @override
  final MemoryCredentialStore credentials = MemoryCredentialStore();
  @override
  final MemorySessionStore sessions = MemorySessionStore();
  @override
  final MemorySignInRepository repository;
  @override
  late final TestGateway gateway;
  @override
  late final DailyPlanService planService;
  @override
  late SignInExecutor executor;
  @override
  final TestScheduler scheduler = TestScheduler();
  @override
  final TestNotifications notifications = TestNotifications();
  @override
  final TestNativeBackgroundResults nativeBackgroundResults =
      TestNativeBackgroundResults();
  int initializeCalls = 0;
  Object? initializeError;
  bool disposed = false;
  @override
  DateTime now() => clock.now;
  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initializeError != null) throw initializeError!;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class TestNativeBackgroundResults implements NativeBackgroundResultPort {
  final pending = <NativeBackgroundResult>[];
  final acknowledged = <Set<String>>[];
  bool notificationsEnabled = false;
  String? activeCredentialInstanceId;
  NativeConnectionCheck connection = const NativeConnectionCheck(
    title: '连接正常',
    detail: '已完成只读签到状态检查。',
  );

  @override
  Future<void> acknowledge(Set<String> resultIds) async {
    acknowledged.add({...resultIds});
    pending.removeWhere((result) => resultIds.contains(result.resultId));
  }

  @override
  Future<NativeConnectionCheck> checkConnection() async => connection;

  @override
  Future<List<NativeBackgroundResult>> readPending() async =>
      List.unmodifiable(pending);

  @override
  Future<void> setActiveCredentialInstance(String? instanceId) async {
    activeCredentialInstanceId = instanceId;
  }

  @override
  Future<void> setNotificationsEnabled(bool enabled) async {
    notificationsEnabled = enabled;
  }
}

class TestClock {
  TestClock(this.now);
  DateTime now;
}

class MemoryCredentialStore implements CredentialStore {
  StoredCredentials? saved;
  Object? saveError;
  bool cleared = false;
  @override
  Future<StoredCredentials?> read() async => saved;
  @override
  Future<StoredCredentials?> peek() async => saved;
  @override
  Future<void> save(StoredCredentials credentials) async {
    saved = credentials;
    if (saveError != null) throw saveError!;
  }

  @override
  Future<void> clear() async {
    cleared = true;
    saved = null;
  }
}

class MemorySessionStore implements SessionStore {
  SessionData? saved;
  bool cleared = false;
  Future<void> Function()? afterClear;
  @override
  Future<SessionData?> read() async => saved;
  @override
  Future<SessionData?> peek() async => saved;
  @override
  Future<void> save(SessionData session) async {
    saved = session;
  }

  @override
  Future<void> clear() async {
    cleared = true;
    saved = null;
    await afterClear?.call();
  }
}

class TestGateway implements SignInGateway {
  TestGateway(this.sessions);
  final SessionStore sessions;
  static const session = SessionData(
    token: 'test-token',
    uid: 'test-uid',
    cookies: {'sid': 'test-cookie'},
    userAgent: 'test-agent',
  );
  Completer<void>? authenticateCompleter;
  Completer<void>? submitCompleter;
  SignInError? authenticateError;
  SignInError? fetchError;
  int authenticateCalls = 0;
  int validateCalls = 0;
  int fetchCalls = 0;
  int submitCalls = 0;
  bool restoreSessionOnSubmit = false;
  @override
  Future<SessionData> authenticate(StoredCredentials credentials) async {
    authenticateCalls++;
    await authenticateCompleter?.future;
    if (authenticateError != null) throw authenticateError!;
    return session;
  }

  @override
  Future<RemoteSessionState> validateSession({int? generation}) async {
    validateCalls++;
    return await sessions.read() == null
        ? RemoteSessionState.expired
        : RemoteSessionState.valid;
  }

  @override
  Future<RemoteSignInState> fetchStatus({int? generation}) async {
    fetchCalls++;
    if (fetchError != null) throw fetchError!;
    return submitCalls == 0
        ? RemoteSignInState.pending
        : RemoteSignInState.done;
  }

  @override
  Future<void> submitSignIn({int? generation}) async {
    final expected = await sessions.read();
    submitCalls++;
    await submitCompleter?.future;
    if (restoreSessionOnSubmit && expected != null) {
      await sessions.saveIfCurrent(expected, expected);
    }
  }
}

class TestScheduler implements BackgroundScheduler {
  final scheduledPlans = <DailyPlan>[];
  bool cancelled = false;
  Object? scheduleError;
  Object? cancelError;
  @override
  Future<void> schedule(DailyPlan plan) async {
    if (scheduleError != null) throw scheduleError!;
    cancelled = false;
    scheduledPlans.add(plan);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (cancelError != null) throw cancelError!;
  }
}

class TestNotifications implements NotificationService {
  int permissionRequests = 0;
  int settingsRequests = 0;
  bool permissionGranted = true;
  final results = <SignInResult>[];
  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<bool> openNotificationSettings() async {
    settingsRequests++;
    return true;
  }

  @override
  Future<void> showLateCatchUp(
    DailyPlan plan,
    DateTime actualAt, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) async {}
  @override
  Future<void> showResult(
    SignInResult result, {
    Future<bool> Function()? isCurrent,
    Future<bool> Function()? isEnabled,
    Future<void> Function(Future<void> Function())? deliverIfCurrent,
  }) async {
    if (isCurrent != null && !await isCurrent()) return;
    results.add(result);
  }
}

/// In-memory I/O boundary; controller tests keep the real planner/coordinator.
class MemorySignInRepository implements SignInRepository {
  MemorySignInRepository(ScheduleSettings settings)
    : _settings = settings,
      _root = null,
      _scope = null;
  MemorySignInRepository._scoped(this._root, this._scope)
    : _settings = testSettings();
  final MemorySignInRepository? _root;
  final int? _scope;
  MemorySignInRepository get _owner => _root ?? this;
  ScheduleSettings _settings;
  final _plans = <String, DailyPlan>{};
  final _records = <SignInRecord>[];
  final _nativeResultIds = <String>{};
  int _counter = 1;
  int? _active = 1;
  bool _cleared = false;
  Object? clearError;
  ScheduleSettings get settings => _owner._settings;
  set settings(ScheduleSettings value) => _owner._settings = value;
  Map<String, DailyPlan> get plans => _owner._plans;
  List<SignInRecord> get records => _owner._records;
  bool get accountDataCleared => _owner._cleared;
  void _check([int? generation]) {
    final active = _owner._active;
    if (active == null ||
        (_scope != null && _scope != active) ||
        (generation != null && generation != active)) {
      throw const AccountDataCleared();
    }
  }

  @override
  Future<int?> activeGeneration() async =>
      _scope == null || _scope == _owner._active ? _owner._active : null;
  @override
  SignInRepository forGeneration(int generation) =>
      MemorySignInRepository._scoped(_owner, generation);
  @override
  Future<T> withGeneration<T>(
    int generation,
    Future<T> Function() action,
  ) async {
    _check(generation);
    final result = await action();
    _check(generation);
    return result;
  }

  @override
  Future<int> activateAccount() async {
    _owner._active = ++_owner._counter;
    plans.clear();
    records.clear();
    return _owner._active!;
  }

  @override
  Future<ScheduleSettings> loadSettings() async {
    _check();
    return settings;
  }

  @override
  Future<void> saveSettings(ScheduleSettings value) async {
    _check();
    settings = value;
  }

  @override
  Future<DailyPlan?> planForDay(String day) async {
    _check();
    return plans[day];
  }

  @override
  Future<void> upsertPlan(DailyPlan plan) async {
    _check(plan.generation);
    plans[plan.day] = plan;
  }

  @override
  Future<DailyPlan> resolveDailyPlan(DailyPlan candidate) async {
    _check(candidate.generation);
    final existing = plans[candidate.day];
    if (existing != null &&
        (existing.attemptedAt != null ||
            existing.status == DailyPlanStatus.success ||
            existing.status == DailyPlanStatus.done ||
            (existing.startMinute == candidate.startMinute &&
                existing.endMinute == candidate.endMinute))) {
      return existing;
    }
    plans[candidate.day] = candidate;
    return candidate;
  }

  @override
  Future<({DailyPlan plan, bool claimed})> claimAttempt({
    required String day,
    required DateTime attemptedAt,
    required bool lateExecution,
    DailyPlan? expectedAutomaticPlan,
  }) async {
    _check();
    final plan = plans[day]!;
    if (plan.attemptedAt != null ||
        plan.status == DailyPlanStatus.success ||
        plan.status == DailyPlanStatus.done) {
      return (plan: plan, claimed: false);
    }
    final claimed = plan.copyWith(
      status: DailyPlanStatus.submitting,
      attemptedAt: attemptedAt,
      actualAt: attemptedAt,
      lateExecution: lateExecution,
    );
    plans[day] = claimed;
    return (plan: claimed, claimed: true);
  }

  @override
  Future<SignInRecord> insertRecord(SignInRecord record) async {
    _check(record.generation);
    final saved = record.copyWith(id: records.length + 1);
    records.add(saved);
    return saved;
  }

  @override
  Future<void> importNativeResult(NativeBackgroundResult result) async {
    _check();
    if (!_owner._nativeResultIds.add(result.resultId)) return;
    await insertRecord(
      result.record.copyWith(id: null, generation: _owner._active!),
    );
  }

  @override
  Future<({DailyPlan? plan, SignInRecord record})> finalizeExecution({
    required DailyPlan? plan,
    required SignInRecord record,
  }) async {
    _check(record.generation);
    if (plan != null && !plans.containsKey(plan.day)) {
      throw const AccountDataCleared();
    }
    if (plan != null) {
      _check(plan.generation);
      plans[plan.day] = plan;
    }
    return (plan: plan, record: await insertRecord(record));
  }

  @override
  Future<List<SignInRecord>> recordsForDay(String day) async {
    _check();
    return records.where((record) => record.day == day).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  }

  @override
  Future<List<SignInRecord>> recordsForMonth(String month) async {
    _check();
    return records.where((record) => record.day.startsWith('$month-')).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  }

  @override
  Future<List<SignInRecord>> latestRecordsForDay(
    String day, {
    int limit = 5,
  }) async => (await recordsForDay(day)).take(limit > 5 ? 5 : limit).toList();
  @override
  Future<void> clearAccountData() async {
    if (_owner.clearError != null) throw _owner.clearError!;
    if (_scope != null) _check();
    _owner._cleared = true;
    _owner._active = null;
    _owner._counter++;
    plans.clear();
    records.clear();
    _owner._nativeResultIds.clear();
    settings = testSettings();
  }
}

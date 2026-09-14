import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import '../shortcuts/native_background_results.dart';

/// An execution's account lifetime was invalidated. Callers must discard it
/// without reloading another account, notifications or rescheduling.
class AccountDataCleared implements Exception {
  const AccountDataCleared();
}

class AutomaticPlanObsolete implements Exception {
  const AutomaticPlanObsolete();
}

abstract interface class SignInRepository {
  Future<int?> activeGeneration();
  Future<int> activateAccount();
  SignInRepository forGeneration(int generation);

  /// Serializes a native-only effect with logout. The callback must not call
  /// this repository or start a nested SQLite transaction.
  Future<T> withGeneration<T>(int generation, Future<T> Function() action);
  Future<ScheduleSettings> loadSettings();
  Future<void> saveSettings(ScheduleSettings settings);
  Future<DailyPlan?> planForDay(String day);
  Future<void> upsertPlan(DailyPlan plan);
  Future<DailyPlan> resolveDailyPlan(DailyPlan candidate);
  Future<({DailyPlan plan, bool claimed})> claimAttempt({
    required String day,
    required DateTime attemptedAt,
    required bool lateExecution,
    DailyPlan? expectedAutomaticPlan,
  });
  Future<SignInRecord> insertRecord(SignInRecord record);
  Future<void> importNativeResult(NativeBackgroundResult result);
  Future<({DailyPlan? plan, SignInRecord record})> finalizeExecution({
    required DailyPlan? plan,
    required SignInRecord record,
  });
  Future<List<SignInRecord>> recordsForDay(String day);
  Future<List<SignInRecord>> recordsForMonth(String month);
  Future<List<SignInRecord>> latestRecordsForDay(String day, {int limit = 5});
  Future<void> clearAccountData();
}

class SqliteSignInRepository implements SignInRepository {
  SqliteSignInRepository(this._appDatabase, {this._generation});
  final int? _generation;
  @override
  SignInRepository forGeneration(int generation) =>
      SqliteSignInRepository(_appDatabase, generation: generation);
  @override
  Future<int?> activeGeneration() async {
    final rows = await _appDatabase.database.query(
      'account_state',
      where: 'id = 1 AND active = 1',
    );
    if (rows.isEmpty) return null;
    final generation = rows.single['generation']! as int;
    return _generation == null || _generation == generation ? generation : null;
  }

  Future<int> _assertActive(DatabaseExecutor database) async {
    final rows = await database.query(
      'account_state',
      where: 'id = 1 AND active = 1',
    );
    if (rows.isEmpty) throw const AccountDataCleared();
    final generation = rows.single['generation']! as int;
    if (_generation != null && generation != _generation) {
      throw const AccountDataCleared();
    }
    return generation;
  }

  /// Only BEGIN contention can be retried. Once the callback has entered it may
  /// have published a native side effect, so neither callback nor COMMIT replays.
  Future<T> _beginTransaction<T>(Future<T> Function(Transaction) action) async {
    final waiting = Stopwatch()..start();
    while (true) {
      var entered = false;
      try {
        return await _appDatabase.database.transaction((transaction) {
          entered = true;
          return action(transaction);
        });
      } on DatabaseException catch (error) {
        final code = (error.getResultCode() ?? 0) & 0xff;
        if (entered ||
            (code != 5 && code != 6) ||
            waiting.elapsed >= const Duration(seconds: 15)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  Future<T> _transaction<T>(Future<T> Function(Transaction) action) =>
      _beginTransaction((transaction) async {
        await _assertActive(transaction);
        return action(transaction);
      });
  @override
  Future<T> withGeneration<T>(int generation, Future<T> Function() action) =>
      SqliteSignInRepository(
        _appDatabase,
        generation: generation,
      )._transaction((_) => action());
  @override
  Future<int> activateAccount() => _beginTransaction((transaction) async {
    await transaction.rawUpdate(
      'UPDATE account_state SET generation = generation + 1, active = 1 WHERE id = 1',
    );
    await transaction.delete('schedule_settings');
    await transaction.delete('daily_plans');
    await transaction.delete('sign_in_records');
    await transaction.delete('native_result_imports');
    return (await transaction.query('account_state')).single['generation']!
        as int;
  });

  final AppDatabase _appDatabase;

  @override
  Future<({DailyPlan plan, bool claimed})> claimAttempt({
    required String day,
    required DateTime attemptedAt,
    required bool lateExecution,
    DailyPlan? expectedAutomaticPlan,
  }) => _transaction((transaction) async {
    final existing = await _planForDay(transaction, day);
    if (expectedAutomaticPlan != null) {
      final settings = await transaction.query(
        'schedule_settings',
        where: 'id = 1',
      );
      final enabled = settings.isEmpty
          ? _defaultSettings().enabled
          : settings.single['enabled'] == 1;
      final expected = expectedAutomaticPlan;
      if (!enabled ||
          existing == null ||
          existing.generation != expected.generation ||
          existing.day != expected.day ||
          existing.startMinute != expected.startMinute ||
          existing.endMinute != expected.endMinute ||
          existing.plannedAt != expected.plannedAt ||
          attemptedAt.isBefore(existing.plannedAt)) {
        throw const AutomaticPlanObsolete();
      }
    }
    if (existing == null) throw StateError('Daily plan is missing');
    if (_mustPreserve(existing)) return (plan: existing, claimed: false);
    final claimed = existing.copyWith(
      status: DailyPlanStatus.submitting,
      attemptedAt: attemptedAt,
      actualAt: attemptedAt,
      lateExecution: lateExecution,
    );
    await _writePlan(transaction, claimed);
    return (plan: claimed, claimed: true);
  });

  @override
  Future<ScheduleSettings> loadSettings() async {
    return _transaction((transaction) async {
      final rows = await transaction.rawQuery(
        'SELECT enabled, notifications_enabled, start_minute, end_minute '
        'FROM schedule_settings WHERE id = ?',
        [1],
      );
      if (rows.isNotEmpty) {
        return _settingsFromRow(rows.single);
      }

      final settings = _defaultSettings();
      await transaction.rawInsert(
        'INSERT INTO schedule_settings '
        '(id, enabled, notifications_enabled, start_minute, end_minute) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          1,
          settings.enabled ? 1 : 0,
          settings.notificationsEnabled ? 1 : 0,
          settings.startMinute,
          settings.endMinute,
        ],
      );
      return settings;
    });
  }

  @override
  Future<void> saveSettings(ScheduleSettings settings) async {
    await _transaction(
      (transaction) => transaction.rawInsert(
        'INSERT INTO schedule_settings '
        '(id, enabled, notifications_enabled, start_minute, end_minute) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET '
        'enabled = excluded.enabled, '
        'notifications_enabled = excluded.notifications_enabled, '
        'start_minute = excluded.start_minute, '
        'end_minute = excluded.end_minute',
        [
          1,
          settings.enabled ? 1 : 0,
          settings.notificationsEnabled ? 1 : 0,
          settings.startMinute,
          settings.endMinute,
        ],
      ),
    );
  }

  @override
  Future<DailyPlan?> planForDay(String day) =>
      _transaction((transaction) => _planForDay(transaction, day));

  @override
  Future<void> upsertPlan(DailyPlan plan) => _transaction((transaction) async {
    if (plan.generation != await _assertActive(transaction)) {
      throw const AccountDataCleared();
    }
    final existing = await _planForDay(transaction, plan.day);
    final accepted = _acceptPlan(existing, plan);
    if (accepted != existing) {
      await _writePlan(transaction, accepted);
    }
  });

  @override
  Future<({DailyPlan? plan, SignInRecord record})> finalizeExecution({
    required DailyPlan? plan,
    required SignInRecord record,
  }) => _transaction((transaction) async {
    if (plan != null &&
        (plan.day != record.day || plan.status.name != record.status.name)) {
      throw ArgumentError(
        'Terminal plan and record must describe the same result',
      );
    }
    final generation = await _assertActive(transaction);
    if (record.generation != generation ||
        (plan != null && plan.generation != generation)) {
      throw const AccountDataCleared();
    }
    final existing = await _planForDay(transaction, record.day);
    if (plan != null && existing == null) {
      // This transaction is also the logout fence. A stale terminal snapshot
      // must never recreate a day removed by clearAccountData.
      throw const AccountDataCleared();
    }
    var accepted = plan == null ? existing : _acceptPlan(existing, plan);
    var acceptedRecord = record.copyWith(id: null);
    if (accepted != null && accepted != existing) {
      try {
        await _writePlan(transaction, accepted);
      } catch (_) {
        // A failed SQLite statement does not discard the durable claim. Keep
        // recording the known remote result in this transaction if possible.
        accepted = await _planForDay(transaction, record.day);
        const error = SignInError(SignInErrorKind.localStorage);
        acceptedRecord = acceptedRecord.copyWith(
          errorKind: error.kind,
          detail: '${acceptedRecord.detail}${error.userMessage}',
        );
      }
    }
    if (accepted != null) {
      acceptedRecord = acceptedRecord.copyWith(plannedAt: accepted.plannedAt);
      if (_completed(accepted) &&
          (acceptedRecord.status == SignInRecordStatus.failed ||
              acceptedRecord.status == SignInRecordStatus.unknown)) {
        // Another execution completed while this caller held a stale remote
        // read. Never publish that stale failure as the newest local record.
        acceptedRecord = acceptedRecord.copyWith(
          status: SignInRecordStatus.done,
          title: '今日已签到',
          detail: '今日签到状态已确认。',
          errorKind: null,
        );
      }
    }
    final inserted = await _insertRecord(transaction, acceptedRecord);
    return (plan: accepted, record: inserted);
  });

  static DailyPlan _acceptPlan(DailyPlan? existing, DailyPlan proposed) {
    if (existing == null) return proposed;
    if (_completed(existing)) return existing;
    if (existing.attemptedAt != null) {
      // Matching claim identity permits forward state changes, not replaying
      // an old submitting/confirming snapshot over a later terminal result.
      if (proposed.attemptedAt != existing.attemptedAt ||
          _attemptPhase(proposed.status) == 0 ||
          _attemptPhase(proposed.status) < _attemptPhase(existing.status)) {
        return existing;
      }
      return existing.copyWith(status: proposed.status);
    }
    return proposed;
  }

  static bool _completed(DailyPlan plan) =>
      plan.status == DailyPlanStatus.success ||
      plan.status == DailyPlanStatus.done;

  @override
  Future<DailyPlan> resolveDailyPlan(DailyPlan candidate) {
    return _transaction((transaction) async {
      if (candidate.generation != await _assertActive(transaction)) {
        throw const AccountDataCleared();
      }
      final existing = await _planForDay(transaction, candidate.day);
      if (existing == null) {
        await _writePlan(transaction, candidate);
        return candidate;
      }

      if (_mustPreserve(existing) ||
          _isReusableForCandidate(existing, candidate)) {
        return existing;
      }

      await _writePlan(transaction, candidate);
      return candidate;
    });
  }

  Future<DailyPlan?> _planForDay(DatabaseExecutor database, String day) async {
    final rows = await database.rawQuery(
      'SELECT day, start_minute, end_minute, planned_at, status, attempted_at, '
      'actual_at, range_regenerated, late_execution, generation '
      'FROM daily_plans WHERE day = ? AND generation = '
      '(SELECT generation FROM account_state WHERE id = 1 AND active = 1)',
      [day],
    );
    return rows.isEmpty ? null : _planFromRow(rows.single);
  }

  Future<void> _writePlan(DatabaseExecutor database, DailyPlan plan) async {
    if (plan.generation != await _assertActive(database)) {
      throw const AccountDataCleared();
    }
    await database.rawInsert(
      'INSERT INTO daily_plans '
      '(day, start_minute, end_minute, planned_at, status, attempted_at, '
      'actual_at, range_regenerated, late_execution, generation) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(day) DO UPDATE SET '
      'start_minute = excluded.start_minute, '
      'end_minute = excluded.end_minute, '
      'planned_at = excluded.planned_at, '
      'status = excluded.status, '
      'attempted_at = excluded.attempted_at, '
      'actual_at = excluded.actual_at, '
      'range_regenerated = excluded.range_regenerated, '
      'late_execution = excluded.late_execution, '
      'generation = excluded.generation',
      [
        plan.day,
        plan.startMinute,
        plan.endMinute,
        plan.plannedAt.toIso8601String(),
        plan.status.name,
        plan.attemptedAt?.toIso8601String(),
        plan.actualAt?.toIso8601String(),
        plan.rangeRegenerated ? 1 : 0,
        plan.lateExecution ? 1 : 0,
        plan.generation,
      ],
    );
  }

  @override
  Future<SignInRecord> insertRecord(SignInRecord record) =>
      _transaction((transaction) => _insertRecord(transaction, record));

  @override
  Future<void> importNativeResult(NativeBackgroundResult result) =>
      _transaction((transaction) async {
        final generation = await _assertActive(transaction);
        final inserted = await transaction.rawInsert(
          'INSERT OR IGNORE INTO native_result_imports '
          '(result_id, credential_instance_id) VALUES (?, ?)',
          [result.resultId, result.credentialInstanceId],
        );
        if (inserted == 0) return;
        await _insertRecord(
          transaction,
          result.record.copyWith(id: null, generation: generation),
        );
      });

  Future<SignInRecord> _insertRecord(
    DatabaseExecutor database,
    SignInRecord record,
  ) async {
    if (record.generation != await _assertActive(database)) {
      throw const AccountDataCleared();
    }
    final id = await database.rawInsert(
      'INSERT INTO sign_in_records '
      '(day, planned_at, occurred_at, source, status, title, detail, error_kind, generation) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        record.day,
        record.plannedAt?.toIso8601String(),
        record.occurredAt.toIso8601String(),
        record.source.name,
        record.status.name,
        record.title,
        record.detail,
        record.errorKind?.name,
        record.generation,
      ],
    );
    return record.copyWith(id: id);
  }

  @override
  Future<List<SignInRecord>> recordsForDay(String day) =>
      _records('WHERE day = ?', [day]);

  @override
  Future<List<SignInRecord>> recordsForMonth(String month) =>
      _records('WHERE substr(day, 1, 7) = ?', [month]);

  @override
  Future<List<SignInRecord>> latestRecordsForDay(String day, {int limit = 5}) {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'Must be at least 1');
    }
    return _records('WHERE day = ?', [day], limit: limit > 5 ? 5 : limit);
  }

  @override
  Future<void> clearAccountData() async {
    await _beginTransaction((transaction) async {
      if (_generation != null) await _assertActive(transaction);
      await transaction.rawUpdate(
        'UPDATE account_state SET generation = generation + 1, active = 0 WHERE id = 1',
      );
      await transaction.delete('schedule_settings');
      await transaction.delete('daily_plans');
      await transaction.delete('sign_in_records');
      await transaction.delete('native_result_imports');
    });
  }

  Future<List<SignInRecord>> _records(
    String clause,
    List<Object?> arguments, {
    int? limit,
  }) async {
    final queryArguments = [...arguments, ?limit];
    final rows = await _transaction(
      (transaction) => transaction.rawQuery(
        'SELECT id, day, planned_at, occurred_at, source, status, title, detail, '
        'error_kind, generation FROM sign_in_records $clause AND generation = (SELECT generation FROM account_state WHERE id = 1 AND active = 1) '
        'ORDER BY occurred_at DESC, id DESC '
        '${limit == null ? '' : 'LIMIT ?'}',
        queryArguments,
      ),
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  ScheduleSettings _defaultSettings() => ScheduleSettings(
    enabled: true,
    notificationsEnabled: false,
    startMinute: 480,
    endMinute: 600,
  );

  ScheduleSettings _settingsFromRow(Map<String, Object?> row) =>
      ScheduleSettings(
        enabled: row['enabled'] == 1,
        notificationsEnabled: row['notifications_enabled'] == 1,
        startMinute: row['start_minute']! as int,
        endMinute: row['end_minute']! as int,
      );

  DailyPlan _planFromRow(Map<String, Object?> row) => DailyPlan.fromMap({
    'day': row['day'],
    'generation': row['generation'],
    'startMinute': row['start_minute'],
    'endMinute': row['end_minute'],
    'plannedAt': row['planned_at'],
    'status': row['status'],
    'attemptedAt': row['attempted_at'],
    'actualAt': row['actual_at'],
    'rangeRegenerated': row['range_regenerated'],
    'lateExecution': row['late_execution'],
  });

  static bool _mustPreserve(DailyPlan plan) =>
      plan.attemptedAt != null ||
      plan.status == DailyPlanStatus.success ||
      plan.status == DailyPlanStatus.done;

  static int _attemptPhase(DailyPlanStatus status) => switch (status) {
    DailyPlanStatus.planned ||
    DailyPlanStatus.checking ||
    DailyPlanStatus.jittering => 0,
    DailyPlanStatus.submitting => 1,
    DailyPlanStatus.confirming => 2,
    DailyPlanStatus.failed || DailyPlanStatus.unknown => 3,
    DailyPlanStatus.success || DailyPlanStatus.done => 4,
  };

  static bool _isReusableForCandidate(DailyPlan existing, DailyPlan candidate) {
    if (existing.day != candidate.day ||
        existing.startMinute != candidate.startMinute ||
        existing.endMinute != candidate.endMinute) {
      return false;
    }

    final expectedDay = DateTime.tryParse(candidate.day);
    if (expectedDay == null || _dayString(expectedDay) != candidate.day) {
      return false;
    }

    final plannedAt = existing.plannedAt.toLocal();
    if (_dayString(plannedAt) != candidate.day) {
      return false;
    }

    final dayStart = DateTime(
      expectedDay.year,
      expectedDay.month,
      expectedDay.day,
    );
    final windowStart = dayStart.add(Duration(minutes: candidate.startMinute));
    final windowEnd = dayStart.add(Duration(minutes: candidate.endMinute));
    return !plannedAt.isBefore(windowStart) && !plannedAt.isAfter(windowEnd);
  }

  static String _dayString(DateTime dateTime) =>
      '${dateTime.year.toString().padLeft(4, '0')}-'
      '${dateTime.month.toString().padLeft(2, '0')}-'
      '${dateTime.day.toString().padLeft(2, '0')}';

  SignInRecord _recordFromRow(Map<String, Object?> row) =>
      SignInRecord.fromMap({
        'id': row['id'],
        'generation': row['generation'],
        'day': row['day'],
        'plannedAt': row['planned_at'],
        'occurredAt': row['occurred_at'],
        'source': row['source'],
        'status': row['status'],
        'title': row['title'],
        'detail': row['detail'],
        'errorKind': row['error_kind'],
      });
}

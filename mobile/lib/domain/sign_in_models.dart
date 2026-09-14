import 'sign_in_errors.dart';

const Object _notProvided = Object();

enum DailyPlanStatus {
  planned,
  checking,
  jittering,
  submitting,
  confirming,
  success,
  done,
  failed,
  unknown,
}

enum SignInRecordStatus { success, done, failed, unknown }

enum TriggerSource {
  manual,
  shortcut,
  shortcutBackground,
  scheduled,
  lateCatchUp,
  statusSync,
}

class ScheduleSettings {
  ScheduleSettings({
    required this.enabled,
    required this.notificationsEnabled,
    required this.startMinute,
    required this.endMinute,
  }) {
    if (startMinute < 0 || startMinute > 1439) {
      throw ArgumentError.value(
        startMinute,
        'startMinute',
        'Must be 0 to 1439',
      );
    }
    if (endMinute < 0 || endMinute > 1439) {
      throw ArgumentError.value(endMinute, 'endMinute', 'Must be 0 to 1439');
    }
    if (startMinute >= endMinute) {
      throw ArgumentError('startMinute must be before endMinute');
    }
  }

  final bool enabled;
  final bool notificationsEnabled;
  final int startMinute;
  final int endMinute;

  Map<String, Object?> toMap() => {
    'enabled': enabled,
    'notificationsEnabled': notificationsEnabled,
    'startMinute': startMinute,
    'endMinute': endMinute,
  };

  factory ScheduleSettings.fromMap(Map<String, Object?> map) =>
      ScheduleSettings(
        enabled: map['enabled']! as bool,
        notificationsEnabled: map['notificationsEnabled']! as bool,
        startMinute: map['startMinute']! as int,
        endMinute: map['endMinute']! as int,
      );

  ScheduleSettings copyWith({
    bool? enabled,
    bool? notificationsEnabled,
    int? startMinute,
    int? endMinute,
  }) => ScheduleSettings(
    enabled: enabled ?? this.enabled,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
  );

  @override
  bool operator ==(Object other) =>
      other is ScheduleSettings &&
      other.enabled == enabled &&
      other.notificationsEnabled == notificationsEnabled &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute;

  @override
  int get hashCode =>
      Object.hash(enabled, notificationsEnabled, startMinute, endMinute);
}

class DailyPlan {
  const DailyPlan({
    required this.day,
    this.generation = 1,
    required this.startMinute,
    required this.endMinute,
    required this.plannedAt,
    required this.status,
    this.attemptedAt,
    this.actualAt,
    this.rangeRegenerated = false,
    this.lateExecution = false,
  });

  final String day;
  final int generation;
  final int startMinute;
  final int endMinute;
  final DateTime plannedAt;
  final DailyPlanStatus status;
  final DateTime? attemptedAt;
  final DateTime? actualAt;
  final bool rangeRegenerated;
  final bool lateExecution;

  Map<String, Object?> toMap() => {
    'day': day,
    'generation': generation,
    'startMinute': startMinute,
    'endMinute': endMinute,
    'plannedAt': plannedAt.toIso8601String(),
    'status': status.name,
    'attemptedAt': attemptedAt?.toIso8601String(),
    'actualAt': actualAt?.toIso8601String(),
    'rangeRegenerated': rangeRegenerated ? 1 : 0,
    'lateExecution': lateExecution ? 1 : 0,
  };

  factory DailyPlan.fromMap(Map<String, Object?> map) => DailyPlan(
    day: map['day']! as String,
    generation: map['generation'] as int? ?? 1,
    startMinute: map['startMinute']! as int,
    endMinute: map['endMinute']! as int,
    plannedAt: DateTime.parse(map['plannedAt']! as String),
    status: DailyPlanStatus.values.byName(map['status']! as String),
    attemptedAt: _nullableDateTime(map['attemptedAt']),
    actualAt: _nullableDateTime(map['actualAt']),
    rangeRegenerated: _sqliteBool(map['rangeRegenerated'], 'rangeRegenerated'),
    lateExecution: _sqliteBool(map['lateExecution'], 'lateExecution'),
  );

  DailyPlan copyWith({
    String? day,
    int? generation,
    int? startMinute,
    int? endMinute,
    DateTime? plannedAt,
    DailyPlanStatus? status,
    Object? attemptedAt = _notProvided,
    Object? actualAt = _notProvided,
    bool? rangeRegenerated,
    bool? lateExecution,
  }) => DailyPlan(
    day: day ?? this.day,
    generation: generation ?? this.generation,
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
    plannedAt: plannedAt ?? this.plannedAt,
    status: status ?? this.status,
    attemptedAt: identical(attemptedAt, _notProvided)
        ? this.attemptedAt
        : attemptedAt as DateTime?,
    actualAt: identical(actualAt, _notProvided)
        ? this.actualAt
        : actualAt as DateTime?,
    rangeRegenerated: rangeRegenerated ?? this.rangeRegenerated,
    lateExecution: lateExecution ?? this.lateExecution,
  );

  @override
  bool operator ==(Object other) =>
      other is DailyPlan &&
      other.day == day &&
      other.generation == generation &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute &&
      other.plannedAt == plannedAt &&
      other.status == status &&
      other.attemptedAt == attemptedAt &&
      other.actualAt == actualAt &&
      other.rangeRegenerated == rangeRegenerated &&
      other.lateExecution == lateExecution;

  @override
  int get hashCode => Object.hash(
    day,
    generation,
    startMinute,
    endMinute,
    plannedAt,
    status,
    attemptedAt,
    actualAt,
    rangeRegenerated,
    lateExecution,
  );
}

class SignInRecord {
  const SignInRecord({
    this.id,
    required this.day,
    this.generation = 1,
    this.plannedAt,
    required this.occurredAt,
    required this.source,
    required this.status,
    required this.title,
    required this.detail,
    this.errorKind,
  });

  final int? id;
  final String day;
  final int generation;
  final DateTime? plannedAt;
  final DateTime occurredAt;
  final TriggerSource source;
  final SignInRecordStatus status;
  final String title;
  final String detail;
  final SignInErrorKind? errorKind;

  Map<String, Object?> toMap() => {
    'id': id,
    'day': day,
    'generation': generation,
    'plannedAt': plannedAt?.toIso8601String(),
    'occurredAt': occurredAt.toIso8601String(),
    'source': source.name,
    'status': status.name,
    'title': title,
    'detail': detail,
    'errorKind': errorKind?.name,
  };

  factory SignInRecord.fromMap(Map<String, Object?> map) => SignInRecord(
    id: map['id'] as int?,
    day: map['day']! as String,
    generation: map['generation'] as int? ?? 1,
    plannedAt: _nullableDateTime(map['plannedAt']),
    occurredAt: DateTime.parse(map['occurredAt']! as String),
    source: TriggerSource.values.byName(map['source']! as String),
    status: SignInRecordStatus.values.byName(map['status']! as String),
    title: map['title']! as String,
    detail: map['detail']! as String,
    errorKind: _nullableErrorKind(map['errorKind']),
  );

  SignInRecord copyWith({
    Object? id = _notProvided,
    String? day,
    int? generation,
    Object? plannedAt = _notProvided,
    DateTime? occurredAt,
    TriggerSource? source,
    SignInRecordStatus? status,
    String? title,
    String? detail,
    Object? errorKind = _notProvided,
  }) => SignInRecord(
    id: identical(id, _notProvided) ? this.id : id as int?,
    day: day ?? this.day,
    generation: generation ?? this.generation,
    plannedAt: identical(plannedAt, _notProvided)
        ? this.plannedAt
        : plannedAt as DateTime?,
    occurredAt: occurredAt ?? this.occurredAt,
    source: source ?? this.source,
    status: status ?? this.status,
    title: title ?? this.title,
    detail: detail ?? this.detail,
    errorKind: identical(errorKind, _notProvided)
        ? this.errorKind
        : errorKind as SignInErrorKind?,
  );

  @override
  bool operator ==(Object other) =>
      other is SignInRecord &&
      other.id == id &&
      other.day == day &&
      other.generation == generation &&
      other.plannedAt == plannedAt &&
      other.occurredAt == occurredAt &&
      other.source == source &&
      other.status == status &&
      other.title == title &&
      other.detail == detail &&
      other.errorKind == errorKind;

  @override
  int get hashCode => Object.hash(
    generation,
    id,
    day,
    plannedAt,
    occurredAt,
    source,
    status,
    title,
    detail,
    errorKind,
  );
}

class SignInResult {
  const SignInResult({
    required this.status,
    required this.title,
    required this.detail,
    this.record,
  });

  const SignInResult.success({
    this.title = '签到成功',
    this.detail = '已完成今日签到。',
    this.record,
  }) : status = SignInRecordStatus.success;

  final SignInRecordStatus status;
  final String title;
  final String detail;
  final SignInRecord? record;

  Map<String, Object?> toMap() => {
    'status': status.name,
    'title': title,
    'detail': detail,
    'record': record?.toMap(),
  };

  factory SignInResult.fromMap(Map<String, Object?> map) => SignInResult(
    status: SignInRecordStatus.values.byName(map['status']! as String),
    title: map['title']! as String,
    detail: map['detail']! as String,
    record: _nullableRecord(map['record']),
  );

  SignInResult copyWith({
    SignInRecordStatus? status,
    String? title,
    String? detail,
    Object? record = _notProvided,
  }) => SignInResult(
    status: status ?? this.status,
    title: title ?? this.title,
    detail: detail ?? this.detail,
    record: identical(record, _notProvided)
        ? this.record
        : record as SignInRecord?,
  );

  @override
  bool operator ==(Object other) =>
      other is SignInResult &&
      other.status == status &&
      other.title == title &&
      other.detail == detail &&
      other.record == record;

  @override
  int get hashCode => Object.hash(status, title, detail, record);
}

DateTime? _nullableDateTime(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

SignInErrorKind? _nullableErrorKind(Object? value) =>
    value == null ? null : SignInErrorKind.values.byName(value as String);

SignInRecord? _nullableRecord(Object? value) => value == null
    ? null
    : SignInRecord.fromMap(Map<String, Object?>.from(value as Map));

bool _sqliteBool(Object? value, String name) {
  if (value == null || value == false || value == 0) {
    return false;
  }
  if (value == true || value == 1) {
    return true;
  }
  throw ArgumentError.value(value, name, 'Must be a SQLite boolean (0 or 1)');
}

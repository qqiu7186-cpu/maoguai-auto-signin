import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../domain/sign_in_errors.dart';
import '../domain/sign_in_models.dart';

class NativeBackgroundResult {
  const NativeBackgroundResult({
    required this.resultId,
    required this.credentialInstanceId,
    required this.record,
  });

  final String resultId;
  final String credentialInstanceId;
  final SignInRecord record;

  factory NativeBackgroundResult.fromMap(Map<Object?, Object?> value) {
    String requiredText(String key, {int maximum = 160}) {
      final raw = value[key];
      if (raw is! String) throw FormatException('Missing $key');
      final text = raw.trim();
      if (text.isEmpty || text.length > maximum) {
        throw FormatException('Invalid $key');
      }
      final safe = SignInError.safeDetail(text);
      if (safe != text) throw FormatException('Unsafe $key');
      return text;
    }

    final resultId = requiredText('resultId', maximum: 128);
    final credentialInstanceId = requiredText(
      'credentialInstanceId',
      maximum: 128,
    );
    final day = requiredText('day', maximum: 10);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      throw const FormatException('Invalid day');
    }
    final occurredRaw = requiredText('occurredAt', maximum: 48);
    final occurredAt = DateTime.tryParse(occurredRaw);
    if (occurredAt == null || _dayKey(occurredAt.toLocal()) != day) {
      throw const FormatException('Invalid occurredAt');
    }
    final status = switch (requiredText('status', maximum: 24)) {
      'success' => SignInRecordStatus.success,
      'done' => SignInRecordStatus.done,
      'failed' ||
      'waitingFirstUnlock' ||
      'running' => SignInRecordStatus.failed,
      'unknown' => SignInRecordStatus.unknown,
      _ => throw const FormatException('Invalid status'),
    };
    final errorKindValue = value['errorKind'];
    final errorKind = errorKindValue == null
        ? null
        : SignInErrorKind.values.asNameMap()[errorKindValue];
    if (errorKindValue != null && errorKind == null) {
      throw const FormatException('Invalid errorKind');
    }
    return NativeBackgroundResult(
      resultId: resultId,
      credentialInstanceId: credentialInstanceId,
      record: SignInRecord(
        day: day,
        occurredAt: occurredAt,
        source: TriggerSource.shortcutBackground,
        status: status,
        title: requiredText('title', maximum: 80),
        detail: requiredText('detail', maximum: 160),
        errorKind: errorKind,
      ),
    );
  }

  static String _dayKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class NativeConnectionCheck {
  const NativeConnectionCheck({required this.title, required this.detail});

  final String title;
  final String detail;

  factory NativeConnectionCheck.fromMap(Map<Object?, Object?> value) {
    final title = value['title'];
    final detail = value['detail'];
    if (title is! String || detail is! String) {
      throw const FormatException('Invalid connection result');
    }
    final safeTitle = SignInError.safeDetail(title);
    final safeDetail = SignInError.safeDetail(detail);
    if (safeTitle != title || safeDetail != detail) {
      throw const FormatException('Unsafe connection result');
    }
    return NativeConnectionCheck(title: title, detail: detail);
  }
}

abstract interface class NativeBackgroundResultPort {
  Future<List<NativeBackgroundResult>> readPending();
  Future<void> acknowledge(Set<String> resultIds);
  Future<void> setNotificationsEnabled(bool enabled);
  Future<void> setActiveCredentialInstance(String? instanceId);
  Future<NativeConnectionCheck> checkConnection();
}

class NativeBackgroundResultChannel implements NativeBackgroundResultPort {
  NativeBackgroundResultChannel([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('maoguai/native_background');

  final MethodChannel _channel;

  @override
  Future<List<NativeBackgroundResult>> readPending() async {
    if (!Platform.isIOS) return const [];
    final response = await _channel.invokeMethod<List<Object?>>(
      'readPendingResults',
    );
    return (response ?? const <Object?>[])
        .whereType<Map>()
        .map((entry) {
          try {
            return NativeBackgroundResult.fromMap(
              Map<Object?, Object?>.from(entry),
            );
          } on FormatException {
            return null;
          }
        })
        .whereType<NativeBackgroundResult>()
        .toList(growable: false);
  }

  @override
  Future<void> acknowledge(Set<String> resultIds) {
    if (!Platform.isIOS) return Future.value();
    return _channel.invokeMethod<void>(
      'acknowledgeResultIds',
      resultIds.toList()..sort(),
    );
  }

  @override
  Future<void> setNotificationsEnabled(bool enabled) {
    if (!Platform.isIOS) return Future.value();
    return _channel.invokeMethod<void>('setNotificationsEnabled', enabled);
  }

  @override
  Future<void> setActiveCredentialInstance(String? instanceId) {
    if (!Platform.isIOS) return Future.value();
    return _channel.invokeMethod<void>(
      'setActiveCredentialInstance',
      instanceId,
    );
  }

  @override
  Future<NativeConnectionCheck> checkConnection() async {
    if (!Platform.isIOS) {
      return const NativeConnectionCheck(
        title: '仅限 iPhone',
        detail: '快捷指令后台签到仅在 iOS 可用。',
      );
    }
    final response = await _channel.invokeMethod<Map<Object?, Object?>>(
      'checkConnection',
    );
    if (response == null) throw const FormatException('Missing connection');
    return NativeConnectionCheck.fromMap(response);
  }
}

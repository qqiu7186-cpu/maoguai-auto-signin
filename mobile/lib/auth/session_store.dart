import 'dart:convert';

import 'auth_models.dart';
import 'credential_store.dart';
import '../storage/sign_in_repository.dart';

abstract interface class SessionStore {
  Future<SessionData?> read();

  /// Non-mutating: a delayed invalid snapshot cannot clear a newer session.
  Future<SessionData?> peek();

  Future<void> save(SessionData session);

  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore([SecureBackend? backend])
    : _backend = backend ?? const FlutterSecureBackend();

  static const _sessionKey = 'signin_session_v2';
  static const _legacySessionKey = 'signin_session_v1';

  final SecureBackend _backend;

  @override
  Future<SessionData?> read() => _read(clearInvalid: true);

  @override
  Future<SessionData?> peek() => _read(clearInvalid: false);

  Future<SessionData?> _read({required bool clearInvalid}) async {
    final value = await _backend.read(key: _sessionKey);
    if (value == null) {
      if (clearInvalid) {
        await _backend.delete(key: _legacySessionKey);
      }
      return null;
    }
    final session = SessionData.fromJsonString(value);
    if (session == null && clearInvalid) {
      await clear();
    }
    return session;
  }

  @override
  Future<void> save(SessionData session) async {
    await _backend.delete(key: _legacySessionKey);
    await _backend.write(key: _sessionKey, value: jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() => Future.wait([
    _backend.delete(key: _sessionKey),
    _backend.delete(key: _legacySessionKey),
  ]);
}

extension ConditionalSessionWrite on SessionStore {
  Future<void> clearIfCurrent(SessionData? expected) async {
    if (expected == null) return;
    final store = this;
    if (store is GuardedSessionStore) {
      final generation = expected.generation;
      if (generation == null) return;
      try {
        await store.repository.withGeneration(generation, () async {
          if (await store.delegate.peek() == expected) {
            await store.delegate.clear();
          }
        });
      } on AccountDataCleared {
        return;
      }
    } else if (await peek() == expected) {
      await clear();
    }
  }

  Future<bool> saveIfCurrent(
    SessionData? expected,
    SessionData replacement,
  ) async {
    final store = this;
    if (store is GuardedSessionStore) {
      return store.compareAndSave(expected, replacement);
    }
    if (await peek() != expected) return false;
    await save(replacement);
    return true;
  }
}

/// The SQLite lifetime transaction serializes session publication with durable
/// logout invalidation, including native secure-store awaits across isolates.
class GuardedSessionStore implements SessionStore {
  GuardedSessionStore({
    required this.delegate,
    required this.credentials,
    required this.repository,
  });
  final SessionStore delegate;
  final CredentialStore credentials;
  final SignInRepository repository;

  @override
  Future<SessionData?> read() async {
    final session = await delegate.peek();
    if (session == null || session.generation == null) return null;
    final account = await credentials.peek();
    if (session.generation != await repository.activeGeneration() ||
        account == null ||
        account.instanceId != session.credentialInstanceId) {
      return null;
    }
    return session;
  }

  @override
  Future<SessionData?> peek() => read();

  Future<bool> compareAndSave(
    SessionData? expected,
    SessionData replacement,
  ) async {
    final generation = replacement.generation;
    if (generation == null) throw const AccountDataCleared();
    return repository.withGeneration(generation, () async {
      final account = await credentials.peek();
      if (account == null ||
          account.instanceId != replacement.credentialInstanceId) {
        return false;
      }
      var current = await delegate.peek();
      if (current?.generation != generation ||
          current?.credentialInstanceId != account.instanceId) {
        current = null;
      }
      if (current != expected) return false;
      await delegate.save(replacement);
      return true;
    });
  }

  @override
  Future<void> save(SessionData session) async {
    final generation = session.generation;
    if (generation == null) throw const AccountDataCleared();
    await repository.withGeneration(generation, () async {
      final account = await credentials.peek();
      if (account == null ||
          account.instanceId != session.credentialInstanceId) {
        throw const AccountDataCleared();
      }
      await delegate.save(session);
    });
  }

  @override
  Future<void> clear() => delegate.clear();
}

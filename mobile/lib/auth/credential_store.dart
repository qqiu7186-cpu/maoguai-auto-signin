import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'auth_models.dart';

export 'auth_models.dart' show StoredCredentials;

const maoguaiProtocolRevision = 'maoguai-2550505-v1';

abstract interface class SecureBackend {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

class FlutterSecureBackend implements SecureBackend {
  const FlutterSecureBackend([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _migration = MethodChannel('maoguai/keychain_accessibility');

  @override
  Future<void> delete({required String key}) =>
      _storage.delete(key: key, iOptions: _iosOptions);

  @override
  Future<String?> read({required String key}) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // Native migration changes only accessibility in-place. Never read/write
      // a secret snapshot: another account may have replaced it meanwhile.
      await _migration.invokeMethod<void>('migrate', key);
    }
    return _storage.read(key: key, iOptions: _iosOptions);
  }

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value, iOptions: _iosOptions);
}

abstract interface class CredentialStore {
  /// Foreground restore may clean up an invalid partial credential set.
  Future<StoredCredentials?> read();

  /// A non-mutating snapshot for asynchronous account guards. Incomplete
  /// credentials return null without deleting a potentially newer instance.
  Future<StoredCredentials?> peek();

  Future<void> save(StoredCredentials credentials);

  Future<void> clear();
}

class SecureCredentialStore implements CredentialStore {
  const SecureCredentialStore([SecureBackend? backend])
    : _backend = backend ?? const FlutterSecureBackend();

  static const _usernameKey = 'signin_username';
  static const _passwordKey = 'signin_password';
  static const _instanceKey = 'signin_credential_instance';
  static const _revisionKey = 'signin_protocol_revision';

  final SecureBackend _backend;

  @override
  Future<StoredCredentials?> read() => _read(clearPartial: true);

  @override
  Future<StoredCredentials?> peek() => _read(clearPartial: false);

  Future<StoredCredentials?> _read({required bool clearPartial}) async {
    final values = await Future.wait([
      _backend.read(key: _usernameKey),
      _backend.read(key: _passwordKey),
      _backend.read(key: _instanceKey),
      _backend.read(key: _revisionKey),
    ]);
    final storedUsername = values[0];
    final storedPassword = values[1];
    final username = storedUsername?.trim() ?? '';
    final password = storedPassword ?? '';
    final instanceId = values[2]?.trim() ?? '';
    if (username.isEmpty ||
        password.isEmpty ||
        instanceId.isEmpty ||
        values[3] != maoguaiProtocolRevision) {
      if (clearPartial &&
          (storedUsername != null ||
              storedPassword != null ||
              values[2] != null ||
              values[3] != null)) {
        await clear();
      }
      return null;
    }
    return StoredCredentials(
      username: username,
      password: password,
      instanceId: instanceId,
    );
  }

  @override
  Future<void> save(StoredCredentials credentials) async {
    if (credentials.username.trim().isEmpty || credentials.password.isEmpty) {
      await clear();
      return;
    }
    await clear();
    await _backend.write(key: _usernameKey, value: credentials.username);
    await _backend.write(key: _passwordKey, value: credentials.password);
    final id =
        credentials.instanceId ??
        StoredCredentials.create(
          username: credentials.username,
          password: credentials.password,
        ).instanceId!;
    await _backend.write(key: _instanceKey, value: id);
    await _backend.write(key: _revisionKey, value: maoguaiProtocolRevision);
  }

  @override
  Future<void> clear() async {
    await Future.wait([
      _backend.delete(key: _usernameKey),
      _backend.delete(key: _passwordKey),
      _backend.delete(key: _instanceKey),
      _backend.delete(key: _revisionKey),
    ]);
  }
}

String maskUsername(String username) {
  final symbols = username.trim().runes.map(String.fromCharCode).toList();
  if (symbols.isEmpty) {
    return '';
  }
  if (symbols.length <= 2) {
    return '*' * symbols.length;
  }
  if (symbols.length <= 4) {
    return '${symbols.first}${'*' * (symbols.length - 2)}${symbols.last}';
  }
  return '${symbols.take(2).join()}${'*' * (symbols.length - 4)}'
      '${symbols.skip(symbols.length - 2).join()}';
}

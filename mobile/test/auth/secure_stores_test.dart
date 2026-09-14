import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maoguai_signin/auth/auth_models.dart';
import 'package:maoguai_signin/auth/credential_store.dart';
import 'package:maoguai_signin/auth/session_store.dart';

class MemorySecureBackend implements SecureBackend {
  MemorySecureBackend([Map<String, String>? initialValues])
    : values = {...?initialValues};

  final Map<String, String> values;

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

class FailingWriteSecureBackend extends MemorySecureBackend {
  FailingWriteSecureBackend(super.initialValues, {required this.failOnWrite});

  final int failOnWrite;
  int _writeCount = 0;

  @override
  Future<void> write({required String key, required String value}) async {
    _writeCount++;
    if (_writeCount == failOnWrite) {
      throw StateError('simulated secure write failure');
    }
    await super.write(key: key, value: value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('iOS secure reads migrate metadata before reading and use first unlock device protection', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const storage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    const migration = MethodChannel('maoguai/keychain_accessibility');
    messenger.setMockMethodCallHandler(migration, (call) async {
      calls.add('migrate:${call.arguments}');
      return null;
    });
    messenger.setMockMethodCallHandler(storage, (call) async {
      final args = call.arguments as Map;
      expect(
        (args['options'] as Map)['accessibility'],
        'first_unlock_this_device',
      );
      calls.add('${call.method}:${args['key']}');
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(storage, null);
      messenger.setMockMethodCallHandler(migration, null);
    });
    const backend = FlutterSecureBackend();
    for (final key in [
      'signin_username',
      'signin_password',
      'signin_credential_instance',
      'signin_protocol_revision',
      'signin_session_v2',
    ]) {
      await backend.read(key: key);
      await backend.write(key: key, value: 'test');
      expect(
        calls,
        containsAllInOrder(['migrate:$key', 'read:$key', 'write:$key']),
      );
    }
  });
  test('partial credentials are rejected and cleared', () async {
    final backend = MemorySecureBackend({'signin_username': 'student'});
    final store = SecureCredentialStore(backend);

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test(
    'legacy revision-less credentials are deleted before login restore',
    () async {
      final backend = MemorySecureBackend({
        'signin_username': 'old-school-user',
        'signin_password': 'old-school-password',
        'signin_credential_instance': 'old-instance',
      });
      final store = SecureCredentialStore(backend);

      expect(await store.read(), isNull);
      expect(backend.values, isEmpty);
    },
  );

  test('saving credentials writes the maoguai target revision', () async {
    final backend = MemorySecureBackend();
    final store = SecureCredentialStore(backend);
    await store.save(
      const StoredCredentials(username: 'mao-100', password: 'secret'),
    );

    expect(backend.values['signin_protocol_revision'], 'maoguai-2550505-v1');
    final restored = await store.read();
    expect(restored?.username, 'mao-100');
    expect(restored?.password, 'secret');
  });

  test('credentials without an instance ID are rejected and cleared', () async {
    final backend = MemorySecureBackend({
      'signin_username': 'mao-101',
      'signin_password': 'stored-password',
      'signin_protocol_revision': 'maoguai-2550505-v1',
    });

    expect(await SecureCredentialStore(backend).read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('whitespace-only persisted username is rejected and cleared', () async {
    final backend = MemorySecureBackend({'signin_username': '   '});
    final store = SecureCredentialStore(backend);

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test(
    'empty persisted password without username is rejected and cleared',
    () async {
      final backend = MemorySecureBackend({'signin_password': ''});
      final store = SecureCredentialStore(backend);

      expect(await store.read(), isNull);
      expect(backend.values, isEmpty);
    },
  );

  test('both empty persisted credentials are rejected and cleared', () async {
    final backend = MemorySecureBackend({
      'signin_username': '',
      'signin_password': '',
    });
    final store = SecureCredentialStore(backend);

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('failed replacement write cannot leave mixed credentials', () async {
    final backend = FailingWriteSecureBackend({
      'signin_username': 'old-account',
      'signin_password': 'old-password',
    }, failOnWrite: 2);
    final store = SecureCredentialStore(backend);

    await expectLater(
      store.save(
        const StoredCredentials(
          username: 'new-account',
          password: 'new-password',
        ),
      ),
      throwsStateError,
    );

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('session JSON round-trips without appearing in toString', () async {
    const session = SessionData(
      token: 'secret-token',
      uid: '123',
      cookies: {'ASP.NET_SessionId': 'cookie-secret'},
      userAgent: 'Mozilla/5.0 test',
    );
    final store = SecureSessionStore(MemorySecureBackend());

    await store.save(session);

    expect(await store.read(), session);
    expect(session.toString(), isNot(contains('secret-token')));
    expect(session.toString(), isNot(contains('cookie-secret')));
  });

  test('v2 session removes the old protocol session key', () async {
    final backend = MemorySecureBackend({'signin_session_v1': '{old'});
    expect(await SecureSessionStore(backend).read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('malformed v2 session removes both v2 and legacy v1 sessions', () async {
    final backend = MemorySecureBackend({
      'signin_session_v1': '{legacy',
      'signin_session_v2': '{malformed',
    });

    expect(await SecureSessionStore(backend).read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('saving a v2 session removes a legacy v1 session', () async {
    final backend = MemorySecureBackend({'signin_session_v1': '{legacy'});
    const session = SessionData(
      token: 'session-token',
      uid: 'uid-1',
      cookies: {'sid': 'session-cookie'},
      userAgent: 'Mozilla/5.0 test',
    );

    await SecureSessionStore(backend).save(session);

    expect(backend.values.containsKey('signin_session_v1'), isFalse);
    expect(await SecureSessionStore(backend).read(), session);
  });

  test('malformed session data is rejected and cleared', () async {
    final backend = MemorySecureBackend({'signin_session_v2': '{not json'});
    final store = SecureSessionStore(backend);

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('equivalent session cookies have the same hash regardless of order', () {
    const first = SessionData(
      token: 'token',
      uid: '123',
      cookies: {'first': 'one', 'second': 'two'},
      userAgent: 'Mozilla/5.0 test',
    );
    const second = SessionData(
      token: 'token',
      uid: '123',
      cookies: {'second': 'two', 'first': 'one'},
      userAgent: 'Mozilla/5.0 test',
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });
}

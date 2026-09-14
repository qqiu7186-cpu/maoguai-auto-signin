import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/auth/auth_models.dart';
import 'package:maoguai_signin/auth/credential_store.dart';
import 'package:maoguai_signin/auth/session_store.dart';
import 'package:maoguai_signin/domain/sign_in_models.dart';
import 'package:maoguai_signin/schedule/daily_plan_service.dart';
import 'package:maoguai_signin/signin/maoguai_sign_in_client.dart';
import 'package:maoguai_signin/signin/sign_in_coordinator.dart';
import 'package:maoguai_signin/storage/sign_in_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_database.dart';
import '../support/test_dependencies.dart';
import 'secure_stores_test.dart' show MemorySecureBackend;
import '../signin/maoguai_sign_in_client_test.dart'
    show RecordingAdapter, jsonReply;

void main() {
  setUpAll(sqfliteFfiInit);
  late TestDatabaseBundle bundle;
  late MemoryCredentialStore credentials;
  late MemorySessionStore raw;
  late GuardedSessionStore sessions;
  late SessionData original;
  setUp(() async {
    bundle = await openTestDatabase();
    credentials = MemoryCredentialStore();
    await credentials.save(
      const StoredCredentials(
        username: 'A',
        password: 'password-A',
        instanceId: 'instance-A',
      ),
    );
    raw = MemorySessionStore();
    sessions = GuardedSessionStore(
      delegate: raw,
      credentials: credentials,
      repository: bundle.repository,
    );
    original = TestGateway.session.forAccount(1, 'instance-A');
    await sessions.save(original);
  });
  tearDown(() => bundle.database.close());

  for (final partialCredentials in [true, false]) {
    test(
      partialCredentials
          ? 'A partial secure credential snapshot cannot delete B after logout and login'
          : 'A malformed secure session snapshot cannot delete B after logout and login',
      () async {
        final backend = _PausedSecureBackend();
        final realCredentials = SecureCredentialStore(backend);
        final realSessions = SecureSessionStore(backend);
        final guarded = GuardedSessionStore(
          delegate: realSessions,
          credentials: realCredentials,
          repository: bundle.repository,
        );
        await realCredentials.save(
          const StoredCredentials(
            username: 'account-A',
            password: 'password-A',
            instanceId: 'instance-A',
          ),
        );
        await guarded.save(original);
        if (partialCredentials) {
          // The secure delete operations during logout are not one atomic read.
          // Capture the partial A snapshot while A's metadata is still active.
          backend.values.remove('signin_password');
          backend.pauseKey = 'signin_password';
        } else {
          backend.values['signin_session_v2'] = '{malformed A session';
          backend.pauseKey = 'signin_session_v2';
        }
        final staleRead = guarded.read();
        await backend.captured.future;
        await bundle.repository.clearAccountData();
        await realCredentials.clear();
        await realSessions.clear();
        await realCredentials.save(
          const StoredCredentials(
            username: 'account-B',
            password: 'password-B',
            instanceId: 'instance-B',
          ),
        );
        final generation = await bundle.repository.activateAccount();
        final bSession = const SessionData(
          token: 'token-B',
          uid: 'uid-B',
          cookies: {'sid': 'cookie-B'},
          userAgent: 'agent-B',
        ).forAccount(generation, 'instance-B');
        await guarded.save(bSession);
        final savedB = Map<String, String>.of(backend.values);

        backend.resume.complete();
        expect(await staleRead, isNull);
        expect(
          backend.values,
          savedB,
          reason: 'a stale guard must perform no secure cleanup',
        );
        expect((await realCredentials.read())!.username, 'account-B');
        expect(await guarded.read(), bSession);
      },
    );
  }

  test(
    'a delayed partial reauthentication credential read cannot clear B',
    () async {
      final backend = _PausedSecureBackend();
      final realCredentials = SecureCredentialStore(backend);
      final realSessions = SecureSessionStore(backend);
      final guarded = GuardedSessionStore(
        delegate: realSessions,
        credentials: realCredentials,
        repository: bundle.repository,
      );
      await realCredentials.save(
        const StoredCredentials(
          username: 'account-A',
          password: 'password-A',
          instanceId: 'instance-A',
        ),
      );
      backend.values.remove('signin_password');
      backend.pauseKey = 'signin_password';
      // No session: preflight reaches its own reauthentication credential read.
      final gateway = TestGateway(guarded);
      final coordinator = SignInCoordinator(
        gateway: gateway,
        credentialStore: realCredentials,
        sessionStore: guarded,
        repository: bundle.repository,
        planService: DailyPlanService(bundle.repository),
      );
      final execution = coordinator.run(
        source: TriggerSource.manual,
        now: DateTime(2026, 9, 9, 9),
      );
      final discarded = expectLater(
        execution,
        throwsA(isA<AccountDataCleared>()),
      );
      await backend.captured.future;
      await bundle.repository.clearAccountData();
      await realCredentials.clear();
      await realSessions.clear();
      await realCredentials.save(
        const StoredCredentials(
          username: 'account-B',
          password: 'password-B',
          instanceId: 'instance-B',
        ),
      );
      final generation = await bundle.repository.activateAccount();
      final bSession = const SessionData(
        token: 'token-B',
        uid: 'uid-B',
        cookies: {'sid': 'cookie-B'},
        userAgent: 'agent-B',
      ).forAccount(generation, 'instance-B');
      await guarded.save(bSession);
      final savedB = Map<String, String>.of(backend.values);
      backend.resume.complete();
      await discarded;
      expect(backend.values, savedB);
      expect(await guarded.read(), bSession);
      expect(gateway.authenticateCalls, 0);
      expect(gateway.submitCalls, 0);
      expect(await bundle.repository.recordsForDay('2026-09-09'), isEmpty);
    },
  );

  test(
    'real protocol cookie refresh keeps its account and credential lifetime',
    () async {
      final client = MaoguaiSignInClient(
        sessionStore: sessions,
        adapter: RecordingAdapter([
          jsonReply(
            {
              'code': 0,
              'data': {'signed': false},
            },
            headers: {
              'set-cookie': ['sid=updated; Path=/'],
            },
          ),
        ]),
      );
      await client.fetchStatus(generation: 1);
      expect((await sessions.read())!.generation, 1);
      expect((await sessions.read())!.credentialInstanceId, 'instance-A');
      expect(raw.saved!.cookies['sid'], 'updated');
    },
  );

  test(
    'invalidation rejects a late session write before final native clear',
    () async {
      await bundle.repository.clearAccountData();
      await expectLater(
        sessions.saveIfCurrent(original, original),
        throwsA(isA<AccountDataCleared>()),
      );
      await sessions.clear();
      expect(raw.saved, isNull);
    },
  );

  test(
    'inactive account rejects an unbound legacy session during logout cleanup',
    () async {
      raw.saved = TestGateway.session;
      await credentials.save(
        const StoredCredentials(username: 'A', password: 'password-A'),
      );
      await bundle.repository.clearAccountData();
      expect(await sessions.read(), isNull);
    },
  );

  test(
    'a delayed real HTTP response cannot replace a newer account session',
    () async {
      final body = StreamController<Uint8List>();
      final arrived = Completer<void>();
      final adapter = RecordingAdapter([
        (request) {
          arrived.complete();
          return ResponseBody(
            body.stream,
            200,
            headers: {
              'set-cookie': ['sid=late-A; Path=/'],
            },
          );
        },
      ]);
      final client = MaoguaiSignInClient(
        sessionStore: sessions,
        adapter: adapter,
      );
      final reading = client.fetchStatus(generation: 1);
      final rejected = expectLater(reading, throwsA(isA<AccountDataCleared>()));
      await arrived.future;
      await bundle.repository.clearAccountData();
      await credentials.save(
        const StoredCredentials(
          username: 'B',
          password: 'password-B',
          instanceId: 'instance-B',
        ),
      );
      final generation = await bundle.repository.activateAccount();
      final current = TestGateway.session.forAccount(generation, 'instance-B');
      await sessions.save(current);
      body.add(
        Uint8List.fromList(utf8.encode('{"code":0,"data":{"signed":false}}')),
      );
      await body.close();
      await rejected;
      expect(raw.saved, current);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'old account compare-and-save cannot overwrite a newly activated account',
    () async {
      await bundle.repository.clearAccountData();
      await credentials.save(
        const StoredCredentials(
          username: 'B',
          password: 'password-B',
          instanceId: 'instance-B',
        ),
      );
      final bGeneration = await bundle.repository.activateAccount();
      final bSession = TestGateway.session.forAccount(
        bGeneration,
        'instance-B',
      );
      await sessions.save(bSession);
      await expectLater(
        sessions.saveIfCurrent(original, original),
        throwsA(isA<AccountDataCleared>()),
      );
      expect(raw.saved, bSession);
      await sessions.clearIfCurrent(original);
      expect(raw.saved, bSession);
    },
  );

  test(
    'reauth publication checks the initiating credential instance',
    () async {
      await credentials.save(
        const StoredCredentials(
          username: 'A',
          password: 'password-A',
          instanceId: 'replacement-instance',
        ),
      );
      expect(await sessions.saveIfCurrent(original, original), isFalse);
      expect(await sessions.read(), isNull);
    },
  );

  test(
    'logout waits for a session write already inside the lifetime transaction',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final delayed = _PausedSessions(entered, release)..saved = original;
      final guarded = GuardedSessionStore(
        delegate: delayed,
        credentials: credentials,
        repository: bundle.repository,
      );
      final writing = guarded.saveIfCurrent(original, original);
      await entered.future;
      var invalidated = false;
      final logout = bundle.repository.clearAccountData().then((_) async {
        invalidated = true;
        await delayed.clear();
      });
      await Future<void>.delayed(Duration.zero);
      expect(invalidated, isFalse);
      release.complete();
      await writing;
      await logout;
      expect(delayed.saved, isNull);
    },
  );
}

class _PausedSessions extends MemorySessionStore {
  _PausedSessions(this.entered, this.release);
  final Completer<void> entered;
  final Completer<void> release;
  @override
  Future<void> save(SessionData session) async {
    entered.complete();
    await release.future;
    await super.save(session);
  }
}

class _PausedSecureBackend extends MemorySecureBackend {
  String? pauseKey;
  final captured = Completer<void>();
  final resume = Completer<void>();
  @override
  Future<String?> read({required String key}) async {
    final snapshot = await super.read(key: key);
    if (key == pauseKey && !captured.isCompleted) {
      captured.complete();
      await resume.future;
    }
    return snapshot;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maoguai_signin/auth/auth_models.dart';
import 'package:maoguai_signin/auth/session_store.dart';
import 'package:maoguai_signin/domain/sign_in_errors.dart';
import 'package:maoguai_signin/signin/maoguai_sign_in_client.dart';
import 'package:maoguai_signin/signin/protocol_constants.dart';
import 'package:maoguai_signin/signin/sign_in_gateway.dart';

const credentials = StoredCredentials(
  username: 'mao-100',
  password: 'pass word',
);

const stored = SessionData(
  token: 'token-1',
  uid: 'mao-100',
  cookies: {'token': 'token-1', 'sid': 'cookie-1'},
  userAgent: ProtocolConstants.userAgent,
);

final uuidExpression = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class MemorySessions implements SessionStore {
  MemorySessions([this.value = stored]);

  SessionData? value;
  bool failSave = false;

  @override
  Future<SessionData?> read() async => value;

  @override
  Future<SessionData?> peek() async => value;

  @override
  Future<void> save(SessionData session) async {
    if (failSave) throw StateError('secret-token cookie-secret password');
    value = session;
  }

  @override
  Future<void> clear() async => value = null;
}

typedef Reply = ResponseBody Function(RequestOptions request);

class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter(List<Reply> replies) : replies = List.of(replies);

  final List<Reply> replies;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return replies.removeAt(0)(options);
  }

  @override
  void close({bool force = false}) {}
}

Reply jsonReply(
  Object? body, {
  int status = 200,
  Map<String, List<String>>? headers,
}) =>
    (_) => ResponseBody.fromString(jsonEncode(body), status, headers: headers);

Reply timeoutReply = (request) => throw DioException(
  requestOptions: request,
  type: DioExceptionType.receiveTimeout,
  message: 'secret-token cookie-secret password mao-100',
);

Matcher errorKind(SignInErrorKind kind) => isA<SignInError>()
    .having((error) => error.kind, 'kind', kind)
    .having(
      (error) => error.toString(),
      'safe text',
      isNot(contains('secret')),
    );

void main() {
  test('request policy refuses every non-audited endpoint', () {
    for (final path in [
      'http://evil.example/sign',
      '//evil.example/sign',
      '/other',
      '/../sign',
      '/sign?target=evil',
      '/sign#fragment',
      '/sign/%2e%2e',
    ]) {
      expect(
        () => ProtocolConstants.requestUri(path),
        throwsA(errorKind(SignInErrorKind.invalidResponse)),
      );
    }
  });

  late MemorySessions sessions;
  late RecordingAdapter adapter;
  late List<Duration> delays;

  MaoguaiSignInClient client(List<Reply> replies) {
    adapter = RecordingAdapter(replies);
    return MaoguaiSignInClient(
      sessionStore: sessions,
      adapter: adapter,
      delay: (duration) async => delays.add(duration),
      uuidFactory: () => '123e4567-e89b-42d3-a456-426614174000',
    );
  }

  setUp(() {
    sessions = MemorySessions();
    delays = [];
  });

  test('login sends exact compact JSON and maoguai signature', () async {
    final gateway = client([
      jsonReply({
        'code': 0,
        'data': {'token': 't-1', 'uid': 'u-1'},
      }),
    ]);

    final session = await gateway.authenticate(credentials);

    final request = adapter.requests.single;
    const body = '{"account":"mao-100","password":"pass word"}';
    expect(request.method, 'POST');
    expect(request.uri, Uri.parse('https://2550505.com/auth/login'));
    expect(request.data, body);
    expect(request.followRedirects, isFalse);
    expect(request.connectTimeout, const Duration(seconds: 10));
    expect(request.receiveTimeout, const Duration(seconds: 15));
    expect(request.headers['X-Client-Version'], '0c1c05');
    expect(request.headers['User-Agent'], ProtocolConstants.userAgent);
    expect(
      request.headers['hash'],
      sha256.convert(utf8.encode('/auth/login${body}undefined')).toString(),
    );
    expect(
      uuidExpression.hasMatch(request.headers['Authorization'] as String),
      isTrue,
    );
    expect(request.headers['Content-Type'], 'application/json');
    expect(request.headers.keys.toSet(), {
      'Accept',
      'User-Agent',
      'Authorization',
      'X-Client-Version',
      'hash',
      'Content-Type',
      // Added by Dio after serializing the exact String body.
      'content-length',
    });
    expect(session.userAgent, ProtocolConstants.userAgent);
  });

  test(
    'fresh login excludes stored cookies and preserves the old session',
    () async {
      final gateway = client([
        (request) {
          expect(sessions.value, stored);
          return jsonReply({
            'code': 0,
            'data': {'token': 'new-token', 'uid': 'new-user'},
          })(request);
        },
      ]);

      final session = await gateway.authenticate(credentials);

      final request = adapter.requests.single;
      expect(request.headers.containsKey('Cookie'), isFalse);
      const body = '{"account":"mao-100","password":"pass word"}';
      expect(
        request.headers['hash'],
        sha256.convert(utf8.encode('/auth/login${body}undefined')).toString(),
      );
      expect(session.cookies, {'token': 'new-token'});
      expect(sessions.value, stored);
    },
  );

  for (final entry in <String, (Object, String, String)>{
    'top-level token': (
      {'code': 0, 'token': 'top-token', 'uid': 'top-uid'},
      'top-token',
      'top-uid',
    ),
    'data token': (
      {
        'code': 0,
        'data': {'token': 'data-token', 'uid': 'data-uid'},
      },
      'data-token',
      'data-uid',
    ),
    'nested data token': (
      {
        'code': 0,
        'data': {
          'data': {'token': 'nested-token', 'uid': 'nested-uid'},
        },
      },
      'nested-token',
      'nested-uid',
    ),
  }.entries) {
    test('login extracts ${entry.key}', () async {
      final result = await client([jsonReply(entry.value.$1)])
          .authenticate(credentials);

      expect(result.token, entry.value.$2);
      expect(result.uid, entry.value.$3);
      expect(result.cookies['token'], result.token);
      expect(result.userAgent, ProtocolConstants.userAgent);
    });
  }

  test('login extracts a host cookie token and falls back to account uid', () async {
    final result = await client([
      jsonReply(
        {'code': 0},
        headers: {
          'set-cookie': [
            'token=cookie-token; Domain=2550505.com; Path=/; Secure; HttpOnly',
            'sid=cookie-1; Path=/',
          ],
        },
      ),
    ]).authenticate(credentials);

    expect(result.token, 'cookie-token');
    expect(result.uid, 'mao-100');
    expect(result.cookies, {'token': 'cookie-token', 'sid': 'cookie-1'});
    expect(result.userAgent, ProtocolConstants.userAgent);
  });

  test(
    'login cannot reuse an inherited token absent from its response',
    () async {
      await expectLater(
        client([
          jsonReply({'code': 0}),
        ]).authenticate(credentials),
        throwsA(errorKind(SignInErrorKind.invalidResponse)),
      );

      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.headers.containsKey('Cookie'), isFalse);
      expect(sessions.value, stored);
    },
  );

  test('login ignores a token cookie from a rejected domain', () async {
    await expectLater(
      client([
        jsonReply(
          {'code': 0},
          headers: {
            'set-cookie': [
              'token=attacker-token; Domain=evil.example; Path=/; Secure',
            ],
          },
        ),
      ]).authenticate(credentials),
      throwsA(errorKind(SignInErrorKind.invalidResponse)),
    );

    expect(adapter.requests, hasLength(1));
    expect(sessions.value, stored);
  });

  test('status signs undefined body with token and sends cookie', () async {
    sessions.value = const SessionData(
      token: 'token-1',
      uid: 'mao-100',
      cookies: {'token': 'token-1', 'sid': 'cookie-1'},
      userAgent: 'test-agent',
    );
    final gateway = client([
      jsonReply({
        'code': 0,
        'data': {'signed': false},
      }),
    ]);

    expect(await gateway.fetchStatus(), RemoteSignInState.pending);
    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.uri, Uri.parse('https://2550505.com/sign/signed'));
    expect(request.data, isNull);
    expect(
      request.headers['hash'],
      sha256.convert(utf8.encode('/sign/signedundefinedtoken-1')).toString(),
    );
    expect(request.headers['Cookie'], contains('token=token-1'));
    expect(request.headers['User-Agent'], ProtocolConstants.userAgent);
    expect(request.headers, isNot(contains('Content-Type')));
    expect(request.headers.keys.toSet(), {
      'Accept',
      'User-Agent',
      'Authorization',
      'X-Client-Version',
      'hash',
      'Cookie',
    });
    expect(sessions.value!.userAgent, ProtocolConstants.userAgent);
  });

  for (final signed in [false, true]) {
    test('status maps signed $signed', () async {
      final result = await client([
        jsonReply({
          'code': 0,
          'data': {'signed': signed},
        }),
      ]).fetchStatus();

      expect(
        result,
        signed ? RemoteSignInState.done : RemoteSignInState.pending,
      );
    });
  }

  test('status accepts the production top-level signed flag', () async {
    final result = await client([
      jsonReply({'code': 0, 'signed': true}),
    ]).fetchStatus();

    expect(result, RemoteSignInState.done);
  });

  test('status accepts a numeric-string success code', () async {
    final result = await client([
      jsonReply({
        'code': '0',
        'data': {'signed': true},
      }),
    ]).fetchStatus();

    expect(result, RemoteSignInState.done);
  });

  for (final body in [
    {
      'data': {'signed': false},
    },
    {'code': 0},
    {
      'code': 0,
      'data': {'signed': 0},
    },
    {
      'code': false,
      'data': {'signed': false},
    },
  ]) {
    test('malformed status maps to invalidResponse: $body', () async {
      await expectLater(
        client([jsonReply(body)]).fetchStatus(),
        throwsA(errorKind(SignInErrorKind.invalidResponse)),
      );
    });
  }

  test('nonzero login code maps to invalidCredentials', () async {
    await expectLater(
      client([
        jsonReply({'code': 1001, 'message': 'password secret-token'}),
      ]).authenticate(credentials),
      throwsA(errorKind(SignInErrorKind.invalidCredentials)),
    );
  });

  test(
    'validation uses the signed GET and maps authenticated response',
    () async {
      expect(
        await client([
          jsonReply({
            'code': 0,
            'data': {'signed': true},
          }),
        ]).validateSession(),
        RemoteSessionState.valid,
      );
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.uri.path, '/sign/signed');
    },
  );

  for (final status in [401, 403]) {
    test('HTTP $status expires validation and status', () async {
      final gateway = client([
        jsonReply({}, status: status),
        jsonReply({}, status: status),
      ]);

      expect(await gateway.validateSession(), RemoteSessionState.expired);
      await expectLater(
        gateway.fetchStatus(),
        throwsA(errorKind(SignInErrorKind.authExpired)),
      );
      expect(adapter.requests, hasLength(2));
    });
  }

  test('explicit expired session response maps to authExpired', () async {
    await expectLater(
      client([
        jsonReply({'code': 401, 'message': 'token expired'}),
      ]).fetchStatus(),
      throwsA(errorKind(SignInErrorKind.authExpired)),
    );
  });

  test('sign sends one empty-body POST with the signed protocol', () async {
    await client([
      jsonReply({'code': 0}),
    ]).submitSignIn();

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.uri, Uri.parse('https://2550505.com/sign'));
    expect(request.data, isNull);
    expect(
      request.headers['hash'],
      sha256.convert(utf8.encode('/signundefinedtoken-1')).toString(),
    );
    expect(request.headers, isNot(contains('Content-Type')));
  });

  test('nonzero sign code preserves a safe server business message', () async {
    try {
      await client([
        jsonReply({'code': 3, 'message': '今日已签到，请勿重复提交'}),
      ]).submitSignIn();
      fail('expected a business rejection');
    } on SignInError catch (error) {
      expect(error.kind, SignInErrorKind.businessRejected);
      expect(error.detail, '今日已签到，请勿重复提交');
    }
  });

  test(
    'nonzero sign code redacts sensitive values from a server message',
    () async {
      try {
        await client([
          jsonReply({'code': 3, 'message': 'token=secret-token cookie-secret'}),
        ]).submitSignIn();
        fail('expected a business rejection');
      } on SignInError catch (error) {
        expect(error.kind, SignInErrorKind.businessRejected);
        expect(error.detail, isNot(contains('secret-token')));
        expect(error.detail, isNot(contains('cookie-secret')));
      }
    },
  );

  test('cookies accept only the fixed HTTPS host and root path', () async {
    await client([
      jsonReply(
        {
          'code': 0,
          'data': {'signed': false},
        },
        headers: {
          'set-cookie': [
            'sid=rotated; Domain=2550505.com; Path=/; Secure',
            'hostonly=accepted',
            'alien=secret; Domain=evil.example; Path=/',
            'subdomain=secret; Domain=api.2550505.com; Path=/',
            'narrow=secret; Path=/sign',
          ],
        },
      ),
    ]).fetchStatus();

    expect(sessions.value!.cookies, {
      'token': 'token-1',
      'sid': 'rotated',
      'hostonly': 'accepted',
    });
    expect(sessions.value!.userAgent, ProtocolConstants.userAgent);
  });

  test('missing session does not access network', () async {
    sessions.value = null;
    final gateway = client([]);

    expect(await gateway.validateSession(), RemoteSessionState.expired);
    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.authExpired)),
    );
    await expectLater(
      gateway.submitSignIn(),
      throwsA(errorKind(SignInErrorKind.authExpired)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('failed sign POST is never retried', () async {
    final gateway = client([timeoutReply, timeoutReply]);

    await expectLater(
      gateway.submitSignIn(),
      throwsA(errorKind(SignInErrorKind.networkUnavailable)),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('failed login POST is never retried', () async {
    final gateway = client([timeoutReply, timeoutReply]);

    await expectLater(
      gateway.authenticate(credentials),
      throwsA(errorKind(SignInErrorKind.networkUnavailable)),
    );
    expect(adapter.requests, hasLength(1));
    expect(delays, isEmpty);
  });

  test('status retries exactly three read attempts', () async {
    final gateway = client([timeoutReply, timeoutReply, timeoutReply]);

    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.networkUnavailable)),
    );
    expect(adapter.requests, hasLength(3));
    expect(delays, [const Duration(seconds: 1), const Duration(seconds: 2)]);
  });

  test('status retries 429 and honors bounded Retry-After', () async {
    final gateway = client([
      jsonReply(
        {},
        status: 429,
        headers: {
          'retry-after': ['999999999999999999999999999999'],
        },
      ),
      jsonReply(
        {},
        status: 429,
        headers: {
          'retry-after': ['4'],
        },
      ),
      jsonReply({
        'code': 0,
        'data': {'signed': false},
      }),
    ]);

    expect(await gateway.fetchStatus(), RemoteSignInState.pending);
    expect(adapter.requests, hasLength(3));
    expect(delays, [const Duration(seconds: 60), const Duration(seconds: 4)]);
  });

  test('status retries 5xx and returns its safe final kind', () async {
    final gateway = client(List.filled(3, jsonReply({}, status: 503)));

    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.serverUnavailable)),
    );
    expect(adapter.requests, hasLength(3));
    expect(delays, [const Duration(seconds: 1), const Duration(seconds: 2)]);
  });

  test('redirect is rejected without following or retrying', () async {
    final gateway = client([
      jsonReply(
        {},
        status: 302,
        headers: {
          'location': ['https://evil.example/steal'],
        },
      ),
    ]);

    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.businessRejected)),
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.followRedirects, isFalse);
    expect(delays, isEmpty);
  });

  test('malformed JSON cannot echo response or request secrets', () async {
    final gateway = client([
      (_) => ResponseBody.fromString(
        'secret-token cookie-secret password mao-100',
        200,
      ),
    ]);

    try {
      await gateway.fetchStatus();
      fail('expected an invalid response');
    } on SignInError catch (error) {
      expect(error.kind, SignInErrorKind.invalidResponse);
      expect(error.detail, '服务端返回的内容不是有效 JSON。');
      expect(error.detail, isNot(contains('secret')));
    }
  });

  test('JSON list response identifies the invalid JSON shape', () async {
    final gateway = client([(_) => ResponseBody.fromString('[]', 200)]);

    try {
      await gateway.fetchStatus();
      fail('expected an invalid response');
    } on SignInError catch (error) {
      expect(error.kind, SignInErrorKind.invalidResponse);
      expect(error.detail, '服务端返回的 JSON 不是对象。');
    }
  });

  test('missing signed status identifies the invalid status field', () async {
    final gateway = client([
      jsonReply({'code': 0, 'data': <String, Object?>{}}),
    ]);

    try {
      await gateway.fetchStatus();
      fail('expected an invalid response');
    } on SignInError catch (error) {
      expect(error.kind, SignInErrorKind.invalidResponse);
      expect(error.detail, '签到状态中缺少有效的 signed 标记。');
    }
  });

  test('nested explicit expiry response maps to authExpired', () async {
    await expectLater(
      client([
        jsonReply({
          'code': 9,
          'data': {'message': '请先登录'},
        }),
      ]).fetchStatus(),
      throwsA(errorKind(SignInErrorKind.authExpired)),
    );
  });

  test('login rejects a token that cannot be sent as an RFC cookie', () async {
    await expectLater(
      client([
        jsonReply({'code': 0, 'token': 'secret\r\nx: leaked'}),
      ]).authenticate(credentials),
      throwsA(errorKind(SignInErrorKind.invalidResponse)),
    );
  });

  test('declared response over 1 MiB is rejected before consumption', () async {
    var consumed = false;
    final gateway = client([
      (_) => ResponseBody(
        (() async* {
          consumed = true;
          yield Uint8List.fromList(utf8.encode('{}'));
        })(),
        200,
        headers: {
          'content-length': ['1048577'],
        },
      ),
    ]);

    try {
      await gateway.fetchStatus();
      fail('expected an invalid response');
    } on SignInError catch (error) {
      expect(error.kind, SignInErrorKind.invalidResponse);
      expect(error.detail, '服务端响应内容超过大小限制。');
    }
    expect(consumed, isFalse);
  });

  test(
    'streamed response over 1 MiB stops before consuming its tail',
    () async {
      var consumedTail = false;
      final gateway = client([
        (_) => ResponseBody(
          (() async* {
            yield Uint8List(1024 * 1024);
            yield Uint8List(1);
            consumedTail = true;
            yield Uint8List(1);
          })(),
          200,
        ),
      ]);

      await expectLater(
        gateway.fetchStatus(),
        throwsA(errorKind(SignInErrorKind.invalidResponse)),
      );
      expect(consumedTail, isFalse);
    },
  );

  test('invalid stored cookie is rejected before network access', () async {
    sessions.value = const SessionData(
      token: 'token-1',
      uid: 'mao-100',
      cookies: {'sid': 'cookie\r\nx: leaked'},
      userAgent: ProtocolConstants.userAgent,
    );
    final gateway = client([]);

    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.invalidResponse)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('a stale status response cannot overwrite a newer session', () async {
    const newer = SessionData(
      token: 'newer-token',
      uid: 'mao-100',
      cookies: {'token': 'newer-token'},
      userAgent: ProtocolConstants.userAgent,
    );
    final gateway = client([
      (_) {
        sessions.value = newer;
        return ResponseBody.fromString(
          jsonEncode({
            'code': 0,
            'data': {'signed': false},
          }),
          200,
        );
      },
    ]);

    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.authExpired)),
    );
    expect(sessions.value, newer);
  });

  test('local session save failure maps to a safe storage error', () async {
    sessions.failSave = true;
    final gateway = client([
      jsonReply({
        'code': 0,
        'data': {'signed': false},
      }),
    ]);

    await expectLater(
      gateway.fetchStatus(),
      throwsA(errorKind(SignInErrorKind.localStorage)),
    );
    expect(adapter.requests, hasLength(1));
  });
}

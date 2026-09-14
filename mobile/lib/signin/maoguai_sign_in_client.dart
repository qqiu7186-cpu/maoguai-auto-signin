import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../auth/auth_models.dart';
import '../auth/session_store.dart';
import '../domain/sign_in_errors.dart';
import '../storage/sign_in_repository.dart';
import 'protocol_constants.dart';
import 'sign_in_gateway.dart';

class MaoguaiSignInClient implements SignInGateway {
  MaoguaiSignInClient({
    required this._sessionStore,
    HttpClientAdapter? adapter,
    Future<void> Function(Duration)? delay,
    String Function()? uuidFactory,
  }) : _delay = delay ?? Future<void>.delayed,
       _uuidFactory = uuidFactory ?? _uuidV4,
       _dio = Dio(
         BaseOptions(
           baseUrl: ProtocolConstants.baseUri.toString(),
           connectTimeout: const Duration(seconds: 10),
           sendTimeout: const Duration(seconds: 15),
           receiveTimeout: const Duration(seconds: 15),
           followRedirects: false,
           maxRedirects: 0,
           responseType: ResponseType.stream,
           validateStatus: (_) => true,
         ),
       ) {
    _dio.httpClientAdapter = _BoundedAdapter(adapter ?? _dio.httpClientAdapter);
  }

  static const _receiveTimeout = Duration(seconds: 15);
  static const _requestTimeout = Duration(seconds: 25);

  final SessionStore _sessionStore;
  final Future<void> Function(Duration) _delay;
  final String Function() _uuidFactory;
  final Dio _dio;

  @override
  Future<SessionData> authenticate(StoredCredentials credentials) async {
    final response = await _requestOnce(
      method: 'POST',
      path: ProtocolConstants.loginPath,
      payload: {
        'account': credentials.username,
        'password': credentials.password,
      },
      token: '',
      cookies: const {},
    );
    final code = _responseCode(response.data);
    if (code == null) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '服务端未返回可识别的状态码。',
      );
    }
    if (code != 0) {
      throw SignInError(
        SignInErrorKind.invalidCredentials,
        detail: _serverMessage(response.data),
      );
    }

    final cookies = {...response.cookies};
    final token =
        _nestedString(response.data, 'token') ??
        response.receivedCookies['token'];
    if (token == null || token.isEmpty || !_cookieValue.hasMatch(token)) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '登录响应中缺少有效的会话令牌。',
      );
    }
    cookies['token'] = token;
    final uid = _nestedString(response.data, 'uid') ?? credentials.username;
    if (uid.isEmpty) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '登录响应中缺少有效的账号标识。',
      );
    }
    return SessionData(
      token: token,
      uid: uid,
      cookies: Map.unmodifiable(cookies),
      userAgent: ProtocolConstants.userAgent,
    );
  }

  @override
  Future<RemoteSessionState> validateSession({int? generation}) async {
    final session = await _loadSession();
    if (session == null) return RemoteSessionState.expired;
    _checkGeneration(session, generation);
    try {
      final response = await _readStatus(session);
      _parseSigned(response.data);
      await _saveCookies(session, response.cookies);
      return RemoteSessionState.valid;
    } on SignInError catch (error) {
      if (error.kind == SignInErrorKind.authExpired) {
        return RemoteSessionState.expired;
      }
      rethrow;
    }
  }

  @override
  Future<RemoteSignInState> fetchStatus({int? generation}) async {
    final session = await _requireSession(generation: generation);
    final response = await _readStatus(session);
    final signed = _parseSigned(response.data);
    await _saveCookies(session, response.cookies);
    return signed ? RemoteSignInState.done : RemoteSignInState.pending;
  }

  @override
  Future<void> submitSignIn({int? generation}) async {
    final session = await _requireSession(generation: generation);
    final response = await _requestOnce(
      method: 'POST',
      path: ProtocolConstants.signPath,
      token: session.token,
      cookies: session.cookies,
    );
    _requireSuccessfulCode(response.data);
    await _saveCookies(session, response.cookies);
  }

  Future<_ProtocolResponse> _readStatus(SessionData session) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _requestOnce(
          method: 'GET',
          path: ProtocolConstants.statusPath,
          token: session.token,
          cookies: session.cookies,
        );
      } on _TemporaryError catch (error) {
        if (attempt >= 2) rethrow;
        await _delay(error.retryAfter ?? Duration(seconds: 1 << attempt));
      }
    }
  }

  Future<_ProtocolResponse> _requestOnce({
    required String method,
    required String path,
    Map<String, Object?>? payload,
    String token = '',
    Map<String, String> cookies = const {},
  }) async {
    final uri = ProtocolConstants.requestUri(path);
    final jsonBody = payload == null ? null : jsonEncode(payload);
    final headers = _headers(
      path: path,
      jsonBody: jsonBody,
      token: token,
      cookies: cookies,
    );
    final cancel = CancelToken();
    try {
      final response = await _dio
          .request<ResponseBody>(
            uri.toString(),
            data: jsonBody,
            options: Options(method: method, headers: headers),
            cancelToken: cancel,
          )
          .timeout(_requestTimeout);
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw SignInError(
          SignInErrorKind.authExpired,
          detail: '服务器返回 HTTP $status，登录状态已失效。',
        );
      }
      if (status == 429) {
        throw _TemporaryError(
          SignInErrorKind.rateLimited,
          detail: '服务器限制访问（HTTP 429）。',
          retryAfter: _retryAfter(response.headers),
        );
      }
      if (status >= 500 && status <= 599) {
        throw _TemporaryError(
          SignInErrorKind.serverUnavailable,
          detail: '服务器暂时不可用（HTTP $status）。',
        );
      }
      if (status < 200 || status >= 300) {
        throw SignInError(
          SignInErrorKind.businessRejected,
          detail: '服务器拒绝请求（HTTP $status）。',
        );
      }
      final body = response.data;
      if (body == null) {
        throw const SignInError(
          SignInErrorKind.invalidResponse,
          detail: '服务器未返回响应内容。',
        );
      }
      final data = await _readJson(body.stream).timeout(_receiveTimeout);
      final cookieResult = _mergeCookies(cookies, response.headers);
      return _ProtocolResponse(
        data,
        cookieResult.merged,
        cookieResult.received,
      );
    } on SignInError {
      rethrow;
    } on TimeoutException {
      throw const _TemporaryError(
        SignInErrorKind.networkUnavailable,
        detail: '网络请求超时。',
      );
    } on SocketException {
      throw const _TemporaryError(
        SignInErrorKind.networkUnavailable,
        detail: '网络连接失败。',
      );
    } on HttpException catch (error) {
      if (_isTransportCause(error)) {
        throw const _TemporaryError(
          SignInErrorKind.networkUnavailable,
          detail: '网络连接失败。',
        );
      }
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '网络协议响应异常，未能读取服务器数据。',
      );
    } on DioException catch (error) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          throw const _TemporaryError(
            SignInErrorKind.networkUnavailable,
            detail: '网络请求超时。',
          );
        case DioExceptionType.unknown:
          if (error.error case final SignInError cause) {
            throw cause;
          }
          if (_isTransportCause(error.error)) {
            throw const _TemporaryError(
              SignInErrorKind.networkUnavailable,
              detail: '网络连接失败。',
            );
          }
          throw const SignInError(
            SignInErrorKind.invalidResponse,
            detail: '网络层返回未知错误，未能读取服务器数据。',
          );
        default:
          throw const SignInError(
            SignInErrorKind.invalidResponse,
            detail: '网络请求被客户端中止或拒绝。',
          );
      }
    } catch (_) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '客户端处理服务器响应时发生异常。',
      );
    } finally {
      cancel.cancel('Request finished');
    }
  }

  Map<String, String> _headers({
    required String path,
    required String? jsonBody,
    required String token,
    required Map<String, String> cookies,
  }) {
    final authorization = _uuidFactory();
    if (!_uuidExpression.hasMatch(authorization)) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '客户端请求标识生成失败。',
      );
    }
    final bodyForHash = jsonBody ?? 'undefined';
    final tokenForHash = token.isEmpty ? 'undefined' : token;
    final digest = sha256
        .convert(utf8.encode(path + bodyForHash + tokenForHash))
        .toString();
    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': ProtocolConstants.userAgent,
      'Authorization': authorization,
      'X-Client-Version': ProtocolConstants.clientVersion,
      'hash': digest,
      if (jsonBody != null) 'Content-Type': 'application/json',
    };
    for (final entry in cookies.entries) {
      if (!_cookieName.hasMatch(entry.key) ||
          !_cookieValue.hasMatch(entry.value)) {
        throw const SignInError(
          SignInErrorKind.invalidResponse,
          detail: '本地会话数据格式无效，请重新登录。',
        );
      }
    }
    if (cookies.isNotEmpty) {
      headers['Cookie'] = cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
    }
    if (headers.values.any(
      (value) => value.contains(RegExp(r'[\x00-\x1f\x7f]')),
    )) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '客户端请求头格式无效。',
      );
    }
    return headers;
  }

  Future<Map<String, dynamic>> _readJson(Stream<Uint8List> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > _BoundedAdapter.maxResponseBytes) {
        throw const SignInError(
          SignInErrorKind.invalidResponse,
          detail: '服务端响应内容超过大小限制。',
        );
      }
      bytes.add(chunk);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '服务端返回的内容不是有效 JSON。',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '服务端返回的 JSON 不是对象。',
      );
    }
    return decoded;
  }

  ({Map<String, String> merged, Map<String, String> received}) _mergeCookies(
    Map<String, String> previous,
    Headers headers,
  ) {
    final cookies = {...previous};
    final received = <String, String>{};
    for (final raw in headers['set-cookie'] ?? const <String>[]) {
      try {
        final cookie = Cookie.fromSetCookieValue(raw);
        final domain = cookie.domain?.toLowerCase().replaceFirst(
          RegExp(r'^\.'),
          '',
        );
        final path = cookie.path;
        if ((domain != null && domain != ProtocolConstants.baseUri.host) ||
            (path != null && path != '/') ||
            !_cookieName.hasMatch(cookie.name) ||
            !_cookieValue.hasMatch(cookie.value)) {
          continue;
        }
        if (cookie.value.isEmpty ||
            (cookie.maxAge != null && cookie.maxAge! <= 0) ||
            (cookie.maxAge == null &&
                cookie.expires != null &&
                !cookie.expires!.isAfter(DateTime.now().toUtc()))) {
          cookies.remove(cookie.name);
          received.remove(cookie.name);
        } else {
          cookies[cookie.name] = cookie.value;
          received[cookie.name] = cookie.value;
        }
      } on FormatException {
        // Ignore malformed remote Cookie data without surfacing it.
      }
    }
    return (
      merged: Map.unmodifiable(cookies),
      received: Map.unmodifiable(received),
    );
  }

  int? _responseCode(Map<String, dynamic> data) {
    final code = data['code'];
    if (code is int) return code;
    if (code is String) return int.tryParse(code.trim());
    return null;
  }

  String? _nestedString(Map<String, dynamic> data, String key) {
    Object? current = data;
    for (var depth = 0; depth < 3; depth++) {
      if (current is! Map) return null;
      final value = current[key];
      if (value is String && value.isNotEmpty) return value;
      current = current['data'];
    }
    return null;
  }

  bool _parseSigned(Map<String, dynamic> data) {
    final code = _responseCode(data);
    if (code == null) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '服务端未返回可识别的状态码。',
      );
    }
    if (code != 0) {
      if (_isExplicitAuthExpiry(data)) {
        throw const SignInError(SignInErrorKind.authExpired);
      }
      throw SignInError(
        SignInErrorKind.businessRejected,
        detail: _serverMessage(data),
      );
    }
    final payload = data['data'];
    final signed =
        data['signed'] ?? (payload is Map ? payload['signed'] : null);
    if (signed is! bool) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '签到状态中缺少有效的 signed 标记。',
      );
    }
    return signed;
  }

  void _requireSuccessfulCode(Map<String, dynamic> data) {
    final code = _responseCode(data);
    if (code == null) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '服务端未返回可识别的状态码。',
      );
    }
    if (code != 0) {
      if (_isExplicitAuthExpiry(data)) {
        throw const SignInError(SignInErrorKind.authExpired);
      }
      throw SignInError(
        SignInErrorKind.businessRejected,
        detail: _serverMessage(data),
      );
    }
  }

  String? _serverMessage(Map<String, dynamic> data) => SignInError.safeDetail(
    _nestedString(data, 'message') ??
        _nestedString(data, 'msg') ??
        _nestedString(data, 'error'),
  );

  bool _isExplicitAuthExpiry(Map<String, dynamic> data) {
    final code = _responseCode(data);
    if (code == 401 || code == 403) return true;
    final message = [
      _nestedString(data, 'message'),
      _nestedString(data, 'msg'),
    ].whereType<String>().join(' ').toLowerCase();
    return const [
      '未登录',
      '请先登录',
      '登录已过期',
      'token expired',
    ].any(message.contains);
  }

  Duration? _retryAfter(Headers headers) {
    final values = headers['retry-after'];
    if (values == null || values.length != 1) return null;
    final value = values.single.trim();
    if (!RegExp(r'^\d+$').hasMatch(value)) return null;
    final seconds = BigInt.tryParse(value);
    if (seconds == null) return null;
    return Duration(seconds: seconds > BigInt.from(60) ? 60 : seconds.toInt());
  }

  bool _isTransportCause(Object? error) {
    if (error is SocketException || error is TimeoutException) return true;
    return error is HttpException &&
        const {
          'Connection closed while receiving data',
          'Connection closed before full header was received',
          'Connection closed before full body was received',
          'Connection closed before response was received',
          'Connection closed before data was received',
          'Socket closed before request was sent',
        }.contains(error.message);
  }

  Future<SessionData?> _loadSession() async {
    try {
      final session = await _sessionStore.peek();
      if (session == null || session.token.isEmpty || session.uid.isEmpty) {
        return null;
      }
      return session;
    } catch (_) {
      throw const SignInError(SignInErrorKind.localStorage);
    }
  }

  Future<SessionData> _requireSession({int? generation}) async {
    final session =
        await _loadSession() ??
        (throw const SignInError(SignInErrorKind.authExpired));
    _checkGeneration(session, generation);
    return session;
  }

  void _checkGeneration(SessionData session, int? generation) {
    if (generation != null && session.generation != generation) {
      throw const AccountDataCleared();
    }
  }

  Future<void> _saveCookies(
    SessionData session,
    Map<String, String> cookies,
  ) async {
    final replacement = SessionData(
      token: cookies['token'] ?? session.token,
      uid: session.uid,
      cookies: cookies,
      userAgent: ProtocolConstants.userAgent,
      generation: session.generation,
      credentialInstanceId: session.credentialInstanceId,
    );
    try {
      if (!await _sessionStore.saveIfCurrent(session, replacement)) {
        throw const SignInError(SignInErrorKind.authExpired);
      }
    } on SignInError {
      rethrow;
    } on AccountDataCleared {
      rethrow;
    } catch (_) {
      throw const SignInError(SignInErrorKind.localStorage);
    }
  }

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static final _uuidExpression = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _cookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9a-zA-Z]+$");
  static final _cookieValue = RegExp(
    r'^[\x21\x23-\x2b\x2d-\x3a\x3c-\x5b\x5d-\x7e]*$',
  );
}

class _ProtocolResponse {
  const _ProtocolResponse(this.data, this.cookies, this.receivedCookies);

  final Map<String, dynamic> data;
  final Map<String, String> cookies;
  final Map<String, String> receivedCookies;
}

class _TemporaryError extends SignInError {
  const _TemporaryError(super.kind, {super.detail, this.retryAfter});

  final Duration? retryAfter;
}

class _BoundedAdapter implements HttpClientAdapter {
  _BoundedAdapter(this._delegate);

  static const maxResponseBytes = 1024 * 1024;

  final HttpClientAdapter _delegate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final allowed = {
      ProtocolConstants.requestUri(ProtocolConstants.loginPath): 'POST',
      ProtocolConstants.requestUri(ProtocolConstants.statusPath): 'GET',
      ProtocolConstants.requestUri(ProtocolConstants.signPath): 'POST',
    };
    if (allowed[options.uri] != options.method || options.followRedirects) {
      throw const SignInError(
        SignInErrorKind.invalidResponse,
        detail: '客户端阻止了未授权的请求地址。',
      );
    }
    final response = await _delegate.fetch(
      options,
      requestStream,
      cancelFuture,
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final lengths = Headers.fromMap(
        response.headers,
      )[Headers.contentLengthHeader];
      if (lengths != null) {
        final length = lengths.length == 1
            ? int.tryParse(lengths.single)
            : null;
        if (length == null || length < 0 || length > maxResponseBytes) {
          throw const SignInError(
            SignInErrorKind.invalidResponse,
            detail: '服务端响应内容超过大小限制。',
          );
        }
      }
      response.stream = _boundedStream(response.stream);
    } else {
      response.stream = const Stream.empty();
    }
    return response;
  }

  Stream<Uint8List> _boundedStream(Stream<Uint8List> stream) {
    var received = 0;
    late StreamSubscription<Uint8List> subscription;
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        subscription = stream.listen(
          (chunk) {
            received += chunk.length;
            if (received > maxResponseBytes) {
              controller.addError(
                const SignInError(
                  SignInErrorKind.invalidResponse,
                  detail: '服务端响应内容超过大小限制。',
                ),
              );
              unawaited(subscription.cancel());
              unawaited(controller.close());
              return;
            }
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: controller.close,
          cancelOnError: true,
        );
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () => subscription.cancel(),
    );
    return controller.stream;
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);
}

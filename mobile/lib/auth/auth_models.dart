import 'dart:convert';
import 'dart:math';

class StoredCredentials {
  const StoredCredentials({
    required this.username,
    required this.password,
    this.instanceId,
  });
  factory StoredCredentials.create({
    required String username,
    required String password,
  }) => StoredCredentials(
    username: username,
    password: password,
    instanceId: base64UrlEncode(
      List.generate(24, (_) => Random.secure().nextInt(256)),
    ),
  );
  final String? instanceId;

  final String username;
  final String password;

  @override
  String toString() => 'StoredCredentials(redacted)';
}

class SessionData {
  const SessionData({
    required this.token,
    required this.uid,
    required this.cookies,
    required this.userAgent,
    this.generation,
    this.credentialInstanceId,
  });

  final String token;
  final String uid;
  final Map<String, String> cookies;
  final String userAgent;
  final int? generation;
  final String? credentialInstanceId;
  SessionData forAccount(int generation, String? credentialInstanceId) =>
      SessionData(
        token: token,
        uid: uid,
        cookies: cookies,
        userAgent: userAgent,
        generation: generation,
        credentialInstanceId: credentialInstanceId,
      );

  Map<String, Object?> toJson() => {
    'token': token,
    'uid': uid,
    'cookies': cookies,
    'userAgent': userAgent,
    'generation': generation,
    'credentialInstanceId': credentialInstanceId,
  };

  static SessionData? fromJsonString(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final token = decoded['token'];
      final uid = decoded['uid'];
      final cookies = decoded['cookies'];
      final userAgent = decoded['userAgent'];
      if (token is! String ||
          token.isEmpty ||
          uid is! String ||
          uid.isEmpty ||
          cookies is! Map ||
          userAgent is! String ||
          userAgent.isEmpty) {
        return null;
      }
      final parsedCookies = <String, String>{};
      for (final entry in cookies.entries) {
        if (entry.key is! String ||
            (entry.key as String).isEmpty ||
            entry.value is! String ||
            (entry.value as String).isEmpty) {
          return null;
        }
        parsedCookies[entry.key as String] = entry.value as String;
      }
      return SessionData(
        token: token,
        uid: uid,
        cookies: parsedCookies,
        userAgent: userAgent,
        generation: decoded['generation'] as int?,
        credentialInstanceId: decoded['credentialInstanceId'] as String?,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is SessionData &&
        generation == other.generation &&
        credentialInstanceId == other.credentialInstanceId &&
        token == other.token &&
        uid == other.uid &&
        userAgent == other.userAgent &&
        _sameCookies(cookies, other.cookies);
  }

  @override
  int get hashCode => Object.hash(
    generation,
    credentialInstanceId,
    token,
    uid,
    userAgent,
    Object.hashAll(
      (cookies.keys.toList()..sort()).map(
        (key) => Object.hash(key, cookies[key]),
      ),
    ),
  );

  @override
  String toString() => 'SessionData(redacted)';
}

bool _sameCookies(Map<String, String> first, Map<String, String> second) {
  if (first.length != second.length) {
    return false;
  }
  for (final entry in first.entries) {
    if (second[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

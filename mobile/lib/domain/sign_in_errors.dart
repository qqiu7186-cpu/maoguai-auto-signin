enum SignInErrorKind {
  invalidCredentials,
  authExpired,
  networkUnavailable,
  rateLimited,
  serverUnavailable,
  businessRejected,
  invalidResponse,
  resultUnknown,
  localStorage,
}

const Object _notProvided = Object();

class SignInError implements Exception {
  const SignInError(this.kind, {this.detail});

  final SignInErrorKind kind;
  final String? detail;

  /// A displayable error explanation must never be used for raw transport
  /// exceptions, request bodies, or response bodies. This final boundary also
  /// protects records when another gateway supplies a [SignInError].
  static String? safeDetail(String? value) {
    final detail = value
        ?.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (detail == null || detail.isEmpty) return null;
    const hidden = '服务端提示中包含敏感信息，已隐藏。';
    final hasSecret = RegExp(
      r'\b(?:token|cookie|authorization|password|passwd|session|sid)\b(?:\s*[:=]\s*|\s+)\S+',
      caseSensitive: false,
    ).hasMatch(detail);
    final hasSecretWord = RegExp(
      r'\bsecret[-_a-z0-9]*\b',
      caseSensitive: false,
    ).hasMatch(detail);
    final hasChineseSecret = RegExp(r'(?:密码|令牌|会话|身份凭证)\s*[:：=]\s*\S+')
        .hasMatch(detail);
    if (hasSecret || hasSecretWord || hasChineseSecret) return hidden;
    return detail.length > 160 ? '${detail.substring(0, 160)}…' : detail;
  }

  String get userMessage {
    switch (kind) {
      case SignInErrorKind.invalidCredentials:
        return '账号或密码不正确，请检查后重试。';
      case SignInErrorKind.authExpired:
        return '登录状态已过期，请重新登录。';
      case SignInErrorKind.networkUnavailable:
        return '网络不可用，请检查网络后重试。';
      case SignInErrorKind.rateLimited:
        return '操作过于频繁，请稍后再试。';
      case SignInErrorKind.serverUnavailable:
        return '服务暂时不可用，请稍后重试。';
      case SignInErrorKind.businessRejected:
        return '签到未被接受，请稍后重试。';
      case SignInErrorKind.invalidResponse:
        return '服务端返回的数据格式不符合已知协议，未能确认签到结果。';
      case SignInErrorKind.resultUnknown:
        return '签到结果未知，请稍后同步确认。';
      case SignInErrorKind.localStorage:
        return '本地数据保存失败，请稍后重试。';
    }
  }

  Map<String, Object?> toMap() => {'kind': kind.name, 'detail': detail};

  factory SignInError.fromMap(Map<String, Object?> map) => SignInError(
    SignInErrorKind.values.byName(map['kind']! as String),
    detail: map['detail'] as String?,
  );

  SignInError copyWith({
    SignInErrorKind? kind,
    Object? detail = _notProvided,
  }) => SignInError(
    kind ?? this.kind,
    detail: identical(detail, _notProvided) ? this.detail : detail as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is SignInError && other.kind == kind && other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, detail);

  @override
  String toString() => 'SignInError(kind: ${kind.name})';
}

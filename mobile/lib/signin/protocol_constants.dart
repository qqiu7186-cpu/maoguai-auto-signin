import '../domain/sign_in_errors.dart';

abstract final class ProtocolConstants {
  static final Uri baseUri = Uri.parse('https://2550505.com');
  static const clientVersion = '0c1c05';
  static const userAgent = 'Mozilla/5.0 (QingLong; 2550505-sign)';
  static const loginPath = '/auth/login';
  static const statusPath = '/sign/signed';
  static const signPath = '/sign';

  /// No configurable host, arbitrary path, query, or redirect target is accepted.
  static Uri requestUri(String path) {
    if (path != loginPath && path != statusPath && path != signPath) {
      throw const SignInError(SignInErrorKind.invalidResponse);
    }
    final uri = baseUri.resolve(path);
    if (uri.scheme != 'https' ||
        uri.host != baseUri.host ||
        uri.port != 443 ||
        uri.path != path ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const SignInError(SignInErrorKind.invalidResponse);
    }
    return uri;
  }
}

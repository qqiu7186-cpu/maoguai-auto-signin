import '../auth/auth_models.dart';

enum RemoteSessionState { valid, expired }

enum RemoteSignInState { pending, done }

abstract interface class SignInGateway {
  /// Returns a candidate only. The caller publishes it after secure credentials
  /// and the initiating account lifetime are current.
  Future<SessionData> authenticate(StoredCredentials credentials);

  Future<RemoteSessionState> validateSession({int? generation});

  Future<RemoteSignInState> fetchStatus({int? generation});

  /// Sends one attempt. Completion is not proof that the server recorded it;
  /// callers must confirm through [fetchStatus].
  Future<void> submitSignIn({int? generation});
}

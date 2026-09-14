import 'dart:async';

/// Joins overlapping callers to the same operation, including its result.
/// This is isolate-local; durable submission ownership belongs in SQLite.
class AsyncLock<T> {
  Future<T>? _inFlight;

  Future<T> run(Future<T> Function() operation) {
    final active = _inFlight;
    if (active != null) return active;

    final completion = Completer<T>();
    _inFlight = completion.future;
    Future<void> execute() async {
      try {
        completion.complete(await operation());
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      } finally {
        _inFlight = null;
      }
    }

    unawaited(execute());
    return completion.future;
  }
}

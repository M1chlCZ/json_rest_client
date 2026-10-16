import 'dart:math';

/// Controls automatic retries of transient request failures.
///
/// A policy applies when the client receives it through the `retryPolicy`
/// constructor parameter. Retries cover network failures and the HTTP
/// statuses listed in [retryableStatuses].
class RetryPolicy {
  /// Creates a retry policy.
  ///
  /// [maxAttempts] counts every attempt, including the first one.
  /// [baseDelay] sets the lower bound of the delay before the first retry.
  /// [retryableStatuses] lists the HTTP statuses that trigger a retry.
  /// [retryNonIdempotent] enables retries for `POST` and other non-idempotent
  /// methods.
  const RetryPolicy({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 200),
    this.retryableStatuses = const {429, 500, 502, 503, 504},
    this.retryNonIdempotent = false,
  }) : assert(maxAttempts >= 1, 'maxAttempts is at least one');

  /// Total number of attempts for one exchange, including the first one.
  final int maxAttempts;

  /// Lower bound of the delay before the first retry.
  final Duration baseDelay;

  /// HTTP statuses that trigger a retry when the method is retryable.
  final Set<int> retryableStatuses;

  /// Enables retries for non-idempotent methods such as `POST`.
  final bool retryNonIdempotent;

  /// Returns the delay before the retry that follows [attempt].
  ///
  /// [attempt] counts failed exchanges, so pass `1` for the first retry.
  /// [retryAfterHeader] is the raw `Retry-After` response header value.
  ///
  /// A valid header value is a whole number of seconds, and the client
  /// honors it exactly. A malformed or missing value falls back to the
  /// backoff. The delay for attempt `n` lies between `baseDelay * 2^(n-1)`
  /// and twice that value.
  Duration delayFor(int attempt, String? retryAfterHeader) {
    final retryAfterSeconds = _parseRetryAfterSeconds(retryAfterHeader);
    if (retryAfterSeconds != null) {
      return Duration(seconds: retryAfterSeconds);
    }
    final step = attempt < 1 ? 0 : attempt - 1;
    var lowerBound = baseDelay.inMicroseconds;
    for (var index = 0; index < step; index++) {
      lowerBound *= 2;
    }
    if (lowerBound <= 0) {
      return Duration.zero;
    }
    final jitter = Random().nextInt(lowerBound + 1);
    return Duration(microseconds: lowerBound + jitter);
  }
}

int? _parseRetryAfterSeconds(String? header) {
  if (header == null) {
    return null;
  }
  final value = header.trim();
  if (value.isEmpty) {
    return null;
  }
  final seconds = int.tryParse(value);
  if (seconds == null || seconds < 0) {
    return null;
  }
  return seconds;
}

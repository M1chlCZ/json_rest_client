/// Base class for all exceptions thrown by the JSON REST client.
///
/// For HTTP status errors the [message] is the raw response body; the
/// `'HTTP <status>'` fallback is used only when that body is empty.
/// [statusCode] and [headers] describe the response that caused the failure
/// when one is available.
sealed class RestClientException implements Exception {
  /// Creates an exception whose [message] describes the failure.
  ///
  /// [statusCode] and [headers] carry the response that caused the failure,
  /// when an HTTP response exists.
  const RestClientException(this.message, {this.statusCode, this.headers});

  /// Human-readable description of the failure.
  ///
  /// HTTP status exceptions carry the raw response body here, or
  /// `'HTTP <status>'` when the body is empty.
  final String message;

  /// HTTP status code of the response that caused the failure, if any.
  final int? statusCode;

  /// Headers of the response that caused the failure, if any.
  final Map<String, String>? headers;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a request fails because of a network-level error.
class NetworkException extends RestClientException {
  /// Creates a [NetworkException] with the given [message], [statusCode], and
  /// [headers].
  const NetworkException(super.message, {super.statusCode, super.headers});
}

/// Thrown when a request does not complete within the configured timeout.
class RequestTimeoutException extends RestClientException {
  /// Creates a [RequestTimeoutException] with the given [message],
  /// [statusCode], and [headers].
  const RequestTimeoutException(
    super.message, {
    super.statusCode,
    super.headers,
  });
}

/// Thrown when the server responds with HTTP `400 Bad Request`.
class BadRequestException extends RestClientException {
  /// Creates a [BadRequestException] with the given [message], [statusCode],
  /// and [headers].
  const BadRequestException(super.message, {super.statusCode, super.headers});
}

/// Thrown when the server responds with HTTP `401` or `403` and no valid
/// authentication token can be obtained.
class UnauthorizedException extends RestClientException {
  /// Creates an [UnauthorizedException] with the given [message], [statusCode],
  /// and [headers].
  const UnauthorizedException(super.message, {super.statusCode, super.headers});
}

/// Thrown when the server responds with HTTP `404 Not Found`.
class NotFoundException extends RestClientException {
  /// Creates a [NotFoundException] with the given [message], [statusCode], and
  /// [headers].
  const NotFoundException(super.message, {super.statusCode, super.headers});
}

/// Thrown when the server responds with HTTP `409 Conflict`.
class ConflictDataException extends RestClientException {
  /// Creates a [ConflictDataException] with the given [message], [statusCode],
  /// and [headers].
  const ConflictDataException(super.message, {super.statusCode, super.headers});
}

/// Thrown when the server responds with HTTP `422 Unprocessable Entity`.
class InvalidInputException extends RestClientException {
  /// Creates an [InvalidInputException] with the given [message], [statusCode],
  /// and [headers].
  const InvalidInputException(super.message, {super.statusCode, super.headers});
}

/// Thrown when the server responds with HTTP `500` or any other unexpected
/// non-success status code.
class ServerErrorException extends RestClientException {
  /// Creates a [ServerErrorException] with the given [message], [statusCode],
  /// and [headers].
  const ServerErrorException(super.message, {super.statusCode, super.headers});
}

/// Thrown when a successful response body cannot be decoded as JSON.
class DeserializationException extends RestClientException {
  /// Creates a [DeserializationException] with the given [message],
  /// [statusCode], and [headers].
  const DeserializationException(
    super.message, {
    super.statusCode,
    super.headers,
  });
}

/// Thrown when a response body exceeds the requested size limit.
final class ResponseLimitException extends RestClientException {
  /// Creates a [ResponseLimitException] with the given [message],
  /// [statusCode], and [headers].
  const ResponseLimitException(
    super.message, {
    super.statusCode,
    super.headers,
  });
}

/// Base class for all exceptions thrown by the JSON REST client.
sealed class RestClientException implements Exception {
  /// Creates an exception with a human-readable [message].
  const RestClientException(this.message);

  /// Human-readable description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a request fails because of a network-level error.
class NetworkException extends RestClientException {
  /// Creates a [NetworkException] with the given [message].
  const NetworkException(super.message);
}

/// Thrown when a request does not complete within the configured timeout.
class RequestTimeoutException extends RestClientException {
  /// Creates a [RequestTimeoutException] with the given [message].
  const RequestTimeoutException(super.message);
}

/// Thrown when the server responds with HTTP `400 Bad Request`.
class BadRequestException extends RestClientException {
  /// Creates a [BadRequestException] with the given [message].
  const BadRequestException(super.message);
}

/// Thrown when the server responds with HTTP `401` or `403` and no valid
/// authentication token can be obtained.
class UnauthorizedException extends RestClientException {
  /// Creates an [UnauthorizedException] with the given [message].
  const UnauthorizedException(super.message);
}

/// Thrown when the server responds with HTTP `404 Not Found`.
class NotFoundException extends RestClientException {
  /// Creates a [NotFoundException] with the given [message].
  const NotFoundException(super.message);
}

/// Thrown when the server responds with HTTP `409 Conflict`.
class ConflictDataException extends RestClientException {
  /// Creates a [ConflictDataException] with the given [message].
  const ConflictDataException(super.message);
}

/// Thrown when the server responds with HTTP `422 Unprocessable Entity`.
class InvalidInputException extends RestClientException {
  /// Creates an [InvalidInputException] with the given [message].
  const InvalidInputException(super.message);
}

/// Thrown when the server responds with HTTP `500` or any other unexpected
/// non-success status code.
class ServerErrorException extends RestClientException {
  /// Creates a [ServerErrorException] with the given [message].
  const ServerErrorException(super.message);
}

/// Thrown when a successful response body cannot be decoded as JSON.
class DeserializationException extends RestClientException {
  /// Creates a [DeserializationException] with the given [message].
  const DeserializationException(super.message);
}

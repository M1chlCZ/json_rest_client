import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'retry_policy.dart';
import 'token_store.dart';

/// Obtains a fresh authentication token, or `null` when refreshing failed.
///
/// The returned token is used for one retry. Implementations usually also
/// persist it to their `TokenStore` so later requests use it.
typedef TokenRefresher = Future<String?> Function();

/// Resolves the `user-agent` value used for outgoing requests.
typedef UserAgentProvider = Future<String> Function();

/// Called before one HTTP exchange starts.
typedef RequestInterceptor = void Function(String method, Uri url);

/// Called after one HTTP exchange completes with a response.
///
/// [statusCode] is the HTTP status and [duration] measures the exchange.
typedef ResponseInterceptor =
    void Function(String method, Uri url, int statusCode, Duration duration);

/// Called after one HTTP exchange fails with [error].
///
/// [duration] measures the time until the failure.
typedef ErrorInterceptor =
    void Function(String method, Uri url, Object error, Duration duration);

/// A raw HTTP response returned by [JsonRestClient.sendRaw].
///
/// Every HTTP status is returned as-is; non-success statuses are not mapped to
/// exceptions.
class RestResponse {
  /// Creates a raw response from its [statusCode], [headers], and [bodyBytes].
  const RestResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  /// HTTP status code of the response.
  final int statusCode;

  /// Response headers with lowercased names, as provided by `package:http`.
  final Map<String, String> headers;

  /// Raw response body bytes exactly as received.
  final Uint8List bodyBytes;

  /// The body decoded as UTF-8, replacing malformed sequences.
  String get body => utf8.decode(bodyBytes, allowMalformed: true);
}

/// A small JSON-over-HTTP client with typed exceptions, pluggable token
/// storage, user-agent injection, single-flight refresh-on-`401` retries,
/// retry policies with backoff, and per-exchange interceptor hooks.
///
/// Request paths are always resolved relative to [baseUrl]; a leading `/` on a
/// path is ignored. Absolute URI paths are not supported and must not be
/// passed.
///
/// Instances are reusable for the lifetime of the app. When no [http.Client] is
/// injected, an internal one is created and released by [close]; an injected
/// client is never closed by this class and remains the responsibility of the
/// caller.
class JsonRestClient {
  /// Creates a client for [baseUrl], treated as a directory prefix.
  ///
  /// [baseUrl] is resolved against request paths; a trailing `/` is added when
  /// it is missing.
  /// [tokenStore] is consulted only for [auth] requests and only by
  /// [authTokenKey]. [onUnauthorized] is called at most once per refresh burst
  /// after a `401` or `403`; when it is `null` those responses throw
  /// [UnauthorizedException] immediately. The token it returns is used for one
  /// retry. [userAgentProvider] supplies the `user-agent` header,
  /// lowercased before it is sent. [defaultHeaders] are applied to every
  /// request, matched case-insensitively, and can be overridden per call.
  /// [timeout] is the default per-request timeout. [retryPolicy] enables
  /// automatic retries of transient failures. [onRequest], [onResponse], and
  /// [onError] observe every HTTP exchange, including each retry attempt.
  JsonRestClient({
    required String baseUrl,
    http.Client? client,
    required this.tokenStore,
    this.onUnauthorized,
    this.userAgentProvider,
    this.authScheme = 'Bearer',
    this.authTokenKey = 'token',
    Map<String, String> defaultHeaders = const {},
    this.timeout = const Duration(seconds: 30),
    this.retryPolicy,
    this.onRequest,
    this.onResponse,
    this.onError,
  }) : baseUrl = baseUrl,
       defaultHeaders = Map.unmodifiable(defaultHeaders),
       _baseUri = _resolveBaseUri(baseUrl),
       _ownsClient = client == null,
       _client = client ?? http.Client();

  /// Base URL against which request paths are resolved.
  final String baseUrl;

  /// Store used to read the token for authenticated requests.
  final TokenStore tokenStore;

  /// Refreshes the token after a `401` or `403` response.
  ///
  /// The returned token is used for one retry.
  final TokenRefresher? onUnauthorized;

  /// Supplies the `user-agent` header value, lowercased before sending.
  final UserAgentProvider? userAgentProvider;

  /// Scheme prepended to the token in the `authorization` header.
  final String authScheme;

  /// Key passed to [TokenStore.read] when loading the token.
  final String authTokenKey;

  /// Unmodifiable headers sent with every request, matched
  /// case-insensitively; per-call headers override them.
  final Map<String, String> defaultHeaders;

  /// Default timeout applied to each HTTP exchange.
  final Duration timeout;

  /// Retries transient failures when set; `null` disables retries.
  final RetryPolicy? retryPolicy;

  /// Called before every HTTP exchange.
  final RequestInterceptor? onRequest;

  /// Called after every HTTP exchange that completes with a response.
  final ResponseInterceptor? onResponse;

  /// Called after every HTTP exchange that fails with an error.
  final ErrorInterceptor? onError;

  final http.Client _client;
  final Uri _baseUri;
  final bool _ownsClient;
  Future<String?>? _refreshInFlight;

  static const Set<String> _idempotentMethods = {
    'GET',
    'HEAD',
    'PUT',
    'DELETE',
  };

  /// Closes the internally created HTTP client.
  ///
  /// When an [http.Client] was injected, this method does nothing; closing that
  /// client remains the caller's responsibility. The instance must not be used
  /// after [close].
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  /// Sends a `GET` request to [path] relative to [baseUrl].
  ///
  /// [path] is always resolved relative to [baseUrl]; a leading `/` is ignored.
  /// [path] must not contain a query string, pass parameters via [query]
  /// instead; [query] entries are URL-encoded and appended to the resolved URI.
  /// Header names are matched case-insensitively and [headers] override
  /// [defaultHeaders] for this call. [auth] sends the token read from
  /// [tokenStore] as `<authScheme> <token>`; when no token exists the header is
  /// omitted. After a `401` or `403`, the token returned by [onUnauthorized] is
  /// used for one retry. [timeout] overrides [timeout] for this call. When
  /// [retryPolicy] is set, each exchange follows that policy.
  ///
  /// A successful response with an empty body returns `null`. Otherwise the
  /// body is JSON-decoded and passed to [decoder] when provided; without a
  /// decoder the decoded value is cast to `T?`.
  ///
  /// HTTP status errors throw the matching [RestClientException] subtype whose
  /// [RestClientException.message] is the raw response body, or
  /// `'HTTP <status>'` when the body is empty.
  ///
  /// [debug] is accepted for call-site compatibility and has no effect; this
  /// client never logs.
  Future<T?> get<T>(
    String path, {
    Map<String, String>? headers,
    Map<String, String>? query,
    bool auth = false,
    Duration? timeout,
    T Function(dynamic json)? decoder,
    bool debug = false,
  }) {
    return _request<T>(
      method: 'GET',
      path: path,
      headers: headers,
      query: query,
      auth: auth,
      timeout: timeout,
      decoder: decoder,
    );
  }

  /// Sends a `POST` request to [path] relative to [baseUrl].
  ///
  /// [body] is JSON-encoded and sent with an `application/json` content type
  /// unless a caller-supplied header overrides it, matched case-insensitively.
  /// All other parameters behave as described on [get].
  Future<T?> post<T>(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? query,
    bool auth = false,
    Duration? timeout,
    T Function(dynamic json)? decoder,
    bool debug = false,
  }) {
    return _request<T>(
      method: 'POST',
      path: path,
      body: body,
      headers: headers,
      query: query,
      auth: auth,
      timeout: timeout,
      decoder: decoder,
    );
  }

  /// Sends [method] to exactly one of [path] or [url] and returns the raw
  /// response.
  ///
  /// Provide either [path], which resolves relative to [baseUrl] with the same
  /// rules as [get], or an absolute [url]; providing both or neither throws an
  /// [ArgumentError]. [body] is JSON-encoded when it is not `null`. Headers
  /// merge in the same order as [get] and [post]. First [defaultHeaders], then
  /// the computed `user-agent`, then an `application/json` content type when
  /// [body] is not `null`, then per-call [headers]. Names match
  /// case-insensitively and per-call values override earlier entries.
  /// [timeout] overrides [timeout] for this call. When [retryPolicy] is set,
  /// each exchange follows that policy.
  ///
  /// A [RestResponse] is returned for every HTTP status; non-success statuses
  /// do not throw and the refresh-on-`401` path is not used. When
  /// [maxResponseBytes] is set and the body grows past it, reading stops and a
  /// [ResponseLimitException] is thrown.
  ///
  /// Network failures throw [NetworkException] and exceeding the timeout
  /// throws [RequestTimeoutException].
  Future<RestResponse> sendRaw(
    String method, {
    String? path,
    Uri? url,
    Object? body,
    Map<String, String>? headers,
    Duration? timeout,
    int? maxResponseBytes,
  }) async {
    if ((path == null) == (url == null)) {
      throw ArgumentError('Exactly one of path and url must be provided.');
    }
    final uri = url ?? _buildUri(path!, null);
    final requestTimeout = timeout ?? this.timeout;
    final requestHeaders = await _buildHeaders(
      auth: false,
      isPost: body != null,
      extra: headers,
    );
    return _runWithRetry<RestResponse>(
      method: method,
      send: () => _observe<RestResponse>(
        method: method,
        uri: uri,
        send: () => _sendRaw(
          method: method,
          uri: uri,
          headers: requestHeaders,
          body: body,
          timeout: requestTimeout,
          maxResponseBytes: maxResponseBytes,
        ),
        statusOf: (response) => response.statusCode,
      ),
      statusOf: (response) => response.statusCode,
      retryAfterOf: (response) => response.headers['retry-after'],
    );
  }

  Future<T?> _request<T>({
    required String method,
    required String path,
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? query,
    bool auth = false,
    Duration? timeout,
    T Function(dynamic json)? decoder,
  }) async {
    final uri = _buildUri(path, query);
    final requestTimeout = timeout ?? this.timeout;
    final isPost = method == 'POST';

    var response = await _sendWithRetry(
      method: method,
      uri: uri,
      headers: await _buildHeaders(auth: auth, isPost: isPost, extra: headers),
      body: body,
      timeout: requestTimeout,
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      final refresher = onUnauthorized;
      if (refresher == null) {
        throw UnauthorizedException(
          _errorMessage(response),
          statusCode: response.statusCode,
          headers: response.headers,
        );
      }
      final token = await (_refreshInFlight ??= refresher().whenComplete(() {
        _refreshInFlight = null;
      }));
      if (token == null || token.isEmpty) {
        throw UnauthorizedException(
          _errorMessage(response),
          statusCode: response.statusCode,
          headers: response.headers,
        );
      }
      response = await _sendWithRetry(
        method: method,
        uri: uri,
        headers: await _buildHeaders(
          auth: auth,
          isPost: isPost,
          extra: headers,
          tokenOverride: token,
        ),
        body: body,
        timeout: requestTimeout,
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw UnauthorizedException(
          _errorMessage(response),
          statusCode: response.statusCode,
          headers: response.headers,
        );
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _mapStatusError(response);
    }

    return _decode<T>(response, decoder);
  }

  Uri _buildUri(String path, Map<String, String>? query) {
    final relativePath = path.startsWith('/') ? path.substring(1) : path;
    final uri = _baseUri.resolve(relativePath);
    if (query == null || query.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: query);
  }

  Future<Map<String, String>> _buildHeaders({
    required bool auth,
    required bool isPost,
    Map<String, String>? extra,
    String? tokenOverride,
  }) async {
    final headers = <String, String>{
      for (final entry in defaultHeaders.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final agent = await userAgentProvider?.call();
    if (agent != null && agent.isNotEmpty) {
      headers['user-agent'] = agent.toLowerCase();
    }
    if (auth) {
      final token = tokenOverride ?? await tokenStore.read(authTokenKey);
      if (token != null && token.isNotEmpty) {
        headers['authorization'] = '$authScheme $token';
      }
    }
    if (isPost) {
      headers.putIfAbsent('content-type', () => 'application/json');
    }
    if (extra != null) {
      for (final entry in extra.entries) {
        headers[entry.key.toLowerCase()] = entry.value;
      }
    }
    return headers;
  }

  Future<http.Response> _sendWithRetry({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Duration timeout,
    Object? body,
  }) {
    return _runWithRetry<http.Response>(
      method: method,
      send: () => _observe<http.Response>(
        method: method,
        uri: uri,
        send: () => _send(
          method: method,
          uri: uri,
          headers: headers,
          timeout: timeout,
          body: body,
        ),
        statusOf: (response) => response.statusCode,
      ),
      statusOf: (response) => response.statusCode,
      retryAfterOf: (response) => response.headers['retry-after'],
    );
  }

  Future<T> _runWithRetry<T>({
    required String method,
    required Future<T> Function() send,
    required int Function(T value) statusOf,
    required String? Function(T value) retryAfterOf,
  }) async {
    var attempt = 1;
    while (true) {
      try {
        final value = await send();
        final policy = retryPolicy;
        if (policy != null &&
            _canRetry(policy, method, attempt) &&
            policy.retryableStatuses.contains(statusOf(value))) {
          await Future<void>.delayed(
            policy.delayFor(attempt, retryAfterOf(value)),
          );
          attempt++;
          continue;
        }
        return value;
      } on NetworkException {
        final policy = retryPolicy;
        if (policy == null || !_canRetry(policy, method, attempt)) {
          rethrow;
        }
        await Future<void>.delayed(policy.delayFor(attempt, null));
        attempt++;
      }
    }
  }

  Future<T> _observe<T>({
    required String method,
    required Uri uri,
    required Future<T> Function() send,
    required int Function(T value) statusOf,
  }) async {
    final stopwatch = Stopwatch()..start();
    onRequest?.call(method, uri);
    T value;
    try {
      value = await send();
    } catch (error) {
      onError?.call(method, uri, error, stopwatch.elapsed);
      rethrow;
    }
    onResponse?.call(method, uri, statusOf(value), stopwatch.elapsed);
    return value;
  }

  bool _canRetry(RetryPolicy policy, String method, int attempt) {
    if (attempt >= policy.maxAttempts) {
      return false;
    }
    return policy.retryNonIdempotent ||
        _idempotentMethods.contains(method.toUpperCase());
  }

  Future<http.Response> _send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Duration timeout,
    Object? body,
  }) async {
    try {
      return await _execute(
        method: method,
        uri: uri,
        headers: headers,
        body: body,
      ).timeout(timeout);
    } on TimeoutException {
      throw RequestTimeoutException(
        '$method $uri timed out after ${timeout.inMilliseconds} ms',
      );
    } on SocketException catch (error) {
      throw NetworkException(error.message);
    } on http.ClientException catch (error) {
      throw NetworkException(error.message);
    }
  }

  Future<http.Response> _execute({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Object? body,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) {
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final streamedResponse = await _client.send(request);
    return http.Response.fromStream(streamedResponse);
  }

  Future<RestResponse> _sendRaw({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Duration timeout,
    Object? body,
    int? maxResponseBytes,
  }) async {
    try {
      return await _readRaw(
        method: method,
        uri: uri,
        headers: headers,
        body: body,
        maxResponseBytes: maxResponseBytes,
      ).timeout(timeout);
    } on TimeoutException {
      throw RequestTimeoutException(
        '$method $uri timed out after ${timeout.inMilliseconds} ms',
      );
    } on SocketException catch (error) {
      throw NetworkException(error.message);
    } on http.ClientException catch (error) {
      throw NetworkException(error.message);
    }
  }

  Future<RestResponse> _readRaw({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Object? body,
    int? maxResponseBytes,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) {
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final streamedResponse = await _client.send(request);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamedResponse.stream) {
      builder.add(chunk);
      if (maxResponseBytes != null && builder.length > maxResponseBytes) {
        throw ResponseLimitException(
          '$method $uri response exceeds $maxResponseBytes bytes',
          statusCode: streamedResponse.statusCode,
          headers: streamedResponse.headers,
        );
      }
    }
    return RestResponse(
      statusCode: streamedResponse.statusCode,
      headers: streamedResponse.headers,
      bodyBytes: builder.takeBytes(),
    );
  }

  T? _decode<T>(http.Response response, T Function(dynamic json)? decoder) {
    final body = response.body;
    if (body.trim().isEmpty) {
      return null;
    }
    final decoded = _jsonDecode(response);
    if (decoder != null) {
      return decoder(decoded);
    }
    try {
      return decoded as T?;
    } on TypeError catch (error) {
      throw DeserializationException(
        error.toString(),
        statusCode: response.statusCode,
        headers: response.headers,
      );
    }
  }

  dynamic _jsonDecode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException catch (error) {
      throw DeserializationException(
        error.message,
        statusCode: response.statusCode,
        headers: response.headers,
      );
    }
  }

  /// Maps a non-success response to a typed exception whose message is the raw
  /// response body, or `'HTTP <status>'` when that body is empty.
  RestClientException _mapStatusError(http.Response response) {
    final message = _errorMessage(response);
    final statusCode = response.statusCode;
    final headers = response.headers;
    return switch (statusCode) {
      400 => BadRequestException(
        message,
        statusCode: statusCode,
        headers: headers,
      ),
      404 => NotFoundException(
        message,
        statusCode: statusCode,
        headers: headers,
      ),
      409 => ConflictDataException(
        message,
        statusCode: statusCode,
        headers: headers,
      ),
      422 => InvalidInputException(
        message,
        statusCode: statusCode,
        headers: headers,
      ),
      _ => ServerErrorException(
        message,
        statusCode: statusCode,
        headers: headers,
      ),
    };
  }

  String _errorMessage(http.Response response) {
    if (response.body.trim().isEmpty) {
      return 'HTTP ${response.statusCode}';
    }
    return response.body;
  }
}

Uri _resolveBaseUri(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  if (uri.path.endsWith('/')) {
    return uri;
  }
  return uri.replace(path: '${uri.path}/');
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'token_store.dart';

/// Obtains a fresh authentication token, or `null` when refreshing failed.
///
/// The returned token is used for the single retry. Implementations usually
/// also persist it to their `TokenStore` so later requests pick it up.
typedef TokenRefresher = Future<String?> Function();

/// Resolves the `user-agent` value used for outgoing requests.
typedef UserAgentProvider = Future<String> Function();

/// A small JSON-over-HTTP client with typed exceptions, pluggable token
/// storage, user-agent injection, and single-flight refresh-on-`401` retries.
///
/// Request paths are always resolved relative to [baseUrl]; a leading `/` on a
/// path is ignored so it cannot escape the base directory.
///
/// Instances are reusable for the lifetime of the app. When no [http.Client] is
/// injected, an internal one is created and released by [close]; an injected
/// client is never closed by this class and remains the responsibility of the
/// caller.
class JsonRestClient {
  /// Creates a client for [baseUrl], treated as a directory prefix.
  ///
  /// [baseUrl] is resolved against request paths, so it should end with `/`.
  /// [tokenStore] is consulted only for [auth] requests and only by
  /// [authTokenKey]. [onUnauthorized] is called at most once per refresh burst
  /// after a `401` or `403`; when it is `null` those responses throw
  /// [UnauthorizedException] immediately. The token it returns is used for the
  /// single retry. [userAgentProvider] supplies the `user-agent` header,
  /// lowercased before it is sent. [defaultHeaders] are applied to every
  /// request, matched case-insensitively, and can be overridden per call.
  /// [timeout] is the default per-request timeout.
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
  /// The returned token is used for the single retry.
  final TokenRefresher? onUnauthorized;

  /// Supplies the `user-agent` header value, lowercased before sending.
  final UserAgentProvider? userAgentProvider;

  /// Scheme prepended to the token in the `authorization` header.
  final String authScheme;

  /// Key passed to [TokenStore.read] when loading the token.
  final String authTokenKey;

  /// Unmodifiable headers sent with every request, matched
  /// case-insensitively; per-call headers take precedence.
  final Map<String, String> defaultHeaders;

  /// Default timeout applied to each HTTP exchange.
  final Duration timeout;

  final http.Client _client;
  final Uri _baseUri;
  final bool _ownsClient;
  Future<String?>? _refreshInFlight;

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
  /// used for one retry. [timeout] overrides [timeout] for this call.
  ///
  /// A successful response with an empty body returns `null`. Otherwise the
  /// body is JSON-decoded and passed to [decoder] when provided; without a
  /// decoder the decoded value is cast to `T?`.
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

    var response = await _send(
      method: method,
      uri: uri,
      headers: await _buildHeaders(auth: auth, isPost: isPost, extra: headers),
      body: body,
      timeout: requestTimeout,
    );

    if (response.statusCode == 401 || response.statusCode == 403) {
      final refresher = onUnauthorized;
      if (refresher == null) {
        throw UnauthorizedException(_errorMessage(response));
      }
      final token = await (_refreshInFlight ??= refresher().whenComplete(() {
        _refreshInFlight = null;
      }));
      if (token == null || token.isEmpty) {
        throw UnauthorizedException(_errorMessage(response));
      }
      response = await _send(
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
        throw UnauthorizedException(_errorMessage(response));
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

  T? _decode<T>(http.Response response, T Function(dynamic json)? decoder) {
    final body = response.body;
    if (body.trim().isEmpty) {
      return null;
    }
    final decoded = _jsonDecode(body);
    if (decoder != null) {
      return decoder(decoded);
    }
    try {
      return decoded as T?;
    } on TypeError catch (error) {
      throw DeserializationException(error.toString());
    }
  }

  dynamic _jsonDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw DeserializationException(error.message);
    }
  }

  RestClientException _mapStatusError(http.Response response) {
    final message = _errorMessage(response);
    return switch (response.statusCode) {
      400 => BadRequestException(message),
      404 => NotFoundException(message),
      409 => ConflictDataException(message),
      422 => InvalidInputException(message),
      500 => ServerErrorException(message),
      _ => ServerErrorException(message),
    };
  }

  String _errorMessage(http.Response response) {
    final body = response.body.trim();
    if (body.isEmpty) {
      return 'HTTP ${response.statusCode}';
    }
    return 'HTTP ${response.statusCode}: $body';
  }
}

Uri _resolveBaseUri(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  if (uri.path.endsWith('/')) {
    return uri;
  }
  return uri.replace(path: '${uri.path}/');
}

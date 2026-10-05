# json_rest_client

A small, dependency-light JSON HTTP client for Dart with typed exceptions,
pluggable auth token storage, user-agent injection, and refresh-on-`401` retry
with a single-flight refresh lock. It is a thin wrapper around
[`package:http`](https://pub.dev/packages/http) that removes the repeated
response-decoding and error-mapping boilerplate from an app's networking layer.

## Features

- `get` and `post` helpers that JSON-decode response bodies automatically.
- Typed exceptions for network, timeout, HTTP status, and deserialization
  failures.
- Auth tokens read from a host-provided `TokenStore`.
- Single-flight token refresh on `401`/`403`, followed by one retry with the
  refreshed token.
- Case-insensitive header merging with per-call overrides.
- Configurable base URL, default timeout, auth scheme, token key, and headers.

## Install

```bash
dart pub add json_rest_client
```

## Quick start

```dart
import 'package:json_rest_client/json_rest_client.dart';

class InMemoryTokenStore implements TokenStore {
  String? token;

  @override
  Future<String?> read(String key) async => token;
}

Future<void> main() async {
  final client = JsonRestClient(
    baseUrl: 'https://api.example.com/v1/',
    tokenStore: InMemoryTokenStore()..token = 'secret',
  );

  final user = await client.get<Map<String, dynamic>>('users/1', auth: true);
  print(user);

  client.close();
}
```

In a Flutter app, back the `TokenStore` with `flutter_secure_storage` (or any
other persistence layer) and create one `JsonRestClient` per base URL for the
lifetime of the app.

## Configuration

| Parameter | Type | Default | Purpose |
| --- | --- | --- | --- |
| `baseUrl` | `String` | required | Directory prefix for every request path. A trailing `/` is added when missing. |
| `client` | `http.Client?` | `null` | Optional injected HTTP client. When injected, `close()` does not close it. |
| `tokenStore` | `TokenStore` | required | Reads the auth token for `auth: true` requests. |
| `onUnauthorized` | `TokenRefresher?` | `null` | Called after a `401`/`403`; returns the token for the single retry. |
| `userAgentProvider` | `UserAgentProvider?` | `null` | Supplies the `user-agent` header; the value is lowercased before sending. |
| `authScheme` | `String` | `'Bearer'` | Scheme prepended to the token in the `authorization` header. |
| `authTokenKey` | `String` | `'token'` | Key passed to `TokenStore.read` when loading the token. |
| `defaultHeaders` | `Map<String, String>` | `const {}` | Headers applied to every request, matched case-insensitively. |
| `timeout` | `Duration` | `Duration(seconds: 30)` | Default timeout for each HTTP exchange. |

### Request methods

Both methods resolve `path` relative to `baseUrl` and return the decoded body
as `T?`, or `null` for an empty successful body.

| Method | Signature | Notes |
| --- | --- | --- |
| `get<T>` | `get<T>(path, {headers, query, auth = false, timeout, decoder, debug = false})` | Sends `GET`. |
| `post<T>` | `post<T>(path, {body, headers, query, auth = false, timeout, decoder, debug = false})` | JSON-encodes `body` and sends `application/json` unless a caller-supplied `content-type` header wins. |

`T` is inferred from the call site, for example
`client.get<List<dynamic>>('items')`, or produced by `decoder`, a
`T Function(dynamic json)` applied to the decoded JSON. Without a `decoder`
the decoded value is cast to `T?`.

## Auth tokens

The client never persists tokens itself; it reads them through the
`TokenStore` interface:

```dart
abstract interface class TokenStore {
  Future<String?> read(String key);
}
```

A minimal implementation backed by a map:

```dart
class AppTokenStore implements TokenStore {
  final Map<String, String> _tokens = {};

  @override
  Future<String?> read(String key) async => _tokens[key];

  Future<void> write(String key, String token) async => _tokens[key] = token;
}
```

When a request is made with `auth: true`, the client reads
`tokenStore.read(authTokenKey)` and sends the header
`authorization: <authScheme> <token>`. When no token exists, or the stored
value is empty, the header is omitted. Customize the key and scheme per base
URL:

```dart
final store = AppTokenStore();

Future<String?> refreshPosToken() async {
  return store.read('posRefreshToken');
}

final posClient = JsonRestClient(
  baseUrl: 'https://pos.example.com/api/',
  tokenStore: store,
  authScheme: 'JWT',
  authTokenKey: 'posToken',
  onUnauthorized: refreshPosToken,
);
```

## Refresh semantics

When a response has status `401` or `403`:

1. If `onUnauthorized` is `null`, an `UnauthorizedException` is thrown.
2. Otherwise `onUnauthorized` is called. Concurrent unauthorized responses on
   the same client share one in-flight refresh (single-flight); the callback
   runs once per refresh burst.
3. The token returned by the callback is used for exactly one retry of the
   original request. The retry does not re-read the `TokenStore`.
4. If the callback returns `null` or an empty string, or if the retry is still
   `401`/`403`, an `UnauthorizedException` is thrown.
5. If the callback itself throws, that error propagates to the caller.

Implementations should persist the new token to their `TokenStore` so later
requests pick it up; the client does not write it back.

## Headers

Header names are matched case-insensitively and merged in this order, with
later entries winning:

1. `defaultHeaders` from the constructor.
2. Computed `user-agent` (from `userAgentProvider`) and `authorization` (for
   `auth: true`).
3. The default `content-type: application/json` for `POST` requests, applied
   only when no `content-type` is present yet.
4. Per-call `headers`.

## Paths, query, and timeouts

- Paths are resolved relative to `baseUrl`, which is treated as a directory:
  a trailing `/` is added when missing, and a leading `/` on the request path
  is ignored. Absolute URI paths are not supported and should not be passed.
- `path` must not contain a query string. Pass parameters with `query`; values
  are URL-encoded.
- The per-call `timeout` overrides the constructor default for that request.

## Exceptions

Every failure detected by the client itself throws a subtype of the sealed
`RestClientException`:

| Exception | Condition |
| --- | --- |
| `NetworkException` | A `SocketException` or `http.ClientException` occurred. |
| `RequestTimeoutException` | The exchange exceeded the timeout. |
| `BadRequestException` | The server responded with `400`. |
| `UnauthorizedException` | `401`/`403` with no usable refresh token, or the retry was still unauthorized. |
| `NotFoundException` | The server responded with `404`. |
| `ConflictDataException` | The server responded with `409`. |
| `InvalidInputException` | The server responded with `422`. |
| `ServerErrorException` | The server responded with `500` or any other non-2xx status. |
| `DeserializationException` | The body was not valid JSON, or it could not be cast to `T`. |

Errors thrown by caller-supplied callbacks (`decoder`, `onUnauthorized`,
`tokenStore`, `userAgentProvider`) and JSON-encoding failures of an unsupported
`body` propagate unchanged.

For HTTP status errors, `message` is the raw response body; the fallback
`'HTTP <status>'` is used only when the body is empty.

## Client ownership

`close()` releases the `http.Client` created internally by the constructor.
When a client is injected through the `client` parameter, `close()` does
nothing and closing that client remains the caller's responsibility. Do not
use the instance after calling `close()`.

## Platform support

The package imports `dart:io` to detect `SocketException`, so it targets
mobile, desktop, and server Dart applications. It is not supported on the web.

## `debug` parameter

`debug` is accepted on `get` and `post` for call-site compatibility and has no
effect: the client never logs.

## Example

See [`example/main.dart`](example/main.dart) for a runnable CLI that calls a
real public JSON endpoint.

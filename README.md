# json_rest_client

A small JSON HTTP client for Dart with typed exceptions, pluggable auth token
storage, user-agent injection, and refresh-on-`401` retry. The package wraps
[`package:http`](https://pub.dev/packages/http) and removes repeated
response-decoding and error-mapping code from an app's networking layer.

## Features

- `get` and `post` helpers that JSON-decode response bodies
- `sendRaw` for status and bytes access without decoding
- Typed exceptions for network, timeout, HTTP status, and deserialization
  failures
- Auth tokens from a host-provided `TokenStore`
- Single-flight token refresh on `401` or `403`, then one retry
- Case-insensitive header merging with per-call overrides
- Configurable base URL, timeout, auth scheme, token key, and headers

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

In a Flutter app, back the `TokenStore` with `flutter_secure_storage`. Create
one `JsonRestClient` per base URL for the lifetime of the app.

## Configuration

| Parameter | Default | Purpose |
| --- | --- | --- |
| `baseUrl` | required | Prefix for every request path. A trailing `/` is added when missing. |
| `client` | `null` | Injected `http.Client`. `close()` leaves it open. |
| `tokenStore` | required | Reads the token for `auth: true` requests. |
| `onUnauthorized` | `null` | Refreshes the token after a `401` or `403`. |
| `userAgentProvider` | `null` | Supplies the `user-agent` header. The value is lowercased. |
| `authScheme` | `'Bearer'` | Scheme in the `authorization` header. |
| `authTokenKey` | `'token'` | Key for `TokenStore.read`. |
| `defaultHeaders` | `const {}` | Headers for every request. |
| `timeout` | 30 seconds | Default timeout for one exchange. |

## Requests

`get` and `post` resolve `path` relative to `baseUrl` and return the decoded
body as `T?`, or `null` for an empty successful body:

```dart
final List<dynamic> items = await client.get<List<dynamic>>('items');

final Map<String, dynamic> created = await client.post<Map<String, dynamic>>(
  'items',
  body: {'name': 'bolt'},
  auth: true,
);
```

Pass a `decoder` to build `T` from the decoded JSON. Pass query parameters
with `query`. Do not put a query string in `path`. A per-call `timeout`
overrides the default.

`sendRaw` returns a `RestResponse` for every status and does not throw for
non-success statuses:

```dart
final RestResponse response = await client.sendRaw(
  'GET',
  path: 'items',
  maxResponseBytes: 1000000,
);
print(response.statusCode);
print(response.headers);
print(response.body);
```

## Auth and refresh

With `auth: true`, the client reads `tokenStore.read(authTokenKey)` and sends
`authorization: <authScheme> <token>`. When no token exists, it omits the
header.

When a response is `401` or `403`:

1. Without `onUnauthorized`, the client throws an `UnauthorizedException`.
2. Concurrent unauthorized responses on one client share one refresh. The
   callback runs once per burst.
3. The returned token is used for one retry of the original request.
4. A `null`, empty, or still-unauthorized result throws an
   `UnauthorizedException`.

The client does not write the new token back. Persist it in your `TokenStore`
so later requests use it.

## Headers

Header names match case-insensitively. Later entries win in this order:

1. `defaultHeaders` from the constructor.
2. The computed `user-agent` and `authorization` headers.
3. The default `content-type: application/json` for `POST` requests.
4. Per-call `headers`.

## Exceptions

Every failure that the client detects throws a subtype of the sealed
`RestClientException`:

| Exception | Condition |
| --- | --- |
| `NetworkException` | A `SocketException` or `http.ClientException` occurred. |
| `RequestTimeoutException` | The exchange exceeded the timeout. |
| `BadRequestException` | The server returned `400`. |
| `UnauthorizedException` | `401` or `403` with no usable refresh token, or the retry was still unauthorized. |
| `NotFoundException` | The server returned `404`. |
| `ConflictDataException` | The server returned `409`. |
| `InvalidInputException` | The server returned `422`. |
| `ServerErrorException` | The server returned `500` or any other non-2xx status. |
| `DeserializationException` | The body was not valid JSON, or the cast to `T` failed. |
| `ResponseLimitException` | `sendRaw` exceeded `maxResponseBytes`. |

For HTTP status errors, `message` holds the raw response body. The fallback
`'HTTP <status>'` is used only when the body is empty. Errors from
caller-supplied callbacks propagate unchanged.

## Client ownership

`close()` releases the `http.Client` that the constructor created. When you
inject a client through the `client` parameter, `close()` does nothing and the
client remains yours. Do not use the instance after `close()`.

## Platform support

The package imports `dart:io` to detect `SocketException`. It supports mobile,
desktop, and server apps. Web is not supported.

## Example

See [`example/main.dart`](example/main.dart) for a runnable CLI.

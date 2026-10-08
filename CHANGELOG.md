## 0.1.2

- Rewrite the README. Document `sendRaw`, `RestResponse`,
  `ResponseLimitException`, and the refresh rules.

## 0.1.1

- `RestClientException` and every subtype now expose the `statusCode` and
  `headers` of the response that caused the failure, when one exists.
- Added `RestResponse` and `JsonRestClient.sendRaw` for status-and-bytes
  access without JSON decoding or error mapping.
- Added `ResponseLimitException`, thrown by `sendRaw` when a response body
  exceeds `maxResponseBytes`; the body stream is abandoned as soon as the
  limit is crossed.

## 0.1.0

- Initial release: extracted the app's networking layer into a standalone,
  pure-Dart package.
- Added `JsonRestClient` with `get` and `post` helpers that JSON-decode
  responses and return `null` for empty successful bodies.
- Added typed exceptions (`RestClientException` and its subtypes) for network,
  timeout, HTTP status, and deserialization failures.
- HTTP status exceptions carry the raw response body as `message`, falling
  back to `'HTTP <status>'` only when the body is empty.
- Errors thrown by caller-supplied callbacks (`decoder`, `onUnauthorized`,
  `tokenStore`, `userAgentProvider`) and JSON-encoding failures of an
  unsupported `body` propagate unchanged.
- Added single-flight refresh on `401`/`403`: the token returned by
  `onUnauthorized` is used for exactly one retry, and a missing token or a
  still-unauthorized retry raises `UnauthorizedException`.
- Request paths resolve relative to `baseUrl`, ignoring a leading `/`.
- Headers merge case-insensitively in the order `defaultHeaders`, computed
  `user-agent`/`authorization`, then per-call `headers`; per-call values win.
- `close()` releases the internally created `http.Client` only; injected
  clients remain the caller's responsibility.
- Pure-Dart scope using `dart:io` for `SocketException`, so the package targets
  mobile, desktop, and server apps (not web).

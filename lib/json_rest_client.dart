/// A small, dependency-light JSON HTTP client with typed exceptions, pluggable auth token storage, user-agent injection, and refresh-on-401 retry with a single-flight refresh lock.
library;

export 'src/errors.dart';
export 'src/json_rest_client.dart';
export 'src/token_store.dart';

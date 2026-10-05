import 'package:json_rest_client/json_rest_client.dart';

/// In-memory [TokenStore] used by the example app.
///
/// A real app would read the token from secure storage instead.
class ExampleTokenStore implements TokenStore {
  /// Creates a store that returns [token] for every key.
  ExampleTokenStore({this.token});

  /// Token returned by [read]; `null` means no token is stored.
  String? token;

  @override
  Future<String?> read(String key) async => token;
}

/// Fetches a post from JSONPlaceholder and prints its title.
///
/// Run with `dart run example/main.dart`.
Future<void> main() async {
  final client = JsonRestClient(
    baseUrl: 'https://jsonplaceholder.typicode.com/',
    tokenStore: ExampleTokenStore(),
    userAgentProvider: () async => 'json_rest_client_example/0.1.0',
  );
  try {
    final post = await client.get<Map<String, dynamic>>('posts/1');
    print('Post #${post?['id']}: ${post?['title']}');
  } finally {
    client.close();
  }
}

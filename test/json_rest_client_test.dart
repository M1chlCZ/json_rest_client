import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:json_rest_client/json_rest_client.dart';
import 'package:test/test.dart';

class FakeTokenStore implements TokenStore {
  FakeTokenStore(this.token);
  String? token;
  String? lastKey;

  @override
  Future<String?> read(String key) async {
    lastKey = key;
    return token;
  }
}

class MapTokenStore implements TokenStore {
  MapTokenStore(this.tokens);
  final Map<String, String> tokens;
  String? lastKey;

  @override
  Future<String?> read(String key) async {
    lastKey = key;
    return tokens[key];
  }
}

void main() {
  late FakeTokenStore store;

  setUp(() => store = FakeTokenStore('token-1'));

  JsonRestClient clientWith(
    MockClient httpClient, {
    TokenRefresher? onUnauthorized,
    UserAgentProvider? userAgentProvider,
  }) {
    return JsonRestClient(
      baseUrl: 'https://example.com/api/',
      client: httpClient,
      tokenStore: store,
      onUnauthorized: onUnauthorized,
      userAgentProvider: userAgentProvider ?? () async => 'App/1.0 (Test)',
      timeout: const Duration(milliseconds: 200),
    );
  }

  test('get joins the base URL and decodes JSON', () async {
    final client = clientWith(
      MockClient((request) async {
        expect(request.url.toString(), 'https://example.com/api/items');
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );

    expect(await client.get('items'), {'ok': true});
  });

  test('get appends query parameters', () async {
    final client = clientWith(
      MockClient((request) async {
        expect(request.url.queryParameters, {'page': '2', 'q': 'a b'});
        return http.Response('{}', 200);
      }),
    );

    await client.get('items', query: {'page': '2', 'q': 'a b'});
  });

  test(
    'get sends lowercased user agent and bearer auth when requested',
    () async {
      final client = clientWith(
        MockClient((request) async {
          expect(request.headers['user-agent'], 'app/1.0 (test)');
          expect(request.headers['authorization'], 'Bearer token-1');
          return http.Response('{}', 200);
        }),
      );

      await client.get('secure', auth: true);
      expect(store.lastKey, 'token');
    },
  );

  test('post encodes the body as JSON with content-type header', () async {
    final client = clientWith(
      MockClient((request) async {
        expect(request.headers['content-type'], contains('application/json'));
        expect(jsonDecode(request.body), {'a': 1});
        return http.Response('{}', 200);
      }),
    );

    await client.post('items', body: {'a': 1});
  });

  test('refreshes once on 401 and retries with the new token', () async {
    store.token = 'old';
    var refreshCalls = 0;
    var attempts = 0;
    final client = clientWith(
      MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          expect(request.headers['authorization'], 'Bearer old');
          return http.Response('unauthorized', 401);
        }
        expect(request.headers['authorization'], 'Bearer new');
        return http.Response('{"ok":true}', 200);
      }),
      onUnauthorized: () async {
        refreshCalls++;
        store.token = 'new';
        return 'new';
      },
    );

    expect(await client.get('secure', auth: true), {'ok': true});
    expect(refreshCalls, 1);
    expect(attempts, 2);
  });

  test('shares a single refresh across concurrent 401s', () async {
    var refreshCalls = 0;
    final gate = Completer<void>();
    var attempts = 0;
    final client = clientWith(
      MockClient((request) async {
        attempts++;
        if (attempts <= 2) {
          return http.Response('unauthorized', 401);
        }
        return http.Response('{}', 200);
      }),
      onUnauthorized: () async {
        refreshCalls++;
        await gate.future;
        store.token = 'new';
        return 'new';
      },
    );

    final futures = [client.get('a', auth: true), client.get('b', auth: true)];
    await pumpEventQueue();
    expect(refreshCalls, 1);
    gate.complete();
    await Future.wait(futures);
    expect(refreshCalls, 1);
    expect(attempts, 4);
  });

  test('throws UnauthorizedException when refresh yields no token', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('nope', 401)),
      onUnauthorized: () async => null,
    );

    await expectLater(
      client.get('secure', auth: true),
      throwsA(isA<UnauthorizedException>()),
    );
  });

  test('maps status codes to typed exceptions', () async {
    Future<void> expectStatus(int status, Matcher matcher) async {
      final client = clientWith(
        MockClient((request) async => http.Response('body', status)),
      );
      await expectLater(client.get('x'), throwsA(matcher));
    }

    await expectStatus(400, isA<BadRequestException>());
    await expectStatus(404, isA<NotFoundException>());
    await expectStatus(409, isA<ConflictDataException>());
    await expectStatus(422, isA<InvalidInputException>());
    await expectStatus(500, isA<ServerErrorException>());
  });

  test('throws NetworkException on socket failures', () async {
    final client = clientWith(
      MockClient((request) async {
        throw const SocketException('no internet');
      }),
    );

    await expectLater(client.get('x'), throwsA(isA<NetworkException>()));
  });

  test('throws RequestTimeoutException on timeout', () async {
    final client = clientWith(
      MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.Response('{}', 200);
      }),
    );

    await expectLater(client.get('x'), throwsA(isA<RequestTimeoutException>()));
  });

  test('throws DeserializationException on malformed JSON', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('not json', 200)),
    );

    await expectLater(
      client.get('x'),
      throwsA(isA<DeserializationException>()),
    );
  });

  test('strips a leading slash so the base path is preserved', () async {
    final client = clientWith(
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.com/api/twofactor/check',
        );
        return http.Response('{}', 200);
      }),
    );

    await client.get('/twofactor/check');
  });

  test('caller content-type overrides win case-insensitively', () async {
    var calls = 0;
    final client = JsonRestClient(
      baseUrl: 'https://example.com/api/',
      client: MockClient((request) async {
        calls++;
        expect(
          request.headers['content-type'],
          calls == 1 ? 'text/plain' : 'application/xml',
        );
        return http.Response('{}', 200);
      }),
      tokenStore: store,
      defaultHeaders: {'Content-Type': 'text/plain'},
      userAgentProvider: () async => 'app/1.0 (test)',
      timeout: const Duration(milliseconds: 200),
    );

    await client.post('items', body: {'a': 1});
    await client.post(
      'items',
      body: {'a': 1},
      headers: {'Content-Type': 'application/xml'},
    );
  });

  test('retries with the token returned by the refresher', () async {
    store.token = 'old';
    var attempts = 0;
    final client = clientWith(
      MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response('unauthorized', 401);
        }
        expect(request.headers['authorization'], 'Bearer fresh');
        return http.Response('{}', 200);
      }),
      onUnauthorized: () async => 'fresh',
    );

    await client.get('secure', auth: true);
    expect(store.token, 'old');
  });

  test('uses a custom auth token key and scheme', () async {
    final keyedStore = MapTokenStore({'posToken': 'pos-token'});
    final client = JsonRestClient(
      baseUrl: 'https://example.com/api/',
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'JWT pos-token');
        return http.Response('{}', 200);
      }),
      tokenStore: keyedStore,
      authScheme: 'JWT',
      authTokenKey: 'posToken',
      userAgentProvider: () async => 'app/1.0 (test)',
      timeout: const Duration(milliseconds: 200),
    );

    await client.get('secure', auth: true);
    expect(keyedStore.lastKey, 'posToken');
  });

  test('refreshes on 403', () async {
    var attempts = 0;
    final client = clientWith(
      MockClient((request) async {
        attempts++;
        return attempts == 1
            ? http.Response('forbidden', 403)
            : http.Response('{}', 200);
      }),
      onUnauthorized: () async => 'new',
    );

    expect(await client.get('secure', auth: true), <String, dynamic>{});
    expect(attempts, 2);
  });

  test('throws UnauthorizedException on 401 without a refresher', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('nope', 401)),
    );

    await expectLater(
      client.get('secure', auth: true),
      throwsA(isA<UnauthorizedException>()),
    );
  });

  test(
    'throws UnauthorizedException when the retry is still unauthorized',
    () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return http.Response('nope', 401);
        }),
        onUnauthorized: () async => 'new',
      );

      await expectLater(
        client.get('secure', auth: true),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(attempts, 2);
    },
  );

  test('applies a custom decoder to the decoded JSON', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('{"id":7}', 200)),
    );

    final id = await client.get<int>(
      'item',
      decoder: (json) => (json as Map<String, dynamic>)['id'] as int,
    );
    expect(id, 7);
  });

  test('returns null for an empty success body', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('', 204)),
    );

    expect(await client.get('empty'), isNull);
  });

  test('throws DeserializationException on a mismatched type cast', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('"text"', 200)),
    );

    await expectLater(
      client.get<Map<String, dynamic>>('x'),
      throwsA(isA<DeserializationException>()),
    );
  });
}

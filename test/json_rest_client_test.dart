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
}

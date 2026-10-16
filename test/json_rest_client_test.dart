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
    RetryPolicy? retryPolicy,
    RequestInterceptor? onRequest,
    ResponseInterceptor? onResponse,
    ErrorInterceptor? onError,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    return JsonRestClient(
      baseUrl: 'https://example.com/api/',
      client: httpClient,
      tokenStore: store,
      onUnauthorized: onUnauthorized,
      userAgentProvider: userAgentProvider ?? () async => 'App/1.0 (Test)',
      timeout: timeout,
      retryPolicy: retryPolicy,
      onRequest: onRequest,
      onResponse: onResponse,
      onError: onError,
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

  test('exposes the raw response body on HTTP status errors', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('{"error":"boom"}', 409)),
    );

    await expectLater(
      client.get('x'),
      throwsA(
        isA<ConflictDataException>().having(
          (error) => error.message,
          'message',
          '{"error":"boom"}',
        ),
      ),
    );
  });

  test('falls back to the status code when the error body is empty', () async {
    final client = clientWith(
      MockClient((request) async => http.Response('', 500)),
    );

    await expectLater(
      client.get('x'),
      throwsA(
        isA<ServerErrorException>().having(
          (error) => error.message,
          'message',
          'HTTP 500',
        ),
      ),
    );
  });

  test('exposes status code and headers on HTTP errors', () async {
    final client = clientWith(
      MockClient((request) async {
        return http.Response('busy', 503, headers: {'retry-after': '7'});
      }),
    );

    await expectLater(
      client.get('x'),
      throwsA(
        isA<ServerErrorException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.headers?['retry-after'], 'retry-after', '7'),
      ),
    );
  });

  test('sendRaw returns the status, headers, and bytes', () async {
    final client = clientWith(
      MockClient((request) async {
        return http.Response.bytes([1, 2, 3], 201, headers: {'x-a': 'b'});
      }),
    );

    final response = await client.sendRaw('GET', path: 'x');
    expect(response.statusCode, 201);
    expect(response.headers['x-a'], 'b');
    expect(response.bodyBytes, [1, 2, 3]);
  });

  test('sendRaw enforces maxResponseBytes', () async {
    final client = clientWith(
      MockClient((request) async {
        return http.Response.bytes(List<int>.filled(64, 0), 200);
      }),
    );

    await expectLater(
      client.sendRaw('GET', path: 'x', maxResponseBytes: 16),
      throwsA(isA<ResponseLimitException>()),
    );
  });

  group('RetryPolicy.delayFor', () {
    const policy = RetryPolicy(baseDelay: Duration(milliseconds: 100));

    test('applies jittered exponential bounds to the backoff', () {
      for (var i = 0; i < 30; i++) {
        expect(
          policy.delayFor(1, null).inMicroseconds,
          inInclusiveRange(100000, 200000),
        );
        expect(
          policy.delayFor(2, null).inMicroseconds,
          inInclusiveRange(200000, 400000),
        );
        expect(
          policy.delayFor(3, null).inMicroseconds,
          inInclusiveRange(400000, 800000),
        );
      }
      const zero = RetryPolicy(baseDelay: Duration.zero);
      expect(zero.delayFor(3, null), Duration.zero);
    });

    test('honors valid retry-after values exactly', () {
      expect(policy.delayFor(1, '7'), const Duration(seconds: 7));
      expect(policy.delayFor(3, '0'), Duration.zero);
      expect(policy.delayFor(2, ' 12 '), const Duration(seconds: 12));
    });

    test('falls back to the backoff for malformed retry-after values', () {
      for (final value in [null, '', 'abc', '-5', '1.5']) {
        expect(
          policy.delayFor(1, value).inMicroseconds,
          inInclusiveRange(100000, 200000),
        );
      }
    });
  });

  group('retries', () {
    const policy = RetryPolicy(baseDelay: Duration(milliseconds: 1));

    test('retries a retryable status and succeeds', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return attempts == 1
              ? http.Response('busy', 503)
              : http.Response('{"ok":true}', 200);
        }),
        retryPolicy: policy,
      );

      expect(await client.get('items'), {'ok': true});
      expect(attempts, 2);
    });

    test('retries a network failure and succeeds', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          if (attempts == 1) {
            throw const SocketException('reset');
          }
          return http.Response('{}', 200);
        }),
        retryPolicy: policy,
      );

      await client.get('items');
      expect(attempts, 2);
    });

    test('stops after maxAttempts and throws the last error', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return http.Response('busy', 503);
        }),
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          baseDelay: Duration(milliseconds: 1),
        ),
      );

      await expectLater(
        client.get('items'),
        throwsA(isA<ServerErrorException>()),
      );
      expect(attempts, 3);
    });

    test('does not retry POST by default', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return http.Response('busy', 503);
        }),
        retryPolicy: policy,
      );

      await expectLater(
        client.post('items'),
        throwsA(isA<ServerErrorException>()),
      );
      expect(attempts, 1);
    });

    test('retries POST when retryNonIdempotent is true', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return attempts == 1
              ? http.Response('busy', 503)
              : http.Response('{}', 200);
        }),
        retryPolicy: const RetryPolicy(
          baseDelay: Duration(milliseconds: 1),
          retryNonIdempotent: true,
        ),
      );

      expect(await client.post('items', body: {'a': 1}), <String, dynamic>{});
      expect(attempts, 2);
    });

    test('never retries timeouts', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          await Future<void>.delayed(const Duration(seconds: 1));
          return http.Response('{}', 200);
        }),
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          baseDelay: Duration(milliseconds: 1),
        ),
      );

      await expectLater(
        client.get('slow'),
        throwsA(isA<RequestTimeoutException>()),
      );
      expect(attempts, 1);
    });

    test('honors retry-after zero without waiting for the backoff', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return attempts == 1
              ? http.Response('busy', 429, headers: {'retry-after': '0'})
              : http.Response('{}', 200);
        }),
        retryPolicy: const RetryPolicy(baseDelay: Duration(seconds: 30)),
      );

      expect(await client.get('items'), <String, dynamic>{});
      expect(attempts, 2);
    });

    test('retries sendRaw requests with an idempotent method', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return attempts == 1
              ? http.Response('busy', 503)
              : http.Response('{}', 200);
        }),
        retryPolicy: policy,
      );

      final response = await client.sendRaw('PUT', path: 'items');
      expect(response.statusCode, 200);
      expect(attempts, 2);
    });

    test('sendRaw does not retry POST by default', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return http.Response('busy', 503);
        }),
        retryPolicy: policy,
      );

      final response = await client.sendRaw('POST', path: 'items');
      expect(response.statusCode, 503);
      expect(attempts, 1);
    });

    test('sendRaw retries a network failure', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          if (attempts == 1) {
            throw const SocketException('reset');
          }
          return http.Response('{}', 200);
        }),
        retryPolicy: policy,
      );

      final response = await client.sendRaw('GET', path: 'items');
      expect(response.statusCode, 200);
      expect(attempts, 2);
    });
  });

  group('interceptors', () {
    test('observes a successful exchange in order', () async {
      final events = <String>[];
      Duration? responseDuration;
      final client = clientWith(
        MockClient((request) async => http.Response('{}', 200)),
        onRequest: (method, url) => events.add('request $method $url'),
        onResponse: (method, url, status, duration) {
          events.add('response $method $url $status');
          responseDuration = duration;
        },
        onError: (method, url, error, duration) => events.add('error'),
      );

      await client.get('items');

      expect(events, [
        'request GET https://example.com/api/items',
        'response GET https://example.com/api/items 200',
      ]);
      expect(responseDuration, greaterThanOrEqualTo(Duration.zero));
    });

    test('reports a network failure through onError', () async {
      final errors = <Object>[];
      var responses = 0;
      final client = clientWith(
        MockClient((request) async => throw const SocketException('down')),
        onRequest: (method, url) {},
        onResponse: (method, url, status, duration) => responses++,
        onError: (method, url, error, duration) => errors.add(error),
      );

      await expectLater(client.get('items'), throwsA(isA<NetworkException>()));
      expect(responses, 0);
      expect(errors.single, isA<NetworkException>());
    });

    test('fires once per retry attempt', () async {
      var attempts = 0;
      final statuses = <int>[];
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return attempts == 1
              ? http.Response('busy', 503)
              : http.Response('{}', 200);
        }),
        retryPolicy: const RetryPolicy(baseDelay: Duration(milliseconds: 1)),
        onResponse: (method, url, status, duration) => statuses.add(status),
      );

      await client.get('items');
      expect(attempts, 2);
      expect(statuses, [503, 200]);
    });

    test('fires once per refresh attempt', () async {
      store.token = 'old';
      var attempts = 0;
      var requests = 0;
      final statuses = <int>[];
      final client = clientWith(
        MockClient((request) async {
          attempts++;
          return attempts == 1
              ? http.Response('expired', 401)
              : http.Response('{}', 200);
        }),
        onUnauthorized: () async => 'new',
        onRequest: (method, url) => requests++,
        onResponse: (method, url, status, duration) => statuses.add(status),
      );

      await client.get('secure', auth: true);
      expect(requests, 2);
      expect(statuses, [401, 200]);
    });

    test('applies to sendRaw', () async {
      var requests = 0;
      final statuses = <int>[];
      final client = clientWith(
        MockClient((request) async => http.Response('{}', 201)),
        onRequest: (method, url) {
          requests++;
          expect(method, 'POST');
        },
        onResponse: (method, url, status, duration) => statuses.add(status),
      );

      final response = await client.sendRaw('POST', path: 'items');
      expect(response.statusCode, 201);
      expect(requests, 1);
      expect(statuses, [201]);
    });

    test('reports an HTTP status error as a response', () async {
      final events = <String>[];
      final client = clientWith(
        MockClient((request) async => http.Response('boom', 500)),
        onResponse: (method, url, status, duration) =>
            events.add('response $status'),
        onError: (method, url, error, duration) => events.add('error'),
      );

      await expectLater(
        client.get('items'),
        throwsA(isA<ServerErrorException>()),
      );
      expect(events, ['response 500']);
    });
  });

  group('timeout overrides', () {
    test('a shorter per-call timeout times out', () async {
      final client = clientWith(
        MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{}', 200);
        }),
        timeout: const Duration(seconds: 30),
      );

      await expectLater(
        client.get('slow', timeout: const Duration(milliseconds: 50)),
        throwsA(isA<RequestTimeoutException>()),
      );
    });

    test('a longer per-call timeout succeeds', () async {
      final client = clientWith(
        MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{"ok":true}', 200);
        }),
        timeout: const Duration(milliseconds: 50),
      );

      expect(await client.get('slow', timeout: const Duration(seconds: 30)), {
        'ok': true,
      });
    });

    test('sendRaw honors a shorter per-call timeout', () async {
      final client = clientWith(
        MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{}', 200);
        }),
        timeout: const Duration(seconds: 30),
      );

      await expectLater(
        client.sendRaw(
          'GET',
          path: 'slow',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<RequestTimeoutException>()),
      );
    });

    test('sendRaw honors a longer per-call timeout', () async {
      final client = clientWith(
        MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('{}', 200);
        }),
        timeout: const Duration(milliseconds: 50),
      );

      final response = await client.sendRaw(
        'GET',
        path: 'slow',
        timeout: const Duration(seconds: 30),
      );
      expect(response.statusCode, 200);
    });
  });
}

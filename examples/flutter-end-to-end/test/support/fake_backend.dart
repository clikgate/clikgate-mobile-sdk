import 'dart:convert';
import 'dart:typed_data';

import 'package:clikgate_end_to_end/src/backend/backend_api.dart';
import 'package:clikgate_end_to_end/src/session_store.dart';
import 'package:dio/dio.dart';

/// Answers like a sample backend, with no network, and records each request's path and headers.
class FakeBackend implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool rejectPassword = false;

  static const user = {'id': 'user_42', 'email': 'ada@example.com', 'createdAt': '2026-11-21T10:00:00Z'};

  /// A real BackendApi (with its interceptors) whose requests go to this fake.
  BackendApi api(SessionStore session) {
    final api = BackendApi.create('https://backend.test', session);
    return api..dio.httpClientAdapter = this;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final (status, body) = switch (options.path) {
      '/auth/sign-up' => (201, _session()),
      '/auth/sign-in' => rejectPassword ? (401, {'error': 'invalid_credentials'}) : (200, _session()),
      '/me' => (200, {'user': user, 'clikgateIdentityToken': 'token-from-me'}),
      '/payments/paystack/confirm' => (200, {'status': 'paid'}),
      _ => (404, {'error': 'not_found'}),
    };
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  Map<String, Object> _session() => {'user': user, 'accessToken': 'session-1', 'clikgateIdentityToken': 'token-1'};

  @override
  void close({bool force = false}) {}
}

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:http/http.dart' as http;

import 'errors.dart';

/// What Engage needs from the core plugin: the feature switches, the request
/// context and the error report-back. The default ([ClikgateCoreBridge]) is
/// `Clikgate`'s internal API; tests pass a fake.
abstract interface class EngageCore {
  /// `Clikgate.isFeatureEnabled`.
  Future<bool> isFeatureEnabled(String key);

  /// `Clikgate.getRequestContext`.
  Future<ClikgateRequestContext> requestContext();

  /// `Clikgate.reportServerError`.
  Future<void> reportServerError(String code, {String? feature});
}

/// [EngageCore] over the `clikgate_flutter` plugin.
class ClikgateCoreBridge implements EngageCore {
  const ClikgateCoreBridge();

  @override
  Future<bool> isFeatureEnabled(String key) => Clikgate.isFeatureEnabled(key);

  @override
  Future<ClikgateRequestContext> requestContext() => Clikgate.getRequestContext();

  @override
  Future<void> reportServerError(String code, {String? feature}) =>
      Clikgate.reportServerError(code, feature: feature);
}

class _CacheEntry {
  _CacheEntry(this.storedAt, this.body);
  final DateTime storedAt;
  final Map<String, dynamic> body;
}

/// `/v1/sdk/*` calls with the 17A.3 rules: feature switch first (no network
/// when off), the core's request context, `not_identified` before any
/// network call for user calls, 60 s in-memory read cache, at most one retry
/// and only for network errors, typed errors.
class EngageClient {
  EngageClient({
    required this.core,
    http.Client? httpClient,
    this.cacheTtl = const Duration(seconds: 60),
    this.timeout = const Duration(seconds: 10),
    this.retryDelay = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final EngageCore core;
  final http.Client _http;
  final Duration cacheTtl;
  final Duration timeout;
  final Duration retryDelay;
  final DateTime Function() _clock;
  final Map<String, _CacheEntry> _cache = {};

  /// Global error codes the core SDK must also see.
  static const _reportedCodes = {'invalid_sdk_key', 'sdk_disabled', 'installation_unknown'};

  void clearCache() => _cache.clear();

  /// Runs one call. [needsUser]: fail with `not_identified` when the
  /// installation isn't identified. [cacheable]: GET results kept for
  /// [cacheTtl]. [write]: clears the cache after success.
  Future<Map<String, dynamic>> call({
    required String feature,
    required String method,
    required String path,
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    bool needsUser = false,
    bool cacheable = false,
    bool write = false,
  }) async {
    if (!await core.isFeatureEnabled(feature)) {
      throw ClikgateException(ClikgateException.featureDisabled,
          "The '$feature' feature is switched off for this app",
          feature: feature);
    }
    final ctx = await core.requestContext();
    if (needsUser && ctx.customerUserId == null) {
      throw const ClikgateException(ClikgateEngageErrors.notIdentified,
          'Call Clikgate.identifyUser() first: this call acts on behalf of a user.');
    }
    final base = Uri.parse(ctx.apiBaseUrl.replaceFirst(RegExp(r'/+$'), '') + path);
    final uri = query.isEmpty ? base : base.replace(queryParameters: query);
    final key = '${ctx.installationId}|${ctx.customerUserId}|${ctx.identityToken != null}|$method $uri';
    if (cacheable) {
      final hit = _cache[key];
      if (hit != null && _clock().difference(hit.storedAt) < cacheTtl) return hit.body;
      _cache.remove(key);
    }

    final response = await _send(ctx, method, uri, body);
    final json = await _handle(response, feature);
    if (write) _cache.clear();
    if (cacheable) _cache[key] = _CacheEntry(_clock(), json);
    return json;
  }

  Future<http.Response> _send(ClikgateRequestContext ctx, String method, Uri uri,
      Map<String, Object?>? body) async {
    for (var attempt = 0;; attempt++) {
      final req = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(ctx.headers)
        ..headers['Accept'] = 'application/json';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json; charset=utf-8';
        req.body = jsonEncode(body);
      }
      try {
        final streamed = await _http.send(req).timeout(timeout);
        return await http.Response.fromStream(streamed).timeout(timeout);
      } catch (e) {
        final network = e is http.ClientException ||
            e is SocketException ||
            e is HandshakeException ||
            e is TimeoutException;
        if (!network) rethrow;
        if (attempt == 0) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        throw ClikgateException(
            e is TimeoutException ? ClikgateException.timeout : ClikgateException.networkError,
            e is TimeoutException ? 'Request timed out' : 'Network request failed: $e');
      }
    }
  }

  Future<Map<String, dynamic>> _handle(http.Response r, String feature) async {
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    Map<String, dynamic>? json;
    if (text.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) json = decoded.map((k, v) => MapEntry(k.toString(), v));
      } on FormatException {
        json = null;
      }
    }
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (json == null && text.trim().isNotEmpty) {
        throw ClikgateException('server_error', 'Invalid JSON response', status: r.statusCode);
      }
      final body = json ?? <String, dynamic>{};
      if (body['accepted'] == false && body['reason'] == 'feature_disabled') {
        final key = body['feature'] as String? ?? feature;
        await _report(ClikgateException.featureDisabled, key);
        throw ClikgateException(ClikgateException.featureDisabled,
            "The '$key' feature is switched off for this app",
            feature: key);
      }
      return body;
    }
    final err = json?['error'];
    String? code;
    String? message;
    String? param;
    String? errFeature;
    String? touch;
    if (err is Map) {
      code = err['code'] as String?;
      message = err['message'] as String?;
      param = err['param'] as String?;
      errFeature = err['feature'] as String?;
      touch = err['offline_touch_id'] as String?;
    }
    code ??= switch (r.statusCode) {
      401 => 'invalid_sdk_key',
      422 => 'validation_error',
      429 => 'rate_limited',
      >= 500 => 'server_error',
      _ => 'http_${r.statusCode}',
    };
    if (_reportedCodes.contains(code)) await _report(code, null);
    throw ClikgateException(code, message ?? 'HTTP ${r.statusCode}',
        status: r.statusCode, param: param, feature: errFeature, offlineTouchId: touch);
  }

  Future<void> _report(String code, String? feature) async {
    try {
      await core.reportServerError(code, feature: feature);
    } catch (_) {
      // Reporting is best effort.
    }
  }
}

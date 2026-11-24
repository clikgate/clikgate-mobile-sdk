import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:http/http.dart' as http;

import '../channel.dart';
import '../test_seams.dart';
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

/// An [EngageCore] that can also give the request context at once: the
/// stored installation id, customer ID and identity token after the same
/// gates, without waiting for the install or a pending identify. Not exported
/// ([ClikgateCoreBridge] does this over the plugin; tests implement it).
abstract interface class EngageNoWaitCore {
  Future<ClikgateRequestContext> requestContextNoWait();
}

/// RFC 3986 percent-encoding of the UTF-8 bytes of [s] (only
/// `A-Z a-z 0-9 - . _ ~` stay as they are).
String pctEncode(String s) => Uri.encodeComponent(s).replaceAllMapped(
    RegExp(r"[!*'()]"),
    (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}');

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
  })  : _http = httpClient ?? engageHttpClientOverride?.call() ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final EngageCore core;
  final http.Client _http;
  final Duration cacheTtl;
  final Duration timeout;
  final Duration retryDelay;
  final DateTime Function() _clock;
  final Map<String, _CacheEntry> _cache = {};
  final Map<String, DateTime> _refreshedAt = {};

  /// Global error codes the core SDK must also see.
  static const _reportedCodes = {'invalid_sdk_key', 'sdk_disabled', 'installation_unknown'};

  void clearCache() {
    _cache.clear();
    _refreshedAt.clear();
  }

  /// True (and noted) when [key] wasn't claimed in the last [cacheTtl]: a
  /// background refresh at most once per period.
  bool claimRefresh(String key) {
    final now = _clock();
    final last = _refreshedAt[key];
    if (last != null && now.difference(last) < cacheTtl && !now.isBefore(last)) {
      return false;
    }
    _refreshedAt[key] = now;
    return true;
  }

  Future<ClikgateRequestContext> _noWaitContext() async {
    final c = core;
    if (c case final EngageNoWaitCore n) return n.requestContextNoWait();
    if (c is ClikgateCoreBridge) {
      return ClikgateRequestContext.fromMap(await ClikgateChannels.invokeMap(
          'getRequestContext', {'wait': false}));
    }
    return c.requestContext();
  }

  /// Runs one call. [needsUser]: fail with `not_identified` when the
  /// installation isn't identified. [cacheable]: GET results kept for
  /// [cacheTtl]. [write]: clears the cache after success. [byToken]: a read
  /// the server can answer from the identity token alone: with a stored
  /// customer ID and token it is sent at once with `Clikgate-Customer-User-Id`
  /// (no wait for the install or identify); `installation_unknown` /
  /// `not_identified` (an older server, or a race) retry once through the
  /// waiting context. Without a token it waits as other calls do.
  Future<Map<String, dynamic>> call({
    required String feature,
    required String method,
    required String path,
    Map<String, String> query = const {},
    Map<String, Object?>? body,
    bool needsUser = false,
    bool cacheable = false,
    bool write = false,
    bool byToken = false,
  }) async {
    if (!await core.isFeatureEnabled(feature)) {
      throw ClikgateException(ClikgateException.featureDisabled,
          "The '$feature' feature is switched off for this app",
          feature: feature);
    }
    var ctx = byToken ? await _noWaitContext() : await core.requestContext();
    final fast = byToken && ctx.customerUserId != null && ctx.identityToken != null;
    if (byToken && !fast && ctx.customerUserId != null) {
      ctx = await core.requestContext();
    }
    if (needsUser && ctx.customerUserId == null) {
      throw const ClikgateException(ClikgateEngageErrors.notIdentified,
          'Call Clikgate.identifyUser() first: this call acts on behalf of a user.');
    }
    final base = Uri.parse(ctx.apiBaseUrl.replaceFirst(RegExp(r'/+$'), '') + path);
    final uri = query.isEmpty ? base : base.replace(queryParameters: query);
    // The customer ID is part of the key: one user's answer is never served to another.
    final key = '${ctx.installationId}|${ctx.customerUserId}|${ctx.identityToken != null}|$method $uri';
    if (cacheable) {
      final hit = _cache[key];
      if (hit != null && _clock().difference(hit.storedAt) < cacheTtl) return hit.body;
      _cache.remove(key);
    }

    final Map<String, dynamic> json;
    try {
      final response = await _send(ctx, method, uri, body,
          customer: fast ? ctx.customerUserId : null);
      json = await _handle(response, feature, retrying: fast);
    } on ClikgateException catch (e) {
      if (!fast || (e.code != 'installation_unknown' && e.code != ClikgateEngageErrors.notIdentified)) {
        rethrow;
      }
      // An older server ignores the header, or the install / identify is still on its way
      return call(
          feature: feature,
          method: method,
          path: path,
          query: query,
          body: body,
          needsUser: needsUser,
          cacheable: cacheable,
          write: write);
    }
    if (write) _cache.clear();
    if (cacheable) _cache[key] = _CacheEntry(_clock(), json);
    return json;
  }

  Future<http.Response> _send(ClikgateRequestContext ctx, String method, Uri uri,
      Map<String, Object?>? body, {String? customer}) async {
    for (var attempt = 0;; attempt++) {
      final req = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(ctx.headers)
        ..headers['Accept'] = 'application/json';
      if (customer != null) req.headers['Clikgate-Customer-User-Id'] = pctEncode(customer);
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

  /// [retrying]: a token-only read retried through the waiting path, which
  /// reports `installation_unknown` itself if it still holds.
  Future<Map<String, dynamic>> _handle(http.Response r, String feature,
      {bool retrying = false}) async {
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
    if (_reportedCodes.contains(code) && !(retrying && code == 'installation_unknown')) {
      await _report(code, null);
    }
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

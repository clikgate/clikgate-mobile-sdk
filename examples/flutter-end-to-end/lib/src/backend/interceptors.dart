import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:dio/dio.dart';

import '../session_store.dart';

typedef InstallationHeaderSource = Future<ClikgateInstallationHeader?> Function();

/// The no-token option (Path B): adds the `Clikgate-Installation` header to every request to your own backend,
/// which passes it to the server SDK's `identifyUser` after its own sign-in check. The header names this app
/// installation, not the user, and it isn't a secret. Send it only to your own server, over HTTPS.
class InstallationHeaderInterceptor extends Interceptor {
  InstallationHeaderInterceptor({InstallationHeaderSource? header})
      : _header = header ?? Clikgate.getInstallationHeader;

  final InstallationHeaderSource _header;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    // Null while tracking is off on this phone (or before the first config): then the request goes without it.
    final header = await _header();
    if (header != null) options.headers[header.name] = header.value;
    handler.next(options);
  }
}

/// Adds the backend's own access token to signed-in requests.
class AccessTokenInterceptor extends Interceptor {
  AccessTokenInterceptor(this._session);

  final SessionStore _session;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _session.accessToken;
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }
}

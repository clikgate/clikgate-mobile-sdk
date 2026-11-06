import 'package:flutter/services.dart';

import 'exception.dart';
import 'models.dart';

/// Platform channels shared with the native plugins.
class ClikgateChannels {
  ClikgateChannels._();

  static const MethodChannel methods = MethodChannel('com.clikgate/sdk');
  static const EventChannel deepLinks = EventChannel('com.clikgate/deep_links');

  /// Invokes [method], mapping platform errors to [ClikgateException].
  static Future<T?> invoke<T>(String method,
      [Map<String, Object?> args = const {}]) async {
    try {
      return await methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw ClikgateException.fromPlatformException(e);
    } on MissingPluginException {
      throw const ClikgateException(ClikgateException.unsupportedPlatform,
          'The Clikgate plugin is not available on this platform or isolate.');
    }
  }

  /// Invokes [method] and decodes a map result.
  static Future<Map<String, dynamic>> invokeMap(String method,
      [Map<String, Object?> args = const {}]) async {
    final result = await invoke<Object?>(method, args);
    return asStringMap(result);
  }
}

import 'dart:async';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/material.dart';

import 'screens/product_screen.dart';

/// Opens the right screen for each Clikgate deep link: the deferred one after install, and direct opens.
class DeepLinkRouter {
  DeepLinkRouter(this._navigator, {Stream<ClikgateDeepLink>? links}) : _links = links ?? Clikgate.onDeepLink;

  final GlobalKey<NavigatorState> _navigator;
  final Stream<ClikgateDeepLink> _links;
  StreamSubscription<ClikgateDeepLink>? _subscription;

  /// Links that arrive before this listens are kept by the SDK and delivered now.
  void start() => _subscription ??= _links.listen(_open);

  void dispose() => _subscription?.cancel();

  void _open(ClikgateDeepLink link) {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    final blocked = link.blockMessage;
    if (blocked != null) {
      // The link isn't available here (allowed countries or a block rule): say so, and don't route.
      ScaffoldMessenger.of(navigator.context).showSnackBar(SnackBar(content: Text(blocked)));
      return;
    }
    final page = pageFor(link);
    if (page != null) navigator.push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

/// The screen for a link's path, e.g. `/product/42`. Null keeps the user where they are.
Widget? pageFor(ClikgateDeepLink link) {
  final segments = Uri.parse(link.path ?? '/').pathSegments;
  if (segments.length == 2 && segments.first == 'product') return ProductScreen(productId: segments[1]);
  return null;
}

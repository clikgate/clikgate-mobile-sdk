import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;


import 'channel.dart';
import 'models.dart';

/// A broadcast stream that buffers items while nobody listens (latest
/// [capacity]) and replays them to the next (first) subscriber.
class _Replaying<T> {
  _Replaying(this.capacity);

  final int capacity;
  final Queue<T> _buffer = Queue<T>();
  late final StreamController<T> controller =
      StreamController<T>.broadcast(onListen: _replay);

  void add(T item) {
    if (controller.hasListener) {
      controller.add(item);
    } else {
      _buffer.addLast(item);
      while (_buffer.length > capacity) {
        _buffer.removeFirst();
      }
    }
  }

  void _replay() {
    while (_buffer.isNotEmpty) {
      controller.add(_buffer.removeFirst());
    }
  }

  Future<void> close() async {
    _buffer.clear();
    await controller.close();
  }
}

/// Receives deep links and browser handoffs from the native event channel
/// and exposes each as a broadcast
/// stream. Items that arrive while nobody listens are buffered (latest
/// [capacity]) and replayed to the next (first) subscriber.
class DeepLinkHub {
  DeepLinkHub({this.capacity = 10});

  final int capacity;
  StreamSubscription<dynamic>? _native;
  late final _Replaying<ClikgateDeepLink> _links =
      _Replaying<ClikgateDeepLink>(capacity);
  late final _Replaying<ClikgateBrowserHandoff> _handoffs =
      _Replaying<ClikgateBrowserHandoff>(capacity);

  Stream<ClikgateDeepLink> get stream {
    start();
    return _links.controller.stream;
  }

  Stream<ClikgateBrowserHandoff> get handoffs {
    start();
    return _handoffs.controller.stream;
  }

  /// Starts listening to the native side (which then flushes its own buffer).
  void start() {
    _native ??= ClikgateChannels.deepLinks.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) =>
          developer.log('deep link stream error: $e', name: 'Clikgate'),
    );
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final map = asStringMap(event);
    if (map['event'] == 'browserHandoff') {
      _handoffs.add(ClikgateBrowserHandoff.fromMap(map));
    } else {
      _links.add(ClikgateDeepLink.fromMap(map));
    }
  }

  /// Stops listening and drops buffered items.
  Future<void> dispose() async {
    await _native?.cancel();
    _native = null;
    await _links.close();
    await _handoffs.close();
  }
}

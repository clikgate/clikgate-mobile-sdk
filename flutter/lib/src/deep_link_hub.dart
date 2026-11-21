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

/// Passes on the events of a source stream, except that `cancel()` on a subscription returns a
/// future of the zone it was called in. A broadcast subscription's own `cancel()` returns a shared, already completed future of the
/// root zone: awaiting it inside a fake-async zone (such as a `testWidgets` body) resumes the
/// caller outside that zone, and the widget tester then waits forever at the next pump.
class _CancelInCallerZone<T> extends Stream<T> {
  _CancelInCallerZone(this._source);

  final Stream<T> _source;

  @override
  bool get isBroadcast => _source.isBroadcast;

  @override
  StreamSubscription<T> listen(void Function(T event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _CallerZoneSubscription<T>(_source.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError));
}

class _CallerZoneSubscription<T> implements StreamSubscription<T> {
  _CallerZoneSubscription(this._inner);

  final StreamSubscription<T> _inner;

  @override
  Future<void> cancel() {
    // The source is the hub's own broadcast controller (no onCancel), so there's nothing to wait
    // for: its cancel finishes synchronously.
    _inner.cancel();
    return Future<void>.value();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
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

  late final Stream<ClikgateDeepLink> _linkStream =
      _CancelInCallerZone<ClikgateDeepLink>(_links.controller.stream);
  late final Stream<ClikgateBrowserHandoff> _handoffStream =
      _CancelInCallerZone<ClikgateBrowserHandoff>(_handoffs.controller.stream);

  Stream<ClikgateDeepLink> get stream {
    start();
    return _linkStream;
  }

  Stream<ClikgateBrowserHandoff> get handoffs {
    start();
    return _handoffStream;
  }

  /// Starts listening to the native side (which then flushes its own buffer).
  void start() {
    _native ??= ClikgateChannels.deepLinks.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) =>
          developer.log('deep link stream error: $e', name: 'Clikgate'),
    );
  }

  /// Internal (`package:clikgate_flutter/testing.dart`): handles [event] as if it came from the
  /// native event channel, without the platform message round trip (so widget tests need no real
  /// async to see it).
  void deliverForTesting(Object? event) => _onEvent(event);

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final map = asStringMap(event);
    if (map['event'] == 'browserHandoff') {
      _handoffs.add(ClikgateBrowserHandoff.fromMap(map));
    } else {
      _links.add(ClikgateDeepLink.fromMap(map));
    }
  }

  /// Stops listening and drops buffered items; open subscriptions get their done event.
  ///
  /// The native `cancel` is sent synchronously, before this returns (so a test fake's channel
  /// handler that is removed right after still answers it), and the streams are closed in the
  /// caller's zone. The native subscription's cancel future isn't awaited: a broadcast
  /// subscription's cancel future belongs to the root zone (see [_CancelInCallerZone]).
  Future<void> dispose() {
    final native = _native;
    _native = null;
    unawaited(native?.cancel());
    return Future.wait<void>([_links.close(), _handoffs.close()]);
  }
}

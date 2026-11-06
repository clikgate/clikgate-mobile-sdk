/// Clikgate Flutter plugin (core): deep links, install attribution, events,
/// referee-side referrals and uninstall tracking over the native Clikgate
/// Android and iOS SDKs. Referrer-side features live in `clikgate_engage`.
library;

export 'src/clikgate.dart' show Clikgate;
export 'src/exception.dart';
export 'src/models.dart' hide asStringMap;
export 'src/provider.dart';
export 'src/referrals.dart';

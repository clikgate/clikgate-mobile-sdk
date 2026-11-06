/// Clikgate Engage add-on (optional, Dart over `clikgate_flutter`; the share
/// menu uses the native Engage add-on) for
/// apps without their own backend: the user's referral link and stats,
/// leaderboards, promo codes and share helpers.
///
/// Apps with a backend should call the Clikgate control-plane API from their
/// server instead (recommended path; see docs/engage.md).
library;

export 'src/client.dart' show EngageCore, ClikgateCoreBridge;
export 'src/engage.dart';
export 'src/errors.dart';
export 'src/models.dart' hide referralFromJson;
export 'src/share_app.dart';

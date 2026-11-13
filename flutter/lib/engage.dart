/// Clikgate Engage features (part of `clikgate_flutter` since 2.1.0; Dart, and
/// the share menu uses the native SDK's Engage features) for
/// apps without their own backend: the user's referral link and stats,
/// leaderboards, promo codes and share helpers.
///
/// Apps with a backend should call the Clikgate control-plane API from their
/// server instead (recommended path; see docs/engage.md).
library;

export 'src/engage/client.dart' show EngageCore, ClikgateCoreBridge;
export 'src/engage/engage.dart';
export 'src/engage/errors.dart';
export 'src/engage/models.dart' hide referralFromJson;
export 'src/engage/share_app.dart';

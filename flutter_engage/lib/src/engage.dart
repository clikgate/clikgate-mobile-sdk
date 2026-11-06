import 'dart:convert';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'errors.dart';
import 'models.dart';
import 'share_app.dart';

/// Opens [uri] in another app; true when it was opened.
typedef EngageUrlOpener = Future<bool> Function(Uri uri);

/// Presents the system share sheet with [text].
typedef EngageTextSharer = Future<void> Function(String text, {String? subject});

/// Hands a `share.link` call to the native Engage add-on; true when the app
/// itself opened.
typedef EngageLinkSharer = Future<bool> Function(Map<String, Object?> args);

/// The optional Clikgate Engage add-on for apps **without their own
/// backend**: the user's referral link and stats, leaderboards, promo codes
/// and share helpers.
///
/// Apps with a backend should call the Clikgate control-plane API from their
/// server instead and render their own screens (recommended path).
///
/// ```dart
/// final engage = ClikgateEngage();
/// final link = await engage.referrals.createLink(programId: 'rpg_...', displayName: 'Ada');
/// await engage.share.whatsApp(text: 'Join me on MyApp: ${link.url}');
/// ```
///
/// Calls need `Clikgate.configure` (core plugin) and a recorded install.
/// Every network call checks `Clikgate.isFeatureEnabled` first and throws
/// `ClikgateException(feature_disabled)` without a network call when the
/// feature is off. Calls acting for a user (link, stats, my rank, around
/// me, opt-out, hosted page) throw `not_identified` until `Clikgate.identifyUser`
/// was called; `identity_required` comes from the server when the program
/// needs a verified identity token. Reads are cached in memory for 60 s;
/// network errors are retried once. No UI components.
class ClikgateEngage {
  ClikgateEngage({
    http.Client? httpClient,
    EngageCore core = const ClikgateCoreBridge(),
    EngageUrlOpener? openUrl,
    EngageTextSharer? shareText,
    EngageLinkSharer? shareLink,
    Duration cacheTtl = const Duration(seconds: 60),
    Duration retryDelay = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  }) : this._(
          EngageClient(
              core: core,
              httpClient: httpClient,
              cacheTtl: cacheTtl,
              retryDelay: retryDelay,
              clock: clock),
          openUrl ?? _defaultOpenUrl,
          shareText ?? _defaultShareText,
          shareLink ?? _defaultShareLink,
        );

  ClikgateEngage._(this._client, EngageUrlOpener openUrl, EngageTextSharer shareText,
      EngageLinkSharer shareLink)
      : referrals = EngageReferrals._(_client),
        leaderboards = EngageLeaderboards._(_client),
        codes = EngageCodes._(_client),
        share = EngageShare._(openUrl, shareText, shareLink);

  final EngageClient _client;

  /// Version of this package.
  static const String version = '1.0.0';

  /// Referrer side: the user's link and stats (feature `referrals`).
  final EngageReferrals referrals;

  /// System share sheet and WhatsApp (no network).
  final EngageShare share;

  /// Leaderboards published to the SDK (feature `leaderboards`).
  final EngageLeaderboards leaderboards;

  /// Promo / offline codes typed in the app (feature `offline_codes`).
  final EngageCodes codes;

  /// Drops the in-memory read cache (e.g. on pull-to-refresh).
  void clearCache() => _client.clearCache();

  static Future<bool> _defaultOpenUrl(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static Future<void> _defaultShareText(String text, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  static const MethodChannel _channel = MethodChannel('com.clikgate/engage');

  static Future<bool> _defaultShareLink(Map<String, Object?> args) async =>
      await _channel.invokeMethod<bool>('shareLink', args) ?? false;
}

ClikgateException _invalid(String message, String param) =>
    ClikgateException(ClikgateException.invalidArgument, message, param: param);

void _requireId(String value, String param) {
  if (value.trim().isEmpty || value.contains('/')) {
    throw _invalid('$param is required', param);
  }
}

/// Referrer-side referral calls (`engage.referrals`).
class EngageReferrals {
  EngageReferrals._(this._client);
  final EngageClient _client;

  /// Gets or creates the current user's referral link and code. Needs
  /// `Clikgate.identifyUser`.
  Future<ReferralLink> createLink(
      {required String programId, String? displayName}) async {
    _requireId(programId, 'program_id');
    final j = await _client.call(
      feature: ClikgateFeatures.referrals,
      method: 'POST',
      path: '/v1/sdk/referrals/link',
      body: {'program_id': programId, if (displayName != null) 'display_name': displayName},
      needsUser: true,
      write: true,
    );
    return ReferralLink.fromJson(j);
  }

  /// The current user's code, link and counts (`referrer_not_found` if they
  /// have no link yet). Cached for 60 s.
  Future<ReferralStats> myStats({required String programId}) async {
    _requireId(programId, 'program_id');
    final j = await _client.call(
      feature: ClikgateFeatures.referrals,
      method: 'GET',
      path: '/v1/sdk/referrals/me',
      query: {'program_id': programId},
      needsUser: true,
      cacheable: true,
    );
    return ReferralStats.fromJson(j);
  }
}

/// Share helpers (`engage.share`). No feature check.
///
/// [link] / [referralLink] share a Clikgate link through the native Engage
/// add-on: each app Clikgate knows gets its own version of the link (a short
/// ending that tells Clikgate where it was shared), other apps the plain link,
/// and the share is recorded (the app and the link, no personal data; a share
/// count, never a click). [system] / [whatsApp] share plain text and record
/// nothing.
class EngageShare {
  EngageShare._(this._openUrl, this._shareText, this._shareLink);
  final EngageUrlOpener _openUrl;
  final EngageTextSharer _shareText;
  final EngageLinkSharer _shareLink;

  /// Shares a Clikgate link ([url], e.g. `https://inv.myapp.com/summer`) with
  /// an optional [message] in front of it.
  ///
  /// Without [app], opens the share menu; the app the person picks is
  /// recorded when the phone reports it. With [app], opens that app where the
  /// phone can, else the share menu. [shareUrls]: the link's `share_urls` from
  /// your backend (the Clikgate API's link object), used as they are. Returns
  /// true when [app] itself opened, false when the share menu was shown.
  /// Throws `ClikgateException(share_unavailable)` when nothing can share.
  Future<bool> link(String url,
          {String? message, ShareApp? app, Map<ShareApp, String>? shareUrls}) =>
      _call({
        'url': url,
        'message': message,
        'app': app?.value,
        if (shareUrls != null)
          'shareUrls': {for (final e in shareUrls.entries) e.key.value: e.value},
      });

  /// [link] for the user's referral link ([EngageReferrals.createLink]): each
  /// app's version keeps the referral code, so the referrer is still credited.
  Future<bool> referralLink(ReferralLink link, {String? message, ShareApp? app}) =>
      _call({
        'url': link.url,
        'code': link.code,
        'shortUrl': link.shortUrl,
        'message': message,
        'app': app?.value,
      });

  Future<bool> _call(Map<String, Object?> args) async {
    if ((args['url'] as String).trim().isEmpty) {
      throw _invalid('url is required', 'url');
    }
    try {
      return await _shareLink(args);
    } on PlatformException catch (e) {
      throw ClikgateException(e.code, e.message ?? e.code);
    }
  }

  /// Presents the system share sheet with [text].
  Future<void> system({required String text, String? subject}) async {
    try {
      await _shareText(text, subject: subject);
    } catch (e) {
      throw ClikgateException(ClikgateEngageErrors.shareUnavailable, 'Could not share: $e');
    }
  }

  /// Opens WhatsApp with [text] (`whatsapp://send?text=`); if WhatsApp can't
  /// be opened, presents the system share sheet. Returns true when WhatsApp
  /// itself was opened (url_launcher; no `canOpenURL` check, so no
  /// Info.plist entry is required).
  Future<bool> whatsApp({required String text}) async {
    var opened = false;
    try {
      opened = await _openUrl(whatsAppUri(text));
    } catch (_) {
      opened = false;
    }
    if (opened) return true;
    await system(text: text);
    return false;
  }

  /// `whatsapp://send?text=<text>`, percent-encoding everything except the
  /// RFC 3986 unreserved characters (so `&`, `=`, `+`, `#`, `?` and spaces in
  /// the text survive).
  static Uri whatsAppUri(String text) {
    final b = StringBuffer();
    for (final byte in utf8.encode(text)) {
      final unreserved = (byte >= 0x41 && byte <= 0x5A) || // A-Z
          (byte >= 0x61 && byte <= 0x7A) || // a-z
          (byte >= 0x30 && byte <= 0x39) || // 0-9
          byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E; // - . _ ~
      if (unreserved) {
        b.writeCharCode(byte);
      } else {
        b.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return Uri.parse('whatsapp://send?text=$b');
  }
}

/// Leaderboards published to the SDK (`engage.leaderboards`).
class EngageLeaderboards {
  EngageLeaderboards._(this._client);
  final EngageClient _client;

  static String _path(String id, [String suffix = '']) =>
      '/v1/sdk/leaderboards/${Uri.encodeComponent(id)}$suffix';

  /// Top entries of [leaderboardId] ([limit] clamped to 1..100). Does not
  /// need an identified user. Cached for 60 s.
  Future<LeaderboardPage> top(String leaderboardId,
      {LeaderboardPeriod period = LeaderboardPeriod.current,
      String? segment,
      int limit = 50}) async {
    _requireId(leaderboardId, 'leaderboard_id');
    final j = await _client.call(
      feature: ClikgateFeatures.leaderboards,
      method: 'GET',
      path: _path(leaderboardId),
      query: {
        'period': period.value,
        if (segment != null) 'segment': segment,
        'limit': '${limit.clamp(1, 100)}',
      },
      cacheable: true,
    );
    return LeaderboardPage.fromJson(j);
  }

  /// The current user's rank, score, pending count, gap to the next rank and
  /// period end (`rank` null while unranked). Cached for 60 s.
  Future<MyRank> me(String leaderboardId,
      {LeaderboardPeriod period = LeaderboardPeriod.current, String? segment}) async {
    _requireId(leaderboardId, 'leaderboard_id');
    final j = await _client.call(
      feature: ClikgateFeatures.leaderboards,
      method: 'GET',
      path: _path(leaderboardId, '/me'),
      query: {'period': period.value, if (segment != null) 'segment': segment},
      needsUser: true,
      cacheable: true,
    );
    return MyRank.fromJson(j);
  }

  /// Up to [radius] (1..25) entries above and below the current user; the
  /// user's entry has `isMe`. `name`/`metric`/`segment` are null. Cached for
  /// 60 s.
  Future<LeaderboardPage> aroundMe(String leaderboardId,
      {int radius = 5,
      LeaderboardPeriod period = LeaderboardPeriod.current,
      String? segment}) async {
    _requireId(leaderboardId, 'leaderboard_id');
    final j = await _client.call(
      feature: ClikgateFeatures.leaderboards,
      method: 'GET',
      path: _path(leaderboardId, '/around-me'),
      query: {
        'radius': '${radius.clamp(1, 25)}',
        'period': period.value,
        if (segment != null) 'segment': segment,
      },
      needsUser: true,
      cacheable: true,
    );
    return LeaderboardPage.fromJson(j);
  }

  /// Hides ([optOut] true) or shows the current user on every board of a
  /// referral program. Clears the read cache.
  Future<void> setOptOut({required String programId, required bool optOut}) async {
    _requireId(programId, 'program_id');
    await _client.call(
      feature: ClikgateFeatures.leaderboards,
      method: 'POST',
      path: '/v1/sdk/leaderboards/opt-out',
      body: {'program_id': programId, 'opt_out': optOut},
      needsUser: true,
      write: true,
    );
  }

  /// A short-lived signed URL of the hosted leaderboard page
  /// that highlights the current user, for a web view. Never cached. Throws
  /// `hosted_page_unavailable` when the server returns no `embed_url`.
  Future<Uri> hostedPageUrl(String leaderboardId,
      {LeaderboardPeriod period = LeaderboardPeriod.current}) async {
    _requireId(leaderboardId, 'leaderboard_id');
    final j = await _client.call(
      feature: ClikgateFeatures.leaderboards,
      method: 'GET',
      path: _path(leaderboardId, '/me'),
      query: {'period': period.value, 'embed': '1'},
      needsUser: true,
    );
    final url = j['embed_url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || !uri.hasScheme) {
      throw const ClikgateException(ClikgateEngageErrors.hostedPageUnavailable,
          'The server returned no hosted page URL (embed_url)');
    }
    return uri;
  }
}

/// Promo / offline code redemption (`engage.codes`).
class EngageCodes {
  EngageCodes._(this._client);
  final EngageClient _client;

  /// Redeems [code] (3-30 characters after trimming; case-insensitive,
  /// spaces and dashes ignored server-side). Errors: `code_not_found`,
  /// `code_expired`, `code_disabled`, `redemption_limit_reached`,
  /// `rate_limited`, and for referral codes the referral errors of
  /// `applyCode` with `ClikgateException.offlineTouchId` set. Clears the
  /// read cache.
  Future<Redemption> redeem(String code) async {
    final trimmed = code.trim();
    if (trimmed.length < 3 || trimmed.length > 30) {
      throw _invalid('The code must be 3-30 characters', 'code');
    }
    final j = await _client.call(
      feature: ClikgateFeatures.offlineCodes,
      method: 'POST',
      path: '/v1/sdk/codes/redeem',
      body: {'code': trimmed},
      write: true,
    );
    return Redemption.fromJson(j);
  }
}

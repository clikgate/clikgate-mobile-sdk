import { ClikgateError } from '../../index';

import { encodeRfc3986 } from '../../engage/client';
import { ClikgateEngage, EngageErrorCodes } from '../../engage/index';
import { VERSION } from '../../engage/version';
import { BASE, fixture, fixtureText, rig } from './harness';

const PROGRAM = 'rpg_01JAB3C4D5E6F7G8H9JKMNPQRS';
const BOARD = 'lb_01JAB3C4D5E6F7G8H9JKMNPQRS';
const ok = (body: string) => ({ status: 200, body });
const err = (status: number, body: string) => ({ status, body });

describe('referrals', () => {
  it('createLink posts program_id/display_name with the context headers', async () => {
    const r = rig();
    r.on(
      'POST /v1/sdk/referrals/link',
      ok(fixtureText('referral_link_response'))
    );
    const link = await r.engage.referrals.createLink({
      programId: PROGRAM,
      displayName: 'Ada',
    });
    expect(link).toEqual({
      referrerId: 'rfr_01JAB3C4D5E6F7G8H9JKMNPQRS',
      programId: PROGRAM,
      code: 'ADA42X',
      url: 'https://inv.myapp.com/r/ADA42X',
      shortUrl: 'https://inv.myapp.com/a8K2bq',
    });
    const call = r.calls[0]!;
    expect(call.url).toBe(`${BASE}/v1/sdk/referrals/link`);
    expect(JSON.parse(call.body!)).toEqual({
      program_id: PROGRAM,
      display_name: 'Ada',
    });
    expect(call.headers).toEqual({
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      'Clikgate-SDK-Key': 'cg_sdk_test_abc',
      'Clikgate-SDK-Version': 'react-native/1.0.0',
      'Clikgate-SDK-Native-Version': 'android/1.0.0',
      'Clikgate-Installation-Id': '6a1f0c2e-0000-4000-8000-000000000001',
      'Clikgate-Identity-Token': 'sig.1760954400',
    });
    expect(r.core.isFeatureEnabled).toHaveBeenCalledWith('referrals');
  });

  it('omits identity token / native version headers when the context has none', async () => {
    const r = rig({ ctx: { identityToken: null, nativeSdkVersion: null } });
    r.on(
      'POST /v1/sdk/referrals/link',
      ok(fixtureText('referral_link_response'))
    );
    await r.engage.referrals.createLink({ programId: PROGRAM });
    expect(r.calls[0]!.headers['Clikgate-Identity-Token']).toBeUndefined();
    expect(r.calls[0]!.headers['Clikgate-SDK-Native-Version']).toBeUndefined();
    expect(JSON.parse(r.calls[0]!.body!)).toEqual({ program_id: PROGRAM });
  });

  it('myStats decodes the fixture and sends program_id', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/referrals/me',
      ok(fixtureText('referral_stats_response'))
    );
    const s = await r.engage.referrals.myStats({ programId: PROGRAM });
    expect(s).toMatchObject({
      clicks: 12,
      installs: 4,
      signups: 3,
      inProgress: 1,
      qualified: 2,
      disqualified: 0,
      rejected: 1,
      status: 'active',
    });
    expect(r.calls[0]!.url).toBe(
      `${BASE}/v1/sdk/referrals/me?program_id=${PROGRAM}`
    );
  });

  it('rejects a blank programId without any call', async () => {
    const r = rig();
    await expect(
      r.engage.referrals.createLink({ programId: ' ' })
    ).rejects.toMatchObject({ code: 'invalid_argument', param: 'programId' });
    await expect(
      r.engage.referrals.myStats({ programId: '' })
    ).rejects.toBeInstanceOf(ClikgateError);
    expect(r.fetch).not.toHaveBeenCalled();
  });
});

describe('17A.3 rules', () => {
  it('feature switched off: feature_disabled without context or network', async () => {
    const r = rig({
      features: { referrals: false, leaderboards: false, offline_codes: false },
    });
    const calls: Array<[Promise<unknown>, string]> = [
      [r.engage.referrals.createLink({ programId: PROGRAM }), 'referrals'],
      [r.engage.referrals.myStats({ programId: PROGRAM }), 'referrals'],
      [r.engage.leaderboards.top(BOARD), 'leaderboards'],
      [r.engage.leaderboards.me(BOARD), 'leaderboards'],
      [r.engage.leaderboards.aroundMe(BOARD), 'leaderboards'],
      [
        r.engage.leaderboards.setOptOut({ programId: PROGRAM, optOut: true }),
        'leaderboards',
      ],
      [r.engage.leaderboards.hostedPageUrl(BOARD), 'leaderboards'],
      [r.engage.codes.redeem('LAGOS50'), 'offline_codes'],
    ];
    for (const [p, feature] of calls) {
      const e = await p.catch((x) => x);
      expect(e).toBeInstanceOf(ClikgateError);
      expect(e).toMatchObject({
        code: 'feature_disabled',
        feature,
        status: null,
      });
    }
    expect(r.fetch).not.toHaveBeenCalled();
    expect(r.core.getRequestContext).not.toHaveBeenCalled();
  });

  it('user calls fail with not_identified before identify (no network); top and redeem do not need it', async () => {
    const r = rig({ ctx: { customerUserId: null, identityToken: null } });
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD,
      ok(fixtureText('leaderboard_page'))
    );
    r.on(
      'POST /v1/sdk/codes/redeem',
      ok(fixtureText('code_redemption_response'))
    );
    for (const p of [
      r.engage.referrals.createLink({ programId: PROGRAM }),
      r.engage.referrals.myStats({ programId: PROGRAM }),
      r.engage.leaderboards.me(BOARD),
      r.engage.leaderboards.aroundMe(BOARD),
      r.engage.leaderboards.setOptOut({ programId: PROGRAM, optOut: false }),
      r.engage.leaderboards.hostedPageUrl(BOARD),
    ]) {
      await expect(p).rejects.toMatchObject({ code: 'not_identified' });
    }
    expect(r.fetch).not.toHaveBeenCalled();
    await r.engage.leaderboards.top(BOARD);
    await r.engage.codes.redeem('LAGOS50');
    expect(r.fetch).toHaveBeenCalledTimes(2);
  });

  it('context errors from the core propagate (install_pending, opted_out, not_configured)', async () => {
    const r = rig({
      contextError: new ClikgateError('install_pending', 'not yet'),
    });
    await expect(r.engage.leaderboards.top(BOARD)).rejects.toMatchObject({
      code: 'install_pending',
    });
    expect(r.fetch).not.toHaveBeenCalled();
  });

  it('caches reads for 60 s, keyed by user; writes clear the cache', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD,
      ok(fixtureText('leaderboard_page'))
    );
    r.on(
      'POST /v1/sdk/leaderboards/opt-out',
      ok(`{"program_id":"${PROGRAM}","opt_out":true}`)
    );
    const a = await r.engage.leaderboards.top(BOARD);
    const b = await r.engage.leaderboards.top(BOARD);
    expect(b).toBe(a);
    expect(r.fetch).toHaveBeenCalledTimes(1);
    // A different query is a different entry.
    await r.engage.leaderboards.top(BOARD, { limit: 10 });
    expect(r.fetch).toHaveBeenCalledTimes(2);
    r.advance(59_999);
    await r.engage.leaderboards.top(BOARD);
    expect(r.fetch).toHaveBeenCalledTimes(2);
    r.advance(2);
    await r.engage.leaderboards.top(BOARD);
    expect(r.fetch).toHaveBeenCalledTimes(3);
    // A write clears everything.
    await r.engage.leaderboards.setOptOut({ programId: PROGRAM, optOut: true });
    await r.engage.leaderboards.top(BOARD);
    expect(r.fetch).toHaveBeenCalledTimes(5);
    // clearCache()
    r.engage.clearCache();
    await r.engage.leaderboards.top(BOARD);
    expect(r.fetch).toHaveBeenCalledTimes(6);
  });

  it("a different user does not get the previous user's cached read", async () => {
    let user = 'user_42';
    const r = rig();
    r.core.getRequestContext.mockImplementation(async () => ({
      installationId: 'i',
      sdkKey: 'k',
      environment: 'production',
      apiBaseUrl: BASE,
      identityToken: null,
      customerUserId: user,
      sdkVersion: 'react-native/1.0.0',
      nativeSdkVersion: null,
    }));
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD + '/me',
      ok(fixtureText('my_rank'))
    );
    await r.engage.leaderboards.me(BOARD);
    user = 'user_43';
    await r.engage.leaderboards.me(BOARD);
    expect(r.fetch).toHaveBeenCalledTimes(2);
  });

  it('failed reads are not cached', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/referrals/me',
      err(404, '{"error":{"code":"referrer_not_found","message":"none"}}'),
      ok(fixtureText('referral_stats_response'))
    );
    await expect(
      r.engage.referrals.myStats({ programId: PROGRAM })
    ).rejects.toMatchObject({ code: 'referrer_not_found', status: 404 });
    await expect(
      r.engage.referrals.myStats({ programId: PROGRAM })
    ).resolves.toMatchObject({ clicks: 12 });
  });

  it('retries a network error once, then succeeds', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD,
      new TypeError('Network request failed'),
      ok(fixtureText('leaderboard_page'))
    );
    await expect(r.engage.leaderboards.top(BOARD)).resolves.toMatchObject({
      leaderboardId: BOARD,
    });
    expect(r.fetch).toHaveBeenCalledTimes(2);
  });

  it('gives up after one retry with network_error', async () => {
    const r = rig();
    r.on('GET /v1/sdk/leaderboards/' + BOARD, new TypeError('offline'));
    await expect(r.engage.leaderboards.top(BOARD)).rejects.toMatchObject({
      code: 'network_error',
    });
    expect(r.fetch).toHaveBeenCalledTimes(2);
  });

  it.each([429, 500, 503])('does not retry HTTP %i', async (status) => {
    const r = rig();
    r.on('POST /v1/sdk/codes/redeem', err(status, ''));
    const e = await r.engage.codes.redeem('LAGOS50').catch((x) => x);
    expect(e).toMatchObject({
      code: status === 429 ? 'rate_limited' : 'server_error',
      status,
    });
    expect(r.fetch).toHaveBeenCalledTimes(1);
  });

  it('times out an attempt (timeout code) and retries once', async () => {
    jest.useFakeTimers();
    try {
      const r = rig();
      r.fetch.mockImplementation(
        (_u: string, init: { signal?: AbortSignal }) =>
          new Promise((_res, rej) =>
            init.signal?.addEventListener('abort', () =>
              rej(new Error('Aborted'))
            )
          ) as never
      );
      const engage = new ClikgateEngage({
        core: r.core,
        fetch: r.fetch,
        timeoutMs: 50,
        retryDelayMs: 0,
      });
      const p = engage.leaderboards.top(BOARD).catch((x) => x);
      await jest.advanceTimersByTimeAsync(200);
      expect(await p).toMatchObject({ code: 'timeout' });
      expect(r.fetch).toHaveBeenCalledTimes(2);
    } finally {
      jest.useRealTimers();
    }
  });

  it('feature_disabled body: reported to the core, typed error, not cached', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD,
      ok(fixtureText('feature_disabled'))
    );
    await expect(r.engage.leaderboards.top(BOARD)).rejects.toMatchObject({
      code: 'feature_disabled',
      feature: 'leaderboards',
    });
    expect(r.core.reportServerError).toHaveBeenCalledWith(
      'feature_disabled',
      'leaderboards'
    );
    // The body without its own feature: the method's feature.
    r.on(
      'POST /v1/sdk/codes/redeem',
      ok('{"accepted":false,"reason":"feature_disabled"}')
    );
    await expect(r.engage.codes.redeem('LAGOS50')).rejects.toMatchObject({
      code: 'feature_disabled',
      feature: 'offline_codes',
    });
    expect(r.core.reportServerError).toHaveBeenLastCalledWith(
      'feature_disabled',
      'offline_codes'
    );
  });

  it.each(['invalid_sdk_key', 'sdk_disabled', 'installation_unknown'])(
    'reports the global error %s to the core',
    async (code) => {
      const r = rig();
      r.on(
        'GET /v1/sdk/leaderboards/' + BOARD,
        err(
          code === 'installation_unknown' ? 404 : 403,
          `{"error":{"code":"${code}","message":"x"}}`
        )
      );
      await expect(r.engage.leaderboards.top(BOARD)).rejects.toMatchObject({
        code,
      });
      expect(r.core.reportServerError).toHaveBeenCalledWith(code, null);
    }
  );

  it('backend errors keep status, param, message and offlineTouchId; not reported', async () => {
    const r = rig();
    r.on(
      'POST /v1/sdk/codes/redeem',
      err(409, fixtureText('error_code_expired'))
    );
    const e = await r.engage.codes.redeem('LAGOS50').catch((x) => x);
    expect(e).toBeInstanceOf(ClikgateError);
    expect(e).toMatchObject({
      code: EngageErrorCodes.codeExpired,
      status: 409,
      param: 'code',
      message: 'This code has expired.',
      feature: null,
    });
    r.on(
      'POST /v1/sdk/codes/redeem',
      err(
        422,
        '{"error":{"code":"self_referral","message":"own code","offline_touch_id":"oft_9"}}'
      )
    );
    await expect(r.engage.codes.redeem('ADA42X')).rejects.toMatchObject({
      code: 'self_referral',
      offlineTouchId: 'oft_9',
    });
    expect(r.core.reportServerError).not.toHaveBeenCalled();
  });

  it('identity_required from the server is a typed error', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD + '/me',
      err(403, '{"error":{"code":"identity_required","message":"token"}}')
    );
    await expect(r.engage.leaderboards.me(BOARD)).rejects.toMatchObject({
      code: 'identity_required',
      status: 403,
    });
  });

  it('a non-JSON 2xx body is server_error', async () => {
    const r = rig();
    r.on('GET /v1/sdk/leaderboards/' + BOARD, ok('<html>'));
    await expect(r.engage.leaderboards.top(BOARD)).rejects.toMatchObject({
      code: 'server_error',
      status: 200,
    });
  });
});

describe('leaderboards', () => {
  it('top decodes the fixture; default period/limit; clamps the limit', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD,
      ok(fixtureText('leaderboard_page'))
    );
    const page = await r.engage.leaderboards.top(BOARD);
    const f = fixture('leaderboard_page') as {
      entries: unknown[];
      name: string;
    };
    expect(page.name).toBe(f.name);
    expect(page.entries).toHaveLength(f.entries.length);
    expect(page.period.startsAt?.toISOString()).toBe(
      '2026-10-19T23:00:00.000Z'
    );
    expect(r.calls[0]!.url).toBe(
      `${BASE}/v1/sdk/leaderboards/${BOARD}?period=current&limit=50`
    );
    await r.engage.leaderboards.top(BOARD, {
      period: '2026-W42',
      segment: 'Lagos & Abuja',
      limit: 500,
    });
    expect(r.calls[1]!.url).toBe(
      `${BASE}/v1/sdk/leaderboards/${BOARD}?period=2026-W42&segment=Lagos%20%26%20Abuja&limit=100`
    );
  });

  it('me decodes my_rank', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD + '/me',
      ok(fixtureText('my_rank'))
    );
    await expect(r.engage.leaderboards.me(BOARD)).resolves.toEqual({
      leaderboardId: BOARD,
      period: {
        key: '2026-W43',
        status: 'open',
        startsAt: new Date('2026-10-19T23:00:00Z'),
        endsAt: new Date('2026-10-26T23:00:00Z'),
      },
      referrerId: 'rfr_01JAB3C4D5E6F7G8H9JKMNPQRT',
      rank: 2,
      score: 9,
      pending: 0,
      gapToNext: 3,
      bestRank: 2,
      periodEndsAt: new Date('2026-10-26T23:00:00Z'),
      optedOut: false,
    });
    expect(r.calls[0]!.url).toBe(
      `${BASE}/v1/sdk/leaderboards/${BOARD}/me?period=current`
    );
  });

  it('aroundMe: radius default 5, clamped to 1..25, name/metric null', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD + '/around-me',
      ok(
        `{"leaderboard_id":"${BOARD}","period":{"key":"2026-W43","status":"open"},"entries":[{"rank":3,"referrer_id":"r","display":"You","score":7,"is_me":true}]}`
      )
    );
    const page = await r.engage.leaderboards.aroundMe(BOARD);
    expect(page).toMatchObject({
      name: null,
      metric: null,
      segment: null,
      entries: [{ rank: 3, isMe: true, pending: null }],
    });
    await r.engage.leaderboards.aroundMe(BOARD, { radius: 0 });
    expect(r.calls.map((c) => c.url)).toEqual([
      `${BASE}/v1/sdk/leaderboards/${BOARD}/around-me?radius=5&period=current`,
      `${BASE}/v1/sdk/leaderboards/${BOARD}/around-me?radius=1&period=current`,
    ]);
  });

  it('setOptOut posts program_id/opt_out', async () => {
    const r = rig();
    r.on(
      'POST /v1/sdk/leaderboards/opt-out',
      ok(`{"program_id":"${PROGRAM}","opt_out":false}`)
    );
    await expect(
      r.engage.leaderboards.setOptOut({ programId: PROGRAM, optOut: false })
    ).resolves.toBeUndefined();
    expect(JSON.parse(r.calls[0]!.body!)).toEqual({
      program_id: PROGRAM,
      opt_out: false,
    });
  });

  it('hostedPageUrl returns embed_url from /me?embed=1 and is never cached', async () => {
    const r = rig();
    const body = {
      ...fixture('my_rank'),
      embed_token: 'tok',
      embed_url: 'https://inv.myapp.com/leaderboard/lb_1?me=tok',
    };
    r.on('GET /v1/sdk/leaderboards/' + BOARD + '/me', ok(JSON.stringify(body)));
    await expect(r.engage.leaderboards.hostedPageUrl(BOARD)).resolves.toBe(
      'https://inv.myapp.com/leaderboard/lb_1?me=tok'
    );
    await r.engage.leaderboards.hostedPageUrl(BOARD);
    expect(r.fetch).toHaveBeenCalledTimes(2);
    expect(r.calls[0]!.url).toBe(
      `${BASE}/v1/sdk/leaderboards/${BOARD}/me?period=current&embed=1`
    );
  });

  it('hostedPageUrl: hosted_page_unavailable without embed_url (older server)', async () => {
    const r = rig();
    r.on(
      'GET /v1/sdk/leaderboards/' + BOARD + '/me',
      ok(fixtureText('my_rank'))
    );
    await expect(
      r.engage.leaderboards.hostedPageUrl(BOARD)
    ).rejects.toMatchObject({ code: 'hosted_page_unavailable' });
  });

  it('rejects an empty or path-like leaderboard id', async () => {
    const r = rig();
    await expect(r.engage.leaderboards.top('')).rejects.toMatchObject({
      code: 'invalid_argument',
    });
    await expect(r.engage.leaderboards.me('a/b')).rejects.toMatchObject({
      code: 'invalid_argument',
    });
    expect(r.fetch).not.toHaveBeenCalled();
  });
});

describe('codes.redeem', () => {
  it('sends the trimmed code and decodes the redemption', async () => {
    const r = rig();
    r.on(
      'POST /v1/sdk/codes/redeem',
      ok(fixtureText('code_redemption_response'))
    );
    const f = fixture('code_redemption_response') as {
      offline_touch_id: string;
    };
    const red = await r.engage.codes.redeem('  lagos50 ');
    expect(red.offlineTouchId).toBe(f.offline_touch_id);
    expect(JSON.parse(r.calls[0]!.body!)).toEqual({ code: 'lagos50' });
  });

  it('decodes a referral-code redemption', async () => {
    const r = rig();
    r.on(
      'POST /v1/sdk/codes/redeem',
      ok(
        JSON.stringify({
          offline_touch_id: 'oft_1',
          code: {
            code: 'ADA42X',
            kind: 'referral',
            link_id: null,
            campaign_id: null,
            referrer_id: 'rfr_1',
            program_id: PROGRAM,
          },
          referral: { ...fixture('referral'), source: 'offline_code' },
        })
      )
    );
    const red = await r.engage.codes.redeem('ADA42X');
    expect(red.code).toEqual({
      code: 'ADA42X',
      kind: 'referral',
      linkId: null,
      campaignId: null,
      referrerId: 'rfr_1',
      programId: PROGRAM,
    });
    expect(red.referral).toMatchObject({
      source: 'offline_code',
      referralId: 'ref_01JAB3C4D5E6F7G8H9JKMNPQRS',
    });
    expect(red.referral?.createdAt).toBeInstanceOf(Date);
  });

  it.each(['', 'ab', 'x'.repeat(31)])('rejects %p locally', async (code) => {
    const r = rig();
    await expect(r.engage.codes.redeem(code)).rejects.toMatchObject({
      code: 'invalid_argument',
      param: 'code',
    });
    expect(r.core.isFeatureEnabled).not.toHaveBeenCalled();
  });
});

describe('share', () => {
  it('whatsApp opens whatsapp://send with RFC 3986 encoding', async () => {
    const r = rig();
    await expect(
      r.engage.share.whatsApp({
        text: "Join me: https://x.y/r/A?b=1&c=2 (it's #1!)",
      })
    ).resolves.toBe(true);
    expect(r.linking.openURL).toHaveBeenCalledWith(
      'whatsapp://send?text=Join%20me%3A%20https%3A%2F%2Fx.y%2Fr%2FA%3Fb%3D1%26c%3D2%20%28it%27s%20%231%21%29'
    );
    expect(r.shareSheet.share).not.toHaveBeenCalled();
    expect(r.fetch).not.toHaveBeenCalled();
  });

  it('whatsApp falls back to the share sheet when WhatsApp cannot be opened', async () => {
    const r = rig();
    r.linking.openURL.mockRejectedValueOnce(new Error('Unable to open URL'));
    await expect(r.engage.share.whatsApp({ text: 'hi' })).resolves.toBe(false);
    expect(r.shareSheet.share).toHaveBeenCalledWith({ message: 'hi' });
  });

  it('system shows the share sheet; share_unavailable when it fails', async () => {
    const r = rig();
    await r.engage.share.system({ text: 'hi', title: 'Invite' });
    expect(r.shareSheet.share).toHaveBeenCalledWith({
      message: 'hi',
      title: 'Invite',
    });
    r.shareSheet.share.mockRejectedValueOnce(new Error('no activity'));
    await expect(r.engage.share.system({ text: 'hi' })).rejects.toMatchObject({
      code: 'share_unavailable',
    });
    r.linking.openURL.mockRejectedValueOnce(new Error('x'));
    r.shareSheet.share.mockRejectedValueOnce(new Error('no activity'));
    await expect(r.engage.share.whatsApp({ text: 'hi' })).rejects.toMatchObject(
      { code: 'share_unavailable' }
    );
  });

  it('share helpers are not feature-gated', async () => {
    const r = rig({ features: { referrals: false } });
    await expect(r.engage.share.whatsApp({ text: 'hi' })).resolves.toBe(true);
    expect(r.core.isFeatureEnabled).not.toHaveBeenCalled();
  });
});

describe('misc', () => {
  it('encodeRfc3986 keeps only unreserved characters', () => {
    expect(encodeRfc3986("a-b_c.d~e !*'()&=+#?/")).toBe(
      'a-b_c.d~e%20%21%2A%27%28%29%26%3D%2B%23%3F%2F'
    );
  });

  it('VERSION matches package.json', () => {
    expect(VERSION).toBe(require('../../../package.json').version);
    expect(ClikgateEngage.version).toBe(VERSION);
    expect(ClikgateEngage.cacheTtlMs).toBe(60_000);
  });

  it('defaults to the core Clikgate object (rejects unsupported_platform without native)', async () => {
    const engage = new ClikgateEngage({ fetch: jest.fn() });
    await expect(engage.leaderboards.top(BOARD)).rejects.toMatchObject({
      code: 'unsupported_platform',
    });
  });
});

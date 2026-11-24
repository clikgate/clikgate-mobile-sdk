import type { ClikgateRequestContext } from '../../index';

import { ClikgateEngage } from '../../engage/index';
import { BASE, context, fixture, fixtureText } from './harness';

const PROGRAM = 'rpg_01JAB3C4D5E6F7G8H9JKMNPQRS';
const ME = 'GET /v1/sdk/referrals/me';
type Reply = { status: number; body: string };
const ok = (body: string): Reply => ({ status: 200, body });
const err = (status: number, code: string): Reply => ({
  status,
  body: JSON.stringify({
    error: { type: 'invalid_request', code, message: 'x' },
  }),
});

/** Fake core (the waiting context can be held), scripted fetch, saved links kept per customer. */
function setup() {
  const state = {
    userId: 'user_42' as string | null,
    token: 'sig.1760954400' as string | null,
    features: {} as Record<string, boolean>,
    hold: null as Promise<void> | null,
    clock: 1_000_000,
  };
  let release = () => {};
  const waits: Array<boolean> = [];
  const replies: Reply[] = [];
  const calls: Array<{ key: string; headers: Record<string, string> }> = [];
  const saved = new Map<string, { owner: string; link: unknown }>();
  const core = {
    isFeatureEnabled: jest.fn(
      async (key: string) => state.features[key] ?? true
    ),
    getRequestContext: jest.fn(
      async (options?: { wait?: boolean }): Promise<ClikgateRequestContext> => {
        const wait = options?.wait !== false;
        waits.push(wait);
        if (wait && state.hold) await state.hold;
        return context({
          customerUserId: state.userId,
          identityToken: state.token,
        });
      }
    ),
    reportServerError: jest.fn(
      async (_code: string, _feature?: string | null) => {}
    ),
  };
  const engage = new ClikgateEngage({
    core,
    fetch: async (url, init) => {
      calls.push({
        key: `${init.method} ${url.replace(BASE, '').split('?')[0]}`,
        headers: init.headers,
      });
      const r = replies.length > 1 ? replies.shift()! : replies[0]!;
      return { status: r.status, text: async () => r.body };
    },
    now: () => state.clock,
    retryDelayMs: 0,
    savedLinks: {
      saved: async (programId) => {
        const e = saved.get(programId);
        return {
          link: e != null && e.owner === state.userId ? e.link : null,
          token: state.userId,
        };
      },
      save: async (programId, link, token) => {
        if (token === state.userId)
          saved.set(programId, { owner: token, link });
      },
    },
  });
  return {
    engage,
    core,
    state,
    replies,
    calls,
    saved,
    waits,
    me: () => calls.filter((c) => c.key === ME),
    holdWaiting() {
      state.hold = new Promise<void>((r) => {
        release = r;
      });
    },
    release: () => release(),
  };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe('myStats without waiting', () => {
  it('is sent at once with the customer header while the install is pending', async () => {
    const t = setup();
    t.holdWaiting();
    t.state.userId = "usér 42/%(x)!*'";
    t.replies.push(ok(fixtureText('referral_stats_response')));
    const s = await t.engage.referrals.myStats({ programId: PROGRAM });
    expect(s.code).toBe('ADA42X');
    expect(t.me()[0]!.headers['Clikgate-Customer-User-Id']).toBe(
      'us%C3%A9r%2042%2F%25%28x%29%21%2A%27'
    );
    expect(t.me()[0]!.headers['Clikgate-Identity-Token']).toBe(
      'sig.1760954400'
    );
    expect(t.waits).toEqual([false]);
  });

  it('keeps the 60 s cache per customer', async () => {
    const t = setup();
    t.replies.push(ok(fixtureText('referral_stats_response')));
    await t.engage.referrals.myStats({ programId: PROGRAM });
    await t.engage.referrals.myStats({ programId: PROGRAM });
    expect(t.me()).toHaveLength(1);
    t.state.userId = 'user_43';
    await t.engage.referrals.myStats({ programId: PROGRAM });
    expect(t.me()).toHaveLength(2);
    expect(t.me()[1]!.headers['Clikgate-Customer-User-Id']).toBe('user_43');
  });

  it.each([
    ['installation_unknown', 404],
    ['not_identified', 403],
  ])('falls back once through the waiting path on %s', async (code, status) => {
    const t = setup();
    t.replies.push(
      err(status, code),
      ok(fixtureText('referral_stats_response'))
    );
    t.holdWaiting();
    const p = t.engage.referrals.myStats({ programId: PROGRAM });
    await flush();
    expect(t.waits).toEqual([false, true]);
    expect(t.me()).toHaveLength(1);
    t.release();
    await p;
    expect(t.me()).toHaveLength(2);
    expect(t.me()[0]!.headers['Clikgate-Customer-User-Id']).toBe('user_42');
    expect(t.me()[1]!.headers['Clikgate-Customer-User-Id']).toBeUndefined();
    expect(t.core.reportServerError).not.toHaveBeenCalled();
  });

  it('falls back only once', async () => {
    const t = setup();
    t.replies.push(err(403, 'not_identified'));
    await expect(
      t.engage.referrals.myStats({ programId: PROGRAM })
    ).rejects.toMatchObject({ code: 'not_identified' });
    expect(t.me()).toHaveLength(2);
  });

  it('returns other errors as they are', async () => {
    const t = setup();
    t.replies.push(err(422, 'identity_invalid'));
    await expect(
      t.engage.referrals.myStats({ programId: PROGRAM })
    ).rejects.toMatchObject({ code: 'identity_invalid' });
    expect(t.me()).toHaveLength(1);
    expect(t.waits).toEqual([false]);
  });

  it('waits as before without a token', async () => {
    const t = setup();
    t.state.token = null;
    t.replies.push(ok(fixtureText('referral_stats_response')));
    t.holdWaiting();
    const p = t.engage.referrals.myStats({ programId: PROGRAM });
    await flush();
    expect(t.calls).toHaveLength(0);
    t.release();
    await p;
    expect(t.me()[0]!.headers['Clikgate-Customer-User-Id']).toBeUndefined();
  });

  it('createLink keeps waiting', async () => {
    const t = setup();
    t.replies.push(ok(fixtureText('referral_link_response')));
    await t.engage.referrals.createLink({ programId: PROGRAM });
    expect(t.waits).toEqual([true]);
    expect(t.calls[0]!.headers['Clikgate-Customer-User-Id']).toBeUndefined();
  });
});

describe('myLink', () => {
  it('fetches the first time without waiting and saves only the link fields', async () => {
    const t = setup();
    t.holdWaiting();
    t.replies.push(ok(fixtureText('referral_stats_response')));
    const link = await t.engage.referrals.myLink({ programId: PROGRAM });
    expect(link).toEqual({
      referrerId: 'rfr_01JAB3C4D5E6F7G8H9JKMNPQRS',
      programId: PROGRAM,
      code: 'ADA42X',
      url: 'https://inv.myapp.com/r/ADA42X',
      shortUrl: 'https://inv.myapp.com/a8K2bq',
    });
    expect(t.me()[0]!.headers['Clikgate-Customer-User-Id']).toBe('user_42');
    expect(t.saved.get(PROGRAM)!.link).toEqual(
      fixture('referral_link_response')
    );
  });

  it('answers the saved link with no network, then refreshes at most once a minute', async () => {
    const t = setup();
    t.saved.set(PROGRAM, {
      owner: 'user_42',
      link: fixture('referral_link_response'),
    });
    t.replies.push({ status: 503, body: '' });
    const link = await t.engage.referrals.myLink({ programId: PROGRAM });
    expect(link.code).toBe('ADA42X');
    await flush();
    expect(t.me()).toHaveLength(1);
    await t.engage.referrals.myLink({ programId: PROGRAM });
    await flush();
    expect(t.me()).toHaveLength(1);
    t.state.clock += 60_000;
    await t.engage.referrals.myLink({ programId: PROGRAM });
    await flush();
    expect(t.me()).toHaveLength(2);
  });

  it('a background refresh updates a changed url', async () => {
    const t = setup();
    t.saved.set(PROGRAM, {
      owner: 'user_42',
      link: fixture('referral_link_response'),
    });
    t.replies.push(
      ok(
        JSON.stringify({
          ...fixture('referral_stats_response'),
          url: 'https://go.myapp.com/r/ADA42X',
          short_url: 'https://go.myapp.com/a8K2bq',
        })
      )
    );
    const first = await t.engage.referrals.myLink({ programId: PROGRAM });
    expect(first.url).toBe('https://inv.myapp.com/r/ADA42X');
    await flush();
    const next = await t.engage.referrals.myLink({ programId: PROGRAM });
    expect(next.url).toBe('https://go.myapp.com/r/ADA42X');
    expect(next.shortUrl).toBe('https://go.myapp.com/a8K2bq');
  });

  it('keeps saved links per customer', async () => {
    const t = setup();
    t.saved.set(PROGRAM, {
      owner: 'user_42',
      link: fixture('referral_link_response'),
    });
    t.state.userId = 'user_77';
    t.replies.push(err(404, 'referrer_not_found'));
    await expect(
      t.engage.referrals.myLink({ programId: PROGRAM })
    ).rejects.toMatchObject({ code: 'referrer_not_found' });
    expect(t.me()[0]!.headers['Clikgate-Customer-User-Id']).toBe('user_77');
  });

  it('fails with not_identified without a customer, with no network and no wait', async () => {
    const t = setup();
    t.state.userId = null;
    t.state.token = null;
    t.holdWaiting();
    await expect(
      t.engage.referrals.myLink({ programId: PROGRAM })
    ).rejects.toMatchObject({ code: 'not_identified' });
    expect(t.calls).toHaveLength(0);
    expect(t.waits).toEqual([false]);
  });

  it('checks the feature switch first', async () => {
    const t = setup();
    t.saved.set(PROGRAM, {
      owner: 'user_42',
      link: fixture('referral_link_response'),
    });
    t.state.features.referrals = false;
    await expect(
      t.engage.referrals.myLink({ programId: PROGRAM })
    ).rejects.toMatchObject({ code: 'feature_disabled' });
    expect(t.calls).toHaveLength(0);
  });

  it('myStats saves the link', async () => {
    const t = setup();
    t.replies.push(ok(fixtureText('referral_stats_response')));
    await t.engage.referrals.myStats({ programId: PROGRAM });
    t.replies.splice(0, t.replies.length, { status: 503, body: '' });
    const link = await t.engage.referrals.myLink({ programId: PROGRAM });
    expect(link.code).toBe('ADA42X');
  });
});

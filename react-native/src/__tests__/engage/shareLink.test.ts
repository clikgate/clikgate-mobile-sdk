import { readFileSync } from 'fs';
import { join } from 'path';

import { ClikgateError } from '../../index';

import { ClikgateEngage } from '../../engage/ClikgateEngage';
import { SHARE_APPS, ShareApp } from '../../engage/shareApp';
import { fixture } from './harness';
import type { ReferralLink } from '../../engage/models';

/** Change 13 S.1: share.link / share.referralLink go to the native Engage features. */
describe('share.link', () => {
  const calls: Record<string, unknown>[] = [];
  const engage = (reply: () => Promise<boolean> = async () => true) =>
    new ClikgateEngage({
      shareLink: (args) => {
        calls.push(args);
        return reply();
      },
    });

  beforeEach(() => {
    calls.length = 0;
  });

  it('ShareApp matches the contract', () => {
    const targets = JSON.parse(
      readFileSync(
        join(__dirname, '..', '..', '..', '..', 'shared', 'share_targets.json'),
        'utf8'
      )
    );
    expect(SHARE_APPS).toEqual(targets.share_apps);
    expect(ShareApp.WhatsApp).toBe('whatsapp');
  });

  it('sends the url, message, app and share_urls', async () => {
    const opened = await engage().share.link('https://inv.myapp.com/summer', {
      message: 'Join me',
      app: ShareApp.Telegram,
      shareUrls: { whatsapp: 'https://inv.myapp.com/summer-z' },
    });
    expect(opened).toBe(true);
    expect(calls).toEqual([
      {
        url: 'https://inv.myapp.com/summer',
        message: 'Join me',
        app: 'telegram',
        shareUrls: { whatsapp: 'https://inv.myapp.com/summer-z' },
      },
    ]);
  });

  it('referralLink keeps the code and the short link', async () => {
    const r = fixture('referral_link_response');
    const link = {
      url: r.url,
      code: r.code,
      shortUrl: r.short_url,
    } as ReferralLink;
    expect(await engage(async () => false).share.referralLink(link)).toBe(
      false
    );
    expect(calls[0]).toEqual({
      url: 'https://inv.myapp.com/r/ADA42X',
      code: 'ADA42X',
      shortUrl: 'https://inv.myapp.com/a8K2bq',
      message: null,
      app: null,
    });
  });

  it('native errors become ClikgateError; an empty url is refused', async () => {
    const failing = engage(async () => {
      throw Object.assign(new Error('No app can share text on this device'), {
        code: 'share_unavailable',
      });
    });
    await expect(
      failing.share.link('https://inv.myapp.com/summer')
    ).rejects.toMatchObject({
      code: 'share_unavailable',
    });
    await expect(failing.share.link(' ')).rejects.toBeInstanceOf(ClikgateError);
    expect(calls).toHaveLength(1);
  });

  it('without the native module, share_unavailable', async () => {
    await expect(
      new ClikgateEngage().share.link('https://inv.myapp.com/summer')
    ).rejects.toMatchObject({
      code: 'share_unavailable',
    });
  });
});

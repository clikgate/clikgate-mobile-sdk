import { isClikgateMessage } from '../isClikgateMessage';

describe('isClikgateMessage (pure, no native module)', () => {
  it('recognises FCM data messages', () => {
    expect(isClikgateMessage({ cg: 'uc' })).toBe(true);
    expect(isClikgateMessage({ cg: 'uc', other: 'x' })).toBe(true);
  });

  it('recognises the APNs payload as an object', () => {
    expect(
      isClikgateMessage({ aps: { 'content-available': 1 }, cg: { t: 'uc' } })
    ).toBe(true);
  });

  it('recognises the payload serialised as a JSON string', () => {
    expect(isClikgateMessage({ cg: '{"t":"uc"}' })).toBe(true);
    expect(isClikgateMessage({ cg: '{"t":"other"}' })).toBe(false);
    expect(isClikgateMessage({ cg: '["uc"]' })).toBe(false);
    expect(isClikgateMessage({ cg: '{not json' })).toBe(false);
  });

  it('rejects everything else', () => {
    expect(isClikgateMessage(null)).toBe(false);
    expect(isClikgateMessage(undefined)).toBe(false);
    expect(isClikgateMessage('uc')).toBe(false);
    expect(isClikgateMessage({})).toBe(false);
    expect(isClikgateMessage({ cg: 'UC' })).toBe(false);
    expect(isClikgateMessage({ cg: { t: 'x' } })).toBe(false);
    expect(isClikgateMessage({ cg: null })).toBe(false);
    expect(isClikgateMessage({ t: 'uc' })).toBe(false);
    expect(isClikgateMessage({ notification: { title: 'Hi' } })).toBe(false);
  });

  it('does not load the native module', () => {
    jest.isolateModules(() => {
      const factory = jest.fn(() => ({ __esModule: true, default: null }));
      jest.doMock('../NativeClikgate', factory);
      const { isClikgateMessage: fresh } = require('../isClikgateMessage');
      expect(fresh({ cg: 'uc' })).toBe(true);
      expect(factory).not.toHaveBeenCalled();
    });
  });
});

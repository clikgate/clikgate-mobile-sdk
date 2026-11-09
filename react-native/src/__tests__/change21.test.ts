import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate } from '../index';
import { type MockModule } from './testModule';

jest.mock('../NativeClikgate', () => ({
  __esModule: true,
  default: jest.requireActual('./testModule').createMockModule(),
}));

const mockModule: MockModule = jest.requireMock('../NativeClikgate').default;

beforeEach(() => {
  resetClikgateForTesting();
  jest.clearAllMocks();
});

// Change 21 (S.1, S.2, R.2, R.25): the React Native module hands every opened URL to the native SDK exactly as it
// arrived, so the native /resolve (direct App Link / Universal Link opens) and /install launch_url carry the
// redirect's cg_click_id (the server attaches to that click and never records a second one) and X's twclid (like
// li_fat_id, change 19 S.2). The installation id is added natively on every call.
describe('open payloads', () => {
  it('a direct open passes the URL with nothing added', async () => {
    mockModule.handleUrl.mockResolvedValueOnce(true);
    const url = 'https://inv.myapp.com/p/dress';
    await expect(Clikgate.handleUrl(url)).resolves.toBe(true);
    expect(mockModule.handleUrl).toHaveBeenCalledTimes(1);
    expect(mockModule.handleUrl).toHaveBeenCalledWith({ url });
  });

  it('a redirect open passes the click reference unchanged, in one call', async () => {
    mockModule.handleUrl.mockResolvedValueOnce(true);
    const url =
      'https://inv.myapp.com/p/dress?cg_click_id=clk_01JAB3C4D5E6F7G8H9JKMNPQRS&cg_link=lnk_01JAB3C4D5E6F7G8H9JKMNPQRS';
    await expect(Clikgate.handleUrl(url)).resolves.toBe(true);
    expect(mockModule.handleUrl).toHaveBeenCalledTimes(1);
    expect(mockModule.handleUrl).toHaveBeenCalledWith({ url });
  });

  it('handleUrl passes twclid unchanged', async () => {
    mockModule.handleUrl.mockResolvedValueOnce(true);
    const url =
      'https://inv.myapp.com/p/dress?cg_click_id=clk_1&twclid=2-abcDEF123xyz&li_fat_id=LIFAT1';
    await expect(Clikgate.handleUrl(url)).resolves.toBe(true);
    expect(mockModule.handleUrl).toHaveBeenCalledWith({ url });
  });
});

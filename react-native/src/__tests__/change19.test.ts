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

// Change 19 (R.20 S.2): LinkedIn `li_fat_id` and Snap `ScCid` reach the native SDK (and from there Clikgate's
// /install launch_url and /resolve url) exactly as the link carried them; the native SDKs never strip them.
describe('ad click ids in links', () => {
  it('handleUrl passes li_fat_id and ScCid unchanged (ScCid keeps its case)', async () => {
    mockModule.handleUrl.mockResolvedValueOnce(true);
    const url =
      'https://inv.myapp.com/p/dress?cg_click_id=clk_1&li_fat_id=0f1e2d3c-aaaa-bbbb-cccc-1234567890ab&ScCid=snapclick123';
    await expect(Clikgate.handleUrl(url)).resolves.toBe(true);
    expect(mockModule.handleUrl).toHaveBeenCalledWith({ url });
  });
});

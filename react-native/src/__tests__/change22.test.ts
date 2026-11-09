import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate, GoalStatus } from '../index';
import { fixture, toBridgeMap } from './fixtures';
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

/**
 * Change 22: one method, `goal()` (R.9 `received` is a success), and `getInstallationId()` for
 * identity Path B (I.7, R.26). The bridge stays thin: the native SDKs decide the value.
 */
describe('Change 22', () => {
  it('received is a success status, with its reason', async () => {
    const results = fixture('goals_response_received').results as object[];
    mockModule.goal.mockResolvedValueOnce(toBridgeMap(results[0]) as never);
    const r = await Clikgate.goal('level_completed', { reference: 'APP-7' });
    expect(r.status).toBe(GoalStatus.Received);
    expect(r.reason).toBe('not_counted_yet');
    expect(GoalStatus.Received).toBe('received');
  });

  it('an unknown status is still a refusal', async () => {
    mockModule.goal.mockResolvedValueOnce({ status: 'new_status' } as never);
    const r = await Clikgate.goal('level_completed');
    expect(r.status).toBe(GoalStatus.Refused);
  });

  it('getInstallationId resolves the native value, or null when tracking is off', async () => {
    mockModule.getInstallationId.mockResolvedValueOnce({
      installationId: '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11',
    });
    await expect(Clikgate.getInstallationId()).resolves.toBe(
      '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11'
    );
    mockModule.getInstallationId.mockResolvedValueOnce({
      installationId: null,
    });
    await expect(Clikgate.getInstallationId()).resolves.toBeNull();
  });
});

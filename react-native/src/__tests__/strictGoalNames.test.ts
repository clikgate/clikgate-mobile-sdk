import { resetClikgateForTesting } from '../Clikgate';
import { Clikgate, GoalKind, GoalStatus } from '../index';
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
 * An organisation that accepts only goals it has set up: the native SDKs refuse unknown names with
 * `unknown_goal` (archived goals with `goal_archived`) and never retry them. The bridge passes the
 * result through and never checks names itself.
 */
describe('strict goal names', () => {
  const results = fixture('goals_response_refused_unknown_goal')
    .results as object[];

  it('unknown_goal is a refusal with its reason', async () => {
    mockModule.goal.mockResolvedValueOnce(toBridgeMap(results[0]) as never);
    const r = await Clikgate.goal('level_complete', { reference: 'APP-11' });
    expect(r.status).toBe(GoalStatus.Refused);
    expect(r.reason).toBe('unknown_goal');
    expect(r.goalKind).toBeNull();
  });

  it('goal_archived is a refusal with its reason and kind', async () => {
    mockModule.goal.mockResolvedValueOnce(toBridgeMap(results[1]) as never);
    const r = await Clikgate.goal('old_signup', { reference: 'APP-12' });
    expect(r.status).toBe(GoalStatus.Refused);
    expect(r.reason).toBe('goal_archived');
    expect(r.goalKind).toBe(GoalKind.Standard);
  });

  it('every name goes to the native SDK, even after a refusal', async () => {
    mockModule.goal.mockResolvedValue(toBridgeMap(results[0]) as never);
    await Clikgate.goal('level_complete', { reference: 'APP-11' });
    await Clikgate.goal('level_complete', { reference: 'APP-13' });
    expect(mockModule.goal).toHaveBeenCalledTimes(2);
  });
});

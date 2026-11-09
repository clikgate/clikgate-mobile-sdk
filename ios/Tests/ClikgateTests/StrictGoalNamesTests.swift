import XCTest
@testable import Clikgate

/// An organisation that accepts only goals it has set up: `refused` / `unknown_goal` and `goal_archived` are final
/// (no retry, no re-queue), only the server decides, and debug builds log the goal name only.
final class StrictGoalNamesTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    private let lock = NSLock()
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
        h.logger.testSink = { [unowned self] m in self.lock.lock(); self.lines.append(m); self.lock.unlock() }
    }

    override func tearDown() { h.logger.testSink = nil; h.cleanUp(); super.tearDown() }

    private var logs: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    private let unsetLine = "Goal `level_complete` isn't set up in Clikgate"

    func testUnknownAndArchivedAreFinalAndLogTheNameOnly() async {
        server.on("POST /v1/sdk/goals", .fixture("goals_response_refused_unknown_goal"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("level_complete", value: "2500", currency: "NGN", reference: "APP-11", isFirst: nil, label: "vip",
                        done: { results.add($0, "unknown") })
        await core.goal("old_signup", value: nil, currency: nil, reference: "APP-12", isFirst: nil, done: { results.add($0, "archived") })
        await core.flush()
        XCTAssertEqual(results.byKey["unknown"], ClikgateGoalResult(status: .refused, reason: "unknown_goal", goalKind: nil, valueIgnored: false))
        XCTAssertEqual(results.byKey["archived"], ClikgateGoalResult(status: .refused, reason: "goal_archived", goalKind: .standard, valueIgnored: false))
        let left = await core.queuedEventCount
        XCTAssertEqual(left, 0)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
        XCTAssertEqual(logs.filter { $0.contains(unsetLine) }.count, 1)
        XCTAssertFalse(logs.contains { $0.contains("old_signup") && $0.contains("isn't set up") })
        XCTAssertFalse(logs.contains { $0.contains("APP-11") || $0.contains("2500") || $0.contains("vip") })
    }

    func testWholeRequest422RefusalIsFinal() async {
        server.on("POST /v1/sdk/goals", .fixture("goal_refusal_unknown_goal", status: 422))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("level_complete", value: nil, currency: nil, reference: "APP-11", isFirst: nil, done: { results.add($0, "unknown") })
        await core.flush()
        XCTAssertEqual(results.byKey["unknown"], .refused("unknown_goal"))
        let left = await core.queuedEventCount
        XCTAssertEqual(left, 0)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
        XCTAssertEqual(logs.filter { $0.contains(unsetLine) }.count, 1)
    }

    func testWholeRequest422ArchivedIsFinal() async {
        server.on("POST /v1/sdk/goals", .fixture("goal_refusal_goal_archived", status: 422))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("old_signup", value: nil, currency: nil, reference: "APP-12", isFirst: nil, done: { results.add($0, "archived") })
        await core.flush()
        XCTAssertEqual(results.byKey["archived"], .refused("goal_archived"))
        let left = await core.queuedEventCount
        XCTAssertEqual(left, 0)
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 1)
        XCTAssertFalse(logs.contains { $0.contains("isn't set up") })
    }

    func testTheDeviceNeverChecksNamesOrRemembersTheRefusal() async {
        server.on("POST /v1/sdk/goals", .fixture("goals_response_refused_unknown_goal"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("level_complete", value: nil, currency: nil, reference: "APP-11", isFirst: nil, done: { results.add($0, "first") })
        await core.flush()
        XCTAssertEqual(results.byKey["first"]?.reason, "unknown_goal")
        // The organisation may have set the goal up since: the next call goes to the server again.
        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
        await core.goal("level_complete", value: nil, currency: nil, reference: "APP-13", isFirst: nil, done: { results.add($0, "second") })
        await core.flush()
        XCTAssertEqual(results.byKey["second"]?.status, .counted)
        let calls = server.requests("POST /v1/sdk/goals")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual((calls.last?.json["goals"] as? [[String: Any]])?.first?["goal"] as? String, "level_complete")
    }
}

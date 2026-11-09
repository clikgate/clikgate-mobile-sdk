import XCTest
@testable import Clikgate

/// The persisted queue and its flushing. Change 22: goals only (`track()` and app events were removed).
final class QueueTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func sentGoals() -> [[String: Any]] {
        server.requests("POST /v1/sdk/goals").flatMap { ($0.json["goals"] as? [[String: Any]]) ?? [] }
    }

    private func goal(_ core: ClikgateCore, _ key: String, _ ref: String? = nil) async {
        await core.goal(key, value: nil, currency: nil, reference: ref, isFirst: nil)
    }

    func testGoalsWaitForInstallAndPersistAcrossLaunches() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/install", .offline())
        let core = h.makeCore()
        await goal(core, "signup", "S1")
        await goal(core, "level_up", "L1")
        await core.flush()
        XCTAssertTrue(server.requests("POST /v1/sdk/goals").isEmpty, "no goals before /install")

        // "Next launch": a fresh queue reads the queue file.
        let queue = EventQueue(directory: h.dir)
        XCTAssertEqual(queue.events.map { $0.name }, ["signup", "level_up"])

        stubHappyPath()
        let next = h.makeCore()
        await next.start(startTimers: false)
        XCTAssertEqual(sentGoals().map { $0["reference"] as? String }, ["S1", "L1"])
        XCTAssertEqual(EventQueue(directory: h.dir).count, 0)
    }

    func testFailedFlushKeepsGoalsAndRetriesWithTheSameReference() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/goals", .json("{}", status: 500))
        await goal(core, "signup")
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/goals").count, 5, "gives up after 5 attempts")
        var queued = await core.queuedEventCount
        XCTAssertEqual(queued, 1, "goals stay queued")

        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
        await core.flush()
        queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(Set(sentGoals().compactMap { $0["reference"] as? String }).count, 1)
    }

    func testFlushAtCountTriggersFlushAndBatchesAreCapped() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        for i in 0..<19 { await goal(core, "g\(i)") }
        XCTAssertTrue(server.requests("POST /v1/sdk/goals").isEmpty)
        await goal(core, "g19")
        await eventually { self.server.requests("POST /v1/sdk/goals").count == 1 }
        XCTAssertEqual((server.requests("POST /v1/sdk/goals")[0].json["goals"] as? [Any])?.count, 20, "flushes at 20 queued goals")
    }

    func testQueueDropsOldestWhenFull() {
        let dir = h.dir
        let q = EventQueue(directory: dir, maxEvents: 3, maxBytes: 1_048_576)
        for i in 0..<5 {
            q.append(QueuedEvent(eventId: "id\(i)", name: "g\(i)", occurredAt: "2026-10-20T10:00:00Z"))
        }
        XCTAssertEqual(q.events.map { $0.eventId }, ["id2", "id3", "id4"])

        let small = EventQueue(directory: dir.appendingPathComponent("b"), maxEvents: 1000, maxBytes: 1024)
        for i in 0..<5 {
            var e = QueuedEvent(eventId: "b\(i)", name: "g", occurredAt: "2026-10-20T10:00:00Z")
            e.goal = ["goal": .string("g"), "reference": .string(String(repeating: "x", count: 128)), "blob": .string(String(repeating: "y", count: 300))]
            small.append(e)
        }
        XCTAssertLessThanOrEqual(small.totalBytes, 1024)
        XCTAssertEqual(small.events.last?.eventId, "b4")
    }

    func testAppEventsLeftByAnEarlierBuildAreDroppedWithoutANetworkCall() async throws {
        // Change 22 (S): an app event persisted by an earlier development build has no `goal`: it's dropped on the
        // next flush and never sent; the goals around it are sent.
        stubHappyPath()
        let q = EventQueue(directory: h.dir)
        q.append(QueuedEvent(eventId: "e1", name: "purchase", occurredAt: "2026-11-01T10:00:00Z"))
        var g = QueuedEvent(eventId: "goal:signup:S1", name: "signup", occurredAt: "2026-11-01T10:00:01Z")
        g.goal = ["goal": .string("signup"), "reference": .string("S1"), "occurred_at": .string("2026-11-01T10:00:01Z")]
        q.append(g)
        q.append(QueuedEvent(eventId: "e2", name: "level_up", occurredAt: "2026-11-01T10:00:02Z"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.flush()
        XCTAssertEqual(sentGoals().map { $0["goal"] as? String }, ["signup"])
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(server.requests.allSatisfy { !$0.path.contains("/v1/sdk/events") }) // no-track-guard: 404 test (the removed route is never called)
    }

    func testNoTrackOrMoneyAPI() {
        // Change 22 (D1): goal() is the only method. A compile-time check lives in the API dump
        // (scripts/check_api.sh); here, the facade's selectors.
        XCTAssertFalse(Clikgate.shared.responds(to: NSSelectorFromString("track:")))
        XCTAssertNil(NSClassFromString("Clikgate.ClikgateMoney"))
    }
}

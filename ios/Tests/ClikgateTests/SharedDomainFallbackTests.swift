import XCTest
@testable import Clikgate

/// Unmatched links on shared platform domains open in an in-app browser (change 06, SDK 1.4.0).
final class SharedDomainFallbackTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
    }

    private func options(fallback: Bool = true) -> ClikgateOptions {
        ClikgateOptions(linkDomains: ["inv.myapp.com", "ciz.to", "clk.ng"], logLevel: .none, platformDomainBrowserFallback: fallback)
    }

    private var observers: [NSObjectProtocol] = []

    override func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        h.cleanUp()
        super.tearDown()
    }

    private func collectHandoffs() -> HandoffBox {
        let box = HandoffBox()
        observers.append(NotificationCenter.default.addObserver(forName: Clikgate.browserHandoffNotification, object: nil, queue: nil) { n in
            if let url = n.object as? URL { box.append(url) }
        })
        return box
    }

    func testSharedDomainListMatchesTheContract() throws {
        let json = Fixtures.json("shared_link_domains")
        XCTAssertEqual(Set(try XCTUnwrap(json["shared_link_domains"] as? [String])), Set(SharedDomains.hosts))
        XCTAssertEqual(SharedDomains.host(URL(string: "https://CIZ.TO/a")!), "ciz.to")
        XCTAssertEqual(SharedDomains.host(URL(string: "https://dev.ciz.to/a")!), "dev.ciz.to")
        XCTAssertNil(SharedDomains.host(URL(string: "https://x.ciz.to/a")!))
        XCTAssertNil(SharedDomains.host(URL(string: "https://inv.myapp.com/a")!))
        XCTAssertNil(SharedDomains.host(URL(string: "myapp://ciz.to/a")!))
    }

    func testUnmatchedSharedDomainLinkOpensInAppBrowserWithoutDeepLink() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let links = collect(h.dispatcher)
        let handoffs = collectHandoffs()
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        let url = URL(string: "https://ciz.to/other-org?utm_source=x")!
        await core.resolve(url: url)
        await eventually { handoffs.items.count == 1 }
        XCTAssertEqual(h.browser.opened, [url])
        XCTAssertEqual(handoffs.items, [url])
        await drainMain()
        XCTAssertTrue(links.items.isEmpty)
    }

    func testUnmatchedCustomDomainLinkKeepsOldBehaviour() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let links = collect(h.dispatcher)
        let handoffs = collectHandoffs()
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/unknown")!)
        await drainMain()
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").count, 1)
        XCTAssertTrue(h.browser.opened.isEmpty)
        XCTAssertTrue(handoffs.items.isEmpty)
        XCTAssertTrue(links.items.isEmpty)
    }

    func testMatchedSharedDomainLinkIsDeliveredAsBefore() async throws {
        let links = collect(h.dispatcher)
        let handoffs = collectHandoffs()
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://clk.ng/mine")!)
        await eventually { links.items.count == 1 }
        XCTAssertEqual(links.items.first?.path, "/products/42")
        await drainMain()
        XCTAssertTrue(h.browser.opened.isEmpty)
        XCTAssertTrue(handoffs.items.isEmpty)
    }

    func testFallbackCanBeTurnedOff() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let links = collect(h.dispatcher)
        let handoffs = collectHandoffs()
        let core = h.makeCore(options: options(fallback: false))
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://ciz.to/other-org")!)
        await drainMain()
        XCTAssertTrue(h.browser.opened.isEmpty)
        XCTAssertTrue(handoffs.items.isEmpty)
        XCTAssertTrue(links.items.isEmpty)
    }

    func testBrowserFailureReportsNoHandoff() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        h.browser.succeeds = false
        let handoffs = collectHandoffs()
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://ciz.to/other-org")!)
        await drainMain()
        XCTAssertEqual(h.browser.opened.count, 1)
        XCTAssertTrue(handoffs.items.isEmpty)
    }

    func testUnmatchedSharedLaunchUrlOnFirstLaunchIsHandedOff() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let handoffs = collectHandoffs()
        let core = h.makeCore(options: options())
        await core.resolve(url: URL(string: "https://ciz.to/other-org")!)   // before start: launch_url
        await core.start(startTimers: false)
        await eventually { handoffs.items.count == 1 }
        XCTAssertEqual(server.requests("POST /v1/sdk/install").first?.json["launch_url"] as? String, "https://ciz.to/other-org")
        XCTAssertEqual(h.browser.opened.map(\.absoluteString), ["https://ciz.to/other-org"])
        XCTAssertEqual(handoffs.items.map(\.absoluteString), ["https://ciz.to/other-org"])
    }

    func testPublicFacadePostsTheHandoffNotification() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let box = collectHandoffs()
        let sdk = Clikgate()
        sdk.configure(sdkKey: "cg_sdk_test", options: options(), deps: h.deps(), startTimers: false)
        await eventually { self.server.requests("POST /v1/sdk/install").count == 1 }
        XCTAssertTrue(sdk.handle(url: URL(string: "https://clk.ng/abc")!))
        await eventually { box.items.count == 1 }
        XCTAssertEqual(box.items.first?.host, "clk.ng")
    }
}

final class HandoffBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [URL] = []
    func append(_ r: URL) { lock.lock(); _items.append(r); lock.unlock() }
    var items: [URL] { lock.lock(); defer { lock.unlock() }; return _items }
}

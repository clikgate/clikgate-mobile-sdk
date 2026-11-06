import XCTest
@testable import Clikgate

/// Change 21 (S.1, S.2, R.2, R.4, R.25): the open payloads the server counts existing-user opens from.
///
/// - A direct Universal Link open (no redirect) goes to `/resolve` with the URL as opened and the installation in
///   `Clikgate-Installation-Id` (the server finds the `ins_` row from it): the server records the click.
/// - A redirect open carries the redirect's `cg_click_id` inside that URL: the server attaches to that click.
/// - One tap is one click: after `/install` matched the launch URL (`status: matched`), the SDK never `/resolve`s the
///   same URL again (that would record a second click); it attaches by `click_id` or delivers the link locally.
/// - X's `twclid` travels unchanged in the launch and resolved URLs, like `li_fat_id` (change 19 S.2).
final class Change21Tests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared
    let click = "clk_01JAB3C4D5E6F7G8H9JKMNPQRS"

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func resolves() -> [RecordedRequest] { server.requests("POST /v1/sdk/resolve") }
    private func installs() -> [RecordedRequest] { server.requests("POST /v1/sdk/install") }

    /// An install answer without a deep link, with the launch URL's `status`.
    private func stubInstall(_ fixture: String, status: String?) {
        var j = Fixtures.json(fixture)
        j["deep_link"] = NSNull()
        if let s = status { j["status"] = s }
        server.on("POST /v1/sdk/install", StubResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: j)))
    }

    // MARK: - S.1 / S.2: direct and redirect opens

    func testDirectUniversalLinkOpenSendsTheUrlAndTheInstallation() async throws {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let id = await core.currentState().installationId
        let url = "https://inv.myapp.com/p/dress"
        await core.resolve(url: URL(string: url)!)
        let r = try XCTUnwrap(resolves().first)
        XCTAssertEqual(resolves().count, 1)
        XCTAssertEqual(r.json["url"] as? String, url)
        XCTAssertNil(r.json["click_id"], "no click to attach to: the server records this open's click")
        XCTAssertEqual(r.headers["Clikgate-Installation-Id"], id)
    }

    func testRedirectOpenCarriesTheRedirectClickInOneResolve() async throws {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let id = await core.currentState().installationId
        let url = "https://inv.myapp.com/p/dress?cg_click_id=\(click)&cg_link=lnk_01JAB3C4D5E6F7G8H9JKMNPQRS"
        await core.resolve(url: URL(string: url)!)
        let r = try XCTUnwrap(resolves().first)
        XCTAssertEqual(resolves().count, 1, "one tap, one /resolve")
        XCTAssertEqual(r.json["url"] as? String, url, "the click reference reaches the server unchanged")
        XCTAssertEqual(r.headers["Clikgate-Installation-Id"], id)
        XCTAssertEqual(installs().count, 1)
    }

    func testCustomSchemeRedirectOpenKeepsTheClickId() async throws {
        let core = h.makeCore()
        await core.start(startTimers: false)
        let url = "myapp://products/42?cg_click_id=\(click)"
        await core.resolve(url: URL(string: url)!)
        XCTAssertEqual(resolves().single?.json["url"] as? String, url)
    }

    func testRedirectOpenOnFirstLaunchGoesWithTheInstall() async throws {
        let core = h.makeCore()
        let url = "https://inv.myapp.com/p/dress?cg_click_id=\(click)"
        await core.resolve(url: URL(string: url)!)   // the launch URL, before /install
        server.on("POST /v1/sdk/install", .fixture("install_response_attributed_source"))
        await core.start(startTimers: false)
        let install = try XCTUnwrap(installs().first)
        XCTAssertEqual(install.json["launch_url"] as? String, url)
        let id = await core.currentState().installationId
        XCTAssertEqual(install.headers["Clikgate-Installation-Id"], id)
        XCTAssertTrue(resolves().isEmpty, "the install answered with the deep link: no /resolve")
    }

    func testOpenCarriesTheInstallationAndNoUrl() async throws {
        await h.makeCore().start(startTimers: false)
        server.reset(); stubHappyPath()
        let next = h.makeCore()
        await next.start(startTimers: false)
        let open = try XCTUnwrap(server.requests("POST /v1/sdk/open").first)
        let id = await next.currentState().installationId
        XCTAssertEqual(open.headers["Clikgate-Installation-Id"], id)
        XCTAssertNil(open.json["url"], "URLs go to /resolve, never /open")
        XCTAssertNil(open.json["click_id"])
    }

    // MARK: - R.2: one tap is one click

    func testMatchedLaunchUrlAttachesByClickIdNotUrl() async throws {
        stubInstall("install_response_attributed_source", status: "matched")
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        let url = "https://inv.myapp.com/p/dress"
        await core.resolve(url: URL(string: url)!)
        await core.start(startTimers: false)
        let r = try XCTUnwrap(resolves().single)
        XCTAssertEqual(r.json["click_id"] as? String, click, "attaches to the click /install recorded")
        XCTAssertNil(r.json["url"], "a URL would record a second click")
        await eventually { box.items.count == 1 }
    }

    func testMatchedLaunchUrlWithoutAClickIsDeliveredLocally() async throws {
        // Deep-link-only mode: the attribution is organic, so there is no click id to attach to.
        stubInstall("install_response_organic", status: "matched")
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        let url = "https://inv.myapp.com/p/dress?utm_source=x"
        await core.resolve(url: URL(string: url)!)
        await core.start(startTimers: false)
        await eventually { box.items.count == 1 }
        XCTAssertTrue(resolves().isEmpty)
        XCTAssertEqual(box.items.first?.url?.absoluteString, url)
        XCTAssertEqual(box.items.first?.data["utm_source"] as? String, "x")
    }

    func testUnmatchedOrOlderServerLaunchUrlIsResolvedAsBefore() async throws {
        stubInstall("install_response_organic", status: nil)
        let core = h.makeCore()
        let url = "https://inv.myapp.com/p/dress"
        await core.resolve(url: URL(string: url)!)
        await core.start(startTimers: false)
        XCTAssertEqual(resolves().single?.json["url"] as? String, url)
    }

    // MARK: - R.25: X's twclid travels like li_fat_id

    func testTwclidReachesTheServerInTheLaunchAndResolvedUrls() async throws {
        let core = h.makeCore()
        let launch = "https://inv.myapp.com/p/dress?cg_click_id=\(click)&twclid=2-abcDEF123xyz"
        await core.resolve(url: URL(string: launch)!)
        server.on("POST /v1/sdk/install", .fixture("install_response_attributed_source"))
        await core.start(startTimers: false)
        XCTAssertEqual(installs().first?.json["launch_url"] as? String, launch)

        let opened = "https://inv.myapp.com/p/shoes?twclid=TWCLID2"
        await core.resolve(url: URL(string: opened)!)
        XCTAssertEqual(resolves().last?.json["url"] as? String, opened)
    }

    func testTwclidKeptThroughConsentBuffering() async throws {
        server.on("GET /v1/sdk/config", .fixture("config_response_consent_required"))
        server.on("POST /v1/sdk/consent", .ok)
        server.on("POST /v1/sdk/install-ping", .ok)
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        await core.start(startTimers: false)
        let launch = "https://inv.myapp.com/p/dress?twclid=TWCLID1"
        await core.resolve(url: URL(string: launch)!)
        await eventually { box.items.count == 1 }
        XCTAssertEqual(box.items.first?.data["twclid"] as? String, "TWCLID1", "delivered locally while buffering")
        XCTAssertTrue(installs().isEmpty)
        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await drainMain()
        XCTAssertEqual(installs().first?.json["launch_url"] as? String, launch)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

import XCTest
@testable import Clikgate

/// Connected domains (backend Part 3 §31.3): `config.link_domains` ∪ `options.linkDomains`.
final class LinkDomainsTests: XCTestCase {
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

    private func configWithDomains(_ domains: Any?) -> String {
        var o = Fixtures.json("config_response")
        o["link_domains"] = domains
        let data = try! JSONSerialization.data(withJSONObject: o)
        return String(data: data, encoding: .utf8)!
    }

    private func makeCore(domains: [String], box: LinkDomainsBox) -> ClikgateCore {
        let options = ClikgateOptions(linkDomains: domains, logLevel: .none)
        return ClikgateCore(sdkKey: "cg_sdk_test", options: options, deps: h.deps(), logger: h.logger,
                            dispatcher: h.dispatcher, linkDomains: box, wrapper: nil)
    }

    private func matches(_ url: String, _ box: LinkDomainsBox) -> Bool {
        LinkMatcher.isClikgateURL(URL(string: url)!, linkDomains: box.all, appSchemes: ["myapp"])
    }

    // MARK: Parsing

    func testParsesPresentAbsentAndMalformedLinkDomains() {
        XCTAssertEqual(RemoteConfig(json: Fixtures.json("config_response")).linkDomains, ["inv.myapp.com", "ciz.to"])
        // Older server: no field.
        XCTAssertEqual(RemoteConfig(json: Fixtures.json("config_response_legacy")).linkDomains, [])
        // Malformed: not an array → ignored; non-strings and empty strings dropped; normalised.
        XCTAssertEqual(RemoteConfig(json: ["link_domains": "ybr.ng"]).linkDomains, [])
        XCTAssertEqual(RemoteConfig(json: ["link_domains": NSNull()]).linkDomains, [])
        let mixed: [Any] = [" YBR.ng ", 5, NSNull(), "", [String: Any](), "https://Go.YourBrand.com/x"]
        XCTAssertEqual(RemoteConfig(json: ["link_domains": mixed]).linkDomains, ["ybr.ng", "go.yourbrand.com"])
    }

    // MARK: Matching

    func testConfiguredDomainsAlwaysCountAndServerDomainsAreAdded() {
        let box = LinkDomainsBox(optionDomains: ["Go.YourBrand.com", ""])
        XCTAssertTrue(matches("https://go.yourbrand.com/a8K2", box))
        XCTAssertFalse(matches("https://ybr.ng/a8K2", box))

        box.setConfigDomains(["YBR.ng"])
        XCTAssertTrue(matches("https://Ybr.NG/a8K2", box))
        XCTAssertTrue(matches("https://go.yourbrand.com/a8K2", box), "configured domains still count")
        XCTAssertFalse(matches("https://sub.ybr.ng/a8K2", box))

        box.setConfigDomains([])
        XCTAssertTrue(matches("https://go.yourbrand.com/a8K2", box))
        XCTAssertFalse(matches("https://ybr.ng/a8K2", box))
        XCTAssertEqual(box.all, ["go.yourbrand.com"])
    }

    func testMissingServerDomainsAreReportedOncePerLaunch() {
        let box = LinkDomainsBox(optionDomains: ["go.yourbrand.com"])
        XCTAssertEqual(box.setConfigDomains(["YBR.ng", "GO.yourbrand.com"]), ["ybr.ng"])
        XCTAssertEqual(box.setConfigDomains(["ybr.ng", "go.yourbrand.com"]), [], "already reported")
        XCTAssertEqual(box.setConfigDomains(["ybr.ng", "new.yourbrand.com"]), ["new.yourbrand.com"])
        let message = LinkDomainsBox.missingWarning("ybr.ng")
        XCTAssertTrue(message.contains("applinks:ybr.ng"))
        XCTAssertTrue(message.contains("linkDomains"))
    }

    // MARK: Core

    func testServerDomainsFromConfigFetchAreUsedAndPersisted() async {
        stubHappyPath()
        server.on("GET /v1/sdk/config", .json(configWithDomains(["YBR.ng", "go.yourbrand.com"])))
        let box = LinkDomainsBox(optionDomains: ["go.yourbrand.com"])
        let core = makeCore(domains: ["go.yourbrand.com"], box: box)
        await core.start(startTimers: false)
        await eventually { Set(box.all) == ["go.yourbrand.com", "ybr.ng"] }
        XCTAssertTrue(matches("https://ybr.ng/a8K2", box))

        // Relaunch offline: the cached config is read synchronously by the core's init.
        server.on("GET /v1/sdk/config", .json("{}", status: 503))
        let box2 = LinkDomainsBox(optionDomains: ["go.yourbrand.com"])
        _ = makeCore(domains: ["go.yourbrand.com"], box: box2)
        XCTAssertEqual(Set(box2.all), ["go.yourbrand.com", "ybr.ng"])
    }

    func testLegacyConfigKeepsConfiguredDomains() async {
        stubHappyPath()
        server.on("GET /v1/sdk/config", .fixture("config_response_legacy"))
        let box = LinkDomainsBox(optionDomains: ["inv.myapp.com"])
        let core = makeCore(domains: ["inv.myapp.com"], box: box)
        await core.start(startTimers: false)
        await drainMain()
        XCTAssertEqual(box.all, ["inv.myapp.com"])
        XCTAssertTrue(matches("https://inv.myapp.com/r/ADA42", box))
    }
}

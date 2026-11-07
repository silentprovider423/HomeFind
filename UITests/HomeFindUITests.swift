import XCTest

/// UI-Tests je Aktion mit Testkonten im Simulator (Standort simuliert). Mia ist angemeldet,
/// Leo teilt, Ida teilt nicht. Zugänge: HF_TEST_* (tools/run-tests.sh), nie im Repo.
final class HomeFindUITests: XCTestCase {
    var env: [String: String] = [:]
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        env = ProcessInfo.processInfo.environment
        guard env["HF_TEST_SERVER"] != nil, env["HF_TEST_MIA_KEY"] != nil else { throw XCTSkip("HF_TEST_* fehlt") }
        try await resetState()
        app = await MainActor.run { () -> XCUIApplication in
            let a = XCUIApplication()
            a.launchEnvironment["FIND_SERVER"] = env["HF_TEST_SERVER"]
            a.launchEnvironment["FIND_TOKEN"] = env["HF_TEST_MIA_KEY"]
            a.launchEnvironment["FIND_SKIP_ONBOARDING"] = "1"
            a.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
            return a
        }
    }

    // MARK: Server-Hilfen (direkt per HTTP, ohne App-Code)

    @discardableResult
    func api(_ who: String, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Any? {
        var req = URLRequest(url: URL(string: env["HF_TEST_SERVER"]! + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(env["HF_TEST_\(who)_KEY"]!)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try? JSONSerialization.jsonObject(with: data)
    }

    func family(_ who: String) async throws -> [String: Any] {
        try await api(who, "GET", "/api/v1/families/mine") as? [String: Any] ?? [:]
    }

    func incoming(_ who: String) async throws -> [[String: Any]] {
        ((try await family(who))["location_requests"] as? [String: Any])?["incoming"] as? [[String: Any]] ?? []
    }

    func miaSharing() async throws -> Bool {
        (((try await family("MIA"))["me"] as? [String: Any])?["sharing"] as? [String: Any])?["enabled"] as? Bool ?? false
    }

    func resetState() async throws {
        for who in ["MIA", "LEO", "IDA"] {
            for r in try await incoming(who) { if let id = r["id"] as? Int { try await api(who, "POST", "/api/v1/families/location_requests/\(id)/decline", [:]) } }
        }
        try await api("MIA", "PATCH", "/api/v1/families/sharing", ["enabled": false])
        try await api("IDA", "PATCH", "/api/v1/families/sharing", ["enabled": false])
        try await api("LEO", "PATCH", "/api/v1/families/sharing", ["enabled": true, "duration": "permanent"])
        let now = Int(Date().timeIntervalSince1970)
        try await api("LEO", "POST", "/api/v1/owntracks/points",
                      ["_type": "location", "lat": 52.5163, "lon": 13.3777, "tst": now, "acc": 12, "batt": 64, "tid": "leodemo01"])
    }

    @MainActor func waitFor(_ e: XCUIElement, _ t: TimeInterval = 25, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.waitForExistence(timeout: t), "nicht gefunden: \(e)", file: file, line: line)
    }

    // MARK: Tests

    @MainActor func testPeopleListShowsFamilyAndLeoOnMap() {
        app.launch()
        waitFor(app.buttons["person-Leo"])
        XCTAssertTrue(app.buttons["person-Ida"].exists)
        // Ida teilt nicht → Status statt Ort
        XCTAssertTrue(app.staticTexts["Standort wird nicht geteilt"].exists)
        // Stecknadel auf der Karte öffnet die Detailkarte
        let pin = app.buttons["pin-Leo Beispiel"]
        waitFor(pin)
        pin.tap()
        waitFor(app.buttons["detail-favorite"])
        XCTAssertTrue(app.buttons["Leo entfernen"].exists || app.staticTexts["Leo entfernen"].exists)
    }

    @MainActor func testShareOneHourShowsRemainingThenStop() async throws {
        app.launch()
        app.buttons["tab-me"].tap()
        let toggle = app.switches["me-share-toggle"]
        waitFor(toggle)
        toggle.switches.firstMatch.tap()
        let oneHour = app.buttons["Standort 1 Std. teilen"]
        waitFor(oneHour)
        oneHour.tap()
        let remaining = app.staticTexts["me-remaining"]
        waitFor(remaining)
        XCTAssertTrue(remaining.label.contains("Noch"), remaining.label)
        let shared = try await miaSharing()
        XCTAssertTrue(shared)
        // ausschalten
        toggle.switches.firstMatch.tap()
        let gone = NSPredicate(format: "label CONTAINS 'Niemand'")
        waitFor(app.staticTexts.containing(gone).firstMatch)
        let after = try await miaSharing()
        XCTAssertFalse(after)
    }

    @MainActor func testShareFromPlusButtonWithEmail() async throws {
        app.launch()
        let plus = app.buttons["people-add"]
        waitFor(plus)
        plus.tap()
        waitFor(app.buttons["share-suggestion-Leo"])
        app.buttons["share-suggestion-Leo"].tap()
        waitFor(app.buttons["Unbegrenzt"])
        app.buttons["Unbegrenzt"].tap()
        try await Task.sleep(for: .seconds(4))
        let shared = try await miaSharing()
        XCTAssertTrue(shared)
    }

    @MainActor func testUnknownRecipientShowsInviteHint() {
        app.launch()
        app.buttons["people-add"].tap()
        let field = app.textFields["share-recipient"]
        waitFor(field)
        field.tap()
        field.typeText("niemand@beispiel.test")
        app.buttons["share-send"].tap()
        waitFor(app.alerts.firstMatch)
        XCTAssertTrue(app.alerts.firstMatch.label.contains("niemand@beispiel.test"))
        XCTAssertTrue(app.alerts.buttons["Weboberfläche öffnen"].exists)
    }

    @MainActor func testRequestLocationFromIda() async throws {
        app.launch()
        waitFor(app.buttons["person-Ida"])
        app.buttons["person-Ida"].tap()
        let req = app.buttons["detail-request"]
        waitFor(req)
        req.tap()
        waitFor(app.buttons["Anfrage gesendet"])
        let inc = try await incoming("IDA")
        XCTAssertTrue(inc.contains { (($0["requester"] as? [String: Any])?["email"] as? String) == env["HF_TEST_MIA_EMAIL"] })
    }

    @MainActor func testAcceptIncomingRequestFromIda() async throws {
        try await api("IDA", "POST", "/api/v1/families/location_requests", ["target_user_id": Int(env["HF_TEST_MIA_ID"]!)!])
        app.launch()
        let accept = app.buttons["pending-accept-Ida"]
        waitFor(accept)
        accept.tap()
        waitFor(app.buttons["Standort 1 Std. teilen"])
        app.buttons["Standort 1 Std. teilen"].tap()
        try await Task.sleep(for: .seconds(4))
        XCTAssertFalse(accept.exists)
        let shared = try await miaSharing()
        XCTAssertTrue(shared)
    }

    @MainActor func testDeclineIncomingRequest() async throws {
        try await api("IDA", "POST", "/api/v1/families/location_requests", ["target_user_id": Int(env["HF_TEST_MIA_ID"]!)!])
        app.launch()
        let decline = app.buttons["pending-decline-Ida"]
        waitFor(decline)
        decline.tap()
        try await Task.sleep(for: .seconds(3))
        let inc = try await incoming("MIA")
        XCTAssertTrue(inc.isEmpty)
        let shared = try await miaSharing()
        XCTAssertFalse(shared)
    }

    @MainActor func testAddArrivalAlertForLeo() {
        app.launch()
        waitFor(app.buttons["person-Leo"])
        app.buttons["person-Leo"].tap()
        let add = app.buttons["Hinzufügen"]
        waitFor(add)
        add.tap()
        waitFor(app.buttons["alert-save"])
        app.buttons["alert-save"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Leo kommt bei'")).firstMatch
        waitFor(row)
    }

    @MainActor func testDevicesTabShowsOwnDevicesAndFamily() {
        app.launch()
        app.buttons["tab-devices"].tap()
        waitFor(app.staticTexts["Meine Geräte"])
        waitFor(app.staticTexts["Dieses iPhone"])
        XCTAssertTrue(app.staticTexts["Gerät von Leo"].waitForExistence(timeout: 10))
    }

    @MainActor func testPrivacyPage() {
        app.launch()
        app.buttons["tab-me"].tap()
        let link = app.buttons["me-privacy"]
        waitFor(link)
        link.tap()
        waitFor(app.staticTexts["Was liegt wo"])
        XCTAssertTrue(app.staticTexts["privacy-nobody"].exists)
    }

    @MainActor func testMapChooser() {
        app.launch()
        let chooser = app.buttons["map-chooser"]
        waitFor(chooser)
        chooser.tap()
        waitFor(app.buttons["Satellit"])
        app.buttons["Satellit"].tap()
        XCTAssertTrue(app.buttons["Satellit"].isSelected)
        app.buttons["Standard"].tap()
    }
}

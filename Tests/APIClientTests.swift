import XCTest
import CoreLocation
@testable import HomeFind

/// Testkonten kommen aus der Umgebung (tools/run-tests.sh setzt HF_TEST_* aus der gitignorten env-Datei).
struct TestAccounts {
    let server: URL
    let mia: (key: String, id: Int, email: String, password: String)
    let leo: (key: String, id: Int, email: String, password: String)
    let ida: (key: String, id: Int, email: String, password: String)

    static func load() throws -> TestAccounts {
        let e = ProcessInfo.processInfo.environment
        guard let s = e["HF_TEST_SERVER"], let url = URL(string: s) else { throw XCTSkip("HF_TEST_SERVER fehlt – Server-Tests übersprungen") }
        func acc(_ n: String) throws -> (String, Int, String, String) {
            guard let k = e["HF_TEST_\(n)_KEY"], let i = e["HF_TEST_\(n)_ID"].flatMap(Int.init),
                  let m = e["HF_TEST_\(n)_EMAIL"], let p = e["HF_TEST_\(n)_PASSWORD"] else { throw XCTSkip("Testkonto \(n) fehlt") }
            return (k, i, m, p)
        }
        let m = try acc("MIA"), l = try acc("LEO"), i = try acc("IDA")
        return TestAccounts(server: url, mia: (m.0, m.1, m.2, m.3), leo: (l.0, l.1, l.2, l.3), ida: (i.0, i.1, i.2, i.3))
    }

    func client(_ key: String) -> DawarichClient { DawarichClient(baseURL: server, apiKey: key) }
}

/// Tests gegen das Test-Backend (Dawarich) mit simulierten Positionen in Berlin-Mitte.
final class APIClientTests: XCTestCase {
    var acc: TestAccounts!
    var mia: DawarichClient!, leo: DawarichClient!, ida: DawarichClient!

    override func setUp() async throws {
        acc = try TestAccounts.load()
        mia = acc.client(acc.mia.key); leo = acc.client(acc.leo.key); ida = acc.client(acc.ida.key)
        // Ausgangszustand: niemand außer Leo teilt, keine offenen Anfragen.
        for c in [mia!, leo!, ida!] {
            for r in try await c.family().locationRequests?.incoming ?? [] { try? await c.declineRequest(r.id) }
        }
        try await mia.setSharing(enabled: false)
        try await ida.setSharing(enabled: false)
        try await leo.setSharing(enabled: true, duration: "permanent")
    }

    @MainActor func testLoginWithPassword() async throws {
        let key = try await DawarichClient.login(server: acc.server, email: acc.leo.email, password: acc.leo.password)
        XCTAssertEqual(key, acc.leo.key)
    }

    @MainActor func testLoginWrongPasswordFails() async {
        do {
            _ = try await DawarichClient.login(server: acc.server, email: acc.leo.email, password: "falsch-\(UUID())")
            XCTFail("Anmeldung hätte scheitern müssen")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 401)
        } catch { XCTFail("\(error)") }
    }

    @MainActor func testFamilyHasThreeMembers() async throws {
        let f = try await mia.family()
        XCTAssertEqual(f.members?.count, 3)
        XCTAssertEqual(f.me?.userId, acc.mia.id)
        XCTAssertEqual(f.me?.owner, true)
        XCTAssertEqual(f.members?.first { $0.userId == acc.leo.id }?.sharingEnabled, true)
    }

    @MainActor func testPointFromLeoVisibleToMia() async throws {
        let lat = 52.5163 + Double.random(in: 0...0.0009), lon = 13.3777
        let loc = CLLocation(coordinate: .init(latitude: lat, longitude: lon), altitude: 34, horizontalAccuracy: 10,
                             verticalAccuracy: 5, timestamp: .now)
        try await leo.postPoint(PointQueue.payload(for: loc, trigger: .foreground, deviceId: "leotest0001"))
        let locs = try await mia.familyLocations().locations
        let l = try XCTUnwrap(locs.first { $0.userId == acc.leo.id })
        XCTAssertEqual(l.latitude, lat, accuracy: 0.00001)
        XCTAssertEqual(l.longitude, lon, accuracy: 0.00001)
        XCTAssertLessThan(abs(l.date.timeIntervalSinceNow), 120)
    }

    @MainActor func testShareOneHourShowsExpiryAndStop() async throws {
        let r = try await mia.setSharing(enabled: true, duration: ShareDuration.oneHour.serverValue())
        XCTAssertEqual(r.enabled, true)
        let t1 = try await mia.family()
        let s = try XCTUnwrap(t1.me?.sharing)
        XCTAssertTrue(s.enabled)
        let exp = try XCTUnwrap(s.expiresAt)
        XCTAssertEqual(exp.timeIntervalSinceNow, 3600, accuracy: 90)
        XCTAssertTrue(Fmt.remaining(until: exp).contains("1"))

        // Mia sendet einen simulierten Punkt → Leo sieht ihn, nach Stopp nicht mehr.
        let loc = CLLocation(coordinate: .init(latitude: 52.5200, longitude: 13.4050), altitude: 0, horizontalAccuracy: 10,
                             verticalAccuracy: -1, timestamp: .now)
        try await mia.postPoint(PointQueue.payload(for: loc, trigger: .foreground, deviceId: "miatest0001"))
        let t2 = try await leo.familyLocations()
        XCTAssertTrue(t2.locations.contains { $0.userId == acc.mia.id })
        try await mia.setSharing(enabled: false)
        let t3 = try await leo.familyLocations()
        XCTAssertFalse(t3.locations.contains { $0.userId == acc.mia.id })
        let t4 = try await leo.family()
        XCTAssertEqual(t4.members?.first { $0.userId == acc.mia.id }?.sharingEnabled, false)
    }

    @MainActor func testShareEndOfDayExpiresAroundMidnight() async throws {
        try await mia.setSharing(enabled: true, duration: ShareDuration.endOfDay.serverValue())
        let t5 = try await mia.family()
        let exp = try XCTUnwrap(t5.me?.sharing.expiresAt)
        let midnight = ShareDuration.endOfDay(now: .now, calendar: .current)
        XCTAssertGreaterThanOrEqual(exp.timeIntervalSince(midnight), -60)
        XCTAssertLessThanOrEqual(exp.timeIntervalSince(midnight), 3600 + 60)
        try await mia.setSharing(enabled: false)
    }

    @MainActor func testShareIndefinitely() async throws {
        try await mia.setSharing(enabled: true, duration: ShareDuration.indefinitely.serverValue())
        let t6 = try await mia.family()
        let s = try XCTUnwrap(t6.me?.sharing)
        XCTAssertTrue(s.enabled)
        XCTAssertNil(s.expiresAt)
        try await mia.setSharing(enabled: false)
    }

    @MainActor func testRequestDeclineThenAccept() async throws {
        // Ida bittet Mia um ihren Standort → Mia lehnt ab.
        let created = try await ida.requestLocation(of: acc.mia.id)
        var incoming = try await mia.family().locationRequests?.incoming ?? []
        XCTAssertTrue(incoming.contains { $0.id == created.request.id && $0.requester.userId == acc.ida.id })
        let t7 = try await ida.family()
        XCTAssertTrue(t7.locationRequests?.outgoing.contains { $0.targetUserId == acc.mia.id } ?? false)
        try await mia.declineRequest(created.request.id)
        incoming = try await mia.family().locationRequests?.incoming ?? []
        XCTAssertFalse(incoming.contains { $0.id == created.request.id })

        // Neue Anfrage → Mia nimmt für 1 Std. an → teilt.
        let second = try await ida.requestLocation(of: acc.mia.id)
        try await mia.acceptRequest(second.request.id, duration: "1h")
        let t8 = try await mia.family()
        let s = try XCTUnwrap(t8.me?.sharing)
        XCTAssertTrue(s.enabled)
        XCTAssertNotNil(s.expiresAt)
        try await mia.setSharing(enabled: false)
    }

    @MainActor func testRequestWhileAlreadySharingIsRefused() async throws {
        do {
            try await mia.requestLocation(of: acc.leo.id)   // Leo teilt schon
            XCTFail("Anfrage hätte abgelehnt werden müssen")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 422)
        }
    }

    @MainActor func testDeviceNoteRoundTrip() async throws {
        let id = "unittest\(Int.random(in: 1000...9999))"
        var rec = DeviceRecord(id: id, name: "Test-iPad", emoji: "💻", model: "iPad", system: "iPadOS 26", appVersion: "1.0",
                               latitude: 52.5, longitude: 13.4, accuracy: 10, battery: 50, charging: false, updatedAt: .now)
        let body = String(data: try JSONEncoder.iso.encode(rec), encoding: .utf8)!
        let note = try await mia.createNote(title: "homefind-device:\(id)", body: body)
        rec.name = "Umbenannt"
        try await mia.updateNote(id: note.id, body: String(data: try JSONEncoder.iso.encode(rec), encoding: .utf8)!)
        let t9 = try await mia.notes()
        let found = try XCTUnwrap(t9.first { $0.id == note.id })
        let decoded = try JSONDecoder.iso.decode(DeviceRecord.self, from: Data(found.body.utf8))
        XCTAssertEqual(decoded.name, "Umbenannt")
        XCTAssertEqual(decoded.emoji, "💻")
        try await mia.deleteNote(id: note.id)
        let t10 = try await mia.notes()
        XCTAssertFalse(t10.contains { $0.id == note.id })
        // Leo sieht Mias Notizen nie.
        let t11 = try await leo.notes()
        XCTAssertFalse(t11.contains { $0.title?.hasPrefix("homefind-device:\(id)") == true })
    }

    @MainActor func testPlaceAndTransition() async throws {
        let p = try await mia.createPlace(name: "Testort \(Int.random(in: 1...999))", latitude: 52.5210, longitude: 13.4110, radius: 150)
        XCTAssertEqual(p.geofence, true)
        let t12 = try await mia.places()
        XCTAssertTrue(t12.contains { $0.id == p.id })
        try await mia.postTransition(placeId: p.id, enter: true, at: .now, latitude: 52.5210, longitude: 13.4110,
                                     accuracy: 15, deviceId: "unittest")
        try await mia.deletePlace(p.id)
        let t13 = try await mia.places()
        XCTAssertFalse(t13.contains { $0.id == p.id })
    }

    @MainActor func testPointQueueFlushesAgainstServer() async throws {
        let q = PointQueue(fileName: "test-queue-\(UUID()).json")
        Keep.objects.append(q)
        for i in 0..<3 {
            let loc = CLLocation(coordinate: .init(latitude: 52.5163 + Double(i) * 0.0001, longitude: 13.3777), altitude: 0,
                                 horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: .now.addingTimeInterval(Double(i)))
            q.append(PointQueue.payload(for: loc, trigger: .significant, deviceId: "leoqueue01"))
        }
        let sent = await q.flush(using: leo)
        XCTAssertEqual(sent, 3)
        XCTAssertTrue(q.pending.isEmpty)
    }

    @MainActor func testWrongKeyIsUnauthorized() async {
        do {
            _ = try await acc.client("0000").family()
            XCTFail()
        } catch let e as APIError { XCTAssertEqual(e.status, 401) } catch { XCTFail("\(error)") }
    }
}

/// Hält in Tests erzeugte App-Objekte bis Prozessende fest (keine Freigabe am Testende).
@MainActor enum Keep { static var objects: [AnyObject] = [] }

/// Reine App-Logik ohne Server.
final class LogicTests: XCTestCase {
    @MainActor func testEndOfDayHours() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let at2230 = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 22, minute: 30))!
        XCTAssertEqual(ShareDuration.hoursUntilEndOfDay(now: at2230, calendar: cal), 2)
        let at0900 = cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))!
        XCTAssertEqual(ShareDuration.hoursUntilEndOfDay(now: at0900, calendar: cal), 15)
        XCTAssertEqual(ShareDuration.oneHour.serverValue(), "1h")
        XCTAssertEqual(ShareDuration.indefinitely.serverValue(), "permanent")
    }

    @MainActor func testAlertRuleFiresOnArrivalOnce() async {
        let store = AlertStore(fileName: "test-rules-\(UUID()).json")
        Keep.objects.append(store)
        store.add(AlertRule(subject: .person(7), personName: "Leo", trigger: .arrives, placeName: "Schule",
                            latitude: 52.5200, longitude: 13.4050, radius: 150, repeats: false))
        func loc(_ lat: Double, _ t: Int) -> MemberLocation {
            MemberLocation(userId: 7, address: nil, name: "Leo", latitude: lat, longitude: 13.4050, timestamp: t, battery: nil, batteryStatus: nil)
        }
        XCTAssertTrue(store.evaluate(personId: 7, location: loc(52.5300, 100)).isEmpty) // Startzustand: draußen
        XCTAssertEqual(store.evaluate(personId: 7, location: loc(52.5201, 200)).count, 1) // angekommen
        XCTAssertTrue(store.evaluate(personId: 7, location: loc(52.5300, 300)).isEmpty)
        XCTAssertTrue(store.evaluate(personId: 7, location: loc(52.5201, 400)).isEmpty) // „Nur einmal“ → aus
        XCTAssertFalse(store.rules[0].enabled)
    }

    @MainActor func testAlertRuleLeaveRepeats() async {
        let store = AlertStore(fileName: "test-rules-\(UUID()).json")
        Keep.objects.append(store)
        store.add(AlertRule(subject: .person(3), personName: "Ida", trigger: .leaves, placeName: "Arbeit",
                            latitude: 52.5, longitude: 13.4, radius: 200, repeats: true))
        func loc(_ lat: Double, _ t: Int) -> MemberLocation {
            MemberLocation(userId: 3, address: nil, name: nil, latitude: lat, longitude: 13.4, timestamp: t, battery: nil, batteryStatus: nil)
        }
        _ = store.evaluate(personId: 3, location: loc(52.5, 1))
        XCTAssertEqual(store.evaluate(personId: 3, location: loc(52.51, 2)).count, 1)
        _ = store.evaluate(personId: 3, location: loc(52.5, 3))
        XCTAssertEqual(store.evaluate(personId: 3, location: loc(52.51, 4)).count, 1)
        XCTAssertTrue(store.evaluate(personId: 3, location: loc(52.51, 4)).isEmpty) // gleicher Zeitstempel → ignoriert
    }

    @MainActor func testMeRegionRule() async {
        let store = AlertStore(fileName: "test-rules-\(UUID()).json")
        Keep.objects.append(store)
        let rule = AlertRule(subject: .me, trigger: .arrives, placeName: "Privat", latitude: 52.52, longitude: 13.40,
                             radius: 150, serverPlaceId: 12, repeats: true)
        store.add(rule)
        XCTAssertEqual(rule.regionId, "place:12")
        XCTAssertEqual(store.evaluateMe(regionId: "place:12", entered: true).count, 1)
        XCTAssertTrue(store.evaluateMe(regionId: "place:12", entered: false).isEmpty)
    }

    @MainActor func testClustering() {
        func item(_ n: Int, _ lat: Double) -> MapItem {
            MapItem(selection: .person(n), kind: .person(initials: "X", seed: n), title: "\(n)", coordinate: .init(latitude: lat, longitude: 13.4))
        }
        let items = [item(1, 52.5000), item(2, 52.5005), item(3, 52.6)]
        XCTAssertEqual(Clustering.clusters(items, span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5)).count, 2)
        XCTAssertEqual(Clustering.clusters(items, span: .init(latitudeDelta: 0.001, longitudeDelta: 0.001)).count, 3)
    }

    @MainActor func testConnectLinkRoundTrip() throws {
        let s = Session(server: URL(string: "https://find.example.org")!, apiKey: "abc123")
        let back = try XCTUnwrap(SessionStore.session(fromConnect: SessionStore.connectURL(for: s)))
        XCTAssertEqual(back, s)
        XCTAssertEqual(SessionStore.normalizedServer("find.example.org/")?.absoluteString, "https://find.example.org")
        XCTAssertEqual(SessionStore.normalizedServer("http://10.0.0.5:3000")?.absoluteString, "http://10.0.0.5:3000")
    }

    @MainActor func testPayloadFormat() {
        let loc = CLLocation(coordinate: .init(latitude: 52.5, longitude: 13.4), altitude: 30, horizontalAccuracy: 8.4,
                             verticalAccuracy: 3, course: 0, speed: 2, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        let p = PointQueue.payload(for: loc, trigger: .visit, deviceId: "dev1")
        XCTAssertEqual(p["_type"] as? String, "location")
        XCTAssertEqual(p["tst"] as? Int, 1_800_000_000)
        XCTAssertEqual(p["acc"] as? Int, 8)
        XCTAssertEqual(p["t"] as? String, "v")
        XCTAssertEqual(p["topic"] as? String, "owntracks/homefind/dev1")
        XCTAssertEqual(p["vel"] as? Int, 7)
    }

    @MainActor func testDateParsing() {
        XCTAssertNotNil(DawarichClient.parseDate("2026-11-08T00:07:21.000+01:00"))
        XCTAssertNotNil(DawarichClient.parseDate("2026-11-08T00:07:21+01:00"))
    }
}

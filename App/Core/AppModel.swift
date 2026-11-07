import Foundation
import CoreLocation
import MapKit
import SwiftUI
import UserNotifications

enum AppTab: String, CaseIterable, Identifiable { case people, devices, me; var id: String { rawValue } }

enum MapSelection: Hashable {
    case person(Int)
    case device(String)       // eigenes Gerät (Kennung)
    case familyDevice(Int)    // Gerät eines Familienmitglieds (= dessen Standort)
}

/// Zentraler Zustand: Anmeldung, Familie, Geräte, Orte, Senden, Abfrage-Takt.
@Observable
final class AppModel {
    // Anmeldung
    private(set) var session: Session?
    var client: DawarichClient? { session?.client }

    // Serverzustand
    private(set) var family: FamilyState?
    private(set) var notInFamily = false
    private(set) var locations: [Int: MemberLocation] = [:]
    private(set) var devices: [DeviceRecord] = []
    private(set) var accountSettings = AccountSettings()
    private(set) var places: [ServerPlace] = []
    private(set) var lastRefresh: Date?
    private(set) var offline = false
    private(set) var lastSentAt: Date?

    private var deviceNoteIds: [String: Int] = [:]
    private var settingsNoteId: Int?

    // Lokal
    let location = LocationService()
    let alerts = AlertStore()
    let regions = RegionMonitor()
    let namer = PlaceNamer()
    private let queue = PointQueue()

    var favorites: Set<Int> = Set(UserDefaults.standard.array(forKey: "favorites") as? [Int] ?? []) {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }
    var dismissedShareBack: Set<Int> = Set(UserDefaults.standard.array(forKey: "dismissedShareBack") as? [Int] ?? []) {
        didSet { UserDefaults.standard.set(Array(dismissedShareBack), forKey: "dismissedShareBack") }
    }
    var distanceUnit: DistanceUnit = DistanceUnit(rawValue: UserDefaults.standard.string(forKey: "distanceUnit") ?? "")
        ?? (Locale.current.measurementSystem == .us ? .miles : .kilometers) {
        didSet { UserDefaults.standard.set(distanceUnit.rawValue, forKey: "distanceUnit") }
    }
    var mapMode: MapMode = MapMode(rawValue: UserDefaults.standard.string(forKey: "mapMode") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(mapMode.rawValue, forKey: "mapMode") }
    }
    var showsTraffic = UserDefaults.standard.bool(forKey: "showsTraffic") {
        didSet { UserDefaults.standard.set(showsTraffic, forKey: "showsTraffic") }
    }
    /// Sparsames Senden im Hintergrund (signifikante Ortswechsel + Besuche).
    var backgroundSending = UserDefaults.standard.object(forKey: "backgroundSending") as? Bool ?? true {
        didSet { UserDefaults.standard.set(backgroundSending, forKey: "backgroundSending"); updateBackgroundMonitoring() }
    }
    var onboardingDone = UserDefaults.standard.bool(forKey: "onboardingDone") {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }
    /// „Bis zum Ende des Tages“: Dawarich rundet auf ganze Stunden, die App schaltet um Mitternacht ab.
    private(set) var endOfDayCutoff: Date? = UserDefaults.standard.object(forKey: "eodCutoff") as? Date {
        didSet { UserDefaults.standard.set(endOfDayCutoff, forKey: "eodCutoff") }
    }

    // Oberfläche
    var tab: AppTab = .people
    var peoplePath: [Int] = []
    var devicesPath: [MapSelection] = []
    var detent: PresentationDetent = .medium
    var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    var visibleRegion: MKCoordinateRegion?
    var toast: String?
    var errorMessage: String?
    var webURL: URL?

    private var pollTask: Task<Void, Never>?
    private var knownSharing: Set<Int>? = nil

    init() {
        session = SessionStore.load()
        if ProcessInfo.processInfo.environment["FIND_SKIP_ONBOARDING"] == "1" { onboardingDone = true }
        location.onLocation = { [weak self] loc, trigger in self?.handleLocation(loc, trigger: trigger) }
        regions.onEvent = { [weak self] id, entered, date in self?.handleRegion(id, entered: entered, date: date) }
        Notifier.registerCategories()
        if session != nil { startServices() }
    }

    // MARK: Anmelden / Abmelden

    func signIn(_ s: Session) async throws {
        try await s.client.health()
        _ = try await s.client.me()
        SessionStore.save(s)
        session = s
        family = nil; locations = [:]; devices = []; places = []
        startServices()
        await refreshAll()
        // Dieses Gerät war früher entfernt → wieder zulassen.
        if accountSettings.removed.contains(ThisDevice.id) {
            accountSettings.removed.removeAll { $0 == ThisDevice.id }
            await saveAccountSettings()
        }
    }

    func signOut() {
        pollTask?.cancel()
        location.stopBackground()
        location.stopForeground()
        regions.sync([], current: nil)
        queue.clear()
        SessionStore.clear()
        session = nil
        family = nil; locations = [:]; devices = []; places = []
        peoplePath = []; devicesPath = []
        knownSharing = nil
    }

    private func startServices() {
        regions.start()
        updateBackgroundMonitoring()
    }

    // MARK: Abfrage-Takt (kein Push → Abfrage, solange sichtbar; im Hintergrund Abruf)

    func sceneBecameActive() {
        guard session != nil else { return }
        location.startForeground()
        pollTask?.cancel()
        pollTask = Task {
            var tick = 0
            while !Task.isCancelled {
                await refreshFamily()
                if tick % 4 == 0 { await refreshDevices() }
                if tick % 20 == 0 { await refreshPlaces() }
                tick += 1
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func sceneEnteredBackground() {
        pollTask?.cancel()
        location.stopForeground()
        updateBackgroundMonitoring()
        BackgroundRefresh.schedule(endOfDay: endOfDayCutoff)
    }

    /// Hintergrund-Abruf (BGAppRefresh): Familie abgleichen, Regeln prüfen, Puffer senden.
    func backgroundRefresh() async {
        guard session != nil else { return }
        await refreshFamily(background: true)
        if let client { _ = await queue.flush(using: client) }
        BackgroundRefresh.schedule(endOfDay: endOfDayCutoff)
    }

    func refreshAll() async {
        await refreshFamily()
        await refreshDevices()
        await refreshPlaces()
    }

    func refreshFamily(background: Bool = false) async {
        guard let client else { return }
        do {
            let state = try await client.family()
            notInFamily = false
            var locs: [Int: MemberLocation] = [:]
            if state.members?.contains(where: { $0.sharingEnabled && $0.userId != state.me?.userId }) == true {
                for l in try await client.familyLocations().locations { locs[l.userId] = l }
            }
            let previousLocations = locations
            family = state
            locations = locs
            offline = false
            lastRefresh = .now
            await enforceEndOfDay()
            evaluateRules(old: previousLocations)
            notifyChanges(state, background: background)
            for l in locs.values where namer.cached(l.coordinate) == nil && l.address == nil { namer.resolve(l.coordinate) }
            if let flushClient = self.client, !queue.pending.isEmpty { _ = await queue.flush(using: flushClient) }
        } catch let e as APIError where e.status == 404 {
            notInFamily = true
            family = nil
            locations = [:]
        } catch let e as APIError where e.status == 401 {
            errorMessage = e.message
        } catch {
            offline = true
        }
    }

    // MARK: Personen

    var meId: Int? { family?.me?.userId }
    var mySharing: FamilyState.Sharing? { family?.me?.sharing }
    var isSharing: Bool { mySharing?.enabled == true }
    var myName: String { family?.members?.first { $0.userId == meId }?.name ?? "" }

    /// Ende des Teilens (früheres von Server-Ablauf und Tagesende).
    var sharingEnds: Date? {
        guard isSharing else { return nil }
        let candidates = [mySharing?.expiresAt, endOfDayCutoff].compactMap { $0 }
        return candidates.min()
    }

    var people: [Person] {
        guard let family, let members = family.members else { return [] }
        let incoming = family.locationRequests?.incoming ?? []
        let outgoing = Set((family.locationRequests?.outgoing ?? []).map(\.targetUserId))
        return members.filter { $0.userId != family.me?.userId }.map { m in
            Person(id: m.userId, name: m.name, email: m.email, isOwner: m.owner, sharesWithMe: m.sharingEnabled,
                   location: m.sharingEnabled ? locations[m.userId] : nil,
                   incomingRequest: incoming.first { $0.requester.userId == m.userId },
                   requestSent: outgoing.contains(m.userId), isFavorite: favorites.contains(m.userId))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func person(_ id: Int) -> Person? { people.first { $0.id == id } }

    /// Personen mit offener Aktion für den Abschnitt „Mitteilungen“.
    var pendingPeople: [Person] {
        people.filter { $0.incomingRequest != nil || ($0.sharesWithMe && !isSharing && !dismissedShareBack.contains($0.id)) }
    }

    func share(_ duration: ShareDuration, with name: String? = nil) async {
        guard let client else { return }
        do {
            try await client.setSharing(enabled: true, duration: duration.serverValue())
            endOfDayCutoff = duration == .endOfDay ? ShareDuration.endOfDay(now: .now, calendar: .current) : nil
            await refreshFamily()
            sendCurrentLocationNow()
            scheduleExpiryNotice()
            if let name { toast = String(localized: "Du teilst deinen Standort jetzt mit \(name).") }
            else { toast = String(localized: "Du teilst deinen Standort jetzt mit deiner Familie.") }
        } catch { errorMessage = error.localizedDescription }
    }

    func stopSharing() async {
        guard let client else { return }
        do {
            try await client.setSharing(enabled: false)
            endOfDayCutoff = nil
            Notifier.cancel("sharing-expiry")
            await refreshFamily()
            toast = String(localized: "Dein Standort wird nicht mehr geteilt.")
        } catch { errorMessage = error.localizedDescription }
    }

    func requestLocation(of person: Person) async {
        guard let client else { return }
        do {
            try await client.requestLocation(of: person.id)
            await refreshFamily()
            toast = String(localized: "Anfrage an \(person.firstName) gesendet.")
        } catch { errorMessage = error.localizedDescription }
    }

    func accept(_ request: FamilyState.IncomingRequest, duration: ShareDuration) async {
        guard let client else { return }
        do {
            try await client.acceptRequest(request.id, duration: duration.serverValue())
            endOfDayCutoff = duration == .endOfDay ? ShareDuration.endOfDay(now: .now, calendar: .current) : nil
            await refreshFamily()
            sendCurrentLocationNow()
            scheduleExpiryNotice()
        } catch { errorMessage = error.localizedDescription }
    }

    func decline(_ request: FamilyState.IncomingRequest) async {
        guard let client else { return }
        do {
            try await client.declineRequest(request.id)
            await refreshFamily()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleFavorite(_ id: Int) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    }

    /// Weboberfläche des Servers (z. B. Familie verwalten, Einladungen).
    func openWeb(_ path: String) { webURL = webLink(path) }
    func webLink(_ path: String) -> URL? { session?.server.appending(path: path) }

    private func enforceEndOfDay() async {
        guard let cutoff = endOfDayCutoff else { return }
        if !isSharing { endOfDayCutoff = nil; return }
        if Date.now >= cutoff, let client {
            _ = try? await client.setSharing(enabled: false)
            endOfDayCutoff = nil
            if let s = try? await client.family() { family = s }
        }
    }

    private func scheduleExpiryNotice() {
        Notifier.cancel("sharing-expiry")
        guard let end = sharingEnds else { return }
        Notifier.post(id: "sharing-expiry", title: String(localized: "Standort wird nicht mehr geteilt"),
                      body: String(localized: "Die gewählte Dauer ist abgelaufen. Deine Familie sieht deinen Standort nicht mehr."),
                      at: end)
    }

    /// Lokale Mitteilungen statt Push: neue Anfragen und „teilt jetzt mit dir“.
    private func notifyChanges(_ state: FamilyState, background: Bool) {
        let members = state.members ?? []
        let sharingNow = Set(members.filter { $0.sharingEnabled && $0.userId != state.me?.userId }.map(\.userId))
        defer { knownSharing = sharingNow }
        var notified = Set(UserDefaults.standard.array(forKey: "notifiedRequests") as? [Int] ?? [])
        let active = UIApplication.shared.applicationState == .active
        for r in state.locationRequests?.incoming ?? [] where !notified.contains(r.id) {
            notified.insert(r.id)
            guard !active else { continue }
            let name = members.first { $0.userId == r.requester.userId }?.name ?? r.requester.email
            Notifier.post(id: "request-\(r.id)", title: "HomeFind",
                          body: String(localized: "\(name) (\(r.requester.email)) möchte deinem Standort folgen."),
                          category: Notifier.requestCategory, userInfo: ["requestId": r.id])
        }
        UserDefaults.standard.set(Array(notified), forKey: "notifiedRequests")
        guard let known = knownSharing, !active else { return }
        for id in sharingNow.subtracting(known) {
            guard let m = members.first(where: { $0.userId == id }) else { continue }
            let body = isSharing ? String(localized: "\(m.name) teilt jetzt den Standort mit dir.")
                : String(localized: "\(m.name) teilt jetzt den Standort mit dir. Möchtest du deinen Standort auch teilen?")
            Notifier.post(id: "offer-\(id)-\(Int(Date.now.timeIntervalSince1970))", title: "HomeFind", body: body,
                          userInfo: ["personId": id])
        }
    }

    /// Antwort auf eine Mitteilungs-Aktion (Annehmen/Ablehnen direkt aus der Mitteilung).
    func handleNotificationAction(_ action: String, userInfo: [AnyHashable: Any]) async {
        if let pid = userInfo["personId"] as? Int { select(.person(pid)); return }
        guard let rid = userInfo["requestId"] as? Int else { return }
        if family == nil { await refreshFamily(background: true) }
        guard let req = family?.locationRequests?.incoming.first(where: { $0.id == rid }) else { return }
        switch action {
        case Notifier.acceptHour: await accept(req, duration: .oneHour)
        case Notifier.acceptForever: await accept(req, duration: .indefinitely)
        case Notifier.decline: await decline(req)
        default: select(.person(req.requester.userId))
        }
    }

    // MARK: Ortsregeln

    private func evaluateRules(old: [Int: MemberLocation]) {
        for (id, loc) in locations {
            let fired = alerts.evaluate(personId: id, location: loc)
            let name = person(id)?.name ?? loc.name ?? ""
            for r in fired {
                let body = r.trigger == .arrives ? String(localized: "\(name) ist bei „\(r.placeName)“ angekommen.")
                    : String(localized: "\(name) hat „\(r.placeName)“ verlassen.")
                Notifier.post(id: "fence-\(r.id)-\(loc.timestamp)", title: "HomeFind", body: body,
                              category: Notifier.fenceCategory, userInfo: ["personId": id])
            }
        }
    }

    private func handleRegion(_ id: String, entered: Bool, date: Date) {
        for r in alerts.evaluateMe(regionId: id, entered: entered) {
            let body = entered ? String(localized: "Du bist bei „\(r.placeName)“ angekommen.")
                : String(localized: "Du hast „\(r.placeName)“ verlassen.")
            Notifier.post(id: "fence-me-\(r.id)-\(Int(date.timeIntervalSince1970))", title: "HomeFind", body: body,
                          category: Notifier.fenceCategory)
        }
        // Übergang an Dawarich melden (Geofence-Ereignis im eigenen Konto).
        if id.hasPrefix("place:"), let pid = Int(id.dropFirst(6)), let client, let loc = location.lastLocation ?? places.first(where: { $0.id == pid }).map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude) }) {
            Task {
                try? await client.postTransition(placeId: pid, enter: entered, at: date, latitude: loc.coordinate.latitude,
                                                 longitude: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy,
                                                 deviceId: ThisDevice.id)
            }
        }
    }

    /// Regionen neu setzen: eigene Orte (für Dawarich-Übergänge) + eigene Regeln.
    func syncRegions() {
        guard session != nil else { return }
        var list: [RegionMonitor.Region] = []
        var seen = Set<String>()
        for r in alerts.rules where r.subject == .me && r.enabled && !seen.contains(r.regionId) {
            seen.insert(r.regionId)
            list.append(.init(id: r.regionId, center: r.center, radius: r.radius))
        }
        for p in places where !seen.contains("place:\(p.id)") {
            seen.insert("place:\(p.id)")
            list.append(.init(id: "place:\(p.id)", center: p.coordinate, radius: p.radius))
        }
        regions.sync(list, current: location.lastLocation)
    }

    // MARK: Orte (Standortnamen)

    func refreshPlaces() async {
        guard let client else { return }
        if let p = try? await client.places() { places = p.sorted { $0.name < $1.name }; syncRegions() }
    }

    func addPlace(name: String, coordinate: CLLocationCoordinate2D, radius: Double) async {
        guard let client else { return }
        do {
            _ = try await client.createPlace(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radius)
            await refreshPlaces()
        } catch { errorMessage = error.localizedDescription }
    }

    func renamePlace(_ place: ServerPlace, to name: String) async {
        guard let client else { return }
        var p = place; p.name = name
        do { try await client.updatePlace(p); await refreshPlaces() } catch { errorMessage = error.localizedDescription }
    }

    func deletePlace(_ place: ServerPlace) async {
        guard let client else { return }
        do { try await client.deletePlace(place.id); await refreshPlaces() } catch { errorMessage = error.localizedDescription }
    }

    /// Name eines Orts für eine Koordinate (eigener Ort → Serveradresse → Apple).
    func placeName(for c: CLLocationCoordinate2D, serverAddress: String? = nil) -> String? {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        if let p = places.first(where: { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radius }) {
            return p.name
        }
        if let a = serverAddress, !a.isEmpty { return a }
        return namer.cached(c)
    }

    func distance(to c: CLLocationCoordinate2D) -> CLLocationDistance? {
        guard let me = location.lastLocation else { return nil }
        return me.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    // MARK: Senden (sparsam)

    var isThisMeDevice: Bool { accountSettings.meDevice == nil || accountSettings.meDevice == ThisDevice.id }
    var meDeviceName: String? {
        guard let id = accountSettings.meDevice else { return nil }
        return devices.first { $0.id == id }?.name
    }

    private var lastSentLocation: CLLocation?
    private var lastDeviceUpdate: (date: Date, location: CLLocation)?

    private func handleLocation(_ loc: CLLocation, trigger: LocationService.Trigger) {
        guard session != nil else { return }
        if namer.cached(loc.coordinate) == nil { namer.resolve(loc.coordinate) }
        let background = trigger != .foreground
        var bgTask = UIBackgroundTaskIdentifier.invalid
        if background { bgTask = UIApplication.shared.beginBackgroundTask(withName: "HomeFindSend") }
        Task {
            await updateDeviceRecord(loc, force: background)
            if shouldSend(loc, trigger: trigger) {
                queue.append(PointQueue.payload(for: loc, trigger: trigger, deviceId: ThisDevice.id))
                lastSentLocation = loc
                lastSentAt = .now
                if let client { _ = await queue.flush(using: client) }
            }
            if background {
                // Bei Ortswechsel im Hintergrund gleich Familie + Regeln mitprüfen (spart eigene Weckungen).
                await refreshFamily(background: true)
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }

    private func shouldSend(_ loc: CLLocation, trigger: LocationService.Trigger) -> Bool {
        guard isSharing, isThisMeDevice else { return false }
        if trigger != .foreground { return backgroundSending }
        guard let last = lastSentLocation else { return true }
        // Vordergrund: höchstens jede Minute oder ab 50 m Bewegung.
        return loc.timestamp.timeIntervalSince(last.timestamp) >= 60 || loc.distance(from: last) >= 50
    }

    func sendCurrentLocationNow() {
        lastSentLocation = nil
        if let loc = location.lastLocation { handleLocation(loc, trigger: .foreground) } else { location.requestOnce() }
    }

    func updateBackgroundMonitoring() {
        guard session != nil, backgroundSending, location.hasAlways else { location.stopBackground(); return }
        location.startBackground()
    }

    var pendingPointCount: Int { queue.pending.count }

    // MARK: Eigene Geräte (private Notizen)

    private static let devicePrefix = "homefind-device:"
    private static let settingsTitle = "homefind-settings"

    func refreshDevices() async {
        guard let client else { return }
        guard let notes = try? await client.notes() else { return }
        var list: [DeviceRecord] = []
        var ids: [String: Int] = [:]
        settingsNoteId = nil
        for n in notes {
            guard let title = n.title else { continue }
            if title == Self.settingsTitle {
                settingsNoteId = n.id
                if let s = try? JSONDecoder.iso.decode(AccountSettings.self, from: Data(n.body.utf8)) { accountSettings = s }
            } else if title.hasPrefix(Self.devicePrefix),
                      let d = try? JSONDecoder.iso.decode(DeviceRecord.self, from: Data(n.body.utf8)) {
                if ids[d.id] == nil { list.append(d); ids[d.id] = n.id }
            }
        }
        deviceNoteIds = ids
        devices = list.filter { !accountSettings.removed.contains($0.id) }
            .sorted { ($0.id == ThisDevice.id ? 0 : 1, $0.name) < ($1.id == ThisDevice.id ? 0 : 1, $1.name) }
        if accountSettings.removed.contains(ThisDevice.id) {
            errorMessage = String(localized: "Dieses iPhone wurde aus deinem Konto entfernt.")
            signOut()
            return
        }
        if accountSettings.meDevice == nil {
            accountSettings.meDevice = ThisDevice.id
            await saveAccountSettings()
        }
        if ids[ThisDevice.id] == nil { await updateDeviceRecord(location.lastLocation, force: true) }
    }

    /// Eigenen Gerätedatensatz aktualisieren – höchstens alle 10 Min. oder ab 250 m (sparsam).
    private func updateDeviceRecord(_ loc: CLLocation?, force: Bool = false) async {
        guard let client else { return }
        if !force, let last = lastDeviceUpdate, let loc,
           Date.now.timeIntervalSince(last.date) < 600, loc.distance(from: last.location) < 250 { return }
        let existing = devices.first { $0.id == ThisDevice.id }
        let battery = ThisDevice.battery
        var rec = DeviceRecord(id: ThisDevice.id, name: existing?.name ?? ThisDevice.defaultName, emoji: existing?.emoji,
                               model: ThisDevice.modelName, system: ThisDevice.system, appVersion: ThisDevice.appVersion,
                               latitude: loc?.coordinate.latitude ?? existing?.latitude,
                               longitude: loc?.coordinate.longitude ?? existing?.longitude,
                               accuracy: loc?.horizontalAccuracy ?? existing?.accuracy,
                               battery: battery.level, charging: battery.charging, updatedAt: .now)
        if loc == nil, let existing { rec.updatedAt = existing.updatedAt }
        await saveDevice(rec, client: client)
        if let loc { lastDeviceUpdate = (.now, loc) }
    }

    private func saveDevice(_ rec: DeviceRecord, client: DawarichClient) async {
        guard let body = try? String(data: JSONEncoder.iso.encode(rec), encoding: .utf8) else { return }
        do {
            if let nid = deviceNoteIds[rec.id] {
                try await client.updateNote(id: nid, body: body)
            } else {
                let n = try await client.createNote(title: Self.devicePrefix + rec.id, body: body)
                deviceNoteIds[rec.id] = n.id
            }
            if let i = devices.firstIndex(where: { $0.id == rec.id }) { devices[i] = rec } else { devices.insert(rec, at: 0) }
        } catch {}
    }

    func renameDevice(_ id: String, name: String, emoji: String?) async {
        guard let client, var rec = devices.first(where: { $0.id == id }) else { return }
        rec.name = name.isEmpty ? ThisDevice.defaultName : name
        rec.emoji = (emoji?.isEmpty ?? true) ? nil : emoji
        await saveDevice(rec, client: client)
    }

    func useAsMyLocation(_ id: String) async {
        accountSettings.meDevice = id
        await saveAccountSettings()
        if id == ThisDevice.id { sendCurrentLocationNow() }
        toast = String(localized: "„Mein Standort“ kommt jetzt von diesem Gerät.")
    }

    func removeDevice(_ id: String) async {
        guard let client else { return }
        if let nid = deviceNoteIds[id] { try? await client.deleteNote(id: nid) }
        deviceNoteIds[id] = nil
        devices.removeAll { $0.id == id }
        if !accountSettings.removed.contains(id) { accountSettings.removed.append(id) }
        if accountSettings.meDevice == id { accountSettings.meDevice = devices.first?.id }
        await saveAccountSettings()
        if id == ThisDevice.id { signOut() }
    }

    private func saveAccountSettings() async {
        guard let client, let body = try? String(data: JSONEncoder.iso.encode(accountSettings), encoding: .utf8) else { return }
        do {
            if let nid = settingsNoteId { try await client.updateNote(id: nid, body: body) }
            else { settingsNoteId = try await client.createNote(title: Self.settingsTitle, body: body).id }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Karte

    func select(_ s: MapSelection) {
        switch s {
        case .person(let id):
            tab = .people
            peoplePath = [id]
            if let l = person(id)?.location { focus(l.coordinate) }
        case .device(let id):
            tab = .devices
            devicesPath = [s]
            if let c = devices.first(where: { $0.id == id })?.coordinate { focus(c) }
        case .familyDevice(let id):
            tab = .devices
            devicesPath = [s]
            if let l = locations[id] { focus(l.coordinate) }
        }
        if detent == .large { detent = .medium }
    }

    func focus(_ c: CLLocationCoordinate2D) {
        // Ziel etwas nach oben versetzt, weil die Infokarte die untere Hälfte bedeckt.
        let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        let shifted = CLLocationCoordinate2D(latitude: c.latitude - span.latitudeDelta * 0.25, longitude: c.longitude)
        withAnimation { camera = .region(MKCoordinateRegion(center: shifted, span: span)) }
    }

    func zoom(by factor: Double) {
        guard let r = visibleRegion else { return }
        let span = MKCoordinateSpan(latitudeDelta: min(150, max(0.0005, r.span.latitudeDelta * factor)),
                                    longitudeDelta: min(300, max(0.0005, r.span.longitudeDelta * factor)))
        withAnimation { camera = .region(MKCoordinateRegion(center: r.center, span: span)) }
    }

    func handleURL(_ url: URL) async {
        if let s = SessionStore.session(fromConnect: url) {
            do { try await signIn(s) } catch { errorMessage = error.localizedDescription }
            return
        }
        guard url.scheme == "homefind", session != nil else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "person": if let id = parts.first.flatMap(Int.init) { select(.person(id)) }
        case "device": if let id = parts.first { select(.device(id)) }
        default: break
        }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }()
}

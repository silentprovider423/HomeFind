import Foundation
import CoreLocation
import UserNotifications

/// Ortsregel „Mitteilung an mich, wenn … ankommt/verlässt“.
/// Liegt nur auf diesem Gerät und wird hier ausgewertet:
/// - eigene Regeln über Region Monitoring (CLMonitor, max. 20 Regionen),
/// - Regeln über Personen beim Abgleich ihres geteilten Standorts (Vordergrund, Ortswechsel, Hintergrund-Abruf).
nonisolated struct AlertRule: Codable, Identifiable, Equatable {
    enum Subject: Codable, Equatable, Hashable { case me, person(Int) }
    enum Trigger: String, Codable, CaseIterable { case arrives, leaves }

    var id = UUID()
    var subject: Subject
    var personName: String?
    var trigger: Trigger
    var placeName: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var serverPlaceId: Int?
    var repeats: Bool
    var enabled = true
    /// Letzter bekannter Zustand (nur Personen-Regeln): drinnen/draußen/unbekannt.
    var lastInside: Bool?
    var lastTimestamp: Int?

    var center: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: c.latitude, longitude: c.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= radius
    }

    /// Kennung der überwachten Region (gleicher Ort = eine Region).
    var regionId: String {
        if let serverPlaceId { return "place:\(serverPlaceId)" }
        return String(format: "geo:%.5f,%.5f,%.0f", latitude, longitude, radius)
    }
}

enum FenceRadius: Double, CaseIterable, Identifiable {
    case small = 100, medium = 250, large = 500
    var id: Double { rawValue }
}

/// Bewusst `nonisolated`: kein isoliertes deinit (das stürzte beim Freigeben am Ende synchroner Tests ab).
@Observable
nonisolated final class AlertStore {
    private(set) var rules: [AlertRule] = []
    private let url: URL

    init(fileName: String = "alert-rules.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: fileName)
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([AlertRule].self, from: d) { rules = r }
    }

    func rules(for subject: AlertRule.Subject) -> [AlertRule] { rules.filter { $0.subject == subject } }

    func add(_ rule: AlertRule) { rules.append(rule); save() }
    func remove(_ id: UUID) { rules.removeAll { $0.id == id }; save() }
    func update(_ rule: AlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule; save()
    }
    func removeAll() { rules = []; save() }

    /// Personen-Regeln gegen einen neuen Standort prüfen. Liefert die ausgelösten Regeln.
    func evaluate(personId: Int, location: MemberLocation) -> [AlertRule] {
        var fired: [AlertRule] = []
        var changed = false
        for i in rules.indices where rules[i].subject == .person(personId) && rules[i].enabled {
            if let last = rules[i].lastTimestamp, location.timestamp <= last { continue }
            let inside = rules[i].contains(location.coordinate)
            let before = rules[i].lastInside
            rules[i].lastInside = inside
            rules[i].lastTimestamp = location.timestamp
            changed = true
            guard let before, before != inside else { continue }
            let matches = (inside && rules[i].trigger == .arrives) || (!inside && rules[i].trigger == .leaves)
            if matches {
                fired.append(rules[i])
                if !rules[i].repeats { rules[i].enabled = false }
            }
        }
        if changed { save() }
        return fired
    }

    /// Eigene Regeln zu einem Regions-Ereignis.
    func evaluateMe(regionId: String, entered: Bool) -> [AlertRule] {
        var fired: [AlertRule] = []
        for i in rules.indices where rules[i].subject == .me && rules[i].enabled && rules[i].regionId == regionId {
            let matches = (entered && rules[i].trigger == .arrives) || (!entered && rules[i].trigger == .leaves)
            if matches {
                fired.append(rules[i])
                if !rules[i].repeats { rules[i].enabled = false }
            }
        }
        if !fired.isEmpty { save() }
        return fired
    }

    private func save() {
        if let d = try? JSONEncoder().encode(rules) { try? d.write(to: url, options: .atomic) }
    }
}

/// Region Monitoring über CLMonitor (iOS 17+). Weckt die App auch im Hintergrund.
final class RegionMonitor {
    struct Region: Equatable { let id: String; let center: CLLocationCoordinate2D; let radius: Double
        static func == (a: Region, b: Region) -> Bool {
            a.id == b.id && a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude && a.radius == b.radius
        }
    }
    static let maxRegions = 20

    private var monitor: CLMonitor?
    private var listening: Task<Void, Never>?
    private var current: [Region] = []
    var onEvent: ((String, Bool, Date) -> Void)?

    func start() {
        guard listening == nil else { return }
        listening = Task {
            let m = await CLMonitor("HomeFindRegions")
            self.monitor = m
            await self.apply()
            do {
                for try await event in await m.events {
                    let entered = event.state == .satisfied
                    self.onEvent?(event.identifier, entered, event.date)
                }
            } catch {}
        }
    }

    /// Gewünschte Regionen setzen (zu viele → die ersten 20).
    func sync(_ regions: [Region], current location: CLLocation?) {
        lastKnown = location
        let wanted = Array(regions.prefix(Self.maxRegions))
        guard wanted != current else { return }
        current = wanted
        Task { await apply() }
    }

    private var lastKnown: CLLocation?

    private func apply() async {
        guard let monitor else { return }
        let wantedIds = Set(current.map(\.id))
        for id in await monitor.identifiers where !wantedIds.contains(id) {
            await monitor.remove(id)
        }
        let existing = Set(await monitor.identifiers)
        for r in current where !existing.contains(r.id) {
            // Startzustand aus der aktuellen Position, damit beim Anlegen keine falsche „Ankunft“ kommt.
            var assumed: CLMonitor.Event.State = .unknown
            if let lastKnown {
                let inside = lastKnown.distance(from: CLLocation(latitude: r.center.latitude, longitude: r.center.longitude)) <= r.radius
                assumed = inside ? .satisfied : .unsatisfied
            }
            await monitor.add(CLMonitor.CircularGeographicCondition(center: r.center, radius: r.radius),
                              identifier: r.id, assuming: assumed)
        }
    }

    var regionCount: Int { current.count }
}

/// Lokale Mitteilungen (kein Push: es gibt keinen APNs-Schlüssel).
enum Notifier {
    static let requestCategory = "LOCATION_REQUEST"
    static let fenceCategory = "FENCE"
    static let acceptHour = "ACCEPT_1H"
    static let acceptForever = "ACCEPT_FOREVER"
    static let decline = "DECLINE"

    static func registerCategories() {
        let a1 = UNNotificationAction(identifier: acceptHour, title: String(localized: "Standort 1 Std. teilen"))
        let a2 = UNNotificationAction(identifier: acceptForever, title: String(localized: "Unbegrenzt teilen"))
        let d = UNNotificationAction(identifier: decline, title: String(localized: "Ablehnen"), options: [.destructive])
        let request = UNNotificationCategory(identifier: requestCategory, actions: [a1, a2, d], intentIdentifiers: [])
        let fence = UNNotificationCategory(identifier: fenceCategory, actions: [], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([request, fence])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(id: String, title: String, body: String, category: String? = nil, userInfo: [String: Any] = [:],
                     at date: Date? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = userInfo
        if let category { c.categoryIdentifier = category }
        var trigger: UNNotificationTrigger?
        if let date {
            let interval = date.timeIntervalSinceNow
            guard interval > 1 else { return }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

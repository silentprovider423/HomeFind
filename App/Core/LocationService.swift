import Foundation
import CoreLocation
import UIKit

/// Ortung dieses iPhones – bewusst sparsam:
/// - Vordergrund: normale Ortung (10 m genau, erst ab 25 m Bewegung),
/// - Hintergrund: nur „signifikante Ortswechsel“ (~500 m) und Besuche (Ankunft/Abfahrt) – kaum Akku.
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Trigger: String { case foreground = "u", significant = "p", visit = "v", region = "c" }

    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var reducedAccuracy = false
    private(set) var lastLocation: CLLocation?
    private(set) var foregroundActive = false
    private(set) var backgroundActive = false

    /// Wird bei jeder neuen Position gerufen (Vordergrund, Ortswechsel, Besuch).
    var onLocation: ((CLLocation, Trigger) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .other
        updateAuthorization()
    }

    var servicesDenied: Bool { authorization == .denied || authorization == .restricted }
    var hasAlways: Bool { authorization == .authorizedAlways }
    var hasAnyPermission: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    /// Genaue Ortung, solange die App sichtbar ist.
    func startForeground() {
        guard hasAnyPermission, !foregroundActive else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.startUpdatingLocation()
        foregroundActive = true
    }

    func stopForeground() {
        guard foregroundActive else { return }
        manager.stopUpdatingLocation()
        foregroundActive = false
    }

    /// Sparsames Senden im Hintergrund (braucht „Immer“).
    func startBackground() {
        guard hasAlways, !backgroundActive else { return }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
        backgroundActive = true
    }

    func stopBackground() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        backgroundActive = false
    }

    /// Einmalige frische Position (z. B. nach „Als Mein Standort verwenden“).
    func requestOnce() {
        guard hasAnyPermission else { return }
        manager.requestLocation()
    }

    private func updateAuthorization() {
        authorization = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    }

    // MARK: CLLocationManagerDelegate (läuft auf dem Haupt-Thread, weil der Manager dort erzeugt wurde)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            updateAuthorization()
            NotificationCenter.default.post(name: .locationAuthorizationChanged, object: nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
            lastLocation = loc
            let state = UIApplication.shared.applicationState
            onLocation?(loc, state == .active ? .foreground : .significant)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let coordinate = visit.coordinate, accuracy = visit.horizontalAccuracy
        let date = visit.departureDate == .distantFuture ? visit.arrivalDate : visit.departureDate
        MainActor.assumeIsolated {
            let loc = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: date)
            onLocation?(loc, .visit)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension Notification.Name {
    static let locationAuthorizationChanged = Notification.Name("HomeFindLocationAuthorizationChanged")
}

/// Puffer für Punkte, die (noch) nicht beim Server angekommen sind – überlebt Neustarts.
final class PointQueue {
    private let url: URL
    private(set) var pending: [[String: Any]] = []
    static let maxItems = 500

    init(fileName: String = "pending-points.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: fileName)
        if let d = try? Data(contentsOf: url), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            pending = a
        }
    }

    func append(_ point: [String: Any]) {
        pending.append(point)
        if pending.count > Self.maxItems { pending.removeFirst(pending.count - Self.maxItems) }
        save()
    }

    /// Alles der Reihe nach senden; bei Fehler bleibt der Rest im Puffer.
    func flush(using client: DawarichClient) async -> Int {
        var sent = 0
        while let first = pending.first {
            do {
                try await client.postPoint(first)
                pending.removeFirst()
                sent += 1
            } catch {
                break
            }
        }
        save()
        return sent
    }

    func clear() { pending = []; save() }

    private func save() {
        if let d = try? JSONSerialization.data(withJSONObject: pending) { try? d.write(to: url, options: .atomic) }
    }

    /// OwnTracks-Punkt (Format, das Dawarich unter /api/v1/owntracks/points annimmt).
    static func payload(for loc: CLLocation, trigger: LocationService.Trigger, deviceId: String) -> [String: Any] {
        var p: [String: Any] = [
            "_type": "location",
            "lat": loc.coordinate.latitude,
            "lon": loc.coordinate.longitude,
            "tst": Int(loc.timestamp.timeIntervalSince1970),
            "acc": Int(loc.horizontalAccuracy.rounded()),
            "tid": deviceId,
            "topic": "owntracks/homefind/\(deviceId)",
            "t": trigger.rawValue,
            "m": trigger == .foreground ? 2 : 1,
        ]
        if loc.verticalAccuracy >= 0 { p["alt"] = Int(loc.altitude.rounded()) }
        if loc.speed >= 0 { p["vel"] = Int((loc.speed * 3.6).rounded()) }
        let battery = ThisDevice.battery
        if let level = battery.level { p["batt"] = level }
        if let charging = battery.charging { p["bs"] = charging ? 2 : 1 }
        return p
    }
}

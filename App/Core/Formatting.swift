import Foundation
import CoreLocation
import MapKit

enum Fmt {
    /// „Jetzt“, „vor 5 Min.“, „vor 2 Std.“ …
    static func ago(_ date: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return String(localized: "Jetzt") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    static func distance(_ meters: CLLocationDistance, unit: DistanceUnit) -> String {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.unitStyle = .medium
        f.numberFormatter.maximumFractionDigits = 1
        switch unit {
        case .kilometers:
            if meters < 1000 {
                f.numberFormatter.maximumFractionDigits = 0
                return f.string(from: Measurement(value: (meters / 10).rounded() * 10, unit: UnitLength.meters))
            }
            if meters >= 10_000 { f.numberFormatter.maximumFractionDigits = 0 }
            return f.string(from: Measurement(value: meters / 1000, unit: UnitLength.kilometers))
        case .miles:
            let mi = meters / 1609.344
            if mi >= 10 { f.numberFormatter.maximumFractionDigits = 0 }
            return f.string(from: Measurement(value: mi, unit: UnitLength.miles))
        }
    }

    /// Restzeit des Teilens: „Noch 3 Stunden“ / „Noch 25 Minuten“.
    static func remaining(until date: Date, now: Date = .now) -> String {
        let s = max(0, date.timeIntervalSince(now))
        if s >= 3600 {
            let h = Int((s / 3600).rounded())
            return h == 1 ? String(localized: "Noch 1 Stunde") : String(localized: "Noch \(h) Stunden")
        }
        let m = max(1, Int((s / 60).rounded(.up)))
        return m == 1 ? String(localized: "Noch 1 Minute") : String(localized: "Noch \(m) Minuten")
    }

    static func eta(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        return f.string(from: max(60, seconds)) ?? ""
    }
}

/// Ortsnamen: eigene Orte (Privat, Arbeit …) zuerst, dann Adresse vom Server, sonst Apple-Rückwärtssuche
/// (abschaltbar, weil dabei Koordinaten an Apple gehen).
@Observable
final class PlaceNamer {
    private(set) var names: [String: String] = [:]
    private var inFlight: Set<String> = []
    var useApple = UserDefaults.standard.object(forKey: "geocodeWithApple") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useApple, forKey: "geocodeWithApple") }
    }

    private func key(_ c: CLLocationCoordinate2D) -> String { String(format: "%.4f,%.4f", c.latitude, c.longitude) }

    func cached(_ c: CLLocationCoordinate2D) -> String? { names[key(c)] }

    func resolve(_ c: CLLocationCoordinate2D) {
        let k = key(c)
        guard useApple, names[k] == nil, !inFlight.contains(k) else { return }
        inFlight.insert(k)
        guard let req = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)) else {
            inFlight.remove(k); return
        }
        req.preferredLocale = .current
        req.getMapItems { [weak self] items, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight.remove(k)
                guard let item = items?.first else { return }
                let name = item.address?.shortAddress ?? item.addressRepresentations?.cityWithContext ?? item.name
                if let name, !name.isEmpty { self.names[k] = name.replacingOccurrences(of: "\n", with: ", ") }
            }
        }
    }
}

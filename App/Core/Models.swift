import Foundation
import CoreLocation

// MARK: - Server-Antworten (Dawarich)

/// Antwort von `GET /api/v1/families/mine`.
struct FamilyState: Decodable, Equatable {
    struct Family: Decodable, Equatable { let name: String }
    struct Sharing: Decodable, Equatable {
        let enabled: Bool
        let duration: String?
        let expiresAt: Date?
        let startedAt: Date?
    }
    struct Me: Decodable, Equatable {
        let userId: Int
        let owner: Bool
        let sharing: Sharing
    }
    struct Member: Decodable, Equatable, Identifiable {
        let userId: Int
        let email: String
        let name: String
        let owner: Bool
        let sharingEnabled: Bool
        let sharingStartedAt: Date?
        let joinedAt: Date?
        var id: Int { userId }
    }
    struct IncomingRequest: Decodable, Equatable, Identifiable {
        struct Requester: Decodable, Equatable { let userId: Int; let email: String }
        let id: Int
        let requester: Requester
        let suggestedDuration: String?
        let expiresAt: Date?
        let createdAt: Date?
    }
    struct OutgoingRequest: Decodable, Equatable, Identifiable {
        let id: Int
        let targetUserId: Int
        let createdAt: Date?
    }
    struct Requests: Decodable, Equatable {
        let incoming: [IncomingRequest]
        let outgoing: [OutgoingRequest]
    }

    let family: Family?
    let me: Me?
    let members: [Member]?
    let locationRequests: Requests?
}

/// Ein Eintrag aus `GET /api/v1/families/locations` (letzter Standort einer Person, die teilt).
nonisolated struct MemberLocation: Decodable, Equatable {
    let userId: Int
    let address: String?
    let name: String?
    let latitude: Double
    let longitude: Double
    let timestamp: Int
    let battery: Int?
    let batteryStatus: String?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

struct FamilyLocations: Decodable {
    let locations: [MemberLocation]
    let sharingEnabled: Bool?
}

struct SharingResult: Decodable {
    let success: Bool?
    let enabled: Bool?
    let duration: String?
    let expiresAt: Date?
    let message: String?
}

struct CreatedLocationRequest: Decodable {
    struct Request: Decodable { let id: Int; let targetUserId: Int; let expiresAt: Date? }
    let request: Request
}

struct LoginResult: Decodable {
    let userId: Int?
    let email: String?
    let apiKey: String?
    let twoFactorRequired: Bool?
}

struct UserMe: Decodable {
    struct User: Decodable { let id: Int; let email: String }
    let user: User
}

/// Ein Ort des eigenen Kontos (`/api/v1/places`), bei uns „Standortname“ (Privat, Arbeit …).
struct ServerPlace: Codable, Equatable, Identifiable {
    let id: Int
    var name: String
    var latitude: Double
    var longitude: Double
    var visitRadius: Double?
    var geofence: Bool?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var radius: Double { max(visitRadius ?? 150, 100) }
}

/// Notiz (`/api/v1/notes`) – wir nutzen private Notizen als kleinen Gerätespeicher.
struct ServerNote: Decodable, Identifiable {
    let id: Int
    let title: String?
    let body: String
    let updatedAt: Date?
}

// MARK: - Eigene Geräte (als private Notiz auf dem Server)

/// Zustand eines eigenen Geräts mit HomeFind. Liegt als JSON in einer privaten Notiz
/// „homefind-device:<id>“ – nur das eigene Konto kann sie lesen.
struct DeviceRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var emoji: String?
    var model: String
    var system: String
    var appVersion: String
    var latitude: Double?
    var longitude: Double?
    var accuracy: Double?
    var battery: Int?
    var charging: Bool?
    var updatedAt: Date

    /// Symbol nach Gerätetyp (wenn kein Emoji gewählt ist).
    var symbol: String {
        let m = model.lowercased()
        if m.contains("ipad") { return "ipad" }
        if m.contains("mac") { return "laptopcomputer" }
        if m.contains("watch") { return "applewatch" }
        return "iphone"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }
}

/// Gemeinsame Einstellungen aller eigenen Geräte (Notiz „homefind-settings“).
struct AccountSettings: Codable, Equatable {
    /// Gerät, dessen Standort die Familie sieht („Mein Standort“).
    var meDevice: String?
    /// Entfernte Geräte: sie hören beim nächsten Abgleich auf zu senden.
    var removed: [String] = []
}

// MARK: - App-Modell

enum ShareDuration: String, CaseIterable, Identifiable {
    case oneHour, endOfDay, indefinitely
    var id: String { rawValue }

    /// Wert für Dawarich: "1h", ganze Stunden bis Mitternacht, "permanent".
    func serverValue(now: Date = .now, calendar: Calendar = .current) -> String {
        switch self {
        case .oneHour: return "1h"
        case .indefinitely: return "permanent"
        case .endOfDay: return String(Self.hoursUntilEndOfDay(now: now, calendar: calendar))
        }
    }

    /// Dawarich kennt nur ganze Stunden → aufrunden; die App schaltet um Mitternacht selbst ab.
    static func hoursUntilEndOfDay(now: Date, calendar: Calendar) -> Int {
        let end = endOfDay(now: now, calendar: calendar)
        return max(1, Int((end.timeIntervalSince(now) / 3600).rounded(.up)))
    }

    static func endOfDay(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!)
    }
}

/// Eine Person der Familie, aufbereitet für Liste, Karte und Detailkarte.
struct Person: Identifiable, Equatable {
    let id: Int
    let name: String
    let email: String
    let isOwner: Bool
    /// Teilt ihren Standort mit mir.
    let sharesWithMe: Bool
    let location: MemberLocation?
    /// Diese Person möchte meinen Standort sehen.
    let incomingRequest: FamilyState.IncomingRequest?
    /// Ich habe ihren Standort angefordert.
    let requestSent: Bool
    var isFavorite: Bool

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? String(email.prefix(1)).uppercased() : letters.uppercased()
    }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case kilometers, miles
    var id: String { rawValue }
}

enum MapMode: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite
    var id: String { rawValue }
}

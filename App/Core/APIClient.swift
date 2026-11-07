import Foundation

/// Fehler vom Server mit lesbarer Meldung.
struct APIError: LocalizedError, Equatable {
    let status: Int
    let message: String
    var errorDescription: String? { message }

    var isNotInFamily: Bool { status == 404 && message.localizedCaseInsensitiveContains("family") }
}

/// Schlanker Client für die Dawarich-REST-API (Familie, Punkte, Orte, Notizen).
/// Server-Adresse und Schlüssel kommen immer von außen (Anmeldung/Schlüsselbund), nie aus dem Code.
struct DawarichClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    // MARK: Anmeldung

    /// `POST /api/v1/auth/login` → API-Schlüssel des Kontos.
    static func login(server: URL, email: String, password: String, session: URLSession = .shared) async throws -> String {
        var req = URLRequest(url: server.appending(path: "api/v1/auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        let result = try Self.decoder.decode(LoginResult.self, from: data)
        if result.twoFactorRequired == true {
            throw APIError(status: 401, message: String(localized: "Für dieses Konto ist die Zwei-Faktor-Anmeldung aktiv. Melde dich mit einem API-Schlüssel an."))
        }
        guard let key = result.apiKey, !key.isEmpty else {
            throw APIError(status: 500, message: String(localized: "Der Server hat keinen Schlüssel geliefert."))
        }
        return key
    }

    func health() async throws {
        _ = try await send("GET", "api/v1/health", auth: false)
    }

    func me() async throws -> UserMe {
        try await get("api/v1/users/me")
    }

    // MARK: Familie

    func family() async throws -> FamilyState {
        try await get("api/v1/families/mine")
    }

    func familyLocations() async throws -> FamilyLocations {
        try await get("api/v1/families/locations")
    }

    /// Teilen ein/aus. `duration`: "1h", Stundenzahl oder "permanent".
    @discardableResult
    func setSharing(enabled: Bool, duration: String? = nil) async throws -> SharingResult {
        var body: [String: Any] = ["enabled": enabled, "share_history": false]
        if let duration { body["duration"] = duration }
        let data = try await send("PATCH", "api/v1/families/sharing", body: body)
        return try Self.decoder.decode(SharingResult.self, from: data)
    }

    @discardableResult
    func requestLocation(of userId: Int) async throws -> CreatedLocationRequest {
        let data = try await send("POST", "api/v1/families/location_requests", body: ["target_user_id": userId])
        return try Self.decoder.decode(CreatedLocationRequest.self, from: data)
    }

    func acceptRequest(_ id: Int, duration: String) async throws {
        _ = try await send("POST", "api/v1/families/location_requests/\(id)/accept", body: ["duration": duration])
    }

    func declineRequest(_ id: Int) async throws {
        _ = try await send("POST", "api/v1/families/location_requests/\(id)/decline", body: [:])
    }

    // MARK: Punkte

    /// Ein Punkt im OwnTracks-Format (`POST /api/v1/owntracks/points`).
    func postPoint(_ payload: [String: Any]) async throws {
        _ = try await send("POST", "api/v1/owntracks/points", body: payload)
    }

    /// Ankunft/Verlassen eines überwachten Orts melden (`POST /api/v1/points/transitions`).
    func postTransition(placeId: Int, enter: Bool, at date: Date, latitude: Double, longitude: Double,
                        accuracy: Double?, deviceId: String) async throws {
        var body: [String: Any] = [
            "place_id": placeId,
            "event_type": enter ? "enter" : "leave",
            "occurred_at": ISO8601DateFormatter().string(from: date),
            "lonlat": [longitude, latitude],
            "device_id": deviceId,
        ]
        if let accuracy { body["accuracy_m"] = accuracy }
        _ = try await send("POST", "api/v1/points/transitions", body: body)
    }

    // MARK: Orte (Standortnamen)

    func places() async throws -> [ServerPlace] {
        try await get("api/v1/places", query: [URLQueryItem(name: "filter", value: "manual")])
    }

    func createPlace(name: String, latitude: Double, longitude: Double, radius: Double) async throws -> ServerPlace {
        let body: [String: Any] = ["place": ["name": name, "latitude": latitude, "longitude": longitude,
                                             "visit_radius": radius, "geofence": true]]
        let data = try await send("POST", "api/v1/places", body: body)
        return try Self.decoder.decode(ServerPlace.self, from: data)
    }

    func updatePlace(_ place: ServerPlace) async throws {
        let body: [String: Any] = ["place": ["name": place.name, "latitude": place.latitude, "longitude": place.longitude,
                                             "visit_radius": place.radius, "geofence": true]]
        _ = try await send("PATCH", "api/v1/places/\(place.id)", body: body)
    }

    func deletePlace(_ id: Int) async throws {
        _ = try await send("DELETE", "api/v1/places/\(id)")
    }

    // MARK: Notizen (Gerätespeicher)

    func notes() async throws -> [ServerNote] {
        try await get("api/v1/notes", query: [URLQueryItem(name: "standalone", value: "true")])
    }

    @discardableResult
    func createNote(title: String, body: String) async throws -> ServerNote {
        let data = try await send("POST", "api/v1/notes",
                                  body: ["note": ["title": title, "body": body, "noted_at": Self.isoNow()]])
        return try Self.decoder.decode(ServerNote.self, from: data)
    }

    func updateNote(id: Int, body: String) async throws {
        _ = try await send("PATCH", "api/v1/notes/\(id)", body: ["note": ["body": body, "noted_at": Self.isoNow()]])
    }

    func deleteNote(id: Int) async throws {
        _ = try await send("DELETE", "api/v1/notes/\(id)")
    }

    // MARK: Grundlagen

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send("GET", path, query: query)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: 0, message: String(localized: "Antwort des Servers nicht lesbar."))
        }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                      auth: Bool = true) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data)
        return data
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        var message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = obj["error"] as? String { message = m } else if let m = obj["message"] as? String { message = m }
        }
        if http.statusCode == 401 { message = String(localized: "Anmeldung abgelaufen oder Schlüssel ungültig.") }
        throw APIError(status: http.statusCode, message: message)
    }

    private static func isoNow() -> String { ISO8601DateFormatter().string(from: .now) }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Datum: \(s)")
        }
        return d
    }()

    nonisolated static func parseDate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}

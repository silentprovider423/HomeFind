import Foundation
import Security
import UIKit

/// Anmeldung: Server-Adresse + API-Schlüssel. Der Schlüssel liegt im Schlüsselbund.
struct Session: Equatable {
    let server: URL
    let apiKey: String
    var client: DawarichClient { DawarichClient(baseURL: server, apiKey: apiKey) }
}

enum SessionStore {
    private static let service = "org.homeroll.homefind"
    private static let serverKey = "server"

    static func load() -> Session? {
        #if DEBUG
        // Nur Debug: Anmeldung per Startumgebung für Simulator-Tests (kein Passwort-Tippen).
        let env = ProcessInfo.processInfo.environment
        if let s = env["FIND_SERVER"], let url = URL(string: s), let key = env["FIND_TOKEN"], !key.isEmpty {
            return Session(server: url, apiKey: key)
        }
        if env["FIND_LOGGED_OUT"] == "1" { return nil }
        #endif
        guard let s = UserDefaults.standard.string(forKey: serverKey), let url = URL(string: s),
              let key = readKey() else { return nil }
        return Session(server: url, apiKey: key)
    }

    static func save(_ session: Session) {
        UserDefaults.standard.set(session.server.absoluteString, forKey: serverKey)
        writeKey(session.apiKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: serverKey)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }

    private static func readKey() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "apiKey", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func writeKey(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "apiKey"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        // Auch im Hintergrund lesbar (Senden bei Ortswechsel), aber nur auf diesem Gerät.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Server-Adresse normalisieren („host:3000“ → „http://host:3000“).
    static func normalizedServer(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t), url.host() != nil else { return nil }
        return url
    }

    /// Link zum Verbinden eines weiteren Geräts: homefind://connect?server=…&key=…
    static func connectURL(for session: Session) -> URL {
        var c = URLComponents()
        c.scheme = "homefind"
        c.host = "connect"
        c.queryItems = [URLQueryItem(name: "server", value: session.server.absoluteString),
                        URLQueryItem(name: "key", value: session.apiKey)]
        return c.url!
    }

    static func session(fromConnect url: URL) -> Session? {
        guard url.scheme == "homefind", url.host() == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let s = items.first(where: { $0.name == "server" })?.value, let server = URL(string: s),
              let key = items.first(where: { $0.name == "key" })?.value, !key.isEmpty else { return nil }
        return Session(server: server, apiKey: key)
    }
}

/// Kennung und Eckdaten dieses Geräts.
enum ThisDevice {
    static var id: String {
        let k = "deviceId"
        if let id = UserDefaults.standard.string(forKey: k) { return id }
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
        UserDefaults.standard.set(String(id), forKey: k)
        return String(id)
    }

    static var modelName: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) (Simulator)" } ?? "Simulator"
        #else
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }

    static var defaultName: String { UIDevice.current.model } // „iPhone“; eigener Name ist seit iOS 16 ohne Sonderrecht nicht lesbar
    static var system: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    static var battery: (level: Int?, charging: Bool?) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = UIDevice.current.batteryLevel
        let s = UIDevice.current.batteryState
        let level = l < 0 ? nil : Int((l * 100).rounded())
        let charging: Bool? = s == .unknown ? nil : (s == .charging || s == .full)
        return (level, charging)
    }
}

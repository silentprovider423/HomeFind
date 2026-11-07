import SwiftUI
import VisionKit

/// Willkommen + Anmeldung (Server + E-Mail/Passwort, API-Schlüssel oder QR-Code eines anderen Geräts).
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            AppGlyph().frame(width: 96, height: 96)
            Text("Willkommen bei HomeFind").font(.largeTitle.bold()).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 20) {
                feature("person.2.fill", "Personen finden", "Sieh, wo deine Familie gerade ist, und teile deinen Standort – für eine Stunde, bis zum Ende des Tages oder unbegrenzt.")
                feature("laptopcomputer.and.iphone", "Geräte finden", "Alle Geräte mit HomeFind auf einer Karte, mit Batterie und letztem Ort.")
                feature("server.rack", "Dein eigener Server", "Standorte gehen nur an deinen selbst betriebenen Dawarich-Server – nicht an Apple oder andere.")
            }
            .padding(.horizontal, 8)
            Spacer()
            Button { showLogin = true } label: { Text("Weiter").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .accessibilityIdentifier("welcome-continue")
        }
        .padding(28)
        .sheet(isPresented: $showLogin) { LoginView() }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var useKey = false
    @State private var busy = false
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://standort.example.com", text: $server)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("login-server")
                } header: { Text("Server") } footer: { Text("Adresse deines Dawarich-Servers, z. B. im Heimnetz oder über VPN.") }

                Section {
                    Picker("Anmelden mit", selection: $useKey) {
                        Text("Passwort").tag(false)
                        Text("API-Schlüssel").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useKey {
                        SecureField("API-Schlüssel", text: $apiKey).textInputAutocapitalization(.never)
                    } else {
                        TextField("E-Mail", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Passwort", text: $password).textContentType(.password)
                    }
                } footer: {
                    if useKey { Text("Den Schlüssel findest du in der Weboberfläche unter „Einstellungen“ → „API-Schlüssel“.") }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }

                Section {
                    Button { Task { await login() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("Anmelden").bold() }; Spacer() }
                    }
                    .disabled(busy || server.isEmpty || (useKey ? apiKey.isEmpty : (email.isEmpty || password.isEmpty)))
                    if DataScannerViewController.isSupported {
                        Button("QR-Code scannen", systemImage: "qrcode.viewfinder") { scanning = true }
                    }
                } footer: {
                    Text("Weiteres eigenes Gerät? Auf dem ersten Gerät unter „Geräte“ → „+“ den Code anzeigen und hier scannen.")
                }
            }
            .navigationTitle("Anmelden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    guard let url = URL(string: text), let s = SessionStore.session(fromConnect: url) else {
                        error = String(localized: "Das ist kein HomeFind-Code."); return
                    }
                    Task { await signIn(s) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func login() async {
        guard let url = SessionStore.normalizedServer(server) else {
            error = String(localized: "Ungültige Server-Adresse."); return
        }
        busy = true; defer { busy = false }
        do {
            let key = useKey ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                : try await DawarichClient.login(server: url, email: email.trimmingCharacters(in: .whitespaces), password: password)
            await signIn(Session(server: url, apiKey: key))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signIn(_ s: Session) async {
        busy = true; defer { busy = false }
        do { try await model.signIn(s); dismiss() } catch { self.error = error.localizedDescription }
    }
}

/// Rechte erklären: erst „Beim Verwenden“, dann „Immer“, dazu Mitteilungen.
struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var notificationsAsked = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "location.circle.fill").font(.system(size: 72)).foregroundStyle(Color.accentColor)
            Text("Standort und Mitteilungen").font(.title.bold())
            Text("HomeFind zeigt dich auf der Karte und teilt deinen Standort mit deiner Familie – nur wenn du es einschaltest. Mit „Immer“ sieht dich deine Familie auch, wenn die App geschlossen ist. Im Hintergrund sendet HomeFind nur bei deutlichen Ortswechseln, das schont den Akku.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                Button {
                    if model.location.authorization == .notDetermined { model.location.requestWhenInUse() }
                    else { model.location.requestAlways() }
                } label: {
                    Label(locationTitle, systemImage: model.location.hasAlways ? "checkmark.circle.fill" : "location.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass).controlSize(.large)
                .disabled(model.location.hasAlways)
                Button {
                    Task { _ = await Notifier.requestAuthorization(); notificationsAsked = true }
                } label: {
                    Label(notificationsAsked ? "Mitteilungen eingerichtet" : "Mitteilungen erlauben",
                          systemImage: notificationsAsked ? "checkmark.circle.fill" : "bell.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass).controlSize(.large)
                .disabled(notificationsAsked)
            }
            Spacer()
            Button { model.onboardingDone = true; model.sceneBecameActive() } label: {
                Text("Fortfahren").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .accessibilityIdentifier("permissions-continue")
        }
        .padding(28)
    }

    private var locationTitle: LocalizedStringKey {
        switch model.location.authorization {
        case .notDetermined: "Ortung erlauben"
        case .authorizedWhenInUse: "„Immer“ erlauben"
        case .authorizedAlways: "Ortung erlaubt"
        default: "Ortung in „Einstellungen“ aktivieren"
        }
    }
}

/// App-Symbol als Vektor (für Willkommensseite).
struct AppGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.85, blue: 0.45), Color(red: 0.10, green: 0.62, blue: 0.32)],
                                     startPoint: .top, endPoint: .bottom))
            Image(systemName: "house.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(.white).offset(y: 14)
            Circle().stroke(.white.opacity(0.9), lineWidth: 4).frame(width: 56, height: 56).offset(y: -6)
            Circle().fill(.white).frame(width: 14, height: 14).offset(y: -6)
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (String) -> Void
        private var done = false
        init(onResult: @escaping (String) -> Void) { self.onResult = onResult }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let s = code.payloadStringValue { done = true; onResult(s); return }
            }
        }
    }
}

import SwiftUI
import MapKit

/// Reiter „Ich“: eigener Standort, Teilen-Hauptschalter, „Mein Standort“-Gerät, Standortnamen,
/// Mitteilungen, sparsames Senden, Strecke, Datenschutz, Konto.
struct MeView: View {
    @Environment(AppModel.self) private var model
    @State private var askDuration = false
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                HStack(spacing: 12) {
                    Avatar(initials: initials, seed: model.meId ?? 0, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mein Standort").font(.headline)
                        if let c = model.location.lastLocation?.coordinate {
                            Text(model.placeName(for: c) ?? String(localized: "Adresse wird gesucht …"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Kein Standort gefunden").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Von", value: model.isThisMeDevice ? String(localized: "Dieses iPhone") : (model.meDeviceName ?? "–"))
                if !model.isThisMeDevice {
                    Button("Dieses iPhone als „Mein Standort“ verwenden") { Task { await model.useAsMyLocation(ThisDevice.id) } }
                }
            }

            Section {
                Toggle("Standort teilen", isOn: Binding(get: { model.isSharing }, set: { on in
                    if on { askDuration = true } else { Task { await model.stopSharing() } }
                }))
                .accessibilityIdentifier("me-share-toggle")
            } footer: {
                if model.isSharing {
                    if let end = model.sharingEnds {
                        Text("Deine Familie sieht deinen Standort. \(Fmt.remaining(until: end)).").accessibilityIdentifier("me-remaining")
                    } else {
                        Text("Deine Familie sieht deinen Standort.").accessibilityIdentifier("me-remaining")
                    }
                } else {
                    Text("Niemand sieht deinen Standort.")
                }
            }

            if model.location.servicesDenied || !model.location.hasAlways {
                Section {
                    Label(model.location.servicesDenied ? "Ortungsdienste deaktiviert" : "Ortung „Immer“ erlauben, damit deine Familie dich auch sieht, wenn HomeFind geschlossen ist.",
                          systemImage: "location.slash")
                        .font(.subheadline)
                    Button(model.location.servicesDenied ? "In „Einstellungen“ aktivieren" : "Immer erlauben") {
                        if model.location.servicesDenied, let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        } else { model.location.requestAlways() }
                    }
                }
            }

            Section {
                NavigationLink("Standortnamen bearbeiten", value: MeRoute.places)
                NavigationLink(value: MeRoute.alerts) {
                    LabeledContent("Mitteilungen", value: "\(model.alerts.rules.filter(\.enabled).count)")
                }
                .accessibilityIdentifier("me-alerts")
                Button("Mitteilungen von HomeFind anpassen") {
                    if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
                }
            }

            Section {
                Toggle("Im Hintergrund senden", isOn: $model.backgroundSending)
                Picker("Strecke", selection: $model.distanceUnit) {
                    Text("Kilometer").tag(DistanceUnit.kilometers)
                    Text("Meilen").tag(DistanceUnit.miles)
                }
            } footer: {
                Text("Sparsam: im Hintergrund sendet HomeFind nur bei deutlichen Ortswechseln (etwa 500 m) und bei Ankunft oder Abfahrt an einem Ort.\(model.pendingPointCount > 0 ? " " + String(localized: "\(model.pendingPointCount) Standorte warten auf Verbindung.") : "")")
            }

            Section {
                NavigationLink("Datenschutz", value: MeRoute.privacy)
                    .accessibilityIdentifier("me-privacy")
            }

            Section("Konto") {
                LabeledContent("Server", value: model.session?.server.host() ?? "")
                if let fam = model.family?.family?.name { LabeledContent("Familie", value: fam) }
                Button("Weboberfläche öffnen") { model.openWeb("") }
                Button("Abmelden", role: .destructive) { confirmSignOut = true }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Ich")
        .shareDurationDialog(isPresented: $askDuration) { d in Task { await model.share(d) } }
        .confirmationDialog("Abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { model.signOut() }
        } message: { Text("Dieses iPhone sendet dann keinen Standort mehr.") }
    }

    private var initials: String {
        let parts = model.myName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// Standortnamen (Privat, Arbeit, Schule, Sport, eigene) = Orte im eigenen Server-Konto.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var renaming: ServerPlace?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(model.places) { p in
                    Button { renaming = p; newName = p.name } label: {
                        HStack {
                            Image(systemName: PlaceLabel.symbol(for: p.name)).foregroundStyle(Color.accentColor).frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.primary)
                                Text(model.namer.cached(p.coordinate) ?? String(format: "%.4f, %.4f", p.latitude, p.longitude))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .task { model.namer.resolve(p.coordinate) }
                }
                .onDelete { idx in for i in idx { let p = model.places[i]; Task { await model.deletePlace(p) } } }
                Button("Standortnamen hinzufügen", systemImage: "plus") { adding = true }
            } footer: {
                Text("Liegen in deinem Server-Konto. Personen in deiner Familie sehen statt der Adresse diesen Namen, wenn du dort bist – hier in HomeFind. Ankunft und Verlassen meldet dieses iPhone an deinen Server.")
            }
        }
        .navigationTitle("Standortnamen")
        .sheet(isPresented: $adding) { AddPlaceView() }
        .alert("Standortnamen bearbeiten", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Sichern") { if let p = renaming { Task { await model.renamePlace(p, to: newName) } } }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}

enum PlaceLabel: CaseIterable {
    case home, work, school, gym
    var title: String {
        switch self {
        case .home: String(localized: "Privat")
        case .work: String(localized: "Arbeit")
        case .school: String(localized: "Schule")
        case .gym: String(localized: "Sport")
        }
    }
    static func symbol(for name: String) -> String {
        switch name {
        case PlaceLabel.home.title: "house.fill"
        case PlaceLabel.work.title: "briefcase.fill"
        case PlaceLabel.school.title: "graduationcap.fill"
        case PlaceLabel.gym.title: "figure.run"
        default: "mappin.circle.fill"
        }
    }
}

struct AddPlaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = PlaceLabel.home.title
    @State private var custom = ""
    @State private var radius: FenceRadius = .medium

    var body: some View {
        NavigationStack {
            Form {
                Section("Etikett") {
                    Picker("Etikett", selection: $label) {
                        ForEach(PlaceLabel.allCases, id: \.title) { Text($0.title).tag($0.title) }
                        Text("Eigenes Etikett hinzufügen").tag("")
                    }
                    .pickerStyle(.inline).labelsHidden()
                    if label.isEmpty { TextField("Name", text: $custom) }
                }
                Section {
                    Picker("Radius", selection: $radius) {
                        Text("Klein").tag(FenceRadius.small); Text("Mittel").tag(FenceRadius.medium); Text("Groß").tag(FenceRadius.large)
                    }.pickerStyle(.segmented)
                    if let c = model.location.lastLocation?.coordinate {
                        Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: radius.rawValue * 5, longitudinalMeters: radius.rawValue * 5))) {
                            MapCircle(center: c, radius: radius.rawValue).foregroundStyle(Color.accentColor.opacity(0.2)).stroke(Color.accentColor, lineWidth: 2)
                            UserAnnotation()
                        }
                        .id(radius)
                        .frame(height: 170).allowsHitTesting(false).listRowInsets(EdgeInsets())
                    } else {
                        Text("Kein Standort gefunden").foregroundStyle(.secondary)
                    }
                } header: { Text("Mein aktueller Standort") }
            }
            .navigationTitle("Standortname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        guard let c = model.location.lastLocation?.coordinate else { return }
                        let name = label.isEmpty ? custom.trimmingCharacters(in: .whitespaces) : label
                        guard !name.isEmpty else { return }
                        Task { await model.addPlace(name: name, coordinate: c, radius: radius.rawValue); dismiss() }
                    }
                    .disabled(model.location.lastLocation == nil)
                }
            }
        }
    }
}

/// Datenschutz: was liegt wo, wer sieht mich gerade, welche Apple-Dienste beteiligt sind.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var namer = model.namer
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "hand.raised.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                    Text("Deine Standorte liegen auf deinem eigenen Server, nicht bei Apple oder einem anderen Anbieter.")
                        .font(.subheadline)
                }
                .padding(.vertical, 6)
            }

            Section("Wer sieht mich gerade") {
                if model.isSharing {
                    ForEach(model.people) { p in
                        HStack {
                            Avatar(initials: p.initials, seed: p.id, size: 30)
                            Text(p.name)
                            Spacer()
                            Text(model.sharingEnds.map { Fmt.remaining(until: $0) } ?? String(localized: "Unbegrenzt"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if model.people.isEmpty { Text("Niemand – deine Familie hat keine weiteren Mitglieder.") }
                } else {
                    Text("Niemand. Du teilst deinen Standort gerade nicht.").accessibilityIdentifier("privacy-nobody")
                }
                Text("Wer deinen Server verwaltet, kann technisch alle dort gespeicherten Daten sehen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Was liegt wo") {
                row("Aktueller Standort", "server.rack", "Dein Server",
                    "Nur solange du teilst sehen ihn die Mitglieder deiner Familie – nur den letzten Ort, keinen Verlauf.")
                row("Standort-Verlauf", "clock.arrow.circlepath", "Dein Server",
                    "Jeder gesendete Punkt bleibt in deinem Konto (Dawarich speichert einen Verlauf). Nur du siehst ihn; löschen in der Weboberfläche.")
                row("Freigaben und Anfragen", "person.2", "Dein Server", "Wer mit wem teilt, Dauer und offene Anfragen.")
                row("Standortnamen", "house", "Dein Server", "Deine Orte (Privat, Arbeit …) und Ankunft/Verlassen dort.")
                row("Eigene Geräte", "iphone", "Dein Server", "Name, Symbol, Batterie und letzter Ort als private Notiz – nur für dich.")
                row("Mitteilungsregeln", "bell", "Nur dieses iPhone", "Werden hier ausgewertet, nichts davon geht an den Server.")
                row("Favoriten, Kartenstil, Strecke", "star", "Nur dieses iPhone", "")
                row("Zugangsschlüssel", "key", "Schlüsselbund dieses iPhones", "Wird beim Abmelden gelöscht.")
            }

            Section {
                row("Kartenbilder", "map", "Apple Karten", "Apple sieht nur, welche Kartenausschnitte geladen werden.")
                row("Route und Fahrzeit", "car", "Apple Karten", "Nur wenn du auf „Route“ tippst oder eine Detailkarte öffnest.")
                Toggle(isOn: $namer.useApple) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ortsnamen über Apple suchen")
                        Text("Dafür gehen Koordinaten an Apple. Ohne: Standortnamen und Adressen vom Server.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Apple-Dienste") }

            Section("Senden") {
                Text("Im Vordergrund höchstens jede Minute oder ab 50 m Bewegung, im Hintergrund nur bei deutlichen Ortswechseln und Besuchen. Kein Push, kein Dritt-SDK, keine Analyse.")
                    .font(.subheadline)
                if let last = model.lastSentAt {
                    LabeledContent("Zuletzt gesendet", value: Fmt.ago(last))
                }
                Button("Verlauf in der Weboberfläche ansehen") { model.openWeb("map") }
            }
        }
        .navigationTitle("Datenschutz")
    }

    private func row(_ title: LocalizedStringKey, _ symbol: String, _ place: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(place).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

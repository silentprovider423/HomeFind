import SwiftUI
import MapKit

struct DevicesListView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    var body: some View {
        List {
            Section("Meine Geräte") {
                ForEach(model.devices) { d in
                    NavigationLink(value: MapSelection.device(d.id)) { OwnDeviceRow(device: d) }
                        .accessibilityIdentifier("device-\(d.name)")
                }
                if model.devices.isEmpty { Text("Wird geladen …").foregroundStyle(.secondary) }
            }
            ForEach(model.people.filter { $0.location != nil }) { p in
                Section("Geräte von \(p.firstName)") {
                    NavigationLink(value: MapSelection.familyDevice(p.id)) { FamilyDeviceRow(person: p) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Geräte")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("Gerät hinzufügen"))
            }
        }
        .refreshable { await model.refreshDevices() }
        .sheet(isPresented: $showAdd) { AddDeviceView() }
    }
}

enum DeviceStatus {
    static func subtitle(_ d: DeviceRecord, model: AppModel) -> String {
        if d.id == ThisDevice.id {
            if model.location.servicesDenied { return String(localized: "Dieses iPhone • Ortungsdienste aus") }
            if !model.isSharing && model.isThisMeDevice { return String(localized: "Dieses iPhone • Standort wird nicht geteilt") }
            return String(localized: "Dieses iPhone")
        }
        guard let c = d.coordinate else { return String(localized: "Kein Standort gefunden") }
        if let dist = model.distance(to: c), dist < 50 { return String(localized: "Bei dir") }
        if Date.now.timeIntervalSince(d.updatedAt) > 24 * 3600 { return String(localized: "Alter Standort") }
        return model.placeName(for: c) ?? String(localized: "Online")
    }
}

struct OwnDeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: DeviceRecord
    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(emoji: device.emoji, symbol: device.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.name).font(.body.weight(.semibold))
                    if model.accountSettings.meDevice == device.id {
                        Image(systemName: "location.fill").font(.caption2).foregroundStyle(Color.accentColor)
                            .accessibilityLabel(Text("Mein Standort"))
                    }
                }
                Text(DeviceStatus.subtitle(device, model: model)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if device.id != ThisDevice.id, let c = device.coordinate, let d = model.distance(to: c) {
                    Text(Fmt.distance(d, unit: model.distanceUnit)).font(.subheadline).foregroundStyle(.secondary)
                }
                BatteryView(level: device.battery, charging: device.charging)
            }
        }
        .padding(.vertical, 2)
    }
}

struct FamilyDeviceRow: View {
    @Environment(AppModel.self) private var model
    let person: Person
    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(emoji: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gerät von \(person.firstName)").font(.body.weight(.semibold))
                if let l = person.location {
                    Text(model.placeName(for: l.coordinate, serverAddress: l.address) ?? Fmt.ago(l.date))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let l = person.location, let d = model.distance(to: l.coordinate) {
                    Text(Fmt.distance(d, unit: model.distanceUnit)).font(.subheadline).foregroundStyle(.secondary)
                }
                BatteryView(level: person.location?.battery, charging: person.location?.batteryStatus == "charging")
            }
        }
    }
}

/// Detailkarte eines Geräts: Batterie, Ort, Route, Name/Symbol, „Mein Standort“, Details, entfernen.
struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let selection: MapSelection
    @State private var editing = false
    @State private var confirmRemove = false
    @State private var showShare = false
    @State private var routeNotice = false

    var body: some View {
        switch selection {
        case .device(let id):
            if let d = model.devices.first(where: { $0.id == id }) { own(d) } else { missing }
        case .familyDevice(let pid):
            if let p = model.person(pid), let l = p.location { family(p, l) } else { missing }
        case .person:
            missing
        }
    }

    private var missing: some View { ContentUnavailableView("Gerät nicht gefunden", systemImage: "iphone.slash") }

    private func own(_ d: DeviceRecord) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    DeviceIcon(emoji: d.emoji, symbol: d.symbol, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name).font(.title2.bold())
                        Text(DeviceStatus.subtitle(d, model: model)).font(.subheadline)
                        HStack(spacing: 6) {
                            Text(Fmt.ago(d.updatedAt))
                            BatteryView(level: d.battery, charging: d.charging)
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                HStack(spacing: 10) {
                    ActionTile(title: "Route", symbol: "car.fill", disabled: d.coordinate == nil || d.id == ThisDevice.id) { routeNotice = true }
                    ActionTile(title: "Standort teilen", symbol: "person.badge.plus") { showShare = true }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if model.accountSettings.meDevice == d.id {
                    Label("Wird für „Mein Standort“ verwendet", systemImage: "location.fill").foregroundStyle(.secondary)
                } else {
                    Button(d.id == ThisDevice.id ? "Dieses iPhone als „Mein Standort“ verwenden" : "Als „Mein Standort“ verwenden") {
                        Task { await model.useAsMyLocation(d.id) }
                    }
                }
                Button("Name und Symbol bearbeiten") { editing = true }
            }
            Section("Details") {
                LabeledContent("Modell", value: d.model)
                LabeledContent("System", value: d.system)
                LabeledContent("HomeFind", value: d.appVersion)
                LabeledContent("Aktualisiert", value: d.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Button(d.id == ThisDevice.id ? "Dieses iPhone entfernen" : "Dieses Gerät entfernen", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Das Gerät verschwindet aus der Liste und hört beim nächsten Abgleich auf zu senden. Bereits gesendete Standorte bleiben in deinem Server-Verlauf.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(d.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if let c = d.coordinate { model.focus(c) } }
        .sheet(isPresented: $editing) { EditDeviceView(device: d) }
        .sheet(isPresented: $showShare) { ShareLocationView() }
        .confirmationDialog("Dieses Gerät entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) { Task { await model.removeDevice(d.id) } }
        } message: {
            Text(d.id == ThisDevice.id ? "Dieses iPhone wird abgemeldet und sendet keinen Standort mehr." : "„\(d.name)“ wird aus deinem Konto entfernt.")
        }
        .confirmationDialog("Route in „Karten“ öffnen?", isPresented: $routeNotice, titleVisibility: .visible) {
            Button("Route") { if let c = d.coordinate { openRoute(c, d.name) } }
        } message: { Text("Der Zielort wird dafür an Apple Karten übergeben.") }
    }

    private func family(_ p: Person, _ l: MemberLocation) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    DeviceIcon(emoji: nil, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gerät von \(p.firstName)").font(.title2.bold())
                        Text(model.placeName(for: l.coordinate, serverAddress: l.address) ?? "").font(.subheadline)
                        HStack(spacing: 6) {
                            Text(Fmt.ago(l.date))
                            BatteryView(level: l.battery, charging: l.batteryStatus == "charging")
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                ActionTile(title: "Route", symbol: "car.fill") { routeNotice = true }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            } footer: {
                Text("Das Gerät, von dem \(p.firstName) den Standort teilt.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Gerät von \(p.firstName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.focus(l.coordinate) }
        .confirmationDialog("Route in „Karten“ öffnen?", isPresented: $routeNotice, titleVisibility: .visible) {
            Button("Route") { openRoute(l.coordinate, p.name) }
        } message: { Text("Der Zielort wird dafür an Apple Karten übergeben.") }
    }

    private func openRoute(_ c: CLLocationCoordinate2D, _ name: String) {
        let item = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

struct EditDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: DeviceRecord
    @State private var name = ""
    @State private var emoji = ""
    private let suggestions = ["📱", "💻", "⌚️", "🎧", "🚗", "🎒", "🔑", "🧳", "🚲", "🏠"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name).accessibilityIdentifier("device-name") }
                Section("Symbol") {
                    TextField("Emoji", text: $emoji)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                        ForEach(suggestions, id: \.self) { e in
                            Button { emoji = e } label: {
                                Text(e).font(.title).frame(width: 48, height: 48)
                                    .background(Circle().fill(emoji == e ? Color.accentColor.opacity(0.25) : Color(.secondarySystemFill)))
                            }.buttonStyle(.plain)
                        }
                    }
                    Button("Kein Symbol") { emoji = "" }
                }
            }
            .navigationTitle("Name und Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        Task { await model.renameDevice(device.id, name: name, emoji: String(emoji.prefix(2))); dismiss() }
                    }
                    .accessibilityIdentifier("device-save")
                }
            }
            .onAppear { name = device.name; emoji = device.emoji ?? "" }
        }
    }
}

/// Eigenes Gerät hinzufügen: HomeFind auf dem anderen Gerät öffnen und diesen Code scannen.
struct AddDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reveal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                    Text("Weiteres Gerät hinzufügen").font(.title2.bold())
                    Text("Installiere HomeFind auf dem anderen iPhone oder iPad, tippe bei der Anmeldung auf „QR-Code scannen“ und halte die Kamera auf diesen Code.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if let s = model.session {
                        let url = SessionStore.connectURL(for: s)
                        ZStack {
                            if let img = QRCode.image(for: url.absoluteString) {
                                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                                    .frame(width: 220, height: 220).padding(14)
                                    .background(.white, in: .rect(cornerRadius: 18))
                                    .blur(radius: reveal ? 0 : 14)
                            }
                            if !reveal {
                                Button("Code anzeigen") { reveal = true }.buttonStyle(.borderedProminent)
                            }
                        }
                        Label("Der Code enthält deinen Zugangsschlüssel. Zeige ihn nur auf deinen eigenen Geräten.", systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

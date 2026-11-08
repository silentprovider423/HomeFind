import SwiftUI
import MapKit

/// Eine Stecknadel auf der Karte (Person, eigenes Gerät, Familiengerät) oder eine Gruppe davon.
struct MapItem: Identifiable, Equatable {
    enum Kind: Equatable { case person(initials: String, seed: Int), device(emoji: String?), familyDevice(initials: String, seed: Int) }
    let selection: MapSelection
    let kind: Kind
    let title: String
    let coordinate: CLLocationCoordinate2D
    var id: MapSelection { selection }
    static func == (a: MapItem, b: MapItem) -> Bool {
        a.selection == b.selection && a.kind == b.kind && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
    }
}

struct MapCluster: Identifiable {
    let items: [MapItem]
    var id: String { items.map { "\($0.selection)" }.sorted().joined(separator: "|") }
    var coordinate: CLLocationCoordinate2D {
        let lat = items.map(\.coordinate.latitude).reduce(0, +) / Double(items.count)
        let lon = items.map(\.coordinate.longitude).reduce(0, +) / Double(items.count)
        return .init(latitude: lat, longitude: lon)
    }
}

enum Clustering {
    /// Einfache Gruppierung: Punkte, die bei der aktuellen Zoomstufe näher als ~1/14 der sichtbaren Breite liegen.
    static func clusters(_ items: [MapItem], span: MKCoordinateSpan?) -> [MapCluster] {
        guard let span else { return items.map { MapCluster(items: [$0]) } }
        let threshold = max(span.latitudeDelta, span.longitudeDelta) / 14
        var result: [[MapItem]] = []
        for item in items {
            if let i = result.firstIndex(where: { group in
                let c = group[0].coordinate
                return abs(c.latitude - item.coordinate.latitude) < threshold && abs(c.longitude - item.coordinate.longitude) < threshold
            }) {
                result[i].append(item)
            } else {
                result.append([item])
            }
        }
        return result.map { MapCluster(items: $0) }
    }
}

struct FindMapView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var scope
    @State private var showMapChooser = false
    @State private var didInitialFit = false

    private var items: [MapItem] {
        var list: [MapItem] = []
        for p in model.people {
            if let l = p.location {
                list.append(MapItem(selection: .person(p.id), kind: .person(initials: p.initials, seed: p.id),
                                    title: p.name, coordinate: l.coordinate))
            }
        }
        // Eigene Geräte außer diesem iPhone (das zeigt der blaue Punkt).
        for d in model.devices where d.id != ThisDevice.id {
            if let c = d.coordinate {
                list.append(MapItem(selection: .device(d.id), kind: .device(emoji: d.emoji), title: d.name, coordinate: c))
            }
        }
        return list
    }

    var body: some View {
        @Bindable var model = model
        Map(position: $model.camera, scope: scope) {
            UserAnnotation()
            ForEach(Clustering.clusters(items, span: model.visibleRegion?.span)) { cluster in
                Annotation(cluster.items.count == 1 ? cluster.items[0].title : "", coordinate: cluster.coordinate, anchor: .bottom) {
                    if cluster.items.count == 1 {
                        PinView(item: cluster.items[0]) { model.select(cluster.items[0].selection) }
                    } else {
                        ClusterPin(count: cluster.items.count) { zoom(to: cluster) }
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(style)
        .mapControls { MapScaleView(scope: scope) }
        .onMapCameraChange(frequency: .onEnd) { model.visibleRegion = $0.region }
        .overlay(alignment: .topTrailing) {
            GlassEffectContainer {
                VStack(spacing: 0) {
                    Button { showMapChooser = true } label: {
                        Image(systemName: mapSymbol).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("Karte auswählen"))
                    .accessibilityIdentifier("map-chooser")
                    Divider().frame(width: 28)
                    MapUserLocationButton(scope: scope).buttonBorderShape(.circle).tint(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(.trailing, 12)
            .padding(.top, 60)
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                MapPitchToggle(scope: scope).mapControlVisibility(.automatic)
                MapCompass(scope: scope)
            }
            .padding(.trailing, 12)
            .padding(.top, 166)
        }
        .overlay(alignment: .top) {
            if model.location.servicesDenied {
                Label("Ortungsdienste deaktiviert – in „Einstellungen“ aktivieren", systemImage: "location.slash")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .settingsLink()
                    .padding(.top, 60)
            }
        }
        .mapScope(scope)
        .onChange(of: items.count, initial: true) { _, count in
            // Beim ersten Laden alle Personen/Geräte und mich ins Bild holen (wie „Wo ist?“).
            guard !didInitialFit, count > 0 else { return }
            didInitialFit = true
            fitAll()
        }
        .sheet(isPresented: $showMapChooser) {
            MapChooserView().presentationDetents([.height(330)])
        }
    }

    private var style: MapStyle {
        switch model.mapMode {
        case .standard: .standard(pointsOfInterest: .including([.publicTransport, .airport, .park]), showsTraffic: model.showsTraffic)
        case .hybrid: .hybrid(showsTraffic: model.showsTraffic)
        case .satellite: .imagery
        }
    }

    private var mapSymbol: String {
        switch model.mapMode { case .standard: "map"; case .hybrid: "map.fill"; case .satellite: "globe.europe.africa.fill" }
    }

    private func fitAll() {
        var coords = items.map(\.coordinate)
        if let me = model.location.lastLocation?.coordinate { coords.append(me) }
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        // Nur der obere Teil (~45 %) ist sichtbar, den Rest deckt die Infokarte ab.
        let pad = max(0.004, (lats.max()! - lats.min()!) * 0.2)
        let visible = 0.45
        let total = (lats.max()! - lats.min()! + 2 * pad) / visible
        let center = CLLocationCoordinate2D(latitude: lats.max()! + pad - total / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: total, longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.35))
        withAnimation { model.camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    private func zoom(to cluster: MapCluster) {
        let lats = cluster.items.map(\.coordinate.latitude), lons = cluster.items.map(\.coordinate.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (lats.max()! - lats.min()!) * 3),
                                    longitudeDelta: max(0.004, (lons.max()! - lons.min()!) * 3))
        withAnimation { model.camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}

struct PinView: View {
    let item: MapItem
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(.white).frame(width: 50, height: 50).shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    switch item.kind {
                    case .person(let i, let s), .familyDevice(let i, let s): Avatar(initials: i, seed: s, size: 44)
                    case .device(let e): DeviceIcon(emoji: e, size: 44)
                    }
                }
                Image(systemName: "triangle.fill").font(.system(size: 10)).foregroundStyle(.white)
                    .rotationEffect(.degrees(180)).offset(y: -3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.title))
        .accessibilityIdentifier("pin-\(item.title)")
    }
}

struct ClusterPin: View {
    let count: Int
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Text("\(count)").font(.headline).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(count) Personen und Geräte"))
    }
}

/// „Karte auswählen“: Kartenmodus, Verkehr, Strecke in km/mi.
struct MapChooserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        tile(.standard, "Standard", "map")
                        tile(.hybrid, "Hybrid", "map.fill")
                        tile(.satellite, "Satellit", "globe.europe.africa.fill")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    Toggle("Verkehr", isOn: $model.showsTraffic).disabled(model.mapMode == .satellite)
                    Picker("Strecke", selection: $model.distanceUnit) {
                        Text("In Kilometern").tag(DistanceUnit.kilometers)
                        Text("In Meilen").tag(DistanceUnit.miles)
                    }
                }
            }
            .navigationTitle("Karte auswählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig", systemImage: "xmark") { dismiss() } } }
        }
    }

    private func tile(_ mode: MapMode, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button { model.mapMode = mode } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2).frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.mapMode == mode ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(title).font(.footnote.weight(model.mapMode == mode ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.mapMode == mode ? .isSelected : [])
    }
}

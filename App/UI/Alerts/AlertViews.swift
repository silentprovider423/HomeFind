import SwiftUI
import MapKit

struct AlertRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: AlertRule

    var body: some View {
        HStack {
            Image(systemName: rule.trigger == .arrives ? "arrow.down.to.line.circle.fill" : "arrow.up.right.circle.fill")
                .foregroundStyle(rule.enabled ? Color.accentColor : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(rule.repeats ? "Jedes Mal" : (rule.enabled ? "Nur einmal" : "Erledigt"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; model.alerts.update(r); model.syncRegions() }))
                .labelsHidden()
        }
    }

    private var title: String {
        let who = rule.personName ?? ""
        switch (rule.subject, rule.trigger) {
        case (.me, .arrives): return String(localized: "Ich komme bei „\(rule.placeName)“ an")
        case (.me, .leaves): return String(localized: "Ich verlasse „\(rule.placeName)“")
        case (.person, .arrives): return String(localized: "\(who) kommt bei „\(rule.placeName)“ an")
        case (.person, .leaves): return String(localized: "\(who) verlässt „\(rule.placeName)“")
        }
    }
}

/// Standorthinweis anlegen: Wann (ankommt/verlässt) · Ort · Radius · Häufigkeit.
struct AddAlertView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let subject: AlertRule.Subject
    var personName: String?

    enum PlaceChoice: Hashable { case current, place(Int), search }

    @State private var trigger: AlertRule.Trigger = .arrives
    @State private var choice: PlaceChoice = .current
    @State private var radius: FenceRadius = .medium
    @State private var repeats = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var picked: MKMapItem?

    private var currentCoordinate: CLLocationCoordinate2D? {
        switch subject {
        case .me: return model.location.lastLocation?.coordinate
        case .person(let id): return model.person(id)?.location?.coordinate
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wenn") {
                    Picker("Wann", selection: $trigger) {
                        Text(subject == .me ? "Ich ankomme" : "\(personName ?? "") ankommt").tag(AlertRule.Trigger.arrives)
                        Text(subject == .me ? "Ich verlasse" : "\(personName ?? "") verlässt").tag(AlertRule.Trigger.leaves)
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section("Ort") {
                    Picker("Ort", selection: $choice) {
                        Text(subject == .me ? "Mein aktueller Standort" : "Aktueller Standort von \(personName ?? "")")
                            .tag(PlaceChoice.current)
                        ForEach(model.places) { Text($0.name).tag(PlaceChoice.place($0.id)) }
                        Text("Adresse suchen …").tag(PlaceChoice.search)
                    }
                    .pickerStyle(.inline).labelsHidden()
                    if choice == .search {
                        TextField("Adresse oder Ort", text: $query).onSubmit { Task { await search() } }
                        ForEach(results, id: \.self) { item in
                            Button { picked = item } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.name ?? "").foregroundStyle(.primary)
                                        Text(item.address?.shortAddress ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if picked == item { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                }
                Section {
                    Picker("Radius", selection: $radius) {
                        Text("Klein").tag(FenceRadius.small)
                        Text("Mittel").tag(FenceRadius.medium)
                        Text("Groß").tag(FenceRadius.large)
                    }
                    .pickerStyle(.segmented)
                    if let c = coordinate {
                        Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: radius.rawValue * 5,
                                                                        longitudinalMeters: radius.rawValue * 5))) {
                            MapCircle(center: c, radius: radius.rawValue).foregroundStyle(Color.accentColor.opacity(0.2))
                                .stroke(Color.accentColor, lineWidth: 2)
                            Marker("", coordinate: c)
                        }
                        .id("\(c.latitude),\(c.longitude),\(radius.rawValue)")
                        .frame(height: 160)
                        .allowsHitTesting(false)
                        .listRowInsets(EdgeInsets())
                    }
                } header: { Text("Radius") }
                Section {
                    Picker("Häufigkeit", selection: $repeats) {
                        Text("Nur einmal").tag(false)
                        Text("Jedes Mal").tag(true)
                    }
                } footer: {
                    Text(subject == .me
                         ? "Ausgewertet auf diesem iPhone über Region Monitoring – es wird nichts zusätzlich gesendet."
                         : "Ausgewertet auf diesem iPhone mit dem Standort, den \(personName ?? "") mit dir teilt.")
                }
            }
            .navigationTitle("Mitteilung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen", action: save).disabled(coordinate == nil).accessibilityIdentifier("alert-save")
                }
            }
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        switch choice {
        case .current: return currentCoordinate
        case .place(let id): return model.places.first { $0.id == id }?.coordinate
        case .search: return picked?.location.coordinate
        }
    }

    private var placeName: String {
        switch choice {
        case .current:
            if let c = currentCoordinate { return model.placeName(for: c) ?? String(localized: "Aktueller Standort") }
            return String(localized: "Aktueller Standort")
        case .place(let id): return model.places.first { $0.id == id }?.name ?? ""
        case .search: return picked?.name ?? query
        }
    }

    private func search() async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let c = currentCoordinate { req.region = MKCoordinateRegion(center: c, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        results = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
    }

    private func save() {
        guard let c = coordinate else { return }
        var serverId: Int?
        var r = radius.rawValue
        if case .place(let id) = choice, let p = model.places.first(where: { $0.id == id }) { serverId = id; r = p.radius }
        var rule = AlertRule(subject: subject, personName: personName, trigger: trigger, placeName: placeName,
                             latitude: c.latitude, longitude: c.longitude, radius: r, serverPlaceId: serverId, repeats: repeats)
        // Startzustand der Person merken, damit nur echte Wechsel melden.
        if case .person(let id) = subject, let l = model.person(id)?.location {
            rule.lastInside = rule.contains(l.coordinate)
            rule.lastTimestamp = l.timestamp
        }
        model.alerts.add(rule)
        model.syncRegions()
        Task { _ = await Notifier.requestAuthorization() }
        dismiss()
    }
}

/// Alle Mitteilungen: über mich (eigene Regionen) und über andere.
struct AlertsListView: View {
    @Environment(AppModel.self) private var model
    @State private var addMe = false

    var body: some View {
        List {
            Section {
                ForEach(model.alerts.rules(for: .me)) { AlertRuleRow(rule: $0) }
                    .onDelete { idx in delete(model.alerts.rules(for: .me), idx) }
                Button("Hinzufügen", systemImage: "plus") { addMe = true }
            } header: { Text("Über dich") } footer: {
                Text("\(model.regions.regionCount) von \(RegionMonitor.maxRegions) Regionen belegt (eigene Orte und Mitteilungen).")
            }
            let others = model.alerts.rules.filter { $0.subject != .me }
            if !others.isEmpty {
                Section("Über andere") {
                    ForEach(others) { AlertRuleRow(rule: $0) }
                        .onDelete { idx in delete(others, idx) }
                }
            }
        }
        .navigationTitle("Mitteilungen")
        .sheet(isPresented: $addMe) { AddAlertView(subject: .me) }
    }

    private func delete(_ list: [AlertRule], _ idx: IndexSet) {
        for i in idx { model.alerts.remove(list[i].id) }
        model.syncRegions()
    }
}

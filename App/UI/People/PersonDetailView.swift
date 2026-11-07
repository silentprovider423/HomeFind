import SwiftUI
import MapKit

/// Detailkarte einer Person (wie FMPersonDetailCard): Ort, Zeit, Entfernung, Kontakt · Route · Mitteilung,
/// Mitteilungen, Favoriten, Teilen/Nicht mehr teilen mit Restzeit, Standort anfordern, entfernen.
struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let personId: Int
    @State private var eta: TimeInterval?
    @State private var showContact = false
    @State private var askDuration = false
    @State private var confirmStop = false
    @State private var confirmRemove = false
    @State private var addAlert = false
    @State private var routeNotice = false

    var body: some View {
        if let p = model.person(personId) {
            content(p)
        } else {
            ContentUnavailableView("Person nicht gefunden", systemImage: "person.slash")
        }
    }

    private func content(_ p: Person) -> some View {
        List {
            Section {
                header(p)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                HStack(spacing: 10) {
                    ActionTile(title: "Kontakt", symbol: "person.crop.circle.fill") { showContact = true }
                    ActionTile(title: "Route", symbol: "car.fill", subtitle: eta.map(Fmt.eta), disabled: p.location == nil) {
                        routeNotice = true
                    }
                    .accessibilityIdentifier("person-route")
                    ActionTile(title: "Mitteilung", symbol: "bell.fill", disabled: !p.sharesWithMe) { addAlert = true }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let r = p.incomingRequest {
                Section {
                    Text("Diese Person möchte deinen Standort sehen.")
                    Button("Akzeptieren") { askDuration = true }.accessibilityIdentifier("detail-accept")
                    Button("Ablehnen", role: .destructive) { Task { await model.decline(r) } }
                }
            }

            Section {
                ForEach(model.alerts.rules(for: .person(p.id))) { rule in
                    AlertRuleRow(rule: rule)
                }
                .onDelete { idx in
                    let rules = model.alerts.rules(for: .person(p.id))
                    for i in idx { model.alerts.remove(rules[i].id) }
                }
                Button("Hinzufügen", systemImage: "plus") { addAlert = true }.disabled(!p.sharesWithMe)
            } header: { Text("Mitteilungen") } footer: {
                if !p.sharesWithMe { Text("Mitteilungen gibt es, sobald \(p.firstName) den Standort mit dir teilt.") }
            }

            Section {
                Button(p.isFavorite ? "Aus Favoriten löschen" : "Als Favoriten sichern") { model.toggleFavorite(p.id) }
                    .accessibilityIdentifier("detail-favorite")
            }

            Section {
                if model.isSharing {
                    Button("Standort nicht mehr teilen", role: .destructive) { confirmStop = true }
                        .accessibilityIdentifier("detail-stop-sharing")
                } else {
                    Button("Standort teilen") { askDuration = true }
                        .accessibilityIdentifier("detail-share")
                }
                if !p.sharesWithMe {
                    Button(p.requestSent ? "Anfrage gesendet" : "Teilen des Standorts erfragen") {
                        Task { await model.requestLocation(of: p) }
                    }
                    .disabled(p.requestSent)
                    .accessibilityIdentifier("detail-request")
                }
            } footer: {
                if model.isSharing {
                    if let end = model.sharingEnds {
                        Text("\(p.firstName) kann deinen Standort sehen. \(Fmt.remaining(until: end)).")
                            .accessibilityIdentifier("detail-remaining")
                    } else {
                        Text("\(p.firstName) kann deinen Standort sehen.")
                    }
                }
            }

            Section {
                Button("\(p.firstName) entfernen", role: .destructive) { confirmRemove = true }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(p.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: p.location?.timestamp) {
            if let l = p.location { model.focus(l.coordinate); await loadETA(to: l.coordinate) }
        }
        .sheet(isPresented: $showContact) { ContactCard(name: p.name, email: p.email).ignoresSafeArea() }
        .sheet(isPresented: $addAlert) { AddAlertView(subject: .person(p.id), personName: p.firstName) }
        .shareDurationDialog(isPresented: $askDuration) { d in
            Task {
                if let r = p.incomingRequest { await model.accept(r, duration: d) } else { await model.share(d, with: p.firstName) }
            }
        }
        .confirmationDialog("Standort nicht mehr teilen?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Standort nicht mehr teilen", role: .destructive) { Task { await model.stopSharing() } }
        } message: {
            Text("Dein Server teilt mit der ganzen Familie – danach sieht niemand in deiner Familie deinen Standort.")
        }
        .confirmationDialog("\(p.firstName) entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Weboberfläche öffnen") { model.openWeb("family") }
        } message: {
            Text(model.family?.me?.owner == true
                 ? "Mitglieder entfernst du in der Familienverwaltung deines Servers."
                 : "Nur die Person, die die Familie erstellt hat, kann Mitglieder entfernen. Du kannst die Familie in der Weboberfläche verlassen.")
        }
        .confirmationDialog("Route in „Karten“ öffnen?", isPresented: $routeNotice, titleVisibility: .visible) {
            Button("Route") { openRoute(p) }
        } message: {
            Text("Der Zielort wird dafür an Apple Karten übergeben.")
        }
    }

    private func header(_ p: Person) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(initials: p.initials, seed: p.id, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.title2.bold())
                if let l = p.location {
                    Text(model.placeName(for: l.coordinate, serverAddress: l.address) ?? String(localized: "Adresse nicht verfügbar"))
                        .font(.subheadline)
                    HStack(spacing: 6) {
                        Text(Fmt.ago(l.date))
                        if let d = model.distance(to: l.coordinate) { Text("·"); Text(Fmt.distance(d, unit: model.distanceUnit)) }
                        BatteryView(level: l.battery, charging: l.batteryStatus == "charging" || l.batteryStatus == "full")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(PersonStatus.subtitle(p, model: model)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func loadETA(to c: CLLocationCoordinate2D) async {
        guard model.location.lastLocation != nil else { return }
        let req = MKDirections.Request()
        req.source = .forCurrentLocation()
        req.destination = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        req.transportType = .automobile
        eta = try? await MKDirections(request: req).calculateETA().expectedTravelTime
    }

    private func openRoute(_ p: Person) {
        guard let l = p.location else { return }
        let item = MKMapItem(location: CLLocation(latitude: l.latitude, longitude: l.longitude), address: nil)
        item.name = p.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

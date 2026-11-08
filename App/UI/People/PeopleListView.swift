import SwiftUI

struct PeopleListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let people = model.people
        let favorites = people.filter(\.isFavorite)
        let others = people.filter { !$0.isFavorite }
        List {
            if model.notInFamily {
                Section {
                    ContentUnavailableView {
                        Label("Noch keine Familie", systemImage: "person.3")
                    } description: {
                        Text("Lege auf deinem Server eine Familie an oder nimm eine Einladung an. Personen in deiner Familie erscheinen dann hier.")
                    } actions: {
                        Button("Weboberfläche öffnen") { model.openWeb("family") }.buttonStyle(.borderedProminent)
                    }
                }
            } else if people.isEmpty && model.family != nil {
                Section {
                    ContentUnavailableView {
                        Label("Finde deine Freund:innen und Familie auf einer Karte", systemImage: "person.2.fill")
                    } description: {
                        Text("Lade Personen über die Weboberfläche deines Servers in deine Familie ein.")
                    } actions: {
                        Button("Standort teilen") { model.showShareSheet = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            if !model.pendingPeople.isEmpty {
                Section("Mitteilungen") {
                    ForEach(model.pendingPeople) { PendingRow(person: $0) }
                }
            }
            if !favorites.isEmpty {
                Section("Favoriten") { ForEach(favorites) { row($0) } }
            }
            if !others.isEmpty {
                Section { ForEach(others) { row($0) } }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Personen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showShareSheet = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("Standort teilen"))
                    .accessibilityIdentifier("people-add")
            }
        }
        .refreshable { await model.refreshFamily() }
        .sheet(isPresented: Binding(get: { model.showShareSheet }, set: { model.showShareSheet = $0 })) { ShareLocationView() }
    }

    private func row(_ p: Person) -> some View {
        NavigationLink(value: p.id) { PersonRow(person: p) }
            .accessibilityIdentifier("person-\(p.firstName)")
            .contextMenu {
                if let l = p.location {
                    Button("Route …", systemImage: "car") { model.openDirections(to: l.coordinate, name: p.name) }
                }
                Button(p.isFavorite ? "Aus Favoriten löschen" : "Als Favoriten sichern", systemImage: p.isFavorite ? "star.slash" : "star") {
                    model.toggleFavorite(p.id)
                }
            }
            .swipeActions {
                Button { model.toggleFavorite(p.id) } label: {
                    Label(p.isFavorite ? "Aus Favoriten löschen" : "Als Favoriten sichern", systemImage: p.isFavorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
    }
}

struct PersonRow: View {
    @Environment(AppModel.self) private var model
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            Avatar(initials: person.initials, seed: person.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.body.weight(.semibold))
                Text(PersonStatus.subtitle(person, model: model)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let l = person.location {
                VStack(alignment: .trailing, spacing: 2) {
                    if let d = model.distance(to: l.coordinate) {
                        Text(Fmt.distance(d, unit: model.distanceUnit)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(Fmt.ago(l.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum PersonStatus {
    /// Zweite Zeile in der Liste: Ort, oder Status wie „Kann deinen Standort sehen“.
    static func subtitle(_ p: Person, model: AppModel) -> String {
        if let l = p.location {
            if let d = model.distance(to: l.coordinate), d < 50 { return String(localized: "Bei dir") }
            return model.placeName(for: l.coordinate, serverAddress: l.address) ?? String(localized: "Adresse nicht verfügbar")
        }
        if p.sharesWithMe { return String(localized: "Kein Standort gefunden") }
        if p.requestSent { return model.isSharing ? String(localized: "Kann deinen Standort sehen, Anfrage gesendet") : String(localized: "Anfrage gesendet") }
        if model.isSharing { return String(localized: "Kann deinen Standort sehen") }
        return String(localized: "Standort wird nicht geteilt")
    }
}

/// Offene Aktion: Anfrage annehmen/ablehnen oder zurückteilen.
struct PendingRow: View {
    @Environment(AppModel.self) private var model
    let person: Person
    @State private var askDuration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Avatar(initials: person.initials, seed: person.id, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.subheadline.weight(.semibold))
                    Text(person.incomingRequest != nil ? "Diese Person möchte deinen Standort sehen."
                         : "Diese Person teilt ihren Standort mit dir. Möchtest du deinen Standort teilen?")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(person.incomingRequest != nil ? "Akzeptieren" : "Teilen") { askDuration = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pending-accept-\(person.firstName)")
                Button(person.incomingRequest != nil ? "Ablehnen" : "Nicht teilen") {
                    if let r = person.incomingRequest { Task { await model.decline(r) } }
                    else { model.dismissedShareBack.insert(person.id) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pending-decline-\(person.firstName)")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .shareDurationDialog(isPresented: $askDuration) { d in
            Task {
                if let r = person.incomingRequest { await model.accept(r, duration: d) }
                else { await model.share(d, with: person.firstName) }
            }
        }
    }
}

extension View {
    /// Aktionsblatt „Standort 1 Std. teilen · Bis zum Ende des Tages · Unbegrenzt“.
    func shareDurationDialog(isPresented: Binding<Bool>, onPick: @escaping (ShareDuration) -> Void) -> some View {
        confirmationDialog("Standort teilen", isPresented: isPresented, titleVisibility: .visible) {
            Button("Standort 1 Std. teilen") { onPick(.oneHour) }
            Button("Bis zum Ende des Tages") { onPick(.endOfDay) }
            Button("Unbegrenzt") { onPick(.indefinitely) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Deine Familie sieht deinen Standort für die gewählte Dauer.")
        }
    }
}

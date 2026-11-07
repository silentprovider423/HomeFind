import SwiftUI

/// „Standort teilen“: Empfänger wählen (An:-Feld, Vorschläge aus der Familie, Kontakte), dann Dauer.
/// Dawarich teilt immer mit der ganzen Familie – Personen außerhalb lädt man über die Weboberfläche ein.
struct ShareLocationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var askDuration = false
    @State private var pickContact = false
    @State private var notInFamily: String?
    @State private var invalid: String?
    @State private var target: Person?
    @State private var web: URL?

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Standort teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden", action: submit).disabled(recipient.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("share-send")
                }
            }
            .sheet(item: $web) { SafariView(url: $0).ignoresSafeArea() }
            .sheet(isPresented: $pickContact) {
                ContactPicker { mail in pickContact = false; if let mail { recipient = mail; submit() } }
            }
            .shareDurationDialog(isPresented: $askDuration) { d in
                Task { await model.share(d, with: target?.firstName); dismiss() }
            }
            .alert(Text("\(notInFamily ?? "") ist noch nicht in deiner Familie"), isPresented: notInFamilyBinding) {
                Button("Weboberfläche öffnen") { web = model.webLink("family") }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("\(notInFamily ?? "") verwendet eventuell HomeFind nicht. Lade die Person über die Weboberfläche deines Servers ein – sobald sie beitritt, erscheint sie hier.")
            }
            .alert("Ungültige Adresse", isPresented: invalidBinding) {
                Button("OK", role: .cancel) {}
            } message: { Text(invalid ?? "") }
        }
    }

    private var content: some View {
        List {
            Section {
                HStack {
                    Text("An:").foregroundStyle(.secondary)
                    TextField("E-Mail-Adresse", text: $recipient)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.send).onSubmit(submit)
                        .accessibilityIdentifier("share-recipient")
                    Button { pickContact = true } label: { Image(systemName: "plus.circle") }
                        .accessibilityLabel(Text("Kontakte"))
                }
            }
            familySection
            sharingSection
        }
    }

    private var familySection: some View {
        Section {
            ForEach(model.people) { p in suggestion(p) }
            Button("Person einladen …", systemImage: "person.badge.plus") { web = model.webLink("family") }
        } header: { Text("Familie") } footer: {
            Text("Dein Server teilt deinen Standort mit allen Mitgliedern deiner Familie. Neue Personen lädst du über die Weboberfläche ein.")
        }
    }

    private func suggestion(_ p: Person) -> some View {
        Button { target = p; recipient = p.email; askDuration = true } label: {
            HStack(spacing: 12) {
                Avatar(initials: p.initials, seed: p.id, size: 36)
                VStack(alignment: .leading) {
                    Text(p.name).foregroundStyle(.primary)
                    Text(p.email).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSharing { Image(systemName: "checkmark").foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("share-suggestion-\(p.firstName)")
    }

    @ViewBuilder private var sharingSection: some View {
        if model.isSharing {
            Section {
                Text(model.sharingEnds.map { Fmt.remaining(until: $0) } ?? String(localized: "Unbegrenzt")).foregroundStyle(.secondary)
            } header: { Text("Du teilst gerade") }
        }
    }

    private var notInFamilyBinding: Binding<Bool> {
        Binding(get: { notInFamily != nil }, set: { if !$0 { notInFamily = nil } })
    }
    private var invalidBinding: Binding<Bool> {
        Binding(get: { invalid != nil }, set: { if !$0 { invalid = nil } })
    }

    private func submit() {
        let mail = recipient.trimmingCharacters(in: .whitespaces).lowercased()
        guard mail.contains("@"), mail.contains(".") else {
            invalid = String(localized: "„\(recipient)“ ist anscheinend keine gültige E-Mail-Adresse.")
            return
        }
        if let me = model.family?.members?.first(where: { $0.userId == model.meId }), me.email.lowercased() == mail {
            invalid = String(localized: "Du kannst deinen Standort nicht mit dir selbst teilen.")
            return
        }
        if let p = model.people.first(where: { $0.email.lowercased() == mail }) {
            target = p
            askDuration = true
        } else {
            notInFamily = mail
        }
    }
}

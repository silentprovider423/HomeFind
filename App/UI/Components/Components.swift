import SwiftUI
import SafariServices
import ContactsUI
import CoreImage.CIFilterBuiltins

/// Rundes Bild mit Initialen (wie die Kontaktbilder in „Wo ist?“).
struct Avatar: View {
    let initials: String
    let seed: Int
    var size: CGFloat = 44

    static let palettes: [[Color]] = [
        [Color(red: 0.98, green: 0.62, blue: 0.35), Color(red: 0.93, green: 0.36, blue: 0.27)],
        [Color(red: 0.45, green: 0.72, blue: 0.98), Color(red: 0.20, green: 0.45, blue: 0.90)],
        [Color(red: 0.55, green: 0.85, blue: 0.55), Color(red: 0.20, green: 0.62, blue: 0.40)],
        [Color(red: 0.85, green: 0.60, blue: 0.95), Color(red: 0.58, green: 0.33, blue: 0.85)],
        [Color(red: 0.98, green: 0.80, blue: 0.40), Color(red: 0.92, green: 0.58, blue: 0.15)],
        [Color(red: 0.55, green: 0.85, blue: 0.90), Color(red: 0.15, green: 0.60, blue: 0.70)],
    ]

    var body: some View {
        let colors = Self.palettes[abs(seed) % Self.palettes.count]
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Symbol eines Geräts (Emoji oder SF-Symbol) im Kreis.
struct DeviceIcon: View {
    let emoji: String?
    var symbol = "iphone"
    var size: CGFloat = 44
    var body: some View {
        Circle().fill(Color(.secondarySystemFill))
            .overlay {
                if let emoji, !emoji.isEmpty { Text(emoji).font(.system(size: size * 0.5)) }
                else { Image(systemName: symbol).font(.system(size: size * 0.45)).foregroundStyle(.primary) }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct BatteryView: View {
    let level: Int?
    var charging: Bool? = nil
    var body: some View {
        if let level {
            HStack(spacing: 3) {
                Image(systemName: symbol(level)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(level <= 20 && charging != true ? .red : .secondary)
                if charging == true { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
            }
            .font(.footnote)
            .accessibilityLabel(Text("Batterie \(level) %"))
        }
    }
    private func symbol(_ l: Int) -> String {
        switch l { case ..<13: "battery.0percent"; case ..<38: "battery.25percent"; case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"; default: "battery.100percent" }
    }
}

/// Knopf in der Aktionsreihe der Detailkarte (Kontakt · Route · Mitteilung).
struct ActionTile: View {
    let title: LocalizedStringKey
    let symbol: String
    var subtitle: String? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3).frame(height: 26)
                Text(title).font(.footnote.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .disabled(disabled)
    }
}

/// Kurze Bestätigung unten („Du teilst deinen Standort jetzt mit …“).
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("toast")
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// Kontaktkarte für eine Person (ohne Zugriff aufs Adressbuch – „Neuen Kontakt erstellen“ geht trotzdem).
struct ContactCard: UIViewControllerRepresentable {
    let name: String
    let email: String
    func makeUIViewController(context: Context) -> UINavigationController {
        let c = CNMutableContact()
        let parts = name.split(separator: " ")
        c.givenName = parts.first.map(String.init) ?? name
        c.familyName = parts.dropFirst().joined(separator: " ")
        c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        let vc = CNContactViewController(forUnknownContact: c)
        vc.contactStore = CNContactStore()
        vc.allowsActions = true
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

/// Kontakte-Auswahl (läuft außerhalb der App, braucht keine Adressbuch-Berechtigung).
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        vc.displayedPropertyKeys = [CNContactEmailAddressesKey]
        vc.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0")
        return vc
    }
    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}
    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String?) -> Void
        init(onPick: @escaping (String?) -> Void) { self.onPick = onPick }
        nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let mail = contact.emailAddresses.first.map { String($0.value) }
            MainActor.assumeIsolated { onPick(mail) }
        }
        nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            MainActor.assumeIsolated { onPick(nil) }
        }
    }
}

enum QRCode {
    static func image(for text: String, scale: CGFloat = 10) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension View {
    /// Hinweis „Ortungsdienste deaktiviert“ mit Sprung in die Einstellungen.
    func settingsLink() -> some View {
        Button { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: { self }
    }
}

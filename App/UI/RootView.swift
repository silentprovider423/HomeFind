import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.session == nil {
            WelcomeView()
        } else if !model.onboardingDone {
            PermissionsView()
        } else {
            MainView()
        }
    }
}

/// Hauptfenster: Karte vollflächig, darüber die Infokarte (drei Größen) mit Reitern.
struct MainView: View {
    @Environment(AppModel.self) private var model
    static let smallDetent = PresentationDetent.height(150)

    var body: some View {
        @Bindable var model = model
        FindMapView()
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                MainSheet()
                    .presentationDetents([Self.smallDetent, .medium, .large], selection: $model.detent)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                    .sheet(item: $model.webURL) { SafariView(url: $0).ignoresSafeArea() }
                    .sheet(isPresented: $model.showMapChooser) { MapChooserView().presentationDetents([.height(330)]) }
                    .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                        Button("OK", role: .cancel) {}
                    } message: { Text(model.errorMessage ?? "") }
            }
            // Tastaturkürzel wie am Mac (⌘+ / ⌘−, ⌘1/⌘2/⌘3)
            .background {
                Group {
                    Button("Vergrößern") { model.zoom(by: 0.5) }.keyboardShortcut("+", modifiers: .command)
                    Button("Verkleinern") { model.zoom(by: 2) }.keyboardShortcut("-", modifiers: .command)
                    Button("Personen") { model.tab = .people }.keyboardShortcut("1", modifiers: .command)
                    Button("Geräte") { model.tab = .devices }.keyboardShortcut("2", modifiers: .command)
                    Button("Ich") { model.tab = .me }.keyboardShortcut("3", modifiers: .command)
                }
                .opacity(0).accessibilityHidden(true)
            }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// Inhalt der Infokarte: je Reiter ein eigener Navigationsstapel, unten die Reiterleiste.
struct MainSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Group {
                switch model.tab {
                case .people:
                    NavigationStack(path: $model.peoplePath) {
                        PeopleListView()
                            .navigationDestination(for: Int.self) { PersonDetailView(personId: $0) }
                    }
                case .devices:
                    NavigationStack(path: $model.devicesPath) {
                        DevicesListView()
                            .navigationDestination(for: MapSelection.self) { DeviceDetailView(selection: $0) }
                    }
                case .me:
                    NavigationStack(path: $model.mePath) {
                        MeView()
                            .navigationDestination(for: MeRoute.self) { route in
                                switch route {
                                case .privacy: PrivacyView()
                                case .places: PlacesView()
                                case .alerts: AlertsListView()
                                }
                            }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            GlassTabBar(selection: $model.tab)
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(text: t)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: t) { try? await Task.sleep(for: .seconds(3)); withAnimation { model.toast = nil } }
            }
        }
        .animation(.snappy, value: model.toast)
    }
}

/// Reiterleiste im Liquid-Glass-Stil: Personen · Geräte · Ich (kein „Objekte“ – AirTags gibt es nur bei Apple).
struct GlassTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                item(.people, "Personen", "person.2.fill")
                item(.devices, "Geräte", "laptopcomputer.and.iphone")
                item(.me, "Ich", "person.crop.circle.fill")
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func item(_ tab: AppTab, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button {
            withAnimation(.snappy) { selection = tab }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(height: 24)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
            .background {
                if selection == tab {
                    Capsule().fill(Color.primary.opacity(0.08)).matchedGeometryEffect(id: "sel", in: ns)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

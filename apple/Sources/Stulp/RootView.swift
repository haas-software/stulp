import StulpKit
import SwiftUI

/// The places in the app. On iPhone a tab bar (Thuis, Automatisering, Instellingen); on iPad the
/// same tabs as a sidebar with the categories and rooms in it, as Home does; on the Mac a sidebar
/// window with Settings in ⌘,.
enum AppTab: Hashable {
    case home
    case category(DevicePresentation.Category)
    case room(String)
    case automations
    case notifications
    case apps
    case settings

    static var initial: AppTab {
        switch DebugLaunch.tab {
        case "automations": .automations
        case "settings": .settings
        case "apps": .apps
        case "notifications": .notifications
        default: .home
        }
    }
}

struct RootView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.initial
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isConfigured {
                main
            } else {
                NavigationStack { OnboardingView() }
            }
        }
        .sheet(item: $model.openDevice.identified) { item in
            DeviceDetailView(deviceID: item.id)
                .environment(model)
        }
        .sheet(isPresented: $model.addingDevice) {
            AddDeviceView()
                .environment(model)
        }
        .noticeBanner($model.notice)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: model.start()
            #if os(iOS)
            case .background: model.stop()
            #endif
            default: break
            }
        }
        .task {
            if let open = DebugLaunch.open { model.openDevice = open }
            #if DEBUG
            // `-stulpAdd YES`: the add sheet at launch (screenshots); `-stulpAddRoute` picks a step.
            if UserDefaults.standard.bool(forKey: "stulpAdd") { model.addingDevice = true }
            #endif
        }
        #if os(iOS)
        // A tapped notification with a camera opens that camera.
        .onChange(of: PushCenter.shared.openDevice, initial: true) { _, id in
            guard let id else { return }
            model.openDevice = id
            PushCenter.shared.openDevice = nil
        }
        #endif
    }

    @ViewBuilder private var main: some View {
        #if os(macOS)
        MacRootView(tab: $tab)
        #else
        tabs
        #endif
    }

    #if os(iOS)
    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Thuis", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            // Only with a sidebar (iPad, an open Duo): in a tab bar these would crowd out the rest.
            if width == .regular {
                TabSection("Categorieën") {
                    ForEach(model.presentCategories) { category in
                        Tab(category.title, systemImage: category.symbol, value: AppTab.category(category)) {
                            NavigationStack { CategoryView(category: category) }
                        }
                    }
                }
                TabSection("Ruimtes") {
                    ForEach(model.children(of: nil)) { group in
                        Tab(group.name, systemImage: RoomSymbol.name(for: group.name), value: AppTab.room(group.id)) {
                            NavigationStack { RoomView(groupID: group.id) }
                        }
                    }
                }
            }
            Tab("Automatisering", systemImage: "clock.fill", value: AppTab.automations) {
                NavigationStack { FlowsView() }
            }
            Tab("Instellingen", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: model.groups) { _, _ in
            // A room that is gone cannot stay selected.
            if case .room(let id) = tab, model.group(id) == nil { tab = .home }
        }
        .onChange(of: width) { _, new in
            // Folding the Duo shut takes the sidebar's rooms and categories away.
            switch tab {
            case .category, .room: if new != .regular { tab = .home }
            default: break
            }
        }
    }
    #endif
}

#if os(macOS)
/// The Mac window: an explicit split view. `.sidebarAdaptable` shares one navigation column between
/// the tabs on the Mac, which trips SwiftUI as soon as two of them push.
private struct MacRootView: View {
    @Environment(HomeModel.self) private var model
    @Binding var tab: AppTab

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { tab }, set: { if let new = $0 { tab = new } })) {
                Section {
                    Label("Thuis", systemImage: "house.fill").tag(AppTab.home)
                    ForEach(model.presentCategories) { category in
                        Label(category.title, systemImage: category.symbol).tag(AppTab.category(category))
                    }
                }
                Section("Ruimtes") {
                    ForEach(model.children(of: nil)) { group in
                        Label(group.name, systemImage: RoomSymbol.name(for: group.name)).tag(AppTab.room(group.id))
                    }
                }
                Section("Stulp") {
                    Label("Automatisering", systemImage: "clock.fill").tag(AppTab.automations)
                    Label("Meldingen", systemImage: "bell.fill").tag(AppTab.notifications)
                    Label("Apps", systemImage: "puzzlepiece.extension.fill").tag(AppTab.apps)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                ConnectionFooter().padding(10)
            }
        } detail: {
            Group {
                switch tab {
                case .home: NavigationStack { HomeView() }
                case .category(let category): NavigationStack { CategoryView(category: category) }
                case .room(let id): NavigationStack { RoomView(groupID: id) }
                case .automations: NavigationStack { FlowsView() }
                case .notifications: NavigationStack { NotificationsView() }
                case .apps: NavigationStack { AppsView() }
                case .settings: NavigationStack { SettingsView() }
                }
            }
            .id(tab)
        }
    }
}
#endif

/// The state of the line to Stulp, as small as it can be: only when it is not simply live.
struct ConnectionFooter: View {
    @Environment(HomeModel.self) private var model

    var body: some View {
        switch model.phase {
        case .live:
            EmptyView()
        case .connecting:
            Label("Verbinden…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .offline(let reason):
            Label(reason, systemImage: "wifi.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A symbol for a room from its name, so the sidebar reads like Home's. Unknown names get a door.
enum RoomSymbol {
    static func name(for room: String) -> String {
        let n = room.lowercased()
        let table: [(String, String)] = [
            ("woonkamer", "sofa.fill"), ("zitkamer", "sofa.fill"), ("living", "sofa.fill"),
            ("keuken", "fork.knife"), ("eetkamer", "fork.knife"),
            ("slaapkamer", "bed.double.fill"), ("kinderkamer", "teddybear.fill"),
            ("badkamer", "bathtub.fill"), ("douche", "shower.fill"), ("toilet", "toilet.fill"), ("wc", "toilet.fill"),
            ("tuin", "tree.fill"), ("buiten", "sun.horizon.fill"), ("terras", "chair.lounge.fill"), ("balkon", "chair.lounge.fill"),
            ("garage", "car.fill"), ("oprit", "car.fill"),
            ("kantoor", "desktopcomputer"), ("werkkamer", "desktopcomputer"), ("studeer", "desktopcomputer"),
            ("hal", "door.left.hand.closed"), ("gang", "door.left.hand.closed"), ("entree", "door.left.hand.closed"),
            ("trap", "stairs"), ("overloop", "stairs"), ("zolder", "house.lodge.fill"),
            ("wasruimte", "washer.fill"), ("bijkeuken", "washer.fill"), ("berging", "cabinet.fill"), ("schuur", "cabinet.fill"),
        ]
        return table.first { n.contains($0.0) }?.1 ?? "square.split.bottomrightquarter.fill"
    }
}

#Preview("Thuis") {
    RootView().previewHouse()
}

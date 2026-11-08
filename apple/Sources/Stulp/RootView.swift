import StulpKit
import SwiftUI

/// The places in the app. On iPhone a tab bar with Thuis and the house's first level of places
/// (floors, or rooms in a flat house), each with its icon, so one tap takes you there; Automatisering,
/// Meldingen and Instellingen sit in the menu at the top. On iPad the same tabs as a sidebar, with
/// the categories, Automatisering and Instellingen in it too; on the Mac a sidebar window with
/// Settings in ⌘,.
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
        case let tab? where tab.hasPrefix("room:"): .room(String(tab.dropFirst(5)))
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
                NavigationStack { HomeView(isTab: true) }
            }
            // The system tab bar keeps a tab's label and place for as long as its identity stays
            // the same, so a new order (or name, or icon) never showed. Each location tab's
            // identity therefore carries all of that: a change makes new tabs, drawn in the new
            // order. Only these tabs are rebuilt; Thuis, with Instellingen pushed on it, stays.
            let locations = model.children(of: nil)
            let signature = locations.map { "\($0.id):\($0.name):\(RoomSymbol.symbol($0))" }.joined(separator: "|")
            ForEach(locations.map { (key: "\($0.id)#\(signature)", group: $0) }, id: \.key) { entry in
                Tab(entry.group.name, systemImage: RoomSymbol.symbol(entry.group), value: AppTab.room(entry.group.id)) {
                    NavigationStack { HomeView(scope: entry.group.id, isTab: true) }
                }
            }
            // Only with a sidebar (iPad, an open Duo); on an iPhone they are in the menu at the top,
            // so the tab bar holds the places.
            if width == .regular {
                TabSection("Categorieën") {
                    ForEach(model.presentCategories) { category in
                        Tab(category.title, systemImage: category.symbol, value: AppTab.category(category)) {
                            NavigationStack { CategoryView(category: category) }
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
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: model.groups) { _, _ in
            // A room that is gone cannot stay selected.
            if case .room(let id) = tab, model.group(id) == nil { tab = .home }
        }
        .onChange(of: width, initial: true) { _, new in
            // Folding the Duo shut takes the sidebar's categories, Automatisering and Instellingen
            // away; they are in the menu at the top then.
            switch tab {
            case .category, .automations, .settings, .notifications, .apps: if new != .regular { tab = .home }
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
                Section("Locaties") {
                    ForEach(model.children(of: nil)) { group in
                        Label(group.name, systemImage: RoomSymbol.symbol(group)).tag(AppTab.room(group.id))
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
                case .room(let id): NavigationStack { HomeView(scope: id) }
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

/// Where the menu at the top leads, on an iPhone (the iPad and the Mac have these in the sidebar).
enum MenuRoute: Hashable {
    case automations, notifications, settings
}

extension View {
    /// The menu (…) of a tab's first screen on an iPhone: Automatisering, Meldingen, Instellingen,
    /// pushed onto that tab's stack. With a sidebar only the bell, since the rest is in the sidebar.
    func mainMenu() -> some View {
        modifier(MainMenu())
    }
}

private struct MainMenu: ViewModifier {
    @State private var route: MenuRoute?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbar {
                if width == .regular {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Meldingen", systemImage: "bell") { route = .notifications }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Automatisering", systemImage: "clock") { route = .automations }
                            Button("Meldingen", systemImage: "bell") { route = .notifications }
                            Divider()
                            Button("Instellingen", systemImage: "gearshape") { route = .settings }
                        } label: {
                            Label("Menu", systemImage: "ellipsis")
                        }
                    }
                }
            }
            .task {
                #if DEBUG
                // `-stulpTab automations|notifications|settings` on an iPhone: through the menu.
                if width != .regular, route == nil {
                    switch DebugLaunch.tab {
                    case "automations": route = .automations
                    case "notifications": route = .notifications
                    case "settings": route = .settings
                    default: break
                    }
                }
                #endif
            }
            .navigationDestination(item: $route) { route in
                switch route {
                case .automations: FlowsView()
                case .notifications: NotificationsView()
                case .settings: SettingsView()
                }
            }
        #else
        content
        #endif
    }
}

#Preview("Thuis") {
    RootView().previewHouse()
}

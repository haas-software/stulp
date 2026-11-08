import StulpKit
import SwiftUI

/// Where an overview pushes to.
enum HomeRoute: Hashable {
    /// A category, within the overview's scope (nil: the whole house).
    case category(DevicePresentation.Category, scope: String?)
    case room(String)
}

/// The overview, laid out as Home's: the categories with their summary on top, then scenes,
/// cameras, and every room with its tiles. The same page serves the whole house (Thuis), a
/// location in the tab bar (Beneden: its scenes, its cameras, its rooms, also those a level or more
/// down) and a room you tap. The bar carries no title; what stays in
/// sight is the room you are in, as a capsule at the top. Every title is such a capsule.
struct HomeView: View {
    @Environment(HomeModel.self) private var model
    /// The location or room this page covers; nil is the whole house.
    var scope: String? = nil
    /// A tab's first screen: it carries the menu at the top.
    var isTab = false
    @State private var editingRoom = false

    private var title: String {
        guard let scope else { return "Thuis" }
        return model.group(scope)?.name ?? "Ruimte"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: .sectionHeaders) {
                    if !model.loaded {
                        ProgressView("Stulp laden…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if scope != nil, model.group(scope) == nil {
                        ContentUnavailableView("Ruimte niet gevonden", systemImage: "questionmark.square.dashed")
                    } else if model.devices(scope: scope).isEmpty {
                        empty
                    } else {
                        content
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .task(id: model.loaded) {
                // `-stulpScrollTo Keuken`: start scrolled to that heading, for screenshots.
                if model.loaded, scope == nil, let heading = DebugLaunch.scrollTo {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(SectionTitle<HomeRoute>.scrollID(heading), anchor: .top)
                }
            }
        }
        .background(HomeBackground())
        .pageTitle(title)
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .category(let category, let scope): CategoryView(category: category, scope: scope)
            case .room(let id): HomeView(scope: id)
            }
        }
        .toolbar {
            HomeToolbar()
            if scope != nil {
                ToolbarItem(placement: .trailingBar) {
                    Button("Ruimte-instellingen", systemImage: "slider.horizontal.3") { editingRoom = true }
                }
            }
        }
        .sheet(isPresented: $editingRoom) {
            if let scope {
                NavigationStack { RoomEditor(groupID: scope) }
                    .environment(model)
            }
        }
        .modifier(TabMenu(active: isTab))
        .refreshable { await model.reloadDevices() }
    }

    @ViewBuilder private var content: some View {
        if let scope, let place = model.group(scope) {
            // Every title is a capsule that scrolls along, the page's too: the place itself first,
            // over its categories and its own devices, until the next capsule pushes it away.
            Section {
                #if os(iOS)
                ConnectionFooter()
                #endif
                CategoryStrip(scope: scope)
                let own = tiles(model.devices(in: scope))
                if !own.isEmpty { TileGrid(devices: own) }
            } header: {
                SectionTitle<HomeRoute>(title: place.name, subtitle: place.parentId.map { model.path(of: $0) })
            }
        } else {
            Section {
                #if os(iOS)
                ConnectionFooter()
                #endif
                CategoryStrip(scope: nil)
            } header: {
                SectionTitle<HomeRoute>(title: "Thuis")
            }
        }

        let all = model.devices(scope: scope)
        let scenes = all.filter(\.isScene)
        if !scenes.isEmpty {
            Section {
                TileGrid(devices: scenes, tapToggles: true)
            } header: {
                SectionTitle<HomeRoute>(title: "Scènes")
            }
        }

        let cameras = all.filter(Self.isCamera)
        if !cameras.isEmpty {
            Section {
                CameraStrip(cameras: cameras)
            } header: {
                SectionTitle<HomeRoute>(title: "Camera's")
            }
        }

        ForEach(model.rooms(scope: scope).filter { $0.group.id != scope }, id: \.group.id) { entry in
            let devices = tiles(model.devices(in: entry.group.id))
            if !devices.isEmpty {
                Section {
                    TileGrid(devices: devices)
                } header: {
                    heading(entry.group, depth: entry.depth)
                }
            }
        }

        if scope == nil {
            let loose = tiles(model.devices(in: nil))
            if !loose.isEmpty {
                Section {
                    TileGrid(devices: loose)
                } header: {
                    SectionTitle<HomeRoute>(title: "Overig")
                }
            }
        }
    }

    /// In the whole house: the room by name with its location (the tab it lives under) beside it.
    /// Within a location: the room's path below that location. The page's own room has no link.
    private func heading(_ group: DeviceGroup, depth: Int) -> SectionTitle<HomeRoute> {
        if let scope {
            let base = model.path(of: scope)
            let path = model.path(of: group.id)
            let title = path.hasPrefix(base + " › ") ? String(path.dropFirst(base.count + 3)) : group.name
            return SectionTitle(title: title, destination: group.id == scope ? nil : HomeRoute.room(group.id))
        }
        return SectionTitle(
            title: depth == 0 ? group.name : pathBelowRoot(group),
            subtitle: depth == 0 ? nil : model.group(rootID(group))?.name,
            destination: HomeRoute.room(group.id))
    }

    static func isCamera(_ device: Device) -> Bool {
        device.deviceClass == "camera" || device.deviceClass == "doorbell"
    }

    /// Scenes and cameras have their own rows above.
    private func tiles(_ devices: [Device]) -> [Device] {
        devices.filter { !$0.isScene && !Self.isCamera($0) }
    }

    /// "Woonkamer › Bank" for Beneden › Woonkamer › Bank: the location is already the subtitle.
    private func pathBelowRoot(_ group: DeviceGroup) -> String {
        let root = model.group(rootID(group))?.name ?? ""
        let path = model.path(of: group.id)
        return path.hasPrefix(root + " › ") ? String(path.dropFirst(root.count + 3)) : path
    }

    private func rootID(_ group: DeviceGroup) -> String {
        var current = group
        while let parent = model.group(current.parentId) { current = parent }
        return current.id
    }

    @ViewBuilder private var empty: some View {
        if let scope, let group = model.group(scope) {
            ContentUnavailableView {
                Label("Deze ruimte is nog leeg", systemImage: RoomSymbol.symbol(group))
            } description: {
                Text("Verplaats een apparaat hierheen met een lange druk op zijn tegel.")
            }
        } else {
            ContentUnavailableView {
                Label("Nog geen apparaten", systemImage: "house")
            } description: {
                Text("Voeg een apparaat toe uit een van je apps, of een Matter-apparaat met zijn code.")
            } actions: {
                Button("Apparaat toevoegen") { model.addingDevice = true }
                    .buttonStyle(.glassProminent)
            }
            .frame(minHeight: 400)
        }
    }
}

extension View {
    /// The title for the back button, VoiceOver and the Mac's window; on iOS not drawn in the bar,
    /// since every page names itself with the capsule at its top.
    @ViewBuilder
    func pageTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
        #else
        navigationTitle(title)
        #endif
    }
}

extension HomeModel {
    /// The devices of the whole house (nil) or of a place and everything below it.
    func devices(scope: String?) -> [Device] {
        guard let scope else { return visibleDevices.sorted(by: Self.tileOrder) }
        return allDevices(under: scope)
    }

    /// The rooms of the whole house (nil), or a place itself and the rooms below it, in display
    /// order with their depth.
    func rooms(scope: String?) -> [(group: DeviceGroup, depth: Int)] {
        guard let scope, let root = group(scope) else { return scope == nil ? roomTree : [] }
        var out: [(DeviceGroup, Int)] = [(root, 0)]
        func walk(_ parent: String, _ depth: Int) {
            for child in children(of: parent) {
                out.append((child, depth))
                walk(child.id, depth + 1)
            }
        }
        walk(scope, 1)
        return out
    }
}

/// The plus (add a device, a scene, a room) and, on iPhone, the bell.
struct HomeToolbar: ToolbarContent {
    @Environment(HomeModel.self) private var model
    @State private var addingRoom = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .trailingBar) {
            Menu {
                Button("Apparaat toevoegen", systemImage: "plus.square.on.square") { model.addingDevice = true }
                Button("Ruimte toevoegen", systemImage: "square.split.bottomrightquarter") { addingRoom = true }
            } label: {
                Label("Voeg toe", systemImage: "plus")
            }
            .sheet(isPresented: $addingRoom) {
                NavigationStack { RoomEditor(groupID: nil) }
                    .environment(model)
            }
        }
    }
}

/// Home's category buttons: symbol, name and what is going on, in a row that scrolls.
struct CategoryStrip: View {
    @Environment(HomeModel.self) private var model
    var scope: String?

    var body: some View {
        let devices = model.devices(scope: scope)
        let categories = DevicePresentation.Category.allCases.filter { category in
            devices.contains { DevicePresentation.categories($0).contains(category) }
        }
        if !categories.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(categories) { category in
                        NavigationLink(value: HomeRoute.category(category, scope: scope)) {
                            CategoryButton(
                                category: category,
                                summary: DevicePresentation.summary(category, devices: devices))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

private struct CategoryButton: View {
    let category: DevicePresentation.Category
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(category.title).font(.footnote.weight(.semibold))
                if !summary.isEmpty {
                    Text(summary).font(.footnote).foregroundStyle(.secondary).contentTransition(.numericText())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// A quiet wash of the icon's pink behind the overview, where Home has its wallpaper.
struct HomeBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            #if os(iOS)
            Color(.systemGroupedBackground)
            #else
            Color(nsColor: .windowBackgroundColor)
            #endif
            LinearGradient(
                colors: [Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.12), .clear],
                startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// The devices of one category, room by room, within a scope (nil: the whole house).
struct CategoryView: View {
    @Environment(HomeModel.self) private var model
    let category: DevicePresentation.Category
    var scope: String? = nil

    var body: some View {
        let devices = model.devices(scope: scope).filter { DevicePresentation.categories($0).contains(category) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: .sectionHeaders) {
                Section {
                    let summary = DevicePresentation.summary(category, devices: devices)
                    if !summary.isEmpty {
                        Text(summary).font(.title3).foregroundStyle(.secondary)
                    }
                } header: {
                    SectionTitle<HomeRoute>(title: category.title, subtitle: scope.map { model.path(of: $0) })
                }
                ForEach(rooms(devices), id: \.0) { title, members in
                    Section {
                        TileGrid(devices: members)
                    } header: {
                        SectionTitle<HomeRoute>(title: title)
                    }
                }
                if devices.isEmpty {
                    ContentUnavailableView("Niets in \(category.title.lowercased())", systemImage: category.symbol)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .pageTitle(category.title)
        .background(HomeBackground())
        .refreshable { await model.reloadDevices() }
    }

    private func rooms(_ devices: [Device]) -> [(String, [Device])] {
        var out: [(String, [Device])] = []
        for entry in model.rooms(scope: scope) {
            let members = devices.filter { $0.groupId == entry.group.id }
            if !members.isEmpty { out.append((model.path(of: entry.group.id), members)) }
        }
        if scope == nil {
            let known = Set(model.groups.map(\.id))
            let loose = devices.filter { $0.groupId.map { !known.contains($0) } ?? true }
            if !loose.isEmpty { out.append(("Overig", loose)) }
        }
        return out
    }
}

#Preview("Thuis") {
    NavigationStack { HomeView(isTab: true) }.previewHouse()
}

/// The menu at the top only where the view is a tab's first screen.
private struct TabMenu: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active { content.mainMenu() } else { content }
    }
}

import StulpKit
import SwiftUI

/// Where Home pushes to from the overview.
enum HomeRoute: Hashable {
    case category(DevicePresentation.Category)
    case room(String)
}

/// The overview, laid out as Home's: the categories with their summary on top, then scenes,
/// cameras, and every room with its tiles.
struct HomeView: View {
    @Environment(HomeModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.loaded {
                        ProgressView("Stulp laden…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if model.visibleDevices.isEmpty {
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
            .sectionTitles("Thuis")
            .task(id: model.loaded) {
                // `-stulpScrollTo Keuken`: start scrolled to that heading, for screenshots.
                if model.loaded, let heading = DebugLaunch.scrollTo {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(SectionTracker.scrollID(heading), anchor: .top)
                }
            }
        }
        .background(HomeBackground())
        .largeTitle()
        .navigationDestination(for: HomeRoute.self) { route in
            switch route {
            case .category(let category): CategoryView(category: category)
            case .room(let id): RoomView(groupID: id)
            }
        }
        .toolbar { HomeToolbar() }
        .refreshable { await model.reloadDevices() }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        ConnectionFooter()
        #endif
        CategoryStrip()

        let scenes = model.sceneDevices
        if !scenes.isEmpty {
            SectionTitle<HomeRoute>(title: "Scènes")
            TileGrid(devices: scenes, tapToggles: true)
        }

        let cameras = model.cameras
        if !cameras.isEmpty {
            SectionTitle<HomeRoute>(title: "Camera's")
            CameraStrip(cameras: cameras)
        }

        ForEach(model.roomTree, id: \.group.id) { entry in
            let devices = tiles(model.devices(in: entry.group.id))
            if !devices.isEmpty {
                SectionTitle(
                    title: entry.depth == 0 ? entry.group.name : model.path(of: entry.group.id),
                    destination: HomeRoute.room(entry.depth == 0 ? entry.group.id : rootID(entry.group)))
                TileGrid(devices: devices)
            }
        }

        let loose = tiles(model.devices(in: nil))
        if !loose.isEmpty {
            SectionTitle<HomeRoute>(title: "Overig")
            TileGrid(devices: loose)
        }
    }

    /// Scenes and cameras have their own rows above.
    private func tiles(_ devices: [Device]) -> [Device] {
        devices.filter { !$0.isScene && $0.deviceClass != "camera" && $0.deviceClass != "doorbell" }
    }

    private func rootID(_ group: DeviceGroup) -> String {
        var current = group
        while let parent = model.group(current.parentId) { current = parent }
        return current.id
    }

    private var empty: some View {
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

/// The plus (add a device, a scene, a room) and, on iPhone, the bell.
struct HomeToolbar: ToolbarContent {
    @Environment(HomeModel.self) private var model
    @State private var addingRoom = false

    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                NotificationsView()
            } label: {
                Label("Meldingen", systemImage: "bell")
            }
        }
        #endif
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

    var body: some View {
        let categories = model.presentCategories
        if !categories.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(categories) { category in
                        NavigationLink(value: HomeRoute.category(category)) {
                            CategoryButton(
                                category: category,
                                summary: DevicePresentation.summary(category, devices: Array(model.visibleDevices)))
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

/// The devices of one category, room by room.
struct CategoryView: View {
    @Environment(HomeModel.self) private var model
    let category: DevicePresentation.Category

    var body: some View {
        let devices = model.devices(in: category)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let summary = DevicePresentation.summary(category, devices: devices)
                if !summary.isEmpty {
                    Text(summary).font(.title3).foregroundStyle(.secondary)
                }
                ForEach(rooms(devices), id: \.0) { title, members in
                    SectionTitle<HomeRoute>(title: title)
                    TileGrid(devices: members)
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
        .sectionTitles(category.title)
        .background(HomeBackground())
        .largeTitle()
        .refreshable { await model.reloadDevices() }
    }

    private func rooms(_ devices: [Device]) -> [(String, [Device])] {
        var out: [(String, [Device])] = []
        for entry in model.roomTree {
            let members = devices.filter { $0.groupId == entry.group.id }
            if !members.isEmpty { out.append((model.path(of: entry.group.id), members)) }
        }
        let known = Set(model.groups.map(\.id))
        let loose = devices.filter { $0.groupId.map { !known.contains($0) } ?? true }
        if !loose.isEmpty { out.append(("Overig", loose)) }
        return out
    }
}

/// One room: its own tiles, then the rooms inside it.
struct RoomView: View {
    @Environment(HomeModel.self) private var model
    let groupID: String
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let group = model.group(groupID) {
                    let own = model.devices(in: groupID)
                    let cameras = own.filter { $0.deviceClass == "camera" || $0.deviceClass == "doorbell" }
                    if !cameras.isEmpty { CameraStrip(cameras: cameras) }
                    let rest = own.filter { !cameras.contains($0) }
                    if !rest.isEmpty { TileGrid(devices: rest) }
                    ForEach(subrooms(of: group.id), id: \.id) { sub in
                        let members = model.devices(in: sub.id)
                        if !members.isEmpty {
                            SectionTitle<HomeRoute>(title: model.path(of: sub.id).replacingOccurrences(of: "\(group.name) › ", with: ""))
                            TileGrid(devices: members)
                        }
                    }
                    if model.allDevices(under: groupID).isEmpty {
                        ContentUnavailableView {
                            Label("Deze ruimte is nog leeg", systemImage: RoomSymbol.name(for: group.name))
                        } description: {
                            Text("Verplaats een apparaat hierheen met een lange druk op zijn tegel.")
                        }
                    }
                } else {
                    ContentUnavailableView("Ruimte niet gevonden", systemImage: "questionmark.square.dashed")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .sectionTitles(model.group(groupID)?.name ?? "Ruimte")
        .background(HomeBackground())
        .largeTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Ruimte-instellingen", systemImage: "ellipsis") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { RoomEditor(groupID: groupID) }
                .environment(model)
        }
        .refreshable { await model.reloadDevices() }
    }

    private func subrooms(of id: String) -> [DeviceGroup] {
        var out: [DeviceGroup] = []
        func walk(_ parent: String) {
            for child in model.children(of: parent) {
                out.append(child)
                walk(child.id)
            }
        }
        walk(id)
        return out
    }
}

#Preview("Thuis") {
    NavigationStack { HomeView() }.previewHouse()
}

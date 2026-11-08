import StulpKit
import SwiftUI

/// "Apparaat toevoegen", as Home's add sheet: on an iPhone first the Matter code scan (Apple's
/// own setup screen), then Stulp's own scene, then every app that can pair, with its device types.
struct AddDeviceView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var drivers: [Driver] = []
    @State private var loading = true
    @State private var error: String?
    @State private var path = NavigationPath()

    enum Route: Hashable {
        case scene
        case driver(Driver)
        /// Debug only (`-stulpAddRoute apps` / `settings:<app>`): screens for screenshots on an iPhone.
        case apps
        case appSettings(String)
        case appPage(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                #if os(iOS)
                MatterAddSection()
                #endif
                Section {
                    NavigationLink(value: Route.scene) {
                        DriverRow(symbol: "sparkles", title: "Scène", subtitle: "Schakelt of activeert opgeslagen standen van apparaten")
                    }
                } header: {
                    Text("Stulp")
                }
                if loading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Apps laden…").foregroundStyle(.secondary)
                        }
                    }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                } else if groups.isEmpty {
                    Section {
                        Text("Geen app kan nu apparaten koppelen. Een app die nog niet draait of nog ingesteld moet worden, verschijnt hier zodra hij klaar is.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups, id: \.app) { group in
                    Section(group.title) {
                        ForEach(group.drivers) { driver in
                            NavigationLink(value: Route.driver(driver)) {
                                DriverRow(symbol: DriverRow.symbol(for: driver.deviceClass), title: driver.name, subtitle: nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Apparaat toevoegen")
            .inlineTitle()
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .scene: SceneEditor(sceneID: nil)
                case .driver(let driver): PairFlowView(driver: driver)
                case .apps: AppsView()
                case .appSettings(let id): AppDetailView(appID: id)
                case .appPage(let id):
                    if let app = model.apps.first(where: { $0.id == id }) { AppSettingsPage(app: app) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
            .task {
                await load()
                debugRoute()
            }
        }
        .macSheetSize(width: 520, height: 620)
    }

    private struct Group {
        let app: String
        let title: String
        let drivers: [Driver]
    }

    /// Drivers that can pair now, per app, in the order of the apps' names.
    private var groups: [Group] {
        let pairable = drivers.filter { $0.pair && $0.ready }
        let byApp = Dictionary(grouping: pairable, by: \.appId)
        return byApp.map { app, drivers in
            let title = model.apps.first { $0.id == app }?.name ?? drivers.first?.ownerName ?? app
            return Group(app: app, title: title, drivers: drivers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `-stulpAddRoute scene|apps|<driver id>`: open a step at launch (simulator screenshots).
    private func debugRoute() {
        #if DEBUG
        guard path.isEmpty, let route = UserDefaults.standard.string(forKey: "stulpAddRoute") else { return }
        switch route {
        case "scene": path.append(Route.scene)
        case "apps": path.append(Route.apps)
        case let r where r.hasPrefix("page:"): path.append(Route.appPage(String(r.dropFirst("page:".count))))
        case let r where r.hasPrefix("settings:"): path.append(Route.appSettings(String(r.dropFirst("settings:".count))))
        default:
            if let driver = drivers.first(where: { $0.driverName == route || $0.id == route }) {
                path.append(Route.driver(driver))
            }
        }
        #endif
    }

    private func load() async {
        guard let client = model.client else {
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            async let apps: Void = model.reloadApps()
            drivers = try await client.drivers()
            await apps
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DriverRow: View {
    let symbol: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The symbol a device of this class will get on its tile.
    static func symbol(for deviceClass: String) -> String {
        DevicePresentation.symbol(Device(id: "", name: "", deviceClass: deviceClass))
    }
}

// MARK: - Pairing with an app's driver

/// One pairing session with a driver: the app's own pages where it has them, otherwise Stulp's
/// built-in steps (`validate`, then `list_devices`). The session is closed however this ends.
struct PairFlowView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let driver: Driver

    enum Step: Equatable {
        case opening
        case page(String)
        case searching
        case candidates([JSONValue])
        case adding(String)
        case failed(String)
    }

    @State private var step = Step.opening
    @State private var session: PairSession?
    @State private var bridge: AppPageBridge?
    @State private var closed = false

    var body: some View {
        content
            .navigationTitle(bridge?.title ?? driver.name)
            .inlineTitle()
            .task { await open() }
            .onDisappear { close() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .opening:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .page(let view):
            if let bridge {
                AppPageView(bridge: bridge, path: pagePath(view))
            }
        case .searching:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Zoeken naar apparaten…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .candidates(let candidates):
            candidateList(candidates)
        case .adding(let name):
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("\(name) toevoegen…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Koppelen lukt niet", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Probeer opnieuw") { Task { await retry() } }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func candidateList(_ candidates: [JSONValue]) -> some View {
        List {
            if candidates.isEmpty {
                ContentUnavailableView {
                    Label("Geen apparaten gevonden", systemImage: "magnifyingglass")
                } description: {
                    Text("Controleer eerst de instellingen van de app.")
                } actions: {
                    Button("Zoek opnieuw") { Task { await search() } }
                }
            } else {
                Section {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                        Button {
                            Task { await add(candidate) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: DriverRow.symbol(for: candidate["class"]?.string ?? driver.deviceClass))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                Text(name(of: candidate))
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Gevonden")
                } footer: {
                    Text("Kies een apparaat om het aan Stulp toe te voegen.")
                }
            }
        }
        .refreshable { await search() }
    }

    private func name(of candidate: JSONValue) -> String {
        let name = LocalizedText.resolve(candidate["name"])
        return name.isEmpty ? driver.name : name
    }

    private func pagePath(_ view: String) -> String {
        let session = session?.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "/app-ui/\(driver.appId)/pair/\(driver.driverName)/\(view).html?session=\(session)"
    }

    // MARK: - Steps

    private func open() async {
        guard session == nil, let client = model.client else { return }
        do {
            let opened = try await client.openPair(app: driver.appId, driver: driver.driverName)
            session = opened
            let bridge = AppPageBridge(client: client, appId: driver.appId, pairSession: opened.id)
            bridge.onShowView = { view in Task { await show(view) } }
            bridge.onNextView = { Task { await move(by: 1) } }
            bridge.onPreviousView = { Task { await move(by: -1) } }
            bridge.onClose = { dismiss() }
            self.bridge = bridge
            if driver.startsWithCustomView, let first = driver.pairViews.first {
                step = .page(first)
                return
            }
            if opened.handlers.contains("validate") {
                let answer = try await client.emit(pair: opened.id, event: "validate")
                if answer == .string("nok") || answer == .bool(false) {
                    step = .failed("Configureer de app eerst.")
                    return
                }
            }
            await search()
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func retry() async {
        close()
        session = nil
        bridge = nil
        closed = false
        step = .opening
        await open()
    }

    /// A page asks for the next view by name. Its own views stay pages; anything else is the
    /// built-in device list, which is what almost every driver ends with.
    private func show(_ view: String) async {
        if driver.customPairViews.contains(view) {
            step = .page(view)
        } else if view == "done" {
            dismissAll()
        } else {
            await search()
        }
    }

    private func move(by offset: Int) async {
        let views = driver.pairViews
        let current: String? = if case .page(let view) = step { view } else if case .candidates = step { "list_devices" } else { nil }
        guard let current, let index = views.firstIndex(of: current) else { return }
        let next = index + offset
        guard views.indices.contains(next) else {
            if offset < 0 { dismiss() }
            return
        }
        await show(views[next])
    }

    private func search() async {
        guard let client = model.client, let session else { return }
        step = .searching
        do {
            let answer = try await client.emit(pair: session.id, event: "list_devices")
            step = .candidates(answer.array ?? [])
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func add(_ candidate: JSONValue) async {
        guard let client = model.client else { return }
        let name = name(of: candidate)
        step = .adding(name)
        do {
            let device = try await client.addDevice(app: driver.appId, driver: driver.driverName, candidate: candidate)
            model.notice = HomeModel.Notice(text: "\(device.name) is toegevoegd.", isError: false)
            await model.reloadDevices()
            dismissAll(opening: device.id)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// Closes the whole add sheet and, once it is gone, opens the new device: two sheets cannot
    /// change places in one go.
    private func dismissAll(opening device: String? = nil) {
        close()
        model.addingDevice = false
        guard let device else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            model.openDevice = device
        }
    }

    private func close() {
        guard !closed, let session, let client = model.client else { return }
        closed = true
        Task.detached { try? await client.closePair(session.id) }
    }
}

#Preview("Toevoegen") {
    AddDeviceView().previewHouse()
}

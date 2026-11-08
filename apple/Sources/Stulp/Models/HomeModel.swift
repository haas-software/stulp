import Foundation
import Observation
import StulpKit

/// The whole house as the app holds it: devices (live), rooms, and on demand scenes, Flows, apps
/// and notifications. One instance per app, shared through the environment.
///
/// Devices stay current through one event stream. When it opens, the app takes a snapshot; events
/// that arrive meanwhile wait in the stream, so nothing falls in between. A `device.update`
/// carries the full device and is applied as is; anything structural reloads what it touches.
@MainActor
@Observable
final class HomeModel {
    enum Phase: Equatable {
        case connecting
        case live
        case offline(String)
    }

    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private(set) var connection: StulpConnection?
    private(set) var phase: Phase = .connecting
    private(set) var version = ""

    private(set) var devices: [String: Device] = [:]
    private(set) var groups: [DeviceGroup] = []
    private(set) var scenes: [StulpScene] = []
    private(set) var flows: [Flow] = []
    private(set) var cards: FlowCardCatalog?
    private(set) var apps: [StulpAppInfo] = []
    private(set) var notifications: [StulpNotification] = []
    /// Whether the first snapshot arrived; until then the house is not "empty", only unknown.
    private(set) var loaded = false

    /// A short message at the bottom of the window, gone after a few seconds.
    var notice: Notice?
    /// The device whose detail is open (also set by a tapped notification).
    var openDevice: String?
    /// The add sheet (`AddDeviceView`), from the toolbar or the menu.
    var addingDevice = false

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: Set<Reload> = []
    @ObservationIgnored let demo: Bool

    private enum Reload: Hashable { case devices, scenes, flows, cards, apps, notifications }

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            PreviewHouse.fill(self)
            return
        }
        connection = try? SharedStulpConfiguration.load()
        #if DEBUG
        if connection == nil, let address = DebugLaunch.address, let key = DebugLaunch.key {
            connection = try? StulpConnection.parse(address: address, key: key)
        }
        #endif
    }

    var client: StulpClient? { connection.map { StulpClient(connection: $0, logSource: Self.logSource) } }

    static let logSource: String = {
        #if os(macOS)
        "mac-app"
        #else
        "ios-app"
        #endif
    }()

    var isConfigured: Bool { connection != nil || demo }

    // MARK: - Connection

    /// Checks the address and key against `/api/stulp/health` and keeps them only when they work.
    func connect(_ candidate: StulpConnection) async throws -> String {
        let health = try await StulpClient(connection: candidate, logSource: Self.logSource).validate()
        guard health.ok else { throw StulpClientError.invalidResponse }
        try SharedStulpConfiguration.save(candidate)
        // The stream of the previous connection must not keep running against the old address.
        stop()
        connection = candidate
        version = health.stulpVersion
        reset()
        start()
        return health.stulpVersion
    }

    func disconnect() {
        stop()
        try? SharedStulpConfiguration.remove()
        try? PendingMatterDevices.remove()
        StulpPresenceSettings.remove()
        connection = nil
        reset()
    }

    private func reset() {
        devices = [:]
        groups = []
        scenes = []
        flows = []
        cards = nil
        apps = []
        notifications = []
        loaded = false
        phase = .connecting
    }

    // MARK: - Live

    /// Starts (or keeps) the event stream. Called when the app becomes active.
    func start() {
        guard !demo, liveTask == nil, connection != nil else { return }
        liveTask = Task { [weak self] in await self?.live() }
    }

    /// Stops the stream; iOS would cut it in the background anyway.
    func stop() {
        liveTask?.cancel()
        liveTask = nil
    }

    private func live() async {
        var delay: Duration = .milliseconds(500)
        while !Task.isCancelled, let client {
            if case .offline = phase {} else if !loaded { phase = .connecting }
            do {
                for try await element in client.events() {
                    switch element {
                    case .opened:
                        try await snapshot(client)
                        phase = .live
                        delay = .milliseconds(500)
                    case .event(let event):
                        handle(event)
                    }
                }
                if Task.isCancelled { break }
                phase = .offline("De verbinding met Stulp is verbroken.")
            } catch is CancellationError {
                break
            } catch let error as URLError where error.code == .cancelled {
                break
            } catch {
                phase = .offline(error.localizedDescription)
                if case StulpClientError.unauthorized = error { break }
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(10))
        }
        liveTask = nil
    }

    private func snapshot(_ client: StulpClient) async throws {
        async let boot = client.bootstrap()
        async let all = client.devices()
        let (b, d) = try await (boot, all)
        version = b.stulpVersion
        groups = b.deviceGroups
        devices = Dictionary(d.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        loaded = true
        // Whatever pages loaded on their own is stale after a gap.
        if !flows.isEmpty { schedule(.flows) }
        if !scenes.isEmpty { schedule(.scenes) }
        if !apps.isEmpty { schedule(.apps) }
    }

    func handle(_ event: StulpEvent) {
        switch (event.manager, event.type) {
        case ("devices", "device.update"):
            if let data = event.data, let device = try? Self.decode(Device.self, data) {
                devices[device.id] = device
            } else {
                schedule(.devices)
            }
        case ("devices", _):
            schedule(.devices)
        case ("scene", _):
            schedule(.scenes)
            schedule(.devices)
        case ("flow", "flow.run"), ("flow", "card.trigger"):
            if !flows.isEmpty { schedule(.flows) }
        case ("flow", _):
            schedule(.flows)
        case ("apps", _):
            schedule(.apps)
            schedule(.devices)
            cards = nil
        case ("notifications", let type):
            if type == "notification.create", let text = event.data?["excerpt"]?.string {
                notice = Notice(text: text, isError: false)
            }
            schedule(.notifications)
        case ("system", _), ("store", _):
            cards = nil
            for reload in [Reload.devices, .scenes, .flows, .apps, .notifications] { schedule(reload) }
        default:
            break
        }
    }

    /// Bursts of events (a restore, an app restart) become one reload per kind.
    private func schedule(_ reload: Reload) {
        pendingReload.insert(reload)
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let work = self.pendingReload
            self.pendingReload = []
            self.reloadTask = nil
            for reload in work {
                switch reload {
                case .devices: await self.reloadDevices()
                case .scenes: await self.reloadScenes()
                case .flows: await self.reloadFlows()
                case .cards: await self.reloadCards()
                case .apps: await self.reloadApps()
                case .notifications: await self.reloadNotifications()
                }
            }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    // MARK: - Loading

    func reloadDevices() async {
        guard let client else { return }
        do {
            async let all = client.devices()
            async let rooms = client.groups()
            let (d, g) = try await (all, rooms)
            devices = Dictionary(d.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            groups = g
            loaded = true
        } catch {
            report(error)
        }
    }

    func reloadScenes() async {
        guard let client else { return }
        do { scenes = try await client.scenes() } catch { report(error) }
    }

    func reloadFlows() async {
        guard let client else { return }
        do {
            flows = try await client.flows().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            report(error)
        }
    }

    func reloadCards() async {
        guard let client else { return }
        do { cards = try await client.cards() } catch { report(error) }
    }

    /// The card catalog, loaded once and dropped when apps or units change.
    func ensureCards() async {
        if cards == nil { await reloadCards() }
    }

    func reloadApps() async {
        guard let client else { return }
        do {
            apps = try await client.apps().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            report(error)
        }
    }

    func reloadNotifications() async {
        guard let client else { return }
        do { notifications = try await client.notifications() } catch { report(error) }
    }

    // MARK: - Doing things

    /// Runs one request, shows its error as a notice and optionally a confirmation. Answers whether
    /// it worked, for callers that close a sheet only on success.
    @discardableResult
    func perform(_ success: String? = nil, _ work: (StulpClient) async throws -> Void) async -> Bool {
        guard let client else { return false }
        do {
            try await work(client)
            if let success { notice = Notice(text: success, isError: false) }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func report(_ error: Error) {
        if error is CancellationError { return }
        if let url = error as? URLError, url.code == .cancelled { return }
        notice = Notice(text: error.localizedDescription, isError: true)
    }

    /// Sets a capability and shows the new value at once. The event stream brings the device's own
    /// answer; a refusal puts the old value back.
    func set(_ device: Device, _ capability: String, _ value: JSONValue) async {
        guard !demo else {
            devices[device.id]?.capabilitiesObj[capability]?.value = value
            return
        }
        let previous = devices[device.id]?.capabilitiesObj[capability]?.value
        devices[device.id]?.capabilitiesObj[capability]?.value = value
        let ok = await perform { try await $0.setCapability(device: device.id, capability: capability, value: value) }
        if !ok { devices[device.id]?.capabilitiesObj[capability]?.value = previous }
    }

    /// The tile's tap: flip its boolean, or press a scene button.
    func toggle(_ device: Device) async {
        guard let capability = DevicePresentation.toggleCapability(device) else { return }
        if DevicePresentation.isStateless(capability) {
            await set(device, capability.id, true)
        } else {
            await set(device, capability.id, .bool(!(capability.bool ?? false)))
        }
    }

    func rename(_ device: Device, to name: String) async {
        await perform { client in
            let updated = try await client.renameDevice(device.id, name: name)
            self.devices[updated.id] = updated
        }
    }

    func move(_ device: Device, to group: String?) async {
        await perform { client in
            let updated = try await client.moveDevice(device.id, toGroup: group)
            self.devices[updated.id] = updated
        }
    }

    func delete(_ device: Device) async {
        let ok = await perform("\(device.name) is verwijderd.") { try await $0.deleteDevice(device.id) }
        if ok {
            devices[device.id] = nil
            if openDevice == device.id { openDevice = nil }
        }
    }

    // MARK: - Reading the house

    var visibleDevices: [Device] { devices.values.filter { !$0.hidden } }

    /// Devices in one room (nil: in no known room), in their tile order.
    func devices(in group: String?) -> [Device] {
        let known = Set(groups.map(\.id))
        return visibleDevices
            .filter { group == nil ? ($0.groupId.map { !known.contains($0) } ?? true) : $0.groupId == group }
            .sorted(by: Self.tileOrder)
    }

    static func tileOrder(_ a: Device, _ b: Device) -> Bool {
        let sa = a.sortOrder.flatMap { $0 > 0 ? $0 : nil } ?? .infinity
        let sb = b.sortOrder.flatMap { $0 > 0 ? $0 : nil } ?? .infinity
        if sa != sb { return sa < sb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    func children(of parent: String?) -> [DeviceGroup] {
        groups.filter { $0.parentId == parent }.sorted {
            let sa = $0.sortOrder ?? .infinity, sb = $1.sortOrder ?? .infinity
            if sa != sb { return sa < sb }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Every room in display order, depth first, with its depth.
    var roomTree: [(group: DeviceGroup, depth: Int)] {
        var out: [(DeviceGroup, Int)] = []
        func walk(_ parent: String?, _ depth: Int) {
            for group in children(of: parent) {
                out.append((group, depth))
                walk(group.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    func group(_ id: String?) -> DeviceGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// "Woonkamer › Bank": a device's place, also to tell two lamps with one name apart.
    func path(of group: String?) -> String {
        var names: [String] = []
        var current = self.group(group)
        var guardCount = 0
        while let g = current, guardCount < 32 {
            names.insert(g.name, at: 0)
            current = self.group(g.parentId)
            guardCount += 1
        }
        return names.joined(separator: " › ")
    }

    /// Devices in a room and all rooms below it.
    func allDevices(under group: String) -> [Device] {
        var ids: Set<String> = [group]
        var changed = true
        while changed {
            changed = false
            for g in groups where g.parentId.map(ids.contains) == true && !ids.contains(g.id) {
                ids.insert(g.id)
                changed = true
            }
        }
        return visibleDevices.filter { $0.groupId.map(ids.contains) == true }.sorted(by: Self.tileOrder)
    }

    var sceneDevices: [Device] { visibleDevices.filter(\.isScene).sorted(by: Self.tileOrder) }
    var cameras: [Device] {
        visibleDevices.filter { $0.deviceClass == "camera" || $0.deviceClass == "doorbell" }.sorted(by: Self.tileOrder)
    }

    var presentCategories: [DevicePresentation.Category] {
        let all = visibleDevices
        return DevicePresentation.Category.allCases.filter { category in
            all.contains { DevicePresentation.categories($0).contains(category) }
        }
    }

    func devices(in category: DevicePresentation.Category) -> [Device] {
        visibleDevices.filter { DevicePresentation.categories($0).contains(category) }.sorted(by: Self.tileOrder)
    }

    func scene(for device: Device) -> StulpScene? {
        guard let id = device.sceneId else { return nil }
        return scenes.first { $0.id == id }
    }

    // MARK: - Demo

    /// Used by previews and `-stulpDemo YES`: a filled house without a server.
    func fillDemo(devices: [Device], groups: [DeviceGroup], flows: [Flow] = [], version: String = "demo") {
        self.devices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.groups = groups
        self.flows = flows
        self.version = version
        self.loaded = true
        self.phase = .live
    }
}

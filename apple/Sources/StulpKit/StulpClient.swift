import Foundation

/// Stulp's HTTP API with the key as a Bearer token. Stateless: every call is one request, so the
/// app, the Matter extension and a Shortcuts action can each make one when they need it.
public struct StulpClient: Sendable {
    public let connection: StulpConnection
    let session: URLSession
    let logSource: String

    public init(connection: StulpConnection, logSource: String = "apple", session: URLSession? = nil) {
        self.connection = connection
        self.logSource = logSource
        self.session = session ?? Self.shared
    }

    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - Requests

    public func url(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: connection.baseURL)?.absoluteURL else {
            throw StulpClientError.invalidResponse
        }
        return url
    }

    /// A request with the Bearer header, for callers that load themselves (images, streams).
    public func request(_ path: String, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    public func send(
        _ method: String, _ path: String, json: JSONValue? = nil, body: Data? = nil, contentType: String? = nil
    ) async throws -> Data {
        var request = try request(path, method: method)
        if let json {
            request.httpBody = try JSONEncoder().encode(json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return data
    }

    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try Self.decode(type, from: try await send("GET", path))
    }

    public func call<T: Decodable>(_ method: String, _ path: String, json: JSONValue? = nil, as type: T.Type = T.self) async throws -> T {
        try Self.decode(type, from: try await send(method, path, json: json))
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw StulpClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let server = try? JSONDecoder().decode(ServerError.self, from: data)
            if http.statusCode == 401 { throw StulpClientError.unauthorized }
            throw StulpClientError.server(status: http.statusCode, message: server?.message)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StulpClientError.invalidResponse
        }
    }

    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - System

    public func validate() async throws -> StulpHealth {
        try await get("/api/stulp/health")
    }

    public func bootstrap() async throws -> Bootstrap {
        try await get("/api/stulp/manage/bootstrap")
    }

    public func system() async throws -> SystemSettings {
        try await get("/api/stulp/system")
    }

    public func updateSystem(_ patch: JSONValue) async throws -> SystemSettings {
        try await call("PUT", "/api/stulp/system", json: patch)
    }

    /// One line on the controller's console next to the plugin and request lines. Stulp stores
    /// nothing; a failure here is never a reason to stop, so callers ignore it.
    public func log(_ level: String, _ message: String) async throws {
        try await send("POST", "/api/stulp/log", json: [
            "source": .string(logSource), "level": .string(level), "message": .string(String(message.prefix(1000))),
        ])
    }

    public func trace(_ message: String) { trace("info", message) }

    public func trace(_ level: String, _ message: String) {
        Task { try? await self.log(level, message) }
    }

    // MARK: - Devices

    /// Every device, full (all capabilities with value, units and range in the house's units).
    public func devices() async throws -> [Device] {
        let map: [String: Device] = try await get("/api/manager/devices/device")
        return Array(map.values)
    }

    public func device(_ id: String) async throws -> Device {
        try await get("/api/manager/devices/device/\(Self.escape(id))")
    }

    /// The value is read in the house's units; Stulp converts it back for the device.
    public func setCapability(device: String, capability: String, value: JSONValue) async throws {
        try await send("PUT", "/api/manager/devices/device/\(Self.escape(device))/capability/\(Self.escape(capability))",
                       json: ["value": value])
    }

    public func renameDevice(_ id: String, name: String) async throws -> Device {
        try await call("PUT", "/api/manager/devices/device/\(Self.escape(id))", json: ["name": .string(name)])
    }

    public func deleteDevice(_ id: String) async throws {
        try await send("DELETE", "/api/manager/devices/device/\(Self.escape(id))")
    }

    /// Only the changed keys; the driver hears about exactly those.
    public func saveDeviceSettings(_ id: String, values: [String: JSONValue]) async throws -> Device {
        try await call("PUT", "/api/manager/devices/device/\(Self.escape(id))/settings", json: .object(values))
    }

    public func moveDevice(_ id: String, toGroup group: String?) async throws -> Device {
        try await call("PUT", "/api/stulp/devices/\(Self.escape(id))/group", json: ["groupId": .string(group ?? "")])
    }

    /// The complete order of one group's devices.
    public func orderDevices(group: String?, ids: [String]) async throws {
        try await send("PUT", "/api/stulp/devices/order", json: [
            "groupId": .string(group ?? ""), "deviceIds": .array(ids.map { .string($0) }),
        ])
    }

    public func media(_ device: String) async throws -> [MediaSource] {
        try await get("/api/stulp/devices/\(Self.escape(device))/media")
    }

    public func mediaPath(device: String, slot: String, kind: String) -> String {
        "/api/stulp/devices/\(Self.escape(device))/media/\(Self.escape(slot))/stream?kind=\(kind)"
    }

    public func still(device: String, slot: String) async throws -> Data {
        try await send("GET", mediaPath(device: device, slot: slot, kind: "image"))
    }

    // MARK: - Groups

    public func groups() async throws -> [DeviceGroup] {
        try await get("/api/stulp/device-groups")
    }

    public func createGroup(name: String, parentId: String?) async throws -> DeviceGroup {
        try await call("POST", "/api/stulp/device-groups", json: ["name": .string(name), "parentId": .string(parentId ?? "")])
    }

    public func updateGroup(_ id: String, _ fields: JSONValue) async throws -> DeviceGroup {
        try await call("PUT", "/api/stulp/device-groups/\(Self.escape(id))", json: fields)
    }

    public func deleteGroup(_ id: String) async throws {
        try await send("DELETE", "/api/stulp/device-groups/\(Self.escape(id))")
    }

    // MARK: - Scenes

    public func scenes() async throws -> [StulpScene] {
        try await get("/api/stulp/scenes")
    }

    public func saveScene(_ scene: StulpScene) async throws -> StulpScene {
        let body: JSONValue = [
            "name": .string(scene.name), "kind": .string(scene.kind),
            "states": .array(scene.states.map { ["deviceId": .string($0.deviceId), "capabilityId": .string($0.capabilityId), "value": $0.value] }),
        ]
        if scene.id.isEmpty { return try await call("POST", "/api/stulp/scenes", json: body) }
        return try await call("PUT", "/api/stulp/scenes/\(Self.escape(scene.id))", json: body)
    }

    public func deleteScene(_ id: String) async throws {
        try await send("DELETE", "/api/stulp/scenes/\(Self.escape(id))")
    }

    // MARK: - Flows

    public func flows() async throws -> [Flow] {
        let map: [String: Flow] = try await get("/api/manager/flow/flow")
        return Array(map.values)
    }

    public func saveFlow(_ flow: Flow) async throws -> Flow {
        if flow.id.isEmpty { return try await call("POST", "/api/manager/flow/flow", json: flow.body) }
        return try await call("PUT", "/api/manager/flow/flow/\(Self.escape(flow.id))", json: flow.body)
    }

    public func deleteFlow(_ id: String) async throws {
        try await send("DELETE", "/api/manager/flow/flow/\(Self.escape(id))")
    }

    public func setFlowEnabled(_ id: String, _ enabled: Bool) async throws {
        try await send("PUT", "/api/manager/flow/flow/\(Self.escape(id))/enabled", json: ["enabled": .bool(enabled)])
    }

    public func runFlow(_ id: String) async throws -> FlowRunResult {
        try await call("POST", "/api/stulp/flows/\(Self.escape(id))/run")
    }

    public func cards() async throws -> FlowCardCatalog {
        try await get("/api/stulp/flow/cards")
    }

    public func autocomplete(card: FlowCard, argument: String, query: String, args: [String: JSONValue]) async throws -> [AutocompleteItem] {
        let value: JSONValue = try await call("POST", "/api/stulp/flow/autocomplete", json: [
            "appId": .string(card.appId), "cardType": .string(card.type.rawValue), "cardId": .string(card.cardId),
            "argument": .string(argument), "query": .string(query), "args": .object(args),
        ])
        return (value.array ?? []).map { AutocompleteItem(raw: $0) }
    }

    // MARK: - Apps and drivers

    public func apps() async throws -> [StulpAppInfo] {
        let map: [String: StulpAppInfo] = try await get("/api/manager/apps/app")
        return Array(map.values)
    }

    public func setAppEnabled(_ id: String, _ enabled: Bool) async throws {
        try await send("PUT", "/api/manager/apps/app/\(Self.escape(id))/\(enabled ? "enable" : "disable")")
    }

    public func restartApp(_ id: String) async throws {
        try await send("POST", "/api/manager/apps/app/\(Self.escape(id))/restart")
    }

    /// Uninstalls an app, or refuses one that only announced itself.
    public func removeApp(_ id: String) async throws {
        try await send("DELETE", "/api/manager/apps/app/\(Self.escape(id))")
    }

    /// Accepting an app that announced itself: the one act a program cannot do for itself.
    public func installApp(_ id: String) async throws {
        try await send("POST", "/api/stulp/apps/\(Self.escape(id))/install")
    }

    public func appSetting(_ app: String, _ name: String) async throws -> JSONValue {
        do {
            return try await get("/api/manager/apps/app/\(Self.escape(app))/setting/\(Self.escape(name))")
        } catch StulpClientError.server(404, _) {
            return .null
        }
    }

    public func setAppSetting(_ app: String, _ name: String, _ value: JSONValue) async throws {
        try await send("PUT", "/api/manager/apps/app/\(Self.escape(app))/setting/\(Self.escape(name))", json: ["value": value])
    }

    public func unsetAppSetting(_ app: String, _ name: String) async throws {
        try await send("DELETE", "/api/manager/apps/app/\(Self.escape(app))/setting/\(Self.escape(name))")
    }

    /// An app's own API (`api` routes in its manifest). `path` may carry a query.
    public func appAPI(_ app: String, method: String, path: String, body: JSONValue?) async throws -> JSONValue {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let data = try await send(method.uppercased(), "/api/stulp/apps/\(Self.escape(app))/api/\(clean)",
                                  json: method.uppercased() == "GET" ? nil : (body ?? .null))
        return data.isEmpty ? .null : try Self.decode(JSONValue.self, from: data)
    }

    public func drivers() async throws -> [Driver] {
        let value: JSONValue = try await get("/api/manager/drivers/driver")
        // A map keyed by id (Stulp's shape), tolerated as an array too.
        let items = value.object.map { Array($0.values) } ?? value.array ?? []
        let data = try JSONEncoder().encode(JSONValue.array(items))
        return try Self.decode([Driver].self, from: data)
    }

    public func driver(_ id: String) async throws -> Driver {
        try await get("/api/manager/drivers/driver/\(id.split(separator: ":").map { Self.escape(String($0)) }.joined(separator: ":"))")
    }

    // MARK: - Pairing

    public func openPair(app: String, driver: String) async throws -> PairSession {
        try await call("POST", "/api/stulp/pair", json: ["appId": .string(app), "driverId": .string(driver)])
    }

    public func emit(pair: String, event: String, data: JSONValue = .null) async throws -> JSONValue {
        let raw = try await send("POST", "/api/stulp/pair/\(Self.escape(pair))/emit/\(Self.escape(event))", json: data)
        return raw.isEmpty ? .null : try Self.decode(JSONValue.self, from: raw)
    }

    public func closePair(_ id: String) async throws {
        try await send("DELETE", "/api/stulp/pair/\(Self.escape(id))")
    }

    /// Adds a candidate a driver offered (`list_devices`) and answers with the new device.
    public func addDevice(app: String, driver: String, candidate: JSONValue) async throws -> Device {
        try await call("POST", "/api/stulp/apps/\(Self.escape(app))/drivers/\(Self.escape(driver))/pair/devices", json: candidate)
    }

    // MARK: - Notifications

    public func notifications() async throws -> [StulpNotification] {
        try await get("/api/manager/notifications/notification")
    }

    public func deleteNotification(_ id: String) async throws {
        try await send("DELETE", "/api/manager/notifications/notification/\(Self.escape(id))")
    }

    // MARK: - Backup

    /// The whole document plus every installed app bundle, as a ZIP in a temporary file.
    public func downloadBackup() async throws -> URL {
        let (file, response) = try await session.download(for: try request("/api/stulp/backup"))
        try Self.check(response, data: Data())
        let date = Date().formatted(.iso8601.year().month().day())
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("stulp-backup-\(date).zip")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    public func restore(zip: Data) async throws {
        var request = try request("/api/stulp/restore", method: "POST")
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (data, response) = try await session.upload(for: request, from: zip)
        try Self.check(response, data: data)
    }

    // MARK: - This phone (com.stulp.notify)

    /// The phone devices of the notifications app, to point this device at.
    public func phones() async throws -> [Device] {
        try await devices()
            .filter(\.isPhone)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates this app's own phone device in Stulp. `installation` is fixed per installation, so
    /// registering again returns the same device.
    public func registerPhone(name: String, installation: String) async throws -> Device {
        try await addDevice(app: "com.stulp.notify", driver: "phone", candidate: [
            "name": .string(name), "data": ["kind": "app", "installation": .string(installation)],
        ])
    }

    /// This app's APNs token for this device; Stulp sends there.
    public func registerPush(deviceId: String, token: String, environment: String) async throws {
        _ = try await appAPI("com.stulp.notify", method: "POST", path: "register_push", body: [
            "deviceId": .string(deviceId), "token": .string(token), "environment": .string(environment),
        ])
    }

    /// Reports what the phone knows (charger, home) on its device.
    public func report(deviceId: String, values: [String: Bool]) async throws {
        _ = try await appAPI("com.stulp.notify", method: "POST", path: "report", body: [
            "deviceId": .string(deviceId), "values": .object(values.mapValues { .bool($0) }),
        ])
    }

    public func testNotification(deviceId: String) async throws {
        _ = try await appAPI("com.stulp.notify", method: "POST", path: "test", body: ["deviceId": .string(deviceId)])
    }
}

struct ServerError: Decodable, Sendable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }

    var message: String? { errorDescription ?? error }
}

public enum StulpClientError: LocalizedError, Equatable {
    case unauthorized
    case invalidResponse
    case missingOnboardingPayload
    case incompatibleMatterApp
    case noDevicesFound
    case commissioningTimedOut
    case commissioningFailed(String)
    case server(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Stulp wees de toegangssleutel af. Controleer het adres en de sleutel."
        case .invalidResponse:
            "Stulp gaf een antwoord dat deze app niet begrijpt."
        case .missingOnboardingPayload:
            "iOS gaf geen Matter-koppelcode terug."
        case .incompatibleMatterApp:
            "De draaiende Matter-app ondersteunt deze iOS-koppeling nog niet."
        case .noDevicesFound:
            "Matter is gekoppeld, maar er kwam geen apparaat terug om toe te voegen."
        case .commissioningTimedOut:
            "Stulp kreeg niet binnen 3 minuten en 15 seconden antwoord van het Matter-apparaat."
        case .commissioningFailed(let message):
            message
        case .server(let status, let message):
            message ?? "Stulp gaf HTTP \(status)."
        }
    }
}

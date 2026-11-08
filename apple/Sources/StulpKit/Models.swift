import Foundation

// The shapes Stulp's API answers with. Decoding is lenient where the server is: optional fields
// stay optional, numbers that may come as strings are read either way, and anything free-form
// stays `JSONValue`.

// MARK: - Devices

public struct Device: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var appId: String
    public var groupId: String?
    public var sortOrder: Double?
    public var name: String
    public var deviceClass: String
    public var capabilities: [String]
    public var capabilitiesObj: [String: Capability]
    public var available: Bool
    public var unavailableMessage: String?
    public var warningMessage: String?
    public var hardwareName: String?
    public var manufacturer: String?
    public var driverId: String?
    public var settings: [String: JSONValue]
    public var data: JSONValue?
    public var hidden: Bool
    public var sceneId: String?

    enum CodingKeys: String, CodingKey {
        case id, appId, groupId, sortOrder, name, capabilities, capabilitiesObj, available, unavailableMessage
        case warningMessage, hardwareName, manufacturer, driverId, settings, data, hidden, sceneId
        case deviceClass = "class"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        appId = (try? c.decodeIfPresent(String.self, forKey: .appId)) ?? ""
        let group = (try? c.decodeIfPresent(String.self, forKey: .groupId)) ?? nil
        groupId = group?.isEmpty == true ? nil : group
        sortOrder = try? c.decodeIfPresent(Double.self, forKey: .sortOrder)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        deviceClass = (try? c.decodeIfPresent(String.self, forKey: .deviceClass)) ?? "other"
        capabilitiesObj = (try? c.decodeIfPresent([String: Capability].self, forKey: .capabilitiesObj)) ?? [:]
        let listed = (try? c.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        // The order the app declared is the order a person reads; anything only in the object
        // follows alphabetically.
        capabilities = listed + capabilitiesObj.keys.filter { !listed.contains($0) }.sorted()
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? true
        unavailableMessage = try? c.decodeIfPresent(String.self, forKey: .unavailableMessage)
        warningMessage = try? c.decodeIfPresent(String.self, forKey: .warningMessage)
        hardwareName = try? c.decodeIfPresent(String.self, forKey: .hardwareName)
        manufacturer = try? c.decodeIfPresent(String.self, forKey: .manufacturer)
        driverId = try? c.decodeIfPresent(String.self, forKey: .driverId)
        settings = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .settings)) ?? [:]
        data = try? c.decodeIfPresent(JSONValue.self, forKey: .data)
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        sceneId = (try? c.decodeIfPresent(String.self, forKey: .sceneId)) ?? data?["sceneId"]?.string
    }

    public init(
        id: String, appId: String = "", groupId: String? = nil, sortOrder: Double? = nil, name: String,
        deviceClass: String = "other", capabilities: [Capability] = [], available: Bool = true
    ) {
        self.id = id
        self.appId = appId
        self.groupId = groupId
        self.sortOrder = sortOrder
        self.name = name
        self.deviceClass = deviceClass
        self.capabilities = capabilities.map(\.id)
        self.capabilitiesObj = Dictionary(capabilities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.available = available
        self.settings = [:]
        self.hidden = false
    }

    /// Capabilities in reading order.
    public var orderedCapabilities: [Capability] {
        capabilities.compactMap { capabilitiesObj[$0] }
    }

    public subscript(capability id: String) -> Capability? { capabilitiesObj[id] }

    public var isScene: Bool { appId == "com.stulp.scene" || deviceClass == "scene" }
    public var isPhone: Bool { appId == "com.stulp.notify" }

    /// The driver's own id (`stulp:app:<app>:<driver>` → `<driver>`).
    public var driverName: String? {
        guard let driverId, let last = driverId.split(separator: ":").last else { return nil }
        return String(last)
    }
}

public struct Capability: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var title: String
    public var type: String
    public var getable: Bool
    public var setable: Bool
    public var value: JSONValue?
    public var units: String?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var values: [EnumValue]
    public var desc: String?

    enum CodingKeys: String, CodingKey { case id, title, type, getable, setable, value, units, min, max, step, values, desc }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text ?? id
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "string"
        getable = (try? c.decodeIfPresent(Bool.self, forKey: .getable)) ?? true
        setable = (try? c.decodeIfPresent(Bool.self, forKey: .setable)) ?? false
        let raw = try? c.decodeIfPresent(JSONValue.self, forKey: .value)
        value = raw == .null ? nil : raw
        units = (try? c.decodeIfPresent(LocalizedText.self, forKey: .units))?.text
        min = try? c.decodeIfPresent(Double.self, forKey: .min)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
        step = try? c.decodeIfPresent(Double.self, forKey: .step)
        values = (try? c.decodeIfPresent([EnumValue].self, forKey: .values)) ?? []
        desc = (try? c.decodeIfPresent(LocalizedText.self, forKey: .desc))?.text
    }

    public init(
        id: String, title: String, type: String, setable: Bool = false, value: JSONValue? = nil,
        units: String? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil, values: [EnumValue] = []
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.getable = true
        self.setable = setable
        self.value = value
        self.units = units
        self.min = min
        self.max = max
        self.step = step
        self.values = values
    }

    /// `onoff.2` → `onoff`: a numbered copy shares everything with its base.
    public var base: String { id.split(separator: ".").first.map(String.init) ?? id }
    public var isBoolean: Bool { type == "boolean" }
    public var isNumber: Bool { type == "number" }
    public var isEnum: Bool { type == "enum" || !values.isEmpty }
    public var bool: Bool? { value?.bool }
    public var number: Double? { value?.number }
}

public struct EnumValue: Sendable, Hashable, Decodable, Identifiable {
    public let id: String
    public let title: String

    enum CodingKeys: String, CodingKey { case id, title, label }

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Double.self, forKey: .id) {
            id = JSONValue.number(n).text
        } else if let b = try? c.decode(Bool.self, forKey: .id) {
            id = b ? "true" : "false"
        } else {
            id = ""
        }
        let title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text
            ?? (try? c.decodeIfPresent(LocalizedText.self, forKey: .label))?.text
        self.title = (title?.isEmpty == false ? title : nil) ?? id
    }
}

public struct DeviceGroup: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var sortOrder: Double?

    public init(id: String, name: String, parentId: String? = nil, sortOrder: Double? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.sortOrder = sortOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        let parent = (try? c.decodeIfPresent(String.self, forKey: .parentId)) ?? nil
        parentId = parent?.isEmpty == true ? nil : parent
        sortOrder = try? c.decodeIfPresent(Double.self, forKey: .sortOrder)
    }
}

/// A camera still or stream a plugin registered for a device.
public struct MediaSource: Sendable, Hashable, Decodable, Identifiable {
    public var deviceId: String
    public var slot: String
    public var kind: String
    public var title: String?

    public var id: String { "\(kind):\(slot)" }
    public var isVideo: Bool { kind == "video" }
}

/// The snapshot that arrives with an opened event stream.
public struct Bootstrap: Sendable, Decodable {
    public var ok: Bool
    public var stulpVersion: String
    public var deviceGroups: [DeviceGroup]
}

public struct StulpHealth: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let stulpVersion: String
}

// MARK: - Scenes

public struct StulpScene: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// `switch` (on applies and remembers, off restores) or `button` (apply only).
    public var kind: String
    public var states: [SceneState]
    public var active: Bool

    public init(id: String = "", name: String, kind: String = "switch", states: [SceneState] = [], active: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.states = states
        self.active = active
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "switch"
        states = (try? c.decodeIfPresent([SceneState].self, forKey: .states)) ?? []
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
    }

    public var isButton: Bool { kind == "button" }
}

public struct SceneState: Sendable, Hashable, Codable {
    public var deviceId: String
    public var capabilityId: String
    public var value: JSONValue

    public init(deviceId: String, capabilityId: String, value: JSONValue) {
        self.deviceId = deviceId
        self.capabilityId = capabilityId
        self.value = value
    }
}

// MARK: - Apps and drivers

public struct StulpAppInfo: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var name: String
    public var version: String?
    public var enabled: Bool
    public var offered: Bool
    public var state: String?
    public var crashed: Bool
    public var crashedMessage: String?
    public var retryAt: String?
    /// Whether the app has its own settings page.
    public var hasSettings: Bool

    enum CodingKeys: String, CodingKey { case id, name, version, enabled, offered, state, crashed, crashedMessage, retryAt, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(LocalizedText.self, forKey: .name))?.text ?? id
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        offered = (try? c.decodeIfPresent(Bool.self, forKey: .offered)) ?? false
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        crashed = (try? c.decodeIfPresent(Bool.self, forKey: .crashed)) ?? false
        crashedMessage = try? c.decodeIfPresent(String.self, forKey: .crashedMessage)
        retryAt = try? c.decodeIfPresent(String.self, forKey: .retryAt)
        switch try? c.decodeIfPresent(JSONValue.self, forKey: .settings) {
        case .bool(let b): hasSettings = b
        case .object(let o): hasSettings = !o.isEmpty
        case .array(let a): hasSettings = !a.isEmpty
        case .string(let s): hasSettings = !s.isEmpty
        default: hasSettings = false
        }
    }

    public var isRunning: Bool { state == "running" }
}

public struct Driver: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var ownerUri: String
    public var ownerName: String?
    public var name: String
    public var deviceClass: String
    public var ready: Bool
    public var pair: Bool
    public var pairViews: [String]
    public var customPairViews: [String]
    public var settings: [SettingSpec]

    enum CodingKeys: String, CodingKey {
        case id, ownerUri, ownerName, name, ready, pair, pairViews, customPairViews, settings
        case deviceClass = "class"
    }

    private struct View: Decodable { let id: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerUri = (try? c.decodeIfPresent(String.self, forKey: .ownerUri)) ?? ""
        ownerName = (try? c.decodeIfPresent(LocalizedText.self, forKey: .ownerName))?.text
        name = (try? c.decodeIfPresent(LocalizedText.self, forKey: .name))?.text ?? id
        deviceClass = (try? c.decodeIfPresent(String.self, forKey: .deviceClass)) ?? "other"
        ready = (try? c.decodeIfPresent(Bool.self, forKey: .ready)) ?? true
        switch try? c.decodeIfPresent(JSONValue.self, forKey: .pair) {
        case .bool(let b): pair = b
        case .array(let a): pair = !a.isEmpty
        case .object: pair = true
        default: pair = false
        }
        pairViews = ((try? c.decodeIfPresent([View].self, forKey: .pairViews)) ?? []).compactMap(\.id)
        customPairViews = (try? c.decodeIfPresent([String].self, forKey: .customPairViews)) ?? []
        settings = SettingSpec.flatten((try? c.decodeIfPresent([SettingSpec].self, forKey: .settings)) ?? [])
    }

    /// `stulp:app:<id>` → `<id>`.
    public var appId: String {
        ownerUri.hasPrefix("stulp:app:") ? String(ownerUri.dropFirst("stulp:app:".count)) : ownerUri
    }

    /// The driver's own id, the last part of `stulp:app:<app>:<driver>`.
    public var driverName: String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    /// The app draws its first pairing step itself (a page in a web view).
    public var startsWithCustomView: Bool {
        guard let first = pairViews.first else { return false }
        return customPairViews.contains(first)
    }
}

/// One field of a driver's device settings. A `group` only gathers children; it is flattened.
public struct SettingSpec: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var type: String
    public var label: String
    public var hint: String?
    public var placeholder: String?
    public var value: JSONValue?
    public var values: [EnumValue]
    public var min: Double?
    public var max: Double?
    public var children: [SettingSpec]

    enum CodingKeys: String, CodingKey { case id, type, label, hint, placeholder, value, values, attr, children }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "text"
        label = (try? c.decodeIfPresent(LocalizedText.self, forKey: .label))?.text ?? id
        hint = (try? c.decodeIfPresent(LocalizedText.self, forKey: .hint))?.text
        placeholder = (try? c.decodeIfPresent(LocalizedText.self, forKey: .placeholder))?.text
        value = try? c.decodeIfPresent(JSONValue.self, forKey: .value)
        values = (try? c.decodeIfPresent([EnumValue].self, forKey: .values)) ?? []
        let attr = try? c.decodeIfPresent(JSONValue.self, forKey: .attr)
        min = attr?["min"]?.number
        max = attr?["max"]?.number
        children = (try? c.decodeIfPresent([SettingSpec].self, forKey: .children)) ?? []
    }

    static func flatten(_ specs: [SettingSpec]) -> [SettingSpec] {
        specs.flatMap { $0.children.isEmpty ? [$0] : flatten($0.children) }.filter { !$0.id.isEmpty }
    }
}

public struct PairSession: Decodable, Sendable, Hashable {
    public let id: String
    public let handlers: [String]
}

// MARK: - Notifications and system

public struct StulpNotification: Identifiable, Sendable, Hashable, Decodable {
    public var id: String
    public var appId: String?
    public var excerpt: String
    public var createdAt: String?

    public var date: Date? { createdAt.flatMap(StulpDate.parse) }
}

public struct SystemSettings: Sendable, Hashable, Decodable {
    public var statistics: Bool
    public var statisticsBytes: Int?
    public var units: [String: String]
    public var unitsOffer: [UnitQuantity]

    enum CodingKeys: String, CodingKey { case statistics, statisticsBytes, units, unitsOffer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statistics = (try? c.decodeIfPresent(Bool.self, forKey: .statistics)) ?? false
        statisticsBytes = try? c.decodeIfPresent(Int.self, forKey: .statisticsBytes)
        units = (try? c.decodeIfPresent([String: String].self, forKey: .units)) ?? [:]
        unitsOffer = (try? c.decodeIfPresent([UnitQuantity].self, forKey: .unitsOffer)) ?? []
    }
}

public struct UnitQuantity: Sendable, Hashable, Decodable, Identifiable {
    public var name: String
    public var title: String
    public var hint: String?
    public var `default`: String?
    public var options: [UnitOption]

    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, title, hint, `default`, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text ?? name
        hint = (try? c.decodeIfPresent(LocalizedText.self, forKey: .hint))?.text
        `default` = try? c.decodeIfPresent(String.self, forKey: .default)
        options = (try? c.decodeIfPresent([UnitOption].self, forKey: .options)) ?? []
    }
}

public struct UnitOption: Sendable, Hashable, Decodable {
    public var unit: String
    public var title: String

    enum CodingKeys: String, CodingKey { case unit, title }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text ?? unit
    }
}

/// Stulp writes RFC 3339 with fractional seconds; both forms are read.
public enum StulpDate {
    public static func parse(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return d
        }
        return try? Date(text, strategy: .iso8601)
    }
}

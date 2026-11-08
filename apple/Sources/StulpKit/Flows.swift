import Foundation

/// A Flow as Stulp stores it: a graph of cards (`nodes`) and the lines between them (`edges`).
/// Stulp runs it breadth first from the trigger that fired, one card at a time and in edge order;
/// a false condition or a failed action stops only its own branch. The app edits it as rules
/// (`FlowRules`), but what travels is always this graph.
public struct Flow: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var nodes: [FlowNode]
    public var edges: [FlowEdge]
    public var lastRunAt: String?
    public var lastError: String?
    public var revision: JSONValue?

    public init(id: String = "", name: String, enabled: Bool = true, nodes: [FlowNode] = [], edges: [FlowEdge] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.nodes = nodes
        self.edges = edges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        nodes = (try? c.decodeIfPresent([FlowNode].self, forKey: .nodes)) ?? []
        edges = (try? c.decodeIfPresent([FlowEdge].self, forKey: .edges)) ?? []
        lastRunAt = try? c.decodeIfPresent(String.self, forKey: .lastRunAt)
        let error = try? c.decodeIfPresent(String.self, forKey: .lastError)
        lastError = error?.isEmpty == true ? nil : error
        revision = try? c.decodeIfPresent(JSONValue.self, forKey: .revision)
    }

    /// What goes to `POST`/`PUT`: only what the server copies.
    public var body: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "enabled": .bool(enabled),
            "nodes": .array(nodes.map(\.json)),
            "edges": .array(edges.map(\.json)),
        ]
        if let revision { object["revision"] = revision }
        return .object(object)
    }

    public var lastRun: Date? { lastRunAt.flatMap(StulpDate.parse) }

    public func count(_ type: FlowCardType) -> Int {
        nodes.filter { $0.step.cardType == type }.count
    }
}

public struct FlowNode: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var x: Double
    public var y: Double
    public var step: FlowStep

    public init(id: String = UUID().uuidString.lowercased(), x: Double = 0, y: Double = 0, step: FlowStep) {
        self.id = id
        self.x = x
        self.y = y
        self.step = step
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0
        y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0
        step = try c.decode(FlowStep.self, forKey: .step)
    }

    var json: JSONValue {
        ["id": .string(id), "x": .number(x), "y": .number(y), "step": step.json]
    }
}

public struct FlowStep: Sendable, Hashable, Codable {
    public var appId: String
    public var cardId: String
    public var cardType: FlowCardType
    public var args: [String: JSONValue]
    public var inverted: Bool

    public init(appId: String, cardId: String, cardType: FlowCardType, args: [String: JSONValue] = [:], inverted: Bool = false) {
        self.appId = appId
        self.cardId = cardId
        self.cardType = cardType
        self.args = args
        self.inverted = inverted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = (try? c.decodeIfPresent(String.self, forKey: .appId)) ?? ""
        cardId = (try? c.decodeIfPresent(String.self, forKey: .cardId)) ?? ""
        cardType = (try? c.decodeIfPresent(FlowCardType.self, forKey: .cardType)) ?? .action
        args = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .args)) ?? [:]
        inverted = (try? c.decodeIfPresent(Bool.self, forKey: .inverted)) ?? false
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "appId": .string(appId), "cardId": .string(cardId),
            "cardType": .string(cardType.rawValue), "args": .object(args),
        ]
        if inverted { object["inverted"] = .bool(true) }
        return .object(object)
    }

    /// The device a card is about (`{"$device": id}`), if any.
    public var deviceId: String? {
        for value in args.values {
            if let id = value["$device"]?.string { return id }
        }
        return nil
    }
}

public struct FlowEdge: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var from: String
    public var to: String

    public init(id: String = UUID().uuidString.lowercased(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }

    var json: JSONValue { ["id": .string(id), "from": .string(from), "to": .string(to)] }
}

public enum FlowCardType: String, Sendable, Hashable, Codable, CaseIterable {
    case trigger, condition, action

    /// The words Stulp has always used: ALS, EN, DAN.
    public var title: String {
        switch self {
        case .trigger: "Als"
        case .condition: "En"
        case .action: "Dan"
        }
    }
}

/// The result of `POST /api/stulp/flows/:id/run`.
public struct FlowRunResult: Sendable, Decodable {
    public var success: Bool
    public var stopped: Bool
    public var error: String?

    enum CodingKeys: String, CodingKey { case success, stopped, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? c.decodeIfPresent(Bool.self, forKey: .success)) ?? true
        stopped = (try? c.decodeIfPresent(Bool.self, forKey: .stopped)) ?? false
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Cards

/// `GET /api/stulp/flow/cards`.
public struct FlowCardCatalog: Sendable, Decodable {
    public var triggers: [FlowCard]
    public var conditions: [FlowCard]
    public var actions: [FlowCard]

    public init(triggers: [FlowCard] = [], conditions: [FlowCard] = [], actions: [FlowCard] = []) {
        self.triggers = triggers
        self.conditions = conditions
        self.actions = actions
    }

    public func cards(_ type: FlowCardType) -> [FlowCard] {
        switch type {
        case .trigger: triggers
        case .condition: conditions
        case .action: actions
        }
    }

    public func card(for step: FlowStep) -> FlowCard? {
        cards(step.cardType).first { $0.appId == step.appId && $0.id == step.cardId }
            ?? (triggers + conditions + actions).first { $0.appId == step.appId && $0.id == step.cardId }
    }
}

public struct FlowCard: Identifiable, Sendable, Hashable, Decodable {
    public var appId: String
    public var appName: String
    public var cardId: String
    public var type: FlowCardType
    public var title: String
    public var titleFormatted: String?
    public var hint: String?
    public var args: [CardArgument]
    public var tokens: [FlowToken]
    public var available: Bool
    /// `device`: the card belongs to the devices in `deviceIds`.
    public var scope: String?
    public var deviceArgument: String?
    public var deviceIds: [String]
    public var capability: String?

    public var id: String { cardId }
    public var key: String { "\(appId)/\(type.rawValue)/\(cardId)" }

    enum CodingKeys: String, CodingKey {
        case appId, appName, id, type, title, titleFormatted, hint, args, tokens, available, scope, deviceArgument, deviceIds, capability
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = (try? c.decodeIfPresent(String.self, forKey: .appId)) ?? ""
        appName = (try? c.decodeIfPresent(LocalizedText.self, forKey: .appName))?.text ?? appId
        cardId = try c.decode(String.self, forKey: .id)
        type = (try? c.decodeIfPresent(FlowCardType.self, forKey: .type)) ?? .action
        title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text ?? cardId
        titleFormatted = (try? c.decodeIfPresent(LocalizedText.self, forKey: .titleFormatted))?.text
        hint = (try? c.decodeIfPresent(LocalizedText.self, forKey: .hint))?.text
        args = (try? c.decodeIfPresent([CardArgument].self, forKey: .args)) ?? []
        tokens = (try? c.decodeIfPresent([FlowToken].self, forKey: .tokens)) ?? []
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? true
        scope = try? c.decodeIfPresent(String.self, forKey: .scope)
        deviceArgument = try? c.decodeIfPresent(String.self, forKey: .deviceArgument)
        deviceIds = (try? c.decodeIfPresent([String].self, forKey: .deviceIds)) ?? []
        capability = try? c.decodeIfPresent(String.self, forKey: .capability)
    }

    public var isDeviceCard: Bool { scope == "device" || deviceArgument != nil || args.contains { $0.type == "device" } }

    /// The generic capability cards: shown last for a device, after its own cards.
    public var isGeneric: Bool {
        ["device_capability_changed", "device_capability_equals", "set_device_capability", "matter_event"].contains(cardId)
    }

    /// The sentence a step reads as: `titleFormatted` with the chosen values filled in. An argument
    /// still missing stays `[[name]]`, so it is clear what is left to choose.
    public func sentence(for step: FlowStep, label: (CardArgument, JSONValue) -> String?) -> String {
        guard var text = titleFormatted, !text.isEmpty else { return title }
        // `!{{plain|inverted}}`: an inverted condition reads the second half.
        while let open = text.range(of: "!{{"),
              let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) {
            let inner = text[open.upperBound..<close.lowerBound]
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let chosen = step.inverted ? (parts.count > 1 ? parts[1] : "") : parts[0]
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: chosen)
        }
        for argument in args {
            let marker = "[[\(argument.name)]]"
            guard text.contains(marker), let value = step.args[argument.name], !value.isNull, value != .string("") else { continue }
            text = text.replacingOccurrences(of: marker, with: label(argument, value) ?? value.text)
        }
        return text
    }
}

public struct CardArgument: Sendable, Hashable, Decodable, Identifiable {
    public var name: String
    public var type: String
    public var title: String
    public var optional: Bool
    public var placeholder: String?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var units: String?
    public var values: [EnumValue]
    public var filter: String?
    public var value: JSONValue?

    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, type, title, optional, placeholder, min, max, step, units, values, filter, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "text"
        title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text ?? name
        optional = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? false
        placeholder = (try? c.decodeIfPresent(LocalizedText.self, forKey: .placeholder))?.text
        min = try? c.decodeIfPresent(Double.self, forKey: .min)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
        step = try? c.decodeIfPresent(Double.self, forKey: .step)
        units = (try? c.decodeIfPresent(LocalizedText.self, forKey: .units))?.text
        values = (try? c.decodeIfPresent([EnumValue].self, forKey: .values)) ?? []
        filter = try? c.decodeIfPresent(String.self, forKey: .filter)
        value = try? c.decodeIfPresent(JSONValue.self, forKey: .value)
    }
}

public struct FlowToken: Sendable, Hashable, Decodable {
    public var name: String
    public var type: String?
    public var title: String

    enum CodingKeys: String, CodingKey { case name, type, title }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        title = (try? c.decodeIfPresent(LocalizedText.self, forKey: .title))?.text ?? name
    }
}

/// One suggestion from `POST /api/stulp/flow/autocomplete`. The whole object is what a step
/// stores, so it is kept as JSON next to the fields shown.
public struct AutocompleteItem: Sendable, Hashable, Identifiable {
    public var raw: JSONValue
    public var id: String { raw["id"]?.text ?? name }
    public var name: String { LocalizedText.resolve(raw["name"]) }
    public var description: String? {
        let text = LocalizedText.resolve(raw["description"])
        return text.isEmpty ? nil : text
    }
}

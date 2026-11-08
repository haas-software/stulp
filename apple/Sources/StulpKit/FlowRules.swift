import Foundation

/// One rule of a Flow, the way Apple's Home app shows an automation: *Als* one of these happens,
/// *En* all of these hold, *Dan* do these in order.
///
/// In the graph that is: every trigger connected to the first condition, the conditions in one
/// chain, and the last condition (or every trigger, without conditions) connected to every
/// action, in order. Stulp runs a node's outgoing lines in their order, one card at a time, so the
/// actions run in the listed order and one failing does not stop the next. A chain of actions
/// (a1 → a2 → a3, as the old canvas made it) is read too and written back as a chain, so a Flow
/// keeps behaving exactly as it did.
public struct FlowRule: Identifiable, Sendable, Hashable {
    public var id: String
    public var triggers: [FlowNode]
    public var conditions: [FlowNode]
    public var actions: [FlowNode]
    /// The actions were a chain: a failed action stops the ones after it.
    public var actionsInSequence: Bool

    public init(
        id: String = UUID().uuidString, triggers: [FlowNode] = [], conditions: [FlowNode] = [],
        actions: [FlowNode] = [], actionsInSequence: Bool = false
    ) {
        self.id = id
        self.triggers = triggers
        self.conditions = conditions
        self.actions = actions
        self.actionsInSequence = actionsInSequence
    }

    public subscript(type: FlowCardType) -> [FlowNode] {
        get {
            switch type {
            case .trigger: triggers
            case .condition: conditions
            case .action: actions
            }
        }
        set {
            switch type {
            case .trigger: triggers = newValue
            case .condition: conditions = newValue
            case .action: actions = newValue
            }
        }
    }

    public var isEmpty: Bool { triggers.isEmpty && conditions.isEmpty && actions.isEmpty }
    /// Stulp only runs a rule that starts somewhere and does something.
    public var isComplete: Bool { !triggers.isEmpty && !actions.isEmpty }

    /// The lines this rule stands for, in the order Stulp should follow them.
    func edges() -> [(String, String)] {
        var out: [(String, String)] = []
        var previous = triggers.map(\.id)
        for condition in conditions {
            for from in previous { out.append((from, condition.id)) }
            previous = [condition.id]
        }
        if actionsInSequence {
            for action in actions {
                for from in previous { out.append((from, action.id)) }
                previous = [action.id]
            }
        } else {
            for action in actions {
                for from in previous { out.append((from, action.id)) }
            }
        }
        return out
    }
}

public enum FlowRules {
    /// The rules a Flow consists of, one per connected part of the graph, in the order their first
    /// card appears. `nil` when some part does not fit the rule shape (a branch, conditions side by
    /// side); the app then shows the Flow read-only instead of rewriting what it cannot represent.
    public static func rules(from flow: Flow) -> [FlowRule]? {
        let index = Dictionary(flow.nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard index.count == flow.nodes.count else { return nil }
        // An edge to a card that is not there: not something to quietly drop.
        guard flow.edges.allSatisfy({ index[$0.from] != nil && index[$0.to] != nil }) else { return nil }

        var rules: [FlowRule] = []
        for component in components(flow) {
            guard let rule = rule(component, flow: flow, index: index) else { return nil }
            rules.append(rule)
        }
        return rules
    }

    /// The graph for a list of rules. Positions are laid out in columns (Als, En, Dan) so the stored
    /// coordinates stay readable; an edge that already existed keeps its id.
    public static func graph(from rules: [FlowRule], reusing old: [FlowEdge] = []) -> (nodes: [FlowNode], edges: [FlowEdge]) {
        var nodes: [FlowNode] = []
        var edges: [FlowEdge] = []
        var existing: [String: String] = [:]
        for edge in old { existing["\(edge.from)>\(edge.to)"] = edge.id }
        var top = 40.0
        for rule in rules where !rule.isEmpty {
            var rows = 0
            for (column, list) in [rule.triggers, rule.conditions, rule.actions].enumerated() {
                for (row, var node) in list.enumerated() {
                    node.x = 40 + Double(column) * 340
                    node.y = top + Double(row) * 160
                    nodes.append(node)
                }
                rows = max(rows, list.count)
            }
            for (from, to) in rule.edges() {
                edges.append(FlowEdge(id: existing["\(from)>\(to)"] ?? UUID().uuidString.lowercased(), from: from, to: to))
            }
            top += Double(max(rows, 1)) * 160 + 80
        }
        return (nodes, edges)
    }

    // MARK: - Reading

    private static func components(_ flow: Flow) -> [[FlowNode]] {
        var neighbours: [String: [String]] = [:]
        for edge in flow.edges {
            neighbours[edge.from, default: []].append(edge.to)
            neighbours[edge.to, default: []].append(edge.from)
        }
        var seen: Set<String> = []
        var out: [[FlowNode]] = []
        let byId = Dictionary(flow.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for node in flow.nodes where !seen.contains(node.id) {
            var stack = [node.id]
            var ids: Set<String> = []
            while let id = stack.popLast() {
                guard seen.insert(id).inserted else { continue }
                ids.insert(id)
                stack.append(contentsOf: neighbours[id] ?? [])
            }
            // In the Flow's own order, which is also the order a person put them there.
            out.append(flow.nodes.filter { ids.contains($0.id) && byId[$0.id] != nil })
        }
        return out
    }

    private static func rule(_ nodes: [FlowNode], flow: Flow, index: [String: Int]) -> FlowRule? {
        let ids = Set(nodes.map(\.id))
        let edges = flow.edges.filter { ids.contains($0.from) }
        let actual = Set(edges.map { "\($0.from)>\($0.to)" })
        guard actual.count == edges.count else { return nil }

        let triggers = nodes.filter { $0.step.cardType == .trigger }
        let conditions = nodes.filter { $0.step.cardType == .condition }
        let actions = nodes.filter { $0.step.cardType == .action }

        guard let orderedConditions = chain(conditions, edges: edges) else { return nil }

        // Fan-out: the order of the first line into each action is the order Stulp runs them.
        let firstLine = Dictionary(
            edges.enumerated().reversed().map { ($1.to, $0) }, uniquingKeysWith: { _, last in last })
        let fanned = actions.sorted {
            (firstLine[$0.id] ?? Int.max, index[$0.id] ?? 0) < (firstLine[$1.id] ?? Int.max, index[$1.id] ?? 0)
        }
        var candidate = FlowRule(
            id: nodes.first?.id ?? UUID().uuidString, triggers: triggers, conditions: orderedConditions,
            actions: fanned, actionsInSequence: false)
        if matches(candidate, actual) { return candidate }

        guard actions.count > 1, let chained = chain(actions, edges: edges) else { return nil }
        candidate.actions = chained
        candidate.actionsInSequence = true
        return matches(candidate, actual) ? candidate : nil
    }

    private static func matches(_ rule: FlowRule, _ actual: Set<String>) -> Bool {
        let expected = rule.edges().map { "\($0.0)>\($0.1)" }
        return expected.count == actual.count && Set(expected) == actual
    }

    /// The cards of one kind as a single chain (each links to the next), or `nil`.
    private static func chain(_ cards: [FlowNode], edges: [FlowEdge]) -> [FlowNode]? {
        guard cards.count > 1 else { return cards }
        let ids = Set(cards.map(\.id))
        let inner = edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        guard inner.count == cards.count - 1 else { return nil }
        var next: [String: String] = [:]
        var hasIncoming: Set<String> = []
        for edge in inner {
            guard next[edge.from] == nil, !hasIncoming.contains(edge.to) else { return nil }
            next[edge.from] = edge.to
            hasIncoming.insert(edge.to)
        }
        let heads = cards.filter { !hasIncoming.contains($0.id) }
        guard heads.count == 1, var current = heads.first else { return nil }
        let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = [current]
        while let id = next[current.id], let node = byId[id] {
            out.append(node)
            current = node
        }
        return out.count == cards.count ? out : nil
    }
}

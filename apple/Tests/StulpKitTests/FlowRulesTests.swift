import Foundation
import StulpKit
import Testing

@Suite("FlowRules: de graaf als Als-En-Dan-regels")
struct FlowRulesTests {
    private func node(_ id: String, _ type: FlowCardType, card: String = "card") -> FlowNode {
        FlowNode(id: id, step: FlowStep(appId: "stulp", cardId: card, cardType: type))
    }

    private func flow(_ nodes: [FlowNode], _ edges: [(String, String)]) -> Flow {
        Flow(id: "f", name: "Test", nodes: nodes, edges: edges.enumerated().map { FlowEdge(id: "e\($0)", from: $1.0, to: $1.1) })
    }

    private func pairs(_ edges: [FlowEdge]) -> [String] { edges.map { "\($0.from)>\($0.to)" } }

    @Test("De echte flow 'Keuken: Zet lamp aan' zijn twee losse regels")
    func kitchen() throws {
        let json = """
        {"id":"1152843e","name":"Keuken: Zet lamp aan","enabled":true,
         "nodes":[
          {"id":"t1","x":59,"y":67,"step":{"appId":"stulp","cardId":"capability.alarm_motion.on","cardType":"trigger","args":{"device":{"$device":"m"},"value":true}}},
          {"id":"t2","x":58,"y":226,"step":{"appId":"stulp","cardId":"capability.alarm_motion.off","cardType":"trigger","args":{"device":{"$device":"m"},"value":true}}},
          {"id":"a1","x":573,"y":63,"step":{"appId":"stulp","cardId":"capability.onoff.set","cardType":"action","args":{"device":{"$device":"l"},"value":true}}},
          {"id":"a2","x":560,"y":228,"step":{"appId":"stulp","cardId":"capability.onoff.set","cardType":"action","args":{"device":{"$device":"l"},"value":false}}}],
         "edges":[{"id":"e1","from":"t1","to":"a1"},{"id":"e2","from":"t2","to":"a2"}]}
        """
        let flow = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        let rules = try #require(FlowRules.rules(from: flow))
        #expect(rules.count == 2)
        #expect(rules[0].triggers.map(\.id) == ["t1"])
        #expect(rules[0].actions.map(\.id) == ["a1"])
        #expect(rules[1].triggers.map(\.id) == ["t2"])
        #expect(rules[1].actions.map(\.id) == ["a2"])
        #expect(rules.allSatisfy { $0.conditions.isEmpty && $0.isComplete })

        // Written back, the same lines with the same ids.
        let graph = FlowRules.graph(from: rules, reusing: flow.edges)
        #expect(Set(pairs(graph.edges)) == ["t1>a1", "t2>a2"])
        #expect(Set(graph.edges.map(\.id)) == ["e1", "e2"])
        #expect(graph.nodes.count == 4)
    }

    @Test("Twee triggers, een keten voorwaarden en uitwaaierende acties in lijnvolgorde")
    func fanOut() throws {
        let nodes = [node("t1", .trigger), node("t2", .trigger), node("c1", .condition), node("c2", .condition),
                     node("a2", .action), node("a1", .action)]
        // a1's line comes first: that is the order Stulp runs them in, whatever the node order.
        let edges = [("t1", "c1"), ("t2", "c1"), ("c1", "c2"), ("c2", "a1"), ("c2", "a2")]
        let rules = try #require(FlowRules.rules(from: flow(nodes, edges)))
        #expect(rules.count == 1)
        let rule = rules[0]
        #expect(rule.triggers.map(\.id) == ["t1", "t2"])
        #expect(rule.conditions.map(\.id) == ["c1", "c2"])
        #expect(rule.actions.map(\.id) == ["a1", "a2"])
        #expect(!rule.actionsInSequence)

        let graph = FlowRules.graph(from: rules)
        #expect(pairs(graph.edges) == ["t1>c1", "t2>c1", "c1>c2", "c2>a1", "c2>a2"])
    }

    @Test("Zonder voorwaarden gaat elke trigger naar elke actie")
    func noConditions() throws {
        let nodes = [node("t1", .trigger), node("t2", .trigger), node("a1", .action), node("a2", .action)]
        let edges = [("t1", "a1"), ("t1", "a2"), ("t2", "a1"), ("t2", "a2")]
        let rules = try #require(FlowRules.rules(from: flow(nodes, edges)))
        #expect(rules.count == 1)
        #expect(rules[0].actions.map(\.id) == ["a1", "a2"])
    }

    @Test("Een keten acties blijft een keten")
    func chain() throws {
        let nodes = [node("t", .trigger), node("a3", .action), node("a1", .action), node("a2", .action)]
        let edges = [("t", "a1"), ("a1", "a2"), ("a2", "a3")]
        let rules = try #require(FlowRules.rules(from: flow(nodes, edges)))
        #expect(rules[0].actions.map(\.id) == ["a1", "a2", "a3"])
        #expect(rules[0].actionsInSequence)

        let graph = FlowRules.graph(from: rules)
        #expect(pairs(graph.edges) == ["t>a1", "a1>a2", "a2>a3"])
        let again = try #require(FlowRules.rules(from: Flow(id: "f", name: "x", nodes: graph.nodes, edges: graph.edges)))
        #expect(again.map(\.actions).map { $0.map(\.id) } == [["a1", "a2", "a3"]])
        #expect(again[0].actionsInSequence)
    }

    @Test("Vertakkingen passen niet in een lijst", arguments: [
        // Two conditions side by side.
        [("t", "c1"), ("t", "c2"), ("c1", "a"), ("c2", "a")],
        // An action only one condition leads to.
        [("t", "c1"), ("c1", "a"), ("t", "a2")],
        // Actions half fanned out, half chained.
        [("t", "a"), ("t", "a2"), ("a", "a2")],
    ])
    func branches(_ edges: [(String, String)]) {
        let nodes = [node("t", .trigger), node("c1", .condition), node("c2", .condition), node("a", .action), node("a2", .action)]
        let used = Set(edges.flatMap { [$0.0, $0.1] })
        #expect(FlowRules.rules(from: flow(nodes.filter { used.contains($0.id) }, edges)) == nil)
    }

    @Test("Een lijn naar een kaart die er niet is, wordt niet stilletjes weggegooid")
    func danglingEdge() {
        #expect(FlowRules.rules(from: flow([node("t", .trigger)], [("t", "weg")])) == nil)
    }

    @Test("Losse kaarten zonder lijnen zijn onvolledige regels")
    func loose() throws {
        let rules = try #require(FlowRules.rules(from: flow([node("t", .trigger), node("a", .action)], [])))
        #expect(rules.count == 2)
        #expect(rules.allSatisfy { !$0.isComplete })
    }

    @Test("Heen en terug: regels → graaf → regels")
    func roundTrip() throws {
        let first = FlowRule(triggers: [node("t", .trigger)], conditions: [node("c", .condition)],
                             actions: [node("a1", .action), node("a2", .action)])
        let second = FlowRule(triggers: [node("t2", .trigger)], actions: [node("b", .action)])
        let empty = FlowRule()
        let graph = FlowRules.graph(from: [first, empty, second])
        #expect(graph.nodes.count == 6)
        let rules = try #require(FlowRules.rules(from: Flow(id: "f", name: "x", nodes: graph.nodes, edges: graph.edges)))
        #expect(rules.count == 2)
        #expect(rules[0].conditions.map(\.id) == ["c"])
        #expect(rules[0].actions.map(\.id) == ["a1", "a2"])
        #expect(rules[1].triggers.map(\.id) == ["t2"])
        // Columns per part, rows per card, rules below each other.
        let t = try #require(graph.nodes.first { $0.id == "t" })
        let a2 = try #require(graph.nodes.first { $0.id == "a2" })
        let t2 = try #require(graph.nodes.first { $0.id == "t2" })
        #expect(a2.x > t.x)
        #expect(t2.y > a2.y)
    }

    @Test("Een bestaande lijn houdt zijn id, een nieuwe krijgt er een")
    func edgeIDs() {
        let rule = FlowRule(triggers: [node("t", .trigger)], actions: [node("a", .action), node("b", .action)])
        let graph = FlowRules.graph(from: [rule], reusing: [FlowEdge(id: "oud", from: "t", to: "a")])
        #expect(graph.edges.first { $0.to == "a" }?.id == "oud")
        let fresh = graph.edges.first { $0.to == "b" }?.id
        #expect(fresh != nil && fresh != "oud")
    }
}

@Suite("FlowCard: de zin van een kaart")
struct FlowCardSentenceTests {
    private func card(_ titleFormatted: String) throws -> FlowCard {
        let json = """
        {"appId":"stulp","id":"c","type":"condition","title":"Titel","titleFormatted":\(String(reflecting: titleFormatted)),
         "args":[{"name":"value","type":"number","units":"°C"},{"name":"level","type":"dropdown","values":[{"id":"6","label":{"nl":"6 Bft"}}]}]}
        """
        return try JSONDecoder().decode(FlowCard.self, from: Data(json.utf8))
    }

    @Test("Gekozen waarden staan in de zin, ontbrekende blijven [[naam]]")
    func filled() throws {
        let card = try card("Het is boven [[value]] met [[level]]")
        let step = FlowStep(appId: "stulp", cardId: "c", cardType: .condition, args: ["value": 21.5])
        let text = card.sentence(for: step) { argument, value in
            argument.name == "value" ? "\(value.text) \(argument.units ?? "")" : nil
        }
        #expect(text == "Het is boven 21.5 °C met [[level]]")
    }

    @Test("!{{zo|anders}} leest de tweede helft als de kaart is omgekeerd")
    func inverted() throws {
        let card = try card("De deur !{{is|is niet}} open")
        var step = FlowStep(appId: "stulp", cardId: "c", cardType: .condition)
        #expect(card.sentence(for: step) { _, _ in nil } == "De deur is open")
        step.inverted = true
        #expect(card.sentence(for: step) { _, _ in nil } == "De deur is niet open")
    }

    @Test("Zonder titleFormatted is de titel de zin")
    func plain() throws {
        let json = #"{"appId":"stulp","id":"c","type":"action","title":{"nl":"Wacht even","en":"Wait"}}"#
        let card = try JSONDecoder().decode(FlowCard.self, from: Data(json.utf8))
        #expect(card.sentence(for: FlowStep(appId: "stulp", cardId: "c", cardType: .action)) { _, _ in nil } == "Wacht even")
    }

    @Test("Een lege of null waarde telt als niet gekozen")
    func emptyValue() throws {
        let card = try card("Boven [[value]]")
        let step = FlowStep(appId: "stulp", cardId: "c", cardType: .condition, args: ["value": ""])
        #expect(card.sentence(for: step) { _, _ in "x" } == "Boven [[value]]")
    }
}

import Foundation
import StulpKit
import Testing

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

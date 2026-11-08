import StulpKit
import SwiftUI

/// How a Flow step reads in the app: its sentence with the chosen values filled in ("Zet Aan/uit
/// aan"), the device it is about, a symbol, and the one-line summary of a whole Flow. One place, so
/// the list, the editor and the picker never disagree about what a card says.
@MainActor
enum FlowText {
    static let dutch = Locale(identifier: "nl_NL")

    // MARK: - Steps

    static func card(_ step: FlowStep, _ model: HomeModel) -> FlowCard? {
        model.cards?.card(for: step)
    }

    /// The device a step is about: the value of its device argument.
    static func device(_ step: FlowStep, _ model: HomeModel) -> Device? {
        guard let id = step.deviceId, !id.isEmpty else { return nil }
        return model.devices[id]
    }

    /// The card's sentence with the chosen values in it. A value not chosen yet stays `[[name]]`,
    /// so it is visible what is missing.
    static func sentence(_ step: FlowStep, _ model: HomeModel) -> String {
        guard let card = card(step, model) else { return model.cards == nil ? "…" : "Onbekende kaart (\(step.cardId))" }
        let sentence = card.sentence(for: step) { argument, value in
            label(argument, value, card: card, step: step, model: model)
        }
        // A card whose title does not mention a chosen time or text ("Het is een bepaald
        // tijdstip") would hide exactly what makes it this card; it goes behind it.
        let template = card.titleFormatted ?? ""
        let extra = card.args.filter { ["time", "text", "string", "dropdown", "enum", "autocomplete", "number"].contains($0.type) }
            .filter { !template.contains("[[\($0.name)]]") }
            .compactMap { argument -> String? in
                guard let value = step.args[argument.name], !value.isNull, value != .string("") else { return nil }
                return label(argument, value, card: card, step: step, model: model)
            }
        return extra.isEmpty ? sentence : "\(sentence) (\(extra.joined(separator: ", ")))"
    }

    /// "Lamp keuken · Keuken": the device and its room, or the app for a card without a device.
    static func subtitle(_ step: FlowStep, _ model: HomeModel) -> String? {
        if let device = device(step, model) {
            let room = model.path(of: device.groupId)
            return room.isEmpty ? device.name : "\(device.name) · \(room)"
        }
        if step.deviceId != nil { return "Apparaat bestaat niet meer" }
        guard let card = card(step, model), card.appId != "stulp" else { return nil }
        return card.appName
    }

    /// The device's own symbol, or one that says what a device-less card does.
    static func symbol(_ step: FlowStep, _ model: HomeModel) -> String {
        if let device = device(step, model) { return DevicePresentation.symbol(device) }
        switch step.cardId {
        case "time_at": return "clock.fill"
        case "sunrise": return "sunrise.fill"
        case "sunset": return "sunset.fill"
        case "delay": return "hourglass"
        case "notification": return "bell.fill"
        case "matter_event": return "dot.radiowaves.left.and.right"
        default: break
        }
        switch step.cardType {
        case .trigger: return "bolt.fill"
        case .condition: return "checkmark.circle.fill"
        case .action: return "wand.and.stars"
        }
    }

    /// The words for one chosen value, as the sentence should read it.
    static func label(_ argument: CardArgument, _ value: JSONValue, card: FlowCard, step: FlowStep, model: HomeModel) -> String? {
        switch argument.type {
        case "device":
            guard let id = value["$device"]?.string else { return nil }
            return model.devices[id]?.name ?? "een verwijderd apparaat"
        case "capability":
            guard let id = value.string, !id.isEmpty else { return "elke waarde" }
            return device(step, model)?[capability: id]?.title ?? id
        case "capability-value":
            if let definition = capability(for: step, card: card, model: model) {
                if let match = definition.values.first(where: { $0.id == value.text }) { return match.title }
                if definition.isBoolean, let b = value.bool { return DevicePresentation.words(definition.base, b).state }
                if let n = value.number {
                    var copy = definition
                    copy.value = .number(n)
                    return DevicePresentation.display(copy)
                }
            }
            return value.bool.map { $0 ? "aan" : "uit" } ?? value.text
        default:
            break
        }
        if let match = argument.values.first(where: { $0.id == value.text }) { return match.title }
        if case .object = value { return autocompleteLabel(value) }
        if argument.type == "checkbox" || argument.type == "boolean", let b = value.bool { return b ? "ja" : "nee" }
        if let n = value.number {
            let text = DevicePresentation.number(n, decimals: 2)
            guard let units = argument.units, !units.isEmpty else {
                return argument.name == "seconds" ? "\(text) s" : text
            }
            return units == "%" ? "\(text)%" : "\(text) \(units)"
        }
        return value.text
    }

    /// What an autocomplete choice is called: its name, title, label or id.
    static func autocompleteLabel(_ value: JSONValue) -> String {
        if let s = value.string { return s }
        for key in ["name", "title", "label"] {
            let text = LocalizedText.resolve(value[key])
            if !text.isEmpty { return text }
        }
        return value["id"]?.text ?? ""
    }

    /// The capability a value argument is about: the card's own (derived cards) or the one chosen
    /// in the step (the generic cards).
    static func capability(for step: FlowStep, card: FlowCard?, model: HomeModel) -> Capability? {
        guard let device = device(step, model) else { return nil }
        let id = card?.capability ?? step.args["capability"]?.string ?? ""
        return id.isEmpty ? nil : device[capability: id]
    }

    // MARK: - Choosing

    /// The devices a card can be about, in tile order.
    static func devices(for card: FlowCard, _ model: HomeModel) -> [Device] {
        let allowed = Set(card.deviceIds)
        return model.devices.values.filter { allowed.contains($0.id) }.sorted(by: HomeModel.tileOrder)
    }

    /// The choices a capability value offers: its enum values, or on/off for a boolean.
    static func choices(_ capability: Capability) -> [(value: JSONValue, title: String)]? {
        if !capability.values.isEmpty {
            return capability.values.map { (.string($0.id), $0.title) }
        }
        if capability.isBoolean {
            let words = DevicePresentation.words(capability.base, true)
            return [(.bool(true), words.on.capitalizedFirst), (.bool(false), words.off.capitalizedFirst)]
        }
        return nil
    }

    /// A fresh step with every argument filled in that can be worked out, so a new card is usable
    /// instead of a row of blanks. `preferred` is the device the card was picked from.
    static func step(from card: FlowCard, device preferred: Device?, _ model: HomeModel) -> FlowStep {
        let candidates = devices(for: card, model)
        let device = candidates.first { $0.id == preferred?.id } ?? candidates.first
        var args: [String: JSONValue] = [:]
        for argument in card.args {
            switch argument.type {
            case "device":
                args[argument.name] = ["$device": .string(device?.id ?? "")]
            case "checkbox", "boolean":
                args[argument.name] = .bool(argument.value?.bool ?? false)
            case "dropdown", "enum":
                args[argument.name] = argument.value ?? argument.values.first.map { .string($0.id) } ?? ""
            case "capability":
                args[argument.name] = .string(argument.optional ? "" : device?.capabilities.first ?? "")
            case "capability-value":
                args[argument.name] = ""
            default:
                args[argument.name] = argument.value ?? ""
            }
        }
        var step = FlowStep(appId: card.appId, cardId: card.cardId, cardType: card.type, args: args)
        // The value field follows the capability, so seed it as the editor would.
        if let definition = capability(for: step, card: card, model: model), let first = choices(definition)?.first,
           card.args.contains(where: { $0.type == "capability-value" && $0.name == "value" }) {
            step.args["value"] = first.value
        }
        return step
    }

    /// Whether a card has anything left to choose once its device is picked.
    static func needsEditing(_ card: FlowCard) -> Bool {
        card.args.contains { $0.type != "device" }
    }

    // MARK: - Flows

    /// "Lamp keuken: Aan/uit werd aan → Ventilator: Zet Aan/uit aan": the first trigger and the
    /// first action, with a count for the rest. An arrow and not "Als …, dan …": card titles are
    /// whole sentences ("Het is een bepaald tijdstip") that do not bend into a subordinate clause.
    static func summary(_ flow: Flow, _ model: HomeModel) -> String {
        let triggers = flow.nodes.filter { $0.step.cardType == .trigger }
        let actions = flow.nodes.filter { $0.step.cardType == .action }
        guard let trigger = triggers.first else {
            return flow.nodes.isEmpty ? "Nog leeg" : "Nog zonder Als-kaart"
        }
        var text = phrase(trigger.step, model)
        if triggers.count > 1 { text += " (+\(triggers.count - 1))" }
        if let action = actions.first {
            text += " → " + phrase(action.step, model)
            if actions.count > 1 { text += " (+\(actions.count - 1))" }
        }
        return text
    }

    /// A step on one line: the device's name in front when the sentence does not name it.
    static func phrase(_ step: FlowStep, _ model: HomeModel) -> String {
        let sentence = self.sentence(step, model)
        guard let device = device(step, model), !sentence.contains(device.name) else { return sentence }
        return "\(device.name): \(sentence)"
    }

    /// The symbol of a Flow: its first trigger's.
    static func symbol(_ flow: Flow, _ model: HomeModel) -> String {
        guard let trigger = flow.nodes.first(where: { $0.step.cardType == .trigger }) else { return "clock.fill" }
        return symbol(trigger.step, model)
    }

    /// The tokens the rule's triggers offer to the fields after them (`{{value}}`).
    static func tokens(of triggers: [FlowNode], _ model: HomeModel) -> [FlowToken] {
        var seen: Set<String> = []
        var out: [FlowToken] = []
        for trigger in triggers {
            for token in card(trigger.step, model)?.tokens ?? [] where seen.insert(token.name).inserted {
                out.append(token)
            }
        }
        return out
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(dutch))
    }
}

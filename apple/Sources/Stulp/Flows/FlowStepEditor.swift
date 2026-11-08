import StulpKit
import SwiftUI

/// The fields of one card, the way Home configures a trigger or an action: the sentence it will
/// read as on top (live), then one row per argument with the control that fits its type.
struct FlowStepEditor: View {
    enum Mode { case add, edit }

    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let card: FlowCard?
    let mode: Mode
    /// The tokens of the rule's triggers, offered in text fields.
    let tokens: [FlowToken]
    let onDone: (FlowStep) -> Void
    @State private var step: FlowStep

    init(step: FlowStep, card: FlowCard?, mode: Mode, tokens: [FlowToken], onDone: @escaping (FlowStep) -> Void) {
        self.card = card
        self.mode = mode
        self.tokens = tokens
        self.onDone = onDone
        _step = State(initialValue: step)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: FlowText.symbol(step, model))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FlowText.sentence(step, model))
                            .font(.headline)
                        if let subtitle = FlowText.subtitle(step, model) {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } footer: {
                if let hint = card?.hint, !hint.isEmpty { Text(hint) }
            }

            if let card {
                let arguments = card.args
                if !arguments.isEmpty {
                    Section {
                        ForEach(arguments) { argument in
                            FlowArgumentRow(argument: argument, card: card, step: $step, tokens: tokens)
                        }
                    }
                }
                if card.type == .condition {
                    Section {
                        Toggle("Omkeren (niet)", isOn: $step.inverted)
                    } footer: {
                        Text("Omgekeerd gaat de regel juist door als deze voorwaarde niet klopt.")
                    }
                }
            } else {
                Section {
                    Text("Deze kaart is er niet meer: de app die hem aanbood is weg of uitgeschakeld.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(card?.type.editorTitle ?? "Kaart")
        .inlineTitle()
        .toolbar {
            if mode == .edit {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .add ? "Voeg toe" : "Gereed") { onDone(step) }
                    .disabled(card == nil)
            }
        }
    }
}

extension FlowCardType {
    /// The words Home uses for the three parts of an automation.
    var editorTitle: String {
        switch self {
        case .trigger: "Wanneer"
        case .condition: "Voorwaarde"
        case .action: "Actie"
        }
    }

    var addTitle: String {
        switch self {
        case .trigger: "Voeg gebeurtenis toe"
        case .condition: "Voeg voorwaarde toe"
        case .action: "Voeg actie toe"
        }
    }
}

/// One argument and its control.
struct FlowArgumentRow: View {
    @Environment(HomeModel.self) private var model
    let argument: CardArgument
    let card: FlowCard
    @Binding var step: FlowStep
    let tokens: [FlowToken]

    private var value: JSONValue? { step.args[argument.name] }

    private var title: String {
        var title = argument.title == argument.name ? fallbackTitle : argument.title
        if let units = argument.units, !units.isEmpty { title += " (\(units))" }
        return title
    }

    /// Manifests often leave a device argument untitled; say what the field is.
    private var fallbackTitle: String {
        switch argument.type {
        case "device": "Apparaat"
        case "capability": "Eigenschap"
        case "capability-value": "Waarde"
        default: argument.name.capitalizedFirst
        }
    }

    private func set(_ new: JSONValue) { step.args[argument.name] = new }

    var body: some View {
        switch argument.type {
        case "device": devicePicker
        case "capability": capabilityPicker
        case "capability-value": capabilityValue
        case "dropdown", "enum": dropdown
        case "autocomplete":
            NavigationLink {
                AutocompletePicker(argument: argument, card: card, step: $step)
            } label: {
                LabeledContent(title) {
                    let chosen = value.map(FlowText.autocompleteLabel) ?? ""
                    Text(chosen.isEmpty ? "Kies…" : chosen)
                        .foregroundStyle(value?.object == nil ? .secondary : .primary)
                }
            }
        case "checkbox", "boolean":
            Toggle(title, isOn: Binding(get: { value?.bool ?? false }, set: { set(.bool($0)) }))
        case "number", "range":
            NumberField(title: title, placeholder: argument.placeholder, value: Binding(get: { value }, set: { set($0 ?? .null) }))
        case "time":
            DatePicker(title, selection: timeBinding, displayedComponents: .hourAndMinute)
                .environment(\.locale, FlowText.dutch)
        case "json":
            TokenTextField(title: title, placeholder: "true, 42, \"tekst\" of {{token}}", tokens: tokens,
                           text: Binding(get: { value.map(Self.jsonText) ?? "" }, set: { set(Self.json($0)) }))
        default:
            TokenTextField(title: title, placeholder: argument.placeholder ?? "", tokens: tokens,
                           text: Binding(get: { value?.text ?? "" }, set: { set(.string($0)) }))
        }
    }

    // MARK: Device and capability

    private var devicePicker: some View {
        let devices = FlowText.devices(for: card, model)
        let chosen = value?["$device"]?.string ?? ""
        return Picker(title, selection: Binding(get: { chosen }, set: { id in
            set(["$device": .string(id)])
            // Another device has other capabilities: whatever followed from the old one goes.
            if step.args["capability"] != nil {
                step.args["capability"] = ""
                step.args["value"] = ""
            }
            if card.capability != nil, let definition = FlowText.capability(for: step, card: card, model: model),
               let first = FlowText.choices(definition)?.first, step.args["value"] != nil {
                step.args["value"] = first.value
            }
        })) {
            if chosen.isEmpty || model.devices[chosen] == nil {
                Text(chosen.isEmpty ? "Kies…" : "Verwijderd apparaat").tag(chosen)
            }
            ForEach(grouped(devices), id: \.0) { room, members in
                Section(room) {
                    ForEach(members) { device in
                        Text(deviceLabel(device)).tag(device.id)
                    }
                }
            }
        }
    }

    /// Two devices may share a name ("Woonkamer" the lamp and "Woonkamer" the camera), so the app
    /// goes with it when it would otherwise be ambiguous.
    private func deviceLabel(_ device: Device) -> String {
        let twins = model.devices.values.filter { $0.name == device.name }.count
        guard twins > 1 else { return device.name }
        let app = model.apps.first { $0.id == device.appId }?.name ?? device.appId
        return "\(device.name) — \(app)"
    }

    private func grouped(_ devices: [Device]) -> [(String, [Device])] {
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

    @ViewBuilder private var capabilityPicker: some View {
        if let device = FlowText.device(step, model) {
            Picker(title, selection: Binding(get: { value?.string ?? "" }, set: { id in
                set(.string(id))
                // The value field follows the capability.
                if let definition = device[capability: id], let first = FlowText.choices(definition)?.first {
                    step.args["value"] = first.value
                } else if step.args["value"] != nil {
                    step.args["value"] = ""
                }
            })) {
                if argument.optional { Text("Elke waarde").tag("") }
                ForEach(device.orderedCapabilities) { capability in
                    Text(capability.title).tag(capability.id)
                }
            }
            .onAppear {
                if (value?.string ?? "").isEmpty, !argument.optional, let first = device.capabilities.first {
                    set(.string(first))
                }
            }
        } else {
            LabeledContent(title) { Text("Kies eerst een apparaat").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var capabilityValue: some View {
        if let definition = FlowText.capability(for: step, card: card, model: model) {
            if let choices = FlowText.choices(definition) {
                Picker(title, selection: Binding(get: { value?.text ?? "" }, set: { text in
                    set(choices.first { $0.value.text == text }?.value ?? .string(text))
                })) {
                    ForEach(choices, id: \.value.text) { choice in
                        Text(choice.title).tag(choice.value.text)
                    }
                }
                .onAppear {
                    if value == nil || value == .string(""), let first = choices.first { set(first.value) }
                }
            } else if definition.isNumber {
                let units = definition.units.map { " (\($0))" } ?? ""
                NumberField(title: title == "Waarde" ? "\(definition.title)\(units)" : title,
                            placeholder: definition.units.map { "waarde in \($0)" },
                            value: Binding(get: { value }, set: { set($0 ?? .null) }))
            } else {
                TokenTextField(title: definition.title, placeholder: "waarde of {{token}}", tokens: tokens,
                               text: Binding(get: { value?.text ?? "" }, set: { set(.string($0)) }))
            }
        } else {
            LabeledContent(title) { Text("Kies eerst een eigenschap").foregroundStyle(.secondary) }
        }
    }

    private var dropdown: some View {
        Picker(title, selection: Binding(get: { value?.text ?? "" }, set: { set(.string($0)) })) {
            if !argument.values.contains(where: { $0.id == (value?.text ?? "") }) {
                Text("Kies…").tag(value?.text ?? "")
            }
            ForEach(argument.values) { choice in
                Text(choice.title).tag(choice.id)
            }
        }
    }

    // MARK: Time and JSON

    /// "HH:mm" in the step, a Date in the picker (today, which does not matter).
    private var timeBinding: Binding<Date> {
        Binding {
            let parts = (value?.string ?? "").split(separator: ":").compactMap { Int($0) }
            var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            components.hour = parts.first ?? 7
            components.minute = parts.count > 1 ? parts[1] : 0
            return Calendar.current.date(from: components) ?? .now
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            set(.string(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)))
        }
    }

    static func jsonText(_ value: JSONValue) -> String {
        if case .string(let s) = value { return s }
        return value.text
    }

    /// Parsed as JSON unless it carries a token: `{{value}}` is filled in by Stulp, not here.
    static func json(_ text: String) -> JSONValue {
        if text.contains("{{") { return .string(text) }
        guard let data = text.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(text)
        }
        return parsed
    }
}

/// A number typed as text: Dutch comma or dot, empty is no value, a `{{token}}` stays text.
struct NumberField: View {
    let title: String
    var placeholder: String?
    @Binding var value: JSONValue?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            TextField(placeholder ?? "", text: $text)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onChange(of: text) { _, new in value = Self.parse(new) }
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, new in
            if !focused { text = Self.format(new) }
        }
    }

    static func parse(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        if trimmed.contains("{{") { return .string(trimmed) }
        if let n = Double(trimmed.replacingOccurrences(of: ",", with: ".")) { return .number(n) }
        return .string(trimmed)
    }

    static func format(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let n = value.number {
            return n.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(FlowText.dutch))
        }
        return value.string ?? ""
    }
}

/// A text field with a menu that puts a trigger's `{{token}}` at the end of the text.
struct TokenTextField: View {
    let title: String
    let placeholder: String
    let tokens: [FlowToken]
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                if !tokens.isEmpty {
                    Menu {
                        Section("Waarde van de gebeurtenis") {
                            ForEach(tokens, id: \.name) { token in
                                Button("\(token.title)  {{\(token.name)}}") {
                                    let separator = text.isEmpty || text.hasSuffix(" ") ? "" : " "
                                    text += separator + "{{\(token.name)}}"
                                }
                            }
                        }
                    } label: {
                        Label("Voeg waarde in", systemImage: "curlybraces")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Voeg een waarde van de gebeurtenis in")
                }
            }
        }
    }
}

/// The search list of an autocomplete argument. Typing asks the app (debounced); a slower answer
/// to an older question never overwrites a newer one. The whole chosen item is what the step keeps.
struct AutocompletePicker: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let argument: CardArgument
    let card: FlowCard
    @Binding var step: FlowStep
    @State private var query = ""
    @State private var items: [AutocompleteItem] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let chosen = step.args[argument.name], chosen.object != nil {
                Section("Gekozen") {
                    Label(FlowText.autocompleteLabel(chosen), systemImage: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            Section {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if items.isEmpty, !loading {
                    Text(query.isEmpty ? "Typ om te zoeken." : "Niets gevonden.").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button {
                        step.args[argument.name] = item.raw
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name.isEmpty ? FlowText.autocompleteLabel(item.raw) : item.name)
                                .foregroundStyle(.primary)
                            if let description = item.description {
                                Text(description).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: argument.placeholder ?? "Zoek")
        .navigationTitle(argument.title)
        .inlineTitle()
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func search(_ text: String) async {
        guard let client = model.client else { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await client.autocomplete(card: card, argument: argument.name, query: text, args: step.args)
            // `.task(id:)` cancels the previous search when the text changes, so a late answer to
            // an older question is dropped here rather than shown.
            guard !Task.isCancelled else { return }
            items = found
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

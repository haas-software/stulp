import StulpKit
import SwiftUI

/// One Flow, edited the way Home edits an automation: a name, on or off, and per rule what starts
/// it (*Als*), what must hold (*En*) and what happens (*Dan*). Most Flows are one rule; a Flow made
/// of independent parts (motion on → lamp on, motion off → lamp off) shows one block per part.
///
/// Only what travels changes: the rules become the graph again on save (`FlowRules.graph`), with
/// the existing lines keeping their ids. A graph the rules cannot express (a branch, conditions side
/// by side) stays read-only here instead of being rewritten into something else.
struct FlowEditor: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The Flow as last saved; nil until a new one is saved for the first time.
    @State private var current: Flow?
    @State private var name: String
    @State private var enabled: Bool
    /// nil: read-only, the graph does not fit the rule shape.
    @State private var rules: [FlowRule]?
    @State private var saved: Snapshot

    @State private var picking: Picking?
    @State private var editing: Editing?
    @State private var confirmingCancel = false
    @State private var confirmingDelete = false
    @State private var busy = false

    private struct Snapshot: Equatable {
        var name: String
        var enabled: Bool
        var rules: [FlowRule]?
    }

    /// Adding a card to one part of one rule.
    private struct Picking: Identifiable {
        let rule: String
        let type: FlowCardType
        var id: String { "\(rule)/\(type.rawValue)" }
    }

    /// Editing the fields of one card.
    private struct Editing: Identifiable {
        let rule: String
        let type: FlowCardType
        let node: String
        var id: String { node }
    }

    init(flow: Flow?) {
        let parsed: [FlowRule]? = flow.map { FlowRules.rules(from: $0) } ?? []
        let rules = parsed.map { $0.isEmpty ? [FlowRule()] : $0 }
        _current = State(initialValue: flow)
        _name = State(initialValue: flow?.name ?? "")
        _enabled = State(initialValue: flow?.enabled ?? true)
        _rules = State(initialValue: rules)
        _saved = State(initialValue: Snapshot(name: flow?.name ?? "", enabled: flow?.enabled ?? true, rules: rules))
    }

    private var snapshot: Snapshot { Snapshot(name: name, enabled: enabled, rules: rules) }
    private var dirty: Bool { snapshot != saved }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Naam", text: $name, prompt: Text("Bijv. Keuken: lamp bij beweging"))
                    Toggle("Actief", isOn: $enabled)
                } footer: {
                    if let error = current?.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else if let run = current?.lastRun {
                        Text("Laatst uitgevoerd \(FlowText.relative(run)).")
                    }
                }

                if rules != nil {
                    editableRules
                } else {
                    readOnly
                }

                if current != nil {
                    Section {
                        Button("Test nu", systemImage: "play.fill") { Task { await test() } }
                            .disabled(busy)
                        Button("Verwijder flow", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            .disabled(busy)
                            .tint(.red)
                    } footer: {
                        Text("Testen voert de flow nu één keer uit, alsof een Als-kaart afging. Voorwaarden tellen gewoon mee.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(current == nil ? "Nieuwe flow" : (trimmedName.isEmpty ? "Flow" : trimmedName))
            .inlineTitle()
            .toolbar { toolbar }
            .interactiveDismissDisabled(dirty)
            .task {
                await model.ensureCards()
                #if DEBUG
                // `-stulpFlowPick trigger|condition|action` opens the card picker, for screenshots.
                if let raw = UserDefaults.standard.string(forKey: "stulpFlowPick"), let type = FlowCardType(rawValue: raw),
                   let rule = rules?.first {
                    picking = Picking(rule: rule.id, type: type)
                }
                // `-stulpFlowEdit <node id>` opens that card's fields.
                if let wanted = UserDefaults.standard.string(forKey: "stulpFlowEdit") {
                    for rule in rules ?? [] {
                        for type in FlowCardType.allCases where rule[type].contains(where: { $0.id == wanted }) {
                            editing = Editing(rule: rule.id, type: type, node: wanted)
                        }
                    }
                }
                #endif
            }
            .sheet(item: $picking) { picking in
                FlowCardPicker(type: picking.type, tokens: tokens(of: picking.rule)) { step in
                    add(step, to: picking.rule, as: picking.type)
                }
                .environment(model)
            }
            .sheet(item: $editing) { editing in
                if let node = node(editing) {
                    NavigationStack {
                        FlowStepEditor(step: node.step, card: model.cards?.card(for: node.step), mode: .edit,
                                       tokens: tokens(of: editing.rule)) { step in
                            replace(editing, with: step)
                            self.editing = nil
                        }
                    }
                    .macSheetSize(width: 520, height: 560)
                    .environment(model)
                }
            }
            .confirmationDialog("Wijzigingen weggooien?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                Button("Gooi weg", role: .destructive) { dismiss() }
                Button("Ga door met bewerken", role: .cancel) {}
            }
            .confirmationDialog("\(trimmedName.isEmpty ? "Deze flow" : trimmedName) verwijderen?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Verwijder", role: .destructive) { Task { await delete() } }
            }
        }
        .macSheetSize(width: 620, height: 720)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Annuleer") {
                if dirty { confirmingCancel = true } else { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Bewaar") {
                Task {
                    if await save() != nil { dismiss() }
                }
            }
            .disabled(trimmedName.isEmpty || busy || (!dirty && current != nil))
        }
    }

    // MARK: - Rules

    @ViewBuilder private var editableRules: some View {
        let all = rules ?? []
        ForEach(all) { rule in
            let number = (all.firstIndex { $0.id == rule.id } ?? 0) + 1
            part(rule, .trigger, number: number, count: all.count)
            part(rule, .condition, number: number, count: all.count)
            part(rule, .action, number: number, count: all.count)
            if all.count > 1 {
                Section {
                    Button("Verwijder regel \(number)", systemImage: "minus.circle", role: .destructive) {
                        rules?.removeAll { $0.id == rule.id }
                    }
                    .tint(.red)
                }
            }
        }
        Section {
            Button("Regel toevoegen", systemImage: "plus.circle") {
                rules?.append(FlowRule())
            }
        } footer: {
            Text("Een regel is een losse Als-En-Dan. Zo kan één flow een lamp bij beweging aan- en bij stilte weer uitzetten.")
        }
    }

    private func part(_ rule: FlowRule, _ type: FlowCardType, number: Int, count: Int) -> some View {
        Section {
            ForEach(rule[type]) { node in
                Button {
                    editing = Editing(rule: rule.id, type: type, node: node.id)
                } label: {
                    StepRow(step: node.step)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Wijzig", systemImage: "slider.horizontal.3") {
                        editing = Editing(rule: rule.id, type: type, node: node.id)
                    }
                    Button("Verwijder", systemImage: "trash", role: .destructive) {
                        remove(node.id, from: rule.id, type)
                    }
                }
            }
            .onDelete { offsets in
                mutate(rule.id) { $0[type].remove(atOffsets: offsets) }
            }
            .onMove(perform: type == .action ? { from, to in mutate(rule.id) { $0.actions.move(fromOffsets: from, toOffset: to) } } : nil)

            Button {
                picking = Picking(rule: rule.id, type: type)
            } label: {
                Label(type.addTitle, systemImage: "plus.circle.fill")
            }
        } header: {
            Text(count > 1 ? "Regel \(number) · \(header(type))" : header(type))
        } footer: {
            footer(rule, type)
        }
    }

    private func header(_ type: FlowCardType) -> String {
        switch type {
        case .trigger: "Als"
        case .condition: "En"
        case .action: "Dan"
        }
    }

    @ViewBuilder private func footer(_ rule: FlowRule, _ type: FlowCardType) -> some View {
        switch type {
        case .trigger:
            Text(rule.triggers.count > 1 ? "Als een van deze gebeurt." : "Wat de regel start.")
        case .condition:
            Text(rule.conditions.isEmpty ? "Optioneel: wat er dan ook moet kloppen." : "Alle voorwaarden moeten kloppen.")
        case .action:
            if !rule.isEmpty && !rule.isComplete {
                Label("Deze regel mist nog een Als- of Dan-kaart. Stulp voert hem pas uit als hij beide heeft.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if rule.actions.count > 1 {
                Text(rule.actionsInSequence
                     ? "Na elkaar, in deze volgorde. Mislukt er een, dan slaat Stulp de rest over."
                     : "Na elkaar, in deze volgorde. Mislukt er een, dan gaat Stulp door met de volgende.")
            }
        }
    }

    // MARK: - Read-only

    @ViewBuilder private var readOnly: some View {
        Section {
            Label("Deze flow vertakt zich op een manier die niet als lijst te tonen is. Je kunt hem hernoemen, aan- of uitzetten en testen; de kaarten blijven zoals ze zijn.",
                  systemImage: "arrow.triangle.branch")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(FlowCardType.allCases, id: \.self) { type in
            let nodes = current?.nodes.filter { $0.step.cardType == type } ?? []
            if !nodes.isEmpty {
                Section(header(type)) {
                    ForEach(nodes) { node in StepRow(step: node.step) }
                }
            }
        }
    }

    // MARK: - Editing the rules

    private func tokens(of rule: String) -> [FlowToken] {
        FlowText.tokens(of: rules?.first { $0.id == rule }?.triggers ?? [], model)
    }

    private func mutate(_ rule: String, _ change: (inout FlowRule) -> Void) {
        guard let index = rules?.firstIndex(where: { $0.id == rule }) else { return }
        change(&rules![index])
    }

    private func add(_ step: FlowStep, to rule: String, as type: FlowCardType) {
        mutate(rule) { $0[type].append(FlowNode(step: step)) }
    }

    private func remove(_ node: String, from rule: String, _ type: FlowCardType) {
        mutate(rule) { $0[type].removeAll { $0.id == node } }
    }

    private func node(_ editing: Editing) -> FlowNode? {
        rules?.first { $0.id == editing.rule }?[editing.type].first { $0.id == editing.node }
    }

    private func replace(_ editing: Editing, with step: FlowStep) {
        mutate(editing.rule) { rule in
            if let index = rule[editing.type].firstIndex(where: { $0.id == editing.node }) {
                rule[editing.type][index].step = step
            }
        }
    }

    // MARK: - Saving

    /// Saves what is on screen and answers the Flow as Stulp stored it.
    private func save() async -> Flow? {
        busy = true
        defer { busy = false }
        var flow = current ?? Flow(name: trimmedName)
        flow.name = trimmedName
        flow.enabled = enabled
        if let rules {
            let graph = FlowRules.graph(from: rules, reusing: current?.edges ?? [])
            flow.nodes = graph.nodes
            flow.edges = graph.edges
        }
        var stored: Flow?
        let base = current
        let ok = await model.perform { client in
            do {
                stored = try await client.saveFlow(flow)
            } catch StulpClientError.server(409, _) where base != nil {
                // Every run bumps the revision, so a Flow that fired (or was tested) while open
                // would refuse its own save. When only that changed, save onto the new revision;
                // when someone else changed the Flow itself, say so instead of overwriting it.
                guard let base, let fresh = try await client.flows().first(where: { $0.id == base.id }) else { throw FlowEditorError.gone }
                guard fresh.name == base.name, fresh.enabled == base.enabled, fresh.nodes == base.nodes, fresh.edges == base.edges else {
                    throw FlowEditorError.changedElsewhere
                }
                flow.revision = fresh.revision
                stored = try await client.saveFlow(flow)
            }
        }
        guard ok, let stored else { return nil }
        current = stored
        // Ids of new cards and lines come from Stulp; read the rules back from what it stored.
        if rules != nil, let parsed = FlowRules.rules(from: stored) {
            rules = parsed.isEmpty ? [FlowRule()] : parsed
        }
        saved = snapshot
        await model.reloadFlows()
        return stored
    }

    private func test() async {
        var flow = current
        if dirty || flow == nil { flow = await save() }
        guard let flow else { return }
        await FlowRunner.run(flow, model)
    }

    private func delete() async {
        guard let id = current?.id else { return }
        let ok = await model.perform("\(trimmedName) is verwijderd.") { try await $0.deleteFlow(id) }
        if ok {
            await model.reloadFlows()
            dismiss()
        }
    }
}

enum FlowEditorError: LocalizedError {
    case gone
    case changedElsewhere

    var errorDescription: String? {
        switch self {
        case .gone: "Deze flow bestaat niet meer in Stulp."
        case .changedElsewhere: "Deze flow is intussen ergens anders gewijzigd. Sluit hem en open hem opnieuw."
        }
    }
}

/// One card in the editor: its symbol, its sentence and the device it is about.
struct StepRow: View {
    @Environment(HomeModel.self) private var model
    let step: FlowStep

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: FlowText.symbol(step, model))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if step.inverted && !(model.cards?.card(for: step)?.titleFormatted?.contains("!{{") ?? false) {
                        Text("NIET")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange, in: .capsule)
                    }
                    Text(FlowText.sentence(step, model))
                        .foregroundStyle(.primary)
                }
                if let subtitle = FlowText.subtitle(step, model) {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Running a Flow by hand and saying what came of it.
@MainActor
enum FlowRunner {
    static func run(_ flow: Flow, _ model: HomeModel) async {
        var result: FlowRunResult?
        let ok = await model.perform { result = try await $0.runFlow(flow.id) }
        guard ok, let result else { return }
        if let error = result.error, !error.isEmpty {
            model.notice = .init(text: error, isError: true)
        } else if result.stopped {
            model.notice = .init(text: "Een voorwaarde hield \(flow.name) tegen.", isError: false)
        } else {
            model.notice = .init(text: "\(flow.name) is uitgevoerd.", isError: false)
        }
        await model.reloadFlows()
    }
}

#Preview("Nieuwe flow") {
    FlowEditor(flow: nil).previewHouse()
}

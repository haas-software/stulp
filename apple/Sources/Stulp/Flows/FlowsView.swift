import StulpKit
import SwiftUI

/// Automatisering: every Flow as Home lists its automations — what starts it and what it does in
/// one line, a switch to turn it on or off, and the last run or the last error underneath.
struct FlowsView: View {
    @Environment(HomeModel.self) private var model
    @State private var editing: Flow?
    @State private var creating = false
    @State private var deleting: Flow?
    @State private var loaded = false
    /// The switch moves at once; the event stream brings Stulp's own answer a moment later.
    @State private var pendingEnabled: [String: Bool] = [:]

    var body: some View {
        List {
            if !model.flows.isEmpty {
                Section {
                    ForEach(model.flows) { flow in
                        row(flow)
                    }
                } footer: {
                    Text("Een flow start bij een gebeurtenis (Als), controleert voorwaarden (En) en doet dan iets (Dan).")
                }
            }
        }
        .overlay { overlay }
        .navigationTitle("Automatisering")
        .largeTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Nieuwe flow", systemImage: "plus") { creating = true }
                    .disabled(!model.isConfigured)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $creating) {
            FlowCanvasEditor(flow: nil).environment(model)
        }
        .sheet(item: $editing) { flow in
            FlowCanvasEditor(flow: flow).environment(model)
        }
        .confirmationDialog("\(deleting?.name ?? "Flow") verwijderen?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { flow in
            Button("Verwijder", role: .destructive) { Task { await delete(flow) } }
        } message: { _ in
            Text("De flow verdwijnt; de apparaten blijven zoals ze zijn.")
        }
        .onChange(of: model.flows) { _, flows in
            // Once Stulp agrees, the local override is no longer needed.
            for flow in flows where pendingEnabled[flow.id] == flow.enabled { pendingEnabled[flow.id] = nil }
        }
    }

    @ViewBuilder private var overlay: some View {
        if model.flows.isEmpty {
            if !loaded && !model.demo {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("Nog geen automatisering", systemImage: "clock.fill")
                } description: {
                    Text("Laat je huis zelf iets doen: een lamp aan bij beweging, de rolluiken omlaag bij zonsondergang.")
                } actions: {
                    Button("Nieuwe flow") { creating = true }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.isConfigured)
                }
            }
        }
    }

    private func row(_ flow: Flow) -> some View {
        let enabled = pendingEnabled[flow.id] ?? flow.enabled
        return HStack(spacing: 12) {
            Button {
                editing = flow
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: FlowText.symbol(flow, model))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(enabled ? Color.white : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                    in: .rect(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.name.isEmpty ? "Naamloze flow" : flow.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(FlowText.summary(flow, model))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        status(flow)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Toggle("Actief", isOn: Binding(get: { enabled }, set: { new in Task { await setEnabled(flow, new) } }))
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Verwijder", systemImage: "trash", role: .destructive) { deleting = flow }
            Button("Test", systemImage: "play.fill") { Task { await FlowRunner.run(flow, model) } }
                .tint(.accentColor)
        }
        .contextMenu {
            Button("Wijzig", systemImage: "slider.horizontal.3") { editing = flow }
            Button("Test nu", systemImage: "play.fill") { Task { await FlowRunner.run(flow, model) } }
            Button(enabled ? "Zet uit" : "Zet aan", systemImage: "power") { Task { await setEnabled(flow, !enabled) } }
            Divider()
            Button("Verwijder…", systemImage: "trash", role: .destructive) { deleting = flow }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func status(_ flow: Flow) -> some View {
        if let error = flow.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if let run = flow.lastRun {
            Text("Laatst uitgevoerd \(FlowText.relative(run))")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        async let flows: Void = model.reloadFlows()
        async let cards: Void = model.ensureCards()
        _ = await (flows, cards)
        if !loaded { openFromLaunch() }
        loaded = true
    }

    /// Debug only: `-stulpFlow <name, id or "new">` opens that Flow's editor, for screenshots.
    private func openFromLaunch() {
        #if DEBUG
        guard let wanted = UserDefaults.standard.string(forKey: "stulpFlow") else { return }
        if wanted == "new" {
            creating = true
        } else {
            editing = model.flows.first { $0.id == wanted || $0.name == wanted }
        }
        #endif
    }

    private func setEnabled(_ flow: Flow, _ enabled: Bool) async {
        pendingEnabled[flow.id] = enabled
        let ok = await model.perform { try await $0.setFlowEnabled(flow.id, enabled) }
        if ok {
            await model.reloadFlows()
        } else {
            pendingEnabled[flow.id] = nil
        }
    }

    private func delete(_ flow: Flow) async {
        let ok = await model.perform("\(flow.name) is verwijderd.") { try await $0.deleteFlow(flow.id) }
        if ok { await model.reloadFlows() }
        deleting = nil
    }
}

#Preview("Automatisering") {
    NavigationStack { FlowsView() }.previewHouse()
}

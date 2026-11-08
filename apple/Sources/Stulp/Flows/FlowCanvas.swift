import StulpKit
import SwiftUI

/// A Flow on a canvas, as Stulp has always drawn it: cards where you put them, lines from a card's
/// output to the next card's input. *Als* cards start, *En* cards may stop their branch, *Dan* cards
/// act; Stulp runs the lines breadth first in their order. What you see is exactly the graph that
/// is stored, so any Flow can be edited here, branches included.
///
/// Drag a card to move it. Drag from its output (the dot on the right) onto another card to connect
/// them, or tap the output and then the card: on a small phone that is easier than dragging. Tap a
/// line's middle to remove it. Pinch to zoom; double-tap empty canvas to put a card there.
struct FlowCanvasEditor: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The Flow as last saved; nil until a new one is saved for the first time.
    @State private var current: Flow?
    @State private var flow: Flow
    @State private var saved: Flow

    @State private var heights: [String: CGFloat] = [:]
    @State private var dragOffset: (node: String, offset: CGSize)?
    /// A line being drawn from an output, to the point under the finger.
    @State private var drawing: (from: String, to: CGPoint)?
    /// Tap-to-connect: the output tapped first; the next tapped card is the target.
    @State private var connectingFrom: String?
    @State private var scale: CGFloat = Self.initialScale
    @State private var pinchBase: CGFloat?

    @State private var adding: Adding?
    @State private var choosingKindAt: CGPoint?
    @State private var editing: String?
    @State private var confirmingCancel = false
    @State private var confirmingDelete = false
    @State private var busy = false

    private struct Adding: Identifiable {
        let type: FlowCardType
        let at: CGPoint?
        var id: String { type.rawValue }
    }

    static let cardWidth: CGFloat = 260
    /// The ports sit at a fixed height on the card, so lines never depend on a measured height.
    static let portY: CGFloat = 26
    static let initialScale: CGFloat = {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 0.8 : 1
        #else
        1
        #endif
    }()

    init(flow: Flow?) {
        let start = flow ?? Flow(name: "")
        _current = State(initialValue: flow)
        _flow = State(initialValue: start)
        _saved = State(initialValue: start)
    }

    private var dirty: Bool {
        flow.name != saved.name || flow.enabled != saved.enabled || flow.nodes != saved.nodes || flow.edges != saved.edges
    }

    private var trimmedName: String { flow.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            canvas
                .background(Color.canvasBackground.ignoresSafeArea())
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .overlay(alignment: .bottom) { hint }
                .navigationTitle(current == nil ? "Nieuwe flow" : (trimmedName.isEmpty ? "Flow" : trimmedName))
                .inlineTitle()
                .toolbar { toolbar }
                .interactiveDismissDisabled(dirty)
                .task { await model.ensureCards() }
                .sheet(item: $adding) { adding in
                    FlowCardPicker(type: adding.type, tokens: tokens) { step in
                        add(step, at: adding.at)
                    }
                    .environment(model)
                }
                .sheet(item: $editing.identified) { item in
                    if let node = flow.nodes.first(where: { $0.id == item.id }) {
                        NavigationStack {
                            FlowStepEditor(step: node.step, card: model.cards?.card(for: node.step), mode: .edit,
                                           tokens: tokens) { step in
                                update(item.id) { $0.step = step }
                                editing = nil
                            }
                        }
                        .macSheetSize(width: 520, height: 560)
                        .environment(model)
                    }
                }
                .confirmationDialog("Wat komt hier?", isPresented: Binding(
                    get: { choosingKindAt != nil }, set: { if !$0 { choosingKindAt = nil } }), titleVisibility: .visible
                ) {
                    ForEach(FlowCardType.allCases, id: \.self) { type in
                        Button(type.canvasTitle) { adding = Adding(type: type, at: choosingKindAt) }
                    }
                }
                .confirmationDialog("Wijzigingen weggooien?", isPresented: $confirmingCancel, titleVisibility: .visible) {
                    Button("Gooi weg", role: .destructive) { dismiss() }
                    Button("Ga door met bewerken", role: .cancel) {}
                }
                .confirmationDialog("\(trimmedName.isEmpty ? "Deze flow" : trimmedName) verwijderen?",
                                    isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Verwijder", role: .destructive) { Task { await delete() } }
                }
        }
        .macSheetSize(width: 1000, height: 720)
    }

    // MARK: - Canvas

    private var size: CGSize {
        let right = flow.nodes.map { $0.x + Self.cardWidth }.max() ?? 0
        let bottom = flow.nodes.map { $0.y + (heights[$0.id] ?? 110) }.max() ?? 0
        return CGSize(width: max(1400, right + 500), height: max(1000, bottom + 400))
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                DotGrid()
                    .frame(width: size.width, height: size.height)
                    .contentShape(.rect)
                    .gesture(SpatialTapGesture(count: 2).onEnded { choosingKindAt = $0.location })
                    .onTapGesture { connectingFrom = nil }
                lines
                ForEach(flow.nodes) { node in
                    card(node)
                }
                if let drawing, let from = flow.nodes.first(where: { $0.id == drawing.from }) {
                    Connector(from: output(of: from), to: drawing.to)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5]))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? scale
                    pinchBase = base
                    scale = min(1.6, max(0.35, base * value.magnification))
                }
                .onEnded { _ in pinchBase = nil })
        .overlay {
            if flow.nodes.isEmpty {
                ContentUnavailableView {
                    Label("Een leeg canvas", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Begin met een Als-kaart: wat zet deze flow in gang?")
                } actions: {
                    Button("Als-kaart toevoegen") { adding = Adding(type: .trigger, at: nil) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    static let space = "flowcanvas"

    private var lines: some View {
        ZStack(alignment: .topLeading) {
            ForEach(flow.edges) { edge in
                if let from = node(edge.from), let to = node(edge.to) {
                    let a = output(of: from), b = input(of: to)
                    Connector(from: a, to: b)
                        .stroke(to.step.cardType.color.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    Arrowhead(at: b)
                        .fill(to.step.cardType.color)
                    // The middle of the line: tap to remove it (a line itself is too thin to aim at).
                    Menu {
                        Button("Verwijder lijn", systemImage: "scissors", role: .destructive) {
                            flow.edges.removeAll { $0.id == edge.id }
                        }
                    } label: {
                        Circle()
                            .fill(.background)
                            .stroke(to.step.cardType.color, lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .frame(width: 32, height: 32)
                            .contentShape(.circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .position(Connector.midpoint(from: a, to: b))
                    .accessibilityLabel("Lijn van \(FlowText.sentence(from.step, model)) naar \(FlowText.sentence(to.step, model))")
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func card(_ node: FlowNode) -> some View {
        let offset = dragOffset?.node == node.id ? dragOffset!.offset : .zero
        let isTarget = connectingFrom.map { canConnect($0, node.id) } ?? false
        return FlowCardView(
            node: node,
            connecting: connectingFrom == node.id,
            isTarget: isTarget,
            onOutputTap: {
                connectingFrom = connectingFrom == node.id ? nil : node.id
            },
            outputDrag: DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { value in drawing = (node.id, value.location) }
                .onEnded { value in
                    drawing = nil
                    if let target = target(at: value.location), canConnect(node.id, target) {
                        connect(node.id, target)
                    }
                })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[node.id] = $0 }
            .offset(x: node.x + offset.width, y: node.y + offset.height)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { dragOffset = (node.id, $0.translation) }
                    .onEnded { value in
                        dragOffset = nil
                        update(node.id) {
                            $0.x = Self.snap(max(0, $0.x + value.translation.width))
                            $0.y = Self.snap(max(0, $0.y + value.translation.height))
                        }
                    })
            .onTapGesture {
                if let from = connectingFrom {
                    if canConnect(from, node.id) { connect(from, node.id) }
                    connectingFrom = nil
                } else {
                    editing = node.id
                }
            }
            .contextMenu { menu(node) }
            .zIndex(dragOffset?.node == node.id ? 1 : 0)
    }

    @ViewBuilder private func menu(_ node: FlowNode) -> some View {
        Button("Bewerk", systemImage: "slider.horizontal.3") { editing = node.id }
        Button("Verbind met…", systemImage: "arrow.right.circle") { connectingFrom = node.id }
        if node.step.cardType == .condition {
            Button(node.step.inverted ? "Niet meer omkeren" : "Omkeren (niet)", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") {
                update(node.id) { $0.step.inverted.toggle() }
            }
        }
        Button("Dupliceer", systemImage: "plus.square.on.square") {
            flow.nodes.append(FlowNode(x: node.x + 30, y: node.y + 30, step: node.step))
        }
        if flow.edges.contains(where: { $0.from == node.id || $0.to == node.id }) {
            Button("Haal lijnen weg", systemImage: "scissors") {
                flow.edges.removeAll { $0.from == node.id || $0.to == node.id }
            }
        }
        Divider()
        Button("Verwijder kaart", systemImage: "trash", role: .destructive) {
            flow.nodes.removeAll { $0.id == node.id }
            flow.edges.removeAll { $0.from == node.id || $0.to == node.id }
        }
    }

    // MARK: - Header, hint, toolbar

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Naam", text: $flow.name, prompt: Text("Naam van de flow"))
                .textFieldStyle(.plain)
                .font(.headline)
            Toggle("Actief", isOn: $flow.enabled)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder private var hint: some View {
        if let from = connectingFrom, let node = node(from) {
            Label("Tik op de kaart die na \"\(FlowText.sentence(node.step, model))\" komt", systemImage: "arrow.right.circle")
                .font(.callout)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding()
                .onTapGesture { connectingFrom = nil }
        } else if let warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding()
        }
    }

    /// Stulp saves a Flow that cannot run yet, but says so; here it is said before saving.
    private var warning: String? {
        guard !flow.nodes.isEmpty else { return nil }
        let triggers = flow.nodes.filter { $0.step.cardType == .trigger }
        if triggers.isEmpty { return "Zonder Als-kaart start deze flow nooit." }
        if !reachesAction(from: triggers.map(\.id)) { return "Verbind een Als-kaart met een Dan-kaart, anders doet de flow niets." }
        return nil
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Annuleer") {
                if dirty { confirmingCancel = true } else { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Bewaar") {
                Task { if await save() != nil { dismiss() } }
            }
            .disabled(trimmedName.isEmpty || busy || (!dirty && current != nil))
        }
        #if os(iOS)
        ToolbarItemGroup(placement: .bottomBar) { bottomItems }
        #else
        ToolbarItemGroup(placement: .primaryAction) { bottomItems }
        #endif
    }

    @ViewBuilder private var bottomItems: some View {
        Menu {
            ForEach(FlowCardType.allCases, id: \.self) { type in
                Button(type.canvasTitle, systemImage: type.symbol) { adding = Adding(type: type, at: nil) }
            }
        } label: {
            Label("Kaart toevoegen", systemImage: "plus")
        }
        Button("Pas in beeld", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { fit() }
        Spacer()
        Button("Test", systemImage: "play.fill") { Task { await test() } }
            .disabled(busy || flow.nodes.isEmpty)
        if current != nil {
            Menu {
                Button("Verwijder flow", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Label("Meer", systemImage: "ellipsis")
            }
        }
    }

    // MARK: - Geometry

    private func node(_ id: String) -> FlowNode? { flow.nodes.first { $0.id == id } }

    private func output(of node: FlowNode) -> CGPoint {
        CGPoint(x: node.x + Self.cardWidth, y: node.y + Self.portY)
    }

    private func input(of node: FlowNode) -> CGPoint {
        CGPoint(x: node.x, y: node.y + Self.portY)
    }

    private func target(at point: CGPoint) -> String? {
        flow.nodes.last { node in
            CGRect(x: node.x, y: node.y, width: Self.cardWidth, height: heights[node.id] ?? 110).insetBy(dx: -12, dy: -12).contains(point)
        }?.id
    }

    private static func snap(_ value: Double) -> Double { (value / 10).rounded() * 10 }

    /// Fits the cards into the window: the zoom at which the widest card row is visible.
    private func fit() {
        guard !flow.nodes.isEmpty else { scale = Self.initialScale; return }
        let right = (flow.nodes.map { $0.x + Self.cardWidth }.max() ?? 0) + 40
        #if os(iOS)
        let width = UIScreen.main.bounds.width
        #else
        let width: CGFloat = 1000
        #endif
        withAnimation(.snappy) { scale = min(1.2, max(0.35, width / right)) }
    }

    // MARK: - Editing the graph

    /// Stulp's own rules for a line: not to itself, never into an *Als* card, no duplicates, and no
    /// loop (a Flow runs from its triggers forward and must end).
    private func canConnect(_ from: String, _ to: String) -> Bool {
        guard from != to, let target = node(to), target.step.cardType != .trigger else { return false }
        if flow.edges.contains(where: { $0.from == from && $0.to == to }) { return false }
        // A loop: `from` can already be reached from `to`.
        var stack = [to]
        var seen: Set<String> = []
        while let id = stack.popLast() {
            if id == from { return false }
            guard seen.insert(id).inserted else { continue }
            stack.append(contentsOf: flow.edges.filter { $0.from == id }.map(\.to))
        }
        return true
    }

    private func connect(_ from: String, _ to: String) {
        flow.edges.append(FlowEdge(from: from, to: to))
    }

    private func reachesAction(from starts: [String]) -> Bool {
        var stack = starts
        var seen: Set<String> = []
        while let id = stack.popLast() {
            guard seen.insert(id).inserted else { continue }
            if node(id)?.step.cardType == .action { return true }
            stack.append(contentsOf: flow.edges.filter { $0.from == id }.map(\.to))
        }
        return false
    }

    private func update(_ id: String, _ change: (inout FlowNode) -> Void) {
        guard let index = flow.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&flow.nodes[index])
    }

    /// A new card goes where the canvas was double-tapped, or else in its kind's column below what
    /// is there. A card added while another card waits for a connection is connected to it.
    private func add(_ step: FlowStep, at point: CGPoint?) {
        let column: Double = switch step.cardType {
        case .trigger: 40
        case .condition: 380
        case .action: 720
        }
        let x = point.map { Self.snap(max(0, $0.x - Self.cardWidth / 2)) } ?? column
        let below = flow.nodes.filter { abs($0.x - x) < Self.cardWidth }.map { $0.y + (heights[$0.id] ?? 110) }.max()
        let y = point.map { Self.snap(max(0, $0.y - Self.portY)) } ?? Self.snap((below ?? 0) + 40)
        let node = FlowNode(x: x, y: y, step: step)
        flow.nodes.append(node)
        if let from = connectingFrom, canConnect(from, node.id) { connect(from, node.id) }
        connectingFrom = nil
    }

    /// Every trigger's tokens: a text field may use any of them.
    private var tokens: [FlowToken] {
        FlowText.tokens(of: flow.nodes.filter { $0.step.cardType == .trigger }, model)
    }

    // MARK: - Saving

    /// Saves what is on screen and answers the Flow as Stulp stored it.
    private func save() async -> Flow? {
        busy = true
        defer { busy = false }
        var outgoing = flow
        outgoing.name = trimmedName
        var stored: Flow?
        let base = current
        let ok = await model.perform { client in
            do {
                stored = try await client.saveFlow(outgoing)
            } catch StulpClientError.server(409, _) where base != nil {
                // Every run bumps the revision, so a Flow that fired (or was tested) while open
                // would refuse its own save. When only that changed, save onto the new revision;
                // when someone else changed the Flow itself, say so instead of overwriting it.
                guard let base, let fresh = try await client.flows().first(where: { $0.id == base.id }) else {
                    throw FlowEditorError.gone
                }
                guard fresh.name == base.name, fresh.enabled == base.enabled, fresh.nodes == base.nodes,
                      fresh.edges == base.edges
                else { throw FlowEditorError.changedElsewhere }
                outgoing.revision = fresh.revision
                stored = try await client.saveFlow(outgoing)
            }
        }
        guard ok, let stored else { return nil }
        current = stored
        flow = stored
        saved = stored
        await model.reloadFlows()
        return stored
    }

    private func test() async {
        var target = current
        if dirty || target == nil { target = await save() }
        guard let target else { return }
        await FlowRunner.run(target, model)
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

// MARK: - One card

private struct FlowCardView<Drag: Gesture>: View {
    @Environment(HomeModel.self) private var model
    let node: FlowNode
    let connecting: Bool
    let isTarget: Bool
    let onOutputTap: () -> Void
    let outputDrag: Drag

    private var type: FlowCardType { node.step.cardType }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(type.title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(type.color, in: .capsule)
                if node.step.inverted {
                    Text("NIET")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: .capsule)
                }
                Spacer(minLength: 0)
                Image(systemName: FlowText.symbol(node.step, model))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(type.color)
            }
            Text(FlowText.sentence(node.step, model))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = FlowText.subtitle(node.step, model) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(width: FlowCanvasEditor.cardWidth, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                .fill(type.color)
                .frame(height: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isTarget || connecting ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isTarget || connecting ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .overlay(alignment: .topLeading) {
            if type != .trigger {
                Circle()
                    .fill(.background)
                    .stroke(type.color, lineWidth: 2.5)
                    .frame(width: 14, height: 14)
                    .offset(x: -7, y: FlowCanvasEditor.portY - 7)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The output: big enough to hit with a finger, small to look at.
            Circle()
                .fill(connecting ? Color.accentColor : type.color)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.background, lineWidth: 2))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
                .offset(x: 20, y: FlowCanvasEditor.portY - 20)
                .onTapGesture(perform: onOutputTap)
                .highPriorityGesture(outputDrag)
                .accessibilityLabel("Uitgang")
                .accessibilityHint("Tik en kies daarna de kaart die hierna komt")
                .accessibilityAddTraits(.isButton)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Drawing

/// A line from an output to an input: leaves to the right, arrives from the left.
struct Connector: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        let bend = max(60, abs(to.x - from.x) / 2)
        var path = Path()
        path.move(to: from)
        path.addCurve(to: to, control1: CGPoint(x: from.x + bend, y: from.y), control2: CGPoint(x: to.x - bend, y: to.y))
        return path
    }

    /// The curve's point at t = ½, where the line's handle sits.
    static func midpoint(from: CGPoint, to: CGPoint) -> CGPoint {
        let bend = max(60, abs(to.x - from.x) / 2)
        let c1 = CGPoint(x: from.x + bend, y: from.y), c2 = CGPoint(x: to.x - bend, y: to.y)
        return CGPoint(x: (from.x + 3 * c1.x + 3 * c2.x + to.x) / 8, y: (from.y + 3 * c1.y + 3 * c2.y + to.y) / 8)
    }
}

private struct Arrowhead: Shape {
    let at: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: at.x - 1, y: at.y))
        path.addLine(to: CGPoint(x: at.x - 11, y: at.y - 6))
        path.addLine(to: CGPoint(x: at.x - 11, y: at.y + 6))
        path.closeSubpath()
        return path
    }
}

/// The dotted paper the cards lie on.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            var dots = Path()
            var y: CGFloat = step
            while y < size.height {
                var x: CGFloat = step
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(.secondary.opacity(0.35)))
        }
    }
}

extension Color {
    /// The canvas: the grouped background, so the white cards stand out in light and dark.
    static var canvasBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

extension FlowCardType {
    /// The colours Stulp has always used: ALS blue, EN amber, DAN green.
    var color: Color {
        switch self {
        case .trigger: .blue
        case .condition: .orange
        case .action: .green
        }
    }

    var symbol: String {
        switch self {
        case .trigger: "bolt.fill"
        case .condition: "questionmark.diamond.fill"
        case .action: "play.fill"
        }
    }

    var canvasTitle: String {
        switch self {
        case .trigger: "Als: wat de flow start"
        case .condition: "En: wat moet kloppen"
        case .action: "Dan: wat er gebeurt"
        }
    }
}

// MARK: - Running and errors

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

#Preview("Canvas") {
    FlowCanvasEditor(flow: nil).previewHouse()
}

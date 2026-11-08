import StulpKit
import SwiftUI

/// One accessory tile, as in Home: the symbol in a circle, the name, and its state in one word or
/// value. Tapping the symbol switches it (when it has one obvious switch); tapping the rest opens
/// its controls. A lit/open/playing tile turns bright, an unreachable one fades and says so.
struct DeviceTile: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    /// Scenes: the whole tile is the switch, as Home's scene tiles are.
    var tapToggles = false

    @State private var confirmingDelete = false
    @Environment(\.colorScheme) private var scheme

    private var active: Bool { DevicePresentation.isActive(device) }
    private var alarming: Bool { DevicePresentation.isAlarming(device) }
    private var toggle: Capability? { DevicePresentation.toggleCapability(device) }

    var body: some View {
        HStack(spacing: 10) {
            symbolButton
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(DevicePresentation.status(device))
                    .font(.subheadline)
                    .foregroundStyle(active ? Color.black.opacity(0.55) : Color.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(active ? Color.black : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 20, style: .continuous))
        .contentShape(.rect(cornerRadius: 20, style: .continuous))
        .opacity(device.available ? 1 : 0.55)
        .onTapGesture {
            if tapToggles, toggle != nil {
                Task { await model.toggle(device) }
            } else {
                model.openDevice = device.id
            }
        }
        .contextMenu { menu }
        .confirmationDialog("\(device.name) verwijderen?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Verwijder", role: .destructive) { Task { await model.delete(device) } }
        } message: {
            Text("Flows die dit apparaat gebruiken, werken daarna niet meer.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue(DevicePresentation.status(device))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(toggle != nil ? "Tik twee keer om te schakelen" : "Tik twee keer voor de bediening")
        .accessibilityAction { primaryAction() }
        .accessibilityAction(named: "Details") { model.openDevice = device.id }
        .animation(.snappy, value: active)
    }

    private var background: AnyShapeStyle {
        if alarming { return AnyShapeStyle(Color.red.opacity(0.25)) }
        if active { return AnyShapeStyle(Color.white.opacity(0.96)) }
        // In light mode a material vanishes into the grouped background; a grey fill keeps the
        // tile visible and the white "on" tiles standing out, as in Home.
        if scheme == .light { return AnyShapeStyle(Color.black.opacity(0.06)) }
        return AnyShapeStyle(.regularMaterial)
    }

    private var symbolButton: some View {
        Button(action: primaryAction) {
            Image(systemName: DevicePresentation.symbol(device))
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active || alarming ? Color.white : Color.secondary)
                .frame(width: 38, height: 38)
                .background(circle, in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var circle: AnyShapeStyle {
        if alarming { return AnyShapeStyle(Color.red) }
        if active { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.quaternary)
    }

    private func primaryAction() {
        if toggle != nil {
            Task { await model.toggle(device) }
        } else {
            model.openDevice = device.id
        }
    }

    @ViewBuilder private var menu: some View {
        if let toggle, !DevicePresentation.isStateless(toggle) {
            let words = DevicePresentation.words(toggle.base, toggle.bool ?? false)
            Button(words.action.capitalizedFirst, systemImage: "power") {
                Task { await model.toggle(device) }
            }
        } else if let toggle, DevicePresentation.isStateless(toggle) {
            Button("Activeer", systemImage: "play.fill") { Task { await model.toggle(device) } }
        }
        Button("Bediening en instellingen", systemImage: "slider.horizontal.3") {
            model.openDevice = device.id
        }
        do {
            // Scenes too: a scene put in a location shows under that location's scenes.
            Menu("Verplaats naar", systemImage: "arrow.right.square") {
                ForEach(model.roomTree, id: \.group.id) { entry in
                    Button(String(repeating: "   ", count: entry.depth) + entry.group.name) {
                        Task { await model.move(device, to: entry.group.id) }
                    }
                    .disabled(entry.group.id == device.groupId)
                }
                Divider()
                Button("Geen ruimte") { Task { await model.move(device, to: nil) } }
                    .disabled(device.groupId == nil)
            }
        }
        Divider()
        Button("Verwijder…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Tiles in a grid: two columns on an iPhone, as many as fit on an iPad or a Mac.
struct TileGrid: View {
    let devices: [Device]
    var tapToggles = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
    private var minimum: CGFloat { width == .regular ? 190 : 150 }
    #else
    private let minimum: CGFloat = 190
    #endif

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: 300), spacing: 10)], spacing: 10) {
            ForEach(devices) { device in
                DeviceTile(device: device, tapToggles: tapToggles || device.isScene)
            }
        }
    }
}

/// A section heading as Haas Foto's has its month: a small glass capsule. In a `LazyVStack` with
/// pinned section headers it stays at the top while its section scrolls by, until the next one
/// pushes it away, so where you are is always in sight; the title bar itself stays put.
struct SectionTitle<Destination: Hashable>: View {
    let title: String
    var subtitle: String?
    var destination: Destination?

    var body: some View {
        Group {
            if let destination {
                NavigationLink(value: destination) { label(chevron: true) }
                    .buttonStyle(.plain)
            } else {
                label(chevron: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .id(Self.scrollID(title))
    }

    private func label(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline.weight(.bold))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(chevron), in: .capsule)
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The scroll id of a heading (`-stulpScrollTo` in debug builds).
    static func scrollID(_ title: String) -> String { "section:\(title)" }
}

#Preview("Tegels") {
    let model = HomeModel(demo: true)
    ScrollView {
        TileGrid(devices: model.visibleDevices.sorted(by: HomeModel.tileOrder)).padding()
    }
    .environment(model)
}

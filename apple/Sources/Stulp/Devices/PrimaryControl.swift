import StulpKit
import SwiftUI

/// The one big control in the middle of a device's card, picked by what the device is: Home's
/// brightness and position sliders, the thermostat's temperature, the lock, the power pill.
struct PrimaryControl: View {
    enum Kind: Equatable {
        case none
        /// A lamp with a dim level (and usually `onoff`).
        case brightness
        /// Blinds or curtains with a position; `windowcoverings_state` buttons go with it.
        case position
        /// Only up/stop/down.
        case coveringState
        case thermostat
        case lock
        /// A plain switch: `onoff`, or `off_grid` (which asks first).
        case power(String)
        /// A stateless press: a scene button, `button`.
        case press(String)
        /// A sensor: its one reading, large.
        case reading(String)

        init(device: Device) {
            let has = { (id: String) in device[capability: id] != nil }
            let settable = { (id: String) in device[capability: id]?.setable == true }
            if device.isScene {
                if has("onoff") { self = .power("onoff") }
                else if has("button") { self = .press("button") }
                else { self = .none }
            } else if settable("dim") {
                self = .brightness
            } else if settable("windowcoverings_set") {
                self = .position
            } else if settable("windowcoverings_state") {
                self = .coveringState
            } else if settable("target_temperature") {
                self = .thermostat
            } else if settable("locked") {
                self = .lock
            } else if settable("onoff") {
                self = .power("onoff")
            } else if settable("off_grid") {
                self = .power("off_grid")
            } else if settable("button") {
                self = .press("button")
            } else if device.deviceClass == "camera" || device.deviceClass == "doorbell" {
                // The picture is a camera's main view; its sensors go in the rows.
                self = .none
            } else if let quick = DevicePresentation.quickCapability(device), !quick.setable, quick.value != nil {
                self = .reading(quick.id)
            } else {
                self = .none
            }
        }

        /// Capabilities this control already shows, so the rows below leave them out.
        func consumes(_ capability: Capability) -> Bool {
            switch self {
            case .none: false
            case .brightness: ["dim", "onoff"].contains(capability.id)
            case .position: ["windowcoverings_set", "windowcoverings_state"].contains(capability.id)
            case .coveringState: capability.id == "windowcoverings_state"
            case .thermostat: ["target_temperature", "measure_temperature", "thermostat_mode"].contains(capability.id)
            case .lock: capability.id == "locked"
            case .power(let id), .press(let id), .reading(let id): capability.id == id
            }
        }
    }

    @Environment(HomeModel.self) private var model
    let device: Device
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .none:
                EmptyView()
            case .brightness:
                BrightnessControl(device: device)
            case .position:
                PositionControl(device: device)
            case .coveringState:
                CoveringButtons(device: device)
            case .thermostat:
                ThermostatControl(device: device)
            case .lock:
                LockControl(device: device)
            case .power(let id):
                PowerControl(device: device, capabilityID: id)
            case .press(let id):
                PressControl(device: device, capabilityID: id)
            case .reading(let id):
                if let capability = device[capability: id] {
                    VStack(spacing: 4) {
                        // A number reads large, as Home's sensor cards do; words stay a title.
                        Text(DevicePresentation.short(capability))
                            .font(capability.isNumber
                                ? .system(size: 56, weight: .semibold, design: .rounded)
                                : .title.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(capability.base.hasPrefix("alarm_") && capability.bool == true ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                            .contentTransition(.numericText())
                        Text(capability.title).font(.headline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .disabled(!device.available)
        .opacity(device.available ? 1 : 0.5)
    }
}

// MARK: - Vertical slider

/// Home's tall rounded slider: the filled part is the value. It follows the finger and sends once,
/// when the finger lifts, so a drag is one request and not fifty.
struct VerticalSlider: View {
    /// 0...1.
    let value: Double
    let label: String
    var symbol: String?
    var onCommit: (Double) -> Void

    @State private var draft: Double?
    private let height: CGFloat = 300

    var body: some View {
        let shown = draft ?? value
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.quaternary)
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(height: max(0, min(1, shown)) * height)
                .animation(draft == nil ? .snappy : nil, value: shown)
            if let symbol {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(shown > 0.12 ? Color.white : Color.secondary)
                    .padding(.bottom, 22)
            }
        }
        .frame(width: 116, height: height)
        .clipShape(.rect(cornerRadius: 36, style: .continuous))
        .contentShape(.rect(cornerRadius: 36, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    draft = max(0, min(1, 1 - gesture.location.y / height))
                }
                .onEnded { _ in
                    if let draft { onCommit((draft * 100).rounded() / 100) }
                    draft = nil
                })
        .overlay(alignment: .top) {
            Text("\(Int((shown * 100).rounded()))%")
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .offset(y: -38)
        }
        .padding(.top, 40)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) procent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(1, value + 0.1))
            case .decrement: onCommit(max(0, value - 0.1))
            @unknown default: break
            }
        }
    }
}

private struct BrightnessControl: View {
    @Environment(HomeModel.self) private var model
    let device: Device

    var body: some View {
        let on = device[capability: "onoff"]?.bool ?? true
        let level = on ? (device[capability: "dim"]?.number ?? 0) : 0
        VStack(spacing: 18) {
            VerticalSlider(value: level, label: "Helderheid", symbol: "lightbulb.fill") { new in
                Task { await setLevel(new) }
            }
            if device[capability: "onoff"] != nil {
                Button {
                    Task { await model.set(device, "onoff", .bool(!on)) }
                } label: {
                    Label(on ? "Uitzetten" : "Aanzetten", systemImage: "power")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(.vertical, 8)
    }

    /// Home's rule: dragging to the bottom turns the lamp off, dragging up from off turns it on.
    private func setLevel(_ level: Double) async {
        let hasOnOff = device[capability: "onoff"] != nil
        if level <= 0, hasOnOff {
            await model.set(device, "onoff", false)
            return
        }
        if hasOnOff, device[capability: "onoff"]?.bool != true {
            await model.set(device, "onoff", true)
        }
        await model.set(device, "dim", .number(level))
    }
}

private struct PositionControl: View {
    @Environment(HomeModel.self) private var model
    let device: Device

    var body: some View {
        let position = device[capability: "windowcoverings_set"]?.number ?? 0
        VStack(spacing: 18) {
            VerticalSlider(value: position, label: "Positie", symbol: position > 0 ? "blinds.horizontal.open" : "blinds.horizontal.closed") { new in
                Task { await model.set(device, "windowcoverings_set", .number(new)) }
            }
            Text(position >= 0.99 ? "Open" : position <= 0.01 ? "Dicht" : "\(Int((position * 100).rounded()))% open")
                .font(.headline).foregroundStyle(.secondary)
            if device[capability: "windowcoverings_state"]?.setable == true {
                CoveringButtons(device: device)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Up, stop, down: the three words a screen understands.
private struct CoveringButtons: View {
    @Environment(HomeModel.self) private var model
    let device: Device

    var body: some View {
        let state = device[capability: "windowcoverings_state"]?.value?.string
        HStack(spacing: 14) {
            button("up", "Omhoog", "chevron.up", state)
            button("idle", "Stop", "stop.fill", state)
            button("down", "Omlaag", "chevron.down", state)
        }
        .padding(.vertical, 8)
    }

    private func button(_ value: String, _ title: String, _ symbol: String, _ state: String?) -> some View {
        Button {
            Task { await model.set(device, "windowcoverings_state", .string(value)) }
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(state == value ? Color.accentColor : nil)
        .accessibilityLabel(title)
    }
}

private struct ThermostatControl: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    @State private var draft: Double?
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        let target = device[capability: "target_temperature"]
        let step = target?.step.flatMap { $0 > 0 ? $0 : nil } ?? 0.5
        let low = target?.min ?? 5
        let high = target?.max ?? 35
        let value = draft ?? target?.number ?? low
        let units = target?.units ?? "°C"
        VStack(spacing: 14) {
            Text("Gewenst").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 22) {
                stepButton("minus", "Lager") { change(value - step, low, high) }
                    .disabled(value - step < low - 0.0001)
                Text(Self.format(value, units))
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: value))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: true, vertical: false)
                stepButton("plus", "Hoger") { change(value + step, low, high) }
                    .disabled(value + step > high + 0.0001)
            }
            if let current = device[capability: "measure_temperature"], current.value != nil {
                Label("Nu \(DevicePresentation.short(current))", systemImage: "thermometer.medium")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let mode = device[capability: "thermostat_mode"], !mode.values.isEmpty {
                ModePicker(device: device, capability: mode)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    /// Taps collect for a moment and go as one request: five taps up are one change.
    private func change(_ new: Double, _ low: Double, _ high: Double) {
        let clamped = min(high, max(low, (new * 100).rounded() / 100))
        withAnimation(.snappy) { draft = clamped }
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await model.set(device, "target_temperature", .number(clamped))
            draft = nil
        }
    }

    static func format(_ value: Double, _ units: String) -> String {
        let text = DevicePresentation.number(value, decimals: 1)
        return units == "°C" || units == "°F" ? "\(text)°" : "\(text) \(units)"
    }
}

private struct ModePicker: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capability: Capability

    var body: some View {
        let selection = Binding<String>(
            get: { capability.value?.text ?? "" },
            set: { new in Task { await model.set(device, capability.id, .string(new)) } })
        Picker(capability.title, selection: selection) {
            ForEach(capability.values) { value in
                Text(value.title).tag(value.id)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!capability.setable)
        .frame(maxWidth: 420)
    }
}

private struct LockControl: View {
    @Environment(HomeModel.self) private var model
    let device: Device

    var body: some View {
        let locked = device[capability: "locked"]?.bool ?? false
        VStack(spacing: 14) {
            Button {
                Task { await model.set(device, "locked", .bool(!locked)) }
            } label: {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(locked ? Color.white : Color.accentColor)
                    .frame(width: 140, height: 140)
                    .background(locked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(locked ? "Van het slot doen" : "Op slot doen")
            Text(locked ? "Op slot" : "Open").font(.title3.weight(.semibold))
            Text(locked ? "Tik om van het slot te doen" : "Tik om op slot te doen")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .animation(.snappy, value: locked)
    }
}

/// The large on/off pill. `off_grid` (a home battery's emergency power) asks first, in words that
/// say what happens: going off the grid is not a lamp.
private struct PowerControl: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capabilityID: String
    @State private var confirming = false

    var body: some View {
        let on = device[capability: capabilityID]?.bool ?? false
        let words = DevicePresentation.words(capabilityID, on)
        VStack(spacing: 14) {
            Button {
                if capabilityID == "off_grid" { confirming = true } else { flip(on) }
            } label: {
                ZStack(alignment: on ? .top : .bottom) {
                    Capsule().fill(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary))
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(8)
                        .overlay {
                            Image(systemName: "power")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                        }
                }
                .frame(width: 116, height: 220)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(device.name)
            .accessibilityValue(words.state)
            .accessibilityHint(words.action)
            Text(words.state.capitalizedFirst).font(.title3.weight(.semibold))
        }
        .padding(.vertical, 12)
        .animation(.snappy, value: on)
        .confirmationDialog(
            on ? "Opnieuw met het net verbinden?" : "Van het net schakelen?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(words.action.capitalizedFirst, role: on ? nil : .destructive) { flip(on) }
        } message: {
            Text(on
                ? "Het huis gaat terug op het stroomnet."
                : "Het huis loopt dan op noodstroom uit de batterij, los van het net. Alles wat meer vraagt dan de batterij levert, valt uit.")
        }
    }

    private func flip(_ on: Bool) {
        Task { await model.set(device, capabilityID, .bool(!on)) }
    }
}

private struct PressControl: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capabilityID: String
    @State private var pressed = 0

    var body: some View {
        VStack(spacing: 14) {
            Button {
                pressed += 1
                Task { await model.set(device, capabilityID, true) }
            } label: {
                Image(systemName: device.isScene ? "sparkles" : "hand.tap.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 140)
                    .background(Color.accentColor.gradient, in: .circle)
                    .symbolEffect(.bounce, value: pressed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(device.isScene ? "Activeer \(device.name)" : "Druk op \(device.name)")
            Text(device.isScene ? "Tik om te activeren" : "Tik om te drukken")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .sensoryFeedback(.success, trigger: pressed)
    }
}

import StulpKit
import SwiftUI

/// One capability as a form row: a value to read, or the standard control to change it. An unknown
/// value reads "—"; it is never shown as off or zero.
struct CapabilityRow: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capability: Capability

    var body: some View {
        Group {
            if !capability.setable {
                LabeledContent(capability.title) {
                    Text(DevicePresentation.display(capability))
                        .foregroundStyle(alarmStyle)
                        .contentTransition(.numericText())
                        .textSelection(.enabled)
                }
            } else if DevicePresentation.isStateless(capability) {
                pressButton
            } else if capability.base == "speaker_playing" {
                playPause
            } else if capability.isBoolean {
                Toggle(capability.title, isOn: Binding(
                    get: { capability.bool ?? false },
                    set: { new in Task { await model.set(device, capability.id, .bool(new)) } }))
            } else if capability.isEnum {
                Picker(capability.title, selection: Binding(
                    get: { capability.value?.text ?? "" },
                    set: { new in Task { await model.set(device, capability.id, enumValue(new)) } })
                ) {
                    if capability.value == nil { Text("—").tag("") }
                    ForEach(capability.values) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.menu)
            } else if capability.isNumber, let low = capability.min, let high = capability.max, high > low {
                NumberSlider(device: device, capability: capability, range: low...high)
            } else if capability.isNumber {
                NumberStepper(device: device, capability: capability)
            } else {
                TextValueRow(device: device, capability: capability)
            }
        }
        .disabled(!device.available)
    }

    /// An urgent alarm that is on reads red; any other active alarm orange.
    private var alarmStyle: AnyShapeStyle {
        guard capability.base.hasPrefix("alarm_"), capability.bool == true else { return AnyShapeStyle(.secondary) }
        return DevicePresentation.urgentAlarms.contains(capability.base) ? AnyShapeStyle(.red) : AnyShapeStyle(.orange)
    }

    /// An enum id goes back as the type it came in: a number stays a number.
    private func enumValue(_ id: String) -> JSONValue {
        if case .number = capability.value, let n = Double(id) { return .number(n) }
        if capability.type == "number", let n = Double(id) { return .number(n) }
        return .string(id)
    }

    private var pressButton: some View {
        let symbol = switch capability.base {
        case "speaker_prev": "backward.fill"
        case "speaker_next": "forward.fill"
        default: "hand.tap"
        }
        return Button {
            Task { await model.set(device, capability.id, true) }
        } label: {
            Label(capability.title, systemImage: symbol)
        }
    }

    /// A transport button says what pressing does: playing shows pause.
    private var playPause: some View {
        let playing = capability.bool ?? false
        return LabeledContent(capability.title) {
            Button {
                Task { await model.set(device, capability.id, .bool(!playing)) }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(playing ? "Pauzeer" : "Speel af")
        }
    }
}

/// A number with a range: the value above, a slider below that sends when it is let go.
private struct NumberSlider: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capability: Capability
    let range: ClosedRange<Double>
    @State private var draft: Double?

    var body: some View {
        let value = draft ?? capability.number ?? range.lowerBound
        let percent = range.lowerBound == 0 && range.upperBound == 1 && capability.units == nil
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(capability.title) {
                Text(capability.value == nil && draft == nil ? "—" : label(value, percent: percent))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Slider(
                value: Binding(get: { value }, set: { draft = $0 }),
                in: range,
                step: capability.step.flatMap { $0 > 0 && $0 < (range.upperBound - range.lowerBound) ? $0 : nil } ?? (percent ? 0.01 : 1)
            ) {
                Text(capability.title)
            } onEditingChanged: { editing in
                guard !editing, let draft else { return }
                Task {
                    await model.set(device, capability.id, .number(draft))
                    self.draft = nil
                }
            }
        }
    }

    private func label(_ value: Double, percent: Bool) -> String {
        if percent { return "\(Int((value * 100).rounded()))%" }
        var copy = capability
        copy.value = .number(value)
        return DevicePresentation.display(copy)
    }
}

/// A number without a range: a stepper by its step (or 1).
private struct NumberStepper: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capability: Capability

    var body: some View {
        let step = capability.step.flatMap { $0 > 0 ? $0 : nil } ?? 1
        Stepper {
            LabeledContent(capability.title, value: DevicePresentation.display(capability))
        } onIncrement: {
            send((capability.number ?? 0) + step)
        } onDecrement: {
            send((capability.number ?? 0) - step)
        }
    }

    private func send(_ value: Double) {
        Task { await model.set(device, capability.id, .number((value * 1000).rounded() / 1000)) }
    }
}

/// Free text: typed, and sent on return.
private struct TextValueRow: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let capability: Capability
    @State private var text = ""

    var body: some View {
        TextField(capability.title, text: $text, prompt: Text(capability.title))
            .onAppear { text = capability.value?.text ?? "" }
            .onChange(of: capability.value) { _, new in text = new?.text ?? "" }
            .onSubmit { Task { await model.set(device, capability.id, .string(text)) } }
            #if os(iOS)
            .submitLabel(.send)
            #endif
    }
}

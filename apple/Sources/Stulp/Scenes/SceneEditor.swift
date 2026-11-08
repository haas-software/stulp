import StulpKit
import SwiftUI

/// The scene being edited, shared by the editor and the screens it pushes (picking devices,
/// setting one device's states).
@MainActor
@Observable
final class SceneDraft {
    var name = ""
    /// `switch`: on applies and remembers, off restores. `button`: applies only.
    var kind = "switch"
    var states: [SceneState] = []

    func index(_ device: String, _ capability: String) -> Int? {
        states.firstIndex { $0.deviceId == device && $0.capabilityId == capability }
    }

    func value(_ device: String, _ capability: String) -> JSONValue? {
        index(device, capability).map { states[$0].value }
    }

    func set(_ device: String, _ capability: String, _ value: JSONValue?) {
        if let i = index(device, capability) {
            if let value { states[i].value = value } else { states.remove(at: i) }
        } else if let value {
            states.append(SceneState(deviceId: device, capabilityId: capability, value: value))
        }
    }

    func includes(_ device: String) -> Bool { states.contains { $0.deviceId == device } }

    func remove(device: String) { states.removeAll { $0.deviceId == device } }

    /// Takes over what the device does now. A capability whose value Stulp does not know (yet) is
    /// left as it was: a scene should never write a guess.
    @discardableResult
    func capture(_ device: Device) -> Int {
        var taken = 0
        for capability in SceneRules.writable(device) {
            guard let value = capability.value else { continue }
            set(device.id, capability.id, value)
            taken += 1
        }
        return taken
    }
}

/// Which states a scene may hold: settable and readable (a scene has to be able to put back what it
/// changed), not a button or a skip that has no state, and never another scene.
enum SceneRules {
    static func writable(_ device: Device) -> [Capability] {
        guard !device.isScene else { return [] }
        return device.orderedCapabilities.filter { $0.setable && $0.getable && !DevicePresentation.isStateless($0) }
    }

    /// The starting value of a state that is switched on without a known value.
    static func initial(_ capability: Capability) -> JSONValue {
        if let value = capability.value { return value }
        if capability.isBoolean { return true }
        if let first = capability.values.first { return .string(first.id) }
        if capability.isNumber { return .number(capability.min ?? 0) }
        return ""
    }

    /// "Aan", "60%", "Op slot": a state as a person reads it.
    static func describe(_ capability: Capability?, _ value: JSONValue) -> String {
        guard var capability else { return value.text }
        capability.value = value
        return DevicePresentation.display(capability)
    }
}

/// Home's scene editor: a name, switch or button, and the devices with the states they get.
struct SceneEditor: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil: a new scene.
    let sceneID: String?

    @State private var draft = SceneDraft()
    @State private var loaded = false
    @State private var saving = false
    @State private var deleting = false
    @State private var error: String?

    private var existing: StulpScene? { sceneID.flatMap { id in model.scenes.first { $0.id == id } } }
    /// A switch scene that is on remembers what it changed; Stulp refuses edits until it is off.
    private var locked: Bool { existing.map { !$0.isButton && $0.active } ?? false }

    var body: some View {
        Form {
            if locked {
                Section {
                    Label("Deze scène staat aan. Zet hem eerst uit om hem te wijzigen; uitzetten zet de vorige standen terug.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField("Naam", text: $draft.name, prompt: Text("Bijvoorbeeld Avond"))
                Picker("Soort", selection: $draft.kind) {
                    Text("Schakelaar").tag("switch")
                    Text("Knop").tag("button")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(draft.kind == "button"
                     ? "Een knop zet de gekozen standen en onthoudt niets. Handig voor ‘Alles uit’: die uitzetten zou alles weer aandoen."
                     : "Een schakelaar zet de gekozen standen bij aan, en zet bij uit terug wat er daarvoor was.")
            }
            devicesSection
            missingSection
            if !draft.states.isEmpty {
                Section {
                    Button("Neem de huidige standen over", systemImage: "arrow.down.doc") {
                        var taken = 0
                        for device in includedDevices { taken += draft.capture(device) }
                        model.notice = HomeModel.Notice(
                            text: taken == 0 ? "Er zijn nog geen standen bekend." : "Huidige standen overgenomen.", isError: taken == 0)
                    }
                } footer: {
                    Text("Zet de apparaten eerst zoals je ze in deze scène wilt, en neem dan in één keer over wat ze nu doen.")
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            if existing != nil {
                Section {
                    Button("Verwijder scène", role: .destructive) { deleting = true }
                        .disabled(locked)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(locked || saving)
        .navigationTitle(sceneID == nil ? "Nieuwe scène" : (draft.name.isEmpty ? "Scène" : draft.name))
        .inlineTitle()
        .toolbar {
            // Pushed from the add sheet the back button already cancels; in its own sheet it needs one.
            if !(sceneID == nil && model.addingDevice) {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { close() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Bewaar") { Task { await save() } }
                        .disabled(locked || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.states.isEmpty)
                }
            }
        }
        .confirmationDialog("Scène verwijderen?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Verwijder", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Flows die deze scène gebruiken, werken daarna niet meer.")
        }
        .task { await load() }
        .navigationDestination(for: SceneRoute.self) { route in
            switch route {
            case .pick: SceneDevicePicker(draft: draft)
            case .device(let id): SceneDeviceEditor(draft: draft, deviceID: id)
            }
        }
    }

    enum SceneRoute: Hashable {
        case pick
        case device(String)
    }

    // MARK: - Sections

    private var includedDevices: [Device] {
        let ids = Set(draft.states.map(\.deviceId))
        return SceneDevicePicker.ordered(model).flatMap(\.devices).filter { ids.contains($0.id) }
    }

    private var devicesSection: some View {
        let devices = includedDevices
        let tally: String = {
            let n = draft.states.count, m = Set(draft.states.map(\.deviceId)).count
            return "\(n == 1 ? "1 stand" : "\(n) standen") op \(m == 1 ? "1 apparaat" : "\(m) apparaten")"
        }()
        return Section {
            ForEach(devices) { device in
                NavigationLink(value: SceneRoute.device(device.id)) {
                    SceneDeviceRow(device: device, room: model.path(of: device.groupId), states: summary(device))
                }
                .swipeActions {
                    Button("Haal weg", role: .destructive) { draft.remove(device: device.id) }
                }
                .contextMenu {
                    Button("Neem huidige standen over", systemImage: "arrow.down.doc") { draft.capture(device) }
                    Button("Haal weg uit scène", systemImage: "minus.circle", role: .destructive) { draft.remove(device: device.id) }
                }
            }
            NavigationLink(value: SceneRoute.pick) {
                Label("Apparaten kiezen", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Apparaten")
        } footer: {
            if !draft.states.isEmpty { Text(tally) }
        }
    }

    private func summary(_ device: Device) -> String {
        draft.states.filter { $0.deviceId == device.id }.map { state in
            let capability = device[capability: state.capabilityId]
            return SceneRules.describe(capability, state.value)
        }
        .joined(separator: ", ")
    }

    /// States whose device or capability is gone: they do nothing, and are shown so they can go.
    @ViewBuilder private var missingSection: some View {
        let missing = draft.states.filter { state in
            model.devices[state.deviceId]?[capability: state.capabilityId] == nil
        }
        if !missing.isEmpty {
            Section {
                ForEach(missing, id: \.self) { state in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.devices[state.deviceId]?.name ?? "Verdwenen apparaat")
                            Text("\(state.capabilityId) → \(state.value.text)").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Haal weg", role: .destructive) { draft.set(state.deviceId, state.capabilityId, nil) }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Niet meer beschikbaar")
            } footer: {
                Text("Deze standen horen bij een apparaat of functie die er niet meer is.")
            }
        }
    }

    // MARK: - Work

    private func load() async {
        guard !loaded else { return }
        if sceneID != nil, existing == nil { await model.reloadScenes() }
        if let existing {
            draft.name = existing.name
            draft.kind = existing.kind
            draft.states = existing.states
        }
        loaded = true
    }

    private func save() async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        let scene = StulpScene(
            id: sceneID ?? "", name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: draft.kind, states: draft.states)
        do {
            let saved = try await client.saveScene(scene)
            await model.reloadScenes()
            await model.reloadDevices()
            model.notice = HomeModel.Notice(text: "Scène \(saved.name) is bewaard.", isError: false)
            close()
        } catch StulpClientError.server(409, _) {
            error = "Zet de scène eerst uit; een schakelaar die aan staat onthoudt wat hij veranderde."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let sceneID else { return }
        let ok = await model.perform("De scène is verwijderd.") { try await $0.deleteScene(sceneID) }
        if ok {
            await model.reloadScenes()
            await model.reloadDevices()
            if let device = model.openDevice, model.devices[device] == nil { model.openDevice = nil }
            close()
        }
    }

    /// From the add sheet a new scene closes the whole sheet; elsewhere only this editor.
    private func close() {
        if sceneID == nil, model.addingDevice {
            model.addingDevice = false
        } else {
            dismiss()
        }
    }
}

private struct SceneDeviceRow: View {
    let device: Device
    let room: String
    let states: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DevicePresentation.symbol(device))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text([room, states].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Picking devices

/// Every device that has states a scene can hold, room by room; a tick puts it in the scene with
/// what it does now.
struct SceneDevicePicker: View {
    @Environment(HomeModel.self) private var model
    let draft: SceneDraft
    @State private var search = ""

    struct Room: Identifiable {
        let id: String
        let title: String
        let devices: [Device]
    }

    static func ordered(_ model: HomeModel) -> [Room] {
        let eligible = model.devices.values.filter { !SceneRules.writable($0).isEmpty }
        var rooms: [Room] = []
        for entry in model.roomTree {
            let members = eligible.filter { $0.groupId == entry.group.id }.sorted(by: HomeModel.tileOrder)
            if !members.isEmpty { rooms.append(Room(id: entry.group.id, title: model.path(of: entry.group.id), devices: members)) }
        }
        let known = Set(model.groups.map(\.id))
        let loose = eligible.filter { $0.groupId.map { !known.contains($0) } ?? true }.sorted(by: HomeModel.tileOrder)
        if !loose.isEmpty { rooms.append(Room(id: "", title: "Zonder ruimte", devices: loose)) }
        return rooms
    }

    var body: some View {
        let rooms = Self.ordered(model).compactMap { room -> Room? in
            guard !search.isEmpty else { return room }
            let hits = room.devices.filter { $0.name.localizedCaseInsensitiveContains(search) }
            return hits.isEmpty ? nil : Room(id: room.id, title: room.title, devices: hits)
        }
        List {
            ForEach(rooms) { room in
                Section(room.title) {
                    ForEach(room.devices) { device in
                        Button {
                            toggle(device)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: DevicePresentation.symbol(device))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                    if !device.available {
                                        Text("Reageert niet · laatst bekende standen").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: draft.includes(device.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(draft.includes(device.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            }
                        }
                        .tint(.primary)
                        .accessibilityAddTraits(draft.includes(device.id) ? .isSelected : [])
                    }
                }
            }
        }
        .overlay {
            if rooms.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Zoek een apparaat")
        .navigationTitle("Apparaten kiezen")
        .inlineTitle()
    }

    private func toggle(_ device: Device) {
        if draft.includes(device.id) {
            draft.remove(device: device.id)
        } else if draft.capture(device) == 0 {
            // Nothing known yet: start with the first state switched on, so the device is in.
            if let first = SceneRules.writable(device).first {
                draft.set(device.id, first.id, SceneRules.initial(first))
            }
        }
    }
}

// MARK: - One device's states

struct SceneDeviceEditor: View {
    @Environment(HomeModel.self) private var model
    let draft: SceneDraft
    let deviceID: String

    var body: some View {
        if let device = model.devices[deviceID] {
            Form {
                ForEach(SceneRules.writable(device)) { capability in
                    Section {
                        Toggle(capability.title, isOn: Binding(
                            get: { draft.value(device.id, capability.id) != nil },
                            set: { on in draft.set(device.id, capability.id, on ? SceneRules.initial(capability) : nil) }))
                        if let value = draft.value(device.id, capability.id) {
                            SceneValueEditor(capability: capability, value: Binding(
                                get: { value },
                                set: { draft.set(device.id, capability.id, $0) }))
                        }
                    }
                }
                Section {
                    Button("Neem de huidige standen over", systemImage: "arrow.down.doc") {
                        if draft.capture(device) == 0 {
                            model.notice = HomeModel.Notice(text: "\(device.name) heeft nog geen bekende standen.", isError: true)
                        }
                    }
                } footer: {
                    Text(device.available ? "Wat \(device.name) nu doet, wordt de stand in deze scène." : "\(device.name) reageert nu niet; je ziet de laatst bekende standen.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(device.name)
            .inlineTitle()
        } else {
            ContentUnavailableView("Apparaat niet gevonden", systemImage: "questionmark.square.dashed")
        }
    }
}

/// The value one state gets: on/off, a choice, a percentage, a number or text.
struct SceneValueEditor: View {
    let capability: Capability
    @Binding var value: JSONValue

    var body: some View {
        if capability.isBoolean {
            let words = DevicePresentation.words(capability.base, true)
            Picker("Stand", selection: Binding(get: { value.bool ?? false }, set: { value = .bool($0) })) {
                Text(words.on.capitalizedFirst).tag(true)
                Text(words.off.capitalizedFirst).tag(false)
            }
            .pickerStyle(.segmented)
        } else if !capability.values.isEmpty {
            Picker("Stand", selection: Binding(get: { value.text }, set: { value = .string($0) })) {
                ForEach(capability.values) { option in Text(option.title).tag(option.id) }
            }
        } else if capability.isNumber, let min = capability.min, let max = capability.max, max > min {
            let percent = min == 0 && max == 1 && (capability.units ?? "").isEmpty
            let number = Binding(get: { value.number ?? min }, set: { value = .number($0) })
            VStack(alignment: .leading) {
                HStack {
                    Text("Stand")
                    Spacer()
                    Text(percent ? "\(Int((number.wrappedValue * 100).rounded()))%" : SceneRules.describe(capability, .number(number.wrappedValue)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let step = capability.step, step > 0, !percent {
                    Slider(value: number, in: min...max, step: step)
                } else {
                    Slider(value: number, in: min...max)
                }
            }
        } else if capability.isNumber {
            TextField("Waarde", value: Binding(get: { value.number ?? 0 }, set: { value = .number($0) }), format: .number)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        } else {
            TextField("Waarde", text: Binding(get: { value.text }, set: { value = .string($0) }))
        }
    }
}

#Preview("Nieuwe scène") {
    NavigationStack { SceneEditor(sceneID: nil) }.previewHouse()
}

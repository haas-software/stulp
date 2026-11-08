import StulpKit
import SwiftUI

/// A device's settings: its name, its room, and whatever its driver lets you set. One *Bewaar*
/// saves what changed and only that; the driver hears about exactly the keys that differ.
struct DeviceSettingsView: View {
    @Environment(HomeModel.self) private var model
    let deviceID: String

    var body: some View {
        if let device = model.devices[deviceID] {
            DeviceSettingsForm(device: device)
        } else {
            ContentUnavailableView("Apparaat niet gevonden", systemImage: "questionmark.square.dashed")
        }
    }
}

private struct DeviceSettingsForm: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: Device

    @State private var name = ""
    @State private var room: String?
    @State private var values: [String: JSONValue] = [:]
    @State private var specs: [SettingSpec] = []
    @State private var loadingDriver = true
    @State private var driverError: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var editingScene = false
    @State private var testing = false
    @State private var driverName: String?
    @State private var scenesLoaded = false

    /// A switch scene that is on holds a snapshot of what it changed; renaming or re-recording it
    /// then would leave that snapshot pointing at something else.
    private var sceneLocked: Bool {
        device.isScene && device[capability: "onoff"]?.bool == true
    }

    private var changedSettings: [String: JSONValue] {
        values.filter { key, value in original(key) != value }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var dirty: Bool {
        (trimmedName != device.name && !trimmedName.isEmpty) || room != device.groupId || !changedSettings.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Naam", text: $name, prompt: Text(device.name))
                    .disabled(sceneLocked)
                if !device.isScene {
                    Picker("Ruimte", selection: $room) {
                        Text("Geen ruimte").tag(String?.none)
                        ForEach(model.roomTree, id: \.group.id) { entry in
                            Text(String(repeating: "    ", count: entry.depth) + entry.group.name)
                                .tag(Optional(entry.group.id))
                        }
                    }
                }
            } footer: {
                if sceneLocked {
                    Text("Zet de scène eerst uit om de naam of de standen te wijzigen.")
                } else {
                    Text("De naam waaronder dit apparaat in Stulp en in je automatiseringen staat.")
                }
            }

            if device.isScene {
                SceneStatesSection(device: device, locked: sceneLocked, loaded: scenesLoaded) { editingScene = true }
            } else {
                driverSection
            }

            if device.isPhone {
                Section {
                    Button {
                        Task {
                            testing = true
                            await model.perform("Testmelding verstuurd naar \(device.name).") {
                                try await $0.testNotification(deviceId: device.id)
                            }
                            testing = false
                        }
                    } label: {
                        Label("Stuur testmelding", systemImage: "bell.badge")
                    }
                    .disabled(testing)
                } footer: {
                    Text("Een melding naar dit toestel, om te zien of meldingen aankomen.")
                }
            }

            Section("Over dit apparaat") {
                if let hardware = device.hardwareName, !hardware.isEmpty, hardware != device.name {
                    LabeledContent("Hardware", value: hardware)
                }
                if let manufacturer = device.manufacturer, !manufacturer.isEmpty, manufacturer != appName {
                    LabeledContent("Fabrikant", value: manufacturer)
                }
                LabeledContent("App", value: appName)
                if let driver = driverName ?? device.driverName, !device.isScene {
                    LabeledContent("Soort", value: driver)
                }
                LabeledContent("Status", value: device.available ? "Bereikbaar" : "Geen reactie")
                LabeledContent("ID") {
                    Text(device.id).font(.caption.monospaced()).textSelection(.enabled)
                }
            }

            Section {
                Button(device.isScene ? "Verwijder scène" : "Verwijder apparaat", role: .destructive) {
                    confirmingDelete = true
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text("Automatiseringen die dit apparaat gebruiken, werken daarna niet meer.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Instellingen")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Bewaar") { Task { await save() } }
                        .disabled(!dirty)
                }
            }
        }
        .confirmationDialog("\(device.name) verwijderen?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Verwijder", role: .destructive) { Task { await model.delete(device) } }
        } message: {
            Text(device.isScene
                ? "De scène verdwijnt, met de standen die erin zitten."
                : "Het apparaat verdwijnt uit Stulp. Je kunt het later opnieuw toevoegen.")
        }
        .sheet(isPresented: $editingScene) {
            NavigationStack { SceneEditor(sceneID: device.sceneId) }
                .environment(model)
        }
        .task(id: device.id) { await load() }
    }

    @ViewBuilder private var driverSection: some View {
        if loadingDriver {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if let driverError {
            Section {
                Label(driverError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } else if !specs.isEmpty {
            Section("Apparaatinstellingen") {
                ForEach(specs) { spec in
                    SettingField(spec: spec, value: binding(spec))
                }
            }
        }
    }

    private var appName: String {
        if device.isScene { return "Stulp" }
        return model.apps.first { $0.id == device.appId }?.name ?? device.appId
    }

    private func original(_ key: String) -> JSONValue {
        device.settings[key] ?? specs.first { $0.id == key }?.value ?? .null
    }

    private func binding(_ spec: SettingSpec) -> Binding<JSONValue> {
        Binding(
            get: { values[spec.id] ?? original(spec.id) },
            set: { values[spec.id] = $0 })
    }

    private func load() async {
        name = device.name
        room = device.groupId
        values = [:]
        if device.isScene {
            loadingDriver = false
            if model.scene(for: device) == nil { await model.reloadScenes() }
            scenesLoaded = true
            return
        }
        if model.apps.isEmpty { await model.reloadApps() }
        guard let client = model.client, let driverId = device.driverId else {
            loadingDriver = false
            return
        }
        do {
            let driver = try await client.driver(driverId)
            specs = driver.settings
            driverName = driver.name
            driverError = nil
        } catch {
            driverError = "De instellingen van dit apparaat zijn niet te laden: \(error.localizedDescription)"
        }
        loadingDriver = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if !trimmedName.isEmpty, trimmedName != device.name {
            await model.rename(device, to: String(trimmedName.prefix(100)))
        }
        if room != device.groupId, !device.isScene {
            await model.move(device, to: room)
        }
        let changed = changedSettings
        if !changed.isEmpty {
            let ok = await model.perform("Instellingen bewaard.") { client in
                _ = try await client.saveDeviceSettings(device.id, values: changed)
            }
            if ok { values = [:] }
            await model.reloadDevices()
        }
    }
}

/// One driver setting in the control its type asks for. The hint goes under it, the way a form
/// footer would, but per field.
private struct SettingField: View {
    let spec: SettingSpec
    @Binding var value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let hint = spec.hint, !hint.isEmpty {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch spec.type {
        case "checkbox":
            Toggle(spec.label, isOn: Binding(
                get: { value.bool ?? (value.string == "true") },
                set: { value = .bool($0) }))
        case "dropdown":
            Picker(spec.label, selection: Binding(
                get: { value.text },
                set: { value = .string($0) })
            ) {
                if !spec.values.contains(where: { $0.id == value.text }) { Text("—").tag(value.text) }
                ForEach(spec.values) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.menu)
        case "number":
            LabeledContent(spec.label) {
                TextField(spec.placeholder ?? spec.label, value: Binding(
                    get: { value.number ?? Double(value.text) },
                    set: { value = $0.map { .number($0) } ?? .null }),
                    format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        case "password":
            LabeledContent(spec.label) {
                SecureField(spec.placeholder ?? spec.label, text: text)
                    .multilineTextAlignment(.trailing)
            }
        default:
            LabeledContent(spec.label) {
                TextField(spec.placeholder ?? spec.label, text: text)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        }
    }

    private var text: Binding<String> {
        Binding(get: { value.text }, set: { value = .string($0) })
    }
}

/// What a scene sets, readable: "Staande lamp · Dimniveau → 60%".
private struct SceneStatesSection: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let locked: Bool
    let loaded: Bool
    let edit: () -> Void

    var body: some View {
        let scene = model.scene(for: device)
        Section {
            if let scene {
                LabeledContent("Soort", value: scene.isButton ? "Knop · past de standen toe" : "Schakelaar · uit zet de vorige standen terug")
                if scene.states.isEmpty {
                    Text("Nog geen standen gekozen.").foregroundStyle(.secondary)
                }
                ForEach(Array(scene.states.prefix(12).enumerated()), id: \.offset) { _, state in
                    stateRow(state)
                }
                if scene.states.count > 12 {
                    Text("en nog \(scene.states.count - 12)").foregroundStyle(.secondary)
                }
            } else if loaded {
                Text("De standen van deze scène zijn niet te laden.").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Button("Standen bewerken", systemImage: "slider.horizontal.3", action: edit)
                .disabled(locked || scene == nil)
        } header: {
            Text("Standen")
        } footer: {
            if locked { Text("Een schakelaar-scène die aan staat, onthoudt wat hij veranderde. Zet hem eerst uit.") }
        }
    }

    private func stateRow(_ state: SceneState) -> some View {
        let target = model.devices[state.deviceId]
        var capability = target?[capability: state.capabilityId]
        capability?.value = state.value
        return LabeledContent {
            Text(capability.map(DevicePresentation.display) ?? state.value.text)
        } label: {
            Text(target?.name ?? "Niet meer beschikbaar")
            Text(capability?.title ?? state.capabilityId)
        }
    }
}

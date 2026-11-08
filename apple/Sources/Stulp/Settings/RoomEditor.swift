import StulpKit
import SwiftUI

/// All rooms, one section per level: the top rooms first, then the rooms inside each room. Rooms
/// are reordered among their siblings only, which is all a tree's order means.
struct RoomsView: View {
    @Environment(HomeModel.self) private var model
    @State private var editing: IdentifiedString?
    @State private var adding = false

    var body: some View {
        List {
            if model.groups.isEmpty {
                ContentUnavailableView {
                    Label("Nog geen ruimtes", systemImage: "square.split.bottomrightquarter")
                } description: {
                    Text("Een ruimte groepeert apparaten, zoals in Woning. Ruimtes kunnen ook in elkaar liggen.")
                } actions: {
                    Button("Ruimte toevoegen") { adding = true }
                }
            }
            ForEach(parents, id: \.self) { parent in
                let siblings = model.children(of: parent)
                Section(parent.map { "In \(model.path(of: $0))" } ?? "Ruimtes") {
                    ForEach(siblings) { group in
                        Button {
                            editing = IdentifiedString(id: group.id)
                        } label: {
                            row(group)
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { from, to in
                        var order = siblings
                        order.move(fromOffsets: from, toOffset: to)
                        Task { await reorder(order) }
                    }
                }
            }
        }
        .navigationTitle("Ruimtes")
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Ruimte toevoegen", systemImage: "plus") { adding = true }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                if !model.groups.isEmpty { EditButton() }
            }
            #endif
        }
        .sheet(item: $editing) { item in
            NavigationStack { RoomEditor(groupID: item.id) }.environment(model)
        }
        .sheet(isPresented: $adding) {
            NavigationStack { RoomEditor(groupID: nil) }.environment(model)
        }
        .refreshable { await model.reloadDevices() }
    }

    /// The root plus every room that has rooms inside it, in tree order.
    private var parents: [String?] {
        var out: [String?] = model.children(of: nil).isEmpty ? [] : [nil]
        for entry in model.roomTree where !model.children(of: entry.group.id).isEmpty {
            out.append(entry.group.id)
        }
        return out
    }

    private func row(_ group: DeviceGroup) -> some View {
        HStack {
            Label(group.name, systemImage: RoomSymbol.name(for: group.name))
            Spacer()
            Text.count(model.allDevices(under: group.id).count, "apparaat", "apparaten")
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private func reorder(_ order: [DeviceGroup]) async {
        await model.perform { client in
            for (index, group) in order.enumerated() where group.sortOrder != Double((index + 1) * 10) {
                _ = try await client.updateGroup(group.id, ["sortOrder": .number(Double((index + 1) * 10))])
            }
        }
        await model.reloadDevices()
    }
}

/// One room: its name, where it lies, the order of its tiles, and removing it. With `groupID` nil
/// it creates a room. Presented in a NavigationStack sheet.
struct RoomEditor: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupID: String?

    @State private var name = ""
    @State private var parent: String?
    @State private var order: [Device] = []
    @State private var loaded = false
    @State private var working = false
    @State private var confirmingDelete = false

    private var existing: DeviceGroup? { model.group(groupID) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Naam", text: $name)
                    .submitLabel(.done)
            } footer: {
                if model.groups.contains(where: { $0.id != groupID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    Text("Er is al een ruimte met deze naam.").foregroundStyle(.red)
                }
            }
            Section {
                Picker("Binnen", selection: $parent) {
                    Text("Geen (bovenste niveau)").tag(String?.none)
                    ForEach(candidates, id: \.group.id) { entry in
                        Text(String(repeating: "   ", count: entry.depth) + entry.group.name).tag(Optional(entry.group.id))
                    }
                }
            } footer: {
                Text("Een ruimte binnen een andere ruimte, zoals een zithoek in de woonkamer.")
            }
            if existing != nil, !order.isEmpty {
                Section {
                    ForEach(order) { device in
                        Label(device.name, systemImage: DevicePresentation.symbol(device))
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Volgorde van de tegels")
                } footer: {
                    Text("Sleep een apparaat naar zijn plek in Thuis.")
                }
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                #endif
            }
            if existing != nil {
                Section {
                    Button("Verwijder ruimte", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("De apparaten en ruimtes erin gaan een niveau omhoog; er verdwijnt geen apparaat.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(existing == nil ? "Nieuwe ruimte" : (existing?.name ?? "Ruimte"))
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuleer") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else {
                    Button(existing == nil ? "Voeg toe" : "Bewaar") { Task { await save() } }
                        .disabled(trimmed.isEmpty || trimmed.count > 80)
                }
            }
        }
        .confirmationDialog("\(existing?.name ?? "Ruimte") verwijderen?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Verwijder ruimte", role: .destructive) { Task { await delete() } }
        } message: {
            Text("De apparaten en ruimtes erin gaan een niveau omhoog.")
        }
        .onAppear(perform: load)
        .macSheetSize(width: 480, height: 560)
    }

    /// Every room except this one and the rooms inside it: a room cannot lie inside itself.
    private var candidates: [(group: DeviceGroup, depth: Int)] {
        guard let groupID else { return model.roomTree }
        var excluded: Set<String> = [groupID]
        var changed = true
        while changed {
            changed = false
            for g in model.groups where g.parentId.map(excluded.contains) == true && !excluded.contains(g.id) {
                excluded.insert(g.id)
                changed = true
            }
        }
        return model.roomTree.filter { !excluded.contains($0.group.id) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = existing?.name ?? ""
        parent = existing?.parentId
        if let groupID { order = model.devices(in: groupID) }
    }

    private func save() async {
        working = true
        defer { working = false }
        let original = groupID.map { model.devices(in: $0).map(\.id) } ?? []
        let ok = await model.perform { client in
            if let groupID {
                _ = try await client.updateGroup(groupID, ["name": .string(trimmed), "parentId": .string(parent ?? "")])
                if order.map(\.id) != original {
                    try await client.orderDevices(group: groupID, ids: order.map(\.id))
                }
            } else {
                _ = try await client.createGroup(name: trimmed, parentId: parent)
            }
        }
        guard ok else { return }
        await model.reloadDevices()
        dismiss()
    }

    private func delete() async {
        guard let groupID else { return }
        working = true
        defer { working = false }
        let ok = await model.perform("De ruimte is verwijderd.") { try await $0.deleteGroup(groupID) }
        guard ok else { return }
        await model.reloadDevices()
        dismiss()
    }
}

#Preview("Ruimtes") {
    NavigationStack { RoomsView() }.previewHouse()
}

import StulpKit
import SwiftUI

/// Choosing a card, device first as Manage did and as Home does: rooms, then a device, then what
/// that device can do (its own cards first, the generic ones last). Cards that belong to no device
/// (time, sun, a notification, waiting) have their own section. Searching looks through every card.
/// Choosing pushes the card's fields; "Voeg toe" hands the finished step back.
struct FlowCardPicker: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let type: FlowCardType
    let tokens: [FlowToken]
    let onAdd: (FlowStep) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if let catalog = model.cards {
                    list(catalog.cards(type).filter(\.available))
                } else {
                    ProgressView("Kaarten laden…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(type.addTitle)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
            }
            .task { await model.ensureCards() }
        }
        .macSheetSize(width: 520, height: 620)
    }

    @ViewBuilder private func list(_ cards: [FlowCard]) -> some View {
        let deviceCards = cards.filter { $0.isDeviceCard && !$0.deviceIds.isEmpty }
        let free = cards.filter { !$0.isDeviceCard }
        List {
            if query.isEmpty {
                ForEach(rooms(deviceCards), id: \.0) { room, devices in
                    Section(room) {
                        ForEach(devices) { device in
                            NavigationLink {
                                DeviceCards(device: device, cards: deviceCards, tokens: tokens, onAdd: finish)
                            } label: {
                                DeviceRow(device: device, count: Self.cards(for: device, in: deviceCards).count)
                            }
                        }
                    }
                }
                if !free.isEmpty {
                    Section("Niet aan een apparaat gebonden") {
                        ForEach(free, id: \.key) { card in
                            cardLink(card, device: nil)
                        }
                    }
                }
                if deviceCards.isEmpty && free.isEmpty {
                    ContentUnavailableView("Geen kaarten", systemImage: "square.stack.3d.up.fill",
                                           description: Text("Geen enkele app biedt nu zo'n kaart aan."))
                }
            } else {
                let found = search(cards.filter { !$0.isDeviceCard || !$0.deviceIds.isEmpty })
                ForEach(byApp(found), id: \.0) { app, members in
                    Section(app) {
                        ForEach(members, id: \.key) { card in
                            cardLink(card, device: nil)
                        }
                    }
                }
                if found.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: "Zoek een kaart of apparaat")
    }

    private func cardLink(_ card: FlowCard, device: Device?) -> some View {
        NavigationLink {
            FlowStepEditor(step: FlowText.step(from: card, device: device, model), card: card, mode: .add, tokens: tokens, onDone: finish)
        } label: {
            CardRow(card: card)
        }
    }

    private func finish(_ step: FlowStep) {
        onAdd(step)
        dismiss()
    }

    // MARK: - Grouping

    static func cards(for device: Device, in cards: [FlowCard]) -> [FlowCard] {
        cards.filter { $0.deviceIds.contains(device.id) }
    }

    private func rooms(_ cards: [FlowCard]) -> [(String, [Device])] {
        let ids = Set(cards.flatMap(\.deviceIds))
        let devices = model.devices.values.filter { ids.contains($0.id) }.sorted(by: HomeModel.tileOrder)
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

    /// A card matches on its title, its app, or the name of a device it belongs to.
    private func search(_ cards: [FlowCard]) -> [FlowCard] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return cards.filter { card in
            card.title.localizedStandardContains(needle) || card.appName.localizedStandardContains(needle)
                || card.deviceIds.contains { model.devices[$0]?.name.localizedStandardContains(needle) == true }
        }
    }

    private func byApp(_ cards: [FlowCard]) -> [(String, [FlowCard])] {
        let names = Dictionary(grouping: cards) { $0.appId == "stulp" ? "Stulp" : $0.appName }
        return names.keys.sorted { a, b in
            if a == "Stulp" { return b != "Stulp" }
            if b == "Stulp" { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, names[$0] ?? []) }
    }
}

/// What one device can do, its own cards first and the generic capability cards last.
private struct DeviceCards: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    let cards: [FlowCard]
    let tokens: [FlowToken]
    let onAdd: (FlowStep) -> Void

    var body: some View {
        let mine = FlowCardPicker.cards(for: device, in: cards)
        let specific = mine.filter { !$0.isGeneric }
        let generic = mine.filter(\.isGeneric)
        List {
            Section("\(device.name) kan") {
                ForEach(specific, id: \.key) { link($0) }
            }
            if !generic.isEmpty {
                Section("Algemeen") {
                    ForEach(generic, id: \.key) { link($0) }
                }
            }
        }
        .navigationTitle(device.name)
        .inlineTitle()
    }

    private func link(_ card: FlowCard) -> some View {
        NavigationLink {
            FlowStepEditor(step: FlowText.step(from: card, device: device, model), card: card, mode: .add, tokens: tokens, onDone: onAdd)
        } label: {
            CardRow(card: card)
        }
    }
}

private struct DeviceRow: View {
    let device: Device
    let count: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                Text.count(count, "mogelijkheid", "mogelijkheden")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: DevicePresentation.symbol(device)).foregroundStyle(.tint)
        }
    }
}

/// A card in a list: its title with the unfilled `[[blanks]]` read as "…".
private struct CardRow: View {
    let card: FlowCard

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.title(card))
            if let hint = card.hint, !hint.isEmpty {
                Text(hint).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    static func title(_ card: FlowCard) -> String {
        guard let formatted = card.titleFormatted, !formatted.isEmpty else { return card.title }
        var text = formatted
        // `!{{plain|inverted}}` reads its plain half until someone inverts the card.
        while let open = text.range(of: "!{{"), let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) {
            let inner = text[open.upperBound..<close.lowerBound]
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: inner.split(separator: "|").first.map(String.init) ?? "")
        }
        for argument in card.args {
            text = text.replacingOccurrences(of: "[[\(argument.name)]]", with: argument.type == "device" ? "apparaat" : "…")
        }
        return text
    }
}

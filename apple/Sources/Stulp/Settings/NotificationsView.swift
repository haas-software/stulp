import StulpKit
import SwiftUI

/// Stulp's notification history: what apps and Flows wrote down, newest first. The phone's own
/// pushes are separate; this is what Stulp keeps.
struct NotificationsView: View {
    @Environment(HomeModel.self) private var model
    @State private var loading = true
    @State private var confirmingClear = false

    private var items: [StulpNotification] {
        model.notifications.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
                    .swipeActions {
                        Button("Wis", systemImage: "trash", role: .destructive) { Task { await delete([item]) } }
                    }
                    .contextMenu {
                        Button("Wis", systemImage: "trash", role: .destructive) { Task { await delete([item]) } }
                    }
            }
        }
        .overlay {
            if items.isEmpty {
                if loading && model.client != nil {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("Geen meldingen", systemImage: "bell.slash")
                    } description: {
                        Text("Meldingen van apps en Flows verschijnen hier.")
                    }
                }
            }
        }
        .navigationTitle("Meldingen")
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Wis alles", systemImage: "trash") { confirmingClear = true }
                    .disabled(items.isEmpty)
            }
        }
        .confirmationDialog("Alle meldingen wissen?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Wis alles", role: .destructive) { Task { await delete(items) } }
        }
        .task {
            if model.apps.isEmpty { await model.reloadApps() }
            await model.reloadNotifications()
            loading = false
        }
        .refreshable { await model.reloadNotifications() }
    }

    private func row(_ item: StulpNotification) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.excerpt)
            HStack(spacing: 4) {
                Text(source(item))
                if let date = item.date {
                    Text("·")
                    Text(date, format: .relative(presentation: .named))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The app's name; Stulp's own Matter app reads as Stulp.
    private func source(_ item: StulpNotification) -> String {
        guard let app = item.appId, !app.isEmpty, app != "com.stulp.matter" else { return "Stulp" }
        return model.apps.first { $0.id == app }?.name ?? app
    }

    private func delete(_ list: [StulpNotification]) async {
        await model.perform { client in
            for item in list { try await client.deleteNotification(item.id) }
        }
        await model.reloadNotifications()
    }
}

#Preview("Meldingen") {
    NavigationStack { NotificationsView() }.previewHouse()
}

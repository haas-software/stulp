import StulpKit
import SwiftUI

/// The apps Stulp runs, as Settings lists apps: apps that announced themselves and wait to be
/// accepted first, then the installed ones. An app is accepted, not fetched: it arrives because
/// someone placed it, and accepting it is the one step a program cannot take for itself.
struct AppsView: View {
    @Environment(HomeModel.self) private var model
    @State private var loaded = false

    var body: some View {
        let offered = model.apps.filter(\.offered)
        let installed = model.apps.filter { !$0.offered }
        List {
            if !offered.isEmpty {
                Section {
                    ForEach(offered) { app in OfferedAppRow(app: app) }
                } header: {
                    Text("Aangemeld")
                } footer: {
                    Text("Deze apps hebben zich bij Stulp gemeld en draaien pas als je ze installeert.")
                }
            }
            Section {
                ForEach(installed) { app in
                    NavigationLink {
                        AppDetailView(appID: app.id)
                    } label: {
                        AppRow(app: app)
                    }
                }
            } header: {
                if !offered.isEmpty { Text("Geïnstalleerd") }
            }
        }
        .overlay {
            if !loaded && model.apps.isEmpty {
                ProgressView()
            } else if model.apps.isEmpty {
                ContentUnavailableView {
                    Label("Geen apps", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Een app meldt zich zelf bij Stulp zodra hij draait.")
                }
            }
        }
        .navigationTitle("Apps")
        .refreshable { await model.reloadApps() }
        .task {
            await model.reloadApps()
            loaded = true
        }
    }
}

/// Name, version and how it is doing, with the symbol tinted by state.
struct AppRow: View {
    let app: StulpAppInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(app.enabled && !app.crashed ? Color.accentColor : Color.gray, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(AppStatus.line(app))
                    .font(.footnote)
                    .foregroundStyle(app.crashed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

enum AppStatus {
    /// "1.4.0 · Actief", "Gecrasht · herstart om 14:05".
    static func line(_ app: StulpAppInfo) -> String {
        var parts: [String] = []
        if let version = app.version, !version.isEmpty { parts.append(version) }
        parts.append(state(app))
        return parts.joined(separator: " · ")
    }

    static func state(_ app: StulpAppInfo) -> String {
        if app.offered { return "Wacht op installatie" }
        if !app.enabled { return "Uit" }
        if let retry = app.retryAt.flatMap(StulpDate.parse) {
            return "Automatische herstart om \(retry.formatted(date: .omitted, time: .shortened))"
        }
        if app.crashed { return "Gecrasht" }
        switch app.state {
        case "running": return "Actief"
        case "starting": return "Start…"
        case "stopped": return "Gestopt"
        case nil, "": return "Onbekend"
        case let other?: return other.capitalizedFirst
        }
    }
}

private struct OfferedAppRow: View {
    @Environment(HomeModel.self) private var model
    let app: StulpAppInfo
    @State private var refusing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppRow(app: app)
            HStack {
                Button("Installeer") {
                    Task {
                        await model.perform("\(app.name) is geïnstalleerd.") { try await $0.installApp(app.id) }
                        await model.reloadApps()
                    }
                }
                .buttonStyle(.glassProminent)
                Button("Weiger", role: .destructive) { refusing = true }
                    .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
        .confirmationDialog("\(app.name) weigeren?", isPresented: $refusing, titleVisibility: .visible) {
            Button("Weiger", role: .destructive) {
                Task {
                    await model.perform { try await $0.removeApp(app.id) }
                    await model.reloadApps()
                }
            }
        } message: {
            Text("De app wordt niet gestart. Meldt hij zich opnieuw, dan staat hij hier weer.")
        }
    }
}

/// One installed app: on or off, restart, its own settings page, remove.
struct AppDetailView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let appID: String
    @State private var removing = false
    @State private var busy = false

    var body: some View {
        if let app = model.apps.first(where: { $0.id == appID }) {
            form(app)
        } else {
            ContentUnavailableView("App niet gevonden", systemImage: "puzzlepiece.extension")
        }
    }

    private func form(_ app: StulpAppInfo) -> some View {
        Form {
            Section {
                AppRow(app: app)
                if app.crashed, let message = app.crashedMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                LabeledContent("Id") {
                    Text(app.id).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                Toggle("Ingeschakeld", isOn: Binding(
                    get: { app.enabled },
                    set: { on in
                        Task {
                            busy = true
                            await model.perform { try await $0.setAppEnabled(app.id, on) }
                            await model.reloadApps()
                            busy = false
                        }
                    }))
                .disabled(busy)
                if app.enabled {
                    Button("Herstart", systemImage: "arrow.clockwise") {
                        Task {
                            busy = true
                            await model.perform("\(app.name) herstart.") { try await $0.restartApp(app.id) }
                            await model.reloadApps()
                            busy = false
                        }
                    }
                    .disabled(busy)
                }
            } footer: {
                Text("Een app die uit staat draait niet; zijn apparaten blijven bestaan maar reageren niet.")
            }
            if app.hasSettings {
                Section {
                    NavigationLink {
                        AppSettingsPage(app: app)
                    } label: {
                        Label("Instellingen van \(app.name)", systemImage: "slider.horizontal.3")
                    }
                    .disabled(!app.enabled)
                } footer: {
                    if !app.enabled { Text("Schakel de app in om zijn instellingen te openen.") }
                }
            }
            Section {
                Button("Verwijder app…", systemImage: "trash", role: .destructive) { removing = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.name)
        .inlineTitle()
        .task { if model.flows.isEmpty { await model.reloadFlows() } }
        .confirmationDialog("\(app.name) verwijderen?", isPresented: $removing, titleVisibility: .visible) {
            Button("Verwijder", role: .destructive) {
                Task {
                    let ok = await model.perform("\(app.name) is verwijderd.") { try await $0.removeApp(app.id) }
                    if ok {
                        await model.reloadApps()
                        await model.reloadDevices()
                        dismiss()
                    }
                }
            }
        } message: {
            Text(impact(app))
        }
    }

    /// What disappears with the app: its devices go, Flows that need it are switched off (with a
    /// reason), not deleted.
    private func impact(_ app: StulpAppInfo) -> String {
        let devices = model.devices.values.filter { $0.appId == app.id }
        let ids = Set(devices.map(\.id))
        let flows = model.flows.filter { flow in
            flow.nodes.contains { $0.step.appId == app.id || $0.step.deviceId.map(ids.contains) == true }
        }
        var lines: [String] = []
        switch devices.count {
        case 0: lines.append("Er verdwijnen geen apparaten.")
        case 1: lines.append("1 apparaat verdwijnt, met zijn instellingen.")
        default: lines.append("\(devices.count) apparaten verdwijnen, met hun instellingen.")
        }
        switch flows.count {
        case 0: break
        case 1: lines.append("1 flow die de app gebruikt wordt uitgezet.")
        default: lines.append("\(flows.count) flows die de app gebruiken worden uitgezet.")
        }
        return lines.joined(separator: " ")
    }
}

/// The app's own settings page, full size.
struct AppSettingsPage: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: StulpAppInfo
    @State private var bridge: AppPageBridge?

    var body: some View {
        Group {
            if let bridge {
                AppPageView(bridge: bridge, path: "/app-ui/\(app.id)/settings/")
            } else {
                ContentUnavailableView("Niet verbonden", systemImage: "wifi.exclamationmark")
            }
        }
        .navigationTitle(bridge?.title ?? app.name)
        .inlineTitle()
        .task {
            if bridge == nil, let client = model.client {
                let made = AppPageBridge(client: client, appId: app.id)
                // A settings page that closes itself (after OAuth, say) goes back to the app.
                made.onClose = { dismiss() }
                bridge = made
            }
        }
        #if os(iOS)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
    }
}

#Preview("Apps") {
    NavigationStack { AppsView() }.previewHouse()
}

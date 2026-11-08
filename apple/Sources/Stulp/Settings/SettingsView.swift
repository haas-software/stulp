import StulpKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings: the connection, what this iPhone does for Stulp (its phone device, home/away, the
/// charger, notifications), Stulp's own switches, rooms, apps, backup and about. iOS shows it as a
/// tab; the Mac as the Settings window (⌘,).
struct SettingsView: View {
    @Environment(HomeModel.self) private var model
    /// Debug: `-stulpSettings rooms|notifications` opens that page at launch (for screenshots).
    @State private var debugPage: String? = {
        #if DEBUG
        UserDefaults.standard.string(forKey: "stulpSettings")
        #else
        nil
        #endif
    }()

    var body: some View {
        #if os(macOS)
        NavigationStack { form }
        #else
        form
        #endif
    }

    private var form: some View {
        Form {
            if model.connection != nil || model.demo {
                ConnectionSection()
                #if os(iOS)
                PhoneSections()
                #endif
                StulpSection()
                Section {
                    NavigationLink {
                        RoomsView()
                    } label: {
                        Label("Ruimtes", systemImage: "square.split.bottomrightquarter")
                    }
                    #if os(iOS)
                    NavigationLink {
                        AppsView()
                    } label: {
                        Label("Apps", systemImage: "puzzlepiece.extension")
                    }
                    #endif
                }
                BackupSection()
            } else {
                Section {
                    ConnectionFields { _ in }
                }
            }
            AboutSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Instellingen")
        .navigationDestination(isPresented: Binding(get: { debugPage != nil }, set: { if !$0 { debugPage = nil } })) {
            if debugPage == "notifications" { NotificationsView() } else { RoomsView() }
        }
    }
}

// MARK: - Connection

private struct ConnectionSection: View {
    @Environment(HomeModel.self) private var model
    @State private var changing = false
    @State private var confirmingDisconnect = false

    var body: some View {
        Section {
            LabeledContent("Adres", value: model.connection?.displayAddress ?? "Demo")
            LabeledContent("Stulp", value: model.version.isEmpty ? "–" : model.version)
            LabeledContent("Status") {
                switch model.phase {
                case .live: Label("Live", systemImage: "circle.fill").foregroundStyle(.green)
                case .connecting: Text("Verbinden…").foregroundStyle(.secondary)
                case .offline(let reason): Text(reason).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                }
            }
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            Button("Verbinding wijzigen…") { changing = true }
            Button("Verbreek verbinding", role: .destructive) { confirmingDisconnect = true }
        } header: {
            Text("Verbinding")
        }
        .sheet(isPresented: $changing) {
            ConnectionSheet().environment(model)
        }
        .confirmationDialog("Verbinding met Stulp verbreken?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Verbreek verbinding", role: .destructive) { model.disconnect() }
        } message: {
            Text("De app vergeet het adres, de sleutel, het gekozen toestel en de thuislocatie. In Stulp zelf verandert niets.")
        }
    }
}

// MARK: - This phone (iOS)

#if os(iOS)
/// What this iPhone does for Stulp. It is a phone device of the notifications app: Flows aim
/// notifications at it, and it reports home/away and the charger on it.
private struct PhoneSections: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var presence = StulpPresenceSettings.load()
    @State private var phones: [Device] = []
    @State private var newName = ""
    @State private var working = false
    private var monitor: PresenceMonitor { .shared }
    private var push: PushCenter { .shared }

    var body: some View {
        Group {
            phoneSection
            presenceSection
            chargerSection
            notificationSection
        }
        .task { await loadPhones() }
    }

    private var phoneSection: some View {
        Section {
            if let presence {
                LabeledContent("Dit toestel", value: presence.phoneName)
            }
            if !phones.isEmpty {
                Menu {
                    ForEach(phones) { phone in
                        Button(phone.name) { choose(phone) }
                    }
                } label: {
                    Label(presence == nil ? "Kies een bestaand toestel" : "Kies een ander toestel", systemImage: "iphone")
                }
            }
            HStack {
                TextField("Bijvoorbeeld iPhone van Daphne", text: $newName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { Task { await register() } }
                Button("Registreer") { Task { await register() } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        } header: {
            Text("Dit toestel in Stulp")
        } footer: {
            Text("Elke telefoon is een eigen apparaat in Stulp. Registreer dit toestel, of kies er een die al bestaat.")
        }
    }

    private var presenceSection: some View {
        Section {
            permissionRow
            Button {
                Task { await setHome() }
            } label: {
                Label(presence?.latitude == nil ? "Stel thuis in op deze plek" : "Zet thuis opnieuw op deze plek",
                      systemImage: "mappin.and.ellipse")
                    .foregroundStyle(presence == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .disabled(presence == nil || working)
            if !monitor.lastEvent.isEmpty {
                LabeledContent("Laatst gemeld", value: monitor.lastEvent)
            }
            HStack {
                Button("Meld thuis") { Task { await report(home: true) } }
                Spacer()
                Button("Meld weg") { Task { await report(home: false) } }
            }
            .buttonStyle(.borderless)
            .disabled(presence == nil)
        } header: {
            Text("Thuis en weg")
        } footer: {
            Text("Binnen 300 m meldt thuis, zodat het alarm eraf kan voordat je bij de deur bent; 150 m verlaten meldt weg. iOS doet dat ook als de app dicht is.")
        }
    }

    /// Without "Always" iOS does not wake the app for home/away; that has to be visible.
    @ViewBuilder private var permissionRow: some View {
        switch monitor.authorization {
        case .authorizedAlways:
            Label("Locatie: altijd", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button {
                monitor.requestAlways()
            } label: {
                Label("Sta locatie toe", systemImage: "location.circle")
            }
        default:
            Button {
                openURL(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label("Zet locatie op Altijd in Instellingen", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var chargerSection: some View {
        Section {
            Button {
                openURL(URL(string: "shortcuts://")!)
            } label: {
                Label("Open Opdrachten", systemImage: "square.2.layers.3d")
            }
        } header: {
            Text("Aan de lader")
        } footer: {
            Text("Maak bij Automatisering twee automatiseringen op Lader: ‘Is aangesloten’ en ‘Is losgekoppeld’, met de actie Meld lader aan Stulp, aan of uit. Zet ze op Direct uitvoeren.")
        }
    }

    private var notificationSection: some View {
        Section {
            switch push.status {
            case .authorized, .provisional, .ephemeral:
                Label(push.registered ? "Meldingen staan aan" : "Toegestaan, nog niet bij Stulp",
                      systemImage: push.registered ? "checkmark.circle.fill" : "bell.badge")
                    .foregroundStyle(push.registered ? .green : .orange)
            case .denied:
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("Zet meldingen aan in Instellingen", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            default:
                Button {
                    Task { await push.request() }
                } label: {
                    Label("Sta meldingen toe", systemImage: "bell.badge")
                }
                .disabled(presence == nil)
            }
            if !push.lastError.isEmpty {
                Text(push.lastError).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Meldingen")
        } footer: {
            Text("Stulp stuurt meldingen rechtstreeks naar deze app: gewoon, dringend (door Focus heen) of kritiek, met camerabeeld. Tik op een melding met camerabeeld en de camera gaat open. Kies eerst welk toestel dit is.")
        }
    }

    // MARK: Actions

    private func loadPhones() async {
        guard let client = model.client else { return }
        do { phones = try await client.phones() } catch { model.report(error) }
    }

    private func register() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let client = model.client else { return }
        working = true
        defer { working = false }
        do {
            let phone = try await client.registerPhone(name: name, installation: StulpInstallation.id)
            newName = ""
            choose(phone)
            await loadPhones()
        } catch {
            model.report(error)
        }
    }

    private func choose(_ phone: Device) {
        var settings = presence ?? StulpPresenceSettings(phoneId: phone.id, phoneName: phone.name)
        settings.phoneId = phone.id
        settings.phoneName = phone.name
        do {
            try settings.save()
            presence = settings
            model.notice = .init(text: "Dit toestel is \(phone.name) in Stulp.", isError: false)
            Task { await PushCenter.shared.send() }
        } catch {
            model.report(error)
        }
    }

    private func setHome() async {
        working = true
        defer { working = false }
        do {
            try await monitor.setHome()
            presence = StulpPresenceSettings.load()
            model.notice = .init(text: "Thuis staat op deze plek.", isError: false)
        } catch {
            model.report(error)
        }
    }

    private func report(home: Bool) async {
        do {
            try await StulpPresenceReport.send(["home": home], source: "ios-app")
            model.notice = .init(text: home ? "Thuis gemeld." : "Weg gemeld.", isError: false)
        } catch {
            model.report(error)
        }
    }
}
#endif

// MARK: - Stulp's own switches

/// Units and statistics: `GET`/`PUT /api/stulp/system`. The pickers come from `unitsOffer`, so
/// there is no second list of units in the app to drift out of step.
private struct StulpSection: View {
    @Environment(HomeModel.self) private var model
    @State private var system: SystemSettings?

    var body: some View {
        if model.client != nil { section }
    }

    private var section: some View {
        Section {
            if let system {
                ForEach(system.unitsOffer) { quantity in
                    Picker(quantity.title, selection: unitBinding(quantity)) {
                        ForEach(quantity.options, id: \.unit) { option in
                            Text(option.title).tag(option.unit)
                        }
                    }
                }
                Toggle("Statistiek verzamelen", isOn: Binding(
                    get: { system.statistics },
                    set: { new in Task { await update(["statistics": .bool(new)]) } }))
                if system.statistics, let bytes = system.statisticsBytes {
                    LabeledContent("Geheugen", value: Int64(bytes).formatted(.byteCount(style: .memory)))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Stulp")
        } footer: {
            Text("Eenheden gelden overal waar je een waarde leest of intypt; apparaten en Flows houden hun eigen eenheid. Statistiek houdt per meting een dag, week en maand bij, alleen in het geheugen.")
        }
        .task { await load() }
    }

    private func unitBinding(_ quantity: UnitQuantity) -> Binding<String> {
        Binding(
            get: { system?.units[quantity.name] ?? quantity.default ?? quantity.options.first?.unit ?? "" },
            set: { unit in Task { await update(["units": .object([quantity.name: .string(unit)])]) } })
    }

    private func load() async {
        guard let client = model.client else { return }
        do { system = try await client.system() } catch { model.report(error) }
    }

    private func update(_ patch: JSONValue) async {
        await model.perform { client in system = try await client.updateSystem(patch) }
    }
}

// MARK: - Backup

/// The whole document plus every installed app bundle as one ZIP, and back.
private struct BackupSection: View {
    @Environment(HomeModel.self) private var model
    @State private var downloading = false
    @State private var exportDocument: ZipDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var restoring: RestoreFile?

    var body: some View {
        Section {
            Button {
                Task { await download() }
            } label: {
                HStack {
                    Label("Download backup", systemImage: "arrow.down.circle")
                    Spacer()
                    if downloading { ProgressView() }
                }
            }
            .disabled(downloading || model.client == nil)
            Button {
                importing = true
            } label: {
                Label("Herstel backup…", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(model.client == nil)
        } header: {
            Text("Backup")
        } footer: {
            Text("Een backup bevat de apparaten, ruimtes, scènes, Flows, instellingen en de geïnstalleerde apps. Waarden die apparaten nu melden horen er niet bij; die komen vanzelf terug.")
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .zip,
                      defaultFilename: ZipDocument.name) { result in
            if case .failure(let error) = result { model.report(error) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): model.report(error)
            }
        }
        .sheet(item: $restoring) { file in
            RestoreSheet(file: file).environment(model)
        }
    }

    private func download() async {
        downloading = true
        defer { downloading = false }
        await model.perform { client in
            let url = try await client.downloadBackup()
            exportDocument = ZipDocument(data: try Data(contentsOf: url))
            try? FileManager.default.removeItem(at: url)
            exporting = true
        }
    }

    private func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            restoring = RestoreFile(name: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            model.report(error)
        }
    }
}

struct RestoreFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}

/// Restoring replaces everything; it only goes ahead after saying so in so many words.
private struct RestoreSheet: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: RestoreFile
    @State private var understood = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Bestand", value: file.name)
                    LabeledContent("Grootte", value: Int64(file.data.count).formatted(.byteCount(style: .file)))
                }
                Section {
                    Label("Alles in Stulp wordt vervangen door deze backup: apparaten, ruimtes, scènes, Flows, instellingen en apps.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Toggle("Ik begrijp dat de huidige staat wordt vervangen", isOn: $understood)
                } footer: {
                    Text("Stulp bewaart de vorige staat als herstelkopie naast het document.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Herstel backup")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Herstel", role: .destructive) { Task { await restore() } }
                            .disabled(!understood)
                    }
                }
            }
        }
        .macSheetSize(width: 480, height: 400)
        .interactiveDismissDisabled(working)
    }

    private func restore() async {
        working = true
        defer { working = false }
        let ok = await model.perform("De backup is hersteld.") { try await $0.restore(zip: file.data) }
        if ok {
            await model.reloadDevices()
            dismiss()
        }
    }
}

struct ZipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    static var name: String { "stulp-backup-\(Date().formatted(.iso8601.year().month().day())).zip" }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        Section("Over") {
            LabeledContent("Versie", value: AppInfo.version)
            Link("Support", destination: AppInfo.support)
            Link("Privacybeleid", destination: AppInfo.privacy)
        }
    }
}

#Preview("Instellingen") {
    NavigationStack { SettingsView() }.previewHouse()
}

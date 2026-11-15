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
    @State private var working = false
    /// The APNs key Stulp signs with: nil while unknown, "" when there is none.
    @State private var pushKeyId: String?
    @State private var importingKey = false
    /// A key file whose name no longer carries the key id; the id is typed in.
    @State private var pendingPEM: String?
    @State private var pendingKeyId = ""
    @State private var testing = false
    private var monitor: PresenceMonitor { .shared }
    private var push: PushCenter { .shared }

    var body: some View {
        Group {
            notificationSection
            phoneSection
            presenceSection
            chargerSection
            pushKeySection
        }
        .task {
            await loadPhones()
            await loadPushKey()
        }
        // PushCenter registers this phone by itself; the sections below follow.
        .onChange(of: push.registered) { _, _ in
            presence = StulpPresenceSettings.load()
            Task { await loadPhones() }
        }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data]) { result in
            Task { await importKey(result) }
        }
    }

    private var phoneSection: some View {
        Section {
            if let presence {
                LabeledContent("Dit toestel", value: presence.phoneName)
            }
            if phones.count > 1 || (presence == nil && !phones.isEmpty) {
                Menu {
                    ForEach(phones) { phone in
                        Button(phone.name) { choose(phone) }
                    }
                } label: {
                    Label(presence == nil ? "Kies een bestaand toestel" : "Kies een ander toestel", systemImage: "iphone")
                }
            }
            if presence == nil {
                Button {
                    Task { await register() }
                } label: {
                    Label("Meld deze telefoon aan bij Stulp", systemImage: "iphone.badge.plus")
                }
                .disabled(working)
            }
        } header: {
            Text("Deze telefoon in Stulp")
        } footer: {
            Text("Gaat vanzelf zodra je meldingen aanzet. Een andere naam geef je bij het apparaat zelf in Stulp.")
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
                if push.registered {
                    Label("Meldingen komen binnen op \(push.phoneName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { await push.retry() }
                    } label: {
                        Label("Nog niet bij Stulp: opnieuw aanmelden", systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    }
                }
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
                    Label("Zet meldingen aan", systemImage: "bell.badge")
                }
            }
            if !push.lastError.isEmpty {
                Text(push.lastError).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Meldingen")
        } footer: {
            Text("Stulp stuurt meldingen rechtstreeks naar deze app: gewoon, dringend (door Focus heen) of kritiek, met camerabeeld. Tik op een melding met camerabeeld en de camera gaat open. Deze telefoon meldt zich daarbij zelf aan.")
        }
    }

    /// Stulp signs every notification with an APNs key of the developer account; without one
    /// Apple accepts nothing. It lives in the notifications app's settings, set from here.
    private var pushKeySection: some View {
        Section {
            switch pushKeyId {
            case nil:
                LabeledContent("Pushsleutel", value: "…")
            case let id? where id.isEmpty:
                Label("Stulp heeft nog geen pushsleutel", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case let id?:
                LabeledContent("Pushsleutel", value: id)
            }
            if let pendingPEM {
                HStack {
                    TextField("Key ID, 10 tekens", text: $pendingKeyId)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await saveKey(pem: pendingPEM, keyId: pendingKeyId) } }
                    Button("Bewaar") { Task { await saveKey(pem: pendingPEM, keyId: pendingKeyId) } }
                        .disabled(!PushKey.isKeyId(pendingKeyId.trimmingCharacters(in: .whitespaces).uppercased()) || working)
                }
            }
            Button {
                importingKey = true
            } label: {
                Label(pushKeyId?.isEmpty == false ? "Vervang de pushsleutel…" : "Kies het .p8-bestand…", systemImage: "key")
            }
            .disabled(working || pushKeyId == nil)
            if let presence {
                Button {
                    Task { await test(presence.phoneId, name: presence.phoneName) }
                } label: {
                    Label("Stuur testmelding", systemImage: "bell.badge")
                }
                .disabled(testing || pushKeyId?.isEmpty != false)
            }
        } header: {
            Text("Pushsleutel van Apple")
        } footer: {
            Text("Eenmalig, voor alle telefoons samen. Maak op developer.apple.com bij Certificates, IDs & Profiles → Keys een sleutel met Apple Push Notifications service (APNs), omgeving Sandbox & Production, en kies hier het gedownloade AuthKey_….p8. De sleutel gaat naar Stulp en blijft niet op deze telefoon.")
        }
    }

    // MARK: Actions

    private func loadPushKey() async {
        guard let client = model.client else { return }
        do { pushKeyId = try await client.pushKeyId() ?? "" } catch { model.report(error) }
    }

    private func importKey(_ result: Result<URL, any Error>) async {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let pem = try String(contentsOf: url, encoding: .utf8)
            guard PushKey.isPEM(pem) else {
                model.notice = .init(text: "Dat is geen APNs-sleutel: kies het AuthKey_….p8 dat Apple je liet downloaden.", isError: true)
                return
            }
            if let id = PushKey.keyId(fromFileName: url.lastPathComponent) {
                await saveKey(pem: pem, keyId: id)
            } else {
                // Renamed after the download: Apple shows the id next to the key.
                pendingPEM = pem
                pendingKeyId = ""
            }
        } catch {
            model.report(error)
        }
    }

    private func saveKey(pem: String, keyId: String) async {
        guard let key = PushKey(pem: pem, keyId: keyId), let client = model.client else { return }
        working = true
        defer { working = false }
        do {
            try await client.setPushKey(key)
            pendingPEM = nil
            pendingKeyId = ""
            pushKeyId = key.keyId
            model.notice = .init(text: "Stulp heeft de pushsleutel \(key.keyId).", isError: false)
            if let presence { await test(presence.phoneId, name: presence.phoneName) }
        } catch {
            model.report(error)
        }
    }

    private func test(_ phoneId: String, name: String) async {
        testing = true
        defer { testing = false }
        await model.perform("Testmelding verstuurd naar \(name).") {
            try await $0.testNotification(deviceId: phoneId)
        }
    }

    private func loadPhones() async {
        guard let client = model.client else { return }
        do { phones = try await client.phones() } catch { model.report(error) }
    }

    /// Without notifications too (thuis en weg, de lader): this phone as a device in Stulp.
    private func register() async {
        guard let client = model.client else { return }
        working = true
        defer { working = false }
        do {
            let settings = try await client.ensurePhone(presence, name: UIDevice.current.name, installation: StulpInstallation.id)
            try settings.save()
            presence = settings
            await loadPhones()
            await PushCenter.shared.send()
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

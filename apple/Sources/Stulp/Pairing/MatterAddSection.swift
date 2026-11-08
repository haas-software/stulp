#if os(iOS)
import MatterSupport
import StulpKit
import SwiftUI

/// Adding a factory-new Matter accessory: Apple's own setup screen scans the code and puts the
/// accessory on Wi-Fi or Thread; the setup extension then hands the code to Stulp, which
/// commissions it into its own fabric. The extension writes its milestones to the app group; this
/// shows them live, because Apple's own phase is otherwise invisible and exactly where it stalls.
@MainActor
@Observable
final class MatterAdder {
    static let shared = MatterAdder()

    private(set) var isWorking = false
    private(set) var status = ""
    private(set) var steps: [MatterProgressStep] = []
    /// Shown once the hand-over to Stulp does not follow the network step.
    private(set) var hint = ""

    /// After the network step the hand-over normally follows within seconds; after this it hardly
    /// ever comes any more (waiting five minutes for Apple's own time-out, while a second attempt
    /// right away succeeded).
    static let stallSeconds: TimeInterval = 40

    @ObservationIgnored private var adding: Task<Void, any Error>?

    func cancel() {
        adding?.cancel()
        hint = ""
        status = "Toevoegen geannuleerd. Probeer het meteen opnieuw; dat slaagt meestal."
    }

    private func refreshProgress() {
        steps = MatterProgress.load()
        guard isWorking, let last = steps.last else { return }
        let handedOver = steps.contains { $0.text.hasPrefix("commissionDevice") }
        let networkChosen = steps.contains { $0.text.hasPrefix("thread:") || $0.text.hasPrefix("wifi:") }
        let waited = Date().timeIntervalSince(last.at)
        if networkChosen && !handedOver && waited >= Self.stallSeconds {
            hint = "Al \(Int(waited)) s geen overdracht aan Stulp na de netwerkstap. iOS krijgt het apparaat dan meestal niet meer te pakken en wacht tot zijn eigen time-out van vijf minuten. Annuleer en probeer het meteen opnieuw."
        } else {
            hint = ""
        }
    }

    func add(connection: StulpConnection?) async {
        guard let connection, !isWorking else { return }
        guard MatterAddDeviceRequest.isSupported else {
            status = "Matter toevoegen wordt op dit toestel niet ondersteund."
            return
        }
        isWorking = true
        status = "iOS opent de Matter-scanner…"
        hint = ""
        MatterProgress.clear()
        steps = []
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshProgress()
            }
        }
        defer {
            poll.cancel()
            isWorking = false
            refreshProgress()
            hint = ""
        }
        let trace = StulpClient(connection: connection, logSource: "ios-app")
        trace.trace("Matter toevoegen gestart vanuit de app")
        do {
            let home = MatterAddDeviceRequest.Home(displayName: "Thuis")
            let topology = MatterAddDeviceRequest.Topology(ecosystemName: "Stulp", homes: [home])
            let request = MatterAddDeviceRequest(topology: topology, showing: .allDevices, shouldScanNetworks: true)
            let work = Task { try await request.perform() }
            adding = work
            defer { adding = nil }
            try await work.value
            status = "Het apparaat is rechtstreeks aan Stulp toegevoegd."
            trace.trace("Matter toevoegen afgerond door iOS")
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) || error is CancellationError {
                status = "Toevoegen geannuleerd."
                trace.trace("warn", "Matter toevoegen geannuleerd")
            } else {
                status = error.localizedDescription
                trace.trace("error", "Matter toevoegen mislukt: \(Self.describe(nsError))")
            }
        }
    }

    /// Domain, code and the whole chain of underlying errors: MatterSupport itself only says
    /// "error 1", the reason is in the userInfo below it.
    nonisolated static func describe(_ error: NSError, depth: Int = 0) -> String {
        var text = "\(error.domain) \(error.code) \(error.localizedDescription)"
        let info = error.userInfo.filter { $0.key != NSUnderlyingErrorKey && $0.key != "NSMultipleUnderlyingErrorsKey" }
        if !info.isEmpty {
            text += " userInfo=" + info.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        }
        var underlying: [NSError] = []
        if let one = error.userInfo[NSUnderlyingErrorKey] as? NSError { underlying.append(one) }
        if let many = error.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] { underlying += many }
        if depth < 4 {
            for u in underlying { text += " <- " + describe(u, depth: depth + 1) }
        }
        return String(text.prefix(900))
    }
}

/// The first section of the add sheet on an iPhone or iPad.
struct MatterAddSection: View {
    @Environment(HomeModel.self) private var model
    private var adder: MatterAdder { MatterAdder.shared }

    var body: some View {
        Section {
            Button {
                Task { await adder.add(connection: model.connection) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor, in: .rect(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(adder.isWorking ? "Bezig met toevoegen…" : "Matter-apparaat").foregroundStyle(.primary)
                        Text("Scan de code op het apparaat").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if adder.isWorking { ProgressView() }
                }
            }
            // A row, not a link: the text stays black and grey like the rows below it.
            .tint(.primary)
            .disabled(adder.isWorking || model.connection == nil)
            .accessibilityIdentifier("add-matter-device")

            if adder.isWorking || !adder.steps.isEmpty {
                MatterProgressList(adder: adder)
            }
            if !adder.hint.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(adder.hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Annuleer en probeer opnieuw", role: .destructive) { adder.cancel() }
                        .font(.footnote.weight(.semibold))
                }
            }
        } header: {
            Text("Matter")
        } footer: {
            Text(adder.status.isEmpty
                 ? "iOS regelt Bluetooth en het netwerk; daarna voegt Stulp het apparaat rechtstreeks aan je eigen Stulp toe."
                 : adder.status)
        }
    }
}

/// The milestones of the pairing with the seconds since its start.
private struct MatterProgressList: View {
    let adder: MatterAdder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let start = adder.steps.first?.at
            ForEach(Array(adder.steps.suffix(8).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 8) {
                    Text(start.map { String(format: "%3.0fs", step.at.timeIntervalSince($0)) } ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(step.text).font(.caption)
                }
            }
            if adder.isWorking && adder.steps.isEmpty {
                Text("Wachten op iOS: QR-code, Bluetooth en netwerk…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif

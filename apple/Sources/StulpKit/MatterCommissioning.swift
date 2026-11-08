import Foundation

/// The iPhone half of adding a factory-new Matter accessory. MatterSupport has put the accessory on
/// Wi-Fi or Thread over BLE before this runs; from here the phone only carries the onboarding code.
/// Stulp does PASE, attestation, NOC/CASE and endpoint inspection itself.
public struct MatterCommissioning: Sendable {
    static let appID = "com.stulp.matter"
    static let driverID = "matter"

    let client: StulpClient
    let pollInterval: Duration
    let timeout: Duration
    let candidateRetryDelay: Duration

    public init(
        client: StulpClient, pollInterval: Duration = .milliseconds(1500), timeout: Duration = .seconds(195),
        candidateRetryDelay: Duration = .milliseconds(250)
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.candidateRetryDelay = candidateRetryDelay
    }

    public func commission(onboardingPayload: String) async throws -> [PendingMatterDevice] {
        let payload = onboardingPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw StulpClientError.missingOnboardingPayload }

        let pair = try await client.openPair(app: Self.appID, driver: Self.driverID)
        guard pair.handlers.contains("commission"), pair.handlers.contains("commission_state"),
              pair.handlers.contains("list_devices")
        else {
            try? await client.closePair(pair.id)
            throw StulpClientError.incompatibleMatterApp
        }
        client.trace("pair \(pair.id) geopend, payload \(payload.count) tekens")

        return try await withTaskCancellationHandler {
            do {
                let devices = try await run(pairID: pair.id, payload: payload)
                client.trace("pair \(pair.id) klaar: \(devices.count) apparaat/apparaten toegevoegd")
                await closeIgnoringCancellation(pair.id)
                return devices
            } catch {
                client.trace("error", "pair \(pair.id) mislukt: \(error.localizedDescription)")
                await closeIgnoringCancellation(pair.id)
                throw error
            }
        } onCancel: { [client] in
            Task.detached { try? await client.closePair(pair.id) }
        }
    }

    /// Name and room from Apple's sheet. A bridge can yield several Stulp devices; rolling one name
    /// out over all of them would wipe their useful names, so only a single result takes it.
    public func configure(devices: [PendingMatterDevice], name: String, roomName: String?) async throws {
        guard !devices.isEmpty else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if devices.count == 1, !cleanName.isEmpty, cleanName != devices[0].name {
            _ = try await client.renameDevice(devices[0].id, name: cleanName)
        }
        guard let roomName, !roomName.isEmpty else { return }
        guard let group = try await client.groups().first(where: { $0.name == roomName }) else { return }
        for device in devices {
            _ = try await client.moveDevice(device.id, toGroup: group.id)
        }
    }

    private func run(pairID: String, payload: String) async throws -> [PendingMatterDevice] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // A single request can get lost while Stulp keeps working (a status poll in the middle of
        // PASE never got an answer). `commission` answers a running session with its state, so
        // repeating is safe; giving up would throw away a pairing that succeeds.
        var state = try await emitRetrying(pairID, "commission", ["code": .string(payload), "address": ""], deadline, clock)
        client.trace("commission gestuurd, running=\(state.running)")
        while state.running {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                client.trace("warn", "commission_state nog running na \(timeout.components.seconds) s")
                throw StulpClientError.commissioningTimedOut
            }
            try await Task.sleep(for: pollInterval)
            state = try await emitRetrying(pairID, "commission_state", [:], deadline, clock)
        }
        client.trace("commission klaar: found=\(state.found ?? 0) warning=\(state.warning ?? "-")")
        if let warning = state.warning, !warning.isEmpty { throw StulpClientError.commissioningFailed(warning) }
        guard (state.found ?? 0) > 0 else { throw StulpClientError.noDevicesFound }

        let candidates = try await client.emit(pair: pairID, event: "list_devices").array ?? []
        client.trace("list_devices: \(candidates.count) kandidaat/kandidaten")
        guard !candidates.isEmpty else { throw StulpClientError.noDevicesFound }

        var devices: [PendingMatterDevice] = []
        for candidate in candidates {
            let device = try await add(candidate)
            devices.append(PendingMatterDevice(id: device.id, name: device.name))
        }
        return devices
    }

    private func emitRetrying(
        _ pairID: String, _ event: String, _ data: JSONValue, _ deadline: ContinuousClock.Instant, _ clock: ContinuousClock
    ) async throws -> CommissionState {
        var attempt = 0
        while true {
            do {
                return CommissionState(try await client.emit(pair: pairID, event: event, data: data))
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                attempt += 1
                client.trace("warn", "\(event) zonder antwoord (poging \(attempt)): \(error.localizedDescription)")
                guard attempt < 4, clock.now < deadline else { throw error }
                try Task.checkCancellation()
            }
        }
    }

    private func add(_ candidate: JSONValue) async throws -> Device {
        var firstError: Error?
        for attempt in 0..<2 {
            do {
                let device = try await client.addDevice(app: Self.appID, driver: Self.driverID, candidate: candidate)
                client.trace("toegevoegd: \(device.name) (\(device.id))")
                return device
            } catch {
                client.trace("warn", "kandidaat toevoegen mislukt (poging \(attempt + 1)): \(error.localizedDescription)")
                if attempt == 1 || !Self.retryable(error) { throw error }
                firstError = error
                try Task.checkCancellation()
                try await Task.sleep(for: candidateRetryDelay)
            }
        }
        throw firstError ?? StulpClientError.invalidResponse
    }

    static func retryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case .server(let status, _) = error as? StulpClientError { return status >= 500 }
        return false
    }

    private func closeIgnoringCancellation(_ pairID: String) async {
        _ = await Task.detached { [client] in try? await client.closePair(pairID) }.value
    }
}

struct CommissionState: Sendable {
    let running: Bool
    let warning: String?
    /// The number of devices found on success. An older proposal had an object here; both are read.
    let found: Int?

    init(_ value: JSONValue) {
        running = value["running"]?.bool ?? false
        warning = value["warning"]?.string
        if let n = value["found"]?.number {
            found = Int(n)
        } else {
            found = value["found"]?["found"]?.number.map { Int($0) }
        }
    }
}

#if os(iOS)
import CoreLocation
import Foundation
import Observation
import StulpKit
import os

/// Home and away from two rings iOS watches itself, also while the app is not running: entering
/// within 300 m makes home (early enough to switch the alarm off), leaving 150 m makes away. The
/// other two crossings do not count, so a wobbling GPS fix at home never makes away. iOS wakes the
/// app at a crossing; the app reports it to Stulp, and the Flows decide what happens.
@MainActor
@Observable
final class PresenceMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = PresenceMonitor()

    private(set) var authorization: CLAuthorizationStatus
    private(set) var lastEvent = ""

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let logger = Logger(subsystem: "software.haas.stulp", category: "Presence")
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var creating: Task<CLMonitor, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var locating: CheckedContinuation<CLLocation, any Error>?

    override private init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// At every launch, also when iOS wakes the app in the background for a ring: the monitor must
    /// listen again at once to receive the event.
    func start() {
        guard listening == nil else { return }
        listening = Task { [weak self] in await self?.listen() }
    }

    func requestAlways() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Puts home at the current place and restarts the rings.
    func setHome() async throws {
        requestAlways()
        let location = try await currentLocation()
        guard var settings = StulpPresenceSettings.load() else { throw StulpPresenceError.noPhone }
        settings.latitude = location.coordinate.latitude
        settings.longitude = location.coordinate.longitude
        try settings.save()
        try await configure(settings)
    }

    func clearHome() async {
        if let monitor {
            for id in await monitor.identifiers { await monitor.remove(id) }
        }
    }

    private func configure(_ settings: StulpPresenceSettings) async throws {
        guard let lat = settings.latitude, let lon = settings.longitude else { return }
        let monitor = try await ensureMonitor()
        let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        for id in await monitor.identifiers { await monitor.remove(id) }
        await monitor.add(
            CLMonitor.CircularGeographicCondition(center: center, radius: settings.arriveRadius),
            identifier: "arrive", assuming: .unsatisfied)
        await monitor.add(
            CLMonitor.CircularGeographicCondition(center: center, radius: settings.leaveRadius),
            identifier: "leave", assuming: .satisfied)
        note("ringen gezet: thuis binnen \(Int(settings.arriveRadius)) m, weg buiten \(Int(settings.leaveRadius)) m")
    }

    private func ensureMonitor() async throws -> CLMonitor {
        if let monitor { return monitor }
        // One creation, also when start() and setHome() ask together: a second CLMonitor with the
        // same name in one process is not allowed.
        if let creating { return await creating.value }
        // Letters and digits only: with a hyphen CoreLocation stops the app with "Monitor name is
        // not valid".
        let task = Task { await CLMonitor("StulpPresence") }
        creating = task
        let created = await task.value
        monitor = created
        creating = nil
        return created
    }

    private func listen() async {
        do {
            let monitor = try await ensureMonitor()
            if await monitor.identifiers.isEmpty, let settings = StulpPresenceSettings.load() {
                try await configure(settings)
            }
            for try await event in await monitor.events {
                switch (event.identifier, event.state) {
                case ("arrive", .satisfied): await report(["home": true])
                case ("leave", .unsatisfied): await report(["home": false])
                default: continue
                }
            }
        } catch {
            note("geofence gestopt: \(error.localizedDescription)")
        }
        listening = nil
    }

    private func report(_ values: [String: Bool]) async {
        let text = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        lastEvent = "\(Date().formatted(date: .omitted, time: .shortened)) \(text == "home=true" ? "thuis" : text == "home=false" ? "weg" : text)"
        do {
            try await StulpPresenceReport.send(values, source: "ios-presence")
        } catch {
            note("melden mislukt (\(text)): \(error.localizedDescription)")
        }
    }

    private func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            locating = continuation
            manager.requestLocation()
        }
    }

    private func note(_ text: String) {
        logger.info("\(text, privacy: .public)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // After "while using" ask for "always" right away: without it iOS does not wake the
            // app for the rings.
            if status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.locating?.resume(returning: location)
            self.locating = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in
            self.locating?.resume(throwing: error)
            self.locating = nil
        }
    }
}
#endif

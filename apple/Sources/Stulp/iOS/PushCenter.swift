#if os(iOS)
import Observation
import StulpKit
import SwiftUI
import UIKit
import UserNotifications
import os

/// Notifications through the app: permission, the APNs token to Stulp, and what a tap on a
/// notification does (a camera opens its live view).
@MainActor
@Observable
final class PushCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushCenter()

    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var registered = false
    var lastError = ""
    /// Set after a tap on a notification that carries a camera; RootView opens that device.
    var openDevice: String?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private let logger = Logger(subsystem: "software.haas.stulp", category: "Push")

    /// At every launch: iOS may change the token, so register again whenever permission exists.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Task { await refresh(register: true) }
    }

    func request() async {
        do {
            // Critical alerts (.criticalAlert) only once Apple approved the app for them; until
            // then a critical notification arrives as time-sensitive.
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if !granted { lastError = "Meldingen staan uit voor Stulp; zet ze aan in Instellingen." }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh(register: true)
    }

    private func refresh(register: Bool) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        if register, [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(_ deviceToken: Data) async {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        await send()
    }

    func didFail(_ error: any Error) {
        lastError = "Apple gaf geen push-token: \(error.localizedDescription)"
    }

    /// Also after choosing or registering a phone: the token belongs to that device.
    func send() async {
        guard let token else { return }
        guard let connection = try? SharedStulpConfiguration.load(),
              let settings = StulpPresenceSettings.load(), !settings.phoneId.isEmpty
        else { return }
        do {
            try await StulpClient(connection: connection, logSource: "ios-push")
                .registerPush(deviceId: settings.phoneId, token: token, environment: Self.environment)
            registered = true
            lastError = ""
        } catch {
            registered = false
            lastError = "Push-token niet bij Stulp: \(error.localizedDescription)"
            logger.error("register_push: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A build from Xcode talks to the APNs sandbox, TestFlight and the App Store to production.
    /// Only a development profile is still inside the app; that says which.
    static var environment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
        else { return "production" }
        return text[open.upperBound..<close.lowerBound] == "development" ? "development" : "production"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let stulp = response.notification.request.content.userInfo["stulp"] as? [String: Any]
        guard let camera = stulp?["camera"] as? String, !camera.isEmpty else { return }
        await MainActor.run { self.openDevice = camera }
    }
}

/// UIKit's callbacks for the APNs token; SwiftUI has no way of its own for them.
final class StulpAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushCenter.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Task { @MainActor in PushCenter.shared.didFail(error) }
    }
}
#endif

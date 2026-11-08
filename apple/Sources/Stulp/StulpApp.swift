import StulpKit
import SwiftUI

@main
struct StulpApp: App {
    static let mainWindowID = "main"

    #if os(iOS)
    @UIApplicationDelegateAdaptor(StulpAppDelegate.self) private var delegate
    #endif
    @State private var model = HomeModel(demo: DebugLaunch.demo)

    init() {
        #if os(iOS)
        // iOS wakes the app in the background for a home/away crossing; the geofence must listen
        // again at once to receive the event.
        PresenceMonitor.shared.start()
        PushCenter.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environment(model)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 520)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1080, height: 720)
        .commands { StulpCommands(model: model) }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 680)
        }
        #endif
    }
}

#if os(macOS)
/// The menu bar: add a device (⌘N), reload (⌘R).
struct StulpCommands: Commands {
    let model: HomeModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Apparaat toevoegen…") { model.addingDevice = true }
                .keyboardShortcut("n")
                .disabled(!model.isConfigured)
            Divider()
            Button("Vernieuw") { Task { await model.reloadDevices() } }
                .keyboardShortcut("r")
                .disabled(!model.isConfigured)
        }
    }
}
#endif

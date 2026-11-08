import StulpKit
import SwiftUI

/// Debug-only launch arguments, for the simulator and screenshots. Release ignores them.
enum DebugLaunch {
    #if DEBUG
    /// `-stulpDemo YES`: a filled house without a server.
    static var demo: Bool { UserDefaults.standard.bool(forKey: "stulpDemo") }
    /// `-stulpAddress http://127.0.0.1:8080 -stulpKey KEY`: connect without onboarding.
    static var address: String? { UserDefaults.standard.string(forKey: "stulpAddress") }
    static var key: String? { UserDefaults.standard.string(forKey: "stulpKey") }
    /// `-stulpTab automations|settings|home`.
    static var tab: String? { UserDefaults.standard.string(forKey: "stulpTab") }
    /// `-stulpOpen <device id>`: open that device's detail at launch.
    static var open: String? { UserDefaults.standard.string(forKey: "stulpOpen") }
    #else
    static let demo = false
    static let address: String? = nil
    static let key: String? = nil
    static let tab: String? = nil
    static let open: String? = nil
    #endif
}

extension ToolbarItemPlacement {
    /// iOS: the trailing end of the navigation bar; Mac: the window toolbar.
    static var trailingBar: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }
}

extension View {
    /// The sheet size a Mac needs (a sheet there has no size of its own); nothing on iOS.
    @ViewBuilder
    func macSheetSize(width: CGFloat = 520, height: CGFloat = 600) -> some View {
        #if os(macOS)
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// Large title on iOS; the Mac has none.
    @ViewBuilder
    func largeTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.large)
        #endif
    }

    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The notice at the bottom: Liquid Glass capsule, gone after four seconds.
    func noticeBanner(_ notice: Binding<HomeModel.Notice?>) -> some View {
        overlay(alignment: .bottom) {
            if let current = notice.wrappedValue {
                Label(current.text, systemImage: current.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(current.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { notice.wrappedValue = nil }
                    .task(id: current.id) {
                        try? await Task.sleep(for: .seconds(current.isError ? 6 : 4))
                        if notice.wrappedValue?.id == current.id { notice.wrappedValue = nil }
                    }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.snappy, value: notice.wrappedValue)
    }
}

extension Binding where Value == String? {
    /// A `.sheet(item:)` binding over an optional id.
    var identified: Binding<IdentifiedString?> {
        Binding<IdentifiedString?>(
            get: { wrappedValue.map(IdentifiedString.init) },
            set: { wrappedValue = $0?.id })
    }
}

struct IdentifiedString: Identifiable, Hashable {
    let id: String
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static let support = URL(string: "https://haas.software/apps/support/")!
    static let privacy = URL(string: "https://haas.software/apps/privacy/")!
}

extension Text {
    /// Dutch plurals by hand: "1 apparaat", "3 apparaten".
    static func count(_ n: Int, _ one: String, _ many: String) -> Text {
        Text(n == 1 ? "1 \(one)" : "\(n) \(many)")
    }
}

import StulpKit
import SwiftUI
import WebKit

/// The host side of an app's own page (`/app-ui/…`: its settings, a pairing step). The page talks
/// to Stulp only through `stulp.js`, which posts every call to the message handler `stulp` and
/// gets a promise back; this object answers those calls with the app's own API, its settings and
/// the pairing session — and with the native pieces a page cannot draw itself (an alert, a
/// confirmation, a title, closing).
///
/// The page never sees the key. Its assets load with a cookie Stulp accepts only under `/app-ui/`;
/// everything it asks of the API goes through here with the Bearer token.
@MainActor
@Observable
final class AppPageBridge {
    struct Confirmation: Identifiable {
        let id = UUID()
        let message: String
        let destructive: Bool
        fileprivate let answer: CheckedContinuation<Bool, Never>
    }

    struct Message: Identifiable {
        let id = UUID()
        let text: String
    }

    let appId: String
    /// The pairing session, for `emit`; nil on a settings page.
    let pairSession: String?

    private(set) var title: String?
    private(set) var loading = true
    private(set) var loadError: String?
    var confirmation: Confirmation?
    var message: Message?

    /// What the page asks of its host beyond answering: the pairing flow decides what a view is,
    /// and the sheet decides what closing means.
    @ObservationIgnored var onShowView: (String) -> Void = { _ in }
    @ObservationIgnored var onNextView: () -> Void = {}
    @ObservationIgnored var onPreviousView: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onOpenURL: (URL) -> Void = { _ in }

    @ObservationIgnored private let client: StulpClient
    @ObservationIgnored fileprivate weak var webView: WKWebView?

    init(client: StulpClient, appId: String, pairSession: String? = nil) {
        self.client = client
        self.appId = appId
        self.pairSession = pairSession
    }

    var connection: StulpConnection { client.connection }

    func url(_ path: String) -> URL? { try? client.url(path) }

    fileprivate func started() {
        loading = true
        loadError = nil
    }

    fileprivate func finished() { loading = false }

    fileprivate func failed(_ error: Error) {
        loading = false
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadError = error.localizedDescription
    }

    /// An event for `Stulp.on(name, …)` in the page.
    func send(event name: String, data: JSONValue = .null) {
        guard let webView,
              let nameJSON = try? String(decoding: JSONEncoder().encode(JSONValue.string(name)), as: UTF8.self),
              let dataJSON = try? String(decoding: JSONEncoder().encode(data), as: UTF8.self)
        else { return }
        webView.evaluateJavaScript("window.__stulpEvent && window.__stulpEvent(\(nameJSON), \(dataJSON))")
    }

    func answer(_ confirmation: Confirmation, _ value: Bool) {
        confirmation.answer.resume(returning: value)
        if self.confirmation?.id == confirmation.id { self.confirmation = nil }
    }

    // MARK: - The protocol of stulp.js

    enum BridgeError: LocalizedError {
        case foreignPage
        case noSession
        case unknown(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .foreignPage: "Deze pagina hoort niet bij deze app."
            case .noSession: "Er loopt geen koppeling."
            case .unknown(let action): "Onbekende opdracht: \(action)."
            case .missing(let field): "Er ontbreekt een waarde: \(field)."
            }
        }
    }

    /// One call from the page: `{action, args, context}`. Answers the value for the promise.
    func handle(_ body: JSONValue) async throws -> JSONValue {
        // A page may only speak for the app it was loaded for: a redirect or an embedded page of
        // another app must not reach this app's settings.
        if let page = body["context"]?["appId"]?.string, page != appId { throw BridgeError.foreignPage }
        let action = body["action"]?.string ?? ""
        let args = body["args"] ?? .object([:])

        switch action {
        case "get":
            return try await client.appSetting(appId, try text(args, "name"))
        case "set":
            try await client.setAppSetting(appId, try text(args, "name"), args["value"] ?? .null)
            return true
        case "unset":
            try await client.unsetAppSetting(appId, try text(args, "name"))
            return true
        case "api":
            let method = args["method"]?.string ?? "GET"
            let body = args["body"].flatMap { $0.isNull ? nil : $0 }
            return try await client.appAPI(appId, method: method, path: try text(args, "path"), body: body)
        case "emit":
            guard let pairSession else { throw BridgeError.noSession }
            return try await client.emit(pair: pairSession, event: try text(args, "event"), data: args["data"] ?? .null)
        case "showView":
            onShowView(try text(args, "view"))
            return true
        case "nextView":
            onNextView()
            return true
        case "prevView":
            onPreviousView()
            return true
        case "close":
            onClose()
            return true
        case "title":
            let value = args["title"]?.text ?? ""
            title = value.isEmpty ? nil : value
            return true
        case "openURL":
            guard let url = URL(string: try text(args, "url")), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw BridgeError.missing("url")
            }
            onOpenURL(url)
            return true
        case "alert":
            message = Message(text: args["message"]?.text ?? "")
            return true
        case "confirm":
            let text = args["message"]?.text ?? ""
            let destructive = args["type"]?.string == "warning" || args["type"]?.string == "error"
            let answer = await withCheckedContinuation { continuation in
                // A page asking twice before the first is answered: the first counts as "no".
                if let open = confirmation { answer(open, false) }
                confirmation = Confirmation(message: text, destructive: destructive, answer: continuation)
            }
            return .bool(answer)
        case "ready", "navigationClose":
            return true
        default:
            throw BridgeError.unknown(action)
        }
    }

    private func text(_ args: JSONValue, _ field: String) throws -> String {
        guard let value = args[field], !value.isNull else { throw BridgeError.missing(field) }
        return value.text
    }
}

/// An app page in a web view, with the native alert and confirmation it may ask for, and a spinner
/// until it has loaded. `path` is relative to Stulp (`/app-ui/<app>/settings/`).
struct AppPageView: View {
    let bridge: AppPageBridge
    let path: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var bridge = bridge
        ZStack {
            AppWebView(bridge: bridge, path: path)
                .opacity(bridge.loading ? 0 : 1)
            if bridge.loading {
                ProgressView()
                    .controlSize(.large)
            } else if let error = bridge.loadError {
                ContentUnavailableView {
                    Label("Pagina niet geladen", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            }
        }
        .background(pageBackground)
        .onAppear { bridge.onOpenURL = { openURL($0) } }
        .alert(
            bridge.confirmation?.message ?? "",
            isPresented: Binding(
                get: { bridge.confirmation != nil },
                set: { if !$0, let open = bridge.confirmation { bridge.answer(open, false) } }),
            presenting: bridge.confirmation
        ) { confirmation in
            Button("Annuleer", role: .cancel) { bridge.answer(confirmation, false) }
            Button("OK", role: confirmation.destructive ? .destructive : nil) { bridge.answer(confirmation, true) }
        }
        .alert(
            bridge.message?.text ?? "",
            isPresented: Binding(get: { bridge.message != nil }, set: { if !$0 { bridge.message = nil } })
        ) {
            Button("OK", role: .cancel) { bridge.message = nil }
        }
    }

    /// The same grouped background the page itself uses (app-frame.css), so nothing flashes.
    private var pageBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - The web view

#if os(iOS)
private typealias Representable = UIViewRepresentable
#else
private typealias Representable = NSViewRepresentable
#endif

struct AppWebView: Representable {
    let bridge: AppPageBridge
    let path: String

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view) }
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view) }
    #endif

    private func make(_ context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing of an app page outlives it: no cache, no storage shared with another app's page.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: "stulp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.keyboardDismissMode = .interactive
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        #if DEBUG
        view.isInspectable = true
        #endif
        bridge.webView = view
        context.coordinator.load(path, in: view)
        return view
    }

    private func update(_ view: WKWebView, _ context: Context) {
        if context.coordinator.path != path { context.coordinator.load(path, in: view) }
    }

    private static func dismantle(_ view: WKWebView) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "stulp", contentWorld: .page)
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
        let bridge: AppPageBridge
        private(set) var path: String?

        init(bridge: AppPageBridge) { self.bridge = bridge }

        /// Sets the `/app-ui/` cookie, then loads. The cookie has to be in the store before the
        /// request leaves, or the first page loads without it and gets a 404.
        func load(_ path: String, in view: WKWebView) {
            self.path = path
            guard let url = bridge.url(path), let host = url.host() else {
                bridge.failed(URLError(.badURL))
                return
            }
            bridge.started()
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: "stulp-session",
                .value: bridge.connection.appUISessionProof,
                .domain: host,
                .path: "/app-ui/",
            ]
            if url.scheme == "https" { properties[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties) else {
                bridge.failed(URLError(.userAuthenticationRequired))
                return
            }
            view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak view] in
                guard let view else { return }
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                view.load(request)
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            let body = JSONValue(foundation: message.body)
            do {
                let value = try await bridge.handle(body)
                return (value.foundation, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            bridge.finished()
            #if DEBUG
            // `-stulpPageScript "<js>"`: drive a page from the command line (simulator tests).
            if let script = UserDefaults.standard.string(forKey: "stulpPageScript") {
                webView.evaluateJavaScript(script)
            }
            #endif
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            bridge.failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            bridge.failed(error)
        }

        /// A 404 here is almost always a page the app does not have (or no session), not a network
        /// problem: say so instead of showing an empty white page.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                bridge.failed(StulpClientError.server(status: http.statusCode, message: "Stulp gaf deze pagina niet (HTTP \(http.statusCode))."))
                return .cancel
            }
            return .allow
        }

        /// The page stays the page: a link elsewhere opens outside the app, as `openURL` does.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let home = bridge.url("/")
            let sameOrigin = url.host() == home?.host() && url.port == home?.port && url.scheme == home?.scheme
            if sameOrigin || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { return .allow }
            if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
                bridge.onOpenURL(url)
            }
            return .cancel
        }

        /// `target="_blank"` and `window.open`: outside the app, never a second web view.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") {
                bridge.onOpenURL(url)
            }
            return nil
        }

        /// A page's own `alert()`/`confirm()` (instead of Stulp.alert) still gets a native answer.
        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async {
            bridge.message = AppPageBridge.Message(text: message)
        }

        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async -> Bool {
            (try? await bridge.handle(["action": "confirm", "args": ["message": .string(message)]]).bool) ?? false
        }
    }
}

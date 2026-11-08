import CryptoKit
import Foundation
import Security

/// Where Stulp is and the key it runs with (`STULP_TOKEN`). The key goes as a Bearer token on
/// every API request; the app never puts it in a URL.
public struct StulpConnection: Codable, Equatable, Sendable {
    public let baseURL: URL
    public let accessKey: String

    public init(baseURL: URL, accessKey: String) {
        self.baseURL = baseURL
        self.accessKey = accessKey
    }

    /// Address and key as typed in onboarding. The address may be a bare host (`stulp.local:8080`,
    /// https is assumed) and may also be the old Manage link `https://host/KEY`, in which case the
    /// key field may stay empty: people still have that link.
    public static func parse(address: String, key: String = "") throws -> StulpConnection {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw StulpConnectionError.empty }
        if !value.contains("://") { value = "https://" + value }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw StulpConnectionError.invalidURL
        }

        let fromPath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromPath.contains("/") else { throw StulpConnectionError.invalidURL }
        let accessKey = typed.isEmpty ? fromPath : typed
        guard !accessKey.isEmpty else { throw StulpConnectionError.missingKey }

        components.path = ""
        guard let baseURL = components.url else { throw StulpConnectionError.invalidURL }
        return StulpConnection(baseURL: baseURL, accessKey: accessKey)
    }

    /// Kept for the tests and the Matter extension's older call sites: a full `https://host/KEY`.
    public static func parse(_ link: String) throws -> StulpConnection {
        try parse(address: link)
    }

    /// The `Authorization` header value.
    public var authorization: String { "Bearer \(accessKey)" }

    /// The cookie an app's own pages (`/app-ui/…`) need for their assets in a web view, which
    /// cannot carry a Bearer header on subresources. Stulp accepts it only under `/app-ui/`:
    /// hex(sha256("stulp web session\0" + key)).
    public var appUISessionProof: String {
        var input = Data("stulp web session".utf8)
        input.append(0)
        input.append(Data(accessKey.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// The host as shown in Settings, without scheme.
    public var displayAddress: String {
        var text = baseURL.host() ?? baseURL.absoluteString
        if let port = baseURL.port { text += ":\(port)" }
        return text
    }
}

public enum StulpConnectionError: LocalizedError, Equatable {
    case empty
    case invalidURL
    case missingKey

    public var errorDescription: String? {
        switch self {
        case .empty: "Vul het adres van Stulp in."
        case .invalidURL: "Dit is geen geldig http- of https-adres van Stulp."
        case .missingKey: "Vul de toegangssleutel van Stulp in."
        }
    }
}

/// The connection in the Keychain, shared with the extensions (Matter setup) through the keychain
/// group. Device-only, never synchronised.
public enum SharedStulpConfiguration {
    private static let service = "software.haas.stulp.connection"
    private static let account = "primary"

    public static func load() throws -> StulpConnection? {
        var query = try baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(StulpConnection.self, from: data)
    }

    public static func save(_ connection: StulpConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let query = try baseQuery()
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess {
            SharedBaseURL.save(connection.baseURL)
            return
        }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var item = query
        for (key, value) in values { item[key] = value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        SharedBaseURL.save(connection.baseURL)
    }

    public static func remove() throws {
        let status = SecItemDelete(try baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
        SharedBaseURL.save(nil)
    }

    private static func baseQuery() throws -> [String: Any] {
        guard let group = StulpBundle.value("StulpKeychainAccessGroup") else {
            throw SharedConfigurationError.missingKeychainAccessGroup
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

/// Identifiers that project.yml hands to runtime through Info.plist. An unexpanded `$(…)` or an
/// empty value counts as missing.
enum StulpBundle {
    static func value(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "De Stulp-verbinding kon niet veilig worden bewaard: \(message)"
        }
        return "De Stulp-verbinding kon niet veilig worden bewaard (\(status))."
    }
}

public struct PendingMatterDevice: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum PendingMatterDevices {
    private static let key = "pending-matter-devices"

    public static func load() throws -> [PendingMatterDevice] {
        guard let data = try sharedDefaults().data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingMatterDevice].self, from: data)) ?? []
    }

    public static func save(_ devices: [PendingMatterDevice]) throws {
        try sharedDefaults().set(try JSONEncoder().encode(devices), forKey: key)
    }

    public static func remove() throws {
        try sharedDefaults().removeObject(forKey: key)
    }
}

/// Stulp's address without the key, for the notification extension: Stulp sends a camera still as
/// `/image/<id>`, and the keychain is closed while the phone is locked. The address is not secret.
public enum SharedBaseURL {
    /// The same key is spelled out in `NotificationService`, which does not link StulpKit.
    public static let key = "stulp-base-url"

    public static func save(_ url: URL?) {
        guard let defaults = try? sharedDefaults() else { return }
        if let url {
            defaults.set(url.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public func sharedDefaults() throws -> UserDefaults {
    guard let identifier = StulpBundle.value("StulpAppGroup"),
          let shared = UserDefaults(suiteName: identifier)
    else {
        throw SharedConfigurationError.missingAppGroup
    }
    return shared
}

/// One milestone of a Matter pairing, written by the extension and shown live by the app. Apple's
/// own phase is otherwise invisible to the app, and that is exactly where it sometimes stalls.
public struct MatterProgressStep: Codable, Equatable, Sendable {
    public let at: Date
    public let text: String
}

public enum MatterProgress {
    private static let key = "matter-progress"
    public static let maximum = 40

    public static func clear() {
        try? sharedDefaults().removeObject(forKey: key)
    }

    public static func record(_ text: String) {
        var steps = load()
        steps.append(MatterProgressStep(at: Date(), text: text))
        if steps.count > maximum { steps.removeFirst(steps.count - maximum) }
        if let data = try? JSONEncoder().encode(steps) {
            try? sharedDefaults().set(data, forKey: key)
        }
    }

    public static func load() -> [MatterProgressStep] {
        guard let data = try? sharedDefaults().data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MatterProgressStep].self, from: data)) ?? []
    }
}

public enum SharedConfigurationError: LocalizedError {
    case missingKeychainAccessGroup
    case missingAppGroup

    public var errorDescription: String? {
        switch self {
        case .missingKeychainAccessGroup:
            "De gedeelde Keychain-groep ontbreekt. Controleer de signing van de app en de extensies."
        case .missingAppGroup:
            "De gedeelde app-groep ontbreekt. Controleer de signing van de app en de extensies."
        }
    }
}

/// Which phone device in Stulp this iPhone is, and where home is. Shared with the extensions and
/// the Shortcuts actions through the app group.
public struct StulpPresenceSettings: Codable, Equatable, Sendable {
    public var phoneId: String
    public var phoneName: String
    public var latitude: Double?
    public var longitude: Double?
    /// Entering within this radius: home. Generous, so the alarm can be off before you reach the
    /// door.
    public var arriveRadius: Double = 300
    /// Leaving this radius: away.
    public var leaveRadius: Double = 150

    private static let key = "presence-settings"

    public init(phoneId: String, phoneName: String) {
        self.phoneId = phoneId
        self.phoneName = phoneName
    }

    public static func load() -> StulpPresenceSettings? {
        guard let data = try? sharedDefaults().data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StulpPresenceSettings.self, from: data)
    }

    public func save() throws {
        try sharedDefaults().set(JSONEncoder().encode(self), forKey: Self.key)
    }

    public static func remove() {
        try? sharedDefaults().removeObject(forKey: key)
    }
}

/// One report from the phone to Stulp (charger, home), from the app or a Shortcuts action. Without
/// a chosen phone or a connection nothing happens.
public enum StulpPresenceReport {
    public static func send(_ values: [String: Bool], source: String) async throws {
        guard let connection = try SharedStulpConfiguration.load() else {
            throw StulpPresenceError.notConnected
        }
        guard let settings = StulpPresenceSettings.load(), !settings.phoneId.isEmpty else {
            throw StulpPresenceError.noPhone
        }
        let client = StulpClient(connection: connection, logSource: source)
        try await client.report(deviceId: settings.phoneId, values: values)
        let text = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        client.trace("gemeld: \(text)")
    }
}

/// A fixed id per installation, for this app's phone device.
public enum StulpInstallation {
    public static var id: String {
        let key = "installation-id"
        if let existing = try? sharedDefaults().string(forKey: key), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        try? sharedDefaults().set(fresh, forKey: key)
        return fresh
    }
}

public enum StulpPresenceError: LocalizedError {
    case notConnected
    case noPhone

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Verbind de Stulp-app eerst met je Stulp."
        case .noPhone: "Kies in de Stulp-app eerst welk toestel dit is."
        }
    }
}

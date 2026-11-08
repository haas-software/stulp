import Foundation

/// One mutation from `GET /api/stulp/events` (server-sent events).
public struct StulpEvent: Sendable {
    /// `apps`, `devices`, `flow`, `scene`, `notifications`, `system` or `store`.
    public var manager: String
    /// For example `device.update`, `group.create`, `flow.run`, `store.reload`.
    public var type: String
    public var id: String?
    /// The full device on `device.update`, the record on `notification.create`; otherwise nil.
    public var data: JSONValue?

    public init(manager: String, type: String, id: String? = nil, data: JSONValue? = nil) {
        self.manager = manager
        self.type = type
        self.id = id
        self.data = data
    }
}

/// The live stream of mutations. Each yielded element is either `.opened` (the stream is live: take
/// a snapshot now, later events are waiting in the stream so nothing falls in between) or an event.
/// The stream ends when the connection does; reconnecting is the caller's choice.
public enum EventStreamElement: Sendable {
    case opened
    case event(StulpEvent)
}

extension StulpClient {
    static let streaming: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Stulp sends a keepalive after 15 s of silence; a minute without anything is a dead line.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public func events() -> AsyncThrowingStream<EventStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try request("/api/stulp/events")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await Self.streaming.bytes(for: request)
                    try Self.check(response, data: Data())
                    continuation.yield(.opened)
                    var parser = EventParser()
                    // Lines are split here and not with `bytes.lines`: that drops empty lines, and
                    // the empty line is what ends an event, so every event waited for the next.
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        guard byte == 0x0A else {
                            line.append(byte)
                            continue
                        }
                        if line.last == 0x0D { line.removeLast() }
                        if let event = parser.feed(String(decoding: line, as: UTF8.self)) {
                            continuation.yield(.event(event))
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    if let event = parser.feed("") { continuation.yield(.event(event)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Server-sent events framing: `event:` and `data:` lines, a blank line ends one event, a line
/// starting with `:` is a comment (Stulp's `connected` and keepalive).
struct EventParser {
    private var type = ""
    private var data: [String] = []

    /// `AsyncLineSequence` drops empty lines, so an `event:` line also ends the previous event.
    mutating func feed(_ line: String) -> StulpEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let (field, value) = Self.split(line)
        switch field {
        case "event":
            let finished = data.isEmpty ? nil : flush()
            type = value
            return finished
        case "data":
            data.append(value)
        default:
            break
        }
        return nil
    }

    private mutating func flush() -> StulpEvent? {
        defer {
            type = ""
            data = []
        }
        guard !data.isEmpty else { return nil }
        let text = data.joined(separator: "\n")
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        let manager = value["manager"]?.string ?? ""
        let kind = value["type"]?.string ?? type
        let payload = value["data"]
        return StulpEvent(
            manager: manager, type: kind, id: value["id"]?.string,
            data: payload == .null ? nil : payload)
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

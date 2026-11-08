import Foundation

/// One recorded series (`GET /api/stulp/statistics`): which device and capability Stulp keeps a
/// short history of. Stulp only records while statistics are switched on.
public struct StatisticsSeries: Sendable, Hashable, Decodable {
    public var deviceId: String
    public var capability: String
    /// `gauge` (average with min and max), `fraction` (share of the time on) or `counter` (used).
    public var kind: String
}

/// One window of a series: day (10-minute slots), week (2 hours) or month (5 hours).
public struct StatisticsWindow: Sendable, Decodable {
    public var kind: String
    public var window: String
    public var slots: [StatisticsSlot]
}

public struct StatisticsSlot: Sendable, Hashable, Decodable, Identifiable {
    public var at: Date
    public var count: Int
    public var average: Double?
    public var on: Double?
    public var used: Double?
    public var min: Double?
    public var max: Double?

    public var id: Date { at }

    enum CodingKeys: String, CodingKey { case at, count, average, on, used, min, max }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .at)
        guard let date = StulpDate.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "not a date: \(text)")
        }
        at = date
        count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
        average = try? c.decodeIfPresent(Double.self, forKey: .average)
        on = try? c.decodeIfPresent(Double.self, forKey: .on)
        used = try? c.decodeIfPresent(Double.self, forKey: .used)
        min = try? c.decodeIfPresent(Double.self, forKey: .min)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
    }

    /// The one number a chart draws for this slot, whatever the kind.
    public var value: Double? { average ?? on ?? used }
}

extension StulpClient {
    private struct SeriesList: Decodable { let series: [StatisticsSeries] }

    /// The series Stulp records for one device. Empty when statistics are off.
    public func statistics(device: String) async throws -> [StatisticsSeries] {
        let list: SeriesList = try await get("/api/stulp/statistics")
        return list.series.filter { $0.deviceId == device }
    }

    /// `window`: `day`, `week` or `month`. Values are in the app's own unit, not the house's.
    public func statistics(device: String, capability: String, window: String) async throws -> StatisticsWindow {
        try await get("/api/stulp/statistics/\(Self.escape(device))/\(Self.escape(capability))?window=\(window)")
    }
}

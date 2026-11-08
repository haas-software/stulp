import Charts
import StulpKit
import SwiftUI

/// What a device did over the last day, week or month, when Stulp keeps statistics. Hidden when
/// there is nothing recorded for this device (statistics off, or nothing numeric to keep).
struct HistorySection: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    /// The series recorded for this device, loaded by the card (see `load`).
    let series: [StatisticsSeries]

    enum Window: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: "Dag"
            case .week: "Week"
            case .month: "Maand"
            }
        }
    }

    @State private var selected: String?
    @State private var window = Window.day
    @State private var data: StatisticsWindow?
    @State private var failed = false

    var body: some View {
        Section {
            if series.count > 1 {
                Picker("Meting", selection: $selected) {
                    ForEach(series, id: \.capability) { s in
                        Text(title(s.capability)).tag(Optional(s.capability))
                    }
                }
                .pickerStyle(.menu)
            }
            Picker("Periode", selection: $window) {
                ForEach(Window.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            chart
                .frame(height: 180)
                .padding(.vertical, 4)
        } header: {
            Text("Geschiedenis")
        } footer: {
            Text("In de eenheid waarin de app meet.")
        }
        .task(id: "\(selected ?? "")/\(window.rawValue)") { await loadWindow() }
        .onAppear {
            let quick = DevicePresentation.quickCapability(device)?.id
            if selected == nil {
                selected = series.first { $0.capability == quick }?.capability ?? series.first?.capability
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if let data, !data.slots.isEmpty {
            let kind = data.kind
            Chart(data.slots) { slot in
                if kind == "gauge", let low = slot.min, let high = slot.max {
                    AreaMark(x: .value("Tijd", slot.at), yStart: .value("Laagst", low), yEnd: .value("Hoogst", high))
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                        .interpolationMethod(.monotone)
                }
                if let value = slot.value {
                    if kind == "gauge" {
                        LineMark(x: .value("Tijd", slot.at), y: .value("Gemiddeld", value))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                    } else {
                        BarMark(x: .value("Tijd", slot.at), y: .value(kind == "fraction" ? "Aan" : "Verbruik", kind == "fraction" ? value * 100 : value))
                            .foregroundStyle(Color.accentColor.gradient)
                    }
                }
            }
            .chartYAxisLabel(kind == "fraction" ? "% van de tijd aan" : "")
        } else if failed {
            Text("De geschiedenis is niet te laden.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if data != nil {
            Text("Nog niets vastgelegd in deze periode.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func title(_ capability: String) -> String {
        device[capability: capability]?.title ?? capability
    }

    /// The series of one device in the device's own capability order; empty when statistics are
    /// off or nothing is recorded, and then the section is left out.
    static func load(_ device: Device, client: StulpClient?) async -> [StatisticsSeries] {
        guard let client else { return [] }
        let found = (try? await client.statistics(device: device.id)) ?? []
        return found.sorted {
            (device.capabilities.firstIndex(of: $0.capability) ?? .max) < (device.capabilities.firstIndex(of: $1.capability) ?? .max)
        }
    }

    private func loadWindow() async {
        guard let client = model.client, let selected else { return }
        do {
            data = try await client.statistics(device: device.id, capability: selected, window: window.rawValue)
            failed = false
        } catch {
            failed = true
        }
    }
}

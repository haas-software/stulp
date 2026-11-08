import StulpKit
import SwiftUI

/// One accessory's controls, as Home shows them: who it is on top, one big control in the middle
/// (brightness, position, temperature, lock), and everything else it can do or report below.
/// Values arrive live through the model; whatever is set shows at once and the device's own
/// answer follows over the event stream.
struct DeviceDetailView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceID: String
    @State private var path: [DetailRoute] = DetailRoute.initial

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let device = model.devices[deviceID] {
                    DeviceDetailContent(device: device)
                } else {
                    ContentUnavailableView(
                        "Apparaat niet gevonden", systemImage: "questionmark.square.dashed",
                        description: Text("Het is verwijderd of nog niet geladen."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Klaar", systemImage: "xmark") { dismiss() }
                }
            }
            .navigationDestination(for: DetailRoute.self) { route in
                switch route {
                case .settings: DeviceSettingsView(deviceID: deviceID)
                }
            }
        }
        .macSheetSize(width: 560, height: 720)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
    }
}

enum DetailRoute: Hashable {
    case settings

    /// `-stulpDeviceSettings YES` (Debug): open straight into Instellingen, for screenshots.
    static var initial: [DetailRoute] {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "stulpDeviceSettings") ? [.settings] : []
        #else
        []
        #endif
    }
}

private struct DeviceDetailContent: View {
    @Environment(HomeModel.self) private var model
    let device: Device
    @State private var history: [StatisticsSeries] = []

    var body: some View {
        let primary = PrimaryControl.Kind(device: device)
        let rows = device.orderedCapabilities.filter { !primary.consumes($0) }
        Form {
            Section {
                DeviceHeader(device: device)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if primary != .none {
                Section {
                    PrimaryControl(device: device, kind: primary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }

            if device.deviceClass == "camera" || device.deviceClass == "doorbell" {
                CameraSection(device: device)
            }

            if !rows.isEmpty {
                Section(primary == .none ? "Status" : "Meer") {
                    ForEach(rows) { capability in
                        CapabilityRow(device: device, capability: capability)
                    }
                }
            }

            if !history.isEmpty {
                HistorySection(device: device, series: history)
            }

            Section {
                NavigationLink(value: DetailRoute.settings) {
                    Label("Instellingen", systemImage: "gearshape")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: device.id) { history = await HistorySection.load(device, client: model.client) }
        // The header already names the device, as Home's card does; a title above it would say
        // the same twice. It still names the back button of Instellingen.
        .navigationTitle(device.name)
        #if os(iOS)
        .toolbar(removing: .title)
        #endif
        .inlineTitle()
    }
}

/// Symbol, name, where it is and how it is: the top of Home's accessory card.
struct DeviceHeader: View {
    @Environment(HomeModel.self) private var model
    let device: Device

    var body: some View {
        let active = DevicePresentation.isActive(device)
        let alarming = DevicePresentation.isAlarming(device)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: DevicePresentation.symbol(device))
                    .font(.system(size: 26, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active || alarming ? Color.white : Color.secondary)
                    .frame(width: 56, height: 56)
                    .background(alarming ? AnyShapeStyle(Color.red) : active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.title2.weight(.bold))
                    let place = model.path(of: device.groupId)
                    Text(place.isEmpty ? (device.isScene ? "Scène" : "Geen ruimte") : place)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(DevicePresentation.status(device))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(device.available ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if !device.available {
                Label(
                    device.unavailableMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Stulp krijgt geen antwoord van dit apparaat.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let warning = device.warningMessage, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: active)
    }
}

#Preview("Lamp") {
    DeviceDetailView(deviceID: "lamp1").previewHouse()
}

#Preview("Thermostaat") {
    DeviceDetailView(deviceID: "thermo").previewHouse()
}

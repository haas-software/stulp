import StulpKit
import SwiftUI

/// A small house for previews and `-stulpDemo YES`: rooms, lights, sensors, a lock, a camera, a
/// scene and a battery, with values that look alive.
enum PreviewHouse {
    @MainActor
    static func fill(_ model: HomeModel) {
        let groups = [
            DeviceGroup(id: "woonkamer", name: "Woonkamer", sortOrder: 1),
            DeviceGroup(id: "keuken", name: "Keuken", sortOrder: 2),
            DeviceGroup(id: "slaapkamer", name: "Slaapkamer", sortOrder: 3),
            DeviceGroup(id: "tuin", name: "Tuin", sortOrder: 4),
            DeviceGroup(id: "bank", name: "Bank", parentId: "woonkamer", sortOrder: 1),
        ]
        func onoff(_ on: Bool) -> Capability {
            Capability(id: "onoff", title: "Aan/uit", type: "boolean", setable: true, value: .bool(on))
        }
        func dim(_ level: Double) -> Capability {
            Capability(id: "dim", title: "Dimniveau", type: "number", setable: true, value: .number(level), min: 0, max: 1, step: 0.01)
        }
        func temperature(_ t: Double) -> Capability {
            Capability(id: "measure_temperature", title: "Temperatuur", type: "number", value: .number(t), units: "°C", step: 0.1)
        }
        let devices = [
            Device(id: "lamp1", groupId: "woonkamer", sortOrder: 1, name: "Staande lamp", deviceClass: "light", capabilities: [onoff(true), dim(0.6)]),
            Device(id: "lamp2", groupId: "woonkamer", sortOrder: 2, name: "Plafond", deviceClass: "light", capabilities: [onoff(false), dim(0.3)]),
            Device(id: "tv", groupId: "bank", name: "Leeslamp", deviceClass: "light", capabilities: [onoff(false)]),
            Device(id: "thermo", groupId: "woonkamer", sortOrder: 3, name: "Thermostaat", deviceClass: "thermostat", capabilities: [
                Capability(id: "target_temperature", title: "Gewenste temperatuur", type: "number", setable: true, value: .number(20.5), units: "°C", min: 5, max: 30, step: 0.5),
                temperature(20.1),
            ]),
            Device(id: "lamp3", groupId: "keuken", sortOrder: 1, name: "Aanrecht", deviceClass: "light", capabilities: [onoff(true)]),
            Device(id: "motion", groupId: "keuken", sortOrder: 2, name: "Beweging", deviceClass: "sensor", capabilities: [
                Capability(id: "alarm_motion", title: "Beweging", type: "boolean", value: .bool(false)),
                Capability(id: "measure_battery", title: "Batterij", type: "number", value: .number(84), units: "%"),
            ]),
            Device(id: "door", groupId: "tuin", sortOrder: 1, name: "Achterdeur", deviceClass: "lock", capabilities: [
                Capability(id: "locked", title: "Op slot", type: "boolean", setable: true, value: .bool(true)),
            ]),
            Device(id: "cam", groupId: "tuin", sortOrder: 2, name: "Oprit", deviceClass: "camera", capabilities: [
                Capability(id: "alarm_motion", title: "Beweging", type: "boolean", value: .bool(false)),
            ]),
            Device(id: "blinds", groupId: "slaapkamer", sortOrder: 1, name: "Rolluik", deviceClass: "blinds", capabilities: [
                Capability(id: "windowcoverings_set", title: "Positie", type: "number", setable: true, value: .number(0.4), min: 0, max: 1, step: 0.01),
            ]),
            Device(id: "sensor2", groupId: "slaapkamer", sortOrder: 2, name: "Klimaat", deviceClass: "sensor", capabilities: [
                temperature(18.4),
                Capability(id: "measure_humidity", title: "Luchtvochtigheid", type: "number", value: .number(56), units: "%"),
            ]),
            Device(id: "battery", name: "Thuisbatterij", deviceClass: "battery", capabilities: [
                Capability(id: "measure_power", title: "Vermogen", type: "number", value: .number(-1240), units: "W"),
                Capability(id: "measure_battery", title: "Lading", type: "number", value: .number(72), units: "%"),
            ]),
            Device(id: "scene:avond", appId: "com.stulp.scene", name: "Avond", deviceClass: "scene", capabilities: [onoff(false)]),
            Device(id: "scene:weg", appId: "com.stulp.scene", name: "Weg", deviceClass: "scene", capabilities: [
                Capability(id: "button", title: "Activeren", type: "boolean", setable: true),
            ]),
            Device(id: "plug", groupId: "keuken", sortOrder: 3, name: "Koffie", deviceClass: "socket", capabilities: [onoff(false)], available: false),
        ]
        let flow = Flow(id: "f1", name: "Keuken: lamp bij beweging", enabled: true)
        model.fillDemo(devices: devices, groups: groups, flows: [flow])
    }
}

extension View {
    /// The demo house in the environment, for `#Preview`.
    @MainActor
    func previewHouse() -> some View {
        environment(HomeModel(demo: true))
    }
}

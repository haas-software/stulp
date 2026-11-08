import Foundation
import Testing
@testable import StulpKit

enum Fixtures {
    /// A device as a local Stulp answered it (virtual switch, full view).
    static let device = #"""
    {"id":"94af8fc7-9493-4338-b0d3-153746420eb6","appId":"com.stulp.virtualdevices","groupId":null,"sortOrder":null,
     "name":"Testlamp","class":"other","data":{"id":"Testlamp"},"settings":{},"capabilities":["onoff"],"available":true,
     "unavailableMessage":"","zone":"stulp-home","note":"","iconOverride":null,"virtualClass":null,"uiIndicator":null,
     "hidden":false,"warningMessage":null,"energy":null,"ownerUri":"stulp:app:com.stulp.virtualdevices","repair":false,
     "flags":[],"manufacturer":"Virtuele apparaten","driverId":"stulp:app:com.stulp.virtualdevices:switch",
     "hardwareName":"Testlamp","capabilitiesObj":{"onoff":{"id":"onoff","title":"Aan/uit","type":"boolean","getable":true,
     "setable":true,"lastUpdated":null,"value":false}},"ready":true,"unpair":true,"capabilitiesComplete":true,
     "detailComplete":true,"settingsObj":{},"ui":{}}
    """#

    /// A Matter lamp with a dim level and a power meter, as docs/web-api.md shows it.
    static let lamp = #"""
    {"id":"7f3c","appId":"com.stulp.matter","groupId":"g-woonkamer","sortOrder":3,"name":"Staande lamp",
     "class":"light","data":{"node":"0x12"},"settings":{},"capabilities":["onoff","dim","measure_power"],
     "available":true,"unavailableMessage":"","hidden":false,"warningMessage":null,
     "driverId":"stulp:app:com.stulp.matter:matter","hardwareName":"Staande lamp","manufacturer":"IKEA",
     "capabilitiesObj":{
      "onoff":{"id":"onoff","title":"Aan/uit","type":"boolean","getable":true,"setable":true,"lastUpdated":null,"value":true},
      "dim":{"id":"dim","title":"Dimniveau","type":"number","getable":true,"setable":true,"lastUpdated":null,"min":0.0,"max":1.0,"step":0.01,"value":0.6},
      "measure_power":{"id":"measure_power","title":"Vermogen","type":"number","getable":true,"setable":false,"lastUpdated":null,"units":"W","step":0.001,"value":7.2}}}
    """#

    static func decode(_ text: String) throws -> Device {
        try JSONDecoder().decode(Device.self, from: Data(text.utf8))
    }
}

@Suite("Modellen")
struct ModelTests {
    @Test func realDevice() throws {
        let device = try Fixtures.decode(Fixtures.device)
        #expect(device.name == "Testlamp")
        #expect(device.groupId == nil)
        #expect(device.deviceClass == "other")
        #expect(device.driverName == "switch")
        #expect(device[capability: "onoff"]?.bool == false)
        #expect(device[capability: "onoff"]?.setable == true)
    }

    @Test func lampKeepsDeclaredOrder() throws {
        let lamp = try Fixtures.decode(Fixtures.lamp)
        #expect(lamp.orderedCapabilities.map(\.id) == ["onoff", "dim", "measure_power"])
        #expect(lamp[capability: "measure_power"]?.units == "W")
        #expect(lamp.manufacturer == "IKEA")
    }

    /// An unknown value is unknown, never off or zero.
    @Test func nullValueIsNil() throws {
        let json = #"{"id":"x","name":"X","capabilitiesObj":{"onoff":{"id":"onoff","type":"boolean","value":null}}}"#
        let device = try Fixtures.decode(json)
        #expect(device[capability: "onoff"]?.value == nil)
        #expect(DevicePresentation.short(device[capability: "onoff"]!) == "—")
    }

    @Test func emptyGroupIdIsNoRoom() throws {
        let device = try Fixtures.decode(#"{"id":"x","name":"X","groupId":""}"#)
        #expect(device.groupId == nil)
        let group = try JSONDecoder().decode(DeviceGroup.self, from: Data(#"{"id":"g","name":"G","parentId":""}"#.utf8))
        #expect(group.parentId == nil)
    }

    @Test func localizedTitlesAndEnumValues() throws {
        let json = #"""
        {"id":"x","name":"X","capabilitiesObj":{"thermostat_mode":{"id":"thermostat_mode","title":{"en":"Mode","nl":"Modus"},
         "type":"enum","setable":true,"value":"heat","values":[{"id":"heat","title":{"en":"Heat","nl":"Verwarmen"}},{"id":"off","title":"Uit"}]}}}
        """#
        let mode = try #require(try Fixtures.decode(json)[capability: "thermostat_mode"])
        #expect(mode.title == "Modus")
        #expect(mode.values.map(\.title) == ["Verwarmen", "Uit"])
        #expect(DevicePresentation.display(mode) == "Verwarmen")
    }

    @Test func notificationDate() throws {
        let n = try JSONDecoder().decode(StulpNotification.self, from: Data(
            #"{"id":"n","appId":"com.stulp.notify","excerpt":"Deurbel","createdAt":"2026-08-10T19:28:06.140406Z"}"#.utf8))
        #expect(n.date != nil)
    }

    @Test func systemSettings() throws {
        let json = #"""
        {"units":{"temperature":"°C","power":""},"statistics":true,"statisticsBytes":2048,
         "unitsOffer":[{"name":"power","title":"Vermogen","canonical":"W","default":"","options":[{"unit":"","title":"Zoals de app het meldt"},{"unit":"W","title":"W"}]}]}
        """#
        let system = try JSONDecoder().decode(SystemSettings.self, from: Data(json.utf8))
        #expect(system.statistics)
        #expect(system.unitsOffer.first?.options.first?.unit == "")
        #expect(system.units["power"] == "")
    }
}

@Suite("Weergave")
struct PresentationTests {
    private func device(_ cls: String, _ caps: [Capability]) -> Device {
        Device(id: "d", name: "D", deviceClass: cls, capabilities: caps)
    }

    @Test func urgentAlarmComesFirst() {
        let d = device("sensor", [
            Capability(id: "measure_temperature", title: "T", type: "number", value: 20),
            Capability(id: "alarm_smoke", title: "Rook", type: "boolean", value: true),
        ])
        #expect(DevicePresentation.quickCapability(d)?.id == "alarm_smoke")
        #expect(DevicePresentation.isAlarming(d))
    }

    /// A numbered copy (`onoff.2`) shares its base's priority.
    @Test func numberedCopy() {
        let d = device("socket", [
            Capability(id: "measure_power", title: "P", type: "number", value: 3),
            Capability(id: "onoff.2", title: "Aan/uit 2", type: "boolean", setable: true, value: true),
        ])
        #expect(DevicePresentation.quickCapability(d)?.id == "onoff.2")
        #expect(DevicePresentation.toggleCapability(d)?.id == "onoff.2")
    }

    /// What a battery *is* goes before what it measures.
    @Test func batteryShowsPower() {
        let d = device("battery", [
            Capability(id: "measure_temperature", title: "T", type: "number", value: 31, units: "°C"),
            Capability(id: "measure_battery", title: "Lading", type: "number", value: 72, units: "%"),
            Capability(id: "measure_power", title: "Vermogen", type: "number", value: -1240, units: "W"),
        ])
        #expect(DevicePresentation.quickCapability(d)?.id == "measure_power")
        #expect(DevicePresentation.status(d) == "-1240 W")
    }

    @Test func dutchNumbers() {
        #expect(DevicePresentation.short(Capability(id: "target_temperature", title: "", type: "number", value: 20.5, units: "°C")) == "20,5°")
        #expect(DevicePresentation.short(Capability(id: "measure_temperature", title: "", type: "number", value: 21.0, units: "°C")) == "21°")
        #expect(DevicePresentation.short(Capability(id: "measure_humidity", title: "", type: "number", value: 56, units: "%")) == "56%")
        #expect(DevicePresentation.short(Capability(id: "dim", title: "", type: "number", value: 0.335)) == "34%")
        #expect(DevicePresentation.short(Capability(id: "measure_power", title: "", type: "number", value: 1234.6, units: "W")) == "1235 W")
    }

    @Test func dimmedLampReadsItsLevel() throws {
        let lamp = try Fixtures.decode(Fixtures.lamp)
        #expect(DevicePresentation.status(lamp) == "60%")
        #expect(DevicePresentation.isActive(lamp))
        #expect(DevicePresentation.symbol(lamp) == "lightbulb.fill")
    }

    @Test func unavailable() {
        var d = device("light", [Capability(id: "onoff", title: "", type: "boolean", setable: true, value: true)])
        d.available = false
        #expect(DevicePresentation.status(d) == "Geen reactie")
        #expect(!DevicePresentation.isActive(d))
        #expect(DevicePresentation.toggleCapability(d) == nil)
    }

    @Test func wordsForBooleans() {
        let lock = Capability(id: "locked", title: "", type: "boolean", setable: true, value: true)
        #expect(DevicePresentation.short(lock) == "Op slot")
        #expect(DevicePresentation.words("locked", true).action == "van het slot doen")
        #expect(DevicePresentation.words("speaker_playing", true).action == "pauzeren")
        #expect(DevicePresentation.short(Capability(id: "alarm_contact", title: "", type: "boolean", value: true)) == "Open")
    }

    @Test func categories() {
        typealias C = DevicePresentation.Category
        #expect(DevicePresentation.categories(device("light", [])) == [C.lights])
        #expect(DevicePresentation.categories(device("thermostat", [])) == [C.climate])
        #expect(DevicePresentation.categories(device("sensor", [
            Capability(id: "alarm_contact", title: "", type: "boolean"),
            Capability(id: "measure_temperature", title: "", type: "number"),
        ])) == [C.security, C.climate])
        #expect(DevicePresentation.categories(device("other", [])).isEmpty)
    }

    @Test func summaries() {
        let lamps = [
            device("light", [Capability(id: "onoff", title: "", type: "boolean", value: true)]),
            device("light", [Capability(id: "onoff", title: "", type: "boolean", value: false)]),
        ]
        #expect(DevicePresentation.summary(.lights, devices: lamps) == "1 aan")
        let sensors = [
            device("sensor", [Capability(id: "measure_temperature", title: "", type: "number", value: 18.4)]),
            device("thermostat", [Capability(id: "measure_temperature", title: "", type: "number", value: 21.2)]),
        ]
        #expect(DevicePresentation.summary(.climate, devices: sensors) == "18–21°")
    }
}

import Foundation

/// How a device reads: the one value a tile shows, the words for a boolean, the symbol for its
/// class and the category it belongs to. The rules are the ones Manage had, so a tile says the same
/// thing it always said; they live here (not in a view) so they are tested.
public enum DevicePresentation {
    // MARK: - The tile's one capability

    /// One ordered list decides every tile's quick control or status. `onoff.2` shares `onoff`'s
    /// priority. Urgent alarms come first: a smoke detector that goes off says so on its tile.
    static let priority = [
        "alarm_smoke", "alarm_fire", "alarm_co", "alarm_co2", "alarm_vape", "alarm_water", "alarm_heat",
        "onoff", "locked", "garagedoor_closed", "windowcoverings_state", "homealarm_state",
        "alarm_motion", "alarm_contact", "alarm_glassbreak", "alarm_vibration", "alarm_generic", "alarm_pressure", "alarm_night",
        "speaker_playing", "volume_mute", "vacuumcleaner_state", "dim",
        "target_temperature", "measure_temperature", "thermostat_mode",
        "measure_humidity", "measure_co2", "measure_co", "measure_pm25", "air_quality_state", "measure_luminance",
        "measure_pressure", "measure_noise",
        "measure_rain", "measure_water", "measure_wind_strength", "measure_gust_strength", "measure_wind_angle", "measure_ultraviolet",
        "measure_battery", "alarm_battery", "alarm_tamper",
        "measure_power", "meter_power", "measure_current", "measure_voltage", "meter_water", "meter_gas",
        "volume_set", "speaker_track", "speaker_artist", "light_temperature", "light_mode", "light_hue", "light_saturation",
        "windowcoverings_set", "lock_mode", "button",
    ]

    /// What a device *is* goes before what it happens to measure: a home battery's cell temperature
    /// is correct and useless. Power before charge, because the system unit already shows the charge.
    static let priorityByClass = [
        "battery": ["measure_power", "measure_battery", "battery_charging_state"],
    ]

    public static let urgentAlarms: Set<String> = [
        "alarm_smoke", "alarm_fire", "alarm_co", "alarm_co2", "alarm_vape", "alarm_water", "alarm_heat",
    ]

    public static func quickCapability(_ device: Device) -> Capability? {
        let all = device.orderedCapabilities
        for wanted in (priorityByClass[device.deviceClass] ?? []) + priority {
            if let found = all.first(where: { $0.base == wanted }) { return found }
        }
        let fallbacks: [(Capability) -> Bool] = [
            { $0.base.hasPrefix("alarm_") },
            { $0.setable && $0.isBoolean },
            { $0.base.hasPrefix("measure_") },
            { $0.base.hasPrefix("meter_") },
        ]
        for test in fallbacks {
            if let found = all.first(where: test) { return found }
        }
        return all.first
    }

    /// A capability without state: pressing it does something, it is never on or off.
    public static func isStateless(_ capability: Capability) -> Bool {
        ["speaker_prev", "speaker_next", "button"].contains(capability.base)
    }

    /// The tile toggles with one tap: a settable boolean with state, or a scene button.
    public static func toggleCapability(_ device: Device) -> Capability? {
        guard device.available, let quick = quickCapability(device), quick.setable else { return nil }
        if quick.isBoolean { return quick }
        return nil
    }

    /// Whether the tile looks "on": lit, open, playing, alarming. Home shows exactly that difference.
    public static func isActive(_ device: Device) -> Bool {
        guard device.available, let quick = quickCapability(device) else { return false }
        switch quick.base {
        case "dim", "windowcoverings_set": return (quick.number ?? 0) > 0
        case "locked", "garagedoor_closed": return quick.bool == false
        case "windowcoverings_state": return quick.value?.string == "up"
        default: break
        }
        if quick.base.hasPrefix("alarm_") { return quick.bool == true }
        if quick.isBoolean, !isStateless(quick) { return quick.bool == true }
        // A lamp that only reports its dim level and is off still has `onoff`.
        if let onoff = device[capability: "onoff"] { return onoff.bool == true }
        return false
    }

    public static func isAlarming(_ device: Device) -> Bool {
        device.orderedCapabilities.contains { urgentAlarms.contains($0.base) && $0.bool == true }
    }

    /// The short status under a tile's name: "Aan", "45%", "21,5°", "Geen reactie".
    public static func status(_ device: Device) -> String {
        guard device.available else { return "Geen reactie" }
        if device.isScene {
            return device[capability: "onoff"].map { $0.bool == true ? "Actief" : "Uit" } ?? "Scène"
        }
        guard let quick = quickCapability(device) else { return "" }
        // A dimmable lamp that is on reads its level, as in Home.
        if quick.base == "onoff", quick.bool == true, let dim = device[capability: "dim"], let level = dim.number {
            return "\(Int((level * 100).rounded()))%"
        }
        return short(quick)
    }

    // MARK: - Values

    /// The compact value of a tile: Dutch decimal comma, no trailing ",0", "°C" as "°".
    public static func short(_ capability: Capability) -> String {
        guard let value = capability.value, value != .string("") else { return "—" }
        if capability.isBoolean, let b = value.bool { return words(capability.base, b).state.capitalizedFirst }
        guard let n = value.number else { return display(capability) }
        if capability.base == "dim" || capability.base == "windowcoverings_set" { return "\(Int((n * 100).rounded()))%" }
        let decimals = ["measure_temperature", "target_temperature", "measure_humidity", "measure_pressure"].contains(capability.base) ? 1 : 0
        let text = number(n, decimals: decimals)
        switch capability.units ?? "" {
        case "": return text
        case "%": return "\(text)%"
        case "°C": return "\(text)°"
        case let units: return "\(text) \(units)"
        }
    }

    /// The full value of a row in a device's detail: enum titles, words for booleans, the unit.
    public static func display(_ capability: Capability) -> String {
        guard let value = capability.value, value != .string("") else { return "—" }
        if let match = capability.values.first(where: { $0.id == value.text }) { return match.title }
        if capability.isBoolean, let b = value.bool { return words(capability.base, b).state.capitalizedFirst }
        if let n = value.number {
            if let min = capability.min, let max = capability.max, min == 0, max == 1, capability.units == nil {
                return "\(Int((n * 100).rounded()))%"
            }
            let decimals = capability.step.map { $0 >= 1 ? 0 : min(3, Int((-log10($0)).rounded(.up))) } ?? 1
            let text = number(n, decimals: decimals)
            guard let units = capability.units, !units.isEmpty else { return text }
            return units == "%" ? "\(text)%" : "\(text) \(units)"
        }
        return value.text
    }

    public static func number(_ n: Double, decimals: Int) -> String {
        n.formatted(.number.precision(.fractionLength(0...max(0, decimals))).locale(Locale(identifier: "nl_NL")).grouping(.never))
    }

    /// The words for a boolean. A button says what pressing it does; a state says what is.
    public struct Words: Sendable {
        public let on: String
        public let off: String
        public let turnOn: String
        public let turnOff: String
        let current: Bool

        public var state: String { current ? on : off }
        public var action: String { current ? turnOff : turnOn }
    }

    public static func words(_ base: String, _ value: Bool) -> Words {
        let w: (String, String, String, String) = switch base {
        case "off_grid": ("noodstroom", "op het net", "van het net schakelen", "opnieuw met het net verbinden")
        case "speaker_playing": ("speelt", "gepauzeerd", "afspelen", "pauzeren")
        case "volume_mute": ("stil", "geluid aan", "dempen", "geluid aanzetten")
        case "locked": ("op slot", "open", "op slot doen", "van het slot doen")
        case "garagedoor_closed": ("dicht", "open", "sluiten", "openen")
        case "alarm_contact": ("open", "dicht", "", "")
        case "alarm_motion": ("beweging", "geen beweging", "", "")
        case "alarm_battery": ("batterij bijna leeg", "batterij in orde", "", "")
        case "alarm_tamper": ("gesaboteerd", "in orde", "", "")
        case "alarm_smoke": ("rook", "geen rook", "", "")
        case "alarm_water": ("water", "droog", "", "")
        case "onoff", "": ("aan", "uit", "aanzetten", "uitzetten")
        default:
            base.hasPrefix("alarm_") ? ("alarm", "rustig", "", "") : ("aan", "uit", "aanzetten", "uitzetten")
        }
        return Words(on: w.0, off: w.1, turnOn: w.2, turnOff: w.3, current: value)
    }

    // MARK: - Symbols and categories

    /// The SF Symbol of a device class, filled; `active` picks the open/lit variant where one exists.
    public static func symbol(_ device: Device) -> String {
        let active = isActive(device)
        switch device.deviceClass {
        case "light": return active ? "lightbulb.fill" : "lightbulb"
        case "socket": return "poweroutlet.type.f.fill"
        case "camera": return "video.fill"
        case "doorbell": return "video.doorbell.fill"
        case "lock": return active ? "lock.open.fill" : "lock.fill"
        case "sensor":
            if device[capability: "alarm_contact"] != nil { return active ? "door.left.hand.open" : "door.left.hand.closed" }
            if device[capability: "alarm_motion"] != nil { return "figure.walk.motion" }
            if device[capability: "alarm_smoke"] != nil { return "smoke.fill" }
            if device[capability: "alarm_water"] != nil { return "drop.fill" }
            if device[capability: "measure_temperature"] != nil { return "thermometer.medium" }
            return "sensor.fill"
        case "weather": return "cloud.sun.fill"
        case "phone": return "iphone"
        case "thermostat": return "thermometer.medium"
        case "heater": return "heat.waves"
        case "airconditioning": return "air.conditioner.horizontal.fill"
        case "fan": return "fan.fill"
        case "speaker", "tv", "amplifier": return "hifispeaker.fill"
        case "blinds", "sunshade": return active ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        case "windowcoverings", "curtain": return active ? "curtains.open" : "curtains.closed"
        case "garagedoor": return active ? "door.garage.open" : "door.garage.closed"
        case "battery": return "bolt.batteryblock.fill"
        case "solarpanel": return "sun.max.fill"
        case "heatpump": return "heat.waves"
        case "evcharger": return "ev.charger.fill"
        case "homealarm": return "shield.lefthalf.filled"
        case "scene": return "sparkles"
        case "kettle", "coffeemachine", "washer", "dryer", "dishwasher", "vacuumcleaner": return "washer.fill"
        default: return "switch.2"
        }
    }

    /// The categories at the top of Home, in Home's order. A device can be in more than one.
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case climate, lights, security, coverings, energy, media

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .climate: "Klimaat"
            case .lights: "Verlichting"
            case .security: "Beveiliging"
            case .coverings: "Raambekleding"
            case .energy: "Energie"
            case .media: "Media"
            }
        }

        public var symbol: String {
            switch self {
            case .climate: "thermometer.medium"
            case .lights: "lightbulb.fill"
            case .security: "lock.fill"
            case .coverings: "blinds.horizontal.closed"
            case .energy: "bolt.fill"
            case .media: "hifispeaker.fill"
            }
        }
    }

    public static func categories(_ device: Device) -> Set<Category> {
        var out: Set<Category> = []
        switch device.deviceClass {
        case "light": out.insert(.lights)
        case "thermostat", "heater", "heatpump", "airconditioning", "fan": out.insert(.climate)
        case "lock", "camera", "doorbell", "homealarm", "garagedoor": out.insert(.security)
        case "blinds", "sunshade", "windowcoverings", "curtain": out.insert(.coverings)
        case "battery", "solarpanel", "evcharger": out.insert(.energy)
        case "speaker", "tv", "amplifier": out.insert(.media)
        default: break
        }
        let bases = Set(device.capabilities.map { $0.split(separator: ".").first.map(String.init) ?? $0 })
        if device.deviceClass == "sensor" || device.deviceClass == "weather" {
            if bases.contains("measure_temperature") || bases.contains("measure_humidity") { out.insert(.climate) }
        }
        if bases.contains("alarm_contact") || bases.contains("alarm_motion") || bases.contains("locked")
            || !bases.isDisjoint(with: urgentAlarms) {
            out.insert(.security)
        }
        if device.deviceClass == "socket", bases.contains("measure_power") { out.insert(.energy) }
        return out
    }

    /// The summary on a category button: "3 aan", "19–22°", "Alles op slot".
    public static func summary(_ category: Category, devices: [Device]) -> String {
        let members = devices.filter { $0.available && categories($0).contains(category) }
        switch category {
        case .lights:
            let on = members.filter { $0.deviceClass == "light" && $0[capability: "onoff"]?.bool == true }.count
            return on == 0 ? "Alles uit" : "\(on) aan"
        case .climate:
            let temperatures = members.compactMap { $0[capability: "measure_temperature"]?.number }
            guard let low = temperatures.min(), let high = temperatures.max() else { return "" }
            let a = number(low, decimals: 0), b = number(high, decimals: 0)
            return a == b ? "\(a)°" : "\(a)–\(b)°"
        case .security:
            if members.contains(where: isAlarming) { return "Alarm" }
            let open = members.filter {
                $0[capability: "alarm_contact"]?.bool == true || $0[capability: "locked"]?.bool == false
            }.count
            return open == 0 ? "Alles dicht" : "\(open) open"
        case .coverings:
            let open = members.filter(isActive).count
            return open == 0 ? "Alles dicht" : "\(open) open"
        case .energy:
            let watts = members.compactMap { device -> Double? in
                guard let power = device[capability: "measure_power"], let n = power.number else { return nil }
                return power.units == "kW" ? n * 1000 : n
            }
            guard !watts.isEmpty else { return "" }
            let total = watts.reduce(0, +)
            return abs(total) >= 1000 ? "\(number(total / 1000, decimals: 1)) kW" : "\(number(total, decimals: 0)) W"
        case .media:
            let playing = members.filter { $0[capability: "speaker_playing"]?.bool == true }.count
            return playing == 0 ? "Stil" : "\(playing) speelt"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

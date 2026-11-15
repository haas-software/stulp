//! Welke tegel een ESPHome-entiteit wordt. Alleen wat het apparaat zelf meldt
//! krijgt een tegel; configuratie en diagnose (herstarten, uptime, IP) niet.
use crate::api::{CATEGORY_NONE, Entity, Kind, Reading};
use alloc::string::String;
use stulp_core::json::{self, Value};
use stulp_sdk::{Result, util::float};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Driver {
    /// Een deurbel: vaste tegels met eigen titels en de flowkaart "Er werd aangebeld".
    Doorbell,
    /// Elk ander ESPHome-apparaat: een tegel per entiteit, `<soort>.<object_id>`.
    Device,
}
impl Driver {
    pub(crate) fn parse(id: &str) -> Option<Self> {
        match id {
            "doorbell" => Some(Self::Doorbell),
            "device" => Some(Self::Device),
            _ => None,
        }
    }
}

/// De capabilities die deze app zelf beheert bij een deurbel.
pub(crate) const DOORBELL: [&str; 3] = ["alarm_generic", "onoff", "measure_signal_strength"];

/// Een project of naam dat op een deurbel wijst, zoals `zuidwijk.doorbell`.
pub(crate) fn is_doorbell(project: &str, name: &str) -> bool {
    let has = |s: &str| {
        let s = s.to_ascii_lowercase();
        s.contains("doorbell") || s.contains("deurbel")
    };
    has(project) || has(name)
}

fn signal(e: &Entity) -> bool {
    e.kind == Kind::Sensor && e.device_class == "signal_strength"
}

/// De binary sensor die "er wordt aangebeld" betekent: niet de statussensor,
/// en bij voorkeur een met bel of ring in zijn naam.
pub(crate) fn bell(entities: &[Entity]) -> Option<u32> {
    let candidates = || {
        entities
            .iter()
            .filter(|e| e.kind == Kind::BinarySensor && !e.status && e.category == CATEGORY_NONE)
    };
    candidates()
        .find(|e| {
            let id = e.object_id.as_str();
            id.contains("bell") || id.contains("ring") || id.contains("button")
        })
        .or_else(|| candidates().next())
        .map(|e| e.key)
}

fn valid_suffix(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

fn sensor_base(class: &str) -> Option<&'static str> {
    Some(match class {
        "temperature" => "measure_temperature",
        "humidity" => "measure_humidity",
        "power" => "measure_power",
        "energy" => "meter_power",
        "voltage" => "measure_voltage",
        "current" => "measure_current",
        "illuminance" => "measure_luminance",
        "battery" => "measure_battery",
        "pressure" => "measure_pressure",
        "carbon_dioxide" => "measure_co2",
        "pm25" => "measure_pm25",
        "signal_strength" => "measure_signal_strength",
        _ => return None,
    })
}

fn binary_base(class: &str) -> &'static str {
    match class {
        "motion" | "occupancy" | "presence" => "alarm_motion",
        "door" | "window" | "opening" | "garage_door" => "alarm_contact",
        "moisture" => "alarm_water",
        "smoke" => "alarm_smoke",
        "tamper" => "alarm_tamper",
        _ => "alarm_generic",
    }
}

/// De capability voor een entiteit, of `None` als die geen tegel krijgt.
pub(crate) fn capability(driver: Driver, e: &Entity, all: &[Entity]) -> Result<Option<String>> {
    if driver == Driver::Doorbell {
        let cap = match e.kind {
            Kind::BinarySensor if bell(all) == Some(e.key) => "alarm_generic",
            Kind::Switch if e.object_id.contains("chime") || e.object_id.contains("gong") => {
                "onoff"
            }
            Kind::Sensor if signal(e) => "measure_signal_strength",
            _ => return Ok(None),
        };
        return Ok(Some(json::copy(cap)?));
    }
    // Het WiFi-signaal is diagnose, maar wel het eerste waar je naar kijkt
    // als een apparaat wegvalt; dat ene blijft.
    if (e.category != CATEGORY_NONE && !signal(e)) || e.status || !valid_suffix(&e.object_id) {
        return Ok(None);
    }
    let base = match e.kind {
        Kind::BinarySensor => binary_base(&e.device_class),
        Kind::Sensor => match sensor_base(&e.device_class) {
            Some(b) => b,
            None => return Ok(None),
        },
        Kind::Switch => "onoff",
        // Tekst heeft geen tegel, en een knop zonder vaste capability is in
        // de app niet in te drukken; beide horen bij een latere versie.
        Kind::TextSensor | Kind::Button => return Ok(None),
    };
    Ok(Some(stulp_sdk::util::join(&[base, ".", &e.object_id])?))
}

/// De bases die deze app zelf toevoegt; alleen die mag hij ook weer weghalen.
pub(crate) fn owned(driver: Driver, cap: &str) -> bool {
    match driver {
        Driver::Doorbell => DOORBELL.contains(&cap),
        Driver::Device => cap.split_once('.').is_some_and(|(base, suffix)| {
            valid_suffix(suffix)
                && (base == "onoff"
                    || base.starts_with("alarm_")
                    || base.starts_with("measure_")
                    || base == "meter_power")
        }),
    }
}

fn rounded(n: f64, decimals: u64) -> f64 {
    let scale = [1.0, 10.0, 100.0, 1000.0, 10_000.0][decimals.min(4) as usize];
    let v = n * scale;
    if !v.is_finite() || v.abs() > 9.0e15 {
        return n;
    }
    let r = if v >= 0.0 { v + 0.5 } else { v - 0.5 };
    (r as i64) as f64 / scale
}

/// De waarde voor een tegel; `None` als de stand er niet bij past of onbekend is.
pub(crate) fn value(e: &Entity, cap: &str, reading: &Reading) -> Result<Option<Value>> {
    Ok(match reading {
        Reading::Bool(b) if matches!(e.kind, Kind::BinarySensor | Kind::Switch) => {
            Some(Value::Bool(*b))
        }
        Reading::Number(n) if e.kind == Kind::Sensor => {
            let (n, decimals) = if cap.starts_with("meter_power") && e.unit == "Wh" {
                (n / 1000.0, e.decimals + 3)
            } else {
                (*n, e.decimals)
            };
            Some(float(rounded(n, decimals))?)
        }
        _ => None,
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::tests::doorbell_entities;
    #[test]
    fn the_zuidwijk_doorbell_gets_bell_chime_and_signal_only() {
        let all = doorbell_entities();
        let caps: alloc::vec::Vec<_> = all
            .iter()
            .filter_map(|e| capability(Driver::Doorbell, e, &all).unwrap())
            .collect();
        assert_eq!(caps, ["alarm_generic", "measure_signal_strength", "onoff"]);
        let caps: alloc::vec::Vec<_> = all
            .iter()
            .filter_map(|e| capability(Driver::Device, e, &all).unwrap())
            .collect();
        assert_eq!(
            caps,
            [
                "alarm_generic.doorbell",
                "measure_signal_strength.doorbell_wifi_signal",
                "onoff.doorbell_chime_active"
            ]
        );
        assert!(is_doorbell("zuidwijk.doorbell", "x"));
        assert!(!is_doorbell("esphome.bluetooth-proxy", "proxy"));
    }
    #[test]
    fn readings_are_rounded_to_the_sensors_own_precision() {
        let all = doorbell_entities();
        let wifi = all
            .iter()
            .find(|e| e.object_id == "doorbell_wifi_signal")
            .unwrap();
        assert_eq!(
            value(
                wifi,
                "measure_signal_strength",
                &Reading::Number(-66.000_001)
            )
            .unwrap(),
            Some(float(-66.0).unwrap())
        );
        assert_eq!(
            value(wifi, "measure_signal_strength", &Reading::Missing).unwrap(),
            None
        );
        assert!(owned(Driver::Device, "onoff.doorbell_chime_active"));
        assert!(!owned(Driver::Device, "onoff"));
        assert!(!owned(Driver::Doorbell, "dim"));
    }
}

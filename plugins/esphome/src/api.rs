//! ESPHome's native API zonder versleuteling: 0x00, varint-lengte, varint-type
//! en dan een protobufbericht. Alleen de berichten die Stulp nodig heeft.
use alloc::{string::String, vec::Vec};
use stulp_core::json;
use stulp_sdk::{Error, Result};

pub(crate) const HELLO_REQUEST: u32 = 1;
pub(crate) const HELLO_RESPONSE: u32 = 2;
pub(crate) const CONNECT_REQUEST: u32 = 3;
pub(crate) const CONNECT_RESPONSE: u32 = 4;
pub(crate) const DISCONNECT_REQUEST: u32 = 5;
pub(crate) const DISCONNECT_RESPONSE: u32 = 6;
pub(crate) const PING_REQUEST: u32 = 7;
pub(crate) const PING_RESPONSE: u32 = 8;
pub(crate) const DEVICE_INFO_REQUEST: u32 = 9;
pub(crate) const DEVICE_INFO_RESPONSE: u32 = 10;
pub(crate) const LIST_ENTITIES_REQUEST: u32 = 11;
pub(crate) const LIST_BINARY_SENSOR: u32 = 12;
pub(crate) const LIST_SENSOR: u32 = 16;
pub(crate) const LIST_SWITCH: u32 = 17;
pub(crate) const LIST_TEXT_SENSOR: u32 = 18;
pub(crate) const LIST_DONE: u32 = 19;
pub(crate) const SUBSCRIBE_STATES: u32 = 20;
pub(crate) const BINARY_SENSOR_STATE: u32 = 21;
pub(crate) const SENSOR_STATE: u32 = 25;
pub(crate) const SWITCH_STATE: u32 = 26;
pub(crate) const TEXT_SENSOR_STATE: u32 = 27;
pub(crate) const SWITCH_COMMAND: u32 = 33;
pub(crate) const GET_TIME_REQUEST: u32 = 36;
pub(crate) const GET_TIME_RESPONSE: u32 = 37;
pub(crate) const LIST_BUTTON: u32 = 61;

/// Het grootste bericht dat Stulp aanneemt; een entiteitenlijst blijft ver daaronder.
pub(crate) const MAX_MESSAGE: usize = 16 * 1024;
/// Zoveel onverwerkte bytes mag één verbinding vasthouden.
const MAX_BUFFER: usize = 64 * 1024;

fn push(out: &mut Vec<u8>, bytes: &[u8]) -> Result {
    if bytes.len() > MAX_MESSAGE.saturating_sub(out.len()) {
        return Err(Error::Invalid("ESPHome-bericht te groot"));
    }
    out.try_reserve(bytes.len())
        .map_err(|_| stulp_core::Error::Memory)?;
    out.extend_from_slice(bytes);
    Ok(())
}

fn varint(out: &mut Vec<u8>, mut n: u64) -> Result {
    let mut bytes = [0u8; 10];
    let mut len = 0;
    loop {
        let low = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            bytes[len] = low;
            len += 1;
            break;
        }
        bytes[len] = low | 0x80;
        len += 1;
    }
    push(out, &bytes[..len])
}

/// Een protobufbody, veld voor veld opgebouwd.
#[derive(Default)]
pub(crate) struct Body(Vec<u8>);
impl Body {
    pub(crate) fn text(mut self, field: u32, value: &str) -> Result<Self> {
        varint(&mut self.0, u64::from(field) << 3 | 2)?;
        varint(&mut self.0, value.len() as u64)?;
        push(&mut self.0, value.as_bytes())?;
        Ok(self)
    }
    pub(crate) fn uint(mut self, field: u32, value: u64) -> Result<Self> {
        varint(&mut self.0, u64::from(field) << 3)?;
        varint(&mut self.0, value)?;
        Ok(self)
    }
    pub(crate) fn fixed32(mut self, field: u32, value: u32) -> Result<Self> {
        varint(&mut self.0, u64::from(field) << 3 | 5)?;
        push(&mut self.0, &value.to_le_bytes())?;
        Ok(self)
    }
    pub(crate) fn boolean(self, field: u32, value: bool) -> Result<Self> {
        self.uint(field, u64::from(value))
    }
}

/// Eén compleet frame zoals het over de socket gaat.
pub(crate) fn frame(kind: u32, body: Body) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    push(&mut out, &[0])?;
    varint(&mut out, body.0.len() as u64)?;
    varint(&mut out, u64::from(kind))?;
    push(&mut out, &body.0)?;
    Ok(out)
}

/// Leest een varint vanaf `at`; `None` als de bytes nog niet binnen zijn.
fn read_varint(bytes: &[u8], at: &mut usize) -> Result<Option<u64>> {
    let mut n = 0u64;
    for shift in 0..10u32 {
        let Some(byte) = bytes.get(*at) else {
            return Ok(None);
        };
        *at += 1;
        n |= u64::from(byte & 0x7f) << (7 * shift);
        if byte & 0x80 == 0 {
            return Ok(Some(n));
        }
    }
    Err(Error::Invalid("ongeldige varint van ESPHome"))
}

/// Knipt binnenkomende bytes in berichten, ook als die over meerdere pakketten vallen.
#[derive(Default)]
pub(crate) struct Decoder {
    buffer: Vec<u8>,
}
impl Decoder {
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Result {
        if bytes.len() > MAX_BUFFER.saturating_sub(self.buffer.len()) {
            return Err(Error::Invalid("ESPHome stuurt meer dan Stulp bijhoudt"));
        }
        self.buffer
            .try_reserve(bytes.len())
            .map_err(|_| stulp_core::Error::Memory)?;
        self.buffer.extend_from_slice(bytes);
        Ok(())
    }
    /// Het volgende complete bericht: type en body.
    pub(crate) fn next(&mut self) -> Result<Option<(u32, Vec<u8>)>> {
        let Some(first) = self.buffer.first() else {
            return Ok(None);
        };
        if *first != 0 {
            return Err(Error::Invalid(
                "Dit ESPHome-apparaat versleutelt zijn API (encryption key); dat ondersteunt Stulp nog niet.",
            ));
        }
        let mut at = 1;
        let Some(len) = read_varint(&self.buffer, &mut at)? else {
            return Ok(None);
        };
        let Some(kind) = read_varint(&self.buffer, &mut at)? else {
            return Ok(None);
        };
        let len = usize::try_from(len)
            .ok()
            .filter(|n| *n <= MAX_MESSAGE)
            .ok_or(Error::Invalid("ESPHome-bericht te groot"))?;
        let kind = u32::try_from(kind).map_err(|_| Error::Invalid("onbekend ESPHome-bericht"))?;
        let end = at
            .checked_add(len)
            .ok_or(Error::Invalid("ESPHome-bericht te groot"))?;
        if self.buffer.len() < end {
            return Ok(None);
        }
        let mut body = Vec::new();
        push(&mut body, &self.buffer[at..end])?;
        self.buffer.drain(..end);
        Ok(Some((kind, body)))
    }
}

/// Eén protobufwaarde; lengte-begrensde velden blijven een lening.
#[derive(Clone, Copy)]
pub(crate) enum Wire<'a> {
    Varint(u64),
    Fixed32(u32),
    Fixed64,
    Bytes(&'a [u8]),
}

/// Alle velden van een body, in volgorde; een kapotte body is een fout.
pub(crate) fn fields(body: &[u8]) -> Result<Vec<(u32, Wire<'_>)>> {
    let truncated = || Error::Invalid("afgekapt ESPHome-bericht");
    let mut out = Vec::new();
    let mut at = 0;
    while at < body.len() {
        let key = read_varint(body, &mut at)?.ok_or_else(truncated)?;
        let number = u32::try_from(key >> 3).map_err(|_| truncated())?;
        let value = match key & 7 {
            0 => Wire::Varint(read_varint(body, &mut at)?.ok_or_else(truncated)?),
            1 => {
                body.get(at..at + 8).ok_or_else(truncated)?;
                at += 8;
                Wire::Fixed64
            }
            2 => {
                let len = read_varint(body, &mut at)?.ok_or_else(truncated)?;
                let len = usize::try_from(len).map_err(|_| truncated())?;
                let end = at.checked_add(len).ok_or_else(truncated)?;
                let bytes = body.get(at..end).ok_or_else(truncated)?;
                at = end;
                Wire::Bytes(bytes)
            }
            5 => {
                let b = body.get(at..at + 4).ok_or_else(truncated)?;
                at += 4;
                Wire::Fixed32(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            }
            _ => return Err(Error::Invalid("onbekend protobuftype van ESPHome")),
        };
        json::push(&mut out, (number, value), 256)?;
    }
    Ok(out)
}

fn text(fields: &[(u32, Wire<'_>)], number: u32) -> Result<String> {
    for (n, v) in fields {
        if *n == number
            && let Wire::Bytes(bytes) = v
        {
            let s = core::str::from_utf8(bytes)
                .map_err(|_| Error::Invalid("ESPHome-tekst is geen UTF-8"))?;
            return Ok(json::copy(s)?);
        }
    }
    Ok(String::new())
}
fn uint(fields: &[(u32, Wire<'_>)], number: u32) -> u64 {
    fields
        .iter()
        .find_map(|(n, v)| match v {
            Wire::Varint(x) if *n == number => Some(*x),
            _ => None,
        })
        .unwrap_or(0)
}
fn fixed32(fields: &[(u32, Wire<'_>)], number: u32) -> Option<u32> {
    fields.iter().find_map(|(n, v)| match v {
        Wire::Fixed32(x) if *n == number => Some(*x),
        _ => None,
    })
}

/// Wat het apparaat over zichzelf vertelt.
#[derive(Default)]
pub(crate) struct Info {
    pub(crate) name: String,
    pub(crate) mac: String,
    pub(crate) version: String,
    pub(crate) model: String,
    pub(crate) project: String,
    pub(crate) project_version: String,
}
pub(crate) fn info(body: &[u8]) -> Result<Info> {
    let f = fields(body)?;
    Ok(Info {
        name: text(&f, 2)?,
        mac: text(&f, 3)?,
        version: text(&f, 4)?,
        model: text(&f, 6)?,
        project: text(&f, 8)?,
        project_version: text(&f, 9)?,
    })
}
/// `true` als het apparaat een wachtwoord verwacht dat Stulp niet heeft.
pub(crate) fn invalid_password(body: &[u8]) -> Result<bool> {
    Ok(uint(&fields(body)?, 1) != 0)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Kind {
    BinarySensor,
    Sensor,
    Switch,
    TextSensor,
    Button,
}
/// Entiteitcategorie: 0 gewoon, 1 configuratie, 2 diagnose.
pub(crate) const CATEGORY_NONE: u64 = 0;

/// Eén entiteit uit de lijst; de key is een fixed32 en geen getal om mee te rekenen.
pub(crate) struct Entity {
    pub(crate) kind: Kind,
    pub(crate) key: u32,
    pub(crate) object_id: String,
    pub(crate) device_class: String,
    pub(crate) unit: String,
    pub(crate) decimals: u64,
    pub(crate) category: u64,
    pub(crate) status: bool,
}
/// `None` voor berichttypes die geen entiteit beschrijven.
pub(crate) fn entity(kind: u32, body: &[u8]) -> Result<Option<Entity>> {
    // Veldnummers per type: (soort, device_class, categorie).
    let (kind, class, category) = match kind {
        LIST_BINARY_SENSOR => (Kind::BinarySensor, 5, 9),
        LIST_SENSOR => (Kind::Sensor, 9, 13),
        LIST_SWITCH => (Kind::Switch, 9, 8),
        LIST_TEXT_SENSOR => (Kind::TextSensor, 0, 7),
        LIST_BUTTON => (Kind::Button, 8, 7),
        _ => return Ok(None),
    };
    let f = fields(body)?;
    let key = fixed32(&f, 2).ok_or(Error::Invalid("ESPHome-entiteit zonder key"))?;
    Ok(Some(Entity {
        kind,
        key,
        object_id: text(&f, 1)?,
        device_class: if class == 0 {
            String::new()
        } else {
            text(&f, class)?
        },
        unit: if kind == Kind::Sensor {
            text(&f, 6)?
        } else {
            String::new()
        },
        decimals: if kind == Kind::Sensor { uint(&f, 7) } else { 0 },
        category: uint(&f, category),
        status: kind == Kind::BinarySensor && uint(&f, 6) != 0,
    }))
}

/// Een gemelde stand; `Missing` betekent dat het apparaat zelf nog niets weet.
#[derive(PartialEq, Debug)]
pub(crate) enum Reading {
    Bool(bool),
    Number(f64),
    Text(String),
    Missing,
}
/// `None` voor berichttypes die geen stand melden.
pub(crate) fn state(kind: u32, body: &[u8]) -> Result<Option<(u32, Reading)>> {
    if !matches!(
        kind,
        BINARY_SENSOR_STATE | SENSOR_STATE | SWITCH_STATE | TEXT_SENSOR_STATE
    ) {
        return Ok(None);
    }
    let f = fields(body)?;
    let key = fixed32(&f, 1).ok_or(Error::Invalid("ESPHome-stand zonder key"))?;
    // Een schakelaar kent geen missing_state; veld 3 is daar niet gedefinieerd.
    if kind != SWITCH_STATE && uint(&f, 3) != 0 {
        return Ok(Some((key, Reading::Missing)));
    }
    let reading = match kind {
        BINARY_SENSOR_STATE | SWITCH_STATE => Reading::Bool(uint(&f, 2) != 0),
        SENSOR_STATE => {
            let n = f32::from_bits(fixed32(&f, 2).unwrap_or(0));
            if n.is_finite() {
                Reading::Number(f64::from(n))
            } else {
                Reading::Missing
            }
        }
        _ => Reading::Text(text(&f, 2)?),
    };
    Ok(Some((key, reading)))
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    #[test]
    fn frames_split_over_packets_and_keys_stay_fixed32() {
        // ListEntitiesBinarySensorResponse van de echte deurbel (sleutel 0x2697c6f7).
        let body = Body::default()
            .text(1, "doorbell")
            .unwrap()
            .fixed32(2, 0x2697_c6f7)
            .unwrap()
            .text(3, "Doorbell")
            .unwrap();
        let bytes = frame(LIST_BINARY_SENSOR, body).unwrap();
        let mut d = Decoder::default();
        d.feed(&bytes[..3]).unwrap();
        assert!(d.next().unwrap().is_none());
        d.feed(&bytes[3..]).unwrap();
        let (kind, body) = d.next().unwrap().unwrap();
        assert_eq!(kind, LIST_BINARY_SENSOR);
        let e = entity(kind, &body).unwrap().unwrap();
        assert_eq!(e.key, 0x2697_c6f7);
        assert_eq!(e.object_id, "doorbell");
        assert!(d.next().unwrap().is_none());
    }
    #[test]
    fn encrypted_devices_and_oversized_frames_are_refused() {
        let mut d = Decoder::default();
        d.feed(&[1, 0, 0]).unwrap();
        assert!(d.next().is_err());
        let mut d = Decoder::default();
        d.feed(&[0, 0xff, 0xff, 0x7f, 1]).unwrap();
        assert!(d.next().is_err());
    }
    #[test]
    fn missing_and_false_states_differ() {
        let off = Body::default().fixed32(1, 9).unwrap();
        assert_eq!(
            state(BINARY_SENSOR_STATE, &off.0).unwrap(),
            Some((9, Reading::Bool(false)))
        );
        let missing = Body::default()
            .fixed32(1, 9)
            .unwrap()
            .boolean(3, true)
            .unwrap();
        assert_eq!(
            state(SENSOR_STATE, &missing.0).unwrap(),
            Some((9, Reading::Missing))
        );
        assert_eq!(state(PING_REQUEST, &[]).unwrap(), None);
    }
}

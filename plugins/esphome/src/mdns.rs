//! ESPHome-apparaten op het netwerk: één PTR-vraag naar `_esphomelib._tcp`,
//! en uit de antwoorden naam, adres, poort en de TXT-velden.
use alloc::{string::String, vec::Vec};
use stulp_core::json;
use stulp_sdk::{Datagram, Error, Result};

pub(crate) const SERVICE: &str = "_esphomelib._tcp.local.";
const PTR: u16 = 12;
const TXT: u16 = 16;
const A: u16 = 1;
const SRV: u16 = 33;

/// Een PTR-vraag vanaf een gewone poort; het apparaat antwoordt dan unicast.
pub(crate) fn query() -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.try_reserve(64).map_err(|_| stulp_core::Error::Memory)?;
    out.extend_from_slice(&[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for label in SERVICE.trim_end_matches('.').split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.extend_from_slice(&[0, 0, 12, 0, 1]);
    Ok(out)
}

/// Een gevonden ESPHome-apparaat.
#[derive(Default, Debug, PartialEq)]
pub(crate) struct Found {
    /// De instantienaam, gelijk aan de ESPHome-naam (`doorbell`).
    pub(crate) name: String,
    /// IPv4-adres of, zonder A-record, de mDNS-hostnaam.
    pub(crate) address: String,
    pub(crate) port: u16,
    /// Kleine letters zonder scheidingstekens, zoals ESPHome het in TXT zet.
    pub(crate) mac: String,
    pub(crate) project: String,
    pub(crate) version: String,
    pub(crate) friendly: String,
}

fn bad<T>() -> Result<T> {
    Err(Error::Invalid("ongeldig mDNS-pakket"))
}
fn octets<'a>(p: &'a [u8], at: &mut usize, len: usize) -> Result<&'a [u8]> {
    let end = at.checked_add(len).ok_or(Error::Invalid("mDNS-lengte"))?;
    let b = p
        .get(*at..end)
        .ok_or(Error::Invalid("afgekapt mDNS-veld"))?;
    *at = end;
    Ok(b)
}
fn u16be(p: &[u8], at: &mut usize) -> Result<u16> {
    let b = octets(p, at, 2)?;
    Ok(u16::from_be_bytes([b[0], b[1]]))
}
/// Een naam in kleine letters met punten, compressie alleen terugwijzend.
fn name(p: &[u8], at: &mut usize) -> Result<String> {
    let mut out = String::new();
    let mut pos = *at;
    let mut jumped = false;
    for _ in 0..128 {
        let here = pos;
        let len = *p.get(pos).ok_or(Error::Invalid("afgekapte mDNS-naam"))?;
        pos += 1;
        if len & 0xc0 == 0xc0 {
            let next = *p.get(pos).ok_or(Error::Invalid("afgekapte mDNS-naam"))?;
            pos += 1;
            let target = usize::from(len & 0x3f) << 8 | usize::from(next);
            if target >= here {
                return bad();
            }
            if !jumped {
                *at = pos;
                jumped = true;
            }
            pos = target;
            continue;
        }
        if len & 0xc0 != 0 {
            return bad();
        }
        if len == 0 {
            if !jumped {
                *at = pos;
            }
            return Ok(out);
        }
        let label = octets(p, &mut pos, usize::from(len))?;
        let label = core::str::from_utf8(label).map_err(|_| Error::Invalid("mDNS-label"))?;
        if out.len() + label.len() + 1 > 255 {
            return bad();
        }
        out.try_reserve(label.len() + 1)
            .map_err(|_| stulp_core::Error::Memory)?;
        for c in label.chars() {
            out.push(c.to_ascii_lowercase());
        }
        out.push('.');
    }
    bad()
}

enum Record {
    Ptr(String),
    Srv(String, u16),
    Txt(Vec<(String, String)>),
    A([u8; 4]),
}

fn txt(data: &[u8]) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < data.len() {
        let len = usize::from(data[at]);
        at += 1;
        let entry = octets(data, &mut at, len)?;
        let Ok(entry) = core::str::from_utf8(entry) else {
            continue;
        };
        if let Some((k, v)) = entry.split_once('=') {
            json::push(
                &mut out,
                (json::copy(&k.to_ascii_lowercase())?, json::copy(v)?),
                64,
            )?;
        }
    }
    Ok(out)
}

fn records(p: &[u8]) -> Result<Vec<(String, Record)>> {
    if p.len() < 12 || p[2] & 0x80 == 0 {
        return bad();
    }
    let count = |i: usize| usize::from(u16::from_be_bytes([p[i], p[i + 1]]));
    let mut at = 12;
    for _ in 0..count(4) {
        name(p, &mut at)?;
        octets(p, &mut at, 4)?;
    }
    let total = count(6) + count(8) + count(10);
    let mut out = Vec::new();
    for _ in 0..total.min(256) {
        let owner = name(p, &mut at)?;
        let kind = u16be(p, &mut at)?;
        octets(p, &mut at, 6)?;
        let len = usize::from(u16be(p, &mut at)?);
        let start = at;
        let data = octets(p, &mut at, len)?;
        let record = match kind {
            PTR => {
                let mut i = start;
                Record::Ptr(name(p, &mut i)?)
            }
            SRV => {
                let mut i = start + 4;
                let port = u16be(p, &mut i)?;
                Record::Srv(name(p, &mut i)?, port)
            }
            TXT => Record::Txt(txt(data)?),
            A if len == 4 => Record::A([data[0], data[1], data[2], data[3]]),
            _ => continue,
        };
        json::push(&mut out, (owner, record), 256)?;
    }
    Ok(out)
}

fn ipv4(octets: [u8; 4]) -> Result<String> {
    use core::fmt::Write;
    let mut s = String::new();
    s.try_reserve(15).map_err(|_| stulp_core::Error::Memory)?;
    write!(s, "{}.{}.{}.{}", octets[0], octets[1], octets[2], octets[3])
        .map_err(|_| Error::Invalid("IPv4-adres"))?;
    Ok(s)
}

/// Alle apparaten uit een zoekronde, één keer per MAC (of naam), op naam gesorteerd.
pub(crate) fn found(datagrams: &[Datagram]) -> Result<Vec<Found>> {
    let mut all = Vec::new();
    for d in datagrams {
        // Eén kapot pakket van een ander apparaat mag de rest niet verbergen.
        if let Ok(r) = records(&d.payload) {
            for x in r {
                json::push(&mut all, x, 4096)?;
            }
        }
    }
    let mut out: Vec<Found> = Vec::new();
    for (owner, record) in &all {
        let Record::Ptr(instance) = record else {
            continue;
        };
        if owner != SERVICE || !instance.ends_with(SERVICE) {
            continue;
        }
        let label = instance.trim_end_matches(SERVICE).trim_end_matches('.');
        if label.is_empty() {
            continue;
        }
        let mut f = Found {
            name: json::copy(label)?,
            ..Found::default()
        };
        let mut host = String::new();
        for (o, r) in &all {
            if o != instance {
                continue;
            }
            match r {
                Record::Srv(h, port) => {
                    host = json::copy(h)?;
                    f.port = *port;
                }
                Record::Txt(entries) => {
                    for (k, v) in entries {
                        let slot = match k.as_str() {
                            "mac" => &mut f.mac,
                            "project_name" => &mut f.project,
                            "version" => &mut f.version,
                            "friendly_name" => &mut f.friendly,
                            _ => continue,
                        };
                        *slot = json::copy(v)?;
                    }
                }
                _ => (),
            }
        }
        for (o, r) in &all {
            if let Record::A(ip) = r
                && !host.is_empty()
                && *o == host
            {
                f.address = ipv4(*ip)?;
            }
        }
        if f.address.is_empty() && !host.is_empty() {
            f.address = json::copy(host.trim_end_matches('.'))?;
        }
        f.mac = mac(&f.mac)?;
        if f.port == 0 {
            f.port = 6053;
        }
        if f.address.is_empty()
            || out
                .iter()
                .any(|o| (!f.mac.is_empty() && o.mac == f.mac) || o.name == f.name)
        {
            continue;
        }
        json::push(&mut out, f, 256)?;
    }
    out.sort_unstable_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// Eén vorm voor een MAC uit TXT (`c8c9a36abd17`) en uit DeviceInfo (`C8:C9:A3:…`).
pub(crate) fn mac(raw: &str) -> Result<String> {
    let mut out = String::new();
    out.try_reserve(12).map_err(|_| stulp_core::Error::Memory)?;
    for c in raw.chars().filter(|c| *c != ':' && *c != '-') {
        if !c.is_ascii_hexdigit() || out.len() >= 12 {
            return Ok(String::new());
        }
        out.push(c.to_ascii_lowercase());
    }
    Ok(if out.len() == 12 { out } else { String::new() })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
pub(crate) mod tests {
    use super::*;
    /// Het echte antwoord van de Zuidwijk-deurbel op [`query`], 15-11-2026.
    pub(crate) const DOORBELL: &[u8] = b"\x00\x00\x84\x00\x00\x01\x00\x01\x00\x00\x00\x03\x0b_esphomelib\x04_tcp\x05local\x00\x00\x0c\x00\x01\x0b_esphomelib\x04_tcp\x05local\x00\x00\x0c\x00\x01\x00\x00\x11\x94\x00!\x08doorbell\x0b_esphomelib\x04_tcp\x05local\x00\xc0J\x00!\x00\x01\x00\x00\x11\x94\x00\x16\x00\x00\x00\x00\x17\xa5\x08doorbell\x05local\x00\xc0J\x00\x10\x00\x01\x00\x00\x11\x94\x00t\x13project_version=2.0\x1eproject_name=zuidwijk.doorbell\rboard=d1_mini\x10platform=ESP8266\x10mac=c8c9a36abd17\x10version=2022.6.1\xc0}\x00\x01\x00\x01\x00\x00\x00x\x00\x04\xc0\xa8\x01G";
    pub(crate) fn datagram(payload: &[u8]) -> Datagram {
        Datagram {
            source: json::copy("192.168.1.71:5353").unwrap(),
            interface: 0,
            payload: payload.to_vec(),
        }
    }
    #[test]
    fn the_real_doorbell_answer_gives_address_port_and_identity() {
        let list = found(&[datagram(DOORBELL), datagram(DOORBELL), datagram(b"junk")]).unwrap();
        assert_eq!(
            list,
            [Found {
                name: "doorbell".into(),
                address: "192.168.1.71".into(),
                port: 6053,
                mac: "c8c9a36abd17".into(),
                project: "zuidwijk.doorbell".into(),
                version: "2022.6.1".into(),
                friendly: String::new(),
            }]
        );
    }
    #[test]
    fn query_is_a_single_ptr_question() {
        let q = query().unwrap();
        assert_eq!(&q[4..6], &[0, 1]);
        assert!(q.ends_with(b"\x0b_esphomelib\x04_tcp\x05local\x00\x00\x0c\x00\x01"));
        assert_eq!(mac("C8:C9:A3:6A:BD:17").unwrap(), "c8c9a36abd17");
        assert_eq!(mac("nonsense").unwrap(), "");
    }
}

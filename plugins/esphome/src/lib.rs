//! ESPHome-apparaten via hun lokale API, zonder Home Assistant ertussen: één
//! open TCP-verbinding per apparaat, standen komen binnen zodra ze veranderen.
#![no_std]
#![forbid(unsafe_code)]
extern crate alloc;
#[cfg(test)]
extern crate std;
use alloc::{string::String, vec::Vec};
use stulp_core::json::{self, Value};
use stulp_sdk::{
    Client, DatagramRequest, DatagramTarget, Error, Plugin, Result, StreamCommand, StreamEvent,
    Transport, clone,
    util::{field, join},
};
mod api;
mod map;
mod mdns;
use api::Body;
use map::Driver;

/// ESPHome's eigen API-poort.
const PORT: u16 = 6053;
/// Een stap van de handshake, of het antwoord op een ping, mag zo lang duren.
const ANSWER_MS: u64 = 10_000;
/// Verbinden met een apparaat dat niet bestaat duurt even; daarna is het een fout.
const OPEN_MS: u64 = 15_000;
/// Zo vaak vraagt Stulp of het apparaat er nog is. Het apparaat pingt zelf ook.
const PING_MS: u64 = 20_000;
/// Langer wacht een volgende poging nooit.
const MAX_BACKOFF_MS: u64 = 60_000;
/// Een nieuwe zoekronde op het netwerk hoogstens zo vaak.
const SEARCH_MS: u64 = 30_000;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Closed,
    Opening,
    Hello,
    Connect,
    Info,
    List,
    Live,
}

struct Device {
    id: String,
    driver: Driver,
    mac: String,
    stream: u64,
    phase: Phase,
    decoder: api::Decoder,
    entities: Vec<api::Entity>,
    /// Entiteitkey en de tegel die hij voedt.
    caps: Vec<(u32, String)>,
    bell: Option<u32>,
    pressed: Option<bool>,
    next: u64,
    backoff: u64,
    deadline: u64,
    ping: u64,
    failures: u32,
    /// Het adres klopte niet (ander apparaat, of geen antwoord): eerst opnieuw zoeken.
    lost: bool,
    error: String,
}
impl Device {
    fn new(id: &str, driver: Driver, mac: &str, now: u64) -> Result<Self> {
        Ok(Self {
            id: json::copy(id)?,
            driver,
            mac: json::copy(mac)?,
            stream: 0,
            phase: Phase::Closed,
            decoder: api::Decoder::default(),
            entities: Vec::new(),
            caps: Vec::new(),
            bell: None,
            pressed: None,
            next: now,
            backoff: 2000,
            deadline: 0,
            ping: 0,
            failures: 0,
            lost: false,
            error: String::new(),
        })
    }
    fn write<T: Transport>(&self, c: &mut Client<T>, kind: u32, body: Body) -> Result {
        if self.stream == 0 {
            return Err(Error::Transport("geen verbinding"));
        }
        c.stream(StreamCommand::Write {
            id: self.stream,
            bytes: api::frame(kind, body)?,
        })
    }
    fn close<T: Transport>(&mut self, c: &mut Client<T>) -> Result {
        if self.stream != 0 {
            // Netjes afmelden; een ESP8266 heeft maar een paar plaatsen voor clients.
            let _ = self.write(c, api::DISCONNECT_REQUEST, Body::default());
            c.stream(StreamCommand::Close { id: self.stream })?;
        }
        self.stream = 0;
        self.phase = Phase::Closed;
        self.decoder = api::Decoder::default();
        self.deadline = 0;
        self.pressed = None;
        Ok(())
    }
}

struct Pair {
    id: String,
    driver: Driver,
}

/// Eén eigenaar voor alle verbindingen, de koppelsessies en de laatste zoekronde.
#[derive(Default)]
pub struct Esphome {
    devices: Vec<Device>,
    pairs: Vec<Pair>,
    serial: u64,
    found: Vec<mdns::Found>,
    searched: Option<u64>,
}

fn friendly(e: &Error) -> Result<String> {
    match e {
        Error::Timeout => {
            json::copy("Het apparaat antwoordt niet. Staat het aan en zit het op het netwerk?")
                .map_err(Error::from)
        }
        Error::Transport(why) => join(&["Geen verbinding met het apparaat: ", why]),
        _ => stulp_sdk::message(e),
    }
}

impl Esphome {
    /// Een zoekronde, of de vorige als die nog vers is.
    async fn search<T: Transport>(&mut self, c: &mut Client<T>, fresh: bool) -> Result {
        if !fresh
            && self
                .searched
                .is_some_and(|t| c.now().saturating_sub(t) < SEARCH_MS)
        {
            return Ok(());
        }
        let datagrams = c
            .datagrams(DatagramRequest {
                target: DatagramTarget::Mdns,
                payload: mdns::query()?,
                timeout_ms: 3000,
            })
            .await?;
        self.found = mdns::found(&datagrams)?;
        self.searched = Some(c.now());
        Ok(())
    }

    async fn candidates<T: Transport>(
        &mut self,
        c: &mut Client<T>,
        driver: Driver,
    ) -> Result<Value> {
        self.search(c, true).await?;
        let mut list = Vec::new();
        for f in &self.found {
            // Zonder MAC is er niets dat een apparaat over herstarts heen herkent.
            if f.mac.is_empty() || self.devices.iter().any(|d| d.mac == f.mac) {
                continue;
            }
            if driver == Driver::Doorbell && !map::is_doorbell(&f.project, &f.name) {
                continue;
            }
            let name = if f.friendly.is_empty() {
                &f.name
            } else {
                &f.friendly
            };
            json::push(
                &mut list,
                json::fields(&[
                    ("name", json::string(name)?),
                    ("data", json::fields(&[("mac", json::string(&f.mac)?)])?),
                    (
                        "store",
                        json::fields(&[
                            ("address", json::string(&f.address)?),
                            ("port", Value::uint(u64::from(f.port))),
                            ("project", json::string(&f.project)?),
                            ("version", json::string(&f.version)?),
                        ])?,
                    ),
                ])?,
                256,
            )?;
        }
        Ok(Value::Array(list))
    }

    /// Adres en poort voor de volgende poging: het ingevulde adres, anders
    /// het laatst gevonden adres, anders (of na een misser) een zoekronde.
    async fn target<T: Transport>(&mut self, c: &mut Client<T>, i: usize) -> Result<(String, u16)> {
        let d = c.state().device(&self.devices[i].id)?;
        let manual = json::text(field(d, "settings"), "address").trim();
        if !manual.is_empty() {
            return Ok((json::copy(manual)?, PORT));
        }
        let store = field(d, "store");
        let known = json::copy(json::text(store, "address"))?;
        let stored_port = json::uint(store, "port");
        let port = u16::try_from(stored_port)
            .ok()
            .filter(|p| *p > 0)
            .unwrap_or(PORT);
        if !known.is_empty() && !self.devices[i].lost {
            return Ok((known, port));
        }
        self.search(c, false).await?;
        let mac = &self.devices[i].mac;
        let Some(f) = self.found.iter().find(|f| f.mac == *mac) else {
            if known.is_empty() {
                return Err(Error::Invalid(
                    "Stulp vindt dit apparaat niet op het netwerk. Staat het aan?",
                ));
            }
            // Niet gevonden, maar het oude adres kan nog steeds kloppen.
            return Ok((known, port));
        };
        let (address, port) = (json::copy(&f.address)?, f.port);
        if address != known || u64::from(port) != stored_port {
            let id = json::copy(&self.devices[i].id)?;
            c.store(
                &id,
                json::fields(&[
                    ("address", json::string(&address)?),
                    ("port", Value::uint(u64::from(port))),
                ])?,
            )
            .await?;
        }
        self.devices[i].lost = false;
        Ok((address, port))
    }

    async fn fail<T: Transport>(&mut self, c: &mut Client<T>, i: usize, e: Error) -> Result {
        if let Error::Core(stulp_core::Error::Memory) = e {
            return Err(e);
        }
        let message = friendly(&e)?;
        let d = &mut self.devices[i];
        d.close(c)?;
        d.failures = d.failures.saturating_add(1);
        // Twee keer geen antwoord: misschien kreeg het apparaat een ander adres.
        if d.failures.is_multiple_of(2) {
            d.lost = true;
        }
        d.next = c.now().saturating_add(d.backoff);
        d.backoff = (d.backoff * 2).min(MAX_BACKOFF_MS);
        let id = json::copy(&d.id)?;
        let changed = d.error != message;
        d.error = message;
        let device = c.state().device(&id)?;
        if changed || json::boolean(device, "available") {
            c.unavailable(&id, &self.devices[i].error).await?;
        }
        Ok(())
    }

    async fn open<T: Transport>(&mut self, c: &mut Client<T>, i: usize) -> Result {
        let (host, port) = self.target(c, i).await?;
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or(Error::Invalid("stream ids exhausted"))?;
        let d = &mut self.devices[i];
        c.stream(StreamCommand::Open {
            id: self.serial,
            host: json::copy(host.trim_matches(['[', ']']))?,
            port,
            tls: false,
            device_certificate: false,
        })?;
        d.stream = self.serial;
        d.phase = Phase::Opening;
        d.deadline = c.now().saturating_add(OPEN_MS);
        Ok(())
    }

    /// Wat de tegels na de entiteitenlijst moeten zijn: toevoegen wat er is,
    /// weghalen wat deze app ooit toevoegde en wat het apparaat niet meer heeft.
    async fn sync<T: Transport>(&mut self, c: &mut Client<T>, i: usize) -> Result {
        let d = &mut self.devices[i];
        let mut caps = Vec::new();
        for e in &d.entities {
            if let Some(cap) = map::capability(d.driver, e, &d.entities)?
                && !caps.iter().any(|(_, c): &(u32, String)| *c == cap)
            {
                json::push(&mut caps, (e.key, cap), 256)?;
            }
        }
        d.bell = if d.driver == Driver::Doorbell {
            map::bell(&d.entities)
        } else {
            None
        };
        d.caps = caps;
        // Een lege lijst is een apparaat dat halverwege opstart, geen apparaat zonder functies.
        if d.entities.is_empty() {
            return Ok(());
        }
        let id = json::copy(&d.id)?;
        let mut have = Vec::new();
        for v in json::array(c.state().device(&id)?, "capabilities") {
            if let Some(s) = v.as_str() {
                json::push(&mut have, json::copy(s)?, 1024)?;
            }
        }
        let mut changes = Vec::new();
        for (_, cap) in &d.caps {
            if !have.contains(cap) {
                json::push(&mut changes, ("capability.add", json::copy(cap)?), 256)?;
            }
        }
        for cap in &have {
            if map::owned(d.driver, cap) && !d.caps.iter().any(|(_, c)| c == cap) {
                json::push(&mut changes, ("capability.remove", json::copy(cap)?), 256)?;
            }
        }
        for (method, cap) in changes {
            c.call(
                method,
                &json::fields(&[
                    ("deviceId", json::string(&id)?),
                    ("capability", json::string(&cap)?),
                ])?,
            )
            .await?;
        }
        Ok(())
    }

    async fn info<T: Transport>(&mut self, c: &mut Client<T>, i: usize, body: &[u8]) -> Result {
        let info = api::info(body)?;
        let d = &mut self.devices[i];
        let mac = mdns::mac(&info.mac)?;
        if !mac.is_empty() && mac != d.mac {
            d.lost = true;
            return Err(Error::Invalid(
                "Op dit adres staat een ander ESPHome-apparaat; Stulp zoekt het opnieuw.",
            ));
        }
        let id = json::copy(&d.id)?;
        let store = field(c.state().device(&id)?, "store");
        let mut patch = json::object();
        for (key, value) in [
            ("version", &info.version),
            ("model", &info.model),
            ("project", &info.project),
            ("projectVersion", &info.project_version),
        ] {
            if json::text(store, key) != value.as_str() {
                json::set(&mut patch, key, json::string(value)?)?;
            }
        }
        if patch.as_object().is_some_and(|o| !o.is_empty()) {
            c.store(&id, patch).await?;
        }
        let line = join(&[
            "ESPHOME_CONNECTED name=",
            &info.name,
            " version=",
            &info.version,
            " project=",
            &info.project,
        ])?;
        c.log("info", &line)?;
        Ok(())
    }

    /// Verwerkt alles wat compleet binnen is; standen gaan als één patch naar Stulp.
    async fn drain<T: Transport>(&mut self, c: &mut Client<T>, i: usize) -> Result {
        let mut patch = json::object();
        let mut rang = false;
        for _ in 0..256 {
            let Some((kind, body)) = self.devices[i].decoder.next()? else {
                break;
            };
            let now = c.now();
            let d = &mut self.devices[i];
            if d.phase == Phase::Live {
                d.deadline = 0;
            }
            match kind {
                api::HELLO_RESPONSE if d.phase == Phase::Hello => {
                    d.write(c, api::CONNECT_REQUEST, Body::default())?;
                    d.phase = Phase::Connect;
                    d.deadline = now.saturating_add(ANSWER_MS);
                }
                api::CONNECT_RESPONSE if d.phase == Phase::Connect => {
                    if api::invalid_password(&body)? {
                        return Err(Error::Invalid(
                            "Dit ESPHome-apparaat vraagt een API-wachtwoord; dat ondersteunt Stulp nog niet.",
                        ));
                    }
                    d.write(c, api::DEVICE_INFO_REQUEST, Body::default())?;
                    d.phase = Phase::Info;
                    d.deadline = now.saturating_add(ANSWER_MS);
                }
                api::DEVICE_INFO_RESPONSE if d.phase == Phase::Info => {
                    self.info(c, i, &body).await?;
                    let d = &mut self.devices[i];
                    d.entities.clear();
                    d.write(c, api::LIST_ENTITIES_REQUEST, Body::default())?;
                    d.phase = Phase::List;
                    d.deadline = now.saturating_add(ANSWER_MS);
                }
                api::LIST_DONE if d.phase == Phase::List => {
                    self.sync(c, i).await?;
                    let d = &mut self.devices[i];
                    d.write(c, api::SUBSCRIBE_STATES, Body::default())?;
                    d.phase = Phase::Live;
                    d.deadline = 0;
                    d.ping = now.saturating_add(PING_MS);
                    d.failures = 0;
                    d.backoff = 2000;
                    d.lost = false;
                    d.error.clear();
                    let id = json::copy(&d.id)?;
                    if !json::boolean(c.state().device(&id)?, "available") {
                        c.available(&id, true).await?;
                    }
                }
                api::PING_REQUEST => d.write(c, api::PING_RESPONSE, Body::default())?,
                api::PING_RESPONSE => (),
                api::GET_TIME_REQUEST => {
                    let seconds = u32::try_from(c.wall_time()?).unwrap_or(u32::MAX);
                    d.write(
                        c,
                        api::GET_TIME_RESPONSE,
                        Body::default().fixed32(1, seconds)?,
                    )?;
                }
                api::DISCONNECT_REQUEST => {
                    let _ = d.write(c, api::DISCONNECT_RESPONSE, Body::default());
                    return Err(Error::Transport("het apparaat sloot de verbinding"));
                }
                _ if d.phase == Phase::List => {
                    if let Some(e) = api::entity(kind, &body)? {
                        json::push(&mut d.entities, e, 256)?;
                    }
                }
                _ if d.phase == Phase::Live => {
                    let Some((key, reading)) = api::state(kind, &body)? else {
                        continue;
                    };
                    if d.bell == Some(key)
                        && let api::Reading::Bool(on) = reading
                    {
                        // Alleen de overgang telt: de eerste stand na verbinden is geen druk.
                        rang |= on && d.pressed == Some(false);
                        d.pressed = Some(on);
                    }
                    let Some((_, cap)) = d.caps.iter().find(|(k, _)| *k == key) else {
                        continue;
                    };
                    let Some(e) = d.entities.iter().find(|e| e.key == key) else {
                        continue;
                    };
                    let Some(value) = map::value(e, cap, &reading)? else {
                        continue;
                    };
                    let cap = json::copy(cap)?;
                    // Elke overgang apart melden, ook een druk die binnen één ronde begint en eindigt.
                    if json::get(&patch, &cap).is_some() {
                        let id = json::copy(&d.id)?;
                        c.values(&id, core::mem::replace(&mut patch, json::object()))
                            .await?;
                    }
                    let id = json::copy(&self.devices[i].id)?;
                    let current = json::get(field(c.state().device(&id)?, "state"), &cap);
                    if current.is_none_or(|v| !json::equal(v, &value)) {
                        json::set(&mut patch, &cap, value)?;
                    }
                }
                _ => (),
            }
        }
        let id = json::copy(&self.devices[i].id)?;
        if patch.as_object().is_some_and(|o| !o.is_empty()) {
            c.values(&id, patch).await?;
        }
        if rang {
            c.call(
                "flow.trigger",
                &json::fields(&[
                    ("kind", json::string("trigger")?),
                    ("id", json::string("doorbell_pressed")?),
                    ("tokens", json::object()),
                    ("state", json::fields(&[("deviceId", json::string(&id)?)])?),
                ])?,
            )
            .await?;
        }
        Ok(())
    }

    async fn event<T: Transport>(&mut self, c: &mut Client<T>, event: StreamEvent) -> Result {
        let id = match &event {
            StreamEvent::Opened(id) | StreamEvent::Data(id, _) | StreamEvent::Closed(id, _) => *id,
        };
        let Some(i) = self.devices.iter().position(|d| d.stream == id) else {
            return Ok(());
        };
        let result = match event {
            StreamEvent::Opened(_) => {
                let d = &mut self.devices[i];
                d.phase = Phase::Hello;
                d.deadline = c.now().saturating_add(ANSWER_MS);
                let body = Body::default().text(1, "Stulp")?.uint(2, 1)?.uint(3, 6)?;
                d.write(c, api::HELLO_REQUEST, body)
            }
            StreamEvent::Data(_, bytes) => self.devices[i].decoder.feed(&bytes),
            StreamEvent::Closed(_, e) => Err(e),
        };
        if let Err(e) = result {
            self.fail(c, i, e).await?;
        }
        Ok(())
    }

    async fn capability<T: Transport>(&mut self, c: &mut Client<T>, p: &Value) -> Result<Value> {
        let id = json::text(p, "deviceId");
        let cap = json::text(p, "capability");
        let d = self
            .devices
            .iter()
            .find(|d| d.id == id)
            .ok_or(Error::Invalid(
                "Dit apparaat hoort niet bij de ESPHome-app.",
            ))?;
        let key = d
            .caps
            .iter()
            .find(|(_, c)| c == cap)
            .map(|(k, _)| *k)
            .ok_or(Error::Invalid("Dit apparaat kent deze bediening niet."))?;
        let entity = d
            .entities
            .iter()
            .find(|e| e.key == key && e.kind == api::Kind::Switch)
            .ok_or(Error::Invalid("Dit is alleen een melding, geen bediening."))?;
        if d.phase != Phase::Live {
            return Err(Error::Invalid(
                "Het apparaat is nu niet verbonden; probeer het zo opnieuw.",
            ));
        }
        let on = field(p, "value")
            .as_bool()
            .ok_or(Error::Invalid("Deze bediening vraagt aan of uit."))?;
        // De tegel volgt pas op de SwitchState die het apparaat terugstuurt.
        d.write(
            c,
            api::SWITCH_COMMAND,
            Body::default().fixed32(1, entity.key)?.boolean(2, on)?,
        )?;
        Ok(Value::Null)
    }
}

impl Plugin for Esphome {
    fn manifest(&self) -> &'static [u8] {
        include_bytes!("../app.json")
    }
    async fn handle<T: Transport>(
        &mut self,
        c: &mut Client<T>,
        method: &str,
        p: &Value,
    ) -> Result<Value> {
        match method {
            "app.init" => Ok(Value::Null),
            "driver.init" => {
                Driver::parse(json::text(p, "driverId"))
                    .ok_or(Error::Invalid("unknown ESPHome driver"))?;
                Ok(Value::Null)
            }
            "device.init" => {
                let id = json::text(p, "deviceId");
                let d = c.state().device(id)?;
                let driver = Driver::parse(json::text(d, "driverId"))
                    .ok_or(Error::Invalid("unknown ESPHome driver"))?;
                let mac = mdns::mac(json::text(field(d, "data"), "mac"))?;
                if mac.is_empty() {
                    return Err(Error::Invalid(
                        "Dit apparaat heeft geen MAC-adres; koppel het opnieuw.",
                    ));
                }
                if let Some(i) = self.devices.iter().position(|d| d.id == id) {
                    self.devices.remove(i).close(c)?;
                }
                let device = Device::new(id, driver, &mac, c.now())?;
                json::push(&mut self.devices, device, 8).map_err(|_| {
                    Error::Invalid(
                        "Stulp houdt hoogstens acht ESPHome-apparaten tegelijk verbonden.",
                    )
                })?;
                Ok(Value::Null)
            }
            "device.delete" => {
                if let Some(i) = self
                    .devices
                    .iter()
                    .position(|d| d.id == json::text(p, "deviceId"))
                {
                    self.devices.remove(i).close(c)?;
                }
                Ok(Value::Null)
            }
            "capability.invoke" => self.capability(c, p).await,
            "capabilities.invoke" => {
                let mut errors = json::object();
                for cmd in json::array(p, "commands") {
                    let mut params = clone(cmd)?;
                    json::set(&mut params, "deviceId", clone(field(p, "deviceId"))?)?;
                    if let Err(e) = self.capability(c, &params).await {
                        json::set(
                            &mut errors,
                            json::text(cmd, "capability"),
                            json::string(&stulp_sdk::message(&e)?)?,
                        )?;
                    }
                }
                Ok(errors)
            }
            "flow.run" => match json::text(p, "id") {
                "doorbell_pressed" => Ok(Value::Bool(true)),
                _ => Err(Error::Invalid("Onbekende ESPHome-flowkaart.")),
            },
            "pair.start" => {
                let id = json::text(p, "sessionId");
                let driver = Driver::parse(json::text(p, "driverId"))
                    .ok_or(Error::Invalid("unknown ESPHome driver"))?;
                if id.is_empty() || self.pairs.iter().any(|s| s.id == id) {
                    return Err(Error::Invalid("invalid pair session"));
                }
                json::push(
                    &mut self.pairs,
                    Pair {
                        id: json::copy(id)?,
                        driver,
                    },
                    32,
                )?;
                Ok(json::parse(br#"["list_devices"]"#).map_err(stulp_core::Error::from)?)
            }
            "pair.list" => {
                let driver = Driver::parse(json::text(p, "driverId"))
                    .ok_or(Error::Invalid("unknown ESPHome driver"))?;
                self.candidates(c, driver).await
            }
            "pair.emit" => {
                let driver = self
                    .pairs
                    .iter()
                    .find(|s| s.id == json::text(p, "sessionId"))
                    .ok_or(Error::Invalid("pair session missing"))?
                    .driver;
                if json::text(p, "event") != "list_devices" {
                    return Err(Error::Invalid("unknown pair event"));
                }
                self.candidates(c, driver).await
            }
            "pair.close" => {
                self.pairs.retain(|s| s.id != json::text(p, "sessionId"));
                Ok(Value::Null)
            }
            "registrations" => stulp_sdk::registrations(
                &json::parse(self.manifest()).map_err(stulp_core::Error::from)?,
            ),
            "ui.asset" => Ok(json::fields(&[("found", Value::Bool(false))])?),
            _ => Err(Error::Invalid("unknown ESPHome method")),
        }
    }
    async fn settings<T: Transport>(
        &mut self,
        c: &mut Client<T>,
        id: &str,
        patch: &Value,
    ) -> Result<Value> {
        c.state().device(id)?;
        if let Some(address) = json::get(patch, "address") {
            let address = address
                .as_str()
                .ok_or(Error::Invalid("Het adres moet tekst zijn."))?
                .trim();
            if address.len() > 253
                || address
                    .bytes()
                    .any(|b| b <= 32 || b >= 127 || b"/@\\?#:".contains(&b))
            {
                return Err(Error::Invalid(
                    "Vul een IP-adres of hostnaam in, zonder poort, of laat het leeg.",
                ));
            }
            if let Some(d) = self.devices.iter_mut().find(|d| d.id == id) {
                d.close(c)?;
                d.next = c.now();
                d.backoff = 2000;
                d.lost = false;
            }
        }
        Ok(Value::Null)
    }
    async fn tick<T: Transport>(&mut self, c: &mut Client<T>) -> Result {
        let mut i = 0;
        while i < self.devices.len() {
            if c.state().device(&self.devices[i].id).is_ok() {
                i += 1;
            } else {
                self.devices.remove(i).close(c)?;
            }
        }
        for _ in 0..64 {
            let Some(event) = c.poll_stream() else {
                break;
            };
            self.event(c, event).await?;
        }
        for i in 0..self.devices.len() {
            if let Err(e) = self.drain(c, i).await {
                self.fail(c, i, e).await?;
                continue;
            }
            let now = c.now();
            let d = &mut self.devices[i];
            if d.phase == Phase::Closed {
                if now >= d.next
                    && let Err(e) = self.open(c, i).await
                {
                    self.fail(c, i, e).await?;
                }
                continue;
            }
            if d.deadline != 0 && now >= d.deadline {
                self.fail(c, i, Error::Timeout).await?;
                continue;
            }
            if d.phase == Phase::Live && d.deadline == 0 && now >= d.ping {
                d.ping = now.saturating_add(PING_MS);
                d.deadline = now.saturating_add(ANSWER_MS);
                if let Err(e) = d.write(c, api::PING_REQUEST, Body::default()) {
                    self.fail(c, i, e).await?;
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;

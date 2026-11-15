#![allow(clippy::unwrap_used, clippy::panic)]
use super::*;
#[path = "../../../tests/wire.rs"]
mod wire;
use core::cell::RefCell;
use std::{collections::VecDeque, rc::Rc};
use stulp_sdk::{Datagram, Event};
use wire::{Wire, value};

pub(crate) const BELL: u32 = 0x2697_5b9a;
const STATUS: u32 = 0x1df9_5151;
const UPTIME: u32 = 0xb59f_8f95;
const WIFI: u32 = 0x5ec8_1469;
const RESTART: u32 = 0xf103_1b0e;
const CHIME: u32 = 0x2efb_bc90;

fn body() -> Body {
    Body::default()
}
/// De entiteitenlijst van de echte Zuidwijk-deurbel (ESPHome 2022.6.1), zoals
/// die op 15-11-2026 over de API kwam; keys zijn de echte fixed32-waarden.
fn doorbell_frames() -> Vec<(u32, Body)> {
    let b = |object: &str, key: u32, name: &str| {
        body()
            .text(1, object)
            .unwrap()
            .fixed32(2, key)
            .unwrap()
            .text(3, name)
            .unwrap()
            .text(4, &alloc::format!("doorbell{object}"))
            .unwrap()
    };
    let text = |object: &str, key: u32| {
        (
            api::LIST_TEXT_SENSOR,
            b(object, key, object).uint(7, 2).unwrap(),
        )
    };
    alloc::vec![
        (api::LIST_BINARY_SENSOR, b("doorbell", BELL, "Doorbell")),
        (
            api::LIST_BINARY_SENSOR,
            b("status_doorbell", STATUS, "Status Doorbell")
                .text(5, "connectivity")
                .unwrap()
                .boolean(6, true)
                .unwrap()
                .uint(9, 2)
                .unwrap(),
        ),
        (
            api::LIST_SENSOR,
            b("doorbell_uptime", UPTIME, "Doorbell Uptime")
                .text(5, "mdi:timer-outline")
                .unwrap()
                .text(6, "s")
                .unwrap()
                .uint(10, 2)
                .unwrap()
                .uint(13, 2)
                .unwrap(),
        ),
        (
            api::LIST_SENSOR,
            b("doorbell_wifi_signal", WIFI, "Doorbell WiFi Signal")
                .text(6, "dBm")
                .unwrap()
                .text(9, "signal_strength")
                .unwrap()
                .uint(10, 1)
                .unwrap()
                .uint(13, 2)
                .unwrap(),
        ),
        (
            api::LIST_SWITCH,
            b("doorbell_restart", RESTART, "Doorbell Restart")
                .text(5, "mdi:restart")
                .unwrap()
                .uint(8, 1)
                .unwrap(),
        ),
        (
            api::LIST_SWITCH,
            b("doorbell_chime_active", CHIME, "Doorbell Chime Active"),
        ),
        text("doorbell_esphome_version", 0x2370_cfcb),
        text("doorbell_ip", 0xd429_960e),
        text("doorbell_ssid", 0x191c_fe94),
        text("doorbell_bssid", 0xc459_cae4),
    ]
}
pub(crate) fn doorbell_entities() -> Vec<api::Entity> {
    doorbell_frames()
        .into_iter()
        .map(|(kind, b)| {
            let bytes = api::frame(kind, b).unwrap();
            let mut d = api::Decoder::default();
            d.feed(&bytes).unwrap();
            let (kind, body) = d.next().unwrap().unwrap();
            api::entity(kind, &body).unwrap().unwrap()
        })
        .collect()
}

/// Een nagespeelde deurbel achter de streamadapter: antwoordt op de handshake
/// en de lijst zoals de echte, en noteert alles wat Stulp stuurt.
struct Fake {
    events: VecDeque<StreamEvent>,
    opened: Vec<(u64, String, u16)>,
    closed: Vec<u64>,
    /// Elk bericht dat Stulp verstuurde: stream, type, body.
    written: Vec<(u64, u32, Vec<u8>)>,
    decoders: Vec<(u64, api::Decoder)>,
    /// Alles wat de plugin naar de controller stuurde.
    calls: Vec<Value>,
    mac: &'static str,
    password: bool,
    /// De bel staat al aan op het moment van verbinden.
    ringing: bool,
    answer: bool,
    mdns: Vec<&'static [u8]>,
    searches: usize,
    searching: bool,
}
impl Fake {
    fn reply(&mut self, id: u64, kind: u32, b: Body) {
        let bytes = api::frame(kind, b).unwrap();
        // In twee stukken, zoals TCP het mag afleveren.
        let (a, z) = bytes.split_at(bytes.len() / 2);
        self.events.push_back(StreamEvent::Data(id, a.to_vec()));
        self.events.push_back(StreamEvent::Data(id, z.to_vec()));
    }
    fn device(&mut self, id: u64, kind: u32) {
        if !self.answer {
            return;
        }
        match kind {
            api::HELLO_REQUEST => self.reply(
                id,
                api::HELLO_RESPONSE,
                body()
                    .uint(1, 1)
                    .unwrap()
                    .uint(2, 6)
                    .unwrap()
                    .text(3, "doorbell (esphome v2022.6.1)")
                    .unwrap()
                    .text(4, "doorbell")
                    .unwrap(),
            ),
            api::CONNECT_REQUEST => {
                let b = if self.password {
                    body().boolean(1, true).unwrap()
                } else {
                    body()
                };
                self.reply(id, api::CONNECT_RESPONSE, b);
            }
            api::DEVICE_INFO_REQUEST => {
                let mac = self.mac;
                self.reply(
                    id,
                    api::DEVICE_INFO_RESPONSE,
                    body()
                        .text(2, "doorbell")
                        .unwrap()
                        .text(3, mac)
                        .unwrap()
                        .text(4, "2022.6.1")
                        .unwrap()
                        .text(6, "d1_mini")
                        .unwrap()
                        .text(8, "zuidwijk.doorbell")
                        .unwrap()
                        .text(9, "2.0")
                        .unwrap(),
                );
            }
            api::LIST_ENTITIES_REQUEST => {
                for (kind, b) in doorbell_frames() {
                    self.reply(id, kind, b);
                }
                self.reply(id, api::LIST_DONE, body());
            }
            api::SUBSCRIBE_STATES => {
                let ringing = self.ringing;
                self.reply(
                    id,
                    api::BINARY_SENSOR_STATE,
                    body()
                        .fixed32(1, BELL)
                        .unwrap()
                        .boolean(2, ringing)
                        .unwrap(),
                );
                self.reply(
                    id,
                    api::BINARY_SENSOR_STATE,
                    body().fixed32(1, STATUS).unwrap().boolean(2, true).unwrap(),
                );
                self.reply(
                    id,
                    api::SENSOR_STATE,
                    body()
                        .fixed32(1, UPTIME)
                        .unwrap()
                        .fixed32(2, 0.145f32.to_bits())
                        .unwrap(),
                );
                self.reply(
                    id,
                    api::SENSOR_STATE,
                    body()
                        .fixed32(1, WIFI)
                        .unwrap()
                        .fixed32(2, (-66.0f32).to_bits())
                        .unwrap(),
                );
                self.reply(id, api::SWITCH_STATE, body().fixed32(1, RESTART).unwrap());
                self.reply(
                    id,
                    api::SWITCH_STATE,
                    body().fixed32(1, CHIME).unwrap().boolean(2, true).unwrap(),
                );
                self.reply(
                    id,
                    api::TEXT_SENSOR_STATE,
                    body()
                        .fixed32(1, 0xd429_960e)
                        .unwrap()
                        .text(2, "192.168.1.71")
                        .unwrap(),
                );
            }
            api::PING_REQUEST => self.reply(id, api::PING_RESPONSE, body()),
            _ => (),
        }
    }
    /// Een stand die het apparaat uit zichzelf stuurt.
    fn push(&mut self, kind: u32, key: u32, on: bool) {
        let id = self.opened.last().unwrap().0;
        self.reply(
            id,
            kind,
            body().fixed32(1, key).unwrap().boolean(2, on).unwrap(),
        );
    }
    fn sent(&self, kind: u32) -> usize {
        self.written.iter().filter(|w| w.1 == kind).count()
    }
}
struct Net {
    wire: Wire,
    fake: Rc<RefCell<Fake>>,
}
impl Transport for Net {
    fn stream(&mut self, command: StreamCommand) -> Result {
        let mut f = self.fake.borrow_mut();
        match command {
            StreamCommand::Open {
                id,
                host,
                port,
                tls,
                ..
            } => {
                assert!(!tls);
                assert!(f.opened.last().is_none_or(|o| o.0 < id));
                f.opened.push((id, host, port));
                f.decoders.push((id, api::Decoder::default()));
                f.events.push_back(StreamEvent::Opened(id));
            }
            StreamCommand::Write { id, bytes } => {
                let mut kinds = Vec::new();
                let mut got = Vec::new();
                {
                    let d = &mut f.decoders.iter_mut().find(|d| d.0 == id).unwrap().1;
                    d.feed(&bytes).unwrap();
                    while let Some((kind, b)) = d.next().unwrap() {
                        kinds.push(kind);
                        got.push((id, kind, b));
                    }
                }
                f.written.extend(got);
                if !f.closed.contains(&id) {
                    for kind in kinds {
                        f.device(id, kind);
                    }
                }
            }
            StreamCommand::Close { id } => f.closed.push(id),
        }
        Ok(())
    }
    fn poll_stream(&mut self) -> Option<StreamEvent> {
        self.fake.borrow_mut().events.pop_front()
    }
    fn start_datagrams(&mut self, request: DatagramRequest) -> Result {
        assert!(matches!(request.target, DatagramTarget::Mdns));
        assert_eq!(request.payload, mdns::query().unwrap());
        let mut f = self.fake.borrow_mut();
        f.searches += 1;
        f.searching = true;
        Ok(())
    }
    fn poll_datagrams(&mut self) -> Option<Result<Vec<Datagram>>> {
        let mut f = self.fake.borrow_mut();
        if !core::mem::take(&mut f.searching) {
            return None;
        }
        Some(Ok(f
            .mdns
            .iter()
            .map(|p| mdns::tests::datagram(p))
            .collect()))
    }
    fn log(&mut self, _: &str, _: &str) -> Result {
        Ok(())
    }
    async fn send(&mut self, v: &Value) -> Result {
        self.fake.borrow_mut().calls.push(clone(v)?);
        self.wire.send(v).await
    }
    async fn next(&mut self) -> Result<Event> {
        self.wire.next().await
    }
    fn now(&self) -> u64 {
        self.wire.now()
    }
    fn wall_time(&self) -> Result<u64> {
        self.wire.wall_time()
    }
    fn random(&mut self) -> Result<[u8; 32]> {
        self.wire.random()
    }
}

const ID: &str = "com.stulp.esphome";
fn client(devices: &str) -> (Client<Net>, Rc<RefCell<Fake>>) {
    let p = Esphome::default();
    let c = Wire::client(ID, p.manifest(), devices, "{}");
    let snapshot = clone(c.state().root()).unwrap();
    let fake = Rc::new(RefCell::new(Fake {
        events: VecDeque::new(),
        opened: Vec::new(),
        closed: Vec::new(),
        written: Vec::new(),
        decoders: Vec::new(),
        calls: Vec::new(),
        mac: "C8:C9:A3:6A:BD:17",
        password: false,
        ringing: false,
        answer: true,
        mdns: alloc::vec![mdns::tests::DOORBELL],
        searches: 0,
        searching: false,
    }));
    let net = Net {
        wire: c.into_transport(),
        fake: fake.clone(),
    };
    (Client::from_snapshot(net, snapshot).unwrap(), fake)
}
fn doorbell(store: &str) -> String {
    alloc::format!(
        r#"[{{"id":"bell","appId":"{ID}","driverId":"doorbell","name":"Deurbel","data":{{"mac":"c8c9a36abd17"}},"store":{store},"settings":{{"address":""}},"capabilities":["alarm_generic","onoff","measure_signal_strength"],"state":{{}},"available":true}}]"#
    )
}
fn handle(p: &mut Esphome, c: &mut Client<Net>, method: &str, params: &str) -> Result<Value> {
    stulp_platform::host::block_on(p.handle(c, method, &value(params)))
}
fn tick(p: &mut Esphome, c: &mut Client<Net>, n: usize) {
    for _ in 0..n {
        stulp_platform::host::block_on(p.tick(c)).unwrap();
        // Een lege ronde met de controller is een kloktik van 100 ms.
        stulp_platform::host::block_on(c.idle()).unwrap();
    }
}
fn state(c: &Client<Net>) -> &Value {
    field(c.state().device("bell").unwrap(), "state")
}
fn start(
    devices: &str,
    setup: impl FnOnce(&mut Fake),
) -> (Esphome, Client<Net>, Rc<RefCell<Fake>>) {
    let mut p = Esphome::default();
    let (mut c, fake) = client(devices);
    setup(&mut fake.borrow_mut());
    handle(&mut p, &mut c, "device.init", r#"{"deviceId":"bell"}"#).unwrap();
    // Openen, hello, connect, info, lijst, standen: een ronde per stap.
    tick(&mut p, &mut c, 8);
    (p, c, fake)
}
fn live(store: &str) -> (Esphome, Client<Net>, Rc<RefCell<Fake>>) {
    let (p, c, fake) = start(&doorbell(store), |_| ());
    assert_eq!(p.devices[0].phase, Phase::Live);
    (p, c, fake)
}

#[test]
fn handshake_lists_entities_and_reports_only_confirmed_values() {
    let (_p, c, fake) = live(r#"{"address":"192.168.1.71","port":6053}"#);
    let s = state(&c);
    assert_eq!(field(s, "alarm_generic").as_bool(), Some(false));
    assert_eq!(field(s, "onoff").as_bool(), Some(true));
    assert_eq!(
        stulp_sdk::util::number(field(s, "measure_signal_strength")),
        Some(-66.0)
    );
    // Diagnose en configuratie (uptime, IP, herstarten) krijgen geen tegel.
    assert_eq!(s.as_object().unwrap().len(), 3);
    assert!(json::boolean(
        c.state().device("bell").unwrap(),
        "available"
    ));
    let f = fake.borrow();
    assert_eq!(f.opened, [(1, "192.168.1.71".into(), 6053)]);
    let order: Vec<u32> = f.written.iter().map(|x| x.1).collect();
    assert_eq!(
        order,
        [
            api::HELLO_REQUEST,
            api::CONNECT_REQUEST,
            api::DEVICE_INFO_REQUEST,
            api::LIST_ENTITIES_REQUEST,
            api::SUBSCRIBE_STATES
        ]
    );
    // API 1.6, zonder wachtwoord.
    let hello = api::fields(&f.written[0].2).unwrap();
    assert!(matches!(hello[1], (2, api::Wire::Varint(1))));
    assert!(f.written[1].2.is_empty());
    assert_eq!(f.searches, 0);
}

#[test]
fn a_press_fires_the_flow_once_and_the_tile_follows_both_edges() {
    let (mut p, mut c, fake) = live(r#"{"address":"192.168.1.71","port":6053}"#);
    let before = fake.borrow().calls.len();
    // Indrukken en loslaten komen in dezelfde ronde binnen.
    fake.borrow_mut().push(api::BINARY_SENSOR_STATE, BELL, true);
    fake.borrow_mut()
        .push(api::BINARY_SENSOR_STATE, BELL, false);
    tick(&mut p, &mut c, 2);
    let f = fake.borrow();
    let calls = &f.calls[before..];
    let triggers: Vec<&Value> = calls
        .iter()
        .filter(|v| json::text(v, "m") == "flow.trigger")
        .collect();
    assert_eq!(triggers.len(), 1);
    let t = field(triggers[0], "p");
    assert_eq!(json::text(t, "id"), "doorbell_pressed");
    assert_eq!(json::text(field(t, "state"), "deviceId"), "bell");
    let flips: Vec<bool> = calls
        .iter()
        .filter(|v| json::text(v, "m") == "device.merge")
        .filter_map(|v| field(field(field(v, "p"), "patch"), "alarm_generic").as_bool())
        .collect();
    assert_eq!(flips, [true, false]);
    // Een herhaalde "uit" is geen nieuwe druk en geen nieuwe schrijfactie.
    drop(f);
    let before = fake.borrow().calls.len();
    fake.borrow_mut()
        .push(api::BINARY_SENSOR_STATE, BELL, false);
    tick(&mut p, &mut c, 2);
    assert!(
        fake.borrow().calls[before..]
            .iter()
            .all(|v| !matches!(json::text(v, "m"), "flow.trigger" | "device.merge"))
    );
}

#[test]
fn the_first_state_after_connecting_is_not_a_press() {
    let (mut p, mut c, fake) = start(
        &doorbell(r#"{"address":"192.168.1.71","port":6053}"#),
        |f| {
            f.ringing = true;
        },
    );
    assert_eq!(field(state(&c), "alarm_generic").as_bool(), Some(true));
    let triggers = |fake: &Rc<RefCell<Fake>>| {
        fake.borrow()
            .calls
            .iter()
            .filter(|v| json::text(v, "m") == "flow.trigger")
            .count()
    };
    assert_eq!(triggers(&fake), 0);
    fake.borrow_mut()
        .push(api::BINARY_SENSOR_STATE, BELL, false);
    tick(&mut p, &mut c, 2);
    assert_eq!(triggers(&fake), 0);
    fake.borrow_mut().push(api::BINARY_SENSOR_STATE, BELL, true);
    tick(&mut p, &mut c, 2);
    assert_eq!(triggers(&fake), 1);
}

#[test]
fn the_chime_switch_sends_a_command_and_waits_for_the_device() {
    let (mut p, mut c, fake) = live(r#"{"address":"192.168.1.71","port":6053}"#);
    handle(
        &mut p,
        &mut c,
        "capability.invoke",
        r#"{"deviceId":"bell","capability":"onoff","value":false}"#,
    )
    .unwrap();
    // Nog geen bevestiging: de tegel staat nog aan.
    assert_eq!(field(state(&c), "onoff").as_bool(), Some(true));
    {
        let f = fake.borrow();
        let (_, kind, b) = f.written.last().unwrap();
        assert_eq!(*kind, api::SWITCH_COMMAND);
        let fields = api::fields(b).unwrap();
        assert!(matches!(fields[0], (1, api::Wire::Fixed32(CHIME))));
        assert!(matches!(fields[1], (2, api::Wire::Varint(0))));
    }
    fake.borrow_mut().push(api::SWITCH_STATE, CHIME, false);
    tick(&mut p, &mut c, 2);
    assert_eq!(field(state(&c), "onoff").as_bool(), Some(false));
    // De herstartschakelaar is geen tegel en dus ook geen bediening.
    assert!(
        handle(
            &mut p,
            &mut c,
            "capability.invoke",
            r#"{"deviceId":"bell","capability":"onoff.doorbell_restart","value":true}"#,
        )
        .is_err()
    );
}

#[test]
fn without_an_address_the_doorbell_is_found_by_its_mac() {
    let (_p, c, fake) = live("{}");
    let store = field(c.state().device("bell").unwrap(), "store");
    assert_eq!(json::text(store, "address"), "192.168.1.71");
    assert_eq!(json::uint(store, "port"), 6053);
    assert_eq!(json::text(store, "project"), "zuidwijk.doorbell");
    assert_eq!(json::text(store, "version"), "2022.6.1");
    assert_eq!(fake.borrow().searches, 1);
}

#[test]
fn silence_makes_the_device_unavailable_and_it_reconnects_with_backoff() {
    let (mut p, mut c, fake) = live(r#"{"address":"192.168.1.71","port":6053}"#);
    fake.borrow_mut().answer = false;
    // Ping na 20 s, geen antwoord binnen 10 s.
    tick(&mut p, &mut c, 310);
    let d = c.state().device("bell").unwrap();
    assert!(!json::boolean(d, "available"));
    assert!(json::text(d, "unavailableMessage").contains("antwoordt niet"));
    assert!(fake.borrow().closed.contains(&1));
    assert!(fake.borrow().sent(api::PING_REQUEST) >= 1);
    fake.borrow_mut().answer = true;
    tick(&mut p, &mut c, 400);
    assert!(json::boolean(
        c.state().device("bell").unwrap(),
        "available"
    ));
    let f = fake.borrow();
    let last = f.opened.last().unwrap();
    assert!(last.0 > 1);
    assert_eq!(last.1, "192.168.1.71");
}

#[test]
fn a_different_device_at_the_address_is_a_clear_error() {
    let (p, c, _) = start(
        &doorbell(r#"{"address":"192.168.1.99","port":6053}"#),
        |f| {
            f.mac = "AA:BB:CC:DD:EE:FF";
        },
    );
    let d = c.state().device("bell").unwrap();
    assert!(json::text(d, "unavailableMessage").contains("ander ESPHome-apparaat"));
    assert!(p.devices[0].lost);
}

#[test]
fn a_password_protected_device_says_so() {
    let (_, c, _) = start(
        &doorbell(r#"{"address":"192.168.1.71","port":6053}"#),
        |f| {
            f.password = true;
        },
    );
    let d = c.state().device("bell").unwrap();
    assert!(json::text(d, "unavailableMessage").contains("wachtwoord"));
}

#[test]
fn pairing_lists_the_doorbell_once_and_not_when_already_paired() {
    let mut p = Esphome::default();
    let (mut c, _) = client("[]");
    let list = handle(&mut p, &mut c, "pair.list", r#"{"driverId":"doorbell"}"#).unwrap();
    let list = list.as_array().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(json::text(&list[0], "name"), "doorbell");
    assert_eq!(json::text(field(&list[0], "data"), "mac"), "c8c9a36abd17");
    assert_eq!(
        json::text(field(&list[0], "store"), "address"),
        "192.168.1.71"
    );
    let generic = handle(&mut p, &mut c, "pair.list", r#"{"driverId":"device"}"#).unwrap();
    assert_eq!(generic.as_array().unwrap().len(), 1);

    let (mut p, mut c, _) = live(r#"{"address":"192.168.1.71","port":6053}"#);
    let list = handle(&mut p, &mut c, "pair.list", r#"{"driverId":"doorbell"}"#).unwrap();
    assert!(list.as_array().unwrap().is_empty());
}

#[test]
fn a_generic_device_gets_its_tiles_from_the_entity_list() {
    let (_, c, _) = start(
        &alloc::format!(
            r#"[{{"id":"bell","appId":"{ID}","driverId":"device","name":"ESP","data":{{"mac":"c8c9a36abd17"}},"store":{{"address":"192.168.1.71","port":6053}},"settings":{{}},"capabilities":["onoff.gone","measure_temperature"],"state":{{}},"available":true}}]"#
        ),
        |_| (),
    );
    let caps: Vec<&str> = json::array(c.state().device("bell").unwrap(), "capabilities")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    // `onoff.gone` was van deze app en bestaat niet meer; `measure_temperature`
    // heeft geen achtervoegsel en is dus niet door deze app toegevoegd.
    assert_eq!(
        caps,
        [
            "measure_temperature",
            "alarm_generic.doorbell",
            "measure_signal_strength.doorbell_wifi_signal",
            "onoff.doorbell_chime_active"
        ]
    );
    assert_eq!(
        field(state(&c), "onoff.doorbell_chime_active").as_bool(),
        Some(true)
    );
}

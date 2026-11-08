//! REST-dispatch deelt dezelfde mutaties als het appkanaal.
use super::{Environment, Request, Response, copy, objects};
use alloc::vec::Vec;
use stulp_core::{
    Error, Result,
    json::{self, TryClone, Value},
    store::{Storage, Store},
};

/// Wat de REST-tabel van deze crate bij een verzoek vond; [`dispatch`]
/// `match`t erop. Paden en methodes staan alleen in [`routes`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// `GET /api/stulp/attach-token/{id}`.
    AttachToken,
    /// `POST /api/stulp/apps/{id}/install`.
    AppInstall,
    /// `PUT /api/stulp/devices/{id}/group`.
    DeviceGroup,
    /// `PUT /api/manager/flow/flow/{id}/enabled`.
    FlowEnabled,
    /// `GET /api/manager/devices/capability`.
    Capabilities,
    /// `GET /api/manager/devices/device/{id}/capability/{cap...}`.
    CapabilityValue,
    /// `GET /api/stulp/statistics`.
    Statistics,
    /// `GET /api/stulp/statistics/{id}/{cap...}`.
    StatisticsWindow,
    /// `GET /api/stulp/devices/{id}/media`.
    DeviceMedia,
    /// `GET /api/stulp/events`.
    Events,
    /// `GET /api/stulp/health`.
    Health,
    /// `GET /api/stulp/manage/bootstrap`.
    Bootstrap,
    /// `GET /api/manager/devices/device`.
    Devices,
    /// `GET /api/manager/apps/app`.
    Apps,
    /// `GET /api/manager/drivers/driver`.
    Drivers,
    /// `GET /api/manager/system/ping`.
    Ping,
    /// `GET /api/manager/system/name`.
    Name,
    /// `GET /api/manager/system`.
    ManagerSystem,
    /// `GET /api/stulp/system`.
    System,
    /// `PUT /api/stulp/system`.
    SystemUpdate,
    /// `GET /api/manager/drivers/driver/{id...}`.
    Driver,
    /// `/api/manager/apps/app/{rest...}`, elke methode: `GET` leest, de
    /// rest is van de diensten achter de controller (herstarten, wissen).
    App,
    /// `/api/manager/apps/app/{id}/setting/{key...}`, elke methode, met de
    /// eigen 405 van vóór de Mux.
    AppSetting,
    /// `PUT /api/manager/apps/app/{id}/enable` en `.../disable`.
    AppToggle(bool),
    /// `POST /api/stulp/log`.
    Log,
    /// `PUT /api/stulp/devices/order`.
    DeviceOrder,
    /// Een collectie, elke methode, met de eigen 405 van vóór de Mux.
    Collection(Collection),
    /// Een record in een collectie (`.../{id}`), idem.
    Record(Collection),
}

/// Een collectie achter de REST-API: haar naam in het document en of de
/// lijst een object op id is (`keyed`) of de waarde zelf.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Collection {
    name: &'static str,
    keyed: bool,
}

/// De collecties: het pad van de lijst, het patroon van een record, de naam
/// in het document en `keyed`.
const COLLECTIONS: [(&str, &str, &str, bool); 5] = [
    (
        "/api/stulp/device-groups",
        "/api/stulp/device-groups/{id}",
        "deviceGroups",
        false,
    ),
    (
        "/api/stulp/scenes",
        "/api/stulp/scenes/{id}",
        "scenes",
        false,
    ),
    (
        "/api/manager/flow/flow",
        "/api/manager/flow/flow/{id}",
        "flows",
        true,
    ),
    (
        "/api/manager/notifications/notification",
        "/api/manager/notifications/notification/{id}",
        "notifications",
        false,
    ),
    (
        "/api/manager/devices/device",
        "/api/manager/devices/device/{id}",
        "devices",
        true,
    ),
];

/// De routetabel, één keer gebouwd in [`super::Web::new`]. Een conflict is
/// een bedradingsfout en komt daar terug, niet bij een verzoek.
///
/// Wat hier niet staat, is niet van deze crate: `OPTIONS` (altijd 204, vóór
/// de tabel), de statische bestanden (`super::asset`) en wat de controller
/// na een 404 zelf routeert (koppelen, callbacks, scènes, de kaartcatalogus).
/// Daarom is een pad dat hier alleen een andere methode kent ook een 404 en
/// geen 405: de controller kan het voor die methode nog bedienen.
pub(super) fn routes() -> Result<leanhttp::Mux<Route>> {
    let mut mux = leanhttp::Mux::new();
    let table: [(&str, Route); 25] = [
        ("GET /api/stulp/attach-token/{id}", Route::AttachToken),
        ("POST /api/stulp/apps/{id}/install", Route::AppInstall),
        ("PUT /api/stulp/devices/{id}/group", Route::DeviceGroup),
        (
            "PUT /api/manager/flow/flow/{id}/enabled",
            Route::FlowEnabled,
        ),
        ("GET /api/manager/devices/capability", Route::Capabilities),
        (
            "GET /api/manager/devices/device/{id}/capability/{cap...}",
            Route::CapabilityValue,
        ),
        ("GET /api/stulp/statistics", Route::Statistics),
        (
            "GET /api/stulp/statistics/{id}/{cap...}",
            Route::StatisticsWindow,
        ),
        ("GET /api/stulp/devices/{id}/media", Route::DeviceMedia),
        ("GET /api/stulp/events", Route::Events),
        ("GET /api/stulp/health", Route::Health),
        ("GET /api/stulp/manage/bootstrap", Route::Bootstrap),
        ("GET /api/manager/devices/device", Route::Devices),
        ("GET /api/manager/apps/app", Route::Apps),
        ("GET /api/manager/drivers/driver", Route::Drivers),
        ("GET /api/manager/system/ping", Route::Ping),
        ("GET /api/manager/system/name", Route::Name),
        ("GET /api/manager/system", Route::ManagerSystem),
        ("GET /api/stulp/system", Route::System),
        ("PUT /api/stulp/system", Route::SystemUpdate),
        ("GET /api/manager/drivers/driver/{id...}", Route::Driver),
        ("/api/manager/apps/app/{rest...}", Route::App),
        (
            "/api/manager/apps/app/{id}/setting/{key...}",
            Route::AppSetting,
        ),
        ("POST /api/stulp/log", Route::Log),
        ("PUT /api/stulp/devices/order", Route::DeviceOrder),
    ];
    let wire = |e: leanhttp::Error| match e {
        leanhttp::Error::Alloc { .. } => Error::Memory,
        _ => Error::Invalid("REST route table"),
    };
    for (pattern, route) in table {
        mux.handle(pattern, route).map_err(wire)?;
    }
    for (pattern, on) in [
        ("PUT /api/manager/apps/app/{id}/enable", true),
        ("PUT /api/manager/apps/app/{id}/disable", false),
    ] {
        mux.handle(pattern, Route::AppToggle(on)).map_err(wire)?;
    }
    for (list, record, name, keyed) in COLLECTIONS {
        let collection = Collection { name, keyed };
        mux.handle(list, Route::Collection(collection))
            .map_err(wire)?;
        mux.handle(record, Route::Record(collection))
            .map_err(wire)?;
    }
    Ok(mux)
}

pub(super) fn dispatch<S: Storage>(
    store: &mut Store<S>,
    routes: &leanhttp::Mux<Route>,
    req: &Request,
    env: &mut impl Environment,
) -> Result<Response> {
    let method = if req.method == "HEAD" {
        "GET"
    } else {
        &req.method
    };
    if method == "OPTIONS" {
        return Response::json(204, &Value::Null);
    }
    // De Mux zoekt op een leanhttp-verzoek; alleen methode en pad tellen.
    let mut found = leanhttp::Request::default();
    found.method = json::copy(&req.method)?;
    found.path = json::copy(&req.path)?;
    let route = match routes.find(&mut found).map_err(|_| Error::Memory)? {
        leanhttp::Found::Route(route) => *route,
        // Ook een andere methode is "niet van ons": zie [`routes`].
        leanhttp::Found::NotFound | leanhttp::Found::MethodNotAllowed(_) => {
            return Err(Error::Missing("route not found"));
        }
    };
    let value = |name: &str| found.path_value(name).unwrap_or("");
    let result = match route {
        Route::AttachToken => return super::manager::attach_token(store, env, value("id")),
        Route::AppInstall => return super::manager::install(store, env, value("id")),
        Route::DeviceGroup => return super::manager::group(store, req, env, value("id")),
        Route::FlowEnabled => return super::manager::flow_enabled(store, req, env, value("id")),
        Route::Capabilities => return super::manager::capabilities(store),
        Route::CapabilityValue => {
            return super::manager::capability_value(store, value("id"), value("cap"));
        }
        Route::Statistics => return Response::json(200, &store.statistics().list()?),
        Route::StatisticsWindow => {
            let window = req
                .query
                .split('&')
                .filter_map(|q| q.split_once('='))
                .find(|(k, _)| *k == "window")
                .map(|(_, v)| v)
                .unwrap_or("");
            return Response::json(
                200,
                &store
                    .statistics()
                    .window(value("id"), value("cap"), window)?,
            );
        }
        Route::DeviceMedia => return Response::json(200, &store.device_media(value("id"))?),
        Route::Events => {
            super::query_value(&req.query, "manager")?;
            if !matches!(
                super::query_value(&req.query, "view")?.as_str(),
                "" | "overview"
            ) {
                return Response::error(400, "unknown event view");
            }
            return Ok(Response {
                status: 200,
                content_type: "text/event-stream",
                body: super::Body::Static(b": connected\n\n"),
                headers: Vec::new(),
            });
        }
        Route::Health => json::fields(&[
            ("ok", Value::Bool(true)),
            ("stulpVersion", json::string(env!("CARGO_PKG_VERSION"))?),
        ])?,
        Route::Bootstrap => json::fields(&[
            ("ok", Value::Bool(true)),
            ("stulpVersion", json::string(env!("CARGO_PKG_VERSION"))?),
            ("devices", super::views::devices(store, "overview")?),
            (
                "deviceGroups",
                copy(json::get(store.document().root(), "deviceGroups"))?,
            ),
        ])?,
        Route::Devices => {
            let view = super::query_value(&req.query, "view")?;
            if !matches!(view.as_str(), "" | "overview" | "automation") {
                return Response::error(400, "unknown device view");
            }
            super::views::devices(store, &view)?
        }
        Route::Apps => objects::apps(store)?,
        Route::Drivers => objects::drivers(store)?,
        Route::Ping => Value::Bool(true),
        Route::Name => json::string("Stulp")?,
        Route::ManagerSystem => json::fields(&[
            ("name", json::string("Stulp")?),
            ("version", json::string(env!("CARGO_PKG_VERSION"))?),
            ("language", json::string(store.language())?),
        ])?,
        Route::System => system(store)?,
        Route::Driver => {
            let drivers = objects::drivers(store)?;
            return Response::json(
                200,
                json::get(&drivers, value("id")).ok_or(Error::Missing("driver does not exist"))?,
            );
        }
        Route::App => {
            if method != "GET" {
                return Err(Error::Missing("route not found"));
            }
            return app_read(store, value("rest"));
        }
        Route::AppSetting => {
            let (id, key) = (value("id"), value("key"));
            if method == "GET" {
                // Lezen gaat zoals elke andere GET onder deze app.
                let rest = req
                    .path
                    .strip_prefix("/api/manager/apps/app/")
                    .unwrap_or("");
                return app_read(store, rest);
            }
            if key.is_empty() {
                return Err(Error::Missing("route not found"));
            }
            match method {
                "PUT" => {
                    let body = json::parse(&req.body)?;
                    let value = json::get(&body, "value")
                        .ok_or(Error::Invalid("value is required"))?
                        .try_clone()?;
                    store.setting(id, key, Some(value))?;
                }
                "DELETE" => store.setting(id, key, None)?,
                _ => return Response::error(405, "method not allowed"),
            }
            Value::Bool(true)
        }
        Route::AppToggle(on) => {
            let id = value("id");
            let mut record = store.document().record("apps", id)?.try_clone()?;
            if json::boolean(&record, "offered") {
                return Err(Error::Invalid("install the offered app first"));
            }
            json::set(&mut record, "enabled", Value::Bool(on))?;
            store.put("apps", record, false, None, &env.now()?)?;
            Value::Bool(true)
        }
        Route::Log => {
            log(req, env)?;
            Value::Bool(true)
        }
        Route::SystemUpdate => {
            let body = json::parse(&req.body)?;
            let mut system = copy(json::get(store.document().root(), "system"))?;
            if let Some(value) = json::get(&body, "statistics") {
                if value.as_bool().is_none() {
                    return Err(Error::Invalid("statistics must be boolean"));
                }
                json::set(&mut system, "statistics", value.try_clone()?)?;
            }
            if let Some(patch) = json::get(&body, "units") {
                let mut units = match json::get(&system, "units") {
                    Some(value) => value.try_clone()?,
                    None => json::object(),
                };
                stulp_core::units::update(&mut units, patch)?;
                json::set(&mut system, "units", units)?;
            }
            store.system(system)?;
            self::system(store)?
        }
        Route::DeviceOrder => {
            let body = json::parse(&req.body)?;
            let mut ids = Vec::new();
            for id in json::array(&body, "deviceIds") {
                json::push(
                    &mut ids,
                    id.as_str().ok_or(Error::Invalid("invalid device id"))?,
                    4096,
                )?;
            }
            store.reorder_devices(json::text(&body, "groupId"), &ids)?;
            Value::Bool(true)
        }
        Route::Collection(c) => {
            return collection_request(store, c.name, c.keyed, method, req, env);
        }
        Route::Record(c) => {
            return record_request(store, c.name, value("id"), method, req, env);
        }
    };
    Response::json(200, &result)
}

/// `POST /api/stulp/log`: de iOS-app en de Matter-extensie loggen hierlangs
/// mee op de node, één regel per stap, zodat een vastgelopen koppeling niet
/// alleen op de telefoon staat. Begrensd en zonder opslag; alleen de console.
fn log(req: &Request, env: &mut impl Environment) -> Result {
    let body = json::parse(&req.body)?;
    let source = json::text(&body, "source").trim();
    let level = json::text(&body, "level");
    let message = json::text(&body, "message").trim();
    if source.is_empty() || source.len() > 64 || source.contains(|c: char| c.is_control()) {
        return Err(Error::Invalid(
            "log source must be 1-64 printable characters",
        ));
    }
    if !matches!(level, "info" | "warn" | "error") {
        return Err(Error::Invalid("log level must be info, warn or error"));
    }
    if message.is_empty() || message.len() > 1024 {
        return Err(Error::Invalid("log message must be 1-1024 characters"));
    }
    let mut clean = alloc::string::String::new();
    clean
        .try_reserve(message.len())
        .map_err(|_| Error::Memory)?;
    for c in message.chars() {
        clean.push(if c.is_control() { ' ' } else { c });
    }
    env.log(source, level, &clean);
    Ok(())
}

fn system<S: Storage>(store: &Store<S>) -> Result<Value> {
    let mut system = copy(json::get(store.document().root(), "system"))?;
    json::remove(&mut system, "attachSecret")?;
    let units = stulp_core::units::filled(json::get(&system, "units").unwrap_or(&json::object()))?;
    json::set(&mut system, "units", units)?;
    json::set(&mut system, "unitsOffer", stulp_core::units::offer()?)?;
    json::set(
        &mut system,
        "statistics",
        Value::Bool(store.statistics_enabled()),
    )?;
    json::set(
        &mut system,
        "statisticsRunning",
        Value::Bool(store.statistics_enabled()),
    )?;
    json::set(
        &mut system,
        "statisticsBytes",
        Value::uint(store.statistics().bytes() as u64),
    )?;
    Ok(system)
}

fn collection_request<S: Storage>(
    store: &mut Store<S>,
    collection: &str,
    keyed: bool,
    method: &str,
    req: &Request,
    env: &mut impl Environment,
) -> Result<Response> {
    match method {
        "GET" => {
            if keyed {
                let mut out = json::Object::new();
                for record in store.document().records(collection) {
                    out.push(
                        json::text(record, "id"),
                        if collection == "flows" {
                            super::flow_units::convert(store, record, false, None)?
                        } else {
                            record.try_clone()?
                        },
                    )?;
                }
                Response::json(200, &Value::Object(out))
            } else if collection == "scenes" {
                let mut out = Vec::new();
                for s in store.document().records(collection) {
                    json::push(&mut out, super::scenes::output(store, s)?, 4096)?;
                }
                Response::json(200, &Value::Array(out))
            } else {
                Response::json(200, &copy(json::get(store.document().root(), collection))?)
            }
        }
        "POST" if matches!(collection, "deviceGroups" | "scenes" | "flows") => {
            let mut body = json::parse(&req.body)?;
            let id = env.id()?;
            json::set(&mut body, "id", json::string(&id)?)?;
            if collection == "scenes" && json::get(&body, "states").is_some() {
                super::scenes::incoming(store, &mut body, None)?;
            }
            if collection == "flows" {
                body = super::flow_units::convert(store, &body, true, None)?;
            }
            normalize_flow_ids(collection, &mut body, env)?;
            store.put(collection, body, true, None, &env.now()?)?;
            if collection == "scenes" {
                Response::json(
                    201,
                    &super::scenes::output(store, store.document().record(collection, &id)?)?,
                )
            } else {
                let record = store.document().record(collection, &id)?;
                Response::json(
                    201,
                    &if collection == "flows" {
                        super::flow_units::convert(store, record, false, None)?
                    } else {
                        record.try_clone()?
                    },
                )
            }
        }
        _ => Response::error(405, "method not allowed"),
    }
}

fn record_request<S: Storage>(
    store: &mut Store<S>,
    collection: &str,
    id: &str,
    method: &str,
    req: &Request,
    env: &mut impl Environment,
) -> Result<Response> {
    match method {
        "GET" if collection == "devices" => Response::json(200, &objects::device(store, id)?),
        "GET" if collection == "scenes" => Response::json(
            200,
            &super::scenes::output(store, store.document().record(collection, id)?)?,
        ),
        "GET" if collection == "flows" => Response::json(
            200,
            &super::flow_units::convert(
                store,
                store.document().record(collection, id)?,
                false,
                None,
            )?,
        ),
        "GET" => Response::json(200, store.document().record(collection, id)?),
        // Ontkoppelen vraagt eerst de app om externe middelen op te ruimen.
        "DELETE" if collection == "devices" => {
            Err(Error::Missing("device removal requires app callback"))
        }
        "DELETE" => {
            store.delete(collection, id)?;
            Response::json(200, &Value::Bool(true))
        }
        "PUT" if collection != "notifications" => {
            let body = json::parse(&req.body)?;
            if collection == "devices" {
                let d = store.document().record("devices", id)?;
                if json::text(d, "appId") == "com.stulp.scene"
                    && let Some(name) = json::get(&body, "name")
                    && !json::get(d, "name").is_some_and(|v| json::equal(v, name))
                {
                    let sid = json::copy(json::text(
                        json::get(d, "data").unwrap_or(&Value::Null),
                        "sceneId",
                    ))?;
                    let mut scene = store.document().record("scenes", &sid)?.try_clone()?;
                    json::set(&mut scene, "name", name.try_clone()?)?;
                    store.put("scenes", scene, false, None, &env.now()?)?;
                }
            }
            let mut record = store.document().record(collection, id)?.try_clone()?;
            let fields: &[&str] = match collection {
                "devices" => &["name", "groupId"],
                "deviceGroups" => &["name", "parentId", "sortOrder"],
                "flows" => &["name", "enabled", "nodes", "edges"],
                "scenes" => &["name", "kind", "states"],
                _ => &[],
            };
            for key in fields {
                if let Some(value) = json::get(&body, key) {
                    json::set(&mut record, key, value.try_clone()?)?;
                }
            }
            if collection == "devices" {
                super::manager::metadata(&mut record, &body)?;
            }
            if collection == "scenes" && json::get(&body, "states").is_some() {
                super::scenes::incoming(
                    store,
                    &mut record,
                    Some(store.document().record(collection, id)?),
                )?;
            }
            if collection == "flows" && json::get(&body, "nodes").is_some() {
                record = super::flow_units::convert(
                    store,
                    &record,
                    true,
                    Some(store.document().record(collection, id)?),
                )?;
            }
            normalize_flow_ids(collection, &mut record, env)?;
            let revision = json::get(&body, "revision")
                .map(|v| v.as_u64().ok_or(Error::Invalid("invalid revision")))
                .transpose()?;
            store.put(collection, record, false, revision, &env.now()?)?;
            if collection == "devices" {
                Response::json(200, &objects::device(store, id)?)
            } else if collection == "scenes" {
                Response::json(
                    200,
                    &super::scenes::output(store, store.document().record(collection, id)?)?,
                )
            } else {
                let record = store.document().record(collection, id)?;
                Response::json(
                    200,
                    &if collection == "flows" {
                        super::flow_units::convert(store, record, false, None)?
                    } else {
                        record.try_clone()?
                    },
                )
            }
        }
        _ => Response::error(405, "method not allowed"),
    }
}

fn normalize_flow_ids(collection: &str, value: &mut Value, env: &mut impl Environment) -> Result {
    if collection != "flows" {
        return Ok(());
    }
    for field in ["nodes", "edges"] {
        let mut records = Vec::new();
        for item in json::array(value, field) {
            let mut item = item.try_clone()?;
            if json::text(&item, "id").trim().is_empty() {
                json::set(&mut item, "id", json::string(&env.id()?)?)?;
            }
            json::push(&mut records, item, 256)?;
        }
        json::set(value, field, Value::Array(records))?;
    }
    Ok(())
}

fn app_read<S: Storage>(store: &Store<S>, path: &str) -> Result<Response> {
    let (id, tail) = path.split_once('/').unwrap_or((path, ""));
    let app = objects::app(store, id)?;
    let empty = json::object();
    let manifest = store.manifest(id).unwrap_or(&empty);
    let settings = json::get(store.document().root(), "appSettings")
        .and_then(|s| json::get(s, id))
        .unwrap_or(&empty);
    let value = match tail {
        "" => app,
        "setting" => settings.try_clone()?,
        "locale" => json::fields(&[
            ("language", json::string(store.language())?),
            ("name", copy(json::get(&app, "name"))?),
            ("manifest", manifest.try_clone()?),
        ])?,
        "update" => json::fields(&[
            ("version", copy(json::get(&app, "version"))?),
            ("updateAvailable", Value::Bool(false)),
            (
                "reason",
                json::string(
                    "an app is updated by placing a new image; it announces its version when it attaches",
                )?,
            ),
        ])?,
        _ => {
            let key = tail
                .strip_prefix("setting/")
                .filter(|k| !k.is_empty())
                .ok_or(Error::Missing("route not found"))?;
            json::get(settings, key)
                .ok_or(Error::Missing("setting does not exist"))?
                .try_clone()?
        }
    };
    Response::json(200, &value)
}

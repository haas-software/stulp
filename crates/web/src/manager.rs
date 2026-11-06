//! Beheerhandelingen gebruiken dezelfde documenteigenaar als de appverbindingen.
use super::{Environment, Request, Response, objects};
use stulp_core::{
    Error, Result,
    json::{self, TryClone, Value},
    store::{Storage, Store},
};

/// `GET /api/stulp/attach-token/{id}`: het attach-token van een app, met
/// het geheim dat bij de eerste vraag ontstaat.
pub(super) fn attach_token<S: Storage>(
    store: &mut Store<S>,
    env: &mut impl Environment,
    id: &str,
) -> Result<Response> {
    let mut system = json::get(store.document().root(), "system")
        .unwrap_or(&json::object())
        .try_clone()?;
    if json::text(&system, "attachSecret").is_empty() {
        let mut secret = env.id()?;
        let extra = env.id()?;
        secret.try_reserve(extra.len()).map_err(|_| Error::Memory)?;
        secret.push_str(&extra);
        json::set(&mut system, "attachSecret", json::string(&secret)?)?;
        store.system(system.try_clone()?)?;
    }
    let token = stulp_protocol::token::token(json::text(&system, "attachSecret"), id)?;
    Response::json(
        200,
        &json::fields(&[
            ("appId", json::string(id)?),
            ("token", json::string(&token)?),
            (
                "known",
                Value::Bool(store.document().record("apps", id).is_ok()),
            ),
        ])?,
    )
}

/// `POST /api/stulp/apps/{id}/install`: een aangeboden app installeren.
pub(super) fn install<S: Storage>(
    store: &mut Store<S>,
    env: &mut impl Environment,
    id: &str,
) -> Result<Response> {
    let mut app = store.document().record("apps", id)?.try_clone()?;
    if json::boolean(&app, "offered") {
        json::set(&mut app, "offered", Value::Bool(false))?;
        json::set(&mut app, "enabled", Value::Bool(true))?;
        store.put("apps", app, false, None, &env.now()?)?;
    }
    Response::json(200, &objects::app(store, id)?)
}

/// `PUT /api/stulp/devices/{id}/group`: een apparaat naar een andere groep.
pub(super) fn group<S: Storage>(
    store: &mut Store<S>,
    r: &Request,
    env: &mut impl Environment,
    id: &str,
) -> Result<Response> {
    let body = json::parse(&r.body)?;
    let group = json::get(&body, "groupId")
        .and_then(Value::as_str)
        .ok_or(Error::Invalid("groupId is required"))?;
    let mut d = store.device(id)?;
    json::set(&mut d, "groupId", json::string(group)?)?;
    store.put("devices", d, false, None, &env.now()?)?;
    Response::json(200, &objects::device(store, id)?)
}

/// `PUT /api/manager/flow/flow/{id}/enabled`: een Flow aan of uit.
pub(super) fn flow_enabled<S: Storage>(
    store: &mut Store<S>,
    r: &Request,
    env: &mut impl Environment,
    id: &str,
) -> Result<Response> {
    let body = json::parse(&r.body)?;
    let enabled = json::get(&body, "enabled")
        .and_then(Value::as_bool)
        .ok_or(Error::Invalid("enabled must be boolean"))?;
    let mut flow = store.document().record("flows", id)?.try_clone()?;
    json::set(&mut flow, "enabled", Value::Bool(enabled))?;
    store.put("flows", flow, false, None, &env.now()?)?;
    Response::json(200, store.document().record("flows", id)?)
}

/// `GET /api/manager/devices/capability`: elke capability die een apparaat
/// heeft, één keer.
pub(super) fn capabilities<S: Storage>(store: &Store<S>) -> Result<Response> {
    let mut catalog = json::object();
    for record in store.document().records("devices") {
        let d = store.device(json::text(record, "id"))?;
        for id in json::array(&d, "capabilities")
            .iter()
            .filter_map(Value::as_str)
        {
            if json::get(&catalog, id).is_none() {
                let definition = super::capability::definition(store, &d, id)?;
                json::set(
                    &mut catalog,
                    id,
                    json::fields(&[
                        ("id", json::string(id)?),
                        ("uri", json::string("stulp:manager:devices")?),
                        ("type", json::string(json::text(&definition, "type"))?),
                        ("getable", Value::Bool(true)),
                        ("setable", Value::Bool(true)),
                    ])?,
                )?;
            }
        }
    }
    Response::json(200, &catalog)
}

/// `GET /api/manager/devices/device/{id}/capability/{cap...}`: de waarde.
pub(super) fn capability_value<S: Storage>(
    store: &Store<S>,
    id: &str,
    cap: &str,
) -> Result<Response> {
    let d = store.device(id)?;
    if !json::array(&d, "capabilities")
        .iter()
        .any(|v| v.as_str() == Some(cap))
    {
        return Err(Error::Missing("capability does not exist"));
    }
    Response::json(
        200,
        json::get(&d, "state")
            .and_then(|v| json::get(v, cap))
            .unwrap_or(&Value::Null),
    )
}

pub(super) fn metadata(record: &mut Value, patch: &Value) -> Result {
    let mut data = json::get(record, "store")
        .unwrap_or(&json::object())
        .try_clone()?;
    for (key, stored) in FIELDS {
        if let Some(value) = json::get(patch, key) {
            json::set(&mut data, stored, value.try_clone()?)?;
        }
    }
    json::set(record, "store", data)
}
pub(super) const FIELDS: &[(&str, &str)] = &[
    ("zone", "__stulp.api.zone"),
    ("note", "__stulp.api.note"),
    ("iconOverride", "__stulp.api.iconOverride"),
    ("virtualClass", "__stulp.api.virtualClass"),
    ("uiIndicator", "__stulp.api.uiIndicator"),
    ("hidden", "__stulp.api.hidden"),
];

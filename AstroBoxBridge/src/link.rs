//! Connection lifecycle: emulator bridge → Bluetooth link → companion core device.

use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use bluetooth::emu::bridge;
use corelib::device::{
    DeviceKind,
    xiaomi::{
        SendError,
        components::{auth::AuthComponent, bind::XiaomiConnectOptions, info::InfoSystem},
        packet::dispatcher,
        r#type::ConnectType,
    },
};
use pb::xiaomi::protocol;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Notify;

use crate::host;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ConnState {
    Disconnected,
    Attaching,
    Connecting,
    Connected,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Battery {
    pub level: u32,
    /// unknown | charging | notCharging | full
    pub charge_status: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSummary {
    pub name: String,
    pub addr: String,
    pub serial_number: String,
    pub firmware_version: String,
    pub model: String,
    pub product_device: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub battery: Option<Battery>,
}

/// One connection attempt and, if it succeeds, the connection it becomes.
struct Session {
    generation: u64,
    lost: Notify,
    lost_reason: Mutex<Option<String>>,
}

struct Link {
    state: ConnState,
    device: Option<DeviceSummary>,
    /// companion core device id (the band's Bluetooth address) while one exists.
    addr: Option<String>,
    session: Option<Arc<Session>>,
    generation: u64,
}

static LINK: Mutex<Link> = Mutex::new(Link {
    state: ConnState::Disconnected,
    device: None,
    addr: None,
    session: None,
    generation: 0,
});

/// Serialises connect / disconnect / teardown.
static OP: LazyLock<tokio::sync::Mutex<()>> = LazyLock::new(|| tokio::sync::Mutex::new(()));

fn link() -> std::sync::MutexGuard<'static, Link> {
    LINK.lock().unwrap_or_else(|e| e.into_inner())
}

fn set_state(state: ConnState, device: Option<DeviceSummary>) {
    let changed = {
        let mut l = link();
        let changed = l.state != state || l.device != device;
        l.state = state;
        l.device = device.clone();
        changed
    };
    if changed {
        host::emit(json!({ "type": "state", "state": state, "device": device }));
    }
}

/// The connected band's device id, or an error for methods that need one.
pub fn connected_addr() -> Result<String, String> {
    let l = link();
    match (l.state, l.addr.as_ref()) {
        (ConnState::Connected, Some(addr)) => Ok(addr.clone()),
        (ConnState::Attaching | ConnState::Connecting, _) => Err("still connecting to the band".into()),
        _ => Err("not connected to a band (call `connect` first)".into()),
    }
}

// ----------------------------------------------------------------- connect

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectParams {
    #[serde(default = "default_host")]
    host: String,
    port: u16,
    auth_key: String,
    state_dir: PathBuf,
    #[serde(default = "default_timeout")]
    timeout_secs: u64,
    /// Optional app device id to present during AUTH; defaults to the one
    /// saved in `stateDir/credentials.json`, if any.
    #[serde(default)]
    app_device_id: Option<String>,
}

fn default_host() -> String {
    "127.0.0.1".into()
}

fn default_timeout() -> u64 {
    120
}

pub async fn connect(p: ConnectParams) -> Result<Value, String> {
    let auth_key = p.auth_key.trim().to_ascii_lowercase();
    if auth_key.len() != 32 || !auth_key.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("authKey must be 32 hex characters".into());
    }
    if p.port == 0 {
        return Err("port must be non-zero".into());
    }

    let _op = OP.lock().await;
    teardown(None).await;

    let session = {
        let mut l = link();
        l.generation += 1;
        let s = Arc::new(Session { generation: l.generation, lost: Notify::new(), lost_reason: Mutex::new(None) });
        l.session = Some(s.clone());
        s
    };
    let deadline = Instant::now() + Duration::from_secs(p.timeout_secs.max(5));

    match connect_inner(&p, &auth_key, &session, deadline).await {
        Ok(device) => {
            set_state(ConnState::Connected, Some(device.clone()));
            tokio::spawn(watchdog(session));
            serde_json::to_value(device).map_err(|e| e.to_string())
        }
        Err(err) => {
            log::warn!(target: "mirage", "connect failed: {err}");
            teardown(None).await;
            Err(err)
        }
    }
}

async fn connect_inner(
    p: &ConnectParams,
    auth_key: &str,
    session: &Arc<Session>,
    deadline: Instant,
) -> Result<DeviceSummary, String> {
    set_state(ConnState::Attaching, None);
    std::fs::create_dir_all(&p.state_dir)
        .map_err(|e| format!("cannot create stateDir {}: {e}", p.state_dir.display()))?;
    let keys = p.state_dir.join("link-keys");

    // 1. attach to the emulator's HCI bridge (it may not be listening yet)
    let endpoint = format!("{}:{}", p.host, p.port);
    loop {
        let (host, port, keys) = (p.host.clone(), p.port, keys.clone());
        match blocking(move || bridge().attach(&host, port, Some(keys))).await? {
            Ok(_) => break,
            Err(err) if Instant::now() + Duration::from_secs(2) < deadline => {
                log::info!(target: "mirage", "bridge {endpoint} not ready ({err}); retrying");
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            Err(err) => return Err(format!("cannot attach to the emulator bridge at {endpoint}: {err}")),
        }
    }

    // 2. find the band and page it: pair (the band may ask the user to
    // confirm), encrypt, open SPP. Bonded addresses from link-keys are known
    // up front without names; devices that answered this session's inquiry
    // carry names, so try those first (a stale bonded address only costs a
    // page timeout). Keep inquiring while the band may still be booting.
    tokio::time::sleep(Duration::from_secs(3)).await; // attach's inquiry
    let mut attempt = 0;
    let found = 'search: loop {
        let mut candidates = bridge().status().session.devices;
        candidates.sort_by_key(|d| d.name.trim().is_empty());
        let mut last_error = None;
        for dev in candidates {
            attempt += 1;
            set_state(ConnState::Connecting, None);
            host::take_bridge_warning();
            let a = dev.addr.clone();
            let Err(err) = blocking(move || bridge().connect(&a, &[5, 1], false)).await? else {
                break 'search dev;
            };
            let reason = host::take_bridge_warning().unwrap_or_else(|| format!("{err:?}"));
            if reason.contains("declined") {
                return Err(format!("Bluetooth pairing failed: {reason}"));
            }
            if !bridge().attached() {
                return Err(format!("the emulator bridge closed ({reason})"));
            }
            log::warn!(target: "mirage", "Bluetooth connect attempt {attempt} to {} failed: {reason}", dev.addr);
            last_error = Some(reason);
        }
        if Instant::now() + Duration::from_secs(8) >= deadline {
            return Err(match last_error {
                Some(reason) => format!("Bluetooth connection failed: {reason}"),
                None => "the band did not answer the Bluetooth inquiry (is it still booting?)".into(),
            });
        }
        if last_error.is_none() {
            log::info!(target: "mirage", "no band found yet; inquiring again");
        }
        if let Err(err) = blocking(|| bridge().rescan()).await? {
            return Err(format!("inquiry failed: {err}"));
        }
        tokio::time::sleep(Duration::from_secs(4)).await;
    };
    let addr = found.addr.clone();
    let name = bridge()
        .status()
        .session
        .devices
        .into_iter()
        .find(|d| d.addr == addr && !d.name.trim().is_empty())
        .map(|d| d.name)
        .or_else(|| saved_credential(&p.state_dir, "name"))
        .unwrap_or_else(|| "Xiaomi Band".to_string());
    log::info!(target: "mirage", "Bluetooth link up with {name} ({addr})");

    // 4. route the band's bytes into the companion core and authenticate
    let rt = tokio::runtime::Handle::current();
    let generation = session.generation;
    let rx_addr = addr.clone();
    let on_data = move |data: Result<Vec<u8>, String>| match data {
        Ok(data) => dispatcher::on_packet(rt.clone(), rx_addr.clone(), data),
        Err(err) => link_lost(generation, err),
    };
    bridge()
        .subscribe(Arc::new(move |data| {
            // never unwind into the bridge's reader thread
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| on_data(data)));
        }))
        .map_err(|e| format!("cannot subscribe to the SPP channel: {e:?}"))?;
    link().addr = Some(addr.clone());

    let app_device_id = p.app_device_id.clone().or_else(|| saved_credential(&p.state_dir, "appDeviceId"));
    let options = XiaomiConnectOptions { local_bind: None, app_device_id };
    let auth = corelib::device::create_device_with_options(
        tokio::runtime::Handle::current(),
        DeviceKind::Xiaomi,
        name.clone(),
        addr.clone(),
        auth_key.to_string(),
        2,
        ConnectType::SPP,
        Some(6),
        bridge().max_send_len(),
        None,
        false,
        options,
        |data| async move { bridge().send_async(data).await.map_err(|e| SendError::Io(format!("{e:?}"))) },
    );
    let remaining = deadline.saturating_duration_since(Instant::now()).max(Duration::from_secs(20));
    tokio::select! {
        r = tokio::time::timeout(remaining, auth) => match r {
            Ok(Ok(_)) => {}
            Ok(Err(err)) => return Err(format!("authentication failed: {err:#}")),
            Err(_) => return Err("timed out authenticating with the band (wrong AuthKey?)".into()),
        },
        reason = session_lost(session) => return Err(format!("the band dropped the link while authenticating: {reason}")),
    }
    log::info!(target: "mirage", "authenticated with {name} ({addr})");
    save_credentials(&p.state_dir, &addr, &name, &endpoint).await;

    // 5. device info + battery
    tokio::select! {
        d = fetch_device(&addr, &name) => Ok(d),
        reason = session_lost(session) => Err(format!("the band dropped the link: {reason}")),
    }
}

async fn session_lost(session: &Session) -> String {
    session.lost.notified().await;
    session.lost_reason.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or_default()
}

/// Run blocking bridge work off the async workers.
async fn blocking<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> Result<R, String> {
    tokio::task::spawn_blocking(f).await.map_err(|e| {
        if e.is_panic() {
            format!("internal error: {}", host::panic_message(&*e.into_panic()))
        } else {
            "cancelled".to_string()
        }
    })
}

/// A string field of `stateDir/credentials.json`, written after the last
/// successful connect.
fn saved_credential(dir: &Path, key: &str) -> Option<String> {
    let text = std::fs::read(dir.join("credentials.json")).ok()?;
    let v: Value = serde_json::from_slice(&text).ok()?;
    v[key].as_str().filter(|s| !s.trim().is_empty()).map(str::to_owned)
}

async fn save_credentials(dir: &Path, addr: &str, name: &str, endpoint: &str) {
    let a = addr.to_string();
    let creds = corelib::ecs::with_rt_mut(move |rt| {
        rt.component_ref::<AuthComponent>(&a)
            .map(|auth| json!({ "authkey": auth.authkey, "appDeviceId": auth.app_device_id }))
    })
    .await;
    if let Some(mut creds) = creds {
        creds["addr"] = json!(addr);
        creds["name"] = json!(name);
        creds["endpoint"] = json!(endpoint);
        let path = dir.join("credentials.json");
        if let Err(err) = std::fs::write(&path, serde_json::to_vec_pretty(&creds).unwrap_or_default()) {
            log::warn!(target: "mirage", "cannot write {}: {err}", path.display());
        }
    }
}

// ------------------------------------------------------------- device info

const INFO_TIMEOUT: Duration = Duration::from_secs(8);

async fn request_info(addr: &str) -> Result<protocol::DeviceInfo, String> {
    let a = addr.to_string();
    let rx = corelib::ecs::with_rt_mut(move |rt| {
        rt.with_device_mut(&a, |world, entity| world.get_mut::<InfoSystem>(entity).map(|mut s| s.request_device_info()))
            .flatten()
    })
    .await
    .ok_or("the band is no longer registered")?;
    match tokio::time::timeout(INFO_TIMEOUT, rx).await {
        Ok(Ok(Ok(info))) => Ok(info),
        Ok(Ok(Err(err))) => Err(format!("device info request failed: {err:#}")),
        Ok(Err(_)) => Err("device info request was dropped".into()),
        Err(_) => Err("device info request timed out".into()),
    }
}

async fn request_battery(addr: &str) -> Result<Battery, String> {
    let a = addr.to_string();
    let rx = corelib::ecs::with_rt_mut(move |rt| {
        rt.with_device_mut(&a, |world, entity| world.get_mut::<InfoSystem>(entity).map(|mut s| s.request_device_status()))
            .flatten()
    })
    .await
    .ok_or("the band is no longer registered")?;
    let status = match tokio::time::timeout(INFO_TIMEOUT, rx).await {
        Ok(Ok(Ok(status))) => status,
        Ok(Ok(Err(err))) => return Err(format!("device status request failed: {err:#}")),
        Ok(Err(_)) => return Err("device status request was dropped".into()),
        Err(_) => return Err("device status request timed out".into()),
    };
    use protocol::device_status::battery::ChargeStatus;
    let charge_status = match status.battery.charge_status.and_then(|c| ChargeStatus::try_from(c).ok()) {
        Some(ChargeStatus::Charging) => "charging",
        Some(ChargeStatus::NotCharging) => "notCharging",
        Some(ChargeStatus::Full) => "full",
        _ => "unknown",
    };
    Ok(Battery { level: status.battery.capacity, charge_status })
}

async fn fetch_device(addr: &str, name: &str) -> DeviceSummary {
    let mut info = request_info(addr).await;
    if info.is_err() {
        info = request_info(addr).await;
    }
    let info = info.unwrap_or_else(|err| {
        log::warn!(target: "mirage", "{err}");
        protocol::DeviceInfo::default()
    });
    let battery = request_battery(addr).await.map_err(|err| log::warn!(target: "mirage", "{err}")).ok();
    DeviceSummary {
        name: name.to_string(),
        addr: addr.to_string(),
        serial_number: info.serial_number,
        firmware_version: info.firmware_version,
        model: info.model,
        product_device: info.product_device,
        battery,
    }
}

pub async fn device_info() -> Result<Value, String> {
    let addr = connected_addr()?;
    let name = link().device.as_ref().map(|d| d.name.clone()).unwrap_or_default();
    let info = request_info(&addr).await?;
    let battery = request_battery(&addr).await.map_err(|err| log::warn!(target: "mirage", "{err}")).ok();
    let device = DeviceSummary {
        name,
        addr: addr.clone(),
        serial_number: info.serial_number,
        firmware_version: info.firmware_version,
        model: info.model,
        product_device: info.product_device,
        battery,
    };
    {
        let mut l = link();
        if l.state == ConnState::Connected && l.addr.as_deref() == Some(&addr) {
            l.device = Some(device.clone());
        }
    }
    serde_json::to_value(device).map_err(|e| e.to_string())
}

// ---------------------------------------------------------- status / stop

pub fn status() -> Value {
    let (state, device) = {
        let l = link();
        (l.state, l.device.clone())
    };
    json!({ "state": state, "device": device, "bridge": bridge().status() })
}

pub async fn disconnect() -> Result<Value, String> {
    let _op = OP.lock().await;
    teardown(None).await;
    Ok(Value::Null)
}

/// Drop the companion core device and the bridge; ends in `disconnected`.
/// Callers hold `OP`.
async fn teardown(reason: Option<String>) {
    let addr = {
        let mut l = link();
        l.generation += 1; // late callbacks from the old link become stale
        l.session = None;
        l.addr.take()
    };
    let _ = blocking(|| bridge().detach()).await;
    if let Some(addr) = addr {
        let a = addr.clone();
        let removed = corelib::ecs::with_rt_mut(move |rt| rt.remove_device(&a).is_some()).await;
        corelib::device::cleanup_device_state(DeviceKind::Xiaomi, &addr);
        if removed {
            log::info!(target: "mirage", "released {addr}");
        }
    }
    if let Some(reason) = reason {
        log::warn!(target: "mirage", "disconnected: {reason}");
    }
    set_state(ConnState::Disconnected, None);
}

/// The bridge reports the SPP channel or the emulator bridge went away.
fn link_lost(generation: u64, reason: String) {
    let Some(rt) = host::runtime() else { return };
    rt.spawn(async move {
        let (session, state) = {
            let l = link();
            match l.session.clone() {
                Some(s) if s.generation == generation && l.generation == generation => (s, l.state),
                _ => return,
            }
        };
        *session.lost_reason.lock().unwrap_or_else(|e| e.into_inner()) = Some(reason.clone());
        session.lost.notify_one();
        if state == ConnState::Connected {
            let _op = OP.lock().await;
            if link().generation == generation {
                teardown(Some(reason)).await;
            }
        }
    });
}

/// Catches a link that dies without the bridge telling the data callback
/// (e.g. the emulator's socket closing before SPP was ever reported open).
async fn watchdog(session: Arc<Session>) {
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if link().generation != session.generation {
            return;
        }
        let status = bridge().status();
        if !status.attached {
            link_lost(session.generation, "the emulator bridge closed".into());
            return;
        }
        if !status.session.spp_open {
            link_lost(session.generation, "the band closed the SPP channel".into());
            return;
        }
    }
}

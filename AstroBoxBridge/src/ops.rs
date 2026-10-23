//! Resource management on the connected band: installs, watchfaces, quick apps.

use std::io::{Cursor, Read};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use corelib::device::xiaomi::{
    components::{install::InstallSystem, mass::SendMassCallbackData, resource::ResourceSystem},
    packet::mass::MassDataType,
    resutils,
};
use pb::xiaomi::protocol;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::oneshot;

use crate::{host, link::connected_addr};

const LIST_TIMEOUT: Duration = Duration::from_secs(30);

/// Run `f` against one of the band's companion core systems on the ECS thread.
async fn with_system<S, R>(addr: &str, f: impl FnOnce(&mut S) -> R + Send + 'static) -> Result<R, String>
where
    S: corelib::ecs::Component,
    R: Send + 'static,
{
    let a = addr.to_string();
    corelib::ecs::with_rt_mut(move |rt| {
        rt.with_device_mut(&a, |world, entity| world.get_mut::<S>(entity).map(|mut s| f(&mut s))).flatten()
    })
    .await
    .ok_or_else(|| "the band is no longer connected".to_string())
}

async fn await_reply<T>(rx: oneshot::Receiver<anyhow::Result<T>>, what: &str) -> Result<T, String> {
    match tokio::time::timeout(LIST_TIMEOUT, rx).await {
        Ok(Ok(Ok(v))) => Ok(v),
        Ok(Ok(Err(err))) => Err(format!("{what} failed: {err:#}")),
        Ok(Err(_)) => Err(format!("{what}: the band disconnected")),
        Err(_) => Err(format!("{what} timed out after {}s", LIST_TIMEOUT.as_secs())),
    }
}

// ------------------------------------------------------------------ install

#[derive(Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum InstallKind {
    Watchface,
    Quickapp,
    Canopus,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallParams {
    path: PathBuf,
    kind: InstallKind,
    #[serde(default)]
    package_name: Option<String>,
    /// Watchfaces only: install under this id instead of the one in the file
    /// (the companion core rewrites the id inside the package).
    #[serde(default)]
    watchface_id: Option<String>,
}

#[derive(Default)]
struct QuickAppManifest {
    package: String,
    name: String,
    version_name: String,
    version_code: i64,
}

fn read_rpk_manifest(data: &[u8]) -> Result<QuickAppManifest, String> {
    let mut zip = zip::ZipArchive::new(Cursor::new(data)).map_err(|e| format!("not a quick app package (.rpk zip): {e}"))?;
    let mut text = String::new();
    zip.by_name("manifest.json")
        .map_err(|e| format!("the .rpk has no manifest.json: {e}"))?
        .read_to_string(&mut text)
        .map_err(|e| format!("cannot read manifest.json: {e}"))?;
    let v: Value = serde_json::from_str(&text).map_err(|e| format!("manifest.json is not valid JSON: {e}"))?;
    Ok(QuickAppManifest {
        package: v["package"].as_str().unwrap_or_default().trim().to_string(),
        name: v["name"].as_str().unwrap_or_default().to_string(),
        version_name: v["versionName"].as_str().unwrap_or_default().to_string(),
        version_code: v["versionCode"].as_i64().unwrap_or_default(),
    })
}

/// A .mwz archive installs as the watchface .bin inside it (root entry first),
/// as the companion core does.
fn extract_watchface_bin(data: &[u8]) -> Option<Vec<u8>> {
    let mut zip = zip::ZipArchive::new(Cursor::new(data)).ok()?;
    let mut root = None;
    let mut any = None;
    for i in 0..zip.len() {
        let entry = zip.by_index(i).ok()?;
        if entry.is_dir() || !entry.name().to_ascii_lowercase().ends_with(".bin") {
            continue;
        }
        if !entry.name().contains('/') {
            root.get_or_insert(i);
        }
        any.get_or_insert(i);
    }
    let mut entry = zip.by_index(root.or(any)?).ok()?;
    let mut buf = Vec::with_capacity(entry.size() as usize);
    entry.read_to_end(&mut buf).ok()?;
    Some(buf)
}

/// The companion core refuses ids with this prefix ("表盘已损坏").
const DAMAGED_WATCHFACE_ID_PREFIX: &str = "1209";

pub async fn install(id: u64, p: InstallParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    let file = tokio::fs::read(&p.path).await.map_err(|e| format!("cannot read {}: {e}", p.path.display()))?;
    if file.is_empty() {
        return Err(format!("{} is empty", p.path.display()));
    }

    if p.kind == InstallKind::Canopus {
        let outcome = corelib::device::canopus::install_native_package(&addr, &file,
            Arc::new(move |progress| host::emit_progress(id, progress, "Sending Canopus module"))).await?;
        return serde_json::to_value(outcome).map_err(|e| e.to_string());
    }
    let (data_type, payload, package_name, mut result) = match p.kind {
        InstallKind::Canopus => unreachable!(),
        InstallKind::Quickapp => {
            let manifest = read_rpk_manifest(&file);
            let package = match p.package_name.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                Some(pkg) => pkg.to_string(),
                None => {
                    let m = manifest.as_ref().map_err(Clone::clone)?;
                    if m.package.is_empty() {
                        return Err("manifest.json has no `package`; pass packageName".into());
                    }
                    m.package.clone()
                }
            };
            let m = manifest.unwrap_or_default();
            let mut info = json!({ "ok": true, "kind": "quickapp", "packageName": package });
            if !m.name.is_empty() {
                info["name"] = json!(m.name);
            }
            if !m.version_name.is_empty() {
                info["versionName"] = json!(m.version_name);
            }
            if m.version_code != 0 {
                info["versionCode"] = json!(m.version_code);
            }
            (MassDataType::ThirdPartyApp, file, package, info)
        }
        InstallKind::Watchface => {
            let bin = if resutils::is_zip(&file) {
                extract_watchface_bin(&file).ok_or("the watchface archive contains no .bin")?
            } else {
                file
            };
            let file_id = corelib::device::watchface::resolve_xiaomi_watchface_id(addr.clone(), bin.clone())
                .await
                .map_err(|e| format!("{e:#}"))?;
            if let Some(fid) = file_id.as_deref().map(str::trim) {
                if fid.starts_with(DAMAGED_WATCHFACE_ID_PREFIX) {
                    return Err(format!("the watchface is damaged (id {fid})"));
                }
            }
            let explicit = p.watchface_id.as_deref().map(str::trim).filter(|s| !s.is_empty());
            let face_id = explicit.map(str::to_owned).or(file_id).ok_or(
                "cannot find a watchface id in the file (not a Xiaomi watchface .bin/.mwz?)",
            )?;
            let package = p.package_name.clone().unwrap_or_else(|| "a.b.c".into());
            let info = json!({ "ok": true, "kind": "watchface", "watchfaceId": face_id });
            (MassDataType::Watchface, bin, package, info)
        }
    };
    let watchface_override = match p.kind {
        InstallKind::Watchface => p.watchface_id.clone().filter(|s| !s.trim().is_empty()),
        InstallKind::Quickapp | InstallKind::Canopus => None,
    };
    let size = payload.len();
    result["bytes"] = json!(size);

    host::emit_progress(id, 0.0, "Waiting for the band to accept the package");
    let started = Instant::now();
    let throttle = Arc::new(Mutex::new((Instant::now(), -1.0f32)));
    let progress = Arc::new(move |pg: SendMassCallbackData| {
        let mut last = throttle.lock().unwrap_or_else(|e| e.into_inner());
        let done = pg.progress >= 1.0;
        if done || pg.progress - last.1 >= 0.01 || last.0.elapsed() >= Duration::from_millis(250) {
            *last = (Instant::now(), pg.progress);
            let msg = format!("Sending {:.0}% (part {}/{})", pg.progress * 100.0, pg.current_part_num, pg.total_parts);
            host::emit_progress(id, pg.progress, &msg);
        }
    });

    let pkg = package_name.clone();
    let fut = with_system::<InstallSystem, _>(&addr, move |sys| {
        sys.send_install_request_with_progress(data_type, payload, Some(&pkg), progress, watchface_override.as_deref())
    })
    .await?
    .map_err(|e| format!("install request failed: {e:#}"))?;
    log::info!(target: "mirage", "installing {} ({size} bytes)", result["packageName"].as_str().or(result["watchfaceId"].as_str()).unwrap_or("?"));
    fut.await.map_err(|e| format!("install failed: {e:#}"))?;

    let secs = started.elapsed().as_secs_f64();
    host::emit_progress(id, 1.0, "Installed");
    result["elapsedSecs"] = json!((secs * 10.0).round() / 10.0);
    log::info!(target: "mirage", "install finished in {secs:.1}s");
    Ok(result)
}

// --------------------------------------------------------------- watchfaces

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WatchfaceOut {
    id: String,
    name: String,
    current: bool,
    can_remove: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    can_edit: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    version_code: Option<u64>,
}

async fn fetch_watchfaces(addr: &str) -> Result<Vec<protocol::WatchFaceItem>, String> {
    let rx = with_system::<ResourceSystem, _>(addr, |s| s.request_watchface_list()).await?;
    await_reply(rx, "watchface list request").await
}

pub async fn watchfaces() -> Result<Value, String> {
    let addr = connected_addr()?;
    let list: Vec<WatchfaceOut> = fetch_watchfaces(&addr)
        .await?
        .into_iter()
        .map(|w| WatchfaceOut {
            id: w.id,
            name: w.name,
            current: w.is_current,
            // absent means removable, as in the companion core's UI
            can_remove: w.can_remove.unwrap_or(true),
            can_edit: w.can_edit,
            version_code: w.version_code,
        })
        .collect();
    serde_json::to_value(list).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
pub struct WatchfaceIdParams {
    id: String,
}

pub async fn set_watchface(p: WatchfaceIdParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    corelib::device::watchface::set_current(addr, p.id).await.map_err(|e| format!("{e:#}"))?;
    Ok(Value::Null)
}

pub async fn remove_watchface(p: WatchfaceIdParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    let faces = fetch_watchfaces(&addr).await?;
    match faces.iter().find(|w| w.id == p.id) {
        None => return Err(format!("no watchface with id {} on the band", p.id)),
        Some(w) if w.is_current => return Err("cannot remove the current watchface; switch to another one first".into()),
        Some(w) if w.can_remove == Some(false) => return Err(format!("the band does not allow removing {}", w.name)),
        Some(_) => {}
    }
    corelib::device::watchface::uninstall(addr, p.id).await.map_err(|e| format!("{e:#}"))?;
    Ok(Value::Null)
}

// --------------------------------------------------------------- quick apps

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct QuickAppOut {
    package_name: String,
    name: String,
    version: u32,
    can_remove: bool,
    fingerprint: String,
}

async fn fetch_quick_apps(addr: &str) -> Result<Vec<protocol::AppItem>, String> {
    let rx = with_system::<ResourceSystem, _>(addr, |s| s.request_quick_app_list()).await?;
    await_reply(rx, "quick app list request").await
}

pub async fn quick_apps() -> Result<Value, String> {
    let addr = connected_addr()?;
    let list: Vec<QuickAppOut> = fetch_quick_apps(&addr)
        .await?
        .into_iter()
        .map(|a| QuickAppOut {
            package_name: a.package_name,
            name: a.app_name,
            version: a.version_code,
            can_remove: a.can_remove,
            fingerprint: a.fingerprint.iter().map(|b| format!("{b:02x}")).collect(),
        })
        .collect();
    serde_json::to_value(list).map_err(|e| e.to_string())
}

/// Live Supervisor inventory over CPC2, independent of quick apps.
pub async fn canopus_modules() -> Result<Value, String> {
    let addr = connected_addr()?;
    let modules = corelib::device::canopus::list_device_modules(&addr).await?;
    serde_json::to_value(modules).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuickAppParams {
    package_name: String,
    /// launchQuickApp only: page/URI to open (default: the app's entry page)
    #[serde(default)]
    page: String,
}

/// corelib addresses quick apps by the fingerprint from the last list, so
/// refresh it and make sure the app is there.
async fn ensure_listed(addr: &str, package: &str) -> Result<protocol::AppItem, String> {
    fetch_quick_apps(addr)
        .await?
        .into_iter()
        .find(|a| a.package_name == package)
        .ok_or_else(|| format!("{package} is not installed on the band"))
}

pub async fn launch_quick_app(p: QuickAppParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    ensure_listed(&addr, &p.package_name).await?;
    corelib::device::thirdparty_app::launch(addr, p.package_name, p.page).await.map_err(|e| format!("{e:#}"))?;
    Ok(Value::Null)
}

pub async fn remove_quick_app(p: QuickAppParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    let app = ensure_listed(&addr, &p.package_name).await?;
    if !app.can_remove {
        return Err(format!("the band does not allow removing {}", p.package_name));
    }
    corelib::device::thirdparty_app::uninstall(addr.clone(), p.package_name.clone())
        .await
        .map_err(|e| format!("{e:#}"))?;
    // The uninstall command has no acknowledgement; confirm via the list.
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        tokio::time::sleep(Duration::from_millis(1000)).await;
        let apps = fetch_quick_apps(&addr).await?;
        if !apps.iter().any(|a| a.package_name == p.package_name) {
            return Ok(Value::Null);
        }
        if Instant::now() >= end {
            return Err(format!("the band still lists {} after the uninstall request", p.package_name));
        }
    }
}

// ------------------------------------------------------------ notifications

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationParams {
    /// Namespace the band groups the notification under (one "app" per source).
    #[serde(default = "default_notification_source")]
    source: String,
    /// Reusing an id replaces that notification.
    #[serde(default)]
    id: u32,
    #[serde(default = "default_notification_app")]
    app_name: String,
    title: String,
    #[serde(default)]
    sub_title: String,
    #[serde(default)]
    text: String,
}

fn default_notification_source() -> String {
    "mirage".into()
}

fn default_notification_app() -> String {
    "Mirage".into()
}

pub async fn send_notification(p: NotificationParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    let timestamp_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or_default();
    let content = corelib::device::notification::NotificationContent {
        id: p.id,
        app_name: p.app_name,
        title: p.title,
        sub_title: p.sub_title,
        text: p.text,
        timestamp_ms,
        live_activity: None,
    };
    corelib::device::notification::send(addr, p.source, content).await.map_err(|e| format!("{e:#}"))?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectParams {
    /// Module id (ADR-CAN-003).
    module: String,
    /// connectListen: start (default) or stop the module's pushes.
    #[serde(default = "yes")]
    enable: bool,
    /// connectSend: 1 text, 2 binary (default).
    #[serde(default = "binary")]
    kind: u8,
    /// connectSend: the message as hex (binary) or `text`.
    #[serde(default)]
    data_hex: String,
    #[serde(default)]
    text: String,
}

fn yes() -> bool {
    true
}

fn binary() -> u8 {
    corelib::device::canopus::CONNECT_BINARY
}

fn from_hex(text: &str) -> Result<Vec<u8>, String> {
    if text.len() % 2 != 0 {
        return Err("dataHex has an odd length".into());
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).map_err(|_| "dataHex is not hex".to_string()))
        .collect()
}

/// CanopusConnect: registers (or removes) the phone as the listener of a module and
/// starts printing the module's messages as `{"type":"connect",...}` events.
pub async fn connect_listen(p: ConnectParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    if p.enable {
        subscribe_connect_events(&addr)?;
    }
    corelib::device::canopus::connect_listen(&addr, &p.module, p.enable).await?;
    Ok(Value::Null)
}

/// CanopusConnect: one message to the module's listener.
pub async fn connect_send(p: ConnectParams) -> Result<Value, String> {
    let addr = connected_addr()?;
    let data = if p.kind == corelib::device::canopus::CONNECT_TEXT {
        p.text.into_bytes()
    } else {
        from_hex(&p.data_hex)?
    };
    corelib::device::canopus::connect_send(&addr, &p.module, p.kind, &data).await?;
    Ok(Value::Null)
}

static CONNECT_PUMP: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// Forwards the device's CanopusConnect messages to the callback (once per device).
fn subscribe_connect_events(addr: &str) -> Result<(), String> {
    let mut subscribed = CONNECT_PUMP.lock().unwrap();
    if subscribed.as_deref() == Some(addr) {
        return Ok(());
    }
    let mut rx = corelib::device::canopus::connect_subscribe(addr)?;
    *subscribed = Some(addr.to_string());
    let Some(rt) = host::runtime() else { return Ok(()) };
    rt.spawn(async move {
        while let Some(message) = rx.recv().await {
            let data_hex: String = message.data.iter().map(|b| format!("{b:02x}")).collect();
            host::emit(serde_json::json!({
                "type": "connect",
                "module": message.module_id,
                "kind": message.kind,
                "dataHex": data_hex,
            }));
        }
    });
    Ok(())
}

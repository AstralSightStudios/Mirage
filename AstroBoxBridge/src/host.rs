//! The host side of the bridge: the C callback, the thread that calls it,
//! the tokio runtime, and `log` forwarding.

use std::ffi::{CString, c_char, c_void};
use std::sync::mpsc::{self, Sender};
use std::sync::{Mutex, Once, OnceLock};

use serde_json::{Value, json};

/// `typedef void (*mab_callback)(const char *json, void *ctx);`
pub type MabCallback = unsafe extern "C" fn(json: *const c_char, ctx: *mut c_void);

#[derive(Clone, Copy)]
struct Target {
    cb: Option<MabCallback>,
    /// The host's opaque context pointer, carried as an integer so it can
    /// cross threads; the bridge never dereferences it.
    ctx: usize,
}

static TARGET: Mutex<Target> = Mutex::new(Target { cb: None, ctx: 0 });
static QUEUE: OnceLock<Mutex<Sender<String>>> = OnceLock::new();
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static START: Once = Once::new();

/// Set (or replace) the callback and bring everything up once.
pub fn init(cb: Option<MabCallback>, ctx: *mut c_void) {
    *TARGET.lock().unwrap_or_else(|e| e.into_inner()) = Target { cb, ctx: ctx as usize };
    START.call_once(|| {
        let (tx, rx) = mpsc::channel::<String>();
        let _ = QUEUE.set(Mutex::new(tx));
        // One thread delivers every message, in order. Producers never call
        // into the host themselves, so a host that calls mab_call from inside
        // its callback cannot deadlock or re-enter the bridge.
        let _ = std::thread::Builder::new().name("mirage-ab-callback".into()).spawn(move || {
            for msg in rx {
                let target = *TARGET.lock().unwrap_or_else(|e| e.into_inner());
                let Some(cb) = target.cb else { continue };
                // serde_json escapes NUL, so this cannot fail for our messages
                let Ok(text) = CString::new(msg) else { continue };
                unsafe { cb(text.as_ptr(), target.ctx as *mut c_void) };
            }
        });

        install_logger();

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("mirage-ab-rt")
            .build()
            .expect("failed to start the tokio runtime");

        // the companion core's ECS world lives on its own thread; start it once.
        corelib::ecs::init_runtime_default();
        spawn_core_event_pump(rt.handle());
        log::info!(target: "mirage", "mirage companion core {} ready", env!("CARGO_PKG_VERSION"));

        let _ = RUNTIME.set(rt);
    });
}

fn spawn_core_event_pump(handle: &tokio::runtime::Handle) {
    let mut rx = corelib::events::subscribe();
    handle.spawn(async move {
        loop {
            match rx.recv().await {
                Ok(event) => match event {
                    corelib::events::CoreEvent::CanopusConnectMessage(msg) => {
                        let (kind, text, data_hex) = match msg.payload {
                            corelib::device::canopus::connect::ConnectPayload::Text(ref text) => {
                                (
                                    1u8,
                                    text.clone(),
                                    text.as_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>(),
                                )
                            }
                            corelib::device::canopus::connect::ConnectPayload::Binary(ref bin) => {
                                (
                                    2u8,
                                    String::new(),
                                    bin.iter().map(|b| format!("{b:02x}")).collect::<String>(),
                                )
                            }
                        };
                        emit(json!({
                            "type": "connect",
                            "device": msg.device_addr,
                            "module": msg.module,
                            "kind": kind,
                            "text": text,
                            "dataHex": data_hex,
                        }));
                    }
                    corelib::events::CoreEvent::SharedLinkDetected(detected) => {
                        emit(json!({
                            "type": "sharedLinkDetected",
                            "device": detected.device_addr,
                        }));
                    }
                    corelib::events::CoreEvent::DeviceStateChanged(state) => {
                        emit(json!({
                            "type": "deviceStateChanged",
                            "device": state.device_addr,
                        }));
                    }
                    corelib::events::CoreEvent::InterconnectMessage(msg) => {
                        emit(json!({
                            "type": "interconnect",
                            "device": msg.device_addr,
                            "packageName": msg.pkg_name,
                            "payloadHex": msg.payload.iter().map(|b| format!("{b:02x}")).collect::<String>(),
                        }));
                    }
                },
                Err(tokio::sync::broadcast::error::RecvError::Lagged(missed)) => {
                    log::warn!(target: "mirage", "core event pump lagged, missed {missed} events");
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    break;
                }
            }
        }
    });
}

pub fn runtime() -> Option<&'static tokio::runtime::Runtime> {
    RUNTIME.get()
}

/// Queue one message for the host. Dropped before `mab_init`.
pub fn emit(msg: Value) {
    let Some(queue) = QUEUE.get() else { return };
    let text = msg.to_string();
    let _ = queue.lock().unwrap_or_else(|e| e.into_inner()).send(text);
}

pub fn emit_result(id: u64, result: Result<Value, String>) {
    emit(match result {
        Ok(result) => json!({ "type": "result", "id": id, "ok": true, "result": result }),
        Err(error) => json!({ "type": "result", "id": id, "ok": false, "error": error }),
    });
}

pub fn emit_progress(id: u64, progress: f32, message: &str) {
    let progress = if progress.is_finite() { progress.clamp(0.0, 1.0) } else { 0.0 };
    // f32 → JSON would print 0.23999999463558197
    let progress = (f64::from(progress) * 10_000.0).round() / 10_000.0;
    emit(json!({ "type": "progress", "id": id, "progress": progress, "message": message }));
}

// ---------------------------------------------------------------- logging

struct Forward;

/// The last warning the emulator bridge logged. `EmuBridge::connect` only
/// returns a coarse error enum and logs the real reason (e.g. "pairing was
/// declined on the band"), so we keep it to report it.
static LAST_BRIDGE_WARNING: Mutex<Option<String>> = Mutex::new(None);

pub fn take_bridge_warning() -> Option<String> {
    LAST_BRIDGE_WARNING.lock().unwrap_or_else(|e| e.into_inner()).take()
}

impl log::Log for Forward {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let message = record.args().to_string();
        if record.target() == "emubt" && record.level() == log::Level::Warn {
            *LAST_BRIDGE_WARNING.lock().unwrap_or_else(|e| e.into_inner()) = Some(message.clone());
        }
        let level = match record.level() {
            log::Level::Error => "error",
            log::Level::Warn => "warn",
            log::Level::Info => "info",
            log::Level::Debug | log::Level::Trace => "debug",
        };
        emit(json!({ "type": "log", "level": level, "target": record.target(), "message": message }));
    }

    fn flush(&self) {}
}

fn install_logger() {
    static LOGGER: Forward = Forward;
    // Another logger may already own the process; then we simply don't forward.
    if log::set_logger(&LOGGER).is_ok() {
        let debug = std::env::var_os("MIRAGE_AB_DEBUG").is_some_and(|v| !v.is_empty() && v != "0");
        log::set_max_level(if debug { log::LevelFilter::Debug } else { log::LevelFilter::Info });
    }
}

/// Best-effort text of a panic payload.
pub fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

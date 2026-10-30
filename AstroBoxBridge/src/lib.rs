//! Mirage ⇄ companion core bridge.
//!
//! A tiny in-process JSON-RPC over a C ABI (see `include/mirage_astrobox.h`):
//! `mab_call` queues a request and returns its id; every request completes
//! with exactly one `{"type":"result",...}` message on the callback given to
//! `mab_init`, interleaved with `log`, `progress` and `state` messages.

mod host;
mod link;
mod ops;

use std::ffi::{CStr, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::de::DeserializeOwned;
use serde_json::Value;

pub use host::MabCallback;

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Start the bridge (idempotent). Later calls only replace the callback.
#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn mab_init(cb: Option<MabCallback>, ctx: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| host::init(cb, ctx)));
}

/// Queue `method` with `params_json` (NULL or "" means `{}`); returns the
/// request id, or 0 when `mab_init` has not been called yet.
#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn mab_call(method: *const c_char, params_json: *const c_char) -> u64 {
    if host::runtime().is_none() {
        return 0;
    }
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let queued = catch_unwind(AssertUnwindSafe(|| {
        let method = unsafe { c_text(method) };
        let params = unsafe { c_text(params_json) };
        spawn_request(id, method, params);
    }));
    if let Err(panic) = queued {
        host::emit_result(id, Err(format!("internal error: {}", host::panic_message(&*panic))));
    }
    id
}

unsafe fn c_text(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

fn spawn_request(id: u64, method: Option<String>, params: Option<String>) {
    let Some(rt) = host::runtime() else { return };
    let work = rt.spawn(async move {
        let method = method.unwrap_or_default();
        let params: Value = match params.as_deref().map(str::trim) {
            None | Some("") => Value::Object(Default::default()),
            Some(text) => serde_json::from_str(text).map_err(|e| format!("invalid params JSON: {e}"))?,
        };
        handle(id, &method, params).await
    });
    // A panic inside the request becomes a JoinError here, never an unwind
    // across the FFI boundary.
    rt.spawn(async move {
        let result = match work.await {
            Ok(result) => result,
            Err(err) if err.is_panic() => {
                let msg = host::panic_message(&*err.into_panic());
                log::error!(target: "mirage", "request {id} panicked: {msg}");
                Err(format!("internal error: {msg}"))
            }
            Err(_) => Err("request was cancelled".to_string()),
        };
        host::emit_result(id, result);
    });
}

fn parse<T: DeserializeOwned>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))
}

async fn handle(id: u64, method: &str, params: Value) -> Result<Value, String> {
    match method {
        "connect" => link::connect(parse(params)?).await,
        "disconnect" => link::disconnect().await,
        "status" => Ok(link::status()),
        "deviceInfo" => link::device_info().await,
        "install" => ops::install(id, parse(params)?).await,
        "watchfaces" => ops::watchfaces().await,
        "setWatchface" => ops::set_watchface(parse(params)?).await,
        "removeWatchface" => ops::remove_watchface(parse(params)?).await,
        "quickApps" => ops::quick_apps().await,
        "canopusModules" => ops::canopus_modules().await,
        "canopusDeviceInfo" => ops::canopus_device_info().await,
        "canopusQueryModule" => ops::canopus_query_module(parse(params)?).await,
        "canopusSetEnabled" => ops::canopus_set_enabled(parse(params)?).await,
        "canopusActivate" => ops::canopus_activate(parse(params)?).await,
        "canopusRemove" => ops::canopus_remove(parse(params)?).await,
        "canopusScan" => ops::canopus_scan().await,
        "canopusExitSafeMode" => ops::canopus_exit_safe_mode(parse(params)?).await,
        "canopusGetBootPersistence" => ops::canopus_get_boot_persistence().await,
        "canopusSetBootPersistence" => ops::canopus_set_boot_persistence(parse(params)?).await,
        "connectListen" => ops::connect_listen(parse(params)?).await,
        "connectSend" => ops::connect_send(parse(params)?).await,
        "launchQuickApp" => ops::launch_quick_app(parse(params)?).await,
        "removeQuickApp" => ops::remove_quick_app(parse(params)?).await,
        "sendNotification" => ops::send_notification(parse(params)?).await,
        "callRpc" => ops::call_rpc(id, parse(params)?).await,
        "rpcMethods" => Ok(serde_json::to_value(corelib::rpc::methods()).unwrap()),
        "" => Err("missing method name".to_string()),
        other => {
            if corelib::rpc::methods().contains(&other) {
                ops::call_named_rpc(id, other, params).await
            } else {
                Err(format!("unknown method `{other}`"))
            }
        }
    }
}

/*
 * mirage_astrobox.h — Mirage ⇄ companion core bridge (libmirage_astrobox.a)
 *
 * An in-process JSON-RPC. Requests go in through mab_call(); results and
 * events come back as JSON text through the single callback given to
 * mab_init(). The callback runs on one dedicated background thread, one
 * message at a time and in order; `json` is only valid during the call.
 * Calling mab_call() from inside the callback is fine.
 *
 * Messages (all objects carry "type"):
 *   {"type":"result","id":N,"ok":true,"result":<any>}
 *   {"type":"result","id":N,"ok":false,"error":"<message>"}
 *       exactly one per request id
 *   {"type":"log","level":"info|warn|error|debug","target":"...","message":"..."}
 *       companion core logs; debug level when env MIRAGE_AB_DEBUG is set
 *   {"type":"progress","id":N,"progress":0.0..1.0,"message":"..."}
 *       install / RPC progress for request N
 *   {"type":"state","state":"disconnected|attaching|connecting|connected","device":{...}|null}
 *       on every connection state change, including the band dropping the link
 *   {"type":"connect","device":"...","module":"...","kind":1|2,"text":"...","dataHex":"..."}
 *       CanopusConnect (ADR-CAN-009) pushed message from a module on the band
 *   {"type":"sharedLinkDetected","device":"..."}
 *       another phone app (e.g. Mi Fitness) took over the BLE link session
 *   {"type":"deviceStateChanged","device":"..."}
 *       companion core device state change notification
 *
 * Methods (params → result; camelCase JSON):
 *   connect      {host?="127.0.0.1", port, authKey, stateDir, timeoutSecs?=120, appDeviceId?, bandAddr?}
 *                → Device. stateDir is a per-band directory owned by the caller; the
 *                bridge keeps "link-keys" and "credentials.json" there. The band asks
 *                the user to confirm pairing the first time a stateDir connects.
 *   disconnect   {} → null
 *   status       {} → {state, device|null, bridge:{attached, endpoint, localAddr, devices,
 *                     link, encrypted, rfcommChannel, sppOpen, txBytes, rxBytes}}
 *   deviceInfo   {} → Device (refreshed)
 *   install      {path, kind:"watchface"|"quickapp"|"canopus", packageName?, watchfaceId?}
 *                → {ok:true, kind, bytes, elapsedSecs, packageName, name?, versionName?, versionCode?} (quickapp)
 *                → {ok:true, kind, bytes, elapsedSecs, watchfaceId} (watchface)
 *                → {moduleId, targetId, rebootRequired} (canopus native package)
 *   watchfaces   {} → [{id, name, current, canRemove, canEdit?, versionCode?}]
 *   setWatchface {id} → null
 *   removeWatchface {id} → null
 *   quickApps    {} → [{packageName, name, version, canRemove, fingerprint}]
 *   launchQuickApp {packageName, page?=""} → null
 *   removeQuickApp {packageName} → null
 *   sendNotification {title, text?="", subTitle?="", appName?="Mirage", source?="mirage", id?=0}
 *                → null once queued
 *
 * Canopus Native (ADR-CAN-008, ADR-CAN-009):
 *   canopusModules            {} → [{slot, moduleId, version, state, lifecycleClass, flags, activationError}]
 *   canopusDeviceInfo         {} → {frameworkRevision, safeMode, moduleCount, safeModeReason, errorCode, flags, scanSummary, targetId?}
 *   canopusQueryModule        {slot?|module?} → ModuleItem|null
 *   canopusSetEnabled         {module, enabled:bool} → null
 *   canopusActivate           {module} → null only after native activation completes
 *   canopusRemove             {module} → null
 *   canopusScan               {} → null
 *   canopusExitSafeMode       {action:"keep"|"disableAll"|"rollbackAll"} → null
 *   canopusGetBootPersistence {} → {supported, pinned}
 *   canopusSetBootPersistence {pinned:bool} → null
 *   connectListen             {module, enable?=true} → null
 *   connectSend               {module, kind?=2, dataHex?="", text?=""} → null
 *
 * Core RPC Capability Layer:
 *   callRpc      {method, params?} → <result>
 *   rpcMethods   {} → ["device.kind", "sync.time", ...]
 *   <rpcMethod>  {...params} → <result> (direct invocation of any registered core RPC method)
 *
 * Device = {name, addr, serialNumber, firmwareVersion, model, productDevice,
 *           battery?: {level, chargeStatus:"unknown|charging|notCharging|full"}}
 *
 * Link with: libmirage_astrobox.a plus
 *   -framework CoreAudio -framework Security -framework IOKit -framework IOBluetooth
 *   -framework CoreBluetooth -framework WebKit -framework ApplicationServices
 *   -framework CoreGraphics -framework Carbon -framework CoreVideo
 *   -framework CoreFoundation -framework AppKit -framework Foundation
 *   -liconv -lobjc -lc -lm
 */
#ifndef MIRAGE_ASTROBOX_H
#define MIRAGE_ASTROBOX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mab_callback)(const char *json, void *ctx);

/* Start the bridge: tokio runtime, companion core, log forwarding.
 * Idempotent; a later call only replaces the callback/context. */
void mab_init(mab_callback cb, void *ctx);

/* Queue a request. params_json may be NULL or "" for {}. Returns the request
 * id (> 0) immediately, or 0 if mab_init() has not been called. */
uint64_t mab_call(const char *method, const char *params_json);

#ifdef __cplusplus
}
#endif

#endif /* MIRAGE_ASTROBOX_H */

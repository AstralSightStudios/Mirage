/*
 * Smoke test for libmirage_astrobox.a through its C API.
 *
 *   smoke <port> <authKey> <stateDir> [method[=paramsJSON] ...]
 *
 * Runs init → connect → (the given methods, default: deviceInfo watchfaces
 * quickApps) → disconnect, printing every callback message. A `sleep=N`
 * step idles N seconds while events keep printing. Exit status is
 * non-zero if connect fails. Build with examples/build-smoke.sh.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "mirage_astrobox.h"

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static uint64_t done_id;   /* last completed request id */
static int done_ok;
static struct timespec t0;

static double elapsed(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (t.tv_sec - t0.tv_sec) + (t.tv_nsec - t0.tv_nsec) / 1e9;
}

static void on_message(const char *json, void *ctx) {
    (void)ctx;
    printf("%8.3f %s\n", elapsed(), json);
    fflush(stdout);
    if (!strstr(json, "\"type\":\"result\"")) return;
    const char *p = strstr(json, "\"id\":");
    if (!p) return;
    pthread_mutex_lock(&mu);
    done_id = strtoull(p + 5, NULL, 10);
    done_ok = strstr(json, "\"ok\":true") != NULL;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

/* Issue one request and wait for its result; returns 1 if ok. */
static int call(const char *method, const char *params) {
    printf("%8.3f >>> %s %s\n", elapsed(), method, params ? params : "{}");
    fflush(stdout);
    uint64_t id = mab_call(method, params);
    if (id == 0) { fprintf(stderr, "mab_call returned 0\n"); return 0; }
    pthread_mutex_lock(&mu);
    while (done_id != id) pthread_cond_wait(&cv, &mu);
    int ok = done_ok;
    pthread_mutex_unlock(&mu);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <port> <authKey> <stateDir> [method[=paramsJSON] ...]\n", argv[0]);
        return 2;
    }
    clock_gettime(CLOCK_MONOTONIC, &t0);
    mab_init(on_message, NULL);
    mab_init(on_message, NULL); /* idempotent */

    char params[4096];
    const char *band = getenv("MAB_BAND"); /* optional band address */
    snprintf(params, sizeof params,
             "{\"host\":\"127.0.0.1\",\"port\":%s,\"authKey\":\"%s\",\"stateDir\":\"%s\",\"timeoutSecs\":180%s%s%s}",
             argv[1], argv[2], argv[3], band ? ",\"bandAddr\":\"" : "", band ? band : "", band ? "\"" : "");
    call("status", NULL);
    if (!call("connect", params)) {
        call("status", NULL);
        return 1;
    }

    const char *defaults[] = {"deviceInfo", "watchfaces", "quickApps"};
    int n = argc > 4 ? argc - 4 : 3;
    for (int i = 0; i < n; i++) {
        const char *arg = argc > 4 ? argv[4 + i] : defaults[i];
        char method[128];
        const char *eq = strchr(arg, '=');
        size_t len = eq ? (size_t)(eq - arg) : strlen(arg);
        if (len >= sizeof method) len = sizeof method - 1;
        memcpy(method, arg, len);
        method[len] = 0;
        if (strcmp(method, "sleep") == 0) { /* sleep=N: idle N seconds, still printing events */
            printf("%8.3f --- sleeping %s s\n", elapsed(), eq ? eq + 1 : "5");
            fflush(stdout);
            sleep(eq ? (unsigned)atoi(eq + 1) : 5);
            continue;
        }
        call(method, eq ? eq + 1 : NULL);
    }

    call("status", NULL);
    call("disconnect", NULL);
    call("status", NULL);
    return 0;
}

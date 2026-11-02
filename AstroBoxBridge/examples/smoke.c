/*
 * Smoke test for libmirage_astrobox.a through its C API.
 *
 *   smoke <port> <authKey> <stateDir> [method[=paramsJSON] ...]
 *   smoke <port> <authKey> <stateDir> --stdin     (requests from stdin, one per line)
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
/* The results of the last DONE_KEEP requests, so several requests can be in flight at once and
 * a blocking call still finds its own result. */
#define DONE_KEEP 256
static uint64_t done_ids[DONE_KEEP];
static int done_oks[DONE_KEEP];
static unsigned done_count;
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
    done_ids[done_count % DONE_KEEP] = strtoull(p + 5, NULL, 10);
    done_oks[done_count % DONE_KEEP] = strstr(json, "\"ok\":true") != NULL;
    done_count++;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

/* The result of request `id` once it has come in, or -1 while it has not. */
static int result_of(uint64_t id) {
    unsigned n = done_count < DONE_KEEP ? done_count : DONE_KEEP;
    for (unsigned i = 0; i < n; i++) {
        unsigned at = (done_count - 1 - i) % DONE_KEEP;
        if (done_ids[at] == id) return done_oks[at];
    }
    return -1;
}

/* Issue one request and wait for its result; returns 1 if ok. */
static int call(const char *method, const char *params) {
    printf("%8.3f >>> %s %s\n", elapsed(), method, params ? params : "{}");
    fflush(stdout);
    uint64_t id = mab_call(method, params);
    if (id == 0) { fprintf(stderr, "mab_call returned 0\n"); return 0; }
    pthread_mutex_lock(&mu);
    int ok;
    while ((ok = result_of(id)) < 0) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    return ok;
}

/* Issue one request and do not wait: its result is printed when it comes in. */
static void call_async(const char *method, const char *params) {
    printf("%8.3f >>> %s %s\n", elapsed(), method, params ? params : "{}");
    fflush(stdout);
    if (mab_call(method, params) == 0) fprintf(stderr, "mab_call returned 0\n");
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

    if (argc > 4 && strcmp(argv[4], "--stdin") == 0) {
        printf("%8.3f {\"type\":\"ready\"}\n", elapsed());
        fflush(stdout);
        /* Interactive: one `[&]method[=paramsJSON]` per line on stdin, `quit` to leave. The
         * callback keeps printing device messages (e.g. {"type":"connect",...}) meanwhile. */
        char *line = NULL;
        size_t cap = 0;
        ssize_t n;
        while ((n = getline(&line, &cap, stdin)) != -1) {
            while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
            if (n == 0) continue;
            if (strcmp(line, "quit") == 0) break;
            /* A leading '&' starts the request without waiting for its result. */
            int async = line[0] == '&';
            char *method = line + async;
            char *eq = strchr(method, '=');
            if (eq) *eq = 0;
            if (async) call_async(method, eq ? eq + 1 : NULL);
            else call(method, eq ? eq + 1 : NULL);
        }
        free(line);
        call("disconnect", NULL);
        return 0;
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

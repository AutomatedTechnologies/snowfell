/*
 * bridge.c — T3 session bridge: the CLI's own channel to the hosted
 * Minion service, over system libcurl (ships with macOS 10.13; no
 * third-party code — R2/R5).
 *
 * What T1/T3 discovery established [design record DESIGN-T1 §2, §4.1
 * and DESIGN-T3]:
 *  - The service origin is https://muse.ai/ (app/electron/main.cjs:7,
 *    API_ENDPOINT). The desktop shell makes no service call of its
 *    own; authentication is entirely the hosted endpoint's cookie
 *    session (partition `persist:muse`, main.cjs:346/404/506),
 *    created by a hosted in-window sign-in flow with 2FA (Meta auth
 *    hosts, utils.cjs META_REDIRECT_HOSTS). The shell holds no
 *    tokens and there is no API-key mechanic to copy.
 *  - The whole /api namespace on the origin answers 401
 *    {"error":"Authentication required"} to any unauthenticated
 *    request (observed from this VM, 2026-11-13) — the wire calls
 *    themselves sit behind that session and are NOT enumerable from
 *    source or public assets. The exact send/read paths and stream
 *    format are therefore a T4 capture item (owner's signed-in
 *    session, on the Air), NOT asserted here.
 *
 * ------------------------------------------------------------------
 * WIRE SEAM — the block below is the single fill-in point for T4.
 * MINION_SEND_PATH and the JSON payload shape are PLACEHOLDERS chosen
 * to be replaced by the captured values; they are not discovered
 * endpoints. Until the seam is filled, this bridge is honest about
 * its state: `minion status` reports the seam as unconfirmed, and a
 * dispatch without a session cookie fails at the auth boundary
 * before any network traffic (see minion_bridge_dispatch).
 * ------------------------------------------------------------------
 *
 * R1 mechanics implemented here, for real:
 *  - No CURLOPT_TIMEOUT and no deadline of any kind on a transfer:
 *    a dispatch ends on transfer completion, on a transport error,
 *    or when the owner's interrupt flag aborts the transfer through
 *    the progress callback (CURLE_ABORTED_BY_CALLBACK -> the
 *    INTERRUPTED event). SIGINT is the only early exit.
 *  - Streaming: the write callback appends each chunk to the reply
 *    buffer and emits a DELTA snapshot event per chunk, so the reply
 *    reaches stdout incrementally as the service produces it.
 *  - Error surfaces are specific: no-cookie (auth boundary) ->
 *    MINION_BRIDGE_ERROR before any request; HTTP 401/403 ->
 *    session-rejected error; other HTTP -> status-coded error;
 *    transport failure -> the libcurl diagnostic.
 *
 * Auth handling: the session cookie is supplied by the owner at run
 * time in the MINION_COOKIE environment variable (a Cookie header
 * value from the owner's own signed-in browser/app session). It is
 * read once at open, held only in process memory, never written to
 * disk, never printed, never included in any error text. When the
 * owner does not supply it, the bridge does not guess: dispatch
 * stops at the boundary described above. (T4 rig script carries the
 * owner-side step.)
 */
#include "bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <curl/curl.h>

/* --- WIRE SEAM (T4 capture fills these; see header comment) ------- */
#define MINION_SERVICE_ORIGIN "https://muse.ai"
#define MINION_SEND_PATH      "/api/send"   /* PLACEHOLDER — unconfirmed */
#define MINION_WIRE_CONFIRMED 0
/* ------------------------------------------------------------------ */

#define MINION_COOKIE_ENV "MINION_COOKIE"

struct MinionBridge {
    char *identity;
    char *cookie;            /* owned; NULL when not supplied */
    CURL *curl;
    /* per-dispatch state */
    char *reply;             /* growing reply buffer (snapshot text) */
    size_t reply_len;
    size_t reply_cap;
    volatile int *interrupt_flag;
    MinionBridgeEventFn on_event;
    void *event_ctx;
    char error_text[256];
};

static void bridge_emit(MinionBridge *b, MinionBridgeEventType type,
                        const char *text) {
    MinionBridgeEvent ev;
    if (!b->on_event) return;
    ev.type = type;
    ev.text = text;
    b->on_event(b->event_ctx, &ev);
}

static int bridge_reply_append(MinionBridge *b, const char *data,
                               size_t n) {
    if (b->reply_len + n + 1 > b->reply_cap) {
        size_t ncap = b->reply_cap ? b->reply_cap : 1024;
        char *nb;
        while (b->reply_len + n + 1 > ncap) ncap *= 2;
        nb = (char *)realloc(b->reply, ncap);
        if (!nb) return -1;
        b->reply = nb;
        b->reply_cap = ncap;
    }
    memcpy(b->reply + b->reply_len, data, n);
    b->reply_len += n;
    b->reply[b->reply_len] = '\0';
    return 0;
}

/* libcurl write callback: append the chunk, emit a DELTA snapshot. */
static size_t bridge_write_cb(char *ptr, size_t size, size_t nmemb,
                              void *userdata) {
    MinionBridge *b = (MinionBridge *)userdata;
    size_t n = size * nmemb;
    if (bridge_reply_append(b, ptr, n) != 0) return 0;  /* abort */
    bridge_emit(b, MINION_BRIDGE_DELTA, b->reply);
    return n;
}

/* libcurl progress callback: the ONLY early-exit mechanism — the
 * owner's interrupt flag. Returning non-zero aborts the transfer
 * (CURLE_ABORTED_BY_CALLBACK). No time-based condition exists here. */
static int bridge_progress_cb(void *userdata, curl_off_t dltotal,
                              curl_off_t dlnow, curl_off_t ultotal,
                              curl_off_t ulnow) {
    MinionBridge *b = (MinionBridge *)userdata;
    (void)dltotal; (void)dlnow; (void)ultotal; (void)ulnow;
    if (b->interrupt_flag && *b->interrupt_flag) return 1;
    return 0;
}

/* Minimal JSON string escaping for the message payload. Returns a
 * malloc'd string (caller frees), or NULL on allocation failure. */
static char *bridge_json_escape(const char *s) {
    size_t cap = strlen(s) * 6 + 1, len = 0;
    char *out = (char *)malloc(cap);
    const unsigned char *p;
    if (!out) return NULL;
    for (p = (const unsigned char *)s; *p; p++) {
        unsigned char c = *p;
        const char *rep = NULL;
        char ubuf[8];
        switch (c) {
        case '"':  rep = "\\\""; break;
        case '\\': rep = "\\\\"; break;
        case '\n': rep = "\\n"; break;
        case '\r': rep = "\\r"; break;
        case '\t': rep = "\\t"; break;
        default:
            if (c < 0x20) {
                snprintf(ubuf, sizeof(ubuf), "\\u%04x", c);
                rep = ubuf;
            }
            break;
        }
        if (rep) {
            size_t rl = strlen(rep);
            memcpy(out + len, rep, rl);
            len += rl;
        } else {
            out[len++] = (char)c;
        }
    }
    out[len] = '\0';
    return out;
}

MinionBridge *minion_bridge_open(const char *identity,
                                 const char **error_out) {
    MinionBridge *b = (MinionBridge *)calloc(1, sizeof(MinionBridge));
    const char *cookie_env;
    if (!b) {
        if (error_out) *error_out = "out of memory";
        return NULL;
    }
    b->identity = minion_strdup(identity ? identity : "minion-cli");
    if (!b->identity) {
        free(b);
        if (error_out) *error_out = "out of memory";
        return NULL;
    }
    cookie_env = getenv(MINION_COOKIE_ENV);
    if (cookie_env && cookie_env[0]) {
        b->cookie = minion_strdup(cookie_env);
        if (!b->cookie) {
            free(b->identity);
            free(b);
            if (error_out) *error_out = "out of memory";
            return NULL;
        }
    }
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
        free(b->cookie);
        free(b->identity);
        free(b);
        if (error_out) *error_out = "libcurl initialization failed";
        return NULL;
    }
    b->curl = curl_easy_init();
    if (!b->curl) {
        free(b->cookie);
        free(b->identity);
        free(b);
        if (error_out) *error_out = "libcurl initialization failed";
        return NULL;
    }
    return b;
}

const char *minion_bridge_name(MinionBridge *b) {
    (void)b;
#if MINION_WIRE_CONFIRMED
    return "libcurl HTTPS (T3)";
#else
    return "libcurl HTTPS (T3 — wire seam unconfirmed; T4 capture)";
#endif
}

int minion_bridge_dispatch(MinionBridge *b, const char *text,
                           volatile int *interrupt_flag,
                           MinionBridgeEventFn on_event, void *ctx) {
    char url[512];
    char *escaped, *body;
    struct curl_slist *headers = NULL;
    CURLcode rc;
    long http_status = 0;

    b->on_event = on_event;
    b->event_ctx = ctx;
    b->interrupt_flag = interrupt_flag;

    /* Auth boundary: without the owner's session cookie the service
     * will only answer 401, and the designed sign-in mechanic (a
     * hosted flow in a browser window) is not one a CLI can perform.
     * Fail here, cleanly, before any network traffic. */
    if (!b->cookie) {
        bridge_emit(b, MINION_BRIDGE_ERROR,
            "authentication required: no session cookie supplied. "
            "The service's only sign-in is its hosted browser flow; "
            "supply the session cookie from your signed-in session "
            "in the " MINION_COOKIE_ENV " environment variable "
            "(see the T4 rig script). Nothing was sent.");
        return 1;
    }

    escaped = bridge_json_escape(text);
    if (!escaped) {
        bridge_emit(b, MINION_BRIDGE_ERROR, "out of memory");
        return 1;
    }
    {
        const char *pre = "{\"message\":\"";
        const char *post = "\"}";
        size_t blen = strlen(pre) + strlen(escaped) + strlen(post) + 1;
        body = (char *)malloc(blen);
        if (!body) {
            free(escaped);
            bridge_emit(b, MINION_BRIDGE_ERROR, "out of memory");
            return 1;
        }
        snprintf(body, blen, "%s%s%s", pre, escaped, post);
    }
    free(escaped);

    snprintf(url, sizeof(url), "%s%s", MINION_SERVICE_ORIGIN,
             MINION_SEND_PATH);

    b->reply_len = 0;
    if (b->reply) b->reply[0] = '\0';

    curl_easy_reset(b->curl);
    curl_easy_setopt(b->curl, CURLOPT_URL, url);
    curl_easy_setopt(b->curl, CURLOPT_POST, 1L);
    curl_easy_setopt(b->curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(b->curl, CURLOPT_WRITEFUNCTION, bridge_write_cb);
    curl_easy_setopt(b->curl, CURLOPT_WRITEDATA, b);
    curl_easy_setopt(b->curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(b->curl, CURLOPT_XFERINFOFUNCTION,
                     bridge_progress_cb);
    curl_easy_setopt(b->curl, CURLOPT_XFERINFODATA, b);
    /* Deliberately NO CURLOPT_TIMEOUT / CURLOPT_LOW_SPEED_TIME or
     * any other deadline: R1 forbids an observation cap. Interruption
     * is the owner's SIGINT, via the progress callback above. */
    headers = curl_slist_append(headers,
                                "Content-Type: application/json");
    headers = curl_slist_append(headers, "Accept: application/json");
    if (b->identity) {
        char ua[256];
        snprintf(ua, sizeof(ua), "User-Agent: %s", b->identity);
        headers = curl_slist_append(headers, ua);
    }
    {
        /* Cookie header built in a transient buffer; the value is
         * the owner's own session credential and is never logged. */
        size_t clen = strlen("Cookie: ") + strlen(b->cookie) + 1;
        char *chead = (char *)malloc(clen);
        if (!chead) {
            curl_slist_free_all(headers);
            free(body);
            bridge_emit(b, MINION_BRIDGE_ERROR, "out of memory");
            return 1;
        }
        snprintf(chead, clen, "Cookie: %s", b->cookie);
        headers = curl_slist_append(headers, chead);
        free(chead);
    }
    curl_easy_setopt(b->curl, CURLOPT_HTTPHEADER, headers);

    rc = curl_easy_perform(b->curl);
    curl_easy_getinfo(b->curl, CURLINFO_RESPONSE_CODE, &http_status);
    curl_slist_free_all(headers);
    free(body);

    if (rc == CURLE_ABORTED_BY_CALLBACK) {
        bridge_emit(b, MINION_BRIDGE_INTERRUPTED, "");
        return 2;
    }
    if (rc != CURLE_OK) {
        snprintf(b->error_text, sizeof(b->error_text),
                 "service unreachable: %s", curl_easy_strerror(rc));
        bridge_emit(b, MINION_BRIDGE_ERROR, b->error_text);
        return 1;
    }
    if (http_status == 401 || http_status == 403) {
        bridge_emit(b, MINION_BRIDGE_ERROR,
            "authentication rejected by the service (session expired "
            "or invalid): sign in again in the hosted app and refresh "
            "the session cookie. The message was not delivered.");
        return 1;
    }
    if (http_status < 200 || http_status >= 300) {
        snprintf(b->error_text, sizeof(b->error_text),
                 "service answered HTTP %ld; the message was not "
                 "confirmed delivered", http_status);
        bridge_emit(b, MINION_BRIDGE_ERROR, b->error_text);
        return 1;
    }
    bridge_emit(b, MINION_BRIDGE_DONE, b->reply ? b->reply : "");
    return 0;
}

void minion_bridge_close(MinionBridge *b) {
    if (!b) return;
    if (b->curl) curl_easy_cleanup(b->curl);
    if (b->cookie) {
        /* Scrub the credential from process memory before freeing. */
        memset(b->cookie, 0, strlen(b->cookie));
        free(b->cookie);
    }
    free(b->reply);
    free(b->identity);
    free(b);
}

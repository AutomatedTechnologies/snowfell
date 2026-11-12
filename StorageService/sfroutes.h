// sfroutes.h — route registration for the Snowfell Storage Service
// REST surface (design record 03 §8). The app context is owned by the
// entry point (service_main.c) and passed to every handler.
#ifndef SFROUTES_H
#define SFROUTES_H

#include "sfstore.h"
#include "sfhttp.h"

typedef struct {
    sf_store *store;
    char *data_dir;          // service data dir (spool + fs backends)
    char *bootstrap_path;    // <dir>/bootstrap-operator-token.txt or NULL
    char bind_label[80];     // "127.0.0.1:8471" as bound, for /v1/health
    int64_t start_unix;      // service start, for uptime
} sf_app_ctx;

sf_app_ctx *sf_app_ctx_new(sf_store *store, const char *data_dir);
void sf_app_ctx_free(sf_app_ctx *ctx);

// Register the /v1 tree on the server. `ctx` is an sf_app_ctx owned by
// the caller; it must outlive the server.
void sf_register_routes(sf_http_server *srv, void *ctx);

#endif // SFROUTES_H

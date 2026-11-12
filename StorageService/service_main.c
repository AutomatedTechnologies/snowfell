// service_main.c — entry point for snowfell-storage-service.
// Design record 03 §2/§5.5: per-user companion service; state in the
// data dir (mode 0700); loopback bind by default; operator bootstrap
// token written once to a 0600 file and deleted on first operator
// authentication (the delete hook lives in sfroutes.c).
//
// Config (environment):
//   SNOWFELL_CLOUD_DIR   data dir (default ~/Library/Application
//                        Support/Snowfell/cloud)
//   SNOWFELL_CLOUD_BIND  bind address (default 127.0.0.1)
//   SNOWFELL_CLOUD_PORT  port (default 8471; 0 = ephemeral, for tests)
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfcommon.h"
#include "sfauth.h"
#include "sfhttp.h"
#include "sfroutes.h"
#include "sfstore.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static sf_http_server *g_server = NULL;

static void on_signal(int sig) {
    (void)sig;
    if (g_server) sf_http_server_stop(g_server);
}

static int mkdir_p_mode(const char *path, mode_t final_mode) {
    char tmp[4096];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof tmp) return -1;
    memcpy(tmp, path, n + 1);
    for (size_t i = 1; i <= n; i++) {
        if (tmp[i] == '/' || tmp[i] == '\0') {
            char save = tmp[i];
            int last = (tmp[i] == '\0');
            tmp[i] = '\0';
            if (mkdir(tmp, last ? final_mode : 0755) != 0 && errno != EEXIST)
                return -1;
            tmp[i] = save;
        }
    }
    return 0;
}

static void join_path(char *out, size_t cap, const char *dir, const char *name) {
    snprintf(out, cap, "%s/%s", dir, name);
}

static void service_log(const char *dir, const char *line) {
    char lp[4096];
    join_path(lp, sizeof lp, dir, "service.log");
    FILE *f = fopen(lp, "a");
    if (!f) return;
    sf_time ts;
    sf_now_iso(ts);
    fprintf(f, "%s %s\n", ts, line);
    fclose(f);
}

int main(void) {
    const char *dir_env = getenv("SNOWFELL_CLOUD_DIR");
    char dir_buf[4096];
    const char *data_dir;
    if (dir_env && dir_env[0]) {
        data_dir = dir_env;
    } else {
        const char *home = getenv("HOME");
        if (home && home[0]) {
            snprintf(dir_buf, sizeof dir_buf,
                     "%s/Library/Application Support/Snowfell/cloud", home);
        } else {
            snprintf(dir_buf, sizeof dir_buf, "snowfell-cloud");
        }
        data_dir = dir_buf;
    }
    const char *bind_addr = getenv("SNOWFELL_CLOUD_BIND");
    if (!bind_addr || !bind_addr[0]) bind_addr = "127.0.0.1";
    long port = 8471;
    const char *port_env = getenv("SNOWFELL_CLOUD_PORT");
    if (port_env && port_env[0]) {
        char *endp = NULL;
        long v = strtol(port_env, &endp, 10);
        if (endp != port_env && *endp == '\0' && v >= 0 && v <= 65535) port = v;
    }

    if (mkdir_p_mode(data_dir, 0700) != 0) {
        fprintf(stderr, "snowfell-storage: cannot create data dir %s: %s\n",
                data_dir, strerror(errno));
        return 1;
    }
    chmod(data_dir, 0700);

    char db_path[4096];
    join_path(db_path, sizeof db_path, data_dir, "cloud.db");
    sf_store *store = sf_store_open(db_path);
    if (!store) {
        fprintf(stderr, "snowfell-storage: cannot open store %s\n", db_path);
        return 1;
    }

    // Default filesystem backend ('local', {"root":"fsroot"}) when the
    // store has no backends at all.
    sf_backend *backends = NULL;
    size_t backend_count = 0;
    if (sf_store_list_backends(store, &backends, &backend_count) == SF_OK) {
        sf_backend_free_all(backends, backend_count);
        if (backend_count == 0) {
            sf_backend created;
            memset(&created, 0, sizeof created);
            sf_result r = sf_store_create_backend(
                store, "local", "filesystem", "{\"root\":\"fsroot\"}", "", &created);
            if (r == SF_OK) {
                free(created.config_json);
                sf_store_audit(store, -1, "system", "system", "backend.create",
                               "backend:local", "ok",
                               "{\"reason\":\"default_filesystem_backend\"}", NULL);
                service_log(data_dir, "default filesystem backend 'local' created");
            } else {
                service_log(data_dir, "default backend creation failed");
            }
        }
    }

    // Operator bootstrap (§5.5): the plaintext goes to the 0600 file
    // exactly once; logs record only that bootstrap occurred.
    char token[256];
    token[0] = '\0';
    sf_result br = sf_auth_bootstrap_operator(store, token, sizeof token);
    if (br == SF_OK) {
        char bp[4096];
        join_path(bp, sizeof bp, data_dir, "bootstrap-operator-token.txt");
        int fd = open(bp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            fchmod(fd, 0600);
            FILE *bf = fdopen(fd, "w");
            if (bf) {
                fprintf(bf, "%s\n", token);
                fclose(bf);
            } else {
                close(fd);
            }
        }
        memset(token, 0, sizeof token);
        sf_store_audit(store, -1, "system", "system", "service.bootstrap",
                       "operator", "ok", "{}", NULL);
        service_log(data_dir, "operator bootstrap token issued (written to bootstrap file)");
    }

    sf_app_ctx *ctx = sf_app_ctx_new(store, data_dir);
    if (!ctx) {
        fprintf(stderr, "snowfell-storage: out of memory\n");
        sf_store_close(store);
        return 1;
    }

    sf_http_server *srv = sf_http_server_new(bind_addr, (uint16_t)port);
    if (!srv) {
        fprintf(stderr, "snowfell-storage: cannot bind %s:%ld\n", bind_addr, port);
        service_log(data_dir, "bind failed");
        sf_app_ctx_free(ctx);
        sf_store_close(store);
        return 1;
    }
    g_server = srv;
    sf_register_routes(srv, ctx);

    uint16_t bound = sf_http_server_port(srv);
    snprintf(ctx->bind_label, sizeof ctx->bind_label, "%s:%u", bind_addr,
             (unsigned)bound);

    char port_path[4096];
    join_path(port_path, sizeof port_path, data_dir, "service.port");
    FILE *pf = fopen(port_path, "w");
    if (pf) {
        fprintf(pf, "%u\n", (unsigned)bound);
        fclose(pf);
    }

    char start_line[4608];
    snprintf(start_line, sizeof start_line, "service started bind=%s port=%u dir=%s",
             bind_addr, (unsigned)bound, data_dir);
    service_log(data_dir, start_line);

    printf("SNOWFELL_STORAGE_READY port=%u dir=%s\n", (unsigned)bound, data_dir);
    fflush(stdout);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    int rr = sf_http_server_run(srv);
    service_log(data_dir, rr == 0 ? "service stopped" : "service run failed");

    sf_http_server_free(srv);
    g_server = NULL;
    sf_app_ctx_free(ctx);
    sf_store_close(store);
    return rr == 0 ? 0 : 1;
}

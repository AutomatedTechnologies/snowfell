// sfhttp.h — the HTTP/1.1 core (design record 03 §8): one request per
// connection, Content-Length framing only, header cap 1 MiB, route
// dispatch by (method, path pattern). The transport is isolated here
// so a future TLS listener replaces this file, not the routes (§2.3).
#ifndef SFHTTP_H
#define SFHTTP_H

#include "sfcommon.h"

// A parsed request. Header names are matched case-insensitively via
// sf_http_header(). `path` is percent-decoded and split from the query
// string; query pairs are available via sf_http_query(). `body` is the
// full request body (handlers that stream — object PUT — use the
// raw-body hook below instead; this field is for JSON-sized bodies).
typedef struct {
    char method[8];              // GET POST PUT PATCH DELETE HEAD
    char *path;                  // decoded, no query string
    char *query;                 // raw query string or NULL
    char *raw_target;            // as sent (for object keys: the
                                 // undecoded tail is recoverable via
                                 // sf_http_path_suffix)
    // headers: parallel arrays, owned
    char **header_names, **header_values;
    size_t header_count;
    uint8_t *body;
    size_t body_len;
    char remote_ip[48];
} sf_http_request;

const char *sf_http_header(const sf_http_request *req, const char *name);
// Query parameter lookup into a caller buffer; returns 1 when present.
int sf_http_query(const sf_http_request *req, const char *name,
                  char *out, size_t out_cap);
// Everything in the decoded path after `prefix` (for object keys,
// which contain slashes), or NULL when the path lacks the prefix.
const char *sf_http_path_suffix(const sf_http_request *req, const char *prefix);

// A response under construction.
typedef struct {
    int status;
    char content_type[96];       // default application/json
    uint8_t *body;
    size_t body_len;
    // extra headers: parallel arrays, owned
    char **header_names, **header_values;
    size_t header_count;
} sf_http_response;

void sf_http_response_init(sf_http_response *resp);
void sf_http_response_set_header(sf_http_response *resp,
                                 const char *name, const char *value);
// Takes ownership of a malloc'd body.
void sf_http_response_set_body(sf_http_response *resp, uint8_t *body, size_t len);
void sf_http_response_free(sf_http_response *resp);

// Route handler. `ctx` is the application context (store + config).
typedef void (*sf_http_handler)(void *ctx, const sf_http_request *req,
                                sf_http_response *resp);

// The server. Routes are matched in registration order; a pattern is
// an exact path, or ends in "/*" meaning: the literal prefix, then a
// non-empty remainder captured for sf_http_path_suffix.
typedef struct sf_http_server sf_http_server;
sf_http_server *sf_http_server_new(const char *bind_addr, uint16_t port);
void sf_http_server_route(sf_http_server *srv, const char *method,
                          const char *pattern, sf_http_handler fn, void *ctx);
// For object PUT: a route may claim the raw body stream instead of a
// buffered body. When raw_prefix matches the path prefix, the server
// calls raw_handler with the socket reader abstracted: read_body
// yields exactly Content-Length bytes in chunks.
typedef int (*sf_body_reader)(void *rctx, uint8_t *buf, size_t cap, size_t *nread);
typedef void (*sf_http_raw_handler)(void *ctx, const sf_http_request *req,
                                    sf_body_reader read_body, void *rctx,
                                    sf_http_response *resp);
void sf_http_server_route_raw(sf_http_server *srv, const char *method,
                              const char *path_prefix, sf_http_raw_handler fn,
                              void *ctx);
// Run until sf_http_server_stop is called from a signal handler or
// another thread. Returns 0 on clean stop, -1 on bind/listen failure.
int sf_http_server_run(sf_http_server *srv);
void sf_http_server_stop(sf_http_server *srv);
uint16_t sf_http_server_port(sf_http_server *srv);
void sf_http_server_free(sf_http_server *srv);

#endif // SFHTTP_H

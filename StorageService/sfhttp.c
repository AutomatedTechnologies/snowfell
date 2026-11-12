// sfhttp.c — HTTP/1.1 core for the Snowfell Storage Service.
// Design record 03 §8: one request per connection (Connection: close),
// Content-Length framing only (chunked -> 411), header cap 1 MiB,
// percent-decoded paths, exact + "/*" prefix route patterns, and a
// raw-body hook so object PUT streams instead of buffering.
// Buffered (JSON) route bodies are capped at 1 MiB (-> 413); the raw
// hook is the only path for larger bodies and enforces its own cap.
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfhttp.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define SF_HEADER_CAP (1024u * 1024u)   // 1 MiB
#define SF_JSON_BODY_CAP (1024u * 1024u) // 1 MiB buffered-body cap

// ---------------------------------------------------------------- util

static char *xstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static char *xstrndup(const char *s, size_t n) {
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Percent-decode src[0..n) into a fresh NUL-terminated string. When
// plus_as_space is set (query values), '+' decodes to a space.
static char *pct_decode(const char *src, size_t n, int plus_as_space) {
    char *out = (char *)malloc(n + 1);
    if (!out) return NULL;
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        char c = src[i];
        if (c == '%' && i + 2 < n) {
            int hi = hexval((unsigned char)src[i + 1]);
            int lo = hexval((unsigned char)src[i + 2]);
            if (hi >= 0 && lo >= 0) {
                out[w++] = (char)(hi * 16 + lo);
                i += 2;
                continue;
            }
        }
        if (c == '+' && plus_as_space) c = ' ';
        out[w++] = c;
    }
    out[w] = '\0';
    return out;
}

static const char *reason_phrase(int status) {
    switch (status) {
        case 200: return "OK";
        case 201: return "Created";
        case 204: return "No Content";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 409: return "Conflict";
        case 411: return "Length Required";
        case 413: return "Payload Too Large";
        case 429: return "Too Many Requests";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        default:  return "Status";
    }
}

// ------------------------------------------------------- public helpers

const char *sf_http_header(const sf_http_request *req, const char *name) {
    if (!req || !name) return NULL;
    for (size_t i = 0; i < req->header_count; i++) {
        if (strcasecmp(req->header_names[i], name) == 0)
            return req->header_values[i];
    }
    return NULL;
}

int sf_http_query(const sf_http_request *req, const char *name,
                  char *out, size_t out_cap) {
    if (!req || !req->query || !name || !out || out_cap == 0) return 0;
    size_t name_len = strlen(name);
    const char *p = req->query;
    while (*p) {
        const char *amp = strchr(p, '&');
        size_t pair_len = amp ? (size_t)(amp - p) : strlen(p);
        const char *eq = (const char *)memchr(p, '=', pair_len);
        size_t key_len = eq ? (size_t)(eq - p) : pair_len;
        // Compare the percent-decoded key against `name`.
        char *key = pct_decode(p, key_len, 0);
        int match = key && strcmp(key, name) == 0 && key_len <= name_len + 2;
        free(key);
        if (match) {
            const char *val = eq ? eq + 1 : p + pair_len;
            size_t val_len = eq ? pair_len - key_len - 1 : 0;
            char *dec = pct_decode(val, val_len, 1);
            if (!dec) return 0;
            size_t cpy = strlen(dec);
            if (cpy >= out_cap) cpy = out_cap - 1;
            memcpy(out, dec, cpy);
            out[cpy] = '\0';
            free(dec);
            return 1;
        }
        if (!amp) break;
        p = amp + 1;
    }
    return 0;
}

const char *sf_http_path_suffix(const sf_http_request *req, const char *prefix) {
    if (!req || !req->path || !prefix) return NULL;
    size_t n = strlen(prefix);
    if (strncmp(req->path, prefix, n) != 0) return NULL;
    return req->path + n;
}

void sf_http_response_init(sf_http_response *resp) {
    memset(resp, 0, sizeof *resp);
    resp->status = 200;
    snprintf(resp->content_type, sizeof resp->content_type, "application/json");
}

void sf_http_response_set_header(sf_http_response *resp,
                                 const char *name, const char *value) {
    if (!resp || !name || !value) return;
    for (size_t i = 0; i < resp->header_count; i++) {
        if (strcasecmp(resp->header_names[i], name) == 0) {
            char *v = xstrdup(value);
            if (v) { free(resp->header_values[i]); resp->header_values[i] = v; }
            return;
        }
    }
    char **nn = (char **)realloc(resp->header_names,
                                 (resp->header_count + 1) * sizeof(char *));
    if (!nn) return;
    resp->header_names = nn;
    char **nv = (char **)realloc(resp->header_values,
                                 (resp->header_count + 1) * sizeof(char *));
    if (!nv) return;
    resp->header_values = nv;
    resp->header_names[resp->header_count] = xstrdup(name);
    resp->header_values[resp->header_count] = xstrdup(value);
    if (resp->header_names[resp->header_count] &&
        resp->header_values[resp->header_count]) {
        resp->header_count++;
    } else {
        free(resp->header_names[resp->header_count]);
        free(resp->header_values[resp->header_count]);
    }
}

void sf_http_response_set_body(sf_http_response *resp, uint8_t *body, size_t len) {
    if (!resp) { free(body); return; }
    free(resp->body);
    resp->body = body;
    resp->body_len = body ? len : 0;
}

void sf_http_response_free(sf_http_response *resp) {
    if (!resp) return;
    free(resp->body);
    resp->body = NULL;
    resp->body_len = 0;
    for (size_t i = 0; i < resp->header_count; i++) {
        free(resp->header_names[i]);
        free(resp->header_values[i]);
    }
    free(resp->header_names);
    free(resp->header_values);
    resp->header_names = resp->header_values = NULL;
    resp->header_count = 0;
}

// ------------------------------------------------------------ socket io

typedef struct {
    int fd;
    uint8_t buf[16384];
    size_t start, end;   // valid bytes are buf[start..end)
    int eof;
} sf_reader;

static int reader_fill(sf_reader *r) {
    if (r->eof) return 0;
    if (r->start == r->end) { r->start = r->end = 0; }
    if (r->end == sizeof r->buf) {
        if (r->start > 0) {
            memmove(r->buf, r->buf + r->start, r->end - r->start);
            r->end -= r->start;
            r->start = 0;
        } else {
            return 1; // buffer full but unconsumed; treat as data ready
        }
    }
    ssize_t n = recv(r->fd, r->buf + r->end, sizeof r->buf - r->end, 0);
    if (n < 0) {
        if (errno == EINTR) return reader_fill(r);
        r->eof = 1;
        return 0;
    }
    if (n == 0) { r->eof = 1; return 0; }
    r->end += (size_t)n;
    return 1;
}

// Read exactly n bytes (fewer on EOF). Returns bytes read.
static size_t reader_read(sf_reader *r, uint8_t *dst, size_t n) {
    size_t got = 0;
    while (got < n) {
        size_t avail = r->end - r->start;
        if (avail > 0) {
            size_t take = avail < (n - got) ? avail : (n - got);
            memcpy(dst + got, r->buf + r->start, take);
            r->start += take;
            got += take;
            continue;
        }
        if (!reader_fill(r)) break;
    }
    return got;
}

static int write_all(int fd, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

// ------------------------------------------------------------- raw hook

typedef struct {
    sf_reader *reader;
    size_t remaining;   // Content-Length bytes not yet yielded
} sf_raw_ctx;

static int raw_read_body(void *rctx, uint8_t *buf, size_t cap, size_t *nread) {
    sf_raw_ctx *rc = (sf_raw_ctx *)rctx;
    if (!rc || !buf || !nread) return -1;
    if (rc->remaining == 0) { *nread = 0; return 0; }
    size_t want = cap < rc->remaining ? cap : rc->remaining;
    size_t got = reader_read(rc->reader, buf, want);
    rc->remaining -= got;
    *nread = got;
    // A short read means the peer closed early; report what we got and
    // let the handler notice remaining != 0 at end-of-stream.
    return 0;
}

// --------------------------------------------------------------- server

typedef struct {
    char *method;
    char *pattern;      // exact, or ending in "/*"
    sf_http_handler fn;
    void *ctx;
} sf_route;

typedef struct {
    char *method;
    char *prefix;
    sf_http_raw_handler fn;
    void *ctx;
} sf_raw_route;

struct sf_http_server {
    char *bind_addr;
    uint16_t requested_port;
    uint16_t bound_port;
    int listen_fd;
    volatile sig_atomic_t stop_flag;
    sf_route *routes;
    size_t route_count, route_cap;
    sf_raw_route *raw_routes;
    size_t raw_count, raw_cap;
};

sf_http_server *sf_http_server_new(const char *bind_addr, uint16_t port) {
    sf_http_server *srv = (sf_http_server *)calloc(1, sizeof *srv);
    if (!srv) return NULL;
    srv->bind_addr = xstrdup(bind_addr ? bind_addr : "127.0.0.1");
    srv->requested_port = port;
    srv->bound_port = port;
    srv->listen_fd = -1;
    if (!srv->bind_addr) { free(srv); return NULL; }

    // Bind + listen here (not in run) so the bound port — including an
    // ephemeral one — is known to the caller before the accept loop.
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST;
    char portstr[16];
    snprintf(portstr, sizeof portstr, "%u", (unsigned)port);
    struct addrinfo *res = NULL;
    if (getaddrinfo(srv->bind_addr, portstr, &hints, &res) != 0 || !res) {
        // Fall back to a plain IPv4 bind if the numeric lookup failed.
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { free(srv->bind_addr); free(srv); return NULL; }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_port = htons(port);
        if (inet_pton(AF_INET, srv->bind_addr, &a.sin_addr) != 1)
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 64) != 0) {
            close(fd);
            free(srv->bind_addr);
            free(srv);
            return NULL;
        }
        srv->listen_fd = fd;
    } else {
        int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd < 0) { freeaddrinfo(res); free(srv->bind_addr); free(srv); return NULL; }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, 64) != 0) {
            close(fd);
            freeaddrinfo(res);
            free(srv->bind_addr);
            free(srv);
            return NULL;
        }
        srv->listen_fd = fd;
        freeaddrinfo(res);
    }
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    if (getsockname(srv->listen_fd, (struct sockaddr *)&ss, &sl) == 0) {
        if (ss.ss_family == AF_INET)
            srv->bound_port = ntohs(((struct sockaddr_in *)&ss)->sin_port);
        else if (ss.ss_family == AF_INET6)
            srv->bound_port = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
    }
    return srv;
}

void sf_http_server_route(sf_http_server *srv, const char *method,
                          const char *pattern, sf_http_handler fn, void *ctx) {
    if (!srv || !method || !pattern || !fn) return;
    if (srv->route_count == srv->route_cap) {
        size_t nc = srv->route_cap ? srv->route_cap * 2 : 16;
        sf_route *nr = (sf_route *)realloc(srv->routes, nc * sizeof *nr);
        if (!nr) return;
        srv->routes = nr;
        srv->route_cap = nc;
    }
    sf_route *r = &srv->routes[srv->route_count];
    r->method = xstrdup(method);
    r->pattern = xstrdup(pattern);
    r->fn = fn;
    r->ctx = ctx;
    if (r->method && r->pattern) srv->route_count++;
    else { free(r->method); free(r->pattern); }
}

void sf_http_server_route_raw(sf_http_server *srv, const char *method,
                              const char *path_prefix, sf_http_raw_handler fn,
                              void *ctx) {
    if (!srv || !method || !path_prefix || !fn) return;
    if (srv->raw_count == srv->raw_cap) {
        size_t nc = srv->raw_cap ? srv->raw_cap * 2 : 8;
        sf_raw_route *nr = (sf_raw_route *)realloc(srv->raw_routes, nc * sizeof *nr);
        if (!nr) return;
        srv->raw_routes = nr;
        srv->raw_cap = nc;
    }
    sf_raw_route *r = &srv->raw_routes[srv->raw_count];
    r->method = xstrdup(method);
    r->prefix = xstrdup(path_prefix);
    r->fn = fn;
    r->ctx = ctx;
    if (r->method && r->prefix) srv->raw_count++;
    else { free(r->method); free(r->prefix); }
}

uint16_t sf_http_server_port(sf_http_server *srv) {
    return srv ? srv->bound_port : 0;
}

void sf_http_server_stop(sf_http_server *srv) {
    // Signal-safe: a single store to a sig_atomic_t flag.
    if (srv) srv->stop_flag = 1;
}

void sf_http_server_free(sf_http_server *srv) {
    if (!srv) return;
    if (srv->listen_fd >= 0) close(srv->listen_fd);
    for (size_t i = 0; i < srv->route_count; i++) {
        free(srv->routes[i].method);
        free(srv->routes[i].pattern);
    }
    free(srv->routes);
    for (size_t i = 0; i < srv->raw_count; i++) {
        free(srv->raw_routes[i].method);
        free(srv->raw_routes[i].prefix);
    }
    free(srv->raw_routes);
    free(srv->bind_addr);
    free(srv);
}

// ------------------------------------------------------------- dispatch

static void send_json_error(int fd, int status, const char *code, const char *msg) {
    char body[512];
    int bl = snprintf(body, sizeof body,
                      "{\"error\":{\"code\":\"%s\",\"message\":\"%s\",\"detail\":{}}}",
                      code, msg);
    if (bl < 0) return;
    if ((size_t)bl >= sizeof body) bl = (int)sizeof body - 1;
    char head[512];
    int hl = snprintf(head, sizeof head,
                      "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                      "Content-Length: %d\r\nConnection: close\r\n\r\n",
                      status, reason_phrase(status), bl);
    if (hl > 0) write_all(fd, head, (size_t)hl);
    write_all(fd, body, (size_t)bl);
}

static void send_response(int fd, const sf_http_response *resp) {
    char head[2048];
    size_t off = 0;
    int n = snprintf(head + off, sizeof head - off, "HTTP/1.1 %d %s\r\n",
                     resp->status, reason_phrase(resp->status));
    if (n < 0) return;
    off += (size_t)n;
    n = snprintf(head + off, sizeof head - off, "Content-Type: %s\r\n",
                 resp->content_type[0] ? resp->content_type : "application/json");
    if (n < 0) return;
    off += (size_t)n;
    n = snprintf(head + off, sizeof head - off, "Content-Length: %zu\r\n",
                 resp->body_len);
    if (n < 0) return;
    off += (size_t)n;
    for (size_t i = 0; i < resp->header_count && off < sizeof head - 64; i++) {
        n = snprintf(head + off, sizeof head - off, "%s: %s\r\n",
                     resp->header_names[i], resp->header_values[i]);
        if (n < 0) return;
        off += (size_t)n;
    }
    n = snprintf(head + off, sizeof head - off, "Connection: close\r\n\r\n");
    if (n < 0) return;
    off += (size_t)n;
    if (write_all(fd, head, off) != 0) return;
    if (resp->body && resp->body_len > 0) write_all(fd, resp->body, resp->body_len);
}

static void request_free(sf_http_request *req) {
    free(req->path);
    free(req->query);
    free(req->raw_target);
    for (size_t i = 0; i < req->header_count; i++) {
        free(req->header_names[i]);
        free(req->header_values[i]);
    }
    free(req->header_names);
    free(req->header_values);
    free(req->body);
    memset(req, 0, sizeof *req);
}

static int pattern_matches(const char *pattern, const char *path) {
    size_t plen = strlen(pattern);
    if (plen >= 2 && strcmp(pattern + plen - 2, "/*") == 0) {
        size_t prefix_len = plen - 1; // keep the trailing '/'
        return strncmp(path, pattern, prefix_len) == 0 && path[prefix_len] != '\0';
    }
    return strcmp(pattern, path) == 0;
}

// Read until the header terminator; returns a malloc'd buffer holding
// the header block (without the final CRLFCRLF) plus leftover body
// bytes already pulled into the reader. *hdr_len set on success.
// Return codes: 0 ok, 1 too large, -1 io/closed.
static int read_headers(sf_reader *r, char **out, size_t *out_len) {
    size_t cap = 16384, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return -1;
    for (;;) {
        // Search for CRLFCRLF in what we have.
        if (len >= 4) {
            for (size_t i = 0; i + 4 <= len; i++) {
                if (memcmp(buf + i, "\r\n\r\n", 4) == 0) {
                    // Push the bytes after the terminator back into the
                    // reader's buffer as already-read body bytes.
                    size_t leftover = len - (i + 4);
                    if (leftover > 0) {
                        // The reader buffer is empty by construction here
                        // (we consumed it byte-wise below), so seed it.
                        memcpy(r->buf, buf + i + 4, leftover);
                        r->start = 0;
                        r->end = leftover;
                    }
                    buf[i] = '\0';
                    *out = buf;
                    *out_len = i;
                    return 0;
                }
            }
        }
        if (len >= SF_HEADER_CAP) { free(buf); return 1; }
        uint8_t byte;
        size_t got = reader_read(r, &byte, 1);
        if (got == 0) { free(buf); return -1; }
        if (len == cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); return -1; }
            buf = nb;
        }
        buf[len++] = (char)byte;
    }
}

static void handle_connection(sf_http_server *srv, int fd,
                              const char *remote_ip) {
    struct timeval tv;
    tv.tv_sec = 120;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    sf_reader reader;
    memset(&reader, 0, sizeof reader);
    reader.fd = fd;

    char *hdr = NULL;
    size_t hdr_len = 0;
    int hr = read_headers(&reader, &hdr, &hdr_len);
    if (hr == 1) { send_json_error(fd, 431, "validation", "headers too large"); return; }
    if (hr != 0) return; // peer went away or sent nothing usable

    sf_http_request req;
    memset(&req, 0, sizeof req);
    snprintf(req.remote_ip, sizeof req.remote_ip, "%s", remote_ip ? remote_ip : "");

    // Request line.
    char *line_end = strstr(hdr, "\r\n");
    char *headers_start;
    if (line_end) { *line_end = '\0'; headers_start = line_end + 2; }
    else headers_start = hdr + hdr_len; // single-line request, no headers
    char *sp1 = strchr(hdr, ' ');
    char *sp2 = sp1 ? strchr(sp1 + 1, ' ') : NULL;
    if (!sp1 || !sp2) {
        send_json_error(fd, 400, "validation", "malformed request line");
        free(hdr);
        return;
    }
    *sp1 = '\0';
    *sp2 = '\0';
    const char *method = hdr;
    const char *target = sp1 + 1;
    if (strlen(method) >= sizeof req.method) {
        send_json_error(fd, 400, "validation", "method too long");
        free(hdr);
        return;
    }
    snprintf(req.method, sizeof req.method, "%s", method);
    req.raw_target = xstrdup(target);

    // Split target into path + query; percent-decode the path.
    const char *q = strchr(target, '?');
    size_t path_len = q ? (size_t)(q - target) : strlen(target);
    req.path = pct_decode(target, path_len, 0);
    req.query = q ? xstrdup(q + 1) : NULL;
    if (!req.path) { free(hdr); request_free(&req); return; }

    // Headers.
    int headers_ok = 1;
    char *p = headers_start;
    while (*p) {
        char *eol = strstr(p, "\r\n");
        char *line = eol ? xstrndup(p, (size_t)(eol - p)) : xstrdup(p);
        if (!line) { headers_ok = 0; break; }
        if (line[0] == '\0') { free(line); break; }
        char *colon = strchr(line, ':');
        if (!colon) { free(line); headers_ok = 0; break; }
        *colon = '\0';
        char *value = colon + 1;
        while (*value == ' ' || *value == '\t') value++;
        char *vend = value + strlen(value);
        while (vend > value && (vend[-1] == ' ' || vend[-1] == '\t')) *--vend = '\0';
        char **nn = (char **)realloc(req.header_names,
                                     (req.header_count + 1) * sizeof(char *));
        if (!nn) { free(line); headers_ok = 0; break; }
        req.header_names = nn;
        char **nv = (char **)realloc(req.header_values,
                                     (req.header_count + 1) * sizeof(char *));
        if (!nv) { free(line); headers_ok = 0; break; }
        req.header_values = nv;
        req.header_names[req.header_count] = xstrdup(line);
        req.header_values[req.header_count] = xstrdup(value);
        free(line);
        if (!req.header_names[req.header_count] ||
            !req.header_values[req.header_count]) { headers_ok = 0; break; }
        req.header_count++;
        if (!eol) break;
        p = eol + 2;
    }
    free(hdr);
    if (!headers_ok) {
        send_json_error(fd, 400, "validation", "malformed headers");
        request_free(&req);
        return;
    }

    // Framing: Content-Length only.
    const char *te = sf_http_header(&req, "Transfer-Encoding");
    if (te && strcasestr(te, "chunked")) {
        send_json_error(fd, 411, "length_required",
                        "chunked transfer encoding is not supported; send Content-Length");
        request_free(&req);
        return;
    }
    int has_cl = 0;
    unsigned long long content_length = 0;
    const char *cl = sf_http_header(&req, "Content-Length");
    if (cl) {
        char *endp = NULL;
        errno = 0;
        content_length = strtoull(cl, &endp, 10);
        if (errno != 0 || endp == cl) {
            send_json_error(fd, 400, "validation", "invalid Content-Length");
            request_free(&req);
            return;
        }
        has_cl = 1;
    }

    sf_http_response resp;
    sf_http_response_init(&resp);

    // Raw-body routes first: they claim the body stream.
    for (size_t i = 0; i < srv->raw_count; i++) {
        sf_raw_route *rr = &srv->raw_routes[i];
        if (strcmp(rr->method, req.method) == 0 &&
            strncmp(req.path, rr->prefix, strlen(rr->prefix)) == 0) {
            sf_raw_ctx rc;
            rc.reader = &reader;
            rc.remaining = has_cl ? (size_t)content_length : 0;
            rr->fn(rr->ctx, &req, raw_read_body, &rc, &resp);
            send_response(fd, &resp);
            sf_http_response_free(&resp);
            request_free(&req);
            return;
        }
    }

    // Buffered routes.
    for (size_t i = 0; i < srv->route_count; i++) {
        sf_route *rt = &srv->routes[i];
        if (strcmp(rt->method, req.method) != 0) continue;
        if (!pattern_matches(rt->pattern, req.path)) continue;
        if (has_cl && content_length > SF_JSON_BODY_CAP) {
            send_json_error(fd, 413, "payload_too_large",
                            "request body exceeds the 1 MiB limit for this route");
            sf_http_response_free(&resp);
            request_free(&req);
            return;
        }
        if (has_cl && content_length > 0) {
            req.body = (uint8_t *)malloc((size_t)content_length + 1);
            if (!req.body) {
                send_json_error(fd, 500, "internal", "out of memory");
                sf_http_response_free(&resp);
                request_free(&req);
                return;
            }
            size_t got = reader_read(&reader, req.body, (size_t)content_length);
            req.body[got] = '\0';
            req.body_len = got;
            if (got != (size_t)content_length) {
                send_json_error(fd, 400, "validation", "request body truncated");
                sf_http_response_free(&resp);
                request_free(&req);
                return;
            }
        }
        rt->fn(rt->ctx, &req, &resp);
        send_response(fd, &resp);
        sf_http_response_free(&resp);
        request_free(&req);
        return;
    }

    send_json_error(fd, 404, "not_found", "route not found");
    sf_http_response_free(&resp);
    request_free(&req);
}

int sf_http_server_run(sf_http_server *srv) {
    if (!srv || srv->listen_fd < 0) return -1;
    // Writes to a closed peer must not kill the service.
    signal(SIGPIPE, SIG_IGN);
    while (!srv->stop_flag) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(srv->listen_fd, &rfds);
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 250000; // poll the stop flag 4x/sec
        int sel = select(srv->listen_fd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (sel == 0) continue;
        struct sockaddr_storage ss;
        socklen_t sl = sizeof ss;
        int fd = accept(srv->listen_fd, (struct sockaddr *)&ss, &sl);
        if (fd < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            continue;
        }
        char ip[48] = "";
        if (ss.ss_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)&ss)->sin_addr,
                      ip, sizeof ip);
        } else if (ss.ss_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&ss)->sin6_addr,
                      ip, sizeof ip);
        }
        handle_connection(srv, fd, ip);
        close(fd);
    }
    return 0;
}

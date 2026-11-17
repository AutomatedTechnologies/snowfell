/*
 * main.c — `minion` entry point. Command surface v1 (charter R3):
 *
 *   minion                    REPL (or stdin mode when piped)
 *   minion send <message...>  one-shot: enqueue one message, drain, exit
 *   minion status             print session state without sending
 *   minion --help             usage
 *
 * R1 semantics in the REPL: every line the owner enters is enqueued
 * first and drained head-first. Typing ahead while a reply streams
 * queues the line — it is delivered after the current turn, in order,
 * never instead of it. Ctrl-C interrupts the in-flight turn only; the
 * undelivered remainder of the queue stays queued and is reported.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#include "minion.h"
#include "session.h"
#include "commands.h"

static volatile int g_interrupted = 0;

static void on_sigint(int sig) {
    (void)sig;
    g_interrupted = 1;
}

/* Streaming printer: DELTA events carry full snapshots (the bridge.h
 * contract), so print only the newly appended suffix of each
 * snapshot — the reply reaches stdout incrementally, as the service
 * produces it (T3). DONE closes the line. Snapshots are append-only
 * in the bridge, so the suffix diff is exact. */
typedef struct {
    size_t last_len;
    int printed_any;
} PrintCtx;

static void on_bridge_event(void *ctx_, const MinionBridgeEvent *ev) {
    PrintCtx *ctx = (PrintCtx *)ctx_;
    switch (ev->type) {
    case MINION_BRIDGE_DELTA:
        if (ev->text) {
            size_t n = strlen(ev->text);
            if (n > ctx->last_len) {
                fputs(ev->text + ctx->last_len, stdout);
                fflush(stdout);
                ctx->last_len = n;
                ctx->printed_any = 1;
            }
        }
        break;
    case MINION_BRIDGE_DONE:
        if (!ctx->printed_any) {
            if (ev->text && ev->text[0]) printf("%s", ev->text);
            else printf("(no reply text)");
        }
        printf("\n");
        fflush(stdout);
        break;
    case MINION_BRIDGE_ERROR:
        printf("!! %s\n", ev->text ? ev->text : "bridge error");
        fflush(stdout);
        break;
    case MINION_BRIDGE_INTERRUPTED:
        printf("\n[interrupted — remainder of the queue stays queued]\n");
        fflush(stdout);
        break;
    }
}

/* Read one line of arbitrary length from f. Returns a malloc'd string
 * without the trailing newline, or NULL at EOF with no bytes read. */
static char *read_line(FILE *f) {
    size_t cap = 256, len = 0;
    char *buf = (char *)malloc(cap);
    int c;
    if (!buf) return NULL;
    while ((c = fgetc(f)) != EOF) {
        if (c == '\n') break;
        if (len + 1 >= cap) {
            char *nb;
            cap *= 2;
            nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); return NULL; }
            buf = nb;
        }
        buf[len++] = (char)c;
    }
    if (c == EOF && len == 0) {
        free(buf);
        return NULL;
    }
    buf[len] = '\0';
    return buf;
}

static void trim(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r'))
        s[--n] = '\0';
}

/* Handle one input line: local command, or enqueue + drain.
 * Returns 1 when the owner asked to quit. */
static int process_line(MinionSession *s, char *line) {
    bool quit = false;
    trim(line);
    if (line[0] == '\0') return 0;
    if (strcmp(line, "/status") == 0) {
        minion_session_print_status(s);
        return 0;
    }
    if (minion_handle_local_command(line, &quit)) return quit ? 1 : 0;
    if (minion_session_send(s, line) == 0) {
        printf("!! could not queue the message\n");
        return 0;
    }
    {
        PrintCtx ctx;
        int rc;
        ctx.last_len = 0;
        ctx.printed_any = 0;
        g_interrupted = 0;
        rc = minion_session_drain(s, &g_interrupted, on_bridge_event, &ctx);
        if (rc == 2 && s->queue.depth > 0)
            printf("[%zu message(s) still queued]\n", s->queue.depth);
    }
    return 0;
}

static int run_repl(MinionSession *s, int interactive) {
    if (interactive) {
        printf("Minion — terminal\n");
        printf("a true command-line interface to Minion; this session "
               "is its own channel\n");
        printf("Type a message and press Enter. /help lists the "
               "local commands.\n");
    }
    for (;;) {
        char *line;
        if (interactive) {
            printf("minion > ");
            fflush(stdout);
        }
        line = read_line(stdin);
        if (!line) break;       /* EOF */
        if (process_line(s, line)) {
            free(line);
            break;
        }
        free(line);
        if (g_interrupted && !interactive) break;
    }
    return 0;
}

static void usage(FILE *out) {
    fprintf(out,
        "usage:\n"
        "  minion                    interactive terminal (REPL)\n"
        "  minion send <message...>  send one message, print the reply\n"
        "  minion status             session state; sends nothing\n"
        "  minion --help             this text\n"
        "With stdin piped, each line is a message (or a local "
        "command), delivered in order.\n");
}

int main(int argc, char **argv) {
    MinionSession session;
    const char *error = NULL;
    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;
    sigaction(SIGINT, &sa, NULL);

    if (argc >= 2 &&
        (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        usage(stdout);
        return 0;
    }

    if (minion_session_open(&session, &error) != 0) {
        fprintf(stderr, "minion: could not open a session: %s\n",
                error ? error : "unknown error");
        return 1;
    }

    if (argc >= 2 && strcmp(argv[1], "status") == 0) {
        minion_session_print_status(&session);
        minion_session_close(&session);
        return 0;
    }

    if (argc >= 2 && strcmp(argv[1], "send") == 0) {
        /* Join argv[2..] with single spaces into one message. */
        size_t total = 0;
        int i, rc;
        char *msg, *p;
        PrintCtx ctx;
        if (argc < 3) {
            fprintf(stderr, "minion send: nothing to send\n");
            minion_session_close(&session);
            return 2;
        }
        for (i = 2; i < argc; i++) total += strlen(argv[i]) + 1;
        msg = (char *)malloc(total + 1);
        if (!msg) {
            minion_session_close(&session);
            return 1;
        }
        p = msg;
        for (i = 2; i < argc; i++) {
            size_t n = strlen(argv[i]);
            if (i > 2) *p++ = ' ';
            memcpy(p, argv[i], n);
            p += n;
        }
        *p = '\0';
        if (minion_session_send(&session, msg) == 0) {
            fprintf(stderr, "minion send: could not queue the message\n");
            free(msg);
            minion_session_close(&session);
            return 1;
        }
        free(msg);
        ctx.last_len = 0;
        ctx.printed_any = 0;
        rc = minion_session_drain(&session, &g_interrupted,
                                  on_bridge_event, &ctx);
        minion_session_close(&session);
        return rc == 0 ? 0 : 1;
    }

    if (argc >= 2) {
        fprintf(stderr, "minion: unknown command '%s'\n", argv[1]);
        usage(stderr);
        minion_session_close(&session);
        return 2;
    }

    {
        int rc = run_repl(&session, isatty(STDIN_FILENO) != 0);
        minion_session_close(&session);
        return rc;
    }
}

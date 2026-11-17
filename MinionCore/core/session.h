/*
 * session.h — one CLI session: the queue plus its bridge.
 *
 * The session is the unit of R1 ownership. Whoever holds a
 * MinionSession owns a queue and a bridge channel; sends accumulate in
 * the queue and drain strictly head-first. `minion status` reads this
 * state without sending anything.
 */
#ifndef MINION_SESSION_H
#define MINION_SESSION_H

#include "minion.h"
#include "queue.h"
#include "bridge.h"

typedef enum {
    MINION_SESSION_NEW = 0,
    MINION_SESSION_OPEN,
    MINION_SESSION_CLOSED
} MinionSessionState;

typedef struct {
    MinionQueue queue;
    MinionBridge *bridge;
    MinionSessionState state;
    uint64_t opened_at_ms;
    uint64_t last_completed_seq;
    int last_dispatch_rc;
    /* Client identity handed to the bridge at open, built from the
     * injected version stamp (version.h) — never a hardcoded
     * literal (merge architecture §C). */
    char identity[128];
} MinionSession;

int minion_session_open(MinionSession *s, const char **error_out);
void minion_session_close(MinionSession *s);

/* Enqueue a send. Returns its sequence number (0 on failure). */
uint64_t minion_session_send(MinionSession *s, const char *text);

/* Drain the queue head-first until empty or interrupted. Events go to
 * on_event. Returns 0 when the queue drained fully, 2 when the owner
 * interrupted (remainder stays queued), other non-zero on error. */
int minion_session_drain(MinionSession *s, volatile int *interrupt_flag,
                         MinionBridgeEventFn on_event, void *ctx);

/* Print session state (the `minion status` surface). Never sends. */
void minion_session_print_status(MinionSession *s);

#endif /* MINION_SESSION_H */

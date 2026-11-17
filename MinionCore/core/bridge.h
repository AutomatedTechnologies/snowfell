/*
 * bridge.h — the session bridge interface (Tranche 3 fills this in).
 *
 * The bridge is the CLI's own channel to the hosted Minion service,
 * held under the CLI's own client identity (charter R4). It replaces
 * the 0.4.2 desktop bridge — academy.cjs relaying
 * `academy:terminal:send-request` into the hosted page's preload.cjs,
 * which drove the page's single composer and observed the reply
 * through a single `termActive` slot — whose two structural defects
 * (supersession, 180 s observation cap) this program exists to remove.
 *
 * Contract the real bridge must keep:
 *  - One dispatch is in flight at a time, driven by the queue head.
 *  - Events stream until the service ends the turn. There is NO
 *    deadline parameter anywhere in this interface: no turn cap.
 *  - The only early exit is MINION_BRIDGE_EVENT_INTERRUPTED, produced
 *    when the owner interrupts (Ctrl-C) — the poll function receives
 *    the owner's interrupt flag and reports it.
 */
#ifndef MINION_BRIDGE_H
#define MINION_BRIDGE_H

#include "minion.h"

typedef enum {
    MINION_BRIDGE_DELTA = 1,      /* reply text so far (snapshot) */
    MINION_BRIDGE_DONE,           /* service ended the turn */
    MINION_BRIDGE_ERROR,          /* transport/service failure */
    MINION_BRIDGE_INTERRUPTED     /* owner interrupted (Ctrl-C) */
} MinionBridgeEventType;

typedef struct {
    MinionBridgeEventType type;
    const char *text;   /* DELTA: snapshot text; ERROR: message. Owned
                           by the bridge; valid until the next poll. */
} MinionBridgeEvent;

typedef struct MinionBridge MinionBridge;

/* Event sink: called synchronously from the dispatch loop. */
typedef void (*MinionBridgeEventFn)(void *ctx, const MinionBridgeEvent *ev);

/* Open a bridge. `identity` is the CLI's client identity string.
 * Returns NULL on failure and sets *error_out (static storage). */
MinionBridge *minion_bridge_open(const char *identity, const char **error_out);

/* Human-readable transport name, e.g. "stub (T2)" — for `status`. */
const char *minion_bridge_name(MinionBridge *b);

/* Dispatch one message and stream its events until DONE / ERROR /
 * INTERRUPTED. `interrupt_flag` is polled between events; when it
 * becomes non-zero the dispatch ends as INTERRUPTED. Returns 0 on
 * DONE, non-zero otherwise. */
int minion_bridge_dispatch(MinionBridge *b, const char *text,
                           volatile int *interrupt_flag,
                           MinionBridgeEventFn on_event, void *ctx);

void minion_bridge_close(MinionBridge *b);

#endif /* MINION_BRIDGE_H */

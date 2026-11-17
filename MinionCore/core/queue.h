/*
 * queue.h — the R1 FIFO send queue.
 *
 * Sends enter at the tail and are dispatched at the head, strictly in
 * order. Nothing in this program removes, reorders, or replaces a
 * queued send: supersession is impossible by construction. A queued
 * send leaves the queue only by being dispatched and completed, or by
 * the owner interrupting the session (Ctrl-C) — and even then the
 * undelivered remainder stays queued and is reported, never dropped
 * silently.
 */
#ifndef MINION_QUEUE_H
#define MINION_QUEUE_H

#include "minion.h"

typedef struct MinionMessage {
    char *text;                 /* owned by the queue node */
    uint64_t seq;               /* 1-based, assigned at enqueue */
    struct MinionMessage *next;
} MinionMessage;

typedef struct {
    MinionMessage *head;
    MinionMessage *tail;
    size_t depth;
    uint64_t next_seq;
    uint64_t total_enqueued;
    uint64_t total_completed;
} MinionQueue;

void minion_queue_init(MinionQueue *q);

/* Enqueue a copy of text. Returns the assigned sequence number, or 0
 * on allocation failure. */
uint64_t minion_queue_enqueue(MinionQueue *q, const char *text);

/* Remove and return the head message (caller frees text + node via
 * minion_message_free). Returns NULL when empty. */
MinionMessage *minion_queue_dequeue(MinionQueue *q);

void minion_message_free(MinionMessage *m);

/* Free every queued message without dispatching (session teardown). */
void minion_queue_clear(MinionQueue *q);

#endif /* MINION_QUEUE_H */

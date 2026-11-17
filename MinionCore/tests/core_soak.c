/*
 * core_soak.c — host-build unit soak for the extracted session core
 * (merge tranche M3). Linux host evidence only: it proves the core's
 * queue/session/bridge behavior at the auth boundary, exactly the
 * T3 soak re-run against the static library — it is NOT a live send
 * test (the wire seam is T4's, on the Air).
 *
 * Assertions:
 *  1. Queue FIFO: enqueue order == dequeue order, sequence numbers
 *     1..N in order, depth accounting exact.
 *  2. Remainder: after a partial drain, the undelivered remainder
 *     stays queued, in order (R1: never dropped, never reordered).
 *  3. Boundary soak (the T3 pattern, per line): with MINION_COOKIE
 *     unset, each session send+drain dispatches exactly once, in
 *     order, and ends at the auth-boundary ERROR event. Run under
 *     strace by the M3 record to prove zero connect() calls.
 *  4. Batch drain: one drain over 3 queued sends stops at the first
 *     dispatch's boundary error with the other two still queued.
 *  5. Version injection: minion_version() equals
 *     MINION_EXPECT_VERSION when the build defines it (else the
 *     labeled developer fallback), the stamped flag matches
 *     MINION_EXPECT_STAMPED, and the session identity carries the
 *     version string.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "minion.h"
#include "queue.h"
#include "session.h"
#include "version.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
} while (0)

typedef struct {
    int errors;
    int deltas;
    int dones;
    int interrupted;
    char last_error[512];
} Capture;

static void on_event(void *ctx_, const MinionBridgeEvent *ev) {
    Capture *c = (Capture *)ctx_;
    switch (ev->type) {
    case MINION_BRIDGE_ERROR:
        c->errors++;
        if (ev->text) {
            strncpy(c->last_error, ev->text, sizeof(c->last_error) - 1);
            c->last_error[sizeof(c->last_error) - 1] = '\0';
        }
        break;
    case MINION_BRIDGE_DELTA: c->deltas++; break;
    case MINION_BRIDGE_DONE: c->dones++; break;
    case MINION_BRIDGE_INTERRUPTED: c->interrupted++; break;
    }
}

static void test_queue_fifo(void) {
    MinionQueue q;
    MinionMessage *m;
    minion_queue_init(&q);
    CHECK(minion_queue_enqueue(&q, "one") == 1, "seq 1");
    CHECK(minion_queue_enqueue(&q, "two") == 2, "seq 2");
    CHECK(minion_queue_enqueue(&q, "three") == 3, "seq 3");
    CHECK(q.depth == 3 && q.total_enqueued == 3, "depth/total after enqueue");

    m = minion_queue_dequeue(&q);
    CHECK(m && m->seq == 1 && strcmp(m->text, "one") == 0, "head is 'one'");
    minion_message_free(m);

    /* Remainder stays queued, in order. */
    CHECK(q.depth == 2, "remainder depth 2");
    m = minion_queue_dequeue(&q);
    CHECK(m && m->seq == 2 && strcmp(m->text, "two") == 0, "next is 'two'");
    minion_message_free(m);
    m = minion_queue_dequeue(&q);
    CHECK(m && m->seq == 3 && strcmp(m->text, "three") == 0, "next is 'three'");
    minion_message_free(m);
    CHECK(minion_queue_dequeue(&q) == NULL && q.depth == 0, "queue empty");
    minion_queue_clear(&q);
    printf("queue FIFO + remainder: ok\n");
}

static void test_session_boundary(void) {
    MinionSession s;
    const char *error = NULL;
    volatile int flag = 0;
    int i;

    unsetenv("MINION_COOKIE");   /* the boundary condition, by design */
    if (minion_session_open(&s, &error) != 0) {
        printf("FAIL: session open: %s\n", error ? error : "?");
        failures++;
        return;
    }

    /* Per-line pattern (the T3 stdin soak): send + drain, x3. */
    for (i = 0; i < 3; i++) {
        Capture cap;
        char msg[16];
        int rc;
        memset(&cap, 0, sizeof(cap));
        snprintf(msg, sizeof(msg), "line-%d", i + 1);
        CHECK(minion_session_send(&s, msg) == (uint64_t)(i + 1),
              "session seq in order");
        rc = minion_session_drain(&s, &flag, on_event, &cap);
        CHECK(rc == 1, "drain stops at the auth boundary (rc 1)");
        CHECK(cap.errors == 1 && cap.deltas == 0 && cap.dones == 0,
              "exactly one boundary ERROR event per dispatch");
        CHECK(strstr(cap.last_error, "authentication required") != NULL,
              "boundary error names the cause");
        CHECK(s.queue.depth == 0, "attempted message accounted, none lost");
    }
    CHECK(s.queue.total_enqueued == 3 && s.queue.total_completed == 0,
          "3 enqueued, 0 completed at the boundary");

    /* Batch pattern: one drain over 3 queued sends stops at the
     * first error; the remainder stays queued, in order. */
    {
        Capture cap;
        MinionMessage *m;
        int rc;
        memset(&cap, 0, sizeof(cap));
        minion_session_send(&s, "batch-1");
        minion_session_send(&s, "batch-2");
        minion_session_send(&s, "batch-3");
        rc = minion_session_drain(&s, &flag, on_event, &cap);
        CHECK(rc == 1 && cap.errors == 1, "batch drain stops at first error");
        CHECK(s.queue.depth == 2, "batch remainder stays queued");
        m = minion_queue_dequeue(&s.queue);
        CHECK(m && strcmp(m->text, "batch-2") == 0, "remainder head batch-2");
        minion_message_free(m);
        m = minion_queue_dequeue(&s.queue);
        CHECK(m && strcmp(m->text, "batch-3") == 0, "remainder next batch-3");
        minion_message_free(m);
    }

    /* Version injection, as the status surface reports it. */
    printf("--- session status (as printed by the core) ---\n");
    minion_session_print_status(&s);
    printf("--- end status ---\n");
    CHECK(strstr(s.identity, minion_version()) != NULL,
          "identity carries the version string");
#ifdef MINION_EXPECT_VERSION
    CHECK(strcmp(minion_version(), MINION_EXPECT_VERSION) == 0,
          "version equals the injected stamp");
#endif
#ifdef MINION_EXPECT_STAMPED
    CHECK(minion_version_is_stamped() == MINION_EXPECT_STAMPED,
          "stamped flag matches the build");
#endif
    if (!minion_version_is_stamped())
        CHECK(strcmp(minion_version(), "0.0.0-dev") == 0,
              "unstamped build reports the labeled developer fallback");

    minion_session_close(&s);
    printf("session boundary soak: ok\n");
}

int main(void) {
    test_queue_fifo();
    test_session_boundary();
    if (failures) {
        printf("SOAK FAIL (%d failures)\n", failures);
        return 1;
    }
    printf("SOAK PASS\n");
    return 0;
}

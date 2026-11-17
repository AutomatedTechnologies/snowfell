#include "session.h"

#include <stdio.h>
#include <string.h>

#include "version.h"

int minion_session_open(MinionSession *s, const char **error_out) {
    memset(s, 0, sizeof(*s));
    minion_queue_init(&s->queue);
    /* Identity from the injected version stamp (merge architecture
     * §C): the same string is the bridge's User-Agent and the status
     * surface's identity line, so CLI, lens, and bundle never drift
     * onto separate version claims. */
    snprintf(s->identity, sizeof(s->identity),
             "minion-cli/%s (macOS 10.13)", minion_version());
    s->bridge = minion_bridge_open(s->identity, error_out);
    if (!s->bridge) {
        s->state = MINION_SESSION_CLOSED;
        return -1;
    }
    s->state = MINION_SESSION_OPEN;
    s->opened_at_ms = minion_now_ms();
    return 0;
}

void minion_session_close(MinionSession *s) {
    if (s->bridge) minion_bridge_close(s->bridge);
    s->bridge = NULL;
    minion_queue_clear(&s->queue);
    s->state = MINION_SESSION_CLOSED;
}

uint64_t minion_session_send(MinionSession *s, const char *text) {
    if (s->state != MINION_SESSION_OPEN) return 0;
    return minion_queue_enqueue(&s->queue, text);
}

int minion_session_drain(MinionSession *s, volatile int *interrupt_flag,
                         MinionBridgeEventFn on_event, void *ctx) {
    MinionMessage *m;
    while ((m = minion_queue_dequeue(&s->queue)) != NULL) {
        int rc = minion_bridge_dispatch(s->bridge, m->text,
                                        interrupt_flag, on_event, ctx);
        s->last_dispatch_rc = rc;
        if (rc == 0) {
            s->queue.total_completed++;
            s->last_completed_seq = m->seq;
        }
        minion_message_free(m);
        if (rc == 2) return 2;      /* interrupted: remainder stays */
        if (rc != 0) return rc;     /* transport error: stop draining */
    }
    return 0;
}

void minion_session_print_status(MinionSession *s) {
    const char *state =
        s->state == MINION_SESSION_OPEN ? "open" :
        s->state == MINION_SESSION_NEW ? "new" : "closed";
    printf("session: %s\n", state);
    if (s->bridge) printf("bridge: %s\n", minion_bridge_name(s->bridge));
    printf("identity: %s\n", s->identity);
    printf("version: %s%s\n", minion_version(),
           minion_version_is_stamped()
               ? ""
               : " (developer build — no version stamp injected; "
                 "packaging stamps from the bundle Info.plist)");
    printf("queued: %zu\n", s->queue.depth);
    printf("enqueued: %llu\n",
           (unsigned long long)s->queue.total_enqueued);
    printf("completed: %llu\n",
           (unsigned long long)s->queue.total_completed);
    printf("last completed seq: %llu\n",
           (unsigned long long)s->last_completed_seq);
}

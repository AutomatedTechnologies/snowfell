#include "queue.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

char *minion_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *copy = (char *)malloc(n);
    if (copy) memcpy(copy, s, n);
    return copy;
}

uint64_t minion_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

void minion_queue_init(MinionQueue *q) {
    q->head = NULL;
    q->tail = NULL;
    q->depth = 0;
    q->next_seq = 1;
    q->total_enqueued = 0;
    q->total_completed = 0;
}

uint64_t minion_queue_enqueue(MinionQueue *q, const char *text) {
    MinionMessage *m = (MinionMessage *)calloc(1, sizeof(MinionMessage));
    if (!m) return 0;
    m->text = minion_strdup(text);
    if (!m->text) {
        free(m);
        return 0;
    }
    m->seq = q->next_seq++;
    m->next = NULL;
    if (q->tail) q->tail->next = m;
    else q->head = m;
    q->tail = m;
    q->depth++;
    q->total_enqueued++;
    return m->seq;
}

MinionMessage *minion_queue_dequeue(MinionQueue *q) {
    MinionMessage *m = q->head;
    if (!m) return NULL;
    q->head = m->next;
    if (!q->head) q->tail = NULL;
    m->next = NULL;
    q->depth--;
    return m;
}

void minion_message_free(MinionMessage *m) {
    if (!m) return;
    free(m->text);
    free(m);
}

void minion_queue_clear(MinionQueue *q) {
    MinionMessage *m;
    while ((m = minion_queue_dequeue(q)) != NULL) minion_message_free(m);
}

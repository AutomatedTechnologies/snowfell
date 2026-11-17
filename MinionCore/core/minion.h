/*
 * minion.h — shared types for the Minion CLI (macOS 10.13 floor).
 *
 * Program: Minion CLI — High Sierra command-line tools (P0).
 * Charter: R1 session ownership (FIFO queue, no supersession, no turn
 * cap), R2 native 10.13 binary, R3 command surface v1.
 *
 * Plain C11 against system headers only. No third-party code.
 */
#ifndef MINION_H
#define MINION_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/* Duplicate a string using only C11/POSIX-2001 facilities. */
char *minion_strdup(const char *s);

/* Monotonic milliseconds, for status reporting (never a turn cap). */
uint64_t minion_now_ms(void);

#endif /* MINION_H */

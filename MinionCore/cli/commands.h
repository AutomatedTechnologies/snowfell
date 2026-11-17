/*
 * commands.h — local commands, at parity with the 0.4.2 terminal
 * (terminal.html): /help, /clear, /view. Anything else beginning with
 * '/' is refused in place with a pointer to /help — same rule as the
 * terminal surface. Local commands never reach the bridge.
 */
#ifndef MINION_COMMANDS_H
#define MINION_COMMANDS_H

#include <stdbool.h>

/* If `line` is a local command (begins with '/'), handle it and
 * return true. *quit is set when the owner asked to leave (/quit is a
 * CLI addition; the terminal's set has no exit command because its
 * window close hides instead of quitting). */
bool minion_handle_local_command(const char *line, bool *quit);

void minion_print_help(void);

#endif /* MINION_COMMANDS_H */

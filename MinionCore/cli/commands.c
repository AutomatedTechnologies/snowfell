#include "commands.h"

#include <stdio.h>
#include <string.h>

void minion_print_help(void) {
    printf("/help   this list\n");
    printf("/clear  clear the scrollback\n");
    printf("/view   back to the hosted Minion window\n");
    printf("/status session state (same as `minion status`)\n");
    printf("/quit   leave the Minion CLI\n");
    printf("Anything else is a message to Minion.\n");
}

bool minion_handle_local_command(const char *line, bool *quit) {
    if (line[0] != '/') return false;

    if (strcmp(line, "/help") == 0) {
        minion_print_help();
    } else if (strcmp(line, "/clear") == 0) {
        /* ANSI clear + home, then the caller reprints its prompt. */
        printf("\033[2J\033[H");
        fflush(stdout);
    } else if (strcmp(line, "/view") == 0) {
        /* Parity stub: the hosted terminal's /view returns to the
         * hosted window. The true CLI has no hosted window — it IS
         * the primary interface — so /view reports that plainly
         * instead of pretending to switch anywhere. */
        printf("No hosted window in the CLI — this terminal is the "
               "primary interface.\n");
    } else if (strcmp(line, "/quit") == 0 || strcmp(line, "/exit") == 0) {
        *quit = true;
    } else {
        printf("Unknown local command: %s — /help lists them. "
               "Nothing was sent.\n", line);
    }
    return true;
}

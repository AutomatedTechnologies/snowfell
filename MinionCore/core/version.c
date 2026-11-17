#include "version.h"

/*
 * The stamp arrives as a compile-time string literal:
 *   -DMINION_VERSION_STAMP='"0.4.4"'
 * (the Makefile's VERSION variable is the injection point; packaging
 * sets it from the bundle Info.plist — merge architecture §C, M5).
 * No stamp is the developer-build case and is labeled as such.
 */
#ifdef MINION_VERSION_STAMP
const char *minion_version(void) { return MINION_VERSION_STAMP; }
int minion_version_is_stamped(void) { return 1; }
#else
const char *minion_version(void) { return "0.0.0-dev"; }
int minion_version_is_stamped(void) { return 0; }
#endif

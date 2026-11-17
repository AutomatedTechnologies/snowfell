/*
 * version.h — the one version identity (merge architecture §C).
 *
 * The merged application's only version source is its bundle
 * Info.plist (CFBundleShortVersionString + CFBundleVersion). The
 * core never carries a hardcoded product version: the build injects
 * the stamp — packaging (M5) passes the plist value as
 * -DMINION_VERSION_STAMP='"x.y.z"' — and at runtime the installed
 * command resolves its own path into the containing bundle and reads
 * the plist (the M5 runtime read supersedes the stamp for the
 * bundled binary; the symlink resolves into the bundle, so the read
 * succeeds for the installed command).
 *
 * Until then, an unstamped developer build reports the labeled
 * fallback below — never a plausible-looking product version — and
 * status surfaces say so (minion_version_is_stamped() == 0).
 */
#ifndef MINION_VERSION_H
#define MINION_VERSION_H

/* The core's version string: the injected stamp when the build
 * provided one, else the developer fallback "0.0.0-dev". */
const char *minion_version(void);

/* Non-zero when minion_version() is an injected stamp; zero for the
 * developer fallback. */
int minion_version_is_stamped(void);

#endif /* MINION_VERSION_H */

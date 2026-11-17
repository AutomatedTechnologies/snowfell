# Minion CLI + shared session core

A true native command-line interface to Minion for macOS 10.13 —
the primary Minion interface per the owner's directive of
2026-11-13 20:59 EST. Charter and design:
`~/workspace/goals/minion-cli-high-sierra/files/`.

State: **T3 — real bridge, built to the auth boundary; M3 (merge,
2026-11-14) — the session core is extracted as a static library.**
The REPL, local commands, FIFO send queue, and one-shot modes are
real code; the session bridge (`core/bridge.c`) is a real libcurl
transport (streaming, no deadline, SIGINT-only early exit) behind
the `bridge.h` contract. Two things remain open, both T4 items: the
wire seam (send path + payload/stream shape) is a labeled
placeholder block in `bridge.c`, filled from a capture in the
owner's signed-in session; and authentication — the service's only
sign-in is its hosted browser flow minting a cookie session, so the
owner supplies the cookie at run time via the `MINION_COOKIE`
environment variable (never stored or printed). Without it,
dispatch stops at a clean auth-boundary error before any network
traffic. Record: `files/DESIGN-T3-2026-11-13.md` (incl. the T4 rig
script, §5). Nothing here has run on a Mac; build evidence is the
syntax-level compile gate (`make gate`) plus host-build boundary
behavior tests (`make soak`).

Layout (M3 extraction — merge architecture §B/§C/§E):
- `core/` — the ONE session/queue core, built as `libminioncore.a`:
  - `queue.c` / `queue.h` — the R1 FIFO send queue (+ string/time helpers in `minion.h`)
  - `session.c` / `session.h` — one session = queue + bridge; the `status` surface
  - `bridge.c` / `bridge.h` — the transport contract (`bridge.h` unchanged since T2) + the T3 libcurl bridge
  - `version.c` / `version.h` — the injected version identity (§C: no hardcoded product version in the core; packaging stamps from the bundle Info.plist, `make VERSION=...`)
  Both merged-app front-ends link this library: the standalone
  `minion` binary below and the merged shell's Terminal lens (M4).
- `cli/` — the standalone binary's front-end:
  - `main.c` — entry point, REPL, `send`/`status`/stdin modes
  - `commands.c` / `commands.h` — local commands at parity with the 0.4.2 terminal
- `tests/core_soak.c` — host-build unit soak for the core (FIFO
  order, remainder, auth-boundary dispatch accounting, version
  injection). `make soak` (developer fallback) and
  `make soak-stamped` (injection proof) run it.

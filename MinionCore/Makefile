# Minion CLI + shared session core — macOS 10.13 floor.
#
# Layout (merge tranche M3, 2026-11-14): the session core
# (queue/session/bridge/version) lives in core/ and builds as a
# static library, libminioncore.a — the ONE session/queue core the
# merged application's Terminal lens and the standalone `minion`
# binary both link (merge architecture §B/§C, host model (d)). The
# CLI front-end (REPL + local commands) lives in cli/.
#
# `make`          build ./minion on a Mac (Xcode CLT, deployment
#                 target 10.13). This is the rig build (Tranche 4,
#                 owner's Air).
# `make core`     build libminioncore.a only.
# `make gate`     syntax-only compile gate from the Linux VM, per
#                 the estate recipe (~/TOOLS.md 2026-11-07): Ubuntu
#                 clang 18, -target x86_64-apple-darwin17,
#                 MacOSX10.13.sdk, -fsyntax-only, over every core
#                 and front-end source. Syntax-level evidence ONLY —
#                 it proves the sources parse against the 10.13
#                 headers; it does not link and does not run.
# `make soak`     host-build boundary soak (tests/core_soak.c) —
#                 Linux host evidence: FIFO order, no-cookie =>
#                 zero network, version-stamp injection.
#
# VERSION is the version-stamp injection point (architecture §C):
# packaging (M5) builds with VERSION=<CFBundleShortVersionString>
# read from the merged bundle's Info.plist. Unset = developer build;
# the core then reports the labeled 0.0.0-dev fallback.

CC      ?= cc
CLANG   ?= clang
SDK     ?= $(HOME)/workspace/tools/sdks/MacOSX10.13.sdk
CFLAGS  := -std=c11 -Wall -Wextra -O2 -D_POSIX_C_SOURCE=200809L
CORE_SRC := core/queue.c core/session.c core/bridge.c core/version.c
CLI_SRC  := cli/main.c cli/commands.c
ALL_SRC  := $(CORE_SRC) $(CLI_SRC)

ifneq ($(VERSION),)
STAMP   := -DMINION_VERSION_STAMP='"$(VERSION)"'
endif

libminioncore.a: $(CORE_SRC) core/*.h
	$(CC) $(CFLAGS) $(STAMP) -Icore -c $(CORE_SRC)
	ar rcs $@ queue.o session.o bridge.o version.o
	rm -f queue.o session.o bridge.o version.o

core: libminioncore.a

minion: libminioncore.a $(CLI_SRC) cli/*.h
	$(CC) $(CFLAGS) -mmacosx-version-min=10.13 -Icore -Icli -o $@ $(CLI_SRC) libminioncore.a -lcurl

gate:
	@for f in $(ALL_SRC); do \
	  echo "gate: $$f"; \
	  $(CLANG) -target x86_64-apple-darwin17 -isysroot $(SDK) \
	    -std=c11 -Wall -Wextra -D_POSIX_C_SOURCE=200809L \
	    -fsyntax-only -Icore -Icli $$f || exit 1; \
	done
	@echo "gate: all files passed (syntax-level only)"

soak: tests/core_soak.c libminioncore.a
	$(CC) $(CFLAGS) -Icore -o /tmp/minion-core-soak tests/core_soak.c libminioncore.a -lcurl
	/tmp/minion-core-soak

soak-stamped: tests/core_soak.c $(CORE_SRC) core/*.h
	$(CC) $(CFLAGS) -DMINION_VERSION_STAMP='"9.9.9-test"' \
	  -DMINION_EXPECT_VERSION='"9.9.9-test"' -DMINION_EXPECT_STAMPED=1 \
	  -Icore -o /tmp/minion-core-soak-stamped tests/core_soak.c $(CORE_SRC) -lcurl
	/tmp/minion-core-soak-stamped

clean:
	rm -f minion libminioncore.a

.PHONY: core gate soak soak-stamped clean

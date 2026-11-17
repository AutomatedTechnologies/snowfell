#!/usr/bin/env python3
"""Snowfell snowfell-test-9 headless smoke check — the Terminal lens
(merge tranche M4) and the shared session core it links.

Asserts:
  * the vendored MinionCore tree is BYTE-IDENTICAL to the M3 tree of
    record (minion-cli program, hidden_files/work/minion-cli) — file
    set + per-file SHA-256; the merge ships ONE core, not a copy that
    can drift
  * MinionCore/core/bridge.h is at the M3 contract hash (bridge.h
    unchanged across the merge, architecture of record)
  * the core soak, built from the VENDORED tree on this host,
    passes: FIFO + remainder, per-line sends end at the auth-boundary
    ERROR in order with 0 completed (no cookie -> nothing is sent),
    batch drain stops at the first error with the rest still queued
  * the stamped soak variant passes (the version-injection seam CI
    uses to give the app link and the bundled `minion` binary one
    version identity)

Host-build note (the M3 recipe, MERGE-M2-M3 record): this VM has no
host curl headers, so bridge.c compiles against the 10.13 SDK's own
curl headers via a shim include dir (a copy of the SDK curl/ headers
+ a stub Availability.h). The sources under test are byte-identical
to the ones the clang 10.13 syntax gate passed. Behavior evidence is
Linux-host level, NOT Mac — the rig verdict stays the owner's (S4).

Usage: python3 smoke_terminal.py
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

APP = Path(__file__).parent
VENDORED = APP / "MinionCore"
TREE_OF_RECORD = (Path.home() / "workspace/goals/minion-cli-high-sierra"
                  / "hidden_files/work/minion-cli")
SDK_CURL = (Path.home() / "workspace/tools/sdks/MacOSX10.13.sdk"
            / "usr/include/curl")
BRIDGE_H_SHA256 = ("73c78129f1bc591f069d8305b1aa7099dea532bf9"
                   "d38dae46325963ca98ef105")

fails = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail else ""))
    if not ok:
        fails.append(name)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_files(root):
    return sorted(p.relative_to(root) for p in root.rglob("*") if p.is_file())


# — 1. bridge.h at the M3 contract hash —
check("bridge.h == M3 contract hash",
      sha256(VENDORED / "core/bridge.h") == BRIDGE_H_SHA256)

# — 2. vendored tree byte-identical to the M3 tree of record —
vendored_files = tree_files(VENDORED)
record_files = tree_files(TREE_OF_RECORD)
check("vendored file set == M3 tree file set",
      vendored_files == record_files,
      f"{len(vendored_files)} files")
mismatch = [str(rel) for rel in vendored_files
            if rel in record_files
            and sha256(VENDORED / rel) != sha256(TREE_OF_RECORD / rel)]
check("every vendored file byte-identical to M3 tree", not mismatch,
      ("mismatch: " + ", ".join(mismatch)) if mismatch else "")

# — 3/4. the soak, built from the vendored tree —
CORE_SRC = ["core/queue.c", "core/session.c", "core/bridge.c", "core/version.c"]


def build_and_run_soak(work, extra_defs, label):
    shim = work / "shim"
    (shim / "curl").mkdir(parents=True)
    for header in SDK_CURL.iterdir():
        shutil.copy2(header, shim / "curl" / header.name)
    (shim / "Availability.h").write_text(
        "/* host-build stub (M3 recipe): the SDK curl headers include\n"
        "   <Availability.h> and annotate declarations with\n"
        "   __OSX_AVAILABLE_STARTING(...); on this Linux host the\n"
        "   annotation is a no-op. */\n"
        "#ifndef AVAILABILITY_H\n#define AVAILABILITY_H\n"
        "#define __OSX_AVAILABLE_STARTING(a, b)\n#endif\n",
        encoding="utf-8")
    src = work / "src"
    shutil.copytree(VENDORED, src)
    out = work / f"soak-{label}"
    # This VM carries the libcurl runtime (libcurl.so.4) but no -dev
    # symlink for -lcurl; link the versioned soname when the plain
    # one is absent.
    curl_link = "-lcurl"
    if not any((Path(d) / "libcurl.so").exists()
               for d in ("/usr/lib/x86_64-linux-gnu", "/usr/lib", "/usr/local/lib")):
        curl_link = "-l:libcurl.so.4"
    cmd = (["gcc", "-std=c11", "-Wall", "-Wextra",
            "-D_POSIX_C_SOURCE=200809L", f"-I{shim}", "-Icore"]
           + extra_defs
           + ["-o", str(out), "tests/core_soak.c"] + CORE_SRC + [curl_link])
    build = subprocess.run(cmd, cwd=src, capture_output=True, text=True)
    if build.returncode != 0:
        check(f"soak ({label}) builds from vendored tree", False,
              build.stderr.strip().splitlines()[-1] if build.stderr else "")
        return
    check(f"soak ({label}) builds from vendored tree", True)
    run = subprocess.run([str(out)], cwd=src, capture_output=True, text=True)
    check(f"soak ({label}) passes", run.returncode == 0
          and "SOAK PASS" in run.stdout,
          (run.stdout.strip().splitlines() or [""])[-1])


with tempfile.TemporaryDirectory(prefix="sf-t9-smoke-") as tmp:
    work = Path(tmp)
    build_and_run_soak(work / "unstamped", [], "unstamped")
    build_and_run_soak(work / "stamped",
                       ["-DMINION_VERSION_STAMP=\"9.9.9-test\"",
                        "-DMINION_EXPECT_VERSION=\"9.9.9-test\"",
                        "-DMINION_EXPECT_STAMPED=1"],
                       "stamped")

print("SMOKE TERMINAL:", "ALL PASS" if not fails else f"{len(fails)} FAILURES")
sys.exit(1 if fails else 0)

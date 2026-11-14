#!/usr/bin/env python3
"""M-09 bind-clamp driver (snowfell-test-5): SnowfellStorageService
must refuse a non-loopback bind unless SNOWFELL_CLOUD_ALLOW_REMOTE=1.

Cases:
  1. SNOWFELL_CLOUD_BIND=0.0.0.0, no override  -> exits non-zero,
     stderr names the refusal, no READY line.
  2. SNOWFELL_CLOUD_BIND=0.0.0.0 + ALLOW_REMOTE=1 -> starts (READY).
  3. default (no BIND env) -> starts on loopback (READY).

Builds the service exactly like test_storage_service.py
(make -C StorageService service). Exit 0 iff all cases pass.
"""
import os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
SVC_DIR = os.path.join(HERE, "StorageService")


def build():
    r = subprocess.run(["make", "-C", SVC_DIR, "service"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
        raise SystemExit("build failed")
    for name in ("SnowfellStorageService", "snowfell-storage-service"):
        p = os.path.join(SVC_DIR, name)
        if os.path.isfile(p):
            return p
    raise SystemExit("service binary not found after build")


def run_case(binary, extra_env, wait_ready):
    data_dir = tempfile.mkdtemp(prefix="snowfell-bindclamp-")
    env = dict(os.environ)
    env["SNOWFELL_CLOUD_DIR"] = data_dir
    env["SNOWFELL_CLOUD_PORT"] = "0"
    env.pop("SNOWFELL_CLOUD_BIND", None)
    env.pop("SNOWFELL_CLOUD_ALLOW_REMOTE", None)
    env.update(extra_env)
    proc = subprocess.Popen([binary], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    out = []
    deadline = time.time() + 20
    ready = False
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        time.sleep(0.1)
        # opportunistic non-blocking drain
        import select
        if proc.stdout and select.select([proc.stdout], [], [], 0)[0]:
            line = proc.stdout.readline()
            if line:
                out.append(line)
                if "SNOWFELL_STORAGE_READY" in line:
                    ready = True
                    break
    rc = proc.poll()
    if rc is None:
        proc.terminate()
        try:
            rest, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            rest, _ = proc.communicate()
        out.append(rest or "")
        rc = proc.returncode
    else:
        rest, _ = proc.communicate()
        out.append(rest or "")
    return rc, "".join(out), ready


def main():
    binary = build()
    failures = []

    rc, out, ready = run_case(binary, {"SNOWFELL_CLOUD_BIND": "0.0.0.0"}, False)
    ok = (rc not in (0, None) and not ready and
          "refusing non-loopback bind" in out)
    print("case 1 (remote bind refused):", "PASS" if ok else "FAIL",
          "rc=%s ready=%s" % (rc, ready))
    if not ok:
        failures.append(1)
        print(out[-800:])

    rc, out, ready = run_case(binary, {"SNOWFELL_CLOUD_BIND": "0.0.0.0",
                                       "SNOWFELL_CLOUD_ALLOW_REMOTE": "1"}, True)
    ok = ready
    print("case 2 (remote bind with override):", "PASS" if ok else "FAIL")
    if not ok:
        failures.append(2)
        print(out[-800:])

    rc, out, ready = run_case(binary, {}, True)
    ok = ready
    print("case 3 (default loopback):", "PASS" if ok else "FAIL")
    if not ok:
        failures.append(3)
        print(out[-800:])

    print("BIND CLAMP: %s" % ("ALL PASS" if not failures else "FAILURES %s" % failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

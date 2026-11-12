#!/usr/bin/env python3
"""Snowfell Storage Service — integration test suite (SF-T12g).

Design of record: ../../03-CLOUD-STORAGE-DESIGN.md, in particular
  §5 (auth: login CRUD, PBKDF2, lockout, sessions/API tokens, reset,
      operator bootstrap), §7 (storage adapters, key grammar, quotas),
  §8 (REST surface, envelopes, error codes, pagination) and
  §10.3 (this suite: real HTTP against the compiled binary).

Python 3 standard library ONLY. Loopback only. $0.

Behaviour:
  * Builds the service:  make -C <StorageService> service
    A build failure is a suite RESULT: the build output is printed
    verbatim and the suite exits 2 — it is never hidden.
  * Starts the binary with SNOWFELL_CLOUD_DIR=<fresh tempdir> and
    SNOWFELL_CLOUD_PORT=0, waits for the SNOWFELL_STORAGE_READY stdout
    line (or a service.port file in the data dir), and reads the
    operator token from <dir>/bootstrap-operator-token.txt (§5.5).
  * Runs assertion groups A..J over real HTTP, printing
        CASE <group>.<n> <name>: PASS|FAIL
    plus a final summary. Exit status: 0 = all pass, 1 = any FAIL,
    2 = build failure.
  * Temp dirs are removed unless SNOWFELL_KEEP_TEST=1.

Ambiguities in the design text (asserted as written; noted here and at
the call sites, per the suite brief):
  * §8 names the object metadata field `metadata_json` and says HEAD
    returns "metadata JSON", but does not name the wire encoding a PUT
    uses to SUPPLY metadata. The suite tries the header
    `X-Snowfell-Metadata` first, then two plausible fallbacks, and
    verifies the round-trip through the object list / HEAD.
  * §7.3 places the S3 object at <tenant_id>/<bucket_id>/<key>, while
    sfadapter.h names the physical object <prefix><tenant_id>/
    <bucket_id>/<sha256-of-key>. Group I asserts the tenant/bucket
    prefix — the load-bearing isolation fact both texts agree on —
    not the final path component.
  * §8 gives usage as "quota vs used, per bucket" without field
    names; the suite accepts the common spellings and also sums the
    per-bucket figures when a bucket list is present.
  * Backend creation (§8) does not spell out whether S3 config rides
    in `config_json` (the §4 column name) or as flat fields; the
    suite tries the documented shapes in order.
"""

import hashlib
import hmac as hmac_mod
import http.server
import json
import os
import re
import secrets as secrets_mod
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from email.utils import parsedate_to_datetime

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# Design §2.1: the service sources live in files/app/StorageService/,
# i.e. inside the script's directory. Fall back to a sibling of the
# script's directory so the suite survives either layout.
STORAGE_DIR = os.path.join(SCRIPT_DIR, "StorageService")
if not os.path.isdir(STORAGE_DIR):
    STORAGE_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "StorageService")
SERVICE_BIN_OVERRIDE = os.environ.get("SNOWFELL_SERVICE_BIN", "")

READY_TIMEOUT = 30.0
HTTP_TIMEOUT = 20.0

# Every password / token the suite generates or receives, for the
# group-H audit-leak scan (design §4: audit detail never carries
# passwords, tokens, or secret material).
SECRETS_USED = []


def note_secret(value):
    if value and isinstance(value, str) and len(value) >= 6:
        SECRETS_USED.append(value)
    return value


def new_password(tag):
    return note_secret("Pw-%s-%s!9" % (tag, secrets_mod.token_hex(8)))


# ---------------------------------------------------------------- cases

class Cases(object):
    def __init__(self):
        self.counts = {}
        self.passed = 0
        self.failed = 0
        self.failures = []

    def case(self, group, name, ok, detail=""):
        n = self.counts.get(group, 0) + 1
        self.counts[group] = n
        verdict = "PASS" if ok else "FAIL"
        line = "CASE %s.%d %s: %s" % (group, n, name, verdict)
        if not ok and detail:
            line += " -- %s" % (detail,)
        print(line, flush=True)
        if ok:
            self.passed += 1
        else:
            self.failed += 1
            self.failures.append(line)
        return ok


# ---------------------------------------------------------------- http

class Resp(object):
    def __init__(self, status, headers, body, error=None):
        self.status = status
        self.headers = headers or {}          # lower-cased name -> value
        self.body = body or b""
        self.error = error
        try:
            self.json = json.loads(self.body.decode("utf-8")) \
                if self.body else None
        except Exception:
            self.json = None

    def text(self):
        return self.body.decode("utf-8", "replace")


class Client(object):
    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")

    def request(self, method, path, token=None, json_body=None,
                raw_body=None, headers=None, content_type=None):
        url = self.base_url + path
        data = raw_body
        hdrs = {}
        if json_body is not None:
            data = json.dumps(json_body).encode("utf-8")
            hdrs["Content-Type"] = "application/json"
        if content_type:
            hdrs["Content-Type"] = content_type
        if token:
            hdrs["Authorization"] = "Bearer " + token
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request(url, data=data, headers=hdrs,
                                     method=method)
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                return Resp(r.status,
                            {k.lower(): v for k, v in r.headers.items()},
                            r.read())
        except urllib.error.HTTPError as e:
            return Resp(e.code,
                        {k.lower(): v for k, v in e.headers.items()}
                        if e.headers else {},
                        e.read())
        except Exception as e:  # connection refused, timeout, ...
            return Resp(0, {}, b"", error=repr(e))

    def get(self, path, token=None, **kw):
        return self.request("GET", path, token=token, **kw)

    def post(self, path, token=None, **kw):
        return self.request("POST", path, token=token, **kw)

    def put(self, path, token=None, **kw):
        return self.request("PUT", path, token=token, **kw)

    def patch(self, path, token=None, **kw):
        return self.request("PATCH", path, token=token, **kw)

    def delete(self, path, token=None, **kw):
        return self.request("DELETE", path, token=token, **kw)

    def head(self, path, token=None, **kw):
        return self.request("HEAD", path, token=token, **kw)


# ------------------------------------------------------- envelope utils
# §8: success { "data": ..., "meta": { "next_cursor": ... } },
#     error   { "error": { "code", "message", "detail" } }.

def data_of(resp):
    if isinstance(resp.json, dict) and "data" in resp.json:
        return resp.json["data"]
    return resp.json


def err_of(resp):
    if isinstance(resp.json, dict) and isinstance(resp.json.get("error"), dict):
        return resp.json["error"]
    return {}


def err_code(resp):
    return err_of(resp).get("code", "")


def rows_of(resp):
    d = data_of(resp)
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        for k in ("items", "rows", "results", "tenants", "logins",
                  "buckets", "objects", "tokens", "audit", "entries",
                  "backends"):
            if isinstance(d.get(k), list):
                return d[k]
    return []


def next_cursor(resp):
    if isinstance(resp.json, dict):
        meta = resp.json.get("meta")
        if isinstance(meta, dict) and "next_cursor" in meta:
            return meta["next_cursor"]
    d = data_of(resp)
    if isinstance(d, dict) and "next_cursor" in d:
        return d["next_cursor"]
    return None


def dig(obj, keys, depth=0):
    """First value found for any of `keys`, searching nested dicts."""
    if depth > 4 or obj is None:
        return None
    if isinstance(obj, dict):
        for k in keys:
            if k in obj and obj[k] is not None:
                return obj[k]
        for v in obj.values():
            found = dig(v, keys, depth + 1)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = dig(v, keys, depth + 1)
            if found is not None:
                return found
    return None


def row_id(row):
    if isinstance(row, dict):
        v = row.get("id")
        if isinstance(v, int):
            return v
        if isinstance(v, str) and v.isdigit():
            return int(v)
    return None


def extract_token(resp, extra_keys=()):
    d = data_of(resp)
    if isinstance(d, str) and d:
        return d
    v = dig(d, ("token", "session_token", "api_token", "access_token",
                "reset_token", "password_reset_token", "plaintext") +
          tuple(extra_keys))
    return v if isinstance(v, str) and v else None


def qs(params):
    return "?" + urllib.parse.urlencode(params)


def seg(name):
    return urllib.parse.quote(str(name), safe="")


def key_path(key):
    return "/".join(urllib.parse.quote(p, safe="")
                    for p in str(key).split("/"))


# ---------------------------------------------------------------- build

def build_service():
    """Returns (binary_path, build_output). binary None on failure."""
    cmd = ["make", "-C", STORAGE_DIR, "service"]
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=600)
        out = p.communicate() if False else p.stdout.decode("utf-8", "replace")
        rc = p.returncode
    except Exception as e:
        return None, "build invocation failed: %r" % (e,)
    if rc != 0:
        return None, out
    if SERVICE_BIN_OVERRIDE and os.path.isfile(SERVICE_BIN_OVERRIDE):
        return SERVICE_BIN_OVERRIDE, out
    candidates = ["SnowfellStorageService", "snowfell-storage-service",
                  "storage-service", "snowfell_storage_service", "service"]
    for name in candidates:
        path = os.path.join(STORAGE_DIR, name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path, out
    # Fall back to any executable regular file the build produced.
    try:
        for name in sorted(os.listdir(STORAGE_DIR)):
            path = os.path.join(STORAGE_DIR, name)
            if os.path.isfile(path) and os.access(path, os.X_OK) \
                    and not name.endswith((".py", ".sql", ".h", ".c",
                                          ".sh", ".md")):
                return path, out
    except OSError:
        pass
    return None, out + "\n[suite] make succeeded but no service binary " \
                       "was found in %s" % STORAGE_DIR


# ------------------------------------------------------------- service

class Instance(object):
    def __init__(self, name):
        self.name = name
        self.dir = None
        self.proc = None
        self.port = None
        self.base_url = None
        self.client = None
        self.operator_token = None
        self.lines = []
        self._lock = threading.Lock()

    def output(self):
        with self._lock:
            return "\n".join(self.lines)


def _parse_port(text):
    if not text:
        return None
    # Anchor on the explicit forms first (READY line is
    # "SNOWFELL_STORAGE_READY port=<n> dir=<path>", and the path may
    # itself contain digit runs that must never be read as the port).
    m = re.search(r"port\s*=\s*(\d+)", str(text))
    if m and 1 <= int(m.group(1)) <= 65535:
        return int(m.group(1))
    m = re.search(r"[: ](\d{2,5})\b", str(text))
    if m and 1 <= int(m.group(1)) <= 65535:
        return int(m.group(1))
    m = re.findall(r"(\d{2,5})", str(text))
    for tok in m:
        v = int(tok)
        if 1 <= v <= 65535:
            return v
    return None


def start_instance(binary, name, data_dir, extra_env=None,
                   expect_bootstrap=True):
    inst = Instance(name)
    inst.dir = data_dir
    os.makedirs(data_dir, exist_ok=True)
    # Suite-owned data dir: drop a stale service.port from a previous
    # instance on this dir (group J restart) so the readiness wait
    # cannot read the dead instance's port.
    try:
        os.unlink(os.path.join(data_dir, "service.port"))
    except OSError:
        pass
    env = dict(os.environ)
    env.pop("SNOWFELL_S3_TEST_SECRET", None)
    env["SNOWFELL_CLOUD_DIR"] = data_dir
    env["SNOWFELL_CLOUD_PORT"] = "0"
    if extra_env:
        env.update(extra_env)
    inst.proc = subprocess.Popen(
        [binary], env=env, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, bufsize=1)

    def reader():
        try:
            for line in inst.proc.stdout:
                with inst._lock:
                    inst.lines.append(line.rstrip("\n"))
        except Exception:
            pass
    threading.Thread(target=reader, daemon=True).start()

    port_file = os.path.join(data_dir, "service.port")
    deadline = time.time() + READY_TIMEOUT
    port = None
    while time.time() < deadline:
        if inst.proc.poll() is not None:
            raise RuntimeError(
                "service %s exited early rc=%s; output:\n%s"
                % (name, inst.proc.returncode, inst.output()))
        with inst._lock:
            for line in inst.lines:
                if "SNOWFELL_STORAGE_READY" in line:
                    port = _parse_port(line.split("SNOWFELL_STORAGE_READY",
                                                   1)[1]) or _parse_port(line)
                    if port:
                        break
        if port:
            break
        if os.path.isfile(port_file):
            try:
                with open(port_file) as f:
                    port = _parse_port(f.read())
            except OSError:
                port = None
            if port:
                break
        time.sleep(0.05)
    if not port:
        raise RuntimeError(
            "service %s did not announce a port within %.0fs; output:\n%s"
            % (name, READY_TIMEOUT, inst.output()))
    inst.port = port
    inst.base_url = "http://127.0.0.1:%d" % port
    inst.client = Client(inst.base_url)

    # Health must answer before the suite proceeds (public route, §8).
    deadline = time.time() + 15
    healthy = False
    while time.time() < deadline:
        r = inst.client.get("/v1/health")
        if r.status == 200:
            healthy = True
            break
        if inst.proc.poll() is not None:
            raise RuntimeError("service %s died during startup; output:\n%s"
                               % (name, inst.output()))
        time.sleep(0.1)
    if not healthy:
        raise RuntimeError(
            "service %s never answered /v1/health at %s; output:\n%s"
            % (name, inst.base_url, inst.output()))

    if expect_bootstrap:
        boot = os.path.join(data_dir, "bootstrap-operator-token.txt")
        deadline = time.time() + 15
        while time.time() < deadline and not os.path.isfile(boot):
            time.sleep(0.05)
        if not os.path.isfile(boot):
            raise RuntimeError(
                "bootstrap operator token file never appeared in %s; "
                "output:\n%s" % (data_dir, inst.output()))
        with open(boot) as f:
            inst.operator_token = note_secret(f.read().strip())
    return inst


def stop_instance(inst):
    if inst is None or inst.proc is None:
        return
    if inst.proc.poll() is None:
        try:
            inst.proc.send_signal(signal.SIGTERM)
        except Exception:
            pass
        try:
            inst.proc.wait(timeout=10)
        except Exception:
            try:
                inst.proc.kill()
            except Exception:
                pass


# ------------------------------------------------------------- stub S3
# §7.3 / §10.3: a local stub S3 that VERIFIES AWS Signature Version 4
# by recomputing the signature from the received headers and the known
# test secret, returning 401 on any mismatch.

def _hmac_sha256(key, msg):
    return hmac_mod.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _sigv4_signing_key(secret, datestamp, region, service):
    k_date = _hmac_sha256(("AWS4" + secret).encode("utf-8"), datestamp)
    k_region = hmac_mod.new(k_date, region.encode("utf-8"),
                            hashlib.sha256).digest()
    k_service = hmac_mod.new(k_region, service.encode("utf-8"),
                             hashlib.sha256).digest()
    return hmac_mod.new(k_service, b"aws4_request",
                        hashlib.sha256).digest()


def verify_sigv4(method, raw_target, headers, body, secret,
                 expected_access_key):
    """headers: an email.message-like mapping (case-insensitive .get).
    Returns True iff the Authorization signature recomputes exactly.
    A few canonicalisation variants are tried (raw vs re-quoted URI,
    header payload-hash vs computed hash vs UNSIGNED-PAYLOAD) because
    §7.3 fixes the ALGORITHM, not those encoder choices; the signing
    key chain and string-to-sign are always recomputed for real."""
    auth = headers.get("Authorization") or ""
    m = re.match(r"AWS4-HMAC-SHA256\s+(.*)", auth)
    if not m:
        return False
    fields = {}
    for part in m.group(1).split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            fields[k.strip()] = v.strip()
    credential = fields.get("Credential", "")
    signed_headers = [h.strip().lower()
                      for h in fields.get("SignedHeaders", "").split(";")
                      if h.strip()]
    signature = fields.get("Signature", "")
    cred_parts = credential.split("/")
    if len(cred_parts) != 5 or cred_parts[0] != expected_access_key:
        return False
    _, datestamp, region, service, _ = cred_parts

    amz_date = headers.get("x-amz-date") or headers.get("X-Amz-Date")
    if not amz_date:
        date_hdr = headers.get("Date")
        if date_hdr:
            try:
                dt = parsedate_to_datetime(date_hdr)
                amz_date = dt.strftime("%Y%m%dT%H%M%SZ")
            except Exception:
                return False
    if not amz_date:
        return False

    split = urllib.parse.urlsplit(raw_target)
    raw_path = split.path or "/"
    query_pairs = urllib.parse.parse_qsl(split.query, keep_blank_values=True)

    def canonical_query():
        enc = [(urllib.parse.quote(k, safe="-_.~"),
                urllib.parse.quote(v, safe="-_.~")) for k, v in query_pairs]
        enc.sort()
        return "&".join("%s=%s" % kv for kv in enc)

    def header_value(name):
        if name == "host":
            return (headers.get("Host") or "").strip()
        return (headers.get(name) or "").strip()

    canon_headers = "".join("%s:%s\n" % (h, re.sub(r"\s+", " ",
                                                   header_value(h)))
                            for h in signed_headers)
    payload_candidates = []
    hdr_hash = headers.get("x-amz-content-sha256") \
        or headers.get("X-Amz-Content-Sha256")
    if hdr_hash:
        payload_candidates.append(hdr_hash.strip())
    payload_candidates.append(hashlib.sha256(body).hexdigest())
    payload_candidates.append("UNSIGNED-PAYLOAD")

    uri_candidates = [raw_path,
                      urllib.parse.quote(
                          urllib.parse.unquote(raw_path), safe="/-_.~"),
                      urllib.parse.quote(raw_path, safe="/-_.~%")]
    scope = "%s/%s/%s/aws4_request" % (datestamp, region, service)
    for uri in dict.fromkeys(uri_candidates):
        for payload_hash in dict.fromkeys(payload_candidates):
            canon_req = "\n".join([method, uri, canonical_query(),
                                   canon_headers,
                                   ";".join(signed_headers), payload_hash])
            string_to_sign = "\n".join([
                "AWS4-HMAC-SHA256", amz_date, scope,
                hashlib.sha256(canon_req.encode("utf-8")).hexdigest()])
            key = _sigv4_signing_key(secret, datestamp, region, service)
            computed = hmac_mod.new(key, string_to_sign.encode("utf-8"),
                                    hashlib.sha256).hexdigest()
            if hmac_mod.compare_digest(computed, signature):
                return True
    return False


class StubS3(object):
    def __init__(self, secret, access_key):
        self.secret = secret
        self.access_key = access_key
        self.store = {}            # (bucket, key) -> bytes
        self.seen = []             # (method, path) for every request
        self.auth_failures = 0
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _split(self):
                parts = urllib.parse.urlsplit(self.path)
                segs = [urllib.parse.unquote(s) for s in
                        parts.path.lstrip("/").split("/", 1)]
                bucket = segs[0] if segs else ""
                key = segs[1] if len(segs) > 1 else ""
                return bucket, key

            def _xml(self, code, body, extra=None):
                payload = body.encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/xml")
                self.send_header("Content-Length", str(len(payload)))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(payload)

            def _check(self, body=b""):
                outer.seen.append((self.command, self.path))
                if not verify_sigv4(self.command, self.path, self.headers,
                                    body, outer.secret, outer.access_key):
                    outer.auth_failures += 1
                    self._xml(401, "<Error><Code>SignatureDoesNotMatch"
                                   "</Code></Error>")
                    return False
                return True

            def do_PUT(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                if not self._check(body):
                    return
                bucket, key = self._split()
                outer.store[(bucket, key)] = body
                etag = '"%s"' % hashlib.md5(body).hexdigest()
                self._xml(200, "", extra={"ETag": etag})

            def do_GET(self):
                if not self._check():
                    return
                bucket, key = self._split()
                if (bucket, key) not in outer.store:
                    self._xml(404, "<Error><Code>NoSuchKey</Code></Error>")
                    return
                body = outer.store[(bucket, key)]
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("ETag", '"%s"' % hashlib.md5(body).hexdigest())
                self.end_headers()
                self.wfile.write(body)

            def do_HEAD(self):
                if not self._check():
                    return
                bucket, key = self._split()
                if (bucket, key) not in outer.store:
                    self._xml(404, "<Error><Code>NoSuchKey</Code></Error>")
                    return
                body = outer.store[(bucket, key)]
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()

            def do_DELETE(self):
                if not self._check():
                    return
                bucket, key = self._split()
                outer.store.pop((bucket, key), None)
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
                                                      Handler)
        self.port = self.server.server_address[1]
        self.endpoint = "http://127.0.0.1:%d" % self.port
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        try:
            self.server.shutdown()
            self.server.server_close()
        except Exception:
            pass


# ---------------------------------------------------------- api helpers

def do_login(client, tenant_slug, username, password):
    r = client.post("/v1/auth/login",
                    json_body={"tenant": tenant_slug, "username": username,
                               "password": password})
    token = extract_token(r) if r.status == 200 else None
    if token:
        note_secret(token)
    return r, token


def make_tenant(ctx, client, operator_token, slug, display):
    r = client.post("/v1/tenants", token=operator_token,
                    json_body={"slug": slug, "display_name": display})
    return r


def make_login(ctx, client, token, tid, username, display, role, password):
    note_secret(password)
    r = client.post("/v1/tenants/%s/logins" % tid, token=token,
                    json_body={"username": username,
                               "display_name": display, "role": role,
                               "password": password})
    return r


def create_bucket(client, token, name, backend_id=None):
    """POST /v1/buckets. §8: create binds a backend (default first
    active). Only 400/422 responses trigger a payload-shape retry —
    a 201 or a 409 is a real answer and is returned untouched."""
    payloads = []
    if backend_id is not None:
        payloads.append({"name": name, "backend_id": backend_id})
        payloads.append({"name": name, "backend": backend_id})
    payloads.append({"name": name})
    last = None
    for payload in payloads:
        last = client.post("/v1/buckets", token=token, json_body=payload)
        if last.status not in (400, 422):
            return last
    return last


def create_backend(client, token, name, kind, endpoint=None, region=None,
                   bucket=None, access_key_id=None, secret_ref=None):
    """POST /v1/backends. Ambiguity (§4 vs §8): S3 config may ride in
    `config_json` as an object, as a JSON string, under `config`, or
    as flat fields. Try the documented shapes in order; only a
    400/422 (shape rejected) advances to the next shape."""
    config = {}
    if endpoint:
        config["endpoint"] = endpoint
    if region:
        config["region"] = region
    if bucket:
        config["bucket"] = bucket
    if access_key_id:
        config["access_key_id"] = access_key_id
    variants = []
    base = {"name": name, "kind": kind}
    if secret_ref:
        base["secret_ref"] = secret_ref
    # `config` (object) first: a lenient handler may accept-and-ignore
    # a `config_json` OBJECT (storing "{}") with a 201, which would
    # silently strand the endpoint — so the shape most likely to be
    # honoured goes first, and string/flat forms are the fallbacks.
    v = dict(base); v["config"] = config; variants.append(v)
    v = dict(base); v["config_json"] = json.dumps(config); variants.append(v)
    v = dict(base); v["config_json"] = config; variants.append(v)
    v = dict(base); v.update(config); variants.append(v)
    last = None
    for payload in variants:
        last = client.post("/v1/backends", token=token, json_body=payload)
        if last.status not in (400, 422):
            return last
    return last


def raw_head(client, path, token=None):
    """HEAD via a raw socket. §8 says HEAD returns the metadata JSON,
    but urllib/http.client discards HEAD response bodies by protocol,
    so the metadata can only be observed on the wire this way.
    Returns (status, headers_dict, body_bytes)."""
    parts = urllib.parse.urlsplit(client.base_url)
    host, port = parts.hostname, parts.port
    lines = ["HEAD %s HTTP/1.1" % path, "Host: %s:%d" % (host, port),
             "Connection: close"]
    if token:
        lines.append("Authorization: Bearer " + token)
    request = ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8")
    raw = b""
    with socket.create_connection((host, port), timeout=HTTP_TIMEOUT) as s:
        s.sendall(request)
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            raw += chunk
    head, _, body = raw.partition(b"\r\n\r\n")
    head_lines = head.decode("iso-8859-1").split("\r\n")
    status = int(head_lines[0].split()[1]) if head_lines else 0
    headers = {}
    for line in head_lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return status, headers, body


def head_metadata(client, path, token=None):
    """Parsed metadata-JSON data object from a raw HEAD, or {}."""
    try:
        status, headers, body = raw_head(client, path, token)
        parsed = json.loads(body.decode("utf-8")) if body else None
        if isinstance(parsed, dict):
            d = parsed.get("data") if "data" in parsed else parsed
            if isinstance(d, dict):
                return status, headers, d
        return status, headers, {}
    except Exception:
        return 0, {}, {}


def object_url(bucket, key):
    return "/v1/buckets/%s/objects/%s" % (seg(bucket), key_path(key))


def put_object(client, token, bucket, key, body, content_type=None,
               headers=None):
    return client.put(object_url(bucket, key), token=token, raw_body=body,
                      headers=headers, content_type=content_type)


def get_object(client, token, bucket, key):
    return client.get(object_url(bucket, key), token=token)


def list_objects(client, token, bucket, params=None):
    path = "/v1/buckets/%s/objects" % seg(bucket)
    if params:
        path += qs(params)
    return client.get(path, token=token)


def object_row(client, token, bucket, key):
    r = list_objects(client, token, bucket, {"limit": 200})
    for row in rows_of(r):
        if isinstance(row, dict) and row.get("key") == key:
            return row
    return None


def metadata_of_row(row):
    if not isinstance(row, dict):
        return None
    raw = row.get("metadata_json", row.get("metadata"))
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            v = json.loads(raw)
            return v if isinstance(v, dict) else None
        except Exception:
            return None
    return None


def usage_bytes(client, token, tid):
    """GET usage (§8: 'quota vs used, per bucket'). Field names are
    not spelled out in the design; accept the common spellings, or
    sum the per-bucket figures when a bucket list is present."""
    r = client.get("/v1/tenants/%s/usage" % tid, token=token)
    if r.status != 200:
        return None, r
    return extract_usage_bytes(data_of(r)), r


def extract_usage_bytes(d):
    if isinstance(d, dict):
        for k in ("used_bytes", "total_bytes", "usage_bytes",
                  "bytes_used", "used", "bytes"):
            v = d.get(k)
            if isinstance(v, int):
                return v
        for k in ("buckets", "per_bucket"):
            rows = d.get(k)
            if isinstance(rows, list) and rows:
                total, ok = 0, False
                for row in rows:
                    if isinstance(row, dict):
                        for kk in ("total_bytes", "used_bytes",
                                   "bytes_used", "bytes"):
                            if isinstance(row.get(kk), int):
                                total += row[kk]
                                ok = True
                                break
                if ok:
                    return total
        for k in ("usage", "totals", "used_detail"):
            v = extract_usage_bytes(d.get(k))
            if v is not None:
                return v
    return None


def usage_quota_bytes(d):
    if isinstance(d, dict):
        for k in ("quota_bytes", "quota", "byte_quota"):
            v = d.get(k)
            if isinstance(v, int):
                return v
        v = dig(d, ("quota_bytes",))
        return v if isinstance(v, int) else None
    return None


def collect_audit(client, token, params_extra=None):
    rows, cursor = [], None
    for _ in range(25):
        params = {"limit": 200}
        if params_extra:
            params.update(params_extra)
        if cursor:
            params["cursor"] = cursor
        r = client.get("/v1/audit" + qs(params), token=token)
        if os.environ.get("SNOWFELL_SUITE_DEBUG"):
            print("DEBUG audit page: status=%s bytes=%d body=%s"
                  % (r.status, len(r.body), r.text()[:400]), flush=True)
            if r.json is None and r.body:
                try:
                    json.loads(r.body.decode("utf-8"))
                except Exception as e:
                    pos = getattr(e, "pos", 0) or 0
                    print("DEBUG audit parse error: %r at %d: %r"
                          % (e, pos, r.body[max(0, pos - 100):pos + 100]),
                          flush=True)
        if r.status != 200:
            return rows, r
        rows.extend(rows_of(r))
        cursor = next_cursor(r)
        if not cursor:
            break
    return rows, r


def audit_detail_text(row):
    if isinstance(row, dict):
        d = row.get("detail_json", row.get("detail"))
        if isinstance(d, str):
            return d
        if d is not None:
            return json.dumps(d)
    return ""


class Ctx(object):
    pass


# ================================================================= A–F

def group_a(ctx):
    C, cl, inst = ctx.cases, ctx.client, ctx.inst1
    r = cl.get("/v1/health")
    d = data_of(r)
    shape_ok = r.status == 200 and isinstance(d, dict) and sum(
        1 for k in ("version", "uptime", "uptime_seconds", "bind",
                    "bind_address", "tenants", "tenant_count",
                    "counts") if k in d) >= 2
    C.case("A", "GET /v1/health 200 with version/uptime/bind/count shape",
           shape_ok, "status=%s body=%s" % (r.status, r.text()[:300]))

    boot = os.path.join(inst.dir, "bootstrap-operator-token.txt")
    exists = os.path.isfile(boot)
    mode_ok = exists and stat.S_IMODE(os.stat(boot).st_mode) == 0o600
    C.case("A", "bootstrap operator token file exists with mode 0600 (§5.5)",
           bool(mode_ok),
           "exists=%s mode=%s" % (exists,
                                  oct(stat.S_IMODE(os.stat(boot).st_mode))
                                  if exists else None))

    # First successful operator authentication (§5.5: the service
    # deletes the bootstrap file on that first operator call).
    r = cl.get("/v1/tenants", token=inst.operator_token)
    C.case("A", "first operator call with bootstrap token succeeds",
           r.status == 200, "status=%s body=%s" % (r.status, r.text()[:300]))
    gone, deadline = False, time.time() + 5
    while time.time() < deadline:
        if not os.path.exists(boot):
            gone = True
            break
        time.sleep(0.05)
    C.case("A", "bootstrap file is gone after first operator call (§5.5)",
           gone)


def group_b(ctx):
    C, cl, op = ctx.cases, ctx.client, ctx.op
    created = []
    for slug, display in (("alpha", "Alpha Tenant"),
                          ("beta", "Beta Tenant"),
                          ("gamma", "Gamma Tenant")):
        r = make_tenant(ctx, cl, op, slug, display)
        d = data_of(r) if isinstance(data_of(r), dict) else {}
        ok = r.status == 201 and d.get("slug") == slug \
            and row_id(d) is not None
        if ok:
            created.append(d)
        if slug == "alpha":
            C.case("B", "create tenant 201 with slug echoed", ok,
                   "status=%s body=%s" % (r.status, r.text()[:300]))
    ctx.tenant_a, ctx.tenant_b = created[0], created[1]
    ctx.tid_a, ctx.tid_b = row_id(created[0]), row_id(created[1])
    C.case("B", "three tenants created for pagination (ids assigned)",
           len(created) == 3, "created=%d" % len(created))

    r = make_tenant(ctx, cl, op, "alpha", "Alpha Again")
    C.case("B", "duplicate slug refused 409",
           r.status == 409, "status=%s body=%s" % (r.status, r.text()[:200]))

    r1 = cl.get("/v1/tenants" + qs({"limit": 2}), token=op)
    page1 = rows_of(r1)
    cur = next_cursor(r1)
    C.case("B", "list pagination page 1: limit=2 returns 2 + next_cursor",
           r1.status == 200 and len(page1) == 2 and cur is not None,
           "status=%s rows=%d cursor=%r" % (r1.status, len(page1), cur))
    r2 = cl.get("/v1/tenants" + qs({"limit": 2, "cursor": cur}), token=op)
    page2 = rows_of(r2)
    ids1 = {row_id(x) for x in page1}
    ids2 = {row_id(x) for x in page2}
    C.case("B", "list pagination page 2 returns remaining tenant(s), no overlap",
           r2.status == 200 and len(page2) >= 1 and not (ids1 & ids2),
           "status=%s rows=%d" % (r2.status, len(page2)))

    r = cl.get("/v1/tenants/%s" % ctx.tid_a, token=op)
    d = data_of(r)
    C.case("B", "get tenant by id returns the tenant",
           r.status == 200 and isinstance(d, dict)
           and d.get("slug") == "alpha",
           "status=%s body=%s" % (r.status, r.text()[:200]))

    r = cl.patch("/v1/tenants/%s" % ctx.tid_a, token=op,
                 json_body={"display_name": "Alpha Renamed"})
    d = data_of(r)
    r2 = cl.get("/v1/tenants/%s" % ctx.tid_a, token=op)
    d2 = data_of(r2)
    name_now = (d2 or {}).get("display_name") if isinstance(d2, dict) else None
    C.case("B", "PATCH display name takes effect",
           r.status in (200, 204) and name_now == "Alpha Renamed",
           "patch=%s name=%r" % (r.status, name_now))
    ctx.alpha_display = "Alpha Renamed"

    r = cl.put("/v1/tenants/%s/quota" % ctx.tid_a, token=op,
               json_body={"quota_bytes": 1073741824,
                          "quota_objects": 1000, "quota_buckets": 50})
    used, ru = usage_bytes(cl, op, ctx.tid_a)
    quota_seen = usage_quota_bytes(data_of(ru)) if ru.status == 200 else None
    shape_ok = ru.status == 200 and isinstance(data_of(ru), dict) \
        and used is not None
    C.case("B", "quota PUT accepted; usage GET has quota-vs-used shape",
           r.status in (200, 204) and shape_ok
           and (quota_seen in (None, 1073741824)),
           "quota_put=%s usage_status=%s used=%r quota=%r"
           % (r.status, ru.status, used, quota_seen))


def group_c(ctx):
    C, cl, op = ctx.cases, ctx.client, ctx.op
    ctx.pw_admin_a = new_password("adminA")
    ctx.pw_user_a = new_password("userA")
    ctx.pw_boss_b = new_password("bossB")

    r = make_login(ctx, cl, op, ctx.tid_a, "admina", "Admin A",
                   "tenant_admin", ctx.pw_admin_a)
    ctx.admin_a = data_of(r) if isinstance(data_of(r), dict) else {}
    ctx.admin_a_id = row_id(ctx.admin_a)
    C.case("C", "create admin login in tenant A 201",
           r.status == 201 and ctx.admin_a_id is not None,
           "status=%s body=%s" % (r.status, r.text()[:300]))

    r = make_login(ctx, cl, op, ctx.tid_a, "usera", "User A",
                   "tenant_user", ctx.pw_user_a)
    ctx.user_a = data_of(r) if isinstance(data_of(r), dict) else {}
    ctx.user_a_id = row_id(ctx.user_a)
    C.case("C", "create user login in tenant A 201",
           r.status == 201 and ctx.user_a_id is not None,
           "status=%s body=%s" % (r.status, r.text()[:300]))

    r = make_login(ctx, cl, op, ctx.tid_a, "usera", "Duplicate",
                   "tenant_user", new_password("dup"))
    C.case("C", "duplicate username in same tenant refused 409",
           r.status == 409, "status=%s" % r.status)

    # Names are per-tenant (§4 UNIQUE(tenant_id, username)): the same
    # username in tenant B succeeds — and serves as B's admin.
    r = make_login(ctx, cl, op, ctx.tid_b, "usera", "User A of B",
                   "tenant_admin", ctx.pw_boss_b)
    ctx.boss_b = data_of(r) if isinstance(data_of(r), dict) else {}
    ctx.boss_b_id = row_id(ctx.boss_b)
    C.case("C", "same username in tenant B created 201 (per-tenant names)",
           r.status == 201 and ctx.boss_b_id is not None
           and ctx.boss_b_id != ctx.user_a_id,
           "status=%s body=%s" % (r.status, r.text()[:300]))

    ra = cl.get("/v1/tenants/%s/logins" % ctx.tid_a + qs({"limit": 200}),
                token=op)
    rows_a = rows_of(ra)
    scoped = all(row_id(x) != ctx.boss_b_id for x in rows_a) and all(
        (not isinstance(x, dict)) or x.get("tenant_id") in (None, ctx.tid_a)
        for x in rows_a)
    C.case("C", "login list for A is scoped: no B rows",
           ra.status == 200 and len(rows_a) >= 2 and scoped,
           "status=%s rows=%s" % (ra.status, r.text()[:300]))

    # Last-admin guard (§5.2) BEFORE any promotion: admina is A's only
    # active admin at this point.
    r = cl.delete("/v1/tenants/%s/logins/%s" % (ctx.tid_a, ctx.admin_a_id),
                  token=op)
    C.case("C", "deleting the tenant's last active admin refused 409 (§5.2)",
           r.status == 409, "status=%s body=%s" % (r.status, r.text()[:200]))

    r = cl.patch("/v1/tenants/%s/logins/%s" % (ctx.tid_a, ctx.user_a_id),
                 token=op, json_body={"role": "tenant_admin"})
    r2 = cl.get("/v1/tenants/%s/logins/%s" % (ctx.tid_a, ctx.user_a_id),
                token=op)
    role_now = (data_of(r2) or {}).get("role") if r2.status == 200 else None
    # Restore the fixture: later groups rely on usera being a plain user
    # only for role display, never for permission shape. Keep the
    # promotion (harmless) but record the observed value first.
    C.case("C", "PATCH role takes effect",
           r.status in (200, 204) and role_now == "tenant_admin",
           "patch=%s role=%r" % (r.status, role_now))

    pw_temp = new_password("temp")
    r = make_login(ctx, cl, op, ctx.tid_a, "tempuser", "Temp",
                   "tenant_user", pw_temp)
    temp_id = row_id(data_of(r) or {})
    cl.patch("/v1/tenants/%s/logins/%s" % (ctx.tid_a, temp_id), token=op,
             json_body={"state": "disabled"})
    rl, _ = do_login(cl, "alpha", "tempuser", pw_temp)
    C.case("C", "disabled login can no longer authenticate",
           temp_id is not None and rl.status in (401, 403),
           "login_status=%s body=%s" % (rl.status, rl.text()[:200]))

    # Cached sessions for later groups (kept under the §5.3 login
    # rate limits by reuse rather than repeated logins).
    _, ctx.admin_a_token = do_login(cl, "alpha", "admina", ctx.pw_admin_a)
    _, ctx.boss_b_token = do_login(cl, "beta", "usera", ctx.pw_boss_b)
    C.case("C", "tenant admins can log in (sessions cached for later groups)",
           bool(ctx.admin_a_token) and bool(ctx.boss_b_token))


def group_d(ctx):
    C, cl, op = ctx.cases, ctx.client, ctx.op

    # Unknown user: same 401 + same body shape as a wrong password
    # (§5.3 — no account-existence oracle).
    r_unknown, _ = do_login(cl, "alpha", "no-such-user", new_password("x"))
    shape_unknown = (r_unknown.status, sorted(err_of(r_unknown).keys()),
                     err_code(r_unknown))

    pw_victim = new_password("victim")
    r = make_login(ctx, cl, op, ctx.tid_a, "victim", "Victim",
                   "tenant_user", pw_victim)
    victim_id = row_id(data_of(r) or {})

    wrong_shapes, all_401 = [], True
    for _ in range(5):
        rw, _ = do_login(cl, "alpha", "victim", new_password("wrong"))
        wrong_shapes.append((rw.status, sorted(err_of(rw).keys()),
                             err_code(rw)))
        all_401 = all_401 and rw.status == 401 \
            and err_code(rw) == "invalid_credentials"
    C.case("D", "wrong password x5 each 401 invalid_credentials (§5.3)",
           all_401, "shapes=%s" % (wrong_shapes[:1],))
    C.case("D", "unknown user 401 with identical body shape (no oracle)",
           shape_unknown == wrong_shapes[0] if wrong_shapes else False,
           "unknown=%s wrong=%s" % (shape_unknown, wrong_shapes[:1]))

    r6, _ = do_login(cl, "alpha", "victim", pw_victim)
    C.case("D", "6th attempt (correct password) refused 429 account_locked",
           r6.status == 429 and err_code(r6) == "account_locked",
           "status=%s code=%s" % (r6.status, err_code(r6)))

    # ---- password reset (§5.4) ----
    pw_old = new_password("resetold")
    pw_new = new_password("resetnew")
    r = make_login(ctx, cl, op, ctx.tid_a, "resetter", "Resetter",
                   "tenant_user", pw_old)
    resetter_id = row_id(data_of(r) or {})
    ri = cl.post("/v1/tenants/%s/logins/%s/password-resets"
                 % (ctx.tid_a, resetter_id), token=ctx.admin_a_token,
                 json_body={})
    reset_token = extract_token(ri)
    if reset_token:
        note_secret(reset_token)
    C.case("D", "admin issues a password reset; token returned once (§5.4)",
           ri.status in (200, 201) and bool(reset_token)
           and resetter_id is not None,
           "status=%s body=%s" % (ri.status, ri.text()[:200]))

    rw = cl.post("/v1/auth/password-reset/complete",
                 json_body={"token": "wrong-" + secrets_mod.token_hex(8),
                            "new_password": pw_new})
    C.case("D", "reset completion with wrong token refused 401",
           rw.status == 401, "status=%s" % rw.status)

    rc = cl.post("/v1/auth/password-reset/complete",
                 json_body={"token": reset_token, "new_password": pw_new})
    C.case("D", "reset completion with the right token succeeds 200",
           rc.status == 200, "status=%s body=%s" % (rc.status, rc.text()[:200]))

    ro, _ = do_login(cl, "alpha", "resetter", pw_old)
    rn, _ = do_login(cl, "alpha", "resetter", pw_new)
    C.case("D", "after reset: old password dead, new password works",
           ro.status == 401 and rn.status == 200,
           "old=%s new=%s" % (ro.status, rn.status))

    rr = cl.post("/v1/auth/password-reset/complete",
                 json_body={"token": reset_token,
                            "new_password": new_password("replay")})
    C.case("D", "replaying the same reset token refused 401 (single-use)",
           rr.status == 401, "status=%s" % rr.status)

    # ---- session me / logout ----
    _, sess = do_login(cl, "alpha", "usera", ctx.pw_user_a)
    rm = cl.get("/v1/auth/me", token=sess)
    dm = data_of(rm)
    me_ok = rm.status == 200 and isinstance(dm, dict) and bool(
        dig(dm, ("username", "login", "role", "tenant_id", "tenant")))
    C.case("D", "GET /v1/auth/me returns the caller's login/tenant/role",
           me_ok, "status=%s body=%s" % (rm.status, rm.text()[:300]))
    rl_out = cl.post("/v1/auth/logout", token=sess, json_body={})
    rm2 = cl.get("/v1/auth/me", token=sess)
    C.case("D", "after logout the session token is dead (me -> 401)",
           rl_out.status in (200, 204) and rm2.status == 401,
           "logout=%s me_after=%s" % (rl_out.status, rm2.status))

    # ---- API tokens (§5.3) ----
    rmint = cl.post("/v1/auth/tokens", token=ctx.admin_a_token,
                    json_body={"label": "suite-token"})
    api_token = extract_token(rmint)
    if api_token:
        note_secret(api_token)
    d_mint = data_of(rmint) if isinstance(data_of(rmint), dict) else {}
    api_id = d_mint.get("id") or d_mint.get("token_id") \
        or dig(d_mint, ("token_id",))
    C.case("D", "API token mint returns plaintext once + token id",
           rmint.status in (200, 201) and bool(api_token)
           and api_id is not None,
           "status=%s body=%s" % (rmint.status, rmint.text()[:200]))

    rme = cl.get("/v1/auth/me", token=api_token)
    C.case("D", "minted API token authenticates",
           rme.status == 200, "status=%s" % rme.status)

    rlist = cl.get("/v1/auth/tokens", token=ctx.admin_a_token)
    leak = api_token and api_token in rlist.text()
    digest_leak = any(k in rlist.text() for k in
                      ("token_sha256", "sha256", "password_hash",
                       "password_salt"))
    C.case("D", "API token list shows id/label only — no secret material",
           rlist.status == 200 and not leak and not digest_leak
           and len(rows_of(rlist)) >= 1,
           "status=%s leak=%s digest_leak=%s"
           % (rlist.status, bool(leak), digest_leak))

    # A second API token that must survive the group-J restart.
    rpersist = cl.post("/v1/auth/tokens", token=ctx.admin_a_token,
                       json_body={"label": "persist-token"})
    ctx.persist_api_token = extract_token(rpersist)
    if ctx.persist_api_token:
        note_secret(ctx.persist_api_token)

    rd = cl.delete("/v1/auth/tokens/%s" % api_id, token=ctx.admin_a_token)
    rme2 = cl.get("/v1/auth/me", token=api_token)
    C.case("D", "revoked API token is refused 401",
           rd.status in (200, 204) and rme2.status == 401,
           "revoke=%s me_after=%s" % (rd.status, rme2.status))
    C.case("D", "persistence API token minted for group J",
           bool(ctx.persist_api_token), "status=%s" % rpersist.status)


def group_e(ctx):
    C, cl = ctx.cases, ctx.client
    a_tok, b_tok = ctx.admin_a_token, ctx.boss_b_token
    ctx.a_objects = {}   # (bucket, key) -> size, tenant A books

    def a_put(bucket, key, body, **kw):
        r = put_object(cl, a_tok, bucket, key, body, **kw)
        if r.status in (200, 201):
            ctx.a_objects[(bucket, key)] = len(body)
        return r

    r = create_bucket(cl, a_tok, "shared")
    ctx.bucket_a_shared = row_id(data_of(r) or {})
    C.case("E", "create bucket in tenant A 201",
           r.status == 201 and ctx.bucket_a_shared is not None,
           "status=%s body=%s" % (r.status, r.text()[:300]))
    r = create_bucket(cl, a_tok, "shared")
    C.case("E", "duplicate bucket name in same tenant refused 409",
           r.status == 409, "status=%s" % r.status)
    r = create_bucket(cl, b_tok, "shared")
    ctx.bucket_b_shared = row_id(data_of(r) or {})
    C.case("E", "same bucket name in other tenant created 201",
           r.status == 201 and ctx.bucket_b_shared is not None
           and ctx.bucket_b_shared != ctx.bucket_a_shared,
           "status=%s body=%s" % (r.status, r.text()[:300]))
    create_bucket(cl, a_tok, "alpha-only")

    payload = bytes(range(256)) * 4 + b"snowfell-a"
    r = a_put("shared", "dir/hello.txt", payload,
              content_type="text/plain")
    C.case("E", "PUT object (new key) 201",
           r.status == 201, "status=%s body=%s" % (r.status, r.text()[:200]))
    rg = get_object(cl, a_tok, "shared", "dir/hello.txt")
    sha = hashlib.sha256(payload).hexdigest()
    C.case("E", "GET round-trips bytes exactly; X-Snowfell-SHA256 matches hashlib",
           rg.status == 200 and rg.body == payload
           and rg.headers.get("x-snowfell-sha256") == sha,
           "status=%s len=%d header=%s sha=%s"
           % (rg.status, len(rg.body), rg.headers.get("x-snowfell-sha256"),
              sha))

    payload2 = b"replacement-bytes-for-hello"
    r = a_put("shared", "dir/hello.txt", payload2,
              content_type="text/plain")
    used, _ = usage_bytes(cl, ctx.op, ctx.tid_a)
    expected = sum(ctx.a_objects.values())
    C.case("E", "PUT same key replaces; usage reflects only the new size",
           r.status in (200, 201)
           and get_object(cl, a_tok, "shared", "dir/hello.txt").body == payload2
           and used == expected,
           "status=%s used=%r expected=%r" % (r.status, used, expected))

    a_put("shared", "prefix-a/1.txt", b"pa1")
    a_put("shared", "prefix-a/2.txt", b"pa2")
    a_put("shared", "prefix-b/1.txt", b"pb1")
    rl = list_objects(cl, a_tok, "shared", {"prefix": "prefix-a/"})
    keys = sorted(x.get("key") for x in rows_of(rl)
                  if isinstance(x, dict))
    C.case("E", "object list with prefix filter returns only matching keys",
           rl.status == 200
           and keys == ["prefix-a/1.txt", "prefix-a/2.txt"],
           "status=%s keys=%s" % (rl.status, keys))

    # §8: HEAD = metadata JSON. Read it off the wire (raw_head);
    # accept the header-carried form as an equivalent presentation.
    h_status, h_headers, h_data = head_metadata(
        cl, object_url("shared", "dir/hello.txt"), token=a_tok)
    sha2 = hashlib.sha256(payload2).hexdigest()
    head_ok = h_status == 200 and (
        (h_data.get("key") == "dir/hello.txt"
         and h_data.get("size_bytes") == len(payload2)
         and h_data.get("sha256") == sha2)
        or (h_headers.get("x-snowfell-sha256") == sha2
            and h_headers.get("content-length") == str(len(payload2))))
    C.case("E", "HEAD returns object metadata JSON (key, size_bytes, sha256) (§8)",
           head_ok, "status=%s data=%s headers=%s"
           % (h_status, h_data,
              {k: v for k, v in h_headers.items() if "snowfell" in k}))

    # Metadata round-trip. Ambiguity (see module docstring): §8 does
    # not name the PUT wire encoding for metadata_json, so probe the
    # plausible encodings and verify via the object list / HEAD.
    meta = {"purpose": "sf-t12g", "seq": 7}
    meta_json = json.dumps(meta)
    transports = [
        ("header X-Snowfell-Metadata",
         {"headers": {"X-Snowfell-Metadata": meta_json}}),
        ("header X-Snowfell-Metadata-Json",
         {"headers": {"X-Snowfell-Metadata-Json": meta_json}}),
        ("query metadata_json", None),
    ]
    meta_ok = False
    for label, kw in transports:
        if kw is None:
            url = object_url("shared", "meta.bin") + \
                qs({"metadata_json": meta_json})
            r = cl.put(url, token=a_tok, raw_body=b"meta-bytes")
        else:
            r = put_object(cl, a_tok, "shared", "meta.bin", b"meta-bytes",
                           **kw)
        if r.status in (200, 201):
            ctx.a_objects[("shared", "meta.bin")] = len(b"meta-bytes")
            got = metadata_of_row(object_row(cl, a_tok, "shared", "meta.bin"))
            if got == meta:
                meta_ok = True
                break
            _, _, h_meta = head_metadata(
                cl, object_url("shared", "meta.bin"), token=a_tok)
            if h_meta.get("metadata") == meta \
                    or h_meta.get("metadata_json") == meta:
                meta_ok = True
                break
            rh2 = cl.head(object_url("shared", "meta.bin"), token=a_tok)
            hdr = rh2.headers.get("x-snowfell-metadata") or \
                rh2.headers.get("x-snowfell-metadata-json")
            if hdr:
                try:
                    if json.loads(hdr) == meta:
                        meta_ok = True
                        break
                except Exception:
                    pass
    C.case("E", "metadata_json round-trips (stored + returned intact)",
           meta_ok)

    a_put("shared", "to-delete.txt", b"gone-soon")
    rd = cl.delete(object_url("shared", "to-delete.txt"), token=a_tok)
    if rd.status in (200, 204):
        ctx.a_objects.pop(("shared", "to-delete.txt"), None)
    rg2 = get_object(cl, a_tok, "shared", "to-delete.txt")
    C.case("E", "DELETE object then GET returns 404",
           rd.status in (200, 204) and rg2.status == 404,
           "delete=%s get=%s" % (rd.status, rg2.status))

    # Key grammar (§7.2): each of these must be a 400.
    bad_keys = ["..", "../escape.txt", "/leading.txt", "a\\b.txt",
                "a//b.txt"]
    results = []
    for bad in bad_keys:
        url = "/v1/buckets/%s/objects/%s" % (
            seg("shared"), urllib.parse.quote(bad, safe="/"))
        rr = cl.put(url, token=a_tok, raw_body=b"x")
        results.append((bad, rr.status))
    C.case("E", "invalid keys (.. / leading / / backslash / //) each 400 invalid_key",
           all(s == 400 for _, s in results),
           "results=%s" % (results,))


def group_f(ctx):
    C, cl, op = ctx.cases, ctx.client, ctx.op
    a_tok = ctx.admin_a_token
    used_before, _ = usage_bytes(cl, op, ctx.tid_a)
    if used_before is None:
        used_before = sum(ctx.a_objects.values())
    headroom = 64
    quota = used_before + headroom
    r = cl.put("/v1/tenants/%s/quota" % ctx.tid_a, token=op,
               json_body={"quota_bytes": quota, "quota_objects": 100000,
                          "quota_buckets": 100})
    C.case("F", "operator sets tenant quota just above current usage",
           r.status in (200, 204), "status=%s" % r.status)

    fit = b"F" * headroom
    rfit = put_object(cl, a_tok, "shared", "quota-fit.bin", fit)
    if rfit.status in (200, 201):
        ctx.a_objects[("shared", "quota-fit.bin")] = len(fit)
    C.case("F", "PUT that fits the quota succeeds 201",
           rfit.status == 201, "status=%s body=%s"
           % (rfit.status, rfit.text()[:200]))

    big = b"B" * (headroom + 1)
    rover = put_object(cl, a_tok, "shared", "quota-over.bin", big)
    detail = err_of(rover).get("detail") or {}
    nums = [v for v in detail.values() if isinstance(v, (int, float))] \
        if isinstance(detail, dict) else []
    C.case("F", "PUT that exceeds quota refused 409 quota_exceeded with figures",
           rover.status == 409 and err_code(rover) == "quota_exceeded"
           and len(nums) >= 2,
           "status=%s code=%s detail=%s"
           % (rover.status, err_code(rover), detail))
    rg = get_object(cl, a_tok, "shared", "quota-over.bin")
    used_after, _ = usage_bytes(cl, op, ctx.tid_a)
    C.case("F", "denied PUT stored nothing; usage unchanged",
           rg.status == 404 and used_after == quota,
           "get=%s used_after=%r quota=%r" % (rg.status, used_after, quota))

    r = cl.delete("/v1/buckets/%s" % seg("shared"), token=a_tok)
    C.case("F", "deleting a non-empty bucket refused 409",
           r.status == 409, "status=%s" % r.status)
    create_bucket(cl, a_tok, "empty-bucket")
    r = cl.delete("/v1/buckets/%s" % seg("empty-bucket"), token=a_tok)
    rgone = cl.get("/v1/buckets/%s" % seg("empty-bucket"), token=a_tok)
    C.case("F", "deleting an empty bucket succeeds (204/200) and it is gone",
           r.status in (200, 204) and rgone.status == 404,
           "delete=%s get=%s" % (r.status, rgone.status))

    # Restore a generous quota for the remaining groups.
    cl.put("/v1/tenants/%s/quota" % ctx.tid_a, token=op,
           json_body={"quota_bytes": 10737418240,
                      "quota_objects": 100000, "quota_buckets": 100})


# ================================================================= G–J

def group_g(ctx):
    """The isolation battery (§3.2, §10.3): every probe is made with
    tenant B's admin token against tenant A's ids/names/keys, and the
    A-side state is re-read as A afterwards to prove it is untouched."""
    C, cl, op = ctx.cases, ctx.client, ctx.op
    a_tok, b_tok = ctx.admin_a_token, ctx.boss_b_token

    # Plant distinct bytes under the SAME key in the SAME bucket name.
    put_object(cl, a_tok, "shared", "shared.txt", b"AAAA-tenant-a-bytes")
    ctx.a_objects[("shared", "shared.txt")] = len(b"AAAA-tenant-a-bytes")
    put_object(cl, a_tok, "shared", "alpha-secret.txt", b"A-ONLY-SECRET")
    ctx.a_objects[("shared", "alpha-secret.txt")] = len(b"A-ONLY-SECRET")
    put_object(cl, b_tok, "shared", "shared.txt", b"BBBB-tenant-b-bytes")
    put_object(cl, a_tok, "alpha-only", "only-a.txt", b"alpha-only-object")
    ctx.a_objects[("alpha-only", "only-a.txt")] = len(b"alpha-only-object")

    def a_snapshot():
        rt = cl.get("/v1/tenants/%s" % ctx.tid_a, token=op)
        rl = cl.get("/v1/tenants/%s/logins" % ctx.tid_a
                    + qs({"limit": 200}), token=op)
        ro = list_objects(cl, a_tok, "alpha-only", {"limit": 200})
        rs = list_objects(cl, a_tok, "shared", {"limit": 200})
        return ((data_of(rt) or {}).get("display_name"),
                sorted(row_id(x) for x in rows_of(rl)),
                sorted(x.get("key") for x in rows_of(ro)
                       if isinstance(x, dict)),
                sorted(x.get("key") for x in rows_of(rs)
                       if isinstance(x, dict)))
    before = a_snapshot()

    r = cl.get("/v1/tenants/%s" % ctx.tid_a, token=b_tok)
    C.case("G", "B token GET tenant A by id -> 404 (indistinguishable)",
           r.status == 404, "status=%s" % r.status)
    r = cl.patch("/v1/tenants/%s" % ctx.tid_a, token=b_tok,
                 json_body={"display_name": "Pwned By B"})
    C.case("G", "B token PATCH tenant A -> 404",
           r.status == 404, "status=%s" % r.status)
    r = cl.delete("/v1/tenants/%s" % ctx.tid_a, token=b_tok)
    C.case("G", "B token DELETE (close) tenant A -> 404",
           r.status == 404, "status=%s" % r.status)
    r = cl.get("/v1/tenants/%s/logins" % ctx.tid_a
               + qs({"limit": 200}), token=b_tok)
    C.case("G", "B token list A's logins via A's tid -> 404",
           r.status == 404, "status=%s rows=%s"
           % (r.status, r.text()[:120]))
    r = cl.post("/v1/tenants/%s/logins" % ctx.tid_a, token=b_tok,
                json_body={"username": "intruder", "display_name": "X",
                           "role": "tenant_admin",
                           "password": new_password("intruder")})
    C.case("G", "B token create login under A's tid -> 404",
           r.status == 404, "status=%s" % r.status)
    r = cl.get("/v1/tenants/%s/usage" % ctx.tid_a, token=b_tok)
    C.case("G", "B token read A's usage -> 404",
           r.status == 404, "status=%s" % r.status)

    r = cl.get("/v1/buckets/%s" % seg("shared"), token=b_tok)
    d = data_of(r) if isinstance(data_of(r), dict) else {}
    C.case("G", "B GET bucket 'shared' returns B's own bucket, never A's",
           r.status == 200 and row_id(d) == ctx.bucket_b_shared
           and row_id(d) != ctx.bucket_a_shared,
           "status=%s id=%r" % (r.status, row_id(d)))

    r = get_object(cl, b_tok, "shared", "shared.txt")
    C.case("G", "B GET shared key returns B's bytes, never A's",
           r.status == 200 and r.body == b"BBBB-tenant-b-bytes",
           "status=%s body=%r" % (r.status, r.body[:32]))
    r = get_object(cl, b_tok, "shared", "alpha-secret.txt")
    C.case("G", "B GET A-only key in shared bucket name -> 404",
           r.status == 404 and b"A-ONLY-SECRET" not in r.body,
           "status=%s" % r.status)

    r = put_object(cl, b_tok, "alpha-only", "only-a.txt",
                   b"B-WRITE-ATTEMPT")
    after_put = a_snapshot()
    a_bytes = get_object(cl, a_tok, "alpha-only", "only-a.txt")
    C.case("G", "B PUT into A-only bucket name writes only B's own (or 404); A's object untouched",
           r.status in (200, 201, 404)
           and a_bytes.body == b"alpha-only-object"
           and after_put == before,
           "status=%s a_body=%r" % (r.status, a_bytes.body[:32]))

    rows, rr = collect_audit(cl, b_tok)
    a_rows = [x for x in rows if isinstance(x, dict)
              and x.get("tenant_id") == ctx.tid_a]
    C.case("G", "audit list as B contains zero A-tenant rows",
           rr.status == 200 and not a_rows,
           "status=%s a_rows=%d total=%d" % (rr.status, len(a_rows),
                                             len(rows)))

    after = a_snapshot()
    C.case("G", "tenant A state fully untouched after the battery (re-read as A)",
           after == before,
           "before=%r after=%r" % (before, after))


def group_h(ctx):
    C, cl, op = ctx.cases, ctx.client, ctx.op
    rows, r = collect_audit(cl, op)
    C.case("H", "operator audit list readable and non-empty",
           r.status == 200 and len(rows) > 0,
           "status=%s rows=%d" % (r.status, len(rows)))

    def has(action_names, result=None, contains=None):
        for x in rows:
            if not isinstance(x, dict):
                continue
            a = x.get("action", "")
            if contains and contains not in a:
                continue
            if action_names and a not in action_names:
                continue
            if result and x.get("result") != result:
                continue
            return True
        return False

    C.case("H", "audit contains tenant.create (ok)",
           has(("tenant.create",), result="ok"))
    C.case("H", "audit contains login.create (ok)",
           has(("login.create",), result="ok"))
    # §5/§8 name audited actions in dot form (object.put is explicit
    # in §7.4); the login action spelling is not fixed in the text,
    # so accept the auth.* spellings for it.
    auth_rows = [x for x in rows if isinstance(x, dict)
                 and ("auth" in x.get("action", "")
                      and "login" in x.get("action", ""))]
    auth_ok = any(x.get("result") == "ok" for x in auth_rows)
    auth_denied = any(x.get("result") in ("denied", "error")
                      for x in auth_rows)
    if not auth_rows:  # fallback: any login action that is not *.create
        auth_rows = [x for x in rows if isinstance(x, dict)
                     and "login" in x.get("action", "")
                     and not x.get("action", "").endswith(".create")]
        auth_ok = any(x.get("result") == "ok" for x in auth_rows)
        auth_denied = any(x.get("result") in ("denied", "error")
                          for x in auth_rows)
    C.case("H", "audit contains auth.login success AND failure rows",
           auth_ok and auth_denied,
           "auth_rows=%s" % ([(x.get("action"), x.get("result"))
                              for x in auth_rows[:6]],))
    C.case("H", "audit contains object.put ok",
           has(("object.put",), result="ok"))
    C.case("H", "audit contains object.put denied (the quota denial)",
           has(("object.put",), result="denied"))

    ids = [x.get("id") for x in rows if isinstance(x, dict)]
    ids = [i for i in ids if isinstance(i, int)]
    C.case("H", "audit rows are returned in id order",
           len(ids) == len(rows) and ids == sorted(ids),
           "first_ids=%s" % (ids[:8],))

    detail_blob = "\n".join(audit_detail_text(x) for x in rows)
    leaked = [s for s in SECRETS_USED if s and s in detail_blob]
    C.case("H", "no audit detail contains any fixture password or token (§4)",
           not leaked, "leaked=%d secrets" % len(leaked))
    full_blob = json.dumps(rows)
    leaked_full = [s for s in SECRETS_USED if s and s in full_blob]
    C.case("H", "no audit row anywhere contains a fixture secret",
           not leaked_full, "leaked=%d secrets" % len(leaked_full))


S3_ACCESS_KEY = "stubaccesskey0001"
S3_BUCKET = "stub-bucket"


def _s3_tenant_session(ctx, inst, slug):
    """Setup (not cases): tenant + admin login + session on `inst`."""
    op = inst.operator_token
    r = inst.client.post("/v1/tenants", token=op,
                         json_body={"slug": slug, "display_name": slug})
    tid = row_id(data_of(r) or {})
    pw = new_password("s3admin")
    r = inst.client.post("/v1/tenants/%s/logins" % tid, token=op,
                         json_body={"username": "s3admin",
                                    "display_name": "S3 Admin",
                                    "role": "tenant_admin",
                                    "password": pw})
    _, token = do_login(inst.client, slug, "s3admin", pw)
    return tid, token


def group_i(ctx):
    C = ctx.cases
    test_secret = note_secret("stub-secret-" + secrets_mod.token_hex(12))
    stub = StubS3(test_secret, S3_ACCESS_KEY)
    stub.start()
    ctx.stub = stub
    inst2 = None
    inst3 = None
    try:
        inst2 = start_instance(
            ctx.binary, "s3", os.path.join(ctx.tmp_root, "inst-s3"),
            extra_env={"SNOWFELL_S3_TEST_SECRET": test_secret})
        ctx.inst2 = inst2
        tid2, sess2 = _s3_tenant_session(ctx, inst2, "s3tenant")

        rb = create_backend(inst2.client, inst2.operator_token,
                            "stub-s3", "s3", endpoint=stub.endpoint,
                            region="us-east-1", bucket=S3_BUCKET,
                            access_key_id=S3_ACCESS_KEY,
                            secret_ref="SNOWFELL_S3_TEST_SECRET")
        backend_id = row_id(data_of(rb) or {})
        C.case("I", "create s3 backend via API (endpoint=stub, secret_ref=env name)",
               rb.status in (200, 201) and backend_id is not None,
               "status=%s body=%s" % (rb.status, rb.text()[:300]))

        rbuck = create_bucket(inst2.client, sess2, "s3data",
                              backend_id=backend_id)
        bucket_id = row_id(data_of(rbuck) or {})
        C.case("I", "create bucket on the s3 backend 201",
               rbuck.status == 201 and bucket_id is not None,
               "status=%s body=%s" % (rbuck.status, rbuck.text()[:200]))

        payload = b"s3-round-trip-" + secrets_mod.token_hex(16).encode()
        rp = put_object(inst2.client, sess2, "s3data", "docs/note.bin",
                        payload)
        rg = get_object(inst2.client, sess2, "s3data", "docs/note.bin")
        C.case("I", "S3 PUT/GET round-trip returns exact bytes",
               rp.status in (200, 201) and rg.status == 200
               and rg.body == payload,
               "put=%s get=%s len=%d" % (rp.status, rg.status, len(rg.body)))

        prefix = "/%s/%s/" % (tid2, bucket_id)
        saw = [p for (m, p) in stub.seen
               if m == "PUT" and prefix in urllib.parse.unquote(p)]
        C.case("I", "stub saw the tenant-prefixed object name (§7.3 tenant/bucket prefix)",
               len(saw) >= 1,
               "prefix=%s seen_puts=%s"
               % (prefix, [p for (m, p) in stub.seen if m == "PUT"][:4]))
        C.case("I", "stub verified every SigV4 signature (zero auth failures)",
               stub.auth_failures == 0,
               "auth_failures=%d requests=%d"
               % (stub.auth_failures, len(stub.seen)))

        rd = inst2.client.delete(object_url("s3data", "docs/note.bin"),
                                 token=sess2)
        rg2 = get_object(inst2.client, sess2, "s3data", "docs/note.bin")
        C.case("I", "S3 DELETE then GET -> 404",
               rd.status in (200, 204) and rg2.status == 404,
               "delete=%s get=%s" % (rd.status, rg2.status))
        stop_instance(inst2)
        inst2 = None

        # Same backend shape, but the service starts WITHOUT the
        # secret env var (§7.3: backend disabled — a fact, not a
        # crash). Accept whichever clean surface the API exposes:
        # backend reported disabled, or a 502 backend_unavailable on
        # the open path. Anything that still answers health cleanly.
        inst3 = start_instance(ctx.binary, "s3-nosecret",
                               os.path.join(ctx.tmp_root, "inst-nosecret"))
        ctx.inst3 = inst3
        tid3, sess3 = _s3_tenant_session(ctx, inst3, "s3tenant")
        rb3 = create_backend(inst3.client, inst3.operator_token,
                             "stub-s3", "s3", endpoint=stub.endpoint,
                             region="us-east-1", bucket=S3_BUCKET,
                             access_key_id=S3_ACCESS_KEY,
                             secret_ref="SNOWFELL_S3_TEST_SECRET")
        d3 = data_of(rb3) if isinstance(data_of(rb3), dict) else {}
        state_disabled = d3.get("state") == "disabled"
        bid3 = row_id(d3)
        clean_error = rb3.status == 502 \
            and err_code(rb3) == "backend_unavailable"
        probes = []
        if bid3 is not None and not state_disabled:
            rbuck3 = create_bucket(inst3.client, sess3, "s3data",
                                   backend_id=bid3)
            probes.append(rbuck3)
            if rbuck3.status == 201:
                probes.append(put_object(inst3.client, sess3, "s3data",
                                         "x.bin", b"x"))
        for pr in probes:
            if pr.status == 502 and err_code(pr) == "backend_unavailable":
                clean_error = True
            elif isinstance(data_of(pr), dict) \
                    and data_of(pr).get("state") == "disabled":
                state_disabled = True
        health = inst3.client.get("/v1/health")
        alive = inst3.proc.poll() is None
        C.case("I", "missing secret env: s3 backend yields a clean backend_unavailable/disabled, service stays healthy",
               (state_disabled or clean_error)
               and health.status == 200 and alive,
               "backend_status=%s state=%r probes=%s health=%s"
               % (rb3.status, d3.get("state"),
                  [(p.status, err_code(p)) for p in probes],
                  health.status))
        stop_instance(inst3)
        inst3 = None
    finally:
        if inst2 is not None:
            stop_instance(inst2)
        if inst3 is not None:
            stop_instance(inst3)
        stub.stop()


def group_j(ctx):
    C, op = ctx.cases, ctx.op
    inst = ctx.inst1
    cl_old = ctx.client

    rt = cl_old.get("/v1/tenants/%s" % ctx.tid_a, token=op)
    tenant_before = data_of(rt)
    obj_before = get_object(cl_old, ctx.admin_a_token, "shared",
                            "dir/hello.txt")
    stop_instance(inst)

    inst_new = start_instance(ctx.binary, "main-restarted", inst.dir,
                              expect_bootstrap=False)
    ctx.inst1 = inst_new
    ctx.client = inst_new.client
    cl = inst_new.client

    r = cl.get("/v1/tenants/%s" % ctx.tid_a, token=op)
    d = data_of(r)
    C.case("J", "after restart tenant A is intact (slug + display name)",
           r.status == 200 and isinstance(d, dict)
           and d.get("slug") == "alpha"
           and d.get("display_name") == (tenant_before or {}).get(
               "display_name"),
           "status=%s body=%s" % (r.status, r.text()[:200]))

    r = cl.get("/v1/buckets/%s" % seg("shared"), token=ctx.admin_a_token)
    C.case("J", "after restart bucket 'shared' is intact",
           r.status == 200, "status=%s" % r.status)

    r = get_object(cl, ctx.admin_a_token, "shared", "dir/hello.txt")
    C.case("J", "after restart object bytes are intact",
           r.status == 200 and obj_before.status == 200
           and r.body == obj_before.body,
           "status=%s len=%d" % (r.status, len(r.body)))

    r = cl.get("/v1/tenants/%s/logins" % ctx.tid_a
               + qs({"limit": 200}), token=op)
    ids = {row_id(x) for x in rows_of(r)}
    C.case("J", "after restart logins are intact (admin + user present)",
           r.status == 200 and ctx.admin_a_id in ids
           and ctx.user_a_id in ids,
           "status=%s ids=%s" % (r.status, sorted(i for i in ids if i)))

    r = cl.get("/v1/auth/me", token=ctx.persist_api_token)
    C.case("J", "pre-restart API token still resolves after restart",
           r.status == 200, "status=%s" % r.status)

    _, fresh = do_login(cl, "alpha", "admina", ctx.pw_admin_a)
    C.case("J", "password login still works after restart",
           bool(fresh))


# ================================================================= main

def main():
    binary, build_out = build_service()
    if binary is None:
        print("BUILD FAILED — make -C %s service" % STORAGE_DIR)
        print(build_out)
        print("SUMMARY: build failure (exit 2)")
        return 2
    print("BUILD OK: %s" % binary)

    cases = Cases()
    ctx = Ctx()
    ctx.cases = cases
    ctx.binary = binary
    ctx.tmp_root = tempfile.mkdtemp(prefix="snowfell-storage-test-")
    keep = os.environ.get("SNOWFELL_KEEP_TEST") == "1"
    try:
        ctx.inst1 = start_instance(binary, "main",
                                   os.path.join(ctx.tmp_root, "inst-main"))
        ctx.client = ctx.inst1.client
        ctx.op = note_secret(ctx.inst1.operator_token)
        groups = (("A", group_a), ("B", group_b), ("C", group_c),
                  ("D", group_d), ("E", group_e), ("F", group_f),
                  ("G", group_g), ("H", group_h), ("I", group_i),
                  ("J", group_j))
        for letter, fn in groups:
            try:
                fn(ctx)
            except Exception:
                cases.case(letter, "group completes without exception",
                           False, traceback.format_exc(limit=5))
    except Exception:
        cases.case("A", "service starts and announces readiness", False,
                   traceback.format_exc(limit=5))
    finally:
        for name in ("inst1", "inst2", "inst3"):
            inst = getattr(ctx, name, None)
            if inst is not None:
                stop_instance(inst)
        stub = getattr(ctx, "stub", None)
        if stub is not None:
            stub.stop()
        if keep:
            print("KEPT test dir: %s" % ctx.tmp_root)
        else:
            shutil.rmtree(ctx.tmp_root, ignore_errors=True)

    print("SUMMARY: %d passed, %d failed, %d total"
          % (cases.passed, cases.failed, cases.passed + cases.failed))
    for line in cases.failures:
        print("FAILED: %s" % line)
    return 1 if cases.failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""SF-T12h verification driver (test_blob_dedup.py): dedup, GC, verify, quota-physical,
metadata header, reset 401, duplicate-slug audit, v1->v2 upgrade."""
import hashlib, json, os, sqlite3, subprocess, sys, tempfile, time
import urllib.request, urllib.error

V1_SCHEMA_SQL = "-- Snowfell Storage Service — operational store DDL (design record 03\n-- §4/§6.1). This schema lives ONLY in the service's cloud.db. It is\n-- never applied to the registry, never bundled, never published:\n-- cs_credentials and cs_tokens hold secret-derived material, and the\n-- publication filter (design record 01 §2) is absolute.\n--\n-- The service embeds this DDL (sf_store_open bootstraps an empty DB\n-- from it) and versions it via cs_meta.schema_version = 1.\n\nPRAGMA foreign_keys = ON;\n\nCREATE TABLE cs_meta (\n    key TEXT PRIMARY KEY,\n    value TEXT NOT NULL\n);\nINSERT INTO cs_meta (key, value) VALUES ('schema_version', '1');\n\nCREATE TABLE cs_tenants (\n    id INTEGER PRIMARY KEY,\n    slug TEXT NOT NULL UNIQUE,\n    display_name TEXT NOT NULL,\n    state TEXT NOT NULL DEFAULT 'active'\n        CHECK (state IN ('active', 'suspended', 'closed')),\n    quota_bytes INTEGER NOT NULL DEFAULT -1,\n    quota_objects INTEGER NOT NULL DEFAULT -1,\n    quota_buckets INTEGER NOT NULL DEFAULT -1,\n    contact_note TEXT NOT NULL DEFAULT '',\n    provenance TEXT NOT NULL DEFAULT 'service',\n    directive TEXT NOT NULL DEFAULT '',\n    created_at TEXT NOT NULL,\n    updated_at TEXT NOT NULL\n);\n\nCREATE TABLE cs_logins (\n    id INTEGER PRIMARY KEY,\n    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n        ON UPDATE CASCADE ON DELETE RESTRICT,\n    username TEXT NOT NULL,\n    display_name TEXT NOT NULL DEFAULT '',\n    role TEXT NOT NULL CHECK (role IN ('tenant_admin', 'tenant_user')),\n    state TEXT NOT NULL DEFAULT 'active'\n        CHECK (state IN ('active', 'disabled')),\n    last_login_at TEXT,\n    created_at TEXT NOT NULL,\n    updated_at TEXT NOT NULL,\n    UNIQUE (tenant_id, username)\n);\n\n-- One credential row per (login, kind). kind 'fido2' is the record-02\n-- seam: columns stay NULL for it until R1 lands; nothing in v1 writes\n-- or reads a fido2 row.\nCREATE TABLE cs_credentials (\n    id INTEGER PRIMARY KEY,\n    login_id INTEGER NOT NULL REFERENCES cs_logins (id)\n        ON UPDATE CASCADE ON DELETE CASCADE,\n    kind TEXT NOT NULL CHECK (kind IN ('password', 'fido2')),\n    password_salt BLOB,\n    password_hash BLOB,\n    password_iterations INTEGER,\n    password_changed_at TEXT,\n    failed_attempts INTEGER NOT NULL DEFAULT 0,\n    locked_until TEXT,\n    created_at TEXT NOT NULL,\n    updated_at TEXT NOT NULL,\n    UNIQUE (login_id, kind)\n);\n\n-- Only SHA-256 digests of tokens are stored (LTD licensing precedent).\n-- tenant_id/login_id are NULL for the operator token (scope = all).\nCREATE TABLE cs_tokens (\n    id INTEGER PRIMARY KEY,\n    tenant_id INTEGER REFERENCES cs_tenants (id)\n        ON UPDATE CASCADE ON DELETE CASCADE,\n    login_id INTEGER REFERENCES cs_logins (id)\n        ON UPDATE CASCADE ON DELETE CASCADE,\n    kind TEXT NOT NULL CHECK (kind IN ('session', 'api', 'operator')),\n    token_sha256 BLOB NOT NULL UNIQUE,\n    label TEXT NOT NULL DEFAULT '',\n    created_at TEXT NOT NULL,\n    expires_at TEXT,\n    revoked_at TEXT,\n    last_used_at TEXT\n);\nCREATE INDEX cs_tokens_login ON cs_tokens (login_id);\n\nCREATE TABLE cs_password_resets (\n    id INTEGER PRIMARY KEY,\n    login_id INTEGER NOT NULL REFERENCES cs_logins (id)\n        ON UPDATE CASCADE ON DELETE CASCADE,\n    token_sha256 BLOB NOT NULL UNIQUE,\n    created_by TEXT NOT NULL DEFAULT '',\n    created_at TEXT NOT NULL,\n    expires_at TEXT NOT NULL,\n    used_at TEXT\n);\n\nCREATE TABLE cs_backends (\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL UNIQUE,\n    kind TEXT NOT NULL CHECK (kind IN ('filesystem', 's3')),\n    config_json TEXT NOT NULL DEFAULT '{}',\n    secret_ref TEXT NOT NULL DEFAULT '',\n    state TEXT NOT NULL DEFAULT 'active'\n        CHECK (state IN ('active', 'disabled')),\n    created_at TEXT NOT NULL,\n    updated_at TEXT NOT NULL\n);\n\nCREATE TABLE cs_buckets (\n    id INTEGER PRIMARY KEY,\n    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n        ON UPDATE CASCADE ON DELETE RESTRICT,\n    name TEXT NOT NULL,\n    backend_id INTEGER NOT NULL REFERENCES cs_backends (id)\n        ON UPDATE CASCADE ON DELETE RESTRICT,\n    quota_bytes INTEGER NOT NULL DEFAULT -1,\n    object_count INTEGER NOT NULL DEFAULT 0,\n    total_bytes INTEGER NOT NULL DEFAULT 0,\n    created_at TEXT NOT NULL,\n    updated_at TEXT NOT NULL,\n    UNIQUE (tenant_id, name)\n);\n\n-- tenant_id is denormalized onto the object row deliberately: every\n-- object query filters on it directly (design §3.2 walls 2-3).\nCREATE TABLE cs_objects (\n    id INTEGER PRIMARY KEY,\n    bucket_id INTEGER NOT NULL REFERENCES cs_buckets (id)\n        ON UPDATE CASCADE ON DELETE RESTRICT,\n    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n        ON UPDATE CASCADE ON DELETE RESTRICT,\n    key TEXT NOT NULL,\n    size_bytes INTEGER NOT NULL,\n    sha256 BLOB NOT NULL,\n    content_type TEXT NOT NULL DEFAULT 'application/octet-stream',\n    metadata_json TEXT NOT NULL DEFAULT '{}',\n    created_at TEXT NOT NULL,\n    updated_at TEXT NOT NULL,\n    UNIQUE (bucket_id, key)\n);\nCREATE INDEX cs_objects_tenant ON cs_objects (tenant_id, bucket_id);\n\n-- Append-only by API (the store exposes insert + scoped read only).\n-- detail_json carries figures and refs — never secrets, never tokens.\nCREATE TABLE cs_audit_log (\n    id INTEGER PRIMARY KEY,\n    ts TEXT NOT NULL,\n    tenant_id INTEGER,\n    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('operator', 'login', 'system')),\n    actor_ref TEXT NOT NULL DEFAULT '',\n    action TEXT NOT NULL,\n    object_ref TEXT NOT NULL DEFAULT '',\n    result TEXT NOT NULL CHECK (result IN ('ok', 'denied', 'error')),\n    detail_json TEXT NOT NULL DEFAULT '{}',\n    ip TEXT\n);\nCREATE INDEX cs_audit_tenant ON cs_audit_log (tenant_id, id);\n"

BIN = os.path.expanduser("~/workspace/goals/snowfell-distro-jira-board-app/files/app/StorageService/snowfell-storage-service")
PASS = FAIL = 0
def case(name, ok, detail=""):
    global PASS, FAIL
    print(("PASS " if ok else "FAIL ") + name + ((" -- " + str(detail)) if (detail and not ok) else ""))
    if ok: PASS += 1
    else: FAIL += 1

class Cl:
    def __init__(self, port): self.base = "http://127.0.0.1:%d" % port
    def req(self, method, path, token=None, body=None, raw=None, headers=None):
        data = raw
        hdrs = dict(headers or {})
        if body is not None:
            data = json.dumps(body).encode(); hdrs["Content-Type"] = "application/json"
        if token: hdrs["Authorization"] = "Bearer " + token
        r = urllib.request.Request(self.base + path, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(r, timeout=20) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()
    def j(self, method, path, token=None, body=None, raw=None, headers=None):
        s, h, b = self.req(method, path, token, body, raw, headers)
        try: parsed = json.loads(b.decode()) if b else {}
        except Exception: parsed = {"_unparsed": b[:200]}
        return s, h, parsed, b

def start(datadir, extra_env=None):
    env = dict(os.environ); env["SNOWFELL_CLOUD_DIR"] = datadir; env["SNOWFELL_CLOUD_PORT"] = "0"
    if extra_env: env.update(extra_env)
    p = subprocess.Popen([BIN], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True)
    line = p.stdout.readline()
    assert "SNOWFELL_STORAGE_READY" in line, line
    port = int(line.split("port=")[1].split()[0])
    return p, Cl(port)

def op_token(datadir):
    for _ in range(50):
        f = os.path.join(datadir, "bootstrap-operator-token.txt")
        if os.path.exists(f): return open(f).read().strip()
        time.sleep(0.1)
    raise RuntimeError("no bootstrap token")

def mk_tenant(cl, op, slug):
    s, _, d, _ = cl.j("POST", "/v1/tenants", token=op, body={"slug": slug, "display_name": slug.title()})
    assert s == 201, (s, d)
    tid = d["data"]["id"]
    pw = "Pw-%s-123456!x" % slug
    s, _, d, _ = cl.j("POST", "/v1/tenants/%s/logins" % tid, token=op,
                      body={"username": "admin", "display_name": "Admin", "role": "tenant_admin", "password": pw})
    assert s == 201, (s, d)
    s, _, d, _ = cl.j("POST", "/v1/auth/login", body={"tenant": slug, "username": "admin", "password": pw})
    assert s == 200, (s, d)
    return tid, d["data"]["token"]

def put_obj(cl, tok, bucket, key, payload, headers=None, ctype="application/octet-stream"):
    hdrs = {"Content-Type": ctype}
    if headers: hdrs.update(headers)
    return cl.j("PUT", "/v1/buckets/%s/objects/%s" % (bucket, key), token=tok, raw=payload, headers=hdrs)

def usage(cl, op, tid):
    s, _, d, _ = cl.j("GET", "/v1/tenants/%s/usage" % tid, token=op)
    assert s == 200, (s, d)
    return d["data"]

def fs_files(datadir, tid):
    root = os.path.join(datadir, "fsroot", str(tid))
    out = []
    for dp, _, fns in os.walk(root):
        for fn in fns: out.append(os.path.join(dp, fn))
    return sorted(out)

tmp = tempfile.mkdtemp(prefix="sf12h-")
datadir = os.path.join(tmp, "main"); os.makedirs(datadir)
proc, cl = start(datadir, {"SNOWFELL_GC_GRACE_SECONDS": "0"})
op = op_token(datadir)
cl.j("GET", "/v1/tenants", token=op)  # first operator call

tidA, tokA = mk_tenant(cl, op, "tenant-a")
tidB, tokB = mk_tenant(cl, op, "tenant-b")
tidC, tokC = mk_tenant(cl, op, "tenant-c")
for tok in (tokA, tokB, tokC):
    s, _, d, _ = cl.j("POST", "/v1/buckets", token=tok, body={"name": "b1"})
    assert s == 201, (s, d)

P = b"payload-P-" + bytes(range(200))
Q = b"payload-Q-shorter"

# ---- dedup hit
s, _, d, _ = put_obj(cl, tokA, "b1", "k1", P)
blobP = d["data"]["blob_id"] if s in (200, 201) else None
case("dedup: first PUT 201 with blob_id", s == 201 and blobP is not None, (s, d))
s, _, d, _ = put_obj(cl, tokA, "b1", "k2", P)
case("dedup: second PUT same payload, same blob_id", s == 201 and d["data"]["blob_id"] == blobP, (s, d))
u = usage(cl, op, tidA)
case("dedup: physical = one copy", u["used_bytes"] == len(P), u)
case("dedup: logical = two references", u["dedup"]["logical_bytes"] == 2 * len(P) and u["dedup"]["physical_bytes"] == len(P) and u["dedup"]["blob_count"] == 1 and u["dedup"]["reference_count"] == 2, u["dedup"])
s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % blobP, token=tokA)
case("dedup: blob refcount = 2", s == 200 and d["data"]["refcount"] == 2, (s, d))
s, _, _, raw = cl.j("GET", "/v1/buckets/b1/objects/k2", token=tokA)
case("dedup: GET k2 returns payload", s == 200 and raw == P, s)
case("dedup: exactly one physical file for tenant A", len(fs_files(datadir, tidA)) == 1, fs_files(datadir, tidA))

# ---- cross-scope non-oracle
s, _, d, _ = put_obj(cl, tokB, "b1", "k1", P)
blobB = d["data"]["blob_id"] if s in (200, 201) else None
uB = usage(cl, op, tidB); uA = usage(cl, op, tidA)
case("xscope: B stores its own blob (different id)", blobB is not None and blobB != blobP, (blobB, blobP))
case("xscope: B physical = own copy; A untouched", uB["used_bytes"] == len(P) and uA["used_bytes"] == len(P), (uB["used_bytes"], uA["used_bytes"]))
s, _, d, _ = cl.j("POST", "/v1/blobs", token=tokC, raw=P, headers={"Content-Type": "application/octet-stream"})
case("xscope: fresh tenant C raw upload deduplicated=false", s == 201 and d["data"]["deduplicated"] is False, (s, d))
blobC = d["data"]["blob_id"]
s, _, d, _ = cl.j("POST", "/v1/blobs", token=tokB, raw=P, headers={"Content-Type": "application/octet-stream"})
case("xscope: B raw upload deduplicated=true (own scope only)", s == 201 and d["data"]["deduplicated"] is True and d["data"]["blob_id"] == blobB, (s, d))
s, _, d, _ = cl.j("GET", "/v1/blobs/%s" % blobP, token=tokB)
case("xscope: B GET A's blob -> 404", s == 404, s)
s, _, d, _ = cl.j("DELETE", "/v1/blobs/%s" % blobP, token=tokA)
case("blob DELETE while referenced -> 409 with refcount", s == 409 and d["error"]["detail"]["refcount"] == 2, (s, d))

# ---- overwrite detach + orphan + GC
pfile = fs_files(datadir, tidA)[0]
s, _, d, _ = put_obj(cl, tokA, "b1", "k1", Q)
blobQ = d["data"]["blob_id"] if s in (200, 201) else None
s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % blobP, token=tokA)
case("overwrite: old blob refcount drops to 1", s == 200 and d["data"]["refcount"] == 1, (s, d))
s, _, d, _ = cl.j("DELETE", "/v1/buckets/b1/objects/k2", token=tokA)
case("overwrite: delete k2 ok", s == 200, (s, d))
s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % blobP, token=tokA)
case("orphan: refcount 0 + orphaned_at stamped", s == 200 and d["data"]["refcount"] == 0 and d["data"]["orphaned_at"], (s, d))
s, _, d, _ = cl.j("POST", "/v1/gc", token=tokA, body={"dry_run": True})
case("GC dry-run: orphans>=1, deleted=0, reclaimed=0", s == 200 and d["data"]["orphans"] >= 1 and d["data"]["deleted"] == 0 and d["data"]["bytes_reclaimed"] == 0, (s, d))
case("GC dry-run: blob file still present", os.path.exists(pfile), pfile)
s, _, d, _ = cl.j("POST", "/v1/gc", token=tokA, body={"dry_run": False})
case("GC real: bytes_reclaimed == len(P) exactly", s == 200 and d["data"]["bytes_reclaimed"] == len(P) and d["data"]["deleted"] >= 1, (s, d))
case("GC real: adapter file gone", not os.path.exists(pfile), pfile)
s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % blobP, token=tokA)
case("GC real: blob row gone (404)", s == 404, s)

# ---- verify ok + corruption
s, _, d, _ = cl.j("POST", "/v1/blobs/%s/verify" % blobQ, token=tokA)
case("verify: intact blob verified=true", s == 200 and d["data"]["verified"] is True, (s, d))
qfiles = fs_files(datadir, tidA)
assert len(qfiles) == 1, qfiles
qfile = qfiles[0]
orig = open(qfile, "rb").read()
with open(qfile, "r+b") as f:
    f.write(bytes([orig[0] ^ 0xFF]))
s, _, d, _ = cl.j("POST", "/v1/blobs/%s/verify" % blobQ, token=tokA)
case("verify: corrupted blob verified=false", s == 200 and d["data"]["verified"] is False, (s, d))
s, _, d, _ = cl.j("GET", "/v1/blobs/%s" % blobQ, token=tokA)
case("corrupt: GET blob -> 502 blob_integrity", s == 502 and d["error"]["code"] == "blob_integrity", (s, d))
s, _, d, _ = cl.j("GET", "/v1/buckets/b1/objects/k1", token=tokA)
case("corrupt: GET object -> 502 blob_integrity", s == 502 and d["error"]["code"] == "blob_integrity", (s, d))
with open(qfile, "wb") as f: f.write(orig)
s, _, d, _ = cl.j("POST", "/v1/blobs/%s/verify" % blobQ, token=tokA)
s2, _, _, raw = cl.j("GET", "/v1/buckets/b1/objects/k1", token=tokA)
case("verify: restored bytes verify true + GET serves again", s == 200 and d["data"]["verified"] is True and s2 == 200 and raw == Q, (s, d, s2))

# ---- quota on physical bytes
u = usage(cl, op, tidA)
phys = u["used_bytes"]
R = b"R" * 500
quota = phys + len(R)
s, _, d, _ = cl.j("PUT", "/v1/tenants/%s/quota" % tidA, token=op, body={"quota_bytes": quota, "quota_objects": 100000, "quota_buckets": 100})
assert s == 200, (s, d)
s, _, d, _ = put_obj(cl, tokA, "b1", "fill", R)
case("quota: PUT filling physical exactly succeeds", s == 201, (s, d))
ok_all = True
for i in range(10):
    s, _, d, _ = put_obj(cl, tokA, "b1", "dup%d" % i, R)
    ok_all = ok_all and s == 201
case("quota: 10 deduped references past logical quota all succeed (physical unchanged)", ok_all, s)
u = usage(cl, op, tidA)
case("quota: physical still == quota after dedup refs", u["used_bytes"] == quota and u["dedup"]["logical_bytes"] > quota, u["dedup"])
s, _, d, _ = put_obj(cl, tokA, "b1", "one-too-many", b"Z")
case("quota: 1 new physical byte over -> 409 quota_exceeded", s == 409 and d["error"]["code"] == "quota_exceeded", (s, d))
cl.j("PUT", "/v1/tenants/%s/quota" % tidA, token=op, body={"quota_bytes": 10737418240, "quota_objects": 100000, "quota_buckets": 100})

# ---- metadata header
meta = {"purpose": "sf-t12h", "n": 3}
s, _, d, _ = put_obj(cl, tokA, "b1", "meta.bin", b"mb", headers={"X-Snowfell-Metadata": json.dumps(meta)})
s2, _, d2, _ = cl.j("GET", "/v1/buckets/b1/objects?limit=200", token=tokA)
row = [r for r in d2["data"] if r.get("key") == "meta.bin"]
case("metadata: header round-trips via object list", s == 201 and row and row[0].get("metadata") == meta, (s, row))
s, _, d, _ = put_obj(cl, tokA, "b1", "meta-bad", b"mb", headers={"X-Snowfell-Metadata": "not-json"})
case("metadata: non-JSON header -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))
s, _, d, _ = put_obj(cl, tokA, "b1", "meta-bad2", b"mb", headers={"X-Snowfell-Metadata": "[1,2]"})
case("metadata: JSON array header -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))
s, _, d, _ = put_obj(cl, tokA, "b1", "meta-bad3", b"mb", headers={"X-Snowfell-Metadata": json.dumps({"x": "y" * 5000})})
case("metadata: >4KB header -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))

# ---- reset completion 401
pw = "Pw-resetter-123!x"
s, _, d, _ = cl.j("POST", "/v1/tenants/%s/logins" % tidA, token=op, body={"username": "resetter", "display_name": "R", "role": "tenant_user", "password": pw})
lid = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/tenants/%s/logins/%s/password-resets" % (tidA, lid), token=tokA, body={})
rtok = d["data"]["reset_token"]
s, _, d, _ = cl.j("POST", "/v1/auth/password-reset/complete", body={"token": "bogus-token-123", "new_password": "Pw-new-123456!x"})
case("reset: unknown token -> 401 invalid_credentials", s == 401 and d["error"]["code"] == "invalid_credentials", (s, d))
s, h, b = cl.req("POST", "/v1/auth/password-reset/complete", raw=b"{not json", headers={"Content-Type": "application/json"})
case("reset: malformed JSON body stays 400", s == 400, s)
s, _, d, _ = cl.j("POST", "/v1/auth/password-reset/complete", body={"token": rtok, "new_password": "Pw-new-123456!x"})
case("reset: valid token -> 200", s == 200, (s, d))
s, _, d, _ = cl.j("POST", "/v1/auth/password-reset/complete", body={"token": rtok, "new_password": "Pw-new2-12345!x"})
case("reset: replayed token -> 401 invalid_credentials", s == 401 and d["error"]["code"] == "invalid_credentials", (s, d))

# ---- duplicate slug audit row
s, _, d, _ = cl.j("POST", "/v1/tenants", token=op, body={"slug": "tenant-a", "display_name": "Dup"})
case("dup slug: 409 conflict", s == 409, (s, d))
rows = []
cursor = None
for _ in range(10):
    path = "/v1/audit?action=tenant.create&limit=200" + (("&cursor=%s" % cursor) if cursor else "")
    s, _, d, _ = cl.j("GET", path, token=op)
    rows.extend(d.get("data", []))
    cursor = (d.get("meta") or {}).get("next_cursor")
    if not cursor: break
denied = [r for r in rows if r.get("result") == "denied"]
case("dup slug: audit row exists, valid JSON detail, object_ref is the slug",
     len(denied) >= 1 and denied[-1]["detail"].get("reason") == "duplicate_slug" and denied[-1]["object_ref"] == "tenant-a",
     denied[-1] if denied else rows[:2])
case("audit: actor_ref opaque (no usernames)", all(r.get("actor_ref") in ("operator", "system") or str(r.get("actor_ref", "")).startswith("login:") for r in rows), [r.get("actor_ref") for r in rows[:5]])

# ---- stats anonymization + admin sweeps
s, _, d, raw = cl.j("GET", "/v1/stats/dedup", token=op)
txt = raw.decode()
case("stats: 200, scopes keyed by tenant_id", s == 200 and any(sc["tenant_id"] == tidA for sc in d["data"]["scopes"]), (s, d))
case("stats: no slugs/names anywhere", "tenant-a" not in txt and "Tenant-A" not in txt and "tenant-b" not in txt, txt[:200])
s, _, d, _ = cl.j("POST", "/v1/admin/verify", token=op, body={})
case("admin verify: aggregates scanned=verified+corrupt", s == 200 and d["data"]["scanned"] == d["data"]["verified"] + d["data"]["corrupt"] and d["data"]["scanned"] >= 3, (s, d))
s, _, d, _ = cl.j("DELETE", "/v1/blobs/%s" % blobC, token=tokC)
case("raw blob purge at refcount 0 -> 200", s == 200 and d["data"]["deleted"] is True, (s, d))

proc.terminate(); proc.wait(timeout=10)

# ---- v1 -> v2 upgrade
updir = os.path.join(tmp, "upgrade"); os.makedirs(updir)
dbp = os.path.join(updir, "cloud.db")
v1sql = V1_SCHEMA_SQL
db = sqlite3.connect(dbp); db.executescript(v1sql)
now = "2026-11-12T00:00:00Z"
db.execute("INSERT INTO cs_tenants (slug,display_name,state,quota_bytes,quota_objects,quota_buckets,contact_note,provenance,directive,created_at,updated_at) VALUES ('legacy','Legacy','active',-1,-1,-1,'','','','%s','%s')" % (now, now))
db.execute("INSERT INTO cs_backends (name,kind,config_json,secret_ref,state,created_at,updated_at) VALUES ('local','filesystem','{\"root\":\"fsroot\"}','','active','%s','%s')" % (now, now))
db.execute("INSERT INTO cs_buckets (tenant_id,name,backend_id,quota_bytes,object_count,total_bytes,created_at,updated_at) VALUES (1,'bk',1,-1,3,30,'%s','%s')" % (now, now))
sha1 = hashlib.sha256(b"same-content").digest(); sha2 = hashlib.sha256(b"other-content").digest()
for i, (k, sha, sz) in enumerate([("a.txt", sha1, 12), ("b.txt", sha1, 12), ("c.txt", sha2, 6)]):
    db.execute("INSERT INTO cs_objects (bucket_id,tenant_id,key,size_bytes,sha256,content_type,metadata_json,created_at,updated_at) VALUES (1,1,?,?,?,?,?,'%s','%s')" % (now, now), (k, sz, sha, "text/plain", "{}"))
db.commit(); db.close()
proc2, cl2 = start(updir)
op2 = op_token(updir)
s, _, d, _ = cl2.j("GET", "/v1/health", token=None)
case("upgrade: service opens v1 DB and serves health", s == 200, (s, d))
db = sqlite3.connect(dbp)
ver = db.execute("SELECT value FROM cs_meta WHERE key='schema_version'").fetchone()[0]
blobs = db.execute("SELECT sha256, refcount FROM cs_blobs ORDER BY id").fetchall()
links = db.execute("SELECT COUNT(*) FROM cs_objects WHERE blob_id IS NOT NULL").fetchone()[0]
tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
db.close()
case("upgrade: schema_version = 2", ver == "2", ver)
case("upgrade: one blob per distinct (tenant,sha256), refcounts from links",
     len(blobs) == 2 and sorted(b[1] for b in blobs) == [1, 2], blobs)
case("upgrade: all 3 objects linked", links == 3, links)
case("upgrade: v2 tables exist", {"cs_blobs", "cs_collections", "cs_content_items", "cs_content_versions", "cs_content_refs"} <= tables, tables)
proc2.terminate(); proc2.wait(timeout=10)

print("SF-T12h CHECK: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)

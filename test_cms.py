#!/usr/bin/env python3
"""SF-T12i verification driver (test_cms.py): the CMS content layer —
collections tree + delete guards, items + append-only versions,
metadata-only PATCH, rollback dedup figures, downloads, state +
audit, refs, search (literal % in q), slug conflicts, item delete +
GC reclaim, the cross-tenant isolation battery, corrupt download."""
import hashlib, json, os, subprocess, sys, tempfile, time
import urllib.request, urllib.error

SVC_DIR = os.path.expanduser("~/workspace/goals/snowfell-distro-jira-board-app/files/app/StorageService")
BIN = os.path.join(SVC_DIR, "snowfell-storage-service")
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

def upload_blob(cl, tok, payload):
    s, _, d, _ = cl.j("POST", "/v1/blobs", token=tok, raw=payload,
                      headers={"Content-Type": "application/octet-stream"})
    assert s == 201, (s, d)
    return d["data"]["blob_id"], d["data"]

def blob_meta(cl, tok, bid):
    s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % bid, token=tok)
    assert s == 200, (s, d)
    return d["data"]

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

def sha(b): return hashlib.sha256(b).hexdigest()

# ---- build
r = subprocess.run(["make", "service"], cwd=SVC_DIR, capture_output=True, text=True)
case("build: make service succeeds", r.returncode == 0, r.stdout[-500:] + r.stderr[-500:])

tmp = tempfile.mkdtemp(prefix="sf12i-")
datadir = os.path.join(tmp, "main"); os.makedirs(datadir)
proc, cl = start(datadir, {"SNOWFELL_GC_GRACE_SECONDS": "0"})
op = op_token(datadir)
cl.j("GET", "/v1/tenants", token=op)  # first operator call

tidA, tokA = mk_tenant(cl, op, "cms-a")
tidB, tokB = mk_tenant(cl, op, "cms-b")

P1 = b"alpha-payload-v1-" + bytes(range(120))
P2 = b"beta-payload-v2-different-length"
P3 = b"gamma-attachment-payload"
P4 = b"delta-ephemeral-payload"
P5 = b"epsilon-fragile-payload"

# ---- collections tree
s, _, d, _ = cl.j("POST", "/v1/collections", token=tokA, body={"name": "Library", "slug": "library"})
case("collections: create parent 201", s == 201, (s, d))
coll_parent = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/collections", token=tokA, body={"name": "Docs", "slug": "docs", "parent_id": coll_parent})
case("collections: create child with parent_id", s == 201 and d["data"]["parent_id"] == coll_parent, (s, d))
coll_child = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/collections", token=tokA, body={"name": "Dup", "slug": "docs"})
case("collections: duplicate slug -> 409", s == 409, (s, d))
s, _, d, _ = cl.j("POST", "/v1/collections", token=tokA, body={"name": "Orphan", "slug": "orphan", "parent_id": 999999})
case("collections: missing parent -> 404", s == 404, (s, d))
s, _, d, _ = cl.j("GET", "/v1/collections", token=tokA)
case("collections: list contains parent+child", s == 200 and {c["id"] for c in d["data"]} >= {coll_parent, coll_child}, (s, d))
s, _, d, _ = cl.j("PATCH", "/v1/collections/%s" % coll_child, token=tokA, body={"name": "Documents"})
case("collections: PATCH rename", s == 200 and d["data"]["name"] == "Documents", (s, d))
s, _, d, _ = cl.j("PATCH", "/v1/collections/%s" % coll_parent, token=tokA, body={"parent_id": coll_child})
case("collections: parent cycle -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))

# ---- item create (v1 in one transaction)
blob1, _ = upload_blob(cl, tokA, P1)
blob2, _ = upload_blob(cl, tokA, P2)
case("blobs: raw uploads start at refcount 0", blob_meta(cl, tokA, blob1)["refcount"] == 0)
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "guide", "title": "The Guide", "kind": "document",
    "collection_id": coll_child, "metadata": {"tag": "100% coverage", "n": 1},
    "blob_id": blob1})
case("content: create 201", s == 201, (s, d))
item_guide = d["data"]["id"]
cv = d["data"]["current_version"]
case("content: current version summary is v1/P1",
     cv["version_no"] == 1 and cv["blob_id"] == blob1 and cv["sha256"] == sha(P1) and cv["size_bytes"] == len(P1), cv)
case("content: create bumped blob refcount to 1", blob_meta(cl, tokA, blob1)["refcount"] == 1)
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "guide", "title": "Again", "kind": "document", "blob_id": blob2})
case("content: duplicate slug -> 409 conflict", s == 409 and d["error"]["code"] == "conflict", (s, d))

# ---- cross-tenant blob/collection on create (never a reference leak)
blobB1, _ = upload_blob(cl, tokB, P1)
s, _, d, _ = cl.j("POST", "/v1/content", token=tokB, body={
    "slug": "b-doc", "title": "B Doc", "kind": "text", "blob_id": blobB1})
case("setup: tenant B item created", s == 201, (s, d))
item_b = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/content", token=tokB, body={
    "slug": "b-leak", "title": "Leak", "kind": "text", "blob_id": blob1})
case("xscope: B create with A's blob_id -> 404", s == 404, (s, d))
s, _, d, _ = cl.j("POST", "/v1/content", token=tokB, body={
    "slug": "b-leak2", "title": "Leak2", "kind": "text", "collection_id": coll_child, "blob_id": blobB1})
case("xscope: B create with A's collection_id -> 404", s == 404, (s, d))
case("xscope: failed creates left A's blob refcount at 1", blob_meta(cl, tokA, blob1)["refcount"] == 1)

# ---- version append + metadata-only PATCH
s, _, d, _ = cl.j("POST", "/v1/content/%s/versions" % item_guide, token=tokA,
                  body={"blob_id": blob2, "note": "second pass"})
case("versions: append 201 version_no 2", s == 201 and d["data"]["version_no"] == 2 and d["data"]["blob_id"] == blob2, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s" % item_guide, token=tokA)
case("versions: item current is now v2/P2",
     d["data"]["current_version"]["version_no"] == 2 and d["data"]["current_version"]["sha256"] == sha(P2), d["data"])
s, _, d, _ = cl.j("GET", "/v1/content/%s/versions" % item_guide, token=tokA)
case("versions: list newest-first [2,1]", s == 200 and [v["version_no"] for v in d["data"]] == [2, 1], (s, d))
s, _, d, _ = cl.j("PATCH", "/v1/content/%s" % item_guide, token=tokA,
                  body={"title": "The Guide II", "metadata": {"tag": "100% coverage", "n": 2}})
case("patch: metadata/title PATCH 200", s == 200 and d["data"]["title"] == "The Guide II" and d["data"]["metadata"] == {"tag": "100% coverage", "n": 2}, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/versions" % item_guide, token=tokA)
case("patch: metadata-only PATCH created NO version", s == 200 and len(d["data"]) == 2 and d["data"][0]["version_no"] == 2, (s, d))
s, _, d, _ = cl.j("PATCH", "/v1/content/%s" % item_guide, token=tokA, body={"collection_id": None})
case("patch: collection cleared to root", s == 200 and d["data"]["collection_id"] is None, (s, d))
s, _, d, _ = cl.j("PATCH", "/v1/content/%s" % item_guide, token=tokA, body={"collection_id": coll_child})
case("patch: collection restored", s == 200 and d["data"]["collection_id"] == coll_child, (s, d))

# ---- collection delete guards (item + child present)
s, _, d, _ = cl.j("DELETE", "/v1/collections/%s" % coll_parent, token=tokA)
case("collections: DELETE parent with child -> 409 conflict", s == 409 and d["error"]["code"] == "conflict", (s, d))
s, _, d, _ = cl.j("DELETE", "/v1/collections/%s" % coll_child, token=tokA)
case("collections: DELETE child with item -> 409 conflict", s == 409 and d["error"]["code"] == "conflict", (s, d))

# ---- rollback: dedup figures exact
u_before = usage(cl, op, tidA)["dedup"]
s, _, d, _ = cl.j("POST", "/v1/content/%s/rollback" % item_guide, token=tokA, body={"version_no": 1})
case("rollback: 201, v3 -> v1's blob, note records rollback",
     s == 201 and d["data"]["version_no"] == 3 and d["data"]["blob_id"] == blob1 and d["data"]["note"] == "rollback of v1", (s, d))
case("rollback: blob1 refcount = 2 (v1 + v3)", blob_meta(cl, tokA, blob1)["refcount"] == 2)
u_after = usage(cl, op, tidA)["dedup"]
case("rollback: physical unchanged, logical += len(P1) (one physical copy for v1+v3)",
     u_after["physical_bytes"] == u_before["physical_bytes"] and u_after["logical_bytes"] == u_before["logical_bytes"] + len(P1),
     (u_before, u_after))
case("rollback: exactly 2 physical files for tenant A (P1, P2)", len(fs_files(datadir, tidA)) == 2, fs_files(datadir, tidA))
s, _, _, raw = cl.j("GET", "/v1/content/%s/download" % item_guide, token=tokA)
case("download: current bytes == P1 (rolled back)", s == 200 and raw == P1, s)
s, h, _, raw = cl.j("GET", "/v1/content/%s/versions/2/download" % item_guide, token=tokA)
case("download: version 2 bytes == P2 + sha header", s == 200 and raw == P2 and h.get("X-Snowfell-SHA256") == sha(P2), (s, h.get("X-Snowfell-SHA256")))
s, _, _, raw = cl.j("GET", "/v1/content/%s/versions/1/download" % item_guide, token=tokA)
case("download: version 1 bytes == P1", s == 200 and raw == P1, s)
s, _, d, _ = cl.j("GET", "/v1/content/%s/versions/99/download" % item_guide, token=tokA)
case("download: missing version -> 404", s == 404, (s, d))
s, _, d, _ = cl.j("POST", "/v1/content/%s/rollback" % item_guide, token=tokA, body={"version_no": 99})
case("rollback: missing target version -> 404", s == 404, (s, d))

# ---- state transitions + audit
s, _, d, _ = cl.j("POST", "/v1/content/%s/state" % item_guide, token=tokA, body={"state": "published"})
case("state: draft -> published", s == 200 and d["data"]["state"] == "published", (s, d))
s, _, d, _ = cl.j("POST", "/v1/content/%s/state" % item_guide, token=tokA, body={"state": "bogus"})
case("state: invalid state -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))
s, _, d, _ = cl.j("POST", "/v1/content/%s/state" % item_guide, token=tokA, body={"state": "archived"})
case("state: published -> archived", s == 200 and d["data"]["state"] == "archived", (s, d))
def audit_rows(action):
    s, _, d, _ = cl.j("GET", "/v1/audit?action=%s&limit=200" % action, token=tokA)
    assert s == 200, (s, d)
    return d["data"]
rows = audit_rows("content.state")
case("audit: content.state rows exist with state detail + opaque actor",
     any(r["result"] == "ok" and r["detail"].get("state") == "published" for r in rows)
     and all(r["actor_ref"].startswith("login:") for r in rows), rows[:3])
case("audit: content.create / version_create / rollback rows exist",
     len(audit_rows("content.create")) >= 1 and len(audit_rows("content.version_create")) >= 1
     and len(audit_rows("content.rollback")) >= 1)

# ---- refs
blob3, _ = upload_blob(cl, tokA, P3)
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "related-doc", "title": "Related Doc", "kind": "document", "blob_id": blob2})
item_rel = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/content/%s/refs" % item_guide, token=tokA,
                  body={"to_item_id": item_rel, "kind": "related"})
case("refs: item->item create 201", s == 201 and d["data"]["to_item_id"] == item_rel and d["data"]["to_blob_id"] is None, (s, d))
s, _, d, _ = cl.j("POST", "/v1/content/%s/refs" % item_guide, token=tokA,
                  body={"to_blob_id": blob3, "kind": "attachment"})
case("refs: item->blob create 201", s == 201 and d["data"]["to_blob_id"] == blob3, (s, d))
ref_blob = d["data"]["id"]
case("refs: blob target refcount 0 -> 1", blob_meta(cl, tokA, blob3)["refcount"] == 1)
s, _, d, _ = cl.j("POST", "/v1/content/%s/refs" % item_guide, token=tokA,
                  body={"to_item_id": item_rel, "to_blob_id": blob3})
case("refs: both targets -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))
s, _, d, _ = cl.j("POST", "/v1/content/%s/refs" % item_guide, token=tokA, body={"kind": "none"})
case("refs: neither target -> 400 validation", s == 400 and d["error"]["code"] == "validation", (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/refs" % item_guide, token=tokA)
case("refs: list shows 2", s == 200 and len(d["data"]) == 2, (s, d))
ref_item = [r for r in d["data"] if r["to_item_id"] == item_rel][0]["id"]
s, _, d, _ = cl.j("DELETE", "/v1/content/%s/refs/%s" % (item_guide, ref_blob), token=tokA)
case("refs: DELETE blob ref 200", s == 200 and d["data"]["deleted"] is True, (s, d))
case("refs: blob refcount back to 0 + orphaned", blob_meta(cl, tokA, blob3)["refcount"] == 0 and bool(blob_meta(cl, tokA, blob3)["orphaned_at"]))
s, _, d, _ = cl.j("DELETE", "/v1/content/%s/refs?ref_id=%s" % (item_guide, ref_item), token=tokA)
case("refs: DELETE item ref via ?ref_id= 200", s == 200, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/refs" % item_guide, token=tokA)
case("refs: list empty after deletes", s == 200 and d["data"] == [], (s, d))

# ---- search
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "percent-plan", "title": "Percent Plan", "kind": "text",
    "metadata": {"tag": "100% coverage"}, "blob_id": blob2})
item_pct = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "thousand", "title": "1000 items inventory", "kind": "text", "blob_id": blob2})
item_1000 = d["data"]["id"]
def search(qs, tok=tokA):
    s, _, d, _ = cl.j("GET", "/v1/search/content?%s" % qs, token=tok)
    assert s == 200, (s, d)
    return [r["slug"] for r in d["data"]]
slugs = search("q=100%25")
case("search: q containing % matches literally (percent-plan + guide via metadata; '1000 items' excluded)",
     "percent-plan" in slugs and "guide" in slugs and "thousand" not in slugs, slugs)
slugs = search("kind=text")
case("search: kind filter", set(slugs) == {"percent-plan", "thousand"}, slugs)
slugs = search("state=archived")
case("search: state filter", slugs == ["guide"], slugs)
slugs = search("collection_id=%s" % coll_child)
case("search: collection filter", "guide" in slugs and "percent-plan" not in slugs and "thousand" not in slugs, slugs)
slugs = search("q=guide")
case("search: q substring over slug/title", "guide" in slugs, slugs)
s, _, d, _ = cl.j("GET", "/v1/content?state=draft", token=tokA)
case("list: GET /v1/content with state filter", s == 200 and all(r["state"] == "draft" for r in d["data"]) and len(d["data"]) >= 3, (s, d))

# ---- collection cleanup (delete succeeds once empty)
s, _, d, _ = cl.j("POST", "/v1/collections", token=tokA, body={"name": "Temp", "slug": "temp-coll"})
coll_tmp = d["data"]["id"]
s, _, d, _ = cl.j("DELETE", "/v1/collections/%s" % coll_tmp, token=tokA)
case("collections: DELETE empty collection 200", s == 200 and d["data"]["deleted"] is True, (s, d))
s, _, d, _ = cl.j("PATCH", "/v1/content/%s" % item_guide, token=tokA, body={"collection_id": None})
s2, _, d2, _ = cl.j("DELETE", "/v1/collections/%s" % coll_child, token=tokA)
case("collections: DELETE child once its item moved out -> 200", s == 200 and s2 == 200, (s, s2, d2))
s, _, d, _ = cl.j("DELETE", "/v1/collections/%s" % coll_parent, token=tokA)
case("collections: DELETE parent once child gone -> 200", s == 200, (s, d))

# ---- item delete -> versions gone, blob orphaned, GC reclaims
blob4, _ = upload_blob(cl, tokA, P4)
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "ephemeral", "title": "Ephemeral", "kind": "text", "blob_id": blob4})
item_eph = d["data"]["id"]
case("delete setup: ephemeral v1 bumped blob4 refcount to 1", blob_meta(cl, tokA, blob4)["refcount"] == 1)
s, _, d, _ = cl.j("DELETE", "/v1/content/%s" % item_eph, token=tokA)
case("delete: item DELETE 200 with slug", s == 200 and d["data"]["deleted"] is True and d["data"]["slug"] == "ephemeral", (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s" % item_eph, token=tokA)
case("delete: item gone (404)", s == 404, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/versions" % item_eph, token=tokA)
case("delete: versions gone (404)", s == 404, (s, d))
m4 = blob_meta(cl, tokA, blob4)
case("delete: blob4 orphaned (refcount 0 + orphaned_at)", m4["refcount"] == 0 and bool(m4["orphaned_at"]), m4)
rows = audit_rows("content.delete")
case("audit: content.delete row carries the slug", any(r["detail"].get("slug") == "ephemeral" for r in rows), rows[:3])
s, _, d, _ = cl.j("POST", "/v1/gc", token=tokA, body={"dry_run": True})
case("GC dry-run after delete: deleted=0", s == 200 and d["data"]["deleted"] == 0 and d["data"]["orphans"] >= 2, (s, d))
s, _, d, _ = cl.j("POST", "/v1/gc", token=tokA, body={})
case("GC: reclaims orphaned blobs (P3 ref + P4 item), bytes exact",
     s == 200 and d["data"]["deleted"] == 2 and d["data"]["bytes_reclaimed"] == len(P3) + len(P4), (s, d))
s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % blob4, token=tokA)
case("GC: blob4 row gone (404)", s == 404, (s, d))
s, _, d, _ = cl.j("GET", "/v1/blobs/%s/meta" % blob3, token=tokA)
case("GC: blob3 row gone (404)", s == 404, (s, d))

# ---- isolation battery: tenant B against A everywhere
s, _, d, _ = cl.j("POST", "/v1/collections", token=tokA, body={"name": "Iso", "slug": "iso-coll"})
coll_iso = d["data"]["id"]
s, _, d, _ = cl.j("POST", "/v1/content/%s/refs" % item_guide, token=tokA, body={"to_item_id": item_rel, "kind": "related"})
ref_iso = d["data"]["id"]
s, _, before, _ = cl.j("GET", "/v1/content/%s" % item_guide, token=tokA)
before = before["data"]
iso = []
def probe(name, method, path, body=None):
    s, _, d, _ = cl.j(method, path, token=tokB, body=body)
    iso.append((name, s))
probe("collection GET", "GET", "/v1/collections/%s" % coll_iso)
probe("collection PATCH", "PATCH", "/v1/collections/%s" % coll_iso, {"name": "Hax"})
probe("collection DELETE", "DELETE", "/v1/collections/%s" % coll_iso)
probe("content GET", "GET", "/v1/content/%s" % item_guide)
probe("content PATCH", "PATCH", "/v1/content/%s" % item_guide, {"title": "Hax"})
probe("content DELETE", "DELETE", "/v1/content/%s" % item_guide)
probe("versions GET", "GET", "/v1/content/%s/versions" % item_guide)
probe("versions POST (own blob)", "POST", "/v1/content/%s/versions" % item_guide, {"blob_id": blobB1})
probe("rollback POST", "POST", "/v1/content/%s/rollback" % item_guide, {"version_no": 1})
probe("state POST", "POST", "/v1/content/%s/state" % item_guide, {"state": "draft"})
probe("download GET", "GET", "/v1/content/%s/download" % item_guide)
probe("version download GET", "GET", "/v1/content/%s/versions/1/download" % item_guide)
probe("refs GET", "GET", "/v1/content/%s/refs" % item_guide)
probe("refs POST", "POST", "/v1/content/%s/refs" % item_guide, {"to_item_id": item_b})
probe("refs DELETE", "DELETE", "/v1/content/%s/refs/%s" % (item_guide, ref_iso))
probe("version append cross-blob (B item, A blob)", "POST", "/v1/content/%s/versions" % item_b, {"blob_id": blob1})
probe("collection create under A parent", "POST", "/v1/collections", {"name": "X", "slug": "x-coll", "parent_id": coll_iso})
bad = [(n, s) for n, s in iso if s != 404]
case("isolation: every B->A route probe -> 404", not bad, bad)
s, _, d, _ = cl.j("GET", "/v1/collections", token=tokB)
case("isolation: B collection list has none of A's", s == 200 and all(c["id"] != coll_iso for c in d["data"]), (s, d))
s, _, d, _ = cl.j("GET", "/v1/content", token=tokB)
case("isolation: B content list has none of A's", s == 200 and all(r["id"] != item_guide for r in d["data"]), (s, d))
slugs_b = search("q=Guide", tok=tokB)
case("isolation: B search for A's title -> empty", slugs_b == [], slugs_b)
slugs_b = search("q=100%25", tok=tokB)
case("isolation: B search q=100% -> empty", slugs_b == [], slugs_b)
s, _, d, _ = cl.j("GET", "/v1/content/%s" % item_guide, token=tokA)
case("isolation: A's item untouched after battery",
     s == 200 and d["data"]["title"] == before["title"] and d["data"]["state"] == before["state"]
     and d["data"]["current_version"]["version_no"] == 3, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/versions" % item_guide, token=tokA)
case("isolation: A's versions untouched (still 3)", s == 200 and len(d["data"]) == 3, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/refs" % item_guide, token=tokA)
case("isolation: A's refs untouched (still 1)", s == 200 and len(d["data"]) == 1, (s, d))
s, _, d, _ = cl.j("GET", "/v1/collections/%s" % coll_iso, token=tokA)
case("isolation: A's collection untouched", s == 200 and d["data"]["name"] == "Iso", (s, d))

# ---- corrupt blob download -> 502 blob_integrity
blob5, _ = upload_blob(cl, tokA, P5)
s, _, d, _ = cl.j("POST", "/v1/content", token=tokA, body={
    "slug": "fragile", "title": "Fragile", "kind": "text", "blob_id": blob5})
item_frag = d["data"]["id"]
target = None
for f in fs_files(datadir, tidA):
    if open(f, "rb").read() == P5: target = f
assert target, fs_files(datadir, tidA)
with open(target, "r+b") as fh:
    fh.write(bytes([P5[0] ^ 0xFF]))
s, _, d, _ = cl.j("POST", "/v1/blobs/%s/verify" % blob5, token=tokA)
case("corrupt setup: verify flags the blob", s == 200 and d["data"]["verified"] is False, (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/download" % item_frag, token=tokA)
case("corrupt: current download -> 502 blob_integrity", s == 502 and d["error"]["code"] == "blob_integrity", (s, d))
s, _, d, _ = cl.j("GET", "/v1/content/%s/versions/1/download" % item_frag, token=tokA)
case("corrupt: by-version download -> 502 blob_integrity", s == 502 and d["error"]["code"] == "blob_integrity", (s, d))

proc.terminate(); proc.wait(timeout=10)
print("SF-T12i CHECK: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)

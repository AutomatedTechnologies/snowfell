#!/usr/bin/env python3
"""Snowfell SF-T4 headless smoke check — the write-back queue, proven
against THROWAWAY copies only.

Mirrors WriteBackQueue's schema + enqueue/list SQL exactly (the same
relationship smoke_check.py has to SnapshotStore): it creates a temp
writable store, enqueues one mutation of each D3 kind with payloads built
from REAL snapshot data (user board #3's Status field/option GitHub IDs,
a real item, a real Issue's repo+number), reads them back, and verifies:

  * all three rows are state=pending, attempts=0, FIFO order preserved
  * payload_json round-trips byte-for-byte through JSON encode/decode
  * one local_audit_log row exists per enqueue (action writeback.enqueue)
  * a fourth kind is refused by the schema's CHECK (the D3 fence)
  * the snapshot copy's SHA-256 is identical before/after ALL queue work
  * the BUNDLED snapshot's SHA-256 is identical before/after the run
    (the queue never even opens it — it hashes the file only)

No app, no network, no token. Usage: python3 smoke_writeback.py
"""
import hashlib
import json
import shutil
import sqlite3
import tempfile
from pathlib import Path

SNAPSHOT = Path(__file__).parent / "Snowfell" / "Resources" / "registry.db"

# WriteBackQueue's schema, verbatim (WriteBackQueue.m ensureSchema).
SCHEMA = """
CREATE TABLE IF NOT EXISTS writeback_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('status_move','create_item','comment')),
  board_id TEXT NOT NULL,
  item_id TEXT,
  payload_json TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','sending','sent','failed')),
  created_at TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);
CREATE TABLE IF NOT EXISTS local_audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  object_ref TEXT,
  before_json TEXT,
  after_json TEXT
);
"""

ENQUEUE_SQL = """
INSERT INTO writeback_queue (kind, board_id, item_id, payload_json, state, created_at, attempts, last_error)
VALUES (?, ?, ?, ?, 'pending', ?, 0, NULL)
"""

AUDIT_SQL = """
INSERT INTO local_audit_log (ts, actor, action, object_ref, before_json, after_json)
VALUES (?, 'Snowfell (local user)', 'writeback.enqueue', ?, NULL, ?)
"""

LIST_SQL = """
SELECT id, kind, board_id, item_id, payload_json, state, created_at, attempts, last_error
FROM writeback_queue ORDER BY id ASC
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    bundled_before = sha256(SNAPSHOT)
    print(f"bundled snapshot sha256 (before): {bundled_before}")

    workdir = Path(tempfile.mkdtemp(prefix="snowfell-writeback-smoke-"))
    snapshot_copy = workdir / "registry-copy.db"
    shutil.copyfile(SNAPSHOT, snapshot_copy)
    copy_before = sha256(snapshot_copy)
    assert copy_before == bundled_before, "copy must start identical"

    # --- real addressing data from the throwaway snapshot copy ---------
    snap = sqlite3.connect(f"file:{snapshot_copy}?mode=ro", uri=True)
    board_id, board_title = snap.execute(
        "SELECT gh_node_id, title FROM sf_boards WHERE owner_type='user' AND number=3"
    ).fetchone()
    field_gh_id = snap.execute(
        "SELECT gh_field_id FROM sf_fields WHERE board_id=? AND name='Status'",
        (board_id,),
    ).fetchone()[0]
    options = snap.execute(
        """
        SELECT o.gh_option_id, o.name FROM sf_field_options o
        JOIN sf_fields f ON f.id = o.field_id
        WHERE f.board_id=? AND f.name='Status' ORDER BY o.position
        """,
        (board_id,),
    ).fetchall()
    option_by_name = {name: gh for gh, name in options}
    item_id, item_title, from_status = snap.execute(
        """
        SELECT i.gh_node_id, i.title, v.option_name FROM sf_items i
        JOIN sf_item_values v ON v.item_id = i.gh_node_id
        JOIN sf_fields f ON f.id = v.field_id AND f.name='Status'
        WHERE i.board_id=? AND v.option_name='Todo' LIMIT 1
        """,
        (board_id,),
    ).fetchone()
    issue = snap.execute(
        """
        SELECT gh_node_id, title, content_repo, content_number FROM sf_items
        WHERE board_id=? AND content_kind='Issue' AND content_repo IS NOT NULL LIMIT 1
        """,
        (board_id,),
    ).fetchone()
    snap.close()
    print(f"board: user #3 — {board_title} ({board_id})")
    print(f"Status field gh id: {field_gh_id}; options: {[(n, g) for g, n in options]}")

    # --- the writable store (temp) --------------------------------------
    queue_path = workdir / "writeback.db"
    queue = sqlite3.connect(queue_path)
    queue.executescript(SCHEMA)
    now = "2026-11-10T19:00:00Z"

    payloads = [
        ("status_move", board_id, item_id, {
            "field_id": field_gh_id,
            "option_id": option_by_name["In Progress"],
            "option_name": "In Progress",
            "from_option_name": from_status,
            "item_title": item_title,
        }),
        ("create_item", board_id, None, {
            "title": "SF-T4 smoke: queued draft (never sent)",
            "field_id": field_gh_id,
            "option_id": option_by_name["Done"],
            "option_name": "Done",
        }),
        ("comment", board_id, issue[0], {
            "body": "SF-T4 smoke comment — queued locally, never posted.",
            "item_title": issue[1],
            "content_kind": "Issue",
            "content_repo": issue[2],
            "content_number": issue[3],
        }),
    ]
    enqueued = []
    for kind, b, i, payload in payloads:
        payload_json = json.dumps(payload, sort_keys=True)
        cur = queue.execute(ENQUEUE_SQL, (kind, b, i, payload_json, now))
        queue.execute(AUDIT_SQL, (now, f"writeback_queue:{cur.lastrowid}",
                                  json.dumps({"kind": kind, "state": "pending"}, sort_keys=True)))
        enqueued.append((kind, payload_json))
    queue.commit()
    print(f"enqueued 3 mutations into temp store {queue_path.name}")

    # --- read back + verify ---------------------------------------------
    rows = queue.execute(LIST_SQL).fetchall()
    assert len(rows) == 3, f"expected 3 rows, got {len(rows)}"
    assert [r[1] for r in rows] == [k for k, _ in enqueued], "FIFO order broken"
    for row, (kind, payload_json) in zip(rows, enqueued):
        rid, rkind, rb, ri, rpj, state, created, attempts, last_error = row
        assert state == "pending" and attempts == 0 and last_error is None, row
        assert rpj == payload_json, f"payload bytes differ for {kind}"
        assert json.loads(rpj) == json.loads(payload_json), f"payload round-trip failed for {kind}"
        print(f"  row {rid}: {rkind} state=pending attempts=0 payload round-trip OK")

    audits = queue.execute(
        "SELECT COUNT(*) FROM local_audit_log WHERE action='writeback.enqueue'"
    ).fetchone()[0]
    assert audits == 3, f"expected 3 audit rows, got {audits}"
    print("audit rows (writeback.enqueue): 3")

    # The D3 fence: a fourth kind must be refused by the schema itself.
    try:
        queue.execute(ENQUEUE_SQL, ("delete_item", board_id, item_id, "{}", now))
        queue.commit()
        raise AssertionError("schema accepted a fourth kind — D3 fence broken")
    except sqlite3.IntegrityError:
        queue.rollback()
        print("D3 fence: kind 'delete_item' refused by CHECK constraint OK")
    queue.close()

    # --- the snapshot was never touched ----------------------------------
    copy_after = sha256(snapshot_copy)
    bundled_after = sha256(SNAPSHOT)
    assert copy_after == copy_before, "snapshot COPY hash changed during queue work"
    assert bundled_after == bundled_before, "BUNDLED snapshot hash changed during the run"
    print(f"snapshot copy sha256 unchanged: {copy_after}")
    print(f"bundled snapshot sha256 unchanged: {bundled_after}")
    print("SMOKE OK — queue is local, payloads round-trip, snapshot pristine")


if __name__ == "__main__":
    main()

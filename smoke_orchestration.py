#!/usr/bin/env python3
"""Snowfell SF-T5 headless smoke check — the Orchestration Center's two
lanes, proven against THROWAWAY copies only.

Mirrors DispatchStore's + WriteBackQueue's schemas and SQL exactly (the
same relationship smoke_writeback.py has to SF-T4), in ONE temp store
file — the same arrangement the app uses (local_dispatches and
writeback_queue as sibling table sets in writeback.db, sharing
local_audit_log). It:

  * classifies all sf_actions from the snapshot by the lane rule
    (15 at snapshot v7-0026; 20 at v7-0031 — the five incident.*
    actions of design §12.2 join the estate lane; counts are read
    from the snapshot, never hardcoded)
    OrchestrationViewController implements (+actionUsesGitHubLane:) and
    prints the full table — exactly one action may take the GitHub lane
  * enqueues one ESTATE-lane dispatch (media.convert.proxy) into
    local_dispatches, verifies the payload JSON round-trip, the generic
    transition path (a second dispatch, queued -> approved), and the
    cancel path (queued -> cancelled), with one audit row per event
  * enqueues one GITHUB-lane D3-mapped action (gh.project.move_item,
    translated through the snapshot's StatusField GitHub IDs exactly as
    the composer translates it) into writeback_queue as a status_move
    and verifies its round-trip + writeback.enqueue audit row
  * verifies the snapshot copy's SHA-256 is identical before/after ALL
    store work, and the BUNDLED snapshot's hash never changes

No app, no network, no token, no execution of anything queued.
Usage: python3 smoke_orchestration.py
"""
import hashlib
import json
import shutil
import sqlite3
import tempfile
from pathlib import Path

SNAPSHOT = Path(__file__).parent / "Snowfell" / "Resources" / "registry.db"

# WriteBackQueue's schema, verbatim (WriteBackQueue.m ensureSchema).
WRITEBACK_SCHEMA = """
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

# DispatchStore's schema, verbatim (DispatchStore.m ensureSchema) — note
# the shared local_audit_log CREATE IF NOT EXISTS: whichever store opens
# first creates it, the other reuses it.
DISPATCH_SCHEMA = """
CREATE TABLE IF NOT EXISTS local_dispatches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued','approved','sent_to_lane','done','failed','cancelled')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  result_ref TEXT,
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

DISPATCH_ENQUEUE_SQL = """
INSERT INTO local_dispatches (action_id, payload_json, state, created_at, updated_at, result_ref, last_error)
VALUES (?, ?, 'queued', ?, ?, NULL, NULL)
"""

DISPATCH_TRANSITION_SQL = """
UPDATE local_dispatches SET state = ?, updated_at = ?, result_ref = COALESCE(?, result_ref) WHERE id = ?
"""

DISPATCH_CANCEL_SQL = """
UPDATE local_dispatches SET state = 'cancelled', updated_at = ? WHERE id = ? AND state = 'queued'
"""

WRITEBACK_ENQUEUE_SQL = """
INSERT INTO writeback_queue (kind, board_id, item_id, payload_json, state, created_at, attempts, last_error)
VALUES (?, ?, ?, ?, 'pending', ?, 0, NULL)
"""

AUDIT_SQL = """
INSERT INTO local_audit_log (ts, actor, action, object_ref, before_json, after_json)
VALUES (?, 'Snowfell (local user)', ?, ?, ?, ?)
"""

NOW = "2026-11-10T19:45:00Z"

# The lane rule, mirroring OrchestrationViewController
# +actionUsesGitHubLane: — the GitHub lane (SF-T4 WriteBackQueue) is
# taken ONLY by a manifest action that maps exactly onto a D3 operation.
GITHUB_LANE_ACTIONS = {"gh.project.move_item"}


def lane_for(action_id):
    return "github" if action_id in GITHUB_LANE_ACTIONS else "estate"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    bundled_before = sha256(SNAPSHOT)
    print(f"bundled snapshot sha256 (before): {bundled_before}")

    workdir = Path(tempfile.mkdtemp(prefix="snowfell-orchestration-smoke-"))
    snapshot_copy = workdir / "registry-copy.db"
    shutil.copyfile(SNAPSHOT, snapshot_copy)
    copy_before = sha256(snapshot_copy)
    assert copy_before == bundled_before, "copy must start identical"

    # --- real data from the throwaway snapshot copy --------------------
    snap = sqlite3.connect(f"file:{snapshot_copy}?mode=ro", uri=True)
    actions = snap.execute(
        "SELECT id, kind FROM sf_actions ORDER BY id"
    ).fetchall()
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
    target_id = snap.execute(
        "SELECT id FROM sf_deploy_targets WHERE id='instagram:justinspencersmith'"
    ).fetchone()[0]
    snap.close()

    # --- the lane table for every manifest action in the snapshot -----
    assert len(actions) >= 15, f"expected at least the 15 SF-T1 actions, got {len(actions)}"
    lanes = {aid: lane_for(aid) for aid, _ in actions}
    github = [a for a, lane in lanes.items() if lane == "github"]
    assert github == ["gh.project.move_item"], f"GitHub lane must be exactly one action, got {github}"
    incident_actions = [aid for aid, _ in actions if aid.startswith("incident.")]
    print(f"lane table ({len(actions)} actions from the snapshot manifest; "
          f"{len(incident_actions)} incident.* on the estate lane):")
    for aid, kind in actions:
        print(f"  {aid:<28} kind={kind:<24} lane={lanes[aid]}")
    print(f"deploy target present for composer dropdowns: {target_id}")

    # --- ONE writable store file, both table sets ----------------------
    store_path = workdir / "writeback.db"
    store = sqlite3.connect(store_path)
    store.executescript(WRITEBACK_SCHEMA)
    store.executescript(DISPATCH_SCHEMA)  # shared audit table: no conflict
    print(f"one store file holds both table sets + shared local_audit_log: {store_path.name}")

    # --- estate lane: media.convert.proxy ------------------------------
    proxy_payload = {"asset_id": 1, "profile": "proxy720"}
    proxy_json = json.dumps(proxy_payload, sort_keys=True)
    cur = store.execute(DISPATCH_ENQUEUE_SQL, ("media.convert.proxy", proxy_json, NOW, NOW))
    proxy_id = cur.lastrowid
    store.execute(AUDIT_SQL, (NOW, "dispatch.enqueue", f"local_dispatches:{proxy_id}", None,
                              json.dumps({"action_id": "media.convert.proxy",
                                          "payload": proxy_payload, "state": "queued"}, sort_keys=True)))
    row = store.execute(
        "SELECT action_id, payload_json, state FROM local_dispatches WHERE id=?", (proxy_id,)
    ).fetchone()
    assert row[0] == "media.convert.proxy" and row[2] == "queued", row
    assert row[1] == proxy_json and json.loads(row[1]) == proxy_payload, "payload round-trip failed"
    print(f"  estate dispatch #{proxy_id}: media.convert.proxy state=queued payload round-trip OK")

    # generic transition path: queued -> approved on a second dispatch
    task_payload = {"brief": "SF-T5 smoke: estate agent task (never executed)", "goal_ref": "snowfell"}
    cur = store.execute(DISPATCH_ENQUEUE_SQL, ("estate.agent_task", json.dumps(task_payload, sort_keys=True), NOW, NOW))
    task_id = cur.lastrowid
    store.execute(AUDIT_SQL, (NOW, "dispatch.enqueue", f"local_dispatches:{task_id}", None,
                              json.dumps({"action_id": "estate.agent_task", "state": "queued"}, sort_keys=True)))
    store.execute(DISPATCH_TRANSITION_SQL, ("approved", NOW, None, task_id))
    store.execute(AUDIT_SQL, (NOW, "dispatch.transition", f"local_dispatches:{task_id}",
                              json.dumps({"state": "queued"}, sort_keys=True),
                              json.dumps({"state": "approved", "result_ref": None}, sort_keys=True)))
    state = store.execute("SELECT state FROM local_dispatches WHERE id=?", (task_id,)).fetchone()[0]
    assert state == "approved", state
    print(f"  estate dispatch #{task_id}: estate.agent_task queued -> approved (generic transition) OK")

    # cancel path: queued -> cancelled (the proxy dispatch)
    store.execute(DISPATCH_CANCEL_SQL, (NOW, proxy_id))
    store.execute(AUDIT_SQL, (NOW, "dispatch.cancel", f"local_dispatches:{proxy_id}",
                              json.dumps({"state": "queued"}, sort_keys=True),
                              json.dumps({"state": "cancelled"}, sort_keys=True)))
    state = store.execute("SELECT state FROM local_dispatches WHERE id=?", (proxy_id,)).fetchone()[0]
    assert state == "cancelled", state
    print(f"  estate dispatch #{proxy_id}: queued -> cancelled OK")

    # cancel of a non-queued row must be a no-op at the SQL guard
    cur = store.execute(DISPATCH_CANCEL_SQL, (NOW, task_id))
    assert cur.rowcount == 0, "cancel guard let a non-queued row through"
    print("  cancel guard: approved row refused by the state='queued' guard OK")

    dispatch_audits = store.execute(
        "SELECT COUNT(*) FROM local_audit_log WHERE action LIKE 'dispatch.%'"
    ).fetchone()[0]
    assert dispatch_audits == 4, f"expected 4 dispatch.* audit rows, got {dispatch_audits}"
    print("audit rows (dispatch.enqueue x2, dispatch.transition, dispatch.cancel): 4")

    # --- github lane: gh.project.move_item -> status_move ---------------
    move_payload = {
        "field_id": field_gh_id,
        "option_id": option_by_name["In Progress"],
        "option_name": "In Progress",
        "from_option_name": from_status,
        "item_title": item_title,
    }
    move_json = json.dumps(move_payload, sort_keys=True)
    cur = store.execute(WRITEBACK_ENQUEUE_SQL, ("status_move", board_id, item_id, move_json, NOW))
    move_row_id = cur.lastrowid
    store.execute(AUDIT_SQL, (NOW, "writeback.enqueue", f"writeback_queue:{move_row_id}", None,
                              json.dumps({"kind": "status_move", "state": "pending"}, sort_keys=True)))
    row = store.execute(
        "SELECT kind, board_id, item_id, payload_json, state FROM writeback_queue WHERE id=?",
        (move_row_id,),
    ).fetchone()
    assert row[0] == "status_move" and row[1] == board_id and row[2] == item_id and row[4] == "pending", row
    assert row[3] == move_json and json.loads(row[3]) == move_payload, "move payload round-trip failed"
    print(f"  github dispatch (writeback row #{move_row_id}): gh.project.move_item -> status_move "
          f"state=pending payload round-trip OK (board user #3 — {board_title}; item “{item_title}”: "
          f"{from_status} -> In Progress, field {field_gh_id})")
    wb_audits = store.execute(
        "SELECT COUNT(*) FROM local_audit_log WHERE action='writeback.enqueue'"
    ).fetchone()[0]
    assert wb_audits == 1, f"expected 1 writeback.enqueue audit row, got {wb_audits}"
    print("audit rows (writeback.enqueue): 1 — both lanes write the ONE local_audit_log")
    store.close()

    # --- the snapshot was never touched ---------------------------------
    copy_after = sha256(snapshot_copy)
    bundled_after = sha256(SNAPSHOT)
    assert copy_after == copy_before, "snapshot COPY hash changed during store work"
    assert bundled_after == bundled_before, "BUNDLED snapshot hash changed during the run"
    print(f"snapshot copy sha256 unchanged: {copy_after}")
    print(f"bundled snapshot sha256 unchanged: {bundled_after}")
    print("SMOKE OK — two lanes enqueue locally, states transition + cancel under audit, snapshot pristine")


if __name__ == "__main__":
    main()

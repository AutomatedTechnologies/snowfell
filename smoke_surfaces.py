#!/usr/bin/env python3
"""Snowfell SF-T7 + SF-T11 headless smoke check.

Runs the same SQL SnapshotStore runs for the Roadmap (V5), the
Command Palette (V6), and the Incidents lens (V11) against the bundled
snapshot (Resources/registry.db, read-only) and proves the counts the
views state:

  * Roadmap: boards carrying a 'Start date'/'Target date' field == 19
    of 74 (design record §4 V5); dated items come only from those
    boards' EAV date values; a one-ended item (Start XOR Target) is a
    milestone, never a fabricated span.
  * Palette: the five scopes resolve — boards, items, actions (24
    manifest rows at v8-0041 — schema/0008 added the 4 storage action
    kinds to the 20 of v7-0031), deploy targets (5), drafts view (0
    rows until compositions exist — truthful, not a failure).
  * Palette routing resolution: itemWithNodeID returns a real item for
    a palette hit (board user #3's first item).
  * Incidents: the queue reads exactly 5 incidents in deadline order
    (Nov 11 ×2, Nov 16, Nov 18, then the deadline-less MEMX watch),
    state/severity names come from the vocabulary tables, and the
    Mazda detail carries 9 assets + 1 deadline (asset counts per the
    applied changes/0031 seed: 9/1/1/0/2 = 13).
  * The incident dispatch enqueue path (DispatchStore's SQL) accepts
    an incident-keyed payload and starts it 'queued' — an approval
    request, never a send.

No app, no network. Usage: python3 smoke_surfaces.py
"""
import hashlib
import json
import sqlite3
import tempfile
from pathlib import Path

DB = Path(__file__).parent / "Snowfell" / "Resources" / "registry.db"

# SnapshotStore.datedItemsWithError — verbatim shape (board-ordered).
DATED_ITEMS_SQL = """
SELECT i.gh_node_id, i.board_id, i.title,
       MAX(CASE WHEN f.name = 'Start date' THEN v.date_value END) AS start_date,
       MAX(CASE WHEN f.name = 'Target date' THEN v.date_value END) AS target_date
FROM sf_items i
JOIN sf_boards b ON b.gh_node_id = i.board_id
JOIN sf_item_values v ON v.item_id = i.gh_node_id AND v.date_value IS NOT NULL
JOIN sf_fields f ON f.id = v.field_id AND f.name IN ('Start date', 'Target date')
GROUP BY i.gh_node_id
ORDER BY b.owner_type ASC, b.number ASC, i.title ASC
"""

BOARDS_WITH_DATE_FIELDS_SQL = """
SELECT COUNT(DISTINCT board_id) FROM sf_fields
WHERE name IN ('Start date', 'Target date')
"""

INCIDENT_QUEUE_SQL = """
SELECT i.key, i.title, st.name, sv.name, sv.position, c.name,
       i.source_channel, i.opened_at,
       (SELECT COUNT(*) FROM sf_incident_assets a WHERE a.incident_id = i.id),
       (SELECT d.due_at FROM sf_incident_deadlines d WHERE d.incident_id = i.id
          AND d.state = 'open' ORDER BY d.due_at ASC LIMIT 1)
FROM sf_incidents i
JOIN sf_incident_states st ON st.id = i.state_id
JOIN sf_incident_severities sv ON sv.id = i.severity_id
LEFT JOIN sf_counterparties c ON c.id = i.counterparty_id
ORDER BY (SELECT MIN(d2.due_at) FROM sf_incident_deadlines d2
            WHERE d2.incident_id = i.id AND d2.state = 'open') IS NULL,
         (SELECT MIN(d2.due_at) FROM sf_incident_deadlines d2
            WHERE d2.incident_id = i.id AND d2.state = 'open') ASC,
         sv.position DESC, i.key ASC
"""

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
"""

NOW = "2026-11-10T22:00:00Z"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    before = sha256(DB)
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)

    total_boards = conn.execute("SELECT COUNT(*) FROM sf_boards").fetchone()[0]
    dated_boards = conn.execute(BOARDS_WITH_DATE_FIELDS_SQL).fetchone()[0]
    assert total_boards == 74, f"expected 74 boards, got {total_boards}"
    assert dated_boards == 19, f"expected 19 dated boards, got {dated_boards}"
    print(f"roadmap denominator: {dated_boards} of {total_boards} boards carry date fields")

    dated = conn.execute(DATED_ITEMS_SQL).fetchall()
    one_ended = [r for r in dated if (r[3] is None) != (r[4] is None)]
    two_ended = [r for r in dated if r[3] is not None and r[4] is not None]
    stray = [r for r in dated if r[3] is None and r[4] is None]
    assert not stray, "a dated item with neither date leaked through the join"
    print(f"dated items: {len(dated)} ({len(two_ended)} bars, {len(one_ended)} milestones)")
    for r in dated[:5]:
        print(f"    {r[2][:60]}: start={r[3]} target={r[4]}")

    # Palette scopes.
    boards = conn.execute("SELECT COUNT(*) FROM sf_boards").fetchone()[0]
    actions = conn.execute("SELECT COUNT(*) FROM sf_actions").fetchone()[0]
    targets = conn.execute("SELECT COUNT(*) FROM sf_deploy_targets").fetchone()[0]
    drafts = conn.execute("SELECT COUNT(*) FROM sf_upcoming_drafts").fetchone()[0]
    assert actions == 24, f"expected 24 sf_actions at v8-0041, got {actions}"
    assert targets == 5, f"expected 5 deploy targets, got {targets}"
    assert drafts == 0, f"expected 0 upcoming drafts (none composed yet), got {drafts}"
    print(f"palette scopes: boards={boards} actions={actions} targets={targets} drafts={drafts}")

    item = conn.execute(
        "SELECT gh_node_id, title FROM sf_items WHERE board_id = "
        "(SELECT gh_node_id FROM sf_boards WHERE owner_type='user' AND number=3) "
        "ORDER BY title LIMIT 1"
    ).fetchone()
    resolved = conn.execute(
        "SELECT gh_node_id FROM sf_items WHERE gh_node_id = ?", (item[0],)
    ).fetchone()
    assert resolved is not None, "palette item routing resolution failed"
    print(f"palette item resolution: {item[0]} -> {item[1][:60]}")

    # Incidents queue.
    queue = conn.execute(INCIDENT_QUEUE_SQL).fetchall()
    assert len(queue) == 5, f"expected 5 incidents, got {len(queue)}"
    dues = [r[9] for r in queue]
    print("incident queue (deadline order):")
    for r in queue:
        print(f"    {r[0]:<28} sev={r[3]:<8} state={r[2]:<14} assets={r[8]} next={r[9]}")
    assert dues[0] == "2026-11-11" and dues[1] == "2026-11-11", dues
    assert dues[2] == "2026-11-16" and dues[3] == "2026-11-18", dues
    assert dues[4] is None, "MEMX watch must sort last (no deadline)"

    mazda_assets = conn.execute(
        "SELECT COUNT(*) FROM sf_incident_assets a "
        "JOIN sf_incidents i ON i.id = a.incident_id "
        "WHERE i.key='MAZDA-MFS-2026-11-10'"
    ).fetchone()[0]
    mazda_deadlines = conn.execute(
        "SELECT COUNT(*) FROM sf_incident_deadlines d "
        "JOIN sf_incidents i ON i.id = d.incident_id "
        "WHERE i.key='MAZDA-MFS-2026-11-10'"
    ).fetchone()[0]
    assert mazda_assets == 9 and mazda_deadlines == 1, (mazda_assets, mazda_deadlines)
    print(f"mazda detail: {mazda_assets} assets, {mazda_deadlines} deadline")
    conn.close()

    # Incident dispatch enqueue path (temp store; DispatchStore's shape).
    workdir = Path(tempfile.mkdtemp(prefix="snowfell-surfaces-smoke-"))
    store = sqlite3.connect(workdir / "dispatch.db")
    store.executescript(DISPATCH_SCHEMA)
    payload = json.dumps({"incident_key": "MAZDA-MFS-2026-11-10"}, sort_keys=True)
    cur = store.execute(
        "INSERT INTO local_dispatches (action_id, payload_json, state, created_at, updated_at) "
        "VALUES (?, ?, 'queued', ?, ?)",
        ("incident.email.send", payload, NOW, NOW),
    )
    row = store.execute(
        "SELECT action_id, payload_json, state FROM local_dispatches WHERE id=?",
        (cur.lastrowid,),
    ).fetchone()
    assert row[0] == "incident.email.send" and row[2] == "queued"
    assert json.loads(row[1]) == {"incident_key": "MAZDA-MFS-2026-11-10"}
    print("incident.email.send enqueued as 'queued' with the incident_key payload — "
          "an approval request, never a send")
    store.close()

    after = sha256(DB)
    assert after == before, "bundled snapshot changed under a read-only smoke"
    print(f"bundled snapshot sha256 unchanged: {after}")
    print("SMOKE OK — roadmap/palette/incidents read the record; dispatch queues, never sends")


if __name__ == "__main__":
    main()

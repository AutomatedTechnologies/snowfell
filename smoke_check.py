#!/usr/bin/env python3
"""Snowfell SF-T3 headless smoke check.

Proves the V1 column derivation is DATA-driven: it runs the same SQL
SnapshotStore runs against the bundled snapshot (Resources/registry.db,
read-only) and prints the Status columns for two boards whose
vocabularies differ — user board #3 and the KisMac Uplift org board —
plus the per-column item placement counts and the V3 inputs (one item's
EAV rows, the element-handler table). No app, no network.

Usage: python3 smoke_check.py
"""
import sqlite3
from pathlib import Path

DB = Path(__file__).parent / "Snowfell" / "Resources" / "registry.db"

STATUS_OPTIONS_SQL = """
SELECT o.name FROM sf_fields f
JOIN sf_field_options o ON o.field_id = f.id
WHERE f.board_id = ? AND f.name = 'Status'
ORDER BY o.position ASC
"""

STATUS_COUNTS_SQL = """
SELECT v.option_name, COUNT(*) FROM sf_item_values v
JOIN sf_items i ON i.gh_node_id = v.item_id
JOIN sf_fields f ON f.id = v.field_id
WHERE i.board_id = ? AND f.name = 'Status' AND v.option_name IS NOT NULL
GROUP BY v.option_name
"""


def board_columns(conn, owner_type, number):
    row = conn.execute(
        "SELECT gh_node_id, title FROM sf_boards WHERE owner_type = ? AND number = ?",
        (owner_type, number),
    ).fetchone()
    node_id, title = row
    options = [r[0] for r in conn.execute(STATUS_OPTIONS_SQL, (node_id,))]
    counts = dict(conn.execute(STATUS_COUNTS_SQL, (node_id,)).fetchall())
    placed = sum(counts.get(o, 0) for o in options)
    total = conn.execute(
        "SELECT COUNT(*) FROM sf_items WHERE board_id = ?", (node_id,)
    ).fetchone()[0]
    print(f"board {owner_type} #{number} — {title}")
    print(f"  columns (from sf_field_options, position order): {options}")
    for o in options:
        print(f"    {o}: {counts.get(o, 0)} items")
    print(f"  items placed by Status value: {placed} of {total}")
    return node_id


def main():
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    board_columns(conn, "user", 3)
    board_columns(conn, "org", 1)

    handlers = conn.execute(
        "SELECT element_kind, handler_app FROM sf_element_handlers ORDER BY id"
    ).fetchall()
    print(f"element handlers (V3 chips): {len(handlers)} rows")
    for kind, app in handlers:
        print(f"    {kind} -> {app}")

    sample = conn.execute(
        """
        SELECT f.name, v.value_kind, COALESCE(v.option_name, v.text_value,
               v.date_value, v.json_value)
        FROM sf_item_values v JOIN sf_fields f ON f.id = v.field_id
        WHERE v.item_id = (SELECT gh_node_id FROM sf_items
                           WHERE content_kind = 'Issue' LIMIT 1)
        ORDER BY f.position
        """
    ).fetchall()
    print(f"sample Issue item EAV rows (V3 field list): {len(sample)}")
    for name, kind, value in sample:
        print(f"    {name} [{kind}] = {str(value)[:60]}")
    conn.close()


if __name__ == "__main__":
    main()

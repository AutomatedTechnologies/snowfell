#!/usr/bin/env python3
"""Snowfell snowfell-test-8 headless smoke check — the Piles lens
(design record 13), proven against a SCRATCH copy of the local store
plus the bundled snapshot.

Mirrors PileStore's schema and SQL exactly (the same relationship the
other smokes have to their stores): sf_piles / sf_pile_items in a temp
writeback.db-shaped file sharing local_audit_log, with the snapshot
read through the same queries SnapshotStore's public API runs
(portfolioBoards / statusOptionsForBoard / itemsForBoard).

Asserts (design record 13 sections 2-4):
  * materialization places every snapshot item in exactly one pile
    (the UNIQUE(item_node_id) invariant, verified by count + a
    duplicate probe)
  * Inbox count == the snapshot's statusless item count
  * pile counts sum == total snapshot items
  * a move changes exactly one row's pile (totals unchanged)
  * Clear Top lands the top item in the Done pile
  * deleting a custom pile rehomes its items to the Inbox
  * a second reconcile pass adds 0 rows (idempotent)

No app, no network. Usage: python3 smoke_piles.py
"""
import hashlib
import sqlite3
import tempfile
from pathlib import Path

SNAPSHOT = Path(__file__).parent / "Snowfell" / "Resources" / "registry.db"
NOW = "2026-11-15T17:20:00Z"

# PileStore's schema, verbatim (PileStore.m ensureSchema).
PILE_SCHEMA = """
CREATE TABLE IF NOT EXISTS sf_piles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('system_inbox','system_done','board','custom')),
  board_node_id TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sf_pile_items (
  pile_id INTEGER NOT NULL REFERENCES sf_piles(id),
  item_node_id TEXT UNIQUE NOT NULL,
  position INTEGER NOT NULL,
  title TEXT NOT NULL,
  board_title TEXT NOT NULL,
  added_at TEXT NOT NULL
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

AUDIT_SQL = """
INSERT INTO local_audit_log (ts, actor, action, object_ref, before_json, after_json)
VALUES (?, 'Snowfell (local user)', ?, ?, ?, ?)
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class PileMirror:
    """PileStore's materialize / reconcile / move / clear-top /
    create / delete, line for line in SQL terms."""

    def __init__(self, store, snap):
        self.store = store
        self.snap = snap

    # SnapshotStore public queries, mirrored.
    def boards(self):
        return self.snap.execute(
            "SELECT gh_node_id, title FROM sf_boards "
            "ORDER BY closed ASC, archived_hidden ASC, owner_type DESC, number ASC"
        ).fetchall()

    def status_options(self, board_id):
        return [r[0] for r in self.snap.execute(
            "SELECT o.name FROM sf_fields f "
            "JOIN sf_field_options o ON o.field_id = f.id "
            "WHERE f.board_id = ? AND f.name = 'Status' ORDER BY o.position ASC",
            (board_id,))]

    def items_for_board(self, board_id):
        return self.snap.execute(
            "SELECT i.gh_node_id, i.title, sv.option_name FROM sf_items i "
            "LEFT JOIN sf_fields sf ON sf.board_id = i.board_id AND sf.name = 'Status' "
            "LEFT JOIN sf_item_values sv ON sv.item_id = i.gh_node_id AND sv.field_id = sf.id "
            "WHERE i.board_id = ? ORDER BY i.rowid ASC",
            (board_id,)).fetchall()

    def ensure_pile(self, name, kind, board_id=None):
        if kind == "board":
            row = self.store.execute(
                "SELECT id FROM sf_piles WHERE kind = ? AND board_node_id = ?",
                (kind, board_id)).fetchone()
        else:
            row = self.store.execute(
                "SELECT id FROM sf_piles WHERE kind = ?", (kind,)).fetchone()
        if row:
            return row[0]
        cur = self.store.execute(
            "INSERT INTO sf_piles (name, kind, board_node_id, created_at) VALUES (?, ?, ?, ?)",
            (name, kind, board_id, NOW))
        return cur.lastrowid

    def max_position(self, pile_id):
        row = self.store.execute(
            "SELECT MAX(position) FROM sf_pile_items WHERE pile_id = ?",
            (pile_id,)).fetchone()
        return -1 if row[0] is None else row[0]

    def materialize_and_reconcile(self):
        initial = self.store.execute(
            "SELECT COUNT(*) FROM sf_pile_items").fetchone()[0] == 0
        inbox = self.ensure_pile("Inbox", "system_inbox")
        self.ensure_pile("Done", "system_done")
        pile_by_board = {}
        for board_id, title in self.boards():
            pile_by_board[board_id] = self.ensure_pile(title, "board", board_id)
        placed = {r[0] for r in self.store.execute("SELECT item_node_id FROM sf_pile_items")}
        added = 0
        for board_id, board_title in self.boards():
            items = self.items_for_board(board_id)
            if initial:
                rank = {name: i for i, name in enumerate(self.status_options(board_id))}
                board_items = [it for it in items if it[2] is not None and it[0] not in placed]
                inbox_items = [it for it in items if it[2] is None and it[0] not in placed]
                board_items.sort(key=lambda it: rank.get(it[2], len(rank)))  # stable: import order within rank
                pos = self.max_position(pile_by_board[board_id]) + 1
                for node_id, title, _ in board_items:
                    self.store.execute(
                        "INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        (pile_by_board[board_id], node_id, pos, title, board_title, NOW))
                    pos += 1
                    added += 1
                    placed.add(node_id)
                for node_id, title, _ in inbox_items:
                    pos = self.max_position(inbox) + 1
                    self.store.execute(
                        "INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) "
                        "VALUES (?, ?, ?, ?, ?, ?)",
                        (inbox, node_id, pos, title, board_title, NOW))
                    added += 1
                    placed.add(node_id)
            else:
                for node_id, title, status in items:
                    if node_id in placed:
                        continue
                    if status is None:
                        self.store.execute(
                            "UPDATE sf_pile_items SET position = position + 1 WHERE pile_id = ?",
                            (inbox,))
                        self.store.execute(
                            "INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) "
                            "VALUES (?, ?, 0, ?, ?, ?)",
                            (inbox, node_id, title, board_title, NOW))
                    else:
                        pos = self.max_position(pile_by_board[board_id]) + 1
                        self.store.execute(
                            "INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) "
                            "VALUES (?, ?, ?, ?, ?, ?)",
                            (pile_by_board[board_id], node_id, pos, title, board_title, NOW))
                    added += 1
                    placed.add(node_id)
        self.store.execute(AUDIT_SQL, (NOW, "pile.materialize" if initial else "pile.reconcile",
                                       "sf_piles", None, None))
        self.store.commit()
        return added

    def pile_id_for_kind(self, kind):
        return self.store.execute(
            "SELECT id FROM sf_piles WHERE kind = ?", (kind,)).fetchone()[0]

    def move_item(self, item_node_id, dest_pile_id):
        src = self.store.execute(
            "SELECT pile_id FROM sf_pile_items WHERE item_node_id = ?",
            (item_node_id,)).fetchone()[0]
        if src == dest_pile_id:
            return
        pos = self.max_position(dest_pile_id) + 1
        self.store.execute(
            "UPDATE sf_pile_items SET pile_id = ?, position = ? WHERE item_node_id = ?",
            (dest_pile_id, pos, item_node_id))
        remaining = [r[0] for r in self.store.execute(
            "SELECT item_node_id FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC",
            (src,))]
        for i, node_id in enumerate(remaining):
            self.store.execute(
                "UPDATE sf_pile_items SET position = ? WHERE pile_id = ? AND item_node_id = ?",
                (i, src, node_id))
        self.store.execute(AUDIT_SQL, (NOW, "pile.move", f"sf_pile_items:{item_node_id}", None, None))
        self.store.commit()

    def clear_top(self, pile_id):
        row = self.store.execute(
            "SELECT item_node_id FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC LIMIT 1",
            (pile_id,)).fetchone()
        if row is None:
            return False
        self.move_item(row[0], self.pile_id_for_kind("system_done"))
        self.store.execute(AUDIT_SQL, (NOW, "pile.clear_top", f"sf_pile_items:{row[0]}", None, None))
        self.store.commit()
        return True

    def create_pile(self, name):
        cur = self.store.execute(
            "INSERT INTO sf_piles (name, kind, board_node_id, created_at) VALUES (?, 'custom', NULL, ?)",
            (name, NOW))
        self.store.commit()
        return cur.lastrowid

    def delete_pile(self, pile_id):
        inbox = self.pile_id_for_kind("system_inbox")
        items = [r[0] for r in self.store.execute(
            "SELECT item_node_id FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC",
            (pile_id,))]
        pos = self.max_position(inbox) + 1
        for node_id in items:
            self.store.execute(
                "UPDATE sf_pile_items SET pile_id = ?, position = ? WHERE item_node_id = ?",
                (inbox, pos, node_id))
            pos += 1
        self.store.execute("DELETE FROM sf_piles WHERE id = ?", (pile_id,))
        self.store.commit()


def main():
    bundled_before = sha256(SNAPSHOT)
    print(f"bundled snapshot sha256 (before): {bundled_before}")
    snap = sqlite3.connect(f"file:{SNAPSHOT}?mode=ro", uri=True)
    total_items = snap.execute("SELECT COUNT(*) FROM sf_items").fetchone()[0]
    total_boards = snap.execute("SELECT COUNT(*) FROM sf_boards").fetchone()[0]
    statusless = snap.execute(
        "SELECT COUNT(*) FROM sf_items i WHERE NOT EXISTS ("
        "  SELECT 1 FROM sf_item_values v JOIN sf_fields f ON f.id = v.field_id "
        "  WHERE v.item_id = i.gh_node_id AND f.name = 'Status' AND v.option_name IS NOT NULL)"
    ).fetchone()[0]
    print(f"snapshot: {total_boards} boards, {total_items} items, {statusless} statusless")

    workdir = Path(tempfile.mkdtemp(prefix="snowfell-piles-smoke-"))
    store = sqlite3.connect(workdir / "writeback.db")
    store.executescript(PILE_SCHEMA)
    piles = PileMirror(store, snap)

    # --- materialization -------------------------------------------------
    added = piles.materialize_and_reconcile()
    assert added == total_items, f"materialization added {added}, expected {total_items}"
    rows = store.execute("SELECT COUNT(*) FROM sf_pile_items").fetchone()[0]
    distinct = store.execute("SELECT COUNT(DISTINCT item_node_id) FROM sf_pile_items").fetchone()[0]
    assert rows == total_items and distinct == total_items, (rows, distinct)
    print(f"materialization: {added} rows added; every one of {total_items} snapshot items "
          f"in exactly one pile (rows == distinct == total)")

    # the UNIQUE invariant refuses a second placement outright
    any_item = store.execute("SELECT item_node_id, pile_id FROM sf_pile_items LIMIT 1").fetchone()
    try:
        store.execute(
            "INSERT INTO sf_pile_items (pile_id, item_node_id, position, title, board_title, added_at) "
            "VALUES (?, ?, 999, 'dup', 'dup', ?)", (any_item[1], any_item[0], NOW))
        raise AssertionError("UNIQUE(item_node_id) let a duplicate placement through")
    except sqlite3.IntegrityError:
        store.rollback()
        print("invariant: UNIQUE(item_node_id) refuses a second placement OK")

    inbox_id = piles.pile_id_for_kind("system_inbox")
    done_id = piles.pile_id_for_kind("system_done")
    inbox_count = store.execute(
        "SELECT COUNT(*) FROM sf_pile_items WHERE pile_id = ?", (inbox_id,)).fetchone()[0]
    assert inbox_count == statusless, f"Inbox {inbox_count} != statusless {statusless}"
    print(f"inbox: {inbox_count} == statusless item count {statusless}")

    pile_rows = store.execute("SELECT id, kind FROM sf_piles").fetchall()
    board_piles = [r for r in pile_rows if r[1] == "board"]
    assert len(board_piles) == total_boards, (len(board_piles), total_boards)
    summed = store.execute(
        "SELECT COALESCE(SUM(c), 0) FROM (SELECT COUNT(*) AS c FROM sf_pile_items GROUP BY pile_id)"
    ).fetchone()[0]
    assert summed == total_items, (summed, total_items)
    print(f"piles: {len(pile_rows)} total (Inbox + Done + {len(board_piles)} board); "
          f"pile counts sum {summed} == total items {total_items}")

    # board-pile order: Status-vocabulary position first, then import order
    sample_board = snap.execute(
        "SELECT gh_node_id FROM sf_boards WHERE owner_type='user' AND number=3").fetchone()[0]
    options = piles.status_options(sample_board)
    rank = {name: i for i, name in enumerate(options)}
    status_by_item = {r[0]: r[2] for r in piles.items_for_board(sample_board)}
    sample_pile = store.execute(
        "SELECT id FROM sf_piles WHERE kind='board' AND board_node_id = ?",
        (sample_board,)).fetchone()[0]
    ordered = [r[0] for r in store.execute(
        "SELECT item_node_id FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC",
        (sample_pile,))]
    ranks = [rank[status_by_item[n]] for n in ordered]
    assert ranks == sorted(ranks), "board pile is not in Status-vocabulary order"
    print(f"order: board user #3 pile follows its Status vocabulary {options} (positions 0..{len(ordered)-1})")

    # --- reconcile idempotence -------------------------------------------
    added2 = piles.materialize_and_reconcile()
    assert added2 == 0, f"second reconcile added {added2} rows"
    print("reconcile: second pass adds 0 rows (idempotent)")

    # --- move changes exactly one row's pile ------------------------------
    before = dict(store.execute("SELECT item_node_id, pile_id FROM sf_pile_items").fetchall())
    mover = ordered[1] if len(ordered) > 1 else ordered[0]
    piles.move_item(mover, done_id)
    after = dict(store.execute("SELECT item_node_id, pile_id FROM sf_pile_items").fetchall())
    changed = [k for k in before if before[k] != after[k]]
    assert changed == [mover], f"move changed {changed}, expected exactly [{mover}]"
    assert len(after) == total_items
    print("move: exactly one row's pile changed; total rows unchanged")

    # --- Clear Top lands in Done ------------------------------------------
    top = store.execute(
        "SELECT item_node_id FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC LIMIT 1",
        (sample_pile,)).fetchone()[0]
    assert piles.clear_top(sample_pile) is True
    landed = store.execute(
        "SELECT pile_id FROM sf_pile_items WHERE item_node_id = ?", (top,)).fetchone()[0]
    assert landed == done_id, (landed, done_id)
    print("clear top: the sample pile's top item landed in the Done pile")

    # --- delete custom pile rehomes to Inbox -------------------------------
    custom_id = piles.create_pile("Smoke Custom Pile")
    guest = store.execute(
        "SELECT item_node_id FROM sf_pile_items WHERE pile_id = ? ORDER BY position ASC LIMIT 1",
        (sample_pile,)).fetchone()[0]
    piles.move_item(guest, custom_id)
    piles.delete_pile(custom_id)
    assert store.execute("SELECT COUNT(*) FROM sf_piles WHERE id = ?", (custom_id,)).fetchone()[0] == 0
    home = store.execute(
        "SELECT pile_id FROM sf_pile_items WHERE item_node_id = ?", (guest,)).fetchone()[0]
    assert home == inbox_id, (home, inbox_id)
    total_after = store.execute("SELECT COUNT(*) FROM sf_pile_items").fetchone()[0]
    assert total_after == total_items, (total_after, total_items)
    print("delete custom pile: its item rehomed to Inbox; no item orphaned (total unchanged)")

    audits = store.execute(
        "SELECT COUNT(*) FROM local_audit_log WHERE action LIKE 'pile.%'").fetchone()[0]
    assert audits >= 4, f"expected pile.* audit rows, got {audits}"
    print(f"audit: {audits} pile.* rows in the shared local_audit_log")
    store.close()
    snap.close()

    bundled_after = sha256(SNAPSHOT)
    assert bundled_after == bundled_before, "BUNDLED snapshot hash changed during the run"
    print(f"bundled snapshot sha256 unchanged: {bundled_after}")
    print("SMOKE OK — piles materialize from the snapshot, one pile per item, moves/clear/delete hold the invariant")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Snowfell SF-T7 headless smoke check — V6 palette scopes + V5 data truth.

Runs the SAME SQL SnapshotStore runs (datedItems / paletteResults /
draftRows) against the bundled snapshot (Resources/registry.db,
read-only) and proves:
  * a known board name returns that board (palette board scope),
  * a known item title fragment returns the item (palette item scope),
  * action id 'media.convert.proxy' resolves (palette action scope),
  * 'instagram' resolves the deploy target (palette target scope),
  * the drafts query returns the (possibly zero) draft rows, count stated,
  * the dated-items counts are stated exactly: boards with date fields,
    distinct dated items, Start/Target value counts, the date range.
The snapshot's SHA-256 is printed before and after; it must not change.

Usage: python3 smoke_palette.py
"""
import hashlib
import sqlite3
from pathlib import Path

DB = Path(__file__).parent / "Snowfell" / "Resources" / "registry.db"

# --- SnapshotStore.datedItemsWithError: (verbatim) ---
DATED_SQL = """
SELECT i.gh_node_id, i.board_id, b.title, b.owner_type, b.number, i.title,
(SELECT sv.option_name FROM sf_item_values sv
 JOIN sf_fields sf ON sf.id = sv.field_id
 WHERE sv.item_id = i.gh_node_id AND sf.board_id = i.board_id AND sf.name = 'Status'),
(SELECT dv.date_value FROM sf_item_values dv
 JOIN sf_fields df ON df.id = dv.field_id
 WHERE dv.item_id = i.gh_node_id AND df.board_id = i.board_id AND df.name = 'Start date'),
(SELECT dv.date_value FROM sf_item_values dv
 JOIN sf_fields df ON df.id = dv.field_id
 WHERE dv.item_id = i.gh_node_id AND df.board_id = i.board_id AND df.name = 'Target date')
FROM sf_items i
JOIN sf_boards b ON b.gh_node_id = i.board_id
WHERE EXISTS (SELECT 1 FROM sf_item_values xv
 JOIN sf_fields xf ON xf.id = xv.field_id
 WHERE xv.item_id = i.gh_node_id AND xf.name IN ('Start date', 'Target date')
 AND xv.date_value IS NOT NULL)
ORDER BY b.owner_type DESC, b.number ASC, i.title ASC
"""

BOARDS_WITH_DATE_FIELDS_SQL = """
SELECT COUNT(DISTINCT board_id) FROM sf_fields
WHERE name IN ('Start date', 'Target date')
"""

# --- SnapshotStore.paletteResultsForQuery: (per scope, verbatim) ---
PALETTE_BOARD_SQL = """
SELECT gh_node_id, title, owner_type, number FROM sf_boards
WHERE title LIKE ? ESCAPE '\\'
ORDER BY owner_type DESC, number ASC LIMIT 50
"""
PALETTE_ITEM_SQL = """
SELECT i.gh_node_id, i.title, i.board_id, b.title FROM sf_items i
JOIN sf_boards b ON b.gh_node_id = i.board_id
WHERE i.title LIKE ? ESCAPE '\\'
ORDER BY i.title ASC LIMIT 50
"""
PALETTE_ACTION_SQL = """
SELECT id, name, kind FROM sf_actions
WHERE id LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\'
ORDER BY id ASC LIMIT 50
"""
PALETTE_TARGET_SQL = """
SELECT id, platform, account_label FROM sf_deploy_targets
WHERE id LIKE ? ESCAPE '\\' OR platform LIKE ? ESCAPE '\\'
OR account_label LIKE ? ESCAPE '\\'
ORDER BY platform ASC, id ASC LIMIT 50
"""
PALETTE_DRAFT_SQL = """
SELECT composition_id, name, item_title, board_title, deploy_target_id
FROM sf_upcoming_drafts
WHERE name LIKE ? ESCAPE '\\' OR item_title LIKE ? ESCAPE '\\'
OR board_title LIKE ? ESCAPE '\\' OR account_label LIKE ? ESCAPE '\\'
ORDER BY name ASC LIMIT 50
"""

# --- SnapshotStore.draftRowsWithError: (verbatim) ---
DRAFTS_SQL = """
SELECT composition_id, name, version, state, publish_at,
deploy_target_id, platform, account_label, item_id, item_title,
board_id, board_title, element_count, render_asset_id
FROM sf_upcoming_drafts
ORDER BY (publish_at IS NULL) ASC, publish_at ASC, name ASC
"""


def like_pattern(query):
    escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def sha256_of(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    before = sha256_of(DB)
    print(f"bundled snapshot sha256 (before): {before}")
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)

    # Palette: board scope — a known board name fragment returns board #3.
    rows = conn.execute(PALETTE_BOARD_SQL, (like_pattern("DetroitAutomationAcademy"),)).fetchall()
    board3 = [r for r in rows if r[2] == "user" and r[3] == 3]
    assert board3, "board scope: user board #3 not returned for its title"
    print(f"palette board scope: 'DetroitAutomationAcademy' -> {len(rows)} board(s); "
          f"user #3 present: {board3[0][1]} ({board3[0][0]})")

    # Palette: item scope — a known item title fragment returns the item.
    rows = conn.execute(PALETTE_ITEM_SQL, (like_pattern("article series"),)).fetchall()
    assert any("article series" in r[1] for r in rows), "item scope: fragment not returned"
    print(f"palette item scope: 'article series' -> {len(rows)} item(s); "
          f"first: {rows[0][1]} (board: {rows[0][3]})")

    # Palette: action scope — the exact action id resolves.
    rows = conn.execute(PALETTE_ACTION_SQL, (like_pattern("media.convert.proxy"),
                                             like_pattern("media.convert.proxy"))).fetchall()
    assert any(r[0] == "media.convert.proxy" for r in rows), "action scope: media.convert.proxy missing"
    print(f"palette action scope: 'media.convert.proxy' resolves -> "
          f"{[(r[0], r[2]) for r in rows if r[0] == 'media.convert.proxy']}")

    # Palette: target scope — the account-granularity target resolves.
    rows = conn.execute(PALETTE_TARGET_SQL, (like_pattern("instagram"),) * 3).fetchall()
    assert any(r[0] == "instagram:justinspencersmith" for r in rows), "target scope: instagram target missing"
    print(f"palette target scope: 'instagram' -> {[r[0] for r in rows]}")

    # Palette: draft scope + the drafts query itself — count stated as-is.
    rows = conn.execute(PALETTE_DRAFT_SQL, (like_pattern("signal"),) * 4).fetchall()
    print(f"palette draft scope: 'signal' -> {len(rows)} draft(s)")
    drafts = conn.execute(DRAFTS_SQL).fetchall()
    print(f"drafts query (sf_upcoming_drafts): {len(drafts)} row(s) in this snapshot")

    # Roadmap truth: the dated set, exactly as datedItems returns it.
    dated = conn.execute(DATED_SQL).fetchall()
    boards_with_fields = conn.execute(BOARDS_WITH_DATE_FIELDS_SQL).fetchone()[0]
    starts = sum(1 for r in dated if r[7] is not None)
    targets = sum(1 for r in dated if r[8] is not None)
    both = sum(1 for r in dated if r[7] is not None and r[8] is not None)
    all_dates = sorted(d for r in dated for d in (r[7], r[8]) if d is not None)
    boards_in_set = len({r[1] for r in dated})
    print(f"dated items (Roadmap rows): {len(dated)} distinct item(s) on {boards_in_set} board(s)")
    print(f"boards with Start/Target date fields: {boards_with_fields}")
    print(f"date values carried: Start x{starts}, Target x{targets} "
          f"(both x{both}, start-only x{starts - both}, target-only x{targets - both})")
    print(f"date range: {all_dates[0]} -> {all_dates[-1]}")
    sample = dated[0]
    print(f"sample dated row: [{sample[3]} #{sample[4]} {sample[2]}] {sample[5]} "
          f"start={sample[7]} target={sample[8]} status={sample[6]}")

    conn.close()
    after = sha256_of(DB)
    print(f"bundled snapshot sha256 (after): {after}")
    assert before == after, "snapshot changed during smoke"
    print("SMOKE OK — palette scopes resolve, drafts count stated, dated-items truth stated, snapshot pristine")


if __name__ == "__main__":
    main()

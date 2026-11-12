# Snowfell — SF-T2 App Shell + SF-T3 Read Views + SF-T4 Write-back (inert) + SF-T5 Orchestration Center + SF-T6 Snapshot Sync + SF-T7 Roadmap + Palette + Settings + SF-T11 Incidents Lens + SF-T12f Storage Lens (V12) · snowfell-test-2 UI uplift (`AcademyTheme`)

Snowfell is the Detroit Automation Academy's Jira-style board over GitHub
Projects: a macOS 10.13 AppKit application (Objective-C, programmatic UI,
Distro pattern) reading a pinned, hash-verified registry snapshot.
Bundle: `com.detroitautomationacademy.snowfell` · Version 0.1.0 (1) ·
Floor: macOS 10.13 exactly. Design record: `../01-SNOWFELL-DESIGN.md`
(SF-T2 = §6 shell: SDS-10 identity, menu, welcome, V2 Portfolio read-only
from the local cache; SF-T3 = V1 Board + V3 Item Detail, read-only;
SF-T4 = write-back machinery — the local mutation queue, the GraphQL
client for the three D3 operations, confirm sheets, and the Queue panel —
**built inert: sending is compiled OFF in this build**, see the
write-back section below; SF-T5 = the Orchestration Center (V4) — the
sf_actions manifest rendered as data, a composer whose form is generated
from each action's payload_schema_json, and the two dispatch lanes of
D6, **enqueue-only: this app executes nothing from either queue**, see
the orchestration section below; SF-T6 = snapshot sync — the app can
fetch the Academy's published snapshot, verify it into staging, and swap
it on the owner's Apply press, plus the report-only estate consumer —
see the sync section below; SF-T7 = the remaining three views —
V5 Roadmap (a month timeline over the items that actually carry
Start/Target dates), V6 Command Palette (⌘K over boards, items,
actions, deploy targets, AND upcoming drafts), and the V7 Sync &
Settings completion in Preferences — see the SF-T7 section below).

## Structure

```
build.sh                  thin wrapper: ./build.sh check | app
Makefile                  the file manifest (SOURCES / HEADERS / RESOURCES) + rules
smoke_check.py            headless SF-T3 proof (same SQL as SnapshotStore,
                          run against the bundled snapshot; output below)
smoke_writeback.py        headless SF-T4 proof (same SQL as WriteBackQueue,
                          run against throwaway copies; output below)
smoke_orchestration.py    headless SF-T5 proof (same SQL as DispatchStore
                          + WriteBackQueue in one throwaway store file;
                          output below)
smoke_palette.py          headless SF-T7 proof (same SQL as
                          SnapshotStore's palette + dated-items +
                          drafts queries; output below)
smoke_surfaces.py         headless SF-T7 + SF-T11 proof (roadmap
                          denominator, palette scope counts, the
                          incident queue in deadline order, and the
                          incident dispatch enqueue path; output below)
Snowfell/
  main.m                  NSApplication + AppDelegate, no nib
  AppDelegate.h/.m        code-constructed menu bar (SDS-10 §10.4), main
                          window, Preferences, snapshot open/refresh, About;
                          SF-T3: Board + Item Detail windows, View ▸
                          Portfolio/Board/Item Detail (⌘1/⌘2/⌘3);
                          SF-T4: Write-back Queue window (⌘4), File ▸ Send
                          Pending Mutations…, the three confirm-sheet
                          enqueue flows, and the FIFO send pass;
                          SF-T5: Orchestration Center window (⌘5), the
                          DispatchStore opened at launch, snapshot-swap
                          teardown of the Center, Preferences dispatch
                          count;
                          SF-T6: File ▸ Check for Snapshot Update…, the
                          Preferences Snapshot sync block (Check Now /
                          Apply Update), and the factored swap flow
                          (adoptLoadedSnapshotStore:) shared by Open
                          Snapshot… and Apply Update;
                          SF-T7: View ▸ Roadmap (⌘6) + View ▸ Command
                          Palette… (⌘K, an ordinary menu item — the only
                          palette registration), the palette's routing
                          handlers, and the V7 Preferences completion
                          (separate token / flag / queue lines + the
                          disabled token-entry control)
  AcademyWelcomeController.h/.m
                          SDS-8 welcome sheet: logo + runtime-read version
                          line + startup sound, played once on present
  AcademyAppIconView.h/.m the single icon surface — draws the bundle's own
                          AppIcon composition (SDS-10 §10.1.2)
  PortfolioViewController.h/.m
                          V2 Portfolio table over the snapshot (read-only);
                          SF-T3: row double-click activates the board (V1)
  BoardViewController.h/.m
                          V1 Board: columns derived from the selected
                          board's OWN Status options; item cards placed by
                          their EAV Status values; board switcher over all
                          74 boards. SF-T4: card Status popup + New Item…
                          button — request surfaces that enqueue locally
                          (drag stays disabled; see write-back section)
  ItemDetailViewController.h/.m
                          V3 Item Detail: header, every EAV field value in
                          board field order, Elements section =
                          sf_element_handlers chips (display only, no
                          invocation). SF-T4: Add-comment field (enqueues
                          locally; posts nothing)
  WriteBackQueueViewController.h/.m
                          the Queue panel (SF-T4): every queued mutation
                          (kind/target/state/attempts/last error), the arm
                          state as text, and the Send button — disabled in
                          this build, with the reason shown
  RoadmapViewController.h/.m
                          V5 Roadmap (SF-T7): month-grid timeline over
                          the snapshot's dated items, grouped by board —
                          bars for Start→Target, milestone diamonds for
                          one-ended items, an honest stated empty state
                          when a snapshot holds zero dated items
  CommandPaletteViewController.h/.m
                          V6 Command Palette (SF-T7): the ⌘K overlay's
                          content — one search over boards / items /
                          actions / deploy targets / upcoming drafts,
                          resolved through SnapshotStore and routed to
                          V1 / V3 / V4 (composer preselected; drafts to
                          the deploy lane)
  OrchestrationViewController.h/.m
                          V4 Orchestration Center (SF-T5): (a) Action
                          Manifest table over sf_actions with the
                          selected action's target + schema verbatim;
                          (b) Dispatch Composer — form generated from
                          payload_schema_json, snapshot-fed dropdowns,
                          live payload preview, access-review confirm
                          sheet naming the lane; (c) Dispatch Queue +
                          Audit — local_dispatches with state filters,
                          cancel for queued rows, dispatch.* audit rows
  SnapshotStore.h/.m      verify-then-open snapshot cache (sqlite3 C API,
                          SQLITE_OPEN_READONLY; SHA-256 + size vs manifest
                          BEFORE open; halt on mismatch, no fallback).
                          SF-T3: extended IN PLACE with the V1/V3 read
                          queries (status options, board items, item field
                          values, element handlers) — it stays the only
                          data door; no sibling query class was needed.
                          SF-T4: + statusFieldForBoard (the Status field's
                          GitHub field/option IDs for queue payloads).
                          SF-T5: + actions + deployTargets (the V4
                          manifest and the composer's target dropdowns).
                          SF-T7: + datedItems + boardsWithDateFieldsCount
                          (V5), + paletteResultsForQuery + itemWithNodeID
                          (V6 search + routing resolution), + draftRows
                          (the sf_upcoming_drafts projection)
  WriteBackQueue.h/.m     SF-T4: the LOCAL writable store (Application
                          Support/Snowfell/writeback.db) — pending
                          mutations mirroring sf_dispatches semantics +
                          a local sf_audit_log-shaped table. Enqueue /
                          list / state transitions only; the snapshot is
                          never opened by this class
  DispatchStore.h/.m      SF-T5: the estate-lane dispatch store — a
                          sibling table set (local_dispatches) in the
                          SAME writeback.db file, sharing the one
                          local_audit_log. Rows mirror sf_dispatches
                          (action_id, payload_json, state queued |
                          approved | sent_to_lane | done | failed |
                          cancelled, result_ref, last_error). Enqueue /
                          list / transition / cancel only; NO execution
                          engine (SF-T6 is the estate consumer) and no
                          network code
  GitHubProjectsClient.h/.m
                          SF-T4: the GraphQL documents + send path for
                          the three D3 operations, Keychain token custody
                          (D4), and the SNOWFELL_WRITEBACK_ENABLED
                          compile-time lock (0 in this build = inert)
  SnapshotSync.h/.m       SF-T6: fetch the published snapshot manifest +
                          versioned DB (read-only public HTTPS GET of
                          detroitautomationacademy.com — the app's second
                          deliberate NSURLSession file), stage under
                          Application Support/Snowfell/snapshots/, verify
                          size + SHA-256 before any swap is offered
  BoardSummary.h/.m       one Portfolio row (sf_boards + status summary)
  BoardItem.h/.m          one V1 card (sf_items + Status/Labels from EAV)
  ItemFieldValue.h/.m     one V3 field row (one sf_item_values record)
  ElementHandler.h/.m     one sf_element_handlers row (kind → handler app)
  StatusField.h/.m        one board's Status field + option GitHub IDs
                          (sf_fields.gh_field_id / sf_field_options.gh_option_id)
  SFAction.h/.m           one sf_actions manifest row (SF-T5) — id, name,
                          kind, target, payload_schema_json verbatim, risk,
                          requires_confirm, enabled; schema keys scanned
                          in manifest order from the stored JSON text
  DeployTarget.h/.m       one sf_deploy_targets row (SF-T5) — the
                          account-granularity deploy target (§11.1)
  DatedItem.h/.m          one dated sf_items row (SF-T7) — board +
                          Status + the stored Start/Target ISO texts
                          and their parsed dates (either may be nil)
  DraftRow.h/.m           one sf_upcoming_drafts row (SF-T7) — a
                          composition in draft/in_review/pass with its
                          item, board, deploy target, element count
  PaletteResult.h/.m      one ⌘K hit (SF-T7) — kind (board / item /
                          action / target / draft), title, subtitle,
                          and the scope's own reference ID
  Info.plist              bundle identity + audit/conformance keys (below)
  Resources/
    startup-sound.wav     SDS-10 master, byte-identical (hash below)
    registry.db           registry snapshot v7-0031 (74 boards, 614 items;
                          pair swapped by the SF-T9 line — SF-T7 did not
                          touch it; manifest SHA == file SHA verified)
    snapshot-manifest.json  the pin the snapshot is verified against
```

## Language / runtime choice

Objective-C with **ARC** (`-fobjc-arc`). The estate's KisMac2 project
carries ARC both ways across its targets (legacy target NO, current YES);
new Academy code is written ARC, and Snowfell is new code. Memory model is
stated here so no reader has to guess: strong properties, no manual
retain/release anywhere in the tree.

## What is real vs stubbed

Real (implemented, not mocked):
- Menu bar, code-constructed: App (About with the runtime-read version,
  Preferences, Quit ⌘Q) · File (Open Snapshot… ⌘O, Refresh Portfolio ⌘R,
  Close Window ⌘W) · Edit (Cut/Copy/Paste/Select All via the first-responder
  chain) · View (Show Closed Boards / Show Archived Boards — live filters
  with check states — and Enter Full Screen ⌃⌘F) · Window (Minimize, Zoom,
  Bring All to Front) · Help (Snapshot Details, Snowfell Help). Every item
  is wired to a working selector; there are no dead items.
- Snapshot contract: `SnapshotStore` parses `snapshot-manifest.json`,
  streams the DB through SHA-256 (CommonCrypto), compares hash AND byte
  size, and only then opens it read-only. A mismatch produces the failure
  as the Portfolio's state (fact → state), never a silent fallback.
- V2 Portfolio: all `sf_boards` rows with owner, Open/Closed/Archived
  state, item count, and a Status summary composed per board from
  `sf_item_values` in the board's own `sf_field_options` order — status is
  data, never an enum (§1). Verified against the bundled snapshot with the
  same queries the Objective-C runs: 74 boards · 614 items · user board #3
  "Todo 80 · In Progress 6 · Done 15" · KisMac Uplift's 7-stage vocabulary
  in its own order · archived-hidden = Bionic Text + Rejection Acquisition
  Program (D5, hidden until View ▸ Show Archived Boards).
- Welcome sheet: `AcademyAppIconView` + version line read from the
  bundle's own `Info.plist` at runtime (`CFBundleShortVersionString` /
  `CFBundleVersion`, SDS-10 §10.2.2 — nothing hardcoded) + the verified
  snapshot line (version · boards · items, or the load failure).
- Open Snapshot…: pick any `registry.db` with its manifest beside it
  (`snapshot-manifest.json` or `registry-manifest.json`); the pair is
  verified before it replaces the running snapshot.
- V1 Board (SF-T3): the board switcher lists all 74 boards
  (owner #number — title); the default is user board #3, the largest.
  Columns are generated per board from that board's Status
  single-select options in `sf_field_options` order — no status name
  exists anywhere in the source. Cards (title · content kind · state ·
  labels) are placed by each item's Status value read from
  `sf_item_values` joined through the board's own `Status` field, so
  KisMac Uplift renders Intake → Audit → Remediate → Verify → Package →
  Published → Gated from the same code path that renders board #3's
  Todo / In Progress / Done. Clicking a card selects it and opens V3.
- V3 Item Detail (SF-T3 core; SF-T4 comment field): header (title ·
  content kind with repo + number and GitHub state where present · the
  item's Status in the board's vocabulary · URL as selectable text),
  then EVERY field value stored for the item in `sf_item_values`,
  ordered by the board's `sf_fields.position`, rendered per value kind
  (single-select → option_name, date → date_value, labels → JSON array
  joined, repository / text / number as stored), then the Elements
  section: all 7 `sf_element_handlers` rows as chips (kind → handler
  app), and the Add-comment field (SF-T4, below).
- Navigation wiring (SF-T3): Portfolio row double-click (or View ▸
  Board, ⌘2, on a selection) opens V1 for that board; a card click opens
  V3; View ▸ Portfolio / Board / Item Detail (⌘1/⌘2/⌘3) are wired to
  real selectors — Item Detail enables exactly when a card is selected,
  Board exactly when a snapshot is loaded. Opening a replacement
  snapshot closes the Board/Detail windows (they rebuild against the
  new store on demand).
- Write-back queue (SF-T4): `WriteBackQueue` opens
  `~/Library/Application Support/Snowfell/writeback.db` at launch — a
  store the app owns, separate from the snapshot (D1: the snapshot stays
  pristine; it is never opened writable, and this class never opens it
  at all). Rows mirror `sf_dispatches` semantics (kind, board_id,
  item_id, payload_json, state pending|sending|sent|failed, created_at,
  attempts, last_error); the schema's CHECK constraints admit exactly
  the three D3 kinds and the four states. Every enqueue and every send
  outcome appends an `sf_audit_log`-shaped row to `local_audit_log`.
- Enqueue surfaces (SF-T4): the card Status popup (Board), the Board's
  New Item… button (title + initial Status), and V3's Add-comment field
  each end at an AppDelegate confirm sheet in the §3 access-review form
  — destination `https://api.github.com/graphql` + operator, the exact
  effect the mutation WILL have when eventually sent (mutation name,
  item, board, from→to values), and the plain statement that nothing
  has been sent and confirming queues locally only. Payloads carry the
  GitHub field/option IDs read from the snapshot (`StatusField`), plus
  display keys so the Queue panel describes rows without re-reading the
  snapshot. A queued move changes nothing on screen: the card popup
  settles back to the snapshot status until a send + resync lands.
- Queue panel (SF-T4): View ▸ Write-back Queue (⌘4) lists every row
  (kind, target summary, state, attempts, queued-at, last error) and
  states the arm position as text — compiled ON/OFF, token
  configured/not, pending count — with the Send button enabled only
  when both locks are open and work is pending. In this build it is
  disabled and the panel prints why (compiled OFF; no token).
- GraphQL client (SF-T4): `GitHubProjectsClient` carries the exact
  Projects v2 documents for the three D3 operations (below), the
  Keychain probe (attributes only — secret bytes never materialize for
  a state check), and the send path. It is unreachable in this build:
  `SNOWFELL_WRITEBACK_ENABLED` is 0, and `sendMutation:` refuses with
  that fact before any Keychain read or network call; the one POST
  builder re-checks the same lock (defense in depth).

Stubbed / stated, not faked:
- Preferences states the facts it owns (V7 completed in SF-T7; section
  below): the verified snapshot pin, then THREE separate lines — the
  GitHub token state (a Keychain PRESENCE check only: "token present in
  Keychain" / "no token stored"; the secret is never read or shown),
  the write-back flag state (the compiled SNOWFELL_WRITEBACK_ENABLED,
  stated as "DISABLED in this build" while it is 0), and the queue
  counts (pending write-backs + queued estate dispatches, from the two
  local stores). The token ENTRY control renders disabled with its
  reason in the field itself: D4 custody means the token is provisioned
  directly into the Keychain (enable path below), never typed into the
  app. SF-T6's Snapshot sync block stands in the same panel unchanged
  (running version · served version · sync state · Check Now / Apply
  Update) — not duplicated by SF-T7.
- Sending is impossible in this build, by construction: the compile-time
  lock (`SNOWFELL_WRITEBACK_ENABLED` = 0 in `GitHubProjectsClient.h`)
  makes the client refuse every send before touching the Keychain or
  the network, and the menu item / Send button validate shut on the
  same fact. What SF-T4 adds over SF-T3's read-only build is the QUEUE:
  status moves, creates, and comments can be composed and stored
  locally, with confirm sheets — nothing more. Board dragging stays
  disabled (in an armed build, drag becomes visual intent over the
  same popup enqueue path). The Elements chips display the routing
  table but invoke nothing — no handler app is launched, no dispatch is
  written (element invocation, §9.1, remains unbuilt: SF-T5 delivered
  the Orchestration Center below, not the element surface).
- Assignees render only where the snapshot stores them: the v7-0026
  import carries no Assignees value rows (the field exists on all 74
  boards), so no card or detail row invents one. Labels (72 items),
  Repository (83), and Start/Target dates (111) render from the values
  that exist.
- Orchestration Center (SF-T5): the manifest table, the schema-driven
  composer, the confirm sheets, the local dispatch queue with its state
  filters and cancel, and the audit pane are all real (section below).
  What is NOT real, by design: execution. No row in either queue is
  executed by this app — the estate consumer is SF-T6, and the GitHub
  lane's send path is SF-T4's (compiled OFF). Deploy preconditions are
  displayed, never evaluated: the composer prints "review verdict: not
  connected in this build" for media.deploy / signal.publish.linkedin
  rather than reading or faking a Henchman verdict (the verdict source
  arrives with SF-T6).
- No network anywhere in this tranche. No writes anywhere, including to
  the snapshot (read-only open).

## Write-back (SF-T4) — machinery built, inert by default

Write-back v1 is exactly three operations (D3 — the queue schema's CHECK
constraint refuses a fourth kind):

| Queue kind | GraphQL operation | Variables (from the queue payload) |
|---|---|---|
| `status_move` | `updateProjectV2ItemFieldValue` with `value: {singleSelectOptionId: …}` | projectId = board node ID, itemId = item node ID, fieldId = `sf_fields.gh_field_id`, optionId = `sf_field_options.gh_option_id` |
| `create_item` | `addProjectV2DraftIssue`, then the same field-value mutation for the queued initial Status (the create mutation accepts no field values, so initial Status is a second call in the same send attempt) | projectId, title, body; then fieldId/optionId against the returned `projectItem.id` |
| `comment` | `addComment` — after a resolve query (`repository(owner,name).issue(number).id`), because the snapshot stores the project ITEM's node ID, not the issue's | subjectId = resolved issue ID, body = the queued text |

(`addProjectV2ItemById`'s document also ships in the client, for SF-T5's
orchestration surface, which attaches existing content; `create_item`
here always creates a new draft issue.)

**The DraftIssue comment limitation, stated plainly:** GitHub exposes no
comment mutation for draft issues — `addComment` subjects are Issues and
pull requests, and a draft's text surface is its body
(`updateProjectV2DraftIssue`, outside D3's three). Snowfell therefore
lets a comment on a draft be QUEUED (the confirm sheet for a draft names
the limitation before you confirm), and the client fails that row at
send time with `GitHubProjectsClientErrorCommentUnsupportedForDraft`
rather than faking an effect. Comments on real Issues take the
resolve-then-comment path above.

**Token discipline (D4).** The GitHub token is a macOS Keychain
generic-password item, service `com.detroitautomationacademy.snowfell.github`.
It is fetched inside the single method that builds ONE HTTP request, used
to set that request's `Authorization` header, and released when the
method returns. It is never stored in a property or ivar, never written
to either database or any file, and never logged — client errors carry
HTTP status codes and GraphQL error messages only. The state probe
(`tokenStatus`) requests attributes without data, so the secret bytes
never materialize for a state check. With no Keychain item, the client
reports `notConfigured` and queued rows simply stay pending.

**Arm discipline — the double lock.** Sending requires BOTH:
(a) a configured Keychain token, AND (b) the owner's explicit in-app
action — File ▸ Send Pending Mutations… or the Queue panel's Send
button (`sendPendingMutations:`), which walks the pending rows FIFO,
one attempt per row, recording each outcome into the queue row (state +
last_error) and `local_audit_log`. No timers, no background auto-send,
no other caller of the client exists. AND, in this build, a third fact
stands in front of both: **`SNOWFELL_WRITEBACK_ENABLED` is 0**
(`GitHubProjectsClient.h`), checked first in `sendMutation:` and again
in the POST builder — so even an armed UI and a configured token cannot
produce a network call from this build. The menu item and the Send
button validate disabled on the same fact, with the reason printed in
the Queue panel.

**Enable path (rig only, owner's word — do not improvise):**
1. On the rig, with Justin's explicit word for THIS build: edit
   `SNOWFELL_WRITEBACK_ENABLED` from 0 to 1 in
   `Snowfell/GitHubProjectsClient.h` and rebuild (`./build.sh app`).
2. Provision the token directly into the Keychain (never through the
   app, never into a file): e.g. Terminal →
   `security add-generic-password -s com.detroitautomationacademy.snowfell.github -a smit4786 -w`
   (prompts for the token; use a token carrying the `project` scope the
   estate already uses).
3. Launch the app: Preferences and the Queue panel should now read
   token "configured" and compiled ON.
4. Queue one mutation, open View ▸ Write-back Queue (⌘4), press
   Send Pending…, and verify the effect on GitHub itself (the item's
   Status / the new draft / the comment) plus the row's `sent` state
   and the `local_audit_log` entries — the app's own claim is not the
   verification.
Until those steps are taken on the rig, every build from this tree is
local-only, whatever its UI shows.

**What stays impossible in this build:** any network call from the app
(the lock fires first); any send without the owner's explicit action;
any fourth mutation kind (schema CHECK); any write to the snapshot
(opened read-only, and the queue class never opens it); any token
storage outside the Keychain (there is no code path that writes one).

## Orchestration (SF-T5) — the manifest is data; two lanes; this app executes nothing

**Manifest-is-data doctrine (§3).** Actions are `sf_actions` ROWS, not
code. The Orchestration Center (View ▸ Orchestration Center, ⌘5) reads
all 15 rows from the verified snapshot and renders them; the composer
generates its form from the selected row's `payload_schema_json` — keys
in manifest order (scanned from the stored JSON text, since
NSJSONSerialization preserves no order), each key's schema type deciding
the control: `string` → text field, `integer` → validated integer
field, `array` → comma-separated field (stored as a JSON array),
`object` → JSON field (validated to a JSON object), a `a|b|c` union →
popup of the alternatives, and any other value in the type slot is the
schema naming a LITERAL (e.g. `"profile": "proxy720"`) → a field
prefilled with that literal. Keys that reference snapshot data are
pickers, not typing: `board` → all 74 boards, `item` → the selected
board's items by title (a search-select in list form), `status` → the
selected board's OWN Status options, `target_id` → `sf_deploy_targets`
by platform + account label (§11.1). Every schema key is required — the
manifest schemas carry no optional markers, so the composer defaults
nothing silently (§3 ambiguity protocol): the Enqueue button stays
disabled until the payload is complete and valid, and the live preview
shows the exact payload that will be stored, in the store it will be
stored in. A manifest row with `enabled = 0` renders struck in the
manifest, its composer-popup item is disabled, and it cannot be
composed (the v7-0026 manifest has no disabled rows; the path is built
and stated, not exercised by data yet).

**DispatchStore.** Estate-lane rows live in `local_dispatches` — a
sibling table set in the SAME writable file as the write-back queue
(`~/Library/Application Support/Snowfell/writeback.db`; one file was
chosen over a second file so both local stores share the ONE
`local_audit_log`, and the audit pane reads the same log the write-back
rows write). Columns mirror `sf_dispatches`: id, action_id,
payload_json, state (`queued | approved | sent_to_lane | done | failed
| cancelled` — the schema CHECK admits exactly these), created_at,
updated_at, result_ref, last_error. The store offers enqueue / list /
generic audited transition / cancel ONLY: **there is no execution
engine in the app for estate actions** — SF-T6 is the estate consumer
(Minion/hooks read approved rows and execute them). Cancel is guarded
to `queued` rows, in the UI and again in the SQL (`... AND state =
'queued'`): a row past queued may already be held by the consumer and
is never yanked silently. Every enqueue, cancel, and transition appends
a `local_audit_log` row (`dispatch.enqueue` / `dispatch.cancel` /
`dispatch.transition`), and pane (c) lists the log's `dispatch.*`
entries beside the queue.

**The two lanes (D6), exactly as built.** Every enqueue passes through
a confirm sheet in the §3 access-review form — lane, destination /
operator, the exact effect, and the payload verbatim (envelope≠payload)
— and for `requires_confirm = 1` actions (all 15 current rows) the
sheet states plainly that this confirmation covers QUEUEING and that
**queueing is not executing**.

| Manifest action | Kind | Lane in this build | Why |
|---|---|---|---|
| `gh.project.move_item` | github_project_mutation | **GitHub** — translated into the SF-T4 WriteBackQueue as `status_move` | Maps exactly onto a D3 operation; the translation is the Board popup's own (StatusField → field/option GitHub IDs + display keys) |
| `estate.agent_task` | agent_task | Estate | §3 trigger path (b) by definition |
| `estate.cron.trigger` | cron | Estate | §3 trigger path (b) by definition |
| `estate.hook.fire` | hook | Estate | §3 trigger path (b) by definition |
| `gh.workflow.dispatch` | github_workflow | Estate | Workflow dispatch is not a D3 operation; the SF-T5 task fences workflow seeds to the estate lane for SF-T6's consumer — no direct-fire path is invented here |
| `gh.project.add_item` | github_project_mutation | Estate | `addProjectV2ItemById` ships in the client but is NOT a D3 queue kind (the queue schema's CHECK refuses a fourth kind) |
| `gh.issue.create` | github_issue | Estate | A repository issue via REST is a different operation from D3's `create_item` (a draft issue on a board) — its payload names no board |
| `gh.issue.comment` | github_issue | Estate | D3 comment rows are anchored to a board item (the send path resolves the issue from the item's own snapshot record); this payload names a repo issue directly with no board anchor, and silently inventing one is what §3's ambiguity protocol forbids |
| `media.convert.proxy` | media_convert | Estate | Estate conversion pipeline (ffmpeg), executed by the SF-T6 consumer |
| `media.convert.ladder` | media_convert | Estate | Same pipeline |
| `media.extract.audio` | media_convert | Estate | Same pipeline |
| `media.extract.stills` | media_convert | Estate | Same pipeline |
| `media.deploy` | media_deploy | Estate | Deploy executes estate-side after its precondition (below) |
| `media.deploy.instagram` | media_deploy | Estate | Account-level target from `sf_deploy_targets`; executed via the Instagram connector estate-side |
| `signal.publish.linkedin` | media_deploy | Estate | The estate-publication pipeline executes estate-side |

So: GitHub lane 1 of 15, estate lane 14 of 15. The GitHub lane's row is
still only QUEUED — sending remains SF-T4's machinery behind its double
lock + the compile-time lock (still 0), and the GitHub-lane confirm
sheet says so, naming `https://api.github.com/graphql`, the
`updateProjectV2ItemFieldValue` effect, and the from→to values.

**Media / deploy honesty.** For `media.*` and `signal.*` actions the
composer requires exactly the fields their stored schemas name (e.g.
`media.deploy.instagram`: asset_id, target_id, format,
caption_element_id — read from `sf_actions.payload_schema_json`, never
guessed) and displays the standing deploy precondition: Henchman P1–P5
ALL PASS at execution. The verdict source is NOT connected in this
build, and the composer says so in words — "review verdict: not
connected in this build" — rather than showing a fake PASS; enforcement
belongs to the executor (SF-T6), which will read the real verdicts.
`asset_id` / `composition_id` / `caption_element_id` are typed integer
fields, not pickers: `sf_media_assets` / `sf_compositions` hold zero
rows in snapshot v7-0026, so there is nothing truthful to pick from
yet.

**What stays impossible in this build:** executing any queued dispatch
(no engine exists); any new network code (NSURLSession still appears in
exactly one file, `GitHubProjectsClient.m`); any send (the SF-T4 locks
stand, `SNOWFELL_WRITEBACK_ENABLED` still 0); any write to the snapshot
(the stores never open it); any fourth write-back kind (schema CHECK);
composing a disabled manifest action.

## Snapshot sync (SF-T6) — published snapshot in, verified, owner-pressed

**Endpoints (the only two URLs `SnapshotSync` will ever build).**
`GET https://detroitautomationacademy.com/registry/registry-manifest.json`
(the stable manifest) and the versioned database it names
(`snapshot_url` from the manifest, canonically
`https://detroitautomationacademy.com/registry/<version>/registry.db`).
Read-only public HTTPS GETs of the Academy's own published snapshot:
no auth, no token, no POST, no other host.

**The deliberate second NSURLSession file.** Through SF-T5, NSURLSession
appeared in exactly one app file (`GitHubProjectsClient.m`, inert behind
its lock). `SnapshotSync.m` is the second, added deliberately in this
tranche and stated here so the invariant is a decision, not a drift:
sync needs no credential and can send nothing — its requests are GETs
with no body, and its session discipline mirrors the client's (default
configuration, explicit timeouts — 30 s manifest / 120 s database —
completions on the main queue).

**Flow — check, stage, verify, THEN swap (the §2 contract, unchanged).**
File ▸ Check for Snapshot Update… (or Preferences ▸ Check Now) fetches
the stable manifest and compares version + SHA-256 against the running
snapshot's manifest: up to date, or update available. An available
update is downloaded into `~/Library/Application
Support/Snowfell/snapshots/<version>/` (registry.db + the served
manifest bytes beside it as snapshot-manifest.json) and verified —
size + SHA-256 via SnapshotStore's own verifier — BEFORE Apply enables.
A failed download or verification deletes the staged files and reports;
the running snapshot is never touched by a failed sync. Apply Update
hands the staged pair to the existing SnapshotStore load path
(verify-then-open runs a second time at swap) and the factored
`adoptLoadedSnapshotStore:` flow in AppDelegate — the same swap File ▸
Open Snapshot… has always used: Portfolio rebuilds, Board / Item Detail
/ Orchestration windows close and rebuild on demand, the local stores
are untouched.

**Owner-pressed discipline.** There is NO automatic or background
download or swap in this build: no timers, no launch-time fetch (the
launch sequence is unchanged — bundled snapshot, verify, open). The
only network activity in the app outside the inert write-back client
happens between the owner's Check press and the completion of that
check's staging download; the swap itself waits for Apply.

**Estate side (report-only).** `hidden_files/work/snowfell_consumer.py`
polls the same stable manifest from the estate, compares it against
`consumer-state.json`, and on drift re-runs the SF-T1 crawl chain into
a scratch tree (the registry working copy is never overwritten),
diffing the fresh census against the previous run and writing a Δ
report — served version/sha, live counts, per-board deltas, and the
exact publish sequence that WOULD carry the refresh (next free ledger
number read from the live registry tree). It publishes, pushes, and
mutates NOTHING (exit 0 = checked, 2 = fetch/crawl failure with the
error in the report). The `snowfell-sync-watch` hook that would run it
every 30 minutes is specified in
`hidden_files/work/SNOWFELL-SYNC-WATCH-HOOK.md` — spec only; the parent
registers the hook after review.

**Consumer verification run (2026-11-11T01:14Z, this tranche):** exit 0
in 3m38s. First run (no state file) → drift path: served snapshot
**v7-0030** (sha256 `a18d7271…`, ledger 0030 — the published line had
already advanced past the app's bundled v7-0026), live crawl **74
boards · 617 items · 1,000 fields · 229 options**; Δ vs the app-bundled
v7-0026 census: items 614 → 617, entirely on user board #3
(DetroitAutomationAcademy, 101 → 104). Report:
`hidden_files/work/consumer-out/report-20261111T011416Z.md` (+
`latest.md`); the would-be refresh sequence names ledger **0032** as
the next change (read live from the registry tree). The SF-T1 working
crawl files (projects.json / fields.json / items.json) and the registry
working copy were byte-untouched — the fresh crawl's artifacts all
landed under `consumer-out/scratch-home/`.

## Roadmap + Palette + Settings (SF-T7) — the remaining three views

**V5 Roadmap (View ▸ Roadmap, ⌘6).** A month-grid timeline drawn from
`SnapshotStore.datedItems`: every item whose board carries a 'Start
date' / 'Target date' field AND which holds a date value in
`sf_item_values` (the join keys on the item's OWN board's fields —
fields are per-board rows). Rows group by board; a two-ended item
draws a bar from Start to Target, a one-ended item draws a milestone
diamond at its single real date — never a fabricated span — and the
Status renders in the board's own vocabulary. Dates parse from the
stored ISO text (`yyyy-MM-dd`, POSIX). **The bundled snapshot's truth
(measured, smoke below): 76 dated items on 19 boards** — 111 date
values (Start ×73, Target ×38; both ×35, start-only ×38, target-only
×3), range **2026-09-22 → 2026-11-26**; the 19 is also the count of
boards carrying date fields at all (of 74). The header states these
counts on every load. The zero case is built and honest: a snapshot
with zero dated items gets a header stating the count, how many boards
carry date fields, and where dates would come from (GitHub Projects'
Start/Target fields, imported as `sf_item_values` date rows) — the
canvas draws "No dated items to place on the timeline", not bars.
Double-clicking a row resolves the item through the store and opens
V3. Where design §4 and the shipped code differed (the T2–T6 shell had
no roadmap seam at all), the shipped patterns won: lazy window +
reload-on-open, like Board/Orchestration.

**V6 Command Palette (View ▸ Command Palette…, ⌘K).** An `NSPanel`
overlay: one search field, one results table, five scopes through
`SnapshotStore.paletteResultsForQuery` — boards (title), items
(title), actions (id/name), deploy targets (id/platform/account),
and upcoming drafts (the `sf_upcoming_drafts` projection by
name/item/board/account — §11.3's "⌘K scope includes drafts").
Matching is case-insensitive substring with the query's LIKE
metacharacters escaped; an empty query browses boards/actions/
targets/drafts (94 rows in this snapshot) and skips items — 614
titles are not a browse list. Enter or double-click RESOLVES the hit
through the store (boards via the portfolio query, items via the new
`itemWithNodeID`, drafts via `draftRows`) and routes: board → V1
switched to it; item → V3; action → V4 with the composer preselected
(the `selectActionWithID:` seam SF-T7 added to
OrchestrationViewController — AppDelegate opens V4 first, whose reload
runs, THEN preselects, so the routing is never overridden); target →
V4 (targets are picked in the composer's own dropdown; a target alone
preselects nothing, stated in the wiring); draft → V4's deploy lane,
preselecting the deploy action the draft's own target names
(instagram → `media.deploy.instagram`, linkedin →
`signal.publish.linkedin`, any other target → `media.deploy`; a
target-less draft opens the Center unpreselected — nothing invented).
Escape closes via `cancelOperation:` and changes nothing. The ⌘K
registration is the menu item and nothing else — no global hotkey.

**V7 Sync & Settings (Preferences, completed).** The panel SF-T2/T6
built now carries, as SEPARATE lines refreshed on every open: the
snapshot pin; **GitHub token state** — the client's attributes-only
Keychain probe, stated as "token present in Keychain" / "no token
stored" (service `com.detroitautomationacademy.snowfell.github`); the
secret is never read, copied, or displayed for this line, exactly as
SF-T4 built the probe; **write-back flag state** — the compiled
`SNOWFELL_WRITEBACK_ENABLED`, stated in words ("DISABLED in this
build" while 0); and **queue counts** — pending write-backs
(WriteBackQueue) + queued estate dispatches (DispatchStore). The
token-entry control cannot work by D4 design, so it renders DISABLED
with its reason in the field ("provision into the Keychain directly;
Snowfell never accepts a token in-app"). The SF-T6 Snapshot sync
block stands as built — SF-T7 did not duplicate it.

**What stays impossible in this build:** any new network code
(NSURLSession still appears in exactly two files —
`GitHubProjectsClient.m` + `SnapshotSync.m`); any send (the SF-T4
locks stand, `SNOWFELL_WRITEBACK_ENABLED` still 0); any write to the
snapshot (all three new views read through SnapshotStore only);
routing a palette hit from display text (resolution is by node/id
through the store, and an unresolvable hit states itself in place).

## Startup sound — status: PRESENT, byte-identical

`Snowfell/Resources/startup-sound.wav` was copied from the shipped Distro
bundle (`muse-academy-pkg/dt38-x/Distro.app`) and hash-verified before
inclusion:
SHA-256 `07a113244c6b432b22954a089ce519bd239311b14a48f26ae85214ed8c25b09a`
— equal to the SDS-10 library master. It plays once when the welcome
presents, at system volume, no loop (SDS-10 §10.3).

## Audit + conformance keys — honest scaffold state

`Info.plist` carries both sibling keys in the shipped-bundle shapes
(audit: Authority/Date/Disassembled/Scanned/Recompiled; conformance:
Standard "SDS-10" + Logo/VersionAtStartup/StartupSound/MenuBar +
Authority/Date) with **every clause `false`**, plus an `SFBuildStage`
string stating the scaffold is not rig-verified. SDS-10 §10.5 attestations
are written by the build line when a build is cut and are never written
for a clause the build does not meet: this scaffold has not been built or
launched on a rig, so nothing is attested. The first rig build flips each
clause only as its evidence lands (welcome screenshot vs the plist
`CFBundleVersion`, bundled `.wav` hash, menu exercise, icon comparison).

## Syntax-check results (2026-11-10, SF-T7 delivery gate)

Recipe (estate TOOLS.md): Ubuntu clang 18,
`clang -target x86_64-apple-darwin17 -isysroot ~/workspace/tools/sdks/MacOSX10.13.sdk
-fobjc-runtime=macosx-10.13 -fobjc-arc -fsyntax-only` — via `./build.sh check`
(= `make check`). **26/26 files PASS, 0 errors** (`ALL SYNTAX OK`).
Stderr attribution, stated plainly: the run's only diagnostics are 2
`-Wincomplete-implementation` warnings on SnapshotStore, for
`incidentSummariesWithError:` / `incidentDetailForKey:error:` —
declarations the SF-T11 line landed in SnapshotStore.h (01:44 EST,
mid-SF-T7) whose implementations are that tranche's, still in flight
at this gate. No SF-T7 file produced a warning or error; SF-T7 did not
implement, alter, or remove the SF-T11 declarations.

| File | Verdict |
|---|---|
| Snowfell/main.m | PASS (SF-T2) |
| Snowfell/AppDelegate.m | PASS (extended SF-T7) |
| Snowfell/AcademyWelcomeController.m | PASS (SF-T2) |
| Snowfell/AcademyAppIconView.m | PASS (SF-T2) |
| Snowfell/PortfolioViewController.m | PASS (extended SF-T3) |
| Snowfell/BoardViewController.m | PASS (extended SF-T4) |
| Snowfell/ItemDetailViewController.m | PASS (extended SF-T4) |
| Snowfell/WriteBackQueueViewController.m | PASS (new SF-T4) |
| Snowfell/OrchestrationViewController.m | PASS (SF-T5, seam SF-T7) |
| Snowfell/RoadmapViewController.m | PASS (new SF-T7) |
| Snowfell/CommandPaletteViewController.m | PASS (new SF-T7) |
| Snowfell/SnapshotStore.m | PASS (extended SF-T7) |
| Snowfell/WriteBackQueue.m | PASS (new SF-T4) |
| Snowfell/DispatchStore.m | PASS (new SF-T5) |
| Snowfell/GitHubProjectsClient.m | PASS (new SF-T4) |
| Snowfell/BoardSummary.m | PASS (SF-T2) |
| Snowfell/BoardItem.m | PASS (new SF-T3) |
| Snowfell/ItemFieldValue.m | PASS (new SF-T3) |
| Snowfell/ElementHandler.m | PASS (new SF-T3) |
| Snowfell/StatusField.m | PASS (new SF-T4) |
| Snowfell/SFAction.m | PASS (new SF-T5) |
| Snowfell/DeployTarget.m | PASS (new SF-T5) |
| Snowfell/SnapshotSync.m | PASS (new SF-T6) |
| Snowfell/DatedItem.m | PASS (new SF-T7) |
| Snowfell/DraftRow.m | PASS (new SF-T7) |
| Snowfell/PaletteResult.m | PASS (new SF-T7) |

Fixes during the SF-T3 pass (all 10.13-floor discipline): `+[NSColor
separatorColor]` is a 10.14 API — card/chip borders use an explicit
monochrome gray (`colorWithWhite:0.80`) instead; `-[NSMenu lastItem]`
does not exist in the 10.13 headers — the switcher uses
`itemAtIndex:numberOfItems - 1`; (SF-T2, still standing)
`NSMenuItemValidation` does not exist in the 10.13 SDK headers, so menu
validation rides the informal protocol, noted in `AppDelegate.h`.
SF-T4 needed no floor fixes: everything it uses — `NSURLSession`,
`NSISO8601DateFormatter`, the Security framework's `SecItemCopyMatching`,
`NSAlert` accessory views — is at or below the 10.13 surface, and the
Makefile's `app` rule now also links `-framework Security` for the rig
build. SF-T5 needed none either: `NSPopUpButton.lastItem` exists in the
10.13 headers (the SF-T3 note was about `NSMenu`, a different class),
`NSJSONWritingPrettyPrinted` and `monospacedDigitSystemFontOfSize:` are
at the floor, and the new stores reuse SF-T4's sqlite3 patterns — no new
framework appears in the `app` rule. SF-T6 needed none either:
`NSURLSession`, `NSDataWritingAtomic`, and the Application Support
search path are all at or below the 10.13 surface, and no new framework
appears in the `app` rule (SnapshotSync links Foundation only, already
linked). Syntax-level only — no link, no
run; full builds need the Mac rig (below). `Info.plist` parses clean
(plistlib) with the identifier/version/floor above, audit + conformance
values untouched by SF-T3, SF-T4, SF-T5, and SF-T6 (still honestly `false`
pending rig verification; SF-T6 did not modify Info.plist at all).

## SF-T3 smoke check — column derivation is data (headless proof)

`python3 smoke_check.py` runs SnapshotStore's own SQL against the
bundled snapshot, read-only. Verbatim output, 2026-11-10:

```
board user #3 — DetroitAutomationAcademy
  columns (from sf_field_options, position order): ['Todo', 'In Progress', 'Done']
    Todo: 80 items
    In Progress: 6 items
    Done: 15 items
  items placed by Status value: 101 of 101
board org #1 — KisMac Uplift
  columns (from sf_field_options, position order): ['Intake', 'Audit', 'Remediate', 'Verify', 'Package', 'Published', 'Gated']
    Intake: 10 items
    Audit: 0 items
    Remediate: 0 items
    Verify: 0 items
    Package: 0 items
    Published: 0 items
    Gated: 0 items
  items placed by Status value: 10 of 10
element handlers (V3 chips): 7 rows
    markdown -> MacDown
    audio -> SoundDeck
    video -> Snowfell inline player
    image -> Snowfell inline player
    csv -> TableTool
    pdf -> Preview
    code -> Editor of record
sample Issue item EAV rows (V3 field list): 4
    Title [text] = [post-deploy] served-bytes failed @ 4415b8b
    Status [single_select] = Todo
    Labels [labels] = ["ci-cd"]
    Repository [repository] = AutomatedTechnologies/detroit-automation-academy-public
```

Board #3's Todo 80 · In Progress 6 · Done 15 matches the Portfolio's
independently composed status summary — two query paths, one verdict.

## SF-T4 smoke check — the queue is local, the snapshot pristine (headless proof)

`python3 smoke_writeback.py` mirrors WriteBackQueue's schema + SQL
against THROWAWAY copies in a temp directory: it enqueues one mutation
of each D3 kind with payloads built from real snapshot data (board #3's
Status field/option GitHub IDs, a real Todo item, a real Issue), reads
them back, and verifies states, payload round-trip, audit rows, the D3
kind fence, and that neither the snapshot copy nor the bundled snapshot
changed by a single byte. Verbatim output, 2026-11-10:

```
bundled snapshot sha256 (before): 2041a99f5e0b058eedcebd27882a41c9c18a241d7f88d304bf12c865d94d0635
board: user #3 — DetroitAutomationAcademy (PVT_kwHOAc-P_c4BR-XR)
Status field gh id: PVTSSF_lAHOAc-P_c4BR-XRzg_pMis; options: [('Todo', 'f75ad846'), ('In Progress', '47fc9ee4'), ('Done', '98236657')]
enqueued 3 mutations into temp store writeback.db
  row 1: status_move state=pending attempts=0 payload round-trip OK
  row 2: create_item state=pending attempts=0 payload round-trip OK
  row 3: comment state=pending attempts=0 payload round-trip OK
audit rows (writeback.enqueue): 3
D3 fence: kind 'delete_item' refused by CHECK constraint OK
snapshot copy sha256 unchanged: 2041a99f5e0b058eedcebd27882a41c9c18a241d7f88d304bf12c865d94d0635
bundled snapshot sha256 unchanged: 2041a99f5e0b058eedcebd27882a41c9c18a241d7f88d304bf12c865d94d0635
SMOKE OK — queue is local, payloads round-trip, snapshot pristine
```

## SF-T5 smoke check — two lanes, one store file, snapshot pristine (headless proof)

`python3 smoke_orchestration.py` mirrors DispatchStore's + WriteBackQueue's
schemas and SQL in ONE temp store file (the app's own arrangement:
`local_dispatches` beside `writeback_queue`, one shared
`local_audit_log`). It classifies all 15 manifest actions by the
composer's lane rule, enqueues one estate-lane dispatch
(`media.convert.proxy`) and verifies its JSON round-trip, the generic
transition path, and the guarded cancel; then enqueues the one
GitHub-lane action (`gh.project.move_item`, translated through the
snapshot's StatusField IDs) as a `status_move` and verifies its
round-trip. Nothing queued is executed. Verbatim output, 2026-11-10:

```
bundled snapshot sha256 (before): 2041a99f5e0b058eedcebd27882a41c9c18a241d7f88d304bf12c865d94d0635
lane table (15 actions from the snapshot manifest):
  estate.agent_task            kind=agent_task               lane=estate
  estate.cron.trigger          kind=cron                     lane=estate
  estate.hook.fire             kind=hook                     lane=estate
  gh.issue.comment             kind=github_issue             lane=estate
  gh.issue.create              kind=github_issue             lane=estate
  gh.project.add_item          kind=github_project_mutation  lane=estate
  gh.project.move_item         kind=github_project_mutation  lane=github
  gh.workflow.dispatch         kind=github_workflow          lane=estate
  media.convert.ladder         kind=media_convert            lane=estate
  media.convert.proxy          kind=media_convert            lane=estate
  media.deploy                 kind=media_deploy             lane=estate
  media.deploy.instagram       kind=media_deploy             lane=estate
  media.extract.audio          kind=media_convert            lane=estate
  media.extract.stills         kind=media_convert            lane=estate
  signal.publish.linkedin      kind=media_deploy             lane=estate
deploy target present for composer dropdowns: instagram:justinspencersmith
one store file holds both table sets + shared local_audit_log: writeback.db
  estate dispatch #1: media.convert.proxy state=queued payload round-trip OK
  estate dispatch #2: estate.agent_task queued -> approved (generic transition) OK
  estate dispatch #1: queued -> cancelled OK
  cancel guard: approved row refused by the state='queued' guard OK
audit rows (dispatch.enqueue x2, dispatch.transition, dispatch.cancel): 4
  github dispatch (writeback row #1): gh.project.move_item -> status_move state=pending payload round-trip OK (board user #3 — DetroitAutomationAcademy; item “Lane A — Live Transit sponsorships (foundation operationalized 2026-10-18)”: Todo -> In Progress, field PVTSSF_lAHOAc-P_c4BR-XRzg_pMis)
audit rows (writeback.enqueue): 1 — both lanes write the ONE local_audit_log
snapshot copy sha256 unchanged: 2041a99f5e0b058eedcebd27882a41c9c18a241d7f88d304bf12c865d94d0635
bundled snapshot sha256 unchanged: 2041a99f5e0b058eedcebd27882a41c9c18a241d7f88d304bf12c865d94d0635
SMOKE OK — two lanes enqueue locally, states transition + cancel under audit, snapshot pristine
```

## SF-T7 smoke check — palette scopes resolve, the dated truth stated (headless proof)

`python3 smoke_palette.py` runs the same SQL SnapshotStore runs
(datedItems / paletteResultsForQuery per scope / draftRows) against
the bundled snapshot, read-only. Verbatim output, 2026-11-10 (bundled
snapshot v7-0031 — the hash below is that pair's):

```
bundled snapshot sha256 (before): 0ce065be0d9b59d727a135437f8a9cdfba25b6fb01c14a57715e4b7c80fa19a3
palette board scope: 'DetroitAutomationAcademy' -> 1 board(s); user #3 present: DetroitAutomationAcademy (PVT_kwHOAc-P_c4BR-XR)
palette item scope: 'article series' -> 1 item(s); first: Live Transit Detroit — article series (Installments 01–07) (board: DetroitAutomationAcademy)
palette action scope: 'media.convert.proxy' resolves -> [('media.convert.proxy', 'media_convert')]
palette target scope: 'instagram' -> ['instagram:justinspencersmith']
palette draft scope: 'signal' -> 0 draft(s)
drafts query (sf_upcoming_drafts): 0 row(s) in this snapshot
dated items (Roadmap rows): 76 distinct item(s) on 19 board(s)
boards with Start/Target date fields: 19
date values carried: Start x73, Target x38 (both x35, start-only x38, target-only x3)
date range: 2026-09-22 -> 2026-11-26
sample dated row: [user #3 DetroitAutomationAcademy] Academy site rebrand (Forge D) start=2026-09-22 target=2026-10-01 status=Done
bundled snapshot sha256 (after): 0ce065be0d9b59d727a135437f8a9cdfba25b6fb01c14a57715e4b7c80fa19a3
SMOKE OK — palette scopes resolve, drafts count stated, dated-items truth stated, snapshot pristine
```

## SF-T11 — V11 Incidents lens (View ▸ Incidents, ⌘7)

The incident domain (design §12, registry `changes/0031`, snapshot
v7-0031) rendered in-app: `IncidentsViewController` shows the queue
(`SnapshotStore.incidentSummaries` — every `sf_incidents` row ordered
by next open deadline, deadline-less last, then severity position)
beside the detail (`incidentDetailForKey:` — summary, deadlines,
assets with hashes, and the `sf_audit_log` timeline via
object_ref `incident:<key>`). State/severity/counterparty names are
the snapshot's own vocabulary rows joined on `state_id` / `severity_id`
/ `counterparty_id` — no incident enum exists in the app. The five
§12.2 actions render as buttons (Draft Reply / Send Email… / Call /
File Complaint / Arm Watch); each opens a confirm sheet in
access-review form (destination + operator from the manifest row,
payload, grant-vs-decline) and enqueues through
`DispatchStore.enqueueDispatchWithActionID:incidentKey:extraPayload:error:`
— `incident.email.send` starts `queued` and stays there until the
owner approves it in the Orchestration Queue pane; queueing sends
nothing, ever. A snapshot predating 0031 states its version and the
reason the lens is empty. **VERIFY for SF-T11 is the Air rig (owner's
eyes) — see the rig steps below; nothing here claims runtime
verification.** Roadmap model reconciliation: `DatedItem` (per-item)
is the V5 model of record; the per-board `RoadmapEntry` sketch from
the parallel line was retired (recoverable in trash, 2026-11-11).

`python3 smoke_surfaces.py` runs the roadmap/palette/incident SQL
against the bundled snapshot, read-only. Verbatim tail, 2026-11-10:

```
incident queue (deadline order):
    X-DERHOHEN-2FA-2026-11-10    sev=High     state=Awaiting Owner assets=2 next=2026-11-11
    ROCKETMONEY-CHARGE-2026-11-11 sev=Medium   state=Triaged        assets=1 next=2026-11-11
    DBKRSMITH-STORAGE-2026-11-16 sev=Medium   state=Awaiting Owner assets=0 next=2026-11-16
    MAZDA-MFS-2026-11-10         sev=High     state=Awaiting Counterparty assets=9 next=2026-11-18
    MEMX-QUOTE-WATCH             sev=Low      state=Awaiting Counterparty assets=1 next=None
mazda detail: 9 assets, 1 deadline
incident.email.send enqueued as 'queued' with the incident_key payload — an approval request, never a send
bundled snapshot sha256 unchanged: 0ce065be0d9b59d727a135437f8a9cdfba25b6fb01c14a57715e4b7c80fa19a3
SMOKE OK — roadmap/palette/incidents read the record; dispatch queues, never sends
```

## Storage (SF-T12) — V12 Storage lens (View ▸ Storage, ⌘8)

The app side of the multi-tenant cloud storage domain (design record
`../03-CLOUD-STORAGE-DESIGN.md` — service §8 REST surface, app
integration §9). Three new files, all in the Makefile manifest:

- `CloudModels.h/.m` — the §9 value objects, estate model pattern
  (copy properties, no logic beyond the factory): `CloudTenant`
  (id, slug, display name, state, quota policy, usage figures),
  `CloudLogin` (tenant, username, display name, role, state, lock,
  last login — never credential material), `CloudBucket` (name,
  backend, object count, total bytes, quota), `CloudObject` (key,
  size, SHA-256 hex, content type), `CloudAuditEntry` (time, actor,
  action, object, result), `CloudServiceHealth` (version, bind,
  port, tenant count, uptime). Each carries
  `+fromJSONDictionary:` mapping the API's snake_case keys.
- `CloudServiceClient.h/.m` — the block-based async REST client over
  `NSURLSession` for the §8 routes the lens uses: health, tenants
  list/get/create/patch/close, usage, logins list/create/patch/delete
  + admin password set + reset issue, backends list, buckets
  list/create/delete, objects list/delete, audit list. Models ride
  the factories above; usage and backends return their decoded
  payloads verbatim (figures uncompressed).
- `StorageViewController.h/.m` — the V12 lens in the V11 pattern
  (programmatic AppKit, monochrome, 1120×680): left, the service
  state line + Start/Stop Service + the tenant table; right, the
  selected tenant's buckets (name, objects, bytes, quota), logins
  (username, role, state, lock), and audit tail (time, actor, action,
  result), with New Tenant… / Close Tenant… / New Login… /
  Set Password… / Issue Reset… / Delete Login… / New Bucket… /
  Delete Bucket… / Refresh.

**Loopback-only client.** `CloudServiceClient` is the app's THIRD
sanctioned `NSURLSession` file — a deliberate exception beside
`GitHubProjectsClient` (inert, flag-locked) and `SnapshotSync`
(read-only public GET), named as one in its header because §9 makes
the lens a pure REST client of the service it administers: the
console holds no second, privileged path to the data, contains no
SQL, and never opens `cloud.db`. Its base URL is built in exactly one
place and is literally `http://127.0.0.1:<port>` — the port from
`NSUserDefaults` key `SnowfellCloudPort` (default 8471, edited in
Preferences beside the existing settings; the host is never a
setting) — and every assembled request URL's host is re-verified as
`127.0.0.1` before the task resumes: a non-loopback path is refused
in code (`CloudServiceClientErrorNonLoopbackRefused`), not merely
never constructed. No network call exists anywhere in this tranche
outside this client's loopback calls. Errors surface in the client's
own domain with the §8 API error code preserved verbatim in
`userInfo` (`CloudServiceErrorCodeKey`; the envelope's figures ride
`CloudServiceErrorDetailKey`). List calls request the §8 maximum
page (`limit=200`); following `meta.next_cursor` is a stated seam.
Operator tenant scoping for the credential-scoped bucket/object
routes follows the §8 audit route's own convention (`?tenant=<id>`,
honored for operator callers) — stated in the client header.

**CMS + dedup in the lens (SF-T12j).** The Content section under
the buckets/logins/audit stack renders the §13.5 content model —
collections (the structure tree: name, slug, parent), content items
(slug, title, kind, state, current version, size), and the selected
item's append-only version history (version, SHA-256 short, size,
note, created) — through three more model classes (`CloudCollection`,
`CloudContentItem`, `CloudContentVersion`) and the client's §13.7
calls: collections list/create/delete, content list (collection /
kind / state filters; a text query rides the §13.5 search route) /
get / create / patch / delete, versions list/create, rollback, and
the state route. Content is created and versioned by REFERENCING an
already-uploaded blob id — payload bytes enter through the API's
own upload callers, never through this lens, and downloads are not
client calls either: the lens manages structure and references and
handles no files, exactly as it lists object metadata without
fetching object bytes. The section header carries the §13.6 dedup
figures from the usage payload's `dedup` block (logical / physical /
saved / ratio, plus blob and reference counts — quota charges
physical bytes, so the savings accrue to the tenant), and Run GC…
runs the §13.3 sweep for the selected tenant's scope in two steps:
a dry run first, its aggregates (scanned / orphans) shown in the
confirm sheet, and only then the real sweep via the operator route
(`POST /v1/admin/gc` with the tenant id in the body — `/v1/gc` is
the tenant_admin session route and refuses operator callers),
reporting scanned / deleted / bytes reclaimed — aggregates only,
per §13.8's discipline. Every content mutation goes through the
same access-review confirm/prompt sheets as the rest of the lens.
Honest limits unchanged: helper packaging rides the build line
(performed by CI from snowfell-test-2), runtime proof rides the
Air rig, and the lens was not run against a live service in this
tranche — the CMS calls are built to the §13.7 contract the
SF-T12i service lands against.

**Keychain token + pairing flow.** The operator token is a Keychain
generic-password item (service
`com.detroitautomationacademy.snowfell.cloud-operator`, account
`operator`; D4 custody). The client reads it at call time inside its
single request builder, sets that request's `Authorization` header,
and keeps it in no property; the presence probe is attributes-only.
When no token is stored, the lens shows the PAIRING PANE instead of
data: the §5.5 bootstrap instructions (first run writes the token
once to `~/Library/Application Support/Snowfell/cloud/bootstrap-operator-token.txt`,
mode 0600), a token field, and Save to Keychain
(`saveOperatorToken:` → `SecItemAdd`/`SecItemUpdate`). The service
deletes the bootstrap file on the first successful operator
authentication; the pane instructs the same deletion by hand.

**The service's standalone home** is `StorageService/` beside this
app tree (portable C99 + sqlite3: `sfhttp` / `sfstore` / `sfauth` /
`sfadapter` / `sfjson` / `sfsha256`, DDL in `schema_cloud.sql`) — it
runs standalone from a terminal, owns
`~/Library/Application Support/Snowfell/cloud/`, and is equally the
integration suite's target; the lens is only its console. In the
lens, service state comes from `GET /v1/health` polls (Stopped, or
Running on 127.0.0.1:<port> — v<version>, with bind, tenant count,
and uptime; a non-loopback bind is flagged in the line, §2.3).
Start/Stop drive the bundled helper with `NSTask`
(`-[NSBundle pathForAuxiliaryExecutable:@"SnowfellStorageService"]`):
a service already answering health — e.g. run standalone — makes
Start a no-op success and is never terminated by the lens; Stop
terminates only a task this lens started, and the state line says
whose service it is. Every mutation goes through a confirm sheet in
access-review form naming the target: destination (the loopback base
URL), operator (the Keychain token), the exact effect, and that
declining sends nothing. An issued reset token is shown exactly
once, in a selectable field, for out-of-band delivery (§5.4) and is
kept nowhere.

**Honest limits.** The helper joins the bundle at PACKAGING time
(built by `StorageService/Makefile`, copied into
`Contents/MacOS/` — from snowfell-test-2 the CI workflow performs
this step: it builds the service for x86_64 / macOS 10.13 and places
it in the bundle as `SnowfellStorageService`; the Makefile carries
the note and the `app` target's compile line is unchanged), so a
source build of the app alone lacks it: the lens then disables
Start/Stop and states the reason in the service line rather than
faking a start. The service itself (SF-T12c–e) is its own tranche
and schema/0008 (SF-T12b) has since been applied by the registry
single writer (snapshot v8-0041, bundled from snowfell-test-2);
this tranche is the console.
**VERIFY for SF-T12f is `./build.sh check` (below) plus the Air rig
(owner's eyes) for runtime proof — nothing here claims runtime
verification: no service was run against this client in this
tranche, and the lens's REST contract is the suite-proven §8 API,
not a second implementation.**

Syntax check for this delivery (2026-11-12, estate recipe via
`./build.sh check`): **31/31 files PASS, `ALL SYNTAX OK`, 0 errors,
0 warnings in the new and touched files** (the three new sources +
`AppDelegate.m` re-checked individually: silent).

## Known gap: AppIcon asset

No `AppIcon.icns` is included: Snowfell's registered glyph (SDS-3
distinctiveness — one concept, no repeated silhouette family) is a design
step that has not been cut yet, and a placeholder mark would violate the
one-composition rule the moment it shipped. The mechanism is conforming —
`AcademyAppIconView` and the About panel both draw the bundle's AppIcon —
so dropping the registered `.icns` into the bundle (and adding it to the
Makefile's RESOURCES) unifies bundle, Dock, welcome, and About with no
code change. Until then the app presents the system generic icon.

## Next step for a Mac rig build (Justin's MacBook Air, macOS 10.13.6)

1. Copy this `app/` folder to the Air.
2. `cd app && ./build.sh app` — assembles `Snowfell.app` with the system
   clang (Xcode Command Line Tools), links AppKit + Foundation + sqlite3,
   and copies `Info.plist` + the three resources into the bundle.
3. `open Snowfell.app` — verify, in order: the welcome sheet presents with
   the AppIcon composition, the version line reads "Version 0.1.0 (1)" and
   matches the bundle plist, the startup sound plays once, the snapshot
   line reads "Registry snapshot v7-0026 · 74 boards · 614 items", and the
   Portfolio lists the boards (archived pair hidden until toggled).
4. SF-T3 checks: double-click user board #3 in the Portfolio — the Board
   opens with Todo / In Progress / Done columns holding 80 / 6 / 15
   cards; switch the board popup to KisMac Uplift — seven columns
   (Intake…Gated), 10 cards under Intake; click any card — Item Detail
   opens with the item's field values and the 7 handler chips; confirm
   View ▸ Item Detail is disabled until a card is selected.
5. SF-T4 checks (all local — no token exists on the rig yet, and none of
   this may touch GitHub): on a card, change the Status popup — the
   confirm sheet names `updateProjectV2ItemFieldValue`, the item, and
   the from→to values; confirm, then open View ▸ Write-back Queue (⌘4):
   the row sits `pending`, the panel reads compiled OFF / token not
   configured, and Send Pending… is disabled with the reasons printed.
   Cancel a second popup change and confirm the popup settles back to
   the snapshot status both ways. Queue a New Item… and a V3 comment
   the same way (3 rows). Confirm File ▸ Send Pending Mutations… is
   disabled, and that `~/Library/Application Support/Snowfell/writeback.db`
   exists with the 3 rows + 3 `writeback.enqueue` audit rows while the
   bundled snapshot's hash is still `2041a99f…`.
6. SF-T5 checks (all local): open View ▸ Orchestration Center (⌘5) —
   the manifest lists all 15 actions; select `media.convert.proxy` and
   confirm the form is exactly asset_id + profile (prefilled
   `proxy720`), the lane line reads Estate, and Enqueue stays disabled
   until asset_id holds an integer. Queue it: the confirm sheet names
   the estate lane and states queueing is not executing; the row then
   sits `queued` in pane (c) with a `dispatch.enqueue` audit row beside
   it. Cancel it from pane (c) — state `cancelled`, `dispatch.cancel`
   audited. Select `gh.project.move_item`: pick board #3, an item, and
   a Status; queue it and confirm a fourth `status_move` row appears in
   the Write-back Queue (⌘4), still `pending`, nothing sent. Select
   `media.deploy.instagram` and confirm the precondition line reads
   "review verdict: not connected in this build". The same
   `writeback.db` now also holds `local_dispatches` (2 rows: 1
   cancelled, plus any you queued) — one file, both stores.
7. SF-T6 checks: File ▸ Check for Snapshot Update… — with the network
   up, Preferences ▸ Snapshot sync should show the served version beside
   the running one; if a newer snapshot is published, Check downloads +
   verifies it into `~/Library/Application
   Support/Snowfell/snapshots/<version>/` and Apply Update enables —
   press it and confirm the Portfolio rebuilds on the new snapshot and
   Help ▸ Snapshot Details names the new version. Kill the network and
   Check again: the failure is reported and the running snapshot stands.
   Confirm nothing was fetched at launch (no sync traffic before the
   first Check press).
8. SF-T7 checks: View ▸ Roadmap (⌘6) — the header should read 76 dated
   items on 19 boards, range 2026-09-22 → 2026-11-26 (bundled snapshot
   v7-0031); board #3's group holds 14 rows, two-ended items draw bars,
   one-ended items draw diamonds, and double-clicking a row opens its
   Item Detail. View ▸ Command Palette… (⌘K) — the browse list shows
   boards + actions + targets (94 rows, drafts 0); type "article
   series" and Enter: Item Detail opens on the Live Transit article
   item; type "media.convert.proxy" and Enter: the Orchestration
   Center opens with that action preselected in the composer; Esc
   closes the palette and changes nothing. Preferences — three separate
   lines read: token "no token stored" (nothing has been provisioned
   on the rig), write-back "DISABLED in this build", and both queue
   counts matching ⌘4 / ⌘5; the token-entry field is disabled with its
   D4 reason printed in it; the Snapshot sync block appears exactly
   once.
9. SF-T11 checks (the V11 lens — owner's eyes are this tranche's
   VERIFY): View ▸ Incidents (⌘7) — the queue lists 5 incidents in
   deadline order (X-DERHOHEN + ROCKETMONEY first, both due 2026-11-11;
   DBKRSMITH-STORAGE 2026-11-16; MAZDA-MFS 2026-11-18; MEMX last, no
   deadline). Select MAZDA-MFS-2026-11-10: the detail shows 9 assets
   (the packet's hashed files among them), 1 deadline (2026-11-18,
   response_due), and the timeline line stating no audit entries ride
   this snapshot yet. Press Send Email…: the confirm sheet names
   `incident.email.send`, the estate lane, and the owner gate; confirm
   and confirm the row sits `queued` in the Orchestration Queue pane
   (⌘5) — nothing was sent. Press Draft Reply on X-DERHOHEN and confirm
   a second queued row. Decline a third button's sheet and confirm
   nothing queued.
10. Exercise every menu item once (SDS-10 §10.4.6 check) and screenshot the
   app menu open with Quit visible.
11. Only with that evidence: the build line cuts the first catalog build —
   audit + conformance attestation, Distro listing at `testing` (SF-T8;
   no `released` flip without Justin's verdict). Arming write-back is
   NOT part of the catalog build: it follows the enable path in the
   write-back section, on Justin's separate word.

## Deliberately not here (later tranches, by design §6)

The ESTATE CONSUMER's EXECUTION half (SF-T6 delivered the consumer's
report-only drift checker + the in-app sync below; executing queued
dispatches — deploy rows meeting the real Henchman verdict source,
estate actions running — remains unbuilt, and queued write-back rows
still meet a refreshed snapshot only when the owner applies one) ·
registering the `snowfell-sync-watch` hook (spec filed at
`../../hidden_files/work/SNOWFELL-SYNC-WATCH-HOOK.md`; the parent
registers it after review) · element invocation (§9.1 — the Elements
chips still display-only) · dynamic workflow discovery (§3's per-repo
workflow enumeration on sync — the manifest seeds are what this build
composes) · the V10 Drafts lens as its own window (§11.3 — SF-T7 wired
drafts into the ⌘K scope and the store's draftRows query; the bundled
snapshot carries zero compositions, so a dedicated lens window waits
for data worth lensing) · SF-T8 Distro publish
+ rig verify. The shell's seams are cut for them: `SnapshotStore` is
the only snapshot door, `WriteBackQueue` + `DispatchStore` are the
only writable stores (one shared file), and the menu carries no item
whose action belongs to a tranche that has not landed.

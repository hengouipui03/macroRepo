# AA Path Macro: modular fix plan (APPROVED 2026-11-12)

Repo working copy: /home/claude/repo (git, branch `cleanup/match-state`, based on cf5369a).
Files are UTF-8 **with BOM** and **CRLF** line endings. Keep both on every file you touch.
Tests: `cd /home/claude/repo && AHK_RUNTIME=/usr/local/bin/ahkw python3 <Name>Tests.py` (AutoHotkey v2 under wine).
Run all: `for t in *Tests.py; do AHK_RUNTIME=/usr/local/bin/ahkw timeout 300 python3 "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done`
Baseline at cf5369a: 13 pass, 4 FAIL (ActionPacing, CardPriority, CheckpointManager, PlacementPairing). The tests have drifted from the code.

## User answers that fix the design
- Pressing the P **key** does nothing. P is toggled only by clicking the toolbar P button. On = the "P" glyph is white and filled; off = dim grey.
- Holding a unit (its slot key pressed) shows an "n/max" counter above its hotbar slot, e.g. "0/3", "2/3", "1/1". It also shows when the slot is full. Use it.
- Scope: clean up wherever possible. Bugs keep coming back when new changes are layered on.

## Root causes (evidence: session log 2026-11-12, screenshots, code, git history)
1. No owner for the match phase. About 12 flags imply it, and per-match resets are scattered across 7 functions. Fixes flip shared flags (e.g. `BeginUnitManagerPhase` during placement), and that breaks other readers.
2. Purchase confirmation can't tell new from existing. The unit panel also opens on an already-placed unit. The F-manager fallback uses bottom-row parity, which is a coin flip: at 12:37 it recorded 2 ghost units, and a screenshot shows 4 units on the field against 6 recorded.
3. A wrong recorded count is never corrected. The tile lookup retries forever: 625 + 193 log lines, one match lost.
4. The F check during placement sets the upgrade-phase flag, the card handler then reopens F mid-placement, and the 20 s F lockout is wiped.
5. P is judged by the glyph only, once, at Vote Start. The path was often unlit when placement started.
6. Yen is checked after a failed purchase (each miss costs an F open/scroll/close), and it is read during UI transitions ("5 of 1300").
7. cf5369a forces `gRunning := true` for OCR after a run ended: F6 is ignored meanwhile, and the flag is stuck on if the read throws.
8. Silent run exits (card 20 s timeout `return false` → RunMacro bare `return`).
9. Retry loops without bounds: TryStartFromLobby, ReconnectAndRestart, the build loop, RefreshPathView, the tile lookup.

## Design rules (apply everywhere)
- **No new global flag to change another module's behaviour.** Modules expose functions, and a phase is tested only with `InPhase()`.
- **Every retry loop has a named bound** (a constant at the top of its module) and a defined escalation when it runs out. No infinite loops.
- **No magic numbers in logic.** Use named constants. Pixel regions stay where they already live (button records / layout defaults) and are not duplicated.
- **No optional boolean parameters that skip a safety check.**
- **Every exit from the run loop logs its reason** through `EndRun(reason)`.
- Keep behaviour the user asked for (see MACRO_BEHAVIOUR.md and the user rules below) unless this plan changes it explicitly.

## User rules that must keep holding (from the user's standing rules)
- F unit manager: opened only after all units are placed. It stays open while upgrades remain, is closed for cards and reopened after them, and is closed when all upgrades are done. A manager left open from the last match is closed at match start.
- Upgrades strictly follow upgrade priority: no moving on to a lower priority while a higher one is unfinished.
- Placement: relocate after 6 failed purchases (3 on the other side); next unit beside the last placed; partner-behind pairs; Hybrid prefers green Hill; Money unit placed apart on the path edge.
- The side unit panel is never left open.
- On a Disconnected dialog: Reconnect, wait for LobbyPlay, restart from LobbyPlay.
- A log is written continuously for each F6..F7 session.

## Design

### A. `MatchState.ahk` (new): the one owner of phase and per-match state
- `global gPhase := "Idle"`. Phases: `Idle`, `Lobby`, `Preparing` (vote, walk, P), `Placing`, `Upgrading`, `Ended`.
- `SetPhase(p)` validates the name and logs `"Phase: <old> -> <new>"`. `InPhase(p*)` returns true if `gPhase` is any of the given names.
- `ResetMatchState()` is the ONLY per-match reset. It calls each module's own reset (`ResetPlacementSearch`, `ResetCardSelection`, `ResetMatchCardContext`, `ResetEndGameFlow`, `ResetUnitManagerState`, `ResetPathLight`, `ResetPurchaseVerifier`, ...). Remove the scattered inline resets in `EnsureRouteAndSpawn`/`RunMacro` and replace them with calls to it.
- Session vs run: `gSessionArmed` (true from F6 until F7) and `gRunning` (the run loop/thread is live, as today). `CheckDisconnect` uses `gSessionArmed` and never writes `gRunning`. OCR functions that abort on `!gRunning` take an optional abort predicate instead (default `() => gRunning`). CheckDisconnect passes `() => gSessionArmed`.
- `gUnitManagerPhase` is deleted. Its readers use `InPhase("Upgrading")`.

### B. `PurchaseVerifier.ahk` (new): the one place that decides "did this click buy a unit?"
Pure decision plus probes. It never presses F, never changes phase and never writes placement globals.
- Probe 1, **slot counter** (strong): the "n/max" counter above the held unit's hotbar slot. Read it right before the click (while holding the unit). After the click, read it again. If the unit is no longer held, press the slot key, read, then cancel with Q. Use OCR of the hotbar strip above the slots (the existing hotbar/cost OCR in `ReadPlacementMoney` already knows the slot layout; reuse its geometry, don't add new coordinates). Parse `(\d+)\s*/\s*(\d+)`.
- Probe 2, **Yen drop** (strong): Yen before (already read for affordability) vs Yen after. Each value needs 2 agreeing reads. A drop ≥ `PURCHASE_YEN_DROP_FRACTION` (0.5) × unit cost confirms. No drop with both values readable denies.
- Probe 3, **unit panel** (weak): counts as confirmation only when no recorded unit lies within the occupied radius (`CandidateOccupied`) of the click point.
- `DecidePurchase(evidence)` is a pure function and is unit-tested. In order:
  - counter before/after readable: after = before + 1 → `confirmed`; after = before → `denied`.
  - else Yen readable both: drop ≥ fraction × cost → `confirmed`; no drop → `denied`.
  - else weak panel (no recorded unit nearby) → `confirmed`.
  - else `unknown`.
- `unknown`: keep the purchase pending and re-probe (counter then Yen) up to `PURCHASE_REPROBE_LIMIT` (3). If it is still unknown, treat it as a failed attempt but do NOT blacklist the spot.
- Yen affordability is checked BEFORE clicking (2 agreeing reads). If short, wait for Yen (existing wait logic) and don't click.
- Delete `ManagerHoldsUnrecordedUnit`, the `managerConfirmed` parameter of `FinishPlacement`, the selection-click probes in `RecoverPendingPlacement` (clicking the spot can select an existing unit), and both test stubs.

### C. Build audit and reconciliation
- `AuditBuild()`: for each enabled slot, read its counter (slot key, then read, then Q). Compare with `CountSlotPlacements(slot)`.
  - recorded > counter: remove that slot's newest recorded entries down to the counter value. Log each removal as "ghost". Keep the order of the remaining entries.
  - recorded < counter: log it (a purchase the macro missed). Don't invent coordinates; mark the copy as placed so the build doesn't re-buy it, but leave it with no anchor position.
  - Return whether the build is complete per the counters.
- Run `AuditBuild()` when placement thinks the build is complete, before `SetPhase("Upgrading")`. If it is incomplete, stay in `Placing`.
- In `Upgrading`, a manager mismatch (bottom-row count disagrees with the recorded count, or "reached top without purchase #N") retries at most `MANAGER_LOOKUP_LIMIT` times. Then: close F, `SetPhase("Placing")`, `AuditBuild()`, place what's missing, and return to `Upgrading`. Bounded by `AUDIT_LIMIT_PER_MATCH`. When that's exhausted, log it, keep upgrading the units that are found, and skip only the missing ones.

### D. Unit manager gate and cards
- `PressUnitManagerKey()` opens only when `InPhase("Upgrading")`. Closing is allowed in any phase. It has one implementation, and the four call paths use it.
- Card handling is phase-aware. Before cards: drop the preview; close F only if `InPhase("Upgrading")`; close the side panel. After cards: in `Placing`, resume/re-probe the pending purchase (no F); in `Upgrading`, reopen F and reselect the top-priority unit.
- Card timeout: do not end the run. Log it and continue; the game's vote timer auto-picks a card. Bounded by the existing deadline.

### E. `PathLight.ahk` (from `EnsurePathLit`)
- State = glyph (white filled = on) + effect (a lit path detected by the existing world/path reader).
- Per map variant, remember whether a lit path was ever detected (store it alongside the placement profile in learning.ini; not hardcoded).
- `EnsurePathLight(context)` is called at Vote Start and again at the start of `Placing`:
  - glyph off → click P (existing ClickRef on the saved P point), then verify the glyph with polls. Up to `PATH_CLICK_LIMIT` clicks per call; stop as soon as the glyph changes (so it never toggles back off).
  - glyph on, but the variant is known to show a lit path and none is detected at Placing start → toggle once off and once on, each glyph-verified. Once per match.
  - glyph unreadable → log and continue (red overlay fallback as today).
- Keep the "P only by clicking" rule. No P key press anywhere.
- Diagnostics: keep the click-miss crop save.

### F. Run-loop hygiene, lobby, reconnect
- `EndRun(reason)` replaces the bare `return`s in RunMacro; it always logs.
- `TryStartFromLobby`: collapse the nested retry layers into one loop with a named bound per stage (find Play, click with verification, matchmaking panel, Find Match/queue prompt). Same observable steps; bounded; logs which stage gave up. A give-up leads to `EndRun` or one restart from the lobby, never an infinite loop.
- `ReconnectAndRestart`: keep clicking Reconnect until LobbyPlay shows (the user wants this), with a named cadence. Add a long cap (`RECONNECT_GIVE_UP_MS`, 30 min) that logs and Discord-notifies, then keeps the session armed and checks again later rather than spinning.
- Remove `ClickSavedLobbyPlay`'s unverified blind click only if a verified path already covers it; otherwise keep it behind a named constant and log line. Don't change lobby behaviour beyond structure without evidence.

### G. Dead code and stale state
- Delete functions that have no callers (verify with grep across all .ahk and *Tests.py first). Candidates come from the code maps: unused functions in AAPathMacro.ahk, MapNavigation.ahk and Endgame.ahk, and the PlacementArea dead functions and the SelectManagedUnit/OpenRecordedUnit chain if truly unreferenced.
- `placement_run.ini` written but never read: remove the writes or document why they're kept (user syncs learned files via git; check README/MACRO_BEHAVIOUR first).
- Fix the misleading log: PlacedUnits "unit panel confirmed" must say which evidence confirmed the purchase.

### H. Tests
- Repair the 4 failing tests so they reflect the current intended behaviour (don't weaken assertions to make them pass; fix the fixtures/stubs that drifted).
- New tests: `DecidePurchase` table; F refused outside `Upgrading`; `AuditBuild` removes ghosts and keeps order; card close/reopen per phase; PathLight decision (glyph/effect matrix); bounded lobby retries.
- Update MACRO_BEHAVIOUR.md and README where behaviour or structure changed.

## Out of scope
Movement calibration (`ProbePlayer`/`MoveAxesValid`), map-specific stands, card priority rules, vision (Python) algorithms, apart from adding the counter OCR parse if needed.

## Build steps (each: tests green before the next; one commit per step)
0. Repair the 4 failing tests (baseline green).
1. MatchState + session/run split + single ResetMatchState + remove the gRunning override (cf5369a). Delete `gUnitManagerPhase` in favour of `InPhase`.
2. Remove the F fallback and the managerConfirmed flag; F phase gate; phase-aware cards; card timeout no longer ends the run; EndRun.
3. PurchaseVerifier (counter + Yen + weak panel), Yen-before-click, re-probe policy.
4. AuditBuild + manager mismatch escalation + bounded lookups.
5. PathLight.
6. Lobby/reconnect structure + bounds.
7. Dead code, stale state, log wording, docs.
8. Independent review (fresh agent) against this plan and the user rules.

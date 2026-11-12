# AA Path Macro: what it does, every function, every decision

This describes the macro as it currently stands (after the "unit manager stays open" change).
Coordinates are in the 800 x 600 **reference** space unless stated otherwise; they are scaled
to the live Roblox client area at run time. Roblox is sized to 1401 x 975 outer pixels on Start.

---

## 1. Files

| File | Role |
|---|---|
| `AAPathMacro.ahk` | Entry point, GUI, hotkeys, input primitives, colour helpers, card detection/choice, Vote Start flow, the match state machine (`RunMacro`), session control and disconnect detection (`CheckDisconnect`), idle keep-alive, self-tests. |
| `MatchState.ahk` | The one owner of the match phase (`gPhase`: Idle, Lobby, Preparing, Placing, Upgrading, Watching, Ended) and of the per-match reset. `SetPhase`, `InPhase`, `ResetMatchState`, `EndRun`. |
| `LobbyFlow.ahk` | The lobby start and the reconnect loop: `TryStartFromLobby` (staged and bounded), the Play-button readers, `ReconnectAndRestart` and its give-up. All their bounds are constants at the top of the file. |
| `QueueMatch.ahk` | Queue mode: Find Match, the number prompt, Submit, waiting for the queued match (`WaitForQueuedMatch` gives up after `QUEUE_WAIT_LIMIT_MS`, 15 min, logs it and hands over to `RecoverVoteStart`). |
| `UnitSettings.ahk` | Six unit slots (enabled, name, count, priority, target, Hill only / Hybrid / Money, mutually exclusive) saved to `unit_settings.ini`. |
| `MapNavigation.ahk` | Minimap reading (Python vision or AHK fallback), route graph, checkpoints, player probing, movement, obstacle escape, lit-path following. |
| `PathLight.ahk` | The P (path light) button: `EnsurePathLight(context)` at Vote Start and at the start of Placing, glyph-verified clicks, the learned per-variant lit-path flag, the once-per-match off-on cycle, `ResetPathLight`. |
| `Placement.ahk` | Placement candidates, purchase clicks, unit-panel detection, click-away, pending-purchase recovery, the build loop. |
| `BuildAudit.ahk` | The build audit: the recorded placements against the game's slot counters (`AuditBuild`), the bounded audit at build completion, the unit-manager lookup limits and the escalation back through Placing (`RepairBuildAfterManagerMismatch`), per-slot caps. |
| `PurchaseVerifier.ahk` | The one place that decides "did this click buy a unit?": slot-counter probe, Yen probe, weak unit-panel probe and the pure `DecidePurchase`. |
| `PlacementArea.ahk` | Six-failure streak, checkpoint relocation (25% → 50% → 75% of the route). |
| `PlacedUnits.ahk` | Numbered purchase record, upgrade queue, tile-based upgrades (segments, Max, Upg clicks), identity guard, back-off. |
| `UnitManager.ahk` | F unit manager: when F may be pressed, keeping it open, scrolling, finding purchase #N's tile (odd/even layout). |
| `Learning.ahk` | OCR, learned buttons, card text policy and ranking, placement memory. |
| `CardContext.ahk` | Card word colour (green/red) reading, pixel green detection, resistance preference tab, right-panel match modifiers. |
| `Endgame.ahk` | End screen detection, Next/reward dismissal, Replay. |
| `Discord.ahk` | Optional WIN/LOSS webhook with screenshot, and `DiscordWarn` for give-ups (a slot given up, a Reconnect that did not reach the lobby). |
| `MinimapVision.py` | OpenCV service (minimap, lit path, placement lines, Hill spots, unit manager tiles: segments, Max, Upg point, portrait colours). AHK sends all input. |
| `OCRBridge.ps1` | Windows OCR bridge used by `ReadOcrRows`. |
| `*.ini` | `unit_settings.ini`, `card_preferences.ini`, `settings.ini` (webhook), `button_positions.ini`, `learning.ini` (learned data), `placement_layouts.ini`. (`placement_run.ini`, the numbered purchase record, was only ever written and never read back; it is no longer written. An old copy can be deleted.) |

Hotkeys: **F6** start, **F7** stop (releases every key), **F8** overhead camera reset, **F9** route test (no voting/buying), **F10** teach the button under the cursor.

---

## 1a. Architecture and design rules

Each module owns one thing. A change goes into the module that owns the concern; it does not reach into another module's state.

| Module | Owns |
|---|---|
| `MatchState.ahk` | The match phase (`gPhase`) and the one per-match reset. Nothing else decides "where in the match are we". |
| `LobbyFlow.ahk` | Getting from the lobby into a queued/started match, and getting back to the lobby after a disconnect. |
| `QueueMatch.ahk` | The Queue-mode dialogs after Play. |
| `PathLight.ahk` | The P button and the lit-path state. |
| `PurchaseVerifier.ahk` | The decision "did this click buy a unit?". It never presses F, never changes the phase, never writes placement state. |
| `Placement.ahk` / `PlacementArea.ahk` | Where units go, the build loop, relocation between checkpoints. |
| `BuildAudit.ahk` | Reconciling the record with the game's slot counters, the per-slot caps, the unit-manager lookup limits and cooldown. |
| `PlacedUnits.ahk` | The numbered record of placed units (`gPlacements`) and the upgrades of those units. |
| `UnitManager.ahk` | The F unit manager: the F gate, finding purchase #N's tile. The only code that sends F. |
| `CardContext.ahk` / card code in `AAPathMacro.ahk` / `Learning.ahk` | Cards: detection, ranking, choice. Learned data (buttons, card text, placement memory). |
| `Endgame.ahk` | The end screen and Replay. |
| `MapNavigation.ahk` | Minimap, route, walking. |

**Phases** (`SetPhase`/`InPhase`; every change logs "Phase: old -> new"): `Idle`, `Lobby`, `Preparing` (vote, walk, P), `Placing`, `Upgrading`, `Watching` (every target reached, F closed), `Ended`. Behaviour that depends on the phase asks `InPhase()` and nothing else.

**Design rules** (each one exists because a bug came back without it):
1. **One owner for the phase.** No flag implies a phase. Per-match state is cleared only by `ResetMatchState()`, which calls each module's own reset; a new piece of per-match state gets a `Reset...` function that `ResetMatchState` calls.
2. **No new global flag to change another module's behaviour.** Modules expose functions; a phase is tested only with `InPhase()`.
3. **Every retry loop has a named bound** (a constant at the top of its module) and a defined escalation when it runs out. No infinite loops; a long wait is a timestamp check inside the watch loop, not a sleep.
4. **No magic numbers in logic.** Named constants. Pixel regions live where they already are (button records, layout defaults) and are not copied.
5. **No optional boolean parameters that skip a safety check.** `PressUnitManagerKey` takes `"open"`/`"close"`, not a flag.
6. **Every exit from the run loop goes through `EndRun(reason)`**, which always logs why. A give-up that continues (a slot capped, F cooldown) logs one clear line and, where it loses units, warns Discord.
7. **Session vs run:** `gSessionArmed` is F6..F7; `gRunning` is "the run loop is live". `CheckDisconnect` uses the session and never writes `gRunning`.
8. **F** is opened only in `Upgrading`; closing is allowed in any phase. **P** is toggled only by clicking its toolbar button, never by key.
9. Tests extract functions from the `.ahk` files by name (`function(file,name)`), so a function must start at column 0 as `Name(params) {` and end with `}` at column 0. A function used only by a test is a test helper and lives in the test.

---

## 2. One match, start to finish

```
F6 → StartMacro → RunMacro (loops on "replay" and "restart")
  ├─ phase Lobby                    F is forbidden outside the Upgrading phase
  ├─ Lobby: Play → hold W → Play Here → Open → Start   (TryStartFromLobby, staged and bounded, see §7a)
  ├─ Wait for Vote Start (45 s); on timeout → RecoverVoteStart
  ├─ ResetMatchState + phase Preparing   every module's per-match state is cleared here, once
  ├─ EnsureRouteAndSpawn            minimap → P lit (EnsurePathLight "vote") → overhead camera → find player → 3 checkpoints
  ├─ NavigateForPlacement           walk to checkpoint 1 (50 s prep budget)
  ├─ TryVoteStart                   click the green Yes
  ├─ phase Placing + EnsurePathLight "placing"   P checked again; an off-on cycle once if this map variant should show a lit path
  ├─ PlaceConfiguredBuild           every enabled slot × count, cards handled throughout, NO upgrades, NO F
  │                                 when every slot looks complete: AuditBuild (slot counters vs the record); incomplete → keep placing
  ├─ BeginUnitManagerPhase (phase Upgrading) + EnsureUnitManagerOpen      ← the FIRST time F can be pressed
  └─ Watch loop until the match ends:
        cards → ClearCardChoice (a timeout is logged and the loop carries on; it never ends the run)
        end screen → TryEndState (phase Ended; Next, rewards, Replay) → return "replay"
        RefreshMatchModifiers, MaintainUnitManager, UpgradePriorityPass, IdleKeepAliveTick
        a unit-manager lookup that keeps failing → close F, phase Placing, AuditBuild, place what is missing, back to Upgrading (§5a)
```

### Decisions in the flow
- If a match is already running (route on the minimap, no Vote Start), the macro refuses to build into it.
- If Vote Start is not confirmed in time (45 s from the lobby, 3 min after Replay), `RecoverVoteStart` keeps reading the screen instead of ending the run: Vote Start → continue as normal; lobby → restart from LobbyPlay; end screen → Replay flow; minimap route with no Vote Start for 10 s → sit the match out until its end screen. It logs every 30 s while nothing recognisable is on screen. Only F7 or a disconnect ends it.
- An end screen visible at start is handled first (Replay).
- Navigation timeout is not a failure: placement starts from where the player is.
- **Vote Start click** (`TryVoteStart`): one click on the visible Yes. A counted vote closes the panel within about a second. If it is still open 4 s later, the `0/1` count under the title is read (`ReadVoteCount`): a counted vote gets no second click, as Yes may toggle it back off; an uncounted or unreadable one gets one more click, the cursor first moved off and back. Then the macro waits for the countdown to close the panel (up to a minute) and places as normal; the run never stops over it. Only a panel still open after a minute sits the match out.
- **Click evidence:** an untaken Vote Start or P click saves the region as it looked afterwards to `cache\clickmiss-<vote|p>-<date_time>.bmp` (newest 10 kept, `SaveClickMissCrop`). The P log lines include `levels <P>,<i>`, the brightness of the P and i glyphs that decide on/off.
- A build that is not complete never reaches the upgrade phase (see §5).

---

## 3. The F unit manager (rules)

| Rule | How it is enforced |
|---|---|
| F is pressed **only after every configured unit is placed**. | The match phase is not `Upgrading` until `RunMacro` calls `BeginUnitManagerPhase()` (which is `SetPhase("Upgrading")` plus the manager's own reset) after `PlaceConfiguredBuild` returns `complete`. `PressUnitManagerKey(action)` is the only code that sends F. `"open"` is refused unless `InPhase("Upgrading")` (`UnitManagerActive()` is exactly that); `"close"` is allowed in any phase, and callers send it only after two readings confirm the manager is open. There is no exception: the old F-manager purchase fallback is gone. Placement, relocation and route preparation never touch F. |
| Once open, it **stays open while upgrades remain**, except during card choice. | Unit switching, finished targets, paused units and idle clicks never close it. **Once every upgrade target is reached** the watch loop closes it once (`CloseUnitManagerIfOpen`, F only after two readings confirm it is open) and calls `EndUnitManagerPhase()` (phase `Watching`: every target reached, F closed, watching for the end screen), so it stays closed; a target raised in the GUI mid-match opens it again. **Cards are phase-aware:** `CloseUnitManagerForCards()` presses F (to close) only if two readings agree the manager is open (at most twice), and the cards are read only after two readings in a row confirm it is **closed**. The open manager covers the right-hand card. In `Upgrading` the close is remembered, and when the card screen is gone `ReopenUnitManagerAfterCards()` reopens it through the guarded `EnsureUnitManagerOpen()` and resets the upgrade selection, so the top-priority unit is reselected through the manager before any R. In `Placing` (and every other phase) a manager that reads open is a leftover and is only closed; F is never reopened after the cards and the pending purchase resumes without F. **Card timeout:** a card still open after `CARD_CHOICE_TIMEOUT_MS` (20 s) logs "Card choice still open after 20s; the game's vote timer will pick; continuing."; `ClearCardChoice` returns false so the caller takes no action over the open card, and no caller ends the run for it. |
| Click-aways never hit the manager. | The click-away point moved from (740,150), which is on top of the open manager, to **(497,168)**: empty world between "Return to lobby" and the manager's left edge, above the cards and right of the side unit panel. It is `CLICK_AWAY_X/Y` in `AAPathMacro.ahk`. |
| F is never sent on a guess. | `EnsureUnitManagerOpen()` presses F only after **3 consecutive "closed" readings**. Failed or unreadable frames reset the count. F is not repeated within **2.5 s** of the last press, so it cannot fire again while the manager is still animating open. |
| "Open" means the real manager. | Vision (`unit_manager`) only accepts the yellow "Unit Overview" heading when it is a thin text line on the manager's dark panel. Bright yellow scenery in that corner (Sand Village's path) once read as "open": F was skipped after placement and after cards, then pressed during the next card, opening the manager over the right card. |
| A misreading cannot toggle it repeatedly. | If two F presses in a row never produce an "open" reading, F is locked for 20 s and the log says so. |
| No opening F during cards or the end screen. | `UnitManagerBlocked()` checks `HasCardChoice()` and `IsEndGameBlocking()` before every open attempt. The only F during cards is the single closing press above. |
| If the game closes it, it is reopened once. | `MaintainUnitManager()` checks every 3 s in the watch loop and reopens through the same guarded `EnsureUnitManagerOpen()`. |
| Leftover manager before placement. | `EnsureRouteAndSpawn` closes it with one F, only after two readings confirm it is open (`CloseUnitManagerIfOpen`). Left open it hid the weather and Level Modifiers at match start. F is still never used to **open** the manager before the build is complete. |
| F never confirms a purchase. | The old fallback that opened F during placement and compared the bottom row's parity (`ManagerHoldsUnrecordedUnit`, which recorded ghost units) was removed. |

### Finding purchase #N (`LocateManagedUnit`)
1. Refuse while a placement purchase is unresolved, or while a card is up (reason `card`).
2. `EnsureUnitManagerOpen()`. If it fails, the reason is `manager`.
3. If the last tile found was this purchase and the list has not moved since (no scroll, no F), reuse it.
4. Otherwise scroll down until the list bottom stays still for two single-notch checks (`ResetUnitManagerBottom`).
5. Row/column of #N from the bottom (`ManagedUnitCell`). The game lists the **newest unit top-left**, reading left to right, so #1 is in the bottom row. Odd or even comes from the recorded unit count; the bottom row on screen must show the matching 1 or 2 tiles, otherwise nothing is clicked and the lookup is retried:
   - even unit count: #1 bottom-right, #2 bottom-left, #3 the row above on the right, and so on;
   - odd unit count: #1 **alone at the bottom-left**, then #2 right / #3 left in the row above, and so on.
6. Scroll up one notch at a time. If a notch moves a full row or more, it stops instead of guessing. If the list cannot move any further, the reason is `missing` (the manager shows fewer units than recorded).
7. Every failure records a reason in `gUnitManagerFailure`: `card`, `manager`, `mismatch` (the bottom row disagrees with the record), `scroll`, `missing`, `panel` or `blocked`. `mismatch`, `missing` and `scroll` are counted per purchase and audit cycle against `MANAGER_LOOKUP_LIMIT` (§5a).

Upgrades find a tile with `LocateManagedUnit` and click it from `UpgradeOnceAction` (the tile's Upg button, or only the portrait when the game needs the unit selected first). Nothing else selects units through the manager.

Each tile is read by vision (`unitmanager`): bright bar segments are done (green and yellow are the same); a dark body, with or without a white outline, is not done, whether the Upg button is the grey **Max** button, the Upg click point, and the portrait's colours.

---

## 4. Upgrades

- **Queue:** unfinished recorded units, lowest priority number first, ties by purchase number (`UpgradeQueue`). Each watch-loop pass works only on the head of the queue (`UpgradePriorityPass`). **Strict priority:** a lower priority is never upgraded while a higher one is unfinished, even while the head is paused.
- **Everything happens on the unit's manager tile** (`UpgradeOnceAction`). The side panel's UPG heading, OCR and R are no longer used.
- **When the tile cannot be found:**
  - `card` → choose the card (the manager is closed for it, then reopened), then find **the same** unit again. Nothing is deferred.
  - `manager` → retry the same priority. This is never counted against the unit.
  - `mismatch`, `missing`, `scroll` → the same retries as below, but at most **`MANAGER_LOOKUP_LIMIT` (6)** failed lookups per purchase per audit cycle. Then the build is audited (§5a); once `AUDIT_LIMIT_PER_MATCH` (2) audits are used up the unit is given up as **unreachable** (logged) and the units that are found go on.
  - `manager` (F will not open) → retry the same priority. `MANAGER_OPEN_FAIL_LIMIT` (30) failures in a row without a found tile never give the match up: upgrades pause for `UNIT_MANAGER_GIVEUP_COOLDOWN_MS` (30 s; logged, a timestamp check, so the watch loop keeps handling cards, the end screen and disconnects), then the same bounded attempts start again, and this repeats while the phase is Upgrading. No unit is marked unreachable for it.
  - Any other reason → retry the same unit up to **3** times, then pause it 2 s (see Pause).
- **Level:** the number of lit segments. A new lit segment confirms an upgrade. Fewer lit segments than already confirmed means the tile is doubtful: it is found again, and the lower count is accepted only after three reads in a row.
- **Not enough Yen:** vision reads the Upg button's brightness (`afford`: lit = can buy, dimmed = cannot). A dimmed button is waited on with no click and no failed read counted, even if the bar is unreadable.
- **Clicks (like holding R):** keep clicking the tile's Upg button until MAX or the target. When the button state is unknown, clicks that buy nothing are repeated with no failure counter. MAX target: every 0.3 s, even if the bar is unreadable. Finite target: after each click wait for the new segment, at most 2 s, so a slow bar cannot overshoot.
- **Second look (`StableTileRead`):** a level jump that no click explains, and any MAX, must read the same twice, 0.25 s apart. One more segment right after a click is accepted at once.
- **Identity guard:** the first tile seen for each slot teaches that slot's portrait colours. A tile is refused only when it is far from its own slot's colours and at most half as far from another slot's, so look-alike units never block upgrades.
- **Pause:** unreadable bars (3 reads), missing tiles (3 tries) or a portrait mismatch pause **the same unit** for 2 s, then it is read again; lower priorities wait (no back-off, no hand-over), but only within the bounds: `UPGRADE_DEFER_LIMIT` (40) deferrals without progress, or the lookup limit above, end the wait by giving the unit up as unreachable. An unreachable unit is not unfinished: the upgrade queue skips it, so it never holds lower priorities back. Logged on the first pause and about every 30 s. One diagnostic screenshot per unit per match goes to `cache\upg-tile-<id>.bmp`.
- **Sell X only:** Fishi's small red element icon once passed as a sell X, added a fake row, broke the row pitch and left every bar unreadable. Vision now keeps only sell-X-sized marks.
- **MAX = grey Max button and every segment lit** (or unreadable bar). A grey button over unlit segments (a manager still opening; this ended #7 at 5 of 8 and skipped unit 2) is never clicked and is believed only if it stays for 4 s.
- **Target reached or MAX:** mark complete, log the next unit. After the last target the manager is closed (§3).
- **Live target edits** in the GUI apply to already-placed units at once (`RefreshRecordedUpgradeTarget`).
- **Cards during upgrades:** the macro presses Q only if a placement preview is active, closes the manager once (only if it is confirmed open), closes the side unit panel with its X if it is showing, and chooses the card. Afterwards it reopens the manager and finds the top-priority unit's tile again before any click.
- **Side unit panel:** an Upg click on a tile opens it. It is closed (click-away) while the unit waits for Yen and when a target is reached, so it does not sit over the left card or the end screen.

---

## 5. Placement

- **Order:** slots in order, copies in order; the macro stays on a unit until it is placed (except Hill-only with no Hill space). Each copy is bound to its slot and copy number before the mouse-down (`PlacementPurchaseReady`).
- **Where:** the first edge unit goes beside the lit path, closest to the player. Units sit 12 px outside the road, and only an 8–18 px edge gap is accepted. Every point must be within 180 px of the player.
- **Pairs (`PlaceUnitAction`):** row 1 is the path edge; row 2 is one partner spot straight behind a row-1 unit. Partners come first: every edge unit whose partner spot is still open gets one try there (`TryPartnerPlacement`), newest first, before any new edge spot. A miss closes only that partner spot.
- **Front and behind:** `PlacementUpstreamDirection` measures where the enemies come from on the minimap route (from the player toward the far end from the base) and turns it into a screen direction with the measured W/D movement. `placementline` returns two lanes from ONE start, the free edge spot nearest the player, running both ways along the same side of the road: front (toward the enemies) and behind. From the end of a visible stretch the second walk would wrap around to the other side of the road, so it is dropped. `PlacementLaneOrder` tries the lane holding fewer edge units first (front on a tie) and then alternates. The far side of the road is used only when this side is used up, so edge + partner pairs never stack on both sides of the road in one place.
- **Without a direction** (no base or movement calibration): one lane beside the player, continued beside the newest edge unit (`StartLineAtNewestEdgeUnit`), onward along the edge and then back along it.
- **Edge blocking:** 3 misses on one edge block the whole stretch they walked (48 px either way of every miss, `RegisterPlacementEdgeMiss`); the next tries go to the opposite side or another edge.
- **Money:** on the path edge, the free spot farthest from all placed units (or from the player if first). Others keep 48 px from it (normal 24). Never an anchor; the line keeps growing from the last ordinary edge unit.
- **Hill-only / Hybrid:** Hill-only needs highlighted Hill terrain and never falls back to ground. Hybrid tries the green Hill highlights (nearest the path first), then ground. Hill units are never anchors.
- **Purchase confirmation (`PurchaseVerifier.ahk`):** the side unit panel is NOT proof of a purchase (it also opens on an already placed unit; it once recorded ghost units). `DecidePurchase(evidence)` is a pure function with this rule order: (1) **slot counter**: holding a unit shows `n/max` above its hotbar card (also when the slot is full); read before the click (while holding the unit) and after it, `n+1` is `confirmed`, `n` unchanged is `denied` (any other change is not trusted); (2) **Yen**: before and after, each a range from two reads that agree within a tolerance (`|a-b| <= max(YEN_READ_TOLERANCE_ABS (300), YEN_READ_TOLERANCE_FRACTION (5%) x the larger)`, because Yen keeps moving); `confirmed` when the highest Yen after is at least `PURCHASE_YEN_DROP_FRACTION` (0.5) x cost below the lowest Yen before, `denied` only when the lowest Yen after is not below the highest Yen before (no drop at all), anything in between is not decided here; (3) **unit panel (weak)**: `confirmed` only when no recorded unit lies within the `CandidateOccupied` radius of the click point (the panel is not even checked next to a recorded unit); (4) otherwise `unknown`. After the click the HUD is read once settled (`PURCHASE_SETTLE_MS`); if the counter cannot be read the unit is no longer held, so any remaining hold is dropped first (pressing the held slot key again would toggle the hold off), then the slot key is pressed once to read the counter and Q drops it again. `confirmed` goes to `RegisterPlacedUnit`, whose PlacedUnits log line names the evidence ("confirmed by slot counter 0/3 -> 1/3", "Yen ..." or "unit panel (no recorded unit nearby)"). `denied` is a failed purchase: the failure is counted and the spot blacklisted. `unknown` keeps the purchase pending and probes again up to `PURCHASE_REPROBE_LIMIT` (3) more times; if it is still unknown the attempt counts as a failure but the spot is NOT blacklisted, and its slot is marked: before the NEXT purchase of ANY slot that slot's counter is read (two agreeing reads) and the record fixed, so a unit that was really bought is recorded in purchase order. A purchase that is `confirmed` but cannot be recorded normally (a recorded unit already stands there) is recorded at once as a unit with no anchor position, with the panel and preview closed. Before EVERY purchase click, the held slot's counter is compared with the recorded count: a difference in either direction (or a full slot) is reconciled first (a second agreeing read is required; if the reads disagree no click is sent), so extra units are never bought on a stale record. The counter is OCR of the strip above the hotbar (`ReadPlacementMoney`, mapped to the slot by the same `HOTBAR_SLOT_X` the cost reader uses). Before buying, a selection-only click rejects spots that already hold a unit. Failed spots (28 px radius) are skipped for the rest of the game. Hill spots that failed in two matches in a row on the same map profile are skipped from the start of the next match; a success there clears the record.
- **Slot already full before the click:** if the counter read while holding the unit already shows `n = max`, nothing is clicked (it could only be refused). It is not a failure and blacklists no spot; the slot is reconciled with the counter instead (§5a). If the game's limit is below the configured count, the slot is held at that limit (`CapSlot`) and counts as complete.
- **Recovery:** a purchase hidden by cards is resolved from the same evidence (`RecoverPendingPlacement`) and never bought twice. It never clicks the field again: a click on the spot can select an existing unit.
- **Short of Yen (`PlacementShortOfYen`, `WaitForPlacementYen`):** checked BEFORE the click, while the unit is held (`ReadPurchaseState`: Yen needs two OCR reads that agree within the tolerance, the LOWER of the two is used, at most `PURCHASE_READ_ATTEMPTS`). One OCR pass reads the Yen counter above the toolbar, the held unit's counter and the cost under each of the six slot portraits (`ReadPlacementMoney`). If Yen is below the unit's cost, no click is sent, nothing counts toward relocation, the spot is not rejected and no edge is blocked; the held unit is dropped, the macro re-reads Yen about once a second (at most `YEN_WAIT_MS`, 20 s) and then places the same unit (checking again before it clicks). After `YEN_WAIT_ROUND_LIMIT` (30) such waits in a row for one copy it is given up (`CapSlot`, logged and sent to Discord). Costs are remembered by unit name in `learning.ini` (`[UnitCosts]`); a new value is believed only when two reads agree. Unreadable Yen or an unknown cost does not block the click: the counter decides afterwards. Each purchase costs about four OCR passes (two before the click, two after).
- **Relocation:** 6 consecutive failed purchases move the player to the next route checkpoint (25% → 50% → 75%). At checkpoint 3 it keeps trying locally.
- **Three-path map (Sky Island):** vision reports `paths=3` when crimson AND blue lines are on the minimap besides the green one. Each colour counts by the summed length of its line pieces (each 20+ px, total 60+ px at the reference minimap size), because the green and blue lines cut the crimson one into short pieces where they cross; enemy icons and the skull are smaller blobs; all three become one walkable route. The macro walks to the fixed spot `THREE_PATH_STAND` (20.26, 22.10 on the 96-grid), where the paths meet beside the base: along the lines, then straight for the last 6 cells to within 1.5 cells. Placement stays there (checkpoint index 3, no relocation).
- **Lit path colour:** lime, or on sand-tinted maps (Sand Village) pure yellow. Yellow is used when it outweighs lime; once a frame clearly shows a yellow path, the rest of the match uses yellow only (`worldreset` at match start), so green Hill highlights are never path there. Yellow below 74% of the height (the Weather Alert banner) is ignored.
- **P is switched ON** (`EnsurePathLight(context)`, `PathLight.ahk`): the lit path is placement's first path source and steers walking (`FollowLitPath`). P is toggled ONLY by clicking the toolbar P button at its saved coordinate; the P key does nothing in the game and is never pressed. On = the "P" glyph white and filled, off = dim grey; each click is verified by reading the glyph (`ReadPathGlyph`). It runs twice: at Vote Start (`"vote"`, from `EnsureRouteAndSpawn`) and at the start of Placing (`"placing"`, from `RunMacro`, before the first purchase). At `"placing"` the lit path is looked for FIRST, whatever the glyph says: a lit path that is detected means P is on and P is never clicked then. P is clicked only when the glyph reads off AND no lit path is detected. If the Vote Start click already moved the glyph (it registered) and the glyph still reads off but sits where that click left it, the Placing call does not click again (it would switch P back off).
  - Glyph off: click P, then poll the glyph (`PATH_GLYPH_POLLS` reads, `PATH_GLYPH_POLL_MS` apart). At most `PATH_CLICK_LIMIT` (3) clicks per call. A click that left the glyph unchanged did not register and is repeated; a click that changed the glyph by `PATH_TOGGLE_CHANGE` toggled it, so no further click is sent in that call (it could switch P off again). The click-miss crop is saved when P still looks off.
  - Glyph on: nothing, except at `"placing"` when this minimap variant is known to show a lit path and the world reader finds none: one off-on cycle (two clicks, each verified by the glyph), once per match.
  - Glyph unreadable: logged and the macro carries on; placement falls back to the red overlay. An unreadable or unconfirmed P never stops the macro.
  - Learned, not hardcoded: when a lit path is read successfully (`ReadLitPath`, also used by `RefreshPathView`) the current minimap variant gets `lit_path=1` in its `[minimap.<id>]` section of `learning.ini` (the same section as its saved drawing). On maps with no lit path nothing is ever recorded, P on draws nothing, and the red overlay fallback works with P left on.
  - `RefreshPathView` no longer toggles P itself; the old once-per-match re-click there (`gPathRelightTried`) was replaced by the Placing call.
- **Path source, lit P path first (`RefreshPathView`):** before placing (first unit, after a rescan or relocation) the macro reads the lit path with nothing held (vision `world`, after `pathviewclear` drops any earlier red view), so green Hill highlights never count. It is accepted once it covers at least 1% of the client (`LIT_PATH_MIN_FRACTION`; real lit paths measure 2.4-5%, maps without one 0). It still reads under Sandstorm, where the haze turns the red overlay orange (`path-world-sandstorm-p-on.png`).
- **Fallback, the red no-place overlay (vision `pathview`):** used only when no lit path shows. The overlay appears only while a unit is held. The macro selects the slot, moves the cursor onto the HUD, reads the overlay and cancels the hold. The road is the long red band of constant width; red that is wider (Hill ground) or thinner/shorter (health bars, unit rings) is not road. Every red area is also stored as no-place: lane spots, partner spots and click re-checks never land on red. Later unselected frames only refresh the baseline image and keep this view; `worldreset` clears it at match start. The first read of each game is saved as `cache\pathview-<date_time>.png` (road magenta, other red blue, player white; newest 10 kept).
- **Bounds in the build loop** (`PlaceConfiguredBuildAction`): `BUILD_COPY_ATTEMPT_LIMIT` (40) attempts at one copy, then the copy is given up (the slot is held at its count); `BUILD_RELOCATE_WAIT_LIMIT` (20 waits of 3 s) for a relocation that cannot start, then the current position is accepted as the checkpoint (`AcceptCurrentPlacementArea`); `HILL_RETRY_LIMIT` (12 waits of 10 s) for a Hill-only unit, then it is given up; `PATH_VISION_ERROR_LIMIT` (6) vision calls with no answer in a row while reading the path, then the match is sat out like an empty path; `CARD_RESUME_LIMIT` (5) card-interrupted resumptions per placement or upgrade call. Every give-up is logged. A slot given up (the game's limit below the configured count, 40 attempts at one copy, 12 Hill waits) counts as complete and logs one line, "Slot N (name): giving up after ...; continuing with M of K units.", which is also sent to Discord (`DiscordWarn`) when units are lost.
- **No path from either source:** after 3 reads in a row with neither a lit path nor a red road (`PATH_READ_ATTEMPTS`), the raw frame of the last red read is saved as `cache\pathfail-<date_time>.png` (newest 10 kept) and the match is sat out until its end screen (Replay follows), instead of retrying the same unit forever.
- **Hidden base heart** (the player spawns standing on it, e.g. Magic Town): the 25/50/75% points are the same three spots from either end of the route, so they are drawn from the route's two far ends (`MapRouteQuarters`) and the player walks toward the middle one. Each step re-reads the minimap; once the arrow has left the heart it is read whole, the checkpoints are numbered from it and the target switches to checkpoint 1 (`ResolveHiddenBase`). If the heart is still hidden on reaching the middle point, or when the prep timer runs out, the route end nearest where the player started is taken as the base.
- **Two-path maps:** when the minimap has a second (purple) path, the checkpoints are the points where it meets the green route (`MapCrossingCheckpoints`): the first crossing the enemies reach, then the next meeting points toward the base. Vision reports them (`scan` → `crossings`); they are saved with the learned minimap variant.
  - **Cards while walking:** every movement key is released *before* the card is chosen (`MovementHoldUntil`, `MovementCardPause`), so the player stands still during card selection. Afterwards the walk resumes toward the same checkpoint from the player's actual position, and card time does not count against the walk.
  - **20-second rule:** if relocation walking (card time excluded, added up across retries for the same checkpoint) passes 20 s without arriving, `TeleportBackToSpawn()` clicks the Settings gear (bottom left), then the arrow button on the row OCR confirms as "Teleport back to Spawn", then Settings' red X. It then re-finds the player and walks to the same checkpoint from spawn. "Return to Lobby" (the next row down) is never clicked. At most 2 teleports per checkpoint.
  - **Give-up rule:** after both teleports, another 20 s of failed walking ends the retries: the current position counts as that checkpoint and placement resumes there (previously it retried forever).
- **Speed:** the Level Modifiers OCR runs at most every 30 s during placement and never during upgrades (the F manager covers it); a missed unit panel only re-runs OCR layout learning until the panel has been recognised once (`gUnitPanelSeen`). Unit placement/selection holds, gaps and cursor travel are 150 ms (was 200 ms), and the pause after a confirmed placement is 100 ms (was 180 ms). The post-click settle (`PURCHASE_SETTLE_MS`) is unchanged in spirit, so purchases are still verified.
- **Same unit until placed:** a copy that is not placed yet is retried (0.3 s apart; 3 s while relocation is not possible) before any later unit, so the build order holds. The only exception is a Hill-only unit with no usable Hill space: it waits 10 s while later units are placed, then is tried again.
- **No upgrades during placement.** Upgrades need the F manager, and F is only allowed once every unit is placed, so the build loop no longer calls `UpgradePriorityPass`. Consequence: if a unit can never be placed (for example a Hill-only unit with no Hill space), upgrades do not start for that match.
- **Click-away after each confirmed placement** uses the same (497,168) point.

---

### 5a. Build audit (`BuildAudit.ahk`)
**Positions after a relocation:** the camera follows the player, so once `RelocatePlacementArea` has started moving, the screen positions of the units placed earlier are stale. Every recorded unit is then marked `viewPending`: it stays in the record and in the upgrade queue (upgrades find it in F by purchase number), but `PlacementAnchorKnown` is false for it, so `CandidateOccupied`, `EdgeAnchors`, the exclusion strings and the lane seeds skip it, and nothing ever shifts the old coordinates. `gPlacementProfile` is blanked at the same time, so learned-placement and Hill-miss writes pause for the rest of the match (the camera pose no longer matches the profile). Both are deliberate protection against using stale coordinates; the one thing still guarding against buying onto an existing unit in the new view is the pre-click counter and the Yen/counter confirmation.

The macro's record (`gPlacements`) can be wrong in both directions, so the game's own slot counters are used to correct it:
- **When:** when placement believes the build is complete (`VerifyCompletedBuild`, at most `BUILD_AUDIT_LIMIT` = 4 per match, then the record is accepted), and when the unit manager keeps disagreeing with the record (see below). Never before the phase becomes Upgrading.
- **What:** for each enabled slot with a count (`AuditBuild`): press its key, read the counter (`ProbeSlotCounter`, up to `AUDIT_COUNTER_ATTEMPTS` = 4 separate probes; the record changes only when TWO probes agree), cancel with Q, compare with `CountSlotPlacements(slot)`. The end screen aborts the audit at once (the run loop's end-screen handling takes over) and a card is chosen before any slot key is pressed.
  - recorded > counter: **ghosts**. The slot's NEWEST entries are removed down to the counter, each removal logged ("ghost #N"), the order of the remaining entries kept, purchase numbers renumbered (the manager lists units in purchase order) and anchor/partner links fixed. The ghost's spot is kept off the candidate list for this match only: the audit never writes a learned penalty to `learning.ini` (which entry is the ghost is only a guess).
  - recorded < counter: a purchase the macro **missed**. It is recorded as placed (the build does not buy it again) with no position (`anchorless`): `PlacementAnchorKnown` is false for it, so `CandidateOccupied`, `EdgeAnchors`, partner placement, vision exclusions and `MoneySpotScore` skip it. It joins the upgrade queue. It is appended last, so when it is found late its real place in the purchase order is unknown: a warning is logged and every unit recorded after that slot's last entry is flagged `orderUncertain`; for those, the unit manager tile must pass the portrait check (`TileIdentityMismatch`) before they are upgraded, and where the portrait cannot be used that is logged once.
  - A capped slot (the game's limit below the configured count) also needs two agreeing reads.
  - counter unreadable after the retries: the recorded count is trusted and logged.
  - Returns whether every slot reaches its target (configured count, or the cap) per the counters. Incomplete: placement stays in the Placing phase and keeps placing.
- **Manager mismatch escalation:** `mismatch`/`missing`/`scroll` lookups for one purchase (and portrait mismatches) are retried at most `MANAGER_LOOKUP_LIMIT` (6) times per audit cycle. Then the run loop calls `RepairBuildAfterManagerMismatch`: close F (confirmed, retried up to `REPAIR_CLOSE_ATTEMPTS`; if it will not close the audit is skipped and upgrades go on), with card handling on, `SetPhase("Placing")`, `AuditBuild`, place whatever is missing, `BeginUnitManagerPhase` and reopen F (the normal path back to Upgrading). At most `AUDIT_LIMIT_PER_MATCH` (2) per match. When that is used up, the unit that cannot be found is logged and skipped (`unreachable`); the units that are found keep their priority order.

## 6. Cards

### Detection
`HasCardChoice()` looks at the centre card only: two tall bright outlines at x≈314/488 and a dark interior. Hue is ignored, and the right-side "Level info" panel can never count as a card. Cards are checked during every wait, cursor move and pause (`CheckCardInterruption` inside `WaitFor`).

### Handling (`ClearCardChoice` → `TryChooseCard` → `ConfirmLockedCardSelection`)
1. Press Q only if a placement preview is active. During upgrades, close the F manager once (only if it is confirmed open). Then, if the side unit panel is detected, click **its own red X** (`CloseUnitPanelForCards`): the panel draws over the left card (its "769K" damage was read as card 1's text) and a click on empty world does not close it while the cards are up.
   After the card screen closes, the manager is reopened and the top-priority unit is reselected before any R.
2. **Pixel green check first** (`PixelGreenCards`). Each card's title and first effect lines are scanned for bright green glyphs (G>170, G−R>80, G−B>60) versus bright red. If exactly one card is green, it is chosen **immediately, before OCR**, because votes can end within seconds. On the supplied screenshot this gives Range: 173 green pixels against 0 and 0 on the two red cards.
   Card positions come from `cardboxes` (MinimapVision.py), measured once per card screen: the left and middle dark panels give the card width and spacing, and the right card is placed one spacing further, so the Level Modifiers panel touching it is never read as part of it. If detection fails three times, the fixed 800x600 layout is used.
3. Otherwise OCR reads word boxes, and each word's pixels give its colour (`ReadWordColourCards`). Shared reward lines ("+30% SummerPearls", secret portal) are ignored. A card whose OCR colour is unknown but whose pixels are clearly green still counts as green.
4. The choice is locked for this card screen. The same OCR read also covers the Level Modifiers panel to the right of the cards (`PanelRowsFromWords`), so the match totals cost no extra read. The card is clicked once and re-clicked after 1 s while the screen is still open, 14 px higher or lower each time. Re-clicks never re-run OCR (about a second each of a ~10 s vote); only a pixel check runs, and one clearly green card still takes over a non-green pick. The lock clears when the screen closes.

### Ranking (`ChooseBestCard`), in order of authority
1. **GREEN FIRST, above everything.** One green card is chosen outright. If two or three are green, only the green cards are compared. A red card never beats a green one, whatever its text says. Green Speed reductions are allowed.
2. **Buffs (green):** Double Attack → Attack/Cooldown/Range by **tier first** (Tier II of any of them beats Tier I of any; within a tier Attack → Cooldown → Range) → Random Blessings → any other green card (readable, e.g. green −Enemy Speed, or unreadable) → Yen → Boss Damage. A bigger amount breaks exact ties.
   - **Three unreadable cards of one colour** (all green or all red words): pick the **middle** card.
3. **Debuffs (red, only when nothing is green), judged on the total AFTER taking the card** (`DebuffOutlook`, `DebuffBetter`). The totals come from the Level Modifiers panel, read once per card screen while the cards are up (`ReadModifiersForCards`).
   1. Shield → Explosive Death (no limit).
   2. Health, if current + card ≤ **300%**.
   3. Resistance, if every type the card adds stays ≤ **150**.
   4. Regen (any amount), if the total stays ≤ **2%**.
   5. Health or resistance past its cap: the card that ends **least far past its own cap** (projected ÷ cap) wins; Health wins an exact tie.
   6. Regen past 2%, then any other readable red effect.
   7. An unreadable red card, but only after the OCR retries (fallback).
   8. Positive enemy Speed is never clicked. An all-Speed offer is left to the vote timer.
   - An unreadable amount assumes the worst case: Health +200%, resistance +100 per type, regen past the cap.
   - The ceilings are `CARD_HEALTH_CAP`, `CARD_RESIST_CAP` and `CARD_REGEN_CAP` at the top of `CardContext.ahk`.
   - Example (the reported loss): 230% Health, 100/100 resist; offer Health +200 / +50+50 resist / Regen +5. Health would reach 430% (past 300), resist 150/150 (within), regen 5% (past 2) → **resist**.
   - **Resistance cards compared with each other (same step above), Balanced team (the current setting):**
     **a shared physical + magical debuff (e.g. +50 Physical / +50 Magic) always beats a sole one (+75 or +100 Physical, +75 Magic, ...)**, whatever the amounts and even if one of its numbers was unreadable.
     Between two shared cards, or two sole cards: smaller total, then smaller single increase, then the lower projected match resistance.
   - Magic team / Physical team checkboxes (Cards tab): if one is ticked, it overrides the shared-first rule and the card that adds less of the stat that team must avoid wins.
4. **Secret portal/drop bonus:** with two ordinary debuffs available, the ordinary ones are preferred.
5. **Difficulty (Cards tab, saved in card_preferences.ini).** **Easy** = everything above, all match. **Medium** = Easy until **wave 30** (the "Wave N" label is read by OCR about every 15 s from the watch loop, `RefreshMatchWave`; a misread never lowers it). From wave 30 (`CardLateMedium`):
   - A **Tier II Shield or Explosive Death** beats every buff (Tier II = at least twice the Tier I amount: Shield 3, Explosive Death 6, Health 50%, physical + magical 50 each, single resist 75; size = amount ÷ Tier I amount). The pixel green shortcut is skipped so the red cards are read first, and a later pixel check never swaps such a choice for a green card.
   - Otherwise green cards first as before. Red against red (`DebuffBetterLate`): cards that stay **within their caps** first, and among them the **biggest** (same size: the Easy order); with every cap reached, a **shared physical + magical** card while both resistances are under 150, otherwise the **smallest** (the Easy rule). Regen only after every other red card; positive Speed never.
6. **Never chosen:** positive (red) enemy Speed. An all-Speed offer is left unclicked (the vote timer picks at random anyway). Unclear red/unknown text is re-read up to 3 times (1.5 s apart) before the fallback: any green card first, then the easiest readable non-Speed debuff, then an unreadable non-Speed card.

### Reported screenshot
"+ Enemy Health I" (red) / "+ Range I" (green) / "+ Resistant Enemies I" (red, +50 physical and +50 magic) → **Range** by the pixel check, with no OCR needed. If Range were absent: Health, then the shared resist card ahead of any sole resist card.

---

## 7. End of match, idle, reporting
- **End screen:** the green Next button triggers end handling. The macro clicks Next, clicks game space 5 times to dismiss rewards, then selects **Return to lobby** in Queue mode or **Replay** in Solo mode. After returning to the lobby, it tries to verify Play on screen for 60 seconds before clicking its saved position for the current window size and display scaling (`LOBBY_SAVED_PLAY_FALLBACK`). It then follows the usual walking flow (§7a). Replay waits up to 3 minutes for the next Vote Start. Placement, upgrades and idle clicks pause during these transitions.
- **Disconnects:** `gSessionArmed` is true from F6 until F7 (also if the run loop has ended by itself); `gRunning` only says the run loop is live. Every 3 s, while the session is armed, `CheckDisconnect` looks for a centered dark panel and uses OCR to confirm the Disconnected title and locate the Reconnect button. It never writes `gRunning`: the OCR read takes a keep-reading predicate (`ReadOcrRows`/`FindReconnectButton`, default `gRunning`) and `CheckDisconnect` passes `() => gSessionArmed`, so F7 still cuts the read short. It abandons the current action (`AbandonCurrentAction`, phase back to Idle) and clicks Reconnect (verified) at `RECONNECT_CLICK_CADENCE_MS` (1 s) while the button is visible (`ReconnectAndRestart`). During loading it keeps watching for Reconnect or the lobby Play button. When Play is confirmed, the restart takes the same steps as F6 (`PrepareRunStart`: Roblox sized, attached and focused, mode read) and then restarts from the lobby (`ResetMatchState`, phase Lobby). F7 cancels recovery. One call is capped at `RECONNECT_GIVE_UP_MS` (30 min): it then logs, warns Discord and returns with the session still armed (`gSessionArmed` untouched, `gReconnecting` cleared), so `CheckDisconnect` starts a new attempt on its next tick if the dialog is still there. The "always reconnect" rule holds without a tight endless loop inside one call. F6 while a reconnect is pending is refused with the log line "Reconnect in progress; F6 ignored. Press F7 to stop." (a run started over the dialog would act on it); F7 still cancels.
### 7a. Lobby start (`TryStartFromLobby`, `LobbyFlow.ahk`)
One loop with explicit stages and the same game steps as before: **play** (read the labelled Play button, click it with a verification that Play is still under the cursor) → **walk** (hold W until the matchmaking panel shows) → **panel** → **queue** (Find Match, number prompt, Submit; `StartQueueMatch`) or **portal** (Solo: Play Here, Open, Start).
- A Play click is verified before it is sent; a click whose effect is visible (the panel is open afterwards) is not repeated. Otherwise Play is read and clicked again, up to `LOBBY_PLAY_CLICK_LIMIT` (2) per round (the usual log shows "1/2" then "2/2" before the walk).
- Bounds, each with a log line naming the stage when it gives up: **find Play** one wait of `LOBBY_PLAY_WAIT_MS` (30 s; `LOBBY_PLAY_WAIT_AFTER_RETURN_MS` 60 s after a return to the lobby); **click Play** `LOBBY_PLAY_CLICK_FAIL_LIMIT` (3) clicks that could not be sent; **walk** `LOBBY_WALK_ROUND_LIMIT` (3) rounds of `LOBBY_WALK_MS` (7 s) + `LOBBY_WALK_GRACE_MS` (3 s); **queue** `LOBBY_QUEUE_RETRY_LIMIT` (4) Find Match/prompt attempts; **portal** `LOBBY_PORTAL_ATTEMPT_LIMIT` (3).
- A stage that gives up makes **one restart from the play stage** (counters reset, logged "Lobby: restarting from the Play stage (n/3)"), at most `LOBBY_RESTART_LIMIT` (3) times; after that `EndRun("lobby: <stage> gave up after 3 restart(s) from the Play stage.")` ends the run (the session stays armed). F7 returns false at once without a restart.
- The saved-LobbyPlay blind click (the label OCR sometimes fails) is kept behind `LOBBY_SAVED_PLAY_FALLBACK`: after a return to the lobby, when Play was not read in time, the saved point is clicked once per round and "Lobby: Play was not read within N s; using the saved Play position (fallback)." is logged.

- **Session logs:** every Activity line is also appended at once to `logs\session-<date>_<time>.log` (git-ignored), so nothing is lost if the macro is closed or killed without F7. Each F6 starts a new file (the file opened with the macro is reused for the first run); `=====` markers show F6, F7 and the macro closing, so a file without a final marker was cut short. Files not written to for 30 days are deleted when the macro opens (`SESSION_LOG_DAYS`, `PruneSessionLogs`; `SessionLogLine`, `SessionLogMarker`, `BeginSessionLog`, `EndSessionLog`).
- **Discord:** once per match, WIN/LOSS plus a screenshot: on the Next screen when its result is read, otherwise just before Replay is clicked (Next seen = defeat, Replay without Next = win, unless OCR reads the result there). The webhook is in `settings.ini`, which is not synced by git: save it on each device.
- **Idle keep-alive:** when every target is complete, the macro clicks the manager-safe click-away point every 5 minutes. It skips the click while cards, a unit panel or an end screen are up.
- **Match modifiers:** the right panel (Enemy Health %, Physical/Magic resistance, Regen %) is read during placement and once per card screen (the unit manager covers it otherwise). Only label-first rows ("Enemy Health: +430.0%") count, so card text can never be read as a total. Picked cards are added in between. It is never clicked.

---

## 8. Function reference

### AAPathMacro.ahk
| Function | What it does |
|---|---|
| `BuildGui`, `AddReadableEdit` | Build the macro window (units, cards, learning, Discord tabs, activity log). |
| `FindRoblox`, `GetClient`, `ToScreen`, `MoveRef`, `SmoothMoveTo` | Locate Roblox, its client rect, convert reference coordinates to screen, and move the cursor smoothly. |
| `ClickRef`, `ButtonPosition`, `ClickButton` | Click a reference point (with optional re-check after moving), or a learned/static named button. |
| `BeginInputAction`, `EndInputAction`, `ActionPause` | Input pacing (300 ms general, 150 ms unit actions), interruptible pauses that also poll for cards. |
| `ResizeRoblox`, `AttachRoblox`, `OnMacroWindowMove`, `RefreshStatus` | Window size and docking. |
| `RGB`, `IsUiGreen`, `IsUiRed`, `IsUiYellow`, `IsBubbleRed`, `IsMiniMapRouteGreen`, `IsMiniMapPlayerWhite`, `CountRef`, `FindUiGreenCentre` | Colour predicates and counting. |
| `GetMiniMapRoutePoints`, `FindNextRouteWaypoint`, `ArrowPose`, `MapDistance`, `HoldArrow`, `NavigateAlongRoute` | AHK fallback minimap reading and route following. |
| `CameraReset`, `InputPause`, `HoldCameraKey` | Overhead camera (hold I, tilt, hold O). |
| `EnsureRouteAndSpawn` | Match preparation. Never presses F (the manager state was cleared by `ResetMatchState`), then minimap, P, camera, player and checkpoints. |
| `HasVoteStart`, `HasLobbyPlay`, `IsLobbyCyan`, `HasMatchmakingPanel`, `HasOpenPortal`, `TryStartPortal`, `TryVoteStart`, `VoteStartClosed`, `RecoverVoteStart` | Lobby and vote flow; recovery when Vote Start times out. |
| `HasCardChoice`, `HasCardBorder` | Card screen detection. |
| `CheckCardInterruption` | Polled during waits. Pauses the current action, chooses the card, resumes the same unit/purchase. |
| `ClearCardChoice`, `ClearCardChoiceAction` | Card handling entry. Q if a preview is active, close the manager for the card, one click on the open spot (no panel detection), reopen the manager and reset the unit selection afterwards. |
| `ResetCardSelection`, `WaitForCardChoiceClosed` | Card lock reset and a 350 ms stable-closed check. |
| `TryChooseCard` | Pixel-green fast path, then OCR, ranking, retries and fallback. |
| `ConfirmLockedCardSelection` | Re-verify green priority, block Speed, click the card (left card at y=405 if the unit panel is showing). |
| `HasValue` | List contains. |
| `ReadUnitPlan` | Snapshot of the six slots. |
| `ResetIdleKeepAlive`, `IdleKeepAliveAllowed`, `IdleKeepAliveTick` | 5-minute keep-alive at the manager-safe point. |
| `NavigateForPlacement` | Navigation, then the timeout rule. |
| `RunMacro` | The match state machine (§2). Sets the phases Lobby, Preparing, Placing and Upgrading; calls `ResetMatchState` at Vote Start. Every exit goes through `EndRun(reason)` (logs the reason, phase Idle) or returns "replay"/"restart". |
| `PrepareRunStart` | The start steps F6 and the post-reconnect restart share: Roblox found, sized, attached, focused, mode read, `gRunning` on. |
| `StartMacro`, `StopMacro`, `RunMacroSafely`, `TestRoutePreparation`, `ReleaseMovementKeys` | Run control. `StartMacro` arms the session (`gSessionArmed`), `StopMacro` disarms it; stop and a run that ends by itself set the phase to Idle. |
| `CheckDisconnect`, `FindReconnectButton`, `ReconnectButtonVisible` | Disconnect detection, gated on `gSessionArmed` (see §7); the reconnect loop is in `LobbyFlow.ahk`. |
| `WaitFor`, `Notify`, `Log`, `RunSelfTests` | Utilities and the built-in tests. |

### LobbyFlow.ahk
| Function | What it does |
|---|---|
| `ReadVisibleLobbyPlay`, `LobbyPlayAt` | Read the labelled lobby Play button (OCR plus colour) and re-check it under the cursor. |
| `TryStartFromLobby` | The staged, bounded lobby start (§7a). Returns the submit time (Queue), true (Solo) or false. |
| `ClickSavedLobbyPlay` | The blind saved-position click behind `LOBBY_SAVED_PLAY_FALLBACK`. |
| `ReconnectAndRestart`, `ReconnectGiveUp` | Click Reconnect until lobby Play shows, then `PrepareRunStart`, `ResetMatchState`, phase Lobby, `RunMacroSafely`; the 30-minute cap per call (§7). |

### UnitManager.ahk
| Function | What it does |
|---|---|
| `BeginUnitManagerPhase` / `EndUnitManagerPhase` | Enter the Upgrading phase and reset the manager's state / reset it and enter Watching after the last upgrade target (F stays shut until a target is raised). |
| `ResetUnitManagerState`, `UnitManagerActive` | The module's per-match reset (called by `ResetMatchState`); true exactly while the phase is Upgrading. |
| `ReadUnitManager` | Vision `unitmanager`: open, ready, rows, pitch, bottom-row count, entries (portrait and Upg click points, lit/total segments, Max, portrait colours). |
| `FocusUnitManagerGame` | Focus Roblox before F or scrolling. |
| `PressUnitManagerKey` | One F tap. Takes `"open"` or `"close"`. Opening is refused unless `InPhase("Upgrading")`; closing is allowed in any phase. Records the press time. |
| `UnitManagerBlocked` | True while a card or end screen is showing. `fresh` re-reads the end screen first (used right before an opening F, because the end screen's XP panel covers the manager and reads as "closed"). Manager scrolling stops as soon as it is true. |
| `EnsureUnitManagerOpen` | Return the open manager. Press F once only after 3 closed reads, 2.5 s cooldown, 20 s lock after 2 unconfirmed presses. |
| `MaintainUnitManager` | Every 3 s in the watch loop, reopen the manager if the game closed it. |
| `CloseUnitManagerForCards` | The only close: F during card choice only when two readings agree the manager is open (two presses at most). Cards are read only after two "closed" readings. |
| `ReopenUnitManagerAfterCards` | After cards: reset the upgrade selection and reopen the manager, so the correct top-priority unit is reselected. |
| `UnitManagerFail` | Record why a selection failed. |
| `ScrollUnitManager`, `ResetUnitManagerBottom`, `ParseUnitManagerEntry`, `UnitManagerEntry` | Wheel scrolling over the list (drops the remembered tile), bottom anchoring, entry lookup. |
| `ManagedUnitCell` | Row and column of purchase #N for an even or odd unit count. |
| `LocateManagedUnit`, `ForgetManagerTile`, `ResetManagerTileMemory` | Find a purchase's tile (reusing the last position while the list is still), and reset that memory. |
| `ClickManagerPoint` | Click a manager point. |

### PlacedUnits.ahk
| Function | What it does |
|---|---|
| `BeginPlacementRun` | Start of the placement phase: validation cache and selection reset. |
| `PlacementLayoutKey`, `SaveLayoutPoint`, `CachedPlacementCandidates` | Per-map saved positions, reused only when the local path view validates. |
| `RegisterPlacedUnit` | Record purchase #N (slot, priority, target, position) and log what confirmed it. |
| `UpgradeQueue`, `UpgradePriorityPass` | Priority order and one pass on the head. |
| `ResetUpgradeSelection`, `ResetUpgradeTracking`, `RefreshRecordedUpgradeTarget` | Selection and remembered tile, per-unit click tracking, live target edits. |
| `SaveUpgradeDiagnostic` | Saves the client area to `cache\upg-tile-<id>.bmp`, once per unit per match. |
| `DeferUnitUpgrade` | 2 s pause of a stuck unit, which stays at the head of the queue (strict priority). |
| `PortraitDistance`, `SlotDisplayName`, `TileIdentityMismatch` | Portrait-colour identity guard. |
| `ClickTileUpgrade` | Upg click on the tile. |
| `StableTileRead` | Same reading twice, 0.25 s apart, before an unexplained level jump or a MAX is believed. |
| `UpgradeOnce`, `UpgradeOnceAction`, `UpgradeWarning` | Upgrade one unit from its tile, with the rules from §4. |

### Placement.ahk
| Function | What it does |
|---|---|
| `ResetPlacementSearch`, `RefreshPlacementSearch`, `FindPlacementCandidates`, `StartLineAtNewestEdgeUnit`, `PlacementSearchExclusions`, `UsablePlacementPoint`, `PlacementSearchDiagnostic` | Candidate search along the lit path edge. |
| `EdgeAnchors`, `NewestEdgeAnchor`, `PartnerOpen`, `FindPartnerCandidate`, `TryPartnerPlacement` | Edge/partner pairs. |
| `MoneySpotScore`, `PlaceMoneyUnit` | Money units. |
| `PlacementTerrain`, `FailedPlacementSpot`, `RememberFailedPlacementSpot` | Per-game rejected spots (28 px radius). |
| `RememberHillOutcome`, `ReadHillMisses`, `LoadRememberedHillMisses` | Hill spots per map profile (`hillmiss` in learning.ini): skipped from the start of later matches after failed purchases in two matches in a row; a success there clears it. |
| `PlacementClickRef`, `PlacementPurchaseReady` | Guarded click: no click if a card, panel or end screen appears. Binds the purchase. |
| `SelectPlacementUnit`, `CancelUnitPreview` | Slot key and Q (only when a preview is active). |
| `HasUnitPanel`, `UnitPanelRegion`, `UnitPanelColourHits`, `WaitForUnitPanel` | Side unit panel detection (learns its layout per window size). |
| `ClickAwayFromUnitPanel`, `CloseUnitPanel` | Close the side panel at (497,168). **Never touches F or the manager.** |
| `PlacementPanelClosedStable`, `CountSlotPlacements` | Helpers. |
| `FinishPlacement`, `TryPlacementCandidate`, `TryPlacementCandidateAction`, `TrySelectUnitAt`, `RecoverPendingPlacement` | Purchase, confirmation and recovery without double buying. `TryPlacementCandidateAction` reads counter and Yen before the click; `RecoverPendingPlacement` probes and acts on the verdict; `FinishPlacement(unit,point,evidence)` records a confirmed purchase. |
| `NewPurchaseEvidence`, `JudgePurchase`, `DecidePurchase`, `ParseCounterWords`, `SlotCounterFromWords`, `AgreedCounter`, `ReadHotbarPass`, `ReadPurchaseState`, `ProbePurchase` (PurchaseVerifier.ahk) | The verdict (`JudgePurchase` also returns the reason), counter parsing and slot mapping, bounded OCR reads (two agreeing Yen reads), and the post-click probe. They never press F. |
| `PlacementStillBesidePath`, `AddPlacementGeometry`, `OppositePlacementPoint`, `PlacementEdgeNormal`, `SamePlacementEdge`, `BlockedPlacementEdge`, `PlacementBlockedEdgeExclusions`, `RegisterPlacementEdgeMiss` | Edge geometry, opposite-side switch after 3 misses. |
| `TryPlacementPoints`, `MatchSavedPlacementsToPath`, `FindHillPlacementCandidates` | Try lists of points, saved points, Hill spots. |
| `PlaceUnit`, `PlaceUnitAction` | One copy of one slot (no F). |
| `ReadPlacementMoney`, `DigitsValue`, `UnitPlacementCost`, `PlacementShortOfYen`, `WaitForPlacementYen` | Yen counter, held-unit counter words and slot costs from one OCR pass; a Yen-short unit is held back before the click and is not a failure. |
| `PlaceConfiguredBuild`, `PlaceConfiguredBuildAction`, `MissingBuildPlacements` | The whole build loop (no upgrades until complete). |

### BuildAudit.ahk
| Function | What it does |
|---|---|
| `MarkSlotForReconcile`, `ReconcilePendingSlots`, `ManagerLookupLimit` | Slots whose last purchase ended unknown are settled against their counter before the next purchase of any slot; the per-purchase lookup limit (lower once the audits are used up). |
| `ConfirmHeldCounter`, `YenReadsAgree` (PurchaseVerifier.ahk) | A second agreeing counter read of the held unit; the Yen tolerance test. |
| `AuditBuild`, `AuditReadCounter`, `ReconcileSlot`, `RemoveNewestSlotEntries`, `RenumberPlacements`, `AddMissedPurchases` | The audit and its repairs (§5a). |
| `VerifyCompletedBuild` | The bounded audit run at build completion. |
| `SlotTargetCount`, `CapSlot`, `SlotCounterFull` | A slot's target (configured count or cap); the full-slot test used before a click. |
| `NoteManagerLookupMiss`, `EscalateManagerLookup`, `MarkUnitUnreachable`, `ManagerAuditDue`, `NoteManagerOpenFailure`, `ManagerCooldownActive`, `NoteManagerTileFound` | Lookup limits and the request/give-up decision. |
| `RepairBuildAfterManagerMismatch` | Close F, Placing, audit, place, back to Upgrading. |
| `ResetBuildAudit` | Per-match reset (called by `ResetMatchState`). |

### PlacementArea.ahk
| Function | What it does |
|---|---|
| `ResetPlacementArea`, `PlacementFailureLimitReached`, `ResetPlacementFailureStreak`, `RecordFailedPlacement`, `PlacementCopyFailures` | Six-consecutive-failure streak. |
| `PlacementAnchorKnown`, `ContinuePlacementInCurrentView` | Whether a recorded unit has a usable screen position (false after a view move or for an anchorless audit copy); continue placing when relocation cannot start. |
| `RelocatePlacementArea`, `AcceptCurrentPlacementArea`, `RetryFinalCheckpointPlacement` | Move to the next checkpoint (20 s walking rule, then teleport and resume). Keep trying locally at checkpoint 3. |
| `TeleportBackToSpawn`, `CloseSettingsAfterTeleport` | Settings gear → OCR-confirmed "Teleport back to Spawn" arrow → close Settings with its red X. |

### Learning.ahk
| Function | What it does |
|---|---|
| `BuildLearningTab`, `MemoryRead`, `MemoryKey`, `WindowGeometry` | Learned-data storage per window size and DPI. |
| `ButtonSection`, `SaveButtonRecord`, `ReadButtonRecord`, `ForgetButton`, `LearnHoveredButton`, `ButtonLabels`, `ButtonRegion`, `DiscoverButton`, `FindCompactRedControl`, `ClickWindowOnce`, `ClickLearnedButton`, `ObserveTextButtons`, `HasSavedColourControl` | Learn and click named buttons (OCR plus F10 teaching). |
| `SaveFrameBmp`, `ReadOcrRows`, `ParseOcrRows`, `NormalizeWords` | OCR plumbing. |
| `HasSecretPortalReward`, `StripSecretPortalReward`, `BuffTitleStat`, `BuffTitleTier`, `EnemyStatReduction` | Card text parsing. |
| `ReadResistanceAmounts`, `ParseResistanceEffects`, `CombineResistanceLines`, `CardIsResistance` | Physical/magic amounts. |
| `ResistanceIsShared` | **New:** a card adds both physical and magic resist. |
| `ResistancePreferred` | Resistance tie-break: **shared first (Balanced)**, then team preference / total / peak / match totals. |
| `CardPolicy`, `CardPolicyFromLines`, `CardRank` | Card stat, kind, amount, tier, rank. Base debuff label order: shield, explosive death, health, **physical+magical**, physical, magical, 0.5 regen, speed (red cards are actually ranked by `DebuffOutlook`). |
| `CardIsRegen`, `DebuffOutlook`, `DebuffBetter`, `CardBetter` | Red-card ranking on projected totals against the Health 300% / resist 150 / regen 2% caps (§6). |
| `CardHasGreenEffect`, `CardSelectionView`, `CardIsSpeed`, `CardPreferenceScore`, `ChooseBestCard`, `PreferVerifiedGreenChoice`, `FallbackCardChoice` | Ranking and safety (§6). |
| `WhiteBits`, `HashText`, `CardRectangle`, `CardVisual`, `ReadCardMemory`, `RememberCard`, `TeachCurrentCard`, `BitOverlap` | Visual card memory (fallback only). |
| `PlacementContextMatches`, `PreparePlacementMemory`, `PlacementSection`, `ReadPlacementRecords`, `WritePlacementRecords`, `CandidateOccupied`, `KnownPlacementCandidates`, `RememberPlacement` | Placement memory per map/camera profile;  |

### CardContext.ahk
| Function | What it does |
|---|---|
| `BuildCardPreferencesTab`, `CardDamagePreferenceChanged` | Balanced / Magic team / Physical team (`card_preferences.ini`). |
| `ResetMatchCardContext`, `SignedHealthChange`, `ParseMatchModifiers`, `RefreshMatchModifiers`, `ApplySelectedCardModifiers` | Read-only match modifiers. |
| `CardHasForbiddenSpeed` | Positive enemy Speed detection. |
| `RefreshCardBoxes`, `DetectedCardSpans` | Card interiors measured once per card screen (vision `cardboxes`); fixed layout if not found. |
| `CardEffectBounds`, `EffectWordInk`, `CardWordRows`, `SharedNumericCardLine`, `ReadWordColourCards` | Per-word green/red colour, with the pixel fallback for unknown colour. |
| `CardPixelInk`, `CardPixelIsGreen`, `CardPixelIsRed`, `PixelGreenCards`, `PixelInkCards` | **New:** OCR-free green detection and the immediate green pick. |
| `LogCardDecision` | Decision log. |

### PathLight.ahk
| Function | What it does |
|---|---|
| `EnsurePathLight` | The P button at Vote Start (`"vote"`) and the start of Placing (`"placing"`). |
| `PathLightAction` | The pure decision: glyph (on/off/unreadable) x context x variant known lit x lit path seen x cycle used, giving click, cycle, none or unreadable. |
| `PathButtonTarget`, `ReadPathGlyph`, `ClickPathButton`, `ClickUntilGlyph` | The saved P coordinate, one glyph read, one click, clicks verified by the glyph (bounded by `PATH_CLICK_LIMIT`). |
| `ReadLitPath`, `VariantShowsLitPath`, `RecordLitPathSeen` | The world reader's lit path; the learned per-variant flag in `learning.ini`. |
| `PathToggleStillHeld` | True when an earlier click this match moved the glyph without it reading on and it still sits there (no second click at Placing). |
| `PathLightOn`, `ResetPathLight` | True when the glyph read lit at the last call; the per-match reset (called by `ResetMatchState`). |

### MapNavigation.ahk
Minimap capture and graph (`MiniMapBounds`, `CaptureMiniMap`, `MapNeighbours`, `MapComponents`, `MapGreenMask`, `MapBits`, `MapFromBits`, `MapBridgeFragments`, `MapGapOccluded`, `MapThin`, `MapWhiteComponents`, `MapMarkers`, `MapNearest`, `MapDistances`, `MapShortestPath`), checkpoints (`MapPlacementCheckpoints`, `MapFarthestNode`, `MapRouteQuarters`, `ResolveHiddenBase`, `MapRecommendedTarget`), map variants (`ReadMapModel`, `BuildMapModel`, `ArchiveMapModel`, `OccludedShapeMatch`), the timed preparation (`PrepTimeLeft`, `BeginTimedPreparation`, `FinishNavigationTimeout`), movement (`NavigateDrawing` (vision maps never fall back to the camera-turning `NavigateByHeading`), `NavigateByHeading`, `MapLineFollowsRoute`, `ProbePlayer`, `ProbeKeyPair`, `MoveVectorsAgree`, `MoveAxesValid` (D must be W turned a quarter clockwise at a similar speed; saved or fresh readings that fail are deleted/rebuilt, never saved), `RestoreMoveKeys` (a failed re-probe keeps the last good keys), `MoveDurations`, `MovePrediction`, `HoldKeys`, `NavigateWithKeys`, `LearnMoveKey`, `RouteProgress`), obstacles (`EscapeSteps`, `EscapeObstacle`: jump, then step around up to 18 cells, 7 attempts), cards while walking (`MovementHoldUntil`, `MovementCardPause`, `MovementPause`, `TakeMovementCardMs`: keys up before the card, then resume from the actual position), the Python service (`VisionRequest`, `VisionOk`, `VisionClose`, `VisionSync`, `VisionMapModel`, `VisionModelFromScan`, `VisionSetPlayer`, `VisionRefreshPlayer`, `RefreshMapPlayer`, `WorldRequest`), and the lit path (`FollowLitPath`, `AimPresses`, `BesidePathCandidates`, `OnLitPath`; the P button itself is in `PathLight.ahk`).

### Endgame.ahk
`ResetEndGameFlow`, `EndEmptyScreen`, `EndScreenColours`, `ParseEndScreenRows`, `ReadEndScreen` (300 ms cache), `IsEndGameBlocking`, `HasDefeatNext`, `HasReplayButton`, `EndGameButtonStillVisible`, `ClickEndGameButton`, `ReadEndOutcome`, `EndRewardClickAllowed`, `DismissEndRewards`, `TryEndState`, `WaitForReplayVoteStart`.

### Discord.ahk / UnitSettings.ahk
`BuildDiscordTab`, `IsWebhookUrl`, `SaveWebhook`, `TestWebhook`, `PostToWebhook`, `ReportMatchResult`, `DiscordWarn` · `SavedUnitNumber`, `LoadUnitSettings`, `QueueUnitSettingsSave`, `SaveUnitSettings`, `FlushUnitSettings`, `UnitPlacementModeChanged`.

### MinimapVision.py (commands)
`scan/locate/track/moved` (minimap and player), `toolbar/toolbarfixed` (P state), `world/follow/beside/onpath` (lit path), `placementline/placementneighbours/placementvalid/validateplacements` (placement geometry), `hillspots`, `relocation`, `rememberview/viewshift`, **`cardboxes`** (card interiors from the dark card panels), **`unitmanager`** (heading "Unit Overview", Sell-X anchored rows, portrait click points), `debug/worlddebug`, `discord`.

---

## 9. Tests
- `CheckpointManagerTests.py`: manager selection (test-local `SelectManagedUnit` driver over `LocateManagedUnit`) through 20/19/1-unit layouts. Exactly **one F for the whole match**, **no F before placement**, one F to reopen a closed manager, and the misread guard (2 presses at most).
- `UpgradeRegressionTests.py`: finite targets and input guards. A missed selection is retried at the same priority before deferral, and no upgrades/F happen before the build is complete.
- `LearningTests.ahk` (`--self-test`): card policy. Shared resist beats sole 100/75/25, the reported screenshot picks green Range, pixel-only green is found in each position, the reported loss (230% Health, Health +200 offered) now takes resist, the 300/150/2% caps, and Level Modifiers parsing that ignores card wording.
- `CardPhaseTests.py`: F opens only in Upgrading and closes in any phase; cards per phase (Placing: no F, leftover manager only closed; Upgrading: close then reopen, unit reselected; Watching: no F); the card timeout logs and returns without ending the run; `RunMacro` has no bare `return` and no `if !ClearCardChoice() return`.
- `PurchaseVerifierTests.py`: the `DecidePurchase` table (every rule branch, the half-cost Yen edge, precedence, reasons), counter parsing and slot mapping, the weak panel refused next to a recorded unit, and recovery: confirmed registers with its evidence, denied blacklists, unknown re-probes 1+3 times then fails without blacklisting.
- `BuildAuditTests.py`: ghosts removed newest first with order kept, renumbering and links; a missed purchase is anchorless and skipped by the anchor-dependent code; unreadable counters bounded then trusted; caps; the bounded completion audit; escalation limits; the repair goes close F, Placing, audit, place, Upgrading. `UpgradeRegressionTests.py` also covers the lookup limit, audit exhaustion (lower priorities proceed) and the bounded build loop.
- `PathLightTests.py`: the P decision matrix (glyph on/off/unreadable x variant known lit yes/no x lit path seen yes/no, both contexts) as a pure table and end to end, the learned `lit_path` flag, the once-per-match off-on cycle, click bounds, and a check that no `.ahk` file sends the P key. `UpgradeRegressionTests.py` also keeps the P click tests (toolbar mock with glyph levels and ignored clicks).
- `PlacementConfirmationTests.py`: purchases confirmed by the slot counter alone (also with the hold dropped, or no side panel), old models and card overlays never count, Yen checked before the click.
- `MatchStateTests.py`: `SetPhase`/`InPhase` transitions (including Watching) and invalid-phase rejection, `EndRun` logs its reason and goes Idle, `ResetMatchState` calls every module reset once; `CheckDisconnect` with `gRunning` false and `gSessionArmed` true reads the dialog and never sets `gRunning`, and does nothing after F7.
- `LobbyFlowTests.py`: every lobby stage's bound leads to a restart and then `EndRun` (find Play, click Play, walk, queue, portal), a Play click whose effect is visible is not repeated, the saved-Play fallback only behind its constant, F7 never restarts; Reconnect: bounded click cadence, the 30-minute cap returns with `gSessionArmed` still true and a Discord warning, the restart goes `PrepareRunStart` then `ResetMatchState` then phase Lobby.
- `BuildAuditTests.py` also covers the F cooldown (limit starts it, no unit given up, it repeats, the check never blocks), the slot give-up log line and Discord warning, and the ghost penalty in the learning data.
- `CardPriorityTests.py`, `UnitManagerVisionTests.py`, and the existing placement/vision tests.
- The AHK tests need `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

Previous versions of every changed file are in `cache/before-manager-stays-open/`.

# AA Path Macro: what it does, every function, every decision

This describes the macro as it currently stands (after the "unit manager stays open" change).
Coordinates are in the 800 x 600 **reference** space unless stated otherwise; they are scaled
to the live Roblox client area at run time. Roblox is sized to 1401 x 975 outer pixels on Start.

---

## 1. Files

| File | Role |
|---|---|
| `AAPathMacro.ahk` | Entry point, GUI, hotkeys, input primitives, colour helpers, card detection/choice, lobby/vote flow, the match state machine (`RunMacro`), idle keep-alive, self-tests. |
| `UnitSettings.ahk` | Six unit slots (enabled, name, count, priority, target, Hill only / Hybrid / Money, mutually exclusive) saved to `unit_settings.ini`. |
| `MapNavigation.ahk` | Minimap reading (Python vision or AHK fallback), route graph, checkpoints, player probing, movement, obstacle escape, P (path light) toggle. |
| `Placement.ahk` | Placement candidates, purchase clicks, unit-panel detection, click-away, pending-purchase recovery, the build loop. |
| `PlacementArea.ahk` | Six-failure streak, checkpoint relocation (25% → 50% → 75% of the route). |
| `PlacedUnits.ahk` | Numbered purchase record, upgrade queue, tile-based upgrades (segments, Max, Upg clicks), identity guard, back-off. |
| `UnitManager.ahk` | F unit manager: when F may be pressed, keeping it open, scrolling, finding purchase #N's tile (odd/even layout). |
| `Learning.ahk` | OCR, learned buttons, card text policy and ranking, placement memory. |
| `CardContext.ahk` | Card word colour (green/red) reading, pixel green detection, resistance preference tab, right-panel match modifiers. |
| `Endgame.ahk` | End screen detection, Next/reward dismissal, Replay. |
| `Discord.ahk` | Optional WIN/LOSS webhook with screenshot. |
| `MinimapVision.py` | OpenCV service (minimap, lit path, placement lines, Hill spots, unit manager tiles: segments, Max, Upg point, portrait colours). AHK sends all input. |
| `OCRBridge.ps1` | Windows OCR bridge used by `ReadOcrRows`. |
| `*.ini` | `unit_settings.ini`, `card_preferences.ini`, `settings.ini` (webhook), `button_positions.ini`, `learning.ini` (learned data), `placement_run.ini`, `placement_layouts.ini`. |

Hotkeys: **F6** start, **F7** stop (releases every key), **F8** overhead camera reset, **F9** route test (no voting/buying), **F10** teach the button under the cursor.

---

## 2. One match, start to finish

```
F6 → StartMacro → RunMacro (loops on "replay")
  ├─ EndUnitManagerPhase            F is forbidden from here until the build is placed
  ├─ Lobby: Play → hold W → Play Here → Open → Start   (TryStartFromLobby)
  ├─ Wait for Vote Start (45 s)
  ├─ EnsureRouteAndSpawn            minimap → P lit → overhead camera → find player → 3 checkpoints
  ├─ NavigateForPlacement           walk to checkpoint 1 (50 s prep budget)
  ├─ TryVoteStart                   click the green Yes
  ├─ PlaceConfiguredBuild           every enabled slot × count, cards handled throughout, NO upgrades, NO F
  ├─ BeginUnitManagerPhase + EnsureUnitManagerOpen      ← the FIRST time F can be pressed
  └─ Watch loop until the match ends:
        cards → ClearCardChoice
        end screen → TryEndState (Next, rewards, Replay) → return "replay"
        RefreshMatchModifiers, MaintainUnitManager, UpgradePriorityPass, IdleKeepAliveTick
```

### Decisions in the flow
- If a match is already running (route on the minimap, no Vote Start), the macro refuses to build into it.
- An end screen visible at start is handled first (Replay).
- Navigation timeout is not a failure: placement starts from where the player is.
- If Vote Start is still showing after the click, the macro stops before buying anything.
- A build that is not complete never reaches the upgrade phase (see §5).

---

## 3. The F unit manager (rules)

| Rule | How it is enforced |
|---|---|
| F is pressed **only after every configured unit is placed**. | `gUnitManagerPhase` is false until `RunMacro` calls `BeginUnitManagerPhase()` after `PlaceConfiguredBuild` returns `complete`. `PressUnitManagerKey()` refuses to send F while the phase is off. Placement, relocation and route preparation no longer touch F at all. |
| Once open, it **stays open until the match ends**, except during card choice. | Unit switching, finished targets, deferred units and idle clicks never close it (`EnsureUnitManagerClosed` was removed). **Cards are the only exception:** `CloseUnitManagerForCards()` presses F only if two readings agree the manager is open (at most twice), and the cards are read only after two readings in a row confirm it is **closed**. The open manager covers the right-hand card. When the card screen is gone, `ReopenUnitManagerAfterCards()` reopens it through the guarded `EnsureUnitManagerOpen()` and resets the upgrade selection, so the top-priority unit is reselected through the manager before any R. |
| Click-aways never hit the manager. | The click-away point moved from (740,150), which is on top of the open manager, to **(497,168)**: empty world between "Return to lobby" and the manager's left edge, above the cards and right of the side unit panel. It is `CLICK_AWAY_X/Y` in `AAPathMacro.ahk`. |
| F is never sent on a guess. | `EnsureUnitManagerOpen()` presses F only after **3 consecutive "closed" readings**. Failed or unreadable frames reset the count. F is not repeated within **2.5 s** of the last press, so it cannot fire again while the manager is still animating open. |
| "Open" means the real manager. | Vision (`unit_manager`) only accepts the yellow "Unit Overview" heading when it is a thin text line on the manager's dark panel. Bright yellow scenery in that corner (Sand Village's path) once read as "open": F was skipped after placement and after cards, then pressed during the next card, opening the manager over the right card. |
| A misreading cannot toggle it repeatedly. | If two F presses in a row never produce an "open" reading, F is locked for 20 s and the log says so. |
| No opening F during cards or the end screen. | `UnitManagerBlocked()` checks `HasCardChoice()` and `IsEndGameBlocking()` before every open attempt. The only F during cards is the single closing press above. |
| If the game closes it, it is reopened once. | `MaintainUnitManager()` checks every 3 s in the watch loop and reopens through the same guarded `EnsureUnitManagerOpen()`. |
| Leftover manager before placement. | `EnsureRouteAndSpawn` only logs it. It does not press F (placement-phase rule). |

### Finding purchase #N (`LocateManagedUnit`)
1. Refuse while a placement purchase is unresolved, or while a card is up (reason `card`).
2. `EnsureUnitManagerOpen()`. If it fails, the reason is `manager`.
3. If the last tile found was this purchase and the list has not moved since (no scroll, no F), reuse it.
4. Otherwise scroll down until the list bottom stays still for two single-notch checks (`ResetUnitManagerBottom`).
5. Row/column of #N from the bottom (`ManagedUnitCell`). The game lists the **newest unit top-left**, reading left to right, so #1 is in the bottom row. Odd or even comes from the recorded unit count; the bottom row on screen must show the matching 1 or 2 tiles, otherwise nothing is clicked and the lookup is retried:
   - even unit count: #1 bottom-right, #2 bottom-left, #3 the row above on the right, and so on;
   - odd unit count: #1 **alone at the bottom-left**, then #2 right / #3 left in the row above, and so on.
6. Scroll up one notch at a time. If a notch moves a full row or more, it stops instead of guessing. If the list cannot move any further, the reason is `missing` (the manager shows fewer units than recorded).
7. Every failure records a reason in `gUnitManagerFailure`: `card`, `manager`, `scroll`, `missing`, `panel` or `blocked`.

`SelectManagedUnit` (relocation checks, and upgrades when the game needs the unit selected) closes the previous side panel, finds the tile as above and clicks **only the portrait**, then waits for the side unit panel.

Each tile is read by vision (`unitmanager`): bright bar segments are done (green and yellow are the same); a dark body, with or without a white outline, is not done, whether the Upg button is the grey **Max** button, the Upg click point, and the portrait's colours.

---

## 4. Upgrades

- **Queue:** unfinished recorded units, lowest priority number first, ties by purchase number (`UpgradeQueue`). Each watch-loop pass works only on the head of the queue (`UpgradePriorityPass`).
- **Everything happens on the unit's manager tile** (`UpgradeOnceAction`). The side panel's UPG heading, OCR and R are no longer used.
- **When the tile cannot be found:**
  - `card` → choose the card (the manager is closed for it, then reopened), then find **the same** unit again. Nothing is deferred.
  - `manager` → retry the same priority. This is never counted against the unit.
  - Any other reason → retry the same unit up to **3** times, then defer it.
- **Level:** the number of lit segments. A new lit segment confirms an upgrade. Fewer lit segments than already confirmed means the tile is doubtful: it is found again, and the lower count is accepted only after three reads in a row.
- **Clicks (like holding R):** keep clicking the tile's Upg button until MAX or the target. No failure counter, no warnings, no deferral for clicks that buy nothing (not enough Yen). MAX target: every 0.3 s, even if the bar is unreadable. Finite target: after each click wait for the new segment, at most 2 s, so a slow bar cannot overshoot.
- **Second look (`StableTileRead`):** a level jump that no click explains, and any MAX, must read the same twice, 0.25 s apart. One more segment right after a click is accepted at once.
- **Identity guard:** the first tile seen for each slot teaches that slot's portrait colours. A tile is refused only when it is far from its own slot's colours and at most half as far from another slot's, so look-alike units never block upgrades.
- **Deferral:** unreadable bars (3 reads), missing tiles (3 tries) or a portrait mismatch defer only that unit for 10, 20, 40, then 60 s; other units continue. Any confirmed upgrade resets the back-off. One diagnostic screenshot per unit per match goes to `cache\upg-tile-<id>.bmp`.
- **MAX = grey Max button and every segment lit** (or unreadable bar). A grey button over unlit segments (a manager still opening; this ended #7 at 5 of 8 and skipped unit 2) is never clicked and is believed only if it stays for 4 s.
- **Target reached or MAX:** mark complete (the manager stays open), log the next unit.
- **Live target edits** in the GUI apply to already-placed units at once (`RefreshRecordedUpgradeTarget`).
- **Cards during upgrades:** the macro presses Q only if a placement preview is active, closes the manager once (if it is confirmed open), and chooses the card. Afterwards it reopens the manager and finds the top-priority unit's tile again before any click (the remembered tile position is dropped whenever F is pressed or the list scrolls).

---

## 5. Placement

- **Order:** slots in order, copies in order; the macro stays on a unit until it is placed (except Hill-only with no Hill space). Each copy is bound to its slot and copy number before the mouse-down (`PlacementPurchaseReady`).
- **Where:** the first edge unit goes beside the lit path, closest to the player. Units sit 12 px outside the road, and only an 8–18 px edge gap is accepted. Every point must be within 180 px of the player.
- **Pairs (`PlaceUnitAction`):** row 1 is the path edge; row 2 is one partner spot straight behind a row-1 unit. Partners come first: every edge unit whose partner spot is still open gets one try there (`TryPartnerPlacement`), newest first, before any new edge spot. A miss closes only that partner spot.
- **Front and behind:** `PlacementUpstreamDirection` measures where the enemies come from on the minimap route (from the player toward the far end from the base) and turns it into a screen direction with the measured W/D movement. `placementline` then returns two lanes: a front lane starting at the free edge spot nearest the player on the enemy side, and a behind lane on the base side, each running away from the player. `PlacementLaneOrder` tries the side holding fewer edge units first (front on a tie) and then alternates, so a miss on one side is followed by a try on the other rather than squeezing further into the same area.
- **Without a direction** (no base or movement calibration): one lane beside the player, continued beside the newest edge unit (`StartLineAtNewestEdgeUnit`), onward along the edge and then back along it.
- **Edge blocking:** 3 misses on one edge block the whole stretch they walked (48 px either way of every miss, `RegisterPlacementEdgeMiss`); the next tries go to the opposite side or another edge.
- **Money:** on the path edge, the free spot farthest from all placed units (or from the player if first). Others keep 48 px from it (normal 24). Never an anchor; the line keeps growing from the last ordinary edge unit.
- **Hill-only / Hybrid:** Hill-only needs highlighted Hill terrain and never falls back to ground. Hybrid tries the green Hill highlights (nearest the path first), then ground. Hill units are never anchors.
- **Purchase confirmation:** the side unit panel opening after the click confirms the purchase. Before buying, a selection-only click rejects spots that already hold a unit. Failed spots (14 px radius) are skipped for the rest of the game.
- **Recovery:** a purchase hidden by cards is re-checked with selection-only clicks and never bought twice (`RecoverPendingPlacement`).
- **Short of Yen (`PlacementShortOfYen`, `WaitForPlacementYen`):** checked only after a purchase fails, so successful placements cost no time. One OCR pass reads the Yen counter above the toolbar and the cost under each of the six slot portraits (`ReadPlacementMoney`). If Yen is below the unit's cost, the miss is **not** counted toward relocation, the spot is not rejected and no edge is blocked; the macro re-reads Yen about once a second (at most 20 s) and then places the same unit. Costs are remembered by unit name in `learning.ini` (`[UnitCosts]`); a new value is believed only when two reads agree. Once Yen has been seen to cover the cost, further misses before the next purchase skip the read. Unreadable Yen or an unknown cost counts the miss as before.
- **Relocation:** 6 consecutive failed purchases move the player to the next route checkpoint (25% → 50% → 75%). At checkpoint 3 it keeps trying locally.
- **Three-path map (Sky Island):** vision reports `paths=3` when long crimson AND blue lines are on the minimap besides the green one; all three become one walkable route. The macro walks to the fixed spot `THREE_PATH_STAND` (20.26, 22.10 on the 96-grid), where the paths meet beside the base: along the lines, then straight for the last 6 cells to within 1.5 cells. Placement stays there (checkpoint index 3, no relocation).
- **Lit path colour:** lime, or on sand-tinted maps (Sand Village) pure yellow. Yellow is used when it outweighs lime; once a frame clearly shows a yellow path, the rest of the match uses yellow only (`worldreset` at match start), so green Hill highlights are never path there. Yellow below 74% of the height (the Weather Alert banner) is ignored.
- **P:** clicked at most once per game and confirmed only by the P glyph turning white (`toolbarfixed`). A visible road is not accepted as proof.
- **Hidden base heart** (the player spawns standing on it, e.g. Magic Town): the 25/50/75% points are the same three spots from either end of the route, so they are drawn from the route's two far ends (`MapRouteQuarters`) and the player walks toward the middle one. Each step re-reads the minimap; once the arrow has left the heart it is read whole, the checkpoints are numbered from it and the target switches to checkpoint 1 (`ResolveHiddenBase`). If the heart is still hidden on reaching the middle point, or when the prep timer runs out, the route end nearest where the player started is taken as the base.
- **Two-path maps:** when the minimap has a second (purple) path, the checkpoints are the points where it meets the green route (`MapCrossingCheckpoints`): the first crossing the enemies reach, then the next meeting points toward the base. Vision reports them (`scan` → `crossings`); they are saved with the learned minimap variant.
  - **Cards while walking:** every movement key is released *before* the card is chosen (`MovementHoldUntil`, `MovementCardPause`), so the player stands still during card selection. Afterwards the walk resumes toward the same checkpoint from the player's actual position, and card time does not count against the walk.
  - **20-second rule:** if relocation walking (card time excluded, added up across retries for the same checkpoint) passes 20 s without arriving, `TeleportBackToSpawn()` clicks the Settings gear (bottom left), then the arrow button on the row OCR confirms as "Teleport back to Spawn", then Settings' red X. It then re-finds the player and walks to the same checkpoint from spawn. "Return to Lobby" (the next row down) is never clicked. At most 2 teleports per checkpoint.
- **Speed:** the Level Modifiers OCR runs at most every 30 s during placement and never during upgrades (the F manager covers it); a missed unit panel only re-runs OCR layout learning until the panel has been recognised once (`gUnitPanelSeen`). Unit placement/selection holds, gaps and cursor travel are 150 ms (was 200 ms), and the pause after a confirmed placement is 100 ms (was 180 ms). Panel-confirmation waits are unchanged, so purchases are still verified.
- **Same unit until placed:** a copy that is not placed yet is retried (0.3 s apart; 3 s while relocation is not possible) before any later unit, so the build order holds. The only exception is a Hill-only unit with no usable Hill space: it waits 10 s while later units are placed, then is tried again.
- **No upgrades during placement.** Upgrades need the F manager, and F is only allowed once every unit is placed, so the build loop no longer calls `UpgradePriorityPass`. Consequence: if a unit can never be placed (for example a Hill-only unit with no Hill space), upgrades do not start for that match.
- **Click-away after each confirmed placement** uses the same (497,168) point.

---

## 6. Cards

### Detection
`HasCardChoice()` looks at the centre card only: two tall bright outlines at x≈314/488 and a dark interior. Hue is ignored, and the right-side "Level info" panel can never count as a card. Cards are checked during every wait, cursor move and pause (`CheckCardInterruption` inside `WaitFor`).

### Handling (`ClearCardChoice` → `TryChooseCard` → `ConfirmLockedCardSelection`)
1. Press Q only if a placement preview is active. During upgrades, close the F manager once (only if it is confirmed open). This is the only time it is closed. The side unit panel is clicked away only during placement, never during upgrades.
   After the card screen closes, the manager is reopened and the top-priority unit is reselected before any R.
2. **Pixel green check first** (`PixelGreenCards`). Each card's title and first effect lines are scanned for bright green glyphs (G>170, G−R>80, G−B>60) versus bright red. If exactly one card is green, it is chosen **immediately, before OCR**, because votes can end within seconds. On the supplied screenshot this gives Range: 173 green pixels against 0 and 0 on the two red cards.
   Card positions come from `cardboxes` (MinimapVision.py), measured once per card screen: the left and middle dark panels give the card width and spacing, and the right card is placed one spacing further, so the Level Modifiers panel touching it is never read as part of it. If detection fails three times, the fixed 800x600 layout is used.
3. Otherwise OCR reads word boxes, and each word's pixels give its colour (`ReadWordColourCards`). Shared reward lines ("+30% SummerPearls", secret portal) are ignored. A card whose OCR colour is unknown but whose pixels are clearly green still counts as green.
4. The choice is locked for this card screen. Each confirmation re-reads, and newly verified green words override a previous non-green pick. The card is clicked once, re-clicked after 1 s if the screen is still open, and the lock clears when the screen closes.

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
5. **Never chosen:** positive (red) enemy Speed. An all-Speed offer is left unclicked (the vote timer picks at random anyway). Unclear red/unknown text is re-read up to 3 times (1.5 s apart) before the fallback: any green card first, then the easiest readable non-Speed debuff, then an unreadable non-Speed card.

### Reported screenshot
"+ Enemy Health I" (red) / "+ Range I" (green) / "+ Resistant Enemies I" (red, +50 physical and +50 magic) → **Range** by the pixel check, with no OCR needed. If Range were absent: Health, then the shared resist card ahead of any sole resist card.

---

## 7. End of match, idle, reporting
- **End screen:** the green Next button triggers end handling. The macro clicks Next, clicks game space 5 times to dismiss rewards, waits for the paired Return to lobby / Replay buttons, and clicks **Replay** only (never Return to lobby). It then waits up to 3 minutes for the next Vote Start. Placement, upgrades and idle clicks pause meanwhile.
- **Discord:** once per match, WIN/LOSS plus a screenshot. Next before Replay means defeat.
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
| `RGB`, `IsUiGreen`, `IsUiRed`, `IsUiYellow`, `IsBubbleBlue/Red`, `IsMiniMapRouteGreen`, `IsMiniMapPlayerWhite`, `CountRef`, `FindUiGreenCentre` | Colour predicates and counting. |
| `GetMiniMapRoutePoints`, `FindNearestRoutePoint`, `FindNextRouteWaypoint`, `FindMiniMapPlayer`, `ArrowPose`, `MapDistance`, `HoldArrow`, `NavigateAlongRoute` | AHK fallback minimap reading and route following. |
| `CameraReset`, `InputPause`, `HoldCameraKey` | Overhead camera (hold I, tilt, hold O). |
| `EnsureRouteAndSpawn` | Match preparation. Clears the manager phase, never presses F, then minimap, P, camera, player and checkpoints. |
| `HasVoteStart`, `HasLobbyPlay`, `IsLobbyCyan`, `HasMatchmakingPanel`, `HasOpenPortal`, `TryStartPortal`, `TryStartFromLobby`, `TryVoteStart`, `VoteStartClosed` | Lobby and vote flow. |
| `HasCardChoice`, `HasCardBorder` | Card screen detection. |
| `IsCardColour`, `CardBorderKind`, `CardColourKind` | Legacy border classification (not used to decide). |
| `CheckCardInterruption` | Polled during waits. Pauses the current action, chooses the card, resumes the same unit/purchase. |
| `ClearCardChoice`, `ClearCardChoiceAction` | Card handling entry. Q if a preview is active, close the manager for the card, reopen it and reset the unit selection afterwards. No unit-panel click-away during upgrades. |
| `ResetCardSelection`, `WaitForCardChoiceClosed` | Card lock reset and a 350 ms stable-closed check. |
| `TryChooseCard` | Pixel-green fast path, then OCR, ranking, retries and fallback. |
| `ConfirmLockedCardSelection` | Re-verify green priority, block Speed, click the card (left card at y=405 if the unit panel is showing). |
| `HasValue` | List contains. |
| `ReadUnitPlan` | Snapshot of the six slots. |
| `ResetIdleKeepAlive`, `IdleKeepAliveAllowed`, `IdleKeepAliveTick` | 5-minute keep-alive at the manager-safe point. |
| `NavigateForPlacement` | Navigation, then the timeout rule. |
| `RunMacro` | The match state machine (§2). Starts the manager phase after the build. |
| `StartMacro`, `StopMacro`, `RunMacroSafely`, `TestRoutePreparation`, `ReleaseMovementKeys` | Run control. Stop also clears the manager phase. |
| `WaitFor`, `Notify`, `Log`, `RunSelfTests` | Utilities and the built-in tests. |

### UnitManager.ahk
| Function | What it does |
|---|---|
| `BeginUnitManagerPhase` / `EndUnitManagerPhase` | Allow F (after the build is placed) / forbid F and reset all manager state (match start, stop). |
| `ReadUnitManager` | Vision `unitmanager`: open, ready, rows, pitch, bottom-row count, entries (portrait and Upg click points, lit/total segments, Max, portrait colours). |
| `FocusUnitManagerGame` | Focus Roblox before F or scrolling. |
| `PressUnitManagerKey` | One F tap. Refused unless the phase is on. Records the press time. |
| `UnitManagerBlocked` | True while a card or end screen is showing. |
| `EnsureUnitManagerOpen` | Return the open manager. Press F once only after 3 closed reads, 2.5 s cooldown, 20 s lock after 2 unconfirmed presses. |
| `MaintainUnitManager` | Every 3 s in the watch loop, reopen the manager if the game closed it. |
| `CloseUnitManagerForCards` | The only close: F during card choice only when two readings agree the manager is open (two presses at most). Cards are read only after two "closed" readings. |
| `ReopenUnitManagerAfterCards` | After cards: reset the upgrade selection and reopen the manager, so the correct top-priority unit is reselected. |
| `UnitManagerFail` | Record why a selection failed. |
| `ScrollUnitManager`, `ResetUnitManagerBottom`, `ParseUnitManagerEntry`, `UnitManagerEntry` | Wheel scrolling over the list (drops the remembered tile), bottom anchoring, entry lookup. |
| `ManagedUnitCell` | Row and column of purchase #N for an even or odd unit count. |
| `LocateManagedUnit`, `ForgetManagerTile`, `ResetManagerTileMemory` | Find a purchase's tile (reusing the last position while the list is still), and reset that memory. |
| `ClickManagerPoint`, `SelectManagedUnit` | Click a manager point; portrait selection with side-panel confirmation. |
| `SelectManagedUnit` | Select purchase #N (§3). |

### PlacedUnits.ahk
| Function | What it does |
|---|---|
| `BeginPlacementRun`, `SavePlacementRun` | Start and save the numbered purchase record (`placement_run.ini`). |
| `PlacementLayoutKey`, `SaveLayoutPoint`, `CachedPlacementCandidates` | Per-map saved positions, reused only when the local path view validates. |
| `RegisterPlacedUnit` | Record purchase #N (slot, priority, target, position). |
| `UpgradeQueue`, `UpgradePriorityPass` | Priority order and one pass on the head. |
| `ResetUpgradeSelection`, `ResetUpgradeTracking`, `RefreshRecordedUpgradeTarget` | Selection and remembered tile, per-unit click tracking, live target edits. |
| `SaveUpgradeDiagnostic` | Saves the client area to `cache\upg-tile-<id>.bmp`, once per unit per match. |
| `DeferUnitUpgrade` | 10/20/40/60 s back-off for a genuinely stuck unit (the manager stays open). |
| `OpenRecordedUnit` | Portrait selection through the manager (relocation checks). |
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
| `PlacementTerrain`, `FailedPlacementSpot`, `RememberFailedPlacementSpot`, `ForgetFailedPlacementSpot` | Per-game rejected spots (14 px radius). |
| `PlacementClickRef`, `PlacementPurchaseReady` | Guarded click: no click if a card, panel or end screen appears. Binds the purchase. |
| `SelectPlacementUnit`, `CancelUnitPreview` | Slot key and Q (only when a preview is active). |
| `HasUnitPanel`, `UnitPanelRegion`, `UnitPanelColourHits`, `WaitForUnitPanel` | Side unit panel detection (learns its layout per window size). |
| `ClickAwayFromUnitPanel`, `CloseUnitPanel` | Close the side panel at (497,168). **Never touches F or the manager.** |
| `PlacementPanelClosedStable`, `CountSlotPlacements` | Helpers. |
| `FinishPlacement`, `TryPlacementCandidate`, `TryPlacementCandidateAction`, `TrySelectUnitAt`, `RecoverPendingPlacement` | Purchase, confirmation and recovery without double buying. |
| `PlacementStillBesidePath`, `AddPlacementGeometry`, `OppositePlacementPoint`, `PlacementEdgeNormal`, `SamePlacementEdge`, `BlockedPlacementEdge`, `PlacementBlockedEdgeExclusions`, `RegisterPlacementEdgeMiss` | Edge geometry, opposite-side switch after 3 misses. |
| `TryPlacementPoints`, `MatchSavedPlacementsToPath`, `FindHillPlacementCandidates` | Try lists of points, saved points, Hill spots. |
| `PlaceUnit`, `PlaceUnitAction` | One copy of one slot (no F). |
| `ReadPlacementMoney`, `DigitsValue`, `UnitPlacementCost`, `PlacementShortOfYen`, `WaitForPlacementYen` | Yen counter and slot costs (one OCR pass after a failed purchase); Yen-short misses are not failures. |
| `PlaceConfiguredBuild`, `PlaceConfiguredBuildAction`, `MissingBuildPlacements` | The whole build loop (no upgrades until complete). |

### PlacementArea.ahk
| Function | What it does |
|---|---|
| `ResetPlacementArea`, `PlacementFailureLimitReached`, `ResetPlacementFailureStreak`, `RecordFailedPlacement`, `PlacementCopyFailures` | Six-consecutive-failure streak. |
| `PlacementAnchorKnown`, `PlacementViewCanShift`, `ShiftRecordedPlacements`, `ContinuePlacementInCurrentView`, `RecoverPlacementView` | Keep recorded coordinates valid when the view moves. |
| `PlacementRelocationDirection`, `PlacementFarthestUnit`, `PlacementRelocationRoom`, `CheckRelocationUnit`, `RelocatePlacementArea`, `RetryFinalCheckpointPlacement` | Move to the next checkpoint (20 s walking rule, then teleport and resume). Keep trying locally at checkpoint 3. |
| `TeleportBackToSpawn`, `CloseSettingsAfterTeleport` | Settings gear → OCR-confirmed "Teleport back to Spawn" arrow → close Settings with its red X. |

### Learning.ahk
| Function | What it does |
|---|---|
| `BuildLearningTab`, `MemoryRead`, `MemoryKey`, `WindowGeometry` | Learned-data storage per window size and DPI. |
| `ButtonSection`, `SaveButtonRecord`, `ReadButtonRecord`, `ForgetButton`, `LearnHoveredButton`, `ButtonLabels`, `ButtonRegion`, `DiscoverButton`, `FindCompactRedControl`, `ClickWindowOnce`, `ClickLearnedButton`, `ConfirmObservedTransition`, `ObserveTextButtons`, `HasSavedRedControl`, `HasSavedColourControl` | Learn and click named buttons (OCR plus F10 teaching). |
| `SaveFrameBmp`, `ReadOcrRows`, `ParseOcrRows`, `NormalizeWords` | OCR plumbing. |
| `HasSettingsPanel`, `SettingsPanelClosed`, `UnitPanelClosed` | Panel checks. |
| `HasSecretPortalReward`, `StripSecretPortalReward`, `BuffTitleStat`, `BuffTitleTier`, `EnemyStatReduction` | Card text parsing. |
| `ReadResistanceAmounts`, `ParseResistanceEffects`, `CombineResistanceLines`, `CardIsResistance` | Physical/magic amounts. |
| `ResistanceIsShared` | **New:** a card adds both physical and magic resist. |
| `ResistancePreferred` | Resistance tie-break: **shared first (Balanced)**, then team preference / total / peak / match totals. |
| `CardPolicy`, `CardPolicyFromLines`, `CardRank` | Card stat, kind, amount, tier, rank. Base debuff label order: shield, explosive death, health, **physical+magical**, physical, magical, 0.5 regen, speed (red cards are actually ranked by `DebuffOutlook`). |
| `CardIsRegen`, `DebuffOutlook`, `DebuffBetter`, `CardBetter` | Red-card ranking on projected totals against the Health 300% / resist 150 / regen 2% caps (§6). |
| `CardHasGreenEffect`, `CardSelectionView`, `CardIsSpeed`, `CardPreferenceScore`, `ChooseBestCard`, `PreferVerifiedGreenChoice`, `FallbackCardChoice` | Ranking and safety (§6). |
| `WhiteBits`, `HashText`, `CardRectangle`, `CardVisual`, `ReadCardMemory`, `RememberCard`, `TeachCurrentCard`, `BitOverlap` | Visual card memory (fallback only). |
| `PlacementContextMatches`, `PreparePlacementMemory`, `PlacementSection`, `ReadPlacementRecords`, `WritePlacementRecords`, `CandidateOccupied`, `KnownPlacementCandidates`, `RememberPlacement` | Placement memory per map/camera profile. |

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

### MapNavigation.ahk
Minimap capture and graph (`MiniMapBounds`, `CaptureMiniMap`, `MapNeighbours`, `MapComponents`, `MapGreenMask`, `MapBits`, `MapFromBits`, `MapBridgeFragments`, `MapGapOccluded`, `MapThin`, `MapWhiteComponents`, `MapMarkers`, `MapNearest`, `MapDistances`, `MapShortestPath`), checkpoints (`MapPlacementCheckpoints`, `MapFarthestNode`, `MapRouteQuarters`, `ResolveHiddenBase`, `MapRecommendedTarget`), map variants (`ReadMapModel`, `BuildMapModel`, `ArchiveMapModel`, `OccludedShapeMatch`), the timed preparation (`PrepTimeLeft`, `BeginTimedPreparation`, `FinishNavigationTimeout`), movement (`NavigateDrawing`, `NavigateByHeading`, `MapLineFollowsRoute`, `ProbePlayer`, `ProbeKeyPair`, `MoveVectorsAgree`, `MoveDurations`, `MovePrediction`, `HoldKeys`, `NavigateWithKeys`, `LearnMoveKey`, `RouteProgress`), obstacles (`EscapeSteps`, `EscapeObstacle`: jump, then step around up to 18 cells, 7 attempts), cards while walking (`MovementHoldUntil`, `MovementCardPause`, `MovementPause`, `TakeMovementCardMs`: keys up before the card, then resume from the actual position), the Python service (`VisionRequest`, `VisionOk`, `VisionClose`, `VisionSync`, `VisionMapModel`, `VisionModelFromScan`, `VisionSetPlayer`, `VisionRefreshPlayer`, `RefreshMapPlayer`, `WorldRequest`), and the lit path (`EnsurePathLit`, which clicks P at most once; `FollowLitPath`, `AimPresses`, `BesidePathCandidates`, `OnLitPath`).

### Endgame.ahk
`ResetEndGameFlow`, `EndEmptyScreen`, `EndScreenColours`, `ParseEndScreenRows`, `ReadEndScreen` (300 ms cache), `IsEndGameBlocking`, `HasDefeatNext`, `HasReplayButton`, `EndGameButtonStillVisible`, `ClickEndGameButton`, `ReadEndOutcome`, `EndRewardClickAllowed`, `DismissEndRewards`, `TryEndState`, `WaitForReplayVoteStart`.

### Discord.ahk / UnitSettings.ahk
`BuildDiscordTab`, `IsWebhookUrl`, `SaveWebhook`, `TestWebhook`, `PostToWebhook`, `ReportMatchResult` · `SavedUnitNumber`, `LoadUnitSettings`, `QueueUnitSettingsSave`, `SaveUnitSettings`, `FlushUnitSettings`, `UnitPlacementModeChanged`.

### MinimapVision.py (commands)
`scan/locate/track/moved` (minimap and player), `toolbar/toolbarfixed` (P state), `world/follow/beside/onpath` (lit path), `placementline/placementneighbours/placementvalid/validateplacements` (placement geometry), `hillspots`, `relocation`, `rememberview/viewshift`, **`cardboxes`** (card interiors from the dark card panels), **`unitmanager`** (heading "Unit Overview", Sell-X anchored rows, portrait click points), `debug/worlddebug`, `discord`.

---

## 9. Tests
- `CheckpointManagerTests.py`: manager selection through 20/19/1-unit layouts. Exactly **one F for the whole match**, **no F before placement**, one F to reopen a closed manager, and the misread guard (2 presses at most).
- `UpgradeRegressionTests.py`: finite targets and input guards. A missed selection is retried at the same priority before deferral, and no upgrades/F happen before the build is complete.
- `LearningTests.ahk` (`--self-test`): card policy. Shared resist beats sole 100/75/25, the reported screenshot picks green Range, pixel-only green is found in each position, the reported loss (230% Health, Health +200 offered) now takes resist, the 300/150/2% caps, and Level Modifiers parsing that ignores card wording.
- `CardPriorityTests.py`, `UnitManagerVisionTests.py`, and the existing placement/vision tests.
- The AHK tests need `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

Previous versions of every changed file are in `cache/before-manager-stays-open/`.

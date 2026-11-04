# AA Path Macro: what it does, every function, every decision

This describes the macro as it currently stands (after the "unit manager stays open" change).
Coordinates are in the 800 x 600 **reference** space unless stated otherwise; they are scaled
to the live Roblox client area at run time. Roblox is sized to 1401 x 975 outer pixels on Start.

---

## 1. Files

| File | Role |
|---|---|
| `AAPathMacro.ahk` | Entry point, GUI, hotkeys, input primitives, colour helpers, card detection/choice, lobby/vote flow, the match state machine (`RunMacro`), idle keep-alive, self-tests. |
| `UnitSettings.ahk` | Six unit slots (enabled, name, count, priority, target, Hill, Hybrid) saved to `unit_settings.ini`. |
| `MapNavigation.ahk` | Minimap reading (Python vision or AHK fallback), route graph, checkpoints, player probing, movement, obstacle escape, P (path light) toggle. |
| `Placement.ahk` | Placement candidates, purchase clicks, unit-panel detection, click-away, pending-purchase recovery, the build loop. |
| `PlacementArea.ahk` | Five-failure streak, checkpoint relocation (25% → 50% → 75% of the route). |
| `PlacedUnits.ahk` | Numbered purchase record, upgrade queue, UPG reading, R presses, finite-target guards. |
| `UnitManager.ahk` | F unit manager: when F may be pressed, keeping it open, scrolling, selecting purchase #N. |
| `Learning.ahk` | OCR, learned buttons, card text policy and ranking, placement memory. |
| `CardContext.ahk` | Card word colour (green/red) reading, pixel green detection, resistance preference tab, right-panel match modifiers. |
| `Endgame.ahk` | End screen detection, Next/reward dismissal, Replay. |
| `Discord.ahk` | Optional WIN/LOSS webhook with screenshot. |
| `MinimapVision.py` | OpenCV service (minimap, lit path, placement lines, Hill spots, unit manager geometry). AHK sends all input. |
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
| A misreading cannot toggle it repeatedly. | If two F presses in a row never produce an "open" reading, F is locked for 20 s and the log says so. |
| No opening F during cards or the end screen. | `UnitManagerBlocked()` checks `HasCardChoice()` and `IsEndGameBlocking()` before every open attempt. The only F during cards is the single closing press above. |
| If the game closes it, it is reopened once. | `MaintainUnitManager()` checks every 3 s in the watch loop and reopens through the same guarded `EnsureUnitManagerOpen()`. |
| Leftover manager before placement. | `EnsureRouteAndSpawn` only logs it. It does not press F (placement-phase rule). |

### Selecting purchase #N (`SelectManagedUnit`)
1. Refuse while a placement purchase is unresolved, or while a card is up (reason `card`).
2. Close the previous unit's side panel with the manager-safe click-away, and drop any preview (Q).
3. `EnsureUnitManagerOpen()`. If it fails, the reason is `manager`.
4. Scroll down until the list bottom stays still for two single-notch checks (`ResetUnitManagerBottom`).
5. Row/column of #N from the bottom: #1 bottom-right, #2 bottom-left, #3 the row above on the right, and so on.
6. Scroll up one notch at a time. If a notch moves a full row or more, it stops instead of guessing.
7. Click **only the portrait** (never Sell X, Upg or First), then wait for the side unit panel.
8. Every failure records a reason in `gUnitManagerFailure`: `card`, `manager`, `scroll`, `panel` or `blocked`.

---

## 4. Upgrades

- **Queue:** unfinished recorded units, lowest priority number first, ties by purchase number (`UpgradeQueue`). Each watch-loop pass works only on the head of the queue (`UpgradePriorityPass`).
- **Selection:** if the selected unit is not the head, or its panel is gone, it is reselected through the manager (`OpenRecordedUnit` → `SelectManagedUnit`).
- **When selection fails** (this is the change that stops units being skipped):
  - `card` → choose the card (the manager is closed for it, then reopened), then reselect **the same** unit. Nothing is deferred.
  - `manager` → retry the same priority. This is never counted against the unit.
  - Any other reason → retry the same unit up to **3** times. Only then is it deferred for 10 s so the others can continue.
- **MAX target (99):** R about every 300 ms while the panel is open. The level is re-read every 2 s.
- **Finite target:** every R needs a fresh, stable UPG reading (OCR of the gold header at 4x, then 2x, then the full panel). The header pixel signature must not change during OCR. A per-unit input budget is calculated from the first verified level. An ignored R is retried after 4 s only if OCR and the pixels both still show the old level. An unaffordable (non-green) Upgrade button waits without spending budget. A header that stays unreadable 3 times defers the unit 10 s.
- **Target reached or MAX:** mark complete, click away (the manager stays open), log the next unit.
- **Live target edits** in the GUI apply to already-placed units at once (`RefreshRecordedUpgradeTarget`).
- **Cards during upgrades:** the unit panel is **not** clicked away. The macro presses Q only if a placement preview is active, closes the manager once (if it is confirmed open), and chooses the card. Afterwards it reopens the manager, clears the current selection and reselects the top-priority unit through the manager, so R always goes to the correct unit. If the side panel is still open and the chosen card is the left one, the click lands at y=405 instead of 330, so it can never hit the panel's Upgrade button.

---

## 5. Placement

- **Order:** slots in order, copies in order. Each copy is bound to its slot and copy number before the mouse-down (`PlacementPurchaseReady`).
- **Where:** first a point beside the lit path, closest to the player. Then it follows the same side of the road. Units sit 12 px outside the road, and only an 8–18 px edge gap is accepted. A second row is allowed behind a confirmed first-row unit, never a third. Every point must be within 180 px of the player.
- **Hill-only / Hybrid:** Hill-only needs highlighted Hill terrain and never falls back to ground. Hybrid tries Hill, then ground.
- **Purchase confirmation:** the side unit panel opening after the click confirms the purchase. Before buying, a selection-only click rejects spots that already hold a unit. Failed spots (14 px radius) are skipped for the rest of the game.
- **Recovery:** a purchase hidden by cards is re-checked with selection-only clicks and never bought twice (`RecoverPendingPlacement`).
- **Relocation:** 5 consecutive failed purchases move the player to the next route checkpoint (25% → 50% → 75%). At checkpoint 3 it keeps trying locally.
- **Blocked copies** wait 10 s (Hill) or 0.3–3 s while the other slots continue.
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
3. Otherwise OCR reads word boxes, and each word's pixels give its colour (`ReadWordColourCards`). Shared reward lines ("+30% SummerPearls", secret portal) are ignored. A card whose OCR colour is unknown but whose pixels are clearly green still counts as green.
4. The choice is locked for this card screen. Each confirmation re-reads, and newly verified green words override a previous non-green pick. The card is clicked once, re-clicked after 1 s if the screen is still open, and the lock clears when the screen closes.

### Ranking (`ChooseBestCard`), in order of authority
1. **GREEN FIRST, above everything.** One green card is chosen outright. If two or three are green, only the green cards are compared. A red card never beats a green one, whatever its text says. Green Speed reductions are allowed.
2. **Buffs (green):** Random Blessings → Double Attack → Attack → Range → Cooldown → (unreadable green) → Yen → Boss Damage. Tiers only break ties within the same stat, and a bigger amount breaks equal tiers.
3. **Debuffs (red, only when nothing is green):** Shield → Explosive Death → Health → 0.5 Regen → **resistance group** → (positive enemy Speed is forbidden).
   - With 250%+ enemy Health already on the match, more Health drops behind the resistance group.
   - **Resistance group, Balanced team (the current setting):**
     **a shared physical + magical debuff (e.g. +50 Physical / +50 Magic) always beats a sole one (+75 or +100 Physical, +75 Magic, ...)**, whatever the amounts and even if one of its numbers was unreadable.
     Between two shared cards, or two sole cards: smaller total, then smaller single increase, then the lower projected match resistance.
   - Magic team / Physical team checkboxes (Cards tab): if one is ticked, it overrides the shared-first rule and the card that adds less of the stat that team must avoid wins.
4. **Secret portal/drop bonus:** with two ordinary debuffs available, the ordinary ones are preferred.
5. **Never chosen:** positive (red) enemy Speed. An all-Speed offer is left unclicked. Unclear red/unknown text is re-read up to 3 times (1.5 s apart) before a safe fallback is taken: any green card first, then a readable non-Speed debuff, otherwise wait.

### Reported screenshot
"+ Enemy Health I" (red) / "+ Range I" (green) / "+ Resistant Enemies I" (red, +50 physical and +50 magic) → **Range** by the pixel check, with no OCR needed. If Range were absent: Health, then the shared resist card ahead of any sole resist card.

---

## 7. End of match, idle, reporting
- **End screen:** the green Next button triggers end handling. The macro clicks Next, clicks game space 5 times to dismiss rewards, waits for the paired Return to lobby / Replay buttons, and clicks **Replay** only (never Return to lobby). It then waits up to 3 minutes for the next Vote Start. Placement, upgrades and idle clicks pause meanwhile.
- **Discord:** once per match, WIN/LOSS plus a screenshot. Next before Replay means defeat.
- **Idle keep-alive:** when every target is complete, the macro clicks the manager-safe click-away point every 5 minutes. It skips the click while cards, a unit panel or an end screen are up.
- **Match modifiers:** the right panel (Enemy Health %, Physical/Magic resistance) is read every 8 s as context for card choice only. It is never clicked.

---

## 8. Function reference

### AAPathMacro.ahk
| Function | What it does |
|---|---|
| `BuildGui`, `AddReadableEdit` | Build the macro window (units, cards, learning, Discord tabs, activity log). |
| `FindRoblox`, `GetClient`, `ToScreen`, `MoveRef`, `SmoothMoveTo` | Locate Roblox, its client rect, convert reference coordinates to screen, and move the cursor smoothly. |
| `ClickRef`, `ButtonPosition`, `ClickButton` | Click a reference point (with optional re-check after moving), or a learned/static named button. |
| `BeginInputAction`, `EndInputAction`, `ActionPause` | Input pacing (300 ms general, 200 ms unit actions), interruptible pauses that also poll for cards. |
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
| `ReadUnitManager` | Vision `unitmanager`: open, ready, rows, pitch, entries (portrait click points). |
| `FocusUnitManagerGame` | Focus Roblox before F or scrolling. |
| `PressUnitManagerKey` | One F tap. Refused unless the phase is on. Records the press time. |
| `UnitManagerBlocked` | True while a card or end screen is showing. |
| `EnsureUnitManagerOpen` | Return the open manager. Press F once only after 3 closed reads, 2.5 s cooldown, 20 s lock after 2 unconfirmed presses. |
| `MaintainUnitManager` | Every 3 s in the watch loop, reopen the manager if the game closed it. |
| `CloseUnitManagerForCards` | The only close: F during card choice only when two readings agree the manager is open (two presses at most). Cards are read only after two "closed" readings. |
| `ReopenUnitManagerAfterCards` | After cards: reset the upgrade selection and reopen the manager, so the correct top-priority unit is reselected. |
| `UnitManagerFail` | Record why a selection failed. |
| `ScrollUnitManager`, `ResetUnitManagerBottom`, `UnitManagerEntry` | Wheel scrolling over the list, bottom anchoring, entry lookup. |
| `SelectManagedUnit` | Select purchase #N (§3). |

### PlacedUnits.ahk
| Function | What it does |
|---|---|
| `BeginPlacementRun`, `SavePlacementRun` | Start and save the numbered purchase record (`placement_run.ini`). |
| `PlacementLayoutKey`, `SaveLayoutPoint`, `CachedPlacementCandidates` | Per-map saved positions, reused only when the local path view validates. |
| `RegisterPlacedUnit` | Record purchase #N (slot, priority, target, position). |
| `UpgradeQueue`, `UpgradePriorityPass` | Priority order and one pass on the head. |
| `ResetUpgradeSelection`, `ResetFiniteUpgradeGuard`, `RefreshRecordedUpgradeTarget` | Selection state, input budget, live target edits. |
| `ParseUpgradeState`, `ReadUnitUpgradeState`, `UpgradeHeaderSignature`, `UnitUpgradeButtonReady` | UPG level and MAX reading, stability signature, affordability. |
| `SaveUpgradeDiagnostic` | On the third unreadable UPG read, saves the client area to `cache\upg-unreadable-<id>.bmp`. The log line states why the read failed (no number from OCR, or the heading pixels changed during OCR) and the raw OCR text. |
| `DeferUnitUpgrade` | 10 s back-off for a genuinely stuck unit (click-away only, the manager stays open). |
| `OpenRecordedUnit` | `SelectManagedUnit(item.id)`. |
| `PressUnitUpgradeKey` | One R (blocked during cards or with no panel). |
| `UpgradeOnce`, `UpgradeOnceAction`, `UpgradeWarning` | Upgrade one unit, with the card/manager/retry rules from §4. |

### Placement.ahk
| Function | What it does |
|---|---|
| `ResetPlacementSearch`, `RefreshPlacementSearch`, `FindPlacementCandidates`, `FindNeighbourPlacementCandidates`, `PlacementSearchExclusions`, `UsablePlacementPoint`, `PlacementSearchDiagnostic` | Candidate search along the lit path edge. |
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
| `PlaceConfiguredBuild`, `PlaceConfiguredBuildAction`, `MissingBuildPlacements` | The whole build loop (no upgrades until complete). |

### PlacementArea.ahk
| Function | What it does |
|---|---|
| `ResetPlacementArea`, `PlacementFailureLimitReached`, `ResetPlacementFailureStreak`, `RecordFailedPlacement`, `PlacementCopyFailures` | Five-consecutive-failure streak. |
| `PlacementAnchorKnown`, `PlacementViewCanShift`, `ShiftRecordedPlacements`, `ContinuePlacementInCurrentView`, `RecoverPlacementView` | Keep recorded coordinates valid when the view moves. |
| `PlacementRelocationDirection`, `PlacementFarthestUnit`, `PlacementRelocationRoom`, `CheckRelocationUnit`, `RelocatePlacementArea`, `RetryFinalCheckpointPlacement` | Move to the next checkpoint. Keep trying locally at checkpoint 3. |

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
| `CardPolicy`, `CardPolicyFromLines`, `CardRank` | Card stat, kind, amount, tier, rank. Debuff rank order: shield, explosive death, health, 0.5 regen, **physical+magical**, physical, magical, speed. |
| `CardHasGreenEffect`, `CardSelectionView`, `CardIsSpeed`, `CardPreferenceScore`, `ChooseBestCard`, `PreferVerifiedGreenChoice`, `FallbackCardChoice` | Ranking and safety (§6). |
| `WhiteBits`, `HashText`, `CardRectangle`, `CardVisual`, `ReadCardMemory`, `RememberCard`, `TeachCurrentCard`, `BitOverlap` | Visual card memory (fallback only). |
| `PlacementContextMatches`, `PreparePlacementMemory`, `PlacementSection`, `ReadPlacementRecords`, `WritePlacementRecords`, `CandidateOccupied`, `KnownPlacementCandidates`, `RememberPlacement` | Placement memory per map/camera profile. |

### CardContext.ahk
| Function | What it does |
|---|---|
| `BuildCardPreferencesTab`, `CardDamagePreferenceChanged` | Balanced / Magic team / Physical team (`card_preferences.ini`). |
| `ResetMatchCardContext`, `SignedHealthChange`, `ParseMatchModifiers`, `RefreshMatchModifiers`, `ApplySelectedCardModifiers` | Read-only match modifiers. |
| `CardHasForbiddenSpeed` | Positive enemy Speed detection. |
| `CardEffectBounds`, `EffectWordInk`, `CardWordRows`, `SharedNumericCardLine`, `ReadWordColourCards` | Per-word green/red colour, with the pixel fallback for unknown colour. |
| `CardPixelInk`, `CardPixelIsGreen`, `PixelGreenCards`, `PixelInkCards` | **New:** OCR-free green detection and the immediate green pick. |
| `LogCardDecision` | Decision log. |

### MapNavigation.ahk
Minimap capture and graph (`MiniMapBounds`, `CaptureMiniMap`, `MapNeighbours`, `MapComponents`, `MapGreenMask`, `MapBits`, `MapFromBits`, `MapBridgeFragments`, `MapGapOccluded`, `MapThin`, `MapWhiteComponents`, `MapMarkers`, `MapNearest`, `MapDistances`, `MapShortestPath`), checkpoints (`MapPlacementCheckpoints`, `MapRecommendedTarget`), map variants (`ReadMapModel`, `BuildMapModel`, `ArchiveMapModel`, `OccludedShapeMatch`), the timed preparation (`PrepTimeLeft`, `BeginTimedPreparation`, `FinishNavigationTimeout`), movement (`NavigateDrawing`, `NavigateByHeading`, `MapLineFollowsRoute`, `ProbePlayer`, `ProbeKeyPair`, `MoveVectorsAgree`, `MoveDurations`, `MovePrediction`, `HoldKeys`, `NavigateWithKeys`, `LearnMoveKey`, `RouteProgress`), obstacles (`EscapeSteps`, `EscapeObstacle`: jump, then step around up to 18 cells, 7 attempts), the Python service (`VisionRequest`, `VisionOk`, `VisionClose`, `VisionSync`, `VisionMapModel`, `VisionModelFromScan`, `VisionSetPlayer`, `VisionRefreshPlayer`, `RefreshMapPlayer`, `WorldRequest`), and the lit path (`EnsurePathLit`, which clicks P at most once; `FollowLitPath`, `AimPresses`, `BesidePathCandidates`, `OnLitPath`).

### Endgame.ahk
`ResetEndGameFlow`, `EndEmptyScreen`, `EndScreenColours`, `ParseEndScreenRows`, `ReadEndScreen` (300 ms cache), `IsEndGameBlocking`, `HasDefeatNext`, `HasReplayButton`, `EndGameButtonStillVisible`, `ClickEndGameButton`, `ReadEndOutcome`, `EndRewardClickAllowed`, `DismissEndRewards`, `TryEndState`, `WaitForReplayVoteStart`.

### Discord.ahk / UnitSettings.ahk
`BuildDiscordTab`, `IsWebhookUrl`, `SaveWebhook`, `TestWebhook`, `PostToWebhook`, `ReportMatchResult` · `SavedUnitNumber`, `LoadUnitSettings`, `QueueUnitSettingsSave`, `SaveUnitSettings`, `FlushUnitSettings`, `UnitPlacementModeChanged`.

### MinimapVision.py (commands)
`scan/locate/track/moved` (minimap and player), `toolbar/toolbarfixed` (P state), `world/follow/beside/onpath` (lit path), `placementline/placementneighbours/placementvalid/validateplacements` (placement geometry), `hillspots`, `relocation`, `rememberview/viewshift`, **`unitmanager`** (heading "Unit Overview", Sell-X anchored rows, portrait click points), `debug/worlddebug`, `discord`.

---

## 9. Tests
- `CheckpointManagerTests.py`: manager selection through 20/19/1-unit layouts. Exactly **one F for the whole match**, **no F before placement**, one F to reopen a closed manager, and the misread guard (2 presses at most).
- `UpgradeRegressionTests.py`: finite targets and input guards. A missed selection is retried at the same priority before deferral, and no upgrades/F happen before the build is complete.
- `LearningTests.ahk` (`--self-test`): card policy. Shared resist beats sole 100/75/25, the reported screenshot picks green Range, and pixel-only green is found in each position.
- `CardPriorityTests.py`, `UnitManagerVisionTests.py`, and the existing placement/vision tests.
- The AHK tests need `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`.

Previous versions of every changed file are in `cache/before-manager-stays-open/`.

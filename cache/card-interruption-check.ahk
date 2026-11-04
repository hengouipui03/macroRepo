#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gCardHandling := false,gCardAction := "placement",gCardPollAt := 0,gCardInterruptEpoch := 0,gPlacementActiveUnit := 0
global gPendingPlacement := 0,gLastPlacedIndex := 0,gPlacementPreferredSide := 0,gPlacementAttemptClicked := false,gPlacements := []
global gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0,gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
global FAILED_PLACEMENT_RADIUS := 14
global gFailedPlacementSpots := [],gPlacementEdgeMisses := Map()
global preview := false,probeClicks := 0
global testNow := 10000,cardAt := 0,visible := false,panel := false,mode := "",selected := 0,placementClicks := 0,bodyClicks := 0,rClicks := 0,choices := 0,away := 0,keys := []
CheckCardInterruption() {
    global gRunning,gCardHandling,gCardAction,gCardPollAt,gCardInterruptEpoch
    global gPendingPlacement,gPlacementActiveUnit
    if !gRunning || gCardHandling || gCardAction="" || testNow<gCardPollAt
        return false
    gCardPollAt := testNow+100
    if !HasCardChoice()
        return false
    gCardInterruptEpoch += 1
    gCardHandling := true
    try {
        Log("Centre card appeared; pause " gCardAction ", choose, then resume the same unit.")
        ; Preserve a purchase whose panel arrived together with the cards.
        if gCardAction="placement" && gPlacementActiveUnit && gPendingPlacement && HasUnitPanel()
            FinishPlacement(gPlacementActiveUnit,gPendingPlacement)
        if ClearCardChoice() && gRunning && gCardAction="placement" && gPlacementActiveUnit && gPendingPlacement {
            point := gPendingPlacement
            ; Q has cancelled the ghost. This is a selection-only check,
            ; never another purchase, for a panel hidden by the cards.
            if !CandidateOccupied(point.x,point.y) && PlacementClickRef(point.x,point.y,true)
                && WaitFor(HasUnitPanel,550,50)
                FinishPlacement(gPlacementActiveUnit,point)
        }
    } finally gCardHandling := false
    return true
}

ClearCardChoice() {
    global gCardHandling,gCardAction,gCardInterruptEpoch
    if !gCardHandling && gCardAction!="" && HasCardChoice()
        gCardInterruptEpoch += 1
    previous := gCardHandling,gCardHandling := true
    try return ClearCardChoiceAction()
    finally gCardHandling := previous
}

ClearCardChoiceAction() {
    global gRunning,gCardSelection
    if !HasCardChoice() {
        if !gCardSelection
            return true
        if WaitForCardChoiceClosed() {
            ResetCardSelection()
            return true
        }
        return false
    }
    if !ClickAwayFromUnitPanel()
        return false
    Log("Card choice is open; choosing before continuing.")
    deadline := testNow+20000
    while gRunning && testNow<deadline {
        if HasCardChoice()
            TryChooseCard()
        else if WaitForCardChoiceClosed() {
            ResetCardSelection()
            return true
        }
        ActionPause(150)
    }
    return false
}

WaitForCardChoiceClosed() {
    global gRunning
    closedAt := 0,deadline := testNow+1400
    while gRunning && testNow<deadline {
        if HasCardChoice()
            closedAt := 0
        else if !closedAt
            closedAt := testNow
        else if testNow-closedAt>=350
            return true
        if !ActionPause(70)
            return false
    }
    return false
}

ResetCardSelection() {
    global gCardSelection,gCardRetryAt,gCardUnread
    gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
}

ActionPause(durationMs,interruptible := true) {
    global gRunning
    deadline := testNow+durationMs
    while gRunning && testNow<deadline {
        if interruptible && CheckCardInterruption()
            return false
        Sleep Min(40,Max(1,deadline-testNow))
    }
    return gRunning
}

WaitFor(test, timeoutMs, pollMs := 80) {
    global gRunning
    deadline := testNow + timeoutMs
    while gRunning && testNow < deadline {
        if test.Call()
            return true
        if CheckCardInterruption()
            return false
        Sleep pollMs
    }
    return false
}

TryPlacementCandidate(unit,candidate) {
    global gRunning,gCardInterruptEpoch,gPlacementAttemptClicked,gPendingPlacement
    gPlacementAttemptClicked := false
    if !gRunning || IsEndGameBlocking()
        return false
    ; A late confirmed panel still belongs to its original click.
    if gPendingPlacement && HasUnitPanel()
        return FinishPlacement(unit,gPendingPlacement)
    if FailedPlacementSpot(candidate)
        return false
    loop {
        epoch := gCardInterruptEpoch,before := CountSlotPlacements(unit.slot)
        result := TryPlacementCandidateAction(unit,candidate)
        if !result && gRunning && HasCardChoice() && !ClearCardChoice()
            return false
        if CountSlotPlacements(unit.slot)>before
            return true
        if epoch=gCardInterruptEpoch || !gRunning {
            if !result && gRunning && gPlacementAttemptClicked && !HasCardChoice() && !IsEndGameBlocking() {
                if gPendingPlacement && HasUnitPanel()
                    return FinishPlacement(unit,gPendingPlacement)
                RememberFailedPlacementSpot(candidate)
            }
            return result
        }
        ; The interruption cancelled input; retry this unfinished copy/spot.
    }
}

TryPlacementCandidateAction(unit,candidate) {
    global gRunning,gPendingPlacement,gPlacementAttemptClicked
    gPlacementAttemptClicked := false
    if !gRunning
        return false
    if IsEndGameBlocking()
        return false
    ; A panel arriving just after the previous wait belongs to that click.
    if gPendingPlacement && HasUnitPanel()
        return FinishPlacement(unit,gPendingPlacement)
    if HasCardChoice() {
        if !ClearCardChoice()
            return false
        gPendingPlacement := 0
    }
    ; A rejected spot leaves the ghost active. Cancel it first so pressing
    ; the same slot cannot toggle placement OFF and select an existing unit.
    if !CloseUnitPanel() || !CancelUnitPreview() || !PlacementPanelClosedStable()
        return false
    if !SelectPlacementUnit(unit)
        return false
    if !PlacementClickRef(candidate.x,candidate.y,true)
        return false
    gPlacementAttemptClicked := true
    gPendingPlacement := candidate
    if WaitFor(HasUnitPanel,800,50)
        return FinishPlacement(unit,candidate)
    ; One click has finished its confirmation wait. Only then advance to
    ; the adjacent position on this same side of the path.
    if gRunning && !HasCardChoice()
        ActionPause(50)
    return false
}

FinishPlacement(unit,point) {
    global gPendingPlacement,gLastPlacedIndex,gPlacementPreferredSide,gPlacementEdgeMisses
    if !point || CandidateOccupied(point.x,point.y)
        return false
    if !RegisterPlacedUnit(unit,point)
        return false
    ForgetFailedPlacementSpot(point)
    terrain := PlacementTerrain(point)
    if gPlacementEdgeMisses.Has(terrain)
        gPlacementEdgeMisses.Delete(terrain)
    if point.HasProp("index") {
        gLastPlacedIndex := point.index
        gPlacementPreferredSide := point.HasProp("side")?point.side:0
    }
    gPendingPlacement := 0
    ClickAwayFromUnitPanel()
    return ActionPause(180)
}

CountSlotPlacements(slot) {
    global gPlacements
    count := 0
    for item in gPlacements
        if item.slot=slot
            count += 1
    return count
}

ClickAwayFromUnitPanel() {
    global gUpgradeSelectedId
    ; Above the cards, outside the unit panel and below the P/i toolbar.
    ; Drop any preview first so this click can never purchase a unit.
    gUpgradeSelectedId := 0
    if !CancelUnitPreview() || !PlacementClickRef(740,150)
        return false
    return WaitFor(() => !HasUnitPanel(),550,40)
}

CancelUnitPreview() {
    global gRunning
    if !gRunning
        return false
    SendEvent "{q down}"
    try {
        if !ActionPause(30,false)
            return false
    } finally SendEvent "{q up}"
    return ActionPause(30,false)
}

UpgradeOnce(item) {
    global gCardAction,gCardInterruptEpoch,gRunning
    previous := gCardAction,gCardAction := "upgrading"
    try {
        loop {
            epoch := gCardInterruptEpoch
            result := UpgradeOnceAction(item)
            if epoch=gCardInterruptEpoch || !gRunning || item.complete
                return result
            ; Keep this exact recorded unit/priority after closing its panel.
        }
    } finally gCardAction := previous
}

UpgradeOnceAction(item) {
    global gRunning,gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    RefreshRecordedUpgradeTarget(item)
    if item.complete
        return true
    if !gRunning || !ClearCardChoice()
        return false
    if gUpgradeSelectedId!=item.id || !HasUnitPanel() {
        ResetUpgradeSelection()
        Log("Open upgrade #" item.id " " item.name " | priority " item.priority " | target " item.target " | recorded " item.x "," item.y)
        if !OpenRecordedUnit(item)
            return false
        gUpgradeSelectedId := item.id
    }
    finite := item.target!=99
    wantsInput := !gUpgradeLastRAt || testNow-gUpgradeLastRAt>=1000
    ; Every finite-target R needs its own fresh header read.
    if finite && (!wantsInput || (gUpgradeReadAt && testNow<gUpgradeReadAt))
        return false
    state := 0
    if finite || !gUpgradeReadAt || testNow>=gUpgradeReadAt {
        state := ReadUnitUpgradeState(finite)
        gUpgradeReadAt := testNow+(finite?600:2000)
        RefreshRecordedUpgradeTarget(item)
        finite := item.target!=99
        if state.level>=0 && state.level>item.upgrades {
            Log("#" item.id " confirmed UPG " item.upgrades " -> " state.level)
            item.upgrades := state.level
            SavePlacementRun()
        }
        if item.complete || state.maxed || (state.level>=0 && finite && state.level>=item.target) {
            item.complete := true
            SavePlacementRun()
            Log("#" item.id " target " item.target " reached" (state.maxed?" (MAX).":" at UPG " state.level "."))
            ClickAwayFromUnitPanel()
            ResetUpgradeSelection()
            next := UpgradeQueue()
            if next.Length
                Log("Next upgrade #" next[1].id " " next[1].name " | priority " next[1].priority " | target " next[1].target)
            else
                Log("All recorded units have reached their upgrade targets.")
            return true
        }
    }
    if HasCardChoice() {
        ClearCardChoice()
        return false
    }
    if finite {
        if !state || state.level<0 {
            UpgradeWarning(item,"UPG number unreadable; target " item.target ". No R sent until a level is confirmed.")
            return false
        }
        if state.level<item.upgrades {
            UpgradeWarning(item,"stale UPG reading below confirmed " item.upgrades "; no R sent.")
            return false
        }
        if !item.HasProp("upgradeInputLimit")
            ResetFiniteUpgradeGuard(item)
        available := item.upgradeInputCount+Max(0,item.target-state.level)
        item.upgradeInputLimit := item.upgradeInputLimit<0?available:Min(item.upgradeInputLimit,available)
        if item.upgradeInputCount>=item.upgradeInputLimit {
            UpgradeWarning(item,"finite-target input limit reached; waiting for UPG " item.target " confirmation. No extra R sent.")
            return false
        }
        if item.lastUpgradeInputLevel>=0 && state.level<=item.lastUpgradeInputLevel
            && testNow-item.lastUpgradeInputAt<4000 {
            UpgradeWarning(item,"waiting for UPG change after the last R; no repeated input.")
            return false
        }
        if !state.HasProp("canUpgrade") || !state.canUpgrade {
            UpgradeWarning(item,"upgrade button is not affordable/ready; keep this unit selected and wait.")
            return false
        }
        if PressUnitUpgradeKey() {
            item.upgradeInputCount += 1,item.lastUpgradeInputLevel := state.level,item.lastUpgradeInputAt := testNow
            return true
        }
        return false
    }
    if wantsInput
        return PressUnitUpgradeKey()
    return false
}

OpenRecordedUnit(item) {
    if !CloseUnitPanel() || !CancelUnitPreview()
        return false
    ; Ground placement and the selectable model may differ in screen height.
    ; Remember the first working model click for all later upgrade passes.
    targets := [{x:item.selectX,y:item.selectY}]
    for offset in [[0,-10],[0,-20],[-8,-12],[8,-12],[0,-30]]
        targets.Push({x:item.x+offset[1],y:item.y+offset[2]})
    for point in targets {
        if HasCardChoice() {
            if !ClearCardChoice()
                return false
        }
        if !PlacementClickRef(point.x,point.y,true)
            return false
        if WaitFor(HasUnitPanel,900,60) {
            item.selectX := point.x,item.selectY := point.y
            SavePlacementRun()
            return true
        }
    }
    Log("#" item.id " " item.name ": unit panel did not open near recorded " item.x "," item.y "; will retry.")
    return false
}

PressUnitUpgradeKey() {
    global gRunning,gUpgradeLastRAt
    if !gRunning || HasCardChoice() || !HasUnitPanel()
        return false
    gUpgradeLastRAt := testNow
    SendEvent "{r down}"
    try return ActionPause(60,false)
    finally SendEvent "{r up}"
}

ResetUpgradeSelection() {
    global gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0
}


try {
    unit := {slot:3,name:"Third",priority:4,target:6},point := {x:440,y:310,index:2,side:0}
    Reset("before")
    gPlacementActiveUnit := unit,cardAt := testNow+120
    result := TryPlacementCandidate(unit,point)
    Assert(result,"Pre-click interruption failed to resume; choices=" choices " epoch=" gCardInterruptEpoch " clicks=" placementClicks " selected=" selected " now=" testNow " visible=" visible " records=" gPlacements.Length)
    Assert(choices=1 && selected=2 && placementClicks=1 && gPlacements.Length=1,"Pre-click interruption skipped or duplicated a copy")
    Assert(keys[1]="{q down}","Placement was not cancelled with Q before the card click")
    Reset("waiting")
    gPlacementActiveUnit := unit
    Assert(TryPlacementCandidate(unit,point),"Confirmation-wait interruption failed to resume")
    Assert(choices=1 && placementClicks=2 && gPlacements.Length=1 && gLastPlacedIndex=2,"Unconfirmed click consumed a copy or lost its spot")
    Assert(gFailedPlacementSpots.Length=0,"An interrupted click was blacklisted as an invalid position")
    Reset("purchase-cards")
    gPlacementActiveUnit := unit
    Assert(TryPlacementCandidate(unit,point),"Purchase simultaneous with cards was not retained")
    Assert(choices=1 && placementClicks=1 && gPlacements.Length=1,"Confirmed purchase was repeated after cards")
    Reset("covered-purchase")
    gPlacementActiveUnit := unit
    Assert(TryPlacementCandidate(unit,point),"Covered purchase was not recovered")
    Assert(choices=1 && placementClicks=1 && probeClicks=1 && gPlacements.Length=1,"Covered purchase was bought twice or not recorded")
    Reset("upgrade")
    gCardAction := "upgrading"
    item := {id:7,slot:3,name:"Third",priority:4,target:99,complete:false,x:440,y:310,selectX:440,selectY:310,upgrades:0}
    Assert(UpgradeOnce(item),"Upgrade interruption failed to resume")
    Assert(choices=1 && bodyClicks=2 && rClicks=1 && gUpgradeSelectedId=7,"Upgrade did not reopen the exact same recorded unit")
    Assert(item.priority=4 && !item.complete && item.upgrades=0,"Interruption changed priority or fabricated an upgrade")
    Reset("between")
    cardAt := testNow+40
    Assert(!ActionPause(1800) && choices=1 && !visible,"Cards during an action gap were ignored")
    Assert(!gCardHandling,"Card handling guard stayed stuck")
    FileAppend "PASS: centre-card polling during waits and gaps; Q before choice; same slot/spot resumes; simultaneous purchase recorded once; upgrade panel closes and exact unit reopens; priority and counts retained; no recursive card input.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*"
    ExitApp 1
}
Reset(next) {
    global
    preview := false,probeClicks := 0,gFailedPlacementSpots := []
    mode := next,testNow := 10000,cardAt := 0,visible := false,panel := false,selected := 0,placementClicks := 0,bodyClicks := 0,rClicks := 0,choices := 0,away := 0,keys := []
    gPlacements := [],gPendingPlacement := 0,gCardPollAt := 0,gCardInterruptEpoch := 0,gCardAction := "placement",gCardHandling := false
    ResetUpgradeSelection(),ResetCardSelection()
}
Assert(ok,msg) {
    if !ok
        throw Error(msg)
}
Sleep(ms) {
    global testNow
    testNow += Max(1,ms)
}
HasCardChoice(*) {
    global cardAt,testNow,visible
    if cardAt && testNow>=cardAt
        visible := true,cardAt := 0
    return visible
}
HasUnitPanel(*) {
    global panel
    return panel
}
TryChooseCard() {
    global choices,visible,gCardHandling,panel,keys
    Assert(gCardHandling && !panel,"Card selected before closing upgrade GUI")
    Assert(keys.Length && keys[keys.Length]="{q up}","Card selected before Q released")
    choices += 1,visible := false
    return true
}
SendEvent(key) {
    global keys,rClicks,panel,visible,preview
    if key="{q down}"
        preview := false
    keys.Push(key)
    if key="{r down}" {
        Assert(panel && !visible,"R hit an open card or missing unit panel")
        rClicks += 1
    }
}
SelectPlacementUnit(*) {
    global selected,preview
    preview := true
    selected += 1
    return ActionPause(65)
}
PlacementClickRef(x,y,*) {
    global panel,away,gCardAction,placementClicks,bodyClicks,mode,cardAt,testNow,preview,probeClicks
    if x=740 && y=150 {
        panel := false,away += 1
        return true
    }
    if !ActionPause(220)
        return false
    if HasCardChoice()
        throw Error("Unit click sent over cards")
    if gCardAction="placement" {
        if !preview {
            probeClicks += 1,panel := mode="covered-purchase"
            return true
        }
        placementClicks += 1
        if (mode="waiting" || mode="covered-purchase") && placementClicks=1 {
            panel := false,cardAt := testNow+90
        } else {
            panel := true
            if mode="purchase-cards" && placementClicks=1
                cardAt := testNow
        }
    } else {
        bodyClicks += 1,panel := true
        if mode="upgrade" && bodyClicks=1
            cardAt := testNow+30
    }
    return true
}
RegisterPlacedUnit(unit,point) {
    global gPlacements
    item := {slot:unit.slot,x:point.x,y:point.y}
    gPlacements.Push(item)
    return item
}
CandidateOccupied(x,y) {
    global gPlacements
    for p in gPlacements
        if p.x=x && p.y=y
            return true
    return false
}
CloseUnitPanel() {
    if HasUnitPanel()
        return ClickAwayFromUnitPanel()
    return true
}
PlacementPanelClosedStable() => !HasCardChoice() && !HasUnitPanel()
ReadUnitUpgradeState(*) {
    ActionPause(100)
    return {level:0,maxed:false}
}
SavePlacementRun(*) => 0
IsEndGameBlocking(*) => false
Log(*) => 0

FailedPlacementSpot(point) {
    global gFailedPlacementSpots,FAILED_PLACEMENT_RADIUS
    terrain := PlacementTerrain(point)
    for rejected in gFailedPlacementSpots
        if rejected.terrain=terrain && (point.x-rejected.x)**2+(point.y-rejected.y)**2<=FAILED_PLACEMENT_RADIUS**2
            return true
    return false
}

RememberFailedPlacementSpot(point) {
    global gFailedPlacementSpots
    if FailedPlacementSpot(point)
        return
    gFailedPlacementSpots.Push({x:point.x,y:point.y,terrain:PlacementTerrain(point)})
    Log("Rejected " PlacementTerrain(point) " spot " point.x "," point.y "; skip for the rest of this game.")
}

ForgetFailedPlacementSpot(point) {
    global gFailedPlacementSpots,FAILED_PLACEMENT_RADIUS
    index := gFailedPlacementSpots.Length,terrain := PlacementTerrain(point)
    while index>=1 {
        rejected := gFailedPlacementSpots[index]
        if rejected.terrain=terrain && (point.x-rejected.x)**2+(point.y-rejected.y)**2<=FAILED_PLACEMENT_RADIUS**2
            gFailedPlacementSpots.RemoveAt(index)
        index -= 1
    }
}

PlacementTerrain(point) => point.HasProp("hill") && point.hill?"hill":"ground"

ResetFiniteUpgradeGuard(item) {
    item.upgradeInputCount := 0,item.upgradeInputLimit := -1
    item.lastUpgradeInputLevel := -1,item.lastUpgradeInputAt := 0,item.upgradeWarningAt := 0
}

RefreshRecordedUpgradeTarget(item) {
    global gUnitControls,gUpgradeReadAt,gUpgradeSelectedId
    if !IsSet(gUnitControls) || !IsObject(gUnitControls) || item.slot<1 || item.slot>gUnitControls.Length
        return false
    control := gUnitControls[item.slot]
    if !control.HasProp("target") || !IsInteger(control.target.Value)
        return false
    target := Max(0,Min(99,Integer(control.target.Value)))
    if target=item.target
        return false
    Log("#" item.id " slot " item.slot ": upgrade target changed " item.target " -> " target ".")
    item.target := target,item.complete := target=0 || (target!=99 && item.upgrades>=target)
    ResetFiniteUpgradeGuard(item)
    gUpgradeReadAt := 0
    if item.complete && gUpgradeSelectedId=item.id {
        ClickAwayFromUnitPanel()
        ResetUpgradeSelection()
    }
    SavePlacementRun()
    return true
}

UpgradeWarning(item,message) {
    if !item.HasProp("upgradeWarningAt")
        item.upgradeWarningAt := 0
    if !item.upgradeWarningAt || testNow-item.upgradeWarningAt>=4000 {
        Log("#" item.id " " item.name ": " message)
        item.upgradeWarningAt := testNow
    }
}

UpgradeQueue() {
    global gPlacements
    queue := []
    for item in gPlacements {
        if item.complete
            continue
        at := queue.Length+1
        for index,other in queue {
            if item.priority<other.priority || (item.priority=other.priority && item.id<other.id) {
                at := index
                break
            }
        }
        queue.InsertAt(at,item)
    }
    return queue
}

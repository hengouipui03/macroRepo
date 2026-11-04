
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global testNow := 10000,gRunning := true,REF_W := 800,REF_H := 600
global gPlacements := [],gUnitControls := [],gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0
global gCardAction := "",gCardInterruptEpoch := 0,panel := false,selected := 0
global levels := Map(),presses := 0,ignored := 0,ocrOverride := -1,unreadable := false,ready := true
global opened := [],ocrScale := 0,signatureChanged := false
global gPathLit := false,gPathToggleClicked := false,savedP := false,findCalls := 0,fixedCalls := 0,pClicks := 0,pOn := false,pVisible := true
global gPendingPlacement := 0,gPlacementAttemptClicked := false,spotValid := false,slotSelections := 0,placementClicks := 0
global gPlacementAreaFailures := Map(),gRunViewMoved := false,gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map(),gPlacementProfile := ""
global blockedUnit := 0,gHillPlacementUnavailable := false,schedulerMode := false,stopAt := 0,modelFails := 0,layoutY := 210,hillBlocked := false
global moveCalls := 0,shiftReads := 0,trackingOkay := true,cameraShifts := [{dx:0,dy:30},{dx:0,dy:0}]
global gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0
global relocationSceneOkay := true,rememberOkay := true,scaleMovement := false,lastDuration := 120,lastMovementKey := ""
global gMapModel := 0,gMoveKeys := 0,MAP_GRID := 96,baseRoute := [101,102,103,104]

try {
    a := Unit(1,7),b := Unit(2,2)
    gPlacements := [b,a],levels[1] := 0,levels[2] := 0
    ; Ignored inputs must not exhaust the finite budget before target 7.
    ignored := 3
    Loop 35 {
        UpgradePriorityPass()
        testNow += 1100
    }
    Assert(a.complete && a.upgrades=7 && levels[1]=7,"target 7 did not finish exactly")
    Assert(b.complete && levels[2]=2 && presses=12,"target 7 did not hand off to the next unit")
    Assert(ocrScale=4,"finite UPG OCR was not enlarged")
    Assert(UpgradeQueue().Length=0,"completed numeric targets kept reselecting")

    a := Unit(1,7),gPlacements := [a],levels[1] := 6,presses := 0,ocrOverride := -1
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(levels[1]=7 && presses=1,"UPG 6 did not advance once")
    ocrOverride := 6
    Loop 20 {
        testNow += 1100
        UpgradePriorityPass()
    }
    Assert(presses=1 && !a.complete,"stale OCR overshot the target after glyphs changed")
    ocrOverride := -1,testNow += 11000
    UpgradePriorityPass()
    Assert(a.complete && a.upgrades=7 && presses=1,"fresh UPG 7 did not complete the pending unit")

    a := Unit(1,7),b := Unit(2,1),gPlacements := [a,b],levels[1] := 4,levels[2] := 0
    unreadable := true,presses := 0
    ResetUpgradeSelection()
    Loop 3 {
        UpgradePriorityPass()
        testNow += 1100
    }
    Assert(!a.complete && UpgradeQueue().Length=2,"unreadable target was treated as done")
    unreadable := false
    UpgradePriorityPass()
    Assert(selected=2 && levels[2]=1,"unreadable first unit blocked every other unit")

    a := Unit(1,7),gPlacements := [a],levels[1] := 6,ready := false,presses := 0
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(presses=0 && a.upgradeInputCount=0,"waiting for Yen spent finite input budget")
    ready := true,testNow += 1100
    UpgradePriorityPass()
    testNow += 1100
    UpgradePriorityPass()
    Assert(a.complete && presses=1,"money wait did not resume and stop at target 7")

    a := Unit(1,99),gPlacements := [a],levels[1] := 7,gUnitControls := [{target:{Value:7}}]
    ResetUpgradeSelection(),presses := 0
    UpgradePriorityPass()
    Assert(a.target=7 && a.complete && presses=0,"live MAX-to-7 edit failed to hand off")
    gUnitControls := []

    ; A header changing during OCR cannot authorize an R.
    a := Unit(1,7),gPlacements := [a],levels[1] := 6,signatureChanged := true,presses := 0
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(presses=0,"changing heading was accepted as a fresh stable level")
    signatureChanged := false

    ; P is discovered once; later calls use the exact saved coordinate.
    Assert(EnsurePathLit() && findCalls=1 && pClicks=1,"first P click was not saved/confirmed")
    gPathToggleClicked := false,pOn := false
    Assert(EnsurePathLit() && findCalls=1 && pClicks=2,"saved P coordinate required rediscovery")
    gPathToggleClicked := false,pOn := false,pVisible := false
    Assert(EnsurePathLit() && findCalls=1 && pClicks=3,"missing glyph blocked the static coordinate click")
    Assert(!EnsurePathLit() && pClicks=3,"delayed confirmation toggled P a second time")
    panel := false
    candidate := {x:450,y:400,row:1}
    a.count := 2
    TryPlacementCandidateAction(a,candidate)
    Assert(slotSelections=0 && placementClicks=0,"off-path candidate sent a slot or placement input")
    spotValid := true
    TryPlacementCandidateAction(a,candidate)
    Assert(slotSelections=1 && placementClicks=2,"live path-edge candidate did not probe occupancy before its purchase")

    a := Unit(1,1),b := Unit(2,1),gPlacements := [a,b],levels[1] := 0,levels[2] := 0
    blockedUnit := 1,presses := 0,gPendingPlacement := 0
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(a.upgradeRetryAt>testNow && !a.complete,"unselectable unit was not deferred")
    testNow += 1100
    UpgradePriorityPass()
    Assert(levels[2]=1 && presses=1,"failed unit selection starved the next upgrade")
    blockedUnit := 0

    gPlacements := [],gPendingPlacement := 0,gPlacementAreaFailures := Map(),modelFails := 0
    a.count := 1
    candidates := []
    Loop 12
        candidates.Push({x:450+A_Index,y:320})
    TryPlacementPoints(a,candidates)
    Assert(modelFails=7 && PlacementCopyFailures(a)=7,"seven-copy failure limit allowed an eighth click")
    gPlacements.Push(a)
    Assert(PlacementCopyFailures(a)=0,"success did not reset the next copy's failure count")
    PlacementCopyFailures(a,true)
    Assert(PlacementCopyFailures(b)=0,"failure count leaked into a different slot")

    a.x := 400,a.y := 320,a.selectX := 400,a.selectY := 300
    b.x := 480,b.y := 340,b.selectX := 480,b.selectY := 320
    gPlacements := [a,b],gFailedPlacementSpots := [{x:510,y:350}]
    Assert(PlacementViewCanShift(-40,25) && !PlacementViewCanShift(400,0),"relocation visibility bound failed")
    ShiftRecordedPlacements(-40,25)
    Assert(a.x=360 && a.selectY=325 && b.x=440 && gFailedPlacementSpots[1].x=470,"camera shift did not update recorded/select/rejected coordinates")
    Assert(gRunViewMoved && PlacementCopyFailures(a)=0,"new area did not reset per-copy failures")

    ; Multiple downstream segments; farthest model remains clear and selectable.
    gMapModel := {nodes:Map(),player:{x:10,y:10},baseMarker:{x:20,y:20}},gMoveKeys := {}
    heading := ActualRelocationDirection()
    Assert(heading.x>0 && heading.y=0,"baseward direction ignored the calibrated route on a bend")
    baseRoute := [20],heading := ActualRelocationDirection()
    Assert(heading.x=0 && heading.y=0,"relocation continued past the mapped base")
    gMapModel := 0,heading := ActualRelocationDirection()
    Assert(heading.y>0,"missing minimap calibration reverted to an upward step")
    a.x := 400,a.y := 350,a.selectX := 400,a.selectY := 335
    b.x := 480,b.y := 370,b.selectX := 480,b.selectY := 355
    moveCalls := 0,shiftReads := 0,gPendingPlacement := 0,opened := [],scaleMovement := true
    cameraShifts := [{dx:0,dy:-20}],gPlacementRelocateRetryAt := 0
    Assert(RelocatePlacementArea(a) && moveCalls>=7 && a.y<=210 && b.y<=230,"relocation stopped after one step instead of leaving the old area")
    Assert(lastMovementKey="s" && opened.Length>=moveCalls*2,"downstream movement did not repeatedly check farthest-unit selection")
    Assert(PlacementRelocationRoom(0,0),"substantial movement lost a clear unit click margin")
    a.y := 190,a.selectY := 175,b.y := 240,b.selectY := 225
    moveCalls := 0,shiftReads := 0,gPlacementRelocateRetryAt := 0
    Assert(RelocatePlacementArea(a) && moveCalls=1 && a.selectY>=165 && gRunning,"boundary approach walked until the farthest unit was no longer clear")
    Assert(!PlacementRelocationRoom(0,-8),"boundary fixture did not reserve room before the next movement")
    a.y := 350,a.selectY := 335,b.y := 370,b.selectY := 355
    blockedUnit := 2,moveCalls := 0,gPlacementRelocateRetryAt := 0
    Assert(!RelocatePlacementArea(a) && moveCalls=0 && gRunning,"walking started when the farthest unit could not be selected")
    blockedUnit := 0
    moveCalls := 0,shiftReads := 0,trackingOkay := false,gPlacementRelocateRetryAt := 0
    Assert(RelocatePlacementArea(a) && moveCalls=1 && gRunning,"uncertain view caused retreat or further unchecked walking")
    Assert(!PlacementAnchorKnown(a) && !PlacementAnchorKnown(b) && CountSlotPlacements(a.slot)=1,"uncertain view lost counts or trusted stale anchors")
    Assert(!RelocatePlacementArea(a) && moveCalls=1 && PlacementCopyFailures(a)=0,"uncertain view sent another move or blocked placement")
    c := Unit(3,2),levels[3] := 0,gPlacements.Push(c),presses := 0
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(levels[3]=1 && presses=1,"unverified old anchors blocked current-view upgrades")
    trackingOkay := true,testNow += 3100,shiftReads := 0,cameraShifts := [{dx:0,dy:20}],scaleMovement := false
    Assert(RecoverPlacementView() && PlacementAnchorKnown(a) && a.y=370 && b.y=390 && c.y=350,"late recovery shifted new units or lost earlier anchors")
    gPlacements := [a,b],gPlacementRelocateRetryAt := 0
    relocationSceneOkay := false,moveCalls := 0
    PlacementCopyFailures(a,true)
    Assert(!RelocatePlacementArea(a) && moveCalls=0 && gRunning && PlacementCopyFailures(a)=0,"missing path view blocked placement or sent movement")
    relocationSceneOkay := true,rememberOkay := false,gPlacementRelocateRetryAt := 0
    Assert(!RelocatePlacementArea(a) && moveCalls=0 && gRunning,"unsaved view sent movement or stopped the macro")
    rememberOkay := true
    deadline := gPlacementRelocateRetryAt,testNow += 1000
    RelocatePlacementArea(a)
    Assert(gPlacementRelocateRetryAt=deadline,"retries extended the relocation cooldown forever")
    gRunning := false
    Assert(!RelocatePlacementArea(a) && moveCalls=0,"relocation ignored an explicit stop")
    gRunning := true,gPlacementRelocateRetryAt := 0

    layoutY := 300
    state := ParseUpgradeState([{x:140,y:305,w:60,h:15,text:"UPG [7]"}],WindowGeometry())
    Assert(state.level=7,"learned device-specific panel heading was ignored")
    layoutY := 210

    ; A permanently blocked first placement cannot prevent the next placement
    ; or upgrading an already placed unit.
    a := Unit(1,1),b := Unit(2,1),a.count := 1,b.count := 1,a.enabled := true,b.enabled := true
    gPlacements := [],gPlacementAreaFailures := Map(),schedulerMode := true,stopAt := testNow+5000,presses := 0
    levels[2] := 0
    ResetUpgradeSelection()
    PlaceConfiguredBuildAction([a,b])
    Assert(CountSlotPlacements(2)=1 && levels[2]=1,"blocked placement starved later placement/upgrade")
    schedulerMode := false,gRunning := true
    a.hill := true,hillBlocked := true,gPlacements := [],schedulerMode := true,stopAt := testNow+15000
    result := PlaceConfiguredBuildAction([a])
    Assert(result="stopped" && MissingBuildPlacements([a])!="","temporarily unavailable Hill unit was skipped and build marked complete")
    schedulerMode := false,gRunning := true,hillBlocked := false
    FileAppend "PASS: baseward path direction; 140-pixel multi-pulse relocation; farthest-unit click checks each segment; shortened pulse stops before reserved margin; uncertain view continues placement; exact upgrade targets and guards; no duplicate purchases; cooldown and stop handling.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack,"*"
    ExitApp 1
}

Unit(id,target) {
    return {id:id,slot:id,name:"Unit " id,priority:id,target:target,upgrades:0,complete:false,x:400+id*30,y:350}
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
SavePlacementRun(*) => 0
Log(*) => 0
ClearCardChoice(*) => true
HasCardChoice(*) => false
HasUnitPanel(*) => panel
OpenRecordedUnit(item) {
    global panel,selected,opened
    if blockedUnit=item.id
        return false
    panel := true,selected := item.id,opened.Push(item.id)
    return true
}
ClickAwayFromUnitPanel(*) {
    global panel
    panel := false
    return true
}
ActionPause(ms,*) {
    global testNow,gRunning
    testNow += ms
    if schedulerMode && testNow>=stopAt
        gRunning := false
    return true
}
SendEvent(keys) {
    global presses,ignored,levels
    if keys!="{r down}"
        return
    presses += 1
    if ignored>0
        ignored -= 1
    else
        levels[selected] += 1
}
UnitUpgradeButtonReady(*) => ready
UpgradeHeaderSignature() {
    global testNow
    if signatureChanged {
        testNow += 1
        return "changing-" testNow
    }
    return "gold-level-" levels[selected]
}
WindowGeometry() => {x:100,y:200,cx:108,cy:230,w:1296,h:900,cw:800,ch:600,dpi:96}
ReadOcrRows(x1,y1,x2,y2,words := false,scale := 2) {
    global ocrScale
    ocrScale := Max(ocrScale,scale)
    rows := []
    if !unreadable
        rows.Push({x:145,y:215,w:60,h:16,text:"UPG [" (ocrOverride>=0?ocrOverride:levels[selected]) "]"})
    return rows
}
GetClient(&cx,&cy,&cw,&ch) {
    cx := 108,cy := 230,cw := 800,ch := 600
    return true
}
ReadButtonRecord(*) => savedP
SaveButtonRecord(name,point,*) {
    global savedP
    savedP := point
    return true
}
ButtonPosition(name,&rx,&ry) {
    rx := 710,ry := 18
    return true
}
VisionOk(reply) => reply && reply["status"]="ok"
VisionRequest(command) {
    global findCalls,fixedCalls
    if InStr(command,"toolbar ")=1 {
        findCalls += 1
        return Map("status","ok","p","715,21","on","0")
    }
    if InStr(command,"toolbarfixed ")=1 {
        fixedCalls += 1
        Assert(InStr(command,"715 21"),"saved P coordinate shifted")
        return pVisible?Map("status","ok","on",pOn?"1":"0"):false
    }
    if InStr(command,"placementvalid ")=1
        return Map("status","ok","valid",spotValid?"1":"0")
    if InStr(command,"relocation ")=1
        return Map("status","ok","dx","0","dy","32")
    if command="rememberview"
        return Map("status","ok","saved",rememberOkay?"1":"0")
    if InStr(command,"world ")=1
        return Map("status","ok","path",relocationSceneOkay?"100":"0")
    if InStr(command,"viewshift ")=1 {
        global shiftReads
        shiftReads += 1
        if !trackingOkay
            return false
        shift := cameraShifts[Min(shiftReads,cameraShifts.Length)]
        factor := scaleMovement?lastDuration/120:1
        return Map("status","ok","dx",shift.dx*factor,"dy",shift.dy*factor)
    }
    return Map("status","ok","path","100")
}
ClickRef(x,y) {
    global pClicks,pOn
    Assert(x=715 && y=21,"P click missed the fixed coordinate")
    pClicks += 1,pOn := true
    return true
}
IsEndGameBlocking(*) => false
CloseUnitPanel(*) => true
CancelUnitPreview(*) => true
PlacementPanelClosedStable(*) => true
RememberFailedPlacementSpot(*) => 0
SelectPlacementUnit(*) {
    global slotSelections
    slotSelections += 1
    return true
}
PlacementClickRef(x,y,guard := false,purchase := 0) {
    global placementClicks,gPendingPlacement,gPlacementAttemptClicked
    if purchase {
        if !PlacementPurchaseReady(purchase)
            return false
        gPendingPlacement := purchase,gPlacementAttemptClicked := true
    }
    placementClicks += 1
    return true
}
RecoverPendingPlacement(*) => false
WaitFor(*) => false
WaitForUnitPanel(*) => false
FinishPlacement(*) => true
UnitPanelRegion(name) {
    return name="header"?[137,layoutY,215,layoutY+36]:[145,340,265,395]
}
CountSlotPlacements(slot) {
    count := 0
    for item in gPlacements
        count += item.slot=slot?1:0
    return count
}
UsablePlacementPoint(point) => point
PlacementTerrain(*) => "ground"
TryPlacementCandidate(unit,point) {
    global modelFails,gPlacementAttemptClicked
    modelFails += 1,gPlacementAttemptClicked := true
    PlacementCopyFailures(unit,true)
    return false
}
RegisterPlacementEdgeMiss(*) => []
OppositePlacementPoint(point) => point
CandidateOccupied(*) => false
FailedPlacementSpot(*) => false
BlockedPlacementEdge(*) => false
SamePlacementEdge(*) => false
RefreshPlacementSearch(*) => 0
ResetPlacementArea(*) => 0
TryEndState(*) => false
PlacementRelocationDirection(*) => {x:0,y:1}
VisionRefreshPlayer(*) => true
MapNearest(nodes,x,y) => Round(x)
MapShortestPath(nodes,start,target) {
    Assert(start=10 && target=20,"base route was not requested from the current player position")
    return baseRoute
}
MoveDurations(*) => [{key:"d",ms:120}]
AimPresses(fallback,duration,fx,fy) => [{key:fy>=0?"s":"w",ms:duration}]
HoldKeys(presses) {
    global moveCalls,lastDuration,lastMovementKey
    moveCalls += 1,lastDuration := presses[1].ms,lastMovementKey := presses[1].key
    return true
}
StopMacro(*) {
    global gRunning
    gRunning := false
}
Notify(*) => 0
PlaceUnit(unit) {
    global gPlacements,gHillPlacementUnavailable
    gHillPlacementUnavailable := hillBlocked
    if unit.slot=1
        return false
    gPlacements.Push(unit)
    return true
}

UpgradeQueue(readyOnly := false) {
    global gPlacements,gRunViewMoved
    if readyOnly
        RecoverPlacementView()
    queue := []
    for item in gPlacements {
        if readyOnly && (!PlacementAnchorKnown(item) || (gRunViewMoved && (item.x<50 || item.x>745 || item.y<140 || item.y>475)))
            continue
        if item.complete || (readyOnly && item.HasProp("upgradeRetryAt") && testNow<item.upgradeRetryAt)
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

ResetUpgradeSelection() {
    global gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0
}

ResetFiniteUpgradeGuard(item) {
    item.upgradeInputCount := 0,item.upgradeInputLimit := -1
    item.lastUpgradeInputLevel := -1,item.lastUpgradeInputAt := 0,item.upgradeWarningAt := 0
    item.upgradeRetryAt := 0
    item.lastUpgradeInputSignature := "",item.upgradeUnreadCount := 0
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

UpgradePriorityPass() {
    global gRunning,gPlacements
    for item in gPlacements
        RefreshRecordedUpgradeTarget(item)
    queue := UpgradeQueue(true)
    if gRunning && queue.Length
        UpgradeOnce(queue[1])
}

ParseUpgradeState(rows,geometry) {
    global REF_W,REF_H
    state := {level:-1,maxed:false,x:210,y:368,raw:""}
    heading := UnitPanelRegion("header"),button := UnitPanelRegion("button")
    for row in rows {
        text := NormalizeWords(row.text)
        state.raw .= (state.raw=""?"":" | ") text
        y := (row.y+row.h/2)*REF_H/geometry.ch
        if y>=heading[2]-6 && y<=heading[4]+6 && RegExMatch(text,"\bu\s*p\s*[g69](?:rade)?\s*(?:\[|:|\.|-)?\s*(\d+|o)",&match)
            state.level := match[1]="o"?0:Integer(match[1])
        if y>=heading[2]-6 && y<=heading[4]+6 && RegExMatch(text,"\bupg(?:rade)?\s*max(?:ed)?\b")
            state.maxed := true
        if y>=button[2]-6 && y<=button[4]+6 {
            if RegExMatch(text,"^(?:(?:upgrade|upg)\s+)?max(?:ed)?(?:\s+(?:upgrade|upg|level))?$")
                state.maxed := true
            if RegExMatch(text,"\bupgrade\b") {
                state.x := (row.x+row.w/2)*REF_W/geometry.cw
                state.y := y
            }
        }
    }
    return state
}

ReadUnitUpgradeState(finite := false) {
    geometry := WindowGeometry()
    if !geometry
        return {level:-1,maxed:false,signature:"",canUpgrade:false,x:210,y:368,raw:"window unavailable"}
    ; Keep numbers from damage, cooldown and upgrade cost out of the level OCR.
    before := finite?UpgradeHeaderSignature():""
    header := UnitPanelRegion("header")
    rows := finite?ReadOcrRows(header[1],header[2],header[3],header[4],false,4):ReadOcrRows(0,100,340,520)
    state := ParseUpgradeState(rows,geometry)
    if finite && state.level<0 && !state.maxed {
        ; Windows OCR can drop the bracketed digit at 4x but read it at 2x.
        rows := ReadOcrRows(header[1],header[2],header[3],header[4],false,2)
        state := ParseUpgradeState(rows,geometry)
    }
    state.canUpgrade := !finite || UnitUpgradeButtonReady()
    if finite && (state.level<0 || !state.canUpgrade) {
        full := ParseUpgradeState(ReadOcrRows(0,100,340,520),geometry)
        if state.level<0
            state.level := full.level
        state.maxed := state.maxed || full.maxed
        state.raw .= " | " full.raw
    }
    state.signature := finite?UpgradeHeaderSignature():""
    if finite && (before="" || before!=state.signature)
        state.level := -1,state.signature := ""
    return state
}

DeferUnitUpgrade(item,message) {
    ; Unreadable pending targets remain unfinished and return to their priority.
    item.upgradeRetryAt := testNow+10000
    UpgradeWarning(item,message " Retry in 10 seconds; continue other units.")
    ClickAwayFromUnitPanel()
    ResetUpgradeSelection()
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

UpgradeWarning(item,message) {
    if !item.HasProp("upgradeWarningAt")
        item.upgradeWarningAt := 0
    if !item.upgradeWarningAt || testNow-item.upgradeWarningAt>=4000 {
        Log("#" item.id " " item.name ": " message)
        item.upgradeWarningAt := testNow
    }
}

UpgradeOnceAction(item) {
    global gRunning,gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    RefreshRecordedUpgradeTarget(item)
    if item.complete
        return true
    if !gRunning || !ClearCardChoice()
        return false
    if item.HasProp("upgradeRetryAt") && testNow<item.upgradeRetryAt
        return false
    if !item.HasProp("upgradeInputLimit")
        ResetFiniteUpgradeGuard(item)
    if gUpgradeSelectedId!=item.id || !HasUnitPanel() {
        ResetUpgradeSelection()
        Log("Open upgrade #" item.id " " item.name " | priority " item.priority " | target " item.target " | recorded " item.x "," item.y)
        if !OpenRecordedUnit(item) {
            if gRunning
                return DeferUnitUpgrade(item,"Unit panel did not open; let the other units upgrade.")
            return false
        }
        gUpgradeSelectedId := item.id
    }
    finite := item.target!=99
    wantsInput := !gUpgradeLastRAt || testNow-gUpgradeLastRAt>=1000
    ; Every finite-target R needs its own fresh header read.
    if finite && (!wantsInput || (gUpgradeReadAt && testNow<gUpgradeReadAt))
        return false
    state := 0
    if finite || wantsInput || !gUpgradeReadAt || testNow>=gUpgradeReadAt {
        state := ReadUnitUpgradeState(finite)
        gUpgradeReadAt := testNow+(finite?600:2000)
        if RefreshRecordedUpgradeTarget(item)
            return item.complete
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
            item.upgradeUnreadCount += 1
            if item.upgradeUnreadCount>=3
                return DeferUnitUpgrade(item,"UPG header unreadable; target " item.target " remains pending. No R sent.")
            UpgradeWarning(item,"UPG number unreadable; target " item.target ". No R sent until a level is confirmed.")
            return false
        }
        item.upgradeUnreadCount := 0
        if state.level<item.upgrades {
            UpgradeWarning(item,"stale UPG reading below confirmed " item.upgrades "; no R sent.")
            return false
        }
        if item.lastUpgradeInputLevel>=0 && state.level<=item.lastUpgradeInputLevel {
            if testNow-item.lastUpgradeInputAt<4000
                return false
            ; Retry an ignored R only when both OCR and the actual gold glyphs
            ; still show the same level. Changed glyphs + stale OCR cannot spend
            ; another input, even if the configured target has not been read yet.
            if state.signature="" || state.signature!=item.lastUpgradeInputSignature
                return DeferUnitUpgrade(item,"UPG pixels changed but OCR has not confirmed the new level. No extra R sent.")
            item.upgradeInputCount := Max(0,item.upgradeInputCount-1)
            item.lastUpgradeInputLevel := -1
        }
        available := item.upgradeInputCount+Max(0,item.target-state.level)
        item.upgradeInputLimit := item.upgradeInputLimit<0?available:Min(item.upgradeInputLimit,available)
        if item.upgradeInputCount>=item.upgradeInputLimit {
            return DeferUnitUpgrade(item,"Finite-target input limit reached; waiting for UPG " item.target " confirmation. No extra R sent.")
        }
        if !state.HasProp("canUpgrade") || !state.canUpgrade {
            UpgradeWarning(item,"upgrade button is not affordable/ready; keep this unit selected and wait.")
            return false
        }
        if PressUnitUpgradeKey() {
            item.upgradeInputCount += 1,item.lastUpgradeInputLevel := state.level,item.lastUpgradeInputAt := testNow
            item.lastUpgradeInputSignature := state.signature
            return true
        }
        return false
    }
    if wantsInput
        return PressUnitUpgradeKey()
    return false
}
NormalizeWords(text) {
    for code in [0x2212,0x2010,0x2011,0x2012,0x2013,0x2014,0xFE63,0xFF0D]
        text := StrReplace(text,Chr(code),"-")
    text := Trim(RegExReplace(StrLower(text), "[^a-z0-9%+.-]+", " "))
    text := RegExReplace(text,"\b(?:mogic|maglc)\b","magic")
    text := RegExReplace(text,"\b(?:resistmce|resistarw)\b","resistance")
    return RegExReplace(text,"\bspee\b","speed")
}
EnsurePathLit() {
    global gPathLit,REF_W,REF_H,gPathToggleClicked,gRunning
    if !gRunning
        return false
    gPathLit := false
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    geometry := WindowGeometry()
    if !geometry
        return false
    saved := ReadButtonRecord("PathToggle",geometry)
    if !saved {
        ; Discover once per window profile, then persist the exact coordinate.
        reply := VisionRequest("toolbar " cx " " cy " " cw " " ch)
        if VisionOk(reply) {
            point := StrSplit(reply["p"],",")
            saved := {x:geometry.cx-geometry.x+Number(point[1]),y:geometry.cy-geometry.y+Number(point[2])}
        } else {
            ButtonPosition("PathToggle",&rx,&ry)
            saved := {x:geometry.cx-geometry.x+rx*cw/REF_W,y:geometry.cy-geometry.y+ry*ch/REF_H}
        }
        SaveButtonRecord("PathToggle",saved,geometry,"fixed P coordinate")
    }
    px := saved.x-(geometry.cx-geometry.x),py := saved.y-(geometry.cy-geometry.y)
    command := "toolbarfixed " cx " " cy " " cw " " ch " " px " " py
    reply := VisionRequest(command)
    if VisionOk(reply) && reply["on"]="1" {
        Log("In-game path is already illuminated; leaving P enabled.")
        return gPathLit := true
    }
    if gPathToggleClicked {
        Log("P was already clicked this game; no second toggle will be sent.")
        return false
    }
    Log("Clicking the saved P coordinate once, then waiting for illumination.")
    if !ClickRef(px*REF_W/cw,py*REF_H/ch)
        return false
    gPathToggleClicked := true
    Loop 4 {
        if !ActionPause(700) || !GetClient(&cx,&cy,&cw,&ch)
            return false
        reply := VisionRequest(command)
        if VisionOk(reply) && reply["on"]="1" {
            Log("In-game path is illuminated (P lit).")
            return gPathLit := true
        }
    }
    ; A hidden glyph must not block preparation when the road itself is lit.
    reply := VisionRequest("world " cx " " cy " " cw " " ch)
    if VisionOk(reply) && Number(reply["path"])>0
        return gPathLit := true
    Log("P clicked once; visual confirmation delayed. No second toggle sent.")
    return false
}
PlacementStillBesidePath(candidate) {
    global gPlacements
    ; Hill highlights have their own live terrain check. Ground must remain
    ; close to the road even when its candidate came from an older cached line.
    if candidate.HasProp("hill") && candidate.hill
        return true
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    scene := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(scene) || scene["path"]="0"
        return false
    seeds := ""
    for item in gPlacements {
        if !PlacementAnchorKnown(item)
            continue
        if (item.HasProp("hill") && item.hill) || (item.HasProp("row") && item.row!=1)
            continue
        seeds .= (seeds=""?"":";") item.x "," item.y
    }
    row := candidate.HasProp("row")?candidate.row:1
    reply := VisionRequest("placementvalid " candidate.x " " candidate.y " " row " " (seeds=""?"-":seeds))
    if VisionOk(reply) && reply["valid"]="1"
        return true
    Log("Reject stale/off-path coordinate " candidate.x "," candidate.y "; no placement click sent.")
    RememberFailedPlacementSpot(candidate)
    return false
}
TryPlacementCandidateAction(unit,candidate) {
    global gRunning,gPendingPlacement,gPlacementAttemptClicked
    gPlacementAttemptClicked := false
    before := CountSlotPlacements(unit.slot)
    if !gRunning || before>=unit.count
        return false
    if IsEndGameBlocking()
        return false
    ; Never overwrite an unresolved purchase, even when its panel disappeared.
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    if HasCardChoice() {
        if !ClearCardChoice()
            return false
        if CountSlotPlacements(unit.slot)>before
            return true
    }
    ; A rejected spot leaves the ghost active. Cancel it first so pressing
    ; the same slot cannot toggle placement OFF and select an existing unit.
    if !CloseUnitPanel() || !CancelUnitPreview() || !PlacementPanelClosedStable()
        return false
    if !PlacementStillBesidePath(candidate)
        return false
    ; With Q already sent, this click can only select an existing model.
    ; A panel here proves the spot is occupied; it cannot count as a purchase.
    if TrySelectUnitAt(candidate,250) {
        Log("Existing model at " candidate.x "," candidate.y "; no new unit counted or purchased.")
        RememberFailedPlacementSpot(candidate)
        CloseUnitPanel()
        return false
    }
    if !gRunning || HasCardChoice()
        return false
    if CountSlotPlacements(unit.slot)!=before
        return CountSlotPlacements(unit.slot)>before
    if !SelectPlacementUnit(unit)
        return false
    purchase := candidate.Clone()
    purchase.pendingSlot := unit.slot,purchase.pendingCopy := before+1,purchase.pendingTarget := unit.count
    if !PlacementClickRef(candidate.x,candidate.y,true,purchase)
        return false
    if WaitForUnitPanel(700)
        return FinishPlacement(unit,gPendingPlacement)
    return RecoverPendingPlacement(unit)
}
TrySelectUnitAt(point,timeout := 450,learn := false) {
    global gRunning
    return gRunning && !HasCardChoice() && PlacementClickRef(point.x,point.y,true) && WaitForUnitPanel(timeout,learn)
}
PlacementPurchaseReady(purchase) {
    global gRunning,gPendingPlacement
    count := CountSlotPlacements(purchase.pendingSlot)
    return gRunning && !gPendingPlacement && count<purchase.pendingTarget && count+1=purchase.pendingCopy
}
ActualRelocationDirection() {
    global gMapModel,gMoveKeys,MAP_GRID
    if gMapModel && gMapModel.baseMarker && gMoveKeys && VisionRefreshPlayer(gMapModel.player,8) {
        p := gMapModel.player,base := gMapModel.baseMarker
        route := MapShortestPath(gMapModel.nodes,MapNearest(gMapModel.nodes,p.x,p.y),MapNearest(gMapModel.nodes,base.x,base.y))
        if route.Length<2
            return {x:0,y:0}
        if route.Length>=2 {
            node := route[Min(4,route.Length)]
            presses := MoveDurations(Mod(node,MAP_GRID)-p.x,node//MAP_GRID-p.y,gMoveKeys,120)
            dx := 0,dy := 0
            for press in presses {
                dx += press.key="d"?press.ms:press.key="a"?-press.ms:0
                dy += press.key="s"?press.ms:press.key="w"?-press.ms:0
            }
            if dx*dx+dy*dy>0
                return {x:dx,y:dy}
        }
    }
    return {x:0,y:1}
}
PlacementCopyFailures(unit,add := false) {
    global gPlacementAreaFailures
    copy := CountSlotPlacements(unit.slot)+1
    if !gPlacementAreaFailures.Has(unit.slot) || gPlacementAreaFailures[unit.slot].copy!=copy
        gPlacementAreaFailures[unit.slot] := {copy:copy,misses:0}
    state := gPlacementAreaFailures[unit.slot]
    if add {
        state.misses += 1
        Log(unit.name " copy " copy ": " state.misses "/7 failed clicks in this placement area.")
    }
    return state.misses
}
PlacementAnchorKnown(item) {
    return !item.HasProp("viewPending") || !item.viewPending
}
ContinuePlacementInCurrentView(unit,reason) {
    global gPlacementAreaFailures,gPlacementRelocateRetryAt
    if gPlacementAreaFailures.Has(unit.slot)
        gPlacementAreaFailures.Delete(unit.slot)
    if testNow>=gPlacementRelocateRetryAt
        gPlacementRelocateRetryAt := testNow+15000
    RefreshPlacementSearch()
    Log(reason " Continue placement attempts here; relocation can retry later.")
    return false
}
RecoverPlacementView() {
    global gPlacementViewRecovery,gRunning
    recovery := gPlacementViewRecovery
    if !recovery || !gRunning || testNow<recovery.retryAt
        return !recovery
    recovery.retryAt := testNow+3000
    if HasCardChoice() || IsEndGameBlocking() || !GetClient(&cx,&cy,&cw,&ch)
        return false
    if cw!=recovery.cw || ch!=recovery.ch
        return false
    shift := VisionRequest("viewshift " cx " " cy " " cw " " ch)
    if !VisionOk(shift)
        return false
    dx := Number(shift["dx"]),dy := Number(shift["dy"])
    for item in recovery.items {
        item.x := Round(item.x+dx),item.y := Round(item.y+dy)
        item.selectX := Round(item.selectX+dx),item.selectY := Round(item.selectY+dy)
        item.viewPending := false
    }
    gPlacementViewRecovery := 0
    ResetUpgradeSelection()
    SavePlacementRun()
    Log("Recovered earlier unit positions after relocation; their upgrades can resume.")
    return true
}
PlacementViewCanShift(dx,dy) {
    global gPlacements
    for item in gPlacements {
        if !PlacementAnchorKnown(item)
            continue
        for point in [{x:item.x,y:item.y},{x:item.selectX,y:item.selectY}] {
            if point.x+dx<50 || point.x+dx>745 || point.y+dy<140 || point.y+dy>475
                return false
        }
    }
    return true
}
ShiftRecordedPlacements(dx,dy,newArea := true) {
    global gPlacements,gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses
    global gPlacementAreaFailures,gRunViewMoved,gPlacementProfile
    for item in gPlacements {
        item.x := Round(item.x+dx),item.y := Round(item.y+dy)
        item.selectX := Round(item.selectX+dx),item.selectY := Round(item.selectY+dy)
    }
    for point in gFailedPlacementSpots
        point.x := Round(point.x+dx),point.y := Round(point.y+dy)
    gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
    if newArea
        gPlacementAreaFailures := Map()
    gRunViewMoved := true,gPlacementProfile := ""
    RefreshPlacementSearch()
    ResetUpgradeSelection()
    SavePlacementRun()
}
PlacementFarthestUnit() {
    global gPlacements
    farthest := 0,distance := -1
    for item in gPlacements {
        if !PlacementAnchorKnown(item)
            continue
        d := (item.x-400)**2+(item.y-300)**2
        if d>distance
            farthest := item,distance := d
    }
    return farthest
}
PlacementRelocationRoom(dx,dy) {
    global gPlacements
    for item in gPlacements {
        if !PlacementAnchorKnown(item)
            return false
        for point in [{x:item.x,y:item.y},{x:item.selectX,y:item.selectY}]
            if point.x+dx<80 || point.x+dx>720 || point.y+dy<165 || point.y+dy>445
                return false
    }
    return true
}
CheckRelocationUnit(item) {
    if !item
        return true
    ; Selection only. Confirm a usable model click, then close the panel.
    return OpenRecordedUnit(item) && CloseUnitPanel()
}
RelocatePlacementArea(unit) {
    global gRunning,gPlacements,gPendingPlacement,gFailedPlacementSpots,gCardAction
    global gPlacementViewRecovery,gPlacementRelocateRetryAt,gPlacementAreaFailures
    global gPlacementBlockedEdges,gPlacementEdgeMisses,gRunViewMoved,gPlacementProfile
    if !gRunning || IsEndGameBlocking() || !ClearCardChoice()
        return false
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    if !RecoverPlacementView()
        return ContinuePlacementInCurrentView(unit,"Earlier unit coordinates are still being recovered.")
    if testNow<gPlacementRelocateRetryAt
        return ContinuePlacementInCurrentView(unit,"Relocation is cooling down.")
    if !CloseUnitPanel() || !CancelUnitPreview() || !GetClient(&cx,&cy,&cw,&ch)
        return ContinuePlacementInCurrentView(unit,"The game view is not ready for relocation.")
    previous := gCardAction,gCardAction := "relocating"
    totalX := 0,totalY := 0,speed := 0,reason := "No useful downstream path movement was available."
    try {
        Log("Follow the connected path toward base, aiming to leave this area by 140 pixels; check the farthest unit after every movement segment.")
        Loop 18 {
            if !gRunning || IsEndGameBlocking() || !ClearCardChoice()
                break
            farthest := PlacementFarthestUnit()
            if !PlacementRelocationRoom(0,0) || !CheckRelocationUnit(farthest) {
                reason := "The farthest unit needs its current clear click margin."
                break
            }
            scene := VisionRequest("world " cx " " cy " " cw " " ch)
            if !VisionOk(scene) || scene["path"]="0"
                break
            direction := PlacementRelocationDirection()
            if direction.x*direction.x+direction.y*direction.y<1 {
                reason := "Reached the baseward end of the mapped path."
                break
            }
            next := VisionRequest("relocation " direction.x " " direction.y)
            if !VisionOk(next)
                break
            dx := Number(next["dx"]),dy := Number(next["dy"]),length := Sqrt(dx*dx+dy*dy)
            if length<1
                break
            duration := 120,forecast := Max(16,speed*duration*1.5)
            if !PlacementRelocationRoom(-dx/length*forecast,-dy/length*forecast) {
                duration := 60,forecast := Max(8,forecast/2)
                if !PlacementRelocationRoom(-dx/length*forecast,-dy/length*forecast) {
                    reason := "Stop before the farthest unit reaches the screen or HUD margin."
                    break
                }
            }
            remembered := VisionRequest("rememberview")
            if !VisionOk(remembered) || !remembered.Has("saved") || remembered["saved"]!="1"
                break
            presses := AimPresses([],duration,dx*cw/800,dy*ch/600)
            if !presses.Length
                break
            uninterrupted := HoldKeys(presses)
            if !gRunning
                return false
            ActionPause(250)
            if !gRunning
                return false
            shift := VisionRequest("viewshift " cx " " cy " " cw " " ch)
            if !VisionOk(shift) {
                ; Stop taking further segments until the last view is measured.
                oldItems := gPlacements.Clone()
                for item in oldItems
                    item.viewPending := true
                gPlacementViewRecovery := oldItems.Length?{items:oldItems,cw:cw,ch:ch,retryAt:testNow+1000}:0
                gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
                gPlacementAreaFailures := Map(),gRunViewMoved := true,gPlacementProfile := ""
                gPlacementRelocateRetryAt := testNow+15000
                RefreshPlacementSearch()
                ResetUpgradeSelection()
                SavePlacementRun()
                Log("Pause walking: the farthest unit's position needs recovery. Continue placement here without retreating.")
                return true
            }
            sx := Number(shift["dx"]),sy := Number(shift["dy"])
            ShiftRecordedPlacements(sx,sy)
            totalX += sx,totalY += sy,speed := Sqrt(sx*sx+sy*sy)/duration
            farthest := PlacementFarthestUnit()
            if !PlacementRelocationRoom(0,0) || !CheckRelocationUnit(farthest) {
                reason := "Stop walking to preserve the farthest unit's click visibility."
                break
            }
            distance := Sqrt(totalX*totalX+totalY*totalY)
            Log("Downstream relocation " Round(distance) "/140 pixels; farthest unit " (farthest?"#" farthest.id:"none") " remains selectable.")
            if distance>=140 {
                reason := "Reached the new downstream placement area."
                break
            }
            if speed*duration<2 || !uninterrupted {
                reason := "Movement paused; keep placement running in the current view."
                break
            }
        }
        gPlacementRelocateRetryAt := testNow+15000
        if totalX*totalX+totalY*totalY>=8**2 {
            Log("Relocation finished after " Round(Sqrt(totalX*totalX+totalY*totalY)) " pixels. " reason " Resume placement beside this path section.")
            return true
        }
        return ContinuePlacementInCurrentView(unit,reason)
    } finally gCardAction := previous
}
TryPlacementPoints(unit,points) {
    global gRunning,gPlacementAttemptClicked,gPendingPlacement
    queue := points.Clone(),seen := Map()
    while queue.Length {
        if !gRunning || IsEndGameBlocking()
            return false
        if PlacementCopyFailures(unit)>=7
            return false
        if gPendingPlacement
            return RecoverPendingPlacement(unit)
        if CountSlotPlacements(unit.slot)>=unit.count
            return false
        point := UsablePlacementPoint(queue.RemoveAt(1))
        if !point
            continue
        key := PlacementTerrain(point) ":" Round(point.x) "," Round(point.y)
        if seen.Has(key)
            continue
        seen[key] := true
        if TryPlacementCandidate(unit,point)
            return true
        if !gPlacementAttemptClicked
            continue
        misses := RegisterPlacementEdgeMiss(point)
        if !misses.Length
            continue
        Log(unit.name ": 3 failed placement clicks on this edge. Block this section for this game; switch to the opposite side now.")
        alternates := []
        for attempted in misses {
            if attempted.HasProp("other") {
                other := OppositePlacementPoint(attempted)
                if !CandidateOccupied(other.x,other.y) && !FailedPlacementSpot(other) && !BlockedPlacementEdge(other)
                    alternates.Push(other)
            }
        }
        ; If the first three opposite spots also fail, use a later position
        ; on the other face BEFORE extending the current failed face again.
        for queued in queue {
            options := [queued]
            if queued.HasProp("other")
                options.Push(OppositePlacementPoint(queued))
            for other in options {
                if !SamePlacementEdge(misses[1],other) && !CandidateOccupied(other.x,other.y)
                    && !FailedPlacementSpot(other) && !BlockedPlacementEdge(other)
                    alternates.Push(other)
            }
        }
        if !alternates.Length {
            Log(unit.name ": opposite side has no usable visible spot; rescan another path edge before any further placement click.")
            return false
        }
        ; Prepend opposite-side positions BEFORE any fourth original-side click.
        Loop alternates.Length
            queue.InsertAt(1,alternates[alternates.Length-A_Index+1])
    }
    return false
}
PlaceConfiguredBuildAction(plan) {
    global gRunning,gHillPlacementUnavailable
    retryAt := Map(),pendingLogAt := 0
    while gRunning {
        for unit in plan {
            if !unit.enabled
                continue
            while gRunning && CountSlotPlacements(unit.slot)<unit.count {
                if retryAt.Has(unit.slot) && testNow<retryAt[unit.slot]
                    break
                if TryEndState()
                    return "replay"
                before := CountSlotPlacements(unit.slot)
                if PlacementCopyFailures(unit)>=7 {
                    if RelocatePlacementArea(unit)
                        continue
                    retryAt[unit.slot] := testNow+10000
                    break
                }
                Log("Place slot " unit.slot " copy " (before+1) "/" unit.count "; confirmed " before "/" unit.count)
                placed := PlaceUnit(unit)
                after := CountSlotPlacements(unit.slot)
                if placed && after=before+1 {
                    Log("Confirmed slot " unit.slot ": " after "/" unit.count " placements.")
                    continue
                }
                if !gRunning
                    return "stopped"
                if gHillPlacementUnavailable && unit.HasProp("hill") && unit.hill {
                    retryAt[unit.slot] := testNow+10000
                    Log(unit.name ": Hill placement still pending; retry in 10 seconds.")
                    break
                }
                if PlacementCopyFailures(unit)>=7 && RelocatePlacementArea(unit)
                    continue
                retryAt[unit.slot] := testNow+10000
                Log(unit.name ": placement pending; retry in 10 seconds while other placements/upgrades continue.")
                RefreshPlacementSearch()
                break
            }
        }
        if !gRunning
            return "stopped"
        missing := MissingBuildPlacements(plan)
        if missing=""
            return "complete"
        if !pendingLogAt || testNow>=pendingLogAt {
            Notify("Placement pending: " missing ". Upgrades run between placement retries.")
            pendingLogAt := testNow+10000
        }
        if TryEndState()
            return "replay"
        UpgradePriorityPass()
        ActionPause(250)
    }
    return "stopped"
}
MissingBuildPlacements(plan) {
    missing := ""
    for unit in plan {
        count := CountSlotPlacements(unit.slot)
        if unit.enabled && count<unit.count
            missing .= (missing=""?"":"; ") "slot " unit.slot " " count "/" unit.count
    }
    return missing
}
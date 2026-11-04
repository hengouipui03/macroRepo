"""Run current AHK upgrade/toolbar logic with simulated OCR, time and input.

Generated fixtures never capture the screen or send game input.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent
RUNTIME = Path(r"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe")


def function(file, name):
    source = (ROOT / file).read_text(encoding="utf-8-sig")
    match = re.search(r"^" + re.escape(name) + r"\([^\n]*\) \{\n.*?^\}", source, re.M | re.S)
    assert match, name
    return match[0]


names = ["UpgradeQueue", "ResetUpgradeSelection", "ResetFiniteUpgradeGuard",
         "RefreshRecordedUpgradeTarget", "UpgradePriorityPass", "ParseUpgradeState",
         "ReadUnitUpgradeState", "DeferUnitUpgrade", "PressUnitUpgradeKey",
         "UpgradeOnce", "UpgradeWarning", "UpgradeOnceAction"]
logic = "\n\n".join(function("PlacedUnits.ahk", name) for name in names)
logic += "\n" + function("Learning.ahk", "NormalizeWords")
logic += "\n" + function("MapNavigation.ahk", "EnsurePathLit")
logic += "\n" + function("Placement.ahk", "PlacementStillBesidePath")
logic += "\n" + function("Placement.ahk", "TryPlacementCandidateAction")
logic += "\n" + function("Placement.ahk", "TrySelectUnitAt")
logic += "\n" + function("Placement.ahk", "PlacementPurchaseReady")
logic += "\n" + function("PlacementArea.ahk", "PlacementRelocationDirection").replace('PlacementRelocationDirection(', 'ActualRelocationDirection(', 1)
for name in ["PlacementFailureLimitReached", "ResetPlacementFailureStreak", "RecordFailedPlacement", "RetryFinalCheckpointPlacement", "PlacementCopyFailures", "PlacementAnchorKnown", "ContinuePlacementInCurrentView", "RecoverPlacementView", "PlacementViewCanShift", "ShiftRecordedPlacements", "PlacementFarthestUnit", "PlacementRelocationRoom", "CheckRelocationUnit", "RelocatePlacementArea"]:
    logic += "\n" + function("PlacementArea.ahk", name)
logic += "\n" + function("Placement.ahk", "TryPlacementPoints")
logic += "\n" + function("Placement.ahk", "PlaceConfiguredBuildAction")
logic += "\n" + function("Placement.ahk", "MissingBuildPlacements")
logic = logic.replace("A_TickCount", "testNow")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global testNow := 10000,gRunning := true,REF_W := 800,REF_H := 600
global ACTION_HOLD_MS := 300,gPrepDeadline := 0,gNavigationTimedOut := false,navReached := true,endState := false
global gPlacements := [],gUnitControls := [],gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0
global gCardAction := "",gCardInterruptEpoch := 0,panel := false,selected := 0
global levels := Map(),presses := 0,ignored := 0,ocrOverride := -1,unreadable := false,ready := true
global opened := [],ocrScale := 0,signatureChanged := false
global gPathLit := false,gPathToggleClicked := false,savedP := false,findCalls := 0,fixedCalls := 0,pClicks := 0,pOn := false,pVisible := true
global gPendingPlacement := 0,gPlacementAttemptClicked := false,spotValid := false,slotSelections := 0,placementClicks := 0
global gPlacementAreaFailures := Map(),gRunViewMoved := false,gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map(),gPlacementProfile := ""
global blockedUnit := 0,gHillPlacementUnavailable := false,schedulerMode := false,stopAt := 0,modelFails := 0,layoutY := 210,hillBlocked := false
global moveCalls := 0,shiftReads := 0,trackingOkay := true,cameraShifts := [{dx:0,dy:30},{dx:0,dy:0}]
global gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0,PLACEMENT_FAILURE_LIMIT := 5,gConsecutivePlacementFailures := 0
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
    ; A missed selection is retried at the same priority twice before deferral.
    UpgradePriorityPass()
    Assert(!a.upgradeRetryAt && !a.complete && presses=0,"one missed selection skipped the top-priority unit")
    UpgradePriorityPass()
    UpgradePriorityPass()
    Assert(a.upgradeRetryAt>testNow && !a.complete,"unselectable unit was not deferred")
    testNow += 1100
    UpgradePriorityPass()
    Assert(levels[2]=1 && presses=1,"failed unit selection starved the next upgrade")
    blockedUnit := 0

    gPlacements := [],gPendingPlacement := 0,gPlacementAreaFailures := Map(),modelFails := 0
    a.count := 1
    ResetPlacementFailureStreak()
    candidates := []
    Loop 12
        candidates.Push({x:450+A_Index,y:320})
    TryPlacementPoints(a,candidates)
    Assert(modelFails=5 && PlacementFailureLimitReached(),"five consecutive failures allowed a sixth placement attempt")
    gPlacements.Push(a)
    ResetPlacementFailureStreak()
    Assert(PlacementCopyFailures(a)=0,"success did not reset the next copy's failure count")
    PlacementCopyFailures(a,true)
    Assert(PlacementCopyFailures(b)=0,"failure count leaked into a different slot")

    ResetPlacementFailureStreak()
    Loop 2
        PlacementCopyFailures(a,true)
    Loop 3
        PlacementCopyFailures(b,true)
    Assert(PlacementFailureLimitReached(),"switching slots reset consecutive placement failures")
    ContinuePlacementInCurrentView(a,"Simulate a declined relocation.")
    Assert(PlacementFailureLimitReached(),"declined relocation silently reset the five-failure trigger")
    ResetPlacementFailureStreak()
    gPlacementRelocateRetryAt := 0

    a.x := 400,a.y := 320,a.selectX := 400,a.selectY := 300
    b.x := 480,b.y := 340,b.selectX := 480,b.selectY := 320
    gPlacements := [a,b],gFailedPlacementSpots := [{x:510,y:350}]
    Assert(PlacementViewCanShift(-40,25) && !PlacementViewCanShift(400,0),"relocation visibility bound failed")
    ShiftRecordedPlacements(-40,25)
    Assert(a.x=360 && a.selectY=325 && b.x=440 && gFailedPlacementSpots[1].x=470,"camera shift did not update recorded/select/rejected coordinates")
    Assert(gRunViewMoved && PlacementCopyFailures(a)=0,"new area did not reset per-copy failures")

    ; Five misses advance only to the next quarter-path checkpoint.
    gMapModel := {checkpoints:[1010,1020,1030],checkpointIndex:1,target:1010},moveCalls := 0
    ResetPlacementFailureStreak()
    Loop 5
        PlacementCopyFailures(a,true)
    Assert(RelocatePlacementArea(a) && gMapModel.checkpointIndex=2 && gMapModel.target=1020 && moveCalls=1,"five failures did not reach checkpoint 2")
    Assert(!PlacementAnchorKnown(a) && CountSlotPlacements(a.slot)=1,"checkpoint movement lost earlier purchase counts")
    a.complete := false,a.upgradeRetryAt := 0,b.complete := false,b.upgradeRetryAt := 0
    Assert(UpgradeQueue(true).Length=2,"manager upgrades still depended on old world coordinates")
    Loop 5
        PlacementCopyFailures(a,true)
    Assert(RelocatePlacementArea(a) && gMapModel.checkpointIndex=3 && gMapModel.target=1030,"five failures did not reach checkpoint 3")
    Loop 5
        PlacementCopyFailures(a,true)
    Assert(!PlacementFailureLimitReached(),"checkpoint 3 blocked continuing placement")
    beforeMoves := moveCalls
    Assert(!RelocatePlacementArea(a) && moveCalls=beforeMoves && gRunning,"final checkpoint relocated again or stopped")
    gMapModel.checkpointIndex := 1,navReached := false
    Loop 5
        PlacementCopyFailures(a,true)
    Assert(!RelocatePlacementArea(a) && gMapModel.checkpointIndex=1 && gMapModel.target=1020 && gRunning,"failed checkpoint travel advanced the index or stopped the macro")
    navReached := true,gMapModel.checkpointIndex := 0
    ResetPlacementFailureStreak()
    Assert(PlacementFailureLimitReached() && RelocatePlacementArea(a) && gMapModel.checkpointIndex=1,"placement started before reaching the first checkpoint")
    gRunning := false,beforeMoves := moveCalls
    Assert(!RelocatePlacementArea(a) && moveCalls=beforeMoves,"checkpoint travel ignored explicit stop")
    gRunning := true,gMapModel := 0
    ResetPlacementFailureStreak()

    gMapModel := {checkpointIndex:3,checkpoints:[1010,1020,1030]},gConsecutivePlacementFailures := 5,gPlacements := []
    b.count := 2,b.enabled := true,beforeMoves := moveCalls
    Assert(PlaceConfiguredBuildAction([b])="complete" && CountSlotPlacements(2)=2 && moveCalls=beforeMoves,"final checkpoint did not continue until all placements were down")
    gPlacements := [],endState := true
    Assert(PlaceConfiguredBuildAction([b])="replay" && gPlacements.Length=0,"final checkpoint ignored the end-game handler")
    endState := false,gMapModel := 0
    ResetPlacementFailureStreak()

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
    Assert(CountSlotPlacements(2)=1 && levels[2]=0,"blocked placement starved later placement, or upgrades/F started before every unit was placed")
    schedulerMode := false,gRunning := true
    a.hill := true,hillBlocked := true,gPlacements := [],schedulerMode := true,stopAt := testNow+15000
    result := PlaceConfiguredBuildAction([a])
    Assert(result="stopped" && MissingBuildPlacements([a])!="","temporarily unavailable Hill unit was skipped and build marked complete")
    schedulerMode := false,gRunning := true,hillBlocked := false
    FileAppend "PASS: checkpoint 1 then 2 then 3 after five misses; final checkpoint keeps placing; failed travel retains destination; old coordinates do not block manager upgrades; exact upgrade targets/input guards; no duplicate purchases; stop handling.`n","*"
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
BeginInputAction(*) => true
EndInputAction(*) => 0
Log(*) => 0
ClearCardChoice(*) => true
SaveUpgradeDiagnostic(*) => 0
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
ClickRef(x,y,stillValid := 0) {
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
RefreshMapPlayer(*) => true
NavigateDrawing(*) {
    global moveCalls
    moveCalls += 1
    return navReached
}
RefreshPlacementSearch(*) => 0
ResetPlacementArea(*) => 0
TryEndState(*) => endState
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
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "upgrade-priority-regression.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=30)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

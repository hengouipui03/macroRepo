"""Run current AHK upgrade/toolbar logic with simulated OCR, time and input.

Generated fixtures never capture the screen or send game input.
"""
from pathlib import Path
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parent
# AHK_RUNTIME overrides the interpreter (e.g. a wine wrapper off Windows).
RUNTIME = Path(os.environ.get("AHK_RUNTIME", r"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"))


def function(file, name):
    source = (ROOT / file).read_text(encoding="utf-8-sig")
    match = re.search(r"^" + re.escape(name) + r"\([^\n]*\) \{\n.*?^\}", source, re.M | re.S)
    assert match, name
    return match[0]


names = ["UpgradeQueue", "ResetUpgradeSelection", "ResetUpgradeTracking",
         "RefreshRecordedUpgradeTarget", "UpgradePriorityPass", "DeferUnitUpgrade",
         "UpgradeOnce", "UpgradeWarning", "PortraitDistance", "SlotDisplayName",
         "TileIdentityMismatch", "StableTileRead", "UpgradeOnceAction"]
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
global gPlacements := [],gUnitControls := [],gUpgradeSelectedId := 0,gUnitManagerFailure := "",gSlotPortraits := Map()
global gCardAction := "",gCardInterruptEpoch := 0,panel := false,selected := 0
global levels := Map(),maxed := Map(),sigs := Map(),pendingLevel := Map(),clicks := 0,ignored := 0,unreadable := 0,ready := true,dimmed := 0
global placeTries := 0,lagMs := 0,opened := [],flashLevel := Map(),warnings := 0
global gPathLit := false,gPathToggleClicked := false,savedP := false,findCalls := 0,fixedCalls := 0,pClicks := 0,pOn := false,pVisible := true,pIgnoreClicks := 0,gPathReadGaveUp := false
global PATH_TOGGLE_CLICKS := 3,PATH_TOGGLE_CHANGE := 25
global gPendingPlacement := 0,gPlacementAttemptClicked := false,spotValid := false,slotSelections := 0,placementClicks := 0
global gPlacementAreaFailures := Map(),gRunViewMoved := false,gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map(),gPlacementProfile := ""
global blockedUnit := 0,gHillPlacementUnavailable := false,schedulerMode := false,stopAt := 0,modelFails := 0,hillBlocked := false
global moveCalls := 0,shiftReads := 0,trackingOkay := true,cameraShifts := [{dx:0,dy:30},{dx:0,dy:0}]
global gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0,PLACEMENT_FAILURE_LIMIT := 5,gConsecutivePlacementFailures := 0
global relocationSceneOkay := true,rememberOkay := true,scaleMovement := false,lastDuration := 120,lastMovementKey := ""
global gMapModel := 0,gMoveKeys := 0,MAP_GRID := 96,baseRoute := [101,102,103,104]
global navWalkMs := 0,RELOCATION_TELEPORT_MS := 20000,gRelocationWalkMs := 0,gRelocationWalkTarget := 0,gRelocationTeleports := 0,gMovementCardTotalMs := 0,teleports := 0

try {
    ; Tile upgrades: one Upg click per new lit segment, exact finite targets,
    ; ignored clicks never exhaust anything.
    a := Unit(1,7),b := Unit(2,2)
    gPlacements := [b,a],levels[1] := 0,levels[2] := 0,ignored := 3
    Loop 40 {
        UpgradePriorityPass()
        testNow += 700
    }
    Assert(a.complete && a.upgrades=7 && levels[1]=7,"target 7 did not finish exactly")
    Assert(b.complete && levels[2]=2 && clicks=12,"target 7 did not hand off to the next unit (" clicks " clicks)")
    Assert(UpgradeQueue().Length=0,"completed numeric targets kept reselecting")

    ; A slow segment update never lets a second click overshoot a finite target.
    a := Unit(1,7),gPlacements := [a],levels[1] := 6,clicks := 0,lagMs := 1500
    ResetUpgradeSelection()
    Loop 6 {
        UpgradePriorityPass()
        testNow += 400
    }
    Assert(a.complete && levels[1]=7 && clicks=1,"slow segment update allowed an overshoot (" clicks " clicks)")
    lagMs := 0

    ; Strict priority: an unreadable top unit pauses 2 s and is read again; a
    ; lower priority is never upgraded meanwhile.
    a := Unit(1,7),b := Unit(2,1),gPlacements := [a,b],levels[1] := 4,levels[2] := 0,unreadable := 1,clicks := 0
    ResetUpgradeSelection()
    Loop 3 {
        UpgradePriorityPass()
        testNow += 700
    }
    Assert(!a.complete && a.upgradeRetryAt>testNow && clicks=0,"unreadable bar was clicked or not paused")
    Loop 5 {
        UpgradePriorityPass()
        testNow += 700
    }
    Assert(levels[2]=0 && clicks=0,"a lower priority was upgraded while the top unit was unfinished")
    Assert(a.deferCount=2 && a.upgradeRetryAt-testNow<=2000,"stuck top unit backed off instead of re-reading itself")
    unreadable := 0

    ; Waiting for Yen keeps clicking at the same priority, then stops at target.
    a := Unit(1,7),gPlacements := [a],levels[1] := 6,ready := false,clicks := 0
    ResetUpgradeSelection()
    Loop 5 {
        UpgradePriorityPass()
        testNow += 2100
    }
    Assert(!a.complete && !a.upgradeRetryAt && levels[1]=6 && clicks>=3,"waiting for Yen deferred the unit or stopped clicking")
    ready := true
    Loop 3 {
        UpgradePriorityPass()
        testNow += 2100
    }
    Assert(a.complete && levels[1]=7,"money wait did not resume and stop at target 7")

    ; A dimmed Upg button (not enough Yen) waits on the same unit: no click and
    ; no pause, even with an unreadable bar; a lit button resumes upgrading.
    a := Unit(1,7),b := Unit(2,1),gPlacements := [a,b],levels[1] := 4,levels[2] := 0,dimmed := 1,unreadable := 1,clicks := 0
    ResetUpgradeSelection()
    Loop 6 {
        UpgradePriorityPass()
        testNow += 700
    }
    Assert(clicks=0 && !a.upgradeRetryAt && levels[2]=0,"dimmed Upg button was clicked, paused the unit, or let a lower priority upgrade")
    dimmed := 0,unreadable := 0
    Loop 3 {
        UpgradePriorityPass()
        testNow += 2100
    }
    Assert(clicks>=1 && levels[1]>4 && levels[2]=0,"lit Upg button did not resume the top unit")

    a := Unit(1,99),gPlacements := [a],levels[1] := 7,gUnitControls := [{target:{Value:7}}]
    ResetUpgradeSelection(),clicks := 0
    Loop 2 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(a.target=7 && a.complete && clicks=0,"live MAX-to-7 edit failed to hand off")
    gUnitControls := []

    ; MAX target: keep clicking like R while short of Yen; no counter, no deferral.
    a := Unit(1,99),gPlacements := [a],levels[1] := 2,ready := false,clicks := 0,warnings := 0
    ResetUpgradeSelection()
    Loop 30 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(clicks>=25 && !a.upgradeRetryAt && !a.complete && warnings=0,"MAX target stopped, deferred or warned while waiting for Yen (" clicks " clicks)")
    ready := true
    Loop 30 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(levels[1]=8 && !a.complete,"MAX target did not keep upgrading once Yen arrived")

    ; Grey Max with a full bar completes without a click (after a second look).
    a := Unit(1,99),gPlacements := [a],levels[1] := 8,maxed[1] := true,clicks := 0
    Loop 4 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(a.complete && clicks=0,"grey Max tile with a full bar was clicked or not completed")
    ; Grey Max over 5 of 8 lit (manager still opening) is not MAX and is not clicked.
    a := Unit(1,99),gPlacements := [a],levels[1] := 5,maxed[1] := true,clicks := 0
    Loop 6 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(!a.complete && clicks=0,"a passing grey frame at 5 of 8 ended the MAX target")
    maxed[1] := false
    Loop 3 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(!a.complete && clicks>=1,"upgrading did not resume after the passing grey frame")
    ; A grey Max that stays for 4 s is believed even if the bar disagrees.
    a := Unit(1,99),gPlacements := [a],levels[1] := 5,maxed[1] := true,clicks := 0
    Loop 16 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(a.complete && clicks=0,"a lasting Max button was never believed")
    ; Unreadable bar with a grey Max: MAX after a second look.
    a := Unit(1,99),gPlacements := [a],levels[1] := 3,unreadable := 1,clicks := 0
    Loop 3 {
        UpgradePriorityPass()
        testNow += 300
    }
    Assert(a.complete && clicks=0,"unreadable bar with a grey Max was not MAX")
    maxed[1] := false,unreadable := 0
    ; Unreadable bar on a MAX target is still clicked (no overshoot possible).
    a := Unit(1,99),gPlacements := [a],levels[1] := 3,unreadable := 1,clicks := 0
    UpgradePriorityPass()
    Assert(clicks=1 && !a.upgradeRetryAt,"unreadable bar stopped a MAX target")
    unreadable := 0

    ; One wrong frame after the manager reopens cannot finish a finite target.
    a := Unit(1,5),gPlacements := [a],levels[1] := 3,a.upgrades := 3,clicks := 0,flashLevel[1] := 5
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(!a.complete && clicks=0,"a single frame showing 5 completed target 5")
    Loop 12 {
        UpgradePriorityPass()
        testNow += 700
    }
    Assert(a.complete && levels[1]=5 && a.upgrades=5,"target 5 did not finish after the wrong frame")

    ; A tile whose portrait clearly belongs to another unit is never clicked;
    ; a look-alike that is merely a little off still upgrades.
    a := Unit(1,99),b := Unit(2,99),gPlacements := [a,b],levels[1] := 0,levels[2] := 0,clicks := 0
    gSlotPortraits := Map(1,"80.0.0.0.0.0.0.0.0.0.10.10.0.0",2,"0.0.0.0.80.0.0.0.0.0.10.10.0.0")
    sigs[1] := "0.0.0.0.78.0.0.0.0.0.11.11.0.0"
    UpgradePriorityPass()
    Assert(clicks=0 && a.upgradeRetryAt>testNow,"a tile showing another unit was clicked")
    a.upgradeRetryAt := 0,sigs[1] := "70.0.0.0.6.0.0.0.0.0.12.12.0.0"
    UpgradePriorityPass()
    Assert(clicks=1,"a slightly different portrait of the right unit was refused")
    sigs := Map(),gSlotPortraits := Map()

    ; P must end up ON (lit path first, red overlay as fallback). Discovered
    ; once; later calls use the exact saved coordinate. Never stops the macro.
    Assert(EnsurePathLit() && findCalls=1 && pClicks=1 && pOn && gPathLit,"dim P was not lit with one saved click")
    gPathToggleClicked := false,gPathLit := false
    Assert(EnsurePathLit() && findCalls=1 && pClicks=1 && gPathLit,"P already on was clicked, or its coordinate rediscovered")
    gPathToggleClicked := true,pOn := false,gPathLit := false
    Assert(EnsurePathLit() && pClicks=1 && !gPathLit,"P was toggled a second time in one game")
    gPathToggleClicked := false,pVisible := false
    Assert(EnsurePathLit() && pClicks=1,"an unreadable P button was clicked")
    ; A click that leaves the P glyph unchanged did not register: click again.
    pVisible := true,pOn := false,gPathLit := false,pIgnoreClicks := 1
    Assert(EnsurePathLit() && pClicks=3 && pOn && gPathLit,"an unregistered P click was not retried")
    pVisible := true,pOn := false
    panel := false
    candidate := {x:450,y:400,row:1}
    a.count := 2
    TryPlacementCandidateAction(a,candidate)
    Assert(slotSelections=0 && placementClicks=0,"off-path candidate sent a slot or placement input")
    spotValid := true
    TryPlacementCandidateAction(a,candidate)
    Assert(slotSelections=1 && placementClicks=2,"live path-edge candidate did not probe occupancy before its purchase")

    a := Unit(1,1),b := Unit(2,1),gPlacements := [a,b],levels[1] := 0,levels[2] := 0
    blockedUnit := 1,clicks := 0,gPendingPlacement := 0
    ResetUpgradeSelection()
    ; A missed tile lookup is retried at the same priority twice before deferral.
    UpgradePriorityPass()
    Assert(!a.upgradeRetryAt && !a.complete && clicks=0,"one missed lookup skipped the top-priority unit")
    UpgradePriorityPass()
    UpgradePriorityPass()
    Assert(a.upgradeRetryAt>testNow && !a.complete,"unfindable unit was not deferred")
    testNow += 1100
    UpgradePriorityPass()
    Assert(levels[2]=0 && clicks=0,"failed lookup let a lower priority upgrade first")
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
    Assert(UpgradeQueue().Length=2,"manager upgrades still depended on old world coordinates")
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
    ; 20 s of relocation walking without arrival teleports back to spawn, then walks again.
    beforeMoves := moveCalls,teleports := 0,navWalkMs := 21000
    Loop 5
        PlacementCopyFailures(a,true)
    Assert(!RelocatePlacementArea(a) && teleports=1 && moveCalls=beforeMoves+2,"20 s of failed relocation walking did not teleport to spawn and resume")
    navWalkMs := 0
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

    ; Build order is kept: a unit that is not placed yet is retried before any
    ; later unit, and nothing is upgraded meanwhile.
    a := Unit(1,1),b := Unit(2,1),a.count := 1,b.count := 1,a.enabled := true,b.enabled := true
    gPlacements := [],gPlacementAreaFailures := Map(),schedulerMode := true,stopAt := testNow+5000,clicks := 0
    levels[2] := 0,placeTries := 0
    ResetUpgradeSelection()
    PlaceConfiguredBuildAction([a,b])
    Assert(CountSlotPlacements(2)=0 && levels[2]=0 && placeTries>=10,"a later unit was placed before the pending first unit, or upgrades started (" placeTries " tries)")
    schedulerMode := false,gRunning := true
    ; A Hill-only unit with no Hill space is the one exception: later units go first.
    a.hill := true,hillBlocked := true,gPlacements := [],schedulerMode := true,stopAt := testNow+5000
    PlaceConfiguredBuildAction([a,b])
    Assert(CountSlotPlacements(2)=1 && CountSlotPlacements(1)=0,"Hill-only unit without Hill space blocked the next unit")
    schedulerMode := false,gRunning := true,hillBlocked := false,a.hill := false
    a.hill := true,hillBlocked := true,gPlacements := [],schedulerMode := true,stopAt := testNow+15000
    result := PlaceConfiguredBuildAction([a])
    Assert(result="stopped" && MissingBuildPlacements([a])!="","temporarily unavailable Hill unit was skipped and build marked complete")
    schedulerMode := false,gRunning := true,hillBlocked := false
    FileAppend "PASS: checkpoint 1 then 2 then 3 after five misses; final checkpoint keeps placing; failed travel retains destination; old coordinates do not block manager upgrades; tile upgrades: exact targets, slow bars, Yen waits, grey Max, wrong-portrait refusal, MAX targets keep clicking without a counter, a passing grey frame or one wrong level never completes a unit, escalating back-off; build order kept (same unit retried; only Hill-only without Hill lets later units go first); no duplicate purchases; stop handling.`n","*"
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
Log(message,*) {
    global warnings
    if InStr(message,"Upg click") || InStr(message,"Retry in")
        warnings += 1
}
ClearCardChoice(*) => true
SaveUpgradeDiagnostic(*) => 0
PlacementShortOfYen(*) => false
WaitForPlacementYen(*) => false
TeleportBackToSpawn(*) {
    global teleports
    teleports += 1
    return true
}
ProbePlayer(*) => true
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
LocateManagedUnit(id) {
    global gUnitManagerFailure,pendingLevel,levels
    if blockedUnit=id {
        gUnitManagerFailure := "scroll"
        return false
    }
    if pendingLevel.Has(id) && testNow>=pendingLevel[id] {
        levels[id] += 1
        pendingLevel.Delete(id)
    }
    filled := unreadable=id?-1:levels[id]
    if flashLevel.Has(id)
        filled := flashLevel[id],flashLevel.Delete(id)
    entry := {id:id,column:1,x:600,y:200,row:180,filled:filled,total:unreadable=id?-1:8,
        maxed:maxed.Has(id) && maxed[id],ux:700,uy:190,sig:sigs.Has(id)?sigs[id]:"",afford:dimmed=id?0:-1}
    return {state:Map(),entry:entry}
}
ClickTileUpgrade(entry) {
    global clicks,ignored,pendingLevel,levels
    clicks += 1
    if ignored>0 {
        ignored -= 1
        return true
    }
    if !ready || pendingLevel.Has(entry.id) || levels[entry.id]>=8
        return true
    if lagMs
        pendingLevel[entry.id] := testNow+lagMs
    else
        levels[entry.id] += 1
    return true
}
ForgetManagerTile(*) => 0
WindowGeometry() => {x:100,y:200,cx:108,cy:230,w:1296,h:900,cw:800,ch:600,dpi:96}
ReadOcrRows(*) => []
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
        return pVisible?Map("status","ok","on",pOn?"1":"0","levels",pOn?"230,85":"80,85"):false
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
    global pClicks,pOn,pIgnoreClicks
    Assert(x=715 && y=21,"P click missed the fixed coordinate")
    pClicks += 1
    if pIgnoreClicks>0
        pIgnoreClicks -= 1
    else
        pOn := !pOn
    return true
}
IsEndGameBlocking(*) => false
SitOutMatch(reason) => "replay"
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
    global moveCalls,testNow
    moveCalls += 1
    testNow += navWalkMs
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
    global gPlacements,gHillPlacementUnavailable,placeTries
    placeTries += 1
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

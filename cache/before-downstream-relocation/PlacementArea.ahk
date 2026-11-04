; One local circle, per-copy failure counts, and optional path relocation.
global gPlacementAreaFailures := Map(),gRunViewMoved := false
global gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0

ResetPlacementArea() {
    global gPlacementAreaFailures,gRunViewMoved,gPlacementViewRecovery,gPlacementRelocateRetryAt
    gPlacementAreaFailures := Map(),gRunViewMoved := false
    gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0
}

PlacementAnchorKnown(item) {
    return !item.HasProp("viewPending") || !item.viewPending
}

ContinuePlacementInCurrentView(unit,reason) {
    global gPlacementAreaFailures,gPlacementRelocateRetryAt
    if gPlacementAreaFailures.Has(unit.slot)
        gPlacementAreaFailures.Delete(unit.slot)
    if A_TickCount>=gPlacementRelocateRetryAt
        gPlacementRelocateRetryAt := A_TickCount+15000
    RefreshPlacementSearch()
    Log(reason " Continue placement attempts here; relocation can retry later.")
    return false
}

RecoverPlacementView() {
    global gPlacementViewRecovery,gRunning
    recovery := gPlacementViewRecovery
    if !recovery || !gRunning || A_TickCount<recovery.retryAt
        return !recovery
    recovery.retryAt := A_TickCount+3000
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
    if A_TickCount<gPlacementRelocateRetryAt
        return ContinuePlacementInCurrentView(unit,"Relocation is cooling down.")
    if !CloseUnitPanel() || !CancelUnitPreview() || !GetClient(&cx,&cy,&cw,&ch)
        return ContinuePlacementInCurrentView(unit,"The game view is not ready for relocation.")
    scene := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(scene) || scene["path"]="0"
        return ContinuePlacementInCurrentView(unit,"No connected visible path is available for a step.")
    next := VisionRequest("relocation")
    if !VisionOk(next)
        return ContinuePlacementInCurrentView(unit,"No next path step was found.")
    dx := Number(next["dx"]),dy := Number(next["dy"])
    if !PlacementViewCanShift(-dx,-dy) {
        return ContinuePlacementInCurrentView(unit,"The next step would hide a recorded unit.")
    }
    remembered := VisionRequest("rememberview")
    if !VisionOk(remembered) || !remembered.Has("saved") || remembered["saved"]!="1"
        return ContinuePlacementInCurrentView(unit,"The current view could not be saved before moving.")
    presses := AimPresses([],300,dx*cw/800,dy*ch/600)
    if !presses.Length
        return ContinuePlacementInCurrentView(unit,"The next path step has no movement direction.")
    previous := gCardAction,gCardAction := "relocating"
    try {
        Log("Seven failed clicks for the same copy; take a short step up the visible path.")
        HoldKeys(presses)
        if !gRunning
            return false
        ActionPause(400)
        if !gRunning
            return false
        shift := VisionRequest("viewshift " cx " " cy " " cw " " ch)
        if VisionOk(shift) {
            sx := Number(shift["dx"]),sy := Number(shift["dy"])
            ShiftRecordedPlacements(sx,sy,sx*sx+sy*sy>=8**2)
            Log("Camera shift " Round(sx) "," Round(sy) "; updated all recorded unit click points.")
            if sx*sx+sy*sy>=8**2
                return true
            return ContinuePlacementInCurrentView(unit,"The path step made no useful progress.")
        }
        ; Keep the path step. Old anchors await measurement; new placements use
        ; a fresh scan and must not inherit coordinates from the previous view.
        oldItems := gPlacements.Clone()
        for item in oldItems
            item.viewPending := true
        gPlacementViewRecovery := oldItems.Length?{items:oldItems,cw:cw,ch:ch,retryAt:A_TickCount+1000}:0
        gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
        gPlacementAreaFailures := Map(),gRunViewMoved := true,gPlacementProfile := ""
        gPlacementRelocateRetryAt := A_TickCount+15000
        RefreshPlacementSearch()
        ResetUpgradeSelection()
        SavePlacementRun()
        Log("View shift is uncertain. Stay beside the path and continue fresh placement; earlier unit coordinates will be retried without walking back.")
        return true
    } finally gCardAction := previous
}

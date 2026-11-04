; One local circle, per-copy failure counts, and short verified camera moves.
global gPlacementAreaFailures := Map(),gRunViewMoved := false

ResetPlacementArea() {
    global gPlacementAreaFailures,gRunViewMoved
    gPlacementAreaFailures := Map(),gRunViewMoved := false
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
    if !gRunning || IsEndGameBlocking() || !ClearCardChoice()
        return false
    if gPendingPlacement && HasUnitPanel()
        return FinishPlacement(unit,gPendingPlacement)
    if !CloseUnitPanel() || !CancelUnitPreview() || !GetClient(&cx,&cy,&cw,&ch)
        return false
    scene := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(scene) || scene["path"]="0"
        return false
    next := VisionRequest("relocation")
    if !VisionOk(next)
        return false
    dx := Number(next["dx"]),dy := Number(next["dy"])
    if !PlacementViewCanShift(-dx,-dy) {
        Log("Next path area would hide a recorded unit; keep this view and upgrade the placed units.")
        return false
    }
    if !VisionOk(VisionRequest("rememberview"))
        return false
    presses := AimPresses([],300,dx*cw/800,dy*ch/600)
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
        if VisionOk(shift) && PlacementViewCanShift(Number(shift["dx"]),Number(shift["dy"])) {
            sx := Number(shift["dx"]),sy := Number(shift["dy"])
            ShiftRecordedPlacements(sx,sy,sx*sx+sy*sy>=8**2)
            Log("Camera shift " Round(sx) "," Round(sy) "; updated all recorded unit click points.")
            return sx*sx+sy*sy>=8**2
        }
        if !gPlacements.Length {
            scene := VisionRequest("world " cx " " cy " " cw " " ch)
            if VisionOk(scene) && scene["path"]!="0" {
                gFailedPlacementSpots := []
                ShiftRecordedPlacements(0,0)
                return true
            }
        }
        ; Restore the old view if a move cannot keep existing units selectable.
        reverse := [],opposite := Map("w","s","s","w","a","d","d","a")
        for press in presses
            reverse.Push({key:opposite[press.key],ms:press.ms})
        HoldKeys(reverse)
        if !gRunning
            return false
        ActionPause(400)
        shift := VisionRequest("viewshift " cx " " cy " " cw " " ch)
        if VisionOk(shift) && PlacementViewCanShift(Number(shift["dx"]),Number(shift["dy"])) {
            ShiftRecordedPlacements(Number(shift["dx"]),Number(shift["dy"]),false)
            Log("Returned to a view containing all recorded units; defer this copy and continue upgrades.")
            return false
        }
        StopMacro()
        Notify("Stopped: could not verify the view after relocation. Restore the game view before restarting.")
        return false
    } finally gCardAction := previous
}

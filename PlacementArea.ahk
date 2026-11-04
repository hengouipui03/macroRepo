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

PlacementRelocationDirection() {
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
    if A_TickCount<gPlacementRelocateRetryAt
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
                gPlacementViewRecovery := oldItems.Length?{items:oldItems,cw:cw,ch:ch,retryAt:A_TickCount+1000}:0
                gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
                gPlacementAreaFailures := Map(),gRunViewMoved := true,gPlacementProfile := ""
                gPlacementRelocateRetryAt := A_TickCount+15000
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
        gPlacementRelocateRetryAt := A_TickCount+15000
        if totalX*totalX+totalY*totalY>=8**2 {
            Log("Relocation finished after " Round(Sqrt(totalX*totalX+totalY*totalY)) " pixels. " reason " Resume placement beside this path section.")
            return true
        }
        return ContinuePlacementInCurrentView(unit,reason)
    } finally gCardAction := previous
}

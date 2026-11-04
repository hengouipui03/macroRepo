; Quarter-path checkpoints and consecutive placement failures.
global gPlacementAreaFailures := Map(),gRunViewMoved := false
global gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0
global PLACEMENT_FAILURE_LIMIT := 5,gConsecutivePlacementFailures := 0
; Relocation walking (card time excluded) past 20 s without reaching the
; checkpoint teleports back to spawn via Settings, then walks again from there.
global RELOCATION_TELEPORT_MS := 20000,gRelocationWalkMs := 0,gRelocationWalkTarget := 0,gRelocationTeleports := 0

ResetPlacementArea() {
    global gPlacementAreaFailures,gRunViewMoved,gPlacementViewRecovery,gPlacementRelocateRetryAt
    global gRelocationWalkMs,gRelocationWalkTarget,gRelocationTeleports
    gPlacementAreaFailures := Map(),gRunViewMoved := false
    gPlacementViewRecovery := 0,gPlacementRelocateRetryAt := 0
    gRelocationWalkMs := 0,gRelocationWalkTarget := 0,gRelocationTeleports := 0
    ResetPlacementFailureStreak()
}

PlacementFailureLimitReached() {
    global PLACEMENT_FAILURE_LIMIT,gConsecutivePlacementFailures,gMapModel
    if gMapModel && gMapModel.HasProp("checkpointIndex") {
        if gMapModel.checkpointIndex=0
            return true
        if gMapModel.checkpointIndex>=3
            return false
    }
    return gConsecutivePlacementFailures>=PLACEMENT_FAILURE_LIMIT
}

ResetPlacementFailureStreak() {
    global gConsecutivePlacementFailures,gPlacementAreaFailures
    gConsecutivePlacementFailures := 0,gPlacementAreaFailures := Map()
}

RecordFailedPlacement(unit,point) {
    if !point || !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || (point.HasProp("failureCounted") && point.failureCounted)
        return false
    point.failureCounted := true
    PlacementCopyFailures(unit,true)
    return true
}

PlacementAnchorKnown(item) {
    return !item.HasProp("viewPending") || !item.viewPending
}

ContinuePlacementInCurrentView(unit,reason) {
    global gPlacementAreaFailures,gPlacementRelocateRetryAt
    if A_TickCount>=gPlacementRelocateRetryAt
        gPlacementRelocateRetryAt := A_TickCount+3000
    RefreshPlacementSearch()
    Log(reason (PlacementFailureLimitReached()?" Checkpoint travel remains pending before another purchase; existing upgrades continue.":" Placement can continue here."))
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
    global gPlacementAreaFailures,gConsecutivePlacementFailures,PLACEMENT_FAILURE_LIMIT
    copy := CountSlotPlacements(unit.slot)+1
    if !gPlacementAreaFailures.Has(unit.slot) || gPlacementAreaFailures[unit.slot].copy!=copy
        gPlacementAreaFailures[unit.slot] := {copy:copy,misses:0}
    state := gPlacementAreaFailures[unit.slot]
    if add {
        state.misses += 1
        gConsecutivePlacementFailures += 1
        Log("Failed purchase " gConsecutivePlacementFailures "/" PLACEMENT_FAILURE_LIMIT " consecutive | slot " unit.slot " copy " copy)
        if PlacementFailureLimitReached()
            Log("Five consecutive failed purchases: travel to the next baseward checkpoint before another purchase.")
        else if gConsecutivePlacementFailures=PLACEMENT_FAILURE_LIMIT
            Log("Final checkpoint: keep retrying placement until the build is complete or the match ends.")
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

RetryFinalCheckpointPlacement() {
    global gMapModel,gConsecutivePlacementFailures,PLACEMENT_FAILURE_LIMIT
    global gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses
    if !gMapModel || !gMapModel.HasProp("checkpointIndex") || gMapModel.checkpointIndex<3 || gConsecutivePlacementFailures<PLACEMENT_FAILURE_LIMIT
        return
    ResetPlacementFailureStreak()
    gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
    RefreshPlacementSearch()
    Log("Checkpoint 3: refresh local placement attempts and keep trying; no further relocation.")
}

RelocatePlacementArea(unit) {
    global gRunning,gPlacements,gPendingPlacement,gCardAction,gMapModel
    global gPrepDeadline,gNavigationTimedOut,gPlacementViewRecovery,gRunViewMoved,gPlacementProfile
    global gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses
    global RELOCATION_TELEPORT_MS,gRelocationWalkMs,gRelocationWalkTarget,gRelocationTeleports,gMovementCardTotalMs
    if !gRunning || IsEndGameBlocking() || !ClearCardChoice()
        return false
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    if !gMapModel || !gMapModel.HasProp("checkpoints") || gMapModel.checkpoints.Length!=3
        return ContinuePlacementInCurrentView(unit,"The three route checkpoints are unavailable.")
    if gMapModel.checkpointIndex>=3 {
        RetryFinalCheckpointPlacement()
        return false
    }
    if !CloseUnitPanel() || !CancelUnitPreview()
        return false
    next := gMapModel.checkpointIndex+1
    gMapModel.target := gMapModel.checkpoints[next]
    if !RefreshMapPlayer()
        return ContinuePlacementInCurrentView(unit,"Player marker unavailable; retain checkpoint " next " as the destination.")
    ; Upgrade selection now uses purchase order in F, not old world coordinates.
    for item in gPlacements
        item.viewPending := true
    gPlacementViewRecovery := 0,gRunViewMoved := true,gPlacementProfile := ""
    previous := gCardAction,gCardAction := "relocating"
    if gRelocationWalkTarget!=next
        gRelocationWalkTarget := next,gRelocationWalkMs := 0,gRelocationTeleports := 0
    ; Walking time for this checkpoint accumulates across retries.
    oldDeadline := gPrepDeadline,gPrepDeadline := A_TickCount+Max(3000,RELOCATION_TELEPORT_MS-gRelocationWalkMs)
    try {
        Log("Follow the drawn route to checkpoint " next "/3 (" (next*25) "% toward base).")
        started := A_TickCount,cardsBefore := gMovementCardTotalMs
        reached := NavigateDrawing()
        gRelocationWalkMs += Max(0,A_TickCount-started-(gMovementCardTotalMs-cardsBefore))
        if !reached && gRunning && !IsEndGameBlocking() && gRelocationWalkMs>=RELOCATION_TELEPORT_MS && gRelocationTeleports<2 {
            gRelocationTeleports += 1,gRelocationWalkMs := 0
            Log("Moving for 20 s without reaching checkpoint " next "; teleport back to spawn, then resume the route from there.")
            if TeleportBackToSpawn() {
                gPrepDeadline := A_TickCount+30000
                if RefreshMapPlayer() || ProbePlayer()
                    reached := NavigateDrawing()
                else
                    Log("Player marker not found after teleporting to spawn.")
            }
        }
        if !reached
            return ContinuePlacementInCurrentView(unit,"Checkpoint " next " not reached yet; keep that destination and retry.")
        gRelocationWalkTarget := 0,gRelocationWalkMs := 0,gRelocationTeleports := 0
        gMapModel.checkpointIndex := next
        gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
        ResetPlacementFailureStreak()
        RefreshPlacementSearch()
        ResetUpgradeSelection()
        SavePlacementRun()
        Log("Reached checkpoint " next "/3. Resume placement; recorded units remain accessible through F.")
        return true
    } finally {
        gPrepDeadline := oldDeadline,gCardAction := previous
    }
}

; Settings gear (bottom left) -> "Teleport back to Spawn" -> close Settings.
; The arrow button is clicked only on the row OCR confirms as "Teleport back to
; Spawn"; "Return to Lobby" sits on the next row and is never clicked.
TeleportBackToSpawn() {
    global gRunning,REF_W,REF_H
    if !gRunning || HasCardChoice() || IsEndGameBlocking() || !GetClient(&cx,&cy,&cw,&ch)
        return false
    ReleaseMovementKeys()
    if !ButtonPosition("SettingsGear",&gx,&gy) || !ClickRef(gx,gy)
        return false
    row := 0,lobbyY := -1,opened := false
    Loop 8 {
        if !ActionPause(250)
            break
        for candidate in ReadOcrRows(215,190,640,470) {
            text := NormalizeWords(candidate.text)
            opened := opened || RegExMatch(text,"settings|gameplay|spawn|lobby")
            if RegExMatch(text,"lobby")
                lobbyY := (candidate.y+candidate.h/2)*REF_H/ch
            else if !row && RegExMatch(text,"teleport\s*back|back\s*to\s*spawn")
                row := candidate
        }
        if row
            break
    }
    if !row {
        Log("Settings did not show 'Teleport back to Spawn'; nothing clicked inside Settings.")
        if opened
            CloseSettingsAfterTeleport()
        return false
    }
    ry := (row.y+row.h/2)*REF_H/ch+5
    if lobbyY>=0 && Abs(lobbyY-ry)<25 {
        Log("Teleport row is too close to Return to Lobby; not clicked.")
        CloseSettingsAfterTeleport()
        return false
    }
    Log("Settings: click Teleport back to Spawn.")
    clicked := ClickRef(515,ry)
    ActionPause(1500)
    CloseSettingsAfterTeleport()
    return clicked
}

; Settings' own red X at the panel's top right; the boss bar above is excluded.
CloseSettingsAfterTeleport() {
    global REF_W,REF_H
    x := 570,y := 131
    frame := RefPixels(540,104,605,165)
    if frame.valid && FindCompactRedControl(frame,&nx,&ny) && GetClient(&cx,&cy,&cw,&ch)
        x := nx*REF_W/cw,y := ny*REF_H/ch
    ClickRef(x,y)
    ActionPause(300)
}

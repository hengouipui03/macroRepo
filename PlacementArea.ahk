; Quarter-path checkpoints and consecutive placement failures.
global gPlacementAreaFailures := Map(),gRunViewMoved := false
global gPlacementRelocateRetryAt := 0
global PLACEMENT_FAILURE_LIMIT := 6,gConsecutivePlacementFailures := 0
; Relocation walking (card time excluded) past 20 s without reaching the
; checkpoint teleports back to spawn via Settings, then walks again from there.
global RELOCATION_TELEPORT_MS := 20000,gRelocationWalkMs := 0,gRelocationWalkTarget := 0,gRelocationTeleports := 0

ResetPlacementArea() {
    global gPlacementAreaFailures,gRunViewMoved,gPlacementRelocateRetryAt
    global gRelocationWalkMs,gRelocationWalkTarget,gRelocationTeleports
    gPlacementAreaFailures := Map(),gRunViewMoved := false
    gPlacementRelocateRetryAt := 0
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
    ; Yen was checked before the click (PlacementShortOfYen), so a purchase that
    ; did not go through is a real failure.
    PlacementCopyFailures(unit,true)
    return true
}

; False while a recorded unit has no usable position on screen: the view moved
; since it was placed (viewPending, set by RelocatePlacementArea; nothing
; shifts the old coordinates), or the build audit recorded it without any
; (anchorless: a purchase the macro missed). Position-based code skips those.
PlacementAnchorKnown(item) {
    if item.HasProp("anchorless") && item.anchorless
        return false
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
            Log(PLACEMENT_FAILURE_LIMIT " consecutive failed purchases: travel to the next baseward checkpoint before another purchase.")
        else if gConsecutivePlacementFailures=PLACEMENT_FAILURE_LIMIT
            Log("Final checkpoint: keep retrying placement until the build is complete or the match ends.")
    }
    return state.misses
}

; Screen direction (x right, y down) leading up the route toward where the
; enemies come from, measured from the player on the minimap. Path-side
; placement walks the lane this way first. {x:0,y:0} when unknown.
PlacementUpstreamDirection() {
    global gMapModel,gMoveKeys,MAP_GRID
    if !gMapModel || !gMapModel.baseMarker || !gMapModel.player || !gMoveKeys || !gMapModel.nodes.Count
        return {x:0,y:0}
    p := gMapModel.player
    base := MapNearest(gMapModel.nodes,gMapModel.baseMarker.x,gMapModel.baseMarker.y)
    route := MapShortestPath(gMapModel.nodes,MapNearest(gMapModel.nodes,p.x,p.y),MapFarthestNode(gMapModel.nodes,base))
    if route.Length<2
        return {x:0,y:0}
    node := route[Min(6,route.Length)]
    mx := Mod(node,MAP_GRID)-p.x,my := node//MAP_GRID-p.y
    ; Solve minimap = a*W + b*D; D is screen right, W is screen up.
    w := gMoveKeys.w,d := gMoveKeys.d,det := w.x*d.y-w.y*d.x
    if Abs(det)<0.01
        return {x:0,y:0}
    a := (mx*d.y-my*d.x)/det,b := (w.x*my-w.y*mx)/det,length := Sqrt(a*a+b*b)
    if !length
        return {x:0,y:0}
    return {x:b/length,y:-a/length}
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

; Relocation could not even start BUILD_RELOCATE_WAIT_LIMIT times in a row
; (the player marker or the route is unavailable): stop waiting and treat the
; current position as the next checkpoint, as RelocatePlacementArea does after
; its own walking limit. Per-checkpoint failure memory starts fresh.
AcceptCurrentPlacementArea(unit) {
    global gMapModel,gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses
    if gMapModel && gMapModel.HasProp("checkpointIndex") && gMapModel.checkpointIndex<3
        gMapModel.checkpointIndex += 1
    gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
    ResetPlacementFailureStreak()
    RefreshPlacementSearch()
    Log(unit.name ": relocation could not start " BUILD_RELOCATE_WAIT_LIMIT " times in a row; treat the current position as checkpoint "
        (gMapModel && gMapModel.HasProp("checkpointIndex")?gMapModel.checkpointIndex:"?") " and place from here.")
}

RelocatePlacementArea(unit) {
    global gRunning,gPlacements,gPendingPlacement,gCardAction,gMapModel
    global gPrepDeadline,gNavigationTimedOut,gRunViewMoved,gPlacementProfile
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
    ; The camera follows the player, so the screen positions of earlier units are
    ; stale from here on. They stay in the record (upgrades find them in F by
    ; purchase number) but position code skips them (PlacementAnchorKnown), and
    ; learned-placement writes pause (gPlacementProfile is blanked).
    for item in gPlacements
        item.viewPending := true
    gRunViewMoved := true,gPlacementProfile := ""
    previous := gCardAction,gCardAction := "relocating"
    if gRelocationWalkTarget!=next
        gRelocationWalkTarget := next,gRelocationWalkMs := 0,gRelocationTeleports := 0
    ; Walking time for this checkpoint accumulates across retries.
    oldDeadline := gPrepDeadline,gPrepDeadline := A_TickCount+Max(3000,RELOCATION_TELEPORT_MS-gRelocationWalkMs)
    try {
        if gMapModel.HasProp("crossings") && gMapModel.crossings.Length
            Log("Follow the drawn route to checkpoint " next "/3 (the next point where the two paths meet).")
        else
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
        ; Both teleports used and another 20 s of walking still failed: stop
        ; retrying this checkpoint forever and place from where the player is.
        gaveUp := !reached && gRunning && !IsEndGameBlocking() && gRelocationTeleports>=2 && gRelocationWalkMs>=RELOCATION_TELEPORT_MS
        if !reached && !gaveUp
            return ContinuePlacementInCurrentView(unit,"Checkpoint " next " not reached yet; keep that destination and retry.")
        gRelocationWalkTarget := 0,gRelocationWalkMs := 0,gRelocationTeleports := 0
        gMapModel.checkpointIndex := next
        gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
        ResetPlacementFailureStreak()
        RefreshPlacementSearch()
        ResetUpgradeSelection()
        if gaveUp
            Log("Checkpoint " next "/3 not reached after 2 teleports and another 20 s of walking; treat the current position as that checkpoint and resume placement here.")
        else
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

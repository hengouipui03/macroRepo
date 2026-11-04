#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [],REF_W := 800,REF_H := 600
global gCardAction := "",gCardInterruptEpoch := 0,gPlacementActiveUnit := 0
global phantomReturn := false
global preview := false
global mode := "second",panel := false,clicks := [],selected := 0,saved := [],currentX := 0,currentY := 0,late := false,cards := false,cardClears := 0,visionCalls := 0,waits := []
; Deliberate placement along one local side of the in-game path.
global gPlacementLine := [],gLastPlacedIndex := 0,gPlacementPreferredSide := 0
global gHillPlacementUnavailable := false
global gPlacementAttemptClicked := false
global FAILED_PLACEMENT_RADIUS := 14
global gFailedPlacementSpots := []
global gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
global gUnitPanelClose := 0,gPendingPlacement := 0,gPlacementDebugAt := 0

ResetPlacementSearch() {
    global gPlacementLine,gLastPlacedIndex,gPendingPlacement,gPlacementPreferredSide,gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses
    gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
    gPlacementLine := [],gLastPlacedIndex := 0,gPendingPlacement := 0,gPlacementPreferredSide := 0
}

RefreshPlacementSearch() {
    global gPlacementLine,gLastPlacedIndex,gPendingPlacement,gLayoutValidation
    ; Keep confirmed units AND this game's failed spots across rescans.
    ; Only ResetPlacementSearch at the next build clears failure memory.
    gPlacementLine := [],gLastPlacedIndex := 0,gPendingPlacement := 0
    gLayoutValidation := Map()
}

FindPlacementCandidates() {
    global gPlacementLine,gLastPlacedIndex,gPlacementPreferredSide,REF_W,REF_H
    if !gPlacementLine.Length {
        if !GetClient(&cx,&cy,&cw,&ch)
            return []
        scene := VisionRequest("world " cx " " cy " " cw " " ch)
        if !VisionOk(scene) || scene["path"]="0" {
            PlacementSearchDiagnostic("No illuminated world path detected; no slot or placement click sent.")
            return []
        }
        reply := VisionRequest("placementline 48 " PlacementSearchExclusions(false) " " PlacementSearchExclusions(true) " " PlacementBlockedEdgeExclusions())
        if !VisionOk(reply) || !reply.Has("points") || reply["points"]="" || !reply.Has("count") || Number(reply["count"])<1 {
            PlacementSearchDiagnostic("Visible path found, but no nearby edge fits the player view; no slot or placement click sent.")
            return []
        }
        for text in StrSplit(reply["points"],";") {
            xy := StrSplit(text,",")
            point := {x:Round(Number(xy[1])*REF_W/cw),
                y:Round(Number(xy[2])*REF_H/ch),index:gPlacementLine.Length+1,side:0,row:1}
            AddPlacementGeometry(point,reply,point.index,cw,ch)
            gPlacementLine.Push(point)
        }
        first := gPlacementLine[1]
        Log("Start beside the player at " first.x "," first.y "; follow one path edge in adjacent steps.")
    }
    points := []
    ; Every new unit stays on the same path edge, advancing past used spots.
    index := gLastPlacedIndex+1
    while index<=gPlacementLine.Length {
        point := gPlacementLine[index++]
        if gPlacementPreferredSide=1 && point.HasProp("other")
            point := OppositePlacementPoint(point)
        point := UsablePlacementPoint(point)
        if point
            points.Push(point)
    }
    ; A completed short line can still have free positions across the road.
    if !points.Length {
        for original in gPlacementLine {
            if !original.HasProp("other")
                continue
            point := OppositePlacementPoint(original)
            if !CandidateOccupied(point.x,point.y) && !FailedPlacementSpot(point) && !BlockedPlacementEdge(point)
                points.Push(point)
        }
    }
    return points
}

FindNeighbourPlacementCandidates() {
    global gPlacements,REF_W,REF_H
    seeds := "",points := []
    for item in gPlacements {
        if !item.HasProp("x") || (item.HasProp("hill") && item.hill) || (item.HasProp("row") && item.row!=1)
            continue
        seeds .= (seeds=""?"":";") Round(item.x) "," Round(item.y)
    }
    if seeds="" || !GetClient(&cx,&cy,&cw,&ch)
        return points
    scene := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(scene) || scene["path"]="0"
        return points
    reply := VisionRequest("placementneighbours " seeds " " PlacementSearchExclusions(false) " " PlacementSearchExclusions(true) " " PlacementBlockedEdgeExclusions())
    if !VisionOk(reply) || !reply.Has("points") || reply["points"]=""
        return points
    for index,text in StrSplit(reply["points"],";") {
        xy := StrSplit(text,",")
        point := {x:Round(Number(xy[1])*REF_W/cw),y:Round(Number(xy[2])*REF_H/ch),side:0,row:2}
        AddPlacementGeometry(point,reply,index,cw,ch)
        if !CandidateOccupied(point.x,point.y) && !FailedPlacementSpot(point) && !BlockedPlacementEdge(point)
            points.Push(point)
    }
    return points
}

PlacementTerrain(point) => point.HasProp("hill") && point.hill?"hill":"ground"

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
    Log("Rejected " PlacementTerrain(point) " spot " point.x "," point.y "; skip its surrounding area for the rest of this game.")
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

PlacementSearchExclusions(occupied) {
    global gFailedPlacementSpots,gPlacements
    text := "",points := occupied?gPlacements:gFailedPlacementSpots
    for point in points {
        if !occupied && point.terrain!="ground"
            continue
        text .= (text=""?"":";") Round(point.x) "," Round(point.y)
    }
    return text=""?"-":text
}

UsablePlacementPoint(point) {
    ; Skip the whole rejected patch; do not test tiny shifts inside it.
    if FailedPlacementSpot(point)
        return 0
    if !CandidateOccupied(point.x,point.y) && !FailedPlacementSpot(point) && !BlockedPlacementEdge(point)
        return point
    if point.HasProp("other") {
        other := OppositePlacementPoint(point)
        if !CandidateOccupied(other.x,other.y) && !FailedPlacementSpot(other) && !BlockedPlacementEdge(other)
            return other
    }
    return 0
}

PlacementSearchDiagnostic(reason) {
    global gPlacementDebugAt
    Log(reason)
    if !gPlacementDebugAt || A_TickCount-gPlacementDebugAt>=30000 {
        gPlacementDebugAt := A_TickCount
        VisionRequest("worlddebug " A_ScriptDir "\placement-search-debug.png")
    }
}


PlacementClickRef(rx,ry,guardCards := false) {
    global gRunning
    if !gRunning || !ToScreen(rx,ry,&sx,&sy)
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    if !SmoothMoveTo(sx,sy)
        return false
    if !ActionPause(90) || (guardCards && (HasCardChoice() || HasUnitPanel() || IsEndGameBlocking()))
        return false
    SendEvent "{LButton down}"
    try return ActionPause(80,false)
    finally SendEvent "{LButton up}"
}


SelectPlacementUnit(unit) {
    global gRunning
    if !gRunning
        return false
    SendEvent "{" unit.slot " down}"
    try {
        if !ActionPause(40,false)
            return false
    } finally SendEvent "{" unit.slot " up}"
    return ActionPause(45)
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


UnitPanelColourHits(frame,x1,y1,x2,y2,predicate) {
    hits := 0,y := y1
    while y<=y2 {
        x := x1
        while x<=x2 {
            if predicate.Call(frame.AtRef(x,y))
                hits += 1
            x += 4
        }
        y += 4
    }
    return hits
}


RealHasUnitPanel(frame := 0) {
    global gUnitPanelClose
    if !frame
        frame := RefPixels(5,185,300,400)
    if !frame.valid
        return false
    ; Recognize the panel layout for attackers and support units alike:
    ; gold UPG heading, red Sell button, red close X and dark statistics.
    if UnitPanelColourHits(frame,146,214,205,238,IsUiYellow)<4
        || UnitPanelColourHits(frame,25,365,140,387,IsBubbleRed)<6
        || UnitPanelColourHits(frame,258,202,294,234,IsUiRed)<6
        return false
    dark := 0
    for x in [170,190,210,230,250] {
        for y in [270,290,310,330] {
            RGB(frame.AtRef(x,y),&r,&g,&b)
            if Max(r,g,b)<110
                dark += 1
        }
    }
    if dark<10
        return false
    sumX := 0,sumY := 0,hits := 0
    Loop 17 {
        y := 200+A_Index*2
        Loop 19 {
            x := 256+A_Index*2
            if IsUiRed(frame.AtRef(x,y))
                sumX += x,sumY += y,hits += 1
        }
    }
    if hits
        gUnitPanelClose := {x:Round(sumX/hits),y:Round(sumY/hits)}
    return true
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

CloseUnitPanel() {
    if !HasUnitPanel()
        return true
    return ClickAwayFromUnitPanel()
}


PlacementPanelClosedStable() {
    Loop 2 {
        if HasCardChoice() || HasUnitPanel() || !ActionPause(45)
            return false
    }
    return true
}

CountSlotPlacements(slot) {
    global gPlacements
    count := 0
    for item in gPlacements
        if item.slot=slot
            count += 1
    return count
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


AddPlacementGeometry(point,reply,index,cw,ch) {
    global REF_W,REF_H
    point.nx := 0,point.ny := 0
    if reply.Has("normals") {
        entries := StrSplit(reply["normals"],";")
        if entries.Length>=index {
            normal := StrSplit(entries[index],",")
            if normal.Length=2
                point.nx := Number(normal[1]),point.ny := Number(normal[2])
        }
    }
    if reply.Has("opposites") {
        entries := StrSplit(reply["opposites"],";")
        if entries.Length>=index && entries[index]!="-" {
            xy := StrSplit(entries[index],",")
            if xy.Length=2 {
                other := {x:Round(Number(xy[1])*REF_W/cw),y:Round(Number(xy[2])*REF_H/ch),
                    nx:-point.nx,ny:-point.ny,side:1,row:1}
                if point.HasProp("index")
                    other.index := point.index
                if point.HasProp("hill")
                    other.hill := point.hill
                point.other := other
            }
        }
    }
}

OppositePlacementPoint(point) {
    other := point.other.Clone()
    back := point.Clone()
    if back.HasProp("other")
        back.DeleteProp("other")
    other.other := back
    return other
}

PlacementEdgeNormal(point) {
    if point.HasProp("nx") && point.nx**2+point.ny**2>0.5
        return {x:point.nx,y:point.ny}
    return 0
}

SamePlacementEdge(a,b) {
    na := PlacementEdgeNormal(a),nb := PlacementEdgeNormal(b)
    if na && nb
        return na.x*nb.x+na.y*nb.y>0.3
    return (a.HasProp("side")?a.side:0)=(b.HasProp("side")?b.side:0)
}

BlockedPlacementEdge(point) {
    global gPlacementBlockedEdges
    for edge in gPlacementBlockedEdges {
        if edge.terrain!=PlacementTerrain(point) || !SamePlacementEdge(edge.point,point)
            continue
        dx := point.x-edge.point.x,dy := point.y-edge.point.y
        normal := PlacementEdgeNormal(edge.point)
        if normal {
            if Abs(dx*(-normal.y)+dy*normal.x)<48 && Abs(dx*normal.x+dy*normal.y)<80
                return true
        } else if dx**2+dy**2<60**2
            return true
    }
    return false
}

PlacementBlockedEdgeExclusions() {
    global gPlacementBlockedEdges
    text := ""
    for edge in gPlacementBlockedEdges {
        if edge.terrain!="ground"
            continue
        normal := PlacementEdgeNormal(edge.point)
        if normal
            text .= (text=""?"":";") edge.point.x "," edge.point.y "," normal.x "," normal.y
    }
    return text=""?"-":text
}

RegisterPlacementEdgeMiss(point) {
    global gPlacementEdgeMisses,gPlacementBlockedEdges
    terrain := PlacementTerrain(point)
    if !gPlacementEdgeMisses.Has(terrain) || !SamePlacementEdge(gPlacementEdgeMisses[terrain].point,point)
        gPlacementEdgeMisses[terrain] := {point:point,attempts:[]}
    state := gPlacementEdgeMisses[terrain]
    state.attempts.Push(point)
    if state.attempts.Length<3
        return []
    gPlacementBlockedEdges.Push({point:state.point,terrain:terrain})
    gPlacementEdgeMisses.Delete(terrain)
    return state.attempts
}

TryPlacementPoints(unit,points) {
    global gRunning,gPlacementAttemptClicked,gPendingPlacement
    queue := points.Clone(),seen := Map()
    while queue.Length {
        if !gRunning || IsEndGameBlocking()
            return false
        if gPendingPlacement && HasUnitPanel()
            return FinishPlacement(unit,gPendingPlacement)
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

MatchSavedPlacementsToPath(unit,pathPoints) {
    saved := CachedPlacementCandidates(unit)
    result := []
    ; Preserve path order. A previous unit or a saved off-road point cannot
    ; become the origin of another placement row.
    for point in pathPoints {
        best := 0,bestDistance := 6**2
        for candidate in saved {
            distance := (candidate.x-point.x)**2+(candidate.y-point.y)**2
            if distance<=bestDistance && !CandidateOccupied(candidate.x,candidate.y)
                best := candidate,bestDistance := distance
        }
        if best {
            point := point.Clone()
            point.x := best.x,point.y := best.y,point.cached := true
        }
        result.Push(point)
    }
    return result
}

FindHillPlacementCandidates(unit) {
    global REF_W,REF_H
    points := []
    if !GetClient(&cx,&cy,&cw,&ch) || !CancelUnitPreview() || !PlacementPanelClosedStable()
        return points
    baseline := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(baseline) || baseline["path"]="0"
        return points
    if !SelectPlacementUnit(unit) || !ActionPause(350) || HasCardChoice()
        return points
    reply := VisionRequest("hillspots 8 " cx " " cy " " cw " " ch)
    CancelUnitPreview()
    if !VisionOk(reply) || !reply.Has("points") || reply["points"]="" || HasCardChoice()
        return points
    for index,text in StrSplit(reply["points"],";") {
        xy := StrSplit(text,",")
        point := {x:Round(Number(xy[1])*REF_W/cw),y:Round(Number(xy[2])*REF_H/ch),hill:true,side:0}
        AddPlacementGeometry(point,reply,index,cw,ch)
        if !CandidateOccupied(point.x,point.y)
            points.Push(point)
    }
    return points
}

RealPlaceUnit(unit) {
    global gCardAction,gPlacementActiveUnit,gCardInterruptEpoch,gRunning
    previous := gCardAction,previousUnit := gPlacementActiveUnit
    gCardAction := "placement",gPlacementActiveUnit := unit
    try {
        loop {
            epoch := gCardInterruptEpoch,before := CountSlotPlacements(unit.slot)
            result := PlaceUnitAction(unit)
            if !result && gRunning && HasCardChoice() && !ClearCardChoice()
                return false
            if CountSlotPlacements(unit.slot)>before
                return true
            if epoch=gCardInterruptEpoch || !gRunning
                return result
        }
    } finally {
        gCardAction := previous,gPlacementActiveUnit := previousUnit
    }
}

PlaceUnitAction(unit) {
    global gRunning,gPendingPlacement,gHillPlacementUnavailable
    gHillPlacementUnavailable := false
    if !gRunning || IsEndGameBlocking()
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2) || !ClearCardChoice() || !CloseUnitPanel()
        return false
    gPendingPlacement := 0
    if !CancelUnitPreview()
        return false
    RefreshMatchModifiers()
    hillOnly := unit.HasProp("hill") && unit.hill
    hybrid := unit.HasProp("hybrid") && unit.hybrid
    if hillOnly || hybrid {
        hillPoints := FindHillPlacementCandidates(unit)
        if hillPoints.Length {
            Log(unit.name ": prefer green Hill surfaces, nearest the illuminated path first.")
            if TryPlacementPoints(unit,hillPoints)
                return true
            if gPendingPlacement && WaitFor(HasUnitPanel,250,40)
                return FinishPlacement(unit,gPendingPlacement)
        }
        if hillOnly {
            gHillPlacementUnavailable := true
            Log(unit.name ": Hill-only; no usable highlighted Hill space. Do not attempt ground placement.")
            return false
        }
        Log(unit.name ": Hybrid has no usable Hill space; continue with normal path-side placement.")
        if !CancelUnitPreview()
            return false
        gPendingPlacement := 0
    }
    neighbours := FindNeighbourPlacementCandidates()
    if neighbours.Length {
        Log(unit.name ": try the second row beside confirmed path-side units.")
        if TryPlacementPoints(unit,MatchSavedPlacementsToPath(unit,neighbours))
            return true
        if gPendingPlacement && WaitFor(HasUnitPanel,250,40)
            return FinishPlacement(unit,gPendingPlacement)
    }
    points := FindPlacementCandidates()
    if !points.Length {
        Log(unit.name ": no untried local path-side spots; rescans will avoid this game's rejected coordinates.")
        return false
    }
    ; Saved coordinates are reusable only where they match this visible edge.
    points := MatchSavedPlacementsToPath(unit,points)
    if TryPlacementPoints(unit,points)
        return true
    if gPendingPlacement && WaitFor(HasUnitPanel,250,40)
        return FinishPlacement(unit,gPendingPlacement)
    if gRunning
        CancelUnitPreview()
    Log(unit.name ": path-side attempts unconfirmed; path-edge sections limited to 3 misses, then opposite side, keeping this same copy.")
    return false
}


PlaceConfiguredBuild(plan) {
    global gCardAction,gCardInterruptEpoch,gRunning
    previous := gCardAction,gCardAction := "placement"
    try {
        loop {
            epoch := gCardInterruptEpoch
            result := PlaceConfiguredBuildAction(plan)
            if epoch=gCardInterruptEpoch || !gRunning || result!="stopped"
                return result
        }
    } finally gCardAction := previous
}

PlaceConfiguredBuildAction(plan) {
    global gRunning,gHillPlacementUnavailable
    for unit in plan {
        if !unit.enabled
            continue
        while CountSlotPlacements(unit.slot)<unit.count {
            if !gRunning
                return "stopped"
            before := CountSlotPlacements(unit.slot)
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
                Log(unit.name ": leave remaining Hill-only copies unplaced; continue with later units.")
                break
            }
            if TryEndState()
                return "replay"
            Notify(unit.name ": " after "/" unit.count " confirmed; retrying the remaining placement in order.")
            RefreshPlacementSearch()
            if !ActionPause(900)
                return "stopped"
        }
    }
    return "complete"
}

try {
    unit := {slot:3,name:"Unit 3",priority:4,target:6}
    gUnitPanelClose := {x:277,y:216}
    Assert(RealPlaceUnit(unit),"Miss did not progress to adjacent spot")
    Assert(clicks.Length=2 && clicks[1].x=440 && clicks[1].y=310 && clicks[2].y=334,"Attempts were not adjacent and ordered")
    Assert(selected=2 && saved.Length=1 && gLastPlacedIndex=3,"One click/selection/success accounting failed")
    Assert(waits[1]=800,"Confirmation was not awaited before the next position")
    mode := "immediate",clicks := [],selected := 0
    Assert(RealPlaceUnit(unit),"Next unit did not continue along the row")
    Assert(clicks.Length=1 && clicks[1].x=440 && clicks[1].y=358 && gLastPlacedIndex=5,"Next unit was not beside the last placed unit")
    Assert(visionCalls=4,"Next unit unexpectedly replaced the ordered line")
    ResetCase("miss")
    Assert(!RealPlaceUnit(unit) && gRunning && saved.Length=0,"Miss stopped the macro or was saved as success")
    Assert(clicks.Length<=6 && clicks[1].y=310 && clicks[2].y=334 && clicks[3].y=358,"Three-miss edge limit failed")
    Assert(gFailedPlacementSpots.Length=clicks.Length,"Actual rejected clicks were not remembered")
    Assert(FailedPlacementSpot({x:450,y:314}) && !FailedPlacementSpot({x:456,y:310}),"Rejected-area radius did not cover small coordinate shifts")
    previousClicks := clicks.Length
    RefreshPlacementSearch()
    Assert(!RealPlaceUnit(unit),"A failed rescan fabricated a success")
    Loop previousClicks {
        original := clicks[A_Index]
        for laterIndex,later in clicks
            if laterIndex>previousClicks
                Assert(original.x!=later.x || original.y!=later.y,"A rescan clicked the same rejected coordinates again")
    }
    previousClicks := clicks.Length
    RefreshPlacementSearch()
    Assert(!RealPlaceUnit(unit) && clicks.Length=previousClicks,"Exhausted blocked sections kept receiving inputs")
    mode := "jitter",RefreshPlacementSearch()
    Assert(!RealPlaceUnit(unit) && clicks.Length=previousClicks,"Small vision-coordinate jitter bypassed failed memory")
    otherUnit := unit.Clone(),otherUnit.slot := 5
    Assert(!RealPlaceUnit(otherUnit) && clicks.Length=previousClicks,"A later slot retried this game's rejected ground spots")
    RememberFailedPlacementSpot({x:500,y:310,hill:true})
    Assert(FailedPlacementSpot({x:500,y:310,hill:true}) && !FailedPlacementSpot({x:500,y:310}),"Hill and ground rejection lists were mixed")
    ResetPlacementSearch()
    Assert(gFailedPlacementSpots.Length=0,"A fresh game retained failed coordinates")
    mode := "immediate"
    Assert(RealPlaceUnit(unit) && clicks.Length=previousClicks+1,"A fresh game could not retry an old rejected spot")
    ResetCase("opposite")
    Assert(RealPlaceUnit(unit),"Opposite edge was not attempted after three misses")
    Assert(clicks.Length=4 && clicks[3].x=488 && clicks[4].x=340,"More than three clicks continued down the blocked line")
    Assert(gPlacementPreferredSide=1 && gLastPlacedIndex=1 && saved.Length=1,"Opposite success lost side/index/count")
    clicks := [],selected := 0
    Assert(RealPlaceUnit(unit) && clicks[1].x=340 && clicks[1].y=334,"Following unit did not continue on the successful opposite edge")
    ResetCase("straight-edge")
    Assert(RealPlaceUnit(unit),"Straight edge did not switch sides")
    Assert(clicks.Length=4 && clicks[1].x=440 && clicks[2].x=440 && clicks[3].x=440 && clicks[4].x=340,"A fourth same-edge click was sent before the opposite edge")
    ResetCase("straight-edge")
    group := []
    Loop 3
        group.Push({x:440,y:286+A_Index*24,index:A_Index,side:0,nx:1,ny:0,other:{x:340,y:286+A_Index*24,index:A_Index,side:1,nx:-1,ny:0}})
    Assert(!TryPlacementPoints(unit,[group[1],group[2]]) && clicks.Length=2,"Initial two misses were not attempted")
    RefreshPlacementSearch()
    Assert(TryPlacementPoints(unit,[group[3]]) && clicks.Length=4 && clicks[4].x=340,"Rescan reset the edge failure count")
    ResetCase("both-blocked")
    Assert(RealPlaceUnit(unit),"Both blocked sides did not advance along the path")
    Assert(clicks.Length=7 && clicks[7].x=440 && clicks[7].y=370,"Blocked perpendicular line continued past three failures: " ClickTrace())
    Loop 6
        Assert(clicks[A_Index].x!=476,"Farther points on the failed line were clicked")
    ResetCase("neighbours")
    gPlacements := [{slot:3,x:440,y:334,row:1,hill:false}]
    Assert(RealPlaceUnit(unit) && clicks.Length=1 && clicks[1].x=468 && saved[1].row=2,"Next unit did not try a second row beside the confirmed first-row unit")
    Assert(gLastPlacedIndex=0,"Second-row success incorrectly advanced the edge cursor")
    gPlacements := [{slot:3,x:468,y:334,row:2,hill:false}],visionCalls := 0
    Assert(FindNeighbourPlacementCandidates().Length=0 && visionCalls=0,"Second-row unit was used to seed a third row")
    ResetCase("opposite")
    gPlacementLine := [{x:440,y:310,index:1,side:0,nx:1,ny:0,other:{x:340,y:310,index:1,side:1,nx:-1,ny:0}}]
    gLastPlacedIndex := 1,gPlacements := [{slot:3,x:440,y:310}]
    Assert(RealPlaceUnit(unit) && clicks.Length=1 && clicks[1].x=340,"An occupied/exhausted primary line hid the free opposite edge")
    ResetCase("late")
    Assert(RealPlaceUnit(unit) && clicks.Length=1 && saved[1].y=310,"Late panel lost its original position")
    ResetCase("cards")
    Assert(RealPlaceUnit(unit) && selected=2 && cardClears>=1 && saved.Length=1,"Cards did not pause/reselect/resume")
    ResetCase("hill")
    unit.hill := true
    Assert(RealPlaceUnit(unit) && saved[1].hill && clicks[1].x=460,"Hill-marked slot did not try the green surface first")
    ResetCase("hill-none")
    Assert(!RealPlaceUnit(unit) && clicks.Length=0 && gHillPlacementUnavailable,"Hill-only unit fell back to ground when no green highlight appeared")
    ResetCase("hill-fail")
    Assert(!RealPlaceUnit(unit) && clicks.Length=1 && clicks[1].x=460 && gHillPlacementUnavailable,"Rejected Hill-only candidate fell back to ground")
    unit.hill := false,unit.hybrid := true
    ResetCase("hill")
    Assert(RealPlaceUnit(unit) && saved[1].hill && clicks[1].x=460,"Hybrid did not prefer green Hill terrain")
    ResetCase("hill-none")
    Assert(RealPlaceUnit(unit) && clicks[1].x=440 && !saved[1].HasProp("hill"),"Hybrid without Hill terrain did not fall back to ground")
    ResetCase("hill-fail")
    Assert(RealPlaceUnit(unit) && clicks.Length=2 && clicks[2].x=440,"Hybrid with occupied/unusable Hill space did not fall back to ground")
    unit.hybrid := false
    ResetCase("saved-far")
    Assert(RealPlaceUnit(unit) && clicks[1].x=440 && clicks[1].y=310,"Off-path saved placement bypassed the visible path edge")
    Assert(gLastPlacedIndex=1,"Path progress lost when rejecting saved coordinates")
    ResetCase("saved-near")
    Assert(RealPlaceUnit(unit) && clicks[1].x=443 && clicks[1].y=310,"Saved coordinate beside the same visible edge was not reused")
    Assert(gLastPlacedIndex=1,"Reused coordinate did not retain its path index")
    ResetCase("stale-panel")
    Assert(!RealPlaceUnit(unit) && clicks.Length=0 && saved.Length=0,"A panel already open before the new click was counted as a purchase")
    Assert(gFailedPlacementSpots.Length=0,"A cancelled/no-click attempt was marked as a bad spot")
    ResetCase("short-line")
    Assert(RealPlaceUnit(unit) && selected=1 && clicks.Length=1,"One visible path spot was rejected before slot/click")
    ResetCase("end-screen")
    Assert(!RealPlaceUnit(unit) && clicks.Length=0 && selected=0,"Placement input continued over an end screen")
    ResetCase("no-path")
    Assert(!RealPlaceUnit(unit) && clicks.Length=0 && selected=0,"Missing path caused random fallback clicks")
    gRunning := false
    Assert(!RealPlaceUnit(unit) && clicks.Length=0,"Stop permitted another click")
    Assert(RealHasUnitPanel(PanelFrame()),"Unit panel layout not recognized")
    Assert(!RealHasUnitPanel(PanelFrame(false)),"Missing panel controls confirmed a purchase")
    orderCalls := [],orderStop := false,gRunning := true
    plan := [{slot:1,name:"First",enabled:true,count:1},{slot:2,name:"Second",enabled:true,count:2},{slot:3,name:"Disabled",enabled:false,count:1}]
    Assert(PlaceConfiguredBuild(plan)="complete","Ordered build did not finish")
    Assert(orderCalls.Length=5 && orderCalls[1]=1 && orderCalls[2]=1 && orderCalls[3]=2 && orderCalls[4]=2 && orderCalls[5]=2,"Failed copy was skipped or order changed")
    orderCalls := [],orderStop := false,gRunning := true,gPlacements := []
    Assert(PlaceConfiguredBuild([{slot:3,name:"Four A",enabled:true,count:4},{slot:5,name:"Four B",enabled:true,count:4}])="complete","Four-placement build failed")
    Assert(CountSlotPlacements(3)=4 && CountSlotPlacements(5)=4 && gPlacements.Length=8,"Four requested copies did not produce four recorded placements per slot")
    orderCalls := [],orderStop := false,gRunning := true,gPlacements := [],phantomReturn := true
    Assert(PlaceConfiguredBuild([{slot:3,name:"Four with phantom",enabled:true,count:4}])="complete","Ledger-checked build did not complete")
    Assert(CountSlotPlacements(3)=4 && orderCalls.Length=6,"A success return without a new record consumed one of four copies")
    orderCalls := [],orderStop := true,gRunning := true,gPlacements := []
    Assert(PlaceConfiguredBuild(plan)="stopped" && orderCalls.Length=1,"Stop advanced to another copy")
    mode := "hill-skip",orderCalls := [],orderStop := false,gRunning := true,gPlacements := [],phantomReturn := false
    plan := [{slot:3,name:"Hill only",hill:true,enabled:true,count:2},{slot:1,name:"Ground",hill:false,enabled:true,count:1}]
    Assert(PlaceConfiguredBuild(plan)="complete" && CountSlotPlacements(3)=0 && CountSlotPlacements(1)=1,"Unavailable Hill-only units blocked later ground units or were falsely counted")
    FileAppend "PASS: expanded failed areas, fast confirmation and second-row placement beside confirmed units without third-row expansion; per-game rejected coordinates survive rescans and slots, tolerate vision jitter, reset next game, and keep Hill separate; three-miss same-edge limit including along-edge attempts and rescans and opposite-side continuation; ghost reset before slot re-arm; exact four-copy counts for slots 3 and 5; unrecorded successes/stale panels rejected; slot re-pressed before every placement click, adjacent ordered attempts, next unit beside last success, confirmation wait, misses continue, late panel, cards, no-path/no-click, stop and panel detection.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
ResetCase(nextMode) {
    global gRunning,gPlacements,mode,panel,clicks,selected,saved,late,cards,cardClears,visionCalls,waits,preview
    gRunning := true,gPlacements := [],mode := nextMode,panel := false,clicks := [],selected := 0,saved := [],late := false,cards := false,cardClears := 0,visionCalls := 0,waits := []
    preview := false
    ResetPlacementSearch()
}
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 800,ch := 600
    return true
}
VisionRequest(line) {
    global mode,visionCalls
    visionCalls += 1
    if InStr(line,"placementneighbours ")=1 {
        if mode="neighbours"
            return Map("status","ok","count","1","points","468,334","normals","1,0","opposites","340,334")
        return Map("status","ok","count","0","points","")
    }
    if InStr(line,"hillspots ")=1
        return Map("status","ok","points",mode="hill-none"?"":"460,310","count",mode="hill-none"?"0":"1")
    if InStr(line,"world ")=1
        return Map("status","ok","path",mode="no-path"?"0":"100")
    if mode="straight-edge"
        return Map("status","ok","count","8","points","440,310;440,322;440,334;440,346;440,358;440,370;440,382;440,394",
            "normals","1,0;1,0;1,0;1,0;1,0;1,0;1,0;1,0",
            "opposites","340,310;340,322;340,334;340,346;340,358;340,370;340,382;340,394")
    if mode="opposite" || mode="both-blocked"
        return Map("status","ok","count","7","points","440,310;452,310;464,310;476,310;488,310;440,346;440,370",
            "normals","1,0;1,0;1,0;1,0;1,0;1,0;1,0",
            "opposites","340,310;340,322;340,334;340,346;340,358;340,346;340,370")
    if mode="jitter"
        return Map("status","ok","count","8","points","443,310;443,322;443,334;443,346;443,358;443,370;443,382;443,394")
    if mode="short-line"
        return Map("status","ok","count","1","points","440,310")
    return Map("status","ok","count","8","points","440,310;440,322;440,334;440,346;440,358;440,370;440,382;440,394")
}
VisionOk(reply) => reply && reply["status"]="ok"
CandidateOccupied(x,y) {
    global gPlacements
    for unit in gPlacements
        if Sqrt((x-unit.x)**2+(y-unit.y)**2)<24
            return true
    return false
}
FindRoblox() => 1
WinActivate(*) => 0
WinActive(*) => true
WinWaitActive(*) => true
ToScreen(x,y,&sx,&sy) {
    sx := x,sy := y
    return true
}
MouseMove(*) {
    throw Error("Placement bypassed smooth cursor movement")
}

SendEvent(keys) {
    global currentX,currentY,panel,clicks,selected,mode,cards,preview
    if keys="{q down}"
        preview := false
    if keys="{3 down}"
        selected += 1,preview := !preview
    if keys!="{LButton down}"
        return
    if (currentX=277 && currentY=216) || (currentX=740 && currentY=150) {
        panel := false
        return
    }
    if !preview
        throw Error("Placement preview was toggled OFF before clicking")
    if selected<clicks.Length+1
        throw Error("Placement click did not have a fresh slot press")
    clicks.Push({x:currentX,y:currentY})
    if (mode="neighbours" && currentX=468) || ((mode="opposite" || mode="straight-edge") && currentX=340) || (mode="both-blocked" && currentX=440 && currentY=370) || mode="hill" || mode="hill-none" || (mode="hill-fail" && currentX=440) || mode="immediate" || mode="short-line" || mode="saved-far" || mode="saved-near" || ((mode="second" || mode="cards") && clicks.Length=2)
        panel := true
    if mode="cards" && clicks.Length=1
        cards := true
}
ActionPause(*) => true
HasUnitPanel(*) {
    global panel,late
    if late
        panel := true,late := false
    return panel
}
HasCardChoice(*) {
    global cards
    return cards
}
ClearCardChoice(*) {
    global cards,cardClears
    if cards
        cardClears += 1,cards := false
    return true
}
WaitFor(test,timeout,*) {
    global mode,clicks,late,waits
    if timeout=800
        waits.Push(timeout)
    if mode="late" && timeout=800 && clicks.Length=1 {
        late := true
        return false
    }
    return test.Call()
}
RememberPlacement(unit,point,success) {
    global saved
    if !success
        throw Error("Miss recorded as success")
    saved.Push(point)
}
Log(*) => 0
class RefPixels {
    __New(*) {
        throw Error("Explicit offline fixture required")
    }
}
class PanelFrame {
    valid := true
    __New(gold := true) {
        this.gold := gold
    }
    AtRef(x,y) {
        if x>=258 && x<=294 && y>=202 && y<=234
            return 0xF02020
        if x>=82 && x<=136 && y>=365 && y<=387
            return 0xD32A2A
        if this.gold && x>=146 && x<=205 && y>=214 && y<=238
            return 0xF2CB30
        return 0x191B20
    }
}

RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}

IsUiYellow(color) {
    RGB(color, &r, &g, &b)
    return r > 185 && g > 135 && b < 115
}

IsBubbleRed(color) {
    RGB(color, &r, &g, &b)
    return r > 160 && g < 175 && b < 150 && (r - g) > 45
}

IsUiRed(color) {
    RGB(color, &r, &g, &b)
    return r > 180 && g < 100 && b < 105
}

CachedPlacementCandidates(*) {
    global mode
    if mode="saved-far"
        return [{x:700,y:450}]
    if mode="saved-near"
        return [{x:443,y:310}]
    return []
}
SmoothMoveTo(x,y) {
    global currentX,currentY,mode,panel
    currentX := x,currentY := y
    if mode="stale-panel" && x!=740
        panel := true
    return true
}
RegisterPlacedUnit(unit,point) {
    global gPlacements
    gPlacements.Push({id:gPlacements.Length+1,slot:unit.slot,name:unit.name,priority:unit.priority,target:unit.target,x:point.x,y:point.y,upgrades:0,complete:false})
    RememberPlacement(unit,point,true)
    return gPlacements[gPlacements.Length]
}

PlaceUnit(unit) {
    global orderCalls,orderStop,gRunning,gPlacements,phantomReturn,gHillPlacementUnavailable,mode
    gHillPlacementUnavailable := false
    orderCalls.Push(unit.slot)
    if mode="hill-skip" && unit.HasProp("hill") && unit.hill {
        gHillPlacementUnavailable := true
        return false
    }
    if orderStop {
        gRunning := false
        return false
    }
    if phantomReturn && orderCalls.Length=1
        return true
    success := orderCalls.Length!=1 && orderCalls.Length!=3
    if success
        gPlacements.Push({slot:unit.slot})
    return success
}

TryEndState() => false
Notify(*) => 0

IsEndGameBlocking() {
    global mode
    return mode="end-screen"
}

ClickTrace() {
    global clicks
    text := ""
    for p in clicks
        text .= p.x "," p.y ";"
    return text
}

RefreshMatchModifiers(*) => 0

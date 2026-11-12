; Deliberate placement along one local side of the in-game path.
global gPlacementLine := [],gLastPlacedIndex := 0,gPlacementPreferredSide := 0
; Screen direction toward where the enemies come from, for the current lanes.
global gPlacementUp := {x:0,y:0}
; True once the path (lit P path, else the red no-place overlay) has been
; read for the current view.
global gPathViewReady := false,gPathViewSavedThisGame := false
; A lit path counts once it covers this share of the client: real lit paths
; measure 2.4-5% in the fixtures, maps without one read 0.
global LIT_PATH_MIN_FRACTION := 0.01
; Reads in a row with neither a lit path nor a red road before giving up.
global PATH_READ_ATTEMPTS := 3,gPathReadFailures := 0,gPathReadGaveUp := false,gPathRelightTried := false
; Vision errors (no answer at all) in a row; counted apart from empty reads.
global gPathVisionErrors := 0
global gHillPlacementUnavailable := false
global gPlacementAttemptClicked := false
; Bounds on the build loop (each has a defined escalation, see
; PlaceConfiguredBuildAction): attempts at one copy before placement gives up
; on it; waits (3 s each) for a relocation that cannot start before the
; current position is accepted as the checkpoint; waits (10 s each) for Hill
; space before a Hill-only unit is given up; vision errors in a row while
; reading the path before the match is sat out; card interruptions resumed in
; one placement call.
global BUILD_COPY_ATTEMPT_LIMIT := 40,BUILD_RELOCATE_WAIT_LIMIT := 20,HILL_RETRY_LIMIT := 12
global PATH_VISION_ERROR_LIMIT := 6,CARD_RESUME_LIMIT := 5
global FAILED_PLACEMENT_RADIUS := 28
global gFailedPlacementSpots := []
global gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
global gUnitPanelClose := 0,gPendingPlacement := 0,gPlacementDebugAt := 0
global gUnitPanelLayout := 0
; True once the unit panel has been recognised on this device: from then on a
; missed panel is a real miss, not an unknown layout, so it is never re-learned
; with OCR (that read cost up to a second after every failed purchase).
global gUnitPanelSeen := false
global gUnitPreviewActive := true
; Set when a purchase failed only because Yen was short: {slot,cost,since}.
global gPlacementYenWait := 0,gUnitCosts := Map(),gUnitCostCandidates := Map()
; Hotbar geometry (800x600 reference). Slot i's cost label, and the "n/max"
; counter the game shows above the HELD unit's card, are centred on
; HOTBAR_SLOT_X[i]. The counter sits in the narrow band between the Yen text
; (centre y about 500) and the cost labels (centre y 543-559).
global HOTBAR_SLOT_X := [251,315,379,443,508,571]
global HOTBAR_COUNTER_Y_MIN := 510,HOTBAR_COUNTER_Y_MAX := 535

ResetPlacementSearch() {
    global gPlacementYenWait,gPlacementLine,gLastPlacedIndex,gPendingPlacement,gPlacementPreferredSide,gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses,gPathViewReady,gPathViewSavedThisGame
    global gPathReadFailures,gPathReadGaveUp,gPathRelightTried,gPathVisionErrors
    gPathViewReady := false,gPathViewSavedThisGame := false
    gPathVisionErrors := 0
    gPathReadFailures := 0,gPathReadGaveUp := false,gPathRelightTried := false
    gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
    gPlacementLine := [],gLastPlacedIndex := 0,gPendingPlacement := 0,gPlacementPreferredSide := 0
    gPlacementYenWait := 0
}

RefreshPlacementSearch() {
    global gPlacementLine,gLastPlacedIndex,gLayoutValidation,gPathViewReady
    ; A rescan or a moved view reads the red overlay again.
    gPathViewReady := false
    ; Keep confirmed units, failed spots AND unresolved purchases across rescans.
    ; Only ResetPlacementSearch at the next build clears failure memory.
    gPlacementLine := [],gLastPlacedIndex := 0
    gLayoutValidation := Map()
}

FindPlacementCandidates(acrossRoad := true) {
    global gPlacementLine,gLastPlacedIndex,gPlacementPreferredSide,REF_W,REF_H,gPlacementUp
    if !gPlacementLine.Length {
        if !GetClient(&cx,&cy,&cw,&ch)
            return []
        scene := VisionRequest("world " cx " " cy " " cw " " ch)
        if !VisionOk(scene) || scene["path"]="0" {
            PlacementSearchDiagnostic("No illuminated world path detected; no slot or placement click sent.")
            return []
        }
        ; With a known enemy direction the vision returns a front lane (toward
        ; the enemies) and a behind lane (toward the base).
        up := PlacementUpstreamDirection(),gPlacementUp := up
        reply := VisionRequest("placementline 48 " PlacementSearchExclusions(false) " " PlacementSearchExclusions(true) " " PlacementBlockedEdgeExclusions() " " Round(up.x,3) " " Round(up.y,3))
        if !VisionOk(reply) || !reply.Has("points") || reply["points"]="" || !reply.Has("count") || Number(reply["count"])<1 {
            PlacementSearchDiagnostic("Visible path found, but no nearby edge fits the player view; no slot or placement click sent.")
            return []
        }
        for text in StrSplit(reply["points"],";") {
            xy := StrSplit(text,",")
            point := {x:Round(Number(xy[1])*REF_W/cw),
                y:Round(Number(xy[2])*REF_H/ch),index:gPlacementLine.Length+1,side:0,row:1}
            if reply.Has("front")
                point.lane := point.index<=Number(reply["front"])?"front":"behind"
            AddPlacementGeometry(point,reply,point.index,cw,ch)
            gPlacementLine.Push(point)
        }
        first := gPlacementLine[1]
        if reply.Has("front")
            Log("Path-side lanes: " reply["front"] " spots in front (toward the enemies), " (gPlacementLine.Length-Number(reply["front"])) " behind; the less filled side goes first.")
        else if !StartLineAtNewestEdgeUnit()
            Log("Start beside the player at " first.x "," first.y "; follow one path edge in adjacent steps.")
    }
    points := []
    for index in PlacementLaneOrder() {
        point := gPlacementLine[index]
        if gPlacementPreferredSide=1 && point.HasProp("other")
            point := OppositePlacementPoint(point)
        point := UsablePlacementPoint(point,acrossRoad)
        if point
            points.Push(point)
    }
    ; A used-up edge can still have free positions across the road.
    if !points.Length && acrossRoad {
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

; Order of edge spots to try. With front/behind lanes: the side holding fewer
; edge units goes first (front on a tie), then the two sides alternate,
; nearest the player first, so a miss on one side is followed by a try on the
; other instead of squeezing further into the same area. Without lanes: onward
; from the last placed edge unit, then back along the same edge.
PlacementLaneOrder() {
    global gPlacementLine,gLastPlacedIndex,gPlacementUp
    order := []
    if !gPlacementLine.Length || !gPlacementLine[1].HasProp("lane") {
        index := gLastPlacedIndex+1
        while index<=gPlacementLine.Length
            order.Push(index++)
        index := gLastPlacedIndex-1
        while index>=1
            order.Push(index--)
        return order
    }
    front := [],behind := []
    for point in gPlacementLine {
        if point.lane="front"
            front.Push(point.index)
        else
            behind.Push(point.index)
    }
    ; Which side each edge unit is on, seen from the player (screen centre).
    inFront := 0,inBehind := 0
    for item in EdgeAnchors() {
        if (item.x-400)*gPlacementUp.x+(item.y-300)*gPlacementUp.y>=0
            inFront += 1
        else
            inBehind += 1
    }
    first := inBehind<inFront?behind:front
    second := inBehind<inFront?front:behind
    Loop Max(first.Length,second.Length) {
        if A_Index<=first.Length
            order.Push(first[A_Index])
        if A_Index<=second.Length
            order.Push(second[A_Index])
    }
    return order
}

; Two rows only. Row 1 sits on the path edge; row 2 is ONE partner spot
; straight behind a row-1 unit. Roles come from the record (item.row), never
; from re-measuring the road, so a row-2 unit can never anchor anything.
; Hill and Money units are never anchors.
EdgeAnchors() {
    global gPlacements
    anchors := []
    for item in gPlacements {
        if !PlacementAnchorKnown(item) || !item.HasProp("row") || item.row!=1
            || (item.HasProp("hill") && item.hill) || (item.HasProp("money") && item.money)
            continue
        anchors.Push(item)
    }
    return anchors
}

NewestEdgeAnchor() {
    anchors := EdgeAnchors()
    return anchors.Length?anchors[anchors.Length]:0
}

PartnerOpen(anchor) => !anchor.HasProp("partner") || anchor.partner=""

; A rebuilt line continues beside the newest edge unit instead of beside the
; player, when that unit is on the visible edge (or across the same road).
StartLineAtNewestEdgeUnit() {
    global gPlacementLine,gLastPlacedIndex,gPlacementPreferredSide
    anchor := NewestEdgeAnchor()
    if !anchor
        return false
    best := 0,bestDistance := 30**2,side := 0
    for point in gPlacementLine {
        for candidate in [point,point.HasProp("other")?point.other:0] {
            if !candidate
                continue
            distance := (candidate.x-anchor.x)**2+(candidate.y-anchor.y)**2
            if distance<bestDistance
                best := point,bestDistance := distance,side := candidate=point?0:1
        }
    }
    if !best
        return false
    gLastPlacedIndex := best.index,gPlacementPreferredSide := side
    Log("Continue along the edge beside #" anchor.id " " anchor.name " at " anchor.x "," anchor.y ".")
    return true
}

; The single spot straight behind an edge unit: [] when there is none, false
; when the view cannot be read right now (the spot then stays open).
FindPartnerCandidate(anchor) {
    global REF_W,REF_H
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    scene := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(scene) || scene["path"]="0"
        return false
    reply := VisionRequest("placementneighbours " Round(anchor.x) "," Round(anchor.y) " " PlacementSearchExclusions(false) " " PlacementSearchExclusions(true) " " PlacementBlockedEdgeExclusions())
    if !VisionOk(reply)
        return false
    points := []
    if !reply.Has("points") || reply["points"]=""
        return points
    xy := StrSplit(StrSplit(reply["points"],";")[1],",")
    point := {x:Round(Number(xy[1])*REF_W/cw),y:Round(Number(xy[2])*REF_H/ch),side:0,row:2,anchor:anchor.id}
    AddPlacementGeometry(point,reply,1,cw,ch)
    ; A partner never crosses the road.
    if point.HasProp("other")
        point.DeleteProp("other")
    if !CandidateOccupied(point.x,point.y) && !FailedPlacementSpot(point) && !BlockedPlacementEdge(point)
        points.Push(point)
    return points
}

; One try behind this edge unit. A miss closes only that partner spot; it
; never blocks the edge, and the next unit continues along the edge.
TryPartnerPlacement(unit,anchor) {
    global gPlacementYenWait,gPendingPlacement,gCardInterruptEpoch
    ; At the failure limit relocation comes first; the spot stays open.
    if PlacementFailureLimitReached()
        return false
    points := FindPartnerCandidate(anchor)
    if !IsObject(points)
        return false
    if !points.Length {
        anchor.partner := "closed"
        Log(unit.name ": no free spot straight behind #" anchor.id "; that partner spot is closed for this game.")
        SavePlacementRun()
        return false
    }
    Log(unit.name ": one try straight behind #" anchor.id " " anchor.name ".")
    before := CountSlotPlacements(unit.slot),epoch := gCardInterruptEpoch
    if TryPlacementPoints(unit,points)
        return true
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    ; Unresolved purchases, card interruptions and a lack of Yen keep the spot open.
    if gPendingPlacement || CountSlotPlacements(unit.slot)>before || epoch!=gCardInterruptEpoch || (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
        return false
    anchor.partner := "closed"
    Log(unit.name ": the spot behind #" anchor.id " did not take a unit; closed for this game. Continue along the edge.")
    SavePlacementRun()
    return false
}

; Money units have a large area: a path-edge spot as far as possible from
; every placed unit (or from the player when nothing is placed yet).
MoneySpotScore(point) {
    global gPlacements
    best := -1
    for item in gPlacements {
        if !PlacementAnchorKnown(item)
            continue
        distance := Sqrt((point.x-item.x)**2+(point.y-item.y)**2)
        best := best<0?distance:Min(best,distance)
    }
    return best<0?Sqrt((point.x-400)**2+(point.y-300)**2):best
}

PlaceMoneyUnit(unit) {
    global gPendingPlacement,gRunning
    points := FindPlacementCandidates(true)
    if !points.Length {
        Log(unit.name ": no untried local path-side spots for the Money unit.")
        return false
    }
    ranked := []
    for point in points {
        score := MoneySpotScore(point),at := ranked.Length+1
        for index,entry in ranked {
            if score>entry.score {
                at := index
                break
            }
        }
        ranked.InsertAt(at,{point:point,score:score})
    }
    ordered := []
    for entry in ranked
        ordered.Push(entry.point)
    Log(unit.name ": Money unit; path-edge spot farthest from the other units first.")
    if TryPlacementPoints(unit,ordered)
        return true
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    if gRunning
        CancelUnitPreview()
    return false
}

PlacementTerrain(point) => point.HasProp("hill") && point.hill?"hill":"ground"

; -----------------------------------------------------------------------------
; Yen and the hotbar. One OCR call covers the Yen counter above the toolbar,
; the "n/max" counter above the held unit's card and the cost under each of the
; six slot portraits (800x600 reference layout). The purchase flow reads it
; before and after every purchase click (PurchaseVerifier.ahk).
; -----------------------------------------------------------------------------
ReadPlacementMoney() {
    global REF_W,REF_H,HOTBAR_SLOT_X,HOTBAR_COUNTER_Y_MIN,HOTBAR_COUNTER_Y_MAX
    result := {yen:-1,costs:Map(),counterWords:[]}
    geometry := WindowGeometry()
    if !geometry
        return result
    rows := ReadOcrRows(205,484,595,562,true,4)
    yenWords := [],slotWords := Map()
    ; Cost text sits in the lower right of each portrait.
    costX := HOTBAR_SLOT_X
    for word in rows {
        x := (word.x+word.w/2)*REF_W/geometry.cw,y := (word.y+word.h/2)*REF_H/geometry.ch
        if y>=484 && y<HOTBAR_COUNTER_Y_MIN && x>=340 && x<=470 {
            yenWords.Push({x:x,text:word.text})
            continue
        }
        ; The held unit's counter: left/right edges kept so split words can be rejoined.
        if y>=HOTBAR_COUNTER_Y_MIN && y<=HOTBAR_COUNTER_Y_MAX {
            result.counterWords.Push({l:word.x*REF_W/geometry.cw,r:(word.x+word.w)*REF_W/geometry.cw,text:word.text})
            continue
        }
        if y<543 || y>559
            continue
        slot := 0,gap := 30
        for index,centre in costX
            if Abs(x-centre)<gap
                slot := index,gap := Abs(x-centre)
        if slot {
            if !slotWords.Has(slot)
                slotWords[slot] := []
            slotWords[slot].Push({x:x,text:word.text})
        }
    }
    result.yen := DigitsValue(yenWords,0,10000000)
    for slot,words in slotWords {
        cost := DigitsValue(words,50,100000)
        if cost>=0
            result.costs[slot] := cost
    }
    return result
}

; Words left to right, joined: the first run of digits ("13 50" is 1350,
; "9,401" is 9401). -1 when there is none or it is implausible.
DigitsValue(words,low,high) {
    sorted := []
    for word in words {
        at := sorted.Length+1
        for index,other in sorted
            if word.x<other.x {
                at := index
                break
            }
        sorted.InsertAt(at,word)
    }
    text := ""
    for word in sorted
        text .= word.text
    text := RegExReplace(text,"[,.\s]")
    if !RegExMatch(text,"\d{1,8}",&match)
        return -1
    value := Integer(match[0])
    return value>=low && value<=high?value:-1
}

; A unit's placement cost, remembered by unit name in learning.ini. A new
; value is believed only when two reads agree; until then the saved one stands.
UnitPlacementCost(unit,read) {
    global gUnitCosts,gUnitCostCandidates,LEARNING_FILE
    key := MemoryKey(unit.name)
    if !gUnitCosts.Has(key) {
        saved := MemoryRead("UnitCosts",key,"")
        if IsInteger(saved) && Integer(saved)>0
            gUnitCosts[key] := Integer(saved)
    }
    known := gUnitCosts.Has(key)?gUnitCosts[key]:0
    if !read.costs.Has(unit.slot)
        return known
    seen := read.costs[unit.slot]
    if seen=known
        return known
    if gUnitCostCandidates.Has(key) && gUnitCostCandidates[key]=seen {
        gUnitCosts[key] := seen,gUnitCostCandidates.Delete(key)
        try IniWrite seen,LEARNING_FILE,"UnitCosts",key
        Log(unit.name ": placement cost " seen " Yen (read twice on slot " unit.slot ").")
        return seen
    }
    gUnitCostCandidates[key] := seen
    return known
}

; Called BEFORE a purchase click, while the unit is held, with the hotbar state
; ReadPurchaseState read (Yen needs two agreeing reads). True when Yen is below
; the unit's cost: no click is sent, no failure is counted, the spot stays
; usable and the build loop waits for Yen (WaitForPlacementYen). An unreadable
; Yen or an unknown cost does not block the click: the slot counter after the
; click decides.
PlacementShortOfYen(unit,state) {
    global gPlacementYenWait
    if state.cost<=0 || state.yen<0 || state.yen>=state.cost
        return false
    gPlacementYenWait := {slot:unit.slot,cost:state.cost,since:A_TickCount}
    Log(unit.name ": " state.yen " of " state.cost " Yen; no purchase click. Wait for Yen, then place this unit.")
    return true
}

; After a Yen-short check: re-read the counter about once a second until the
; unit is affordable (at most 20 s, or 3 unreadable reads), then retry. The
; retry checks Yen again (two agreeing reads) before it clicks.
WaitForPlacementYen(unit) {
    global gPlacementYenWait,gRunning
    if !IsSet(gPlacementYenWait) || !gPlacementYenWait || gPlacementYenWait.slot!=unit.slot
        return false
    wait := gPlacementYenWait,unread := 0
    while gRunning && A_TickCount-wait.since<20000 && !IsEndGameBlocking() {
        if HasCardChoice() {
            ClearCardChoice()
            ActionPause(150)
            continue
        }
        if !ActionPause(1000)
            break
        yen := ReadPlacementMoney().yen
        if yen>=wait.cost {
            Log(unit.name ": " yen " Yen; affordable now.")
            break
        }
        unread += yen<0?1:0
        if unread>=3
            break
    }
    gPlacementYenWait := 0
    return true
}

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

PlacementSearchExclusions(occupied) {
    global gFailedPlacementSpots,gPlacements
    text := "",points := occupied?gPlacements:gFailedPlacementSpots
    for point in points {
        if occupied && !PlacementAnchorKnown(point)
            continue
        if !occupied && point.terrain!="ground"
            continue
        text .= (text=""?"":";") Round(point.x) "," Round(point.y)
        ; A Money unit is about 3 units across: ring its centre so vision keeps
        ; the same wider gap as CandidateOccupied.
        if occupied && point.HasProp("money") && point.money
            for offset in [[24,0],[-24,0],[0,24],[0,-24]]
                text .= ";" Round(point.x+offset[1]) "," Round(point.y+offset[2])
    }
    return text=""?"-":text
}

UsablePlacementPoint(point,acrossRoad := true) {
    ; Skip the whole rejected patch; do not test tiny shifts inside it.
    if FailedPlacementSpot(point)
        return 0
    if !CandidateOccupied(point.x,point.y) && !BlockedPlacementEdge(point)
        return point
    if acrossRoad && point.HasProp("other") {
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


PlacementClickRef(rx,ry,guardCards := false,purchase := 0,allowUnitPanel := false) {
    global gRunning,gPendingPlacement,gPlacementAttemptClicked,UNIT_ACTION_MS
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
    ; Start moving while input is idle. The click still waits after arrival.
    if !SmoothMoveTo(sx,sy,UNIT_ACTION_MS,UNIT_ACTION_MS,false)
        return false
    if !BeginInputAction(true,UNIT_ACTION_MS) || (guardCards && (HasCardChoice() || (!allowUnitPanel && HasUnitPanel()) || IsEndGameBlocking()))
        return false
    if purchase {
        ; Card handling during cursor movement may have confirmed this copy.
        if !PlacementPurchaseReady(purchase)
            return false
        gPendingPlacement := purchase,gPlacementAttemptClicked := true
    }
    SendEvent "{LButton down}"
    try return ActionPause(UNIT_ACTION_MS,false)
    finally {
        SendEvent "{LButton up}"
        EndInputAction()
    }
}

PlacementPurchaseReady(purchase) {
    global gRunning,gPendingPlacement
    count := CountSlotPlacements(purchase.pendingSlot)
    return gRunning && !gPendingPlacement && !PlacementFailureLimitReached() && count<purchase.pendingTarget && count+1=purchase.pendingCopy
}


SelectPlacementUnit(unit) {
    global gRunning,gUnitPreviewActive,UNIT_ACTION_MS
    if !gRunning || !BeginInputAction(true,UNIT_ACTION_MS)
        return false
    SendEvent "{" unit.slot " down}"
    try {
        if !ActionPause(UNIT_ACTION_MS,false)
            return false
    } finally {
        SendEvent "{" unit.slot " up}"
        gUnitPreviewActive := true
        EndInputAction()
    }
    return gRunning
}


CancelUnitPreview() {
    global gRunning,gUnitPreviewActive,UNIT_ACTION_MS
    if !gRunning
        return false
    if !gUnitPreviewActive
        return true
    if !BeginInputAction(true,UNIT_ACTION_MS)
        return false
    SendEvent "{q down}"
    try {
        if !ActionPause(UNIT_ACTION_MS,false)
            return false
    } finally {
        SendEvent "{q up}"
        gUnitPreviewActive := false
        EndInputAction()
    }
    return gRunning
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


HasUnitPanel(frame := 0) {
    global gUnitPanelClose,gUnitPanelLayout,gUnitPanelSeen
    if gUnitPanelLayout {
        heading := UnitPanelRegion("header"),sell := UnitPanelRegion("sell")
        learned := frame?frame:RefPixels(Min(heading[1],sell[1]),Min(heading[2],sell[2]),Max(heading[3],sell[3]),Max(heading[4],sell[4]))
        if learned.valid && UnitPanelColourHits(learned,heading[1],heading[2],heading[3],heading[4],IsUiYellow)>=4
            && UnitPanelColourHits(learned,sell[1],sell[2],sell[3],sell[4],IsBubbleRed)>=4
            return gUnitPanelSeen := true
    }
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
    return gUnitPanelSeen := true
}

UnitPanelRegion(name) {
    global gUnitPanelLayout
    if gUnitPanelLayout && GetClient(&cx,&cy,&cw,&ch) && gUnitPanelLayout.size=cw "," ch
        return gUnitPanelLayout.%name%
    defaults := Map("header",[137,210,215,246],"button",[145,340,265,395],"sell",[25,365,140,387])
    return defaults[name]
}

WaitForUnitPanel(timeout := 700,learn := true) {
    global gRunning,gUnitPanelLayout,gUnitPanelSeen,REF_W,REF_H
    if WaitFor(HasUnitPanel,timeout,60)
        return true
    if !learn || gUnitPanelSeen || !gRunning || HasCardChoice() || !GetClient(&cx,&cy,&cw,&ch)
        return false
    header := 0,sell := 0,button := 0
    for row in ReadOcrRows(0,100,340,520) {
        text := NormalizeWords(row.text)
        rect := [Max(0,Floor(row.x*REF_W/cw)-6),Max(0,Floor(row.y*REF_H/ch)-6),
            Min(340,Ceil((row.x+row.w)*REF_W/cw)+10),Min(520,Ceil((row.y+row.h)*REF_H/ch)+6)]
        if RegExMatch(text,"\bu\s*p\s*[g69](?:\s|$|[0-9])") {
            rect[3] := Min(340,Max(rect[3],rect[1]+78))
            header := rect
        }
        if RegExMatch(text,"\bsell\b")
            sell := rect
        if RegExMatch(text,"\bupgrade\b|^max(?:ed)?$")
            button := rect
    }
    if !header || !sell || !button || HasCardChoice()
        return false
    gUnitPanelLayout := {size:cw "," ch,header:header,sell:sell,button:button}
    Log("Learned unit panel header and buttons for this device/window.")
    return HasUnitPanel()
}


ClickAwayFromUnitPanel() {
    global gUpgradeSelectedId,CLICK_AWAY_X,CLICK_AWAY_Y
    ; Empty world between "Return to lobby" and the open F manager, above the
    ; cards and outside the unit panel. It never touches the manager, so the
    ; manager stays open; F is never pressed here.
    ; Drop any preview first so this click can never purchase a unit.
    gUpgradeSelectedId := 0
    if !CancelUnitPreview() || !PlacementClickRef(CLICK_AWAY_X,CLICK_AWAY_Y)
        return false
    return WaitFor(() => !HasUnitPanel(),550,40)
}

CloseUnitPanel() {
    if !HasUnitPanel()
        return true
    return ClickAwayFromUnitPanel()
}

; Cards: the side unit panel draws OVER the left card (its "769K" damage was
; read as card 1's text) and a click on empty world does not close it while
; the cards are up. Its own red X does. The X sits where card 1 is, so it is
; clicked only when the panel is detected.
CloseUnitPanelForCards() {
    global gUpgradeSelectedId,gUnitPanelClose
    if !HasUnitPanel()
        return true
    gUpgradeSelectedId := 0
    x := gUnitPanelClose?gUnitPanelClose.x:264,y := gUnitPanelClose?gUnitPanelClose.y:210
    if !PlacementClickRef(x,y,false,0,true)
        return false
    if WaitFor(() => !HasUnitPanel(),700,50)
        return true
    Log("Side unit panel still open over the left card after its X.")
    return false
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

; Records a purchase the PurchaseVerifier confirmed. evidence says what proved
; it (slot counter, Yen drop or unit panel) and goes into the PlacedUnits log.
FinishPlacement(unit,point,evidence) {
    global gPlacementYenWait,gPendingPlacement,gLastPlacedIndex,gPlacementPreferredSide,gPlacementEdgeMisses,gPlacements
    if !point || CandidateOccupied(point.x,point.y)
        return false
    if HasCardChoice()
        return false
    if !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || point.pendingCopy!=CountSlotPlacements(unit.slot)+1 {
        Log("Ignored purchase evidence without the matching pending slot/copy purchase.")
        return false
    }
    ; The purchase is confirmed: drop the hovering ghost before bookkeeping.
    if !CancelUnitPreview() || gPendingPlacement!=point || HasCardChoice()
        return false
    if !RegisterPlacedUnit(unit,point,evidence)
        return false
    if PlacementTerrain(point)="hill"
        RememberHillOutcome(point,true)
    gPlacementYenWait := 0
    ResetPlacementFailureStreak()
    terrain := PlacementTerrain(point)
    if gPlacementEdgeMisses.Has(terrain)
        gPlacementEdgeMisses.Delete(terrain)
    ; A Money unit sits apart on purpose; the line keeps growing from the
    ; last ordinary edge unit, not from her.
    if point.HasProp("index") && !(unit.HasProp("money") && unit.money) {
        gLastPlacedIndex := point.index
        gPlacementPreferredSide := point.HasProp("side")?point.side:0
    }
    gPendingPlacement := 0
    ClickAwayFromUnitPanel()
    return ActionPause(100)
}


TryPlacementCandidate(unit,candidate) {
    global gRunning,gCardInterruptEpoch,gPlacementAttemptClicked,gPendingPlacement
    gPlacementAttemptClicked := false
    if !gRunning || IsEndGameBlocking()
        return false
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    resumes := 0
    loop {
        epoch := gCardInterruptEpoch,before := CountSlotPlacements(unit.slot)
        result := TryPlacementCandidateAction(unit,candidate)
        if !result && gRunning && HasCardChoice() {
            if !ClearCardChoice()
                return false
            RecoverPendingPlacement(unit)
        }
        if CountSlotPlacements(unit.slot)>before
            return true
        if epoch=gCardInterruptEpoch || !gRunning {
            return result
        }
        ; The interruption cancelled input; retry this unfinished copy/spot,
        ; but only CARD_RESUME_LIMIT times per call.
        if ++resumes>CARD_RESUME_LIMIT {
            Log(unit.name ": card interruptions resumed " CARD_RESUME_LIMIT " times for this spot; handing back to the build loop.")
            return result
        }
    }
}

TryPlacementCandidateAction(unit,candidate) {
    global gRunning,gPendingPlacement,gPlacementAttemptClicked
    gPlacementAttemptClicked := false
    before := CountSlotPlacements(unit.slot)
    if !gRunning || before>=SlotTargetCount(unit)
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
    if PlacementFailureLimitReached() || FailedPlacementSpot(candidate)
        return false
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
    ; Holding the unit: read its slot counter and Yen BEFORE the click (Yen
    ; needs two agreeing reads). Short of Yen: no click, wait for Yen instead.
    start := ReadPurchaseState(unit)
    if SlotCounterFull(start.counter) {
        ; The game says this slot is full, so the record is behind (or the
        ; game's limit is below the configured count). No click: it could
        ; only be refused. Not a failure and no spot is blacklisted; the
        ; slot is reconciled with its counter instead.
        CancelUnitPreview()
        ReconcileSlot(unit,start.counter,"slot already full before the click")
        return CountSlotPlacements(unit.slot)>before
    }
    if PlacementShortOfYen(unit,start) {
        CancelUnitPreview()
        return false
    }
    if !gRunning || HasCardChoice()
        return false
    purchase := candidate.Clone()
    purchase.pendingSlot := unit.slot,purchase.pendingCopy := before+1,purchase.pendingTarget := unit.count
    purchase.counterBefore := start.counter,purchase.yenBefore := start.yen,purchase.cost := start.cost,purchase.probes := 0
    if !PlacementClickRef(candidate.x,candidate.y,true,purchase) && !gPendingPlacement {
        ; Nothing was clicked: only the held unit is left to drop.
        CancelUnitPreview()
        return false
    }
    ; The click is sent. Evidence (counter, Yen, weak panel) decides what it did.
    return RecoverPendingPlacement(unit)
}

TrySelectUnitAt(point,timeout := 450,learn := false) {
    global gRunning
    return gRunning && !HasCardChoice() && PlacementClickRef(point.x,point.y,true) && WaitForUnitPanel(timeout,learn)
}

; Resolves an unresolved purchase from evidence (PurchaseVerifier.ahk). Never
; clicks the field: clicking the spot again could select an existing unit.
;  confirmed -> RegisterPlacedUnit through FinishPlacement
;  denied    -> failed purchase, the spot is blacklisted
;  unknown   -> probed again, at most PURCHASE_REPROBE_LIMIT more times, then a
;               failed attempt that does NOT blacklist the spot
; A card, F7 or the end screen mid-probe leaves the purchase pending.
RecoverPendingPlacement(unit) {
    global gRunning,gPendingPlacement,gCardInterruptEpoch,PURCHASE_REPROBE_LIMIT
    point := gPendingPlacement
    if !gRunning || !point || !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || point.pendingCopy!=CountSlotPlacements(unit.slot)+1 || HasCardChoice()
        return false
    before := CountSlotPlacements(unit.slot),epoch := gCardInterruptEpoch
    loop {
        point.probes := (point.HasProp("probes")?point.probes:0)+1
        judged := ProbePurchase(unit,point)
        ; A card handler inside the probe may already have recorded the unit.
        if CountSlotPlacements(unit.slot)>before
            return true
        if !gRunning || HasCardChoice() || IsEndGameBlocking() || epoch!=gCardInterruptEpoch || gPendingPlacement!=point
            return false
        if judged.verdict="confirmed" {
            Log(unit.name ": purchase confirmed by " judged.by ".")
            if FinishPlacement(unit,point,judged.by)
                return true
            if !gRunning || HasCardChoice() || IsEndGameBlocking()
                return false
            ; Confirmed but not recordable (a recorded unit already stands here):
            ; never loop on it. Counted as a failed attempt, the spot is not blamed.
            Log(unit.name ": the purchase was confirmed but could not be recorded at " point.x "," point.y "; counted as a failed attempt.")
            gPendingPlacement := 0
            RecordFailedPlacement(unit,point)
            return false
        }
        if judged.verdict="denied" {
            Log(unit.name ": no unit bought at " point.x "," point.y " (" judged.by "); spot rejected.")
            gPendingPlacement := 0
            CloseUnitPanel()
            CancelUnitPreview()
            RecordFailedPlacement(unit,point)
            RememberFailedPlacementSpot(point)
            if PlacementTerrain(point)="hill"
                RememberHillOutcome(point,false)
            return false
        }
        if point.probes>PURCHASE_REPROBE_LIMIT
            break
        Log(unit.name ": purchase at " point.x "," point.y " still unknown (probe " point.probes "); reading again.")
    }
    Log(unit.name ": purchase at " point.x "," point.y " stayed unknown after " point.probes " probes; counted as a failed attempt, the spot is not blacklisted.")
    gPendingPlacement := 0
    CloseUnitPanel()
    CancelUnitPreview()
    RecordFailedPlacement(unit,point)
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
            || (item.HasProp("money") && item.money)
            continue
        seeds .= (seeds=""?"":";") item.x "," item.y
    }
    row := candidate.HasProp("row")?candidate.row:1
    reply := VisionRequest("placementvalid " candidate.x " " candidate.y " " row " " (seeds=""?"-":seeds))
    if !VisionOk(reply)
        return false
    if reply["valid"]="1"
        return true
    candidate.pathRejected := true
    Log("Reject stale/off-path coordinate " candidate.x "," candidate.y "; no placement click sent.")
    RememberFailedPlacementSpot(candidate)
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
    ; Each miss blocks 48 px either way along the edge, so the whole stretch
    ; the misses walked (a building wall) is blocked end to end.
    for attempted in state.attempts
        gPlacementBlockedEdges.Push({point:attempted,terrain:terrain})
    gPlacementEdgeMisses.Delete(terrain)
    return state.attempts
}

TryPlacementPoints(unit,points,replanStaleLine := false) {
    global gPlacementYenWait,gRunning,gPlacementAttemptClicked,gPendingPlacement
    queue := points.Clone(),seen := Map(),stale := 0
    while queue.Length {
        if !gRunning || IsEndGameBlocking()
            return false
        if PlacementFailureLimitReached()
            return false
        if gPendingPlacement
            return RecoverPendingPlacement(unit)
        if CountSlotPlacements(unit.slot)>=SlotTargetCount(unit)
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
        ; Not enough Yen: other spots would fail the same way, and this miss
        ; must not block the edge.
        if (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
            return false
        if !gPlacementAttemptClicked {
            if replanStaleLine && point.HasProp("pathRejected") && ++stale>=2 {
                Log("Two path-side spots no longer fit the visible road; refresh the lane before trying this copy again.")
                return false
            }
            continue
        }
        if point.HasProp("row") && point.row=2
            continue
        misses := RegisterPlacementEdgeMiss(point)
        if !misses.Length
            continue
        Log(unit.name ": 3 failed placement clicks on this edge. Block that whole stretch for this game; the next tries go to the opposite side or another edge.")
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
            if distance<=bestDistance && !CandidateOccupied(candidate.x,candidate.y) && !FailedPlacementSpot(candidate)
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

PlaceUnit(unit) {
    global gCardAction,gPlacementActiveUnit,gCardInterruptEpoch,gRunning
    previous := gCardAction,previousUnit := gPlacementActiveUnit
    gCardAction := "placement",gPlacementActiveUnit := unit
    try {
        resumes := 0
        loop {
            epoch := gCardInterruptEpoch,before := CountSlotPlacements(unit.slot)
            result := PlaceUnitAction(unit)
            if !result && gRunning && HasCardChoice() {
                if !ClearCardChoice()
                    return false
                RecoverPendingPlacement(unit)
            }
            if CountSlotPlacements(unit.slot)>before
                return true
            if epoch=gCardInterruptEpoch || !gRunning
                return result
            if ++resumes>CARD_RESUME_LIMIT {
                Log(unit.name ": card interruptions resumed " CARD_RESUME_LIMIT " times for this copy; handing back to the build loop.")
                return result
            }
        }
    } finally {
        gCardAction := previous,gPlacementActiveUnit := previousUnit
    }
}

; The path comes from the lit P path FIRST, read with nothing held so green
; Hill highlights never count. Only when no lit path shows (maps without one)
; does the red no-place overlay take over, shown only while a unit is held:
; select the slot, move the cursor onto the HUD so the held unit's own preview
; ring does not cover the road, read the road and every red area (pathview),
; then cancel the hold. Every later placement check reuses this view until a
; rescan or a moved view. PATH_READ_ATTEMPTS reads in a row with neither
; source save the frame and give up (the build then sits the match out).
RefreshPathView(unit) {
    global gPathViewReady,gPathViewSavedThisGame,gPathReadFailures,gPathReadGaveUp,PATH_READ_ATTEMPTS,LIT_PATH_MIN_FRACTION
    global gPathLit,gPathRelightTried,gPathVisionErrors,PATH_VISION_ERROR_LIMIT
    if gPathViewReady
        return true
    if !GetClient(&cx,&cy,&cw,&ch) || !CloseUnitPanel() || !CancelUnitPreview() || HasCardChoice()
        return false
    ; Drop any earlier red view first, or the lit read would just return it.
    VisionRequest("pathviewclear")
    lit := VisionRequest("world " cx " " cy " " cw " " ch)
    if VisionOk(lit) && Number(lit["path"])>=cw*ch*LIT_PATH_MIN_FRACTION {
        gPathViewReady := true,gPathReadFailures := 0
        Log("Path read from the lit P path.")
        return true
    }
    if !gPathLit && !gPathRelightTried {
        ; The match-start P click may not have registered: try P once more
        ; before the red overlay (which can also fail, e.g. in a blizzard).
        gPathRelightTried := true
        Log("No lit P path in view and P was never confirmed on; try P again before the red overlay.")
        if EnsurePathLit() && gPathLit && ActionPause(400) && GetClient(&cx,&cy,&cw,&ch) {
            lit := VisionRequest("world " cx " " cy " " cw " " ch)
            if VisionOk(lit) && Number(lit["path"])>=cw*ch*LIT_PATH_MIN_FRACTION {
                gPathViewReady := true,gPathReadFailures := 0
                Log("Path read from the lit P path.")
                return true
            }
        }
    }
    Log("No lit P path in view; fall back to the red no-place overlay.")
    if !SelectPlacementUnit(unit)
        return false
    if ToScreen(400,60,&sx,&sy)
        SmoothMoveTo(sx,sy)
    ok := ActionPause(300) && !HasCardChoice()
    reply := ok?VisionRequest("pathview " cx " " cy " " cw " " ch):false
    CancelUnitPreview()
    if VisionOk(reply) && reply["path"]!="0" {
        gPathViewReady := true,gPathReadFailures := 0
        Log("Path read from the red no-place overlay while holding " unit.name ".")
        ; One debug image per game: the first read, as the macro saw it.
        if !gPathViewSavedThisGame {
            gPathViewSavedThisGame := true
            SavePathViewDebug()
        }
        return true
    }
    if ok {
        ; A completed read that found nothing counts toward giving up. So does
        ; a vision call with no answer, but only PATH_VISION_ERROR_LIMIT of
        ; them in a row: past that the match is sat out like an empty path.
        if VisionOk(reply) {
            gPathVisionErrors := 0
            gPathReadFailures += 1
            Log("No lit P path and no red road (" gPathReadFailures "/" PATH_READ_ATTEMPTS "); no placement click sent.")
            if gPathReadFailures>=PATH_READ_ATTEMPTS {
                gPathReadGaveUp := true
                SavePathReadFailure()
                return false
            }
        } else {
            gPathVisionErrors += 1
            Log("The vision service gave no answer for the path read (" gPathVisionErrors "/" PATH_VISION_ERROR_LIMIT ").")
            if gPathVisionErrors>=PATH_VISION_ERROR_LIMIT {
                gPathReadGaveUp := true
                Log("The path could not be read " PATH_VISION_ERROR_LIMIT " times in a row; giving up on it.")
                return false
            }
        }
        ActionPause(1000)
    }
    return false
}

; cache\pathfail-<date_time>.png: the raw frame of the last failed red read
; (unit held), for checking why neither path source was found.
SavePathReadFailure() {
    DirCreate A_ScriptDir "\cache"
    file := A_ScriptDir "\cache\pathfail-" FormatTime(A_Now,"yyyy-MM-dd_HH-mm-ss") ".png"
    reply := VisionRequest("pathfaildebug " file)
    if VisionOk(reply) && reply["saved"]="1"
        Log("Saved the frame where no path was found: " file)
    PruneCacheImages("pathfail-*.png",10)
}

; Names sort by time: delete the oldest matching cache images beyond keep.
PruneCacheImages(pattern,keep) {
    files := []
    try Loop Files A_ScriptDir "\cache\" pattern
        files.Push(A_LoopFileFullPath)
    if files.Length<=keep
        return
    sorted := ""
    for path in files
        sorted .= (sorted=""?"":"`n") path
    sorted := Sort(sorted)
    for index,path in StrSplit(sorted,"`n")
        if index<=files.Length-keep
            try FileDelete path
}

; cache\pathview-<date_time>.png: road magenta, other red no-place areas
; blue, player centre white. The newest 10 are kept.
SavePathViewDebug() {
    DirCreate A_ScriptDir "\cache"
    file := A_ScriptDir "\cache\pathview-" FormatTime(A_Now,"yyyy-MM-dd_HH-mm-ss") ".png"
    reply := VisionRequest("pathdebug " file)
    if VisionOk(reply) && reply["saved"]="1"
        Log("Saved this game's path read: " file)
    PruneCacheImages("pathview-*.png",10)
}

PlaceUnitAction(unit) {
    global gRunning,gPendingPlacement,gHillPlacementUnavailable,gPlacementLine,gPlacementYenWait
    gHillPlacementUnavailable := false
    ; No F here: the unit manager is only opened after every unit is placed.
    if !gRunning || IsEndGameBlocking()
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2) || !ClearCardChoice()
        return false
    if RecoverPendingPlacement(unit)
        return true
    if gPendingPlacement
        return false
    if !CloseUnitPanel()
        return false
    if !CancelUnitPreview()
        return false
    RefreshMatchModifiers()
    if !RefreshPathView(unit)
        return false
    hillOnly := unit.HasProp("hill") && unit.hill
    hybrid := unit.HasProp("hybrid") && unit.hybrid
    if hillOnly || hybrid {
        hillPoints := FindHillPlacementCandidates(unit)
        if hillPoints.Length {
            Log(unit.name ": prefer green Hill surfaces, nearest the illuminated path first.")
            if TryPlacementPoints(unit,hillPoints)
                return true
            if gPendingPlacement
                return RecoverPendingPlacement(unit)
            if (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
                return false
        }
        if hillOnly {
            gHillPlacementUnavailable := true
            Log(unit.name ": Hill-only; no usable highlighted Hill space. Do not attempt ground placement.")
            return false
        }
        Log(unit.name ": Hybrid has no usable Hill space; continue with normal path-side placement.")
        if !CancelUnitPreview()
            return false
        if gPendingPlacement
            return false
    }
    if unit.HasProp("money") && unit.money
        return PlaceMoneyUnit(unit)
    ; Partners first: every edge unit with an open partner spot (straight
    ; behind it) gets one try, newest first, before any new edge spot.
    anchors := EdgeAnchors()
    index := anchors.Length
    while index>=1 {
        anchor := anchors[index--]
        if !PartnerOpen(anchor)
            continue
        if TryPartnerPlacement(unit,anchor)
            return true
        if gPendingPlacement || HasCardChoice() || (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
            return false
    }
    ; Then edge spots in front of or behind the player, whichever side is
    ; less filled; across the road only when this side is used up.
    points := FindPlacementCandidates(false)
    if !points.Length && gPlacementLine.Length
        points := FindPlacementCandidates(true)
    if !points.Length {
        Log(unit.name ": no untried local path-side spots; rescans will avoid this game's rejected coordinates.")
        return false
    }
    ; Saved coordinates are reusable only where they match this visible edge.
    points := MatchSavedPlacementsToPath(unit,points)
    if TryPlacementPoints(unit,points,true)
        return true
    if gPendingPlacement
        return RecoverPendingPlacement(unit)
    if (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
        return false
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

; Every retry here is bounded; the escalation when a bound runs out:
;  BUILD_COPY_ATTEMPT_LIMIT  attempts at one copy      -> give up the copy: the slot is held
;                                                         at its recorded count (CapSlot)
;  BUILD_RELOCATE_WAIT_LIMIT relocation could not start -> accept the current position as the
;                                                         checkpoint (AcceptCurrentPlacementArea)
;  HILL_RETRY_LIMIT          Hill-only waits            -> give up the Hill unit (CapSlot)
; When every slot reaches its target the build is audited (VerifyCompletedBuild)
; before it counts as complete; an incomplete audit sends placement back to work.
PlaceConfiguredBuildAction(plan) {
    global gRunning,gHillPlacementUnavailable,gPathReadGaveUp
    global BUILD_COPY_ATTEMPT_LIMIT,BUILD_RELOCATE_WAIT_LIMIT,HILL_RETRY_LIMIT
    retryAt := Map(),pendingLogAt := 0
    attempts := Map(),relocateWaits := Map(),hillWaits := Map()
    while gRunning {
        RetryFinalCheckpointPlacement()
        for unit in plan {
            if !unit.enabled
                continue
            while gRunning && CountSlotPlacements(unit.slot)<SlotTargetCount(unit) {
                if retryAt.Has(unit.slot) && A_TickCount<retryAt[unit.slot]
                    break
                if TryEndState()
                    return "replay"
                before := CountSlotPlacements(unit.slot)
                if PlacementFailureLimitReached() {
                    if RelocatePlacementArea(unit) {
                        relocateWaits[unit.slot] := 0
                        continue
                    }
                    relocateWaits[unit.slot] := relocateWaits.Get(unit.slot,0)+1
                    if relocateWaits[unit.slot]>=BUILD_RELOCATE_WAIT_LIMIT {
                        AcceptCurrentPlacementArea(unit)
                        relocateWaits[unit.slot] := 0
                        continue
                    }
                    ; Relocation not possible yet: wait, then the same unit again.
                    ActionPause(3000)
                    continue
                }
                Log("Place slot " unit.slot " copy " (before+1) "/" unit.count "; confirmed " before "/" unit.count)
                placed := PlaceUnit(unit)
                after := CountSlotPlacements(unit.slot)
                if placed && after=before+1 {
                    Log("Confirmed slot " unit.slot ": " after "/" unit.count " placements.")
                    attempts[unit.slot] := 0
                    continue
                }
                if after>before {
                    ; The slot counter showed more units than were recorded.
                    Log("Slot " unit.slot " now has " after "/" unit.count " placements recorded (reconciled with its counter).")
                    attempts[unit.slot] := 0
                    continue
                }
                if !gRunning
                    return "stopped"
                ; Neither a lit path nor a red road after repeated reads:
                ; sit the match out (Replay follows) instead of looping.
                if gPathReadGaveUp
                    return SitOutMatch("No path found (lit P path or red overlay); the frame is in cache.")
                ; Short of Yen: wait until affordable, then the same unit again.
                ; Not a failure, so it never moves the player to a checkpoint.
                if WaitForPlacementYen(unit)
                    continue
                if gHillPlacementUnavailable && unit.HasProp("hill") && unit.hill {
                    hillWaits[unit.slot] := hillWaits.Get(unit.slot,0)+1
                    if hillWaits[unit.slot]>HILL_RETRY_LIMIT {
                        Log(unit.name ": no Hill space after " HILL_RETRY_LIMIT " waits; giving this unit up.")
                        CapSlot(unit,before,"no Hill space")
                        continue
                    }
                    retryAt[unit.slot] := A_TickCount+10000
                    Log(unit.name ": Hill placement still pending; retry in 10 seconds.")
                    break
                }
                if PlacementFailureLimitReached() && RelocatePlacementArea(unit)
                    continue
                attempts[unit.slot] := attempts.Get(unit.slot,0)+1
                if attempts[unit.slot]>=BUILD_COPY_ATTEMPT_LIMIT {
                    Log(unit.name ": copy " (before+1) " was not placed in " BUILD_COPY_ATTEMPT_LIMIT " attempts; giving up on it.")
                    CapSlot(unit,before,"placement kept failing")
                    attempts[unit.slot] := 0
                    continue
                }
                ; Build order is kept: stay on this unit until it is placed (a
                ; failed spot is already excluded, so the next try is elsewhere).
                ; Only a Hill-only unit without Hill space (above) lets later
                ; units go first.
                Log(unit.name ": not placed yet; retry this same unit.")
                RefreshPlacementSearch()
                ActionPause(300)
            }
        }
        if !gRunning
            return "stopped"
        missing := MissingBuildPlacements(plan)
        if missing="" {
            ; Placement believes the build is complete: the game's own slot
            ; counters decide. Incomplete means more placing in this phase.
            if VerifyCompletedBuild(plan)
                return "complete"
            continue
        }
        if !pendingLogAt || A_TickCount>=pendingLogAt {
            Notify("Placement pending: " missing ". Upgrades (F manager) start once every unit is placed.")
            pendingLogAt := A_TickCount+10000
        }
        if TryEndState()
            return "replay"
        ; Upgrades go through the F manager, which may only open after the
        ; whole build is placed, so none run between placement retries.
        ActionPause(250)
    }
    return "stopped"
}

MissingBuildPlacements(plan) {
    missing := ""
    for unit in plan {
        count := CountSlotPlacements(unit.slot)
        if unit.enabled && count<SlotTargetCount(unit)
            missing .= (missing=""?"":"; ") "slot " unit.slot " " count "/" SlotTargetCount(unit)
    }
    return missing
}

; Deliberate placement along one local side of the in-game path.
global gPlacementLine := [],gLastPlacedIndex := 0,gPlacementPreferredSide := 0
global gHillPlacementUnavailable := false
global gPlacementAttemptClicked := false
global FAILED_PLACEMENT_RADIUS := 14
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
global gPlacementYenWait := 0,gUnitCosts := Map(),gUnitCostCandidates := Map(),gLastYenRead := 0

ResetPlacementSearch() {
    global gPlacementYenWait,gLastYenRead,gPlacementLine,gLastPlacedIndex,gPendingPlacement,gPlacementPreferredSide,gFailedPlacementSpots,gPlacementBlockedEdges,gPlacementEdgeMisses
    gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map()
    gPlacementLine := [],gLastPlacedIndex := 0,gPendingPlacement := 0,gPlacementPreferredSide := 0
    gPlacementYenWait := 0,gLastYenRead := 0
}

RefreshPlacementSearch() {
    global gPlacementLine,gLastPlacedIndex,gLayoutValidation
    ; Keep confirmed units, failed spots AND unresolved purchases across rescans.
    ; Only ResetPlacementSearch at the next build clears failure memory.
    gPlacementLine := [],gLastPlacedIndex := 0
    gLayoutValidation := Map()
}

FindPlacementCandidates(acrossRoad := true) {
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
        if !StartLineAtNewestEdgeUnit()
            Log("Start beside the player at " first.x "," first.y "; follow one path edge in adjacent steps.")
    }
    points := []
    ; Every new unit stays on the same path edge: first onward from the last
    ; placed edge unit, then back along the same edge. Never away from the road.
    order := []
    index := gLastPlacedIndex+1
    while index<=gPlacementLine.Length
        order.Push(index++)
    index := gLastPlacedIndex-1
    while index>=1
        order.Push(index--)
    for index in order {
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
    if gPendingPlacement && WaitFor(HasUnitPanel,250,40)
        return FinishPlacement(unit,gPendingPlacement)
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
    if gPendingPlacement && WaitFor(HasUnitPanel,250,40)
        return FinishPlacement(unit,gPendingPlacement)
    if gRunning
        CancelUnitPreview()
    return false
}

PlacementTerrain(point) => point.HasProp("hill") && point.hill?"hill":"ground"

; -----------------------------------------------------------------------------
; Yen. Read only after a purchase failed, so successful placements cost no
; time. One OCR call covers the Yen counter above the toolbar and the cost
; under each of the six slot portraits (800x600 reference layout).
; -----------------------------------------------------------------------------
ReadPlacementMoney() {
    global REF_W,REF_H
    result := {yen:-1,costs:Map()}
    geometry := WindowGeometry()
    if !geometry
        return result
    rows := ReadOcrRows(205,484,595,562,true,4)
    yenWords := [],slotWords := Map()
    ; Cost text sits in the lower right of each portrait.
    costX := [251,315,379,443,508,571]
    for word in rows {
        x := (word.x+word.w/2)*REF_W/geometry.cw,y := (word.y+word.h/2)*REF_H/geometry.ch
        if y>=484 && y<=515 && x>=340 && x<=470 {
            yenWords.Push({x:x,text:word.text})
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

; Called once per failed purchase. True when Yen was below the unit's cost:
; then the failure is not counted, the spot stays usable, and the build loop
; waits for Yen. Anything unreadable counts as an ordinary failure.
PlacementShortOfYen(unit) {
    global gPlacementYenWait,gLastYenRead,gPlacements
    ; Yen only rises between purchases (no upgrades during placement): once it
    ; was seen to cover this cost, later misses need no new read.
    known := UnitPlacementCost(unit,{yen:-1,costs:Map()})
    if known && IsSet(gLastYenRead) && gLastYenRead && gLastYenRead.placements=gPlacements.Length && gLastYenRead.yen>=known
        return false
    read := ReadPlacementMoney()
    cost := UnitPlacementCost(unit,read)
    if !cost && read.costs.Has(unit.slot) {
        ; First sighting of this cost: confirm it with a second read now.
        read := ReadPlacementMoney()
        cost := UnitPlacementCost(unit,read)
    }
    if read.yen>=0
        gLastYenRead := {yen:read.yen,placements:gPlacements.Length}
    if cost<=0 || read.yen<0 || read.yen>=cost
        return false
    gPlacementYenWait := {slot:unit.slot,cost:cost,since:A_TickCount}
    Log(unit.name ": " read.yen " of " cost " Yen; not a failed spot. Wait for Yen, then place this unit.")
    return true
}

; After a Yen-short purchase: re-read the counter about once a second until
; the unit is affordable (at most 20 s, or 3 unreadable reads), then retry.
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
    if !CandidateOccupied(point.x,point.y) && !FailedPlacementSpot(point) && !BlockedPlacementEdge(point)
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
    if !SmoothMoveTo(sx,sy,UNIT_ACTION_MS,UNIT_ACTION_MS)
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
    global gPlacementYenWait,gPendingPlacement,gLastPlacedIndex,gPlacementPreferredSide,gPlacementEdgeMisses
    if !point || CandidateOccupied(point.x,point.y)
        return false
    if HasCardChoice() || !HasUnitPanel()
        return false
    point.panelSeen := true
    if !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || point.pendingCopy!=CountSlotPlacements(unit.slot)+1 {
        Log("Ignored unit panel without the matching pending slot/copy purchase.")
        return false
    }
    if !RegisterPlacedUnit(unit,point)
        return false
    gPlacementYenWait := 0
    ResetPlacementFailureStreak()
    ForgetFailedPlacementSpot(point)
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
    if FailedPlacementSpot(candidate)
        return false
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
        ; The interruption cancelled input; retry this unfinished copy/spot.
    }
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
    if PlacementFailureLimitReached()
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
    purchase := candidate.Clone()
    purchase.pendingSlot := unit.slot,purchase.pendingCopy := before+1,purchase.pendingTarget := unit.count
    if !PlacementClickRef(candidate.x,candidate.y,true,purchase)
        return false
    if WaitForUnitPanel(300,false)
        return FinishPlacement(unit,gPendingPlacement)
    if gRunning && !HasCardChoice() && !IsEndGameBlocking()
        RecordFailedPlacement(unit,gPendingPlacement)
    return RecoverPendingPlacement(unit)
}

TrySelectUnitAt(point,timeout := 450,learn := false) {
    global gRunning
    return gRunning && !HasCardChoice() && PlacementClickRef(point.x,point.y,true) && WaitForUnitPanel(timeout,learn)
}

RecoverPendingPlacement(unit) {
    global gRunning,gPendingPlacement,gCardInterruptEpoch
    point := gPendingPlacement
    if !gRunning || !point || !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || point.pendingCopy!=CountSlotPlacements(unit.slot)+1 || HasCardChoice() || CandidateOccupied(point.x,point.y)
        return false
    before := CountSlotPlacements(unit.slot),epoch := gCardInterruptEpoch
    if HasUnitPanel() {
        point.panelSeen := true
        if FinishPlacement(unit,point)
            return true
    }
    ; Reselect only: an unreadable purchase must not be replaced by another buy.
    Loop 2 {
        if !CloseUnitPanel() || !CancelUnitPreview()
            return false
        if CountSlotPlacements(unit.slot)>before
            return true
        if gPendingPlacement!=point || !PlacementClickRef(point.x,point.y,true)
            return false
        if WaitForUnitPanel(300,A_Index=2) {
            point.panelSeen := true
            return FinishPlacement(unit,point)
        }
        if CountSlotPlacements(unit.slot)>before
            return true
        if !gRunning || HasCardChoice() || IsEndGameBlocking() || epoch!=gCardInterruptEpoch || gPendingPlacement!=point
            return false
    }
    if point.HasProp("panelSeen") && point.panelSeen {
        Log(unit.name ": purchase panel was seen; reselect this unit to confirm it without another purchase.")
        return false
    }
    ; Two completed selection-only probes found no model after the purchase wait.
    gPendingPlacement := 0
    ; Short of Yen: the spot itself was never tested, so it stays usable.
    if point.HasProp("yenShort") && point.yenShort
        return false
    RememberFailedPlacementSpot(point)
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
    if VisionOk(reply) && reply["valid"]="1"
        return true
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

TryPlacementPoints(unit,points) {
    global gPlacementYenWait,gRunning,gPlacementAttemptClicked,gPendingPlacement
    queue := points.Clone(),seen := Map()
    while queue.Length {
        if !gRunning || IsEndGameBlocking()
            return false
        if PlacementFailureLimitReached()
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
        ; Not enough Yen: other spots would fail the same way, and this miss
        ; must not block the edge.
        if (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
            return false
        if !gPlacementAttemptClicked
            continue
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

PlaceUnit(unit) {
    global gCardAction,gPlacementActiveUnit,gCardInterruptEpoch,gRunning
    previous := gCardAction,previousUnit := gPlacementActiveUnit
    gCardAction := "placement",gPlacementActiveUnit := unit
    try {
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
        }
    } finally {
        gCardAction := previous,gPlacementActiveUnit := previousUnit
    }
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
    ; Pairs: the newest edge unit gets one try at a partner straight behind it,
    ; otherwise the unit goes along the edge beside the newest edge unit.
    anchor := NewestEdgeAnchor()
    if anchor && PartnerOpen(anchor) {
        if TryPartnerPlacement(unit,anchor)
            return true
        if gPendingPlacement || HasCardChoice() || (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
            return false
    }
    points := FindPlacementCandidates(false)
    if !points.Length && gPlacementLine.Length {
        ; This side of the edge is used up: fill open partner spots behind older
        ; edge units, oldest first, before crossing the road.
        for older in EdgeAnchors() {
            if !PartnerOpen(older)
                continue
            if TryPartnerPlacement(unit,older)
                return true
            if gPendingPlacement || HasCardChoice() || (IsSet(gPlacementYenWait) && gPlacementYenWait && gPlacementYenWait.slot=unit.slot)
                return false
        }
        points := FindPlacementCandidates(true)
    }
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

PlaceConfiguredBuildAction(plan) {
    global gRunning,gHillPlacementUnavailable
    retryAt := Map(),pendingLogAt := 0
    while gRunning {
        RetryFinalCheckpointPlacement()
        for unit in plan {
            if !unit.enabled
                continue
            while gRunning && CountSlotPlacements(unit.slot)<unit.count {
                if retryAt.Has(unit.slot) && A_TickCount<retryAt[unit.slot]
                    break
                if TryEndState()
                    return "replay"
                before := CountSlotPlacements(unit.slot)
                if PlacementFailureLimitReached() {
                    if RelocatePlacementArea(unit)
                        continue
                    ; Relocation not possible yet: wait, then the same unit again.
                    ActionPause(3000)
                    continue
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
                ; Short of Yen: wait until affordable, then the same unit again.
                ; Not a failure, so it never moves the player to a checkpoint.
                if WaitForPlacementYen(unit)
                    continue
                if gHillPlacementUnavailable && unit.HasProp("hill") && unit.hill {
                    retryAt[unit.slot] := A_TickCount+10000
                    Log(unit.name ": Hill placement still pending; retry in 10 seconds.")
                    break
                }
                if PlacementFailureLimitReached() && RelocatePlacementArea(unit)
                    continue
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
        if missing=""
            return "complete"
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
        if unit.enabled && count<unit.count
            missing .= (missing=""?"":"; ") "slot " unit.slot " " count "/" unit.count
    }
    return missing
}

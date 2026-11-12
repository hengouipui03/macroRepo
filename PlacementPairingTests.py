"""Pairs along the path edge, edge-stretch blocking and Money units, run
through the actual placement functions with simulated clicks only."""
import re
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function


def arrow(file, name):
    source = (ROOT / file).read_text(encoding="utf-8-sig")
    match = re.search(r"^" + re.escape(name) + r"\([^\n]*\) =>[^\n]*$", source, re.M)
    assert match, name
    return match[0]


assert "PLACEMENT_FAILURE_LIMIT := 6" in (ROOT / "PlacementArea.ahk").read_text(encoding="utf-8-sig")
names = ["EdgeAnchors", "NewestEdgeAnchor", "StartLineAtNewestEdgeUnit", "FindPlacementCandidates", "PlacementLaneOrder",
         "TryPartnerPlacement", "MoneySpotScore", "PlaceMoneyUnit", "PlaceUnitAction",
         "UsablePlacementPoint", "OppositePlacementPoint", "FailedPlacementSpot", "PlacementEdgeNormal",
         "SamePlacementEdge", "BlockedPlacementEdge", "RegisterPlacementEdgeMiss", "TryPlacementPoints",
         "CountSlotPlacements"]
logic = "\n".join(function("Placement.ahk", n) for n in names)
logic += "\n" + arrow("Placement.ahk", "PartnerOpen") + "\n" + arrow("Placement.ahk", "PlacementTerrain")
logic += "\n" + function("PlacedUnits.ahk", "RegisterPlacedUnit")
logic += "\n" + function("Learning.ahk", "CandidateOccupied")
logic += "\n" + function("UnitSettings.ahk", "UnitPlacementModeChanged")
logic += "\n" + function("BuildAudit.ahk", "SlotTargetCount")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [],gPendingPlacement := 0,gPlacementAttemptClicked := false
global gPlacementLine := [],gLastPlacedIndex := 0,gPlacementPreferredSide := 0,gHillPlacementUnavailable := false
global gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map(),FAILED_PLACEMENT_RADIUS := 28
global gSlotCaps := Map(),gCardInterruptEpoch := 0,wall := Map(),partnerWall := Map(),tried := [],gUnitControls := []
try {
    ; 1) Pairs: edge, behind, edge, behind, edge. Row-2 units never anchor.
    Line()
    units := []
    Loop 5
        units.Push(TestUnit(A_Index))
    for unit in units
        Assert(PlaceUnitAction(unit),"unit " unit.slot " was not placed")
    rows := ""
    for item in gPlacements
        rows .= item.row
    Assert(rows="12121","placement rows were " rows " instead of edge/behind alternating")
    Assert(gPlacements[2].anchor=1 && gPlacements[4].anchor=3 && gPlacements[1].partner=2 && gPlacements[3].partner=4,"partners were not bound to their edge units")
    Assert(NewestEdgeAnchor().id=5,"a row-2 unit became an anchor")
    for item in gPlacements
        if item.row=1
            Assert(item.x=420,"an edge unit left the path edge")
    Assert(gPlacements[3].y-gPlacements[1].y<=28 && gPlacements[5].y-gPlacements[3].y<=28,"edge units were not placed beside the last edge unit")

    ; 2) A failed partner try closes only that spot; the unit goes along the
    ;    edge in the same attempt and the edge is not blocked.
    Reset(),Line()
    PlaceUnitAction(TestUnit(1))
    partnerWall[1] := true
    Assert(PlaceUnitAction(TestUnit(2)) && gPlacements[2].row=1,"after a failed partner try the unit did not go along the edge")
    Assert(gPlacements[1].partner="closed" && !gPlacementBlockedEdges.Length,"a partner miss blocked the edge or left the spot open")
    Assert(PlaceUnitAction(TestUnit(3)) && gPlacements[3].row=2 && gPlacements[3].anchor=2,"the next edge unit did not get its partner")

    ; 3) Three misses along a wall block the whole stretch they walked; the
    ;    next tries go to the opposite side, never further along the wall.
    Reset(),Line()
    Loop 6
        wall[A_Index] := true
    tried := []
    Assert(PlaceUnitAction(TestUnit(1)),"no unit placed after the wall")
    Assert(tried.Length>=4 && tried[1].x=420 && tried[2].x=420 && tried[3].x=420 && tried[4].x=380,"after 3 wall misses the 4th try stayed on the walled side")
    Assert(BlockedPlacementEdge(gPlacementLine[5]) && BlockedPlacementEdge(gPlacementLine[6]),"the wall stretch beyond the 3rd miss was not blocked")
    Assert(gPlacements[1].x=380,"unit was not placed across the road")

    ; 4) Money unit: path edge, farthest from everything; others keep 2 spacings
    ;    away, the line still starts at the player, and she never anchors.
    Reset(),Line()
    bulby := TestUnit(1),bulby.money := true
    Assert(PlaceUnitAction(bulby) && gPlacements[1].y=214 && gPlacements[1].x=420,"Money unit not placed at the far end of the edge")
    Assert(gLastPlacedIndex=0 && !NewestEdgeAnchor(),"Money unit became the line start or an anchor")
    Assert(PlaceUnitAction(TestUnit(2)) && gPlacements[2].y-gPlacements[1].y>=48,"a unit was squeezed beside the Money unit")
    Assert(CandidateOccupied(420,214+40) && !CandidateOccupied(420+28,300),"Money footprint radius wrong")

    ; 5) After a rescan the line continues beside the newest edge unit.
    gLastPlacedIndex := 0,gPlacementPreferredSide := 0
    Assert(StartLineAtNewestEdgeUnit() && gLastPlacedIndex=5,"rescan restarted beside the player instead of beside the newest edge unit")

    ; 6) A used-up side fills open partner spots of older edge units, oldest
    ;    first, before crossing the road.
    Reset(),Line()
    PlaceUnitAction(TestUnit(1))
    gPlacements[1].partner := ""
    partnerWall[1] := false
    PlaceUnitAction(TestUnit(2))                     ; partner of #1
    PlaceUnitAction(TestUnit(3))                     ; edge
    partnerWall[3] := true
    PlaceUnitAction(TestUnit(4))                     ; #3's partner fails -> edge (#4)
    gPlacements[3].partner := ""                 ; reopen #3's partner spot for this check
    gPlacements[4].partner := "closed"           ; the newest edge unit has no spot behind
    partnerWall[3] := false
    for point in gPlacementLine
        gFailedPlacementSpots.Push({x:point.x,y:point.y,terrain:"ground"})
    Assert(PlaceUnitAction(TestUnit(5)) && gPlacements[5].row=2 && gPlacements[5].anchor=3,"used-up edge crossed the road before filling an open partner spot")

    ; 7) Hill only, Hybrid and Money are mutually exclusive in the settings.
    gUnitControls := [{hill:{Value:1},hybrid:{Value:0},money:{Value:1}}]
    UnitPlacementModeChanged(1,"money")
    Assert(gUnitControls[1].money.Value=1 && gUnitControls[1].hill.Value=0 && gUnitControls[1].hybrid.Value=0,"Money did not clear Hill only/Hybrid")

    FileAppend "PASS: edge/behind pairs (row-2 never anchors); failed partner closes only its spot; 3 wall misses block the walked stretch and move to the opposite side; Money unit far along the edge with a 3-unit footprint and never an anchor; rescans continue beside the newest edge unit; open partner spots before crossing; exclusive Hill only/Hybrid/Money.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack,"*"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
TestUnit(slot) => {slot:slot,name:"Unit " slot,count:1,priority:slot,target:99,enabled:true}
Reset() {
    global
    gPlacements := [],gPendingPlacement := 0,gPlacementLine := [],gLastPlacedIndex := 0,gPlacementPreferredSide := 0
    gFailedPlacementSpots := [],gPlacementBlockedEdges := [],gPlacementEdgeMisses := Map(),wall := Map(),partnerWall := Map(),tried := []
}
; A straight vertical road at x=400: the edge line is x=420 (normal +x), the
; opposite edge x=380, spots 14 px apart, starting beside the player (y=200).
Line() {
    global gPlacementLine
    gPlacementLine := []
    Loop 10 {
        y := 200+A_Index*14
        point := {x:420,y:y,index:A_Index,side:0,row:1,nx:1,ny:0}
        point.other := {x:380,y:y,index:A_Index,side:1,row:1,nx:-1,ny:0}
        gPlacementLine.Push(point)
    }
}
FindPartnerCandidate(anchor) {
    ; Beyond FAILED_PLACEMENT_RADIUS: a rejected edge spot (<= radius) must not also reject the partner spot behind it.
    point := {x:anchor.x+FAILED_PLACEMENT_RADIUS+12,y:anchor.y,side:0,row:2,anchor:anchor.id,nx:1,ny:0}
    return CandidateOccupied(point.x,point.y)?[]:[point]
}
; Simulated purchase: walls and partner walls reject; success is recorded the
; way FinishPlacement records it.
TryPlacementCandidate(unit,point) {
    global gPlacementAttemptClicked,gLastPlacedIndex,gPlacementPreferredSide,tried
    gPlacementAttemptClicked := true,tried.Push(point)
    if point.row=2 ? (partnerWall.Has(point.anchor) && partnerWall[point.anchor]) : (point.x=420 && wall.Has(point.index) && wall[point.index])
        return false
    RegisterPlacedUnit(unit,point,"test")
    if point.HasProp("index") && !(unit.HasProp("money") && unit.money)
        gLastPlacedIndex := point.index,gPlacementPreferredSide := point.side
    return true
}
FindHillPlacementCandidates(*) => []
MatchSavedPlacementsToPath(unit,points) => points
RecoverPendingPlacement(*) => false
PlacementFailureLimitReached(*) => false
PlacementAnchorKnown(*) => true
MapDistance(x1,y1,x2,y2) => Sqrt((x1-x2)**2+(y1-y2)**2)
RememberPlacement(*) => 0
SaveLayoutPoint(*) => 0
SavePlacementRun(*) => 0
QueueUnitSettingsSave(*) => 0
Log(*) => 0
FindRoblox(*) => 1
WinActivate(*) => 0
WinWaitActive(*) => true
ClearCardChoice(*) => true
HasCardChoice(*) => false
IsEndGameBlocking(*) => false
CloseUnitPanel(*) => true
CancelUnitPreview(*) => true
RefreshMatchModifiers(*) => 0
WaitFor(*) => false
HasUnitPanel(*) => false
FinishPlacement(*) => false
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 800,ch := 600
    return true
}
VisionRequest(*) => false
VisionOk(*) => false
PlacementSearchDiagnostic(*) => 0
PlacementUpstreamDirection(*) {
    return {x:0,y:0}
}
RefreshPathView(*) => true
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "placement-pairing-regression.ahk"
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=30)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

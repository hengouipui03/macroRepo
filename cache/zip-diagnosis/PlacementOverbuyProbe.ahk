
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [{slot:1},{slot:1},{slot:1}],gPendingPlacement := 0,gPlacementAttemptClicked := false
global gLastPlacedIndex := 0,gPlacementPreferredSide := 0,gPlacementEdgeMisses := Map(),gFreshUnitHeader := ""
global gPlacementLine := [],gLayoutValidation := Map()
global panel := false,preview := false,models := Map(),buys := 3
unit := {slot:1,name:"Unit 1",count:4,enabled:true}
TryPlacementCandidateAction(unit,{x:400,y:330})
FileAppend "After fourth actual purchase: bought=" buys " recorded=" CountSlotPlacements(1) " pending=" (gPendingPlacement?1:0) "`n","*","UTF-8"
RefreshPlacementSearch()
TryPlacementCandidateAction(unit,{x:440,y:330})
FileAppend "After failed confirmation and rescan: bought=" buys " recorded=" CountSlotPlacements(1) " configured=" unit.count "`n","*","UTF-8"
ExitApp 0
IsEndGameBlocking(*) => false
HasCardChoice(*) => false
HasUnitPanel(*) => panel
CloseUnitPanel(*) {
 global panel
 panel := false
 return true
}
CancelUnitPreview(*) {
 global preview
 preview := false
 return true
}
PlacementPanelClosedStable(*) => true
PlacementStillBesidePath(*) => true
TrySelectUnitAt(point,*) => PlacementClickRef(point.x,point.y) && WaitForUnitPanel()
PlacementClickRef(x,y,*) {
 global panel,buys,models
 key := x "," y
 if preview {
  buys += 1,models[key] := true
 }
 panel := models.Has(key)
 return true
}
SelectPlacementUnit(*) {
 global preview
 preview := true
 return true
}
WaitForUnitPanel(*) => panel
UpgradeHeaderSignature(*) => "visible-gold-header"
ReadUnitUpgradeState(*) => {level:-1,signature:"visible-gold-header"}
CandidateOccupied(*) => false
ClearCardChoice(*) => true
RememberFailedPlacementSpot(*) => 0
ForgetFailedPlacementSpot(*) => 0
PlacementTerrain(*) => "ground"
RegisterPlacedUnit(unit,point) {
 global gPlacements
 gPlacements.Push({slot:unit.slot,x:point.x,y:point.y})
 return true
}
ClickAwayFromUnitPanel(*) => CloseUnitPanel()
ActionPause(*) => true
Log(*) => 0

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
    if !SelectPlacementUnit(unit)
        return false
    if !PlacementClickRef(candidate.x,candidate.y,true)
        return false
    gPlacementAttemptClicked := true
    gPendingPlacement := candidate.Clone()
    gPendingPlacement.pendingSlot := unit.slot,gPendingPlacement.pendingCopy := CountSlotPlacements(unit.slot)+1
    if WaitForUnitPanel(700)
        return FinishPlacement(unit,gPendingPlacement)
    ; One click has finished its confirmation wait. Only then advance to
    ; the adjacent position on this same side of the path.
    if gRunning && !HasCardChoice()
        ActionPause(50)
    return false
}
FinishPlacement(unit,point) {
    global gPendingPlacement,gLastPlacedIndex,gPlacementPreferredSide,gPlacementEdgeMisses
    if !point || CandidateOccupied(point.x,point.y)
        return false
    if HasCardChoice() || !HasUnitPanel()
        return false
    if !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || point.pendingCopy!=CountSlotPlacements(unit.slot)+1 {
        Log("Ignored unit panel without the matching pending slot/copy purchase.")
        return false
    }
    if !FreshPlacementPanel() {
        Log(unit.name ": waiting for a fresh UPG 0 panel before counting this purchase.")
        return false
    }
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
FreshPlacementPanel() {
    global gFreshUnitHeader
    if HasCardChoice()
        return false
    signature := UpgradeHeaderSignature()
    if signature!="" && signature=gFreshUnitHeader
        return true
    state := ReadUnitUpgradeState(true)
    if state.level!=0 || state.signature="" || HasCardChoice()
        return false
    gFreshUnitHeader := state.signature
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
RefreshPlacementSearch() {
    global gPlacementLine,gLastPlacedIndex,gPendingPlacement,gLayoutValidation
    ; Keep confirmed units AND this game's failed spots across rescans.
    ; Only ResetPlacementSearch at the next build clears failure memory.
    gPlacementLine := [],gLastPlacedIndex := 0,gPendingPlacement := 0
    gLayoutValidation := Map()
}
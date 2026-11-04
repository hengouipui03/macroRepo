
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [],gPendingPlacement := 0,gPlacementAttemptClicked := false
global gLastPlacedIndex := 0,gPlacementPreferredSide := 0,gPlacementEdgeMisses := Map()
global gCardHandling := false,gCardAction := "placement",gCardPollAt := 0,gCardInterruptEpoch := 0,gPlacementActiveUnit := 0,testNow := 10000
global panel := false,preview := false,existingModel := false,purchased := false,cards := false,buys := 0,slots := 0,registrations := 0
global gFreshUnitHeader := "",panelLevel := 0
try {
    unit := {slot:1,name:"Unit 1",count:2,enabled:true},point := {x:400,y:330}
    existingModel := true
    Assert(!TryPlacementCandidateAction(unit,point) && buys=0 && slots=0 && registrations=0,"selecting an old model counted as a new purchase")
    existingModel := false
    Assert(TryPlacementCandidateAction(unit,point) && buys=1 && registrations=1,"real purchase did not bind and confirm its slot/copy")
    Assert(CountSlotPlacements(1)=1,"real purchase was counted more than once")

    ; An unrelated panel visible behind a card is never purchase evidence.
    gPlacements := [],registrations := 0,purchased := false,panel := true,cards := true,gCardPollAt := 0
    gPlacementActiveUnit := unit,gPendingPlacement := Pending(1,1)
    Assert(!FinishPlacement(unit,gPendingPlacement) && registrations=0,"panel obscured by a card was accepted directly")
    CheckCardInterruption()
    Assert(registrations=0 && buys=1,"panel behind cards falsely registered a unit")

    ; A real pending purchase survives the card, then gets verified by selecting
    ; its exact location without pressing a slot or buying another copy.
    purchased := true,panel := true,cards := true,gCardPollAt := 0
    CheckCardInterruption()
    Assert(registrations=1 && CountSlotPlacements(1)=1 && buys=1,"card recovery lost or duplicated a real purchase")
    Assert(!FinishPlacement(unit,Pending(1,1)) && registrations=1,"same pending copy was counted twice")
    Assert(!FinishPlacement(unit,Pending(2,2)) && registrations=1,"pending purchase leaked into another slot")
    Assert(!FinishPlacement(unit,{x:400,y:330}) && registrations=1,"unbound panel was accepted as purchase evidence")
    panel := true,panelLevel := 3
    Assert(!FinishPlacement(unit,Pending(1,2)) && registrations=1,"upgraded old-unit panel was counted as a fresh purchase")
    panelLevel := -1
    Assert(!FinishPlacement(unit,Pending(1,2)) && registrations=1,"unreadable panel was counted as a fresh purchase")
    missing := MissingBuildPlacements([unit,{slot:2,count:1,enabled:true},{slot:3,count:9,enabled:false}])
    Assert(InStr(missing,"slot 1 1/2") && InStr(missing,"slot 2 0/1") && !InStr(missing,"slot 3"),"build completion ignored missing enabled copies")
    FileAppend "PASS: occupied-model probe blocks false purchases; purchases bind slot/copy; card overlay never counts a panel; card recovery selects exact pending location without rebuying; duplicates/cross-slot/unbound confirmations rejected; missing counts retained.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack,"*"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
Pending(slot,copy) => {x:400,y:330,pendingSlot:slot,pendingCopy:copy}
IsEndGameBlocking(*) => false
HasCardChoice(*) => cards
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
PlacementClickRef(*) {
    global panel,purchased,buys
    if preview {
        buys += 1,purchased := true,panel := true
    } else
        panel := existingModel || purchased
    return true
}
WaitForUnitPanel(*) => panel
SelectPlacementUnit(*) {
    global preview,slots
    preview := true,slots += 1
    return true
}
ClearCardChoice(*) {
    global panel,cards,preview
    Assert(registrations=0,"card interruption counted the obscured panel before clearing it")
    panel := false,cards := false,preview := false
    return true
}
RegisterPlacedUnit(unit,point) {
    global registrations,gPlacements
    registrations += 1
    item := {slot:unit.slot,x:point.x,y:point.y}
    gPlacements.Push(item)
    return item
}
CandidateOccupied(*) => false
PlacementTerrain(*) => "ground"
RememberFailedPlacementSpot(*) => 0
ForgetFailedPlacementSpot(*) => 0
ClickAwayFromUnitPanel(*) => CloseUnitPanel()
ActionPause(*) => true
Log(*) => 0
UpgradeHeaderSignature(*) => "gold-" panelLevel
ReadUnitUpgradeState(*) => {level:panelLevel,signature:"gold-" panelLevel}

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
TrySelectUnitAt(point,timeout := 450,learn := false) {
    global gRunning
    return gRunning && !HasCardChoice() && PlacementClickRef(point.x,point.y,true) && WaitForUnitPanel(timeout,learn)
}
RecoverPendingPlacement(unit) {
    global gRunning,gPendingPlacement
    point := gPendingPlacement
    if !gRunning || !point || !point.HasProp("pendingSlot") || point.pendingSlot!=unit.slot
        || point.pendingCopy!=CountSlotPlacements(unit.slot)+1 || HasCardChoice() || CandidateOccupied(point.x,point.y)
        return false
    return CloseUnitPanel() && CancelUnitPreview() && TrySelectUnitAt(point,550,true) && FinishPlacement(unit,point)
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
CountSlotPlacements(slot) {
    global gPlacements
    count := 0
    for item in gPlacements
        if item.slot=slot
            count += 1
    return count
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
CheckCardInterruption() {
    global gRunning,gCardHandling,gCardAction,gCardPollAt,gCardInterruptEpoch
    global gPendingPlacement,gPlacementActiveUnit
    if !gRunning || gCardHandling || gCardAction="" || testNow<gCardPollAt
        return false
    gCardPollAt := testNow+100
    if !HasCardChoice()
        return false
    gCardInterruptEpoch += 1
    gCardHandling := true
    try {
        Log("Centre card appeared; pause " gCardAction ", choose, then resume the same unit.")
        ; Keep the pending click, but never count a panel obscured by cards.
        if ClearCardChoice() && gRunning && gCardAction="placement" && gPlacementActiveUnit && gPendingPlacement {
            RecoverPendingPlacement(gPlacementActiveUnit)
        }
    } finally gCardHandling := false
    return true
}
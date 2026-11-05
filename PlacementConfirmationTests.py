"""Existing models and card overlays must never count as fresh purchases."""
import subprocess
from UpgradeRegressionTests import ROOT,RUNTIME,function

logic = '\n'.join(function(file,name) for file,name in [
    ('Placement.ahk','TryPlacementCandidateAction'),('Placement.ahk','TrySelectUnitAt'),
    ('Placement.ahk','RecoverPendingPlacement'),
    ('Placement.ahk','RefreshPlacementSearch'),('Placement.ahk','PlacementPurchaseReady'),
    ('Placement.ahk','FinishPlacement'),('Placement.ahk','CountSlotPlacements'),
    ('Placement.ahk','MissingBuildPlacements'),('AAPathMacro.ahk','CheckCardInterruption')])
logic += '\n' + function('PlacedUnits.ahk','OpenRecordedUnit')
for name in ['PlacementFailureLimitReached','ResetPlacementFailureStreak','RecordFailedPlacement','PlacementCopyFailures']:
    logic += '\n' + function('PlacementArea.ahk', name)
logic = logic.replace('A_TickCount','testNow')

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gMapModel := 0
global gRunning := true,gPlacements := [],gPendingPlacement := 0,gPlacementAttemptClicked := false
global gLastPlacedIndex := 0,gPlacementPreferredSide := 0,gPlacementEdgeMisses := Map()
global gCardHandling := false,gCardAction := "placement",gCardPollAt := 0,gCardInterruptEpoch := 0,gPlacementActiveUnit := 0,testNow := 10000
global panel := false,preview := false,existingModel := false,purchased := false,cards := false,buys := 0,slots := 0,registrations := 0
global gPlacementLine := [],gLayoutValidation := Map(),gPlacementAreaFailures := Map(),PLACEMENT_FAILURE_LIMIT := 5,gConsecutivePlacementFailures := 0
global modelMode := false,models := Map(),hidePanels := false,delayPanel := false,rejectPurchase := false,failures := 0,cardDuringPurchase := false
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
    purchased := true,panel := true,cards := true,gCardPollAt := 0,gPendingPlacement := Pending(1,1)
    CheckCardInterruption()
    Assert(registrations=1 && CountSlotPlacements(1)=1 && buys=1,"card recovery lost or duplicated a real purchase")
    Assert(!FinishPlacement(unit,Pending(1,1)) && registrations=1,"same pending copy was counted twice")
    Assert(!FinishPlacement(unit,Pending(2,2)) && registrations=1,"pending purchase leaked into another slot")
    Assert(!FinishPlacement(unit,{x:400,y:330}) && registrations=1,"unbound panel was accepted as purchase evidence")
    missing := MissingBuildPlacements([unit,{slot:2,count:1,enabled:true},{slot:3,count:9,enabled:false}])
    Assert(InStr(missing,"slot 1 1/2") && InStr(missing,"slot 2 0/1") && !InStr(missing,"slot 3"),"build completion ignored missing enabled copies")

    ; A bound purchase is confirmed by its side panel, with no UPG OCR.
    unit.count := 4,modelMode := true,models := Map(),panel := false
    gPlacements := [{slot:1},{slot:1},{slot:1}],registrations := 3,buys := 3,gPendingPlacement := 0
    Assert(TryPlacementCandidateAction(unit,point) && buys=4 && CountSlotPlacements(1)=4 && !gPendingPlacement,"side panel did not immediately confirm the fourth purchase")
    RefreshPlacementSearch()
    hidePanels := true
    Assert(!TryPlacementCandidateAction(unit,{x:450,y:330}) && buys=4,"hidden panel allowed a fifth purchase after four were confirmed")
    hidePanels := false
    Assert(!TryPlacementCandidateAction(unit,{x:480,y:330}) && buys=4,"configured target four allowed a fifth purchase")

    ; A delayed panel is recovered at the exact purchase coordinate, without buying.
    unit.count := 1,gPlacements := [],registrations := 0,buys := 0,models := Map(),delayPanel := true
    Assert(TryPlacementCandidateAction(unit,point) && buys=1 && CountSlotPlacements(1)=1,"delayed purchase panel caused a replacement purchase")

    ; A card may open during mouse-up/confirmation, before the click call returns.
    gPlacements := [],registrations := 0,buys := 0,models := Map(),cardDuringPurchase := true
    gPlacementActiveUnit := unit,gCardPollAt := 0
    TryPlacementCandidateAction(unit,point)
    Assert(buys=1 && CountSlotPlacements(1)=1 && !gPendingPlacement,"card during purchase lost the binding or restored an already confirmed pending copy")
    Assert(!TryPlacementCandidateAction(unit,{x:450,y:330}) && buys=1,"post-card recovery bought beyond the configured count")

    ; A rejected spot remains retryable elsewhere after two completed no-model probes.
    gPlacements := [],registrations := 0,buys := 0,models := Map(),rejectPurchase := true,failures := 0
    Assert(!TryPlacementCandidateAction(unit,point) && !gPendingPlacement && gConsecutivePlacementFailures=1,"confirmed empty spot stayed pending or failure was counted twice")
    rejectPurchase := false
    Assert(TryPlacementCandidateAction(unit,{x:450,y:330}) && CountSlotPlacements(1)=1,"a failed purchase prevented the next valid placement")

    ; Five actual rejected purchase clicks, including their recovery probes,
    ; count once each. A sixth buy must be blocked at the transaction boundary.
    gPlacements := [],registrations := 0,buys := 0,models := Map(),rejectPurchase := true
    ResetPlacementFailureStreak()
    Loop 5
        Assert(!TryPlacementCandidateAction(unit,{x:250+A_Index*30,y:330}),"rejected purchase was registered")
    Assert(buys=5 && gConsecutivePlacementFailures=5,"recovery clicks double-counted or dropped failed purchases")
    RefreshPlacementSearch()
    Assert(!TryPlacementCandidateAction(unit,{x:500,y:330}) && buys=5,"rescan allowed a sixth purchase without relocation")
    ResetPlacementFailureStreak(),rejectPurchase := false

    ; Reproduce the start-of-game setup in the user's log. All 16 purchases
    ; across six slots must advance on the panel alone, with OCR unavailable.
    gPlacements := [],registrations := 0,buys := 0,models := Map(),panel := false
    for slot,target in [3,3,1,1,4,4] {
        unit := {slot:slot,name:"Unit " slot,count:target,enabled:true}
        Loop target {
            candidate := {x:200+slot*30,y:230+A_Index*24,hill:slot=1}
            Assert(TryPlacementCandidateAction(unit,candidate),"opening side panel did not advance slot " slot)
        }
        Assert(CountSlotPlacements(slot)=target && !gPendingPlacement,"slot " slot " remained blocked after its side panel opened")
        Assert(!TryPlacementCandidateAction(unit,{x:700,y:400}),"completed slot bought an extra unit")
    }
    Assert(buys=16 && registrations=16,"six-slot startup stopped at one unit or bought extra copies")
    models["400,330"] := true
    recorded := {id:1,name:"Unit 1",x:400,y:330,selectX:400,selectY:330}
    Assert(OpenRecordedUnit(recorded) && panel && buys=16,"side panel did not confirm selection for upgrading without UPG OCR")

    gMapModel := {checkpointIndex:3},gPlacements := [],registrations := 0,buys := 0,models := Map(),panel := false
    unit := {slot:1,name:"Unit 1",count:1,enabled:true},gConsecutivePlacementFailures := 5
    Assert(!PlacementFailureLimitReached() && TryPlacementCandidateAction(unit,point) && buys=1,"checkpoint 3 did not keep placing after five misses")
    gMapModel := 0

    attempt := {pendingSlot:1,pendingCopy:1,pendingTarget:1}
    Assert(!PlacementPurchaseReady(attempt),"last-moment purchase guard ignored the completed target")
    gPlacements := [],gPendingPlacement := Pending(1,1)
    Assert(!PlacementPurchaseReady(attempt),"last-moment purchase guard overwrote an unresolved purchase")
    gPendingPlacement := 0,attempt.pendingCopy := 2
    Assert(!PlacementPurchaseReady(attempt),"last-moment purchase guard accepted the wrong copy number")
    FileAppend "PASS: five actual rejected purchases counted once each; sixth buy blocked after rescan; side panel alone confirms a bound purchase; no UPG OCR; all 16 startup purchases across six slots advance; target four never buys five; existing-model/card/duplicate guards; delayed panel recovery and interruptions.`n","*"
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
PlacementClickRef(x,y,guard := false,purchase := 0) {
    global panel,purchased,buys,gPendingPlacement,gPlacementAttemptClicked,delayPanel,cardDuringPurchase,cards
    if purchase {
        if !PlacementPurchaseReady(purchase)
            return false
        gPendingPlacement := purchase,gPlacementAttemptClicked := true
        buys += 1,purchased := true
        if !rejectPurchase
            models[x "," y] := true
        panel := !rejectPurchase && !delayPanel && !hidePanels
        delayPanel := false
        if cardDuringPurchase {
            cardDuringPurchase := false,cards := true
            CheckCardInterruption()
        }
    } else
        panel := !hidePanels && (modelMode?models.Has(x "," y):existingModel || purchased)
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
SavePlacementRun(*) => 0
SelectManagedUnit(number) {
    global panel
    panel := number>=1 && number<=gPlacements.Length
    return panel
}
UpgradeHeaderSignature(*) {
    throw Error("Placement must not read the upgrade heading")
}
ReadUnitUpgradeState(*) {
    throw Error("Placement must not OCR UPG 0")
}
'''

if __name__ == '__main__':
    target = ROOT/'cache'/'placement-confirmation-regression.ahk'
    target.write_text(fixture+'\n'+logic,encoding='utf-8-sig')
    result = subprocess.run([str(RUNTIME),'/ErrorStdOut=UTF-8',str(target)],capture_output=True,timeout=30)
    print(result.stdout.decode('utf-8-sig'),end='')
    print(result.stderr.decode('utf-8-sig'),end='')
    raise SystemExit(result.returncode)

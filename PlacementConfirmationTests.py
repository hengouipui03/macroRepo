"""Existing models and card overlays must never count as fresh purchases; the
slot counter (and Yen) decide a purchase, the side panel alone never does."""
import subprocess
from UpgradeRegressionTests import ROOT,RUNTIME,function

logic = '\n'.join(function(file,name) for file,name in [
    ('Placement.ahk','TryPlacementCandidateAction'),('Placement.ahk','TrySelectUnitAt'),
    ('Placement.ahk','RecoverPendingPlacement'),
    ('Placement.ahk','RefreshPlacementSearch'),('Placement.ahk','PlacementPurchaseReady'),
    ('Placement.ahk','FinishPlacement'),('Placement.ahk','CountSlotPlacements'),
    ('Placement.ahk','FailedPlacementSpot'),('Placement.ahk','RememberFailedPlacementSpot'),
    ('Placement.ahk','MissingBuildPlacements'),('Placement.ahk','PlacementShortOfYen'),
    ('PurchaseVerifier.ahk','ProbePurchase'),('PurchaseVerifier.ahk','JudgePurchase'),('PurchaseVerifier.ahk','NewPurchaseEvidence'),
    ('AAPathMacro.ahk','CheckCardInterruption')])
logic += '\n' + function('PlacedUnits.ahk','OpenRecordedUnit')
for name in ['SlotTargetCount','SlotCounterFull','CapSlot','ReconcileSlot','RemoveNewestSlotEntries','AddMissedPurchases','RenumberPlacements']:
    logic += '\n' + function('BuildAudit.ahk', name)
logic += '\n' + function('PlacementArea.ahk','PlacementAnchorKnown')
for name in ['PlacementFailureLimitReached','ResetPlacementFailureStreak','RecordFailedPlacement','PlacementCopyFailures']:
    logic += '\n' + function('PlacementArea.ahk', name)
logic = logic.replace('A_TickCount','testNow')

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gMapModel := 0,gPlacementYenWait := 0,PURCHASE_YEN_DROP_FRACTION := 0.5,PURCHASE_REPROBE_LIMIT := 3,PURCHASE_SETTLE_MS := 300
global gFailedPlacementSpots := [],FAILED_PLACEMENT_RADIUS := 28
global gRunning := true,gPlacements := [],gPendingPlacement := 0,gPlacementAttemptClicked := false
global gLastPlacedIndex := 0,gPlacementPreferredSide := 0,gPlacementEdgeMisses := Map()
global gCardHandling := false,gCardAction := "placement",gCardPollAt := 0,gCardInterruptEpoch := 0,gPlacementActiveUnit := 0,testNow := 10000
global panel := false,preview := false,existingModel := false,purchased := false,cards := false,buys := 0,slots := 0,registrations := 0
global gPlacementLine := [],gLayoutValidation := Map(),gPlacementAreaFailures := Map(),PLACEMENT_FAILURE_LIMIT := 5,gConsecutivePlacementFailures := 0
global gSlotCaps := Map(),gLastAudit := 0
global modelMode := false,models := Map(),hidePanels := false,delayPanel := false,rejectPurchase := false,cardDuringPurchase := false
global gameCount := Map(),held := false,yen := 90000,UNIT_COST := 1350,GAME_MAX := 9,lastEvidence := "",dropHoldOnBuy := false,probes := 0,unreadableCounter := false,unreadableYen := false
try {
    unit := {slot:1,name:"Unit 1",count:2,enabled:true},point := {x:400,y:330}
    existingModel := true
    Assert(!TryPlacementCandidateAction(unit,point) && buys=0 && slots=0 && registrations=0,"selecting an old model counted as a new purchase")
    existingModel := false,gFailedPlacementSpots := []
    Assert(TryPlacementCandidateAction(unit,point) && buys=1 && registrations=1,"real purchase did not bind and confirm its slot/copy")
    Assert(CountSlotPlacements(1)=1,"real purchase was counted more than once")
    Assert(InStr(lastEvidence,"slot counter 0/9 -> 1/9"),"the placement was not confirmed by the slot counter: " lastEvidence)
    Assert(!preview && !held,"the held unit was not dropped after the purchase")

    ; An unrelated panel visible behind a card is never purchase evidence.
    NewGame(1,0),registrations := 0,purchased := false,panel := true,cards := true,gCardPollAt := 0
    gPlacementActiveUnit := unit,gPendingPlacement := Pending(1,1)
    Assert(!FinishPlacement(unit,gPendingPlacement,"test") && registrations=0,"purchase confirmed while a card was up")
    Assert(!RecoverPendingPlacement(unit) && registrations=0 && gPendingPlacement,"a pending purchase was probed under a card")
    CheckCardInterruption()
    Assert(registrations=0 && buys=1,"panel behind cards falsely registered a unit")
    Assert(!gPendingPlacement && FailedPlacementSpot({x:400,y:330}) && gConsecutivePlacementFailures>=1,"a refused purchase (counter unchanged) behind the cards stayed pending or was not counted")

    ; A real pending purchase survives the card, then is verified from the slot
    ; counter without clicking the field or buying another copy.
    NewGame(1,0),gameCount[1] := 1,purchased := true,panel := true,cards := true,gCardPollAt := 0,gPendingPlacement := Pending(1,1),buys := 1,registrations := 0
    CheckCardInterruption()
    Assert(registrations=1 && CountSlotPlacements(1)=1 && buys=1,"card recovery lost or duplicated a real purchase")
    Assert(!FinishPlacement(unit,Pending(1,1),"test") && registrations=1,"same pending copy was counted twice")
    Assert(!FinishPlacement(unit,Pending(2,2),"test") && registrations=1,"pending purchase leaked into another slot")
    Assert(!FinishPlacement(unit,{x:400,y:330},"test") && registrations=1,"unbound evidence was accepted as a purchase")
    missing := MissingBuildPlacements([unit,{slot:2,count:1,enabled:true},{slot:3,count:9,enabled:false}])
    Assert(InStr(missing,"slot 1 1/2") && InStr(missing,"slot 2 0/1") && !InStr(missing,"slot 3"),"build completion ignored missing enabled copies")

    ; A bound purchase is confirmed by the slot counter, with no UPG OCR.
    unit.count := 4,modelMode := true,models := Map(),panel := false,gFailedPlacementSpots := []
    NewGame(1,3),registrations := 3,buys := 3,gPendingPlacement := 0
    Assert(TryPlacementCandidateAction(unit,point) && buys=4 && CountSlotPlacements(1)=4 && !gPendingPlacement,"the slot counter did not confirm the fourth purchase")
    RefreshPlacementSearch()
    hidePanels := true
    Assert(!TryPlacementCandidateAction(unit,{x:450,y:330}) && buys=4,"hidden panel allowed a fifth purchase after four were confirmed")
    hidePanels := false
    Assert(!TryPlacementCandidateAction(unit,{x:480,y:330}) && buys=4,"configured target four allowed a fifth purchase")

    ; The side panel never shows: the counter alone confirms, nothing is clicked again.
    unit.count := 1,NewGame(1,0),registrations := 0,buys := 0,models := Map(),delayPanel := true,gConsecutivePlacementFailures := 0
    Assert(TryPlacementCandidateAction(unit,point) && buys=1 && CountSlotPlacements(1)=1 && gConsecutivePlacementFailures=0,"a purchase without a side panel was not confirmed by its counter")

    ; The game drops the hold after the purchase: the slot key is pressed once to read the counter, Q drops it.
    NewGame(1,0),registrations := 0,buys := 0,models := Map(),dropHoldOnBuy := true,slots := 0
    Assert(TryPlacementCandidateAction(unit,point) && buys=1 && slots=2 && !held && !preview,"a dropped hold was not re-read through the slot key (" slots " slot presses)")
    dropHoldOnBuy := false

    ; A card may open during mouse-up/confirmation, before the click call returns.
    NewGame(1,0),registrations := 0,buys := 0,models := Map(),cardDuringPurchase := true
    gPlacementActiveUnit := unit,gCardPollAt := 0
    TryPlacementCandidateAction(unit,point)
    Assert(buys=1 && CountSlotPlacements(1)=1 && !gPendingPlacement,"card during purchase lost the binding or restored an already confirmed pending copy")
    Assert(!TryPlacementCandidateAction(unit,{x:450,y:330}) && buys=1,"post-card recovery bought beyond the configured count")

    ; A refused click (counter unchanged) is a failure; the spot stays retryable elsewhere.
    NewGame(1,0),registrations := 0,buys := 0,models := Map(),rejectPurchase := true,gConsecutivePlacementFailures := 0
    Assert(!TryPlacementCandidateAction(unit,point) && !gPendingPlacement && !preview && gConsecutivePlacementFailures=1,"confirmed empty spot stayed pending, kept its preview, or counted twice")
    Assert(FailedPlacementSpot(point),"a refused purchase did not blacklist its spot")
    rejectPurchase := false
    unit.count := 2
    Assert(TryPlacementCandidateAction(unit,{x:450,y:330}) && CountSlotPlacements(1)=1,"a failed purchase prevented the next valid placement")
    RefreshPlacementSearch()
    Assert(!TryPlacementCandidateAction(unit,point) && !TryPlacementCandidateAction(unit,{x:425,y:330}) && buys=2,"the next copy retried a rejected patch after placement and rescan")

    ; Five actual rejected purchase clicks, including their recovery probes,
    ; count once each. A sixth buy must be blocked at the transaction boundary.
    NewGame(1,0),registrations := 0,buys := 0,models := Map(),rejectPurchase := true,gFailedPlacementSpots := []
    ResetPlacementFailureStreak()
    Loop 5
        Assert(!TryPlacementCandidateAction(unit,{x:250+A_Index*30,y:330}),"rejected purchase was registered")
    Assert(buys=5 && gConsecutivePlacementFailures=5,"recovery clicks double-counted or dropped failed purchases")
    RefreshPlacementSearch()
    Assert(!TryPlacementCandidateAction(unit,{x:500,y:330}) && buys=5,"rescan allowed a sixth purchase without relocation")
    ResetPlacementFailureStreak(),rejectPurchase := false,gFailedPlacementSpots := []

    ; Reproduce the start-of-game setup in the user's log. All 16 purchases
    ; across six slots must advance on the slot counter alone (no side panel).
    NewGame(1,0),registrations := 0,buys := 0,models := Map(),panel := false,hidePanels := true
    for slot,target in [3,3,1,1,4,4] {
        unit := {slot:slot,name:"Unit " slot,count:target,enabled:true}
        Loop target {
            candidate := {x:200+slot*30,y:230+A_Index*24,hill:slot=1}
            Assert(TryPlacementCandidateAction(unit,candidate),"the slot counter did not advance slot " slot)
        }
        Assert(CountSlotPlacements(slot)=target && !gPendingPlacement,"slot " slot " remained blocked after its counter advanced")
        Assert(!TryPlacementCandidateAction(unit,{x:700,y:400}),"completed slot bought an extra unit")
    }
    Assert(buys=16 && registrations=16,"six-slot startup stopped at one unit or bought extra copies")
    hidePanels := false
    models["400,330"] := true
    recorded := {id:1,name:"Unit 1",x:400,y:330,selectX:400,selectY:330}
    Assert(OpenRecordedUnit(recorded) && panel && buys=16,"side panel did not confirm selection for upgrading without UPG OCR")

    gMapModel := {checkpointIndex:3},NewGame(1,0),registrations := 0,buys := 0,models := Map(),panel := false
    unit := {slot:1,name:"Unit 1",count:1,enabled:true},gConsecutivePlacementFailures := 5
    Assert(!PlacementFailureLimitReached() && TryPlacementCandidateAction(unit,point) && buys=1,"checkpoint 3 did not keep placing after five misses")
    gMapModel := 0

    attempt := {pendingSlot:1,pendingCopy:1,pendingTarget:1}
    Assert(!PlacementPurchaseReady(attempt),"last-moment purchase guard ignored the completed target")
    gPlacements := [],gPendingPlacement := Pending(1,1)
    Assert(!PlacementPurchaseReady(attempt),"last-moment purchase guard overwrote an unresolved purchase")
    gPendingPlacement := 0,attempt.pendingCopy := 2
    Assert(!PlacementPurchaseReady(attempt),"last-moment purchase guard accepted the wrong copy number")
    ; Yen is checked BEFORE the click: short of Yen no click is sent, nothing fails, the build waits.
    unit := {slot:1,name:"Unit 1",count:2,enabled:true},NewGame(1,0),registrations := 0,buys := 0,models := Map(),gFailedPlacementSpots := []
    ResetPlacementFailureStreak(),yen := 900,gPlacementYenWait := 0
    Assert(!TryPlacementCandidateAction(unit,point) && buys=0 && !preview && gConsecutivePlacementFailures=0 && gPlacementYenWait && gPlacementYenWait.slot=1 && gPlacementYenWait.cost=UNIT_COST,"a Yen-short unit was clicked, counted as a failure or did not set the wait")
    Assert(!FailedPlacementSpot(point),"a Yen-short spot was blacklisted")
    yen := 90000,gPlacementYenWait := 0
    Assert(TryPlacementCandidateAction(unit,point) && buys=1,"the unit was not bought once Yen allowed it")
    ; Unreadable Yen does not block the click; the counter still decides.
    unreadableYen := true,yen := 5
    Assert(TryPlacementCandidateAction(unit,{x:450,y:330}) && buys=2,"unreadable Yen blocked the purchase")
    unreadableYen := false

    ; The slot counter shows the slot FULL before the click (the record is
    ; behind): no click, no failure, no blacklisted spot; the slot is
    ; reconciled with the counter instead (a missed purchase, no anchor).
    GAME_MAX := 3
    unit := {slot:1,name:"Unit 1",count:3,enabled:true,priority:1,target:0}
    NewGame(1,3),gPlacements := [FullItem(1,1,300,330),FullItem(2,1,340,330)],registrations := 0,buys := 0,models := Map(),slots := 0
    ResetPlacementFailureStreak(),gFailedPlacementSpots := [],gPlacementYenWait := 0
    Assert(TryPlacementCandidateAction(unit,{x:400,y:330}),"a full slot did not report the reconciled copy")
    Assert(buys=0 && !preview && !held,"a click was sent (or the hold kept) for a slot the counter shows full")
    Assert(gConsecutivePlacementFailures=0 && !gPendingPlacement && !FailedPlacementSpot({x:400,y:330}),"a full slot counted a failure or blacklisted the spot")
    Assert(gPlacements.Length=3 && CountSlotPlacements(1)=3 && gPlacements[3].anchorless && gPlacements[3].id=3,"the missed purchase was not recorded as a new anchorless copy")
    Assert(!PlacementAnchorKnown(gPlacements[3]) && PlacementAnchorKnown(gPlacements[1]),"an anchorless copy counted as having an anchor")
    ; The game's own limit (3) is below the configured count (5): the slot is held at 3, never clicked.
    unit.count := 5
    NewGame(1,3),gPlacements := [FullItem(1,1,300,330),FullItem(2,1,340,330),FullItem(3,1,380,330)],buys := 0,gSlotCaps := Map()
    Assert(!TryPlacementCandidateAction(unit,{x:400,y:330}) && buys=0 && gSlotCaps.Has(1) && gSlotCaps[1]=3,"a unit limit below the configured count was not capped")
    Assert(!TryPlacementCandidateAction(unit,{x:420,y:330}) && buys=0 && SlotTargetCount(unit)=3,"a capped slot was tried again")
    Assert(MissingBuildPlacements([unit])="","a capped slot still counted as missing")
    GAME_MAX := 9,gSlotCaps := Map()
    FileAppend "PASS: a full slot before the click: no click, no failure, reconciled; five actual rejected purchases counted once each; sixth buy blocked after rescan; the slot counter alone confirms a bound purchase (also with the hold dropped or no panel); no UPG OCR; all 16 startup purchases across six slots advance; target four never buys five; existing-model/card/duplicate guards; Yen checked before the click; interruptions.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack,"*"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
Pending(slot,copy) => {x:400,y:330,pendingSlot:slot,pendingCopy:copy,counterBefore:{n:copy-1,max:GAME_MAX},yenBefore:90000,cost:UNIT_COST}
; The game: gameCount[slot] units placed; a held unit shows its counter.
NewGame(slot,count) {
    global gPlacements,gameCount,held,preview
    gPlacements := [],gameCount := Map(),held := false,preview := false
    Loop count
        gPlacements.Push({slot:slot})
    gameCount[slot] := count
}
IsEndGameBlocking(*) => false
HasCardChoice(*) => cards
HasUnitPanel(*) => panel
CloseUnitPanel(*) {
    global panel
    panel := false
    return true
}
CancelUnitPreview(*) {
    global preview,held
    preview := false,held := false
    return true
}
ReadPurchaseState(unit) {
    global gameCount,held,yen,probes
    probes += 1
    count := gameCount.Has(unit.slot)?gameCount[unit.slot]:0
    return {yen:unreadableYen?-1:yen,cost:UNIT_COST,counter:held && !unreadableCounter?{n:count,max:GAME_MAX}:false}
}
FullItem(id,slot,x,y) => {id:id,slot:slot,name:"Unit " slot,priority:1,target:0,x:x,y:y,anchor:0,partner:"",hill:false,row:1,complete:false}
ResetUpgradeSelection(*) => 0
PlacementPanelClosedStable(*) => true
PlacementStillBesidePath(*) => true
PlacementClickRef(x,y,guard := false,purchase := 0) {
    global panel,purchased,buys,gPendingPlacement,gPlacementAttemptClicked,delayPanel,cardDuringPurchase,cards,gameCount,held,yen
    if purchase {
        if !PlacementPurchaseReady(purchase)
            return false
        gPendingPlacement := purchase,gPlacementAttemptClicked := true
        buys += 1,purchased := true
        if !rejectPurchase {
            models[x "," y] := true
            gameCount[purchase.pendingSlot] := (gameCount.Has(purchase.pendingSlot)?gameCount[purchase.pendingSlot]:0)+1
            yen -= UNIT_COST
            if dropHoldOnBuy
                held := false
        }
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
    global preview,slots,held
    preview := true,held := true,slots += 1
    return true
}
ClearCardChoice(*) {
    global panel,cards,preview,held
    Assert(registrations=0 || purchased,"card interruption counted the obscured panel before clearing it")
    panel := false,cards := false,preview := false,held := false
    return true
}
RegisterPlacedUnit(unit,point,evidence) {
    global registrations,gPlacements,lastEvidence
    Assert(!preview,"preview was active during successful placement bookkeeping")
    registrations += 1,lastEvidence := evidence
    item := {slot:unit.slot,x:point.x,y:point.y}
    gPlacements.Push(item)
    return item
}
CandidateOccupied(*) => false
PlacementTerrain(*) => "ground"
RememberHillOutcome(*) => 0
UnitPlacementCost(*) => 1350
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

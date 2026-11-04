"""Existing models and card overlays must never count as fresh purchases."""
import subprocess
from UpgradeRegressionTests import ROOT,RUNTIME,function

logic = '\n'.join(function(file,name) for file,name in [
    ('Placement.ahk','TryPlacementCandidateAction'),('Placement.ahk','TrySelectUnitAt'),
    ('Placement.ahk','RecoverPendingPlacement'),
    ('Placement.ahk','FreshPlacementPanel'),
    ('Placement.ahk','FinishPlacement'),('Placement.ahk','CountSlotPlacements'),
    ('Placement.ahk','MissingBuildPlacements'),('AAPathMacro.ahk','CheckCardInterruption')])
logic = logic.replace('A_TickCount','testNow')

fixture = r'''
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
'''

if __name__ == '__main__':
    target = ROOT/'cache'/'placement-confirmation-regression.ahk'
    target.write_text(fixture+'\n'+logic,encoding='utf-8-sig')
    result = subprocess.run([str(RUNTIME),'/ErrorStdOut=UTF-8',str(target)],capture_output=True,timeout=30)
    print(result.stdout.decode('utf-8-sig'),end='')
    print(result.stderr.decode('utf-8-sig'),end='')
    raise SystemExit(result.returncode)

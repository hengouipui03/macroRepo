"""Yen before the click: the Yen counter, the held unit's slot counter and the
slot costs are read from one OCR pass (simulated from the supplied screenshot).
Yen needs two agreeing reads; a unit that is not affordable is never clicked,
nothing is counted as a failure, the spot stays usable, and the build waits for
Yen before retrying the unit."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = "\n".join(function("Placement.ahk", n) for n in [
    "ReadPlacementMoney", "DigitsValue", "UnitPlacementCost", "PlacementShortOfYen",
    "WaitForPlacementYen"])
logic += "\n" + "\n".join(function("PurchaseVerifier.ahk", n) for n in [
    "ReadHotbarPass", "ReadPurchaseState", "YenReadsAgree", "AgreedCounter", "SlotCounterFromWords", "ParseCounterWords"])
logic += "\n" + "\n".join(function("PlacementArea.ahk", n) for n in [
    "RecordFailedPlacement", "PlacementCopyFailures", "PlacementFailureLimitReached"])
logic = logic.replace("A_TickCount", "testNow")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global testNow := 10000,gRunning := true,REF_W := 800,REF_H := 600,LEARNING_FILE := A_Temp "\yen-wait-test.ini"
global HOTBAR_SLOT_X := [251,315,379,443,508,571],HOTBAR_COUNTER_Y_MIN := 510,HOTBAR_COUNTER_Y_MAX := 535
global YEN_READ_TOLERANCE_ABS := 300,YEN_READ_TOLERANCE_FRACTION := 0.05,YEN_WAIT_MS := 20000,YEN_WAIT_UNREADABLE_LIMIT := 3
global PURCHASE_READ_ATTEMPTS := 4,COUNTER_WORD_GAP := 10,COUNTER_SLOT_GAP := 30,COUNTER_MAX_PLAUSIBLE := 99
global gLastOcrRect := "",gPlacementYenWait := 0,gUnitCosts := Map(),gUnitCostCandidates := Map(),gPendingPlacement := 0,gCardInterruptEpoch := 0
global gPlacementAreaFailures := Map(),gConsecutivePlacementFailures := 0,PLACEMENT_FAILURE_LIMIT := 6,gMapModel := 0,gPlacements := []
global yen := 9401,costs := ["2000","1400","800","",  "1000","1300"],ocrCalls := 0,remembered := 0,yenSchedule := 0
try {
    try FileDelete LEARNING_FILE
    ; The supplied screenshot: 9401 Yen; Dark Mage's "1350" is split into two words.
    read := ReadPlacementMoney()
    Assert(read.yen=9401,"Yen counter read " read.yen)
    for slot,value in [2000,1400,800,1350,1000,1300]
        Assert(read.costs.Has(slot) && read.costs[slot]=value,"slot " slot " cost read wrongly")
    Assert(DigitsValue([{x:1,text:"9,401"},{x:2,text:"¥"}],0,10000000)=9401 && DigitsValue([{x:1,text:"¥"}],0,9)=-1,"digit parsing failed")

    ; The held unit's counter is read from the same pass and never leaks into Yen.
    Assert(read.counterWords.Length=4,"the counter strip was not collected (" read.counterWords.Length " words)")
    Assert(SlotCounterFromWords(read.counterWords,1) && SlotCounterFromWords(read.counterWords,1).n=0 && SlotCounterFromWords(read.counterWords,1).max=1,"slot 1 counter 0/1 not read")
    Assert(SlotCounterFromWords(read.counterWords,3) && SlotCounterFromWords(read.counterWords,3).n=2 && SlotCounterFromWords(read.counterWords,3).max=3,"slot 3 counter 2/3 not read")
    Assert(!SlotCounterFromWords(read.counterWords,2),"a counter over another slot was taken for slot 2")

    dark := {slot:4,name:"Dark Mage",count:1}
    ; First sighting: two passes agree on the cost, it is saved; Yen is enough -> not short.
    ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(!PlacementShortOfYen(dark,state) && ocrCalls=2 && state.yen=9401 && gUnitCosts["dark_mage"]=1350,"first cost sighting was not confirmed by two reads")
    Assert(IniRead(LEARNING_FILE,"UnitCosts","dark_mage","")="1350","cost was not remembered")
    ; Short of Yen (two agreeing reads): no click, nothing counted, the build waits.
    yen := 900,ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(PlacementShortOfYen(dark,state) && ocrCalls=2 && gConsecutivePlacementFailures=0,"a Yen-short unit was not held back after two agreeing reads")
    Assert(gPlacementYenWait && gPlacementYenWait.slot=4 && gPlacementYenWait.cost=1350,"Yen wait not set")
    ; One misread ("5") is overruled: the third pass agrees with the second.
    gPlacementYenWait := 0,yenSchedule := [5,9401,9401],ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(state.yen=9401 && ocrCalls=3 && !PlacementShortOfYen(dark,state) && !gPlacementYenWait,"a single Yen misread held the purchase back")
    ; Reads that never agree give no Yen at all (at most 4 passes): the click is not blocked.
    yenSchedule := [100,9401,50,7000],ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(state.yen=-1 && ocrCalls=4 && !PlacementShortOfYen(dark,state),"disagreeing Yen reads were believed or not bounded")
    ; M6: Yen moves between passes (income): two reads within the tolerance agree, the LOWER one is used
    yenSchedule := [9401,9560],ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(state.yen=9401 && state.yenMax=9560 && ocrCalls=2,"two Yen reads within the tolerance were not accepted (min/max)")
    yen := 1300,yenSchedule := [1450,1300],ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(state.yen=1300 && state.yenMax=1450 && PlacementShortOfYen(dark,state),"the lower of two agreeing Yen reads was not used for the affordability check")
    gPlacementYenWait := 0
    ; reads further apart than the tolerance do not agree
    yenSchedule := [1000,1400,2000,2600],ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(state.yen=-1 && ocrCalls=4,"Yen reads outside the tolerance agreed")
    yenSchedule := 0
    ; Unreadable Yen or an unknown cost never blocks the click.
    yen := -1,ocrCalls := 0
    state := ReadPurchaseState(dark)
    Assert(state.yen=-1 && ocrCalls=2 && !PlacementShortOfYen(dark,state),"unreadable Yen blocked the purchase")
    yen := 900
    Assert(!PlacementShortOfYen(dark,{yen:900,cost:0,counter:false}),"an unknown cost blocked the purchase")
    ; A failed purchase no longer reads Yen: it was checked before the click.
    gPlacementYenWait := 0,gConsecutivePlacementFailures := 0,yen := 5000,ocrCalls := 0
    point := {x:410,y:330,pendingSlot:4,pendingCopy:1}
    Assert(RecordFailedPlacement(dark,point) && gConsecutivePlacementFailures=1 && !gPlacementYenWait && ocrCalls=0,"a failed purchase was not counted once, without Yen OCR")
    Assert(!RecordFailedPlacement(dark,point) && gConsecutivePlacementFailures=1,"the same failed purchase was counted twice")
    gPlacements.Push({slot:1}),gConsecutivePlacementFailures := 1
    ; A misread cost does not replace the saved one until it is read twice.
    gUnitCosts := Map(),gUnitCostCandidates := Map()
    Assert(UnitPlacementCost(dark,{yen:0,costs:Map(4,13500)})=1350,"one odd read replaced the saved cost")
    Assert(UnitPlacementCost(dark,{yen:0,costs:Map(4,13500)})=13500,"two agreeing reads did not update the cost")
    gUnitCosts["dark_mage"] := 1350
    ; Waiting: polls about once a second until affordable, then clears.
    gPlacementYenWait := {slot:4,cost:1350,since:testNow},yenSchedule := [600,900,1200,1400],ocrCalls := 0,start := testNow
    Assert(WaitForPlacementYen(dark) && !gPlacementYenWait && ocrCalls=4 && testNow-start<=4500,"Yen wait did not stop once affordable (" ocrCalls " reads)")
    Assert(!WaitForPlacementYen(dark),"no wait pending, yet it waited")
    ; Never longer than 20 s.
    gPlacementYenWait := {slot:4,cost:1350,since:testNow},yenSchedule := 0,yen := 10,start := testNow
    WaitForPlacementYen(dark)
    Assert(testNow-start<=21000 && !gPlacementYenWait,"Yen wait exceeded 20 s")
    FileAppend "PASS: Yen 9401, all six slot costs (split 13 50 joined) and the held unit's counter read from one pass; Yen needs two agreeing reads (bounded); costs confirmed by two reads and saved; a Yen-short unit is held back before the click and is not a failure; unreadable Yen or unknown cost never blocks; wait polls until affordable, max 20 s.`n","*","UTF-8"
    try FileDelete LEARNING_FILE
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
WindowGeometry() => {cw:800,ch:600}
ReadOcrRows(*) {
    global ocrCalls,yen,yenSchedule
    ocrCalls += 1
    if IsObject(yenSchedule) && yenSchedule.Length
        yen := yenSchedule.RemoveAt(1)
    rows := []
    if yen>=0
        rows.Push({x:381,y:491,w:53,h:14,text:yen "¥"})
    xs := [238,302,371,0,496,560]
    for slot,text in costs
        if text!=""
            rows.Push({x:xs[slot],y:549,w:24,h:7,text:text "¥"})
    if costs[4]=""
        rows.Push({x:434,y:549,w:8,h:7,text:"13"}),rows.Push({x:444,y:549,w:13,h:7,text:"50¥"})
    rows.Push({x:236,y:560,w:30,h:6,text:"Elyssia"})
    ; The held unit's counters sit in the band above the cost labels (slot 3 split into words).
    rows.Push({x:241,y:512,w:22,h:9,text:"0/1"})
    rows.Push({x:368,y:512,w:6,h:9,text:"2"}),rows.Push({x:375,y:512,w:4,h:9,text:"/"}),rows.Push({x:380,y:512,w:6,h:9,text:"3"})
    return rows
}
MemoryKey(text) => SubStr(RegExReplace(StrLower(text), "[^a-z0-9_-]+", "_"), 1, 100)
MemoryRead(section,key,fallback := "") {
    try return IniRead(LEARNING_FILE,section,key,fallback)
    catch
        return fallback
}
Log(*) => 0
IsEndGameBlocking(*) => false
HasCardChoice(*) => false
ClearCardChoice(*) => true
ActionPause(ms,*) {
    global testNow
    testNow += ms
    return true
}
HasUnitPanel(*) => false
CloseUnitPanel(*) => true
CancelUnitPreview(*) => true
PlacementClickRef(*) => true
WaitForUnitPanel(*) => false
FinishPlacement(*) => true
CandidateOccupied(*) => false
PlacementTerrain(*) => "ground"
RememberHillOutcome(*) => 0
RememberFailedPlacementSpot(*) {
    global remembered
    remembered += 1
}
CountSlotPlacements(*) => 0
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "yen-wait-test.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=30)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

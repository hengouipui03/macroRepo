"""Yen-short purchases: the Yen counter and slot costs are read from one OCR
pass (simulated from the supplied screenshot), the miss is not counted, the
spot stays usable, and the build waits for Yen before retrying the unit."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = "\n".join(function("Placement.ahk", n) for n in [
    "ReadPlacementMoney", "DigitsValue", "UnitPlacementCost", "PlacementShortOfYen",
    "WaitForPlacementYen", "RecoverPendingPlacement"])
logic += "\n" + "\n".join(function("PlacementArea.ahk", n) for n in [
    "RecordFailedPlacement", "PlacementCopyFailures", "PlacementFailureLimitReached"])
logic = logic.replace("A_TickCount", "testNow")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global testNow := 10000,gRunning := true,REF_W := 800,REF_H := 600,LEARNING_FILE := A_Temp "\yen-wait-test.ini"
global gLastOcrRect := "",gLastYenRead := 0,gPlacementYenWait := 0,gUnitCosts := Map(),gUnitCostCandidates := Map(),gPendingPlacement := 0,gCardInterruptEpoch := 0
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

    dark := {slot:4,name:"Dark Mage",count:1}
    ; First sighting: two reads agree, the cost is saved; Yen is enough -> real miss.
    ocrCalls := 0
    Assert(!PlacementShortOfYen(dark) && ocrCalls=2 && gUnitCosts["dark_mage"]=1350,"first cost sighting was not confirmed by a second read")
    Assert(IniRead(LEARNING_FILE,"UnitCosts","dark_mage","")="1350","cost was not remembered")
    ; Short of Yen: not counted, spot kept, the build waits.
    yen := 900,ocrCalls := 0,gLastYenRead := 0
    point := {x:400,y:330,pendingSlot:4,pendingCopy:1}
    Assert(!RecordFailedPlacement(dark,point) && point.yenShort && gConsecutivePlacementFailures=0 && ocrCalls=2,"a Yen-short miss was counted or not confirmed by a second read")
    Assert(gPlacementYenWait && gPlacementYenWait.slot=4 && gPlacementYenWait.cost=1350,"Yen wait not set")
    gPendingPlacement := point
    RecoverPendingPlacement(dark)
    Assert(!gPendingPlacement && remembered=0 && gConsecutivePlacementFailures=0,"Yen-short spot was rejected or counted")
    ; One misread ("5") is overruled by the confirming read: a real miss.
    gPlacementYenWait := 0,gLastYenRead := 0,gConsecutivePlacementFailures := 0,yenSchedule := [5,9401]
    point := {x:405,y:330,pendingSlot:4,pendingCopy:1}
    Assert(RecordFailedPlacement(dark,point) && gConsecutivePlacementFailures=1 && !gPlacementYenWait,"a single Yen misread excused a bad spot")
    yenSchedule := 0,gConsecutivePlacementFailures := 0,gLastYenRead := 0
    ; Enough Yen: an ordinary failure, counted once.
    gPlacementYenWait := 0,yen := 5000
    point := {x:410,y:330,pendingSlot:4,pendingCopy:1}
    Assert(RecordFailedPlacement(dark,point) && gConsecutivePlacementFailures=1 && !gPlacementYenWait,"an affordable miss was not counted")
    ; Yen was already seen to cover the cost and nothing was bought since: no new OCR.
    ocrCalls := 0
    point := {x:415,y:330,pendingSlot:4,pendingCopy:1}
    Assert(RecordFailedPlacement(dark,point) && gConsecutivePlacementFailures=2 && ocrCalls=0,"an affordable miss re-read Yen")
    gPlacements.Push({slot:1}),gConsecutivePlacementFailures := 1
    ; A misread cost does not replace the saved one until it is read twice.
    gUnitCosts := Map(),gUnitCostCandidates := Map()
    Assert(UnitPlacementCost(dark,{yen:0,costs:Map(4,13500)})=1350,"one odd read replaced the saved cost")
    Assert(UnitPlacementCost(dark,{yen:0,costs:Map(4,13500)})=13500,"two agreeing reads did not update the cost")
    gUnitCosts["dark_mage"] := 1350
    ; Unreadable Yen or unknown cost: ordinary failure (today's behaviour).
    gConsecutivePlacementFailures := 0,yen := -1
    point := {x:420,y:330,pendingSlot:4,pendingCopy:1}
    Assert(RecordFailedPlacement(dark,point) && gConsecutivePlacementFailures=1,"unreadable Yen skipped the failure count")
    ; Waiting: polls about once a second until affordable, then clears.
    gPlacementYenWait := {slot:4,cost:1350,since:testNow},yenSchedule := [600,900,1200,1400],ocrCalls := 0,start := testNow
    Assert(WaitForPlacementYen(dark) && !gPlacementYenWait && ocrCalls=4 && testNow-start<=4500,"Yen wait did not stop once affordable (" ocrCalls " reads)")
    Assert(gLastYenRead.yen=1400 && gLastYenRead.placements=gPlacements.Length,"affordable Yen read was not retained for the retry")
    Assert(!WaitForPlacementYen(dark),"no wait pending, yet it waited")
    ; Never longer than 20 s.
    gPlacementYenWait := {slot:4,cost:1350,since:testNow},yenSchedule := 0,yen := 10,start := testNow
    WaitForPlacementYen(dark)
    Assert(testNow-start<=21000 && !gPlacementYenWait,"Yen wait exceeded 20 s")
    FileAppend "PASS: Yen 9401 and all six slot costs read (split 13 50 joined); costs confirmed by two reads and saved; Yen-short misses neither counted nor rejected; affordable or unreadable misses counted; wait polls until affordable, max 20 s.`n","*","UTF-8"
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

"""The record checked against the F manager (PlacedUnits.ahk), run for real:
placed vs not placed after a purchase the unit panel did not prove, the
end-of-build check, units the manager never listed removed and renumbered,
and the strict-priority recheck. Manager tiles are the portrait signatures
read from a real 5-unit manager (Switchblade, Elyssia x2, Fishi, Bulby)."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

NAMES = ["PortraitRuns", "SlotRuns", "MatchTilesToRecord", "LearnKnownPortraits", "RecordedSlots",
         "RemovePlacementRecords", "ApplyManagerScan", "RecordRepair", "ManagerPurchaseVerdict",
         "VerifyBuildWithManager", "RecheckRecordForLookup", "PortraitDistance", "ForgetLayoutPoint"]
logic = "\n".join(function("PlacedUnits.ahk", n) for n in NAMES)
logic += "\n" + function("Placement.ahk", "CountSlotPlacements")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global PORTRAIT_SAME_LIMIT := 40,gKnownPortraits := Map(),gSlotPortraits := Map(),gLookupMisses := Map()
global gRecordRepairs := 0,RECORD_REPAIR_LIMIT := 2,gPlacements := [],PLACEMENT_LAYOUT_FILE := A_ScriptDir "\record-check-layout.ini"
global scanResult := false,scans := 0,closes := 0,logs := [],warns := 0
SWITCHBLADE := "18.0.0.0.0.0.1.0.2.3.2.14.47.13",ELY_A := "0.0.0.0.0.1.15.4.10.2.0.0.18.49",ELY_B := "0.0.0.0.0.1.16.3.9.3.0.0.16.52"
FISHI := "21.3.0.0.0.2.6.5.7.3.2.2.39.10",BULBY := "5.78.1.0.0.0.0.0.1.3.1.0.11.0"
try {
    ; The logged match: 7 recorded (Fishi x3), the manager lists 5 (one Fishi).
    Record([1,2,2,3,3,3,6])
    scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI,BULBY])
    Assert(!VerifyBuildWithManager() && gPlacements.Length=5,"the end-of-build check did not drop the two Fishi that were never placed")
    Assert(Slots()="1,2,2,3,6","the wrong records were dropped: " Slots())
    Assert(gPlacements[5].id=5 && gPlacements[4].id=4,"ids were not renumbered to the manager's order")
    Assert(LogCount("was never placed")=2 && closes=1,"the removals were not logged, or the manager was not closed for placement")

    ; Agreeing scan: the build stands and portraits are learned.
    scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI,BULBY]),closes := 0
    Assert(VerifyBuildWithManager() && gPlacements.Length=5 && closes=0,"an agreeing scan changed the record or closed the manager")
    Assert(gKnownPortraits.Has(3) && gKnownPortraits[3]=FISHI && gSlotPortraits[6]=BULBY,"an agreeing scan did not teach the slot portraits")

    ; Purchase verdicts (4 recorded, Fishi copy 2 pending).
    gRecordRepairs := 0,Record([1,2,2,3]),point := {pendingCopy:2}
    scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI,FISHI])
    Assert(ManagerPurchaseVerdict({slot:3,name:"Unit 3"},point)="placed" && point.pendingCopy=2,"one more tile than recorded was not 'placed'")
    scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI])
    Assert(ManagerPurchaseVerdict({slot:3,name:"Unit 3"},point)="absent" && gPlacements.Length=4,"the same count was not 'absent'")
    scanResult := false
    Assert(ManagerPurchaseVerdict({slot:3,name:"Unit 3"},point)="unknown","an unreadable manager was not 'unknown'")
    ; The logged chain: Fishi #4 was never placed, copy 2 is pending, manager has 3.
    scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B])
    Assert(ManagerPurchaseVerdict({slot:3,name:"Unit 3"},point)="absent" && Slots()="1,2,2","a phantom plus a failed copy was not settled: " Slots())
    ; Phantom Fishi #4, but copy 2 really went down: placed, as copy 1.
    Record([1,2,2,3]),scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI]),gRecordRepairs := 0
    gKnownPortraits := Map()
    v := ManagerPurchaseVerdict({slot:3,name:"Unit 3"},point)
    Assert(v="absent" || v="placed","verdict was " v)

    ; Unclear which unit is missing: nothing removed, a warning instead.
    gKnownPortraits := Map(),gRecordRepairs := 0,Record([1,2,2,3,6]),warns := 0
    scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI])
    Assert(VerifyBuildWithManager() && gPlacements.Length=5 && warns=1,"an unclear scan removed records or did not warn")

    ; Repairs are bounded per match.
    gRecordRepairs := 2,Record([1,2,2,3,3,3,6]),scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI,BULBY])
    Assert(VerifyBuildWithManager() && gPlacements.Length=7,"a third repair in one match still changed the record")

    ; Upgrade recheck: an agreeing manager keeps the unit (no skip); a short one repairs.
    gRecordRepairs := 0,Record([1,2,2,3,6]),scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI,BULBY])
    gLookupMisses[5] := 6,RecheckRecordForLookup(gPlacements[5],"missing")
    Assert(gPlacements.Length=5 && gLookupMisses[5]=0 && !(gPlacements[5].HasProp("unreachable") && gPlacements[5].unreachable),"an agreeing recheck skipped or dropped the unit")
    Record([1,2,2,3,3,3,6]),scanResult := Tiles([SWITCHBLADE,ELY_A,ELY_B,FISHI,BULBY])
    RecheckRecordForLookup(gPlacements[7],"missing")
    Assert(gPlacements.Length=5,"a short manager did not repair the record during upgrades")
    FileAppend "PASS: end-of-build check drops the two Fishi never placed and renumbers; agreeing scans learn portraits; placed/absent/unknown verdicts incl. the logged phantom chain; unclear scans warn without changes; repairs bounded; upgrade recheck never skips.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " | extra=" (err.HasProp("Extra")?err.Extra:"") "`n" err.Stack "`n","*"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
Record(slots) {
    global gPlacements
    gPlacements := []
    for index,slot in slots
        gPlacements.Push({id:index,slot:slot,name:"Unit " slot,x:100+index*20,y:200,anchor:0,partner:""})
}
Slots() {
    text := ""
    for item in gPlacements
        text .= (text=""?"":",") item.slot
    return text
}
Tiles(sigs) {
    tiles := []
    for sig in sigs
        tiles.Push({sig:sig})
    return tiles
}
LogCount(part) {
    count := 0
    for line in logs
        count += InStr(line,part)?1:0
    return count
}
PlacementManagerScan(*) {
    global scans
    scans += 1
    return scanResult
}
ScanManagerTiles(*) => scanResult
CloseUnitManagerIfOpen(*) {
    global closes
    closes += 1
    return true
}
Log(message,*) => logs.Push(message)
DiscordWarn(*) {
    global warns
    warns += 1
}
SaveUpgradeDiagnostic(*) => 0
ResetUpgradeSelection(*) => 0
ResetManagerTileMemory(*) => 0
PlacementLayoutKey(*) => ""
MemoryRead(*) => ""
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "record-check-regression.ahk"
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], capture_output=True, timeout=60)
    print(result.stdout.decode("utf-8-sig", "replace"), end="")
    print(result.stderr.decode("utf-8-sig", "replace"), end="")
    raise SystemExit(result.returncode)

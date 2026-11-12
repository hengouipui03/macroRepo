"""BuildAudit: ghost entries removed newest-first with the order kept, missed
purchases recorded with no anchor (and skipped by every anchor-dependent
function), unreadable counters retried a bounded number of times and then
trusted, completion per the counters, the bounded completion audit, and the
escalation from the Upgrading phase (close F, Placing, audit, place what is
missing, back to Upgrading). Simulated counters only; nothing touches the
screen."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

NAMES = ["ResetBuildAudit", "SlotTargetCount", "CapSlot", "SlotCounterFull", "AuditReadCounter", "ReconcileSlot",
         "RemoveNewestSlotEntries", "RenumberPlacements", "AddMissedPurchases", "AuditBuild", "VerifyCompletedBuild",
         "NoteManagerLookupMiss", "EscalateManagerLookup", "MarkUnitUnreachable",
         "ManagerAuditDue", "ManagerCooldownActive", "NoteManagerOpenFailure", "NoteManagerTileFound", "RepairBuildAfterManagerMismatch"]
logic = "\n".join(function("BuildAudit.ahk", n) for n in NAMES)
logic += "\n" + function("PlacementArea.ahk", "PlacementAnchorKnown")
logic += "\n" + function("Placement.ahk", "CountSlotPlacements")
logic += "\n" + function("Placement.ahk", "EdgeAnchors")
logic += "\n" + function("Placement.ahk", "PlacementSearchExclusions")
logic += "\n" + function("Learning.ahk", "CandidateOccupied")
logic += "\n" + function("AAPathMacro.ahk", "MapDistance")
logic += "\n" + function("MatchState.ahk", "SetPhase") + "\n" + function("MatchState.ahk", "InPhase")
logic += "\n" + function("PlacedUnits.ahk", "UpgradeQueue")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [],gPendingPlacement := 0
global gPhase := "Upgrading",MATCH_PHASES := ["Idle","Lobby","Preparing","Placing","Upgrading","Watching","Ended"]
global AUDIT_COUNTER_ATTEMPTS := 3,BUILD_AUDIT_LIMIT := 4,AUDIT_LIMIT_PER_MATCH := 2,MANAGER_LOOKUP_LIMIT := 6,MANAGER_OPEN_FAIL_LIMIT := 30
global UNIT_MANAGER_GIVEUP_COOLDOWN_MS := 300,gManagerCooldownUntil := 0,warns := [],ghostMarks := []
global PURCHASE_SETTLE_MS := 300
global gLookupMisses := Map(),gOpenFailures := 0,gEscalationAudits := 0,gCompletionAudits := 0,gAuditDue := false,gSlotCaps := Map(),gLastAudit := 0
global logs := [],counters := Map(),counterReads := Map(),blacklisted := [],steps := [],placeResult := "complete",placeFills := 0,wholePlan := 0
try {
    ; ---- ghosts: the slot's NEWEST entries go, the rest keeps its order, ids are renumbered ----
    plan := [MakePlan(1,3),MakePlan(2,2),MakePlan(3,1)]
    Reset()
    gPlacements := [MakeItem(1,1,100,300),MakeItem(2,2,140,300),MakeItem(3,1,180,300),MakeItem(4,3,220,300),MakeItem(5,1,260,300),MakeItem(6,2,300,300)]
    gPlacements[3].anchor := 1,gPlacements[1].partner := 3
    gPlacements[5].anchor := 3,gPlacements[3].partner := 5
    gPlacements[6].anchor := 2,gPlacements[2].partner := 6
    counters[1] := C(1,3),counters[2] := C(2,2),counters[3] := C(1,1)
    complete := AuditBuild(plan)
    ; slot 1 had 3 recorded (#1,#3,#5), the counter says 1: #5 then #3 are ghosts, #1 stays
    Assert(CountSlotPlacements(1)=1 && gPlacements.Length=4,"ghosts were not removed down to the counter (" gPlacements.Length " left)")
    ids := ""
    for item in gPlacements
        ids .= item.slot ","
    Assert(ids="1,2,3,2,","the remaining entries lost their order: " ids)
    for index,item in gPlacements
        Assert(item.id=index,"entry " index " was not renumbered (id " item.id ")")
    Assert(gLastAudit.removed.Length=2 && gLastAudit.removed[1]=5 && gLastAudit.removed[2]=3,"ghosts were not removed newest first: " Join(gLastAudit.removed))
    Assert(LogCount("ghost #5")=1 && LogCount("ghost #3")=1,"each removal was not logged")
    ; links: #1's partner (#3) is gone; the old #6 (now #4) still points at the old #2 (still #2)
    Assert(gPlacements[1].partner="" && gPlacements[4].anchor=2 && gPlacements[2].partner=4,"anchor/partner links were not renumbered or cleared")
    Assert(!complete && gSlotCaps.Count=0,"slot 1 holds 1 of 3 after the ghosts left: the build must be incomplete")
    Assert(blacklisted.Length=2,"ghost positions were not kept away from placement")
    Assert(ghostMarks.Length=2 && ghostMarks[1]="1:260" && ghostMarks[2]="1:180","ghosts were not penalised in the learning data: " Join(ghostMarks))

    ; ---- a missed purchase: placed, no anchor, skipped by the anchor code ----
    Reset()
    plan := [MakePlan(1,2)]
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(2,2)
    Assert(AuditBuild(plan) && gPlacements.Length=2 && CountSlotPlacements(1)=2,"a missed purchase was not recorded")
    missed := gPlacements[2]
    Assert(missed.anchorless && !PlacementAnchorKnown(missed) && missed.id=2 && missed.anchor=0 && missed.partner="","the missed purchase was not marked anchorless")
    Assert(gLastAudit.added.Length=1 && gLastAudit.added[1]=2 && LogCount("missed purchase")>=1,"the missed purchase was not logged")
    ; it sits at 0,0 on paper: no position code may use it
    Assert(!CandidateOccupied(0,0) && !CandidateOccupied(5,5),"an anchorless copy blocked a spot near 0,0")
    Assert(CandidateOccupied(100,300),"the recorded unit stopped blocking its spot")
    missed.row := 1
    anchors := EdgeAnchors()
    Assert(anchors.Length=1 && anchors[1].id=1,"EdgeAnchors used an anchorless copy")
    Assert(PlacementSearchExclusions(true)="100,300","vision exclusions included an anchorless copy: " PlacementSearchExclusions(true))
    Assert(UpgradeQueue().Length=2,"the missed purchase did not enter the upgrade queue")

    ; ---- more units than planned are all recorded (the manager lists them) ----
    Reset()
    plan := [MakePlan(1,1)]
    gPlacements := []
    counters[1] := C(3,3)
    AuditBuild(plan)
    Assert(gPlacements.Length=3 && gPlacements[3].id=3,"extra units on the field were not recorded")

    ; ---- unreadable counter: bounded retries, then the recorded count is trusted ----
    Reset()
    plan := [MakePlan(1,2),MakePlan(2,1)]
    gPlacements := [MakeItem(1,1,100,300),MakeItem(2,2,140,300)]
    counters[1] := false,counters[2] := C(1,1)
    complete := AuditBuild(plan)
    Assert(counterReads[1]=AUDIT_COUNTER_ATTEMPTS,"an unreadable counter was read " counterReads[1] " times, expected the bound " AUDIT_COUNTER_ATTEMPTS)
    Assert(gLastAudit.unreadable.Length=1 && gLastAudit.unreadable[1]=1 && CountSlotPlacements(1)=1 && gPlacements.Length=2,"an unreadable slot was changed")
    Assert(!complete,"slot 1 has 1 of 2 recorded: the build must be incomplete")
    Assert(LogCount("trusting the 1 recorded")=1,"trusting the record was not logged")
    ; a read that works on the second attempt
    Reset()
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(2,2),flaky[1] := 1
    AuditBuild([MakePlan(1,2)])
    Assert(counterReads[1]=2 && gPlacements.Length=2 && !gLastAudit.unreadable.Length,"a counter that read on the second try was not used")

    ; ---- incomplete per the counters ----
    Reset()
    plan := [MakePlan(1,3)]
    gPlacements := [MakeItem(1,1,100,300),MakeItem(2,1,140,300),MakeItem(3,1,180,300)]
    counters[1] := C(2,3)
    Assert(!AuditBuild(plan) && CountSlotPlacements(1)=2,"a ghost left the build looking complete")
    ; disabled slots and count 0 are not read
    Reset()
    plan := [MakePlan(1,1),MakePlan(2,1)]
    plan[2].enabled := false
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(1,1)
    AuditBuild(plan)
    Assert(!counterReads.Has(2),"a disabled slot was read")

    ; ---- the game's limit below the configured count caps the slot (complete at the cap) ----
    Reset()
    plan := [MakePlan(1,5)]
    gPlacements := [MakeItem(1,1,100,300),MakeItem(2,1,140,300),MakeItem(3,1,180,300)]
    counters[1] := C(3,3)
    Assert(AuditBuild(plan) && gSlotCaps[1]=3 && SlotTargetCount(plan[1])=3,"a unit capped at 3/3 by the game kept the build incomplete")

    ; ---- the completion audit is bounded ----
    Reset()
    plan := [MakePlan(1,1)]
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(0,1)
    Loop BUILD_AUDIT_LIMIT {
        gPlacements := [MakeItem(1,1,100,300)]
        Assert(!VerifyCompletedBuild(plan),"audit " A_Index " should have found a ghost")
    }
    gPlacements := [MakeItem(1,1,100,300)]
    reads := counterReads[1]
    Assert(VerifyCompletedBuild(plan) && counterReads[1]=reads && LogCount("Build audit limit")=1,"the completion audit was not bounded by BUILD_AUDIT_LIMIT")

    ; ---- escalation: lookups, the audit request, the audit limit, give-up ----
    Reset()
    unit := {id:3,name:"Unit 3",complete:false}
    Loop MANAGER_LOOKUP_LIMIT-1
        Assert(NoteManagerLookupMiss(3)<MANAGER_LOOKUP_LIMIT,"lookup limit hit early")
    Assert(NoteManagerLookupMiss(3)=MANAGER_LOOKUP_LIMIT && NoteManagerLookupMiss(4)=1,"the lookup limit is per purchase")
    Assert(EscalateManagerLookup(unit,"mismatch") && ManagerAuditDue() && gEscalationAudits=1,"the first escalation did not request an audit")
    Assert(EscalateManagerLookup(unit,"mismatch") && gEscalationAudits=1,"a pending audit request was counted twice")
    gAuditDue := false
    Assert(EscalateManagerLookup(unit,"missing") && gEscalationAudits=2,"the second escalation did not request an audit")
    gAuditDue := false
    Assert(!EscalateManagerLookup(unit,"missing") && !ManagerAuditDue() && unit.unreachable && gEscalationAudits=AUDIT_LIMIT_PER_MATCH,"audit exhaustion did not give the unit up")
    Assert(LogCount("skipping it and continuing")=1,"giving a unit up was not logged")
    ; ResetBuildAudit clears all of it for the next match
    ResetBuildAudit()
    Assert(!gLookupMisses.Count && gEscalationAudits=0 && gCompletionAudits=0 && !gAuditDue && !gSlotCaps.Count && !gLastAudit,"ResetBuildAudit left state behind")
    ; F that never opens: each round of attempts is bounded, then a cooldown (a
    ; timestamp), then the same attempts again. No unit is given up for it.
    Reset()
    gPlacements := [MakeItem(1,1,100,300),MakeItem(2,2,140,300)]
    gPlacements[1].complete := true
    Loop MANAGER_OPEN_FAIL_LIMIT-1
        Assert(!NoteManagerOpenFailure() && !ManagerCooldownActive(),"F failures hit the limit early")
    NoteManagerTileFound()
    Loop MANAGER_OPEN_FAIL_LIMIT-1
        Assert(!NoteManagerOpenFailure(),"a found tile did not reset the F failure count")
    started := A_TickCount
    Assert(NoteManagerOpenFailure() && ManagerCooldownActive(),"the limit did not start the cooldown")
    Assert(!gPlacements[2].HasProp("unreachable") && !gPlacements[1].HasProp("unreachable") && UpgradeQueue().Length=1,"an F that never opens gave a unit up")
    Assert(LogCount("pausing upgrades for 0 s, then trying again")=1 || LogCount("pausing upgrades for")=1,"the cooldown was not logged once")
    Assert(ManagerCooldownActive() && A_TickCount-started<UNIT_MANAGER_GIVEUP_COOLDOWN_MS,"the cooldown ended at once")
    ; the check is a timestamp: it returns at once (no sleep), then reports the end once
    t := A_TickCount
    Loop 50
        ManagerCooldownActive()
    Assert(A_TickCount-t<UNIT_MANAGER_GIVEUP_COOLDOWN_MS,"the cooldown check blocked")
    Sleep UNIT_MANAGER_GIVEUP_COOLDOWN_MS+60
    Assert(!ManagerCooldownActive() && !ManagerCooldownActive() && LogCount("cooldown over")=1,"the cooldown did not end once")
    ; the cooldown repeats: another full round of failures starts another one
    Loop MANAGER_OPEN_FAIL_LIMIT-1
        Assert(!NoteManagerOpenFailure(),"the failure count was not reset after the cooldown")
    Assert(NoteManagerOpenFailure() && ManagerCooldownActive() && LogCount("pausing upgrades for")=2,"the cooldown did not repeat")
    ; a new match clears it
    ResetBuildAudit()
    Assert(!ManagerCooldownActive(),"ResetBuildAudit left the cooldown running")

    ; ---- a slot given up: one clear line and a Discord warning ----
    Reset()
    warns := []
    CapSlot(MakePlan(2,5),3,"40 attempts at copy 4")
    Assert(LogCount("Slot 2 (Unit 2): giving up after 40 attempts at copy 4; continuing with 3 of 5 units.")=1,"the give-up line is wrong: " (logs.Length?logs[1]:"none"))
    Assert(warns.Length=1 && warns[1]=logs[1],"the give-up was not sent to Discord")
    CapSlot(MakePlan(2,5),3,"again")
    Assert(logs.Length=1 && warns.Length=1,"the same cap was logged twice")
    CapSlot(MakePlan(3,2),2,"the game's limit")
    Assert(warns.Length=1,"a cap that loses no units warned")

    ; ---- back through Placing: close F, audit, place what is missing, Upgrading again ----
    Reset()
    plan := [MakePlan(1,2)]
    gPlacements := [MakeItem(1,1,100,300),MakeItem(2,1,140,300)]
    counters[1] := C(2,2),steps := [],gAuditDue := true,gPhase := "Upgrading",placeResult := "complete"
    Assert(RepairBuildAfterManagerMismatch(plan)="complete","repair did not return to the manager phase")
    Assert(StepText()="close F|audit read in Placing|begin Upgrading|open F","repair steps wrong: " StepText())
    Assert(!ManagerAuditDue() && gPhase="Upgrading","the audit request stayed set or the phase was not restored")
    ; a missing unit is placed in the Placing phase before Upgrading returns
    Reset()
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(1,2),steps := [],gAuditDue := true,gPhase := "Upgrading",placeResult := "complete",placeFills := 1
    Assert(RepairBuildAfterManagerMismatch(plan)="complete" && gPlacements.Length=2,"the missing unit was not placed during the repair")
    Assert(StepText()="close F|audit read in Placing|place in Placing|begin Upgrading|open F","repair with placing: " StepText())
    ; placement that ends in replay does not return to Upgrading
    Reset()
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(1,2),steps := [],gAuditDue := true,gPhase := "Upgrading",placeResult := "replay",placeFills := 0
    Assert(RepairBuildAfterManagerMismatch(plan)="replay" && !InStr(StepText(),"begin Upgrading"),"a replay during the repair went back to Upgrading")
    ; stopped mid-audit
    Reset()
    gPlacements := [MakeItem(1,1,100,300)]
    counters[1] := C(1,2),steps := [],gAuditDue := true,gRunning := false
    Assert(RepairBuildAfterManagerMismatch(plan)="stopped" && !InStr(StepText(),"begin Upgrading"),"a stop during the audit went back to Upgrading")
    gRunning := true

    FileAppend "PASS: ghosts removed newest first with order kept, renumbered and links fixed; missed purchase anchorless and skipped by anchor code; unreadable counter bounded then trusted; caps; bounded completion audit; escalation request/limit/give-up; repair goes close F, Placing, audit, place, Upgrading.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
C(n,cap) => {n:n,max:cap}
MakePlan(slot,count) => {slot:slot,name:"Unit " slot,count:count,enabled:true,priority:slot,target:3,money:false}
MakeItem(id,slot,x,y) => {id:id,slot:slot,name:"Unit " slot,priority:slot,target:3,x:x,y:y,anchor:0,partner:"",hill:false,row:1,complete:false,money:false}
Join(list) {
    text := ""
    for value in list
        text .= value ","
    return text
}
StepText() {
    global steps
    text := ""
    for step in steps
        text .= (text=""?"":"|") step
    return text
}
LogCount(part) {
    global logs
    found := 0
    for line in logs
        found += InStr(line,part)?1:0
    return found
}
Reset() {
    global ghostMarks := []
    global gPlacements,counters,counterReads,blacklisted,logs,gSlotCaps,gLastAudit,gLookupMisses,gEscalationAudits,gCompletionAudits,gAuditDue,gOpenFailures,flaky,gRunning
    ResetBuildAudit()
    gPlacements := [],counters := Map(),counterReads := Map(),blacklisted := [],logs := [],flaky := Map(),gRunning := true
}
Log(text) {
    global logs
    logs.Push(text)
}
; The game's counter for a slot: counters[slot] ({n,max} or false). flaky[slot] = reads that fail first.
ProbeSlotCounter(unit) {
    global counters,counterReads,flaky,steps,gPhase
    if !steps.Length || steps[steps.Length]!="audit read in " gPhase
        steps.Push("audit read in " gPhase)
    counterReads[unit.slot] := (counterReads.Has(unit.slot)?counterReads[unit.slot]:0)+1
    if flaky.Has(unit.slot) && counterReads[unit.slot]<=flaky[unit.slot]
        return false
    return counters.Has(unit.slot)?counters[unit.slot]:false
}
RememberGhostPlacement(unit,point) {
    global ghostMarks
    ghostMarks.Push(unit.slot ":" point.x)
}
DiscordWarn(text) {
    global warns
    warns.Push(text)
}
HasCardChoice(*) => false
ClearCardChoice(*) => true
ResetUpgradeSelection(*) => 0
RememberFailedPlacementSpot(point) {
    global blacklisted
    blacklisted.Push(point)
}
CloseUnitManagerIfOpen(why) {
    global steps
    steps.Push("close F")
}
IsEndGameBlocking(*) => false
BeginUnitManagerPhase(message := "") {
    global steps
    SetPhase("Upgrading")
    steps.Push("begin Upgrading")
}
EnsureUnitManagerOpen(*) {
    global steps
    steps.Push("open F")
    return true
}
PlaceConfiguredBuild(plan) {
    global steps,gPlacements,placeResult,placeFills
    steps.Push("place in " gPhase)
    Loop placeFills
        gPlacements.Push(MakeItem(gPlacements.Length+1,1,200,300))
    return placeResult
}
'''

learning_logic = "\n".join(function("Learning.ahk", n) for n in ["RememberGhostPlacement", "RememberPlacement", "ReadPlacementRecords", "WritePlacementRecords", "PlacementSection", "HashText", "MemoryRead", "KnownPlacementCandidates"])
learning_logic += "\n" + function("AAPathMacro.ahk", "MapDistance")
learning_fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global LEARNING_FILE := A_ScriptDir "\ghost-learning-test.ini",PLACEMENT_BAD_LIMIT := 3,REF_W := 800,REF_H := 600
global gPlacementProfile := "profile.ghost-test",logs := [],gPlacements := []
try {
    try FileDelete LEARNING_FILE
    unit := {slot:1,name:"Bulby"}
    other := {slot:2,name:"Elyssia"}
    WritePlacementRecords(unit,[{x:200,y:300,good:2,bad:0},{x:500,y:300,good:1,bad:1}])
    WritePlacementRecords(other,[{x:200,y:300,good:2,bad:0}])
    ; a ghost at client 200,300 (window 200,300 here): that record is out of use, the other spot and the other unit are not
    Assert(RememberGhostPlacement(unit,{x:202,y:301}),"a remembered spot was not found")
    records := ReadPlacementRecords(unit)
    Assert(records[1].bad>=PLACEMENT_BAD_LIMIT && records[1].good=2,"the ghost spot was not penalised: bad=" records[1].bad)
    Assert(records[2].bad=1,"another spot was penalised")
    Assert(ReadPlacementRecords(other)[1].bad=0,"another unit's record was penalised")
    cands := KnownPlacementCandidates(unit)
    Assert(cands.Length=1 && cands[1].x=500,"the ghost spot is still offered as a good spot (" cands.Length ")")
    ; a ghost at a spot with no record changes nothing
    Assert(!RememberGhostPlacement(unit,{x:700,y:100}),"an unknown spot reported a mark")
    ; a later confirmed purchase there brings the spot back
    RememberPlacement(unit,{x:200,y:300},true)
    Assert(ReadPlacementRecords(unit)[1].bad=0 && ReadPlacementRecords(unit)[1].good=3,"a confirmed purchase did not clear the ghost penalty")
    try FileDelete LEARNING_FILE
    FileAppend "PASS: audit ghosts are penalised in the learning data (out of use, other spots/units untouched, cleared by a later purchase).`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
Log(text) {
    global logs
    logs.Push(text)
}
WindowGeometry() => {cx:0,x:0,cy:0,y:0,cw:800,ch:600}
CandidateOccupied(x,y) => false
'''

# The watch loop must not block during the F cooldown: upgrades are skipped by a
# timestamp check, and the cooldown check itself never sleeps.
_main = (ROOT / "AAPathMacro.ahk").read_text(encoding="utf-8-sig")
assert "if !ManagerCooldownActive() {\n                MaintainUnitManager()\n                UpgradePriorityPass()" in _main, "the watch loop does not skip upgrades during the cooldown"
assert "Sleep" not in function("BuildAudit.ahk", "ManagerCooldownActive") and "ActionPause" not in function("BuildAudit.ahk", "ManagerCooldownActive")

if __name__ == "__main__":
    status = 0
    for name, source in [("build-audit", fixture + "\n" + logic), ("ghost-learning", learning_fixture + "\n" + learning_logic)]:
        target = ROOT / "cache" / f"{name}-regression.ahk"
        target.parent.mkdir(exist_ok=True)
        target.write_text(source, encoding="utf-8-sig")
        result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                                capture_output=True, timeout=60)
        print(result.stdout.decode("utf-8-sig"), end="")
        print(result.stderr.decode("utf-8-sig"), end="")
        status = status or result.returncode
    raise SystemExit(status)

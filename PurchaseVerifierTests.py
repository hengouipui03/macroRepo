"""PurchaseVerifier: the pure purchase verdict (every rule branch and the rule
order), the slot-counter parsing, and how RecoverPendingPlacement acts on it:
confirmed registers, denied is a failure with the spot blacklisted, unknown is
re-probed a bounded number of times and then fails WITHOUT blacklisting."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = "\n".join(function("PurchaseVerifier.ahk", n) for n in [
    "NewPurchaseEvidence", "JudgePurchase", "DecidePurchase", "ParseCounterWords",
    "SlotCounterFromWords", "AgreedCounter", "ProbePurchase"])
logic += "\n" + function("Placement.ahk", "RecoverPendingPlacement")
logic += "\n" + function("Placement.ahk", "CountSlotPlacements")
logic = logic.replace("A_TickCount", "testNow")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global testNow := 10000,gRunning := true,gPlacements := [],gPendingPlacement := 0,gCardInterruptEpoch := 0
global HOTBAR_SLOT_X := [251,315,379,443,508,571]
global PURCHASE_YEN_DROP_FRACTION := 0.5,PURCHASE_REPROBE_LIMIT := 3,PURCHASE_SETTLE_MS := 300
global COUNTER_WORD_GAP := 10,COUNTER_SLOT_GAP := 30,COUNTER_MAX_PLAUSIBLE := 99
global scripted := [],slotKeys := 0,drops := 0,failures := 0,blacklisted := 0,registered := [],panel := false,occupied := false,panelChecks := 0,logs := []
try {
    ; ---- DecidePurchase: every branch of the rule list ----
    ; counter rule
    Assert(Verdict({cb:C(0,3),ca:C(1,3)})="confirmed","counter n+1 did not confirm")
    Assert(Verdict({cb:C(2,3),ca:C(3,3)})="confirmed","counter filling the slot did not confirm")
    Assert(Verdict({cb:C(1,3),ca:C(1,3)})="denied","an unchanged counter did not deny")
    Assert(Verdict({cb:C(3,3),ca:C(3,3)})="denied","an unchanged full counter did not deny")
    ; an odd counter change is not trusted: the next rules decide (and with nothing else it is unknown)
    Assert(Verdict({cb:C(0,3),ca:C(2,3)})="unknown","a +2 counter jump was trusted")
    Assert(Verdict({cb:C(2,3),ca:C(1,3)})="unknown","a falling counter was trusted")
    Assert(Verdict({cb:C(0,3),ca:C(1,4)})="unknown","counters with different max were compared")
    Assert(Verdict({cb:C(0,3),ca:C(2,3),yb:5000,ya:3650,cost:1350})="confirmed","an odd counter did not fall through to Yen")
    ; only one counter readable: not a counter verdict
    Assert(Verdict({cb:0,ca:C(1,3)})="unknown" && Verdict({cb:C(0,3),ca:0})="unknown","a single counter read decided")
    ; Yen rule
    Assert(Verdict({yb:5000,ya:3650,cost:1350})="confirmed","a full Yen drop did not confirm")
    Assert(Verdict({yb:5000,ya:4325,cost:1350})="confirmed","a drop of exactly half the cost did not confirm (675)")
    Assert(Verdict({yb:5000,ya:4326,cost:1350})="denied","a drop below half the cost did not deny")
    Assert(Verdict({yb:5000,ya:5000,cost:1350})="denied" && Verdict({yb:5000,ya:5400,cost:1350})="denied","no Yen drop did not deny")
    Assert(Verdict({yb:-1,ya:3650,cost:1350})="unknown" && Verdict({yb:5000,ya:-1,cost:1350})="unknown","one unreadable Yen decided")
    Assert(Verdict({yb:5000,ya:3650,cost:0})="unknown","Yen decided without a known cost")
    ; weak panel rule
    Assert(Verdict({panel:true,near:false})="confirmed","a panel with no unit nearby did not confirm")
    Assert(Verdict({panel:true,near:true})="unknown","a panel next to a recorded unit confirmed")
    Assert(Verdict({panel:false,near:false})="unknown","nothing at all was not unknown")
    ; rule order: counter, then Yen, then panel
    Assert(Verdict({cb:C(1,3),ca:C(1,3),yb:5000,ya:3650,cost:1350,panel:true})="denied","a Yen drop and a panel overruled the counter")
    Assert(Verdict({cb:C(1,3),ca:C(2,3),yb:5000,ya:5000,cost:1350})="confirmed","a missing Yen drop overruled the counter")
    Assert(Verdict({yb:5000,ya:5000,cost:1350,panel:true})="denied","a panel overruled the Yen reading")
    ; the reason names the evidence
    Assert(InStr(Judge({cb:C(0,3),ca:C(1,3)}).by,"slot counter 0/3 -> 1/3"),"counter reason missing")
    Assert(InStr(Judge({yb:5000,ya:3650,cost:1350}).by,"Yen 5000 -> 3650"),"Yen reason missing")
    Assert(InStr(Judge({panel:true}).by,"unit panel"),"panel reason missing")

    ; ---- counter parsing ----
    Assert(Parse([W(240,262,"0/3")]).Length=1 && Parse([W(240,262,"0/3")])[1].n=0 && Parse([W(240,262,"0/3")])[1].max=3,"0/3 not parsed")
    Assert(Parse([W(240,246,"0"),W(249,252,"/"),W(255,261,"3")]).Length=1 && Parse([W(240,246,"0"),W(249,252,"/"),W(255,261,"3")])[1].max=3,"split words were not rejoined")
    Assert(Parse([W(240,262,"1 / 3")]).Length=1,"spaces around the slash were not accepted")
    Assert(!Parse([W(240,262,"5484")]).Length && !Parse([W(240,262,"0/0")]).Length && !Parse([W(240,262,"4/3")]).Length && !Parse([W(240,262,"1/100")]).Length,"an implausible counter was accepted")
    Assert(Parse([W(240,262,"0/1"),W(368,392,"2/3")]).Length=2,"two separate counters were merged")
    two := [W(240,262,"0/1"),W(368,392,"2/3")]
    Assert(SlotCounterFromWords(two,3).n=2 && SlotCounterFromWords(two,1).max=1,"counters were not mapped by slot x")
    Assert(!SlotCounterFromWords(two,2),"two counters, none over the slot, still gave one")
    one := [W(240,262,"0/1")]
    Assert(!SlotCounterFromWords(one,2),"a counter over slot 1 was taken for slot 2")
    Assert(SlotCounterFromWords(one,1).n=0,"the counter over the held slot was missed")
    ; a lone counter over no slot at all is the held unit's
    stray := [W(200,222,"1/3")]
    Assert(SlotCounterFromWords(stray,5) && SlotCounterFromWords(stray,5).n=1,"the only counter in the strip was not taken")
    Assert(!SlotCounterFromWords([],1),"no counter words gave a counter")
    Assert(AgreedCounter([C(1,3),C(1,3)]).n=1 && !AgreedCounter([C(1,3),C(2,3)]) && !AgreedCounter([]),"counter agreement wrong")

    ; ---- the probe: weak panel only where no recorded unit is near ----
    unit := {slot:1,name:"Unit 1",count:3}
    point := {x:400,y:330,pendingSlot:1,pendingCopy:1,counterBefore:0,yenBefore:-1,cost:0}
    Unread(),panel := true,occupied := false,panelChecks := 0
    judged := ProbePurchase(unit,point)
    Assert(judged.verdict="confirmed" && InStr(judged.by,"unit panel") && panelChecks=1,"the weak panel was not used when nothing else is readable and no unit is near")
    occupied := true,panelChecks := 0
    judged := ProbePurchase(unit,point)
    Assert(judged.verdict="unknown" && panelChecks=0,"the panel was probed or trusted next to a recorded unit")
    occupied := false,panel := false
    ; counter first: an existing unit's panel is up but the counter did not move
    panel := true
    point.counterBefore := C(1,3)
    Script([{yen:-1,cost:1350,counter:C(1,3)}])
    judged := ProbePurchase(unit,point)
    Assert(judged.verdict="denied","an open panel overruled an unchanged counter")
    ; counter unreadable after the click: the slot key reads it, Q drops the hold
    slotKeys := 0,drops := 0,panel := false
    Script([{yen:-1,cost:1350,counter:false},{yen:-1,cost:1350,counter:C(2,3)}])
    judged := ProbePurchase(unit,point)
    Assert(judged.verdict="confirmed" && slotKeys=1 && drops=1,"the held unit's counter was not re-read once through its slot key")
    ; counter fine on the first read: no extra key presses
    slotKeys := 0,drops := 0
    Script([{yen:-1,cost:1350,counter:C(2,3)}])
    ProbePurchase(unit,point)
    Assert(slotKeys=0 && drops=0,"a readable counter still pressed keys")
    ; Yen drop confirms when no counter is readable
    point.counterBefore := 0,point.yenBefore := 5000,point.cost := 1350
    Script([{yen:3650,cost:1350,counter:false}])
    Assert(ProbePurchase(unit,point).verdict="confirmed","a Yen drop did not confirm without a counter")

    ; ---- recovery acts on the verdict ----
    ; confirmed: registered once, evidence passed on
    ResetFlow()
    pending := MakePending(point.x,{n:0,max:3}),gPendingPlacement := pending
    Script([{yen:-1,cost:1350,counter:C(1,3)}])
    Assert(RecoverPendingPlacement(unit) && registered.Length=1 && InStr(registered[1],"slot counter 0/3 -> 1/3") && !gPendingPlacement && failures=0,"a counter-confirmed purchase was not registered with its evidence")
    ; denied: one failure, the spot blacklisted, nothing pending
    ResetFlow()
    gPendingPlacement := MakePending(point.x,{n:0,max:3})
    Script([{yen:-1,cost:1350,counter:C(0,3)}])
    Assert(!RecoverPendingPlacement(unit) && registered.Length=0 && failures=1 && blacklisted=1 && !gPendingPlacement,"a refused purchase was not a blacklisted failure")
    ; unknown: re-probed 3 more times (4 probes in all), then a failure WITHOUT blacklisting
    ResetFlow()
    gPendingPlacement := MakePending(point.x,{n:0,max:3})
    Script([{yen:-1,cost:1350,counter:false}])
    Assert(!RecoverPendingPlacement(unit),"an unknown purchase was reported as bought")
    Assert(slotKeys=4,"unknown was probed " slotKeys " times, expected 1 + PURCHASE_REPROBE_LIMIT")
    Assert(registered.Length=0 && failures=1 && blacklisted=0 && !gPendingPlacement,"an unknown purchase blacklisted its spot, was not counted, or stayed pending")
    ; unknown at first, resolved by a later probe: no failure at all
    ResetFlow()
    gPendingPlacement := MakePending(point.x,{n:0,max:3})
    Script([{yen:-1,cost:1350,counter:false},{yen:-1,cost:1350,counter:false},{yen:-1,cost:1350,counter:false},{yen:-1,cost:1350,counter:false},{yen:-1,cost:1350,counter:C(1,3)}])
    Assert(RecoverPendingPlacement(unit) && registered.Length=1 && failures=0 && blacklisted=0,"a later probe did not confirm the purchase")
    ; a weak panel beside a recorded unit stays unknown, then fails without blacklist
    ResetFlow()
    occupied := true,panel := true
    gPendingPlacement := MakePending(point.x,0)
    Script([{yen:-1,cost:1350,counter:false}])
    Assert(!RecoverPendingPlacement(unit) && registered.Length=0 && blacklisted=0 && failures=1,"a panel next to a recorded unit confirmed or blacklisted")
    occupied := false,panel := false
    ; a card or stop mid-probe leaves the purchase pending, never a failure
    ResetFlow()
    gPendingPlacement := MakePending(point.x,{n:0,max:3})
    Script([{yen:-1,cost:1350,counter:false}])
    gRunning := false
    Assert(!RecoverPendingPlacement(unit) && gPendingPlacement && failures=0 && blacklisted=0,"a stopped run turned the pending purchase into a failure")
    gRunning := true
    FileAppend "PASS: DecidePurchase table (counter, Yen at the half-cost edge, weak panel, precedence, reasons); counter parsing and slot mapping; weak panel rejected next to a recorded unit; counter re-read through the slot key; confirmed registers with its evidence, denied blacklists, unknown re-probes 1+3 times then fails without blacklist.`n","*","UTF-8"
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
W(l,r,text) => {l:l,r:r,text:text}
Parse(words) => ParseCounterWords(words)
; A compact evidence literal: cb/ca counters, yb/ya Yen, cost, panel, near.
Evidence(spec) {
    ev := NewPurchaseEvidence()
    if spec.HasProp("cb")
        ev.counterBefore := spec.cb
    if spec.HasProp("ca")
        ev.counterAfter := spec.ca
    if spec.HasProp("yb")
        ev.yenBefore := spec.yb
    if spec.HasProp("ya")
        ev.yenAfter := spec.ya
    if spec.HasProp("cost")
        ev.cost := spec.cost
    if spec.HasProp("panel")
        ev.panelSeen := spec.panel
    if spec.HasProp("near")
        ev.recordedNearby := spec.near
    return ev
}
Verdict(spec) => DecidePurchase(Evidence(spec))
Judge(spec) => JudgePurchase(Evidence(spec))
MakePending(x,before) => {x:x,y:330,pendingSlot:1,pendingCopy:1,counterBefore:before,yenBefore:-1,cost:0}
Script(states) {
    global scripted
    scripted := states
}
Unread() => Script([{yen:-1,cost:0,counter:false}])
ResetFlow() {
    global slotKeys,drops,failures,blacklisted,registered,gPlacements,gPendingPlacement,gCardInterruptEpoch
    slotKeys := 0,drops := 0,failures := 0,blacklisted := 0,registered := [],gPlacements := [],gPendingPlacement := 0
}
; Each read takes the next scripted state; the last one repeats.
ReadPurchaseState(unit) {
    global scripted
    state := scripted.Length>1?scripted.RemoveAt(1):scripted[1]
    return {yen:state.yen,cost:state.cost,counter:state.counter}
}
SelectPlacementUnit(*) {
    global slotKeys
    slotKeys += 1
    return true
}
CancelUnitPreview(*) {
    global drops
    drops += 1
    return true
}
ActionPause(*) => gRunning
HasUnitPanel(*) {
    global panelChecks
    panelChecks += 1
    return panel
}
CandidateOccupied(*) => occupied
HasCardChoice(*) => false
IsEndGameBlocking(*) => false
CloseUnitPanel(*) => true
PlacementTerrain(*) => "ground"
RememberHillOutcome(*) => 0
Log(text) {
    global logs
    logs.Push(text)
}
RecordFailedPlacement(*) {
    global failures
    failures += 1
    return true
}
RememberFailedPlacementSpot(*) {
    global blacklisted
    blacklisted += 1
}
FinishPlacement(unit,point,evidence) {
    global registered,gPlacements,gPendingPlacement
    registered.Push(evidence)
    gPlacements.Push({slot:unit.slot})
    gPendingPlacement := 0
    return true
}
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "purchase-verifier-regression.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=60)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

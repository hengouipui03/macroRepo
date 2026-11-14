"""BuildLimits: a slot held below its count when placement gives up on it
(one log line and one Discord warning), unit manager lookups that keep failing
(a record recheck after MANAGER_LOOKUP_LIMIT misses, per purchase; never a
skip), an F that never opens (bounded rounds, then a timestamp cooldown
that never blocks) and the per-match reset. Nothing touches the screen."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

NAMES = ["ResetBuildLimits", "SlotTargetCount", "CapSlot", "ManagerLookupNeedsRecheck", "MarkUnitUnreachable",
         "NoteManagerOpenFailure", "ManagerCooldownActive", "NoteManagerTileFound"]
logic = "\n".join(function("BuildLimits.ahk", n) for n in NAMES)
logic += "\n" + function("PlacedUnits.ahk", "UpgradeQueue")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global MANAGER_LOOKUP_LIMIT := 6,MANAGER_OPEN_FAIL_LIMIT := 30,UNIT_MANAGER_GIVEUP_COOLDOWN_MS := 300
global gManagerCooldownUntil := 0,gLookupMisses := Map(),gOpenFailures := 0,gSlotCaps := Map(),gRecordRepairs := 0
global gPlacements := [],logs := [],warns := []
try {
    ; ---- a slot given up: held at its count, one clear line and a Discord warning ----
    unit := {slot:2,name:"Unit 2",count:5}
    Assert(SlotTargetCount(unit)=5,"an uncapped slot did not use its configured count")
    CapSlot(unit,3,"40 attempts at copy 4")
    Assert(SlotTargetCount(unit)=3,"a capped slot still worked towards its configured count")
    Assert(LogCount("Slot 2 (Unit 2): giving up after 40 attempts at copy 4; continuing with 3 of 5 units.")=1,"the give-up line is wrong: " (logs.Length?logs[1]:"none"))
    Assert(warns.Length=1 && warns[1]=logs[1],"the give-up was not sent to Discord")
    CapSlot(unit,3,"again")
    Assert(logs.Length=1 && warns.Length=1,"the same cap was logged twice")
    CapSlot({slot:3,name:"Unit 3",count:2},2,"nothing lost")
    Assert(warns.Length=1,"a cap that loses no units warned")

    ; ---- lookups: per purchase, the limit asks for a record recheck; never a skip ----
    a := {id:1,name:"Unit 1",slot:1,priority:1,complete:false},b := {id:2,name:"Unit 2",slot:2,priority:2,complete:false}
    gPlacements := [a,b],logs := []
    Loop MANAGER_LOOKUP_LIMIT-1
        Assert(!ManagerLookupNeedsRecheck(a),"the lookup limit was hit early")
    Assert(!ManagerLookupNeedsRecheck(b),"the lookup limit is not per purchase")
    Assert(ManagerLookupNeedsRecheck(a) && !(a.HasProp("unreachable") && a.unreachable),"the limit did not ask for a recheck, or gave the unit up")
    Assert(UpgradeQueue().Length=2 && UpgradeQueue()[1].id=1,"a unit whose tile was not found stopped holding lower priorities")

    ; ---- F that never opens: bounded rounds, then a cooldown (a timestamp); no unit given up ----
    a.unreachable := false,logs := []
    Loop MANAGER_OPEN_FAIL_LIMIT-1
        Assert(!NoteManagerOpenFailure() && !ManagerCooldownActive(),"F failures hit the limit early")
    NoteManagerTileFound()
    Loop MANAGER_OPEN_FAIL_LIMIT-1
        Assert(!NoteManagerOpenFailure(),"a found tile did not reset the F failure count")
    started := A_TickCount
    Assert(NoteManagerOpenFailure() && ManagerCooldownActive(),"the limit did not start the cooldown")
    Assert(!a.unreachable && UpgradeQueue().Length=2,"an F that never opens gave a unit up")
    Assert(LogCount("pausing upgrades for")=1,"the cooldown was not logged once")
    t := A_TickCount
    Loop 50
        ManagerCooldownActive()
    Assert(A_TickCount-t<UNIT_MANAGER_GIVEUP_COOLDOWN_MS,"the cooldown check blocked")
    Sleep UNIT_MANAGER_GIVEUP_COOLDOWN_MS+60
    Assert(!ManagerCooldownActive() && !ManagerCooldownActive() && LogCount("cooldown over")=1,"the cooldown did not end once")
    Loop MANAGER_OPEN_FAIL_LIMIT-1
        Assert(!NoteManagerOpenFailure(),"the failure count was not reset after the cooldown")
    Assert(NoteManagerOpenFailure() && ManagerCooldownActive() && LogCount("pausing upgrades for")=2,"the cooldown did not repeat")

    ; ---- a new match clears all of it ----
    ResetBuildLimits()
    Assert(!gLookupMisses.Count && !gOpenFailures && !gSlotCaps.Count && !ManagerCooldownActive(),"ResetBuildLimits left state behind")
    Assert(SlotTargetCount(unit)=5,"a cap survived the per-match reset")
    FileAppend "PASS: slot caps (one line, one Discord warning), lookup limit per purchase asks for a record recheck and never skips the unit, F cooldown bounded and non-blocking, per-match reset.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack,"*"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
LogCount(text) {
    global logs
    count := 0
    for line in logs
        count += InStr(line,text)?1:0
    return count
}
Log(text) {
    global logs
    logs.Push(text)
}
DiscordWarn(text) {
    global warns
    warns.Push(text)
}
'''

# The watch loop must not block during the F cooldown: upgrades are skipped by a
# timestamp check, and the cooldown check itself never sleeps.
_main = (ROOT / "AAPathMacro.ahk").read_text(encoding="utf-8-sig")
assert "if !ManagerCooldownActive() {\n                MaintainUnitManager()\n                UpgradePriorityPass()" in _main, "the watch loop does not skip upgrades during the cooldown"
assert "Sleep" not in function("BuildLimits.ahk", "ManagerCooldownActive") and "ActionPause" not in function("BuildLimits.ahk", "ManagerCooldownActive")

if __name__ == "__main__":
    target = ROOT / "cache" / "build-limits-regression.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=60)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

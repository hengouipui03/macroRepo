"""MatchState phases/reset and session-gated disconnect handling, with stubbed
module resets and OCR. Nothing touches the screen or sends input."""
import re
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

RESETS = ["ResetPlacementSearch", "ResetPlacedUnits", "ResetCardSelection",
          "ResetMatchCardContext", "ResetEndGameFlow", "ResetUnitManagerState"]

phase_logic = "\n".join(function("MatchState.ahk", n) for n in ["SetPhase", "InPhase", "ResetMatchState"])
phase_fixture = r"""
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gPhase := "Idle",MATCH_PHASES := ["Idle","Lobby","Preparing","Placing","Upgrading","Ended"]
global calls := [],logs := []
try {
    Assert(InPhase("Idle") && !InPhase("Lobby") && !InPhase(),"fresh state is not Idle only")
    ; Every phase can be entered, is reported by InPhase, and logs old -> new.
    last := "Idle"
    for name in ["Lobby","Preparing","Placing","Upgrading","Ended","Idle"] {
        logs := []
        Assert(SetPhase(name) && gPhase=name && InPhase(name),"could not enter " name)
        Assert(logs.Length=1 && logs[1]="Phase: " last " -> " name,"transition log wrong for " name ": " (logs.Length?logs[1]:"none"))
        last := name
    }
    ; InPhase takes several names.
    SetPhase("Placing")
    Assert(InPhase("Preparing","Placing") && !InPhase("Upgrading","Ended"),"InPhase with several names")
    ; The same phase again is a quiet no-op.
    logs := []
    Assert(SetPhase("Placing") && !logs.Length,"re-entering the same phase logged or failed")
    ; An unknown name (or a wrong case/empty) is rejected and nothing moves.
    for bad in ["Upgrade","","placing","Watching"] {
        logs := []
        Assert(!SetPhase(bad) && gPhase="Placing" && logs.Length=1 && InStr(logs[1],"rejected"),"invalid phase '" bad "' was accepted")
    }
    ; ResetMatchState calls every module reset exactly once and leaves the phase alone.
    calls := []
    ResetMatchState()
    expected := ["ResetPlacementSearch","ResetPlacedUnits","ResetCardSelection","ResetMatchCardContext","ResetEndGameFlow","ResetUnitManagerState"]
    Assert(calls.Length=expected.Length,"ResetMatchState made " calls.Length " reset calls, expected " expected.Length)
    for name in expected {
        found := 0
        for called in calls
            found += called=name
        Assert(found=1,name " was called " found " times by ResetMatchState")
    }
    Assert(gPhase="Placing","ResetMatchState changed the phase")
    FileAppend "PASS: phase transitions and log, invalid-phase rejection, InPhase with several names, ResetMatchState calls every module reset once.`n","*","UTF-8"
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
""" + "\n".join(f'{n}() {{\n    global calls\n    calls.Push("{n}")\n}}' for n in RESETS)

disc_logic = function("AAPathMacro.ahk", "CheckDisconnect")
disc_fixture = r"""
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gSessionArmed := true,gRunning := false,gReconnecting := false,gReconnectButton := false
global gOcrPid := 0,gInputEpoch := 0,gMacroThreadActive := false
global findCalls := 0,keepSeen := "never",abandons := 0,stopDuringRead := false,logs := []
global BUTTON := {x:400,y:300}
try {
    ; The run loop ended by itself (gRunning false) while F6 is still on: the
    ; dialog is read with the session predicate and handled; gRunning is untouched.
    CheckDisconnect()
    Assert(findCalls=1,"the dialog was not read with gRunning false")
    Assert(keepSeen=true,"the OCR keep-reading predicate was not true while the session is armed")
    Assert(gRunning=false,"CheckDisconnect set gRunning")
    Assert(gReconnecting && gReconnectButton=BUTTON && abandons=1,"disconnect was not handed to Reconnect")
    Assert(logs.Length=1 && InStr(logs[1],"run loop had ended"),"the ended-run case was not logged")
    ; F7 (session disarmed): nothing is read.
    gSessionArmed := false,gReconnecting := false,gReconnectButton := false,findCalls := 0,abandons := 0
    CheckDisconnect()
    Assert(findCalls=0 && !gReconnecting && abandons=0,"CheckDisconnect read the dialog after F7")
    ; F7 pressed while the OCR read is running: the result is dropped.
    gSessionArmed := true,stopDuringRead := true
    CheckDisconnect()
    Assert(findCalls=1 && !gReconnecting && abandons=0 && !gSessionArmed && gRunning=false,"a disconnect found after F7 was still handled")
    ; A run thread that is still unwinding is left alone (gRunning false, thread active).
    gSessionArmed := true,stopDuringRead := false,gMacroThreadActive := true,findCalls := 0
    CheckDisconnect()
    Assert(findCalls=0 && !gReconnecting,"CheckDisconnect read while the run thread was unwinding")
    ; A live run (gRunning true) is abandoned, not restarted from here.
    gMacroThreadActive := false,gRunning := true,logs := []
    CheckDisconnect()
    Assert(gReconnecting && abandons=1 && !logs.Length && gRunning=true,"disconnect during a live run was not handed to Reconnect untouched")
    FileAppend "PASS: CheckDisconnect with gRunning=false and gSessionArmed=true reads the dialog (predicate true) and never sets gRunning; nothing after F7; F7 mid-read drops the result; unwinding run thread left alone.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
HasDisconnectPanel() => true
FindReconnectButton(&disconnected,keepReading := 0) {
    global findCalls,keepSeen,gSessionArmed,stopDuringRead
    findCalls += 1
    keepSeen := keepReading ? keepReading() : "default"
    if stopDuringRead
        gSessionArmed := false
    disconnected := true
    return BUTTON
}
AbandonCurrentAction() {
    global abandons
    abandons += 1
}
ReconnectAndRestart() {
}
Notify(*) => 0
Log(text) {
    global logs
    logs.Push(text)
}
"""

find_logic = function("AAPathMacro.ahk", "FindReconnectButton") + "\n" + function("Learning.ahk", "NormalizeWords")
find_fixture = r"""
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global REF_W := 800,REF_H := 600,ocrKeep := "never"
try {
    pred := () => true
    FindReconnectButton(&d,pred)
    Assert(ocrKeep=pred,"FindReconnectButton did not pass its predicate to ReadOcrRows")
    FindReconnectButton(&d)
    Assert(ocrKeep=0,"the default is not 'no predicate' (ReadOcrRows then keeps reading while gRunning)")
    FileAppend "PASS: FindReconnectButton forwards the optional keep-reading predicate; default unchanged.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
FindRoblox() => 1
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 800,ch := 600
    return true
}
ReadOcrRows(x1,y1,x2,y2,words := false,scale := 2,keepReading := 0) {
    global ocrKeep
    ocrKeep := keepReading
    return []
}
RefPixels(*) => {valid:false}
"""

# CheckDisconnect must not assign gRunning at all (cf5369a forced it true).
assert not re.search(r"gRunning\s*:=", disc_logic), "CheckDisconnect writes gRunning"
# The default of ReadOcrRows is unchanged: stop when gRunning goes false.
assert "keepReading ? keepReading() : gRunning" in (ROOT / "Learning.ahk").read_text(encoding="utf-8-sig")

if __name__ == "__main__":
    for name, fixture, logic in [("match-state", phase_fixture, phase_logic),
                                 ("check-disconnect", disc_fixture, disc_logic),
                                 ("find-reconnect", find_fixture, find_logic)]:
        target = ROOT / "cache" / f"{name}-regression.ahk"
        target.parent.mkdir(exist_ok=True)
        target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
        result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)],
                                capture_output=True, timeout=30)
        print(result.stdout.decode("utf-8-sig"), end="")
        print(result.stderr.decode("utf-8-sig"), end="")
        if result.returncode:
            raise SystemExit(result.returncode)

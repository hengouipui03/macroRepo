"""F gate and phase-aware card handling, with stubbed vision, input and time.

F opens the unit manager only in the Upgrading phase; closing is allowed in
any phase. Cards close F only when it is (expected or confirmed) open, reopen
it only in Upgrading, leave a Placing purchase alone, and a card timeout is
logged and returned to the caller without ending the run."""
import re
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = "\n".join(function("MatchState.ahk", n) for n in ["SetPhase", "InPhase"])
logic += "\n" + "\n".join(function("UnitManager.ahk", n) for n in [
    "PressUnitManagerKey", "EnsureUnitManagerOpen", "CloseUnitManagerForCards",
    "ReopenUnitManagerAfterCards", "CloseUnitManagerIfOpen", "UnitManagerBlocked", "ManagerMayOpen"])
logic += "\n" + function("AAPathMacro.ahk", "ClearCardChoiceAction")
logic = logic.replace("A_TickCount", "testNow")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gPhase := "Idle",MATCH_PHASES := ["Idle","Lobby","Preparing","Placing","Upgrading","Watching","Ended"]
global gRunning := true,testNow := 10000,UNIT_ACTION_MS := 200,CARD_CHOICE_TIMEOUT_MS := 20000,gManagerPurchaseCheck := false
global gUnitManagerLastF := 0,gUnitManagerOpen := false,gUnitManagerConfirmed := false,gUnitManagerUnconfirmedF := 0
global gUnitManagerLockUntil := 0,UNIT_MANAGER_F_COOLDOWN_MS := 2500,gUnitManagerClosedForCards := false,gCardSelection := 0
global managerOpen := false,fPresses := 0,fOpens := 0,fCloses := 0,cards := false,logs := [],chooseCalls := 0,waitClosed := true,reselects := 0,stubborn := false,unreadable := false
try {
    ; --- the F gate ---
    for name in ["Idle","Lobby","Preparing","Placing","Watching","Ended"] {
        SetPhase(name),managerOpen := false,fPresses := 0
        Assert(!PressUnitManagerKey("open") && fPresses=0,"F opened the manager in the " name " phase")
        Assert(!EnsureUnitManagerOpen() && fPresses=0,"EnsureUnitManagerOpen pressed F in the " name " phase")
    }
    SetPhase("Placing"),managerOpen := false,fPresses := 0
    Assert(!PressUnitManagerKey("sideways") && fPresses=0,"an unknown F action was sent")
    for name in ["Idle","Preparing","Placing","Upgrading","Watching","Ended"] {
        SetPhase(name),managerOpen := true,fPresses := 0
        Assert(PressUnitManagerKey("close") && fPresses=1 && !managerOpen,"closing F was refused in the " name " phase")
    }
    SetPhase("Upgrading"),managerOpen := false,fPresses := 0
    Assert(PressUnitManagerKey("open") && fPresses=1 && managerOpen,"F did not open the manager in Upgrading")
    managerOpen := false,fPresses := 0,gUnitManagerLastF := 0,gUnitManagerUnconfirmedF := 0
    Assert(EnsureUnitManagerOpen() && managerOpen && fPresses=1,"EnsureUnitManagerOpen did not open with one F in Upgrading")
    ; The purchase check (a unit panel that never showed) may open F during
    ; placement, and only while that check runs.
    lastF := gUnitManagerLastF,openState := managerOpen
    SetPhase("Placing"),managerOpen := false,fPresses := 0,gManagerPurchaseCheck := true
    Assert(PressUnitManagerKey("open") && fPresses=1 && managerOpen,"the purchase check could not open F in Placing")
    gManagerPurchaseCheck := false,managerOpen := false,fPresses := 0
    Assert(!PressUnitManagerKey("open") && fPresses=0,"F still opened in Placing after the purchase check")
    SetPhase("Upgrading"),gUnitManagerLastF := lastF,managerOpen := openState

    ; --- cards per phase ---
    ; Placing, manager closed: no F before the cards, none after; no reselect.
    ResetCase("Placing",false)
    gUnitManagerClosedForCards := false
    Assert(CloseUnitManagerForCards() && fPresses=0 && !gUnitManagerClosedForCards,"Placing: cards pressed F or marked the manager for reopening")
    Assert(ReopenUnitManagerAfterCards() && fPresses=0 && reselects=0,"Placing: F was reopened after cards")
    gUnitManagerClosedForCards := true
    Assert(ReopenUnitManagerAfterCards() && fPresses=0 && !gUnitManagerClosedForCards,"Placing: a stale closed-for-cards mark reopened F")
    ; Placing, a leftover manager confirmed open: closed once, never reopened.
    ResetCase("Placing",true)
    Assert(CloseUnitManagerForCards() && fCloses=1 && !managerOpen && !gUnitManagerClosedForCards,"Placing: a leftover open manager was not closed once (or was marked for reopening)")
    Assert(ReopenUnitManagerAfterCards() && fPresses=1 && !managerOpen,"Placing: F came back after the cards")
    ; Watching (all targets done): same, F stays shut.
    ResetCase("Watching",false)
    CloseUnitManagerForCards(),ReopenUnitManagerAfterCards()
    Assert(fPresses=0,"Watching: F was pressed around the cards")
    ; Upgrading: close before cards, reopen after, top-priority unit reselected.
    ResetCase("Upgrading",true)
    Assert(CloseUnitManagerForCards() && fCloses=1 && !managerOpen && gUnitManagerClosedForCards,"Upgrading: F was not closed once before the cards")
    testNow += 3000   ; choosing a card takes seconds; F is never re-sent inside its cooldown
    Assert(ReopenUnitManagerAfterCards() && fOpens=1 && managerOpen && reselects=1 && !gUnitManagerClosedForCards,"Upgrading: F was not reopened after the cards (or the unit was not reselected)")
    ; Unreadable manager state never sends F, in any phase.
    for name in ["Placing","Upgrading"] {
        ResetCase(name,true)
        unreadable := true
        CloseUnitManagerForCards()
        Assert(fPresses=0,name ": F sent on an unreadable manager state")
        unreadable := false
    }

    ; --- full card flow through ClearCardChoiceAction ---
    ResetCase("Placing",false),cards := true,chooseCalls := 0
    Assert(ClearCardChoiceAction() && fPresses=0 && !cards,"Placing: card flow pressed F or did not finish")
    ResetCase("Placing",true),cards := true
    Assert(ClearCardChoiceAction() && fCloses=1 && fOpens=0,"Placing: card flow with a leftover manager should only close it")
    ResetCase("Upgrading",true),cards := true
    Assert(ClearCardChoiceAction() && fCloses=1 && fOpens=1 && managerOpen,"Upgrading: card flow did not close then reopen F")

    ; --- timeout: logged, returns to the caller (false), run keeps going ---
    ResetCase("Upgrading",true),cards := true,stubborn := true,logs := [],start := testNow
    result := ClearCardChoiceAction()
    Assert(!result && gRunning && testNow-start>=CARD_CHOICE_TIMEOUT_MS && testNow-start<CARD_CHOICE_TIMEOUT_MS+2000,"card timeout did not return after about 20 s")
    found := false
    for line in logs
        found := found || line="Card choice still open after 20s; the game's vote timer will pick; continuing."
    Assert(found,"card timeout did not log the continue message")
    Assert(gRunning && InPhase("Upgrading") && gUnitManagerClosedForCards,"card timeout changed the run state")
    ; The cards later go away: F comes back through the normal path.
    stubborn := false,cards := false,fOpens := 0
    Assert(ClearCardChoiceAction() && fOpens=1 && managerOpen,"after a timeout the manager was not reopened once the cards closed")
    ; A stop (F7) during the wait is not logged as a timeout.
    ResetCase("Placing",false),cards := true,stubborn := true,logs := [],gRunning := false
    ClearCardChoiceAction()
    for line in logs
        Assert(!InStr(line,"vote timer"),"a stopped run logged a card timeout")
    gRunning := true,stubborn := false
    FileAppend "PASS: F opens only in Upgrading and closes in any phase; cards close F only when it is open and reopen it only in Upgrading (Placing/Watching: no F); card timeout logs and returns without stopping the run.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
ResetCase(phase,open) {
    global managerOpen,fPresses,fOpens,fCloses,gUnitManagerClosedForCards,gUnitManagerLastF,gUnitManagerUnconfirmedF,reselects,cards,logs,gRunning
    SetPhase(phase)
    managerOpen := open,fPresses := 0,fOpens := 0,fCloses := 0,gUnitManagerClosedForCards := false
    gUnitManagerLastF := 0,gUnitManagerUnconfirmedF := 0,reselects := 0,cards := false,logs := [],gRunning := true
}
Assert(value,message) {
    if !value
        throw Error(message)
}
UnitManagerActive() => InPhase("Upgrading")
Log(text) {
    global logs
    logs.Push(text)
}
FocusUnitManagerGame(*) => true
BeginInputAction(*) => true
EndInputAction(*) => 0
ForgetManagerTile(*) => 0
ResetUpgradeSelection(*) {
    global reselects
    reselects += 1
}
ReadEndScreen(*) => {stage:"none"}
IsEndGameBlocking(*) => false
HasCardChoice(*) => cards
ReadUnitManager(*) {
    if unreadable
        return false
    return Map("open",managerOpen?"1":"0")
}
SendEvent(key) {
    global managerOpen,fPresses,fOpens,fCloses
    if key="{f up}" {
        fPresses += 1
        if managerOpen
            fCloses += 1
        else
            fOpens += 1
        managerOpen := !managerOpen
    }
}
ActionPause(ms,*) {
    global testNow
    testNow += ms
    return gRunning
}
CancelUnitPreview(*) => true
CloseUnitPanelForCards(*) => 0
TryChooseCard(*) {
    global cards,stubborn,testNow
    if !stubborn
        cards := false,testNow += 3000
}
WaitForCardChoiceClosed(*) => !cards
ResetCardSelection(*) => 0
'''

if __name__ == "__main__":
    # Static guard: every RunMacro exit goes through EndRun, and a failed
    # ClearCardChoice never ends the run loop.
    source = (ROOT / "AAPathMacro.ahk").read_text(encoding="utf-8-sig")
    body = re.search(r"^RunMacro\(\) \{\r?\n.*?^\}", source, re.M | re.S)[0]
    bare = [line for line in body.splitlines() if re.fullmatch(r"\s*return\s*", line)]
    assert not bare, "RunMacro still has a bare return: %r" % bare
    assert not re.search(r"if !ClearCardChoice\(\)\s*\n\s*return", body), "RunMacro ends the run when ClearCardChoice fails"
    assert "gUnitManagerFinished" not in source
    target = ROOT / "cache" / "card-phase-regression.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=60)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

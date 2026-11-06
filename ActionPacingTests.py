"""Run actual input helpers against a simulated clock and mocked input only."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = '\n'.join(function(file, name) for file, name in [
    ('AAPathMacro.ahk', 'BeginInputAction'),
    ('AAPathMacro.ahk', 'EndInputAction'),
    ('AAPathMacro.ahk', 'ClickRef'),
    ('AAPathMacro.ahk', 'TryVoteStart'),
    ('AAPathMacro.ahk', 'VoteStartClosed'),
    ('AAPathMacro.ahk', 'HoldCameraKey'),
    ('Placement.ahk', 'SelectPlacementUnit'),
    ('Placement.ahk', 'CancelUnitPreview'),
    ('Placement.ahk', 'PlacementClickRef'),
    ('Learning.ahk', 'ClickWindowOnce'),
]).replace('A_TickCount', 'testNow')

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gInputEpoch := 0,ACTION_GAP_MS := 300,gLastInputFinishedAt := 0
global gUnitPreviewActive := true,gPendingPlacement := 0,gPlacementAttemptClicked := false
global testNow := 10000,events := [],ACTION_HOLD_MS := 300,UNIT_ACTION_MS := 150,CLICK_HOLD_MS := 300,MOUSE_SETTLE_MS := 0,stopAfter := 0
global voteMode := false,voteVisible := true,mouseDownAt := 0,voteIgnoreClicks := 0,voteCount := ""
try {
    Assert(SelectPlacementUnit({slot:1}),"slot key failed")
    Assert(PlacementClickRef(400,330),"placement click failed")
    Assert(CancelUnitPreview(),"preview cancellation failed")
    count := events.Length
    Assert(CancelUnitPreview() && events.Length=count,"redundant Q consumed another action")
    Assert(PlacementClickRef(700,190,true,0,true),"manager Upg button click failed")
    Assert(ClickRef(400,330),"standard click failed")
    Assert(ClickWindowOnce({x:400,y:330},{x:0,y:0}),"menu click failed")
    lastUp := 0,actions := 0,downAt := 0,expected := [150,150,150,150,300,300]
    for event in events {
        if InStr(event.key,"down") {
            actions += 1
            if lastUp
                Assert(event.at-lastUp>=expected[actions],"input action gap did not match its placement/general category")
            downAt := event.at
        } else {
            Assert(event.at-downAt=expected[actions],"UI press did not match 150ms placement or 300ms general timing")
            lastUp := event.at
        }
    }
    Assert(actions=6,"input coverage incomplete")
    before := events.Length
    Assert(ClickRef(715,21),"P toggle click failed")
    Assert(events[before+2].at-events[before+1].at=300,"P toggle did not use the shared 300ms press")
    Assert(events[before+1].at-lastUp>=300,"P-specific hold bypassed 300ms action spacing")
    voteMode := true,voteVisible := true,before := events.Length
    Assert(TryVoteStart() && !voteVisible && events.Length=before+2,"Vote Start did not receive a single complete 300ms press")
    Assert(events[before+2].at-events[before+1].at=300,"Vote Start used a different hold duration")
    ; First click not taken, count unreadable: exactly one more click.
    voteVisible := true,voteIgnoreClicks := 1,voteCount := "",before := events.Length
    Assert(TryVoteStart() && !voteVisible && events.Length=before+4,"an untaken Vote Start click did not get exactly one more click")
    ; Panel still open but our vote counted: no second click (it could un-vote).
    voteVisible := true,voteIgnoreClicks := 1,voteCount := 1,before := events.Length
    Assert(!TryVoteStart() && events.Length=before+2,"a counted vote was clicked again")
    voteVisible := false,voteIgnoreClicks := 0,voteCount := ""
    voteMode := false
    before := events.Length
    Assert(PlacementClickRef(570,170,true,0,true) && events.Length=before+2,"manager portrait selection was blocked by an already open unit panel")
    Assert(events[before+2].at-events[before+1].at=150,"manager portrait did not use 150ms unit selection timing")
    testNow += 800,before := testNow
    Assert(SelectPlacementUnit({slot:2}) && testNow-before=150,"calculation time was followed by an unnecessary extra delay")
    gRunning := false,count := events.Length
    Assert(!SelectPlacementUnit({slot:1}) && events.Length=count,"stopped macro emitted a key")
    Assert(HoldCameraKey("i",120,gInputEpoch),"manual camera hold no longer works outside a run")
    gRunning := true,gUnitPreviewActive := true,stopAfter := testNow+100,count := events.Length
    Assert(!CancelUnitPreview() && events.Length=count,"F7 during the action interval still emitted input")
    FileAppend "PASS: 150ms placement/selection and 300ms general UI holds/gaps; P has no exception; Vote Start receives one full 300ms press, one more only if the first was not taken and the count shows no vote; no duplicate Q; no extra delay after calculation; manual camera works; stop interrupts immediately.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
Sleep(ms) {
    global testNow,gRunning,gInputEpoch
    testNow += ms
    if stopAfter && testNow>=stopAfter
        gRunning := false,gInputEpoch += 1
}
ActionPause(ms,*) {
    global testNow
    testNow += ms
    return gRunning
}
InputPause(ms,epoch) {
    global testNow
    testNow += ms
    return epoch=gInputEpoch
}
SendEvent(key) {
    global mouseDownAt,voteVisible
    events.Push({key:key,at:testNow})
    if InStr(key,"LButton") {
        if InStr(key,"down")
            mouseDownAt := testNow
        else if voteMode && testNow-mouseDownAt>=300 {
            if voteIgnoreClicks
                voteIgnoreClicks -= 1
            else
                voteVisible := false
        }
    }
}
Send(key) => SendEvent(key)
Click(key) => SendEvent("LButton " StrLower(key))
CheckCardInterruption(*) => false
HasVoteStart(*) => voteMode && voteVisible
ReadVoteCount(*) => voteCount
MoveRef(*) => true
SaveClickMissCrop(*) => 0
WaitFor(test,*) => test.Call()
FindUiGreenCentre(x1,y1,x2,y2,&x,&y) {
    x := 358,y := 102
    return true
}
HasCardChoice(*) => false
HasUnitPanel(*) => true
IsEndGameBlocking(*) => false
SmoothMoveTo(*) => true
FindRoblox(*) => 1
WinActivate(*) => 0
WinWaitActive(*) => true
WinActive(*) => true
PlacementPurchaseReady(*) => true
Log(*) => 0
ToScreen(x,y,&sx,&sy) {
    sx := x,sy := y
    return true
}
'''

if __name__ == '__main__':
    target = ROOT/'cache'/'action-pacing-regression.ahk'
    target.write_text(fixture+'\n'+logic, encoding='utf-8-sig')
    result = subprocess.run([str(RUNTIME),'/ErrorStdOut=UTF-8',str(target)],
                            capture_output=True,timeout=30)
    print(result.stdout.decode('utf-8-sig'),end='')
    print(result.stderr.decode('utf-8-sig'),end='')
    raise SystemExit(result.returncode)

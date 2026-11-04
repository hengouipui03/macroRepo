"""Run actual input helpers against a simulated clock and mocked input only."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = '\n'.join(function(file, name) for file, name in [
    ('AAPathMacro.ahk', 'BeginInputAction'),
    ('AAPathMacro.ahk', 'EndInputAction'),
    ('AAPathMacro.ahk', 'ClickRef'),
    ('AAPathMacro.ahk', 'HoldCameraKey'),
    ('Placement.ahk', 'SelectPlacementUnit'),
    ('Placement.ahk', 'CancelUnitPreview'),
    ('Placement.ahk', 'PlacementClickRef'),
    ('Learning.ahk', 'ClickWindowOnce'),
    ('PlacedUnits.ahk', 'PressUnitUpgradeKey'),
]).replace('A_TickCount', 'testNow')

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gInputEpoch := 0,ACTION_GAP_MS := 300,gLastInputFinishedAt := 0
global gUnitPreviewActive := true,gUpgradeLastRAt := 0,gPendingPlacement := 0,gPlacementAttemptClicked := false
global testNow := 10000,events := [],CLICK_HOLD_MS := 60,MOUSE_SETTLE_MS := 0,stopAfter := 0
try {
    Assert(SelectPlacementUnit({slot:1}),"slot key failed")
    Assert(PlacementClickRef(400,330),"placement click failed")
    Assert(CancelUnitPreview(),"preview cancellation failed")
    count := events.Length
    Assert(CancelUnitPreview() && events.Length=count,"redundant Q consumed another action")
    Assert(PressUnitUpgradeKey(),"upgrade key failed")
    Assert(ClickRef(400,330),"standard click failed")
    Assert(ClickWindowOnce({x:400,y:330},{x:0,y:0}),"menu click failed")
    lastUp := 0,actions := 0
    for event in events {
        if InStr(event.key,"down") {
            if lastUp
                Assert(event.at-lastUp>=300,"less than 300ms between input actions")
            actions += 1
        } else
            lastUp := event.at
    }
    Assert(actions=6,"input coverage incomplete")
    testNow += 800,before := testNow
    Assert(SelectPlacementUnit({slot:2}) && testNow-before=40,"calculation time was followed by an unnecessary second action delay")
    gRunning := false,count := events.Length
    Assert(!SelectPlacementUnit({slot:1}) && events.Length=count,"stopped macro emitted a key")
    Assert(HoldCameraKey("i",120,gInputEpoch),"manual camera hold no longer works outside a run")
    gRunning := true,gUnitPreviewActive := true,stopAfter := testNow+100,count := events.Length
    Assert(!CancelUnitPreview() && events.Length=count,"F7 during the action interval still emitted input")
    FileAppend "PASS: 300ms key/mouse/menu gaps; no duplicate Q; calculation time counts toward gap; precise holds retained; manual camera works; stop interrupts immediately.`n","*","UTF-8"
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
SendEvent(key) => events.Push({key:key,at:testNow})
Send(key) => SendEvent(key)
Click(key) => SendEvent("LButton " StrLower(key))
CheckCardInterruption(*) => false
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

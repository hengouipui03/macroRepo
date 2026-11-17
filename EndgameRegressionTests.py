"""Exercise the real endgame flow with simulated screens; never send input."""
from pathlib import Path
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parent
RUNTIME = os.environ.get("AHK_RUNTIME", r"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe")
logic = (ROOT / "Endgame.ahk").read_text(encoding="utf-8-sig")

# Keep the parser, cache, pre-click recheck and state machine intact. Replace
# screen capture/classification and input with a sequence of visible screens.
for name in ["EndScreenColours", "ClickEndGameButton"]:
    logic, count = re.subn(r"^" + name + r"\([^\n]*\) \{\n.*?^\}", "", logic,
                           flags=re.M | re.S)
    assert count == 1, name
logic = logic.replace("A_TickCount", "testNow")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global testNow := 10000,gRunning := true,gQueueMode := false,gMatchReported := false
global scenes := [],sceneIndex := 1,clicks := [],reports := [],logs := [],ocrCalls := 0
global geometry := {cw:1385,ch:936},stopAt := 0,changeBeforeClick := false
try {
    ; No reward: Next goes straight to the chosen exit, even when colours
    ; miss the exit menu or mistake its background for the Next screen.
    for queue in [false,true] {
        for kind in ["replay","none","next"] {
            Start([Scene("next","next"),Scene("replay",kind)],queue)
            Assert(TryEndState(),"exit flow stalled with colour classification " kind)
            Assert(ClicksAre("next," (queue?"lobby":"replay")),"extra clicks without rewards")
            Assert(gAwaitingLobby=queue && gAwaitingReplayMap=!queue,"wrong exit wait state")
            Assert(reports.Length=1 && reports[1],"victory not reported once")
        }
    }
    ; Multiple optional rewards before the result, and a late reward after
    ; Next, each get one confirmed click before normal exit handling resumes.
    for result in ["victory","defeat"] {
        Start([Scene("reward","reward"),Scene("reward","reward"),
               Scene("next","next",result),Scene("reward","none"),Scene("replay","none")])
        Assert(TryEndState(),"reward sequence stalled")
        Assert(ClicksAre("reward,reward,next,reward,replay"),"reward/menu click order changed")
        Assert(reports.Length=1 && reports[1]=(result="victory"),"result reporting changed")
    }
    ; Directly observing the exit menu still uses the configured queue mode.
    Start([Scene("replay","replay")],true)
    Assert(TryEndState() && ClicksAre("lobby"),"direct exit menu was blocked by reward handling")

    ; A delayed transition must be polled, never clicked blindly. Stop the
    ; fixture after 20 simulated seconds while no recognized screen appears.
    Start([Scene("next","next"),Scene("none","none")])
    stopAt := testNow+20000
    Assert(!TryEndState() && ClicksAre("next"),"blank transition triggered blind reward clicks")
    Assert(gEndHandling && !gAwaitingReplayMap && !gAwaitingLobby,"pending endgame lost its latch")

    ; A reward disappearing while the cursor moves must fail its recheck:
    ; the next iteration handles Next instead of clicking stale coordinates.
    Start([Scene("reward","reward"),Scene("next","next"),Scene("replay","none")])
    changeBeforeClick := true
    Assert(TryEndState() && ClicksAre("next,replay"),"stale reward click was sent")

    ; Normal gameplay keeps the cheap colour gate and does not start OCR or
    ; endgame handling. The stop guard also rejects input.
    Start([Scene("none","none")])
    Assert(!TryEndState() && !ocrCalls && !gEndHandling && !clicks.Length,"gameplay behaviour changed")
    gRunning := false
    Assert(!EndGameButtonStillVisible("none"),"stopped macro allowed input")
    ResetEndGameFlow()
    Assert(!gEndHandling && !gAwaitingReplayMap && !gAwaitingLobby && !gEndScreenCache,"reset left endgame state behind")
    FileAppend "PASS: optional/multiple/late rewards, both exits, missed/misclassified exit colours, result reporting, delayed transitions without blind clicks, stale-click recheck, gameplay gate and stop/reset.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
Scene(stage,kind,result := "victory") => {stage:stage,kind:kind,result:result}
Start(sequence,queue := false) {
    global scenes,sceneIndex,clicks,reports,logs,ocrCalls,gRunning,gQueueMode,gMatchReported,testNow,stopAt,changeBeforeClick
    ResetEndGameFlow()
    scenes := sequence,sceneIndex := 1,clicks := [],reports := [],logs := [],ocrCalls := 0
    gRunning := true,gQueueMode := queue,gMatchReported := false,testNow += 10000
    stopAt := 0,changeBeforeClick := false
}
ClicksAre(expected) {
    global clicks
    actual := ""
    for clicked in clicks
        actual .= (actual=""?"":",") clicked
    return actual=expected
}
WindowGeometry() => geometry
RefPixels(*) => {valid:true}
EndScreenColours(*) => scenes[sceneIndex].kind
Row(text,x,y) {
    global geometry
    return {text:text,x:(x-10)*geometry.cw/800,y:(y-5)*geometry.ch/600,
            w:20*geometry.cw/800,h:10*geometry.ch/600}
}
ReadOcrRows(x1,y1,x2,y2,*) {
    global scenes,sceneIndex,ocrCalls
    ocrCalls += 1
    screen := scenes[sceneIndex]
    if x1=250 && screen.stage="next"
        return [Row("Next",320,405)]
    if x1=240 && screen.stage="replay"
        return [Row("Return to lobby",320,120)]
    if x1=400 && screen.stage="replay"
        return [Row("Replay",490,120)]
    if x1=300 && screen.stage="reward"
        return [Row("(Click anywhere to continue)",400,508)]
    if x1=175 && screen.stage="next"
        return [Row(screen.result,320,180)]
    return []
}
ClickEndGameButton(screen) {
    global gRunning,scenes,sceneIndex,clicks,changeBeforeClick
    if changeBeforeClick {
        sceneIndex += 1,changeBeforeClick := false
    }
    if !EndGameButtonStillVisible(screen.stage)
        return false
    if screen.stage="replay"
        Assert(Abs(screen.y-120)<0.01 && (Abs(screen.x-320)<0.01 || Abs(screen.x-490)<0.01),"exit coordinates changed")
    clicks.Push(screen.stage="replay" && screen.x<400?"lobby":screen.stage)
    if sceneIndex<scenes.Length
        sceneIndex += 1
    return true
}
ActionPause(ms) {
    global testNow,stopAt,gRunning
    testNow += ms
    if stopAt && testNow>=stopAt
        gRunning := false
    return gRunning
}
Log(text) => logs.Push(text)
ReportMatchResult(won) {
    global reports,gMatchReported
    reports.Push(won),gMatchReported := true
}
NormalizeWords(text) => Trim(RegExReplace(StrLower(text),"[^a-z0-9]+"," "))
SetPhase(*) => true
ResetIdleKeepAlive(*) => true
ResetUpgradeSelection(*) => true
ResetCardSelection(*) => true
HasVoteStart(*) => false
WaitFor(*) => false
WaitForVoteStart(*) => false
Notify(*) => 0
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "endgame-regression.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([RUNTIME, "/ErrorStdOut=UTF-8", str(target)],
                            capture_output=True, timeout=30)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

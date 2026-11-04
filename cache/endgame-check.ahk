#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,testNow := 10000,phase := "victory",reads := 0,clicks := [],reports := [],rewardTimes := [],active := false,stopAtReward := 0,lateReplay := false,pendingUntil := 0,voteReads := 0,voteReadyAfter := 0,fixtureName := "victory",fixtureWidth := 1280,fixtureHeight := 864
; Result modal -> Next -> Replay -> wait for a fresh Vote Start.
global gEndHandling := false,gAwaitingReplayMap := false,gEndResult := ""
global gEndNextClickAt := 0,gEndScreenAt := 0,gEndScreenCache := 0
global gEndRewardsDone := false,gEndRewardSweepAt := 0

ResetEndGameFlow() {
    global gEndHandling,gAwaitingReplayMap,gEndResult,gEndNextClickAt,gEndScreenAt,gEndScreenCache,gEndRewardsDone,gEndRewardSweepAt
    gEndHandling := false,gAwaitingReplayMap := false,gEndResult := ""
    gEndNextClickAt := 0,gEndScreenAt := 0,gEndScreenCache := 0
    gEndRewardsDone := false,gEndRewardSweepAt := 0
}

EndEmptyScreen() => {stage:"none",result:"",x:0,y:0}

EndScreenColours(frame) {
    if !frame.valid
        return "none"
    nextGreen := UnitPanelColourHits(frame,250,365,400,435,IsUiGreen)
    if nextGreen>=12 {
        dark := 0
        for x in [150,220,300,400,470] {
            for y in [240,280,310,340] {
                RGB(frame.AtRef(x,y),&r,&g,&b)
                dark += Max(r,g,b)<70?1:0
            }
        }
        if dark>=14
            return "next"
    }
    if UnitPanelColourHits(frame,240,95,400,150,IsUiGreen)>=12
        && UnitPanelColourHits(frame,400,95,565,150,IsUiYellow)>=12
        return "replay"
    return "none"
}

ParseEndScreenRows(rows,geometry) {
    outcome := "",stats := false,next := 0,replay := 0,lobby := 0
    for row in rows {
        text := NormalizeWords(row.text)
        x := (row.x+row.w/2)*800/geometry.cw
        y := (row.y+row.h/2)*600/geometry.ch
        if x>=100 && x<=540 && y>=130 && y<=230 {
            if RegExMatch(text,"\bvictory[il1]*\b")
                outcome := "victory"
            else if RegExMatch(text,"\bdefeat\b")
                outcome := "defeat"
        }
        if x>=100 && x<=540 && y>=230 && y<=350
            && RegExMatch(text,"total\s*time|waves\s*completed")
            stats := true
        if RegExMatch(text,"\bnext\b") && x>=240 && x<=420 && y>=345 && y<=450
            next := {x:x,y:y}
        if RegExMatch(text,"\breplay\b") && x>=385 && x<=610 && y>=75 && y<=175
            replay := {x:x,y:y}
        if RegExMatch(text,"\breturn\s*to\s*lobby\b") && x>=200 && x<=410 && y>=75 && y<=175
            lobby := {x:x,y:y}
    }
    if next
        return {stage:"next",result:outcome,x:next.x,y:next.y}
    if replay && lobby && lobby.x<replay.x && Abs(lobby.y-replay.y)<25
        return {stage:"replay",result:"",x:replay.x,y:replay.y}
    return EndEmptyScreen()
}

ProductionReadEndScreen(force := false) {
    global gEndScreenAt,gEndScreenCache
    if !force && gEndScreenCache && testNow-gEndScreenAt<300
        return gEndScreenCache
    geometry := WindowGeometry(),screen := EndEmptyScreen()
    if geometry {
        kind := EndScreenColours(RefPixels(100,60,780,455))
        if kind="next"
            screen := ParseEndScreenRows(ReadOcrRows(250,365,400,435),geometry)
        else if kind="replay" {
            ; Focused crops are important: full-screen OCR can miss Replay.
            rows := ReadOcrRows(240,90,400,150).Clone()
            for row in ReadOcrRows(400,90,565,150)
                rows.Push(row)
            screen := ParseEndScreenRows(rows,geometry)
        }
    }
    gEndScreenCache := screen,gEndScreenAt := testNow
    return screen
}

IsEndGameBlocking() {
    global gEndHandling,gAwaitingReplayMap
    return gEndHandling || gAwaitingReplayMap || ReadEndScreen().stage!="none"
}

HasDefeatNext() => ReadEndScreen().stage="next"
HasReplayButton() => ReadEndScreen().stage="replay"

EndGameButtonStillVisible(stage) {
    global gRunning
    return gRunning && ReadEndScreen(true).stage=stage
}

ClickEndGameButton(screen) {
    global gRunning
    hwnd := FindRoblox()
    if !gRunning || !hwnd
        return false
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    if !CancelUnitPreview()
        return false
    return ClickRef(screen.x,screen.y,()=>EndGameButtonStillVisible(screen.stage))
}

ReadEndOutcome() {
    for row in ReadOcrRows(175,135,480,225) {
        text := NormalizeWords(row.text)
        if RegExMatch(text,"\bvictory[il1]*\b")
            return "victory"
        if RegExMatch(text,"\bdefeat\b")
            return "defeat"
    }
    return "unknown"
}

EndRewardClickAllowed() {
    global gRunning,gEndHandling,gAwaitingReplayMap
    return gRunning && gEndHandling && !gAwaitingReplayMap && !HasVoteStart()
}

DismissEndRewards() {
    global gRunning,gEndRewardsDone,gEndRewardSweepAt,gEndScreenAt,gEndScreenCache
    hwnd := FindRoblox()
    if !gRunning || !hwnd
        return false
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    if !CancelUnitPreview()
        return false
    Loop 5 {
        if !gRunning
            return false
        if HasVoteStart()
            return true
        ; Below the result modal, away from Next, Replay, Return to lobby,
        ; the minimap and the bottom unit bar. Never repeat a menu choice.
        if !ClickRef(400,460,EndRewardClickAllowed)
            return HasVoteStart()
        if A_Index<5 && !ActionPause(300)
            return false
    }
    gEndRewardsDone := true,gEndRewardSweepAt := testNow
    gEndScreenAt := 0,gEndScreenCache := 0
    Log("Endgame: five reward-dismissal clicks completed (300ms between clicks).")
    return true
}

TryEndState() {
    global gRunning,gEndHandling,gAwaitingReplayMap,gEndResult,gEndNextClickAt,gEndRewardsDone,gEndRewardSweepAt
    if gAwaitingReplayMap
        return true
    screen := ReadEndScreen()
    if !gEndHandling && screen.stage="none"
        return false
    if !gEndHandling {
        gEndHandling := true
        ResetIdleKeepAlive()
        ResetUpgradeSelection()
        ResetCardSelection()
        Log("Endgame detected; pausing placements and upgrades.")
    }
    deadline := testNow+60000
    while gRunning && testNow<deadline {
        screen := ReadEndScreen()
        if screen.stage="next" {
            if gEndResult="" {
                gEndResult := screen.result!=""?screen.result:ReadEndOutcome()
                Log("Result: " StrUpper(gEndResult) "; visible Next starts the endgame flow.")
                if gEndResult!="unknown"
                    ReportMatchResult(gEndResult="victory")
            }
            if testNow>=gEndNextClickAt {
                if ClickEndGameButton(screen) {
                    Log("Endgame: clicked visible Next; waiting for Replay.")
                    gEndNextClickAt := testNow+2000
                    if !DismissEndRewards()
                        return false
                }
            }
        } else if screen.stage="replay" {
            if !gEndRewardsDone && !DismissEndRewards()
                return false
            if ClickEndGameButton(screen) {
                gAwaitingReplayMap := true
                Log("Endgame: Replay selected once. Waiting for the next Vote Start; no lobby clicks.")
                return true
            }
        } else if gEndRewardsDone && testNow-gEndRewardSweepAt>=5000 {
            ; Rewards may arrive late after Next. The endgame latch keeps
            ; these extra dismissals out of live placement/upgrade phases.
            if !DismissEndRewards()
                return false
        }
        if HasVoteStart() {
            gAwaitingReplayMap := true
            return true
        }
        if !ActionPause(200)
            return false
    }
    if gRunning
        Log("Endgame transition still pending; keeping placements and upgrades paused.")
    return false
}

WaitForReplayVoteStart() {
    global gAwaitingReplayMap
    Notify("Replay loading: waiting for the next Vote Start, on the same or a new map.")
    if !WaitFor(HasVoteStart,180000,250) {
        Notify("Replay did not reach Vote Start within three minutes. Stopped without lobby or placement clicks.")
        return false
    }
    gAwaitingReplayMap := false
    return true
}

RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}

IsUiGreen(color) {
    RGB(color, &r, &g, &b)
    return g > 150 && r < 150 && b < 155 && (g - r) > 45
}

IsUiYellow(color) {
    RGB(color, &r, &g, &b)
    return r > 185 && g > 135 && b < 115
}

IsUiRed(color) {
    RGB(color, &r, &g, &b)
    return r > 180 && g < 100 && b < 105
}

UnitPanelColourHits(frame,x1,y1,x2,y2,predicate) {
    hits := 0,y := y1
    while y<=y2 {
        x := x1
        while x<=x2 {
            if predicate.Call(frame.AtRef(x,y))
                hits += 1
            x += 4
        }
        y += 4
    }
    return hits
}

try {
    for name in ["victory","defeat","replay"] {
        fixtureName := name,fixtureWidth := 1280,fixtureHeight := 864
        frame := EndFixtureFrame(A_ScriptDir "\endgame-fixtures\" name ".mapframe")
        expected := name="replay"?"replay":"next"
        Assert(EndScreenColours(frame)=expected,"Supplied " name " pixels failed the screen gate")
        screen := ProductionReadEndScreen(true)
        Assert(screen.stage=expected,"Supplied " name " OCR/coordinates failed")
        if expected="next" {
            Assert(ReadEndOutcome()=name,"Result header did not identify the correct win/loss")
            Assert(Abs(screen.x-321)<3 && Abs(screen.y-405)<4,"Next coordinate missed its actual caption")
        } else
            Assert(Abs(screen.x-479)<4 && Abs(screen.y-122)<4,"Replay coordinate missed its actual caption")
        fixtureWidth := 1385,fixtureHeight := 936
        frame := EndFixtureFrame(A_ScriptDir "\endgame-fixtures\" name "-laptop.mapframe")
        Assert(EndScreenColours(frame)=expected,"Laptop-sized " name " frame failed")
    }
    fake := [{text:"Victory in battle",x:300,y:250,w:200,h:20},{text:"Next wave",x:500,y:250,w:100,h:20}]
    Assert(ParseEndScreenRows(fake,{cw:1280,ch:864}).stage="none","World text was mistaken for an end button")
    nextOnly := [{text:"Next",x:480,y:573,w:67,h:21}]
    Assert(ParseEndScreenRows(nextOnly,{cw:1280,ch:864}).stage="next","Next-only trigger wrongly required a result title")
    for outcome in ["victory","defeat"] {
        ResetScenario(outcome)
        Assert(TryEndState() && gAwaitingReplayMap,"End flow did not reach replay loading for " outcome)
        Assert(clicks.Length=7 && clicks[1]="next" && clicks[7]="replay","Order was not Next, five reward clicks, Replay")
        Assert(rewardTimes.Length=5,"Reward dismissal did not click five times")
        Loop 4
            Assert(rewardTimes[A_Index+1]-rewardTimes[A_Index]>=300,"Reward clicks lacked the 300ms pause")
        Assert(reports.Length=1 && reports[1]=(outcome="victory"),"Win/loss result was inferred incorrectly")
        Assert(TryEndState() && clicks.Length=7,"Replay was clicked twice while waiting for teleport")
        voteReadyAfter := 3,voteReads := 0
        Assert(WaitForReplayVoteStart() && !gAwaitingReplayMap,"Next Vote Start was not awaited")
        ResetEndGameFlow()
        Assert(!gEndHandling && !gEndRewardsDone,"Next map did not reset endgame state")
    }
    ResetScenario("replay")
    Assert(TryEndState() && clicks.Length=6 && reports.Length=0,"Direct Replay screen failed or fabricated a win")
    ResetScenario("victory"),stopAtReward := 2
    Assert(!TryEndState() && rewardTimes.Length=2 && clicks[clicks.Length]!="replay","F7 did not stop the reward sequence")
    ResetScenario("victory"),lateReplay := true
    Assert(TryEndState() && rewardTimes.Length>=10 && clicks[clicks.Length]="replay","Delayed rewards prevented Replay recovery")
    FileAppend "PASS: actual Victory/Defeat/Replay images at both sizes; Next-only trigger; caption coordinates; five reward clicks with spacing; Replay once; no fabricated win; next Vote Start; delayed rewards; F7.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*"
    ExitApp 1
}
ResetScenario(outcome) {
    global gRunning,testNow,phase,clicks,reports,rewardTimes,active,stopAtReward,lateReplay,pendingUntil,voteReadyAfter,voteReads
    ResetEndGameFlow()
    gRunning := true,testNow += 100000,phase := outcome,clicks := [],reports := [],rewardTimes := [],active := false,stopAtReward := 0,lateReplay := false,pendingUntil := 0,voteReadyAfter := 0,voteReads := 0
}
Assert(value,message) {
    if !value
        throw Error(message)
}
ReadEndScreen(*) {
    global phase,testNow,pendingUntil
    if phase="delayed" && testNow>=pendingUntil
        phase := "replay"
    if phase="victory" || phase="defeat"
        return {stage:"next",result:phase,x:321,y:405}
    if phase="replay"
        return {stage:"replay",result:"",x:479,y:122}
    return EndEmptyScreen()
}
ReadOcrRows(x1,y1,x2,y2) {
    global fixtureName,fixtureWidth,fixtureHeight
    root := A_ScriptDir "\endgame-fixtures\"
    data := ParseFixtureRows(root fixtureName ".tsv")
    if fixtureName="replay" {
        for row in ParseFixtureRows(root "replay-alone.tsv",640,140)
            data.Push(row)
    }
    selected := []
    for row in data {
        rx := (row.x+row.w/2)*800/1280,ry := (row.y+row.h/2)*600/864
        if rx>=x1 && rx<=x2 && ry>=y1 && ry<=y2 {
            row := row.Clone()
            row.x *= fixtureWidth/1280,row.w *= fixtureWidth/1280
            row.y *= fixtureHeight/864,row.h *= fixtureHeight/864
            selected.Push(row)
        }
    }
    return selected
}
ParseFixtureRows(path,dx := 0,dy := 0) {
    rows := []
    for line in StrSplit(FileRead(path,"UTF-8"),"`n","`r") {
        f := StrSplit(line,"`t")
        if f.Length>=5
            rows.Push({x:Number(f[1])+dx,y:Number(f[2])+dy,w:Number(f[3]),h:Number(f[4]),text:f[5]})
    }
    return rows
}
WindowGeometry() {
    global fixtureWidth,fixtureHeight
    return {cw:fixtureWidth,ch:fixtureHeight}
}
RefPixels(*) {
    global fixtureName,fixtureWidth
    return EndFixtureFrame(A_ScriptDir "\endgame-fixtures\" fixtureName (fixtureWidth=1385?"-laptop":"") ".mapframe")
}
class EndFixtureFrame {
    valid := true
    __New(path) {
        this.data := FileRead(path,"RAW")
        this.width := NumGet(this.data,0,"UInt"),this.height := NumGet(this.data,4,"UInt")
    }
    AtRef(x,y) {
        px := Min(this.width-1,Max(0,Round(x*this.width/800)))
        py := Min(this.height-1,Max(0,Round(y*this.height/600)))
        return NumGet(this.data,24+4*(py*this.width+px),"UInt") & 0xFFFFFF
    }
}
NormalizeWords(text) => Trim(RegExReplace(StrLower(text),"[^a-z0-9%+.-]+"," "))
FindRoblox() => 1
WinActive(*) {
    global active
    return active
}
WinActivate(*) {
    global active
    active := true
}
WinWaitActive(*) => true
CancelUnitPreview() {
    global active
    Assert(active,"Input reached another app before focusing Roblox")
    return true
}
ClickRef(x,y,stillValid) {
    global phase,clicks,rewardTimes,stopAtReward,gRunning,lateReplay,pendingUntil,testNow
    if !stillValid.Call()
        return false
    if Abs(x-321)<3 && Abs(y-405)<4 {
        clicks.Push("next"),phase := "rewards"
    } else if x=400 && y=460 {
        Assert(gEndHandling && !gAwaitingReplayMap,"Reward click escaped the endgame phase")
        clicks.Push("reward"),rewardTimes.Push(testNow)
        if stopAtReward && rewardTimes.Length>=stopAtReward
            gRunning := false
        if rewardTimes.Length>=5 {
            if lateReplay && rewardTimes.Length<10 {
                phase := "delayed"
                if !pendingUntil
                    pendingUntil := testNow+8000
            } else
                phase := "replay"
        }
    } else if Abs(x-479)<4 && Abs(y-122)<4 {
        Assert(phase="replay","Replay click occurred before its menu")
        clicks.Push("replay"),phase := "loading"
    } else
        throw Error("Unexpected endgame click at " x "," y)
    return true
}
ActionPause(ms) {
    global testNow,gRunning
    testNow += ms
    return gRunning
}
HasVoteStart() {
    global phase,voteReadyAfter,voteReads
    voteReads += 1
    return phase="loading" && voteReadyAfter>0 && voteReads>=voteReadyAfter
}
WaitFor(test,timeout,poll) {
    global gRunning,testNow
    deadline := testNow+timeout
    while gRunning && testNow<deadline {
        if test.Call()
            return true
        ActionPause(poll)
    }
    return false
}
ReportMatchResult(won) {
    global reports
    reports.Push(won)
}
ResetIdleKeepAlive() => 0
ResetUpgradeSelection() => 0
ResetCardSelection() => 0
Notify(*) => 0
Log(*) => 0

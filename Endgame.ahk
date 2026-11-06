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

ReadEndScreen(force := false) {
    global gEndScreenAt,gEndScreenCache
    if !force && gEndScreenCache && A_TickCount-gEndScreenAt<300
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
    gEndScreenCache := screen,gEndScreenAt := A_TickCount
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
    gEndRewardsDone := true,gEndRewardSweepAt := A_TickCount
    gEndScreenAt := 0,gEndScreenCache := 0
    Log("Endgame: five reward-dismissal clicks completed (300ms between clicks).")
    return true
}

TryEndState() {
    global gRunning,gEndHandling,gAwaitingReplayMap,gEndResult,gEndNextClickAt,gEndRewardsDone,gEndRewardSweepAt,gMatchReported
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
    deadline := A_TickCount+60000
    while gRunning && A_TickCount<deadline {
        screen := ReadEndScreen()
        if screen.stage="next" {
            if gEndResult="" {
                gEndResult := screen.result!=""?screen.result:ReadEndOutcome()
                Log("Result: " StrUpper(gEndResult) "; visible Next starts the endgame flow.")
                if gEndResult!="unknown"
                    ReportMatchResult(gEndResult="victory")
            }
            if A_TickCount>=gEndNextClickAt {
                if ClickEndGameButton(screen) {
                    Log("Endgame: clicked visible Next; waiting for Replay.")
                    gEndNextClickAt := A_TickCount+2000
                    if !DismissEndRewards()
                        return false
                }
            }
        } else if screen.stage="replay" {
            if !gEndRewardsDone && !DismissEndRewards()
                return false
            ; The Next screen may have been missed, or its result unreadable:
            ; report before leaving. Next seen (result recorded) = defeat,
            ; Replay without Next = win, unless OCR reads the outcome here.
            if !gMatchReported {
                outcome := gEndResult="victory" || gEndResult="defeat"?gEndResult:ReadEndOutcome()
                if outcome="unknown"
                    outcome := gEndResult=""?"victory":"defeat"
                Log("Result: " StrUpper(outcome) " (reported at Replay).")
                ReportMatchResult(outcome="victory")
            }
            if ClickEndGameButton(screen) {
                gAwaitingReplayMap := true
                Log("Endgame: Replay selected once. Waiting for the next Vote Start; no lobby clicks.")
                return true
            }
        } else if gEndRewardsDone && A_TickCount-gEndRewardSweepAt>=5000 {
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

; Wait for Replay to clear, then for a confirmed Vote Start.
WaitForReplayVoteStart() {
    global gAwaitingReplayMap
    deadline := A_TickCount+180000
    Notify("Replay clicked: waiting for the Replay button to disappear.")
    if !WaitFor(() => !HasReplayButton(),180000,250) {
        Notify("The Replay button did not clear.")
        return false
    }
    Notify("Replay loading: waiting for the next Vote Start, on the same or a new map.")
    if !WaitForVoteStart(Max(1000,deadline-A_TickCount)) {
        Notify("Vote Start after Replay was not confirmed.")
        return false
    }
    gAwaitingReplayMap := false
    return true
}

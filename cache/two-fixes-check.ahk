#Requires AutoHotkey v2.0
#SingleInstance Off
global gRunning := true, CLICK_HOLD_MS := 180, MOUSE_SETTLE_MS := 350
global events := [], cancelHold := false, focused := true, voteVisible := true, closeVote := true, targets := [], waits := 0
try {
    Assert(ClickRef(355,102), "Placement click failed")
    Assert(events.Length=2 && events[1]="{LButton down}" && events[2]="{LButton up}", "Click was not an explicit left press/release")
    events := [], cancelHold := true
    Assert(!ClickRef(355,102), "Interrupted hold must fail")
    Assert(events.Length=2 && events[2]="{LButton up}", "Interrupted hold did not release left button")
    events := [], cancelHold := false, focused := false
    Assert(!ClickRef(355,102) && events.Length=0, "Click sent without game focus")
    focused := true, gRunning := false
    Assert(!ClickRef(355,102) && events.Length=0, "Click sent after stop")
    gRunning := true, targets := []
    Assert(TryVoteStart(), "Visible vote was not accepted")
    Assert(targets.Length=1 && targets[1]="355,102", "Vote did not use live button centre")
    Assert(waits=1 && !voteVisible, "Vote success was not confirmed")
    voteVisible := true, closeVote := false, targets := [], waits := 0, events := []
    Assert(!TryVoteStart(), "Unchanged vote dialog was reported as success")
    Assert(targets.Length=2 && waits=2 && events.Length=4, "Failed vote retry was not bounded to two left clicks")
    voteVisible := false, events := []
    Assert(!TryVoteStart() && events.Length=0, "Absent vote must not be clicked")
    FileAppend "PASS: explicit left press/release, cancellation release, focus/stop guards, live vote target, confirmation, bounded retry, absent vote.`n", "*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n", "*"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
ToScreen(rx,ry,&sx,&sy) {
    sx := rx, sy := ry
    return true
}
FindRoblox() => 1
WinActivate(*) => 0
WinWaitActive(*) {
    global focused
    return focused
}
SmoothMoveTo(sx,sy) {
    global targets
    targets.Push(sx "," sy)
    return true
}
ActionPause(ms) {
    global cancelHold
    return !(cancelHold && ms=180)
}
SendEvent(keys) {
    global events
    events.Push(keys)
}
Log(*) => 0
HasVoteStart() {
    global voteVisible
    return voteVisible
}
FindUiGreenCentre(x1,y1,x2,y2,&rx,&ry) {
    rx := 355, ry := 102
    return true
}
WaitFor(test,timeout) {
    global closeVote,voteVisible,waits
    waits += 1
    if closeVote
        voteVisible := false
    return test.Call()
}

ClickRef(rx, ry) {
    global CLICK_HOLD_MS, MOUSE_SETTLE_MS, gRunning
    if !gRunning
        return false
    if !ToScreen(rx, ry, &sx, &sy)
        return false
    hwnd := FindRoblox()
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2)
        return false
    if !SmoothMoveTo(sx,sy) || !ActionPause(MOUSE_SETTLE_MS)
        return false
    ; Explicit left-button events give Roblox a held press and release.
    SendEvent "{LButton down}"
    try {
        if !ActionPause(CLICK_HOLD_MS)
            return false
    } finally SendEvent "{LButton up}"
    Log("Left click at client " rx ", " ry)
    return true
}

TryVoteStart() {
    if !HasVoteStart()
        return false
    Loop 2 {
        ; Aim at the visible affirmative button, never a stale OCR/learned
        ; point. The paired green/red vote controls were checked above.
        if !FindUiGreenCentre(315,90,395,115,&rx,&ry)
            return false
        Log("Vote Start: left click visible start/Yes button at " rx ", " ry)
        if !ClickRef(rx,ry)
            return false
        if WaitFor(VoteStartClosed,1500)
            return true
    }
    Log("Vote Start remained visible after clicking; start not confirmed.")
    return false
}

VoteStartClosed() {
    return !HasVoteStart()
}

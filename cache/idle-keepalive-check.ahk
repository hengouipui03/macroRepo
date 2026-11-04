#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [{complete:true}],IDLE_KEEPALIVE_MS := 300000,gIdleKeepAliveAt := 0
global testNow := 10000,clicks := 0,cards := false,panel := false,defeat := false,replay := false,active := false,exists := true,lateCards := false,cancels := 0
ResetIdleKeepAlive() {
    global gIdleKeepAliveAt
    gIdleKeepAliveAt := 0
}

IdleKeepAliveAllowed() {
    global gRunning,gPlacements
    return gRunning && gPlacements.Length && !UpgradeQueue().Length
        && !HasCardChoice() && !HasUnitPanel() && !IsEndGameBlocking()
}

IdleKeepAliveTick() {
    global gRunning,gPlacements,gIdleKeepAliveAt,IDLE_KEEPALIVE_MS
    if !gRunning || !gPlacements.Length || UpgradeQueue().Length {
        ResetIdleKeepAlive()
        return false
    }
    if !gIdleKeepAliveAt {
        gIdleKeepAliveAt := testNow
        return false
    }
    if testNow-gIdleKeepAliveAt<IDLE_KEEPALIVE_MS || !IdleKeepAliveAllowed()
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    ; Focus Roblox before cancelling a preview, so Q cannot reach another app.
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    if !gRunning || !CancelUnitPreview()
        return false
    ; The existing click-away point is above/outside the card area. Recheck
    ; state after smooth movement so a newly opened dialog takes priority.
    if !ClickRef(740,150,IdleKeepAliveAllowed)
        return false
    gIdleKeepAliveAt := testNow
    Log("Idle keep-alive: clicked Roblox after five minutes without upgrades.")
    return true
}

try {
    Assert(!IdleKeepAliveTick(),"Keep-alive clicked immediately on idle entry")
    testNow += 299999
    Assert(!IdleKeepAliveTick() && clicks=0,"Clicked before five minutes")
    testNow += 1
    Assert(IdleKeepAliveTick() && clicks=1 && active,"First five-minute click missing or unfocused")
    testNow += 299999
    Assert(!IdleKeepAliveTick() && clicks=1,"Keep-alive repeated too early")
    testNow += 1
    Assert(IdleKeepAliveTick() && clicks=2,"Second five-minute click missing")
    testNow += 300000,cards := true
    Assert(!IdleKeepAliveTick() && clicks=2,"Keep-alive interfered with card choice")
    cards := false,panel := true
    Assert(!IdleKeepAliveTick() && clicks=2,"Keep-alive interfered with unit panel")
    panel := false,defeat := true
    Assert(!IdleKeepAliveTick() && clicks=2,"Keep-alive clicked on defeat screen")
    defeat := false,replay := true
    Assert(!IdleKeepAliveTick() && clicks=2,"Keep-alive clicked on replay screen")
    replay := false,exists := false
    Assert(!IdleKeepAliveTick() && clicks=2,"Keep-alive clicked without Roblox")
    exists := true,lateCards := true
    Assert(!IdleKeepAliveTick() && clicks=2,"Card appearing during cursor movement received a keep-alive")
    lateCards := false,cards := false
    gPlacements[1].complete := false
    Assert(!IdleKeepAliveTick() && !gIdleKeepAliveAt,"Pending upgrades did not reset idle period")
    gPlacements[1].complete := true
    Assert(!IdleKeepAliveTick(),"Reset idle period clicked immediately")
    testNow += 300000,gRunning := false
    Assert(!IdleKeepAliveTick() && clicks=2 && !gIdleKeepAliveAt,"F7/stopped macro allowed an idle click")
    gRunning := true,gPlacements := []
    Assert(!IdleKeepAliveTick() && clicks=2,"Keep-alive ran before a confirmed build")
    FileAppend "PASS: five-minute repeat; no early click; completed upgrades only; focus before Q; cards/panels/end screens/missing game guarded; late card and stop respected.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
UpgradeQueue() {
    global gPlacements
    queue := []
    for item in gPlacements
        if !item.complete
            queue.Push(item)
    return queue
}
HasCardChoice() {
    global cards
    return cards
}
HasUnitPanel() {
    global panel
    return panel
}
HasDefeatNext() {
    global defeat
    return defeat
}
HasReplayButton() {
    global replay
    return replay
}
FindRoblox() {
    global exists
    return exists?1:0
}
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
    global active,cancels
    Assert(active,"Q was sent before focusing Roblox")
    cancels += 1
    return true
}
ClickRef(x,y,stillValid) {
    global clicks,lateCards,cards
    Assert(x=740 && y=150,"Keep-alive clicked an unexpected point")
    if lateCards
        cards := true
    if !stillValid.Call()
        return false
    clicks += 1
    return true
}
Log(*) => 0

IsEndGameBlocking() {
    global defeat,replay
    return defeat || replay
}

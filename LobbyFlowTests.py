"""Lobby start and reconnect: every stage is bounded, a give-up restarts from
the Play stage and then ends the run; a Play click that worked is not repeated;
the Reconnect cap returns without disarming the session. Stubbed screen/input."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

lobby_logic = "\n".join(function("LobbyFlow.ahk", n) for n in ["TryStartFromLobby", "ReconnectAndRestart", "ReconnectGiveUp"])
lobby_logic += "\n" + function("MatchState.ahk", "InPhase")
lobby_constants = r"""
global LOBBY_PLAY_WAIT_MS := 30,LOBBY_PLAY_WAIT_AFTER_RETURN_MS := 60,LOBBY_PLAY_POLL_MS := 5,LOBBY_CLICK_SETTLE_MS := 1,LOBBY_PANEL_POLL_MS := 1
global LOBBY_PLAY_CLICK_LIMIT := 2,LOBBY_PLAY_CLICK_FAIL_LIMIT := 3,LOBBY_SAVED_PLAY_FALLBACK := true
global LOBBY_WALK_MS := 10,LOBBY_WALK_GRACE_MS := 5,LOBBY_WALK_ROUND_LIMIT := 3,LOBBY_QUEUE_RETRY_LIMIT := 4
global LOBBY_PORTAL_ATTEMPT_LIMIT := 3,LOBBY_PORTAL_RETRY_PAUSE_MS := 1,LOBBY_RESTART_LIMIT := 2
global RECONNECT_CLICK_CADENCE_MS := 50,RECONNECT_GIVE_UP_MS := 600
"""
common = r"""
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
""" + lobby_constants + r"""
global gRunning := true,gQueueMode := true,gPhase := "Idle",gReconnecting := false,gReconnectButton := false,gMacroThreadActive := false
global gSessionArmed := true
global logs := [],ends := [],calls := []
Assert(value,message) {
    if !value
        throw Error(message)
}
Log(text) {
    global logs
    logs.Push(text)
}
Notify(text) {
    Log(text)
}
Joined() {
    global logs
    text := ""
    for line in logs
        text .= line "`n"
    return text
}
CountIn(text,needle) {
    n := 0,pos := 1
    while pos := InStr(text,needle,true,pos) {
        n += 1
        pos += StrLen(needle)
    }
    return n
}
SetPhase(name) {
    global gPhase,calls
    gPhase := name
    calls.Push("phase:" name)
    return true
}
"""

queue_fixture = common + r"""
global playVisible := true,panelOnClick := 0,panelOnWalk := 0,clicks := 0,waits := 0,walks := 0,wDown := 0,wUp := 0
global clickOk := true,savedClicks := 0,savedOk := true,panelOpen := false,queueResult := 1234,queueCalls := 0
global portalOk := false,portalClicks := 0,queueRetries := 0
global findMatch := {x:1,y:1}
HasMatchmakingPanel() => panelOpen
ReadVisibleFindMatch() => panelOpen ? findMatch : false
ReadVisibleLobbyPlay() => playVisible ? {x:5,y:5} : false
LobbyPlayAt(x,y) => true
HasOpenPortal() => true
WaitFor(test,timeoutMs,pollMs := 80) {
    global gRunning,waits,panelOnWalk,walks,panelOpen
    waits += 1
    if timeoutMs=LOBBY_WALK_MS || timeoutMs=LOBBY_WALK_GRACE_MS {
        if timeoutMs=LOBBY_WALK_MS {
            walks += 1
            if panelOnWalk && walks>=panelOnWalk
                panelOpen := true
        }
        return gRunning && test.Call()
    }
    return gRunning && test.Call()
}
ClickRef(x,y,stillValid := 0) {
    global clicks,clickOk,panelOnClick,panelOpen
    if !clickOk
        return false
    clicks += 1
    if panelOnClick && clicks>=panelOnClick
        panelOpen := true
    return true
}
ActionPause(ms,interruptible := true) => gRunning
Send(keys) {
    global wDown,wUp
    if InStr(keys,"w down")
        wDown += 1
    else if InStr(keys,"w up")
        wUp += 1
}
ClickSavedLobbyPlay() {
    global savedClicks,savedOk
    savedClicks += 1
    return savedOk
}
StartQueueMatch(find) {
    global queueResult,queueCalls,queueRetries
    queueCalls += 1
    return queueCalls<=queueRetries ? "retry" : queueResult
}
ClickButton(name,delay := -1,confirm := 0) {
    global portalOk,portalClicks
    portalClicks += 1
    return portalOk
}
TryStartPortal() => true
EndRun(reason) {
    global ends,gPhase
    ends.Push(reason)
    gPhase := "Idle"
    Log("Run ended: " reason)
    return ""
}
Reset(queue := true) {
    global
    gRunning := true,gQueueMode := queue,gPhase := "Lobby",logs := [],ends := [],calls := []
    playVisible := true,panelOnClick := 0,panelOnWalk := 0,clicks := 0,waits := 0,walks := 0,wDown := 0,wUp := 0
    clickOk := true,savedClicks := 0,savedOk := true,panelOpen := false,queueResult := 1234,queueCalls := 0
    portalOk := false,portalClicks := 0,queueRetries := 0
}
try {
    ; Normal start: two verified Play clicks (the panel is closed), a walk, then the queue.
    Reset(),panelOnWalk := 1
    r := TryStartFromLobby()
    Assert(r=1234 && clicks=2 && walks=1 && wDown=1 && wUp=1 && !ends.Length,"normal queue start: r=" r " clicks=" clicks " walks=" walks)
    Assert(InStr(Joined(),"verified and clicked (1/2)") && InStr(Joined(),"verified and clicked (2/2)"),"click log")

    ; A Play click whose effect is visible (panel open) is not repeated and no walk follows.
    Reset(),panelOnClick := 1
    r := TryStartFromLobby()
    Assert(r=1234 && clicks=1 && walks=0 && wDown=0,"verified Play click was repeated or walked: clicks=" clicks " walks=" walks)

    ; The panel already open: no Play click at all.
    Reset(),panelOpen := true
    r := TryStartFromLobby()
    Assert(r=1234 && clicks=0 && waits=0,"open panel still clicked Play")

    ; Solo mode goes through the portal stage.
    Reset(false),panelOnClick := 1,portalOk := true
    Assert(TryStartFromLobby()=true && portalClicks=2 && queueCalls=0,"solo portal path")

    ; Stage "find Play" gives up (label never read): one wait per pass, LIMIT restarts, then EndRun.
    Reset(),playVisible := false
    Assert(TryStartFromLobby()=false && ends.Length=1,"find Play give-up did not end the run")
    Assert(waits=LOBBY_RESTART_LIMIT+1 && clicks=0 && savedClicks=0,"find Play passes: waits=" waits)
    Assert(SubStr(ends[1],1,19)="lobby: find Play (n" && InStr(ends[1],"2 restart(s)"),"find Play reason: " ends[1])
    Assert(CountIn(Joined(),"Lobby: stage 'find Play") = LOBBY_RESTART_LIMIT+1 && CountIn(Joined(),"restarting from the Play stage")=LOBBY_RESTART_LIMIT,"stage give-up log lines")
    Assert(InStr(Joined(),"restarting from the Play stage (2/2)"),"restart counter log")

    ; After a return to the lobby the saved position replaces each unread Play click (once per round), with a log line.
    Reset(),playVisible := false
    Assert(TryStartFromLobby(true)=false && ends.Length=1 && savedClicks=LOBBY_WALK_ROUND_LIMIT*(LOBBY_RESTART_LIMIT+1),"saved fallback clicks=" savedClicks)
    Assert(InStr(Joined(),"using the saved Play position (fallback)") && InStr(ends[1],"lobby: walk"),"fallback log/reason: " ends[1])
    ; ...and not at all when the constant is off, or when no position is saved.
    Reset(),playVisible := false,LOBBY_SAVED_PLAY_FALLBACK := false
    TryStartFromLobby(true)
    Assert(savedClicks=0 && InStr(ends[1],"lobby: find Play"),"fallback ran with the constant off")
    LOBBY_SAVED_PLAY_FALLBACK := true
    Reset(),playVisible := false,savedOk := false
    TryStartFromLobby(true)
    Assert(InStr(ends[1],"no saved position"),"missing saved position reason: " ends[1])

    ; Stage "click Play": the click can never be sent.
    Reset(),clickOk := false
    Assert(TryStartFromLobby()=false && InStr(ends[1],"lobby: click Play"),"click Play reason")
    Assert(CountIn(Joined(),"the Play click was not sent")=(LOBBY_PLAY_CLICK_FAIL_LIMIT-1)*(LOBBY_RESTART_LIMIT+1),"click-fail logs")

    ; Stage "walk": the panel never opens. LIMIT rounds per pass, W always released.
    Reset()
    Assert(TryStartFromLobby()=false && InStr(ends[1],"lobby: walk to the matchmaking panel"),"walk reason")
    Assert(walks=LOBBY_WALK_ROUND_LIMIT*(LOBBY_RESTART_LIMIT+1) && wDown=walks && wUp=wDown,"walk counts " walks "/" wDown "/" wUp)
    Assert(clicks=LOBBY_PLAY_CLICK_LIMIT*walks,"every walk round is preceded by the capped Play clicks: " clicks)

    ; Stage "queue": StartQueueMatch keeps asking for a retry.
    Reset(),panelOpen := true,queueRetries := 999
    Assert(TryStartFromLobby()=false && InStr(ends[1],"lobby: Find Match / queue prompt"),"queue reason")
    Assert(queueCalls=LOBBY_QUEUE_RETRY_LIMIT*(LOBBY_RESTART_LIMIT+1),"queue attempts " queueCalls)
    ; A queue retry that then succeeds.
    Reset(),panelOpen := true,queueResult := 777,queueRetries := 2
    Assert(TryStartFromLobby()=777 && !ends.Length && queueCalls=3,"retry then success")

    ; Stage "portal" (Solo): Play Here / Open never work.
    Reset(false),panelOpen := true
    Assert(TryStartFromLobby()=false && InStr(ends[1],"lobby: Play Here / Open portal"),"portal reason")
    Assert(portalClicks=LOBBY_PORTAL_ATTEMPT_LIMIT*(LOBBY_RESTART_LIMIT+1),"portal attempts " portalClicks)  ; PlayHere fails first, so one click per attempt

    ; Stopped (F7): returns false, no restart, no EndRun from here.
    Reset(),playVisible := false,gRunning := false
    Assert(TryStartFromLobby()=false && !ends.Length && !InStr(Joined(),"restarting"),"stopped run kept restarting")
    FileAppend "PASS: lobby stages are bounded; each give-up logs its stage, restarts from Play, then EndRun; a verified click is not repeated; fallback behind its constant.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`nLOG:`n" Joined() "`n","*","UTF-8"
    ExitApp 1
}
"""

reconnect_fixture = common + r"""
global BTN := {hwnd:1,box:[1,1,2,2],label:0,x:10,y:10}
global visible := true,dialog := true,lobbyPlay := false,clicks := 0,prepOk := true,prepCalls := 0,discord := [],restarted := 0
global lobbyAfterMs := 0,startedAt := 0
ReconnectButtonVisible(button) => visible
DialogGone() {
    global dialog,visible
    dialog := false,visible := false
}
ClientReady() {
    global prepOk
    prepOk := true
}
HasDisconnectPanel() => dialog
FindReconnectButton(&disconnected,keepReading := 0) {
    global dialog
    disconnected := dialog
    return dialog ? BTN : false
}
ReadVisibleLobbyPlay() {
    global lobbyPlay,lobbyAfterMs,startedAt
    return lobbyPlay || (lobbyAfterMs && A_TickCount-startedAt>=lobbyAfterMs)
}
ClickRef(x,y,stillValid := 0) {
    global clicks
    if stillValid && !stillValid.Call()
        return false
    clicks += 1
    return true
}
ActionPause(ms,interruptible := true) {
    global gRunning
    Sleep Min(ms,20)
    return gRunning
}
PrepareRunStart() {
    global prepOk,prepCalls,calls
    prepCalls += 1
    calls.Push("prepare")
    return prepOk
}
ResetMatchState() {
    global calls
    calls.Push("reset")
}
RunMacroSafely() {
    global restarted,calls
    restarted += 1
    calls.Push("run")
}
DiscordWarn(text) {
    global discord
    discord.Push(text)
}
try {
    ; Give-up: the dialog never goes away. One call returns after the cap, session armed.
    gReconnecting := true,gSessionArmed := true,gRunning := false
    t0 := A_TickCount
    ReconnectAndRestart()
    elapsed := A_TickCount-t0
    Assert(elapsed>=RECONNECT_GIVE_UP_MS && elapsed<RECONNECT_GIVE_UP_MS+1500,"gave up after " elapsed " ms")
    Assert(gSessionArmed && !gReconnecting && !gReconnectButton && !gRunning && gPhase="Idle","give-up state: armed=" gSessionArmed " reconnecting=" gReconnecting)
    Assert(discord.Length=1 && InStr(discord[1],"Reconnect did not reach the lobby"),"Discord notify")
    Assert(CountIn(Joined(),"Reconnect did not reach the lobby")=1,"give-up log line")
    ; Bounded cadence: clicks about elapsed/cadence, never a tight loop.
    Assert(clicks>=3 && clicks<=elapsed/RECONNECT_CLICK_CADENCE_MS+2,"clicks " clicks " in " elapsed " ms")
    Assert(restarted=0 && prepCalls=0,"restarted although the lobby never showed")
    ; CheckDisconnect can start a new attempt: gReconnecting is false and the timer logic only needs gSessionArmed.

    ; Success: the dialog goes, lobby Play shows. PrepareRunStart, then ResetMatchState, then Lobby phase, then the run.
    gReconnecting := true,gSessionArmed := true,logs := [],calls := [],discord := [],clicks := 0,prepCalls := 0,gRunning := false
    startedAt := A_TickCount,lobbyAfterMs := 150,dialog := true
    SetTimer(DialogGone,-120)
    ReconnectAndRestart()
    Sleep 80
    Assert(restarted=1 && !gReconnecting && gSessionArmed,"restart after reconnect")
    Assert(calls[1]="prepare" && calls[2]="reset" && calls[3]="phase:Lobby" && calls[4]="run","order: " calls[1] "," calls[2] "," calls[3] "," calls.Length)
    Assert(!discord.Length,"Discord notified on success")

    ; Roblox not ready at first: no reset, the loop goes on and succeeds on a later cadence tick.
    gReconnecting := true,calls := [],prepCalls := 0,restarted := 0,prepOk := false,dialog := false,lobbyPlay := true
    SetTimer(ClientReady,-120)
    ReconnectAndRestart()
    Sleep 80
    Assert(prepCalls>=2 && restarted=1 && calls[1]="prepare","retry when PrepareRunStart fails: " prepCalls)
    Assert(calls[2]!="reset" || prepCalls>=2,"reset before a prepared client")
    FileAppend "PASS: reconnect click cadence bounded; give-up logs and Discord-notifies, keeps the session armed and returns; restart goes through PrepareRunStart then ResetMatchState.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`nLOG:`n" Joined() "`n","*","UTF-8"
    ExitApp 1
}
"""

# WaitForQueuedMatch: bounded by QUEUE_WAIT_LIMIT_MS, with a logged escalation.
queue_wait_logic = function("QueueMatch.ahk", "WaitForQueuedMatch")
queue_wait_fixture = r"""
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,QUEUE_WAIT_LIMIT_MS := 300,QUEUE_WAIT_POLL_MS := 20,QUEUE_LOBBY_CHECK_MS := 10000,QUEUE_LOBBY_RETRY_WAIT_MS := 15000
global logs := [],voteAfter := 0,polls := 0
Notify(text) {
    global logs
    logs.Push(text)
}
HasVoteStart() {
    global voteAfter,polls
    return voteAfter && polls>=voteAfter
}
WaitForVoteStart(*) => true
HasLobbyPlay() => false
TryStartFromLobby(*) => false
ActionPause(ms,interruptible := true) {
    global polls
    polls += 1
    Sleep ms
    return gRunning
}
try {
    started := A_TickCount
    Assert(!WaitForQueuedMatch(0),"an endless queue wait returned true")
    Assert(A_TickCount-started<3000 && logs.Length=1 && InStr(logs[1],"did not reach Vote Start"),"the queue wait was not bounded or did not log its escalation")
    polls := 0,voteAfter := 3,logs := []
    Assert(WaitForQueuedMatch(0) && !logs.Length,"a Vote Start inside the bound was not returned")
    FileAppend "PASS: WaitForQueuedMatch is bounded by QUEUE_WAIT_LIMIT_MS and logs the hand-over to recovery.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
"""

if __name__ == "__main__":
    for name, fixture, logic_text in [("lobby-stages", queue_fixture, lobby_logic), ("reconnect", reconnect_fixture, lobby_logic), ("queue-wait", queue_wait_fixture, queue_wait_logic)]:
        target = ROOT / "cache" / f"{name}-regression.ahk"
        target.parent.mkdir(exist_ok=True)
        target.write_text(fixture + "\n" + logic_text, encoding="utf-8-sig")
        result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)],
                                capture_output=True, timeout=60)
        print(result.stdout.decode("utf-8-sig"), end="")
        print(result.stderr.decode("utf-8-sig"), end="")
        if result.returncode:
            raise SystemExit(result.returncode)

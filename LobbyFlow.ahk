; Lobby start and reconnect. Owns: finding and clicking lobby Play, walking to
; the matchmaking panel, the queue / portal hand-off, and the Reconnect loop.
; Every retry below has a named bound; a stage that runs out is logged by name
; and leads to one restart from the Play stage, then to EndRun.

; Stage "Play": wait for the labelled Play button, click it with verification.
global LOBBY_PLAY_WAIT_MS := 30000
global LOBBY_PLAY_WAIT_AFTER_RETURN_MS := 60000
global LOBBY_PLAY_POLL_MS := 500
global LOBBY_PLAY_CLICK_LIMIT := 2        ; verified Play clicks per round
global LOBBY_PLAY_CLICK_FAIL_LIMIT := 3   ; clicks that could not be sent per round
; The label OCR sometimes fails to read "Play". After a return to the lobby the
; saved LobbyPlay point is clicked once, unverified, when the label was not
; read in time. Set to false to turn the blind click off.
global LOBBY_SAVED_PLAY_FALLBACK := true
; Stage "walk": hold W until the matchmaking panel shows.
global LOBBY_WALK_MS := 7000
global LOBBY_WALK_GRACE_MS := 3000
global LOBBY_WALK_ROUND_LIMIT := 3        ; Play-click + walk rounds
; Stage "queue": Find Match, number prompt, Submit.
global LOBBY_QUEUE_RETRY_LIMIT := 4
; Stage "portal" (Solo mode): Play Here, Open, Start.
global LOBBY_PORTAL_ATTEMPT_LIMIT := 3
global LOBBY_PORTAL_RETRY_PAUSE_MS := 1000
; Every stage gives up into one restart from "play"; after this many restarts
; the run ends.
global LOBBY_RESTART_LIMIT := 3
; Reconnect: click the dialog's Reconnect at this cadence until lobby Play
; shows. One call gives up after the cap (the session stays armed and
; CheckDisconnect tries again on a later tick).
global RECONNECT_CLICK_CADENCE_MS := 1000
global RECONNECT_GIVE_UP_MS := 1800000

ReadVisibleLobbyPlay() {
    global REF_W,REF_H,gRunning
    if !gRunning || !HasLobbyPlay() || !(geometry := WindowGeometry())
        return false
    for row in ReadOcrRows(ButtonRegion("LobbyPlay")*) {
        if NormalizeWords(row.text)!="play"
            continue
        x := (row.x+row.w/2)*REF_W/geometry.cw
        y := (row.y+row.h/2)*REF_H/geometry.ch
        if LobbyPlayAt(x,y)
            return {x:x,y:y}
    }
    return false
}

LobbyPlayAt(x,y) {
    return CountRef(Max(0,x-20),Max(0,y-34),x+20,y+8,4,IsLobbyCyan)>8
}

; One loop with explicit stages: play -> walk -> panel -> (queue | portal).
; Returns the submit time (Queue mode), true (Solo mode) or false (stopped, or
; the run was ended here after the restart limit; EndRun has logged why).
TryStartFromLobby(afterReturnToLobby := false) {
    global gRunning,gQueueMode,LOBBY_PLAY_WAIT_MS,LOBBY_PLAY_WAIT_AFTER_RETURN_MS,LOBBY_PLAY_POLL_MS
    global LOBBY_PLAY_CLICK_LIMIT,LOBBY_PLAY_CLICK_FAIL_LIMIT,LOBBY_SAVED_PLAY_FALLBACK
    global LOBBY_WALK_MS,LOBBY_WALK_GRACE_MS,LOBBY_WALK_ROUND_LIMIT,LOBBY_QUEUE_RETRY_LIMIT
    global LOBBY_PORTAL_ATTEMPT_LIMIT,LOBBY_PORTAL_RETRY_PAUSE_MS,LOBBY_RESTART_LIMIT
    play := 0,findMatch := 0
    playWaitMs := afterReturnToLobby ? LOBBY_PLAY_WAIT_AFTER_RETURN_MS : LOBBY_PLAY_WAIT_MS
    panelReady := gQueueMode ? () => (findMatch := ReadVisibleFindMatch()) : HasMatchmakingPanel
    restarts := 0,stage := "play"
    playClicks := 0,playClickFails := 0,walkRounds := 0,queueTries := 0,portalTries := 0
    while gRunning {
        failed := ""
        switch stage {
        case "play":
            ; Queue mode: the panel may already be open.
            if gQueueMode && panelReady.Call() {
                stage := "panel"
                continue
            }
            if playClicks>=LOBBY_PLAY_CLICK_LIMIT {
                stage := "walk"
                continue
            }
            if !WaitFor(() => (play := ReadVisibleLobbyPlay()),playWaitMs,LOBBY_PLAY_POLL_MS) {
                if !gRunning
                    return false
                if afterReturnToLobby && LOBBY_SAVED_PLAY_FALLBACK {
                    Log("Lobby: Play was not read within " Round(playWaitMs/1000) " s; using the saved Play position (fallback).")
                    if ClickSavedLobbyPlay()
                        stage := panelReady.Call() ? "panel" : "walk"
                    else if gRunning
                        failed := "find Play (no saved position either)"
                } else
                    failed := "find Play (not read within " Round(playWaitMs/1000) " s)"
            } else if !ClickRef(play.x,play.y,() => LobbyPlayAt(play.x,play.y)) || !ActionPause(250) {
                if !gRunning
                    return false
                playClickFails += 1
                if playClickFails>=LOBBY_PLAY_CLICK_FAIL_LIMIT
                    failed := "click Play (" playClickFails " clicks not sent)"
                else
                    Log("Lobby: the Play click was not sent (" playClickFails "/" LOBBY_PLAY_CLICK_FAIL_LIMIT "); reading Play again.")
            } else {
                playClicks += 1
                Log("Lobby Play verified and clicked (" playClicks "/" LOBBY_PLAY_CLICK_LIMIT ").")
                ; A click that opened the panel is not repeated.
                stage := panelReady.Call() ? "panel" : (playClicks>=LOBBY_PLAY_CLICK_LIMIT ? "walk" : "play")
            }
        case "walk":
            walkRounds += 1
            Log("Play clicked. Hold W until the matchmaking panel appears, then release W.")
            Send "{w down}"
            try panelOpen := WaitFor(panelReady,LOBBY_WALK_MS,150)
            finally Send "{w up}"
            if !panelOpen && gRunning {
                Log("Matchmaking panel did not appear after " Round(LOBBY_WALK_MS/1000) " seconds of walking. Wait " Round(LOBBY_WALK_GRACE_MS/1000) " seconds before retrying Lobby Play.")
                panelOpen := WaitFor(panelReady,LOBBY_WALK_GRACE_MS,150)
            }
            if panelOpen && gRunning
                stage := "panel"
            else if gRunning && walkRounds>=LOBBY_WALK_ROUND_LIMIT
                failed := "walk to the matchmaking panel (" walkRounds " rounds)"
            else {
                playClicks := 0,playClickFails := 0
                stage := "play"
            }
        case "panel":
            if !gQueueMode {
                stage := "portal"
                continue
            }
            submittedAt := StartQueueMatch(findMatch)
            if submittedAt!="retry"
                return submittedAt
            queueTries += 1
            if queueTries>=LOBBY_QUEUE_RETRY_LIMIT
                failed := "Find Match / queue prompt (" queueTries " attempts)"
            else
                stage := "play"
        case "portal":
            portalTries += 1
            if ClickButton("PlayHere",-1,HasOpenPortal) && ClickButton("PortalOpen")
                return TryStartPortal()
            if !gRunning
                return false
            if portalTries>=LOBBY_PORTAL_ATTEMPT_LIMIT
                failed := "Play Here / Open portal (" portalTries " attempts)"
            else {
                Log("Lobby: Play Here / Open portal did not work (" portalTries "/" LOBBY_PORTAL_ATTEMPT_LIMIT "); trying again.")
                ActionPause(LOBBY_PORTAL_RETRY_PAUSE_MS)
            }
        }
        if failed=""
            continue
        Log("Lobby: stage '" failed "' gave up.")
        if restarts>=LOBBY_RESTART_LIMIT {
            EndRun("lobby: " failed " gave up after " restarts " restart(s) from the Play stage.")
            return false
        }
        restarts += 1
        Notify("Lobby: restarting from the Play stage (" restarts "/" LOBBY_RESTART_LIMIT ") after '" failed "' gave up.")
        stage := "play"
        playClicks := 0,playClickFails := 0,walkRounds := 0,queueTries := 0,portalTries := 0
    }
    return false
}

; Blind click on the saved LobbyPlay point (see LOBBY_SAVED_PLAY_FALLBACK).
ClickSavedLobbyPlay() {
    geometry := WindowGeometry()
    if !geometry || !(point := ReadButtonRecord("LobbyPlay",geometry)) {
        Notify("Lobby Play is still unverified and has no saved position for this window. Teach it with F10.")
        return false
    }
    Notify("Lobby Play was not detected in time. Clicking its saved position.")
    return ClickWindowOnce(point,geometry) && ActionPause(250)
}

; After a Disconnected dialog: click Reconnect (verified, at the cadence) until
; lobby Play shows, then restart the run from the lobby. One call is capped by
; RECONNECT_GIVE_UP_MS: it then logs, notifies Discord and returns with the
; session still armed, so CheckDisconnect picks the dialog up again later.
ReconnectAndRestart() {
    global gRunning,gReconnecting,gReconnectButton,gMacroThreadActive
    global RECONNECT_CLICK_CADENCE_MS,RECONNECT_GIVE_UP_MS
    if !gReconnecting
        return
    ; The interrupted run must finish unwinding before anything is clicked.
    if gMacroThreadActive {
        SetTimer ReconnectAndRestart, -300
        return
    }
    gRunning := true,button := gReconnectButton,gReconnectButton := false
    startedAt := A_TickCount,nextCheck := 0,clicks := 0
    readyToClick := () => ReconnectButtonVisible(button) && (nextCheck := A_TickCount+RECONNECT_CLICK_CADENCE_MS)
    while gRunning && gReconnecting {
        if A_TickCount-startedAt>=RECONNECT_GIVE_UP_MS {
            ReconnectGiveUp(clicks)
            return
        }
        if A_TickCount<nextCheck {
            ActionPause(nextCheck-A_TickCount,false)
            continue
        }
        nextCheck := A_TickCount+RECONNECT_CLICK_CADENCE_MS
        disconnected := false
        if !button || !ReconnectButtonVisible(button)
            button := HasDisconnectPanel() ? FindReconnectButton(&disconnected) : false
        if !gRunning || !gReconnecting
            return
        ; A disconnect over the lobby can leave Play visible behind the dialog.
        if button {
            if ClickRef(button.x,button.y,readyToClick) {
                clicks += 1
                Log("Reconnect click " clicks " sent. Waiting for the lobby.")
            }
        } else if !disconnected && ReadVisibleLobbyPlay() && gRunning && gReconnecting {
            ; The restart takes the same steps as F6 (Roblox sized, attached,
            ; focused). If Roblox is not ready yet, keep waiting in this loop.
            if !PrepareRunStart()
                continue
            gReconnecting := false
            ResetMatchState()
            SetPhase("Lobby")
            Notify("Reconnected: back in the lobby after " clicks " Reconnect click(s). Restarting from Play.")
            SetTimer RunMacroSafely, -10
            return
        }
    }
}

; The Reconnect cap was reached. The session stays armed (gSessionArmed is not
; touched): gReconnecting is cleared so CheckDisconnect can start a new
; attempt on its next tick if the dialog is still there.
ReconnectGiveUp(clicks) {
    global gRunning,gReconnecting,gReconnectButton,RECONNECT_GIVE_UP_MS
    minutes := Round(RECONNECT_GIVE_UP_MS/60000)
    text := "Reconnect did not reach the lobby after " minutes " minutes and " clicks " click(s). The session stays armed; trying again on the next disconnect check."
    Notify(text)
    DiscordWarn(text)
    gReconnecting := false,gReconnectButton := false,gRunning := false
    SetPhase("Idle")
}

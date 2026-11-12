; The one owner of the match phase and of the per-match reset.
; Phases: Idle (no run), Lobby (waiting at / clicking lobby Play), Preparing
; (Vote Start, minimap, walk to the spot, P), Placing (ordered placement),
; Upgrading (F manager open while upgrades remain), Watching (every upgrade
; target reached, F closed, watching for the end screen), Ended (endgame screens).
; Modules never keep their own copy of the phase: they ask InPhase().
global gPhase := "Idle"
global MATCH_PHASES := ["Idle","Lobby","Preparing","Placing","Upgrading","Watching","Ended"]

; Moves to a named phase and logs the change. An unknown name is rejected and
; the phase stays as it was.
SetPhase(phase) {
    global gPhase,MATCH_PHASES
    valid := false
    for name in MATCH_PHASES {
        if name==phase {
            valid := true
            break
        }
    }
    if !valid {
        Log("Phase: unknown phase '" phase "' rejected; staying in " gPhase ".")
        return false
    }
    if gPhase==phase
        return true
    Log("Phase: " gPhase " -> " phase)
    gPhase := phase
    return true
}

; True when the current phase is any of the given names.
InPhase(phases*) {
    global gPhase
    for name in phases {
        if gPhase==name
            return true
    }
    return false
}

; Every exit from the run loop goes through here: it logs why the run ended,
; puts the phase back to Idle and returns "" (the "stop" result of RunMacro).
EndRun(reason) {
    Log("Run ended: " reason)
    SetPhase("Idle")
    return ""
}

; A RunMacro sub-result: "replay"/"restart"/"vote" pass through, an empty
; result (stopped, gave up) ends the run with the given reason.
ResultOrEndRun(outcome,reason) {
    return outcome!=""?outcome:EndRun(reason)
}

; The ONLY per-match reset. Each module resets its own state; nothing else
; clears match state by hand. Called at Vote Start and when the run returns to
; the lobby.
ResetMatchState() {
    ResetPlacementSearch()
    ResetPlacedUnits()
    ResetCardSelection()
    ResetMatchCardContext()
    ResetEndGameFlow()
    ResetUnitManagerState()
    ResetBuildAudit()
}

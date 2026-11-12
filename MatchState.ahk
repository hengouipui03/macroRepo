; The one owner of the match phase and of the per-match reset.
; Phases: Idle (no run), Lobby (waiting at / clicking lobby Play), Preparing
; (Vote Start, minimap, walk to the spot, P), Placing (ordered placement),
; Upgrading (F manager and upgrades), Ended (endgame screens).
; Modules never keep their own copy of the phase: they ask InPhase().
global gPhase := "Idle"
global MATCH_PHASES := ["Idle","Lobby","Preparing","Placing","Upgrading","Ended"]

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
}

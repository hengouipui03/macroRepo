; Select recorded purchase #N from the F manager's two-column row order.
; F is pressed ONLY after every configured unit has been placed. From then on
; the manager stays open for the rest of the match. The ONLY time it is closed
; is while a card is being chosen; it is reopened right after and the
; top-priority unit is reselected. Unit switches, finished targets and
; click-aways never close it.
; F is re-sent only when vision has confirmed several times in a row that the
; manager really is closed, so a misread can never toggle it shut.
global gUnitManagerOpen := false
global gUnitManagerConfirmed := false
global gUnitManagerPhase := false,gUnitManagerLastF := 0,gUnitManagerCheckAt := 0
global gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0,gUnitManagerFailure := ""
global UNIT_MANAGER_F_COOLDOWN_MS := 2500,UNIT_MANAGER_CHECK_MS := 3000
global gUnitManagerClosedForCards := false

BeginUnitManagerPhase() {
    global gUnitManagerPhase,gUnitManagerLastF,gUnitManagerCheckAt,gUnitManagerUnconfirmedF,gUnitManagerLockUntil
    gUnitManagerPhase := true,gUnitManagerLastF := 0,gUnitManagerCheckAt := 0
    gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0
    Log("All units placed. The F unit manager opens now and stays open until the match ends.")
}

EndUnitManagerPhase() {
    global gUnitManagerPhase,gUnitManagerOpen,gUnitManagerConfirmed,gUnitManagerLastF,gUnitManagerCheckAt
    global gUnitManagerUnconfirmedF,gUnitManagerLockUntil,gUnitManagerFailure,gUnitManagerClosedForCards
    gUnitManagerPhase := false,gUnitManagerOpen := false,gUnitManagerConfirmed := false,gUnitManagerClosedForCards := false
    gUnitManagerLastF := 0,gUnitManagerCheckAt := 0,gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0
    gUnitManagerFailure := ""
}

ReadUnitManager() {
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    state := VisionRequest("unitmanager " cx " " cy " " cw " " ch)
    return VisionOk(state)?state:false
}

FocusUnitManagerGame() {
    hwnd := FindRoblox()
    if !hwnd
        return false
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    return true
}

PressUnitManagerKey() {
    global UNIT_ACTION_MS,gRunning,gUnitManagerPhase,gUnitManagerLastF
    ; Hard rule: no F before the whole build is placed.
    if !gRunning || !gUnitManagerPhase || !FocusUnitManagerGame() || !BeginInputAction(true,UNIT_ACTION_MS)
        return false
    gUnitManagerLastF := A_TickCount
    SendEvent "{f down}"
    try return ActionPause(UNIT_ACTION_MS,false)
    finally {
        SendEvent "{f up}"
        EndInputAction()
    }
}

UnitManagerBlocked() {
    return HasCardChoice() || IsEndGameBlocking()
}

; Returns a ready manager state, opening it with ONE F press only when it has
; been read as closed three times in a row. Unreadable frames never count as
; closed, F is never repeated while a previous press may still be animating,
; and two presses that never produced an "open" reading stop F for 20 seconds.
EnsureUnitManagerOpen() {
    global gUnitManagerOpen,gUnitManagerConfirmed,gUnitManagerPhase,gUnitManagerLastF,gRunning
    global gUnitManagerUnconfirmedF,gUnitManagerLockUntil,UNIT_MANAGER_F_COOLDOWN_MS
    if !gRunning || !gUnitManagerPhase
        return false
    closedReads := 0
    Loop 14 {
        if !gRunning || UnitManagerBlocked()
            return false
        state := ReadUnitManager()
        if state && state["open"]="1" {
            gUnitManagerOpen := true,gUnitManagerConfirmed := true,gUnitManagerUnconfirmedF := 0
            if !state.Has("ready") || state["ready"]="1"
                return state
            closedReads := 0
        } else if state
            closedReads += 1
        else
            closedReads := 0
        if closedReads>=3 && A_TickCount>=gUnitManagerLockUntil
            && (!gUnitManagerLastF || A_TickCount-gUnitManagerLastF>=UNIT_MANAGER_F_COOLDOWN_MS) {
            if gUnitManagerUnconfirmedF>=2 {
                gUnitManagerLockUntil := A_TickCount+20000,gUnitManagerUnconfirmedF := 0
                Log("Two F presses were never confirmed as an open unit manager; no F for 20 seconds.")
                return false
            }
            Log("Unit manager confirmed closed; press F once to open it.")
            if !PressUnitManagerKey()
                return false
            gUnitManagerUnconfirmedF += 1
            gUnitManagerOpen := true,gUnitManagerConfirmed := false,closedReads := 0
        }
        if !ActionPause(150)
            return false
    }
    return false
}

; Watch-loop keep-alive for the manager: it must stay open all match.
MaintainUnitManager() {
    global gUnitManagerPhase,gUnitManagerCheckAt,gRunning,UNIT_MANAGER_CHECK_MS
    if !gRunning || !gUnitManagerPhase || A_TickCount<gUnitManagerCheckAt || UnitManagerBlocked()
        return false
    gUnitManagerCheckAt := A_TickCount+UNIT_MANAGER_CHECK_MS
    state := ReadUnitManager()
    if !state || state["open"]="1"
        return false
    Log("Unit manager is no longer visible; reopening it.")
    return EnsureUnitManagerOpen()?true:false
}

; Card choice is the only time the manager is closed. The open manager covers
; the right-hand card, so cards are read only after two readings in a row
; confirm it is closed. F is sent only when two readings agree it is open
; (at most two presses); mixed or unreadable readings never send F.
CloseUnitManagerForCards() {
    global gUnitManagerPhase,gUnitManagerClosedForCards,gRunning
    if !gRunning || !gUnitManagerPhase
        return gRunning
    ; Marked even if nothing is pressed, so the unit is always reselected.
    gUnitManagerClosedForCards := true
    Loop 2 {
        open := 0,closed := 0
        Loop 2 {
            state := ReadUnitManager()
            if state && state["open"]="1"
                open += 1
            else if state
                closed += 1
            if A_Index=1 && !ActionPause(80,false)
                return false
        }
        if closed=2
            return true
        if open<2 {
            Log("Unit manager state unclear during cards; no F sent.")
            return gRunning
        }
        Log("Card choice: press F to close the unit manager before reading the cards.")
        if !PressUnitManagerKey()
            return gRunning
        Loop 8 {
            if !ActionPause(150,false)
                return false
            state := ReadUnitManager()
            if !state || state["open"]!="0" || !ActionPause(100,false)
                continue
            again := ReadUnitManager()
            if again && again["open"]="0" {
                Log("Unit manager closed; reading the cards.")
                return true
            }
        }
    }
    Log("Unit manager still looks open after two F presses; reading the cards anyway (right card may be hidden).")
    return gRunning
}

; After the card screen is gone: reopen the manager (guarded F) and drop the
; current selection so the next upgrade reselects the correct top-priority
; unit through the manager before any R is pressed.
ReopenUnitManagerAfterCards() {
    global gUnitManagerPhase,gUnitManagerClosedForCards,gRunning
    if !gUnitManagerClosedForCards
        return true
    gUnitManagerClosedForCards := false
    if !gRunning || !gUnitManagerPhase
        return true
    ResetUpgradeSelection()
    Log("Cards closed: reopen the unit manager and reselect the top-priority unit.")
    return EnsureUnitManagerOpen()?true:false
}

UnitManagerFail(reason) {
    global gUnitManagerFailure
    gUnitManagerFailure := reason
    return false
}

ScrollUnitManager(direction,notches := 1) {
    global UNIT_ACTION_MS
    if !FocusUnitManagerGame() || !GetClient(&cx,&cy,&cw,&ch) || !SmoothMoveTo(cx+Round(cw*.91),cy+Round(ch*.42),UNIT_ACTION_MS,UNIT_ACTION_MS)
        return false
    if !BeginInputAction(true,UNIT_ACTION_MS)
        return false
    SendEvent "{Wheel" direction " " notches "}"
    EndInputAction()
    return ActionPause(200)
}

ResetUnitManagerBottom(state) {
    global gPlacements
    ; Overscroll downward is safe. Confirm with single-notch observations after it.
    if !ScrollUnitManager("Down",Max(6,Ceil(gPlacements.Length/2)*6+6))
        return false
    previous := ReadUnitManager(),stable := 0
    Loop 8 {
        if !previous || previous["open"]!="1" || !previous.Has("last") || !ScrollUnitManager("Down",1)
            return false
        current := ReadUnitManager()
        if !current || current["open"]!="1" || !current.Has("last")
            return false
        ; Portrait animations do not indicate that the list itself moved.
        if Abs(Number(current["last"])-Number(previous["last"]))<2
            stable += 1
        else
            stable := 0
        if stable>=2
            return current
        previous := current
    }
    Log("Unit manager bottom could not be confirmed; no portrait clicked.")
    return false
}

UnitManagerEntry(state,column,rowY) {
    pitch := Number(state["pitch"])
    for text in StrSplit(state["entries"],";") {
        parts := StrSplit(text,",")
        if parts.Length=4 && Integer(parts[1])=column && Abs(Number(parts[4])-rowY)<pitch*.22
            return {x:Number(parts[2]),y:Number(parts[3])}
    }
    return false
}

SelectManagedUnit(purchaseId) {
    global gPlacements,REF_W,REF_H,gRunning,gPendingPlacement,gUnitManagerFailure
    gUnitManagerFailure := ""
    if !gRunning || gPendingPlacement || purchaseId<1 || purchaseId>gPlacements.Length
        return UnitManagerFail("blocked")
    if HasCardChoice()
        return UnitManagerFail("card")
    ; The previous unit's panel is closed with the manager-safe click-away;
    ; the manager itself is left open.
    if !CloseUnitPanel() || !CancelUnitPreview()
        return UnitManagerFail(HasCardChoice()?"card":"panel")
    state := EnsureUnitManagerOpen()
    if !state
        return UnitManagerFail(HasCardChoice()?"card":"manager")
    if !(state := ResetUnitManagerBottom(state))
        return UnitManagerFail(HasCardChoice()?"card":"scroll")
    row := (purchaseId-1)//2,column := 1-Mod(purchaseId-1,2)
    pitch := Number(state["pitch"]),last := Number(state["last"]),offset := 0
    limit := Ceil(gPlacements.Length/2)*8+10
    Loop limit {
        if !gRunning
            return UnitManagerFail("blocked")
        if HasCardChoice()
            return UnitManagerFail("card")
        wanted := last-row*pitch+offset
        entry := UnitManagerEntry(state,column,wanted)
        if entry {
            if !GetClient(&cx,&cy,&cw,&ch)
                return UnitManagerFail("manager")
            Log("Select purchase #" purchaseId " in unit manager | row from bottom " (row+1) " | " (column?"right":"left"))
            if PlacementClickRef(entry.x*REF_W/cw,entry.y*REF_H/ch,true,0,true) && WaitForUnitPanel(600,true)
                return true
            return UnitManagerFail(HasCardChoice()?"card":"panel")
        }
        oldLast := Number(state["last"])
        if !ScrollUnitManager("Up",1)
            return UnitManagerFail(HasCardChoice()?"card":"scroll")
        next := ReadUnitManager()
        if !next || next["open"]!="1" || !next.Has("last")
            return UnitManagerFail(HasCardChoice()?"card":"manager")
        delta := Mod(Number(next["last"])-oldLast+pitch*4,pitch)
        ; One notch must move less than one row; never guess after a large jump.
        if delta<1 || delta>pitch*.75 {
            Log("Unit manager scroll did not yield a reliable next row; no portrait clicked.")
            return UnitManagerFail("scroll")
        }
        offset += delta,state := next
    }
    return UnitManagerFail("scroll")
}

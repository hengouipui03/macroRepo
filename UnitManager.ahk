; Select recorded purchase #N from the F manager's two-column row order.
; F is pressed to OPEN the manager only after every configured unit has been
; placed. It then stays open while upgrades remain. It is closed while a card
; is chosen (reopened right after, top-priority unit reselected) and once
; every upgrade target is reached. A manager left open from the last match is
; closed before placement. Unit switches and click-aways never close it.
; F is re-sent only when vision has confirmed several times in a row that the
; manager really is closed, so a misread can never toggle it shut.
global gUnitManagerOpen := false
global gUnitManagerConfirmed := false
global gUnitManagerPhase := false,gUnitManagerLastF := 0,gUnitManagerCheckAt := 0
global gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0,gUnitManagerFailure := ""
global UNIT_MANAGER_F_COOLDOWN_MS := 2500,UNIT_MANAGER_CHECK_MS := 3000
global gUnitManagerClosedForCards := false
; The last tile found for a purchase, valid only while the list has not moved.
global gManagerTile := 0,gSlotPortraits := Map()

BeginUnitManagerPhase(message := "All units placed. The F unit manager opens now and stays open while upgrades remain.") {
    global gUnitManagerPhase,gUnitManagerLastF,gUnitManagerCheckAt,gUnitManagerUnconfirmedF,gUnitManagerLockUntil
    gUnitManagerPhase := true,gUnitManagerLastF := 0,gUnitManagerCheckAt := 0
    gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0
    ResetManagerTileMemory()
    Log(message)
}

EndUnitManagerPhase() {
    global gUnitManagerPhase,gUnitManagerOpen,gUnitManagerConfirmed,gUnitManagerLastF,gUnitManagerCheckAt
    global gUnitManagerUnconfirmedF,gUnitManagerLockUntil,gUnitManagerFailure,gUnitManagerClosedForCards
    gUnitManagerPhase := false,gUnitManagerOpen := false,gUnitManagerConfirmed := false,gUnitManagerClosedForCards := false
    gUnitManagerLastF := 0,gUnitManagerCheckAt := 0,gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0
    gUnitManagerFailure := ""
    ResetManagerTileMemory()
}

ResetManagerTileMemory() {
    global gManagerTile,gSlotPortraits
    gManagerTile := 0,gSlotPortraits := Map()
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

PressUnitManagerKey(closing := false) {
    global UNIT_ACTION_MS,gRunning,gUnitManagerPhase,gUnitManagerLastF
    ; Hard rule: no F to open the manager before the whole build is placed.
    ; Closing (after two readings confirm it is open) is allowed any time.
    if !gRunning || (!gUnitManagerPhase && !closing) || !FocusUnitManagerGame() || !BeginInputAction(true,UNIT_ACTION_MS)
        return false
    gUnitManagerLastF := A_TickCount
    ForgetManagerTile()
    SendEvent "{f down}"
    try return ActionPause(UNIT_ACTION_MS,false)
    finally {
        SendEvent "{f up}"
        EndInputAction()
    }
}

UnitManagerBlocked(fresh := false) {
    if fresh
        ReadEndScreen(true)
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
            ; The end screen's XP panel covers the manager and reads as
            ; "closed" (F then opened the manager over the defeat screen):
            ; look again for the end screen and cards before any F.
            if !ActionPause(300) || UnitManagerBlocked(true)
                return false
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

; One F to close the manager, sent only when two readings in a row confirm it
; is open: a closed or unreadable manager is never toggled. Used for a manager
; left open from the last match and once every upgrade target is reached.
CloseUnitManagerIfOpen(why) {
    global gRunning
    Loop 2 {
        state := ReadUnitManager()
        if !gRunning || !state || state["open"]!="1"
            return gRunning
        if A_Index=1 && !ActionPause(100,false)
            return false
    }
    Log(why)
    if !PressUnitManagerKey(true)
        return false
    Loop 10 {
        if !ActionPause(150,false)
            return false
        state := ReadUnitManager()
        if state && state["open"]="0"
            return true
    }
    Log("Unit manager still looks open after one F; leaving it.")
    return false
}

UnitManagerFail(reason) {
    global gUnitManagerFailure
    gUnitManagerFailure := reason
    return false
}

ForgetManagerTile() {
    global gManagerTile
    gManagerTile := 0
}

ScrollUnitManager(direction,notches := 1) {
    global UNIT_ACTION_MS
    ; Any scroll may move every tile, so the remembered position is dropped.
    ForgetManagerTile()
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
        ; Cards or the end screen stop the scrolling at once.
        if !gRunning || UnitManagerBlocked()
            return false
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

ParseUnitManagerEntry(text) {
    parts := StrSplit(text,",")
    if parts.Length<4
        return false
    entry := {column:Integer(parts[1]),x:Number(parts[2]),y:Number(parts[3]),row:Number(parts[4]),
        filled:-1,total:-1,maxed:false,ux:0,uy:0,sig:"",afford:-1}
    if parts.Length>=10 {
        entry.filled := Integer(parts[5]),entry.total := Integer(parts[6]),entry.maxed := parts[7]="1"
        entry.ux := Number(parts[8]),entry.uy := Number(parts[9]),entry.sig := parts[10]="-"?"":parts[10]
    }
    ; 1 = Upg button lit (can buy now), 0 = dimmed (not enough Yen), -1 = unknown.
    if parts.Length>=11
        entry.afford := Integer(parts[11])
    return entry
}

UnitManagerEntry(state,column,rowY) {
    pitch := Number(state["pitch"])
    for text in StrSplit(state["entries"],";") {
        entry := ParseUnitManagerEntry(text)
        if entry && entry.column=column && Abs(entry.row-rowY)<pitch*.22
            return entry
    }
    return false
}

; The manager lists the NEWEST unit top-left and reads left to right, top to
; bottom, so #1 is in the bottom row. With an even unit count the bottom row
; is #1 right, #2 left. With an odd count #1 is ALONE on the left and every
; row above it holds the next even purchase on the right, odd on the left.
; Rows count up from the bottom (0 = bottom row); column 1 is right.
ManagedUnitCell(purchaseId,bottomCount) {
    if bottomCount=2
        return {row:(purchaseId-1)//2,column:Mod(purchaseId,2)}
    if purchaseId=1
        return {row:0,column:0}
    return {row:purchaseId//2,column:Mod(purchaseId,2)=0?1:0}
}

; Finds purchase #N's tile: the remembered position while the list has not
; moved, otherwise anchored at the list bottom and scrolled up a notch at a
; time. Returns {state,entry} or false with gUnitManagerFailure set.
LocateManagedUnit(purchaseId) {
    global gPlacements,gRunning,gPendingPlacement,gUnitManagerFailure,gManagerTile
    gUnitManagerFailure := ""
    if !gRunning || gPendingPlacement || purchaseId<1 || purchaseId>gPlacements.Length
        return UnitManagerFail("blocked")
    if HasCardChoice()
        return UnitManagerFail("card")
    state := EnsureUnitManagerOpen()
    if !state
        return UnitManagerFail(HasCardChoice()?"card":"manager")
    if gManagerTile && gManagerTile.id=purchaseId {
        if entry := UnitManagerEntry(state,gManagerTile.column,gManagerTile.row)
            return {state:state,entry:entry}
        ForgetManagerTile()
    }
    if !(state := ResetUnitManagerBottom(state))
        return UnitManagerFail(HasCardChoice()?"card":"scroll")
    ; Odd or even comes from the recorded build, not from one screen read.
    ; The bottom row must agree before any tile is used: if it does not, the
    ; list is not really at its bottom (or #1's tile was missed), so retry.
    bottomCount := Mod(gPlacements.Length,2)?1:2
    seen := state.Has("lastcount")?Integer(state["lastcount"]):0
    if seen!=bottomCount {
        Log("Unit manager bottom row shows " seen " tile(s) but " gPlacements.Length " units are recorded; no tile used.")
        return UnitManagerFail("scroll")
    }
    cell := ManagedUnitCell(purchaseId,bottomCount)
    pitch := Number(state["pitch"]),last := Number(state["last"]),offset := 0
    limit := Ceil(gPlacements.Length/2)*8+10
    Loop limit {
        if !gRunning
            return UnitManagerFail("blocked")
        if HasCardChoice()
            return UnitManagerFail("card")
        if IsEndGameBlocking()
            return UnitManagerFail("blocked")
        if entry := UnitManagerEntry(state,cell.column,last-cell.row*pitch+offset) {
            Log("Purchase #" purchaseId " in unit manager | row from bottom " (cell.row+1) " | " (cell.column?"right":"left") " | " (bottomCount=1?"odd":"even") " unit count")
            gManagerTile := {id:purchaseId,column:cell.column,row:entry.row}
            return {state:state,entry:entry}
        }
        oldLast := Number(state["last"])
        if !ScrollUnitManager("Up",1)
            return UnitManagerFail(HasCardChoice()?"card":"scroll")
        next := ReadUnitManager()
        if !next || next["open"]!="1" || !next.Has("last")
            return UnitManagerFail(HasCardChoice()?"card":"manager")
        delta := Mod(Number(next["last"])-oldLast+pitch*4,pitch)
        if delta<1 {
            Log("Reached the top of the unit manager without purchase #" purchaseId "; the manager shows fewer units than recorded. No tile clicked.")
            return UnitManagerFail("missing")
        }
        ; One notch must move less than one row; never guess after a large jump.
        if delta>pitch*.75 {
            Log("Unit manager scroll did not yield a reliable next row; no tile clicked.")
            return UnitManagerFail("scroll")
        }
        offset += delta,state := next
    }
    return UnitManagerFail("scroll")
}

ClickManagerPoint(x,y) {
    global REF_W,REF_H
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    return PlacementClickRef(x*REF_W/cw,y*REF_H/ch,true,0,true)
}

; Portrait click: opens purchase #N's side panel (relocation checks, and
; upgrades when the Upg button needs the unit selected first).
SelectManagedUnit(purchaseId) {
    global gUnitManagerFailure,gRunning,gPendingPlacement,gPlacements
    gUnitManagerFailure := ""
    ; Checked before any click-away, so a pending purchase's panel is kept.
    if !gRunning || gPendingPlacement || purchaseId<1 || purchaseId>gPlacements.Length
        return UnitManagerFail("blocked")
    if HasCardChoice()
        return UnitManagerFail("card")
    if !CloseUnitPanel() || !CancelUnitPreview()
        return UnitManagerFail(HasCardChoice()?"card":"panel")
    if !(found := LocateManagedUnit(purchaseId))
        return false
    if ClickManagerPoint(found.entry.x,found.entry.y) && WaitForUnitPanel(600,true)
        return true
    return UnitManagerFail(HasCardChoice()?"card":"panel")
}

; The unit panel is the primary proof of a purchase. When it never showed, the
; F manager is the fallback: one more unit than recorded flips the parity of
; its bottom row. F is opened for this check only and closed again.
ManagerHoldsUnrecordedUnit() {
    global gPlacements,gRunning,gUnitManagerPhase
    if !gRunning || gUnitManagerPhase || HasCardChoice() || IsEndGameBlocking()
        return false
    BeginUnitManagerPhase("The unit panel was not seen after the purchase; checking the F manager for the unit.")
    found := false
    try {
        if (state := EnsureUnitManagerOpen()) && (state := ResetUnitManagerBottom(state)) {
            seen := state.Has("lastcount")?Integer(state["lastcount"]):0
            found := seen && seen!=(Mod(gPlacements.Length,2)?1:2)
        }
    } finally {
        CloseUnitManagerIfOpen("Unit manager check done; press F once to close it.")
        EndUnitManagerPhase()
    }
    return found
}

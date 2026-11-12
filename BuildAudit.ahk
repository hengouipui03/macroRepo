; Build audit: the recorded placements (gPlacements) against what the game
; itself says. Holding a unit shows "n/max" above its hotbar slot (see
; PurchaseVerifier.ahk), and n is the number of that unit on the field. The
; macro's record can be wrong in both directions:
;   recorded > n  ghost entries (a purchase that never happened): the slot's
;                 NEWEST entries are removed down to n, the order of the rest
;                 is kept and the purchase numbers are renumbered, because
;                 the unit manager's tiles are in purchase order
;   recorded < n  a purchase the macro missed: it is recorded as placed with
;                 no anchor position (so the build does not buy it again and
;                 no position-based code uses it), at the end of the list
; The audit runs when placement believes the build is complete, and again
; when the unit manager keeps disagreeing with the record (see
; RepairBuildAfterManagerMismatch). Every retry here has a named bound.

; Reads of one slot's counter per audit; still unreadable: trust the record.
global AUDIT_COUNTER_ATTEMPTS := 3
; Audits at build completion per match. An audit that finds the build
; incomplete sends placement back to work, so this stops a loop of
; place, audit, place when the two keep disagreeing.
global BUILD_AUDIT_LIMIT := 4
; Audits started because the unit manager and the record disagree, per match.
global AUDIT_LIMIT_PER_MATCH := 2
; Unit manager lookups for one purchase that may fail ("bottom row does not
; match", "reached the top without it", portrait mismatch, scroll trouble)
; per audit cycle, before the audit is requested.
global MANAGER_LOOKUP_LIMIT := 6
; Consecutive lookups that failed only because F would not open (no card,
; no other reason) before upgrades pause for the cooldown below. The match is
; never given up: after the cooldown the same bounded attempts start again,
; and this repeats for as long as the phase is Upgrading.
global MANAGER_OPEN_FAIL_LIMIT := 30
global UNIT_MANAGER_GIVEUP_COOLDOWN_MS := 30000
global gManagerCooldownUntil := 0

global gLookupMisses := Map(),gOpenFailures := 0
global gEscalationAudits := 0,gCompletionAudits := 0,gAuditDue := false
; Slot -> the most units the game lets this slot hold, or that placement gave
; up on. A capped slot counts as complete at that many placements.
global gSlotCaps := Map()
; The newest audit: {removed:[ids],added:[ids],unreadable:[slots],complete}.
global gLastAudit := 0

; Per-match state (called by ResetMatchState).
ResetBuildAudit() {
    global gLookupMisses,gOpenFailures,gEscalationAudits,gCompletionAudits,gAuditDue,gSlotCaps,gLastAudit,gManagerCooldownUntil
    gLookupMisses := Map(),gOpenFailures := 0,gManagerCooldownUntil := 0
    gEscalationAudits := 0,gCompletionAudits := 0,gAuditDue := false
    gSlotCaps := Map(),gLastAudit := 0
}

; How many of this unit placement works towards: the configured count, or the
; cap where the game's limit (or a give-up) is lower.
SlotTargetCount(unit) {
    global gSlotCaps
    return gSlotCaps.Has(unit.slot) ? Min(unit.count,gSlotCaps[unit.slot]) : unit.count
}

; Holds a slot at limit placements: it counts as complete at that many. One
; clear log line, and a Discord warning, whenever this leaves units unplaced.
CapSlot(unit,limit,reason) {
    global gSlotCaps
    if gSlotCaps.Has(unit.slot) && gSlotCaps[unit.slot]<=limit
        return
    gSlotCaps[unit.slot] := limit
    text := "Slot " unit.slot " (" unit.name "): giving up after " reason "; continuing with " limit " of " unit.count " units."
    Log(text)
    if limit<unit.count
        DiscordWarn(text)
}

; The counter shows the slot full: another click can only be refused.
SlotCounterFull(counter) {
    return IsObject(counter) && counter.n>=counter.max
}

; One slot's counter with up to AUDIT_COUNTER_ATTEMPTS reads; false if none.
AuditReadCounter(unit) {
    global gRunning,AUDIT_COUNTER_ATTEMPTS
    Loop AUDIT_COUNTER_ATTEMPTS {
        if !gRunning
            return false
        if HasCardChoice() && !ClearCardChoice()
            return false
        counter := ProbeSlotCounter(unit)
        if counter
            return counter
        Log("Build audit: slot " unit.slot " counter unreadable (" A_Index "/" AUDIT_COUNTER_ATTEMPTS ").")
    }
    return false
}

; Brings one slot's records in line with its counter. source says what
; triggered it (for the log). Returns {removed,added} (counts).
ReconcileSlot(unit,counter,source) {
    recorded := CountSlotPlacements(unit.slot)
    result := {removed:0,added:0}
    if counter.n<recorded {
        Log("Build audit (" source "): slot " unit.slot " shows " counter.n "/" counter.max " but " recorded " are recorded.")
        result.removed := RemoveNewestSlotEntries(unit,recorded-counter.n)
    } else if counter.n>recorded {
        Log("Build audit (" source "): slot " unit.slot " shows " counter.n "/" counter.max " but only " recorded " are recorded; a purchase the macro missed.")
        result.added := AddMissedPurchases(unit,counter.n-recorded)
    }
    if SlotCounterFull(counter) && counter.max<unit.count
        CapSlot(unit,counter.max,"the game's limit for this unit is " counter.max)
    return result
}

; Removes the slot's newest count entries (ghosts), logging each, keeps the
; order of the rest and renumbers. Returns how many were removed.
RemoveNewestSlotEntries(unit,count) {
    global gPlacements,gLastAudit
    removed := Map(),index := gPlacements.Length
    while count>0 && index>=1 {
        item := gPlacements[index]
        if item.slot=unit.slot {
            gPlacements.RemoveAt(index)
            removed[item.id] := true
            count -= 1
            Log("Build audit: ghost #" item.id " " item.name " removed (" (PlacementAnchorKnown(item)?"was recorded at " item.x "," item.y:"no anchor position") ").")
            ; The spot did not hold a unit of ours: keep placement away from it.
            if PlacementAnchorKnown(item) {
                RememberFailedPlacementSpot(item)
                RememberGhostPlacement(unit,item)
            }
            if IsObject(gLastAudit)
                gLastAudit.removed.Push(item.id)
        }
        index -= 1
    }
    if removed.Count
        RenumberPlacements()
    return removed.Count
}

; Purchase numbers are positions in gPlacements (the manager lists units in
; purchase order). Anchor and partner links follow the renumbering; a link to
; a unit that no longer exists is cleared.
RenumberPlacements() {
    global gPlacements
    newId := Map()
    for index,item in gPlacements
        newId[item.id] := index
    for index,item in gPlacements {
        item.anchor := item.anchor && newId.Has(item.anchor) ? newId[item.anchor] : 0
        item.partner := item.partner!="" && newId.Has(item.partner) ? newId[item.partner] : ""
        item.id := index
    }
    ResetUpgradeSelection()
}

; Records count purchases the macro missed: placed, no anchor position.
AddMissedPurchases(unit,count) {
    global gPlacements,gLastAudit
    Loop count {
        item := {id:gPlacements.Length+1,slot:unit.slot,name:unit.name,priority:unit.priority,
            target:unit.target,hill:false,row:1,upgrades:0,x:0,y:0,selectX:0,selectY:0,complete:unit.target=0,
            money:unit.HasProp("money") && unit.money,anchor:0,partner:"",anchorless:true,unreachable:false}
        gPlacements.Push(item)
        Log("Build audit: missed purchase recorded as #" item.id " " item.name " with no anchor position.")
        if IsObject(gLastAudit)
            gLastAudit.added.Push(item.id)
    }
    return count
}

; Reads every enabled slot's counter and reconciles the record. Returns true
; when the build is complete per the counters (an unreadable slot is judged by
; its recorded count).
AuditBuild(plan) {
    global gRunning,gLastAudit,gLookupMisses
    summary := {removed:[],added:[],unreadable:[],complete:true}
    gLastAudit := summary
    ; A new audit cycle: unit manager lookup counts start again.
    gLookupMisses := Map()
    Log("Build audit: reading each slot's counter against the recorded placements.")
    for unit in plan {
        if !unit.enabled || unit.count<1
            continue
        if !gRunning {
            summary.complete := false
            return false
        }
        counter := AuditReadCounter(unit)
        if counter
            ReconcileSlot(unit,counter,"slot counter")
        else if gRunning {
            summary.unreadable.Push(unit.slot)
            Log("Build audit: slot " unit.slot " counter still unreadable after " AUDIT_COUNTER_ATTEMPTS " reads; trusting the " CountSlotPlacements(unit.slot) " recorded placements.")
        }
        if CountSlotPlacements(unit.slot)<SlotTargetCount(unit)
            summary.complete := false
    }
    if !gRunning
        return false
    Log("Build audit finished: " summary.removed.Length " ghost(s) removed, " summary.added.Length " missed purchase(s) recorded, "
        summary.unreadable.Length " slot(s) unreadable; the build is " (summary.complete?"complete.":"incomplete."))
    return summary.complete
}

; The audit that placement runs when it believes the build is complete.
; Bounded by BUILD_AUDIT_LIMIT per match; past it the record is accepted.
VerifyCompletedBuild(plan) {
    global gCompletionAudits,BUILD_AUDIT_LIMIT
    if gCompletionAudits>=BUILD_AUDIT_LIMIT {
        Log("Build audit limit (" BUILD_AUDIT_LIMIT ") reached; the recorded build is accepted as it is.")
        return true
    }
    gCompletionAudits += 1
    return AuditBuild(plan)
}

; --- Unit manager lookups that keep failing --------------------------------

; Counts one failed tile lookup for this purchase in the current audit cycle;
; returns the count.
NoteManagerLookupMiss(purchaseId) {
    global gLookupMisses
    gLookupMisses[purchaseId] := (gLookupMisses.Has(purchaseId)?gLookupMisses[purchaseId]:0)+1
    return gLookupMisses[purchaseId]
}

; The lookup limit for this purchase ran out. The first AUDIT_LIMIT_PER_MATCH
; times the build is audited (RepairBuildAfterManagerMismatch, called by the
; run loop); after that the unit is given up as unreachable: skipped by the
; upgrade queue, so lower priorities go on, and logged.
; Returns true when an audit was requested, false when the unit was skipped.
EscalateManagerLookup(item,reason) {
    global gAuditDue,gEscalationAudits,AUDIT_LIMIT_PER_MATCH,MANAGER_LOOKUP_LIMIT
    if gAuditDue
        return true
    if gEscalationAudits<AUDIT_LIMIT_PER_MATCH {
        gEscalationAudits += 1,gAuditDue := true
        Log("#" item.id " " item.name ": the unit manager lookup failed " MANAGER_LOOKUP_LIMIT " times (" reason "); close F and audit the build (" gEscalationAudits "/" AUDIT_LIMIT_PER_MATCH ").")
        return true
    }
    MarkUnitUnreachable(item,"the unit manager lookup failed " MANAGER_LOOKUP_LIMIT " times (" reason ") and the audit limit (" AUDIT_LIMIT_PER_MATCH ") is used up")
    return false
}

; A unit the manager cannot reach is not unfinished: the upgrade queue skips
; it so lower priorities are not held back by it.
MarkUnitUnreachable(item,why) {
    item.unreachable := true
    Log("#" item.id " " item.name ": " why "; skipping it and continuing with the units that are found.")
}

ManagerAuditDue() {
    global gAuditDue
    return gAuditDue
}

; The manager would not open at all: counted per failed lookup, reset by a
; found tile. Returns true when MANAGER_OPEN_FAIL_LIMIT is reached: upgrades
; then pause for UNIT_MANAGER_GIVEUP_COOLDOWN_MS (a timestamp, checked by
; ManagerCooldownActive; the watch loop keeps running meanwhile) and the same
; bounded attempts start again afterwards. No unit is given up for this.
NoteManagerOpenFailure() {
    global gOpenFailures,MANAGER_OPEN_FAIL_LIMIT,UNIT_MANAGER_GIVEUP_COOLDOWN_MS,gManagerCooldownUntil
    gOpenFailures += 1
    if gOpenFailures<MANAGER_OPEN_FAIL_LIMIT
        return false
    gOpenFailures := 0
    gManagerCooldownUntil := A_TickCount+UNIT_MANAGER_GIVEUP_COOLDOWN_MS
    Log("The unit manager did not open " MANAGER_OPEN_FAIL_LIMIT " times in a row; pausing upgrades for " Round(UNIT_MANAGER_GIVEUP_COOLDOWN_MS/1000) " s, then trying again.")
    return true
}

; True while the cooldown after an F that would not open is running. Logs once
; when it ends.
ManagerCooldownActive() {
    global gManagerCooldownUntil
    if !gManagerCooldownUntil
        return false
    if A_TickCount<gManagerCooldownUntil
        return true
    gManagerCooldownUntil := 0
    Log("Unit manager cooldown over; trying to open it again.")
    return false
}

NoteManagerTileFound() {
    global gOpenFailures
    gOpenFailures := 0
}

; Escalation of a lookup that keeps failing: close F, back to the Placing
; phase, audit the build, place whatever is missing, then back to Upgrading
; through the normal path. Returns "complete" when the manager phase is back,
; otherwise PlaceConfiguredBuild's result ("replay", "stopped", ...).
RepairBuildAfterManagerMismatch(plan) {
    global gAuditDue,gRunning
    gAuditDue := false
    Log("Unit manager and the placement record disagree: closing F and returning to Placing for a build audit.")
    CloseUnitManagerIfOpen("Unit manager mismatch: press F once to close it before the build audit.")
    SetPhase("Placing")
    complete := AuditBuild(plan)
    if !gRunning
        return "stopped"
    if !complete {
        result := PlaceConfiguredBuild(plan)
        if result!="complete"
            return result
    }
    BeginUnitManagerPhase("Build audited (" gPlacements.Length " units); the F unit manager opens again for the upgrades.")
    if !HasCardChoice() && !IsEndGameBlocking()
        EnsureUnitManagerOpen()
    return "complete"
}

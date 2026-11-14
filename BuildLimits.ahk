; Bounds for the build and for the unit manager: a slot held below its
; configured count when placement gives up on it (CapSlot), unit manager
; lookups that keep failing (the record is then checked against the manager),
; record repairs per match, and an F that will not open (upgrades pause for a
; cooldown, then try again).

; Failed unit manager lookups for one purchase ("bottom row does not match",
; "reached the top without it", portrait mismatch, scroll trouble) before the
; record is checked against the manager (RecheckRecordForLookup). The unit is
; never skipped for this: lower priorities keep waiting for it.
global MANAGER_LOOKUP_LIMIT := 6
; Times per match the record may lose units the F manager does not list.
global RECORD_REPAIR_LIMIT := 2
global gRecordRepairs := 0
; Consecutive lookups that failed only because F would not open (no card,
; no other reason) before upgrades pause for the cooldown below. The match is
; never given up: after the cooldown the same bounded attempts start again,
; and this repeats for as long as the phase is Upgrading.
global MANAGER_OPEN_FAIL_LIMIT := 30
global UNIT_MANAGER_GIVEUP_COOLDOWN_MS := 30000
global gManagerCooldownUntil := 0
global gLookupMisses := Map(),gOpenFailures := 0
; Slot -> the most units placement works towards for that slot, when it gave
; up on the rest. A capped slot counts as complete at that many placements.
global gSlotCaps := Map()

; Per-match state (called by ResetMatchState).
ResetBuildLimits() {
    global gLookupMisses,gOpenFailures,gManagerCooldownUntil,gSlotCaps,gRecordRepairs
    gLookupMisses := Map(),gOpenFailures := 0,gManagerCooldownUntil := 0
    gSlotCaps := Map(),gRecordRepairs := 0
}

; How many of this unit placement works towards: the configured count, or
; less where placement gave up on the rest (CapSlot).
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

; Counts one failed tile lookup for this purchase; true once
; MANAGER_LOOKUP_LIMIT is reached (the caller then checks the record against
; the manager, which also resets the count).
ManagerLookupNeedsRecheck(item) {
    global gLookupMisses,MANAGER_LOOKUP_LIMIT
    gLookupMisses[item.id] := gLookupMisses.Get(item.id,0)+1
    return gLookupMisses[item.id]>=MANAGER_LOOKUP_LIMIT
}

; A unit whose upgrade stays stuck (UPGRADE_DEFER_LIMIT) is not unfinished:
; the upgrade queue skips it. Lookup failures never lead here.
MarkUnitUnreachable(item,why) {
    item.unreachable := true
    Log("#" item.id " " item.name ": " why "; skipping it and continuing with the units that are found.")
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

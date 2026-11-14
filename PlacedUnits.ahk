; Confirmed units are numbered in purchase order; only these enter upgrades.
global PLACEMENT_LAYOUT_FILE := A_ScriptDir "\placement_layouts.ini"
global gLayoutValidation := Map()
global gUpgradeSelectedId := 0
; Deferrals (2 s each) of one unit with no progress before it is given up as
; unreachable. A tile the manager lookup cannot find is never given up: the
; record is checked against the F manager instead (RecheckRecordForLookup).
global UPGRADE_DEFER_LIMIT := 40
; Portrait signatures closer than this are the same unit (manager tiles).
global PORTRAIT_SAME_LIMIT := 40
; Slot -> portrait signature, learned only from manager scans that agreed
; with the record. Kept across matches; refreshed by every agreeing scan, so
; a unit swapped into a slot is relearned the next time the counts agree.
global gKnownPortraits := Map()

; Per-match state of the placed-unit record (called by ResetMatchState).
ResetPlacedUnits() {
    global gPlacements
    gPlacements := []
    ResetUpgradeSelection()
    ResetPlacementArea()
}

BeginPlacementRun() {
    global gLayoutValidation
    gLayoutValidation := Map()
    ResetUpgradeSelection()
    ResetPlacementArea()
}

PlacementLayoutKey() {
    global gMapModel,gCameraOverheadReady,gRunViewMoved
    geometry := WindowGeometry()
    if gRunViewMoved || !gMapModel || gMapModel.id="" || !geometry || !gCameraOverheadReady
        return ""
    return "layout." gMapModel.id "." geometry.w "x" geometry.h "." geometry.dpi "." gCameraOverheadReady
}

; A recorded position that never held a unit leaves the saved layout again.
ForgetLayoutPoint(item) {
    global PLACEMENT_LAYOUT_FILE
    section := PlacementLayoutKey()
    if section=""
        return
    value := MemoryRead(section,"slot" item.slot,"",PLACEMENT_LAYOUT_FILE)
    pair := Round(item.x) "," Round(item.y),kept := ""
    for point in StrSplit(value,";")
        if point!="" && point!=pair
            kept .= (kept=""?"":";") point
    if kept!=value
        IniWrite kept,PLACEMENT_LAYOUT_FILE,section,"slot" item.slot
}

SaveLayoutPoint(item) {
    global PLACEMENT_LAYOUT_FILE,gMapModel
    section := PlacementLayoutKey()
    if section=""
        return
    value := MemoryRead(section,"slot" item.slot,"",PLACEMENT_LAYOUT_FILE)
    pair := Round(item.x) "," Round(item.y)
    for point in StrSplit(value,";")
        if point=pair
            return
    IniWrite value=""?pair:value ";" pair,PLACEMENT_LAYOUT_FILE,section,"slot" item.slot
    IniWrite gMapModel.id,PLACEMENT_LAYOUT_FILE,section,"map_id"
}

; evidence names what proved the purchase (the unit panel or the F unit manager).
RegisterPlacedUnit(unit,point,evidence) {
    global gPlacements
    if CandidateOccupied(point.x,point.y) {
        Log("Existing recorded position rejected; slot " unit.slot " count unchanged.")
        return false
    }
    item := {id:gPlacements.Length+1,slot:unit.slot,name:unit.name,priority:unit.priority,
        target:unit.target,hill:point.HasProp("hill") && point.hill,row:point.HasProp("hill") && point.hill?0:point.HasProp("row")?point.row:1,upgrades:0,x:point.x,y:point.y,selectX:point.x,selectY:point.y,complete:unit.target=0,
        money:unit.HasProp("money") && unit.money,anchor:point.HasProp("anchor")?point.anchor:0,partner:"",unreachable:false}
    ; A row-2 unit fills its edge unit's single partner spot.
    if item.anchor
        for other in gPlacements
            if other.id=item.anchor
                other.partner := item.id
    gPlacements.Push(item)
    RememberPlacement(unit,point,true)
    SaveLayoutPoint(item)
    Log("Placed #" item.id " " item.name " at " item.x "," item.y "; priority " item.priority "; confirmed by " evidence ".")
    return item
}

CachedPlacementCandidates(unit) {
    global PLACEMENT_LAYOUT_FILE,gLayoutValidation,REF_W,REF_H,gRunViewMoved
    if gRunViewMoved
        return []
    points := KnownPlacementCandidates(unit)
    if points.Length
        return points
    section := PlacementLayoutKey()
    if section=""
        return points
    values := MemoryRead(section,"slot" unit.slot,"",PLACEMENT_LAYOUT_FILE)
    if values=""
        return points
    if !gLayoutValidation.Has(section) {
        ; Imported/older builds need the same local road view, not just the
        ; same map name. This validates saved positions without replanning.
        all := ""
        Loop 6 {
            part := MemoryRead(section,"slot" A_Index,"",PLACEMENT_LAYOUT_FILE)
            if part!=""
                all .= (all=""?"":";") part
        }
        valid := false
        if all!="" && GetClient(&cx,&cy,&cw,&ch) {
            scene := VisionRequest("world " cx " " cy " " cw " " ch)
            if VisionOk(scene) {
                reply := VisionRequest("validateplacements " all)
                valid := VisionOk(reply) && reply["match"]="1"
            }
        }
        gLayoutValidation[section] := valid
        if valid
            Log("Reusing confirmed positions for this map pattern and local path view.")
    }
    if !gLayoutValidation[section]
        return points
    for value in StrSplit(values,";") {
        xy := StrSplit(value,",")
        if xy.Length=2 && IsNumber(xy[1]) && IsNumber(xy[2]) && !CandidateOccupied(Number(xy[1]),Number(xy[2]))
            points.Push({x:Number(xy[1]),y:Number(xy[2]),cached:true})
    }
    return points
}

UpgradeQueue() {
    global gPlacements
    queue := []
    for item in gPlacements {
        ; A unit the manager cannot reach is skipped, not unfinished: it must
        ; not hold lower priorities back.
        if item.complete || (item.HasProp("unreachable") && item.unreachable)
            continue
        at := queue.Length+1
        for index,other in queue {
            if item.priority<other.priority || (item.priority=other.priority && item.id<other.id) {
                at := index
                break
            }
        }
        queue.InsertAt(at,item)
    }
    return queue
}

ResetUpgradeSelection() {
    global gUpgradeSelectedId
    gUpgradeSelectedId := 0
    ForgetManagerTile()
}

ResetUpgradeTracking(item) {
    item.lastClickAt := 0,item.stableKey := "",item.stableAt := 0,item.maxBarAt := 0
    item.upgradeUnreadCount := 0,item.lowerReads := 0,item.upgradeWarningAt := 0
    item.upgradeRetryAt := 0,item.deferCount := 0
}

RefreshRecordedUpgradeTarget(item) {
    global gUnitControls,gUpgradeSelectedId
    if !IsSet(gUnitControls) || !IsObject(gUnitControls) || item.slot<1 || item.slot>gUnitControls.Length
        return false
    control := gUnitControls[item.slot]
    if !control.HasProp("target") || !IsInteger(control.target.Value)
        return false
    target := Max(0,Min(99,Integer(control.target.Value)))
    if target=item.target
        return false
    Log("#" item.id " slot " item.slot ": upgrade target changed " item.target " -> " target ".")
    item.target := target,item.complete := target=0 || (target!=99 && item.upgrades>=target)
    ResetUpgradeTracking(item)
    if item.complete && gUpgradeSelectedId=item.id {
        CloseUnitPanel()
        ResetUpgradeSelection()
    }
    return true
}

UpgradePriorityPass() {
    global gRunning,gPlacements
    for item in gPlacements
        RefreshRecordedUpgradeTarget(item)
    ; Strict priority: always the highest-priority unfinished unit, even while
    ; it is paused after a failed read. Lower priorities wait for it.
    queue := UpgradeQueue()
    if gRunning && queue.Length
        UpgradeOnce(queue[1])
}

; Evidence for a tile that could not be used: the client area exactly as it
; was. Saved once per unit per match, not on every retry.
SaveUpgradeDiagnostic(item) {
    if item.HasProp("diagnosticSaved") && item.diagnosticSaved
        return
    item.diagnosticSaved := true
    path := A_ScriptDir "\cache\upg-tile-" item.id ".bmp"
    frame := RefPixels(0,0,800,600)
    if frame.valid && SaveFrameBmp(frame,path)
        Log("#" item.id ": saved " path " for diagnosis.")
}

; Strict priority: a stuck unit is not skipped. It pauses 2 s, then the same
; unit is read again; lower priorities wait until it reaches its target, for at
; most UPGRADE_DEFER_LIMIT deferrals (then it is given up as unreachable).
; Logged on the first pause and then about every 30 s.
; mayGiveUp false (a tile the lookup did not find): the pause never counts
; towards giving the unit up; the record recheck handles that case.
DeferUnitUpgrade(item,message,mayGiveUp := true) {
    global UPGRADE_DEFER_LIMIT
    count := (item.HasProp("deferCount")?item.deferCount:0)+1
    if mayGiveUp && count>UPGRADE_DEFER_LIMIT {
        ; Deferred this many times without any progress: give the unit up.
        MarkUnitUnreachable(item,"still stuck after " UPGRADE_DEFER_LIMIT " deferrals (" message ")")
        CloseUnitPanel()
        ResetUpgradeSelection()
        return false
    }
    item.deferCount := count,item.upgradeRetryAt := A_TickCount+2000
    item.lastClickAt := 0,item.upgradeUnreadCount := 0,item.upgradeWarningAt := A_TickCount
    if count=1 || Mod(count,15)=0
        Log("#" item.id " " item.name ": " message " Retry in 2 seconds; lower priorities wait.")
    CloseUnitPanel()
    ResetUpgradeSelection()
    return false
}

UpgradeOnce(item) {
    global gCardAction,gCardInterruptEpoch,gRunning
    previous := gCardAction,gCardAction := "upgrading"
    try {
        resumes := 0
        loop {
            epoch := gCardInterruptEpoch
            result := UpgradeOnceAction(item)
            if epoch=gCardInterruptEpoch || !gRunning || item.complete
                return result
            ; Keep this exact recorded unit/priority after the card, at most
            ; CARD_RESUME_LIMIT times per call.
            if ++resumes>CARD_RESUME_LIMIT
                return result
        }
    } finally gCardAction := previous
}

UpgradeWarning(item,message) {
    if !item.HasProp("upgradeWarningAt")
        item.upgradeWarningAt := 0
    if !item.upgradeWarningAt || A_TickCount-item.upgradeWarningAt>=4000 {
        Log("#" item.id " " item.name ": " message)
        item.upgradeWarningAt := A_TickCount
    }
}

PortraitDistance(a,b) {
    left := StrSplit(a,"."),right := StrSplit(b,".")
    if left.Length!=right.Length
        return 999
    total := 0
    for index,value in left
        total += Abs(Integer(value)-Integer(right[index]))
    return total
}

SlotDisplayName(slot) {
    global gPlacements
    for item in gPlacements
        if item.slot=slot
            return item.name
    return "slot " slot
}

; The first tile seen for a slot teaches that slot's portrait colours. A
; later tile is refused only on clear evidence: far from its own slot's look
; and at most half as far from another slot's. Look-alike units never block.
TileIdentityMismatch(item,entry) {
    global gSlotPortraits,gKnownPortraits
    if entry.sig=""
        return false
    if !gSlotPortraits.Has(item.slot) {
        if !gKnownPortraits.Has(item.slot) {
            gSlotPortraits[item.slot] := entry.sig
            return false
        }
        gSlotPortraits[item.slot] := gKnownPortraits[item.slot]
    }
    own := PortraitDistance(entry.sig,gSlotPortraits[item.slot])
    if own<40
        return false
    for slot,sig in gSlotPortraits {
        if slot=item.slot
            continue
        other := PortraitDistance(entry.sig,sig)
        if other*2<=own {
            Log("#" item.id " " item.name ": this tile looks like " SlotDisplayName(slot) " (distance " other ") rather than " item.name " (distance " own ").")
            return true
        }
    }
    return false
}

ClickTileUpgrade(entry) {
    return ClickManagerPoint(entry.ux,entry.uy)
}

; The same reading twice, at least 250 ms apart, before a level jump nobody
; clicked for, or a MAX, is believed. A manager that has just opened or
; scrolled is still animating, and one frame can show a wrong level or a grey
; button (that ended #7 at 5 of 8 and skipped unit 2).
StableTileRead(item,key) {
    if !item.HasProp("stableKey") || item.stableKey!=key {
        item.stableKey := key,item.stableAt := A_TickCount
        return false
    }
    return A_TickCount-item.stableAt>=250
}

; One upgrade step for a recorded purchase, entirely from its manager tile.
; Like holding R: keep clicking the tile's Upg button until the unit reaches
; MAX or its target. A dimmed Upg button (not enough Yen) is waited on with
; no click; when the button state is unknown, clicks that buy nothing are
; simply repeated. A finite target waits up to 2 s for
; the new segment after each click so a slow bar can never overshoot it.
UpgradeOnceAction(item) {
    global gRunning,gUnitManagerFailure,gUpgradeSelectedId
    RefreshRecordedUpgradeTarget(item)
    if item.complete
        return true
    if !gRunning || !ClearCardChoice()
        return false
    if item.HasProp("upgradeRetryAt") && A_TickCount<item.upgradeRetryAt
        return false
    if !item.HasProp("stableKey")
        ResetUpgradeTracking(item)
    if !(found := LocateManagedUnit(item.id)) {
        if !gRunning
            return false
        reason := gUnitManagerFailure
        if reason="card" || HasCardChoice() {
            ; Choose the card (manager closed and reopened), then this same unit.
            ClearCardChoice()
            return false
        }
        ; F will not open: bounded, then upgrades pause for a cooldown.
        if reason="manager" && NoteManagerOpenFailure()
            return false
        ; A tile that cannot be matched to this purchase (bottom row, missing,
        ; scroll trouble): after MANAGER_LOOKUP_LIMIT tries the record is
        ; checked against the manager (RecheckRecordForLookup). Never skipped.
        if (reason="mismatch" || reason="missing" || reason="scroll") && ManagerLookupNeedsRecheck(item) {
            CloseUnitPanel()
            RecheckRecordForLookup(item,reason)
            ResetUpgradeSelection()
            return false
        }
        item.openFailures := (item.HasProp("openFailures")?item.openFailures:0)+1
        if reason="manager" || item.openFailures<3 {
            UpgradeWarning(item,"tile not found in the unit manager" (reason=""?"":" (" reason ")") "; retry the same priority.")
            return false
        }
        item.openFailures := 0
        SaveUpgradeDiagnostic(item)
        return DeferUnitUpgrade(item,"tile not found in the unit manager after three tries" (reason=""?"":" (" reason ")") ".",false)
    }
    item.openFailures := 0
    entry := found.entry
    if TileIdentityMismatch(item,entry) {
        SaveUpgradeDiagnostic(item)
        ; The same kind of disagreement: after the same lookup limit, the
        ; record is checked against the manager.
        if ManagerLookupNeedsRecheck(item) {
            CloseUnitPanel()
            RecheckRecordForLookup(item,"portrait mismatch")
            ResetUpgradeSelection()
            return false
        }
        return DeferUnitUpgrade(item,"the purchase list and the unit manager disagree about this tile. No upgrade clicked.",false)
    }
    level := entry.filled,finite := item.target!=99
    ; A dimmed Upg button means not enough Yen: nothing to buy yet, so wait on
    ; this unit without counting a failed read or clicking.
    poor := entry.HasProp("afford") && entry.afford=0 && !entry.maxed
    if poor && level<0 {
        item.upgradeUnreadCount := 0
        UpgradeWarning(item,"waiting for Yen (Upg button dimmed).")
        ; The side unit panel (opened by the Upg click) is not used while
        ; waiting; left open it covers the left card and the end screen.
        CloseUnitPanel()
        return false
    }
    ; An unreadable bar cannot overshoot a MAX target, so it is clicked anyway.
    if level<0 && !entry.maxed && finite {
        item.upgradeUnreadCount += 1
        if item.upgradeUnreadCount>=3 {
            SaveUpgradeDiagnostic(item)
            return DeferUnitUpgrade(item,"upgrade segments unreadable three times. No upgrade clicked.")
        }
        UpgradeWarning(item,"upgrade segments unreadable; no upgrade clicked until the level is visible.")
        return false
    }
    item.upgradeUnreadCount := 0
    if level>=0 && level<item.upgrades {
        ; Fewer segments than already confirmed: re-find the tile first, and only
        ; accept the lower count after it is read three times in a row.
        item.lowerReads += 1
        ForgetManagerTile()
        if item.lowerReads<3 {
            UpgradeWarning(item,"tile shows " level " upgrades, below the confirmed " item.upgrades "; re-finding the tile before any click.")
            return false
        }
        Log("#" item.id " " item.name ": tile read " level " upgrades three times; using it instead of " item.upgrades ".")
        item.upgrades := level
    }
    item.lowerReads := 0
    if level>item.upgrades {
        ; One more segment right after our click needs no second look.
        explained := item.lastClickAt && level=item.upgrades+1
        if !explained && !StableTileRead(item,"level " level)
            return false
        Log("#" item.id " " item.name ": upgrade " item.upgrades " -> " level (entry.total>0?" of " entry.total:"") " confirmed on the manager tile.")
        item.upgrades := level,item.deferCount := 0,item.lastClickAt := 0
    }
    maxed := false
    if entry.maxed {
        ; MAX means a grey Max button AND (when readable) every segment lit.
        if entry.total<=0 || level>=entry.total {
            if !StableTileRead(item,"max")
                return false
            maxed := true
        } else {
            ; Grey button over unlit segments is normally a passing frame while
            ; the manager opens. Never click it; believe it only after 4 s.
            if !item.maxBarAt
                item.maxBarAt := A_TickCount
            if A_TickCount-item.maxBarAt<4000 {
                UpgradeWarning(item,"Max button shown but only " level " of " entry.total " segments lit; re-reading before believing MAX.")
                return false
            }
            Log("#" item.id " " item.name ": Max button for 4 s with " level " of " entry.total " segments lit; treating it as MAX.")
            maxed := true
        }
    } else
        item.maxBarAt := 0
    if maxed || (finite && level>=item.target) {
        item.complete := true
        Log("#" item.id " target " item.target " reached" (maxed?" (MAX).":" at upgrade " level "."))
        CloseUnitPanel()
        ResetUpgradeSelection()
        next := UpgradeQueue()
        if next.Length
            Log("Next upgrade #" next[1].id " " next[1].name " | priority " next[1].priority " | target " next[1].target)
        else
            Log("All recorded units have reached their upgrade targets.")
        return true
    }
    if item.lastClickAt && A_TickCount-item.lastClickAt<(finite?2000:300)
        return false
    if poor {
        UpgradeWarning(item,"waiting for Yen (Upg button dimmed).")
        CloseUnitPanel()
        return false
    }
    if HasCardChoice() {
        ClearCardChoice()
        return false
    }
    if !ClickTileUpgrade(entry)
        return false
    item.lastClickAt := A_TickCount
    return true
}

; ---------------------------------------------------------------------------
; The record checked against the F manager. A unit on the map is always listed
; in the manager, so a recorded unit the manager does not list was never
; placed: it is removed from the record and placed again.
; ---------------------------------------------------------------------------

; Consecutive manager tiles with the same portrait, oldest first.
PortraitRuns(tiles) {
    global PORTRAIT_SAME_LIMIT
    runs := []
    for tile in tiles {
        last := runs.Length?runs[runs.Length]:0
        if last && tile.sig!="" && last.sig!="" && PortraitDistance(tile.sig,last.sig)<PORTRAIT_SAME_LIMIT
            last.size += 1
        else
            runs.Push({sig:tile.sig,size:1})
    }
    return runs
}

; Consecutive purchases of the same slot: {slot,first,last,size} (indices).
SlotRuns(slots) {
    runs := []
    for index,slot in slots {
        last := runs.Length?runs[runs.Length]:0
        if last && last.slot=slot
            last.last := index,last.size += 1
        else
            runs.Push({slot:slot,first:index,last:index,size:1})
    }
    return runs
}

; Which purchases (indices into slots, oldest first) the manager's tiles do
; not contain. The manager keeps purchase order, so the portrait runs of the
; tiles must line up, in order, with the slot runs of the record; a slot run
; may have fewer tiles than purchases, or none at all. Exactly one way to line
; them up must fit (a slot's known portrait must match where it is known);
; otherwise the answer is unclear and false is returned. Equal counts need no
; lining up ({drop:[]}); more tiles than purchases gives {drop:[],extra:n}.
MatchTilesToRecord(tiles,slots) {
    global gKnownPortraits,PORTRAIT_SAME_LIMIT
    if tiles.Length>=slots.Length
        return {drop:[],extra:tiles.Length-slots.Length}
    tileRuns := PortraitRuns(tiles),slotRuns := SlotRuns(slots)
    skip := slotRuns.Length-tileRuns.Length
    if skip<0 || slotRuns.Length>12
        return false
    found := 0,drop := []
    Loop (1<<slotRuns.Length) {
        mask := A_Index-1,bits := 0,value := mask
        while value
            bits += value&1,value >>= 1
        if bits!=skip
            continue
        ok := true,candidate := [],t := 1
        for index,run in slotRuns {
            if mask&(1<<(index-1)) {
                Loop run.size
                    candidate.Push(run.first+A_Index-1)
                continue
            }
            tileRun := tileRuns[t++]
            if tileRun.size>run.size
                || (gKnownPortraits.Has(run.slot) && (tileRun.sig="" || PortraitDistance(tileRun.sig,gKnownPortraits[run.slot])>=PORTRAIT_SAME_LIMIT)) {
                ok := false
                break
            }
            ; Same-slot copies are interchangeable: the newest go.
            Loop run.size-tileRun.size
                candidate.Push(run.last-A_Index+1)
        }
        if !ok
            continue
        if ++found>1
            return false
        drop := candidate
    }
    return found=1?{drop:drop,extra:0}:false
}

; A scan that agrees with the record teaches each slot's portrait, for this
; match's tile check too (a stale portrait must not keep failing it).
LearnKnownPortraits(tiles,slots) {
    global gKnownPortraits,gSlotPortraits
    if tiles.Length!=slots.Length
        return
    for index,tile in tiles
        if tile.sig!=""
            gKnownPortraits[slots[index]] := tile.sig,gSlotPortraits[slots[index]] := tile.sig
}

RecordedSlots(extraSlot := 0) {
    global gPlacements
    slots := []
    for item in gPlacements
        slots.Push(item.slot)
    if extraSlot
        slots.Push(extraSlot)
    return slots
}

; Removes purchases that were never placed (indices into gPlacements) and
; renumbers the rest, so #N keeps meaning the Nth tile from the manager's
; bottom. Partner links to a removed unit are reopened.
RemovePlacementRecords(indices,why) {
    global gPlacements,gLookupMisses
    if !indices.Length
        return 0
    ordered := []
    for index in indices
        if index>=1 && index<=gPlacements.Length {
            at := ordered.Length+1
            for position,other in ordered
                if index>other {
                    at := position
                    break
                }
            ordered.InsertAt(at,index)
        }
    for index in ordered {
        item := gPlacements[index]
        Log("#" item.id " " item.name " at " item.x "," item.y " was never placed (" why "); removed from the record so it is placed again.")
        ForgetLayoutPoint(item)
        gPlacements.RemoveAt(index)
    }
    renumber := Map()
    for index,item in gPlacements
        renumber[item.id] := index
    for item in gPlacements {
        if item.anchor
            item.anchor := renumber.Has(item.anchor)?renumber[item.anchor]:0
        if IsInteger(item.partner)
            item.partner := renumber.Has(Integer(item.partner))?renumber[Integer(item.partner)]:""
    }
    for index,item in gPlacements
        item.id := index
    gLookupMisses := Map()
    ResetUpgradeSelection()
    ResetManagerTileMemory()
    return ordered.Length
}

; Applies a manager scan to the record (optionally with a purchase still
; pending as the newest entry). Returns {pending:true/false/"",removed:n,
; agreed:bool} or false when the scan cannot be lined up with the record.
ApplyManagerScan(tiles,pendingSlot := 0) {
    global gPlacements
    slots := RecordedSlots(pendingSlot),recorded := gPlacements.Length
    if !(fit := MatchTilesToRecord(tiles,slots))
        return false
    if fit.extra
        Log("The F manager lists " fit.extra " more unit(s) than recorded.")
    pendingPlaced := pendingSlot?true:"",phantoms := []
    for index in fit.drop {
        if pendingSlot && index=recorded+1
            pendingPlaced := false
        else
            phantoms.Push(index)
    }
    if !phantoms.Length && !fit.extra
        LearnKnownPortraits(tiles,pendingPlaced=true?slots:RecordedSlots())
    removed := phantoms.Length?RecordRepair(phantoms):0
    return {pending:pendingPlaced,removed:removed,agreed:!fit.drop.Length && !fit.extra}
}

; Bounded per match (RECORD_REPAIR_LIMIT): a scan that keeps disagreeing must
; not keep sending the build back to placement.
RecordRepair(phantoms) {
    global gRecordRepairs,RECORD_REPAIR_LIMIT
    if gRecordRepairs>=RECORD_REPAIR_LIMIT {
        Log("The F manager disagrees with the record again, but it was already repaired " RECORD_REPAIR_LIMIT " times this match; keeping the record.")
        return 0
    }
    gRecordRepairs += 1
    return RemovePlacementRecords(phantoms,"the F manager does not list it")
}

; The exact count settles a purchase whose unit panel never proved it:
; "placed" (the manager gained the unit), "absent" (it did not: the spot
; would not take the unit) or "unknown" (the list could not be read).
ManagerPurchaseVerdict(unit,point) {
    global gPlacements
    Log("The unit panel did not prove the purchase; counting the units in the F manager.")
    if !(tiles := PlacementManagerScan())
        return "unknown"
    recorded := gPlacements.Length
    result := ApplyManagerScan(tiles,unit.slot)
    if !result {
        ; Unclear which units the manager lacks: decide on the count alone.
        Log("The F manager lists " tiles.Length " units for " recorded " recorded; which ones are missing is unclear.")
        if tiles.Length=recorded+1
            result := {pending:true}
        else if tiles.Length=recorded
            result := {pending:false}
        else
            return "unknown"
    }
    if !result.pending {
        Log(unit.name ": the F manager lists " tiles.Length " units and none is new; this spot did not take the unit.")
        return "absent"
    }
    ; Removed records may have been earlier copies of this same slot.
    point.pendingCopy := CountSlotPlacements(unit.slot)+1
    Log(unit.name ": no unit panel was seen, but the F manager lists the new unit; recording it.")
    return "placed"
}

; Before the build counts as placed: true when the manager agrees with the
; record (or cannot be read: the record stands), false when units that were
; never placed were removed and must be placed again. A manager that agrees
; is left open for the upgrades that follow.
VerifyBuildWithManager() {
    global gPlacements
    recorded := gPlacements.Length
    if !(tiles := PlacementManagerScan(true)) {
        Log("End-of-build check: the F manager could not be read end to end; keeping the record of " recorded " units.")
        return true
    }
    result := ApplyManagerScan(tiles)
    if !result {
        text := "End-of-build check: the F manager lists " tiles.Length " units, " recorded " are recorded, and which ones are missing is unclear; keeping the record."
        Log(text)
        DiscordWarn(text)
        return true
    }
    if !result.removed {
        if result.agreed
            Log("End-of-build check: the F manager lists all " recorded " recorded units.")
        return true
    }
    CloseUnitManagerIfOpen("Units missing from the F manager will be placed; press F once to close it.")
    return false
}

; Upgrades: a tile that keeps failing the lookup. The manager is counted;
; units it does not list are removed (the watch loop places them again).
; When it lists every recorded unit the tile is there, so the same unit is
; retried: lower priorities still wait. Never skipped.
RecheckRecordForLookup(item,reason) {
    global gLookupMisses,gPlacements
    SaveUpgradeDiagnostic(item)
    gLookupMisses[item.id] := 0
    recorded := gPlacements.Length,id := item.id
    if !(tiles := ScanManagerTiles()) {
        Log("#" id " " item.name ": tile not found (" reason ") and the F manager could not be counted; retrying the same unit.")
        return
    }
    result := ApplyManagerScan(tiles)
    if result && result.removed
        return
    if result && result.agreed
        Log("#" id " " item.name ": tile not found (" reason "), but the F manager lists all " recorded " units; retrying the same unit (lower priorities wait).")
    else
        Log("#" id " " item.name ": tile not found (" reason "); the F manager lists " tiles.Length " units for " recorded " recorded and which are missing is unclear; retrying the same unit.")
}


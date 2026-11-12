; Confirmed units are numbered in purchase order; only these enter upgrades.
global PLACEMENT_RUN_FILE := A_ScriptDir "\placement_run.ini"
global PLACEMENT_LAYOUT_FILE := A_ScriptDir "\placement_layouts.ini"
global gRunRecording := false,gRunMap := "",gLayoutValidation := Map()
global gUpgradeSelectedId := 0

; Per-match state of the placed-unit record (called by ResetMatchState).
ResetPlacedUnits() {
    global gPlacements
    gPlacements := []
    ResetUpgradeSelection()
    ResetPlacementArea()
}

BeginPlacementRun() {
    global gRunRecording,gRunMap,gMapModel,gLayoutValidation
    gRunRecording := true,gRunMap := gMapModel ? gMapModel.id : "",gLayoutValidation := Map()
    ResetUpgradeSelection()
    ResetPlacementArea()
    SavePlacementRun()
}

SavePlacementRun() {
    global gRunRecording,gRunMap,gPlacements,PLACEMENT_RUN_FILE,gPlacementProfile
    if !gRunRecording
        return
    text := "[Run]`r`nmap_id=" gRunMap "`r`nprofile=" gPlacementProfile "`r`ncount=" gPlacements.Length "`r`n"
    for item in gPlacements {
        text .= "`r`n[Placement" item.id "]`r`n"
        for key in ["id","slot","name","priority","target","x","y","selectX","selectY","upgrades","complete","hill","row","money","anchor","partner"]
            text .= key "=" item.%key% "`r`n"
    }
    file := FileOpen(PLACEMENT_RUN_FILE ".tmp","w","UTF-16")
    file.Write(text),file.Close()
    FileMove PLACEMENT_RUN_FILE ".tmp",PLACEMENT_RUN_FILE,1
}

PlacementLayoutKey() {
    global gMapModel,gCameraOverheadReady,gRunViewMoved
    geometry := WindowGeometry()
    if gRunViewMoved || !gMapModel || gMapModel.id="" || !geometry || !gCameraOverheadReady
        return ""
    return "layout." gMapModel.id "." geometry.w "x" geometry.h "." geometry.dpi "." gCameraOverheadReady
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

; evidence names what proved the purchase (slot counter, Yen drop or unit panel).
RegisterPlacedUnit(unit,point,evidence) {
    global gPlacements
    if CandidateOccupied(point.x,point.y) {
        Log("Existing recorded position rejected; slot " unit.slot " count unchanged.")
        return false
    }
    item := {id:gPlacements.Length+1,slot:unit.slot,name:unit.name,priority:unit.priority,
        target:unit.target,hill:point.HasProp("hill") && point.hill,row:point.HasProp("hill") && point.hill?0:point.HasProp("row")?point.row:1,upgrades:0,x:point.x,y:point.y,selectX:point.x,selectY:point.y,complete:unit.target=0,
        money:unit.HasProp("money") && unit.money,anchor:point.HasProp("anchor")?point.anchor:0,partner:""}
    ; A row-2 unit fills its edge unit's single partner spot.
    if item.anchor
        for other in gPlacements
            if other.id=item.anchor
                other.partner := item.id
    gPlacements.Push(item)
    RememberPlacement(unit,point,true)
    SaveLayoutPoint(item)
    SavePlacementRun()
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
        if item.complete
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
    SavePlacementRun()
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

; Strict priority: a stuck unit is never skipped. It pauses 2 s, then the same
; unit is read again; lower priorities wait until it reaches its target.
; Logged on the first pause and then about every 30 s.
DeferUnitUpgrade(item,message) {
    count := (item.HasProp("deferCount")?item.deferCount:0)+1
    item.deferCount := count,item.upgradeRetryAt := A_TickCount+2000
    item.lastClickAt := 0,item.upgradeUnreadCount := 0,item.upgradeWarningAt := A_TickCount
    if count=1 || Mod(count,15)=0
        Log("#" item.id " " item.name ": " message " Retry in 2 seconds; lower priorities wait.")
    CloseUnitPanel()
    ResetUpgradeSelection()
    return false
}

OpenRecordedUnit(item) {
    return SelectManagedUnit(item.id)
}

UpgradeOnce(item) {
    global gCardAction,gCardInterruptEpoch,gRunning
    previous := gCardAction,gCardAction := "upgrading"
    try {
        loop {
            epoch := gCardInterruptEpoch
            result := UpgradeOnceAction(item)
            if epoch=gCardInterruptEpoch || !gRunning || item.complete
                return result
            ; Keep this exact recorded unit/priority after the card.
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
    global gSlotPortraits
    if entry.sig=""
        return false
    if !gSlotPortraits.Has(item.slot) {
        gSlotPortraits[item.slot] := entry.sig
        return false
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
        item.openFailures := (item.HasProp("openFailures")?item.openFailures:0)+1
        if reason="manager" || item.openFailures<3 {
            UpgradeWarning(item,"tile not found in the unit manager" (reason=""?"":" (" reason ")") "; retry the same priority.")
            return false
        }
        item.openFailures := 0
        SaveUpgradeDiagnostic(item)
        return DeferUnitUpgrade(item,"tile not found in the unit manager after three tries" (reason=""?"":" (" reason ")") ".")
    }
    item.openFailures := 0
    entry := found.entry
    if TileIdentityMismatch(item,entry) {
        SaveUpgradeDiagnostic(item)
        return DeferUnitUpgrade(item,"the purchase list and the unit manager disagree about this tile. No upgrade clicked.")
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
        SavePlacementRun()
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
        SavePlacementRun()
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

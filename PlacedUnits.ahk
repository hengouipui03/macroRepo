; Confirmed units are numbered in purchase order; only these enter upgrades.
global PLACEMENT_RUN_FILE := A_ScriptDir "\placement_run.ini"
global PLACEMENT_LAYOUT_FILE := A_ScriptDir "\placement_layouts.ini"
global gRunRecording := false,gRunMap := "",gLayoutValidation := Map()
global gUpgradeSelectedId := 0
; How the tile's Upg button works in this game: "" until a click is seen to add
; a segment, then "direct" (Upg alone) or "select" (portrait first, then Upg).
global gUpgradeClickMode := ""

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

RegisterPlacedUnit(unit,point) {
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
    Log("Placed #" item.id " " item.name " at " item.x "," item.y "; priority " item.priority "; unit panel confirmed.")
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

UpgradeQueue(readyOnly := false) {
    global gPlacements
    queue := []
    for item in gPlacements {
        if item.complete || (readyOnly && item.HasProp("upgradeRetryAt") && A_TickCount<item.upgradeRetryAt)
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
    item.lastClickAt := 0,item.lastClickMode := "",item.noChange := 0
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
    queue := UpgradeQueue(true)
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

; A genuinely stuck unit backs off 10, 20, 40, then 60 seconds so lower
; priorities keep upgrading; any confirmed upgrade resets the back-off.
DeferUnitUpgrade(item,message) {
    count := (item.HasProp("deferCount")?item.deferCount:0)+1
    delay := Min(60,10*(2**(count-1)))
    item.deferCount := count,item.upgradeRetryAt := A_TickCount+delay*1000
    item.lastClickAt := 0,item.noChange := 0,item.upgradeUnreadCount := 0,item.upgradeWarningAt := A_TickCount
    Log("#" item.id " " item.name ": " message " Retry in " delay " seconds; continue other units.")
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

ClickTileUpgrade(entry,select) {
    global gUpgradeSelectedId
    if select {
        if !ClickManagerPoint(entry.x,entry.y) || !WaitForUnitPanel(600,true)
            return false
    }
    return ClickManagerPoint(entry.ux,entry.uy)
}

; One upgrade step for a recorded purchase, entirely from its manager tile:
; lit segments are the level, a grey Max button is MAX, and every click on the
; tile's Upg button is confirmed by a new lit segment before the next one.
UpgradeOnceAction(item) {
    global gRunning,gUnitManagerFailure,gUpgradeClickMode,gUpgradeSelectedId
    RefreshRecordedUpgradeTarget(item)
    if item.complete
        return true
    if !gRunning || !ClearCardChoice()
        return false
    if item.HasProp("upgradeRetryAt") && A_TickCount<item.upgradeRetryAt
        return false
    if !item.HasProp("noChange")
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
        return DeferUnitUpgrade(item,"tile not found in the unit manager after three tries" (reason=""?"":" (" reason ")") "; let the other units upgrade.")
    }
    item.openFailures := 0
    entry := found.entry
    if TileIdentityMismatch(item,entry) {
        SaveUpgradeDiagnostic(item)
        return DeferUnitUpgrade(item,"the purchase list and the unit manager disagree about this tile. No upgrade clicked.")
    }
    level := entry.filled
    if level<0 && !entry.maxed {
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
        Log("#" item.id " " item.name ": upgrade " item.upgrades " -> " level (entry.total>0?" of " entry.total:"") " confirmed on the manager tile.")
        if gUpgradeClickMode="" && item.lastClickMode!="" {
            gUpgradeClickMode := item.lastClickMode
            Log(gUpgradeClickMode="direct"?"Upgrade clicks work directly on the tile's Upg button.":"Upgrade clicks need the unit selected first; selecting the portrait before Upg from now on.")
        }
        item.upgrades := level,item.noChange := 0,item.deferCount := 0,item.lastClickAt := 0
        SavePlacementRun()
    }
    finite := item.target!=99
    if entry.maxed || (finite && level>=item.target) {
        item.complete := true
        SavePlacementRun()
        Log("#" item.id " target " item.target " reached" (entry.maxed?" (MAX).":" at upgrade " level "."))
        if gUpgradeSelectedId=item.id
            CloseUnitPanel()
        ResetUpgradeSelection()
        next := UpgradeQueue()
        if next.Length
            Log("Next upgrade #" next[1].id " " next[1].name " | priority " next[1].priority " | target " next[1].target)
        else
            Log("All recorded units have reached their upgrade targets.")
        return true
    }
    ; One click at a time. A finite target waits 2 s for its new segment, so a
    ; slow bar can never let a second click overshoot the target.
    if item.lastClickAt {
        if A_TickCount-item.lastClickAt<(finite?2000:600)
            return false
        item.noChange += 1
        if Mod(item.noChange,5)=0
            UpgradeWarning(item,"no new segment after " item.noChange " Upg clicks; waiting for Yen and retrying.")
    }
    if HasCardChoice() {
        ClearCardChoice()
        return false
    }
    ; Until a click has been seen to work, alternate: Upg alone twice, then
    ; portrait + Upg, so either game behaviour is discovered.
    select := gUpgradeClickMode="select" || (gUpgradeClickMode="" && item.noChange>=2 && Mod(item.noChange,2)=0)
    if !ClickTileUpgrade(entry,select)
        return false
    if select
        gUpgradeSelectedId := item.id
    item.lastClickAt := A_TickCount,item.lastClickMode := select?"select":"direct"
    return true
}

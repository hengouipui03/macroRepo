; Confirmed units are numbered in purchase order; only these enter upgrades.
global PLACEMENT_RUN_FILE := A_ScriptDir "\placement_run.ini"
global PLACEMENT_LAYOUT_FILE := A_ScriptDir "\placement_layouts.ini"
global gRunRecording := false,gRunMap := "",gLayoutValidation := Map()
global gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0

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
        for key in ["id","slot","name","priority","target","x","y","selectX","selectY","upgrades","complete","hill","row"]
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
        target:unit.target,hill:point.HasProp("hill") && point.hill,row:point.HasProp("hill") && point.hill?0:point.HasProp("row")?point.row:1,upgrades:0,x:point.x,y:point.y,selectX:point.x,selectY:point.y,complete:unit.target=0}
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
    global gPlacements,gRunViewMoved
    if readyOnly
        RecoverPlacementView()
    queue := []
    for item in gPlacements {
        if readyOnly && (!PlacementAnchorKnown(item) || (gRunViewMoved && (item.x<50 || item.x>745 || item.y<140 || item.y>475)))
            continue
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
    global gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0
}

ResetFiniteUpgradeGuard(item) {
    item.upgradeInputCount := 0,item.upgradeInputLimit := -1
    item.lastUpgradeInputLevel := -1,item.lastUpgradeInputAt := 0,item.upgradeWarningAt := 0
    item.upgradeRetryAt := 0
    item.lastUpgradeInputSignature := "",item.upgradeUnreadCount := 0
}

RefreshRecordedUpgradeTarget(item) {
    global gUnitControls,gUpgradeReadAt,gUpgradeSelectedId
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
    ResetFiniteUpgradeGuard(item)
    gUpgradeReadAt := 0
    if item.complete && gUpgradeSelectedId=item.id {
        ClickAwayFromUnitPanel()
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

ParseUpgradeState(rows,geometry) {
    global REF_W,REF_H
    state := {level:-1,maxed:false,x:210,y:368,raw:""}
    heading := UnitPanelRegion("header"),button := UnitPanelRegion("button")
    for row in rows {
        text := NormalizeWords(row.text)
        state.raw .= (state.raw=""?"":" | ") text
        y := (row.y+row.h/2)*REF_H/geometry.ch
        if y>=heading[2]-6 && y<=heading[4]+6 && RegExMatch(text,"\bu\s*p\s*[g69](?:rade)?\s*(?:\[|:|\.|-)?\s*(\d+|o)",&match)
            state.level := match[1]="o"?0:Integer(match[1])
        if y>=heading[2]-6 && y<=heading[4]+6 && RegExMatch(text,"\bupg(?:rade)?\s*max(?:ed)?\b")
            state.maxed := true
        if y>=button[2]-6 && y<=button[4]+6 {
            if RegExMatch(text,"^(?:(?:upgrade|upg)\s+)?max(?:ed)?(?:\s+(?:upgrade|upg|level))?$")
                state.maxed := true
            if RegExMatch(text,"\bupgrade\b") {
                state.x := (row.x+row.w/2)*REF_W/geometry.cw
                state.y := y
            }
        }
    }
    return state
}

UnitUpgradeButtonReady(frame := 0) {
    region := UnitPanelRegion("button")
    if !frame
        frame := RefPixels(region*)
    return frame.valid && UnitPanelColourHits(frame,region[1],region[2],region[3],region[4],IsUiGreen)>=8
}

ReadUnitUpgradeState(finite := false) {
    geometry := WindowGeometry()
    if !geometry
        return {level:-1,maxed:false,signature:"",canUpgrade:false,x:210,y:368,raw:"window unavailable"}
    ; Keep numbers from damage, cooldown and upgrade cost out of the level OCR.
    before := finite?UpgradeHeaderSignature():""
    header := UnitPanelRegion("header")
    rows := finite?ReadOcrRows(header[1],header[2],header[3],header[4],false,4):ReadOcrRows(0,100,340,520)
    state := ParseUpgradeState(rows,geometry)
    if finite && state.level<0 && !state.maxed {
        ; Windows OCR can drop the bracketed digit at 4x but read it at 2x.
        rows := ReadOcrRows(header[1],header[2],header[3],header[4],false,2)
        state := ParseUpgradeState(rows,geometry)
    }
    state.canUpgrade := !finite || UnitUpgradeButtonReady()
    if finite && (state.level<0 || !state.canUpgrade) {
        full := ParseUpgradeState(ReadOcrRows(0,100,340,520),geometry)
        if state.level<0
            state.level := full.level
        state.maxed := state.maxed || full.maxed
        state.raw .= " | " full.raw
    }
    state.signature := finite?UpgradeHeaderSignature():""
    if finite && (before="" || before!=state.signature)
        state.level := -1,state.signature := ""
    return state
}

UpgradeHeaderSignature() {
    region := UnitPanelRegion("header")
    frame := RefPixels(region*)
    if !frame.valid
        return ""
    ; Only the fixed gold heading participates, never animated scenery/stats.
    signature := "",hits := 0
    Loop frame.height {
        y := A_Index-1
        Loop frame.width {
            ink := IsUiYellow(frame.At(A_Index-1,y))
            signature .= ink?"1":"0",hits += ink?1:0
        }
    }
    return hits>=8?signature:""
}

DeferUnitUpgrade(item,message) {
    ; Unreadable pending targets remain unfinished and return to their priority.
    item.upgradeRetryAt := A_TickCount+10000
    UpgradeWarning(item,message " Retry in 10 seconds; continue other units.")
    ClickAwayFromUnitPanel()
    ResetUpgradeSelection()
    return false
}

OpenRecordedUnit(item) {
    if !CloseUnitPanel() || !CancelUnitPreview()
        return false
    ; Ground placement and the selectable model may differ in screen height.
    ; Remember the first working model click for all later upgrade passes.
    targets := [{x:item.selectX,y:item.selectY}]
    for offset in [[0,-15],[0,-30],[0,-50]]
        targets.Push({x:item.x+offset[1],y:item.y+offset[2]})
    for index,point in targets {
        if HasCardChoice() {
            if !ClearCardChoice()
                return false
        }
        if TrySelectUnitAt(point,650,index=1) {
            item.selectX := point.x,item.selectY := point.y
            SavePlacementRun()
            return true
        }
    }
    if gRunning
        Log("#" item.id " " item.name ": unit panel did not open near recorded " item.x "," item.y ".")
    return false
}

PressUnitUpgradeKey() {
    global gRunning,gUpgradeLastRAt
    if !gRunning || HasCardChoice() || !HasUnitPanel()
        return false
    if !BeginInputAction()
        return false
    gUpgradeLastRAt := A_TickCount
    SendEvent "{r down}"
    try return ActionPause(60,false)
    finally {
        SendEvent "{r up}"
        EndInputAction()
    }
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
            ; Keep this exact recorded unit/priority after closing its panel.
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

UpgradeOnceAction(item) {
    global gRunning,gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    RefreshRecordedUpgradeTarget(item)
    if item.complete
        return true
    if !gRunning || !ClearCardChoice()
        return false
    if item.HasProp("upgradeRetryAt") && A_TickCount<item.upgradeRetryAt
        return false
    if !item.HasProp("upgradeInputLimit")
        ResetFiniteUpgradeGuard(item)
    if gUpgradeSelectedId!=item.id || !HasUnitPanel() {
        ResetUpgradeSelection()
        Log("Open upgrade #" item.id " " item.name " | priority " item.priority " | target " item.target " | recorded " item.x "," item.y)
        if !OpenRecordedUnit(item) {
            if gRunning
                return DeferUnitUpgrade(item,"Unit panel did not open; let the other units upgrade.")
            return false
        }
        gUpgradeSelectedId := item.id
    }
    finite := item.target!=99
    wantsInput := !gUpgradeLastRAt || A_TickCount-gUpgradeLastRAt>=300
    ; Every finite-target R needs its own fresh header read.
    if finite && (!wantsInput || (gUpgradeReadAt && A_TickCount<gUpgradeReadAt))
        return false
    state := 0
    if finite || wantsInput || !gUpgradeReadAt || A_TickCount>=gUpgradeReadAt {
        state := ReadUnitUpgradeState(finite)
        gUpgradeReadAt := A_TickCount+(finite?600:2000)
        if RefreshRecordedUpgradeTarget(item)
            return item.complete
        finite := item.target!=99
        if state.level>=0 && state.level>item.upgrades {
            Log("#" item.id " confirmed UPG " item.upgrades " -> " state.level)
            item.upgrades := state.level
            SavePlacementRun()
        }
        if item.complete || state.maxed || (state.level>=0 && finite && state.level>=item.target) {
            item.complete := true
            SavePlacementRun()
            Log("#" item.id " target " item.target " reached" (state.maxed?" (MAX).":" at UPG " state.level "."))
            ClickAwayFromUnitPanel()
            ResetUpgradeSelection()
            next := UpgradeQueue()
            if next.Length
                Log("Next upgrade #" next[1].id " " next[1].name " | priority " next[1].priority " | target " next[1].target)
            else
                Log("All recorded units have reached their upgrade targets.")
            return true
        }
    }
    if HasCardChoice() {
        ClearCardChoice()
        return false
    }
    if finite {
        if !state || state.level<0 {
            item.upgradeUnreadCount += 1
            if item.upgradeUnreadCount>=3
                return DeferUnitUpgrade(item,"UPG header unreadable; target " item.target " remains pending. No R sent.")
            UpgradeWarning(item,"UPG number unreadable; target " item.target ". No R sent until a level is confirmed.")
            return false
        }
        item.upgradeUnreadCount := 0
        if state.level<item.upgrades {
            UpgradeWarning(item,"stale UPG reading below confirmed " item.upgrades "; no R sent.")
            return false
        }
        if item.lastUpgradeInputLevel>=0 && state.level<=item.lastUpgradeInputLevel {
            if A_TickCount-item.lastUpgradeInputAt<4000
                return false
            ; Retry an ignored R only when both OCR and the actual gold glyphs
            ; still show the same level. Changed glyphs + stale OCR cannot spend
            ; another input, even if the configured target has not been read yet.
            if state.signature="" || state.signature!=item.lastUpgradeInputSignature
                return DeferUnitUpgrade(item,"UPG pixels changed but OCR has not confirmed the new level. No extra R sent.")
            item.upgradeInputCount := Max(0,item.upgradeInputCount-1)
            item.lastUpgradeInputLevel := -1
        }
        available := item.upgradeInputCount+Max(0,item.target-state.level)
        item.upgradeInputLimit := item.upgradeInputLimit<0?available:Min(item.upgradeInputLimit,available)
        if item.upgradeInputCount>=item.upgradeInputLimit {
            return DeferUnitUpgrade(item,"Finite-target input limit reached; waiting for UPG " item.target " confirmation. No extra R sent.")
        }
        if !state.HasProp("canUpgrade") || !state.canUpgrade {
            UpgradeWarning(item,"upgrade button is not affordable/ready; keep this unit selected and wait.")
            return false
        }
        if PressUnitUpgradeKey() {
            item.upgradeInputCount += 1,item.lastUpgradeInputLevel := state.level,item.lastUpgradeInputAt := A_TickCount
            item.lastUpgradeInputSignature := state.signature
            return true
        }
        return false
    }
    if wantsInput
        return PressUnitUpgradeKey()
    return false
}

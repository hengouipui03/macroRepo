#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [],gPlacementProfile := "test-profile",gMapModel := 0,gCameraOverheadReady := "overhead-5000",REF_W := 800,REF_H := 600
global dispatchProduction := false
global gUnitControls := [],reportedLevel := -1
global called := [],known := [],visionCalls := 0,layoutMatch := true,mode := "upgrade",currentLevel := 0,maxAt := 99,money := true,readable := true,panel := false,lastPoint := 0,purchases := 0,openBody := true,reports := 0,endClicks := 0
global gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
global gCardAction := "",gCardInterruptEpoch := 0
global testNow := 10000,bodyClicks := 0,awayClicks := 0,cardOpen := false,cardClears := 0
; Confirmed units are numbered in purchase order; only these enter upgrades.
global PLACEMENT_RUN_FILE := A_ScriptDir "\placement_run.ini"
global PLACEMENT_LAYOUT_FILE := A_ScriptDir "\placement_layouts.ini"
global gRunRecording := false,gRunMap := "",gLayoutValidation := Map()
global gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0

BeginPlacementRun() {
    global gRunRecording,gRunMap,gMapModel,gLayoutValidation
    gRunRecording := true,gRunMap := gMapModel ? gMapModel.id : "",gLayoutValidation := Map()
    ResetUpgradeSelection()
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
    global gMapModel,gCameraOverheadReady
    geometry := WindowGeometry()
    if !gMapModel || gMapModel.id="" || !geometry || !gCameraOverheadReady
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
    global PLACEMENT_LAYOUT_FILE,gLayoutValidation,REF_W,REF_H
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
    global gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    gUpgradeSelectedId := 0,gUpgradeLastRAt := 0,gUpgradeReadAt := 0
}

ResetFiniteUpgradeGuard(item) {
    item.upgradeInputCount := 0,item.upgradeInputLimit := -1
    item.lastUpgradeInputLevel := -1,item.lastUpgradeInputAt := 0,item.upgradeWarningAt := 0
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
    queue := UpgradeQueue()
    if gRunning && queue.Length
        UpgradeOnce(queue[1])
}

ParseUpgradeState(rows,geometry) {
    global REF_W,REF_H
    state := {level:-1,maxed:false,x:210,y:368,raw:""}
    for row in rows {
        text := NormalizeWords(row.text)
        state.raw .= (state.raw=""?"":" | ") text
        y := (row.y+row.h/2)*REF_H/geometry.ch
        if y<255 && RegExMatch(text,"\bu\s*p\s*[g69](?:rade)?\s*(?:\[|:|\.|-)?\s*(\d+|o)",&match)
            state.level := match[1]="o"?0:Integer(match[1])
        if y<255 && RegExMatch(text,"\bupg(?:rade)?\s*max(?:ed)?\b")
            state.maxed := true
        if y>325 {
            if RegExMatch(text,"\bmax(?:ed)?\b")
                state.maxed := true
            if RegExMatch(text,"\bupgrade\b") {
                state.x := (row.x+row.w/2)*REF_W/geometry.cw
                state.y := y
            }
        }
    }
    return state
}

RealUnitUpgradeButtonReady(frame := 0) {
    if !frame
        frame := RefPixels(145,340,265,395)
    return frame.valid && UnitPanelColourHits(frame,150,345,255,390,IsUiGreen)>=8
}

ReadUnitUpgradeState(finite := false) {
    geometry := WindowGeometry()
    if !geometry
        return {level:-1,maxed:false,canUpgrade:false,x:210,y:368,raw:"window unavailable"}
    ; Keep numbers from damage, cooldown and upgrade cost out of the level OCR.
    rows := finite?ReadOcrRows(137,216,202,239):ReadOcrRows(135,205,285,395)
    state := ParseUpgradeState(rows,geometry)
    state.canUpgrade := !finite || UnitUpgradeButtonReady()
    if finite && (state.level<0 || !state.canUpgrade) {
        full := ParseUpgradeState(ReadOcrRows(135,205,285,395),geometry)
        if state.level<0
            state.level := full.level
        state.maxed := state.maxed || full.maxed
        state.raw .= " | " full.raw
    }
    return state
}

OpenRecordedUnit(item) {
    if !CloseUnitPanel() || !CancelUnitPreview()
        return false
    ; Ground placement and the selectable model may differ in screen height.
    ; Remember the first working model click for all later upgrade passes.
    targets := [{x:item.selectX,y:item.selectY}]
    for offset in [[0,-10],[0,-20],[-8,-12],[8,-12],[0,-30]]
        targets.Push({x:item.x+offset[1],y:item.y+offset[2]})
    for point in targets {
        if HasCardChoice() {
            if !ClearCardChoice()
                return false
        }
        if !PlacementClickRef(point.x,point.y,true)
            return false
        if WaitFor(HasUnitPanel,900,60) {
            item.selectX := point.x,item.selectY := point.y
            SavePlacementRun()
            return true
        }
    }
    Log("#" item.id " " item.name ": unit panel did not open near recorded " item.x "," item.y "; will retry.")
    return false
}

PressUnitUpgradeKey() {
    global gRunning,gUpgradeLastRAt
    if !gRunning || HasCardChoice() || !HasUnitPanel()
        return false
    gUpgradeLastRAt := testNow
    SendEvent "{r down}"
    try return ActionPause(60,false)
    finally SendEvent "{r up}"
}

ProductionUpgradeOnce(item) {
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
    if !item.upgradeWarningAt || testNow-item.upgradeWarningAt>=4000 {
        Log("#" item.id " " item.name ": " message)
        item.upgradeWarningAt := testNow
    }
}

UpgradeOnceAction(item) {
    global gRunning,gUpgradeSelectedId,gUpgradeLastRAt,gUpgradeReadAt
    RefreshRecordedUpgradeTarget(item)
    if item.complete
        return true
    if !gRunning || !ClearCardChoice()
        return false
    if gUpgradeSelectedId!=item.id || !HasUnitPanel() {
        ResetUpgradeSelection()
        Log("Open upgrade #" item.id " " item.name " | priority " item.priority " | target " item.target " | recorded " item.x "," item.y)
        if !OpenRecordedUnit(item)
            return false
        gUpgradeSelectedId := item.id
    }
    finite := item.target!=99
    wantsInput := !gUpgradeLastRAt || testNow-gUpgradeLastRAt>=1000
    ; Every finite-target R needs its own fresh header read.
    if finite && (!wantsInput || (gUpgradeReadAt && testNow<gUpgradeReadAt))
        return false
    state := 0
    if finite || !gUpgradeReadAt || testNow>=gUpgradeReadAt {
        state := ReadUnitUpgradeState(finite)
        gUpgradeReadAt := testNow+(finite?600:2000)
        RefreshRecordedUpgradeTarget(item)
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
            UpgradeWarning(item,"UPG number unreadable; target " item.target ". No R sent until a level is confirmed.")
            return false
        }
        if state.level<item.upgrades {
            UpgradeWarning(item,"stale UPG reading below confirmed " item.upgrades "; no R sent.")
            return false
        }
        if !item.HasProp("upgradeInputLimit")
            ResetFiniteUpgradeGuard(item)
        available := item.upgradeInputCount+Max(0,item.target-state.level)
        item.upgradeInputLimit := item.upgradeInputLimit<0?available:Min(item.upgradeInputLimit,available)
        if item.upgradeInputCount>=item.upgradeInputLimit {
            UpgradeWarning(item,"finite-target input limit reached; waiting for UPG " item.target " confirmation. No extra R sent.")
            return false
        }
        if item.lastUpgradeInputLevel>=0 && state.level<=item.lastUpgradeInputLevel
            && testNow-item.lastUpgradeInputAt<4000 {
            UpgradeWarning(item,"waiting for UPG change after the last R; no repeated input.")
            return false
        }
        if !state.HasProp("canUpgrade") || !state.canUpgrade {
            UpgradeWarning(item,"upgrade button is not affordable/ready; keep this unit selected and wait.")
            return false
        }
        if PressUnitUpgradeKey() {
            item.upgradeInputCount += 1,item.lastUpgradeInputLevel := state.level,item.lastUpgradeInputAt := testNow
            return true
        }
        return false
    }
    if wantsInput
        return PressUnitUpgradeKey()
    return false
}

try {
    geometry := {cw:800,ch:600}
    Assert(ParseUpgradeState([{x:140,y:220,w:55,h:14,text:"UPG [8]"}],geometry).level=8,"UPG 8 header did not parse")
    Assert(ParseUpgradeState([{x:170,y:360,w:90,h:20,text:"Upgrade: 30000 Yen"}],geometry).level=-1,"Upgrade cost was mistaken for the current level")
    if FileExist(A_ScriptDir "\upgrade-native.tsv") {
        rows := ParseOcrRows(FileRead(A_ScriptDir "\upgrade-native.tsv","UTF-8"),219,311)
        Assert(ParseUpgradeState(rows,{cw:1280,ch:864}).level=9,"Actual attached UPG 9 header was not read correctly")
    }
    try FileDelete PLACEMENT_RUN_FILE
    try FileDelete PLACEMENT_LAYOUT_FILE
    gRunRecording := true,gRunMap := "test-map"
    slow := {slot:3,name:"Unit 3",priority:4,target:6}
    high := {slot:1,name:"Unit 1",priority:1,target:99}
    a := RegisterPlacedUnit(slow,{x:432,y:350})
    b := RegisterPlacedUnit(high,{x:464,y:322,row:2})
    c := RegisterPlacedUnit(high,{x:432,y:398})
    Assert(a.id=1 && b.id=2 && c.id=3,"Successes were not numbered in purchase order")
    Assert(a.row=1 && b.row=2 && IniRead(PLACEMENT_RUN_FILE,"Placement2","row")=2,"Second-row metadata did not survive recording")
    Assert(IniRead(PLACEMENT_RUN_FILE,"Placement1","x")=432 && IniRead(PLACEMENT_RUN_FILE,"Placement2","priority")=1,"Numbered coordinate/priority journal did not persist")
    Assert(!RegisterPlacedUnit(slow,{x:432,y:350}) && gPlacements.Length=3,"The same recorded unit position was counted twice")
    UpgradePriorityPass()
    Assert(called.Length=1 && called[1]=2,"Upgrade order was not priority then placement number")
    b.complete := true,called := []
    UpgradePriorityPass()
    Assert(called.Length=1 && called[1]=3,"Incomplete high priority did not block lower priority")
    c.complete := true,called := []
    UpgradePriorityPass()
    Assert(called.Length=1 && called[1]=1,"Next priority did not start after high priority finished")
    gPlacements := [a],a.complete := false,a.target := 1,a.upgrades := 0
    currentLevel := 0,maxAt := 99,money := true,readable := true,purchases := 0,bodyClicks := 0,awayClicks := 0
    Assert(ProductionUpgradeOnce(a),"First R was not pressed")
    Assert(purchases=1 && panel && awayClicks=0,"First upgrade closed the unit panel")
    testNow += 1000
    Assert(ProductionUpgradeOnce(a) && a.complete && a.upgrades=1 && purchases=1,"Numeric target was overshot or not confirmed")
    Assert(a.selectY=a.y-10,"Selectable model point was not learned above the ground anchor")
    a.complete := false,a.target := 99,a.upgrades := 0,currentLevel := 0,maxAt := 3,money := true,purchases := 0,bodyClicks := 0,awayClicks := 0
    ResetUpgradeSelection()
    Assert(ProductionUpgradeOnce(a) && purchases=1 && panel,"MAX upgrade did not begin")
    opened := bodyClicks
    testNow += 939
    Assert(!ProductionUpgradeOnce(a) && purchases=1,"R repeated before one second")
    testNow += 1
    Assert(ProductionUpgradeOnce(a) && purchases=2 && bodyClicks=opened && awayClicks=0,"Repeated upgrade clicked away or reselected the same unit")
    testNow += 1000
    Assert(ProductionUpgradeOnce(a) && purchases=3,"Third R was not sent")
    testNow += 2000
    Assert(ProductionUpgradeOnce(a) && a.complete && a.upgrades=3 && purchases=3 && awayClicks=1,"MAX failed to stop R and complete the selected unit")
    a.complete := false,a.target := 99,a.upgrades := 0,currentLevel := 0,maxAt := 99,money := false,purchases := 0,bodyClicks := 0,awayClicks := 0
    ResetUpgradeSelection()
    ProductionUpgradeOnce(a)
    opened := bodyClicks
    testNow += 2000
    ProductionUpgradeOnce(a)
    Assert(a.upgrades=0 && !a.complete && panel && bodyClicks=opened && awayClicks=0,"Waiting for Yen recorded fake upgrades or reselected the unit")
    cardOpen := true,money := true
    testNow += 1000
    ProductionUpgradeOnce(a)
    Assert(cardClears=1 && !cardOpen && bodyClicks>opened && panel,"Card did not close panel, select, and reopen the same recorded unit")
    Assert(gUpgradeSelectedId=a.id,"Card interruption lost the selected placement")
    a.complete := false,a.target := 99,currentLevel := 0,maxAt := 99,openBody := false,purchases := 0
    ResetUpgradeSelection(),panel := false
    Assert(!ProductionUpgradeOnce(a) && purchases=0,"R pressed without opening the recorded unit")
    ; Finite targets may not blindly continue when the header is missing/stale.
    a.complete := false,a.target := 8,a.upgrades := 7,currentLevel := 7,maxAt := 99,money := true,readable := true,reportedLevel := -1
    purchases := 0,bodyClicks := 0,awayClicks := 0,openBody := true,gPlacements := [a]
    ResetUpgradeSelection(),ResetFiniteUpgradeGuard(a)
    Assert(ProductionUpgradeOnce(a) && purchases=1 && currentLevel=8,"Target-8 unit did not buy exactly one level from UPG 7")
    reportedLevel := 7
    Loop 10 {
        testNow += 1000
        ProductionUpgradeOnce(a)
    }
    Assert(purchases=1 && currentLevel=8 && !a.complete,"Stale UPG 7 reading kept pressing R toward MAX")
    reportedLevel := -1,testNow += 1000
    Assert(ProductionUpgradeOnce(a) && a.complete && a.upgrades=8 && purchases=1,"Confirmed UPG 8 did not stop R")
    a.complete := false,a.target := 8,a.upgrades := 0,currentLevel := 0,purchases := 0,readable := true
    ResetUpgradeSelection(),ResetFiniteUpgradeGuard(a)
    Loop 10 {
        ProductionUpgradeOnce(a)
        testNow += 1000
    }
    Assert(a.complete && a.upgrades=8 && currentLevel=8 && purchases=8,"Full finite upgrade sequence exceeded target 8")
    a.complete := false,a.target := 8,a.upgrades := 5,currentLevel := 5,purchases := 0,readable := false
    ResetUpgradeSelection(),ResetFiniteUpgradeGuard(a)
    Loop 5 {
        ProductionUpgradeOnce(a)
        testNow += 1000
    }
    Assert(purchases=0 && !a.complete && a.upgrades=5,"Unreadable finite-target UPG header still sent R")
    readable := true,money := false,testNow += 1000
    ProductionUpgradeOnce(a)
    Assert(purchases=0 && panel,"Unaffordable finite upgrade consumed an input or reselected its unit")
    money := true,testNow += 1000
    Assert(ProductionUpgradeOnce(a) && purchases=1 && currentLevel=6,"Finite upgrade did not resume after the button became ready")
    a.upgrades := 7,reportedLevel := 6,testNow += 1000
    Assert(!ProductionUpgradeOnce(a) && purchases=1 && a.upgrades=7,"A decreasing OCR level reset confirmed progress or sent R")
    reportedLevel := -1,a.complete := false,a.target := 99,a.upgrades := 7,currentLevel := 7,purchases := 0
    gUnitControls := [{target:{Value:99}},{target:{Value:99}},{target:{Value:8}}]
    ResetUpgradeSelection(),ResetFiniteUpgradeGuard(a)
    Assert(ProductionUpgradeOnce(a) && a.target=8 && purchases=1 && currentLevel=8,"Live target edit did not replace the recorded MAX target")
    testNow += 1000
    Assert(ProductionUpgradeOnce(a) && a.complete && purchases=1,"Live target 8 continued to MAX")
    gUnitControls := []
    ; Exercise the actual priority dispatcher through completion and handoff.
    first := a.Clone(),first.id := 10,first.slot := 1,first.priority := 1,first.target := 8,first.upgrades := 7,first.complete := false
    second := a.Clone(),second.id := 11,second.slot := 2,second.priority := 1,second.target := 3,second.upgrades := 2,second.complete := false
    third := a.Clone(),third.id := 12,third.slot := 3,third.priority := 2,third.target := 1,third.upgrades := 0,third.complete := false
    done := a.Clone(),done.id := 9,done.priority := 0,done.complete := true
    for item in [first,second,third]
        ResetFiniteUpgradeGuard(item)
    gPlacements := [third,second,done,first],called := [],dispatchProduction := true
    currentLevel := 7,purchases := 0,readable := false,money := true,reportedLevel := -1
    ResetUpgradeSelection()
    UpgradePriorityPass()
    Assert(called.Length=1 && called[1]=10 && purchases=0 && !first.complete,"Unreadable highest priority was marked done or a lower priority started")
    readable := true,testNow += 1000
    UpgradePriorityPass()
    Assert(currentLevel=8 && purchases=1 && gUpgradeSelectedId=10,"Highest priority did not upgrade to 8")
    testNow += 1000
    UpgradePriorityPass()
    Assert(first.complete && gUpgradeSelectedId=0 && UpgradeQueue()[1].id=11 && purchases=1,"At target 8, unit did not close/complete and hand off to next placement")
    currentLevel := 2,testNow += 1000
    UpgradePriorityPass()
    Assert(called[called.Length]=11 && gUpgradeSelectedId=11 && currentLevel=3 && purchases=2,"Same-priority next placement was not selected after target completion")
    testNow += 1000
    UpgradePriorityPass()
    Assert(second.complete && UpgradeQueue()[1].id=12 && purchases=2,"Second target did not hand off to next priority")
    currentLevel := 0,testNow += 1000
    UpgradePriorityPass()
    testNow += 1000
    UpgradePriorityPass()
    Assert(third.complete && UpgradeQueue().Length=0 && purchases=3,"Final priority failed to finish or sent an extra R")
    oldCalls := called.Length
    UpgradePriorityPass()
    Assert(called.Length=oldCalls && purchases=3,"Completed build continued selecting/upgrading units")
    dispatchProduction := false
    openBody := true,gPlacements := [],gMapModel := {id:"map-A"},known := []
    a.slot := 3,a.x := 432,a.y := 350
    SaveLayoutPoint(a)
    got := CachedPlacementCandidates(slow)
    Assert(got.Length=1 && got[1].x=432 && visionCalls=2,"Map layout did not reload after local-view validation")
    gLayoutValidation := Map(),layoutMatch := false
    Assert(CachedPlacementCandidates(slow).Length=0,"Mismatched local view reused saved coordinates")
    known := [{x:500,y:360}],visionCalls := 0
    Assert(CachedPlacementCandidates(slow).Length=1 && visionCalls=0,"Exact matching profile recalculated positions")
    known := [],mode := "play",reports := 0,endClicks := 0
    Assert(!HasDefeatNext() && !HasReplayButton(),"Green/yellow world objects were mistaken for end buttons")
    Assert(!TryEndState() && reports=0 && endClicks=0,"Live playfield caused an end-screen click or report")
    mode := "defeat"
    Assert(HasDefeatNext(),"Actual DEFEAT/Next text was not accepted")
    mode := "replay"
    Assert(HasReplayButton(),"Replay/Return to lobby controls not accepted")
    FileAppend "PASS: confirmed target completion hands off to next placement by priority then ID, skips completed units and sends no extra R; exact target 8; unreadable/stale/decreasing header blocks R; finite input cap; money wait/resume; live UI target edits; numbered persistent coordinates; priority and stable ID order; high-priority blocking; persistent selection; R every second; MAX/target stop; card close/select/reopen; no false increments; model click offset; map cache and wrong-view rejection; no false end clicks.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
UpgradeOnce(item) {
    global called,dispatchProduction
    called.Push(item.id)
    return dispatchProduction?ProductionUpgradeOnce(item):false
}
RememberPlacement(*) => 0
Log(*) => 0
CloseUnitPanel(*) {
    global panel
    panel := false
    return true
}
CancelUnitPreview(*) => true
ClearCardChoice() {
    global gRunning,gCardSelection
    if !HasCardChoice() {
        if !gCardSelection
            return true
        if WaitForCardChoiceClosed() {
            ResetCardSelection()
            return true
        }
        return false
    }
    if !ClickAwayFromUnitPanel()
        return false
    Log("Card choice is open; choosing before continuing.")
    deadline := testNow+20000
    while gRunning && testNow<deadline {
        if HasCardChoice()
            TryChooseCard()
        else if WaitForCardChoiceClosed() {
            ResetCardSelection()
            return true
        }
        ActionPause(150)
    }
    return false
}

ResetCardSelection() {
    global gCardSelection,gCardRetryAt,gCardUnread
    gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
}

WaitForCardChoiceClosed() {
    global gRunning
    closedAt := 0,deadline := testNow+1400
    while gRunning && testNow<deadline {
        if HasCardChoice()
            closedAt := 0
        else if !closedAt
            closedAt := testNow
        else if testNow-closedAt>=350
            return true
        if !ActionPause(70)
            return false
    }
    return false
}

ConfirmLockedCardSelection() {
    global gCardSelection,gCardRetryAt,gRunning
    if !gRunning || !gCardSelection
        return false
    if !HasCardChoice()
        return false
    if testNow<gCardRetryAt {
        ActionPause(100)
        return true
    }
    choice := gCardSelection,rect := CardRectangle(choice.index)
    Log("Keep card " choice.index ": " choice.kind " / " choice.stat "; awaiting confirmation.")
    ; Recheck after moving: a closing dialog must not receive another click.
    if !ClickRef((rect[1]+rect[3])//2,330,HasCardChoice)
        return true
    gCardRetryAt := testNow+1000
    if WaitForCardChoiceClosed() {
        Notify("Selected " choice.kind ": " choice.stat)
        ResetCardSelection()
    }
    return true
}

TryChooseCard() {
    global panel,cardOpen,cardClears
    if panel
        throw Error("Card selected before clicking away from the unit panel")
    cardClears += 1,cardOpen := false
    return true
}

HasCardChoice(*) {
    global cardOpen
    return cardOpen
}
ClickAwayFromUnitPanel(*) {
    global panel,awayClicks,gUpgradeSelectedId
    awayClicks += 1,panel := false,gUpgradeSelectedId := 0
    return true
}
SendEvent(keys) {
    global purchases,currentLevel,money,panel
    if keys="{r down}" {
        if !panel
            throw Error("R pressed without a selected unit")
        purchases += 1
        if money
            currentLevel += 1
    }
}
PlacementClickRef(x,y,*) {
    global panel,lastPoint,currentLevel,purchases,money,openBody,bodyClicks
    lastPoint := {x:x,y:y}
    if x>150 && x<285 && y>330 && y<395 {
        purchases += 1
        if money
            currentLevel += 1
    } else {
        bodyClicks += 1
        panel := openBody && y=340
    }
    return true
}
WaitFor(test,*) => test.Call()
HasUnitPanel(*) {
    global panel
    return panel
}
ActionPause(ms,*) {
    global testNow
    testNow += ms
    return true
}
WindowGeometry() => {w:800,h:600,dpi:96,cw:800,ch:600}
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 800,ch := 600
    return true
}
ReadOcrRows(*) {
    global mode,currentLevel,maxAt,readable,reportedLevel
    if mode="play"
        return [{text:"Wave 12"},{text:"Enemies remaining"}]
    if mode="defeat"
        return [{text:"DEFEAT"},{text:"Next"}]
    if mode="replay"
        return [{text:"Return to lobby"},{text:"Replay"}]
    rows := [{x:170,y:360,w:80,h:20,text:currentLevel>=maxAt?"MAXED":"Upgrade: 5000 Yen"}]
    if readable
        rows.Push({x:145,y:215,w:60,h:16,text:"UPG [" (reportedLevel>=0?reportedLevel:currentLevel) "]"})
    return rows
}
CountRef(*) => 100
IsUiGreen(*) => true
IsUiYellow(*) => true
IsUiRed(*) => true
ReportMatchResult(*) {
    global reports
    reports += 1
}
ClickButton(*) {
    global endClicks
    endClicks += 1
    return true
}
KnownPlacementCandidates(*) {
    global known
    return known.Clone()
}
CandidateOccupied(x,y) {
    global gPlacements
    for item in gPlacements
        if Sqrt((x-item.x)**2+(y-item.y)**2)<24
            return true
    return false
}
VisionOk(reply) => reply && reply["status"]="ok"
VisionRequest(line) {
    global visionCalls,layoutMatch
    visionCalls += 1
    if InStr(line,"world ")=1
        return Map("status","ok","path","100")
    return Map("status","ok","match",layoutMatch?"1":"0")
}
MemoryRead(section,key,fallback := "",file := "") {
    try return IniRead(file,section,key,fallback)
    catch
        return fallback
}

NormalizeWords(text) {
    return Trim(RegExReplace(StrLower(text), "[^a-z0-9%+.-]+", " "))
}

HasDefeatNext() {
    if CountRef(270,345,420,440,5,IsUiGreen)<=14
        return false
    if CountRef(225,168,415,213,4,IsUiRed)<25
        return false
    text := ""
    for row in ReadOcrRows(120,155,535,440)
        text .= " " NormalizeWords(row.text)
    return RegExMatch(text,"\bdefeat\b") && RegExMatch(text,"\bnext\b")
}

HasReplayButton() {
    if CountRef(390,70,620,155,6,IsUiYellow)<=14 || CountRef(220,80,395,150,6,IsUiGreen)<=10
        return false
    text := ""
    for row in ReadOcrRows(210,80,620,205)
        text .= " " NormalizeWords(row.text)
    return RegExMatch(text,"\breplay\b") && RegExMatch(text,"\breturn to lobby\b")
}

TryEndState() {
    ; Report before clicking, while the end screen is still showing.
    if HasDefeatNext() {
        ReportMatchResult(false)
        ClickButton("DefeatNext")
    }
    if HasReplayButton() {
        ReportMatchResult(true)
        ClickButton("Replay")
        return true
    }
    return false
}

UnitUpgradeButtonReady(*) {
    global money
    return money
}
class RefPixels {
    valid := false
    __New(*) {
    }
}
UnitPanelColourHits(*) => 0

ParseOcrRows(content, left, top) {
    rows := []
    for line in StrSplit(content,"`n","`r") {
        fields := StrSplit(line,"`t")
        if fields.Length >= 5 && IsNumber(fields[1]) && IsNumber(fields[2]) && IsNumber(fields[3]) && IsNumber(fields[4])
            rows.Push({x:left+Number(fields[1]),y:top+Number(fields[2]),w:Number(fields[3]),h:Number(fields[4]),text:fields[5]})
    }
    return rows
}

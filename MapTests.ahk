class FixtureMapFrame extends RefPixels {
    __New(path) {
        this.storage := FileRead(path,"RAW")
        this.width := NumGet(this.storage,0,"UInt"),this.height := NumGet(this.storage,4,"UInt")
        this.left := NumGet(this.storage,8,"UInt"),this.top := NumGet(this.storage,12,"UInt")
        this.scaleX := NumGet(this.storage,16,"UInt")/800,this.scaleY := NumGet(this.storage,20,"UInt")/600
        this.bits := this.storage.Ptr+24,this.valid := true
    }
}

RunMapTests() {
    global MAP_GRID,LEARNING_FILE
    count := 0
    CheckMap(condition,message) {
        if !condition
            throw Error("Minimap: " message)
    }
    frame := FixtureMapFrame(A_ScriptDir "\minimap-fixture.mapframe")
    model := ReadMapModel(frame,false)
    CheckMap(model && model.nodes.Count>80,"attached Future City route was not traced")
    count += 1
    CheckMap(model.player,"actual white player chevron was not detected")
    count += 1
    CheckMap(model.baseMarker,"actual white heart/base was not detected")
    count += 1
    ; Expected positions come from the supplied full screenshot, not a generated
    ; arrow template: chevron about (1265,1083), heart about (1208,1075).
    playerNativeX := model.player.x/(MAP_GRID-1)*(frame.width-1)+frame.left+1
    playerNativeY := model.player.y/(MAP_GRID-1)*(frame.height-1)+frame.top+31
    baseNativeX := model.baseMarker.x/(MAP_GRID-1)*(frame.width-1)+frame.left+1
    baseNativeY := model.baseMarker.y/(MAP_GRID-1)*(frame.height-1)+frame.top+31
    CheckMap(MapDistance(playerNativeX,playerNativeY,1265,1083)<8,"heart and arrow positions were confused")
    count += 1
    CheckMap(MapDistance(baseNativeX,baseNativeY,1208,1075)<8,"base position incorrect")
    count += 1
    CheckMap(model.player.hy < -0.8,"actual chevron should face up")
    count += 1
    for marker in ["heart","arrow"] {
        masked := FixtureMapFrame(A_ScriptDir "\minimap-fixture.mapframe")
        centre := marker="heart" ? model.baseMarker : model.player
        mx := centre.x/(MAP_GRID-1)*(masked.width-1),my := centre.y/(MAP_GRID-1)*(masked.height-1)
        y := Max(0,Floor(my-12))
        while y<=Min(masked.height-1,Ceil(my+12)) {
            x := Max(0,Floor(mx-12))
            while x<=Min(masked.width-1,Ceil(mx+12)) {
                if IsMiniMapPlayerWhite(masked.At(x,y))
                    NumPut("UInt",0xFF202020,masked.storage,24+(y*masked.width+x)*4)
                x += 1
            }
            y += 1
        }
        hidden := ReadMapModel(masked,false)
        if marker="heart"
            CheckMap(hidden.player && !hidden.baseMarker,"missing heart corrupted the player reading")
        else
            CheckMap(!hidden.player && hidden.baseMarker,"heart was mistaken for an occluded player")
        count += 1
    }
    CheckMap(model.target>=0 && model.nodes.Has(model.target),"auto destination is not on the drawn line")
    count += 1
    start := MapNearest(model.nodes,model.player.x,model.player.y)
    path := MapShortestPath(model.nodes,start,model.target)
    CheckMap(path.Length>5,"recommended point has no connected route from the player")
    count += 1
    base := MapNearest(model.nodes,model.baseMarker.x,model.baseMarker.y)
    tree := MapDistances(model.nodes,base)
    CheckMap(tree.distance.Count=model.nodes.Count,"red enemy-icon gap left the drawing disconnected")
    count += 1
    top := MapNearest(model.nodes,(1275-frame.left-1)/(frame.width-1)*(MAP_GRID-1),(870-frame.top-31)/(frame.height-1)*(MAP_GRID-1))
    CheckMap(tree.distance.Has(top) && top//MAP_GRID < 25,"upper spawn segment was not joined across red-icon occlusion")
    count += 1
    bend := Map()
    Loop 20
        bend[30*MAP_GRID+20+A_Index] := true
    Loop 20
        bend[(30+A_Index)*MAP_GRID+40] := true
    CheckMap(!MapLineFollowsRoute(bend,30*MAP_GRID+21,50*MAP_GRID+40),"navigator would cut diagonally across a bend")
    count += 1
    CheckMap(MapLineFollowsRoute(bend,30*MAP_GRID+21,30*MAP_GRID+40),"straight route segment rejected")
    count += 1
    originalFile := LEARNING_FILE
    testFile := A_ScriptDir "\map-test-" DllCall("GetCurrentProcessId") ".ini"
    try {
        LEARNING_FILE := testFile
        ArchiveMapModel(model)
        savedId := model.id
        IniWrite model.target,LEARNING_FILE,"minimap." model.id,"destination"
        again := ReadMapModel(frame,true)
        CheckMap(again.id=savedId && again.manual && again.target=model.target,"map drawing/destination did not survive a cold reload")
        count += 1
        CheckMap(MemoryRead("minimap_catalog","variants")=savedId,"same map was added twice")
        count += 1
        occluded := model.Clone(),partial := MapFromBits(model.raw),index := 0
        for key in partial.Clone() {
            index += 1
            if Mod(index,18)=0
                partial.Delete(key)
        }
        occluded.raw := MapBits(partial),occluded.baseMarker := false,occluded.target := -1,occluded.id := ""
        ArchiveMapModel(occluded)
        CheckMap(occluded.id=savedId && occluded.baseMarker && occluded.nodes.Count=model.nodes.Count,"small icon occlusion created a different map or discarded its drawing")
        count += 1
        rotated := model.Clone(),turned := Map()
        for key in MapFromBits(model.raw)
            turned[Mod(key,MAP_GRID)*MAP_GRID+(MAP_GRID-1-key//MAP_GRID)] := true
        rotated.raw := MapBits(turned),rotated.nodes := MapThin(turned),rotated.id := "",rotated.target := -1
        ArchiveMapModel(rotated)
        CheckMap(rotated.id!=savedId,"a different route layout reused the wrong map variant")
        count += 1
    } finally {
        LEARNING_FILE := originalFile
        try FileDelete testFile
    }
    parallel := Map()
    Loop 10 {
        parallel[(20+A_Index)*MAP_GRID+20] := true
        parallel[(20+A_Index)*MAP_GRID+28] := true
    }
    CheckMap(MapBridgeFragments(parallel).mask.Count=10,"unobserved gap joined separate parallel lanes")
    count += 1
    count += RunVisionMapTests(frame,model)
    FileAppend "Future City: " model.nodes.Count " route nodes; player " Round(playerNativeX,1) "," Round(playerNativeY,1) "; base " Round(baseNativeX,1) "," Round(baseNativeY,1) "; heading " Round(model.player.hx,2) "," Round(model.player.hy,2) "; route " path.Length " steps.`n",A_ScriptDir "\map-fixture-results.txt","UTF-8"
    return count
}

; MinimapVision.py on the same Future City crop, plus the supplied mid-wave
; screenshot (darker line, enemies covering much of it). No game input is sent.
RunVisionMapTests(frame,pixelModel) {
    global MAP_GRID
    count := 0
    CheckVision(condition,message) {
        if !condition
            throw Error("Minimap vision: " message)
    }
    CheckVision(VisionOk(VisionRequest("load " A_ScriptDir "\minimap-fixture.mapframe")),"MinimapVision.py did not start (needs Python with opencv-python, numpy, mss, dxcam)")
    count += 1
    model := VisionModelFromScan(VisionRequest("scan"),false)
    CheckVision(model && model.source="vision" && model.nodes.Count>80,"fixture route was not traced")
    count += 1
    CheckVision(model.player && model.baseMarker,"fixture chevron or heart missing")
    count += 1
    playerX := model.player.x/(MAP_GRID-1)*(frame.width-1)+frame.left+1
    playerY := model.player.y/(MAP_GRID-1)*(frame.height-1)+frame.top+31
    baseX := model.baseMarker.x/(MAP_GRID-1)*(frame.width-1)+frame.left+1
    baseY := model.baseMarker.y/(MAP_GRID-1)*(frame.height-1)+frame.top+31
    CheckVision(MapDistance(playerX,playerY,1265,1083)<8 && MapDistance(baseX,baseY,1208,1075)<8,"marker positions differ from the screenshot")
    count += 1
    tree := MapDistances(model.nodes,MapNearest(model.nodes,model.baseMarker.x,model.baseMarker.y))
    CheckVision(tree.distance.Count=model.nodes.Count,"fixture route disconnected")
    count += 1
    CheckVision(BitOverlap(model.raw,pixelModel.raw)>0.78,"vision drawing would not match variants learned by the pixel reader")
    count += 1
    CheckVision(VisionOk(VisionRequest("load " A_ScriptDir "\minimap-screenshot.png")),"screenshot fixture not loaded")
    busy := VisionModelFromScan(VisionRequest("scan"),false)
    CheckVision(busy && busy.player && busy.baseMarker,"mid-wave chevron or heart missing")
    count += 1
    CheckVision(OccludedShapeMatch(busy.raw,busy.explained,model.raw)>0.78,"mid-wave minimap not recognized as the learned clean drawing")
    count += 1
    turned := Map()
    for key in MapFromBits(model.raw)
        turned[Mod(key,MAP_GRID)*MAP_GRID+(MAP_GRID-1-key//MAP_GRID)] := true
    CheckVision(OccludedShapeMatch(busy.raw,busy.explained,MapBits(turned))=0,"mid-wave minimap matched a different layout")
    count += 1
    ; WASD solve: W moves north, D east on the minimap.
    keys := {w:{x:0,y:-8},d:{x:8,y:0}}
    presses := MoveDurations(4,-4,keys)
    CheckVision(presses.Length=2 && presses[1].key="w" && presses[1].ms=400 && presses[2].key="d" && presses[2].ms=400,"north-east move not split into W and D")
    count += 1
    presses := MoveDurations(-4,4,keys)
    CheckVision(presses.Length=2 && presses[1].key="s" && presses[2].key="a","south-west move should use S and A")
    count += 1
    ; Camera turned a quarter: W now moves east and D south.
    presses := MoveDurations(0,4,{w:{x:8,y:0},d:{x:0,y:8}})
    CheckVision(presses.Length=1 && presses[1].key="d" && presses[1].ms=400,"rotated camera not solved from measured keys")
    count += 1
    presses := MoveDurations(40,-20,keys),expected := MovePrediction(presses,keys)
    CheckVision(Max(presses[1].ms,presses[2].ms)=550 && Abs(expected.x*-20-expected.y*40)<1,"long move clipped out of direction")
    count += 1
    CheckVision(MoveVectorsAgree({x:0,y:-8},{x:0.5,y:-7}) && !MoveVectorsAgree({x:0,y:-8},{x:8,y:0}),"key vector agreement")
    count += 1
    ; Obstacles: retry the blocked move jumping, then step around it.
    steps := EscapeSteps(4,0,1)
    CheckVision(steps.Length=1 && Abs(steps[1].x-4)<0.01 && Abs(steps[1].y)<0.01 && steps[1].jump,"first attempt should repeat the blocked move while jumping")
    count += 1
    steps := EscapeSteps(4,0,2)
    CheckVision(Abs(steps[1].x)<0.01 && Abs(Abs(steps[1].y)-3)<0.01 && steps[1].jump,"side step should be perpendicular to the blocked move")
    count += 1
    steps := EscapeSteps(0,-5,4)
    CheckVision(steps.Length=2 && Abs(steps[1].y-3)<0.01 && !steps[1].jump && Abs(steps[2].y)<0.01 && Abs(Abs(steps[2].x)-9)<0.01,"wider attempt should back off, then step aside")
    count += 1
    presses := MoveDurations(0,-8,keys,1200,1.0)
    presses.Push({key:"space",ms:1000})
    expected := MovePrediction(presses,keys)
    CheckVision(presses[1].key="w" && presses[1].ms=1000 && Abs(expected.x)<0.01 && Abs(expected.y+8)<0.01,"full-length step or jump changed the prediction")
    count += 1
    ; Lit path (P on) screenshot through the AHK bridge.
    CheckVision(VisionOk(VisionRequest("loadworld " A_ScriptDir "\path-world-screenshot.png")),"world screenshot not loaded")
    toggle := VisionRequest("toolbar 0 0 1379 1056")
    CheckVision(VisionOk(toggle) && toggle["on"]="1" && StrSplit(toggle["p"],",").Length=2,"lit P toggle not reported")
    count += 1
    world := VisionRequest("world 0 0 1379 1056")
    CheckVision(VisionOk(world) && world["on"]="1" && Number(world["path"])>40000,"lit path around the player not reported")
    count += 1
    beside := VisionRequest("beside 10")
    CheckVision(VisionOk(beside) && Number(beside["count"])>=8,"no placement points beside the lit path")
    for text in StrSplit(beside["points"],";") {
        point := StrSplit(text,",")
        on := VisionRequest("onpath " point[1] " " point[2])
        CheckVision(VisionOk(on) && on["on"]="0","placement point " text " is on the lit path")
    }
    count += 1
    ; Re-aiming: a 400 ms W move toward a path point up and to the right.
    aimed := AimPresses([{key:"w",ms:400}],400,100,-100)
    CheckVision(aimed.Length=2 && aimed[1].key="w" && aimed[2].key="d" && Abs(aimed[1].ms-283)<=1 && Abs(aimed[2].ms-283)<=1,"lit-path aim not split into W and D")
    count += 1
    CheckVision(IsWebhookUrl("https://discord.com/api/webhooks/123/abc_DEF-1") && !IsWebhookUrl("https://example.com/api/webhooks/1/a") && !IsWebhookUrl("http://discord.com/api/webhooks/1/a"),"webhook URL check")
    count += 1
    aimed := AimPresses([{key:"w",ms:400}],400,-120,0)
    CheckVision(aimed.Length=1 && aimed[1].key="a" && aimed[1].ms=400,"lit path to the left should use A")
    count += 1
    return count
}

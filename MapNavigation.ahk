; The minimap is the navigation model. Coordinates are normalized to a 96x96
; drawing; no world illumination or map-name OCR is needed to navigate.
global MAP_GRID := 96
; Sky Island (the only three-path map): stand exactly here, where the green,
; crimson and blue paths meet beside the base (minimap grid units).
global THREE_PATH_STAND := {x:20.26,y:22.10}
global gMapModel := 0
global gPrepDeadline := 0, gCameraOverheadReady := false
global PREPARATION_BUDGET_MS := 50000,gNavigationTimedOut := false
global gMapWalking := false, gMapSpeed := 8.0
; MinimapVision.py reads the minimap; AHK keeps all input. gMoveKeys holds the
; measured minimap movement (grid units/second) of W and D in overhead view.
global VISION_PYTHON := "pythonw.exe"
global gVision := 0, gVisionFailed := false, gMoveKeys := 0, gPathLit := false,gPathToggleClicked := false
global gVisionRetryAt := 0
global PROBE_MS := 220, PROBE_SETTLE_MS := 140
; A card that appears mid-walk pauses movement: keys are released first, the
; card is chosen, then the walk resumes from the player's actual position.
global gMovementInterrupted := false,gMovementCardMs := 0,gMovementCardTotalMs := 0
OnExit(VisionClose)

MiniMapBounds(cw,ch) {
    ; Bottom/right anchoring follows the minimap, not an illuminated world road.
    side := Round(Min(cw*0.20,ch*0.253))
    margin := Max(6,Round(cw/1400*7)), inset := 6
    return {left:cw-margin-side+inset,top:ch-margin-side+inset,right:cw-margin-inset,bottom:ch-margin-inset}
}

CaptureMiniMap() {
    global REF_W,REF_H
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    box := MiniMapBounds(cw,ch)
    return RefPixels(box.left*REF_W/cw,box.top*REF_H/ch,box.right*REF_W/cw,box.bottom*REF_H/ch)
}

MapNeighbours(key,nodes) {
    global MAP_GRID
    x := Mod(key,MAP_GRID), y := key//MAP_GRID, result := []
    for offset in [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]] {
        nx := x+offset[1], ny := y+offset[2]
        if nx>=0 && ny>=0 && nx<MAP_GRID && ny<MAP_GRID {
            next := ny*MAP_GRID+nx
            if nodes.Has(next)
                result.Push(next)
        }
    }
    return result
}

MapComponents(nodes) {
    seen := Map(), components := []
    for key in nodes {
        if seen.Has(key)
            continue
        queue := [key],seen[key] := true,head := 1
        while head<=queue.Length {
            for next in MapNeighbours(queue[head++],nodes) {
                if !seen.Has(next)
                    seen[next] := true,queue.Push(next)
            }
        }
        components.Push(queue)
    }
    return components
}

MapGreenMask(frame) {
    global MAP_GRID
    mask := Map()
    Loop MAP_GRID {
        gy := A_Index-1
        Loop MAP_GRID {
            gx := A_Index-1,hit := false
            for oy in [0.15,0.5,0.85] {
                for ox in [0.15,0.5,0.85] {
                    x := Min(frame.width-1,Floor((gx+ox)*frame.width/MAP_GRID))
                    y := Min(frame.height-1,Floor((gy+oy)*frame.height/MAP_GRID))
                    if IsMiniMapRouteGreen(frame.At(x,y))
                        hit := true
                }
            }
            if hit
                mask[gy*MAP_GRID+gx] := true
        }
    }
    return mask
}

MapBits(mask) {
    global MAP_GRID
    bits := ""
    Loop MAP_GRID*MAP_GRID
        bits .= mask.Has(A_Index-1) ? "1" : "0"
    return bits
}

MapFromBits(bits) {
    nodes := Map()
    Loop Parse bits {
        if A_LoopField="1"
            nodes[A_Index-1] := true
    }
    return nodes
}

MapBridgeFragments(mask,frame := 0) {
    global MAP_GRID
    components := MapComponents(mask)
    if !components.Length
        return {mask:Map(),inferred:Map()}
    largest := 1
    for index,component in components {
        if component.Length>components[largest].Length
            largest := index
    }
    main := Map(),inferred := Map()
    for key in components[largest]
        main[key] := true
    ; Only short, almost axis-aligned gaps are bridged. This covers red enemy
    ; icons on the line without connecting the map's separate parallel lanes.
    Loop 3 {
        changed := false
        for index,component in components {
            if index=largest || component.Length<3 || main.Has(component[1])
                continue
            best := 99999,from := 0,to := 0
            for a in component {
                ax := Mod(a,MAP_GRID),ay := a//MAP_GRID
                for b in main {
                    dx := Abs(ax-Mod(b,MAP_GRID)),dy := Abs(ay-b//MAP_GRID)
                    if Min(dx,dy)>1 || Max(dx,dy)>12
                        continue
                    if Max(dx,dy)>3 && (!frame || !MapGapOccluded(frame,ax,ay,Mod(b,MAP_GRID),b//MAP_GRID))
                        continue
                    distance := dx*dx+dy*dy
                    if distance<best
                        best := distance,from := a,to := b
                }
            }
            if best<99999 {
                ax := Mod(from,MAP_GRID),ay := from//MAP_GRID
                bx := Mod(to,MAP_GRID),by := to//MAP_GRID
                steps := Max(Abs(bx-ax),Abs(by-ay))
                if steps {
                    Loop steps+1 {
                        t := (A_Index-1)/steps
                        key := Round(ay+(by-ay)*t)*MAP_GRID+Round(ax+(bx-ax)*t)
                        if !mask.Has(key)
                            inferred[key] := true
                        main[key] := true
                    }
                }
                for key in component
                    main[key] := true
                changed := true
            }
        }
        if !changed
            break
    }
    return {mask:main,inferred:inferred}
}

MapGapOccluded(frame,ax,ay,bx,by) {
    global MAP_GRID
    steps := Max(Abs(bx-ax),Abs(by-ay))
    if !steps
        return false
    if frame is Map {
        ; Vision supplies a grid of cells covered by icons instead of pixels.
        Loop steps {
            t := A_Index/(steps+1)
            if frame.Has(Round(ay+(by-ay)*t)*MAP_GRID+Round(ax+(bx-ax)*t))
                return true
        }
        return false
    }
    Loop steps {
        t := A_Index/(steps+1)
        x := Round((ax+(bx-ax)*t)/(MAP_GRID-1)*(frame.width-1))
        y := Round((ay+(by-ay)*t)/(MAP_GRID-1)*(frame.height-1))
        for offset in [[0,0],[2,0],[-2,0],[0,2],[0,-2]] {
            color := frame.At(Max(0,Min(frame.width-1,x+offset[1])),Max(0,Min(frame.height-1,y+offset[2])))
            if IsUiRed(color) || IsMiniMapPlayerWhite(color)
                return true
        }
    }
    return false
}

MapThin(mask) {
    global MAP_GRID
    nodes := mask.Clone()
    Loop 18 {
        changed := false
        Loop 2 {
            phase := A_Index,remove := []
            for key in nodes {
                x := Mod(key,MAP_GRID),y := key//MAP_GRID
                if x<1 || y<1 || x>=MAP_GRID-1 || y>=MAP_GRID-1
                    continue
                p := []
                for delta in [-MAP_GRID,-MAP_GRID+1,1,MAP_GRID+1,MAP_GRID,MAP_GRID-1,-1,-MAP_GRID-1]
                    p.Push(nodes.Has(key+delta)?1:0)
                neighbours := 0,transitions := 0
                Loop 8 {
                    neighbours += p[A_Index]
                    if p[A_Index]=0 && p[Mod(A_Index,8)+1]=1
                        transitions += 1
                }
                if neighbours<2 || neighbours>6 || transitions!=1
                    continue
                if phase=1 {
                    if p[1]*p[3]*p[5] || p[3]*p[5]*p[7]
                        continue
                } else if p[1]*p[3]*p[7] || p[1]*p[5]*p[7]
                    continue
                remove.Push(key)
            }
            for key in remove
                nodes.Delete(key),changed := true
        }
        if !changed
            break
    }
    return nodes
}

MapWhiteComponents(frame) {
    white := Map(),seen := Map(),components := []
    Loop frame.height {
        y := A_Index-1
        Loop frame.width {
            x := A_Index-1
            if IsMiniMapPlayerWhite(frame.At(x,y))
                white[y*frame.width+x] := {x:x,y:y}
        }
    }
    for key,pixel in white {
        if seen.Has(key)
            continue
        queue := [pixel],seen[key] := true,head := 1
        while head<=queue.Length {
            point := queue[head++]
            for offset in [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]] {
                nx := point.x+offset[1],ny := point.y+offset[2]
                if nx<0 || ny<0 || nx>=frame.width || ny>=frame.height
                    continue
                next := ny*frame.width+nx
                if white.Has(next) && !seen.Has(next)
                    seen[next] := true,queue.Push(white[next])
            }
        }
        if queue.Length>=6 && queue.Length<=900
            components.Push(queue)
    }
    return components
}

MapMarkers(frame) {
    global MAP_GRID
    player := false,base := false,bestArrow := 0,bestHeart := 0
    scale := Max(frame.width,frame.height)/262
    for pixels in MapWhiteComponents(frame) {
        minX := 99999,minY := 99999,maxX := 0,maxY := 0,sumX := 0,sumY := 0
        for pixel in pixels {
            minX := Min(minX,pixel.x),maxX := Max(maxX,pixel.x)
            minY := Min(minY,pixel.y),maxY := Max(maxY,pixel.y)
            sumX += pixel.x,sumY += pixel.y
        }
        width := maxX-minX+1,height := maxY-minY+1
        if Max(width,height)>28*scale
            continue
        count := pixels.Length
        if count>=70*scale*scale && width/height>0.7 && width/height<1.8 {
            ; The filled heart is substantially larger than the small chevron.
            fill := count/(width*height)
            if fill>0.42 && fill<0.9 && count>bestHeart {
                bestHeart := count
                base := {x:sumX/count/(frame.width-1)*(MAP_GRID-1),y:sumY/count/(frame.height-1)*(MAP_GRID-1)}
            }
            continue
        }
        if count>140*scale*scale
            continue
        if ArrowPose(pixels,scale,scale,&px,&py,&hx,&hy,&confidence) && confidence>bestArrow {
            bestArrow := confidence
            player := {x:px/(frame.width-1)*(MAP_GRID-1),y:py/(frame.height-1)*(MAP_GRID-1),hx:hx,hy:hy}
        }
    }
    return {player:player,baseMarker:base}
}

MapNearest(nodes,x,y) {
    global MAP_GRID
    best := -1,distance := 99999
    for key in nodes {
        d := (Mod(key,MAP_GRID)-x)**2+(key//MAP_GRID-y)**2
        if d<distance
            best := key,distance := d
    }
    return best
}

MapDistances(nodes,start) {
    distances := Map(),parents := Map(),queue := [start],head := 1
    if !nodes.Has(start)
        return {distance:distances,parent:parents}
    distances[start] := 0
    while head<=queue.Length {
        key := queue[head++]
        for next in MapNeighbours(key,nodes) {
            if !distances.Has(next) {
                distances[next] := distances[key]+1,parents[next] := key
                queue.Push(next)
            }
        }
    }
    return {distance:distances,parent:parents}
}

MapShortestPath(nodes,start,target) {
    tree := MapDistances(nodes,start),result := []
    if !tree.distance.Has(target)
        return result
    key := target,result.Push(key)
    while key!=start
        key := tree.parent[key],result.InsertAt(1,key)
    return result
}

MapPlacementCheckpoints(model) {
    global MAP_GRID
    if !model.baseMarker || !model.nodes.Count
        return []
    if model.HasProp("crossings") && model.crossings.Length {
        points := MapCrossingCheckpoints(model)
        if points.Length=3
            return points
    }
    return MapRouteQuarters(model,MapNearest(model.nodes,model.baseMarker.x,model.baseMarker.y)).points
}

MapFarthestNode(nodes,start) {
    tree := MapDistances(nodes,start),far := start,longest := -1
    for node,distance in tree.distance
        if distance>longest
            far := node,longest := distance
    return far
}

; The 25/50/75% points along the route. They are the same three spots from
; either end; only their order (checkpoint 1 = furthest from the base) needs
; the base. Without a base node, the route's two far ends are used (searched
; from the node nearest the player) and the points come back unordered.
MapRouteQuarters(model,base := -1) {
    global MAP_GRID
    ; Sandstorm: checkpoint 1 is a new point halfway between the 25% and 50%
    ; marks (37.5%). It needs the base, so the share counts from the enemy end.
    first := base>=0 && SandstormWeather()?.375:.25
    if base<0 {
        seed := model.player?MapNearest(model.nodes,model.player.x,model.player.y):-1
        if seed<0
            for node in model.nodes {
                seed := node
                break
            }
        base := MapFarthestNode(model.nodes,seed)
    }
    entrance := MapFarthestNode(model.nodes,base)
    result := {points:[],ends:[entrance,base]}
    route := MapShortestPath(model.nodes,entrance,base)
    if route.Length<5
        return result
    lengths := [0],total := 0
    Loop route.Length-1 {
        a := route[A_Index],b := route[A_Index+1]
        total += Sqrt((Mod(b,MAP_GRID)-Mod(a,MAP_GRID))**2+(b//MAP_GRID-a//MAP_GRID)**2)
        lengths.Push(total)
    }
    points := []
    for share in [first,.5,.75] {
        best := 1,error := 1.0e30
        for index,length in lengths
            if Abs(length-total*share)<error
                best := index,error := Abs(length-total*share)
        if points.Length && points[points.Length]=route[best]
            return result
        points.Push(route[best])
    }
    result.points := points
    return result
}

; The base heart was hidden when the route was drawn (the player spawns
; standing on it). The macro walks toward the middle checkpoint, which is the
; same from either end, and checks the minimap again as it moves: once the
; arrow has left the heart, the heart is read whole and the checkpoints are
; numbered from it. final: the middle point was reached (or time ran out)
; with the heart still hidden; the route end nearest where the player started
; is taken as the base, since the player was standing on it.
ResolveHiddenBase(final := false) {
    global gMapModel,MAP_GRID
    if !gMapModel || !gMapModel.HasProp("baseHidden") || !gMapModel.baseHidden
        return false
    if !gMapModel.baseMarker && gMapModel.source="vision" {
        scan := VisionRequest("scan")
        if VisionOk(scan) && scan.Has("heart") {
            point := StrSplit(scan["heart"],",")
            gMapModel.baseMarker := {x:Number(point[1]),y:Number(point[2])}
        }
    }
    how := "uncovered"
    if !gMapModel.baseMarker {
        if !final
            return false
        start := gMapModel.startPoint,a := gMapModel.routeEnds[1],b := gMapModel.routeEnds[2]
        end := MapDistance(start.x,start.y,Mod(a,MAP_GRID),a//MAP_GRID)<=MapDistance(start.x,start.y,Mod(b,MAP_GRID),b//MAP_GRID)?a:b
        gMapModel.baseMarker := {x:Mod(end,MAP_GRID),y:end//MAP_GRID}
        how := "still hidden; using the route end where the player started"
    }
    gMapModel.baseHidden := false
    points := MapPlacementCheckpoints(gMapModel)
    if points.Length!=3 {
        Log("Base heart " how ", but the route could not be numbered from it; keep the current destination.")
        return false
    }
    gMapModel.checkpoints := points,gMapModel.checkpointIndex := 0,gMapModel.target := points[1]
    Log("Base heart " how " at " Round(gMapModel.baseMarker.x,1) "," Round(gMapModel.baseMarker.y,1) ": checkpoints numbered from the base; head for checkpoint 1.")
    return true
}

; Two-path maps: the purple path meets the green route at crossings and at a
; merge before the base. Checkpoint 1 is the meeting point furthest from the
; base along the route (the first crossing the enemies reach); later ones are
; the next meeting points toward the base. With fewer than three meeting
; points the rest are spread along the route from the last one to the base.
MapCrossingCheckpoints(model) {
    global MAP_GRID
    base := MapNearest(model.nodes,model.baseMarker.x,model.baseMarker.y)
    tree := MapDistances(model.nodes,base),meets := []
    for point in model.crossings {
        node := MapNearest(model.nodes,point.x,point.y)
        if node<0 || !tree.distance.Has(node)
            continue
        distance := tree.distance[node],duplicate := false
        for other in meets
            if Abs(other.distance-distance)<8
                duplicate := true
        if duplicate
            continue
        at := meets.Length+1
        for index,other in meets {
            if distance>other.distance {
                at := index
                break
            }
        }
        meets.InsertAt(at,{node:node,distance:distance})
    }
    if !meets.Length
        return []
    points := []
    for meet in meets
        if points.Length<3
            points.Push(meet.node)
    if points.Length<3 {
        route := MapShortestPath(model.nodes,points[points.Length],base),need := 3-points.Length
        if route.Length<need+2
            return []
        Loop need
            points.Push(route[Max(2,Min(route.Length,Round(route.Length*A_Index/(need+1))))])
    }
    return points
}

MapRecommendedTarget(model) {
    global MAP_GRID
    start := MapNearest(model.nodes,model.player.x,model.player.y)
    tree := MapDistances(model.nodes,start)
    baseNode := model.baseMarker ? MapNearest(model.nodes,model.baseMarker.x,model.baseMarker.y) : start
    fromBase := MapDistances(model.nodes,baseNode)
    best := start,bestScore := -99999
    for key in model.nodes {
        if !tree.distance.Has(key) || !fromBase.distance.Has(key) || fromBase.distance[key]<18
            continue
        x := Mod(key,MAP_GRID),y := key//MAP_GRID,coverage := 0
        for other in model.nodes {
            d := (x-Mod(other,MAP_GRID))**2+(y-other//MAP_GRID)**2
            if d<=14*14
                coverage += 1-d/(14*14)*0.35
        }
        score := coverage-tree.distance[key]*0.09
        if score>bestScore
            bestScore := score,best := key
    }
    return best
}

ReadMapModel(frame,archive := true) {
    return BuildMapModel(MapBridgeFragments(MapGreenMask(frame),frame),MapMarkers(frame),frame,archive)
}

; explained: cells seen as route or covered by icons (vision only), used to
; recognize a learned variant while enemies hide part of the line.
BuildMapModel(fragments,markers,frame,archive,explained := 0) {
    if fragments.mask.Count<12
        return false
    model := {frame:frame,nodes:MapThin(fragments.mask),raw:MapBits(fragments.mask),inferred:fragments.inferred,player:markers.player,baseMarker:markers.baseMarker,id:"",target:-1,manual:false,explained:explained,source:explained?"vision":"pixels"}
    model.crossings := markers.HasProp("crossings")?markers.crossings:[]
    model.threePaths := markers.HasProp("threePaths") && markers.threePaths
    if archive
        ArchiveMapModel(model)
    if model.player && model.target<0
        model.target := MapRecommendedTarget(model)
    return model
}

ParseMapPoints(text) {
    points := []
    for pair in StrSplit(text,";") {
        xy := StrSplit(pair,",")
        if xy.Length=2 && IsNumber(xy[1]) && IsNumber(xy[2])
            points.Push({x:Number(xy[1]),y:Number(xy[2])})
    }
    return points
}

MapPointsText(points) {
    text := ""
    for point in points
        text .= (text=""?"":";") Round(point.x,2) "," Round(point.y,2)
    return text
}

ArchiveMapModel(model) {
    global LEARNING_FILE
    names := MemoryRead("minimap_catalog","variants"),best := "",bestMatch := 0.78
    for name in StrSplit(names,",") {
        if name=""
            continue
        saved := MemoryRead("minimap." name,"visible_shape")
        ; A saved branch must still be visible or hidden by an icon. Raw
        ; overlap alone could keep a drawing learned from green scenery.
        covered := model.explained?OccludedShapeMatch(model.raw,model.explained,saved):0
        if model.explained && !covered
            continue
        overlap := Max(BitOverlap(model.raw,saved),covered)
        if overlap>bestMatch
            best := name,bestMatch := overlap
    }
    if best!="" {
        model.id := best
        saved := MemoryRead("minimap." best,"route")
        if StrLen(saved)=96*96
            model.nodes := MapFromBits(saved)
        if !model.baseMarker {
            base := StrSplit(MemoryRead("minimap." best,"base"),",")
            if base.Length=2
                model.baseMarker := {x:Number(base[1]),y:Number(base[2])}
        }
        ; Enemy icons can hide a crossing on this read: keep the fuller set.
        saved := ParseMapPoints(MemoryRead("minimap." best,"crossings"))
        if saved.Length>model.crossings.Length
            model.crossings := saved
        else if model.crossings.Length>saved.Length
            IniWrite MapPointsText(model.crossings),LEARNING_FILE,"minimap." best,"crossings"
        target := MemoryRead("minimap." best,"destination","-1")
        if IsNumber(target) && model.nodes.Has(Integer(target))
            model.target := Integer(target),model.manual := true
        Log("Recognized minimap variant " best "; reused its drawing.")
        return
    }
    model.id := HashText(model.raw)
    section := "minimap." model.id
    IniWrite model.raw,LEARNING_FILE,section,"visible_shape"
    IniWrite MapBits(model.nodes),LEARNING_FILE,section,"route"
    if model.baseMarker
        IniWrite Round(model.baseMarker.x,2) "," Round(model.baseMarker.y,2),LEARNING_FILE,section,"base"
    if model.crossings.Length
        IniWrite MapPointsText(model.crossings),LEARNING_FILE,section,"crossings"
    IniWrite names="" ? model.id : names "," model.id,LEARNING_FILE,"minimap_catalog","variants"
    Log("Learned minimap variant " model.id " (" model.nodes.Count " route nodes).")
}

; Mid-wave, enemy icons can hide half of the line, so overlap with a clean
; saved drawing is low. The variant still matches when nearly every visible
; cell lies on it and nearly every saved cell is visible or covered by an icon.
OccludedShapeMatch(raw,explained,saved) {
    global MAP_GRID
    if StrLen(saved)!=StrLen(raw)
        return 0
    shape := MapFromBits(saved),seen := MapFromBits(raw)
    Near(cells,key,reach) {
        x := Mod(key,MAP_GRID),y := key//MAP_GRID
        Loop reach*2+1 {
            ny := y+A_Index-1-reach
            Loop reach*2+1 {
                nx := x+A_Index-1-reach
                if nx>=0 && ny>=0 && nx<MAP_GRID && ny<MAP_GRID && cells.Has(ny*MAP_GRID+nx)
                    return true
            }
        }
        return false
    }
    if !seen.Count || !shape.Count
        return 0
    onShape := 0,covered := 0
    ; Two cells of reach: a saved stretch bridged under icons is one cell
    ; wide, while the same stretch seen uncovered is the full line width.
    for key in seen
        onShape += Near(shape,key,2)
    for key in shape
        covered += Near(explained,key,1)
    ; Scaled into BitOverlap's range: both ratios must be high to pass 0.78.
    score := Min(onShape/seen.Count,covered/shape.Count)
    return score>=0.93 ? 0.8+0.1*score : 0
}

RefreshMapPlayer(predicted := 0,radius := 10) {
    global gMapModel
    if gMapModel && gMapModel.source="vision"
        return VisionRefreshPlayer(predicted,radius)
    frame := CaptureMiniMap()
    if !frame || !frame.valid || !gMapModel
        return false
    markers := MapMarkers(frame)
    if !markers.player
        return false
    gMapModel.frame := frame,gMapModel.player := markers.player
    if markers.baseMarker
        gMapModel.baseMarker := markers.baseMarker
    return true
}

PrepTimeLeft() {
    global gPrepDeadline,PREPARATION_BUDGET_MS
    return gPrepDeadline?Max(0,gPrepDeadline-A_TickCount):PREPARATION_BUDGET_MS
}

BeginTimedPreparation() {
    global gPrepDeadline,PREPARATION_BUDGET_MS,gNavigationTimedOut
    gNavigationTimedOut := false
    gPrepDeadline := A_TickCount+PREPARATION_BUDGET_MS
    Log("Preparation budget: 50 seconds for camera setup, calibration and navigation. Timeout continues placement at the current location.")
}

FinishNavigationTimeout() {
    global gRunning,gNavigationTimedOut
    gNavigationTimedOut := gRunning && PrepTimeLeft()<=0
    if gNavigationTimedOut
        Log("Navigation time budget expired; stopped movement.")
    return false
}

NavigateDrawing() {
    global gMapModel,gMoveKeys,gNavigationTimedOut
    gNavigationTimedOut := false
    if gMapModel && gMapModel.source="vision" && gMoveKeys {
        ; Red overlay coordinates belong to the stationary placement view.
        VisionRequest("pathviewclear")
        return NavigateWithKeys()
    }
    return NavigateByHeading()
}

; Fallback without Python: turn until the chevron's shape points at the next
; waypoint, then walk forward.
NavigateByHeading() {
    global gMapModel,gRunning,gMapWalking,gMapSpeed,MAP_GRID
    if !gMapModel || !gMapModel.player || gMapModel.target<0
        return false
    gMapWalking := true,deadline := A_TickCount+PrepTimeLeft(),stuck := 0
    try {
        while gRunning && A_TickCount<deadline {
            if !RefreshMapPlayer() {
                ActionPause(120)
                if !RefreshMapPlayer() {
                    Log("Player arrow occluded; drawing retained, movement stopped.")
                    return false
                }
            }
            p := gMapModel.player,target := gMapModel.target
            if MapDistance(p.x,p.y,Mod(target,MAP_GRID),target//MAP_GRID)<2.2 {
                if ResolveHiddenBase(true)
                    continue
                Log("Reached designated point on the minimap drawing.")
                return true
            }
            start := MapNearest(gMapModel.nodes,p.x,p.y)
            sx := Mod(start,MAP_GRID),sy := start//MAP_GRID
            if MapDistance(p.x,p.y,sx,sy)>2.2 {
                ; Walk to the line from any distance; stuck checks bound it.
                wx := sx,wy := sy
            } else {
                path := MapShortestPath(gMapModel.nodes,start,target)
                if !path.Length {
                    Log("Drawing has no connected route to the destination.")
                    return false
                }
                waypoint := path[Min(5,path.Length)]
                ; Never cut across a bend: shorten until the direct segment
                ; stays within one grid cell of the traced path.
                index := Min(5,path.Length)
                while index>2 && !MapLineFollowsRoute(gMapModel.nodes,start,waypoint)
                    waypoint := path[--index]
                wx := Mod(waypoint,MAP_GRID),wy := waypoint//MAP_GRID
            }
            dx := wx-p.x,dy := wy-p.y,distance := Sqrt(dx*dx+dy*dy)
            if distance<0.6
                continue
            alignment := Max(-1,Min(1,(p.hx*dx+p.hy*dy)/distance))
            cross := p.hx*dy-p.hy*dx
            if alignment<0.95 {
                if !HoldArrow(cross>=0?"Right":"Left",Max(55,Min(450,Round(ACos(alignment)*230))))
                    return false
                ActionPause(65)
                continue
            }
            duration := Max(100,Min(550,Round(distance/Max(3,gMapSpeed)*1000*0.8)))
            if !HoldArrow("Up",duration)
                return false
            ActionPause(80)
            if RefreshMapPlayer() {
                ResolveHiddenBase()
                moved := MapDistance(p.x,p.y,gMapModel.player.x,gMapModel.player.y)
                if moved<0.45
                    stuck += 1
                else {
                    stuck := 0
                    gMapSpeed := Max(3,Min(25,gMapSpeed*0.6+moved/duration*1000*0.4))
                }
                if stuck>=3 {
                    Log("Mapped movement is blocked; no random forward/back probes sent.")
                    return false
                }
            }
        }
        return FinishNavigationTimeout()
    } finally gMapWalking := false
}

MapLineFollowsRoute(nodes,a,b) {
    global MAP_GRID
    ax := Mod(a,MAP_GRID),ay := a//MAP_GRID,bx := Mod(b,MAP_GRID),by := b//MAP_GRID
    steps := Max(Abs(bx-ax),Abs(by-ay))
    if !steps
        return true
    Loop steps+1 {
        t := (A_Index-1)/steps,x := Round(ax+(bx-ax)*t),y := Round(ay+(by-ay)*t)
        nearest := MapNearest(nodes,x,y)
        if nearest<0 || MapDistance(x,y,Mod(nearest,MAP_GRID),nearest//MAP_GRID)>1.2
            return false
    }
    return true
}

; -----------------------------------------------------------------------------
; Python minimap vision (MinimapVision.py). One request line, one reply line:
; "ok<TAB>key=value..." | "none" | "fail<TAB>reason=...". Without Python the
; AHK pixel reader above is used and navigation steers by the chevron's shape.
; -----------------------------------------------------------------------------

VisionRequest(line) {
    global gVision,gVisionFailed,gVisionRetryAt,VISION_PYTHON
    if gVisionFailed {
        if A_TickCount<gVisionRetryAt
            return false
        gVisionFailed := false,gVision := 0
    }
    ; Telemetry timers must not interleave their request with another reply.
    wasCritical := A_IsCritical
    Critical "On"
    try {
        if !gVision || gVision.Status!=0 {
            ; Keep the script/current folder and PYTHONPATH out of imports,
            ; but allow packages installed with pip --user on a laptop.
            ; -I also implies -s, which hides those user-site packages.
            gVision := ComObject("WScript.Shell").Exec(VISION_PYTHON ' -E -P -u "' A_ScriptDir '\MinimapVision.py"')
            gVision.StdIn.WriteLine("ping")
            if SubStr(gVision.StdOut.ReadLine(),1,2)!="ok"
                throw Error("no reply from MinimapVision.py")
        }
        gVision.StdIn.WriteLine(line)
        reply := gVision.StdOut.ReadLine()
    } catch as err {
        gVisionFailed := true,gVisionRetryAt := A_TickCount+10000
        try gVision.Terminate()
        gVision := 0
        Log("Python vision unavailable (" err.Message "); retry in 10 seconds. AHK minimap fallback remains available.")
        return false
    } finally Critical wasCritical
    fields := Map("status",StrSplit(reply,"`t")[1])
    for part in StrSplit(reply,"`t") {
        if A_Index>1 && (equals := InStr(part,"="))
            fields[SubStr(part,1,equals-1)] := SubStr(part,equals+1)
    }
    if fields["status"]="fail"
        Log("Minimap vision: " (fields.Has("reason")?fields["reason"]:reply))
    return fields
}

VisionOk(reply) {
    return reply && reply["status"]="ok"
}

VisionClose(*) {
    global gVision
    if gVision && gVision.Status=0 {
        try gVision.StdIn.WriteLine("quit")
        Sleep 50
        try gVision.Terminate()
    }
    gVision := 0
}

; Point the service at the minimap. The mint frame is located once per window
; size/DPI and remembered; a remembered box that shows no route is relocated.
VisionSync(relocate := false) {
    global LEARNING_FILE
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    key := cw "x" ch "." A_ScreenDPI
    saved := relocate ? "" : MemoryRead("minimap_box",key)
    if saved!="" {
        box := StrSplit(saved,",")
        return VisionOk(VisionRequest("box " cx " " cy " " box[1] " " box[2] " " box[3] " " box[4]))
    }
    guess := MiniMapBounds(cw,ch)
    reply := VisionRequest("locate " cx " " cy " " cw " " ch " " guess.left " " guess.top " " guess.right " " guess.bottom)
    if !VisionOk(reply)
        return false
    if reply["source"]="frame" {
        IniWrite reply["box"],LEARNING_FILE,"minimap_box",key
        Log("Located the minimap frame at " reply["box"] " (" key ").")
    } else
        Log("Minimap frame not found; using the proportional guess " reply["box"] ".")
    return true
}

VisionMapModel(archive := true) {
    if !VisionSync()
        return false
    scan := VisionRequest("scan")
    if VisionOk(scan) && StrLen(StrReplace(scan["route"],"0"))<12 && VisionSync(true)
        scan := VisionRequest("scan")
    return VisionOk(scan) ? VisionModelFromScan(scan,archive) : false
}

VisionModelFromScan(scan,archive := true) {
    markers := {player:false,baseMarker:false,crossings:[],threePaths:scan.Has("paths") && scan["paths"]="3"}
    if scan.Has("crossings")
        markers.crossings := ParseMapPoints(scan["crossings"])
    if scan.Has("heart") {
        point := StrSplit(scan["heart"],",")
        markers.baseMarker := {x:Number(point[1]),y:Number(point[2])}
    }
    ; Only a single chevron-sized marker is trusted without movement; the
    ; probe resolves the rest, including a chevron clipped by the frame.
    if scan.Has("player") && scan["arrows"]="1" {
        point := StrSplit(scan["player"],",")
        markers.player := {x:Number(point[1]),y:Number(point[2]),hx:0,hy:-1}
    }
    route := MapFromBits(scan["route"]),occluded := MapFromBits(scan["occluded"])
    explained := occluded.Clone()
    for key in route
        explained[key] := true
    return BuildMapModel(MapBridgeFragments(route,occluded),markers,0,archive,explained)
}

VisionSetPlayer(text) {
    global gMapModel
    point := StrSplit(text,","),x := Number(point[1]),y := Number(point[2])
    old := gMapModel.player,hx := 0,hy := -1
    if old {
        hx := old.hx,hy := old.hy,moved := MapDistance(old.x,old.y,x,y)
        ; Heading is display-only here: the last observed direction of travel.
        if moved>0.5
            hx := (x-old.x)/moved,hy := (y-old.y)/moved
    }
    gMapModel.player := {x:x,y:y,hx:hx,hy:hy}
    return true
}

VisionRefreshPlayer(predicted,radius) {
    global gMapModel
    if !VisionSync()
        return false
    point := predicted ? predicted : gMapModel.player
    if point {
        reply := VisionRequest("track " Round(point.x,2) " " Round(point.y,2) " " Round(radius,1))
        if VisionOk(reply)
            return VisionSetPlayer(reply["player"])
    }
    scan := VisionRequest("scan")
    if VisionOk(scan) && scan.Has("player") && scan["arrows"]="1"
        return VisionSetPlayer(scan["player"])
    return false
}

; -----------------------------------------------------------------------------
; Movement probe and WASD navigation. After the overhead camera is set, tap a
; key and its opposite and ask which white marker changed. That finds the
; player even at the frame edge or under an icon, and measures how W and D move
; the arrow on the minimap. Navigation then solves for W/S and D/A hold times
; directly, so no heading is read from the chevron and the camera never turns.
; -----------------------------------------------------------------------------

ProbePlayer() {
    global gMapModel,gMoveKeys,gCameraOverheadReady,LEARNING_FILE
    gMoveKeys := 0
    if !VisionSync()
        return false
    section := "minimap." gMapModel.id,profile := "keys." gCameraOverheadReady
    learned := StrSplit(MemoryRead(section,profile),",")
    known := learned.Length=4 ? {w:{x:Number(learned[1]),y:Number(learned[2])},d:{x:Number(learned[3]),y:Number(learned[4])}} : 0
    forward := ProbeKeyPair("w","s"),side := {found:false,vector:false}
    w := forward.vector,d := false
    ; A learned map whose W movement still matches skips the D/A probe.
    if known && w && MoveVectorsAgree(w,known.w)
        d := known.d
    if !d {
        side := ProbeKeyPair("d","a"),d := side.vector
        if known && d && !w && MoveVectorsAgree(d,known.d)
            w := known.w
    }
    if !forward.found && !side.found {
        Log("Movement probe: no white marker moved with W/S or D/A; player not found.")
        return false
    }
    ; One blocked axis: in a top-down view D is W turned a quarter clockwise.
    if w && !d
        d := {x:-w.y,y:w.x}
    else if d && !w
        w := {x:d.y,y:-d.x}
    if !w {
        Log("Movement probe found the player but it did not travel; keys not calibrated.")
        return false
    }
    gMoveKeys := {w:w,d:d}
    IniWrite Round(w.x,3) "," Round(w.y,3) "," Round(d.x,3) "," Round(d.y,3),LEARNING_FILE,section,profile
    Log("Player found by movement at " Round(gMapModel.player.x,1) "," Round(gMapModel.player.y,1) "; W " Round(w.x,1) "," Round(w.y,1) " D " Round(d.x,1) "," Round(d.y,1) " cells/s.")
    return true
}

ProbeKeyPair(key,opposite) {
    global PROBE_MS,PROBE_SETTLE_MS
    result := {found:false,vector:false},deltas := []
    for press in [key,opposite] {
        deltas.Push(false)
        if !VisionOk(VisionRequest("mark")) || !HoldKeys([{key:press,ms:PROBE_MS}]) || !ActionPause(PROBE_SETTLE_MS)
            return result
        reply := VisionRequest("moved")
        if !VisionOk(reply)
            continue
        VisionSetPlayer(reply["player"]),result.found := true
        if reply.Has("delta") {
            delta := StrSplit(reply["delta"],",")
            deltas[A_Index] := {x:Number(delta[1]),y:Number(delta[2])}
        }
    }
    seconds := PROBE_MS/1000
    if deltas[1] && deltas[2]
        vector := {x:(deltas[1].x-deltas[2].x)/2/seconds,y:(deltas[1].y-deltas[2].y)/2/seconds}
    else if deltas[1]
        vector := {x:deltas[1].x/seconds,y:deltas[1].y/seconds}
    else if deltas[2]
        vector := {x:-deltas[2].x/seconds,y:-deltas[2].y/seconds}
    else
        return result
    ; A tiny shift is a turn on the spot or a wall, not a usable direction.
    if MapDistance(0,0,vector.x,vector.y)>=1.5
        result.vector := vector
    return result
}

MoveVectorsAgree(a,b) {
    la := MapDistance(0,0,a.x,a.y),lb := MapDistance(0,0,b.x,b.y)
    return la && lb && (a.x*b.x+a.y*b.y)/(la*lb)>0.9 && la/lb>0.6 && la/lb<1.6
}

; Express a minimap displacement as W/S and D/A hold times (a 2x2 solve with
; the measured key vectors). 0.8 leaves the last part to the next correction;
; long moves are scaled down together so the direction is kept.
MoveDurations(dx,dy,keys,maxMs := 550,share := 0.8) {
    w := keys.w,d := keys.d,det := w.x*d.y-w.y*d.x
    if Abs(det)<0.01
        return []
    a := (dx*d.y-dy*d.x)/det,b := (w.x*dy-w.y*dx)/det
    longest := Max(Abs(a),Abs(b))*1000*share,scale := longest>maxMs ? maxMs/longest : 1
    presses := []
    for item in [[a,"w","s"],[b,"d","a"]] {
        ms := Round(Abs(item[1])*1000*share*scale)
        if ms>=40
            presses.Push({key:item[1]>=0?item[2]:item[3],ms:Max(90,ms)})
    }
    return presses
}

MovePrediction(presses,keys) {
    x := 0,y := 0
    for press in presses {
        if press.key="space"
            continue
        vector := InStr("ws",press.key) ? keys.w : keys.d
        sign := (press.key="s" || press.key="a") ? -1 : 1
        x += vector.x*sign*press.ms/1000,y += vector.y*sign*press.ms/1000
    }
    return {x:x,y:y}
}

HoldKeys(presses) {
    global gRunning,gCardAction,gCardInterruptEpoch,gMovementInterrupted
    if !gRunning || !presses.Length
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,1)
        return false
    ; A card already on screen is chosen before any movement key goes down.
    if gCardAction!="" && HasCardChoice() {
        MovementCardPause()
        return gRunning
    }
    epoch := gCardInterruptEpoch
    if !BeginInputAction() {
        if gRunning && epoch!=gCardInterruptEpoch {
            gMovementInterrupted := true
            return true
        }
        return false
    }
    held := [],started := A_TickCount,text := ""
    for press in presses
        text .= " " press.key " " press.ms "ms"
    Log("Hold" text)
    try {
        for press in presses
            Send("{" press.key " down}"),held.Push(press)
        while held.Length {
            next := 1
            for index,press in held {
                if press.ms<held[next].ms
                    next := index
            }
            if !MovementHoldUntil(started+held[next].ms,held)
                return false
            ; A card released every key: this move ends here.
            if !held.Length
                break
            Send "{" held[next].key " up}"
            held.RemoveAt(next)
        }
        return true
    } finally {
        for press in held
            Send "{" press.key " up}"
        EndInputAction()
    }
}

; Wait out a held move. A card appearing releases every held key BEFORE the
; card is chosen, so the player never keeps walking during card selection.
MovementHoldUntil(deadline,held) {
    global gRunning,gCardAction
    checkAt := 0
    while gRunning && A_TickCount<deadline {
        if gCardAction!="" && A_TickCount>=checkAt {
            checkAt := A_TickCount+100
            if HasCardChoice() {
                for press in held
                    Send "{" press.key " up}"
                held.Length := 0
                MovementCardPause()
                return gRunning
            }
        }
        Sleep Min(20,Max(1,deadline-A_TickCount))
    }
    return gRunning
}

; Choose the card with every movement key up; the walk resumes afterwards.
MovementCardPause() {
    global gMovementInterrupted,gMovementCardMs,gMovementCardTotalMs
    started := A_TickCount
    Log("Card appeared while moving; movement keys released and walking paused until the card is chosen.")
    ClearCardChoice()
    elapsed := A_TickCount-started
    gMovementInterrupted := true,gMovementCardMs += elapsed,gMovementCardTotalMs += elapsed
}

; Short settle pause between moves. A card handled here (keys are already up)
; marks the move as interrupted instead of abandoning the walk.
MovementPause(ms) {
    global gRunning,gCardInterruptEpoch,gMovementInterrupted,gMovementCardMs,gMovementCardTotalMs
    epoch := gCardInterruptEpoch,started := A_TickCount
    if ActionPause(ms)
        return true
    if gRunning && epoch!=gCardInterruptEpoch {
        elapsed := A_TickCount-started
        gMovementInterrupted := true,gMovementCardMs += elapsed,gMovementCardTotalMs += elapsed
        return true
    }
    return false
}

; Card time does not count against a walk's time budget.
TakeMovementCardMs() {
    global gMovementCardMs,gPrepDeadline
    ms := gMovementCardMs,gMovementCardMs := 0
    if ms && gPrepDeadline
        gPrepDeadline += ms
    return ms
}

NavigateWithKeys() {
    global gMapModel,gRunning,gMapWalking,gMoveKeys,gPathLit,gPreferRedPath,MAP_GRID,gMovementInterrupted
    if !gMapModel.player || gMapModel.target<0
        return false
    gMovementInterrupted := false,TakeMovementCardMs()
    gMapWalking := true,deadline := A_TickCount+PrepTimeLeft(),drift := 0
    toTarget := MapDistances(gMapModel.nodes,gMapModel.target),escape := 0,escapeFrom := 0,joining := false
    try {
        while gRunning && A_TickCount<deadline {
            if gMovementInterrupted {
                ; Resume the same destination from where the player now stands.
                gMovementInterrupted := false,escape := 0
                Log("Card chosen; resume walking the route from the player's current position.")
                if !RefreshMapPlayer() && !ProbeKeyPair("w","s").found {
                    Log("Player arrow not found after the card; stopped.")
                    return false
                }
            }
            p := gMapModel.player,target := gMapModel.target
            tx := Mod(target,MAP_GRID),ty := target//MAP_GRID
            ; A fixed spot (Sky Island) is the exact point, not the nearest line cell.
            stand := gMapModel.HasProp("standPoint")?gMapModel.standPoint:0
            if stand
                tx := stand.x,ty := stand.y
            if MapDistance(p.x,p.y,tx,ty)<(stand?1.5:2.2) {
                if ResolveHiddenBase(true) {
                    toTarget := MapDistances(gMapModel.nodes,gMapModel.target),escape := 0
                    continue
                }
                Log("Reached designated point on the minimap drawing.")
                return true
            }
            start := MapNearest(gMapModel.nodes,p.x,p.y)
            sx := Mod(start,MAP_GRID),sy := start//MAP_GRID
            ; However far the player starts from the line (spawn can be well
            ; away from it), the minimap leads it to the nearest route point;
            ; the deadline, blocked-move escapes and arrow loss bound the walk.
            if MapDistance(p.x,p.y,sx,sy)>10 && !joining
                Log("Player " Round(MapDistance(p.x,p.y,sx,sy)) " cells from the route; walking to it by the minimap.")
            joining := MapDistance(p.x,p.y,sx,sy)>10
            ; While getting around an obstacle, aim ahead along the route
            ; rather than back at the nearest point, which is the obstacle.
            if stand && MapDistance(p.x,p.y,tx,ty)<=6 {
                ; The last few cells go straight to the exact spot, even where
                ; an icon hid the line on the drawing.
                wx := tx,wy := ty
            } else if MapDistance(p.x,p.y,sx,sy)>2.2 && !escape {
                wx := sx,wy := sy
            } else {
                path := MapShortestPath(gMapModel.nodes,start,target)
                if !path.Length {
                    Log("Drawing has no connected route to the destination.")
                    return false
                }
                ; Never cut across a bend: shorten until the direct segment
                ; stays within one grid cell of the traced path.
                index := Min(6,path.Length)
                while index>2 && !MapLineFollowsRoute(gMapModel.nodes,start,path[index])
                    index -= 1
                wx := Mod(path[index],MAP_GRID),wy := path[index]//MAP_GRID
                if MapDistance(p.x,p.y,wx,wy)<0.6
                    wx := tx,wy := ty
            }
            presses := MoveDurations(wx-p.x,wy-p.y,gMoveKeys)
            if !presses.Length {
                Log("Measured W and D movements are parallel; cannot steer.")
                return false
            }
            if gPathLit && !gPreferRedPath
                presses := FollowLitPath(presses)
            expected := MovePrediction(presses,gMoveKeys),before := {x:p.x,y:p.y}
            if !HoldKeys(presses) || !MovementPause(90)
                return false
            deadline += TakeMovementCardMs()
            if gMovementInterrupted
                continue
            predicted := {x:before.x+expected.x,y:before.y+expected.y}
            if !RefreshMapPlayer(predicted,4+MapDistance(0,0,expected.x,expected.y)*0.6) {
                ; Lost under an icon or the frame: find it again by movement.
                if !ProbeKeyPair("w","s").found {
                    Log("Player arrow lost and not re-found by movement; stopped.")
                    return false
                }
                continue
            }
            ; Hidden base: re-read the minimap now the arrow has moved.
            if ResolveHiddenBase()
                toTarget := MapDistances(gMapModel.nodes,gMapModel.target),escape := 0
            ox := gMapModel.player.x-before.x,oy := gMapModel.player.y-before.y
            moved := MapDistance(0,0,ox,oy),wanted := MapDistance(0,0,expected.x,expected.y)
            ; An escape ends once the player is clearly closer along the route
            ; than where the obstacle stopped it.
            if escape && RouteProgress(toTarget,gMapModel.player)<escapeFrom-2 {
                Log("Obstacle passed.")
                escape := 0
            }
            if moved<0.45 {
                if !escape
                    escapeFrom := RouteProgress(toTarget,before)
                if ++escape>OBSTACLE_ESCAPES.Length {
                    Log("Obstacle not passed by jumping or stepping around it; stopped.")
                    return false
                }
                if !EscapeObstacle(wx-before.x,wy-before.y,escape)
                    return false
                deadline += TakeMovementCardMs()
                continue
            }
            ; Sliding along an obstacle travels off-direction too; only a move
            ; that covered most of its distance says anything about the keys.
            if moved<wanted*0.5
                continue
            ; Repeatedly travelling well off the predicted direction means the
            ; camera turned since calibration: measure the keys again.
            drift := (ox*expected.x+oy*expected.y)/(moved*wanted)<0.7 ? drift+1 : 0
            if drift>=2 {
                Log("Movement no longer matches the measured keys; probing again.")
                if !ProbePlayer()
                    return false
                drift := 0
                continue
            }
            if presses.Length=1
                LearnMoveKey(presses[1],ox,oy)
        }
        return FinishNavigationTimeout()
    } finally gMapWalking := false
}

; The route is normally clear, so a blocked move is first retried while
; jumping (Space held), then the player steps around: to one side, the other,
; then backing off before wider side steps. Each row is one attempt; each step
; is [along, side, jump] in minimap cells relative to the blocked direction,
; with along 0 meaning the blocked move's own length.
global OBSTACLE_ESCAPES := [[[0,0,1]],[[0,3,1]],[[0,-6,1]],[[-3,0,0],[0,9,1]],[[-3,0,0],[0,-12,1]],[[-5,0,0],[0,15,1]],[[-5,0,0],[0,-18,1]]]

EscapeSteps(dx,dy,attempt) {
    global OBSTACLE_ESCAPES
    length := MapDistance(0,0,dx,dy),steps := []
    if length<0.1
        return steps
    ux := dx/length,uy := dy/length
    for step in OBSTACLE_ESCAPES[attempt] {
        along := step[1]=0 && step[2]=0 ? length : step[1]
        steps.Push({x:ux*along-uy*step[2],y:uy*along+ux*step[2],jump:step[3]})
    }
    return steps
}

EscapeObstacle(dx,dy,attempt) {
    global gMapModel,gMoveKeys,gMovementInterrupted
    Log("Blocked; obstacle attempt " attempt (attempt=1?" (jump)":" (step around)") ".")
    for step in EscapeSteps(dx,dy,attempt) {
        presses := MoveDurations(step.x,step.y,gMoveKeys,1200,1.0)
        if !presses.Length
            continue
        expected := MovePrediction(presses,gMoveKeys),longest := 0
        for press in presses
            longest := Max(longest,press.ms)
        if step.jump
            presses.Push({key:"space",ms:longest})
        before := gMapModel.player
        if !HoldKeys(presses) || !MovementPause(90)
            return false
        ; A card stopped this escape; the walk resumes after re-reading the player.
        if gMovementInterrupted
            return true
        if !RefreshMapPlayer({x:before.x+expected.x,y:before.y+expected.y},4+MapDistance(0,0,expected.x,expected.y)*0.6) && !ProbeKeyPair("w","s").found {
            Log("Player arrow lost while getting around an obstacle; stopped.")
            return false
        }
    }
    return true
}

; -----------------------------------------------------------------------------
; Illuminated world path. P at the top right lights the same route the minimap
; shows. Walking on it avoids obstacles, so the minimap plan supplies the
; direction and distance and the lit path supplies the exact heading. Units
; are placed just outside it. W is screen-up and D screen-right overhead.
; -----------------------------------------------------------------------------

; A toggle receives at most one click. Subsequent reads only wait for the
; visual state to catch up; a delayed grey reading must never turn P back off.
; P is switched ON: the lit path is placement's first source (RefreshPathView)
; and steers walking (FollowLitPath). On maps with no lit path, P being on
; draws nothing, so the red no-place overlay fallback works with P left on.
; Only the P glyph is trusted (white = on, dim = off): at most one click per
; game, and an unread or unconfirmed state never stops the macro.
EnsurePathLit() {
    global gPathLit,REF_W,REF_H,gPathToggleClicked,gRunning
    if !gRunning
        return false
    gPathLit := false
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    geometry := WindowGeometry()
    if !geometry
        return false
    saved := ReadButtonRecord("PathToggle",geometry)
    if !saved {
        ; Discover once per window profile, then persist the exact coordinate.
        reply := VisionRequest("toolbar " cx " " cy " " cw " " ch)
        if VisionOk(reply) {
            point := StrSplit(reply["p"],",")
            saved := {x:geometry.cx-geometry.x+Number(point[1]),y:geometry.cy-geometry.y+Number(point[2])}
        } else {
            ButtonPosition("PathToggle",&rx,&ry)
            saved := {x:geometry.cx-geometry.x+rx*cw/REF_W,y:geometry.cy-geometry.y+ry*ch/REF_H}
        }
        SaveButtonRecord("PathToggle",saved,geometry,"fixed P coordinate")
    }
    px := saved.x-(geometry.cx-geometry.x),py := saved.y-(geometry.cy-geometry.y)
    command := "toolbarfixed " cx " " cy " " cw " " ch " " px " " py
    reply := VisionRequest(command)
    if !VisionOk(reply) {
        Log("P button unreadable; leaving P as it is. Placement still tries the lit path first.")
        return true
    }
    if reply["on"]="1" {
        Log("P is on; placement reads the lit path first, the red overlay only as fallback.")
        return gPathLit := true
    }
    if gPathToggleClicked {
        Log("P still looks off, but it was already clicked this game; no second toggle.")
        return true
    }
    ; levels = P glyph, i glyph brightness: the evidence if P is misread.
    Log("P is off (levels " reply["levels"] "); click it once to light the path.")
    if !ClickRef(px*REF_W/cw,py*REF_H/ch)
        return gRunning
    gPathToggleClicked := true
    Loop 4 {
        if !ActionPause(700) || !GetClient(&cx,&cy,&cw,&ch)
            return gRunning
        reply := VisionRequest(command)
        if VisionOk(reply) && reply["on"]="1" {
            Log("P is on; placement reads the lit path first, the red overlay only as fallback.")
            return gPathLit := true
        }
    }
    Log("P still looks off after one click (levels " (VisionOk(reply)?reply["levels"]:"unread") "); no second toggle. Placement falls back to the red overlay if no lit path shows.")
    SaveClickMissCrop("p",600,0,800,50)
    return true
}

WorldRequest(line := "",minPathFraction := 0) {
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    reply := VisionRequest("world " cx " " cy " " cw " " ch)
    if !VisionOk(reply) || reply["path"]="0" || Number(reply["path"])<cw*ch*minPathFraction
        return false
    return line="" ? reply : VisionRequest(line)
}

; Re-aim a planned W/S + D/A move along the lit path, keeping its length.
FollowLitPath(presses) {
    global LIT_PATH_MIN_FRACTION
    sx := 0,sy := 0,longest := 0
    for press in presses {
        sx += press.key="d" ? press.ms : press.key="a" ? -press.ms : 0
        sy += press.key="s" ? press.ms : press.key="w" ? -press.ms : 0
        longest := Max(longest,press.ms)
    }
    reply := WorldRequest("follow " sx " " sy,LIT_PATH_MIN_FRACTION)
    if !VisionOk(reply) || !GetClient(&cx,&cy,&cw,&ch)
        return presses
    ; The minimap leads until the player reaches the lit band (or the band
    ; lies straight ahead in the planned direction); then the band leads.
    if reply["near"]!="1" && Number(reply["align"])<0.7
        return presses
    point := StrSplit(reply["point"],",")
    return AimPresses(presses,longest,point[1]-cw/2,point[2]-ch/2)
}

; W/S and D/A holds toward a screen offset from the player, longest = ms.
AimPresses(fallback,longest,fx,fy) {
    length := MapDistance(0,0,fx,fy)
    if length<1
        return fallback
    aimed := []
    for item in [[-fy,"w","s"],[fx,"d","a"]] {
        ms := Round(Abs(item[1])/length*longest)
        if ms>=40
            aimed.Push({key:item[1]>=0?item[2]:item[3],ms:Max(90,ms)})
    }
    return aimed.Length ? aimed : fallback
}

; Placement points just outside the lit band near the player, in 800x600
; reference coordinates and inside the same safe area as the ring search.
BesidePathCandidates() {
    global REF_W,REF_H
    points := []
    reply := WorldRequest("beside 16")
    if !VisionOk(reply) || reply["points"]="" || !GetClient(&cx,&cy,&cw,&ch)
        return points
    ; Lit band magenta, tried placement points circled orange.
    VisionRequest("worlddebug " A_ScriptDir "\path-debug.png")
    for text in StrSplit(reply["points"],";") {
        point := StrSplit(text,","),x := Round(point[1]*REF_W/cw),y := Round(point[2]*REF_H/ch)
        if x>45 && x<755 && y>100 && y<495
            points.Push({x:x,y:y})
    }
    return points
}

; Uses the last world capture; without one nothing counts as on the path.
OnLitPath(rx,ry) {
    global REF_W,REF_H
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    reply := VisionRequest("onpath " Round(rx*cw/REF_W) " " Round(ry*ch/REF_H))
    return VisionOk(reply) && reply["on"]="1"
}

; Cells left to walk: route distance from the nearest node plus the gap to it.
RouteProgress(toTarget,point) {
    global gMapModel,MAP_GRID
    node := MapNearest(gMapModel.nodes,point.x,point.y)
    if node<0 || !toTarget.distance.Has(node)
        return 99999
    return toTarget.distance[node]+MapDistance(point.x,point.y,Mod(node,MAP_GRID),node//MAP_GRID)
}

; Single-key moves refine that key's measured vector.
LearnMoveKey(press,ox,oy) {
    global gMoveKeys
    sign := (press.key="s" || press.key="a") ? -1 : 1,seconds := press.ms/1000
    observed := {x:ox*sign/seconds,y:oy*sign/seconds}
    name := InStr("ws",press.key) ? "w" : "d"
    if !MoveVectorsAgree(observed,gMoveKeys.%name%)
        return
    old := gMoveKeys.%name%
    gMoveKeys.%name% := {x:old.x*0.7+observed.x*0.3,y:old.y*0.7+observed.y*0.3}
}

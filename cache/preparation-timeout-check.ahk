#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPrepDeadline := 0,PREPARATION_BUDGET_MS := 50000,gNavigationTimedOut := false,testNow := 10000
global gMapWalking := false,gMapSpeed := 8,MAP_GRID := 96,gPathLit := false,gMoveKeys := {},gMapModel := 0,holds := 0,releases := 0,resets := 0,scenario := "success"
PrepTimeLeft() {
    global gPrepDeadline,PREPARATION_BUDGET_MS
    return gPrepDeadline?Max(0,gPrepDeadline-testNow):PREPARATION_BUDGET_MS
}

BeginTimedPreparation() {
    global gPrepDeadline,PREPARATION_BUDGET_MS,gNavigationTimedOut
    gNavigationTimedOut := false
    gPrepDeadline := testNow+PREPARATION_BUDGET_MS
    Log("Preparation budget: 50 seconds for camera setup, calibration and navigation. Timeout continues placement at the current location.")
}

FinishNavigationTimeout() {
    global gRunning,gNavigationTimedOut
    gNavigationTimedOut := gRunning && PrepTimeLeft()<=0
    if gNavigationTimedOut
        Log("Preparation timer reached 50 seconds; stopped movement and will place at the current location.")
    return false
}

NavigateWithKeys() {
    global gMapModel,gRunning,gMapWalking,gMoveKeys,gPathLit,MAP_GRID
    if !gMapModel.player || gMapModel.target<0
        return false
    gMapWalking := true,deadline := testNow+PrepTimeLeft(),drift := 0
    toTarget := MapDistances(gMapModel.nodes,gMapModel.target),escape := 0,escapeFrom := 0,joining := false
    try {
        while gRunning && testNow<deadline {
            p := gMapModel.player,target := gMapModel.target
            tx := Mod(target,MAP_GRID),ty := target//MAP_GRID
            if MapDistance(p.x,p.y,tx,ty)<2.2 {
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
            if MapDistance(p.x,p.y,sx,sy)>2.2 && !escape {
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
            if gPathLit
                presses := FollowLitPath(presses)
            expected := MovePrediction(presses,gMoveKeys),before := {x:p.x,y:p.y}
            if !HoldKeys(presses) || !ActionPause(90)
                return false
            predicted := {x:before.x+expected.x,y:before.y+expected.y}
            if !RefreshMapPlayer(predicted,4+MapDistance(0,0,expected.x,expected.y)*0.6) {
                ; Lost under an icon or the frame: find it again by movement.
                if !ProbeKeyPair("w","s").found {
                    Log("Player arrow lost and not re-found by movement; stopped.")
                    return false
                }
                continue
            }
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

NavigateByHeading() {
    global gMapModel,gRunning,gMapWalking,gMapSpeed,MAP_GRID
    if !gMapModel || !gMapModel.player || gMapModel.target<0
        return false
    gMapWalking := true,deadline := testNow+PrepTimeLeft(),stuck := 0
    try {
        while gRunning && testNow<deadline {
            if !RefreshMapPlayer() {
                ActionPause(120)
                if !RefreshMapPlayer() {
                    Log("Player arrow occluded; drawing retained, movement stopped.")
                    return false
                }
            }
            p := gMapModel.player,target := gMapModel.target
            if MapDistance(p.x,p.y,Mod(target,MAP_GRID),target//MAP_GRID)<2.2 {
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
NavigateForPlacement() {
    global gRunning,gNavigationTimedOut
    if NavigateAlongRoute() {
        Log("Mapped destination reached; continuing into placement preparation.")
        return true
    }
    if !gRunning
        return false
    if !gNavigationTimedOut && PrepTimeLeft()>0 {
        Notify("Navigation stopped before timeout. Check the player arrow and green minimap line before restarting.")
        return false
    }
    gNavigationTimedOut := true
    ReleaseMovementKeys()
    ResetPlacementSearch()
    Log("Navigation time expired. Keep the current player position; use the same path-side placement and selected Hill preferences.")
    return true
}

try {
    gNavigationTimedOut := true
    BeginTimedPreparation()
    Assert(PrepTimeLeft()=50000 && !gNavigationTimedOut,"Preparation did not start with a clean 50-second allowance")
    started := testNow
    testNow += 12000
    Assert(PrepTimeLeft()=38000,"Camera/calibration time did not share the preparation budget")
    gMapModel := {player:{x:0,y:0,hx:1,hy:0},target:95,nodes:Map(0,true,95,true)}
    Assert(!NavigateWithKeys() && gNavigationTimedOut && !gMapWalking,"Navigation expiry did not set the timeout result and release walking state")
    Assert(testNow-started>=50000 && testNow-started<51000,"Navigation retained the old 24-second cap or exceeded the shared budget")
    before := holds
    Assert(!NavigateByHeading() && gNavigationTimedOut && holds=before,"Expired fallback navigation sent another movement pulse")
    gMapModel.player := {x:17,y:23,hx:1,hy:0}
    scenario := "timeout",gPrepDeadline := testNow
    Assert(NavigateForPlacement() && releases=1 && resets=1,"Timeout did not continue placement after releasing movement")
    Assert(gMapModel.player.x=17 && gMapModel.player.y=23,"Timeout moved or reset the current player location")
    scenario := "success",gNavigationTimedOut := false,gPrepDeadline := testNow+10000
    Assert(NavigateForPlacement(),"Successful navigation did not continue")
    scenario := "marker-error",gNavigationTimedOut := false
    Assert(!NavigateForPlacement(),"Non-timeout navigation failure was silently treated as a timeout")
    scenario := "late-error",gPrepDeadline := testNow
    Assert(NavigateForPlacement(),"Failure after the shared deadline did not use current-location placement")
    scenario := "stop",gNavigationTimedOut := true
    Assert(!NavigateForPlacement(),"F7/stopped navigation continued into placement")
    Assert(!FinishNavigationTimeout() && !gNavigationTimedOut,"Stopped macro was mislabeled as a timer expiry")
    FileAppend "PASS: 50-second shared preparation budget; no separate 24-second cap; both navigation paths mark expiry; current location retained; placement resumes; marker errors/F7 still stop. No vote-to-lose input.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
NavigateAlongRoute() {
    global scenario,gNavigationTimedOut,gRunning
    if scenario="success"
        return true
    if scenario="timeout"
        gNavigationTimedOut := true
    if scenario="stop"
        gRunning := false
    return false
}
ReleaseMovementKeys() {
    global releases
    releases += 1
}
ResetPlacementSearch() {
    global resets
    resets += 1
}
MapDistance(x,y,ox,oy) => Sqrt((x-ox)**2+(y-oy)**2)
MapNearest(nodes,x,y) => Round(x)
MapDistances(*) => {distance:Map()}
MapShortestPath(nodes,start,target) {
    points := []
    Loop 6
        points.Push(start+A_Index)
    return points
}
MapLineFollowsRoute(*) => true
MoveDurations(*) => [{key:"w",ms:500}]
MovePrediction(*) => {x:0.5,y:0}
HoldKeys(*) {
    global holds,testNow,gRunning
    holds += 1,testNow += 500
    return gRunning
}
HoldArrow(*) {
    throw Error("Expired heading navigation sent a movement key")
}
ActionPause(ms) {
    global testNow,gRunning
    testNow += ms
    return gRunning
}
RefreshMapPlayer(*) {
    global gMapModel
    p := gMapModel.player
    gMapModel.player := {x:p.x+0.6,y:0,hx:1,hy:0}
    return true
}
FollowLitPath(presses) => presses
LearnMoveKey(*) => 0
ProbeKeyPair(*) => {found:true}
ProbePlayer(*) => true
RouteProgress(*) => 0
EscapeObstacle(*) => true
Notify(*) => 0
Log(*) => 0

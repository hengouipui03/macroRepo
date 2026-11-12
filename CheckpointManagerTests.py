"""Actual checkpoint calculation and manager selection with simulated input."""
import subprocess
from UpgradeRegressionTests import ROOT,RUNTIME,function

route_logic='\n'.join(function('MapNavigation.ahk',n) for n in ['MapNeighbours','MapNearest','MapDistances','MapShortestPath','MapPlacementCheckpoints','MapFarthestNode','MapRouteQuarters','MapCrossingCheckpoints'])
route_logic += '\n' + function('CardContext.ahk','SandstormWeather')
route_fixture=r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global MAP_GRID := 96,gMatchWeather := ""
try {
    nodes := Map()
    Loop 81
        nodes[40*96+A_Index-1] := true
    model := {nodes:nodes,baseMarker:{x:80,y:40}}
    points := MapPlacementCheckpoints(model)
    Assert(points.Length=3 && points[1]=40*96+20 && points[2]=40*96+40 && points[3]=40*96+60,"straight route was not quartered from entrance toward base")
    ; Sandstorm: checkpoint 1 is at 35% of the route.
    gMatchWeather := "sandstorm"
    points := MapPlacementCheckpoints(model)
    gMatchWeather := "rainy"
    Assert(points.Length=3 && points[1]=40*96+28 && points[2]=40*96+40 && points[3]=40*96+60,"sandstorm checkpoint 1 was not at 35%")
    Assert(MapPlacementCheckpoints(model)[1]=40*96+20,"rain moved checkpoint 1 away from 25%")
    nodes := Map()
    Loop 41
        nodes[10*96+9+A_Index] := true
    Loop 40
        nodes[(10+A_Index)*96+50] := true
    model := {nodes:nodes,baseMarker:{x:50,y:50}}
    points := MapPlacementCheckpoints(model)
    tree := MapDistances(nodes,50*96+50)
    Assert(points.Length=3 && tree.distance[points[1]]>tree.distance[points[2]] && tree.distance[points[2]]>tree.distance[points[3]],"bent route checkpoints did not progress toward base")
    Assert(Mod(points[1],96)<50 && points[3]//96>20,"bent route used straight screen distance instead of route order")
    model.baseMarker := false
    Assert(MapPlacementCheckpoints(model).Length=0,"missing base silently invented route direction")
    ; Hidden heart (player standing on it): the same three points come from
    ; the route's ends without a base; the middle one is the same either way.
    model.player := {x:50,y:49}
    hidden := MapRouteQuarters(model)
    model.baseMarker := {x:50,y:50}
    known := MapPlacementCheckpoints(model)
    ; Within 2 cells: the two directions may split a corner differently.
    near := (a,b) => Abs(Mod(a,96)-Mod(b,96))<=2 && Abs(a//96-b//96)<=2
    Assert(hidden.points.Length=3 && near(hidden.points[2],known[2]),"hidden-base middle point differed from the numbered checkpoint 2")
    Assert((near(hidden.points[1],known[1]) && near(hidden.points[3],known[3])) || (near(hidden.points[1],known[3]) && near(hidden.points[3],known[1])),"hidden-base points were not the same three spots")
    e1 := hidden.ends[1],e2 := hidden.ends[2]
    Assert((e1=50*96+50 && e2=10*96+10) || (e1=10*96+10 && e2=50*96+50),"hidden-base route ends were not the two far ends")
    model.baseMarker := false
    ; Two-path map: the meeting points replace the quarters, first crossing
    ; (furthest from the base along the route) first, whatever order vision gave.
    nodes := Map()
    Loop 81
        nodes[40*96+A_Index-1] := true
    model := {nodes:nodes,baseMarker:{x:80,y:40},crossings:[{x:60,y:41},{x:20,y:39},{x:50,y:40}]}
    points := MapPlacementCheckpoints(model)
    Assert(points.Length=3 && points[1]=40*96+20 && points[2]=40*96+50 && points[3]=40*96+60,"two-path checkpoints were not the meeting points in route order")
    ; One meeting point: it comes first, the rest spread toward the base.
    model.crossings := [{x:30,y:40}]
    points := MapPlacementCheckpoints(model)
    Assert(points.Length=3 && points[1]=40*96+30 && points[2]>points[1] && points[3]>points[2] && points[3]<40*96+80,"a single crossing did not lead the checkpoints")
    model.crossings := []
    Assert(MapPlacementCheckpoints(model)[1]=40*96+20,"one-path maps changed")
    FileAppend "PASS: normal 25% and Sandstorm 35% waypoints; straight and bent routes; hidden-base and crossing checkpoints.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
'''

manager_logic=(ROOT/'UnitManager.ahk').read_text(encoding='utf-8-sig')
manager_logic += '\n'+function('MatchState.ahk','SetPhase')+'\n'+function('MatchState.ahk','InPhase')+'\n'+function('AAPathMacro.ahk','BeginInputAction')+'\n'+function('AAPathMacro.ahk','EndInputAction')
manager_logic=manager_logic.replace('A_TickCount','testNow')
manager_fixture=r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,UNIT_ACTION_MS := 200,REF_W := 800,REF_H := 600,gPendingPlacement := 0
global windowFocused := false
global ACTION_GAP_MS := 300,gLastInputFinishedAt := 0,gInputEpoch := 0,testNow := 10000
global gPlacements := [],managerVisible := false,scroll := 180,panel := false,wantedNumber := 0,selected := [],downs := 0,ups := 0,managerReads := 0,readFailure := false
global gUnitManagerOpen := false,gUnitManagerConfirmed := false,gPhase := "Upgrading",MATCH_PHASES := ["Idle","Lobby","Preparing","Placing","Upgrading","Watching","Ended"],gUnitManagerLastF := 0,gUnitManagerCheckAt := 0
global gUnitManagerUnconfirmedF := 0,gUnitManagerLockUntil := 0,gUnitManagerFailure := "",UNIT_MANAGER_F_COOLDOWN_MS := 2500,UNIT_MANAGER_CHECK_MS := 3000
global fPresses := 0,blindVision := false,gManagerTile := 0,gSlotPortraits := Map(),gUnitManagerClosedForCards := false
NoteManagerTileFound() {
}
try {
    ; The game lists the newest unit top-left, reading left to right, so with
    ; an odd count #1 sits alone at the bottom-LEFT (the user's 9-unit match).
    for total in [20,19,9,1] {
        gPlacements := []
        Loop total
            gPlacements.Push({id:A_Index})
        for purchaseId in [1,2,3,4,7,8,9,10,17,18,20,1] {
            if purchaseId>total
                continue
            if purchaseId=17
                windowFocused := false
            wantedNumber := purchaseId
            Assert(SelectManagedUnit(purchaseId),"manager could not select purchase " purchaseId " from " total)
            Assert(selected[selected.Length]=purchaseId && panel,"wrong reverse-order purchase selected for " purchaseId)
        }
        Assert(scroll=Max(0,(Ceil(total/2)-3)*100+20),"returning to #1 did not anchor at the manager bottom")
    }
    Assert(ups>0 && downs>=30,"bottom reset or incremental upward scrolling was not exercised")
    ; F was pressed exactly once for every selection above, and never closed.
    Assert(managerVisible && fPresses=1,"unit manager was toggled during unit switches (" fPresses " F presses)")
    gPendingPlacement := {pendingSlot:1},count := selected.Length
    Assert(!SelectManagedUnit(1) && selected.Length=count,"manager selection interfered with an unresolved purchase")
    gPendingPlacement := 0
    ; Before every unit is placed, F is never pressed.
    SetPhase("Placing"),managerVisible := false,before := fPresses,count := selected.Length
    Assert(!SelectManagedUnit(1) && fPresses=before && !managerVisible && selected.Length=count,"F was pressed before all units were placed")
    BeginUnitManagerPhase()
    Assert(InPhase("Upgrading"),"BeginUnitManagerPhase did not enter the Upgrading phase")
    ; All targets reached: the phase becomes Watching and F stays shut until a target is raised.
    EndUnitManagerPhase(),managerVisible := false,before := fPresses,count := selected.Length
    Assert(InPhase("Watching") && !SelectManagedUnit(1) && fPresses=before && !managerVisible,"F was pressed after every upgrade target was reached")
    BeginUnitManagerPhase()
    readFailure := true,count := selected.Length,before := fPresses
    Assert(!SelectManagedUnit(1) && selected.Length=count && fPresses=before,"missing manager vision caused F or an unverified portrait click")
    Assert(gUnitManagerFailure="manager","manager read failure was not reported as a manager problem")
    readFailure := false
    ; The game closed the manager: exactly one F reopens it.
    managerVisible := false,testNow += 5000,before := fPresses
    Assert(SelectManagedUnit(1) && managerVisible && fPresses=before+1,"closed manager was not reopened with exactly one F")
    ; Vision that keeps misreading an open manager as closed cannot toggle it repeatedly.
    blindVision := true,before := fPresses
    Loop 6 {
        testNow += 3000
        EnsureUnitManagerOpen()
    }
    Assert(fPresses-before<=2 && managerVisible,"misread manager state toggled F repeatedly")
    blindVision := false
    FileAppend "PASS: newest-first layout: even count #1 bottom-right/#2 bottom-left, odd count #1 alone bottom-left; upward by row; bottom reset; one-notch upward scrolling; 20/19/9/1-unit layouts; no skipped purchases; one F for the whole match; no F before placement; reopen once; misread F guard.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 800,ch := 600
    return true
}
VisionOk(state) => state && state["status"]="ok"
VisionRequest(command) {
    global managerReads
    managerReads += 1
    if readFailure
        return false
    if !managerVisible || blindVision
        return Map("status","ok","open","0")
    entries := "",first := -1,last := -1,totalRows := Ceil(gPlacements.Length/2)
    Loop totalRows {
        row := A_Index-1,y := 140+row*100-scroll
        if y>=110 && y<450 {
            if first<0
                first := y
            last := y
            if y+30-30>=100 && y+30+30<=450 {
                Loop 2 {
                    col := A_Index-1
                    candidateId := gPlacements.Length-(row*2+col)
                    if candidateId>=1
                        entries .= (entries=""?"":";") col "," (col=0?570:710) "," (y+30) "," y
                }
            }
        }
    }
    lastcount := 0
    for text in StrSplit(entries,";")
        if text!="" && StrSplit(text,",")[4]=last
            lastcount += 1
    return Map("status","ok","open","1","pitch","100","first",first,"last",last,"lastcount",lastcount,"signature",managerReads,"entries",entries,"top","100","bottom","450")
}
SendEvent(key) {
    global managerVisible,scroll,downs,ups,fPresses
    Assert(windowFocused,"manager input was sent without focusing Roblox")
    if key="{f up}"
        managerVisible := !managerVisible,fPresses += 1
    if RegExMatch(key,"Wheel(Up|Down)\s+(\d+)",&match) {
        count := Integer(match[2])
        if match[1]="Down" {
            downs += 1,scroll := Min(Max(0,(Ceil(gPlacements.Length/2)-3)*100+20),scroll+30*count)
        } else {
            Assert(count=1,"upward selection scrolling skipped more than one notch")
            ups += 1,scroll := Max(0,scroll-30)
        }
    }
}
PlacementClickRef(x,y,*) {
    global panel
    row := Round((y-170+scroll)/100),column := x>650?1:0
    purchaseId := gPlacements.Length-(row*2+column)
    Assert(purchaseId=wantedNumber,"scroll/index mapping clicked purchase " purchaseId " instead of " wantedNumber)
    selected.Push(purchaseId),panel := true
    return true
}
CloseUnitPanel(*) {
    global panel
    panel := false
    return true
}
WaitForUnitPanel(*) => panel
CancelUnitPreview(*) => true
HasCardChoice(*) => false
IsEndGameBlocking(*) => false
ReadEndScreen(*) => {stage:"none"}
ResetUpgradeSelection(*) => 0
CheckCardInterruption(*) => false
SmoothMoveTo(*) => true
FindRoblox(*) => 1
WinActive(*) => windowFocused
WinWaitActive(*) => windowFocused
WinActivate(*) {
    global windowFocused
    windowFocused := true
}
Log(*) => 0
Sleep(ms) {
    global testNow
    testNow += ms
}
ActionPause(ms,*) {
    global testNow
    testNow += ms
    return gRunning
}
'''

if __name__=='__main__':
    for name,fixture,logic in [('route-checkpoints',route_fixture,route_logic),('manager-selection',manager_fixture,manager_logic)]:
        target=ROOT/'cache'/f'{name}-regression.ahk'
        target.write_text(fixture+'\n'+logic,encoding='utf-8-sig')
        result=subprocess.run([str(RUNTIME),'/ErrorStdOut=UTF-8',str(target)],capture_output=True,timeout=30)
        print(result.stdout.decode('utf-8-sig'),end='')
        print(result.stderr.decode('utf-8-sig'),end='')
        if result.returncode:raise SystemExit(result.returncode)

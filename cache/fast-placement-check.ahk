#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPlacements := [],mode := "second",panel := false,clicks := 0,selected := 0,saved := [],currentX := 0,currentY := 0,late := false,cards := false,cardClears := 0
; Fast placement: click nearby ground beside the visible path; the unit panel
; is the only success signal. No preview analysis, OCR or path planning here.
global gFastPathPoints := []
global gFastPanelClose := 0
global gFastPendingPoint := 0

ResetFastPlacement() {
    global gFastPathPoints,gFastPendingPoint
    gFastPathPoints := [],gFastPendingPoint := 0
}

PlacementPathGreen(color) {
    RGB(color,&r,&g,&b)
    return g>175 && r>65 && b<140 && g-r>20
}

AddFastSpot(points,seen,x,y) {
    x := Round(x),y := Round(y),key := x "," y
    if x<65 || x>730 || y<145 || y>480 || seen.Has(key) || CandidateOccupied(x,y)
        return
    seen[key] := true
    points.Push({x:x,y:y})
}

NearbyPlacementOffsets() {
    return [[32,0],[-32,0],[0,28],[0,-28],[32,28],[-32,28],[32,-28],[-32,-28],
        [52,0],[-52,0],[0,48],[0,-48]]
}

FindPlacementCandidates() {
    return [{x:440,y:310},{x:470,y:330},{x:500,y:350}]
}
FastClickRef(rx,ry,guardCards := false) {
    global gRunning
    if !gRunning || !ToScreen(rx,ry,&sx,&sy)
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    MouseMove sx,sy,0
    if !ActionPause(55) || (guardCards && HasCardChoice())
        return false
    SendEvent "{LButton down}"
    try return ActionPause(60)
    finally SendEvent "{LButton up}"
}

SelectFastPlacementUnit(unit) {
    global gRunning
    if !gRunning
        return false
    SendEvent "{" unit.slot " down}"
    try {
        if !ActionPause(55)
            return false
    } finally SendEvent "{" unit.slot " up}"
    return ActionPause(65)
}

CancelUnitPreview() {
    global gRunning
    if !gRunning
        return false
    SendEvent "{q down}"
    try {
        if !ActionPause(45)
            return false
    } finally SendEvent "{q up}"
    return ActionPause(45)
}

UnitPanelColourHits(frame,x1,y1,x2,y2,predicate) {
    hits := 0,y := y1
    while y<=y2 {
        x := x1
        while x<=x2 {
            if predicate.Call(frame.AtRef(x,y))
                hits += 1
            x += 4
        }
        y += 4
    }
    return hits
}

RealHasUnitPanel(frame := 0) {
    global gFastPanelClose
    if !frame
        frame := RefPixels(5,185,300,400)
    if !frame.valid
        return false
    ; Recognize the panel layout for attackers and support units alike:
    ; gold UPG heading, red Sell button, red close X and dark statistics.
    if UnitPanelColourHits(frame,146,214,205,238,IsUiYellow)<4
        || UnitPanelColourHits(frame,25,365,140,387,IsBubbleRed)<6
        || UnitPanelColourHits(frame,258,202,294,234,IsUiRed)<6
        return false
    dark := 0
    for x in [170,190,210,230,250] {
        for y in [270,290,310,330] {
            RGB(frame.AtRef(x,y),&r,&g,&b)
            if Max(r,g,b)<110
                dark += 1
        }
    }
    if dark<10
        return false
    sumX := 0,sumY := 0,hits := 0
    Loop 17 {
        y := 200+A_Index*2
        Loop 19 {
            x := 256+A_Index*2
            if IsUiRed(frame.AtRef(x,y))
                sumX += x,sumY += y,hits += 1
        }
    }
    if hits
        gFastPanelClose := {x:Round(sumX/hits),y:Round(sumY/hits)}
    return true
}

CloseUnitPanel() {
    global gFastPanelClose
    if !HasUnitPanel()
        return true
    if !gFastPanelClose || !FastClickRef(gFastPanelClose.x,gFastPanelClose.y)
        return false
    return WaitFor(() => !HasUnitPanel(),350,30)
}

FinishFastPlacement(unit,point) {
    global gPlacements,gFastPendingPoint
    if !point
        return false
    gPlacements.Push({slot:unit.slot,name:unit.name,priority:unit.priority,target:unit.target,
        upgrades:0,x:point.x,y:point.y,complete:unit.target=0})
    RememberPlacement(unit,point,true)
    Log("Placed " unit.name " at " point.x "," point.y "; unit panel confirmed.")
    gFastPendingPoint := 0
    CloseUnitPanel()
    return true
}

TryPlacementCandidate(unit,candidate) {
    global gRunning,gFastPendingPoint
    if !gRunning
        return false
    ; A panel arriving just after the previous short wait belongs to that click.
    if gFastPendingPoint && HasUnitPanel()
        return FinishFastPlacement(unit,gFastPendingPoint)
    if HasCardChoice() {
        if !ClearCardChoice() || !SelectFastPlacementUnit(unit)
            return false
        gFastPendingPoint := 0
    }
    if !FastClickRef(candidate.x,candidate.y,true)
        return false
    gFastPendingPoint := candidate
    if WaitFor(HasUnitPanel,300,30)
        return FinishFastPlacement(unit,candidate)
    ; Misses do not cancel the preview or stop the macro. The next nearby
    ; position is clicked with the same selected unit.
    return false
}

PlaceUnit(unit) {
    global gRunning,gFastPendingPoint
    if !gRunning
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2) || !ClearCardChoice() || !CloseUnitPanel()
        return false
    gFastPendingPoint := 0
    if !CancelUnitPreview()
        return false
    points := FindPlacementCandidates()
    if !SelectFastPlacementUnit(unit)
        return false
    attempts := 0
    for point in points {
        if !gRunning
            return false
        if TryPlacementCandidate(unit,point)
            return true
        attempts += 1
        if attempts>=64
            break
    }
    if gFastPendingPoint && WaitFor(HasUnitPanel,200,30)
        return FinishFastPlacement(unit,gFastPendingPoint)
    if gRunning
        CancelUnitPreview()
    Log(unit.name ": no unit panel after " attempts " quick placement attempts; continuing.")
    return false
}

try {
    unit := {slot:3,name:"Unit 3",priority:4,target:6}
    gFastPanelClose := {x:277,y:216}
    Assert(PlaceUnit(unit),"A missed click stopped the next spot from being tried")
    Assert(gRunning && clicks=2 && selected=1 && gPlacements.Length=1,"Search did not retain the selected unit or record exactly one purchase")
    Assert(saved[1].x=470 && saved[1].y=330,"Successful position not saved")
    ResetCase("miss")
    Assert(!PlaceUnit(unit) && gRunning && clicks=3 && saved.Length=0,"Unverified click stopped the macro or was recorded as success")
    ResetCase("late")
    Assert(PlaceUnit(unit) && clicks=1 && saved[1].x=440,"Late panel lost its original click position")
    ResetCase("cards")
    Assert(PlaceUnit(unit) && selected=2 && cardClears>=1 && saved.Length=1,"Cards did not pause/reselect/resume placement")
    gRunning := false, clicks := 0
    Assert(!PlaceUnit(unit) && clicks=0,"Stop allowed another click")
    Assert(RealHasUnitPanel(PanelFrame()),"Panel controls were not recognized")
    Assert(!RealHasUnitPanel(PanelFrame(false)),"Missing UPG heading incorrectly confirmed a purchase")
    Assert(!RealHasUnitPanel(SavedFrame(A_ScriptDir "\placement-world.frame")),"World path was mistaken for a unit panel")
    FileAppend "PASS: misses continue; unit selected once; only panel-confirmed purchase saved; late panel records original spot; cards reselect/resume; stop sends no click; panel layout accepted and world rejected.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
ResetCase(nextMode) {
    global gRunning,gPlacements,mode,panel,clicks,selected,saved,late,cards,cardClears,gFastPendingPoint
    gRunning := true,gPlacements := [],mode := nextMode,panel := false,clicks := 0,selected := 0,saved := [],late := false,cards := false,cardClears := 0,gFastPendingPoint := 0
}
FindRoblox() => 1
WinActivate(*) => 0
WinWaitActive(*) => true
ToScreen(x,y,&sx,&sy) {
    sx := x,sy := y
    return true
}
MouseMove(x,y,*) {
    global currentX,currentY
    currentX := x,currentY := y
}
SendEvent(keys) {
    global currentX,currentY,panel,clicks,selected,mode,cards
    if keys="{3 down}"
        selected += 1
    if keys!="{LButton down}"
        return
    if currentX=277 && currentY=216 {
        panel := false
        return
    }
    clicks += 1
    if (mode="second" || mode="cards") && clicks=2
        panel := true
    if mode="cards" && clicks=1
        cards := true
}
ActionPause(*) => true
HasUnitPanel(*) {
    global panel,late
    if late
        panel := true,late := false
    return panel
}
HasCardChoice(*) {
    global cards
    return cards
}
ClearCardChoice(*) {
    global cards,cardClears
    if cards
        cardClears += 1,cards := false
    return true
}
WaitFor(test,*) {
    global mode,clicks,late
    if mode="late" && clicks=1 {
        late := true
        return false
    }
    return test.Call()
}
RememberPlacement(unit,point,success) {
    global saved
    if !success
        throw Error("Miss must not be learned as success")
    saved.Push(point)
}
Log(*) => 0
CandidateOccupied(*) => false
class RefPixels {
    __New(*) {
        throw Error("Offline panel test requires an explicit frame")
    }
}
class PanelFrame {
    valid := true
    __New(gold := true) {
        this.gold := gold
    }
    AtRef(x,y) {
        if x>=258 && x<=294 && y>=202 && y<=234
            return 0xF02020
        if x>=82 && x<=136 && y>=365 && y<=387
            return 0xD32A2A
        if this.gold && x>=146 && x<=205 && y>=214 && y<=238
            return 0xF2CB30
        return 0x191B20
    }
}
class SavedFrame {
    valid := true
    __New(path) {
        this.storage := FileRead(path,"RAW")
        this.w := NumGet(this.storage,0,"UInt"),this.h := NumGet(this.storage,4,"UInt")
    }
    AtRef(x,y) {
        px := Round(x*this.w/800),py := Round(y*this.h/600)
        return NumGet(this.storage,8+4*(py*this.w+px),"UInt") & 0xFFFFFF
    }
}

RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}

IsBubbleBlue(color) {
    RGB(color, &r, &g, &b)
    return b > 150 && g > 110 && (b-r)>55 && (g-r)>25
}

IsBubbleRed(color) {
    RGB(color, &r, &g, &b)
    return r > 160 && g < 175 && b < 150 && (r - g) > 45
}

IsUiRed(color) {
    RGB(color, &r, &g, &b)
    return r > 180 && g < 100 && b < 105
}

IsUiYellow(color) {
    RGB(color, &r, &g, &b)
    return r > 185 && g > 135 && b < 115
}

WinActive(*) => true

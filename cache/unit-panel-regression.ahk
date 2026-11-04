
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gUnitPanelLayout := 0,gUnitPanelClose := 0,REF_W := 800,REF_H := 600,reads := 0
try {
    if HasUnitPanel()
        throw Error("fixture unexpectedly matched the old fixed panel position")
    if !WaitForUnitPanel(10)
        throw Error("panel was not learned from UPG/Sell/Upgrade on the other layout")
    if !HasUnitPanel() || !UnitUpgradeButtonReady()
        throw Error("learned panel/button regions were not reused")
    previous := reads
    if !WaitForUnitPanel(10) || reads!=previous
        throw Error("known panel performed OCR again instead of reusing its regions")
    state := ParseUpgradeState(ReadOcrRows(),{cw:1280,ch:720})
    if state.level!=7
        throw Error("UPG 7 did not parse at the learned heading location")
    FileAppend "PASS: different-device UPG/Sell/Upgrade layout learned once; shared pixel detector and readiness checks reuse it; exact UPG 7 parsed at learned position.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack,"*"
    ExitApp 1
}
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 1280,ch := 720
    return true
}
WaitFor(test,*) => test.Call()
HasCardChoice(*) => false
Log(*) => 0
ReadOcrRows(*) {
    global reads
    reads += 1
    return [{x:224,y:360,w:112,h:24,text:"UPG [7]"},
            {x:40,y:516,w:184,h:36,text:"Sell: 1000 Yen"},
            {x:256,y:516,w:176,h:48,text:"Upgrade: 3000 Yen"}]
}
class RefPixels {
    valid := true
    __New(*) {
    }
    AtRef(x,y) {
        if x>=140 && x<=210 && y>=300 && y<=320
            return 0xFFD520
        if x>=25 && x<=140 && y>=430 && y<=460
            return 0xEE3030
        if x>=160 && x<=270 && y>=430 && y<=470
            return 0x20DD30
        return 0x151515
    }
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
HasUnitPanel(frame := 0) {
    global gUnitPanelClose,gUnitPanelLayout
    if gUnitPanelLayout {
        heading := UnitPanelRegion("header"),sell := UnitPanelRegion("sell")
        learned := frame?frame:RefPixels(Min(heading[1],sell[1]),Min(heading[2],sell[2]),Max(heading[3],sell[3]),Max(heading[4],sell[4]))
        if learned.valid && UnitPanelColourHits(learned,heading[1],heading[2],heading[3],heading[4],IsUiYellow)>=4
            && UnitPanelColourHits(learned,sell[1],sell[2],sell[3],sell[4],IsBubbleRed)>=4
            return true
    }
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
        gUnitPanelClose := {x:Round(sumX/hits),y:Round(sumY/hits)}
    return true
}
UnitPanelRegion(name) {
    global gUnitPanelLayout
    if gUnitPanelLayout && GetClient(&cx,&cy,&cw,&ch) && gUnitPanelLayout.size=cw "," ch
        return gUnitPanelLayout.%name%
    defaults := Map("header",[137,210,215,246],"button",[145,340,265,395],"sell",[25,365,140,387])
    return defaults[name]
}
WaitForUnitPanel(timeout := 700,learn := true) {
    global gRunning,gUnitPanelLayout,REF_W,REF_H
    if WaitFor(HasUnitPanel,timeout,60)
        return true
    if !learn || !gRunning || HasCardChoice() || !GetClient(&cx,&cy,&cw,&ch)
        return false
    header := 0,sell := 0,button := 0
    for row in ReadOcrRows(0,100,340,520) {
        text := NormalizeWords(row.text)
        rect := [Max(0,Floor(row.x*REF_W/cw)-6),Max(0,Floor(row.y*REF_H/ch)-6),
            Min(340,Ceil((row.x+row.w)*REF_W/cw)+10),Min(520,Ceil((row.y+row.h)*REF_H/ch)+6)]
        if RegExMatch(text,"\bu\s*p\s*[g69](?:\s|$|[0-9])") {
            rect[3] := Min(340,Max(rect[3],rect[1]+78))
            header := rect
        }
        if RegExMatch(text,"\bsell\b")
            sell := rect
        if RegExMatch(text,"\bupgrade\b|^max(?:ed)?$")
            button := rect
    }
    if !header || !sell || !button || HasCardChoice()
        return false
    gUnitPanelLayout := {size:cw "," ch,header:header,sell:sell,button:button}
    Log("Learned unit panel header and buttons for this device/window.")
    return HasUnitPanel()
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
NormalizeWords(text) {
    for code in [0x2212,0x2010,0x2011,0x2012,0x2013,0x2014,0xFE63,0xFF0D]
        text := StrReplace(text,Chr(code),"-")
    text := Trim(RegExReplace(StrLower(text), "[^a-z0-9%+.-]+", " "))
    text := RegExReplace(text,"\b(?:mogic|maglc)\b","magic")
    text := RegExReplace(text,"\b(?:resistmce|resistarw)\b","resistance")
    return RegExReplace(text,"\bspee\b","speed")
}
RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}
IsUiYellow(color) {
    RGB(color, &r, &g, &b)
    return r > 185 && g > 135 && b < 115
}
IsBubbleRed(color) {
    RGB(color, &r, &g, &b)
    return r > 160 && g < 175 && b < 150 && (r - g) > 45
}
IsUiRed(color) {
    RGB(color, &r, &g, &b)
    return r > 180 && g < 100 && b < 105
}
IsUiGreen(color) {
    RGB(color, &r, &g, &b)
    return g > 150 && r < 150 && b < 155 && (g - r) > 45
}
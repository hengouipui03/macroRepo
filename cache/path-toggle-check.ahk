#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gPathToggleClicked := false
global gPathLit := false,REF_W := 800,REF_H := 600,clicks := 0,reads := 0,pauses := 0,mode := "delayed",running := true
; A toggle receives at most one click. Subsequent reads only wait for the
; visual state to catch up; a delayed grey reading must never turn P back off.
EnsurePathLit() {
    global gPathLit,REF_W,REF_H,gPathToggleClicked,gRunning
    if !gRunning
        return false
    gPathLit := false
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    reply := VisionRequest("toolbar " cx " " cy " " cw " " ch)
    if !VisionOk(reply) {
        Log("P glyph was not found in the top-right toolbar; path illumination is not confirmed.")
        return false
    }
    if reply["on"]="1" {
        Log("In-game path is already illuminated; leaving P enabled.")
        return gPathLit := true
    }
    if gPathToggleClicked {
        Log("P was already clicked this game; no second toggle will be sent.")
        return false
    }
    point := StrSplit(reply["p"],",")
    Log("P is grey; clicking once, then waiting without toggling again.")
    if !ClickRef(point[1]*REF_W/cw,point[2]*REF_H/ch)
        return false
    gPathToggleClicked := true
    Loop 4 {
        if !ActionPause(700) || !GetClient(&cx,&cy,&cw,&ch)
            return false
        reply := VisionRequest("toolbar " cx " " cy " " cw " " ch)
        if VisionOk(reply) && reply["on"]="1" {
            Log("In-game path is illuminated (P lit).")
            return gPathLit := true
        }
    }
    Log("P clicked once; visual confirmation delayed. No second toggle sent.")
    return false
}
try {
    Assert(EnsurePathLit() && clicks=1 && reads=4,"Delayed toolbar caused a repeated click or no confirmation")
    gPathToggleClicked := false,mode := "on",clicks := 0,reads := 0
    Assert(EnsurePathLit() && clicks=0 && gPathLit,"Already enabled P was toggled")
    gPathToggleClicked := false,mode := "grey",clicks := 0,reads := 0
    Assert(!EnsurePathLit() && clicks=1 && reads=5,"Stale grey frames toggled P twice")
    Assert(!EnsurePathLit() && clicks=1,"A second EnsurePathLit call toggled P off again")
    gPathToggleClicked := false,mode := "missing-after",clicks := 0,reads := 0
    Assert(!EnsurePathLit() && clicks=1,"Missing post-click frames caused another toggle")
    gPathToggleClicked := false,mode := "missing",clicks := 0,reads := 0
    Assert(!EnsurePathLit() && clicks=0,"Missing P received a blind click")
    gPathToggleClicked := false,mode := "grey",clicks := 0,reads := 0,running := false,gRunning := false
    Assert(!EnsurePathLit() && clicks=0,"Stopped macro toggled P")
    FileAppend "PASS: delayed/grey/missing toolbar frames never cause a second P click; already enabled P stays enabled; stop respected.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n","*"
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
VisionRequest(*) {
    global mode,reads
    reads += 1
    if mode="missing" || (mode="missing-after" && reads>1)
        return false
    return Map("on",mode="on" || (mode="delayed" && reads>=4)?"1":"0","p","710,18")
}
VisionOk(reply) => IsObject(reply)
ClickRef(*) {
    global clicks,running
    if !running
        return false
    clicks += 1
    return true
}
ActionPause(*) {
    global pauses,running
    pauses += 1
    return running
}
Log(*) => 0

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gMapModel := 0,gCameraOverheadReady := false,gPathToggleClicked := true,mode := "vision",pChecks := 0,camera := 0
EnsureRouteAndSpawn() {
    global gMapModel,gCameraOverheadReady,gPathToggleClicked
    gCameraOverheadReady := false,gPathToggleClicked := false
    gMapModel := VisionMapModel()
    if !gMapModel {
        frame := CaptureMiniMap()
        if frame && frame.valid
            gMapModel := ReadMapModel(frame)
    }
    if !gMapModel {
        Log("No green route in the bottom-right minimap capture; world illumination is not checked.")
        return false
    }
    ; What vision read this match: route magenta, heart red, player blue.
    if gMapModel.source="vision"
        VisionRequest("debug " A_ScriptDir "\minimap-debug.png")
    BeginTimedPreparation()
    ; The P toolbar is independent of which reader supplied the minimap.
    if !EnsurePathLit() {
        Log("Cannot confirm P/path illumination. Stopped before navigation and placement.")
        return false
    }
    ; Even fallback minimap detection must enable P before checking the arrow.
    if gMapModel.source!="vision" && !gMapModel.player {
        Log("Minimap route drawn, but the small player chevron was not found. Heart is the base.")
        return false
    }
    if !CameraReset()
        return false
    if gMapModel.source!="vision"
        return RefreshMapPlayer()
    if !ProbePlayer()
        return false
    if gMapModel.target<0
        gMapModel.target := MapRecommendedTarget(gMapModel)
    return true
}

try {
    Assert(EnsureRouteAndSpawn() && pChecks=1 && camera=1,"Vision preparation skipped P")
    mode := "fallback",pChecks := 0,camera := 0
    Assert(EnsureRouteAndSpawn() && pChecks=1 && camera=1,"Fallback minimap skipped P")
    mode := "no-arrow",pChecks := 0,camera := 0
    Assert(!EnsureRouteAndSpawn() && pChecks=1 && camera=0,"Missing fallback arrow skipped the P check")
    mode := "p-missing",pChecks := 0,camera := 0
    Assert(!EnsureRouteAndSpawn() && pChecks=1 && camera=0,"Preparation continued without confirmed P")
    FileAppend "PASS: P checked on vision and fallback minimaps, even before a missing-arrow failure; unconfirmed P prevents navigation/placement; new game resets one-click guard.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n","*"
    ExitApp 1
}
Assert(ok,msg) {
    if !ok
        throw Error(msg)
}
VisionMapModel() {
    global mode
    return mode="vision" || mode="p-missing"?{source:"vision",player:1,target:0}:0
}
CaptureMiniMap(*) => {valid:true}
ReadMapModel(*) {
    global mode
    return {source:"pixels",player:mode="no-arrow"?0:1,target:0}
}
VisionRequest(*) => 0
BeginTimedPreparation(*) => 0
EnsurePathLit() {
    global pChecks,gPathToggleClicked,mode
    Assert(!gPathToggleClicked,"New game did not reset toggle guard")
    pChecks += 1
    return mode!="p-missing"
}
CameraReset(*) {
    global camera
    camera += 1
    return true
}
RefreshMapPlayer(*) => true
ProbePlayer(*) => true
MapRecommendedTarget(*) => 0
Log(*) => 0

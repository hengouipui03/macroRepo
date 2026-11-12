; The P button at the top right of the toolbar: the path light. When it is on
; (the "P" glyph white and filled; off = dim grey) the game draws the route as a
; lit path in the world, which placement reads first (RefreshPathView) and
; walking follows (FollowLitPath). The P KEY does nothing in the game; P is
; toggled only by CLICKING the toolbar button, at its saved coordinate.
;
; EnsurePathLight(context) runs at Vote Start ("vote") and again when placing
; starts ("placing"). Two signals exist: the glyph (is the toggle on?) and the
; effect (a lit path really read by the world reader). Per minimap variant the
; macro learns whether a lit path was ever seen (learning.ini, section
; [minimap.<id>], key lit_path), because many maps draw nothing at all.
;
; At "placing" the lit path is looked for FIRST, whatever the glyph reads. A
; lit path that is detected means P is on: P is never clicked then.
;   glyph off        click P (only when no lit path is detected), verify by
;                    glyph polls; at most PATH_CLICK_LIMIT clicks per call. A
;                    click that left the glyph unchanged did not register and is
;                    repeated; a click that changed the glyph by
;                    PATH_TOGGLE_CHANGE toggled it, so no further click is sent
;                    in that call (it could switch P off again). That toggle is
;                    remembered for the match: when the glyph still reads off at
;                    "placing" but sits where the toggle left it, P is not
;                    clicked again.
;   glyph on         nothing, except at "placing" when this variant is known to
;                    show a lit path and none is read now: one verified off-on
;                    cycle (two clicks, each verified by the glyph), once per
;                    match.
;   glyph unreadable log and carry on; placement falls back to the red overlay.
; The click-miss crop (SaveClickMissCrop) is kept as the diagnostic.

; P clicks per call while the glyph stays unchanged, and the P-glyph brightness
; change that proves a click registered.
global PATH_CLICK_LIMIT := 3,PATH_TOGGLE_CHANGE := 25
; After a click: glyph reads, PATH_GLYPH_POLL_MS apart.
global PATH_GLYPH_POLLS := 4,PATH_GLYPH_POLL_MS := 700
; A lit path counts once it covers this share of the client: real lit paths
; measure 2.4-5% in the fixtures, maps without one read 0.
global LIT_PATH_MIN_FRACTION := 0.01
; Waits inside EnsurePathLight: after the off-on cycle before the lit path is
; read, and the path-view settle.
global PATH_LIT_SETTLE_MS := 400
; Per-match state of this module (ResetPathLight): the glyph read lit at the
; last EnsurePathLight; the off-on cycle was used; this variant's lit path was
; recorded; the P glyph levels {before,after} of a click that registered
; (changed the glyph) without the glyph reading on, or 0.
global gPathGlyphOn := false,gPathCycleDone := false,gLitPathRecorded := false,gPathToggle := 0

ResetPathLight() {
    global gPathGlyphOn,gPathCycleDone,gLitPathRecorded,gPathToggle
    gPathGlyphOn := false,gPathCycleDone := false,gLitPathRecorded := false,gPathToggle := 0
}

; True when the glyph read lit at the last EnsurePathLight (walking then
; follows the lit path).
PathLightOn() {
    global gPathGlyphOn
    return gPathGlyphOn
}

; The decision, pure. glyph is "on", "off" or "unread"; context "vote" or
; "placing"; variantLit: this minimap variant is known to show a lit path;
; litSeen: a lit path is read now (only asked at "placing"); cycleDone: the
; off-on cycle was already used this match; toggleHeld: a click earlier this
; match already moved the glyph and it still sits there (only meaningful at
; "placing"). Returns "click", "cycle", "none" or "unreadable". A lit path that
; is detected is never clicked, whatever the glyph says.
PathLightAction(glyph,context,variantLit,litSeen,cycleDone,toggleHeld) {
    if context="placing" && litSeen
        return "none"
    if glyph="unread"
        return "unreadable"
    if glyph="off"
        return context="placing" && toggleHeld ? "none" : "click"
    if context="placing" && variantLit && !litSeen && !cycleDone
        return "cycle"
    return "none"
}

; Learned per minimap variant, in the same ini and section as the variant's
; drawing (see ArchiveMapModel).
VariantShowsLitPath() {
    global gMapModel
    if !gMapModel || gMapModel.id=""
        return false
    return MemoryRead("minimap." gMapModel.id,"lit_path","0")="1"
}

RecordLitPathSeen() {
    global gMapModel,gLitPathRecorded,LEARNING_FILE
    if gLitPathRecorded || !gMapModel || gMapModel.id=""
        return
    gLitPathRecorded := true
    if VariantShowsLitPath()
        return
    IniWrite "1",LEARNING_FILE,"minimap." gMapModel.id,"lit_path"
    Log("Learned that minimap variant " gMapModel.id " shows a lit path.")
}

; The lit path as the world reader sees it now: the reply, or false when it
; covers too little of the client (maps without a lit path read 0). A path that
; reads is recorded for the current minimap variant.
ReadLitPath() {
    global LIT_PATH_MIN_FRACTION
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    lit := VisionRequest("world " cx " " cy " " cw " " ch)
    if VisionOk(lit) && Number(lit["path"])>=cw*ch*LIT_PATH_MIN_FRACTION {
        RecordLitPathSeen()
        return lit
    }
    return false
}

; The P button: its saved fixed coordinate (found by vision once per window
; profile, then persisted) and the vision command that reads its glyph.
; {px,py,cw,ch,command} (client pixels), or false without a client window.
PathButtonTarget() {
    global REF_W,REF_H
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
    return {px:px,py:py,cw:cw,ch:ch,command:"toolbarfixed " cx " " cy " " cw " " ch " " px " " py}
}

; One glyph read: {state:"on"|"off"|"unread",level,levels}. levels = P glyph,
; i glyph brightness: the evidence if P is misread; level is the P glyph's.
ReadPathGlyph(button) {
    reply := VisionRequest(button.command)
    if !VisionOk(reply)
        return {state:"unread",level:-1,levels:""}
    levels := reply.Has("levels")?reply["levels"]:""
    first := StrSplit(levels,",")[1]
    return {state:reply["on"]="1"?"on":"off",level:IsNumber(first)?Number(first):-1,levels:levels}
}

ClickPathButton(button) {
    global REF_W,REF_H
    return ClickRef(button.px*REF_W/button.cw,button.py*REF_H/button.ch)
}

; Clicks P until the glyph reads want ("on" or "off"): at most PATH_CLICK_LIMIT
; clicks, each followed by up to PATH_GLYPH_POLLS glyph reads. startLevel is
; the P glyph level before the first click. Returns the last glyph read, or
; state "stopped" when the run stopped or the window was lost.
ClickUntilGlyph(button,want,startLevel) {
    global PATH_CLICK_LIMIT,PATH_TOGGLE_CHANGE,PATH_GLYPH_POLLS,PATH_GLYPH_POLL_MS
    glyph := {state:"unread",level:-1,levels:""}
    Loop PATH_CLICK_LIMIT {
        if A_Index>1
            Log("P glyph unchanged (levels " glyph.levels "); the click did not register. Click P again (" A_Index "/" PATH_CLICK_LIMIT ").")
        if !ClickPathButton(button)
            return {state:"stopped",level:-1,levels:""}
        Loop PATH_GLYPH_POLLS {
            if !ActionPause(PATH_GLYPH_POLL_MS) || !GetClient(&cx,&cy,&cw,&ch)
                return {state:"stopped",level:-1,levels:""}
            glyph := ReadPathGlyph(button)
            if glyph.state=want
                return glyph
        }
        if glyph.state="unread"
            return glyph
        ; The glyph changed but does not read as wanted: a toggle happened, so a
        ; further click could undo it. Stop clicking in this call.
        if startLevel>=0 && glyph.level>=0 && Abs(glyph.level-startLevel)>=PATH_TOGGLE_CHANGE
            return glyph
    }
    return glyph
}

; True when an earlier click this match registered (moved the glyph by
; PATH_TOGGLE_CHANGE) without it reading on, and the glyph still sits nearer the
; level that click left than the level it started from: a further click would
; only toggle it back.
PathToggleStillHeld(glyph) {
    global gPathToggle
    if !IsObject(gPathToggle) || glyph.level<0
        return false
    return Abs(glyph.level-gPathToggle.after)<Abs(glyph.level-gPathToggle.before)
}

; Called at Vote Start (context "vote") and at the start of Placing ("placing").
; Never stops the macro: true unless the run stopped or Roblox is gone.
EnsurePathLight(context) {
    global gRunning,gPathGlyphOn,gPathCycleDone,gPathToggle,PATH_LIT_SETTLE_MS,PATH_TOGGLE_CHANGE
    if context!="vote" && context!="placing" {
        Log("EnsurePathLight: unknown context '" context "'; P left as it is.")
        return gRunning
    }
    if !gRunning
        return false
    gPathGlyphOn := false
    button := PathButtonTarget()
    if !button
        return false
    glyph := ReadPathGlyph(button)
    ; At "placing" the world is read first: a lit path means P is on.
    litSeen := context="placing" && ReadLitPath()?true:false
    toggleHeld := context="placing" && PathToggleStillHeld(glyph)
    action := PathLightAction(glyph.state,context,VariantShowsLitPath(),litSeen,gPathCycleDone,toggleHeld)
    if action="none" && litSeen && glyph.state!="on" {
        gPathGlyphOn := true
        Log("A lit path is detected although the P glyph reads " glyph.state "; P is left as it is.")
        return true
    }
    if action="none" && toggleHeld && glyph.state="off" {
        Log("P glyph reads off (levels " glyph.levels ") but it sits where the click at Vote Start left it; no second click.")
        return true
    }
    if action="unreadable" {
        Log("P button unreadable; leaving P as it is. Placement still tries the lit path first, then the red overlay.")
        return true
    }
    if action="none" {
        gPathGlyphOn := glyph.state="on"
        Log("P is on; placement reads the lit path first, the red overlay only as fallback.")
        return true
    }
    if action="click" {
        Log("P is off (levels " glyph.levels "); click it to light the path (" context ").")
        result := ClickUntilGlyph(button,"on",glyph.level)
        if result.state="stopped"
            return gRunning
        if result.state!="on" && glyph.level>=0 && result.level>=0 && Abs(result.level-glyph.level)>=PATH_TOGGLE_CHANGE
            gPathToggle := {before:glyph.level,after:result.level}
        if result.state="on" {
            gPathGlyphOn := true
            Log("P is on; placement reads the lit path first, the red overlay only as fallback.")
            return true
        }
        Log("P still looks off (levels " (result.state="unread"?"unread":result.levels) "). Placement falls back to the red overlay if no lit path shows.")
        SaveClickMissCrop("p",600,0,800,50)
        return true
    }
    ; cycle: P reads on, this map variant is known to show a lit path, none is
    ; read: switch P off and on once (each click verified by the glyph).
    gPathCycleDone := true
    Log("P reads on and this minimap variant is known to show a lit path, but none is visible; switch P off and on once.")
    off := ClickUntilGlyph(button,"off",glyph.level)
    if off.state="stopped"
        return gRunning
    if off.state!="off" {
        gPathGlyphOn := true
        Log("P did not switch off (levels " (off.state="unread"?"unread":off.levels) "); leaving it on.")
        return true
    }
    on := ClickUntilGlyph(button,"on",off.level)
    if on.state="stopped"
        return gRunning
    if on.state!="on" {
        Log("P did not switch back on (levels " (on.state="unread"?"unread":on.levels) "). Placement falls back to the red overlay if no lit path shows.")
        SaveClickMissCrop("p",600,0,800,50)
        return true
    }
    gPathGlyphOn := true
    if ActionPause(PATH_LIT_SETTLE_MS) && ReadLitPath()
        Log("P is on again and the lit path shows.")
    else
        Log("P is on again but no lit path shows; the red overlay is the fallback.")
    return true
}

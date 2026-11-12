"""PathLight: the P button is clicked (never pressed), verified by its glyph.
The decision matrix glyph (on/off/unreadable) x variant known to show a lit
path (yes/no) x lit path detected (yes/no) for both contexts ("vote" at Vote
Start, "placing" at the start of Placing), run through EnsurePathLight with
a simulated glyph and world reader; the learned per-variant flag; the
once-per-match off-on cycle; click bounds. Nothing touches the screen."""
import re
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

NAMES = ["ResetPathLight", "PathLightOn", "PathLightAction", "VariantShowsLitPath", "RecordLitPathSeen", "ReadLitPath",
         "PathButtonTarget", "ReadPathGlyph", "ClickPathButton", "ClickUntilGlyph", "EnsurePathLight"]
logic = "\n".join(function("PathLight.ahk", n) for n in NAMES)
logic += "\n" + function("Learning.ahk", "MemoryRead")

# No P KEY anywhere: P is toggled only by clicking the toolbar button.
for source in ROOT.glob("*.ahk"):
    if "before-learning" in source.name or source.name == "VisionLauncher.check.tmp.ahk":
        continue
    for number, line in enumerate(source.read_text(encoding="utf-8-sig").splitlines(), 1):
        if re.search(r"\bSend(Event|Input|Play)?\b", line, re.I) and re.search(r'\{p[ }]|"p"|"\{?p\}?"', line, re.I):
            raise SystemExit(f"FAIL: {source.name}:{number} sends the P key: {line.strip()}")

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,REF_W := 800,REF_H := 600
global PATH_CLICK_LIMIT := 3,PATH_TOGGLE_CHANGE := 25,PATH_GLYPH_POLLS := 4,PATH_GLYPH_POLL_MS := 700,LIT_PATH_MIN_FRACTION := 0.01
global gPathGlyphOn := false,gPathCycleDone := false,gLitPathRecorded := false
global LEARNING_FILE := A_ScriptDir "\path-light-matrix.ini"
global gMapModel := {id:"abc123"},logs := []
global glyphOn := false,glyphReadable := true,litVisible := false,ignoreClicks := 0,clicks := 0,worldReads := 0,crops := 0,savedP := {x:723,y:51}
try {
    if FileExist(LEARNING_FILE)
        FileDelete LEARNING_FILE
    ; ---- the pure decision: 3 glyph states x variant x lit x 2 contexts ----
    count := 0
    for glyph in ["on","off","unread"]
        for variant in [false,true]
            for lit in [false,true]
                for context in ["vote","placing"] {
                    got := PathLightAction(glyph,context,variant,lit,false)
                    want := glyph="unread" ? "unreadable" : glyph="off" ? "click" : (context="placing" && variant && !lit) ? "cycle" : "none"
                    Assert(got=want,"PathLightAction(" glyph "," context ",variant " variant ",lit " lit ") = " got ", expected " want)
                    ; the cycle is used once per match
                    Assert(PathLightAction(glyph,context,variant,lit,true)!="cycle","the off-on cycle was offered twice")
                    count += 1
                }
    Assert(count=24,"matrix incomplete")

    ; ---- the same matrix end to end (clicks sent, final glyph, cycle) ----
    for glyph in ["on","off","unread"]
        for variant in [false,true]
            for lit in [false,true]
                for context in ["vote","placing"] {
                    Fresh(variant)
                    glyphOn := glyph="on",glyphReadable := glyph!="unread",litVisible := lit
                    Assert(EnsurePathLight(context),"EnsurePathLight stopped the macro (" glyph "," context ")")
                    label := glyph " glyph, variant lit " variant ", lit path " lit ", " context
                    wantClicks := glyph="unread" ? 0 : glyph="off" ? 1 : (context="placing" && variant && !lit) ? 2 : 0
                    Assert(clicks=wantClicks,label ": " clicks " clicks, expected " wantClicks)
                    if glyph="off"
                        Assert(glyphOn && PathLightOn(),label ": P was not switched on")
                    if glyph="on"
                        Assert(glyphOn && PathLightOn(),label ": P ended off")
                    if glyph="unread"
                        Assert(!PathLightOn(),label ": an unreadable glyph counted as on")
                    ; the world reader is only asked at "placing" with the glyph on
                    Assert(worldReads>=(glyph="on" && context="placing"?1:0),label ": the lit path was not looked for")
                    if context="vote" || glyph!="on"
                        Assert(worldReads=0,label ": the world was read where it is not needed")
                }

    ; ---- learned per variant: written only when a lit path is read ----
    Fresh(false)
    glyphOn := true,litVisible := true
    EnsurePathLight("placing")
    Assert(MemoryRead("minimap.abc123","lit_path","0")="1" && VariantShowsLitPath(),"a lit path read did not teach the variant")
    ResetPathLight()
    Assert(VariantShowsLitPath(),"the learned flag did not survive the per-match reset")
    Assert(MemoryRead("minimap.other","lit_path","0")="0","another variant was marked")
    gMapModel := {id:"other"}
    Assert(!VariantShowsLitPath(),"the flag leaked to another variant")
    Fresh(false),gMapModel := {id:"quiet"}
    glyphOn := true,litVisible := false
    EnsurePathLight("placing")
    Assert(MemoryRead("minimap.quiet","lit_path","0")="0" && clicks=0,"a variant with no lit path was marked, or P was clicked without evidence")
    ; a variant never marked is never cycled, even with no lit path: that is what maps without one look like
    gMapModel := {id:"abc123"}

    ; ---- the cycle: two verified clicks, once per match ----
    Fresh(true)
    glyphOn := true,litVisible := false
    EnsurePathLight("placing")
    Assert(clicks=2 && glyphOn && gPathCycleDone,"the off-on cycle did not use exactly two clicks")
    EnsurePathLight("placing")
    Assert(clicks=2,"a second off-on cycle in the same match")
    ResetPathLight()
    EnsurePathLight("placing")
    Assert(clicks=4,"the cycle was not available again after the per-match reset")
    ; a click that does not register in the cycle: bounded, P is left as it was
    Fresh(true)
    glyphOn := true,litVisible := false,ignoreClicks := 99
    EnsurePathLight("placing")
    Assert(clicks=PATH_CLICK_LIMIT && glyphOn && PathLightOn(),"an unregistered off click was not bounded or left P off")
    ; the glyph off at Placing (the vote click did not register): clicked, never cycled
    Fresh(true)
    glyphOn := false,litVisible := false
    EnsurePathLight("placing")
    Assert(clicks=1 && glyphOn,"P off at the Placing call was not simply lit")

    ; ---- click bound and glyph verification (glyph off) ----
    Fresh(false)
    glyphOn := false,ignoreClicks := 99
    EnsurePathLight("vote")
    Assert(clicks=PATH_CLICK_LIMIT && !PathLightOn() && crops=1,"unregistered P clicks were not bounded by PATH_CLICK_LIMIT, or the click-miss crop was not saved")
    Fresh(false)
    glyphOn := false,ignoreClicks := 1
    EnsurePathLight("vote")
    Assert(clicks=2 && glyphOn,"one unregistered click was not repeated")
    ; unknown context is refused without a click
    Fresh(false)
    glyphOn := false
    EnsurePathLight("later")
    Assert(clicks=0,"an unknown context clicked P")
    ; stopped
    Fresh(false)
    glyphOn := false,gRunning := false
    Assert(!EnsurePathLight("vote") && clicks=0,"a stopped run clicked P")
    gRunning := true
    FileAppend "PASS: PathLightAction matrix (3 glyph x variant x lit x 2 contexts) and the same matrix end to end; learned per-variant lit_path flag; one verified off-on cycle per match; PATH_CLICK_LIMIT; click-miss crop; no P key anywhere.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
; A fresh match: per-match state, a counted click total, the variant known to
; show a lit path (or not) from the ini.
Fresh(variantLit) {
    global gMapModel,LEARNING_FILE,clicks,worldReads,crops,ignoreClicks,glyphReadable,litVisible,glyphOn,logs
    ResetPathLight()
    gMapModel := {id:"abc123"}
    if FileExist(LEARNING_FILE)
        FileDelete LEARNING_FILE
    if variantLit
        IniWrite "1",LEARNING_FILE,"minimap.abc123","lit_path"
    clicks := 0,worldReads := 0,crops := 0,ignoreClicks := 0,glyphReadable := true,litVisible := false,glyphOn := false,logs := []
}
Log(text) {
    global logs
    logs.Push(text)
}
ActionPause(*) => gRunning
GetClient(&cx,&cy,&cw,&ch) {
    cx := 108,cy := 230,cw := 800,ch := 600
    return true
}
WindowGeometry() => {x:100,y:200,cx:108,cy:230,w:1296,h:900,cw:800,ch:600,dpi:96}
ReadButtonRecord(*) => savedP
SaveButtonRecord(*) => true
ButtonPosition(name,&rx,&ry) {
    rx := 710,ry := 18
    return true
}
VisionOk(reply) => reply && reply["status"]="ok"
VisionRequest(command) {
    global glyphOn,glyphReadable,litVisible,worldReads
    if InStr(command,"toolbarfixed ")=1
        return glyphReadable?Map("status","ok","on",glyphOn?"1":"0","levels",glyphOn?"230,85":"80,85"):false
    if InStr(command,"world ")=1 {
        worldReads += 1
        return Map("status","ok","path",litVisible?"20000":"0")
    }
    return Map("status","ok")
}
ClickRef(x,y,*) {
    global glyphOn,clicks,ignoreClicks
    Assert(x=715 && y=21,"P click missed the saved coordinate")
    clicks += 1
    if ignoreClicks>0
        ignoreClicks -= 1
    else
        glyphOn := !glyphOn
    return true
}
SaveClickMissCrop(*) {
    global crops
    crops += 1
}
'''

if __name__ == "__main__":
    target = ROOT / "cache" / "path-light-regression.ahk"
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + "\n" + logic, encoding="utf-8-sig")
    result = subprocess.run([str(RUNTIME), "/ErrorStdOut=UTF-8", str(target)], cwd=ROOT,
                            capture_output=True, timeout=120)
    print(result.stdout.decode("utf-8-sig"), end="")
    print(result.stderr.decode("utf-8-sig"), end="")
    raise SystemExit(result.returncode)

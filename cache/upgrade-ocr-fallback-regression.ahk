
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global REF_W := 800,REF_H := 600,calls := [],scaledText := "UPG",nativeText := "UPG [9)",fullText := "Damage 5000",changing := false,signatureReads := 0
try {
    state := ReadUnitUpgradeState(true)
    Assert(state.level=9,"4x OCR omitted the digit; focused 2x OCR did not recover UPG 9")
    Assert(calls.Length=2 && calls[1].scale=4 && calls[2].scale=2 && calls[2].x1=137,"fallback did not stay inside the UPG heading")
    Assert(state.signature="stable-heading" && state.canUpgrade,"OCR fallback lost the existing readiness/signature checks")

    nativeText := "UPG",calls := []
    state := ReadUnitUpgradeState(true)
    Assert(state.level=-1,"missing digits were guessed from damage or cost")
    Assert(calls.Length=3 && calls[3].x1=0,"existing full-panel fallback was removed")

    nativeText := "UPG [9)",changing := true,signatureReads := 0
    state := ReadUnitUpgradeState(true)
    Assert(state.level=-1 && state.signature="","changing heading bypassed the upgrade guard")

    changing := false,scaledText := "UPG MAX",nativeText := "UPG"
    state := ReadUnitUpgradeState(true)
    Assert(state.maxed,"fallback discarded an already recognized MAX heading")

    changing := false,fullText := "UPG [5]",calls := []
    state := ReadUnitUpgradeState(false)
    Assert(state.level=5 && calls.Length=1 && calls[1].x1=0,"MAX upgrade reader changed")
    FileAppend "PASS: actual 4x OCR missing digit recovered by focused 2x; no guessed number; existing full-panel, stable-heading and MAX behavior retained.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
WindowGeometry() => {cw:800,ch:600}
UnitPanelRegion(name) => name="header"?[137,210,215,246]:[145,340,265,395]
UnitUpgradeButtonReady(*) => true
UpgradeHeaderSignature(*) {
    global signatureReads
    signatureReads += 1
    return changing?"changed-" signatureReads:"stable-heading"
}
ReadOcrRows(x1,y1,x2,y2,words := false,scale := 2) {
    calls.Push({x1:x1,scale:scale})
    if x1=137 {
        text := scale=4?scaledText:nativeText
        return ParseOcrRows("8`t9`t68`t20`t" text,137,210)
    }
    return [{x:145,y:215,w:68,h:20,text:fullText}]
}

ReadUnitUpgradeState(finite := false) {
    geometry := WindowGeometry()
    if !geometry
        return {level:-1,maxed:false,signature:"",canUpgrade:false,x:210,y:368,raw:"window unavailable"}
    ; Keep numbers from damage, cooldown and upgrade cost out of the level OCR.
    before := finite?UpgradeHeaderSignature():""
    header := UnitPanelRegion("header")
    rows := finite?ReadOcrRows(header[1],header[2],header[3],header[4],false,4):ReadOcrRows(0,100,340,520)
    state := ParseUpgradeState(rows,geometry)
    if finite && state.level<0 && !state.maxed {
        ; Windows OCR can drop the bracketed digit at 4x but read it at 2x.
        rows := ReadOcrRows(header[1],header[2],header[3],header[4],false,2)
        state := ParseUpgradeState(rows,geometry)
    }
    state.canUpgrade := !finite || UnitUpgradeButtonReady()
    if finite && (state.level<0 || !state.canUpgrade) {
        full := ParseUpgradeState(ReadOcrRows(0,100,340,520),geometry)
        if state.level<0
            state.level := full.level
        state.maxed := state.maxed || full.maxed
        state.raw .= " | " full.raw
    }
    state.signature := finite?UpgradeHeaderSignature():""
    if finite && (before="" || before!=state.signature)
        state.level := -1,state.signature := ""
    return state
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
NormalizeWords(text) {
    for code in [0x2212,0x2010,0x2011,0x2012,0x2013,0x2014,0xFE63,0xFF0D]
        text := StrReplace(text,Chr(code),"-")
    text := Trim(RegExReplace(StrLower(text), "[^a-z0-9%+.-]+", " "))
    text := RegExReplace(text,"\b(?:mogic|maglc)\b","magic")
    text := RegExReplace(text,"\b(?:resistmce|resistarw)\b","resistance")
    return RegExReplace(text,"\bspee\b","speed")
}
ParseOcrRows(content, left, top) {
    rows := []
    for line in StrSplit(content,"`n","`r") {
        fields := StrSplit(line,"`t")
        if fields.Length >= 5 && IsNumber(fields[1]) && IsNumber(fields[2]) && IsNumber(fields[3]) && IsNumber(fields[4])
            rows.Push({x:left+Number(fields[1]),y:top+Number(fields[2]),w:Number(fields[3]),h:Number(fields[4]),text:fields[5]})
    }
    return rows
}
; Persistent, local observations. No screenshots, OCR, or file scans at startup.
global LEARNING_FILE := A_ScriptDir "\learning.ini"
global gButtonMemory := Map()
global gLastButtonClicks := Map()
global gCardMemory := Map()
global gPlacementProfile := ""
global gMapKey := ""
global gLearnButton, gTeachCard, gTeachKind, gTeachStat
global gOcrPid := 0
global gLastOcrRows := [], gLastOcrRect := "", gLastOcrTime := 0
global gCardRetryAt := 0, gCardUnread := 0, gCardSelection := 0, gCardModifiersRead := false
global gCardBoxes := 0
global gCardHandling := false,gCardAction := "",gCardPollAt := 0,gCardInterruptEpoch := 0,gPlacementActiveUnit := 0

BuildLearningTab(app) {
    global gLearnButton, gTeachCard, gTeachKind, gTeachStat
    app.AddText("x28 y143 w410", "Static buttons: select a name, hover it in Roblox, press F10.")
    gLearnButton := app.AddDropDownList("x28 y174 w220 Choose1 c20212D BackgroundFFFFFF", ["LobbyPlay", "PlayHere", "PortalOpen", "PortalStart", "PathToggle", "SettingsGear", "TeleportSpawn", "SettingsClose", "VoteYes", "DefeatNext", "Replay", "UnitPanelClose"])
    app.AddText("x28 y211 w405 h58", "F10 saves pixels relative to the Roblox application window, including its title bar. Moving Roblox does not change the saved point. Different window sizes have separate records.")
    app.AddText("x28 y285 w405", "Teach an unreadable card once while its choice is visible:")
    gTeachCard := app.AddDropDownList("x28 y315 w92 Choose1 c20212D BackgroundFFFFFF", ["Card 1", "Card 2", "Card 3"])
    gTeachKind := app.AddDropDownList("x132 y315 w110 Choose1 c20212D BackgroundFFFFFF", ["buff", "debuff"])
    gTeachStat := app.AddDropDownList("x28 y353 w260 Choose1 c20212D BackgroundFFFFFF", ["random blessings", "double attack", "attack", "cooldown", "range", "yen", "boss damage", "shield", "explosive death", "health", "0.5 regen", "physical resist", "magical resist", "physical and magical resist", "speed"])
    app.AddButton("x28 y394 w180", "Remember selected card").OnEvent("Click", TeachCurrentCard)
    app.AddText("x28 y445 w405 h78", "Buttons use saved positions. Card effects are read live from coloured words; enemy Speed increases are blocked. Successful placements reuse matching map, camera and window data. Learning stays in this folder.")
}

MemoryRead(section, key, fallback := "", file := "") {
    global LEARNING_FILE
    try return IniRead(file = "" ? LEARNING_FILE : file, section, key, fallback)
    catch
        return fallback
}

MemoryKey(text) {
    return SubStr(RegExReplace(StrLower(text), "[^a-z0-9_-]+", "_"), 1, 100)
}

WindowGeometry() {
    hwnd := FindRoblox()
    if !hwnd || !GetClient(&cx, &cy, &cw, &ch)
        return false
    WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
    try dpi := DllCall("GetDpiForWindow", "Ptr", hwnd, "UInt")
    catch
        dpi := 96
    return {x: x, y: y, w: w, h: h, dpi: dpi, cx: cx, cy: cy, cw: cw, ch: ch}
}

ButtonSection(name, geometry) {
    return "button." MemoryKey(name) "." geometry.w "x" geometry.h "." geometry.dpi
}

SaveButtonRecord(name, point, geometry, source, file := "") {
    global LEARNING_FILE, gButtonMemory
    if point.x < 0 || point.y < 0 || point.x >= geometry.w || point.y >= geometry.h
        return false
    file := file = "" ? LEARNING_FILE : file
    section := ButtonSection(name, geometry)
    IniWrite Round(point.x) "," Round(point.y), file, section, "window_xy"
    IniWrite source, file, section, "source"
    IniWrite FormatTime(, "yyyy-MM-dd HH:mm:ss"), file, section, "observed"
    gButtonMemory[section] := {x: Round(point.x), y: Round(point.y), source: source}
    Log("Learned " name ": application-window " Round(point.x) "," Round(point.y) " at " geometry.w "x" geometry.h " (" source ")")
    return true
}

ReadButtonRecord(name, geometry, file := "") {
    global gButtonMemory
    section := ButtonSection(name, geometry)
    if file = "" && gButtonMemory.Has(section)
        return gButtonMemory[section]
    parts := StrSplit(MemoryRead(section, "window_xy", "", file), ",")
    if parts.Length != 2 || !IsNumber(parts[1]) || !IsNumber(parts[2])
        return false
    point := {x: Number(parts[1]), y: Number(parts[2]), source: "memory"}
    if point.x < 0 || point.y < 0 || point.x >= geometry.w || point.y >= geometry.h
        return false
    if file = ""
        gButtonMemory[section] := point
    return point
}

ForgetButton(name, geometry) {
    global LEARNING_FILE, gButtonMemory
    section := ButtonSection(name, geometry)
    if gButtonMemory.Has(section)
        gButtonMemory.Delete(section)
    try IniDelete LEARNING_FILE, section
    Log("Discarded failed button position: " name)
}

LearnHoveredButton(*) {
    global gLearnButton
    geometry := WindowGeometry()
    if !geometry {
        Notify("Open Roblox before teaching a button.")
        return
    }
    MouseGetPos(&sx, &sy, &underMouse)
    if underMouse != FindRoblox() {
        Notify("Hover the named button inside Roblox, then press F10.")
        return
    }
    SaveButtonRecord(gLearnButton.Text, {x: sx - geometry.x, y: sy - geometry.y}, geometry, "F10 taught")
    Notify("Saved " gLearnButton.Text " in application-window coordinates.")
}

ButtonLabels(name) {
    switch name {
        case "LobbyPlay": return ["play"]
        case "PlayHere": return ["play here"]
        case "PortalOpen": return ["open"]
        case "PortalStart": return ["start"]
        case "TeleportSpawn": return ["teleport back to spawn", "back to spawn", "return to spawn"]
        case "VoteYes": return ["yes"]
        case "DefeatNext": return ["next"]
        case "Replay": return ["replay"]
        case "PathToggle": return ["p"]
    }
    return []
}

ButtonRegion(name) {
    switch name {
        case "LobbyPlay": return [0, 130, 220, 465]
        case "PathToggle": return [590, 0, 795, 55]
        case "VoteYes": return [280, 60, 500, 145]
        case "Replay": return [270, 65, 650, 165]
        case "UnitPanelClose": return [170, 100, 360, 310]
        case "SettingsClose": return [470, 70, 690, 250]
    }
    return [120, 65, 720, 470]
}

NormalizeWords(text) {
    for code in [0x2212,0x2010,0x2011,0x2012,0x2013,0x2014,0xFE63,0xFF0D]
        text := StrReplace(text,Chr(code),"-")
    text := Trim(RegExReplace(StrLower(text), "[^a-z0-9%+.-]+", " "))
    text := RegExReplace(text,"\b(?:mogic|maglc)\b","magic")
    text := RegExReplace(text,"\b(?:resistmce|resistarw)\b","resistance")
    return RegExReplace(text,"\bspee\b","speed")
}

DiscoverButton(name, geometry) {
    labels := ButtonLabels(name), region := ButtonRegion(name)
    if labels.Length {
        rows := ReadOcrRows(region*)
        for row in rows {
            text := NormalizeWords(row.text)
            for label in labels {
        if StrReplace(text, " ") = StrReplace(label, " ") {
                    point := {x: geometry.cx - geometry.x + row.x + row.w / 2, y: geometry.cy - geometry.y + row.y + row.h / 2, source: "OCR label " text}
                    SaveButtonRecord(name, point, geometry, point.source)
                    return point
                }
            }
        }
    }
    ; Icon controls use a connected red X or a known anchor, never an unrelated
    ; green patch somewhere in the scene. Unconfirmed anchors are not learned.
    if name = "SettingsClose" || name = "UnitPanelClose" {
        frame := RefPixels(region*)
        if frame.valid && FindCompactRedControl(frame, &rx, &ry) {
            point := {x: geometry.cx - geometry.x + rx, y: geometry.cy - geometry.y + ry, source: "red close control"}
            SaveButtonRecord(name, point, geometry, point.source)
            return point
        }
    }
    if ButtonPosition(name, &rx, &ry) {
        global REF_W, REF_H
        return {x: geometry.cx - geometry.x + rx * geometry.cw / REF_W, y: geometry.cy - geometry.y + ry * geometry.ch / REF_H, source: "unconfirmed anchor"}
    }
    return false
}

FindCompactRedControl(frame, &nativeX, &nativeY) {
    ; Search small 8x8 reference tiles; a close button must be locally solid.
    best := 0, found := false
    y := 4
    while y < frame.height - 4 {
        x := 4
        while x < frame.width - 4 {
            score := 0
            for offset in [[-3,-3],[0,-3],[3,-3],[-3,0],[3,0],[-3,3],[0,3],[3,3]]
                score += IsUiRed(frame.At(x + offset[1], y + offset[2])) ? 1 : 0
            if score > best && score >= 6 {
                nativeX := frame.left + x, nativeY := frame.top + y
                best := score, found := true
            }
            x += 4
        }
        y += 4
    }
    return found
}

ClickWindowOnce(point, geometry) {
    global gRunning, CLICK_HOLD_MS, MOUSE_SETTLE_MS
    hwnd := FindRoblox()
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,, 2)
        return false
    if !gRunning || !SmoothMoveTo(geometry.x + Round(point.x), geometry.y + Round(point.y))
        return false
    if !BeginInputAction()
        return false
    Click "Down"
    try return ActionPause(CLICK_HOLD_MS,false)
    finally {
        Click "Up"
        EndInputAction()
    }
}

ClickLearnedButton(name, delayMs, confirm := 0, forceDetect := false) {
    global STATIC_CLICK_MS, gLastButtonClicks
    geometry := WindowGeometry()
    if !geometry
        return false
    point := forceDetect ? false : ReadButtonRecord(name, geometry)
    if !point
        point := DiscoverButton(name, geometry)
    if !point {
        Log("Button not found: " name ". Hover it and use Learning/F10 once.")
        return false
    }
    Log("Button " name ": " point.source "; one click at window " Round(point.x) "," Round(point.y))
    gLastButtonClicks[name] := {point:point,geometry:geometry}
    if !ClickWindowOnce(point, geometry) || !ActionPause(delayMs < 0 ? STATIC_CLICK_MS : delayMs)
        return false
    if confirm {
        if confirm.Call() {
            if point.source = "unconfirmed anchor"
                SaveButtonRecord(name, point, geometry, "confirmed transition")
            return true
        }
        ForgetButton(name, geometry)
        if !forceDetect
            return ClickLearnedButton(name, delayMs, confirm, true)
        return false
    }
    return true
}

ConfirmObservedTransition(name) {
    global gLastButtonClicks
    if !gLastButtonClicks.Has(name)
        return
    last := gLastButtonClicks[name]
    if last.point.source = "unconfirmed anchor"
        SaveButtonRecord(name,last.point,last.geometry,"confirmed " name " flow")
}

SaveFrameBmp(frame, path) {
    if !frame.valid
        return false
    bytes := frame.width * frame.height * 4
    header := Buffer(54, 0)
    NumPut("UShort", 0x4D42, "UInt", bytes + 54, "UInt", 0, "UInt", 54, header)
    NumPut("UInt", 40, "Int", frame.width, "Int", -frame.height, "UShort", 1, "UShort", 32, header, 14)
    NumPut("UInt", bytes, header, 34)
    file := FileOpen(path, "w")
    try {
        file.RawWrite(header)
        pixels := Buffer(bytes)
        DllCall("RtlMoveMemory", "Ptr", pixels, "Ptr", frame.bits, "UPtr", bytes)
        file.RawWrite(pixels)
    } finally file.Close()
    return true
}

ReadOcrRows(rx1, ry1, rx2, ry2,words := false,scale := 2) {
    global gOcrPid, gRunning, gLastOcrRows, gLastOcrRect, gLastOcrTime
    rect := rx1 "," ry1 "," rx2 "," ry2 ":" words ":" scale
    if rect = gLastOcrRect && A_TickCount - gLastOcrTime < 350
        return gLastOcrRows
    frame := RefPixels(rx1, ry1, rx2, ry2)
    rows := []
    if !frame.valid
        return rows
    cacheDir := A_ScriptDir "\cache"
    DirCreate cacheDir
    tag := DllCall("GetCurrentProcessId") "-" A_TickCount
    imageFile := cacheDir "\ocr-" tag ".bmp", textFile := cacheDir "\ocr-" tag ".tsv"
    if !SaveFrameBmp(frame, imageFile)
        return rows
    q := Chr(34)
    command := q A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe" q " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " q A_ScriptDir "\OCRBridge.ps1" q " -ImagePath " q imageFile q " -OutputPath " q textFile q
    if words
        command .= " -WordBoxes"
    command .= " -Scale " Max(1,Min(6,Integer(scale)))
    try {
        Run command,, "Hide", &pid
        gOcrPid := pid
        deadline := A_TickCount + 8000
        while ProcessExist(pid) && A_TickCount < deadline {
            if !gRunning {
                ProcessClose pid
                return rows
            }
            Sleep 30
        }
        if ProcessExist(pid) {
            ProcessClose pid
            Log("Local OCR timed out; teach this control with F10.")
            return rows
        }
        if !FileExist(textFile)
            return rows
        content := FileRead(textFile, "UTF-8")
        if SubStr(content, 1, 5) = "ERROR" {
            Log("Local OCR unavailable: " SubStr(content, 1, 180))
            return rows
        }
        rows := ParseOcrRows(content,frame.left,frame.top)
        geometry := WindowGeometry()
        if geometry && !words
            ObserveTextButtons(rows,geometry)
        gLastOcrRect := rect, gLastOcrRows := rows, gLastOcrTime := A_TickCount
    } finally {
        gOcrPid := 0
        try FileDelete imageFile
        try FileDelete textFile
    }
    return rows
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

ObserveTextButtons(rows, geometry) {
    global REF_W, REF_H
    for name in ["LobbyPlay","PlayHere","PortalOpen","PortalStart","TeleportSpawn","VoteYes","DefeatNext","Replay"] {
        region := ButtonRegion(name)
        for row in rows {
            text := NormalizeWords(row.text)
            rx := (row.x+row.w/2)*REF_W/geometry.cw
            ry := (row.y+row.h/2)*REF_H/geometry.ch
            if rx < region[1] || rx > region[3] || ry < region[2] || ry > region[4]
                continue
            for label in ButtonLabels(name) {
                if StrReplace(text," ") != StrReplace(label," ")
                    continue
                point := {x:geometry.cx-geometry.x+row.x+row.w/2,y:geometry.cy-geometry.y+row.y+row.h/2}
                old := ReadButtonRecord(name,geometry)
                if !old || MapDistance(old.x,old.y,point.x,point.y) > 4
                    SaveButtonRecord(name,point,geometry,"observed OCR label " text)
            }
        }
    }
}

HasSavedRedControl(name) {
    return HasSavedColourControl(name,IsUiRed)
}

HasSavedColourControl(name,predicate) {
    global REF_W, REF_H
    geometry := WindowGeometry()
    if !geometry
        return false
    point := ReadButtonRecord(name,geometry)
    if !point
        return false
    rx := (point.x-(geometry.cx-geometry.x))*REF_W/geometry.cw
    ry := (point.y-(geometry.cy-geometry.y))*REF_H/geometry.ch
    return CountRef(rx-8,ry-8,rx+8,ry+8,2,predicate) >= 4
}

HasSettingsPanel() {
    if HasSavedRedControl("SettingsClose")
        return true
    ; Only an unfamiliar settings layout needs text recognition.
    for row in ReadOcrRows(140,60,700,470) {
        if RegExMatch(NormalizeWords(row.text),"settings|teleport.*spawn|back to spawn") {
            geometry := WindowGeometry()
            if geometry
                DiscoverButton("SettingsClose",geometry)
            return true
        }
    }
    return false
}

SettingsPanelClosed() {
    geometry := WindowGeometry()
    if !geometry || !ReadButtonRecord("SettingsClose",geometry)
        return false
    return !HasSavedRedControl("SettingsClose")
}

UnitPanelClosed() {
    return !HasUnitPanel()
}

; Current frame colour supplies the default kind. Signed enemy reductions
; are beneficial even on a red card; non-negative Speed is always last.
HasSecretPortalReward(text) {
    text := NormalizeWords(text)
    return RegExMatch(text,"\bsecret\b") && RegExMatch(text,"\bportals?\b|\bdrops?\b")
}

StripSecretPortalReward(text) {
    return RegExReplace(text,"(?:[+-]?\s*\d+(?:\.\d+)?\s*%\s*)?\bsecret\s+(?:portals?|drops?)(?:\s+(?:portals?|drops?|rates?|chance|increase|increased))*\b(?:\s*[:+ -]?\s*\d+(?:\.\d+)?\s*%)?"," ")
}

BuffTitleStat(text) {
    if RegExMatch(text,"\brandom\s+blessings?\b")
        return "random blessings"
    if RegExMatch(text,"\bboss(?:es)?\s+(?:damage|dmg)\b|\b(?:damage|dmg)(?:\s+dealt)?\s+(?:to|against|versus|vs)\s+boss(?:es)?\b")
        return "boss damage"
    if RegExMatch(text,"\bdouble\s*attack\b|\battacks?\s+(?:twice|two times)\b")
        return "double attack"
    if RegExMatch(text,"\b(attack|cooldown|cool down|range|yen)\b",&match)
        return match[1]="cool down"?"cooldown":match[1]
    return ""
}

BuffTitleTier(text) {
    text := NormalizeWords(text)
    if RegExMatch(text,"\b(?:random blessings?|boss (?:damage|dmg)|double attack|attack|cooldown|cool down|range|yen)\s+(?:tier\s+)?(viii|vii|vi|iv|iii|ii|ix|v|i|x|l{1,3})\b",&match) {
        token := StrReplace(match[1],"l","i")
        romans := Map("i",1,"ii",2,"iii",3,"iv",4,"v",5,"vi",6,"vii",7,"viii",8,"ix",9,"x",10)
        if romans.Has(token)
            return romans[token]
    }
    if RegExMatch(text,"\b(?:random blessings?|boss (?:damage|dmg)|double attack|attack|cooldown|cool down|range|yen)\s+(?:tier\s+)?(10|[1-9])\b(?![.\d]|\s*%)",&match)
        return Integer(match[1])
    return 1
}

EnemyStatReduction(text,stat) {
    patterns := Map("physical resist","(?:physical|physic|armor|armour)(?:\s+(?:and|magic|magical))*\s*(?:resist(?:ance)?)?",
        "magical resist","magic(?:al)?\s*(?:resist(?:ance)?)?",
        "physical and magical resist","(?:physical\s+and\s+magic(?:al)?|physical|magic(?:al)?)\s*resist(?:ance)?",
        "speed","(?:movement\s+)?speed","health","(?:health|hit points?|hp)","regen","(?:regen|regeneration)",
        "0.5 regen","(?:regen|regeneration)","shield","(?:shield|barrier)")
    if !patterns.Has(stat)
        return false
    effect := patterns[stat],number := "-\s*\d+(?:\.\d+)?\s*%?"
    return RegExMatch(text,number "\s*(?:enemy\s+|enemies\s+)?" effect "\b")
        || RegExMatch(text,"\b" effect "\b(?:\s+(?:tier\s+)?(?:viii|vii|vi|iv|iii|ii|ix|v|i|x|[1-9]))?\s*(?::|by|is|of)?\s*" number)
}

ReadResistanceAmounts(text,prefix) {
    atom := "(?:physical|physic|magical|magic|armor|armour)(?:\s+resist(?:ance)?)?"
    effect := atom "(?:\s+(?:and\s+)?(?:enemy\s+)?" atom ")?"
    amountPattern := "[+-]?\s*\d+(?:\.\d+)?\s*%?"
    pattern := prefix?"(" amountPattern ")\s*(?:enemy\s+|enemies\s+)?(" effect ")"
        :"(" effect ")(?:\s+(?:tier\s+)?(?:viii|vii|vi|iv|iii|ii|ix|v|i|x|10|[1-9])\b(?![.\d]|\s*%))?\s*(?::|by)?\s*(" amountPattern ")"
    result := {physical:0,magical:0,physicalRead:false,magicalRead:false,matches:0}
    position := 1
    while RegExMatch(text,pattern,&match,position) {
        if prefix && RegExMatch(SubStr(text,1,match.Pos-1),"(?:health|speed|shield|attack|range|yen|cooldown)\s*:?\s*$") {
            position := match.Pos+match.Len
            continue
        }
        value := Number(RegExReplace(prefix?match[1]:match[2],"[%\s]")),wording := prefix?match[2]:match[1]
        for name,words in Map("physical","physical|physic|armor|armour","magical","magic|magical") {
            if !RegExMatch(wording,words)
                continue
            ; A title repeating its effect is the same stat, not a second increase.
            if !result.%(name "Read")% || Abs(value)>Abs(result.%name%)
                result.%name% := value
            result.%(name "Read")% := true
        }
        result.matches += 1
        position := match.Pos+match.Len
    }
    return result
}

ParseResistanceEffects(text) {
    text := StripSecretPortalReward(NormalizeWords(text))
    before := ReadResistanceAmounts(text,true),after := ReadResistanceAmounts(text,false)
    result := after.matches>before.matches?after:before
    physical := RegExMatch(text,"physical|physic|armor|armour"),magical := RegExMatch(text,"magic|magical")
    result.known := result.matches>0 && (!physical || result.physicalRead) && (!magical || result.magicalRead)
    result.total := Max(0,result.physical)+Max(0,result.magical)
    result.peak := Max(0,result.physical,result.magical)
    return result
}

CombineResistanceLines(lines) {
    result := {physical:0,magical:0,physicalRead:false,magicalRead:false,known:false,total:0,peak:0}
    hasPhysical := false,hasMagical := false
    for line in lines {
        hasPhysical := hasPhysical || RegExMatch(line,"physical|physic|armor|armour")
        hasMagical := hasMagical || RegExMatch(line,"magic|magical")
        parsed := ParseResistanceEffects(line)
        for name in ["physical","magical"] {
            if parsed.%(name "Read")% {
                if !result.%(name "Read")% || Abs(parsed.%name%)>Abs(result.%name%)
                    result.%name% := parsed.%name%
                result.%(name "Read")% := true
            }
        }
    }
    result.known := (hasPhysical || hasMagical) && (!hasPhysical || result.physicalRead) && (!hasMagical || result.magicalRead)
    result.total := Max(0,result.physical)+Max(0,result.magical)
    result.peak := Max(0,result.physical,result.magical)
    return result
}

CardIsResistance(card) {
    return card.stat="physical resist" || card.stat="magical resist" || card.stat="physical and magical resist"
}

ResistancePreferred(a,b) {
    global gResistancePreference,gMatchModifiers
    left := a.HasProp("resistance")?a.resistance:ParseResistanceEffects(a.HasProp("text")?a.text:"")
    right := b.HasProp("resistance")?b.resistance:ParseResistanceEffects(b.HasProp("text")?b.text:"")
    ; Balanced team: a shared physical+magical debuff (e.g. 50+50) always beats
    ; a sole one (75 or 100 physical), even if its amounts were partly unread.
    ; A ticked Magic/Physical team checkbox still decides by the avoided stat.
    if gResistancePreference="balanced" {
        leftShared := ResistanceIsShared(a,left),rightShared := ResistanceIsShared(b,right)
        if leftShared!=rightShared
            return leftShared
    }
    if left.known!=right.known
        return left.known
    if left.known {
        if gResistancePreference!="balanced" {
            name := gResistancePreference="magic"?"magical":"physical"
            if Max(0,left.%name%)!=Max(0,right.%name%)
                return Max(0,left.%name%)<Max(0,right.%name%)
        }
        if left.total!=right.total
            return left.total<right.total
        ; Equal totals prefer the smaller individual increase before match history.
        if left.peak!=right.peak
            return left.peak<right.peak
        lp := Max(gMatchModifiers.physical+Max(0,left.physical),gMatchModifiers.magical+Max(0,left.magical))
        rp := Max(gMatchModifiers.physical+Max(0,right.physical),gMatchModifiers.magical+Max(0,right.magical))
        if lp!=rp
            return lp<rp
    }
    return CardRank(a.kind,a.stat)<CardRank(b.kind,b.stat)
}

ResistanceIsShared(card,effects) {
    return card.stat="physical and magical resist"
        || (effects.physicalRead && effects.magicalRead && effects.physical>0 && effects.magical>0)
}

CardPolicy(text, greenHint := false, colourKind := "") {
    text := NormalizeWords(text)
    stat := "", kind := "unknown", amount := 0,amountSigned := 0,amountKnown := false,secretPortal := HasSecretPortalReward(text)
    text := StripSecretPortalReward(text)
    tier := BuffTitleTier(text)
    titleStat := (colourKind="buff" || greenHint || RegExMatch(text,"\bbuff\b"))?BuffTitleStat(text):""
    physical := RegExMatch(text, "physical|physic|armor|armour")
    magical := RegExMatch(text, "magic|magical")
    if titleStat="random blessings" || titleStat="boss damage"
        stat := titleStat
    else if titleStat!="" && !physical && !magical && !RegExMatch(text,"shield|barrier|health|hit point|\bhp\b|regen|explosive? death|\benemy (?:movement )?speed\b")
        stat := titleStat
    else if RegExMatch(text,"^(?:(?:enemy|enemies)\s+)?(?:movement\s+)?speed(?:\s|$)")
        stat := "speed"
    else if RegExMatch(text,"\brandom\s+blessings?\b")
        stat := "random blessings"
    else if BuffTitleStat(text)="boss damage"
        stat := "boss damage"
    else if RegExMatch(text,"\bdouble\s*attack\b|\battacks?\s+(?:twice|two times)\b")
        stat := "double attack"
    else if RegExMatch(text,"explosive? death|explod.*death|death.*explod")
        stat := "explosive death"
    else if RegExMatch(text,"\bregen\b|regenerat")
        stat := "regen"
    else if physical && magical
        stat := "physical and magical resist"
    else if physical
        stat := "physical resist"
    else if magical
        stat := "magical resist"
    else if RegExMatch(text, "shield|barrier")
        stat := "shield"
    else if RegExMatch(text, "health|hit point|\bhp\b")
        stat := "health"
    else if RegExMatch(text, "cooldown|cool down|attack speed|\bspa\b")
        stat := "cooldown"
    else if RegExMatch(text, "range")
        stat := "range"
    else if RegExMatch(text, "yen|money|cash|income")
        stat := "yen"
    else if RegExMatch(text, "attack|damage|\batk\b")
        stat := "attack"
    else if RegExMatch(text, "speed|movement")
        stat := "speed"
    ; Flat values count too ("+75 Enemy Magic Resist").
    amountText := RegExReplace(text,"\b(random blessings?|boss (?:damage|dmg)|double attack|attack|cooldown|cool down|range|yen)\s+(?:tier\s+)?(?:10|[1-9])\b(?![.\d]|\s*%)","$1",,1)
    if RegExMatch(amountText, "([+-]?\s*\d+(?:\.\d+)?)\s*%?", &match) {
        amountSigned := Number(RegExReplace(match[1],"\s")),amount := Abs(amountSigned),amountKnown := true
    }
    if stat="regen" && amount=0.5
        stat := "0.5 regen"
    if stat = ""
        return {kind: colourKind != "" ? colourKind : greenHint ? "buff" : "unknown", stat: "unknown", rank: 99, amount: amount, amountSigned:amountSigned,amountKnown:amountKnown,text: text, secretPortal:secretPortal, tier:tier,forbiddenSpeed:CardHasForbiddenSpeed(text)}
    enemyReduction := EnemyStatReduction(text,stat)
    if enemyReduction
        kind := "buff"
    else if stat="speed"
        kind := "debuff"
    else if colourKind != ""
        kind := colourKind
    else if RegExMatch(text, "debuff|negative|enemies|enemy")
        kind := "debuff"
    else if RegExMatch(text, "\bbuff\b|positive")
        kind := "buff"
    else if stat="random blessings" || stat="boss damage" || stat = "double attack" || stat = "attack" || stat = "range" || stat = "yen"
        kind := RegExMatch(text, "-\s*\d|decrease|reduc") ? "debuff" : "buff"
    else if stat = "cooldown"
        kind := RegExMatch(text, "\+\s*\d|increas") ? "debuff" : "buff"
    else
        kind := "debuff"
    rank := CardRank(kind, stat)
    return {kind: kind, stat: stat, rank: rank, amount: amount, amountSigned:amountSigned,amountKnown:amountKnown,text: text, secretPortal:secretPortal, tier:tier,enemyReduction:enemyReduction,resistance:ParseResistanceEffects(text),forbiddenSpeed:CardHasForbiddenSpeed(text)}
}

CardPolicyFromLines(lines,allLines,index,colour) {
    text := "",secretPortal := false
    for line in lines {
        if HasSecretPortalReward(line) {
            secretPortal := true
            line := Trim(StripSecretPortalReward(line))
            if line=""
                continue
        }
        shared := true
        for other,otherLines in allLines {
            if other!=index && (!otherLines || !HasValue(otherLines,line))
                shared := false
        }
        if !shared || RegExMatch(line,"blessing|boss|attack|cooldown|range|yen|shield|death|health|regen|resist|speed|damage|magic|physical")
            text .= " " line
    }
    card := CardPolicy(text,colour="buff",colour)
    card.secretPortal := secretPortal || card.secretPortal
    return card
}

CardRank(kind, stat) {
    ; Buff order: Double Attack, Attack, Cooldown, Range, Random Blessings,
    ; any other green, Yen, Boss Damage. CardPreferenceScore adds tiers.
    if kind="buff" && stat="double attack"
        return 0
    if kind="buff" && stat="random blessings"
        return 4
    if kind="buff" && stat="yen"
        return 98
    if kind="buff" && stat="boss damage"
        return 100
    ; Base debuff order. ChooseBestCard re-ranks red cards by their projected
    ; totals against the caps (DebuffOutlook); this order is only the label.
    priorities := kind="buff"?["attack","cooldown","range"]:["shield","explosive death","health","physical and magical resist","physical resist","magical resist","0.5 regen","speed"]
    for index,name in priorities
        if stat=name
            return index
    return 99
}

CardHasGreenEffect(card) {
    return card.HasProp("effectInk") && card.effectInk="buff"
}

CardSelectionView(card) {
    if card.HasProp("effectInk") && (card.effectInk="buff" || card.effectInk="debuff") {
        card := card.Clone()
        card.kind := card.effectInk
        card.rank := CardRank(card.kind,card.stat)
    }
    return card
}

CardIsSpeed(card) {
    ; Green effect text is authoritative, including a minus lost by OCR.
    if CardHasGreenEffect(card)
        return false
    if card.HasProp("effectInk") && card.effectInk="debuff" && card.stat="speed"
        return true
    return (card.HasProp("redSpeedEffect") && card.redSpeedEffect)
        || (card.HasProp("forbiddenSpeed") && card.forbiddenSpeed)
        || (card.stat="speed" && !(card.HasProp("enemyReduction") && card.enemyReduction))
}

CardPreferenceScore(card) {
    if card.kind="buff" {
        tier := card.HasProp("tier")?Max(1,Min(10,card.tier)):1
        tie := Min(9,card.amount/100)
        ; Double Attack beats every tier of every other buff.
        if card.stat="double attack"
            return -900000000
        ; Attack/Cooldown/Range: the higher tier wins first (Cooldown II beats
        ; Attack I); within one tier Attack, then Cooldown, then Range.
        order := Map("attack",1,"cooldown",2,"range",3)
        if order.Has(card.stat)
            return -tier*1000000+order[card.stat]*1000-tie
        if card.stat="random blessings"
            return 100000000-tier*1000-tie
        if card.stat="yen"
            return 300000000-tier*1000-tie
        if card.stat="boss damage"
            return 400000000-tier*1000-tie
        ; Any other green card, readable (e.g. -Enemy Speed) or unreadable.
        return 200000000
    }
    ; Red cards are compared with DebuffBetter; this is only a coarse score.
    return DebuffOutlook(card).group*10+Min(9,card.amount/100)
}

CardIsRegen(card) => card.stat="regen" || card.stat="0.5 regen"

; How hard a red card makes the match, judged on the total AFTER taking it.
; Groups, easiest first:
;   1 Shield   2 Explosive Death   (no limit)
;   3 Health that stays <= CARD_HEALTH_CAP
;   4 Resistance where every type it adds stays <= CARD_RESIST_CAP
;   5 Regen that stays <= CARD_REGEN_CAP
;   6 Health or resistance past its cap: least far past (ratio) wins
;   7 Regen past its cap   8 any other readable red effect
; Unreadable red cards and positive Speed come after all of these.
DebuffOutlook(card) {
    global CARD_HEALTH_CAP,CARD_RESIST_CAP,CARD_REGEN_CAP,CARD_UNKNOWN_HEALTH,CARD_UNKNOWN_RESIST
    amount := card.HasProp("amountKnown") && card.amountKnown?card.amount:-1
    if card.stat="shield"
        return {group:1,ratio:0,detail:"shield (no limit)"}
    if card.stat="explosive death"
        return {group:2,ratio:0,detail:"explosive death (no limit)"}
    if card.stat="health" {
        now := MatchModifier("health"),after := now+(amount>=0?amount:CARD_UNKNOWN_HEALTH)
        within := amount>=0 && after<=CARD_HEALTH_CAP
        return {group:within?3:6,ratio:after/CARD_HEALTH_CAP,
            detail:"health " now "% -> " after "%" (amount<0?" (amount unread)":"") " | cap " CARD_HEALTH_CAP "%" (within?"":" EXCEEDED")}
    }
    if CardIsResistance(card) {
        effects := card.HasProp("resistance")?card.resistance:{physical:0,magical:0,physicalRead:false,magicalRead:false}
        ratio := 0,detail := "",within := true
        for name in ["physical","magical"] {
            read := effects.%(name "Read")%
            if !(card.stat="physical and magical resist" || card.stat=name " resist" || (read && effects.%name%>0))
                continue
            now := MatchModifier(name),after := now+(read?Max(0,effects.%name%):CARD_UNKNOWN_RESIST)
            within := within && read && after<=CARD_RESIST_CAP
            ratio := Max(ratio,after/CARD_RESIST_CAP)
            detail .= (detail=""?"":", ") name " " now " -> " after (read?"":" (amount unread)")
        }
        return {group:within?4:6,ratio:ratio,detail:detail " | cap " CARD_RESIST_CAP (within?"":" EXCEEDED")}
    }
    if CardIsRegen(card) {
        if amount<0 && card.stat="0.5 regen"
            amount := 0.5
        now := MatchModifier("regen"),after := now+Max(0,amount)
        within := amount>=0 && after<=CARD_REGEN_CAP
        return {group:within?5:7,ratio:after/CARD_REGEN_CAP,
            detail:"regen " now "% -> " (amount>=0?after "%":"? (amount unread)") " | cap " CARD_REGEN_CAP "%" (within?"":" EXCEEDED")}
    }
    return {group:8,ratio:0,detail:"other red effect"}
}

; Medium difficulty. Tier I amounts seen in game; a Tier II card is the same
; card with at least twice the number (Shield 10, Explosive Death 12, Health
; 200, physical + magical 100 each). Size = amount / Tier I amount.
DebuffSize(card) {
    static tierOne := Map("shield",3,"explosive death",6,"health",50,"physical and magical resist",50,"physical resist",75,"magical resist",75)
    if !tierOne.Has(card.stat) || !(card.HasProp("amountKnown") && card.amountKnown) || card.amount<=0
        return 0
    return card.amount/tierOne[card.stat]
}

; Medium late game: a Tier II Shield or Explosive Death beats every buff.
CardBeatsBuffs(card) {
    return CardLateMedium() && !CardIsSpeed(card) && CardSelectionView(card).kind="debuff"
        && (card.stat="shield" || card.stat="explosive death") && DebuffSize(card)>=2
}

; Medium late game, red against red: 1 within its cap (Shield and Explosive
; Death have none), 2 past its cap, 3 regen, 4 anything else.
LateDebuffClass(outlook) {
    if outlook.group<=4
        return 1
    if outlook.group=6
        return 2
    return outlook.group=5 || outlook.group=7?3:4
}

; Shared physical + magical while neither resistance has reached its cap.
LateSharedResistOpen(card) {
    global CARD_RESIST_CAP
    return card.stat="physical and magical resist" && MatchModifier("physical")<CARD_RESIST_CAP && MatchModifier("magical")<CARD_RESIST_CAP
}

; Within the caps the BIGGEST card wins (same size: the Easy order). With
; every cap reached: shared physical + magical while both are under the cap,
; otherwise the smallest (the Easy rule: least past its cap). Regen last.
DebuffBetterLate(a,b) {
    oa := DebuffOutlook(a),ob := DebuffOutlook(b)
    ca := LateDebuffClass(oa),cb := LateDebuffClass(ob)
    if ca!=cb
        return ca<cb
    if ca=1 {
        sa := DebuffSize(a),sb := DebuffSize(b)
        if sa!=sb
            return sa>sb
    } else if ca=2 {
        sa := LateSharedResistOpen(a),sb := LateSharedResistOpen(b)
        if sa!=sb
            return sa
    }
    return DebuffBetterEasy(a,b,oa,ob)
}

; True when red card a is an easier pick than red card b.
DebuffBetter(a,b) {
    if CardLateMedium()
        return DebuffBetterLate(a,b)
    return DebuffBetterEasy(a,b,DebuffOutlook(a),DebuffOutlook(b))
}

DebuffBetterEasy(a,b,oa,ob) {
    if oa.group!=ob.group
        return oa.group<ob.group
    ; Two resistance cards keep the shared-first rule and team preference.
    if CardIsResistance(a) && CardIsResistance(b)
        return ResistancePreferred(a,b)
    ; Least far past its own cap (or the smaller total); Health wins a tie.
    if oa.ratio!=ob.ratio
        return oa.ratio<ob.ratio
    if a.stat!=b.stat
        return a.stat="health"
    return a.amount<b.amount
}

CardBetter(a,b) {
    if a.kind="debuff" && b.kind="debuff"
        return DebuffBetter(a,b)
    return CardPreferenceScore(a)<CardPreferenceScore(b)
}

ChooseBestCard(cards) {
    observedGreen := [],views := []
    for index,card in cards {
        card := CardSelectionView(card)
        views.Push(card)
        if CardHasGreenEffect(card)
            observedGreen.Push(index)
    }
    ; Medium, wave 30+: a Tier II Shield or Explosive Death beats every buff;
    ; of two, the bigger.
    pick := 0
    for index,card in views
        if CardBeatsBuffs(card) && (!pick || DebuffSize(card)>DebuffSize(views[pick]))
            pick := index
    if pick
        return pick
    ; Exactly one verified green effect means there is nothing to compare.
    if observedGreen.Length=1
        return observedGreen[1]
    ; Three unreadable cards of one colour (all green or all red): middle card.
    if views.Length=3 {
        sameColour := true
        for card in views
            if card.stat!="unknown" || (card.kind!="buff" && card.kind!="debuff") || card.kind!=views[1].kind
                sameColour := false
        if sameColour
            return 2
    }
    cards := views
    best := 0,hasBuff := false,hasNonSpeed := false
    ordinaryDebuffs := 0,unknown := false
    for card in cards
        if !CardIsSpeed(card) && (observedGreen.Length?CardHasGreenEffect(card):card.kind="buff")
            hasBuff := true
    ; Colour is the first, absolute decision: red rewards never beat green.
    for card in cards {
        if CardIsSpeed(card) || (observedGreen.Length && !CardHasGreenEffect(card)) || (hasBuff && card.kind!="buff")
            continue
        if !CardIsSpeed(card)
            hasNonSpeed := true
        bonus := card.HasProp("secretPortal") && card.secretPortal
        if !hasBuff && card.kind="debuff" && card.stat!="unknown" && !CardIsSpeed(card) && !bonus
            ordinaryDebuffs += 1
    }
    for index,card in cards {
        if CardIsSpeed(card) || (observedGreen.Length && !CardHasGreenEffect(card)) || (hasBuff && card.kind!="buff")
            continue
        ; Unknown cards also count as alternatives to a known Speed debuff.
        if hasNonSpeed && CardIsSpeed(card)
            continue
        if card.kind="unknown" {
            unknown := true
            continue
        }
        if card.kind="debuff" && card.stat="unknown"
            continue
        bonus := card.HasProp("secretPortal") && card.secretPortal
        if !hasBuff && ordinaryDebuffs>=2 && bonus
            continue
        if !best || CardBetter(card,cards[best])
            best := index
    }
    return unknown && !hasBuff?0:best
}

PreferVerifiedGreenChoice(cards,choice) {
    best := ChooseBestCard(cards)
    if best && CardHasGreenEffect(cards[best]) {
        currentGreen := choice.index<=cards.Length && CardHasGreenEffect(cards[choice.index])
        betterTier := (choice.stat="yen" || choice.stat="boss damage")
            && CardPreferenceScore(CardSelectionView(cards[best]))<CardPreferenceScore(CardSelectionView(choice))
        if !CardHasGreenEffect(choice) || !currentGreen || betterTier {
            promoted := cards[best].Clone()
            promoted.index := best
            return promoted
        }
    }
    ; A fresh harmful-Speed reading cannot inherit an older safe classification.
    if choice.index<=cards.Length && CardIsSpeed(cards[choice.index]) {
        blocked := cards[choice.index].Clone()
        blocked.index := choice.index
        return blocked
    }
    return choice
}

FallbackCardChoice(cards) {
    best := ChooseBestCard(cards)
    if best
        return best
    views := []
    for card in cards
        views.Push(CardSelectionView(card))
    for index,card in views
        if !CardIsSpeed(card) && card.kind="buff"
            return index
    ; Readable red cards: the easiest by the projected-total rules.
    for index,card in views
        if !CardIsSpeed(card) && card.kind="debuff" && card.stat!="unknown" && (!best || DebuffBetter(card,views[best]))
            best := index
    if best
        return best
    ; Unreadable cards rank only above Speed. Leaving the vote to its timer
    ; would pick at random, Speed included. Only an all-Speed offer waits.
    for index,card in views
        if !CardIsSpeed(card)
            return index
    return 0
}

WhiteBits(frame, columns := 32, rows := 28) {
    bits := ""
    Loop rows {
        row := A_Index - 1
        Loop columns {
            col := A_Index - 1, hits := 0
            ; Several points per tile resist one antialiased edge pixel.
            for oy in [0.2, 0.5, 0.8] {
                for ox in [0.2, 0.5, 0.8] {
                    x := Min(frame.width - 1, Floor((col + ox) * frame.width / columns))
                    y := Min(frame.height - 1, Floor((row + oy) * frame.height / rows))
                    RGB(frame.At(x, y), &r, &g, &b)
                    hits += r > 200 && g > 200 && b > 200 ? 1 : 0
                }
            }
            bits .= hits >= 2 ? "1" : "0"
        }
    }
    return bits
}

HashText(text) {
    hash := 2166136261
    Loop Parse text
        hash := ((hash ^ Ord(A_LoopField)) * 16777619) & 0xFFFFFFFF
    return Format("{:08x}", hash)
}

CardRectangle(index) {
    ; Detected cards: split the gaps between neighbours; the right card ends at
    ; its own interior edge so modifier-panel words stay outside.
    if spans := DetectedCardSpans() {
        left := index=1?spans[1][1]-15:(spans[index-1][2]+spans[index][1])//2
        right := index=3?spans[3][2]:(spans[index][2]+spans[index+1][1])//2
        return [left,175,right,445]
    }
    bounds := [[125,175,310,445], [310,175,500,445], [500,175,690,445]]
    return bounds[index]
}

CardVisual(index) {
    frame := RefPixels(CardRectangle(index)*)
    return frame.valid ? WhiteBits(frame) : ""
}

ReadCardMemory(bits) {
    global gCardMemory
    if bits = "" || StrLen(StrReplace(bits, "0")) < 8
        return false
    key := "card." HashText(bits)
    if gCardMemory.Has(key) && gCardMemory[key].bits = bits
        return gCardMemory[key].card
    if MemoryRead(key, "bits") != bits
        return false
    kind := MemoryRead(key, "kind"), stat := MemoryRead(key, "stat")
    if MemoryRead(key,"policy_version","0")!="9" && (MemoryRead(key,"source")!="taught" || kind="buff")
        return false
    if kind != "buff" && kind != "debuff"
        return false
    card := {kind: kind, stat: stat, rank: CardRank(kind, stat), amount: Number(MemoryRead(key, "amount", "0")), text: MemoryRead(key, "text"), secretPortal:MemoryRead(key,"secret_portal","0")="1"}
    savedTier := MemoryRead(key,"tier","1")
    card.tier := IsInteger(savedTier)?Max(1,Min(10,Integer(savedTier))):1
    parsed := CardPolicy(card.text,kind="buff",kind)
    parsed.secretPortal := parsed.secretPortal || card.secretPortal
    parsed.tier := card.tier
    if CardIsResistance(parsed) && MemoryRead(key,"resistance_known","0")="1" {
        physical := Number(MemoryRead(key,"resistance_physical","0")),magical := Number(MemoryRead(key,"resistance_magical","0"))
        parsed.resistance := {known:true,physical:physical,magical:magical,physicalRead:true,magicalRead:true,
            total:Max(0,physical)+Max(0,magical),peak:Max(0,physical,magical)}
    }
    card := parsed
    gCardMemory[key] := {bits: bits, card: card}
    return card
}

RememberCard(bits, card, source := "OCR") {
    global LEARNING_FILE, gCardMemory
    if bits = "" || card.kind = "unknown" || card.stat = "unknown"
        return
    key := "card." HashText(bits)
    for field, value in Map("bits", bits, "kind", card.kind, "stat", card.stat, "amount", card.amount, "text", card.text, "source", source)
        IniWrite value, LEARNING_FILE, key, field
    IniWrite "9",LEARNING_FILE,key,"policy_version"
    IniWrite card.HasProp("tier")?card.tier:1,LEARNING_FILE,key,"tier"
    IniWrite card.HasProp("secretPortal") && card.secretPortal?"1":"0",LEARNING_FILE,key,"secret_portal"
    resistance := card.HasProp("resistance")?card.resistance:ParseResistanceEffects(card.text)
    IniWrite resistance.known?"1":"0",LEARNING_FILE,key,"resistance_known"
    if resistance.known {
        IniWrite resistance.physical,LEARNING_FILE,key,"resistance_physical"
        IniWrite resistance.magical,LEARNING_FILE,key,"resistance_magical"
    }
    gCardMemory[key] := {bits: bits, card: card}
    Log("Learned card: " card.kind " / " card.stat " (" source ")")
}

TeachCurrentCard(*) {
    global gTeachCard, gTeachKind, gTeachStat
    hwnd := FindRoblox()
    if !hwnd
        return
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,, 2) || !HasCardChoice() {
        Notify("A three-card choice must be visible before teaching it.")
        return
    }
    bits := CardVisual(gTeachCard.Value)
    kind := gTeachKind.Text, stat := gTeachStat.Text
    if CardRank(kind, stat) = 99 {
        Notify("Choose a stat from the selected buff/debuff priority list.")
        return
    }
    tier := 1
    if kind="buff" {
        titleText := ""
        for row in ReadOcrRows(CardRectangle(gTeachCard.Value)*)
            titleText .= " " row.text
        tier := BuffTitleTier(titleText)
    }
    RememberCard(bits, {kind:kind,stat:stat,rank:CardRank(kind,stat),amount:0,text:"manually taught " stat,tier:tier}, "taught")
    Notify("Card remembered. The running macro will use it on its next check.")
}

BitOverlap(a, b) {
    if StrLen(a) != StrLen(b) || a = ""
        return 0
    intersection := 0, union := 0
    Loop StrLen(a) {
        one := SubStr(a, A_Index, 1) = "1", two := SubStr(b, A_Index, 1) = "1"
        if one || two
            union += 1
        if one && two
            intersection += 1
    }
    return union ? intersection / union : 0
}

PlacementContextMatches(old, current) {
    if old.map != current.map || old.w != current.w || old.h != current.h || old.dpi != current.dpi
        return false
    if MapDistance(old.px, old.py, current.px, current.py) > 3
        return false
    if old.hx * current.hx + old.hy * current.hy < 0.97
        return false
    return BitOverlap(old.scene, current.scene) >= 0.88
}

PreparePlacementMemory() {
    global LEARNING_FILE, gPlacementProfile, gMapKey
    gPlacementProfile := "", gMapKey := ""
    global gMapModel,gCameraOverheadReady
    if !gMapModel || !gMapModel.player || !gCameraOverheadReady
        return
    geometry := WindowGeometry()
    if !geometry
        return
    p := gMapModel.player
    px := p.x,py := p.y,hx := p.hx,hy := p.hy
    route := MapBits(gMapModel.nodes),scene := route
    gMapKey := "minimap-" gMapModel.id "-" gCameraOverheadReady
    title := "minimap variant " gMapModel.id
    current := {map: gMapKey, w: geometry.w, h: geometry.h, dpi: geometry.dpi, px: px, py: py, hx: hx, hy: hy, scene: scene}
    indexSection := "map." gMapKey
    names := MemoryRead(indexSection, "profiles")
    for name in StrSplit(names, ",") {
        if name = ""
            continue
        section := "profile." name
        values := StrSplit(MemoryRead(section, "pose"), ",")
        dims := StrSplit(MemoryRead(section, "window"), ",")
        if values.Length != 4 || dims.Length != 3
            continue
        old := {map: gMapKey, w: Number(dims[1]), h: Number(dims[2]), dpi: Number(dims[3]), px: Number(values[1]), py: Number(values[2]), hx: Number(values[3]), hy: Number(values[4]), scene: MemoryRead(section, "scene")}
        if PlacementContextMatches(old, current) {
            gPlacementProfile := section
            Log("Placement memory matched map " (title = "" ? gMapKey : title) " and current camera/player pose.")
            return
        }
    }
    ; Cap each map's view profiles; evicted entries are harmless and not reused.
    profileId := gMapKey "-" HashText(scene "," Round(px) "," Round(py) "," Round(hx,1) "," Round(hy,1) "," geometry.w "," geometry.h "," geometry.dpi)
    gPlacementProfile := "profile." profileId
    profileNames := StrSplit(names, ",")
    while profileNames.Length >= 24
        profileNames.RemoveAt(1)
    nextNames := ""
    for name in profileNames {
        if name != "" && name != profileId
            nextNames .= name ","
    }
    IniWrite nextNames profileId, LEARNING_FILE, indexSection, "profiles"
    IniWrite title = "" ? "route fingerprint" : title, LEARNING_FILE, indexSection, "name"
    IniWrite geometry.w "," geometry.h "," geometry.dpi, LEARNING_FILE, gPlacementProfile, "window"
    IniWrite Round(px,2) "," Round(py,2) "," Round(hx,3) "," Round(hy,3), LEARNING_FILE, gPlacementProfile, "pose"
    IniWrite scene, LEARNING_FILE, gPlacementProfile, "scene"
    Log("New placement profile for map " (title = "" ? gMapKey : title) ". Confirmed placements will be remembered.")
}

PlacementSection(unit) {
    global gPlacementProfile
    return gPlacementProfile ".unit." HashText(unit.slot ":" unit.name)
}

ReadPlacementRecords(unit) {
    records := []
    for value in StrSplit(MemoryRead(PlacementSection(unit), "points"), ";") {
        fields := StrSplit(value, ",")
        if fields.Length = 4 && IsNumber(fields[1]) && IsNumber(fields[2]) && IsNumber(fields[3]) && IsNumber(fields[4])
            records.Push({x: Number(fields[1]), y: Number(fields[2]), good: Number(fields[3]), bad: Number(fields[4])})
    }
    return records
}

WritePlacementRecords(unit, records) {
    global LEARNING_FILE
    text := ""
    for record in records
        text .= (text = "" ? "" : ";") Round(record.x) "," Round(record.y) "," record.good "," record.bad
    IniWrite text, LEARNING_FILE, PlacementSection(unit), "points"
}

CandidateOccupied(x, y) {
    global gPlacements
    for item in gPlacements {
        if !PlacementAnchorKnown(item)
            continue
        ; A Money unit is about 3 units across: others keep ~2 spacings away.
        if MapDistance(x,y,item.x,item.y) < (item.HasProp("money") && item.money?48:24)
            return true
    }
    return false
}

KnownPlacementCandidates(unit) {
    global gPlacementProfile, REF_W, REF_H
    candidates := []
    geometry := WindowGeometry()
    if gPlacementProfile = "" || !geometry
        return candidates
    records := ReadPlacementRecords(unit)
    for index, record in records {
        if record.good < 1 || record.bad >= 3
            continue
        x := (record.x - (geometry.cx - geometry.x)) * REF_W / geometry.cw
        y := (record.y - (geometry.cy - geometry.y)) * REF_H / geometry.ch
        if x > 45 && x < 755 && y > 80 && y < 495 && !CandidateOccupied(x,y)
            candidates.Push({x: Round(x), y: Round(y), memoryIndex: index})
    }
    return candidates
}

RememberPlacement(unit, candidate, success := true) {
    global gPlacementProfile, REF_W, REF_H
    if gPlacementProfile = ""
        return
    records := ReadPlacementRecords(unit)
    if !success {
        if candidate.HasProp("memoryIndex") && candidate.memoryIndex <= records.Length {
            records[candidate.memoryIndex].bad += 1
            WritePlacementRecords(unit, records)
            Log("Cached placement rejected by red bubble; failure recorded.")
        }
        return
    }
    geometry := WindowGeometry()
    if !geometry
        return
    wx := geometry.cx - geometry.x + candidate.x * geometry.cw / REF_W
    wy := geometry.cy - geometry.y + candidate.y * geometry.ch / REF_H
    for record in records {
        if MapDistance(wx,wy,record.x,record.y) < 6 {
            record.good += 1
            record.bad := 0
            WritePlacementRecords(unit, records)
            return
        }
    }
    if records.Length >= 80
        records.RemoveAt(1)
    records.Push({x: wx, y: wy, good: 1, bad: 0})
    WritePlacementRecords(unit, records)
    Log("Learned confirmed " unit.name " placement at window " Round(wx) "," Round(wy))
}

; Hill spot outcomes per map profile (same map, window, camera and pose).
; A Hill spot is skipped in later matches only after failed purchases in two
; matches in a row; any purchase that succeeds there clears it. One miss can
; be a card or timing, and a spot that has worked stays usable.
ReadHillMisses() {
    global gPlacementProfile
    records := []
    if gPlacementProfile = ""
        return records
    for value in StrSplit(MemoryRead(gPlacementProfile, "hillmiss"), ";") {
        fields := StrSplit(value, ",")
        if fields.Length = 3 && IsNumber(fields[1]) && IsNumber(fields[2]) && IsNumber(fields[3])
            records.Push({x: Number(fields[1]), y: Number(fields[2]), bad: Number(fields[3])})
    }
    return records
}

RememberHillOutcome(point, success) {
    global gPlacementProfile, LEARNING_FILE, REF_W, REF_H, FAILED_PLACEMENT_RADIUS
    geometry := WindowGeometry()
    if gPlacementProfile = "" || !geometry
        return
    wx := geometry.cx - geometry.x + point.x * geometry.cw / REF_W
    wy := geometry.cy - geometry.y + point.y * geometry.ch / REF_H
    radius := FAILED_PLACEMENT_RADIUS * geometry.cw / REF_W
    records := ReadHillMisses(), found := 0
    for index, record in records
        if MapDistance(wx, wy, record.x, record.y) <= radius {
            found := index
            break
        }
    if success {
        if !found
            return
        records.RemoveAt(found)
    } else if found
        records[found].bad += 1
    else {
        if records.Length >= 40
            records.RemoveAt(1)
        records.Push({x: wx, y: wy, bad: 1})
    }
    text := ""
    for record in records
        text .= (text = "" ? "" : ";") Round(record.x) "," Round(record.y) "," record.bad
    IniWrite text, LEARNING_FILE, gPlacementProfile, "hillmiss"
}

; At match start (after the per-game failed spots are cleared): Hill spots
; that failed in two matches in a row on this map are skipped from the start.
LoadRememberedHillMisses() {
    global gFailedPlacementSpots, REF_W, REF_H
    geometry := WindowGeometry()
    if !geometry
        return
    skipped := 0
    for record in ReadHillMisses() {
        if record.bad < 2
            continue
        x := (record.x - (geometry.cx - geometry.x)) * REF_W / geometry.cw
        y := (record.y - (geometry.cy - geometry.y)) * REF_H / geometry.ch
        gFailedPlacementSpots.Push({x: Round(x), y: Round(y), terrain: "hill"})
        skipped += 1
    }
    if skipped
        Log("Skipping " skipped " Hill spot(s) that failed in two matches in a row on this map.")
}

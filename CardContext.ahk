; Word colours classify cards. Right-hand modifiers are separate read-only context.
global CARD_PREFS_FILE := A_ScriptDir "\card_preferences.ini"
global gResistancePreference := "balanced",gMagicTeamControl := 0,gPhysicalTeamControl := 0
global gMatchModifiers := {health:0,healthKnown:false,physical:0,magical:0},gModifierReadAt := 0

BuildCardPreferencesTab(app) {
    global CARD_PREFS_FILE,gResistancePreference,gMagicTeamControl,gPhysicalTeamControl
    try saved := IniRead(CARD_PREFS_FILE,"Cards","damage_preference","balanced")
    catch
        saved := "balanced"
    gResistancePreference := saved="magic" || saved="physical"?saved:"balanced"
    app.AddText("x28 y145 w410 h45","Damage preference changes resistance choices only. Buffs always come first; positive enemy Speed is never selected.")
    gMagicTeamControl := app.AddCheckbox("x28 y202 w410" (saved="magic"?" Checked":""),"Magic team: prefer physical resistance debuffs")
    gPhysicalTeamControl := app.AddCheckbox("x28 y238 w410" (saved="physical"?" Checked":""),"Physical team: prefer magical resistance debuffs")
    gMagicTeamControl.OnEvent("Click",CardDamagePreferenceChanged.Bind("magic"))
    gPhysicalTeamControl.OnEvent("Click",CardDamagePreferenceChanged.Bind("physical"))
    app.AddText("x28 y286 w410 h95","Leave both off for balanced resistance choices. Both percentages on a combined card are added. Current physical/magical totals break ties. At 250% displayed enemy Health, prefer other safe debuffs before adding more Health.")
    app.AddText("x28 y399 w410 h95","Hill only: highlighted Hill terrain is required. Hybrid: try Hill first, then normal ground. A Hill-only unit without space stays unplaced while the other units continue.")
}

CardDamagePreferenceChanged(which,*) {
    global gMagicTeamControl,gPhysicalTeamControl,gResistancePreference,CARD_PREFS_FILE
    selected := which="magic"?gMagicTeamControl:gPhysicalTeamControl
    other := which="magic"?gPhysicalTeamControl:gMagicTeamControl
    if selected.Value
        other.Value := 0
    gResistancePreference := selected.Value?which:"balanced"
    IniWrite gResistancePreference,CARD_PREFS_FILE,"Cards","damage_preference"
}

ResetMatchCardContext() {
    global gMatchModifiers,gModifierReadAt
    gMatchModifiers := {health:0,healthKnown:false,physical:0,magical:0},gModifierReadAt := 0
}

SignedHealthChange(text,&found) {
    found := false,text := NormalizeWords(text)
    if RegExMatch(text,"(?:enemy\s+)?health\s*:?\s*([+-]?\s*\d+(?:\.\d+)?)\s*%",&m)
        || RegExMatch(text,"([+-]?\s*\d+(?:\.\d+)?)\s*%\s*(?:enemy\s+)?health",&m) {
        found := true
        return Number(StrReplace(m[1]," "))
    }
    return 0
}

ParseMatchModifiers(rows) {
    result := {health:0,healthKnown:false,physical:0,magical:0,physicalKnown:false,magicalKnown:false},text := ""
    for row in rows {
        line := NormalizeWords(row.text),text .= " " line
        value := SignedHealthChange(line,&found)
        if found
            result.health := value,result.healthKnown := true
    }
    for row in rows {
        resistance := ParseResistanceEffects(row.text)
        if resistance.physicalRead
            result.physical := resistance.physical,result.physicalKnown := true
        if resistance.magicalRead
            result.magical := resistance.magical,result.magicalKnown := true
    }
    return result
}

RefreshMatchModifiers() {
    global gRunning,gModifierReadAt,gMatchModifiers,gUnitManagerPhase
    ; The open F manager covers this panel, so it is never read once upgrades
    ; start (card effects are still added as they are chosen). During
    ; placement the values only change with cards, so a 30 s re-read is
    ; plenty: each OCR read costs up to a second between placement actions.
    if !gRunning || A_TickCount<gModifierReadAt || HasCardChoice() || (IsSet(gUnitManagerPhase) && gUnitManagerPhase)
        return
    gModifierReadAt := A_TickCount+30000
    ; This crop is NEVER passed to card selection, card detection or clicking.
    snapshot := ParseMatchModifiers(ReadOcrRows(635,210,785,455))
    if snapshot.healthKnown
        gMatchModifiers.health := snapshot.health,gMatchModifiers.healthKnown := true
    if snapshot.physicalKnown
        gMatchModifiers.physical := snapshot.physical
    if snapshot.magicalKnown
        gMatchModifiers.magical := snapshot.magical
}

ApplySelectedCardModifiers(card) {
    global gMatchModifiers,gModifierReadAt
    if CardIsResistance(card) {
        effects := card.HasProp("resistance")?card.resistance:ParseResistanceEffects(card.text)
        if effects.known
            gMatchModifiers.physical += effects.physical,gMatchModifiers.magical += effects.magical
    }
    if card.stat="health" && RegExMatch(card.text,"enemy|enemies") {
        value := SignedHealthChange(card.text,&found)
        if found
            gMatchModifiers.health += value,gMatchModifiers.healthKnown := true
    }
    gModifierReadAt := A_TickCount+2500
}

CardHasForbiddenSpeed(text) {
    text := NormalizeWords(text)
    enemySpeed := RegExMatch(text,"\b(?:enemy|enemies|movement)\s+(?:movement\s+)?speed\b|^speed\b")
    return enemySpeed && !EnemyStatReduction(text,"speed")
}

; Card interiors are measured once per card screen (MinimapVision cardboxes):
; the dark panels give exact X spans, and the right card is placed by the
; spacing of the other two, so the Level Modifiers panel never leaks into it.
; Without a detection the fixed 800x600 layout is used.
RefreshCardBoxes() {
    global gCardBoxes
    ; Up to three tries per card screen (cards may still be sliding in).
    if IsSet(gCardBoxes) && gCardBoxes && (gCardBoxes.detected || gCardBoxes.tries>=3)
        return gCardBoxes
    gCardBoxes := {detected:false,tries:(IsSet(gCardBoxes) && gCardBoxes?gCardBoxes.tries:0)+1}
    if !GetClient(&cx,&cy,&cw,&ch)
        return gCardBoxes
    reply := VisionRequest("cardboxes " cx " " cy " " cw " " ch)
    if VisionOk(reply) && reply.Has("boxes") {
        spans := []
        for part in StrSplit(reply["boxes"],";") {
            xy := StrSplit(part,",")
            if xy.Length=2
                spans.Push([Max(122,Number(xy[1])),Min(688,Number(xy[2]))])
        }
        if spans.Length=3 {
            gCardBoxes := {detected:true,spans:spans}
            Log("Card interiors at x " reply["boxes"] " (reference 800x600).")
        }
    }
    return gCardBoxes
}

DetectedCardSpans() {
    global gCardBoxes
    return IsSet(gCardBoxes) && gCardBoxes && gCardBoxes.detected?gCardBoxes.spans:0
}

CardEffectBounds(index) {
    if spans := DetectedCardSpans()
        return [spans[index][1]+4,188,spans[index][2]-4,425]
    return [[129,188,290,425],[320,188,482,425],[512,188,674,425]][index]
}

EffectWordInk(frame,x1,y1,x2,y2) {
    if !frame.valid
        return "unknown"
    green := 0,red := 0,y := y1
    while y<=y2 {
        x := x1
        while x<=x2 {
            RGB(frame.AtRef(x,y),&r,&g,&b)
            green += g>90 && g-r>30 && g-b>15?1:0
            red += r>100 && r-g>35 && r-b>25?1:0
            x += 1
        }
        y += 1
    }
    if green>=3 && green>red*1.3
        return "buff"
    if red>=3 && red>=green
        return "debuff"
    return "unknown"
}

CardWordRows(words,index,frame,geometry) {
    global REF_W,REF_H
    bounds := CardEffectBounds(index),outer := CardRectangle(index),lines := []
    for word in words {
        x1 := word.x*REF_W/geometry.cw,y1 := word.y*REF_H/geometry.ch
        x2 := (word.x+word.w)*REF_W/geometry.cw,y2 := (word.y+word.h)*REF_H/geometry.ch
        middle := (x1+x2)/2,cy := (y1+y2)/2
        if middle<outer[1] || middle>=outer[3] || cy<bounds[2] || cy>bounds[4]
            continue
        line := 0
        for existing in lines
            if Abs(existing.y-cy)<=6 {
                line := existing
                break
            }
        if !line {
            line := {y:cy,left:x1,text:"",green:0,red:0,valid:true}
            lines.Push(line)
        }
        ; A right-panel line extends outside the actual card interior: reject
        ; its entire line, including an early word that fits the card crop.
        if x1<bounds[1] || x2>bounds[3]
            line.valid := false
        line.left := Min(line.left,x1)
        line.text .= (line.text=""?"":" ") NormalizeWords(word.text)
        if x1>=bounds[1] && x2<=bounds[3] {
            ink := EffectWordInk(frame,Round(x1),Round(y1),Round(x2),Round(y2))
            line.green += ink="buff"?1:0,line.red += ink="debuff"?1:0
        }
    }
    return lines
}

SharedNumericCardLine(line,allRows) {
    if RegExMatch(line.text,"[a-z]") || !RegExMatch(line.text,"\d") || InStr(line.text,"-")
        return false
    for lines in allRows {
        found := false
        for other in lines
            if other.valid && Abs(other.y-line.y)<=6 && other.text=line.text {
                found := true
                break
            }
        if !found
            return false
    }
    return true
}

ReadWordColourCards(words,frame,geometry) {
    cards := [],allRows := []
    Loop 3
        allRows.Push(CardWordRows(words,A_Index,frame,geometry))
    Loop 3 {
        index := A_Index,lines := allRows[index]
        fullText := "",effectLines := [],green := false,red := false,redSpeed := false
        for line in lines {
            if !line.valid || (index=3 && !DetectedCardSpans() && line.left>=635) || RegExMatch(line.text,"secret|portal|drop rate|summer|pearl|reward|multiplier")
                || SharedNumericCardLine(line,allRows)
                continue
            fullText .= " " line.text
            effectLines.Push(line.text)
            ; Percentage-only effect lines are still coloured evidence.
            ; Their minus may be separate from, or missed by, the OCR word.
            if !RegExMatch(line.text,"[a-z]{2}|\d")
                continue
            green := green || line.green>0
            red := red || line.red>0
            if line.red && CardHasForbiddenSpeed(line.text)
                redSpeed := true
        }
        kind := green?"buff":red?"debuff":"unknown"
        ; OCR missed the words' colour: bright green glyph pixels still mean green.
        ; Likewise bright red glyphs mean red words (used for three unreadable
        ; red cards, where the middle card is taken).
        if kind="unknown" {
            ink := CardPixelInk(frame,index)
            kind := CardPixelIsGreen(ink)?"buff":CardPixelIsRed(ink)?"debuff":"unknown"
        }
        card := CardPolicy(fullText,kind="buff",kind)
        if kind!="unknown"
            card.kind := kind,card.rank := CardRank(kind,card.stat)
        card.resistance := CombineResistanceLines(effectLines)
        card.forbiddenSpeed := CardHasForbiddenSpeed(fullText)
        card.redSpeedEffect := redSpeed
        card.effectInk := kind
        cards.Push(card)
    }
    return cards
}

; Bright title/effect glyph pixels inside one card, inset from its frame.
; Shared white reward lines and the dark interior count as neither colour.
CardPixelInk(frame,index) {
    ink := {green:0,red:0}
    if !frame || !frame.valid
        return ink
    bounds := CardEffectBounds(index)
    y := bounds[2]+10
    while y<=bounds[2]+122 {
        x := bounds[1]+10
        while x<=bounds[3]-10 {
            RGB(frame.AtRef(x,y),&r,&g,&b)
            if g>170 && g-r>80 && g-b>60
                ink.green += 1
            else if r>170 && r-g>80 && r-b>60
                ink.red += 1
            x += 3
        }
        y += 3
    }
    return ink
}

CardPixelIsGreen(ink) => ink.green>=24 && ink.green>ink.red*3
CardPixelIsRed(ink) => ink.red>=24 && ink.red>ink.green*3

PixelGreenCards(frame) {
    green := []
    Loop 3
        if CardPixelIsGreen(CardPixelInk(frame,A_Index))
            green.Push(A_Index)
    return green
}

; Minimal card records for the pixel-only green decision (no OCR yet).
PixelInkCards(greenIndices) {
    cards := []
    Loop 3 {
        ink := HasValue(greenIndices,A_Index)?"buff":"unknown"
        cards.Push({kind:ink,stat:"unknown",rank:99,amount:0,amountSigned:0,amountKnown:false,text:"green words (pixel read)",
            secretPortal:false,tier:1,effectInk:ink,forbiddenSpeed:false,redSpeedEffect:false,
            resistance:{physical:0,magical:0,physicalRead:false,magicalRead:false,known:false,total:0,peak:0}})
    }
    return cards
}

LogCardDecision(cards,best) {
    global gResistancePreference,gMatchModifiers
    for index,card in cards {
        detail := "Card " index ": " card.effectInk " words / " card.stat
        if card.HasProp("amountKnown") && card.amountKnown
            detail .= " | signed value " (card.amountSigned>=0?"+":"") card.amountSigned
        if CardIsResistance(card) && card.resistance.known
            detail .= " | physical " card.resistance.physical " + magical " card.resistance.magical " = " card.resistance.total
        if CardIsSpeed(card)
            detail .= " | FORBIDDEN SPEED"
        Log(detail)
    }
    Log("Choose card " best " | team " gResistancePreference " | current health " gMatchModifiers.health "% / physical " gMatchModifiers.physical " / magical " gMatchModifiers.magical)
}

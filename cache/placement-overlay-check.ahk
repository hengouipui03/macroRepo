#Requires AutoHotkey v2.0
#SingleInstance Off
class RefPixels {
    __New(*) {
        throw Error("Offline check must provide its saved frame")
    }
}
try {
    frame := SavedFrame(A_ScriptDir "\placement-world.frame")
    if HasCardChoice(frame) != false
        throw Error("Card overlay misclassified world")
    frame := SavedFrame(A_ScriptDir "\placement-cards.frame")
    if HasCardChoice(frame) != true
        throw Error("Card overlay misclassified cards")
    frame := SavedFrame(A_ScriptDir "\placement-cards-window.frame")
    if HasCardChoice(frame) != true
        throw Error("Card overlay misclassified cards-window")
    FileAppend "PASS: world path rejected, real mixed card panels detected in client and window screenshots.`n", "*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n", "*"
    ExitApp 1
}
class SavedFrame {
    valid := true
    __New(path) {
        this.storage := FileRead(path,"RAW")
        this.w := NumGet(this.storage,0,"UInt"), this.h := NumGet(this.storage,4,"UInt")
    }
    AtRef(x,y) {
        px := Round(x*this.w/800), py := Round(y*this.h/600)
        return NumGet(this.storage,8+4*(py*this.w+px),"UInt") & 0xFFFFFF
    }
}
HasCardChoice(frame := 0) {
    ; World paths and enemies are also green/red. Require the two tall,
    ; aligned borders and dark interior of each of the three actual cards.
    if !frame
        frame := RefPixels(110,175,700,435)
    if !frame.valid
        return false
    for bounds in [[123,296],[314,488],[506,680]] {
        if !HasCardBorder(frame,bounds[1]) || !HasCardBorder(frame,bounds[2])
            return false
        dark := 0, centre := (bounds[1]+bounds[2])//2
        for x in [centre-35,centre,centre+35] {
            Loop 8 {
                RGB(frame.AtRef(x,300+(A_Index-1)*15),&r,&g,&b)
                if Max(r,g,b)<75
                    dark += 1
            }
        }
        if dark<18
            return false
    }
    return true
}

HasCardBorder(frame, edgeX) {
    ; A border must persist down one column. Scattered green/red objects
    ; in the world cannot add together to masquerade as that border.
    Loop 21 {
        x := edgeX-11+A_Index, hits := 0
        Loop 21 {
            RGB(frame.AtRef(x,195+A_Index*10),&r,&g,&b)
            if (r>100 && r-g>40 && r-b>25) || (g>95 && g-r>35 && g-b>20)
                hits += 1
        }
        if hits>=15
            return true
    }
    return false
}

RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}

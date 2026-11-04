#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global ground := SavedFrame(A_ScriptDir "\slot2-ground.frame"), current := SavedFrame(A_ScriptDir "\slot2-preview.frame")
try {
    if BubbleState(470,420,ground)!=1
        throw Error("Real blue slot-2 preview on orange terrain was rejected")
    current := ground
    if BubbleState(470,420,ground)!=0
        throw Error("Orange ground without a preview was mistaken for a placement ring")
    FileAppend "PASS: captured slot-2 blue preview accepted on orange terrain; same terrain with no preview returns no placement.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n","*"
    ExitApp 1
}
class SavedFrame {
    valid := true
    __New(path) {
        this.storage := FileRead(path,"RAW")
        this.w := NumGet(this.storage,0,"UInt"), this.h := NumGet(this.storage,4,"UInt")
        this.left := NumGet(this.storage,8,"UInt"), this.top := NumGet(this.storage,12,"UInt")
        this.sx := NumGet(this.storage,16,"UInt")/800, this.sy := NumGet(this.storage,20,"UInt")/600
    }
    AtRef(x,y) {
        px := Max(0,Min(this.w-1,Round(x*this.sx)-this.left))
        py := Max(0,Min(this.h-1,Round(y*this.sy)-this.top))
        return NumGet(this.storage,24+4*(py*this.w+px),"UInt") & 0xFFFFFF
    }
}
CapturePlacementArea(*) {
    global current
    return current
}

BubbleState(rx, ry, baseline := 0) {
    frame := CapturePlacementArea(rx,ry)
    if !frame.valid
        return 0
    blue := 0, red := 0
    y := Max(70,ry-180)
    while y<=Min(495,ry+180) {
        x := Max(0,rx-180)
        while x<=Min(799,rx+180) {
            distance := (x-rx)**2+(y-ry)**2
            ; Ignore the model at the centre and the minimap/side HUD.
            if distance>=20**2 && distance<=180**2 && !(x>=635 && y>=430) {
                color := frame.AtRef(x,y)
                RGB(color,&r,&g,&b)
                oldBlue := 0, oldRed := 0
                if baseline && baseline.valid {
                    RGB(baseline.AtRef(x,y),&br,&bg,&bb)
                    oldBlue := bb-br, oldRed := br-bb
                }
                if IsBubbleBlue(color) && (!baseline || b-r-oldBlue>40)
                    blue += 1
                if IsBubbleRed(color) && (!baseline || r-b-oldRed>55)
                    red += 1
            }
            x += 4
        }
        y += 4
    }
    if blue>=8
        return 1
    return red>=8 ? -1 : 0
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

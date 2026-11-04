#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, Off

; AA Path Macro — first readable AutoHotkey v2 implementation.
; All game positions are relative to Roblox's CLIENT area (800 x 600), never to
; a fixed desktop location.  F6 starts, F7 stops, F8 runs only the camera reset.

CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"
SetTitleMatchMode 2

global REF_W := 800
global REF_H := 600
global WINDOW_W := 1415
global WINDOW_H := 1121
global STATIC_CLICK_MS := 2500
global PREP_CLICK_MS := 1000
global CAMERA_TILT_PIXELS := 420
global BUTTONS_FILE := A_ScriptDir "\\button_positions.ini"
global gRunning := false
global gAttached := false
global gMacroHwnd := 0
global gRobloxDx := 0
global gRobloxDy := 0
global gPlacements := []
global gUnitControls := []
global gStatus
global gActivityLog

; Parse/validation mode performs no window, mouse, or keyboard actions.
if A_Args.Length && A_Args[1] = "--check"
    ExitApp 0
if A_Args.Length && A_Args[1] = "--self-test" {
    try {
        result := RunSelfTests()
        FileAppend result "`n", A_ScriptDir "\navigation-checks.txt", "UTF-8"
        ExitApp 0
    } catch as err {
        FileAppend "FAIL: " err.Message "`n", A_ScriptDir "\navigation-checks.txt", "UTF-8"
        ExitApp 1
    }
}

BuildGui()
OnMessage(0x0003, OnMacroWindowMove) ; WM_MOVE

F6::StartMacro()
F7::StopMacro()
F8::CameraReset()
F9::TestRoutePreparation()

BuildGui() {
    global gMacroHwnd, gUnitControls, gStatus, gActivityLog
    app := Gui("+AlwaysOnTop", "AA Path Macro")
    app.BackColor := "20212D"
    app.SetFont("cFFFFFF s9", "Segoe UI")
    app.AddText("x12 y10 w460", "AA PATH MACRO")
    app.SetFont("cA9AEC0 s8", "Segoe UI")
    app.AddText("x12 y30 w460", "F6 start  •  F7 stop  •  F8 camera  •  F9 route test")
    app.SetFont("cFFFFFF s9", "Segoe UI")
    app.AddButton("x12 y52 w106", "Resize Roblox").OnEvent("Click", ResizeRoblox)
    app.AddButton("x124 y52 w100", "Attach Roblox").OnEvent("Click", AttachRoblox)
    app.AddButton("x230 y52 w100", "Start (F6)").OnEvent("Click", StartMacro)
    app.AddButton("x336 y52 w100", "Stop (F7)").OnEvent("Click", StopMacro)
    app.AddText("x12 y84 w430", "1415 × 1121 window • 1s preparation • F8 camera reset only")

    tabs := app.AddTab3("x12 y106 w452 h458", ["Control", "Activity"])
    tabs.UseTab(1)

    gUnitControls := []
    Loop 6 {
        slot := A_Index
        col := Mod(slot - 1, 2)
        row := Floor((slot - 1) / 2)
        gx := 12 + col * 232
        gy := 136 + row * 137
        app.AddGroupBox("x" gx " y" gy " w220 h132", "Slot " slot)
        enabled := app.AddCheckbox("x" (gx + 10) " y" (gy + 22) " Checked", "Enabled")
        name := AddReadableEdit(app, "x" (gx + 82) " y" (gy + 18) " w124", "Unit " slot)
        app.AddText("x" (gx + 10) " y" (gy + 51) " w84", "Placements")
        count := AddReadableEdit(app, "x" (gx + 99) " y" (gy + 47) " w45 Number", "1")
        app.AddUpDown("Range0-30", 1)
        app.AddText("x" (gx + 152) " y" (gy + 51) " w55", "copies")
        app.AddText("x" (gx + 10) " y" (gy + 78) " w84", "Priority")
        priority := AddReadableEdit(app, "x" (gx + 99) " y" (gy + 74) " w45 Number", slot)
        app.AddUpDown("Range1-99", slot)
        app.AddText("x" (gx + 10) " y" (gy + 105) " w106", "Upgrade target")
        target := AddReadableEdit(app, "x" (gx + 120) " y" (gy + 101) " w45 Number", "99")
        app.AddUpDown("Range0-99", 99)
        app.AddText("x" (gx + 170) " y" (gy + 105) " w38", "99=MAX")
        gUnitControls.Push({slot: slot, enabled: enabled, name: name, count: count, priority: priority, target: target})
    }
    tabs.UseTab(2)
    app.AddText("x28 y140 w400", "Live action log — newest actions appear at the bottom")
    gActivityLog := app.AddEdit("x28 y166 w414 h365 ReadOnly VScroll -Wrap c20212D BackgroundFFFFFF", "")
    tabs.UseTab()
    gStatus := app.AddText("x12 y572 w452", "Status: waiting for Roblox")
    app.OnEvent("Close", (*) => ExitApp())
    app.Show("w476 h602 x20 y20")
    gMacroHwnd := app.Hwnd
    RefreshStatus()
}

AddReadableEdit(app, options, value) {
    control := app.AddEdit(options " c20212D BackgroundFFFFFF", value)
    control.SetFont("c20212D s9", "Segoe UI")
    return control
}

; -----------------------------------------------------------------------------
; Window attachment and client-relative coordinate conversion
; -----------------------------------------------------------------------------

FindRoblox() {
    hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
    if !hwnd
        hwnd := WinExist("Roblox")
    return hwnd
}

GetClient(&x, &y, &w, &h) {
    hwnd := FindRoblox()
    if !hwnd
        return false
    try WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
    catch
        return false
    return w > 200 && h > 200
}

; Convert a reference point in the 800 x 600 Roblox client to a live screen point.
ToScreen(rx, ry, &sx, &sy) {
    global REF_W, REF_H
    if !GetClient(&cx, &cy, &cw, &ch)
        return false
    sx := cx + Round(rx * cw / REF_W)
    sy := cy + Round(ry * ch / REF_H)
    return true
}

MoveRef(rx, ry, speed := 0) {
    if ToScreen(rx, ry, &sx, &sy)
        MouseMove sx, sy, speed
}

ClickRef(rx, ry) {
    if !ToScreen(rx, ry, &sx, &sy)
        return false
    WinActivate "ahk_id " FindRoblox()
    MouseMove sx, sy, 0
    ; Roblox can miss a down/up pair delivered within the same frame.
    Click "Down"
    Sleep 80
    Click "Up"
    Log("Click at client " rx ", " ry)
    return true
}

ButtonPosition(name, &rx, &ry) {
    global BUTTONS_FILE
    value := IniRead(BUTTONS_FILE, "Buttons", name, "")
    parts := StrSplit(value, ",")
    if parts.Length != 2
        return false
    rx := Integer(Trim(parts[1]))
    ry := Integer(Trim(parts[2]))
    return true
}

ClickButton(name, delayMs := -1) {
    global STATIC_CLICK_MS, gRunning
    if !ButtonPosition(name, &rx, &ry) {
        Log("Missing button position: " name)
        return false
    }
    Log("Static button: " name)
    if !ClickRef(rx, ry)
        return false
    return ActionPause(delayMs < 0 ? STATIC_CLICK_MS : delayMs)
}

ActionPause(durationMs) {
    global gRunning
    deadline := A_TickCount + durationMs
    while gRunning && A_TickCount < deadline
        Sleep Min(40, deadline - A_TickCount)
    return gRunning
}

ResizeRoblox(*) {
    global WINDOW_W, WINDOW_H
    hwnd := FindRoblox()
    if !hwnd {
        Notify("Roblox was not found.")
        return
    }
    ; The requested size is the complete window, including its title bar.
    WinRestore "ahk_id " hwnd
    WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
    if !GetClient(&cx, &cy, &cw, &ch) {
        Notify("Could not read the Roblox client area.")
        return
    }
    WinMove wx, wy, WINDOW_W, WINDOW_H, "ahk_id " hwnd
    Sleep 250
    RefreshStatus()
}

AttachRoblox(*) {
    global gAttached, gMacroHwnd, gRobloxDx, gRobloxDy
    hwnd := FindRoblox()
    if !hwnd {
        Notify("Open Roblox first.")
        return
    }
    WinGetPos(&mx, &my,,, "ahk_id " gMacroHwnd)
    WinGetPos(&rx, &ry,,, "ahk_id " hwnd)
    gRobloxDx := rx - mx
    gRobloxDy := ry - my
    gAttached := true
    Notify("Roblox attached to this panel.")
}

; Preserve Roblox's offset whenever the macro panel is moved.
OnMacroWindowMove(wParam, lParam, msg, hwnd) {
    global gAttached, gMacroHwnd, gRobloxDx, gRobloxDy
    if !gAttached || hwnd != gMacroHwnd
        return
    roblox := FindRoblox()
    if !roblox
        return
    WinGetPos(&mx, &my,,, "ahk_id " gMacroHwnd)
    try WinMove mx + gRobloxDx, my + gRobloxDy,,, "ahk_id " roblox
}

RefreshStatus(*) {
    global gStatus
    if GetClient(&cx, &cy, &cw, &ch)
        gStatus.Value := "Status: Roblox client " cw " × " ch " at " cx ", " cy
    else
        gStatus.Value := "Status: waiting for Roblox"
}

; -----------------------------------------------------------------------------
; Colour checks.  These deliberately use broad colour ranges because Roblox
; lighting varies.  They are restricted to small client-relative regions.
; -----------------------------------------------------------------------------

RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}

IsRouteGreen(color) {
    RGB(color, &r, &g, &b)
    return g > 185 && r > 45 && r < 205 && b < 105 && (g - r) > 50
}

IsUiGreen(color) {
    RGB(color, &r, &g, &b)
    return g > 150 && r < 150 && b < 155 && (g - r) > 45
}

IsBubbleBlue(color) {
    RGB(color, &r, &g, &b)
    return b > 150 && g > 110 && r < 115 && (b - r) > 75
}

IsBubbleRed(color) {
    RGB(color, &r, &g, &b)
    return r > 160 && g < 175 && b < 150 && (r - g) > 45
}

IsUiRed(color) {
    RGB(color, &r, &g, &b)
    return r > 180 && g < 100 && b < 105
}

IsUiYellow(color) {
    RGB(color, &r, &g, &b)
    return r > 185 && g > 135 && b < 115
}

IsMiniMapRouteGreen(color) {
    RGB(color, &r, &g, &b)
    return g > 145 && r < 170 && b < 135 && (g - r) > 45
}

IsMiniMapPlayerWhite(color) {
    RGB(color, &r, &g, &b)
    return r > 205 && g > 205 && b > 205
}

CountRef(rx1, ry1, rx2, ry2, step, predicate) {
    ; Capture once, then sample memory. Thousands of separate PixelGetColor
    ; calls made an otherwise static menu check take several seconds.
    frame := RefPixels(rx1, ry1, rx2, ry2)
    if !frame.valid
        return 0
    total := 0
    y := ry1
    while y <= ry2 {
        x := rx1
        while x <= rx2 {
            if predicate.Call(frame.AtRef(x, y))
                total += 1
            x += step
        }
        y += step
    }
    return total
}

class RefPixels {
    valid := false
    dc := 0
    bitmap := 0
    oldBitmap := 0
    __New(rx1, ry1, rx2, ry2) {
        global REF_W, REF_H
        if !GetClient(&cx, &cy, &cw, &ch)
            return
        this.scaleX := cw / REF_W, this.scaleY := ch / REF_H
        this.left := Round(rx1 * this.scaleX), this.top := Round(ry1 * this.scaleY)
        this.width := Round(rx2 * this.scaleX) - this.left + 1
        this.height := Round(ry2 * this.scaleY) - this.top + 1
        info := Buffer(40, 0)
        NumPut("UInt", 40, "Int", this.width, "Int", -this.height, "UShort", 1, "UShort", 32, info)
        screen := DllCall("GetDC", "Ptr", 0, "Ptr")
        try {
            this.dc := DllCall("gdi32\CreateCompatibleDC", "Ptr", screen, "Ptr")
            bits := 0
            this.bitmap := DllCall("gdi32\CreateDIBSection", "Ptr", screen, "Ptr", info, "UInt", 0, "Ptr*", &bits, "Ptr", 0, "UInt", 0, "Ptr")
            this.bits := bits
            if !this.dc || !this.bitmap || !bits
                return
            this.oldBitmap := DllCall("gdi32\SelectObject", "Ptr", this.dc, "Ptr", this.bitmap, "Ptr")
            this.valid := DllCall("gdi32\BitBlt", "Ptr", this.dc, "Int", 0, "Int", 0, "Int", this.width, "Int", this.height, "Ptr", screen, "Int", cx + this.left, "Int", cy + this.top, "UInt", 0x00CC0020)
        } finally DllCall("ReleaseDC", "Ptr", 0, "Ptr", screen)
    }
    At(x, y) {
        return NumGet(this.bits + (y * this.width + x) * 4, "UInt") & 0xFFFFFF
    }
    AtRef(rx, ry) {
        x := Max(0, Min(this.width - 1, Round(rx * this.scaleX) - this.left))
        y := Max(0, Min(this.height - 1, Round(ry * this.scaleY) - this.top))
        return this.At(x, y)
    }
    __Delete() {
        if this.oldBitmap
            DllCall("gdi32\SelectObject", "Ptr", this.dc, "Ptr", this.oldBitmap, "Ptr")
        if this.bitmap
            DllCall("gdi32\DeleteObject", "Ptr", this.bitmap)
        if this.dc
            DllCall("gdi32\DeleteDC", "Ptr", this.dc)
    }
}

FindUiGreenCentre(rx1, ry1, rx2, ry2, &centreX, &centreY) {
    frame := RefPixels(rx1, ry1, rx2, ry2)
    if !frame.valid
        return false
    sumX := 0, sumY := 0, hits := 0
    y := ry1
    while y <= ry2 {
        x := rx1
        while x <= rx2 {
            if IsUiGreen(frame.AtRef(x, y)) {
                sumX += x, sumY += y, hits += 1
            }
            x += 5
        }
        y += 5
    }
    if hits < 8
        return false
    centreX := Round(sumX / hits), centreY := Round(sumY / hits)
    return true
}

RouteVisible() {
    ; Main playfield only; avoids the hotbar, health bar, and minimap.
    return CountRef(35, 65, 765, 505, 12, IsRouteGreen) > 24
}

HasUnitPanel() {
    ; The red X at the top-right of the opened unit panel is more stable than text.
    return CountRef(245, 175, 305, 255, 4, IsUiRed) > 8
}

HasMaxUpgrade() {
    return CountRef(150, 255, 250, 325, 4, IsUiYellow) > 8
}

UpgradeIsActive() {
    ; The enabled Upgrade button is the vivid green rectangle in the lower panel.
    return CountRef(145, 350, 275, 420, 4, IsUiGreen) > 8
}

; 0 = no recognisable bubble, 1 = blue/valid, -1 = red/invalid.
BubbleState(rx, ry) {
    blue := CountRef(rx - 72, ry - 72, rx + 72, ry + 72, 8, IsBubbleBlue)
    red := CountRef(rx - 72, ry - 72, rx + 72, ry + 72, 8, IsBubbleRed)
    if blue >= 4 && blue > red
        return 1
    if red >= 4 && red >= blue
        return -1
    return 0
}

; -----------------------------------------------------------------------------
; Minimap navigation.  Map pixels use the same 800 x 600 client coordinates as
; the rest of the macro.  Only this small bottom-right rectangle is sampled.
; -----------------------------------------------------------------------------

GetMiniMapRoutePoints(frame := 0) {
    if !frame
        frame := RefPixels(646, 446, 792, 592)
    points := []
    if !frame.valid
        return points
    ; A two-reference-pixel grid preserves the narrow line and its bends.
    y := 446
    while y <= 592 {
        x := 646
        while x <= 792 {
            if IsMiniMapRouteGreen(frame.AtRef(x, y))
                points.Push({x: x, y: y})
            x += 2
        }
        y += 2
    }
    return points
}

FindNearestRoutePoint(points, playerX, playerY, &routeX, &routeY, &distance) {
    distance := 99999
    for point in points {
        d := MapDistance(playerX, playerY, point.x, point.y)
        if d < distance {
            distance := d
            routeX := point.x, routeY := point.y
        }
    }
    return distance < 99999
}

FindNextRouteWaypoint(points, anchorX, anchorY, directionX, directionY, &targetX, &targetY) {
    ; Walk adjacent green samples. Nearby pixels on another branch are never
    ; considered connected merely because they fall inside a circular radius.
    grid := Map()
    for point in points
        grid[point.x "," point.y] := point
    queue := [{x: anchorX, y: anchorY, distance: 0}]
    seen := Map(anchorX "," anchorY, true)
    head := 1, found := false, bestScore := -99999
    while head <= queue.Length {
        point := queue[head++]
        if point.distance >= 10 {
            dx := point.x - anchorX, dy := point.y - anchorY
            score := dx * directionX + dy * directionY - Abs(point.distance - 14) * 0.3
            if score > bestScore {
                targetX := point.x, targetY := point.y
                bestScore := score, found := true
            }
        }
        if point.distance >= 16
            continue
        for offset in [[2,0],[-2,0],[0,2],[0,-2],[2,2],[2,-2],[-2,2],[-2,-2]] {
            nx := point.x + offset[1], ny := point.y + offset[2]
            key := nx "," ny
            if grid.Has(key) && !seen.Has(key) {
                seen[key] := true
                queue.Push({x: nx, y: ny, distance: point.distance + MapDistance(0, 0, offset[1], offset[2])})
            }
        }
    }
    return found
}

FindMiniMapPlayer(&playerX, &playerY, &headingX, &headingY, frame := 0) {
    if !frame
        frame := RefPixels(646, 446, 792, 592)
    if !frame.valid
        return false
    white := Map(), visited := Map()
    ; Native-resolution components keep the player arrow separate from the
    ; larger white heart. Averaging every white pixel confused the two icons.
    Loop frame.height {
        y := A_Index - 1
        Loop frame.width {
            x := A_Index - 1
            if IsMiniMapPlayerWhite(frame.At(x, y))
                white[y * frame.width + x] := {x: x, y: y}
        }
    }
    candidates := []
    for key, pixel in white {
        if visited.Has(key)
            continue
        queue := [pixel], visited[key] := true, head := 1
        while head <= queue.Length {
            current := queue[head++]
            for offset in [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]] {
                nx := current.x + offset[1], ny := current.y + offset[2]
                if nx < 0 || nx >= frame.width || ny < 0 || ny >= frame.height
                    continue
                nextKey := ny * frame.width + nx
                if white.Has(nextKey) && !visited.Has(nextKey) {
                    visited[nextKey] := true
                    queue.Push(white[nextKey])
                }
            }
        }
        if ArrowPose(queue, frame.scaleX, frame.scaleY, &px, &py, &hx, &hy, &confidence) {
            candidates.Push({x: (px + frame.left) / frame.scaleX, y: (py + frame.top) / frame.scaleY, hx: hx, hy: hy, confidence: confidence})
        }
    }
    if !candidates.Length
        return false
    best := candidates[1]
    for candidate in candidates {
        if candidate.confidence > best.confidence
            best := candidate
    }
    ; If two equally plausible arrows are present, stop instead of guessing.
    for candidate in candidates {
        if candidate != best && candidate.confidence > best.confidence * 0.85
            return false
    }
    playerX := best.x, playerY := best.y
    headingX := best.hx, headingY := best.hy
    return true
}

ArrowPose(pixels, scaleX, scaleY, &px, &py, &hx, &hy, &confidence) {
    count := pixels.Length
    if count < 8 || count > 70 * scaleX * scaleY
        return false
    minX := 99999, minY := 99999, maxX := 0, maxY := 0, sumX := 0, sumY := 0
    occupied := Map()
    for pixel in pixels {
        minX := Min(minX, pixel.x), maxX := Max(maxX, pixel.x)
        minY := Min(minY, pixel.y), maxY := Max(maxY, pixel.y)
        sumX += pixel.x, sumY += pixel.y
        occupied[pixel.y "," pixel.x] := true
    }
    width := (maxX - minX + 1) / scaleX, height := (maxY - minY + 1) / scaleY
    if Max(width, height) > 12 || Min(width, height) < 2
        return false
    ; Fit the actual arrowhead/chevron silhouette, including its open tail.
    ; A covariance axis alone can point across the wings instead of at the tip.
    scores := [], bestScore := 0, bestAngle := 0
    Loop 72 {
        angle := (A_Index - 1) * 5 * 0.01745329252
        ux := Cos(angle), uy := Sin(angle)
        lo := 99999, hi := -99999, sideLo := 99999, sideHi := -99999
        for pixel in pixels {
            x := pixel.x / scaleX, y := pixel.y / scaleY
            along := x * ux + y * uy, across := -x * uy + y * ux
            lo := Min(lo, along), hi := Max(hi, along)
            sideLo := Min(sideLo, across), sideHi := Max(sideHi, across)
        }
        if hi - lo < 2 || sideHi - sideLo < 1.5 {
            scores.Push(0)
            continue
        }
        ; Evaluate the entire small patch, including dark pixels in the tail.
        intersection := 0, union := 0
        y := minY
        while y <= maxY {
            x := minX
            while x <= maxX {
                fx := x / scaleX, fy := y / scaleY
                along := (fx * ux + fy * uy - lo) / (hi - lo)
                across := Abs((-fx * uy + fy * ux - (sideLo + sideHi) / 2) * 2 / (sideHi - sideLo))
                expected := along >= 0 && along <= 1 && across <= 1.08 - along && across >= Max(0, 0.64 - 1.6 * along)
                actual := occupied.Has(y "," x)
                if expected || actual
                    union += 1
                if expected && actual
                    intersection += 1
                x += 1
            }
            y += 1
        }
        score := intersection / Max(1, union)
        scores.Push(score)
        if score > bestScore {
            bestScore := score, bestAngle := angle
        }
    }
    ; Reject a shape that fits two substantially different headings, including
    ; the heart/base marker. Adjacent angles are one heading, not ambiguity.
    alternative := 0
    Loop scores.Length {
        angle := (A_Index - 1) * 5 * 0.01745329252
        if Cos(angle - bestAngle) < 0.5
            alternative := Max(alternative, scores[A_Index])
    }
    if bestScore < 0.54 || alternative >= bestScore * 0.94
        return false
    hx := Cos(bestAngle), hy := Sin(bestAngle)
    confidence := bestScore - alternative
    px := sumX / count, py := sumY / count
    return true
}

MapDistance(x1, y1, x2, y2) {
    return Sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
}

HoldArrow(key, durationMs) {
    global gRunning
    if !gRunning
        return false
    Log("Hold " key " for " durationMs "ms")
    Send "{" key " down}"
    try return ActionPause(durationMs)
    finally Send "{" key " up}"
}

NavigateAlongRoute() {
    global gRunning
    directionX := 1, directionY := 0, stuck := 0, joined := false
    Loop 24 {
        if !gRunning
            return false
        frame := RefPixels(646, 446, 792, 592)
        points := GetMiniMapRoutePoints(frame)
        if points.Length < 8 || !FindMiniMapPlayer(&playerX, &playerY, &hx, &hy, frame) {
            Log("Navigation stopped: green minimap line or unambiguous player arrow missing.")
            return false
        }
        FindNearestRoutePoint(points, playerX, playerY, &routeX, &routeY, &distance)
        if distance > 5 {
            targetX := routeX, targetY := routeY
        } else {
            if joined && RouteVisible() {
                Log("Player on green minimap line; illuminated world route confirmed.")
                return true
            }
            joined := true
            if !FindNextRouteWaypoint(points, routeX, routeY, directionX, directionY, &targetX, &targetY) {
                Log("No connected route continuation; stopping movement.")
                return false
            }
        }
        dx := targetX - playerX, dy := targetY - playerY
        length := Sqrt(dx ** 2 + dy ** 2)
        if length < 2
            continue
        alignment := Max(-1, Min(1, (hx * dx + hy * dy) / length))
        cross := hx * dy - hy * dx
        Log("Arrow " Round(hx, 2) "," Round(hy, 2) "; player " Round(playerX, 1) "," Round(playerY, 1) "; green waypoint " targetX "," targetY)
        ; Read facing before translating. Turn once, then recapture the arrow;
        ; never stack a guessed turn and a forward probe in the same pass.
        if alignment < 0.94 {
            angle := ACos(alignment)
            if !HoldArrow(cross >= 0 ? "Right" : "Left", Max(90, Min(600, Round(angle * 240))))
                return false
            if !ActionPause(250)
                return false
            continue
        }
        oldX := playerX, oldY := playerY
        if !HoldArrow("Up", Max(160, Min(600, Round(length * 32))))
            return false
        if !ActionPause(250)
            return false
        if !FindMiniMapPlayer(&nextX, &nextY, &nextHx, &nextHy)
            return false
        after := MapDistance(nextX, nextY, targetX, targetY)
        if after >= length - 0.5 {
            stuck += 1
            if stuck >= 2 {
                Log("No progress toward the green line; stopping instead of reversing/probing.")
                return false
            }
        } else {
            stuck := 0
            if joined {
                directionX := dx / length, directionY := dy / length
            }
        }
    }
    Log("Navigation limit reached without route confirmation; no placement attempted.")
    return false
}

; -----------------------------------------------------------------------------
; Camera, path scanning, and validated placement
; -----------------------------------------------------------------------------

CameraReset(*) {
    global CAMERA_TILT_PIXELS
    if !GetClient(&cx, &cy, &cw, &ch) {
        Notify("Roblox was not found.")
        return
    }
    WinActivate "ahk_id " FindRoblox()
    Log("Camera reset: hold I for 5 seconds")
    Send "{i down}"
    Sleep 5000
    Send "{i up}"
    ; In first person Roblox uses raw mouse movement to pitch the camera.
    tilt := CAMERA_TILT_PIXELS
    MouseMove cx + cw // 2, cy + ch // 2, 0
    MouseMove cx + cw // 2, cy + ch // 2 + tilt, 18
    WaitForMouseStill(500)
    Log("Camera reset: hold O for 5 seconds")
    Send "{o down}"
    Sleep 5000
    Send "{o up}"
}

WaitForMouseStill(requiredStillMs) {
    MouseGetPos(&lastX, &lastY)
    stillSince := A_TickCount
    loop {
        Sleep 40
        MouseGetPos(&x, &y)
        if x != lastX || y != lastY {
            lastX := x, lastY := y
            stillSince := A_TickCount
        }
        if A_TickCount - stillSince >= requiredStillMs
            return
    }
}

EnsureRouteAndSpawn() {
    global PREP_CLICK_MS
    if !RouteVisible() {
        ; P: illuminated path toggle, top-right of the game client.
        if !ClickButton("PathToggle", PREP_CLICK_MS)
            return false
    }
    ; Gear and its "Teleport back to Spawn" arrow.  Teleporting each new match
    ; is safer than trying to infer an old position after the minimap changes.
    if !ClickButton("SettingsGear", PREP_CLICK_MS)
        return false
    if !ClickButton("TeleportSpawn", PREP_CLICK_MS)
        return false
    if !ClickButton("SettingsClose", PREP_CLICK_MS)
        return false
    ; Keep the loaded camera still. F8 remains the explicit camera reset.
    ; A minimap route is sufficient to navigate toward an offscreen world route.
    return RouteVisible() || GetMiniMapRoutePoints().Length >= 8
}

IsNearRoute(rx, ry, radius := 8) {
    return CountRef(rx - radius, ry - radius, rx + radius, ry + radius, 4, IsRouteGreen) > 0
}

TangentAngle(rx, ry) {
    ; Test 12 axes around a path point and choose the axis with route pixels on
    ; both sides.  Its perpendicular gives "beside the path" candidates.
    bestAngle := 0, bestScore := -1
    Loop 12 {
        angle := (A_Index - 1) * 15
        rad := angle * 0.01745329252
        dx := Round(Cos(rad) * 34), dy := Round(Sin(rad) * 34)
        score := IsNearRoute(rx + dx, ry + dy, 10) + IsNearRoute(rx - dx, ry - dy, 10)
        if score > bestScore {
            bestScore := score
            bestAngle := angle
        }
    }
    return bestAngle
}

FindPlacementCandidates() {
    points := []
    ; Start around the player-facing centre of the viewport, then spread outward.
    ; The later blue-bubble check decides whether each geometric candidate is valid.
    Loop 32 {
        ring := Ceil(A_Index / 8)
        sector := Mod(A_Index - 1, 8) * 45
        rad := sector * 0.01745329252
        sx := Round(400 + Cos(rad) * ring * 55)
        sy := Round(310 + Sin(rad) * ring * 42)
        ; Search a small grid near each radial probe for a route pixel.
        found := false
        y := sy - 24
        while y <= sy + 24 && !found {
            x := sx - 24
            while x <= sx + 24 {
                if x > 35 && x < 765 && y > 65 && y < 505 && IsNearRoute(x, y, 4) {
                    angle := TangentAngle(x, y)
                    normal := (angle + 90) * 0.01745329252
                    ; Test two outward lanes on each side of the path.  The first
                    ; two candidates make "path | unit | unit" possible; the blue
                    ; bubble remains the final authority on range and collisions.
                    for sign in [-1, 1] {
                        for distance in [58, 118] {
                            px := Round(x + sign * Cos(normal) * distance)
                            py := Round(y + sign * Sin(normal) * distance)
                            if px > 45 && px < 755 && py > 80 && py < 495
                                points.Push({x: px, y: py})
                        }
                    }
                    found := true
                    break
                }
                x += 8
            }
            y += 8
        }
    }
    return points
}

PlaceUnit(unit) {
    global gPlacements, gRunning
    Log("Select " unit.name " in slot " unit.slot)
    Send "{" unit.slot "}"
    Sleep 250
    for candidate in FindPlacementCandidates() {
        if !gRunning
            return false
        MoveRef(candidate.x, candidate.y)
        Sleep 180
        if BubbleState(candidate.x, candidate.y) != 1
            continue
        Log("Blue placement bubble: " unit.name " at " candidate.x ", " candidate.y)
        ClickRef(candidate.x, candidate.y)
        if WaitFor(HasUnitPanel, 1100) {
            gPlacements.Push({
                slot: unit.slot,
                name: unit.name,
                priority: unit.priority,
                target: unit.target,
                upgrades: 0,
                x: candidate.x,
                y: candidate.y,
                complete: unit.target = 0
            })
            Log("Placed " unit.name " successfully; saved UPG (0), target " unit.target)
            ; Close the confirmation panel before selecting the next hotbar slot.
            CloseUnitPanel()
            Sleep 180
            return true
        }
    }
    return false
}

UpgradeOnce(item) {
    if item.complete
        return true
    Log("Open " item.name " for UPG (" item.upgrades "/" item.target ")")
    ClickRef(item.x, item.y)
    if !WaitFor(HasUnitPanel, 900)
        return false
    if HasMaxUpgrade() {
        item.complete := true
        Log(item.name " reached MAX UPGRADE.")
        CloseUnitPanel()
        return true
    }
    if UpgradeIsActive() {
        Log("Press R: " item.name " upgrade " (item.upgrades + 1) " of " item.target)
        Send "r"
        Sleep 1000
        item.upgrades += 1
        if item.upgrades >= item.target {
            item.complete := true
            Log(item.name " reached its configured upgrade target.")
        }
    }
    if HasMaxUpgrade()
        item.complete := true
    CloseUnitPanel()
    return true
}

CloseUnitPanel() {
    if HasUnitPanel() {
        Log("Close unit panel")
        ClickButton("UnitPanelClose")
        Sleep 160
    }
}

; -----------------------------------------------------------------------------
; Match state machine
; -----------------------------------------------------------------------------

HasVoteStart() {
    return CountRef(300, 70, 500, 145, 5, IsUiGreen) > 12
}

HasMatchmakingPanel() {
    ; "Play Here" is the distinctive bright-green card in the central panel.
    return CountRef(260, 250, 405, 390, 6, IsUiGreen) > 14
}

HasOpenPortal() {
    ; The bright green Open button in the centred portal confirmation.
    return CountRef(165, 305, 325, 390, 5, IsUiGreen) > 16
}

TryStartPortal() {
    ; The previous static click already allowed 2.5 seconds to render this.
    if FindUiGreenCentre(230, 275, 570, 425, &x, &y) {
        Log("Portal Start detected at " x ", " y)
        ClickRef(x, y)
        return ActionPause(2500)
    }
    Log("Portal Start button was not detected.")
    return false
}

HasReplayButton() {
    return CountRef(390, 70, 620, 155, 6, IsUiYellow) > 14
}

HasDefeatNext() {
    return CountRef(270, 345, 420, 440, 5, IsUiGreen) > 14
}

HasCardChoice() {
    ; Three red-framed card columns, in the central playfield.  Requiring all
    ; three frame areas avoids confusing the card screen with a defeat panel.
    return CountRef(130, 175, 170, 445, 6, IsUiRed) > 5
        && CountRef(310, 175, 350, 445, 6, IsUiRed) > 5
        && CountRef(615, 175, 665, 445, 6, IsUiRed) > 5
}

TryChooseCard() {
    if !HasCardChoice()
        return false
    ; A green card beats a non-green card.  The numeric tie-breaker is left as
    ; a later OCR/template calibration task; green-pixel density is the safe
    ; temporary tie-breaker and middle remains the specified no-green fallback.
    cardXs := [220, 400, 570]
    best := 2, bestGreen := 0
    Loop 3 {
        green := CountRef(cardXs[A_Index] - 70, 190, cardXs[A_Index] + 70, 430, 5, IsUiGreen)
        if green > bestGreen {
            bestGreen := green
            best := A_Index
        }
    }
    ClickRef(cardXs[best], 330)
    Sleep 550
    return true
}

TryStartFromLobby() {
    ; The blue Play button on the left lobby rail.
    if !ClickButton("LobbyPlay")
        return false
    Log("Hold W while looking for Play Here")
    Send "{w down}"
    found := WaitFor(HasMatchmakingPanel, 12000)
    Send "{w up}"
    Log("Release W: Play Here " (found ? "detected" : "not detected"))
    if found {
        if !ClickButton("PlayHere")
            return false
        if HasOpenPortal() {
            Log("Open Portal confirmation detected")
            if !ClickButton("PortalOpen")
                return false
            TryStartPortal()
        }
    }
    return found
}

TryVoteStart() {
    if !HasVoteStart()
        return false
    Log("Vote Start detected; click Yes")
    ClickButton("VoteYes")
    return true
}

TryEndState() {
    if HasDefeatNext() {
        ClickButton("DefeatNext")
    }
    if HasReplayButton() {
        ClickButton("Replay")
        return true
    }
    return false
}

ReadUnitPlan() {
    global gUnitControls
    plan := []
    for controls in gUnitControls {
        count := Max(0, Integer(controls.count.Value))
        priority := Max(1, Integer(controls.priority.Value))
        plan.Push({
            slot: controls.slot,
            enabled: controls.enabled.Value,
            name: controls.name.Value,
            count: count,
            priority: priority,
            target: Max(0, Integer(controls.target.Value))
        })
    }
    return plan
}

UpgradePriorityPass() {
    global gPlacements, gRunning
    activePriority := 0
    for item in gPlacements {
        if !item.complete && (!activePriority || item.priority < activePriority)
            activePriority := item.priority
    }
    if !activePriority
        return
    ; Do not touch priority 2 until every priority-1 unit is at MAX.  When a
    ; priority-1 upgrade is unaffordable it simply waits for more money.
    for item in gPlacements {
        if gRunning && !item.complete && item.priority = activePriority
            UpgradeOnce(item)
    }
}

RunMacro() {
    global gRunning, gPlacements
    plan := ReadUnitPlan()
    ; Loading can take a while. Do not send path, camera or movement inputs
    ; until the small Vote Start dialog proves that the match has fully loaded.
    if !HasVoteStart() && !RouteVisible() {
        if !TryStartFromLobby() {
            Notify("Could not find the lobby Play flow.")
            return
        }
    }
    Notify("Waiting for Vote Start before any map preparation.")
    if !WaitFor(HasVoteStart, 45000, 250) {
        Notify("Vote Start was not detected before the loading timeout.")
        return
    }
    Notify("Vote Start detected. Preparing path and spawn with one-second spacing.")
    if !EnsureRouteAndSpawn() {
        Notify("Neither the world route nor the green minimap line was found.")
        return
    }
    Notify("Following the green minimap route into position.")
    if !NavigateAlongRoute() {
        Notify("Navigation stopped. Check the player arrow and green minimap line before restarting.")
        return
    }
    Log("Navigation complete; accepting Vote Start.")
    if !TryVoteStart() {
        Notify("Vote Start disappeared before the Yes click.")
        return
    }
    Log("Vote accepted; starting placement phase.")
    gPlacements := []
    for unit in plan {
        if !unit.enabled
            continue
        Loop unit.count {
            if !gRunning
                return
            if !PlaceUnit(unit)
                Notify(unit.name " (slot " unit.slot "): no blue placement spot found.")
        }
    }
    Notify("Build placed: " gPlacements.Length " units. Watching upgrades/end screen.")
    while gRunning {
        if TryChooseCard() {
            Notify("Card selected.")
            continue
        }
        if TryEndState() {
            Notify("Replay selected. Waiting for the next match.")
            return "replay"
        }
        UpgradePriorityPass()
        Sleep 850
    }
}

StartMacro(*) {
    global gRunning, WINDOW_W, WINDOW_H
    if gRunning
        return
    if !GetClient(&cx, &cy, &cw, &ch) {
        Notify("Open Roblox before starting.")
        return
    }
    ResizeRoblox()
    ; Refresh the attachment at every start, so dragging the Roblox window
    ; before a run becomes its new offset from the macro panel.
    AttachRoblox()
    gRunning := true
    Notify("Running. F7 stops immediately.")
    SetTimer RunMacroSafely, -10
}

TestRoutePreparation(*) {
    global gRunning
    if gRunning
        return
    hwnd := FindRoblox()
    if !hwnd {
        Notify("Open Roblox before testing the route.")
        return
    }
    WinActivate "ahk_id " hwnd
    if !HasVoteStart() {
        Notify("F9 route test: wait until Vote Start is visible.")
        return
    }
    gRunning := true
    try {
        ResizeRoblox()
        if EnsureRouteAndSpawn() && NavigateAlongRoute()
            Notify("Route test complete. Player aligned with the route; no units placed.")
        else
            Notify("Route test stopped. Inspect the Activity log before continuing.")
    } catch as err {
        Notify("Route test stopped: " err.Message)
    } finally {
        gRunning := false
        ReleaseMovementKeys()
    }
}

RunMacroSafely() {
    global gRunning
    try {
        while gRunning {
            if RunMacro() != "replay"
                break
        }
    }
    catch as err
        Notify("Stopped: " err.Message)
    finally {
        if gRunning {
            gRunning := false
            ReleaseMovementKeys()
        }
    }
}

StopMacro(*) {
    global gRunning
    gRunning := false
    ReleaseMovementKeys()
    Notify("Stopped.")
}

ReleaseMovementKeys() {
    Send "{w up}{Up up}{Down up}{Left up}{Right up}{i up}{o up}{LButton up}"
}

WaitFor(test, timeoutMs, pollMs := 80) {
    global gRunning
    deadline := A_TickCount + timeoutMs
    while gRunning && A_TickCount < deadline {
        if test.Call()
            return true
        Sleep pollMs
    }
    return false
}

Notify(text) {
    global gStatus
    if gStatus
        gStatus.Value := "Status: " text
    Log(text)
    ToolTip text
    SetTimer () => ToolTip(), -1800
}

Log(text) {
    global gActivityLog
    if !gActivityLog
        return
    entry := FormatTime(A_Now, "HH:mm:ss") "  " text
    previous := gActivityLog.Value
    ; Keep the control responsive during long replay sessions.
    if StrLen(previous) > 14000
        previous := SubStr(previous, -9000)
    gActivityLog.Value := previous entry "`r`n"
}

; These checks deliberately avoid capturing a screen or sending any input.
RunSelfTests() {
    passed := 0
    Loop 8 {
        angle := (A_Index - 1) * 45 * 0.01745329252
        ux := Cos(angle), uy := Sin(angle), pixels := []
        Loop 25 {
            y := A_Index - 13
            Loop 25 {
                x := A_Index - 13
                along := (x * ux + y * uy + 7.5) / 15
                across := Abs((-x * uy + y * ux) / 5.5)
                if along >= 0 && along <= 1 && across <= 1.08 - along && across >= Max(0, 0.64 - 1.6 * along)
                    pixels.Push({x: x + 20, y: y + 20})
            }
        }
        if !ArrowPose(pixels, 1.7, 1.7, &px, &py, &hx, &hy, &confidence)
            throw Error("Arrow rejected at " Round(angle / 0.01745329252) " degrees")
        if hx * ux + hy * uy < 0.86
            throw Error("Incorrect heading at " Round(angle / 0.01745329252) " degrees")
        passed += 1
    }
    square := []
    Loop 9 {
        y := A_Index
        Loop 9
            square.Push({x: A_Index, y: y})
    }
    if ArrowPose(square, 1.7, 1.7, &px, &py, &hx, &hy, &confidence)
        throw Error("Symmetric white marker was mistaken for an arrow")
    passed += 1
    ; A disconnected nearby lane must never become a waypoint.
    points := []
    Loop 12
        points.Push({x: 100 + (A_Index - 1) * 2, y: 100})
    Loop 12
        points.Push({x: 100 + (A_Index - 1) * 2, y: 108})
    if !FindNextRouteWaypoint(points, 100, 100, 1, 0, &tx, &ty) || ty != 100 || tx <= 100
        throw Error("Waypoint jumped to a disconnected lane")
    passed += 1
    ; On a right-angle bend, the continuation must come from the connected turn.
    points := []
    Loop 6
        points.Push({x: 100 + (A_Index - 1) * 2, y: 100})
    Loop 8
        points.Push({x: 110, y: 100 + A_Index * 2})
    if !FindNextRouteWaypoint(points, 108, 100, 1, 0, &tx, &ty) || tx != 110 || ty <= 100
        throw Error("Waypoint did not follow the connected bend")
    passed += 1
    return "PASS: " passed " navigation checks"
}

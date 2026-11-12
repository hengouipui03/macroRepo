#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, Off

; AA Path Macro — first readable AutoHotkey v2 implementation.
; All game positions are relative to Roblox's CLIENT area (800 x 600), never to
; a fixed desktop location.  F6 starts, F7 stops, F8 runs only the camera reset.

CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"
SetTitleMatchMode 2

; Session logs (see SessionLogLine): one file per F6 run in logs\.
global LOG_DIR := A_ScriptDir "\logs",gSessionLogFile := "",gSessionLogHasRun := false,SESSION_LOG_DAYS := 30
; Disconnect recovery (see CheckDisconnect).
global gReconnecting := false,gReconnectButton := false,gMacroThreadActive := false
global REF_W := 800
global REF_H := 600
global WINDOW_W := 1401
global WINDOW_H := 975
global ACTION_GAP_MS := 300,gLastInputFinishedAt := 0
global ACTION_HOLD_MS := 300
; Unit placement/selection key holds, click holds, gaps and cursor travel.
; 150 ms (was 200): still a full held press for Roblox, about 25% faster.
global UNIT_ACTION_MS := 150
; Manager-safe click-away (reference 800x600): empty world left of the open F
; unit manager, right of "Return to lobby", above the cards, outside the unit panel.
global CLICK_AWAY_X := 497,CLICK_AWAY_Y := 168
global STATIC_CLICK_MS := 300
global CLICK_HOLD_MS := ACTION_HOLD_MS
global MOUSE_SETTLE_MS := 0
global gInputEpoch := 0
global CAMERA_TILT_PIXELS := 420
global BUTTONS_FILE := A_ScriptDir "\button_positions.ini"
global gRunning := false
; True from F6 until F7: the session is on even when the run loop has ended by
; itself. Disconnect handling is gated on this, never on gRunning.
global gSessionArmed := false
global IDLE_KEEPALIVE_MS := 300000,gIdleKeepAliveAt := 0
global gAttached := false
global gMacroHwnd := 0
global gMacroGui := 0
global gRobloxDx := 0
global gRobloxDy := 0
global gPlacements := []
global gUnitControls := []
global gStatus := 0
global gActivityLog := 0

#Include MatchState.ahk
#Include UnitSettings.ahk
#Include Placement.ahk
#Include PurchaseVerifier.ahk
#Include BuildAudit.ahk
#Include PlacementArea.ahk
#Include UnitManager.ahk
#Include PlacedUnits.ahk
#Include Learning.ahk
#Include CardContext.ahk
#Include QueueMatch.ahk
#Include LobbyFlow.ahk
#Include LearningTests.ahk
#Include MapNavigation.ahk
#Include PathLight.ahk
#Include MapTests.ahk
#Include Discord.ahk
#Include Endgame.ahk

; Parse/validation mode performs no window, mouse, or keyboard actions.
if A_Args.Length && A_Args[1] = "--check"
    ExitApp 0
if A_Args.Length && A_Args[1] = "--play-button-check" {
    gRunning := true
    try {
        ResizeRoblox()
        hwnd := FindRoblox()
        if !hwnd
            throw Error("Roblox is not open")
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,2)
            throw Error("Roblox could not be activated")
        if !HasLobbyPlay()
            throw Error("Lobby Play is not visibly present; no clicks sent")
        if !ClickButton("LobbyPlay")
            throw Error("Play button could not be clicked")
        last := gLastButtonClicks["LobbyPlay"]
        FileAppend "One Play click sent at application-window " Round(last.point.x) "," Round(last.point.y) " (" last.point.source "); no movement or placement.`n", A_ScriptDir "\play-button-checks.txt", "UTF-8"
    } catch as err {
        FileAppend "FAIL: " err.Message "`n", A_ScriptDir "\play-button-checks.txt", "UTF-8"
        ExitApp 1
    } finally {
        gRunning := false
        ReleaseMovementKeys()
    }
    ExitApp 0
}
if A_Args.Length && A_Args[1] = "--self-test" {
    try {
        result := RunSelfTests()
        FileAppend result "`n", A_ScriptDir "\navigation-checks.txt", "UTF-8"
        ExitApp 0
    } catch as err {
        FileAppend "FAIL: " err.Message " (" err.File ":" err.Line ")`n" err.Stack "`n", A_ScriptDir "\navigation-checks.txt", "UTF-8"
        ExitApp 1
    }
}

if A_Args.Length && A_Args[1] = "--startup-check" {
    started := A_TickCount
    BuildGui()
    FileAppend "Panel built in " (A_TickCount-started) "ms; no game scans or OCR.`n", A_ScriptDir "\startup-checks.txt", "UTF-8"
    ExitApp 0
}
BuildGui()
OnMessage(0x0003, OnMacroWindowMove) ; WM_MOVE

F6::StartMacro()
F7::StopMacro()
F8::CameraReset()
F9::TestRoutePreparation()
F10::LearnHoveredButton()

BuildGui() {
    global gMacroHwnd, gMacroGui, gUnitControls, gStatus, gActivityLog, gUnitSettingsReady
    global gMatchMode,UNIT_SETTINGS_FILE
    gUnitSettingsReady := false
    app := Gui(, "AA Path Macro")
    gMacroGui := app
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
    app.AddText("x12 y84 w46", "Mode")
    mode := IniRead(UNIT_SETTINGS_FILE,"Macro","mode","Solo")
    gMatchMode := app.AddDropDownList("x61 y81 w96 Choose" (mode="Queue"?2:1),["Solo","Queue"])
    gMatchMode.OnEvent("Change",SaveMatchMode)
    app.AddText("x170 y84 w265", WINDOW_W " × " WINDOW_H " • automatic overhead camera")

    tabs := app.AddTab3("x12 y106 w452 h548", ["Control", "Activity", "Learning", "Cards", "Discord"])
    tabs.UseTab(1)

    gUnitControls := []
    Loop 6 {
        slot := A_Index
        saved := LoadUnitSettings(slot)
        col := Mod(slot - 1, 2)
        row := Floor((slot - 1) / 2)
        gx := 12 + col * 232
        gy := 136 + row * 159
        app.AddGroupBox("x" gx " y" gy " w220 h154", "Slot " slot)
        enabled := app.AddCheckbox("x" (gx + 10) " y" (gy + 22) (saved.enabled?" Checked":""), "Enabled")
        name := AddReadableEdit(app, "x" (gx + 82) " y" (gy + 18) " w124", saved.name)
        app.AddText("x" (gx + 10) " y" (gy + 51) " w84", "Placements")
        count := AddReadableEdit(app, "x" (gx + 99) " y" (gy + 47) " w45 Number", saved.count)
        app.AddUpDown("Range0-30", saved.count)
        app.AddText("x" (gx + 152) " y" (gy + 51) " w55", "copies")
        app.AddText("x" (gx + 10) " y" (gy + 78) " w84", "Priority")
        priority := AddReadableEdit(app, "x" (gx + 99) " y" (gy + 74) " w45 Number", saved.priority)
        app.AddUpDown("Range1-99", saved.priority)
        hill := app.AddCheckbox("x" (gx+10) " y" (gy+128) " w70" (saved.hill?" Checked":""), "Hill only")
        hybrid := app.AddCheckbox("x" (gx+85) " y" (gy+128) " w65" (saved.hybrid && !saved.hill?" Checked":""), "Hybrid")
        money := app.AddCheckbox("x" (gx+152) " y" (gy+128) " w62" (saved.money && !saved.hill && !saved.hybrid?" Checked":""), "Money")
        app.AddText("x" (gx + 10) " y" (gy + 105) " w106", "Upgrade target")
        target := AddReadableEdit(app, "x" (gx + 120) " y" (gy + 101) " w45 Number", saved.target)
        app.AddUpDown("Range0-99", saved.target)
        app.AddText("x" (gx + 170) " y" (gy + 105) " w38", "99=MAX")
        gUnitControls.Push({slot: slot, enabled: enabled, name: name, count: count, priority: priority, target: target, hill: hill, hybrid:hybrid, money:money})
        enabled.OnEvent("Click",QueueUnitSettingsSave)
        hill.OnEvent("Click",UnitPlacementModeChanged.Bind(slot,"hill"))
        hybrid.OnEvent("Click",UnitPlacementModeChanged.Bind(slot,"hybrid"))
        money.OnEvent("Click",UnitPlacementModeChanged.Bind(slot,"money"))
        for control in [name,count,priority,target]
            control.OnEvent("Change",QueueUnitSettingsSave)
    }
    gUnitSettingsReady := true
    OnExit FlushUnitSettings
    OnExit EndSessionLog.Bind("macro closed")
    tabs.UseTab(2)
    app.AddText("x28 y140 w400", "Live action log — newest actions appear at the bottom")
    gActivityLog := app.AddEdit("x28 y166 w414 h365 ReadOnly VScroll -Wrap c20212D BackgroundFFFFFF", "")
    tabs.UseTab(3)
    BuildLearningTab(app)
    tabs.UseTab(4)
    BuildCardPreferencesTab(app)
    tabs.UseTab(5)
    BuildDiscordTab(app)
    tabs.UseTab()
    gStatus := app.AddText("x12 y662 w452", "Status: waiting for Roblox")
    app.OnEvent("Close", (*) => ExitApp())
    if !(A_Args.Length && A_Args[1] = "--startup-check")
        app.Show("w476 h692 x20 y20")
    gMacroHwnd := app.Hwnd
    gStatus.Value := "Status: ready. Unit settings save automatically. F6 starts."
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

MoveRef(rx, ry) {
    if ToScreen(rx, ry, &sx, &sy)
        return SmoothMoveTo(sx, sy)
    return false
}

SmoothMoveTo(sx, sy,gapMs := 0,travelMs := 0,waitBeforeMove := true) {
    global gRunning, gInputEpoch,ACTION_HOLD_MS
    MouseGetPos(&startX, &startY)
    distance := Sqrt((sx-startX)**2 + (sy-startY)**2)
    if distance < 2
        return true
    if waitBeforeMove && !BeginInputAction(gRunning,gapMs)
        return false
    ; Interpolate an eased path over real time. A single MouseMove with a
    ; speed value is still instantaneous under AutoHotkey's SendInput mode.
    duration := travelMs>0?travelMs:ACTION_HOLD_MS
    started := A_TickCount, epoch := gInputEpoch, wasRunning := gRunning
    previousMode := A_SendMode
    SendMode "Event"
    try {
        loop {
            if epoch != gInputEpoch || (wasRunning && !gRunning) || CheckCardInterruption()
                return false
            progress := Min(1, (A_TickCount-started)/duration)
            eased := progress*progress*(3-2*progress)
            ; Each small step is at most one 20ms segment of the path.
            MouseMove Round(startX+(sx-startX)*eased), Round(startY+(sy-startY)*eased), 0
            if progress >= 1
                return true
            Sleep 20
        }
    } finally {
        SendMode previousMode
        EndInputAction()
    }
}

ClickRef(rx, ry,stillValid := 0) {
    global CLICK_HOLD_MS, MOUSE_SETTLE_MS, gRunning
    if !gRunning
        return false
    if !ToScreen(rx, ry, &sx, &sy)
        return false
    hwnd := FindRoblox()
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2)
        return false
    if !SmoothMoveTo(sx,sy) || !BeginInputAction()
        return false
    if stillValid && !stillValid.Call()
        return false
    ; Explicit left-button events give Roblox a held press and release.
    SendEvent "{LButton down}"
    try {
        if !ActionPause(CLICK_HOLD_MS,false)
            return false
    } finally {
        SendEvent "{LButton up}"
        EndInputAction()
    }
    Log("Left click at client " rx ", " ry)
    return true
}

ButtonPosition(name, &rx, &ry) {
    global BUTTONS_FILE
    value := MemoryRead("Buttons",name,"",BUTTONS_FILE)
    if value = "" {
        ; These are only fallback anchors. Learned positions use exact window
        ; pixels in learning.ini and are not replaced by these guesses.
        defaults := Map("LobbyPlay","88,278","PlayHere","343,319","PortalOpen","253,354","PathToggle","715,21","SettingsGear","21,585","TeleportSpawn","524,366","SettingsClose","585,149","VoteYes","356,102","DefeatNext","320,391","Replay","490,120","UnitPanelClose","276,227")
        value := defaults.Has(name) ? defaults[name] : ""
    }
    parts := StrSplit(value, ",")
    if parts.Length != 2 || !IsNumber(Trim(parts[1])) || !IsNumber(Trim(parts[2]))
        return false
    rx := Integer(Trim(parts[1]))
    ry := Integer(Trim(parts[2]))
    return true
}

ClickButton(name, delayMs := -1, confirm := 0, forceDetect := false) {
    return ClickLearnedButton(name, delayMs, confirm, forceDetect)
}

BeginInputAction(requireRunning := true,gapMs := 0) {
    global ACTION_GAP_MS,gLastInputFinishedAt,gRunning,gInputEpoch
    epoch := gInputEpoch
    loop {
        if epoch!=gInputEpoch || (requireRunning && !gRunning)
            return false
        if requireRunning && CheckCardInterruption()
            return false
        remaining := (gapMs>0?gapMs:ACTION_GAP_MS)-(A_TickCount-gLastInputFinishedAt)
        if remaining<=0
            return true
        Sleep Min(20,remaining)
    }
}

EndInputAction() {
    global gLastInputFinishedAt
    gLastInputFinishedAt := A_TickCount
}

ActionPause(durationMs,interruptible := true) {
    global gRunning
    deadline := A_TickCount+durationMs
    while gRunning && A_TickCount<deadline {
        if interruptible && CheckCardInterruption()
            return false
        Sleep Min(40,Max(1,deadline-A_TickCount))
    }
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
    if !gStatus
        return
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

IsUiGreen(color) {
    RGB(color, &r, &g, &b)
    return g > 150 && r < 150 && b < 155 && (g - r) > 45
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




; 0 = no recognisable bubble, 1 = blue/valid, -1 = red/invalid.


; Compare with the ground before selection. Orange terrain is not an invalid
; preview, and a valid blue ring must not lose a vote against red scenery.

; -----------------------------------------------------------------------------
; Minimap navigation.  Map pixels use the same 800 x 600 client coordinates as
; the rest of the macro.  Only this small bottom-right rectangle is sampled.
; -----------------------------------------------------------------------------

GetMiniMapRoutePoints(frame := 0) {
    global MAP_GRID
    if !frame
        frame := CaptureMiniMap()
    points := []
    if !frame || !frame.valid
        return points
    fragments := MapBridgeFragments(MapGreenMask(frame),frame)
    for key in MapThin(fragments.mask)
        points.Push({x:(frame.left+Mod(key,MAP_GRID)/(MAP_GRID-1)*(frame.width-1))/frame.scaleX,y:(frame.top+key//MAP_GRID/(MAP_GRID-1)*(frame.height-1))/frame.scaleY})
    return points
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
        intersection := 0, union := 0, chevronIntersection := 0, chevronUnion := 0
        y := minY
        while y <= maxY {
            x := minX
            while x <= maxX {
                fx := x / scaleX, fy := y / scaleY
                along := (fx * ux + fy * uy - lo) / (hi - lo)
                across := Abs((-fx * uy + fy * ux - (sideLo + sideHi) / 2) * 2 / (sideHi - sideLo))
                expected := along >= 0 && along <= 1 && across <= 1.08 - along && across >= Max(0, 0.64 - 1.6 * along)
                ; Actual minimap chevron: broad shoulders and two open legs,
                ; as distinct from a filled navigation-arrow silhouette.
                chevron := along >= 0 && along <= 1 && across <= Min(1.05,1.68*(1-along)+0.08) && across >= Max(0,0.92-1.8*along)
                actual := occupied.Has(y "," x)
                if expected || actual
                    union += 1
                if expected && actual
                    intersection += 1
                if chevron || actual
                    chevronUnion += 1
                if chevron && actual
                    chevronIntersection += 1
                x += 1
            }
            y += 1
        }
        score := Max(intersection / Max(1, union),chevronIntersection / Max(1,chevronUnion))
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
    hwnd := FindRoblox()
    if !hwnd
        return false
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,1)
        return false
    Log("Hold " key " for " durationMs "ms")
    if !BeginInputAction()
        return false
    Send "{" key " down}"
    held := [{key:key}]
    ; A card releases the key before it is chosen (no walking during cards).
    try return MovementHoldUntil(A_TickCount+durationMs,held)
    finally {
        if held.Length
            Send "{" key " up}"
        EndInputAction()
    }
}

NavigateAlongRoute() {
    return NavigateDrawing()
}

; -----------------------------------------------------------------------------
; Camera, path scanning, and validated placement
; -----------------------------------------------------------------------------

CameraReset(*) {
    global CAMERA_TILT_PIXELS,gRunning,gInputEpoch,gCameraOverheadReady,gQueueMode
    gCameraOverheadReady := false
    if !GetClient(&cx,&cy,&cw,&ch)
        return false
    WinActivate "ahk_id " FindRoblox()
    epoch := gInputEpoch
    fast := gRunning && gQueueMode
    travelMs := fast?125:0
    if !SmoothMoveTo(cx+cw//2,cy+ch//2,0,travelMs)
        return false
    ; Keep the full calibrated holds when time permits. A short remaining
    ; countdown uses a shorter pair and records that camera profile separately.
    maxHold := fast?2500:5000
    holdMs := gRunning ? Min(maxHold,Max(1200,Round((PrepTimeLeft()-7000)/2))) : 5000
    Log("Overhead camera: hold I " holdMs "ms, tilt down, settle, hold O " holdMs "ms.")
    if !HoldCameraKey("i",holdMs,epoch)
        return false
    tilt := Min(CAMERA_TILT_PIXELS,Round(ch*0.38))
    ; Tilt as soon as I is released. O still waits for the mouse to settle.
    if !SmoothMoveTo(cx+cw//2,cy+ch//2+tilt,0,travelMs,false)
        return false
    if !InputPause(fast?125:250,epoch)
        return false
    if !HoldCameraKey("o",holdMs,epoch)
        return false
    gCameraOverheadReady := (fast?"queue-overhead-":"overhead-") holdMs
    return true
}

InputPause(duration,epoch) {
    global gInputEpoch
    deadline := A_TickCount+duration
    while A_TickCount<deadline {
        if epoch!=gInputEpoch
            return false
        Sleep Min(20,Max(1,deadline-A_TickCount))
    }
    return epoch=gInputEpoch
}

HoldCameraKey(key,duration,epoch) {
    if !BeginInputAction(false)
        return false
    Send "{" key " down}"
    try return InputPause(duration,epoch)
    finally {
        Send "{" key " up}"
        EndInputAction()
    }
}

EnsureRouteAndSpawn() {
    global gMapModel,gCameraOverheadReady,THREE_PATH_STAND
    ; F opens the manager only after every unit is placed. One left open from
    ; the last match hides the weather and Level Modifiers, so it is closed
    ; now (one F, only after two readings confirm it is open). The manager's
    ; own state was cleared by ResetMatchState at Vote Start.
    CloseUnitManagerIfOpen("Unit manager left open from the last match; press F once to close it before placement.")
    gCameraOverheadReady := false
    ; New match: the vision forgets the last map's path colour (yellow on Sand Village).
    VisionRequest("worldreset")
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
    ; P is switched ON (placement reads the lit path first, the red overlay
    ; only as fallback). Only a stop or a lost Roblox window ends preparation.
    if !EnsurePathLight("vote")
        return false
    ; Even fallback minimap detection must enable P before checking the arrow.
    if gMapModel.source!="vision" && !gMapModel.player {
        Log("Minimap route drawn, but the small player chevron was not found. Heart is the base.")
        return false
    }
    if !CameraReset()
        return false
    if gMapModel.source!="vision" {
        if !RefreshMapPlayer()
            return false
    } else if !ProbePlayer()
        return false
    gMapModel.baseHidden := false
    threePaths := gMapModel.HasProp("threePaths") && gMapModel.threePaths
    standPoint := threePaths?THREE_PATH_STAND:FabledKingdomStand(gMapModel)
    if standPoint {
        stand := MapNearest(gMapModel.nodes,standPoint.x,standPoint.y)
        gMapModel.standPoint := standPoint,gMapModel.checkpoints := [stand,stand,stand]
        gMapModel.checkpointIndex := 0,gMapModel.target := stand
        if threePaths
            Log("Three-path map: walk to the fixed spot where the paths meet beside the base (" standPoint.x "," standPoint.y ").")
        else
            Log("Fabled Kingdom (Summer): walk to the fixed bend above the enemy entrance (" standPoint.x "," standPoint.y ").")
        return true
    }
    gMapModel.checkpoints := MapPlacementCheckpoints(gMapModel)
    if gMapModel.checkpoints.Length!=3 && !gMapModel.baseMarker && gMapModel.player {
        ; The heart is hidden (the player spawns standing on it). The 25/50/75%
        ; points are the same from either end, so draw them now, walk to the
        ; middle one, and number them once the moving arrow uncovers the heart.
        quarters := MapRouteQuarters(gMapModel)
        if quarters.points.Length=3 {
            gMapModel.checkpoints := quarters.points,gMapModel.routeEnds := quarters.ends,gMapModel.baseHidden := true
            gMapModel.startPoint := {x:gMapModel.player.x,y:gMapModel.player.y}
            gMapModel.checkpointIndex := 0,gMapModel.target := quarters.points[2]
            Log("Base heart hidden on the minimap (player standing on it?). Route divided at 25%, 50%, 75%; walk to the middle point, then number the checkpoints once the heart is uncovered.")
            return true
        }
    }
    if gMapModel.checkpoints.Length!=3 {
        Log("Cannot divide the connected minimap route into three baseward checkpoints" (gMapModel.baseMarker?".":" (no base heart found)."))
        return false
    }
    gMapModel.checkpointIndex := 0,gMapModel.target := gMapModel.checkpoints[1]
    if gMapModel.HasProp("crossings") && gMapModel.crossings.Length
        Log("Two paths on the minimap (" gMapModel.crossings.Length " meeting points): travel to their first crossing before placement; later checkpoints are the next meeting points toward the base.")
    else
        Log((SandstormWeather()?"Sandstorm: route checkpoints at 35%, 50%, and 75%":"Route divided at 25%, 50%, and 75%") "; travel to checkpoint 1 before placement.")
    return true
}




; One unit per click: the click is repeated only while the same spot still
; shows a blue preview and no unit panel opened, i.e. the click was not taken.
; Roblox can ignore a click when the cursor has not moved since the preview
; appeared, so the cursor is nudged a few pixels and back before each click.



; -----------------------------------------------------------------------------
; Match state machine
; -----------------------------------------------------------------------------

HasVoteStart() {
    ; One capture of the vote panel: green Yes, red No and the yellow
    ; "Vote start:" title above them. Yes/No alone also matched the Replay
    ; screen (green Return to lobby beside a red boss health bar), which
    ; started a map scan on the end screen; that screen has no yellow there.
    frame := RefPixels(315,42,485,115)
    return frame.valid
        && UnitPanelColourHits(frame,315,90,395,115,IsUiGreen) > 8
        && UnitPanelColourHits(frame,405,90,485,115,IsUiRed) > 8
        && UnitPanelColourHits(frame,360,42,450,60,IsUiYellow) >= 10
}

WaitForVoteStart(timeoutMs) {
    global gRunning
    if !WaitFor(HasVoteStart,timeoutMs,250)
        return false
    ; Read only the title above Yes/No, once after the colours match.
    rows := ReadOcrRows(340,36,470,66)
    if !gRunning
        return false
    for row in rows {
        if RegExMatch(NormalizeWords(row.text),"^vote start$") {
            Log("Vote Start confirmed by OCR.")
            return true
        }
    }
    Log("Vote Start colours detected, but OCR did not confirm the title.")
    return false
}

HasLobbyPlay() {
    return CountRef(65,235,115,315,4,IsLobbyCyan) > 10
}

IsLobbyCyan(color) {
    RGB(color,&r,&g,&b)
    return r < 110 && g > 155 && b > 175
}

HasMatchmakingPanel() {
    if HasSavedColourControl("PlayHere",IsUiGreen)
        return true
    ; "Play Here" is the distinctive bright-green card in the central panel.
    return CountRef(260, 250, 405, 390, 6, IsUiGreen) > 14
}

HasOpenPortal() {
    ; The bright green Open button in the centred portal confirmation.
    return CountRef(165, 305, 325, 390, 5, IsUiGreen) > 16
}

TryStartPortal() {
    return ClickButton("PortalStart")
}



HasCardChoice(frame := 0) {
    ; The centre card alone signals the entire choice, regardless of hue.
    if !frame
        frame := RefPixels(295,175,510,435)
    if !frame.valid || !HasCardBorder(frame,314) || !HasCardBorder(frame,488)
        return false
    dark := 0
    for x in [366,401,436] {
        Loop 8 {
            RGB(frame.AtRef(x,300+(A_Index-1)*15),&r,&g,&b)
            if Max(r,g,b)<90
                dark += 1
        }
    }
    return dark>=12
}

HasCardBorder(frame,edgeX) {
    ; A narrow, persistent outline on a dark panel; no red/green restriction.
    Loop 21 {
        x := edgeX-11+A_Index,hits := 0
        Loop 21 {
            y := 195+A_Index*10
            RGB(frame.AtRef(x,y),&r,&g,&b)
            RGB(frame.AtRef(x-7,y),&lr,&lg,&lb)
            RGB(frame.AtRef(x+7,y),&rr,&rg,&rb)
            bright := Max(r,g,b),low := Min(r,g,b)
            contrast := Max(Abs(r-lr)+Abs(g-lg)+Abs(b-lb),Abs(r-rr)+Abs(g-rg)+Abs(b-rb))
            if bright>95 && contrast>75
                hits += 1
        }
        if hits>=15
            return true
    }
    return false
}

; A card choice that stays open this long is left to the game's own vote timer
; (it auto-picks); the run continues instead of ending.
global CARD_CHOICE_TIMEOUT_MS := 20000
; Pause between looks at a card that is still open in the watch loop.
global WATCH_CARD_RETRY_MS := 150

CheckCardInterruption() {
    global gRunning,gCardHandling,gCardAction,gCardPollAt,gCardInterruptEpoch
    global gPendingPlacement,gPlacementActiveUnit
    if !gRunning || gCardHandling || gCardAction="" || A_TickCount<gCardPollAt
        return false
    gCardPollAt := A_TickCount+100
    if !HasCardChoice()
        return false
    gCardInterruptEpoch += 1
    gCardHandling := true
    try {
        Log("Centre card appeared; pause " gCardAction ", choose, then resume the same unit.")
        ; Keep the pending click, but never count a panel obscured by cards.
        if ClearCardChoice() && gRunning && gCardAction="placement" && gPlacementActiveUnit && gPendingPlacement {
            RecoverPendingPlacement(gPlacementActiveUnit)
        }
    } finally gCardHandling := false
    return true
}

; Cards can open at any moment (also mid-placement) and cover the screen.
; Any unit preview is dropped first so a card click cannot place a unit.
ClearCardChoice() {
    global gCardHandling,gCardAction,gCardInterruptEpoch
    if !gCardHandling && gCardAction!="" && HasCardChoice()
        gCardInterruptEpoch += 1
    previous := gCardHandling,gCardHandling := true
    try return ClearCardChoiceAction()
    finally gCardHandling := previous
}

ClearCardChoiceAction() {
    global gRunning,gCardSelection,gUnitManagerClosedForCards,CARD_CHOICE_TIMEOUT_MS
    if !HasCardChoice() {
        if !gCardSelection {
            if gUnitManagerClosedForCards && WaitForCardChoiceClosed()
                ReopenUnitManagerAfterCards()
            return true
        }
        if WaitForCardChoiceClosed() {
            ResetCardSelection()
            ReopenUnitManagerAfterCards()
            return true
        }
        return false
    }
    ; A placement preview is dropped (Q) so a card click cannot buy a unit.
    ; Then close the F unit manager (F only after it is confirmed open) and
    ; the side unit panel (its own X; it covers the left card). Afterwards the
    ; manager is reopened and the top-priority unit is reselected through it.
    if !CancelUnitPreview()
        return false
    if !CloseUnitManagerForCards()
        return false
    CloseUnitPanelForCards()
    Log("Card choice is open; choosing before continuing.")
    deadline := A_TickCount+CARD_CHOICE_TIMEOUT_MS
    while gRunning && A_TickCount<deadline {
        if HasCardChoice()
            TryChooseCard()
        else if WaitForCardChoiceClosed() {
            ResetCardSelection()
            ReopenUnitManagerAfterCards()
            return true
        }
        ActionPause(150)
    }
    ; Not cleared. A timeout is not a stop: the caller gets false (so it takes
    ; no game action over the open card) and its loop carries on; only !gRunning
    ; ends a run.
    if gRunning
        Log("Card choice still open after " Round(CARD_CHOICE_TIMEOUT_MS/1000) "s; the game's vote timer will pick; continuing.")
    return false
}

ResetCardSelection() {
    global gCardSelection,gCardRetryAt,gCardUnread,gCardBoxes,gCardModifiersRead
    gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0,gCardBoxes := 0,gCardModifiersRead := false
}

WaitForCardChoiceClosed() {
    global gRunning
    closedAt := 0,deadline := A_TickCount+1400
    while gRunning && A_TickCount<deadline {
        if HasCardChoice()
            closedAt := 0
        else if !closedAt
            closedAt := A_TickCount
        else if A_TickCount-closedAt>=350
            return true
        if !ActionPause(70)
            return false
    }
    return false
}

ConfirmLockedCardSelection(cards := 0) {
    global gCardSelection,gCardRetryAt,gRunning
    if !gRunning || !gCardSelection
        return false
    if !HasCardChoice()
        return false
    if A_TickCount<gCardRetryAt {
        ActionPause(100)
        return true
    }
    choice := gCardSelection
    ; A re-click never re-runs OCR: each read costs about a second of the vote,
    ; and a re-read once mistook a card for green and switched to it. Only a
    ; fast pixel check remains: one clearly green card that is not the current
    ; (non-green) choice still takes over.
    if !cards {
        green := PixelGreenCards(RefPixels(120,175,690,445))
        if green.Length=1 && green[1]!=choice.index && !CardHasGreenEffect(choice) && !CardBeatsBuffs(choice)
            cards := PixelInkCards(green)
    }
    if cards {
        choice := PreferVerifiedGreenChoice(cards,choice)
        if choice.index!=gCardSelection.index
            Log("Verified green effect takes priority over the previous card choice; select card " choice.index ".")
        gCardSelection := choice
    }
    if CardIsSpeed(choice) {
        Log("Blocked forbidden positive Speed selection.")
        ResetCardSelection()
        return true
    }
    rect := CardRectangle(choice.index)
    Log("Keep card " choice.index ": " choice.kind " / " choice.stat "; awaiting confirmation.")
    ; The left card shares screen space with the side unit panel; click its
    ; lower part when that panel is still showing so Upgrade is never hit.
    clickY := choice.index=1 && HasUnitPanel()?405:330
    ; Each retry clicks a little higher or lower on the card, in case the game
    ; ignores a repeat click on the same pixel.
    tries := choice.HasProp("tries")?choice.tries:0,choice.tries := tries+1
    clickY += [0,14,-14][Mod(tries,3)+1]
    ; Recheck after moving: a closing dialog must not receive another click.
    if !ClickRef((rect[1]+rect[3])//2,clickY,HasCardChoice)
        return true
    gCardRetryAt := A_TickCount+1000
    if WaitForCardChoiceClosed() {
        ApplySelectedCardModifiers(choice)
        Notify("Selected " choice.kind ": " choice.stat)
        ResetCardSelection()
    }
    return true
}

TryChooseCard() {
    global gCardRetryAt, gCardUnread, gCardSelection, gRunning, REF_W, REF_H, gCardModifiersRead
    if !HasCardChoice()
        return false
    if gCardSelection
        return ConfirmLockedCardSelection()
    if A_TickCount < gCardRetryAt {
        ActionPause(100)
        return true
    }
    RefreshCardBoxes()
    ; GREEN FIRST: one card with green words is chosen at once from its
    ; pixels, before OCR (votes can end within seconds). Not in the Medium
    ; late game, where a Tier II Shield or Explosive Death beats buffs, so the
    ; red cards must be read first.
    frame := RefPixels(120,175,690,445)
    green := PixelGreenCards(frame)
    if green.Length=1 && !CardLateMedium() {
        cards := PixelInkCards(green)
        Log("Card " green[1] " is the only card with green words; choose it immediately.")
        gCardUnread := 0
        gCardSelection := cards[green[1]].Clone()
        gCardSelection.index := green[1]
        return ConfirmLockedCardSelection(cards)
    }
    geometry := WindowGeometry()
    if !geometry
        return false
    ; One OCR read covers the cards and the Level Modifiers panel to their
    ; right (uncovered while the cards are up): red cards are judged on the
    ; real match totals, read once per card screen.
    words := ReadOcrRows(125,175,785,455,true)
    if !gCardModifiersRead {
        gCardModifiersRead := true
        ReadModifiersForCards(words,geometry)
    }
    cards := ReadWordColourCards(words,frame,geometry)
    for index,card in cards
        if card.stat!="unknown" && card.kind!="unknown" && !CardIsSpeed(card)
            RememberCard(CardVisual(index),card)
    best := ChooseBestCard(cards)
    if !best {
        ; Retry unclear wording first. The fallback then takes a green card, the
        ; easiest readable red card, or an unreadable card; never positive Speed.
        gCardUnread += 1
        if gCardUnread < 3 {
            Log("Card text unclear; retrying OCR (" gCardUnread "/3).")
            gCardRetryAt := A_TickCount + 1500
            return true
        }
        best := FallbackCardChoice(cards)
        if !best {
            Log("Only positive Speed is offered; not clicking (the vote timer decides).")
            gCardRetryAt := A_TickCount+1500
            return true
        }
        Log("Card text partly unclear; choose safe card " best ".")
    }
    gCardUnread := 0
    LogCardDecision(cards,best)
    gCardSelection := cards[best].Clone()
    gCardSelection.index := best
    return ConfirmLockedCardSelection(cards)
}

HasValue(list,value) {
    for item in list {
        if item = value
            return true
    }
    return false
}

; One click on the visible Yes. A counted vote closes the panel within about
; a second. If it is still open 4 s later, the "0/1" count under the title
; decides: a vote already counted gets no second click (Yes may toggle it
; back off); otherwise one more click, after moving the cursor off and back
; so Roblox sees it arrive. The countdown starts the match anyway, so an
; open panel never stops the run: the macro waits for it to close.
; Returns true once the panel is gone; false only when stopped or after a
; minute with the panel still open.
TryVoteStart() {
    if !HasVoteStart()
        return true
    Loop 2 {
        ; Aim at the visible affirmative button, never a stale OCR/learned point.
        if !FindUiGreenCentre(315,90,395,115,&rx,&ry)
            break
        if A_Index>1 {
            voters := ReadVoteCount()
            if voters!="" && voters>=1 {
                Log("Vote Start still open, but the count shows " voters " vote(s); no second click.")
                break
            }
            Log("Vote Start still open 4 s after the click (count " (voters=""?"unreadable":voters) "); one more click.")
            SaveClickMissCrop("vote",250,0,550,160)
            if !MoveRef(rx,ry+60)
                return false
        }
        Log("Vote Start: left click visible start/Yes button at " rx ", " ry)
        if !ClickRef(rx,ry)
            return false
        if WaitFor(VoteStartClosed,4000,100)
            return true
    }
    Log("Vote Start panel still open; waiting for its countdown to start the match.")
    return WaitFor(VoteStartClosed,60000,250)
}

; The number of Yes votes in the "0/1" under the title, or "" if unreadable.
ReadVoteCount() {
    for row in ReadOcrRows(372,62,436,88)
        if RegExMatch(StrReplace(StrLower(row.text)," "),"([0-9o])/\d",&m)
            return m[1]="o"?0:Integer(m[1])
    return ""
}

; cache\clickmiss-<name>-<date_time>.bmp: the screen region of a click that
; did not take, read after the wait, for checking what was on screen.
SaveClickMissCrop(name,x1,y1,x2,y2) {
    DirCreate A_ScriptDir "\cache"
    file := A_ScriptDir "\cache\clickmiss-" name "-" FormatTime(A_Now,"yyyy-MM-dd_HH-mm-ss") ".bmp"
    frame := RefPixels(x1,y1,x2,y2)
    if frame.valid && SaveFrameBmp(frame,file)
        Log("Saved the screen where the " name " click did not take: " file)
    PruneCacheImages("clickmiss-*.bmp",10)
}

VoteStartClosed() {
    return !HasVoteStart()
}

; Sit out a failed preparation until the regular endgame flow can replay.
SitOutMatch(reason) {
    global gRunning
    if !gRunning
        return ""
    ReleaseMovementKeys()
    Notify(reason " Sitting out this match; Replay follows its end screen.")
    while gRunning {
        if HasCardChoice()
            ClearCardChoice()
        else if TryEndState()
            return "replay"
        ActionPause(500)
    }
    return ""
}

; Vote Start did not appear in time (slow teleport, missed frame). Instead of
; ending the run, keep reading the screen until it shows something to act on:
; Vote Start -> continue, lobby -> restart from LobbyPlay, end screen -> Replay,
; match already running -> sit it out. F7 and disconnects still end this.
RecoverVoteStart(fromQueue := false) {
    global gRunning,gReconnecting,gAwaitingReplayMap
    ; F7 also ends the Vote Start wait; that is a stop, not a timeout.
    if !gRunning || gReconnecting
        return ""
    ; A stale replay latch would make every end-screen check pass at once.
    gAwaitingReplayMap := false
    Notify(fromQueue?"Queue flow interrupted. Watching for Lobby Play or Vote Start."
        :"Vote Start not seen in time. Watching the screen to recover.")
    matchSince := 0,nextNote := A_TickCount+30000
    while gRunning && !gReconnecting {
        if HasVoteStart() {
            matchSince := 0
            if WaitForVoteStart(5000)
                return "vote"
        } else if HasLobbyPlay() && (!fromQueue || ReadVisibleLobbyPlay()) {
            ResetEndGameFlow()
            Notify("Recovery: back in the lobby. Restarting from LobbyPlay.")
            return "restart"
        } else if ReadEndScreen().stage!="none" {
            matchSince := 0
            if TryEndState()
                return "replay"
        } else if GetMiniMapRoutePoints().Length>=8 {
            ; The minimap also shows during the vote countdown, so the match
            ; only counts as started after 10 s with no Vote Start panel.
            if !matchSince
                matchSince := A_TickCount
            else if A_TickCount-matchSince>=10000
                return SitOutMatch("Recovery: the match started without a confirmed Vote Start.")
        } else
            matchSince := 0
        if A_TickCount>=nextNote {
            Log("Recovery: still no Vote Start, lobby, end screen or running match on screen.")
            nextNote := A_TickCount+30000
        }
        ActionPause(500)
    }
    return ""
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
            hill: controls.hill.Value,
            hybrid: controls.hybrid.Value,
            money: controls.money.Value,
            name: controls.name.Value,
            count: count,
            priority: priority,
            target: Max(0, Integer(controls.target.Value))
        })
    }
    return plan
}


ResetIdleKeepAlive() {
    global gIdleKeepAliveAt
    gIdleKeepAliveAt := 0
}

IdleKeepAliveAllowed() {
    global gRunning,gPlacements
    return gRunning && gPlacements.Length && !UpgradeQueue().Length
        && !HasCardChoice() && !HasUnitPanel() && !IsEndGameBlocking()
}

IdleKeepAliveTick() {
    global gRunning,gPlacements,gIdleKeepAliveAt,IDLE_KEEPALIVE_MS,CLICK_AWAY_X,CLICK_AWAY_Y
    if !gRunning || !gPlacements.Length || UpgradeQueue().Length {
        ResetIdleKeepAlive()
        return false
    }
    if !gIdleKeepAliveAt {
        gIdleKeepAliveAt := A_TickCount
        return false
    }
    if A_TickCount-gIdleKeepAliveAt<IDLE_KEEPALIVE_MS || !IdleKeepAliveAllowed()
        return false
    hwnd := FindRoblox()
    if !hwnd
        return false
    ; Focus Roblox before cancelling a preview, so Q cannot reach another app.
    if !WinActive("ahk_id " hwnd) {
        WinActivate "ahk_id " hwnd
        if !WinWaitActive("ahk_id " hwnd,,1)
            return false
    }
    if !gRunning || !CancelUnitPreview()
        return false
    ; The existing click-away point is above/outside the card area. Recheck
    ; state after smooth movement so a newly opened dialog takes priority.
    if !ClickRef(CLICK_AWAY_X,CLICK_AWAY_Y,IdleKeepAliveAllowed)
        return false
    gIdleKeepAliveAt := A_TickCount
    Log("Idle keep-alive: clicked Roblox after five minutes without upgrades.")
    return true
}

NavigateForPlacement() {
    global gRunning,gNavigationTimedOut,gMapModel
    if NavigateAlongRoute() {
        ; At a fixed spot (Sky Island) placement stays put: no relocation.
        if gMapModel && gMapModel.HasProp("standPoint")
            gMapModel.checkpointIndex := 3
        else if gMapModel && gMapModel.HasProp("checkpoints")
            gMapModel.checkpointIndex := 1
        Log("Mapped destination reached; continuing into placement preparation.")
        return true
    }
    if !gRunning
        return false
    if !gNavigationTimedOut && PrepTimeLeft()>0 {
        Notify("Navigation stopped before timeout. Check the player arrow and green minimap line.")
        return false
    }
    gNavigationTimedOut := true
    ReleaseMovementKeys()
    ; Time ran out before the heart was seen: still number the checkpoints, so
    ; later relocations move baseward.
    ResolveHiddenBase(true)
    ResetPlacementSearch()
    Log("Navigation time expired. Keep the current player position; use the same path-side placement and selected Hill preferences.")
    return true
}

RunMacro() {
    global gRunning, gPlacements, gMatchReported,gAwaitingReplayMap,gEndHandling
    global gMatchWeather,gMapModel,gQueueMode,gAwaitingLobby
    SaveUnitSettings()
    ResetIdleKeepAlive()
    plan := ReadUnitPlan()
    returningToLobby := gAwaitingLobby
    if returningToLobby
        Notify("Waiting for lobby Play before queuing again.")
    if gAwaitingReplayMap {
        if !WaitForReplayVoteStart() {
            outcome := RecoverVoteStart()
            if outcome!="vote"
                return ResultOrEndRun(outcome,"Vote Start was not recovered after Replay (stopped, disconnected, or nothing to act on).")
        }
    } else {
        submittedAt := 0,voteVisible := HasVoteStart()
        if !voteVisible {
            if !returningToLobby && IsEndGameBlocking() {
                if TryEndState()
                    return "replay"
                return EndRun("The end screen was not handled (stopped or no Replay option).")
            }
            if !returningToLobby && !HasLobbyPlay() && GetMiniMapRoutePoints().Length>=8 {
                Notify("Match already running. A fresh Vote Start is required for a new build.")
                return EndRun("A match is already running; a fresh Vote Start is required for a new build.")
            }
            SetPhase("Lobby")
            submittedAt := TryStartFromLobby(returningToLobby)
            ; The lobby flow ends the run itself (EndRun logs why) when its stages and restarts run out.
            if !submittedAt && gRunning && InPhase("Idle")
                return ""
            if !submittedAt && (!gRunning || !gQueueMode) {
                if gRunning
                    Notify("Could not find the lobby Play flow. Teach LobbyPlay with F10 if OCR cannot read it.")
                return EndRun(gRunning?"Could not find the lobby Play flow.":"Stopped while starting from the lobby.")
            }
        }
        if returningToLobby && gRunning
            ResetMatchState()
        Notify("Waiting for Vote Start before any map preparation.")
        if gQueueMode {
            if (!voteVisible && !submittedAt) || !WaitForQueuedMatch(submittedAt) {
                ; A fresh queue inside the wait can end the run (lobby restart limit); EndRun has logged it.
                if gRunning && InPhase("Idle")
                    return ""
                outcome := RecoverVoteStart(true)
                if outcome!="vote"
                    return ResultOrEndRun(outcome,"The queued match did not reach Vote Start (stopped, disconnected, or nothing to act on).")
            }
        } else if !WaitForVoteStart(45000) {
            outcome := RecoverVoteStart()
            if outcome!="vote"
                return ResultOrEndRun(outcome,"Vote Start was not seen and recovery ended without a result.")
        }
    }
    ; Only a fresh Vote Start releases the old endgame state. The map is
    ; scanned anew below, even when Replay takes us to another map layout.
    ResetMatchState()
    SetPhase("Preparing")
    Notify("Vote Start detected. Drawing minimap, setting overhead view, then navigating.")
    gMatchReported := false
    ReadMatchConditions()
    if !EnsureRouteAndSpawn()
        return ResultOrEndRun(SitOutMatch("Minimap preparation stopped. The Activity tab and minimap-debug.png show the missing signal."),"Minimap preparation stopped and the match was sat out until stopped.")
    Notify("Following the green minimap route into position.")
    if !NavigateForPlacement()
        return ResultOrEndRun(SitOutMatch("Navigation to the placement area failed."),"Navigation to the placement area failed and the match was sat out until stopped.")
    if !TryVoteStart() {
        if !gRunning
            return EndRun("Stopped while waiting for the vote to close.")
        return ResultOrEndRun(SitOutMatch("Vote Start stayed open for over a minute after clicking Yes."),"Vote Start stayed open and the match was sat out until stopped.")
    }
    ; If the vote obscured the weather, read the panel once more before buying.
    if !gMatchWeather && !gMapModel.HasProp("standPoint") {
        ReadMatchConditions()
        if SandstormWeather() {
            points := MapPlacementCheckpoints(gMapModel)
            if points.Length=3 && points[1]!=gMapModel.checkpoints[1] {
                gMapModel.checkpoints := points,gMapModel.checkpointIndex := 0,gMapModel.target := points[1]
                Log("Sandstorm: travel to the 35% waypoint before placement.")
                if !NavigateForPlacement()
                    return ResultOrEndRun(SitOutMatch("Navigation to the Sandstorm waypoint failed."),"Navigation to the Sandstorm waypoint failed and the match was sat out until stopped.")
            }
        }
    }
    Log("Starting ordered placement from the player along one side of the illuminated path.")
    SetPhase("Placing")
    ; P again, now that the vote is over: a lit path must show if this map
    ; variant is known to have one (EnsurePathLight, once-per-match off-on).
    EnsurePathLight("placing")
    PreparePlacementMemory()
    LoadRememberedHillMisses()
    BeginPlacementRun()
    buildResult := PlaceConfiguredBuild(plan)
    if buildResult!="complete"
        return buildResult="replay"?"replay":EndRun("Placement ended without a complete build (result '" buildResult "').")
    Notify("Build placed: " gPlacements.Length " units. Watching upgrades/end screen.")
    ; Only now may F open the manager; it stays open while upgrades remain.
    BeginUnitManagerPhase()
    if !HasCardChoice() && !IsEndGameBlocking()
        EnsureUnitManagerOpen()
    while gRunning {
        if HasCardChoice() {
            ResetIdleKeepAlive()
            ; A card that stays open (timeout) or a failed step is not a reason to
            ; end the run: the loop looks again. Only !gRunning leaves the loop.
            ClearCardChoice()
            ActionPause(WATCH_CARD_RETRY_MS)
            continue
        }
        if TryEndState() {
            Notify(gAwaitingLobby?"Returning to lobby for the next queue.":"Replay selected. Waiting for the next match.")
            return "replay"
        }
        if gEndHandling {
            ActionPause(200)
            continue
        }
        RefreshMatchModifiers()
        RefreshMatchWave()
        if UnitManagerActive() {
            ; An F that would not open pauses upgrades for a cooldown (a
            ; timestamp, not a sleep): cards, the end screen and disconnects
            ; are still handled by this loop meanwhile.
            if !ManagerCooldownActive() {
                MaintainUnitManager()
                UpgradePriorityPass()
            }
            ; The manager and the record keep disagreeing about a unit: close F,
            ; audit the build in the Placing phase, place what is missing, and
            ; come back to Upgrading (bounded by AUDIT_LIMIT_PER_MATCH).
            if gRunning && ManagerAuditDue() {
                repaired := RepairBuildAfterManagerMismatch(plan)
                if repaired!="complete"
                    return repaired="replay"?"replay":EndRun("Build repair after a unit manager mismatch ended without a complete build (result '" repaired "').")
                continue
            }
            ; Every target reached: close the manager once and keep it closed.
            if gRunning && !UpgradeQueue().Length && !HasCardChoice() && !IsEndGameBlocking() {
                CloseUnitManagerIfOpen("All upgrade targets reached; press F once to close the unit manager.")
                EndUnitManagerPhase()
            }
        } else {
            ; A target raised in the panel mid-match brings the manager back.
            for item in gPlacements
                RefreshRecordedUpgradeTarget(item)
            if UpgradeQueue().Length && !HasCardChoice() && !IsEndGameBlocking() {
                BeginUnitManagerPhase("An upgrade target was raised; the F unit manager opens again.")
                EnsureUnitManagerOpen()
            }
        }
        IdleKeepAliveTick()
        ActionPause(100)
    }
    return EndRun("Stopped while watching upgrades and the end screen.")
}

; The steps every run start shares (F6 and the restart after a reconnect):
; Roblox found, sized, attached and focused, the mode read, the run flag on.
; Returns false, with a status message, when Roblox is not ready.
PrepareRunStart() {
    global gRunning,gUnitPreviewActive,gMatchMode,gQueueMode
    if !GetClient(&cx, &cy, &cw, &ch) {
        Notify("Open Roblox before starting.")
        return false
    }
    ResizeRoblox()
    ; Refresh the attachment at every start, so dragging the Roblox window
    ; before a run becomes its new offset from the macro panel.
    AttachRoblox()
    hwnd := FindRoblox()
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2) {
        Notify("Bring Roblox to the foreground before starting.")
        return false
    }
    gQueueMode := gMatchMode.Text="Queue"
    gRunning := true
    gUnitPreviewActive := true
    return true
}

StartMacro(*) {
    global gRunning,gSessionArmed,gQueueMode,gReconnecting
    ; A reconnect is pending (the Disconnected dialog is being handled): a run
    ; started now would act over the dialog. gRunning is held by that loop.
    if gReconnecting {
        Log("Reconnect in progress; F6 ignored. Press F7 to stop.")
        return
    }
    if gRunning
        return
    if !PrepareRunStart()
        return
    gSessionArmed := true
    BeginSessionLog()
    Notify("Running in " (gQueueMode?"Queue":"Solo") " mode. F7 stops immediately.")
    SetTimer CheckDisconnect, 3000
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
        ResetMatchState()
        SetPhase("Preparing")
        if EnsureRouteAndSpawn() && NavigateAlongRoute()
            Notify("Route test complete. Player aligned with the route; no units placed.")
        else
            Notify("Route test stopped. Inspect the Activity log before continuing.")
    } catch as err {
        Notify("Route test stopped: " err.Message)
    } finally {
        gRunning := false
        SetPhase("Idle")
        ReleaseMovementKeys()
    }
}

RunMacroSafely() {
    global gRunning,gMacroThreadActive
    gMacroThreadActive := true
    try {
        while gRunning {
            ; "replay" = next match after Replay; "restart" = recovered to the lobby.
            result := RunMacro()
            if result!="replay" && result!="restart"
                break
        }
    }
    catch as err {
        Notify("Stopped: " err.Message)
        EndRun("error: " err.Message)
    }
    finally {
        if gRunning {
            gRunning := false
            SetPhase("Idle")
            ReleaseMovementKeys()
        }
        gMacroThreadActive := false
    }
}

StopMacro(*) {
    global gReconnecting,gReconnectButton,gSessionArmed
    gSessionArmed := false
    gReconnecting := false,gReconnectButton := false
    SetTimer CheckDisconnect, 0
    SetTimer ReconnectAndRestart, 0
    AbandonCurrentAction()
    Notify("Stopped.")
    EndSessionLog("session stopped (F7)")
}

; Everything F7 does to the running action: inputs released, waits and OCR
; cut short, the phase back to Idle.
AbandonCurrentAction() {
    global gRunning, gOcrPid, gInputEpoch
    gInputEpoch += 1
    gRunning := false
    ResetIdleKeepAlive()
    SetPhase("Idle")
    ResetUnitManagerState()
    if gOcrPid && ProcessExist(gOcrPid) {
        try ProcessClose gOcrPid
    }
    ReleaseMovementKeys()
}

; Look for the centered dark panel before paying for OCR during a run.
HasDisconnectPanel() {
    return CountRef(315,240,485,335,8,IsDisconnectGrey)>=140
}

IsDisconnectGrey(color) {
    RGB(color,&r,&g,&b)
    lightest := Max(r,g,b)
    return lightest>=20 && lightest<=95 && lightest-Min(r,g,b)<=16
}

CheckDisconnect() {
    global gSessionArmed,gRunning,gReconnecting,gReconnectButton,gOcrPid,gInputEpoch,gMacroThreadActive
    ; Gated on the session (F6 until F7), not on the run loop: if the run loop
    ; ended by itself while F6 is still on, Reconnect must still work. This
    ; function never writes gRunning; the OCR read is told to stop on F7 only.
    if !gSessionArmed || gReconnecting || gOcrPid || !HasDisconnectPanel()
        return
    runEnded := !gRunning
    if runEnded && gMacroThreadActive
        return
    epoch := gInputEpoch
    button := FindReconnectButton(&disconnected,() => gSessionArmed)
    if !button || !gSessionArmed || epoch!=gInputEpoch
        return
    if runEnded
        Log("The run loop had ended without F7; the Disconnected dialog is still handled.")
    gReconnecting := true,gReconnectButton := button
    AbandonCurrentAction()
    Notify("Disconnected. Clicking Reconnect once a second until lobby Play returns.")
    SetTimer ReconnectAndRestart, -300
}

; Read individual words so Leave and Reconnect on the same line stay separate.
; keepReading (optional) is the OCR keep-going predicate; the default keeps
; reading while the run is live (gRunning).
FindReconnectButton(&disconnected,keepReading := 0) {
    global REF_W,REF_H
    disconnected := false
    hwnd := FindRoblox()
    if !hwnd || !GetClient(&cx,&cy,&cw,&ch)
        return false
    titleY := 0,button := false
    for word in ReadOcrRows(220,185,580,425,true,2,keepReading) {
        switch NormalizeWords(word.text) {
        case "disconnected": titleY := word.y
        case "reconnect": button := word
        }
    }
    disconnected := titleY>0
    if !disconnected || !button || button.y<=titleY || FindRoblox()!=hwnd
        return false
    box := [button.x*REF_W/cw,button.y*REF_H/ch,(button.x+button.w)*REF_W/cw,(button.y+button.h)*REF_H/ch]
    label := RefPixels(box*)
    return label.valid ? {hwnd:hwnd,box:box,label:label,x:(box[1]+box[3])/2,y:(box[2]+box[4])/2} : false
}

; Reuse the located label while it stays visible. Compare its light and dark
; pixels separately so a blank patch cannot match, even if the text is small.
ReconnectButtonVisible(button) {
    if FindRoblox()!=button.hwnd
        return false
    label := button.label,frame := RefPixels(button.box*)
    if !frame.valid || frame.width!=label.width || frame.height!=label.height
        return false
    dark := 0,light := 0,darkMatches := 0,lightMatches := 0
    y := 0
    while y<frame.height {
        x := 0
        while x<frame.width {
            wasLight := (label.At(x,y)&0xFF00)>=0x8000
            isLight := (frame.At(x,y)&0xFF00)>=0x8000
            if wasLight
                light += 1,lightMatches += isLight
            else
                dark += 1,darkMatches += !isLight
            x += 2
        }
        y += 2
    }
    return dark>0 && light>0 && darkMatches>=dark*0.75 && lightMatches>=light*0.75
}

ReleaseMovementKeys() {
    Send "{w up}{a up}{s up}{d up}{Space up}{Up up}{Down up}{Left up}{Right up}{i up}{o up}{LButton up}"
}

WaitFor(test, timeoutMs, pollMs := 80) {
    global gRunning
    deadline := A_TickCount + timeoutMs
    while gRunning && A_TickCount < deadline {
        if test.Call()
            return true
        if CheckCardInterruption()
            return false
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
    SessionLogLine(entry)
    previous := gActivityLog.Value
    ; Keep the control responsive during long replay sessions.
    if StrLen(previous) > 14000
        previous := SubStr(previous, -9000)
    gActivityLog.Value := previous entry "`r`n"
}

; Session logs: logs\session-<date>_<time>.log. Every Log line is appended at
; once, so a session survives the macro being closed or killed without F7.
; F6 starts a new file; lines outside a session (opening the macro, F8/F9
; tests, after F7) go to the current file. Markers show where F6/F7 were
; pressed and when the macro closed; a file without them was cut short.

SessionLogLine(entry) {
    global gSessionLogFile
    try {
        if gSessionLogFile="" {
            PruneSessionLogs()
            SessionLogMarker("macro opened",true)
        }
        FileAppend entry "`r`n",gSessionLogFile,"UTF-8"
    }
}

SessionLogMarker(text,newFile := false) {
    global LOG_DIR,gSessionLogFile
    try {
        if newFile || gSessionLogFile="" {
            DirCreate LOG_DIR
            gSessionLogFile := LOG_DIR "\session-" FormatTime(A_Now,"yyyy-MM-dd_HH-mm-ss") ".log"
        }
        FileAppend "===== " FormatTime(A_Now,"yyyy-MM-dd HH:mm:ss") "  " text " =====`r`n",gSessionLogFile,"UTF-8"
    }
}

; When the macro opens: session logs not written to for 30 days are deleted.
PruneSessionLogs() {
    global LOG_DIR,SESSION_LOG_DAYS
    cutoff := DateAdd(A_Now,-SESSION_LOG_DAYS,"Days")
    try Loop Files LOG_DIR "\session-*.log" {
        if A_LoopFileTimeModified<cutoff
            try FileDelete A_LoopFileFullPath
    }
}

; F6: a new file per run. The file opened with the macro is reused for the
; first run, so opening and then starting does not leave a stray file.
BeginSessionLog() {
    global gSessionLogHasRun,gSessionLogFile
    SessionLogMarker("session started (F6)",gSessionLogHasRun || gSessionLogFile="")
    gSessionLogHasRun := true
}

EndSessionLog(reason,*) {
    global gActivityLog
    if gActivityLog
        SessionLogMarker(reason)
    return 0
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
    learned := RunLearningTests()
    mapped := RunMapTests()
    return "PASS: " passed " navigation checks; " learned " learning/policy checks; " mapped " minimap checks"
}


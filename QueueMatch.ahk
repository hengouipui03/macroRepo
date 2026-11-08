global gMatchMode := 0,gQueueMode := false

SaveMatchMode(control,*) {
    global UNIT_SETTINGS_FILE
    try IniWrite control.Text,UNIT_SETTINGS_FILE,"Macro","mode"
}

StartQueueMatch() {
    global gRunning
    if !ClickButton("FindMatch") {
        if gRunning
            Notify("Find Match could not be clicked. Teach FindMatch in Learning with F10.")
        return false
    }
    attempts := 0
    while gRunning {
        geometry := WindowGeometry()
        if !geometry
            return false
        prompt := ParseQueuePrompt(ReadOcrRows(245,205,555,435,true,3),geometry)
        if prompt && QueuePromptVisible(prompt)
            break
        attempts += 1
        if attempts=3 && gRunning
            Notify("Queue number unreadable. Waiting and retrying the read.")
        if !ActionPause(attempts<3?350:2500,false)
            return false
    }
    if !gRunning
        return false
    visible := () => QueuePromptVisible(prompt)
    if !ClickRef(prompt.inputX,prompt.inputY,visible) || !BeginInputAction()
        return false
    hwnd := FindRoblox()
    if !gRunning || !hwnd || !WinActive("ahk_id " hwnd) || !visible.Call()
        return false
    try SendEvent prompt.number
    finally EndInputAction()
    if !ClickRef(prompt.submit.x,prompt.submit.y,visible)
        return false
    submittedAt := A_TickCount
    if !WaitFor(() => !QueuePromptVisible(prompt),5000,150) {
        if gRunning
            Notify("The number prompt stayed open after Submit.")
        return false
    }
    ConfirmObservedTransition("FindMatch")
    Notify("Queue submitted. Waiting for matchmaking and Vote Start.")
    return submittedAt
}

WaitForQueuedMatch(submittedAt) {
    global gRunning
    lobbyCheckAt := submittedAt?submittedAt+10000:0
    retryAt := 0
    while gRunning {
        if HasVoteStart() {
            if WaitForVoteStart(1000)
                return true
        } else if retryAt && A_TickCount>=retryAt {
            retryAt := 0
            if HasLobbyPlay() {
                Notify("Lobby Play is still visible. Starting a fresh queue.")
                submittedAt := TryStartFromLobby()
                if !submittedAt
                    return false
                lobbyCheckAt := submittedAt+10000
            }
        } else if lobbyCheckAt && A_TickCount>=lobbyCheckAt {
            lobbyCheckAt := 0
            if HasLobbyPlay() {
                retryAt := A_TickCount+15000
                Notify("Lobby Play is still visible 10 seconds after Submit. Waiting another 15 seconds before retrying.")
            }
        }
        if !ActionPause(250,false)
            break
    }
    return false
}

; The number and input are stacked between the two button centres. Measure
; the layout in client pixels before scaling to the macro's reference size.
ParseQueuePrompt(rows,geometry) {
    global REF_W,REF_H
    submit := 0,cancel := 0,numbers := []
    for row in rows {
        word := Trim(row.text),point := {x:row.x+row.w/2,y:row.y+row.h/2}
        if StrLower(word)="submit"
            submit := point
        else if StrLower(word)="cancel"
            cancel := point
        else if RegExMatch(word,"^[0-9]{1,8}$") {
            point.number := word
            numbers.Push(point)
        }
    }
    if !submit || !cancel
        return false
    gap := cancel.x-submit.x
    if gap<geometry.cw*.04 || gap>geometry.cw*.24 || Abs(cancel.y-submit.y)>gap*.14
        return false
    centre := (submit.x+cancel.x)/2,number := 0
    for point in numbers {
        rise := submit.y-point.y
        if Abs(point.x-centre)>gap*.25 || rise<gap*.34 || rise>gap*.72
            continue
        if number
            return false
        number := point
    }
    if !number
        return false
    sx := REF_W/geometry.cw,sy := REF_H/geometry.ch
    return {number:number.number,inputX:centre*sx,inputY:(number.y+submit.y)/2*sy,
        submit:{x:submit.x*sx,y:submit.y*sy},cancel:{x:cancel.x*sx,y:cancel.y*sy}}
}

QueuePromptVisible(prompt) {
    left := prompt.submit,right := prompt.cancel
    frame := RefPixels(left.x-13,Min(left.y,right.y)-7,right.x+13,Max(left.y,right.y)+7)
    return frame.valid && UnitPanelColourHits(frame,left.x-13,left.y-7,left.x+13,left.y+7,IsUiGreen)>=4
        && UnitPanelColourHits(frame,right.x-13,right.y-7,right.x+13,right.y+7,IsUiRed)>=4
}

global gMatchMode := 0,gQueueMode := false

SaveMatchMode(control,*) {
    global UNIT_SETTINGS_FILE
    try IniWrite control.Text,UNIT_SETTINGS_FILE,"Macro","mode"
}

ReadVisibleFindMatch() {
    global REF_W,REF_H,gRunning
    if !gRunning || !HasMatchmakingPanel() || !(geometry := WindowGeometry())
        return false
    for row in ReadOcrRows(ButtonRegion("FindMatch")*) {
        label := StrReplace(NormalizeWords(row.text)," ")
        ; OCR can lose the initial F against the card artwork.
        if !RegExMatch(label,"^(?:f|-)?indmatch$")
            continue
        return {x:(row.x+row.w/2)*REF_W/geometry.cw,y:(row.y+row.h/2)*REF_H/geometry.ch}
    }
    return false
}

StartQueueMatch(findMatch) {
    global gRunning
    ; The Find Match outline can change under the cursor. Check the panel
    ; using Play Here, then verify the click by waiting for the number prompt.
    if !ClickRef(findMatch.x,findMatch.y,HasMatchmakingPanel)
        return RetryQueueMatch("Find Match could not be clicked.")
    Log("Clicked visible Find Match. Waiting for the number prompt.")
    deadline := A_TickCount+8000,prompt := false
    while gRunning && A_TickCount<deadline {
        geometry := WindowGeometry()
        if !geometry
            return false
        read := ParseQueuePrompt(ReadOcrRows(245,205,555,435,true,3),geometry)
        if read && QueuePromptVisible(read) {
            prompt := read
            if prompt.number!=""
                break
        }
        if !ActionPause(350,false)
            return false
    }
    if !gRunning
        return false
    if !prompt || !QueuePromptVisible(prompt)
        return RetryQueueMatch("The number prompt did not appear after Find Match.")
    if prompt.number=""
        return RetryQueueMatch("The queue number could not be read.",prompt)
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
    if !WaitFor(() => !visible.Call(),5000,150)
        return RetryQueueMatch("The number prompt stayed open after Submit.",prompt)
    Notify("Queue submitted. Waiting for matchmaking and Vote Start.")
    return submittedAt
}

RetryQueueMatch(reason,prompt := false) {
    global gRunning
    if !gRunning
        return false
    if prompt && QueuePromptVisible(prompt) {
        if !ClickRef(prompt.cancel.x,prompt.cancel.y,() => QueuePromptVisible(prompt))
            || !WaitFor(() => !QueuePromptVisible(prompt),3000,150) {
            if gRunning
                Notify(reason " The number prompt could not be dismissed.")
            return false
        }
    }
    Notify(reason " Checking Find Match again or restarting from Lobby Play.")
    return ActionPause(3000,false) ? "retry" : false
}

; How long a queued match may take to reach Vote Start before the wait hands
; over to RecoverVoteStart (which logs what it finds), and the pause per poll.
global QUEUE_WAIT_LIMIT_MS := 900000,QUEUE_WAIT_POLL_MS := 250
; Lobby Play still showing this long after Submit; the wait before a fresh queue.
global QUEUE_LOBBY_CHECK_MS := 10000,QUEUE_LOBBY_RETRY_WAIT_MS := 15000

WaitForQueuedMatch(submittedAt) {
    global gRunning,QUEUE_WAIT_LIMIT_MS,QUEUE_WAIT_POLL_MS,QUEUE_LOBBY_CHECK_MS,QUEUE_LOBBY_RETRY_WAIT_MS
    lobbyCheckAt := submittedAt?submittedAt+QUEUE_LOBBY_CHECK_MS:0
    retryAt := 0,startedAt := A_TickCount
    while gRunning {
        if A_TickCount-startedAt>=QUEUE_WAIT_LIMIT_MS {
            Notify("The queued match did not reach Vote Start in " Round(QUEUE_WAIT_LIMIT_MS/60000) " minutes; checking the screen for recovery.")
            return false
        }
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
                lobbyCheckAt := submittedAt+QUEUE_LOBBY_CHECK_MS
            }
        } else if lobbyCheckAt && A_TickCount>=lobbyCheckAt {
            lobbyCheckAt := 0
            if HasLobbyPlay() {
                retryAt := A_TickCount+QUEUE_LOBBY_RETRY_WAIT_MS
                Notify("Lobby Play is still visible " Round(QUEUE_LOBBY_CHECK_MS/1000) " seconds after Submit. Waiting another " Round(QUEUE_LOBBY_RETRY_WAIT_MS/1000) " seconds before retrying.")
            }
        }
        if !ActionPause(QUEUE_WAIT_POLL_MS,false)
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
        if number {
            number := 0
            break
        }
        number := point
    }
    sx := REF_W/geometry.cw,sy := REF_H/geometry.ch
    return {number:number?number.number:"",inputX:centre*sx,inputY:number?(number.y+submit.y)/2*sy:0,
        submit:{x:submit.x*sx,y:submit.y*sy},cancel:{x:cancel.x*sx,y:cancel.y*sy}}
}

QueuePromptVisible(prompt) {
    left := prompt.submit,right := prompt.cancel
    frame := RefPixels(left.x-13,Min(left.y,right.y)-7,right.x+13,Max(left.y,right.y)+7)
    return frame.valid && UnitPanelColourHits(frame,left.x-13,left.y-7,left.x+13,left.y+7,IsUiGreen)>=4
        && UnitPanelColourHits(frame,right.x-13,right.y-7,right.x+13,right.y+7,IsUiRed)>=4
}

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true, gPlacements := [], actions := [], preview := 1, clickResult := "placed", focused := true, remembered := false
global panelWords := [], discoveries := 0, injectAfterMove := false, injectOnClick := false, clearedCards := 0, moveCount := 0
global worldFrame := SavedFrame(A_ScriptDir "\placement-world.frame"), cardFrame := SavedFrame(A_ScriptDir "\placement-cards.frame")
global testFrame := SavedFrame(A_ScriptDir "\placement-world.frame")
try {
    unit := {slot:1,name:"Test",priority:1,target:0}, candidate := {x:440,y:310}
    Assert(!HasCardChoice(testFrame), "Illuminated world path detected as cards")
    Assert(TryPlacementCandidate(unit,candidate), "World view prevented placement")
    Assert(actions.Length>=3 && actions[1]="activate" && actions[2]="{1}" && actions[3]="click", "Slot selection/click did not follow game focus")
    Assert(gPlacements.Length=1 && remembered, "Confirmed purchase was not recorded")
    gPlacements := [], actions := [], focused := false, remembered := false
    Assert(!TryPlacementCandidate(unit,candidate) && actions.Length=1 && !remembered, "Unit key sent without game focus")
    focused := true, preview := 0, actions := []
    Assert(!TryPlacementCandidate(unit,candidate) && !HasAction("click") && gPlacements.Length=0, "No-preview candidate clicked or recorded")
    preview := 1, clickResult := "unconfirmed", actions := []
    Assert(!TryPlacementCandidate(unit,candidate) && !gRunning && gPlacements.Length=0 && !remembered, "Unconfirmed purchase recorded as successful")
    gRunning := true, clickResult := "placed", testFrame := worldFrame, preview := 1, remembered := false
    gPlacements := [], actions := [], injectAfterMove := true, moveCount := 0, clearedCards := 0
    Assert(TryPlacementCandidate(unit,candidate), "Placement did not resume after cards opened during preview")
    Assert(clearedCards=1 && gPlacements.Length=1 && actions[2]="{1}" && actions[3]="{1}" && actions[4]="click", "Interrupted preview was not reselected exactly once")
    gPlacements := [], actions := [], injectAfterMove := false, injectOnClick := true, clearedCards := 0
    Assert(TryPlacementCandidate(unit,candidate), "Placement did not resume after cards interrupted a click")
    Assert(clearedCards=1 && gPlacements.Length=1 && actions.Length=5, "Interrupted click produced an extra recorded purchase")
    gRunning := true, panelWords := [{text:"Goblin"},{text:"DEFEAT"},{text:"Next"}]
    Assert(!HasUnitPanel() && discoveries=0, "Red enemies/end screen mistaken for unit panel or learned as its X")
    panelWords := [{text:"Upgrade [0]"},{text:"Sell 200"}]
    Assert(HasUnitPanel() && discoveries=1, "Actual unit controls not accepted")
    FileAppend "PASS: interruption during preview/click resumes and records one purchase; world view reaches selection/click; focus precedes slot key; missing preview is skipped; unconfirmed purchase is not saved; enemies are not unit panels; real unit controls accepted.`n", "*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n", "*"
    ExitApp 1
}
Assert(value,msg) {
    if !value
        throw Error(msg)
}
HasAction(wanted) {
    global actions
    for action in actions
        if action=wanted
            return true
    return false
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
RefPixels(*) {
    global testFrame
    return testFrame
}
FindRoblox() => 1
WinActivate(*) {
    global actions
    actions.Push("activate")
}
WinWaitActive(*) {
    global focused
    return focused
}
ClearCardChoice() {
    global testFrame, worldFrame, clearedCards
    if HasCardChoice() {
        clearedCards += 1
        testFrame := worldFrame
    }
    return true
}
Send(keys) {
    global actions
    actions.Push(keys)
}
ActionPause(*) => true
MoveRef(*) {
    global injectAfterMove, moveCount, testFrame, cardFrame
    moveCount += 1
    if injectAfterMove && moveCount=1
        testFrame := cardFrame
    return true
}
BubbleState(*) {
    global preview
    return preview
}
ClickPlacement(*) {
    global actions,clickResult,injectOnClick,testFrame,cardFrame
    actions.Push("click")
    if injectOnClick {
        injectOnClick := false, testFrame := cardFrame
        return "cards"
    }
    return clickResult
}
RememberPlacement(unit,candidate,success) {
    global remembered
    remembered := success
}
CloseUnitPanel() => 0
Log(*) => 0
Notify(*) => 0
HasSavedRedControl(*) => true
CountRef(*) => 20
ReadOcrRows(*) {
    global panelWords
    return panelWords
}
WindowGeometry() => {w:1415,h:1121}
DiscoverButton(*) {
    global discoveries
    discoveries += 1
}

TryPlacementCandidate(unit, candidate) {
    global gRunning, gPlacements
    hwnd := FindRoblox()
    if !hwnd
        return false
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd,,2)
        return false
    ; A second pass happens only when a card choice interrupted the first.
    Loop 2 {
        if !gRunning || !ClearCardChoice()
            return false
        if !CancelUnitPreview()
            return false
        baseline := CapturePlacementArea(candidate.x,candidate.y)
        Send "{" unit.slot "}"
        if !ActionPause(150)
            return false
        if !MoveRef(candidate.x,candidate.y)
            return false
        if !ActionPause(180)
            return false
        ; Red cards would otherwise read as a red (invalid) bubble.
        if HasCardChoice()
            continue
        bubble := BubbleState(candidate.x,candidate.y,baseline)
        Log("Slot " unit.slot " at " candidate.x "," candidate.y ": " (bubble=1?"blue preview":bubble=-1?"red preview":"no placement preview"))
        if bubble != 1 {
            if bubble = -1
                RememberPlacement(unit,candidate,false)
            ; Close the preview so the next slot key opens a fresh one
            ; instead of toggling this one off.
            Send "q"
            ActionPause(120)
            return false
        }
        result := ClickPlacement(candidate,baseline)
        if result = "cards"
            continue
        if result = "failed" {
            Log(unit.name ": blue preview stayed after three clicks; spot skipped.")
            Send "q"
            ActionPause(120)
            return false
        }
        if result = "unconfirmed" {
            Notify("Placement could not be verified. Stopped to avoid recording or buying extra units.")
            gRunning := false
            return false
        }
        if result != "placed"
            return false
        gPlacements.Push({slot:unit.slot,name:unit.name,priority:unit.priority,target:unit.target,upgrades:0,x:candidate.x,y:candidate.y,complete:unit.target=0})
        RememberPlacement(unit,candidate,true)
        Log("Confirmed " unit.name " placement; saved to matching map/view profile.")
        CloseUnitPanel()
        return gRunning
    }
    return false
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

HasUnitPanel() {
    ; Enemy health bars and card frames are red too. A red patch alone
    ; cannot confirm a purchase; require actual unit-panel controls.
    if !HasSavedRedControl("UnitPanelClose") && CountRef(245,175,305,255,4,IsUiRed)<=8
        return false
    for row in ReadOcrRows(0,130,330,500) {
        if RegExMatch(NormalizeWords(row.text),"\b(upgrade|upg|sell)\b") {
            geometry := WindowGeometry()
            if geometry
                DiscoverButton("UnitPanelClose",geometry)
            return true
        }
    }
    return false
}

RGB(color, &r, &g, &b) {
    r := (color >> 16) & 0xFF
    g := (color >> 8) & 0xFF
    b := color & 0xFF
}

NormalizeWords(text) {
    return Trim(RegExReplace(StrLower(text), "[^a-z0-9%+.-]+", " "))
}

CancelUnitPreview() => true
CapturePlacementArea(*) {
    global testFrame
    return testFrame
}

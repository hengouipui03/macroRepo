#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0,REF_W := 800,REF_H := 600
global greenSpeedOffer := false
global testNow := 10000,visible := true,clicks := [],rankCalls := 0,readCalls := 0,falseFrames := 0,closeOn := 3,nextBest := 1,vanishOnMove := false
ResetCardSelection() {
    global gCardSelection,gCardRetryAt,gCardUnread
    gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
}

WaitForCardChoiceClosed() {
    global gRunning
    closedAt := 0,deadline := testNow+1400
    while gRunning && testNow<deadline {
        if HasCardChoice()
            closedAt := 0
        else if !closedAt
            closedAt := testNow
        else if testNow-closedAt>=350
            return true
        if !ActionPause(70)
            return false
    }
    return false
}

ConfirmLockedCardSelection() {
    global gCardSelection,gCardRetryAt,gRunning
    if !gRunning || !gCardSelection
        return false
    if !HasCardChoice()
        return false
    if testNow<gCardRetryAt {
        ActionPause(100)
        return true
    }
    choice := gCardSelection
    if CardIsSpeed(choice) {
        Log("Blocked forbidden positive Speed selection.")
        ResetCardSelection()
        return true
    }
    rect := CardRectangle(choice.index)
    Log("Keep card " choice.index ": " choice.kind " / " choice.stat "; awaiting confirmation.")
    ; Recheck after moving: a closing dialog must not receive another click.
    if !ClickRef((rect[1]+rect[3])//2,330,HasCardChoice)
        return true
    gCardRetryAt := testNow+1000
    if WaitForCardChoiceClosed() {
        ApplySelectedCardModifiers(choice)
        Notify("Selected " choice.kind ": " choice.stat)
        ResetCardSelection()
    }
    return true
}

TryChooseCard() {
    global gCardRetryAt, gCardUnread, gCardSelection, gRunning, REF_W, REF_H
    if !HasCardChoice()
        return false
    if gCardSelection
        return ConfirmLockedCardSelection()
    if testNow < gCardRetryAt {
        ActionPause(100)
        return true
    }
    geometry := WindowGeometry()
    if !geometry
        return false
    words := ReadOcrRows(125,175,690,445,true)
    frame := RefPixels(120,175,690,445)
    cards := ReadWordColourCards(words,frame,geometry)
    for index,card in cards
        if card.stat!="unknown" && card.kind!="unknown" && !CardIsSpeed(card)
            RememberCard(CardVisual(index),card)
    best := ChooseBestCard(cards)
    if !best {
        ; Never block the run on unreadable text: after a few OCR retries,
        ; take a green card, otherwise a non-Speed alternative.
        gCardUnread += 1
        if gCardUnread < 3 {
            Log("Card text unclear; retrying OCR (" gCardUnread "/3).")
            gCardRetryAt := testNow + 1500
            return true
        }
        best := FallbackCardChoice(cards)
        if !best {
            Log("No readable safe card. Positive Speed is forbidden; waiting for clearer effect text.")
            gCardRetryAt := testNow+1500
            return true
        }
        Log("Card text partly unclear; choose safe card " best ".")
    }
    gCardUnread := 0
    LogCardDecision(cards,best)
    gCardSelection := cards[best].Clone()
    gCardSelection.index := best
    return ConfirmLockedCardSelection()
}

try {
    Assert(TryChooseCard() && gCardSelection.index=1,"First choice not locked")
    nextBest := 2
    falseFrames := 1
    TryChooseCard()
    Assert(gCardSelection.index=1 && rankCalls=1,"Transient frame or changed ranking switched the selected card")
    TryChooseCard()
    TryChooseCard()
    Assert(clicks.Length=3 && !gCardSelection && rankCalls=1,"Selection did not reset after stable dialog closure")
    for point in clicks
        Assert(point.x=217,"Cooldown retry clicked Yen instead")
    visible := true,closeOn := 4
    TryChooseCard()
    Assert(clicks.Length=4 && clicks[4].x=405 && rankCalls=2,"A new choice did not get a new decision")
    visible := true,closeOn := 99,vanishOnMove := true
    nextBest := 1
    TryChooseCard()
    Assert(clicks.Length=4,"Card closing during cursor movement received a stray click")
    ResetCardSelection()
    visible := true,vanishOnMove := false,greenSpeedOffer := true,nextBest := 2
    beforeGreen := clicks.Length,closeOn := beforeGreen+1
    Assert(TryChooseCard() && clicks.Length=beforeGreen+1 && clicks[clicks.Length].x=405 && !gCardSelection,"Green Speed-reduction selection was rejected at final confirmation when OCR lost minus")
    FileAppend "PASS: original card locked across delayed confirmation and flicker; no reranking to Yen; new dialog unlocks; closing dialog click guarded.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
HasCardChoice(*) {
    global visible,falseFrames
    if falseFrames>0 {
        falseFrames -= 1
        return false
    }
    return visible
}
ActionPause(ms) {
    global testNow
    testNow += ms
    return true
}
CardRectangle(index) => [[125,175,310,445],[310,175,500,445],[500,175,690,445]][index]
CardColourKind(*) => "buff"
CardVisual(index) => index
ReadCardMemory(index) {
    global readCalls
    readCalls += 1
    return {kind:"buff",stat:index=1?"cooldown":index=2?"yen":"range",rank:index,amount:20,text:index=1?"Cooldown I":index=2?"Yen I":"Range I"}
}
ChooseBestCard(*) {
    global rankCalls,nextBest
    rankCalls += 1
    return nextBest
}
ClickRef(x,y,stillValid := 0) {
    global clicks,visible,closeOn,vanishOnMove
    if vanishOnMove
        visible := false
    Assert(IsObject(stillValid),"Card click lacked a last-moment visibility guard")
    if !stillValid.Call()
        return false
    clicks.Push({x:x,y:y})
    if clicks.Length>=closeOn
        visible := false
    return true
}
Notify(*) => 0
Log(*) => 0
ReadOcrRows(*) => []
WindowGeometry(*) => {cw:800,ch:600}
NormalizeWords(text) => text
CardRank(*) => 1
CardPolicyFromLines(*) => false
RememberCard(*) => 0

FallbackCardChoice(cards) => ChooseBestCard(cards)

CardPolicy(text,*) => {kind:"buff",stat:InStr(text,"Cooldown")?"cooldown":InStr(text,"Yen")?"yen":"range",rank:1,amount:20,text:text,tier:1}

class RefPixels {
    valid := true
    __New(*) {
    }
}
ReadWordColourCards(*) {
    global greenSpeedOffer
    if greenSpeedOffer
        return [{kind:"debuff",stat:"cooldown",effectInk:"debuff",amount:15,tier:1,text:"Cooldown +15%"},
            {kind:"buff",stat:"speed",effectInk:"buff",amount:20,tier:1,text:"20% Enemy Speed",enemyReduction:false,forbiddenSpeed:true},
            {kind:"debuff",stat:"health",effectInk:"debuff",amount:50,tier:1,text:"Enemy Health +50%"}]
    return [{kind:"buff",stat:"cooldown",amount:20,tier:1,text:"Cooldown I"},
        {kind:"buff",stat:"yen",amount:20,tier:1,text:"Yen I"},
        {kind:"buff",stat:"range",amount:20,tier:1,text:"Range I"}]
}
LogCardDecision(*) => 0
ApplySelectedCardModifiers(*) => 0
CardHasGreenEffect(card) {
    return card.HasProp("effectInk") && card.effectInk="buff"
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


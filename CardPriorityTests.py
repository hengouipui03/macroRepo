"""Actual card ranking and confirmation, with simulated OCR and clicks only."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = '\n'.join(function('Learning.ahk', name) for name in [
    'CardRank', 'CardHasGreenEffect', 'CardSelectionView', 'CardIsSpeed',
    'CardPreferenceScore', 'DebuffOutlook', 'DebuffBetter', 'CardBetter',
    'ChooseBestCard', 'PreferVerifiedGreenChoice', 'FallbackCardChoice',
    'DebuffSize', 'CardBeatsBuffs', 'LateDebuffClass', 'LateSharedResistOpen',
    'DebuffBetterLate', 'DebuffBetterEasy'])
logic += '\n' + function('CardContext.ahk', 'MatchModifier')
logic += '\n' + function('CardContext.ahk', 'CardLateMedium')
logic += '\n' + function('CardContext.ahk', 'ParseWaveNumber')
logic += '\n' + function('Learning.ahk', 'NormalizeWords')
logic += '\n' + function('CardContext.ahk', 'PixelInkCards')
logic += '\n' + '\n'.join(function('AAPathMacro.ahk', name) for name in [
    'ConfirmLockedCardSelection', 'ResetCardSelection'])
fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
global gMatchModifiers := {healthKnown:false},freshCards := [],clicked := [],ocrReads := 0
global CARD_HEALTH_CAP := 300,CARD_RESIST_CAP := 150,CARD_REGEN_CAP := 2,CARD_UNKNOWN_HEALTH := 200,CARD_UNKNOWN_RESIST := 100
global gCardDifficulty := "easy",gMatchWave := 0,MEDIUM_LATE_WAVE := 30
try {
    unknown := Card("unknown","buff"),speed := Card("speed","buff")
    yen := Card("yen","buff"),boss := Card("boss damage","buff")
    red := Card("shield","debuff"),redSpeed := Card("speed","debuff")
    attack := Card("attack","buff"),rangeBuff := Card("range","buff")
    for preferred in [unknown,speed,attack,rangeBuff] {
        for offer in [[preferred,yen,boss],[preferred,boss,yen],[yen,preferred,boss],
                      [boss,preferred,yen],[yen,boss,preferred],[boss,yen,preferred]] {
            best := ChooseBestCard(offer)
            Assert(offer[best]=preferred,"Yen/Boss beat another verified green buff")
            Assert(FallbackCardChoice(offer)=best,"fallback ignored buff hierarchy")
        }
        for offer in [[red,preferred,redSpeed],[preferred,red,redSpeed],[redSpeed,red,preferred]]
            Assert(offer[ChooseBestCard(offer)]=preferred,"red beat green")
    }
    Assert(ChooseBestCard([boss,yen])=2,"Boss was not last")
    ; Buff order: Double Attack > higher tier > Attack/Cooldown/Range >
    ; Random Blessings > any other green > Yen > Boss Damage.
    order := [Tier("double attack",1),Tier("attack",2),Tier("cooldown",2),Tier("range",2),
        Tier("attack",1),Tier("cooldown",1),Tier("range",1),Tier("random blessings",2),
        Tier("random blessings",1),unknown,Tier("yen",2),Tier("yen",1),Tier("boss damage",2),Tier("boss damage",1)]
    for i,better in order
        for j,worse in order
            if i<j {
                Assert(ChooseBestCard([worse,better])=2 && ChooseBestCard([better,worse])=1,
                    "buff order: " better.stat " " better.tier " should beat " worse.stat " " worse.tier)
                Assert(ChooseBestCard([worse,better,yen])=2 || better.stat="yen" || worse.stat="yen" || better.stat="boss damage" || worse.stat="boss damage","three-card order failed")
            }
    Assert(ChooseBestCard([Tier("range",3),Tier("attack",2),Tier("double attack",1)])=3,"Double Attack lost to a higher tier")
    blankGreen := Card("unknown","buff"),blankRed := Card("unknown","debuff")
    Assert(ChooseBestCard([blankGreen,blankGreen,blankGreen])=2,"three unreadable green cards: middle not chosen")
    Assert(ChooseBestCard([blankRed,blankRed,blankRed])=2,"three unreadable red cards: middle not chosen")
    Assert(ChooseBestCard([blankRed,blankRed,red])=3,"mixed red cards wrongly took the middle")
    Assert(!ChooseBestCard([redSpeed,redSpeed,redSpeed]),"harmful Speed was selected")
    ; Re-clicks never re-run OCR; one clearly green card (pixels) still takes
    ; over a locked red choice, but a locked green choice is kept.
    for preferred in [unknown,speed] {
        freshCards := [red,preferred,redSpeed]
        gCardSelection := red.Clone(),gCardSelection.index := 1,gCardRetryAt := 0
        ConfirmLockedCardSelection()
        Assert(clicked[clicked.Length]=2,"a green card did not take over a locked red choice")
    }
    for old in [yen,boss] {
        freshCards := [old,unknown,redSpeed]
        gCardSelection := old.Clone(),gCardSelection.index := 1,gCardRetryAt := 0
        ConfirmLockedCardSelection()
        Assert(clicked[clicked.Length]=1,"a re-click re-ranked two green cards")
    }
    freshCards := [rangeBuff,attack,yen]
    gCardSelection := rangeBuff.Clone(),gCardSelection.index := 1,gCardRetryAt := 0
    ConfirmLockedCardSelection()
    Assert(clicked[clicked.Length]=1,"ordinary green lock changed unnecessarily")
    Assert(ocrReads=0,"a re-click ran OCR")

    ; Medium difficulty (wave 30+).
    Assert(ParseWaveNumber([{text:"+447"},{text:"Wave 49"}])=49 && !ParseWaveNumber([{text:"Stone Golem"}]),"Wave label misread")
    shield10 := Red("shield",10),shield3 := Red("shield",3),boom12 := Red("explosive death",12)
    health50 := Red("health",50),health200 := Red("health",200),health80 := Red("health",80)
    shared100 := Resist(100,100),phys300 := Resist(300,0),regen := Red("0.5 regen",0.5)
    gMatchModifiers := {health:50,healthKnown:true,physical:0,magical:0,regen:0}
    Assert(ChooseBestCard([attack,shield10])=1,"Easy: a Tier II Shield beat a buff")
    gCardDifficulty := "medium",gMatchWave := 29
    Assert(ChooseBestCard([attack,shield10])=1 && ChooseBestCard([health50,health200])=1,"Medium before wave 30 did not play like Easy")
    gMatchWave := 30
    Assert(ChooseBestCard([attack,shield10])=2 && ChooseBestCard([Tier("double attack",1),boom12])=2,"Tier II Shield / Explosive Death did not beat buffs")
    Assert(ChooseBestCard([attack,shield3])=1,"a Tier I Shield beat a buff")
    Assert(ChooseBestCard([Red("shield",6),shield10,attack])=2,"of two Tier II cards the bigger did not win")
    Assert(ChooseBestCard([health50,health200,health80])=2,"within the cap the biggest card did not win")
    Assert(ChooseBestCard([shield3,health200])=2,"Tier II Health within its cap lost to a Tier I Shield")
    gMatchModifiers.health := 150
    Assert(ChooseBestCard([health200,health50])=2,"a card past its cap beat one within it")
    gMatchModifiers := {health:300,healthKnown:true,physical:100,magical:100,regen:0}
    Assert(ChooseBestCard([health200,phys300,shared100])=3,"caps reached: shared resist was not taken while both resists are under 150")
    Assert(ChooseBestCard([regen,health200,health80])=3,"caps reached: regen or the bigger card was taken over the smallest")
    gMatchModifiers.physical := 150,gMatchModifiers.magical := 150
    Assert(ChooseBestCard([shared100,health80])=2,"resists capped: the smallest card was not taken")
    Assert(ChooseBestCard([regen,redSpeed])=1 && !ChooseBestCard([redSpeed,redSpeed]),"regen was not the last resort, or Speed was taken")
    Assert(ChooseBestCard([attack,health200])=1,"Medium: a buff lost to a non-Shield red card")
    gCardDifficulty := "easy",gMatchWave := 0,gMatchModifiers := {healthKnown:false}
    FileAppend "PASS: Double Attack > tier > Attack/Cooldown/Range > Random Blessings > other green > Yen > Boss; three unreadable same-colour cards take the middle; green/unknown/Speed before Yen and Boss in every position; green over red; re-clicks use pixels only (green over a locked red), no OCR; harmful Speed blocked; Medium wave 30+: Tier II Shield/Explosive Death over buffs, biggest within cap, capped -> shared resist then smallest, regen last.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Card(stat,ink) => {kind:ink,stat:stat,effectInk:ink,amount:20,tier:1,rank:CardRank(ink,stat)}
Tier(stat,tier) => {kind:"buff",stat:stat,effectInk:"buff",amount:20,tier:tier,rank:CardRank("buff",stat)}
Red(stat,amount) => {kind:"debuff",stat:stat,effectInk:"debuff",amount:amount,amountKnown:true,tier:1,rank:CardRank("debuff",stat)}
Resist(physical,magical) {
    stat := physical&&magical?"physical and magical resist":physical?"physical resist":"magical resist"
    card := Red(stat,Max(physical,magical))
    card.resistance := {physical:physical,magical:magical,physicalRead:true,magicalRead:true}
    return card
}
Assert(value,message) {
    if !value
        throw Error(message)
}
CardIsResistance(card) => card.stat="physical resist" || card.stat="magical resist" || card.stat="physical and magical resist"
CardIsRegen(card) => card.stat="regen" || card.stat="0.5 regen"
ResistancePreferred(*) => false
WindowGeometry(*) => true
ReadOcrRows(*) => []
RefPixels(*) => true
ReadWordColourCards(*) {
    global ocrReads
    ocrReads += 1
    return freshCards
}
PixelGreenCards(*) {
    green := []
    for index,card in freshCards
        if card.effectInk="buff"
            green.Push(index)
    return green
}
HasCardChoice(*) => true
HasUnitPanel(*) => false
CardRectangle(*) => [100,100,200,400]
WaitForCardChoiceClosed(*) => false
ApplySelectedCardModifiers(*) => 0
Notify(*) => 0
Log(*) => 0
ActionPause(*) => true
ClickRef(*) {
    clicked.Push(gCardSelection.index)
    return true
}
'''

if __name__ == '__main__':
    target = ROOT / 'cache' / 'card-priority-regression.ahk'
    target.parent.mkdir(exist_ok=True)
    target.write_text(fixture + '\n' + logic, encoding='utf-8-sig')
    result = subprocess.run([str(RUNTIME), '/ErrorStdOut=UTF-8', str(target)],
                            capture_output=True, timeout=30)
    print(result.stdout.decode('utf-8-sig'), end='')
    print(result.stderr.decode('utf-8-sig'), end='')
    raise SystemExit(result.returncode)

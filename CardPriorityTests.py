"""Actual card ranking and confirmation, with simulated OCR and clicks only."""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = '\n'.join(function('Learning.ahk', name) for name in [
    'CardRank', 'CardHasGreenEffect', 'CardSelectionView', 'CardIsSpeed',
    'CardPreferenceScore', 'DebuffOutlook', 'DebuffBetter', 'CardBetter',
    'ChooseBestCard', 'PreferVerifiedGreenChoice', 'FallbackCardChoice'])
logic += '\n' + function('CardContext.ahk', 'MatchModifier')
logic += '\n' + '\n'.join(function('AAPathMacro.ahk', name) for name in [
    'ConfirmLockedCardSelection', 'ResetCardSelection'])
fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gCardSelection := 0,gCardRetryAt := 0,gCardUnread := 0
global gMatchModifiers := {healthKnown:false},freshCards := [],clicked := []
global CARD_HEALTH_CAP := 300,CARD_RESIST_CAP := 150,CARD_REGEN_CAP := 2,CARD_UNKNOWN_HEALTH := 200,CARD_UNKNOWN_RESIST := 100
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
    for old in [red,yen,boss] {
        for preferred in [unknown,speed] {
            freshCards := [old,preferred,redSpeed]
            gCardSelection := old.Clone(),gCardSelection.index := 1,gCardRetryAt := 0
            ConfirmLockedCardSelection()
            Assert(clicked[clicked.Length]=2,"locked choice ignored fresh green priority")
        }
    }
    freshCards := [rangeBuff,attack,yen]
    gCardSelection := rangeBuff.Clone(),gCardSelection.index := 1,gCardRetryAt := 0
    ConfirmLockedCardSelection()
    Assert(clicked[clicked.Length]=1,"ordinary green lock changed unnecessarily")
    freshCards := [redSpeed,red,redSpeed]
    gCardSelection := rangeBuff.Clone(),gCardSelection.index := 1,gCardRetryAt := 0
    count := clicked.Length
    ConfirmLockedCardSelection()
    Assert(clicked.Length=count && !gCardSelection,"stale safe lock clicked harmful Speed")
    FileAppend "PASS: Double Attack > tier > Attack/Cooldown/Range > Random Blessings > other green > Yen > Boss; three unreadable same-colour cards take the middle; green/unknown/Speed before Yen and Boss in every position; green over red; locked-choice revalidation; harmful Speed blocked.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Card(stat,ink) => {kind:ink,stat:stat,effectInk:ink,amount:20,tier:1,rank:CardRank(ink,stat)}
Tier(stat,tier) => {kind:"buff",stat:stat,effectInk:"buff",amount:20,tier:tier,rank:CardRank("buff",stat)}
Assert(value,message) {
    if !value
        throw Error(message)
}
CardIsResistance(*) => false
CardIsRegen(*) => false
ResistancePreferred(*) => false
WindowGeometry(*) => true
ReadOcrRows(*) => []
RefPixels(*) => true
ReadWordColourCards(*) => freshCards
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

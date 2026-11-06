RunLearningTests() {
    global LEARNING_FILE, gCardMemory, gPlacementProfile, gButtonMemory, BUTTONS_FILE
    global gResistancePreference,gMatchModifiers
    count := 0
    AssertLearning(condition, message) {
        if !condition
            throw Error(message)
    }
    buffs := ["attack", "cooldown", "range"]
    debuffs := ["shield","explosive death","health","physical and magical resist","physical resist","magical resist","0.5 regen","speed"]
    for index, stat in buffs {
        card := CardPolicy("Buff " stat " +20%")
        AssertLearning(card.kind="buff" && card.stat=stat && card.rank=index,"Buff priority misread: " stat)
        count += 1
    }
    for index, stat in debuffs {
        card := CardPolicy("Enemy " stat " +20%")
        AssertLearning(card.kind="debuff" && card.stat=stat && card.rank=index,"Debuff priority misread: " stat)
        count += 1
    }
    for left, stat in buffs {
        for right, other in buffs {
            if right <= left
                continue
            AssertLearning(ChooseBestCard([CardPolicy("Buff " other),CardPolicy("Buff " stat)])=2,"Buff pair order failed")
            count += 1
        }
    }
    for left, stat in debuffs {
        for right, other in debuffs {
            if right <= left
                continue
            AssertLearning(ChooseBestCard([CardPolicy("Enemy " other),CardPolicy("Enemy " stat)])=2,"Debuff pair order failed")
            count += 1
        }
    }
    AssertLearning(ChooseBestCard([CardPolicy("Enemy shield"),CardPolicy("Buff yen"),CardPolicy("Enemy speed")])=2,"Buff must always beat a debuff")
    count += 1
    AssertLearning(CardPolicy("Attack -20%").kind="debuff","Attack reduction incorrectly classified as a buff")
    count += 1
    AssertLearning(CardPolicy("Cooldown -15%").kind="buff","Cooldown reduction incorrectly classified")
    count += 1
    AssertLearning(CardPolicy("Cooldown +15%").kind="debuff","Cooldown increase incorrectly classified")
    count += 1
    AssertLearning(CardPolicy("Enemy Physical AND Magical Resist +30%").rank=5,"Combined resistance must not be physical-only")
    count += 1
    AssertLearning(ChooseBestCard([CardPolicy("unknown unreadable"),CardPolicy("Enemy shield")])=0,"Unknown card must not be discarded as a possible buff")
    count += 1
    AssertLearning(ChooseBestCard([CardPolicy("unknown unreadable"),CardPolicy("Buff range")])=2,"Known buff should be chosen over an unreadable card")
    count += 1
    ; The supplied red-card screenshot, after its shared "+30% SummerPearls"
    ; line is removed: health outranks magic resist and physical AND magic.
    red := [CardPolicy("+ Enemy Health I +50% Enemy Health",false,"debuff"),CardPolicy("+ Resistant Enemies I +50 Enemy Physical Resist +50 Enemy Magic Resist",false,"debuff"),CardPolicy("+ Spellproof Enemies I +75 Enemy Magic Resist",false,"debuff")]
    AssertLearning(red[1].stat="health" && red[2].stat="physical and magical resist" && red[3].stat="magical resist","Screenshot cards misread")
    count += 1
    AssertLearning(ChooseBestCard(red)=1,"Enemy Health should be chosen from the screenshot cards")
    count += 1
    AssertLearning(red[3].amount=75,"Flat card amount not read")
    count += 1
    ; Green always wins, even when its stat could not be read.
    AssertLearning(ChooseBestCard([CardPolicy("Enemy shield",false,"debuff"),CardPolicy("unreadable",true,"buff")])=2,"Green card must beat a red card")
    count += 1
    AssertLearning(CardPolicy("+10% Unit Attack enemies",true,"buff").kind="buff","Card colour must decide buff or debuff")
    count += 1
    secretShield := CardPolicy("Enemy Shield +3 +30% Secret Portal Drop Rate",false,"debuff")
    secretDeath := CardPolicy("Explosive Death +30% Secret Portal Rate",false,"debuff")
    secretHealth := CardPolicy("Enemy Health +150% +30% Secret Portal Rate",false,"debuff")
    normalHealth := CardPolicy("Enemy Health +50%",false,"debuff")
    normalResist := CardPolicy("Enemy Physical Resist +50",false,"debuff")
    attackBuff := CardPolicy("Buff Attack +20%",true,"buff")
    AssertLearning(secretShield.secretPortal && secretDeath.secretPortal && secretDeath.stat="explosive death","Secret rate or explosive death was not recognized")
    AssertLearning(ChooseBestCard([attackBuff,secretShield,secretHealth])=1,"Secret-rate Shield overrode a green buff")
    AssertLearning(ChooseBestCard([attackBuff,secretHealth,secretDeath])=1,"Secret-rate Explosive Death overrode a green buff")
    AssertLearning(ChooseBestCard([secretHealth,attackBuff,normalHealth])=2,"Other secret-rate debuffs must not override buffs")
    AssertLearning(ChooseBestCard([secretShield,normalHealth,normalResist])=2,"Two easier ordinary debuffs must beat the harder secret-rate option")
    AssertLearning(ChooseBestCard([secretShield,secretDeath,secretHealth])=1,"All-secret choices changed the existing debuff order")
    sharedLines := [["enemy shield","+3 enemy shield","+30% secret portal drop rate","+30% summerpearls"],["enemy health","+50% enemy health","+30% summerpearls"],["physical resist","+50 enemy physical resist","+30% summerpearls"]]
    fromLines := CardPolicyFromLines(sharedLines[1],sharedLines,1,"debuff")
    AssertLearning(fromLines.secretPortal && fromLines.stat="shield" && fromLines.amount=3,"Secret reward was stripped or mistaken for the debuff amount")
    merged := [["+30% secret portal drop rate enemy shield +3"],["buff attack +20%"],["enemy health +50%"]]
    mergedCard := CardPolicyFromLines(merged[1],merged,1,"debuff")
    AssertLearning(mergedCard.secretPortal && mergedCard.stat="shield" && mergedCard.amount=3,"Merged reward/effect OCR lost the Shield or read the reward amount")
    count += 8
    regen := CardPolicy("Enemy Health Regen +0.5",false,"debuff")
    AssertLearning(regen.stat="0.5 regen" && regen.amount=0.5,"0.5 regen was misread as health")
    AssertLearning(ChooseBestCard([CardPolicy("Enemy Magical Resist +50",false,"debuff"),regen])=1,"Resistance within its cap must beat 0.5 regen")
    AssertLearning(ChooseBestCard([regen,CardPolicy("Enemy Health +50%",false,"debuff")])=2,"Regen changed the higher debuff priorities")
    AssertLearning(CardPolicy("Enemy Regen +5",false,"debuff").rank>CardPolicy("Enemy Magical Resist +50",false,"debuff").rank,"Larger regen was incorrectly given the 0.5 preference")
    count += 4
    attackI := CardPolicy("Attack I +20% Unit Attack",true,"buff")
    cooldownII := CardPolicy("Cooldown II -15% Unit Attack Speed",true,"buff")
    rangeIII := CardPolicy("Range III +10% Range",true,"buff")
    double := CardPolicy("Double Attack units attack two times",true,"buff")
    unreadableGreen := CardPolicy("unreadable",true,"buff")
    unreadable := CardPolicy("unreadable")
    speed := CardPolicy("Enemy Speed III +10%",false,"debuff")
    AssertLearning(attackI.tier=1 && cooldownII.tier=2 && rangeIII.tier=3,"Roman title tiers not parsed")
    AssertLearning(cooldownII.stat="cooldown","Buff title lost to body text")
    AssertLearning(ChooseBestCard([attackI,cooldownII])=2,"Tier did not beat stat: Attack I beat Cooldown II")
    AssertLearning(ChooseBestCard([cooldownII,rangeIII,attackI])=2,"Highest tier lost to a lower-tier Attack/Cooldown")
    AssertLearning(ChooseBestCard([CardPolicy("Buff yen +20%"),CardPolicy("Buff range +20%")])=2,"Yen beat Range")
    AssertLearning(ChooseBestCard([CardPolicy("Range II",true,"buff"),CardPolicy("Attack II",true,"buff")])=2,"Same-tier original buff order changed")
    AssertLearning(double.stat="double attack" && double.kind="buff","Double Attack was not recognized")
    AssertLearning(ChooseBestCard([rangeIII,double,CardPolicy("Attack X +500%",true,"buff")])=2,"Double Attack did not beat all other buffs")
    AssertLearning(BuffTitleTier("Attack ll")=2 && BuffTitleTier("Range IV")=4 && BuffTitleTier("Cooldown 2")=2,"OCR/numeric title tiers failed")
    rangeI := CardPolicy("Range I +10% Unit Range",true,"buff")
    cooldownI := CardPolicy("Cooldown I -10% Unit Cooldown",true,"buff")
    rangeII := CardPolicy("Range II +20% Unit Range",true,"buff")
    AssertLearning(ChooseBestCard([cooldownI,rangeI])=1 && ChooseBestCard([rangeI,cooldownI])=2,"Cooldown did not beat equal-tier Range")
    AssertLearning(ChooseBestCard([cooldownII,rangeII])=1,"Cooldown II did not beat Range II")
    AssertLearning(ChooseBestCard([rangeI,cooldownII])=2,"Cooldown II did not beat Range I")
    AssertLearning(ChooseBestCard([cooldownI,rangeII])=2 && ChooseBestCard([rangeII,cooldownI])=1,"Range II must beat Cooldown I in either position")
    AssertLearning(ChooseBestCard([attackI,rangeII])=2 && ChooseBestCard([rangeII,attackI])=1,"Range II must beat Attack I (tier beats stat)")
    for tier in [1,2,3,4,5,6,7,8,9] {
        lower := CardPolicy("Attack " tier " +50% Unit Attack",true,"buff")
        higher := CardPolicy("Range " (tier+1) " +10% Unit Range",true,"buff")
        same := CardPolicy("Cooldown " tier " -50% Unit Cooldown",true,"buff")
        AssertLearning(ChooseBestCard([lower,higher])=2 && FallbackCardChoice([lower,higher])=2,"A lower tier beat a higher tier")
        AssertLearning(ChooseBestCard([same,lower])=2,"Same-tier Attack lost to Cooldown")
        lower.effectInk := "buff",higher.effectInk := "buff"
        AssertLearning(ChooseBestCard([higher,lower])=1,"Observed green tiers compared wrongly")
        count += 3
    }
    AssertLearning(ChooseBestCard([rangeI,rangeII])=2,"Same-stat Range tier comparison changed")
    count += 5
    for sign in ["-",Chr(0x2212),Chr(0xFF0D),Chr(0xFE63),Chr(0x2011)] {
        negativeSpeed := CardPolicy(sign " 20% Enemy Speed",true,"buff")
        AssertLearning(negativeSpeed.kind="buff" && negativeSpeed.enemyReduction && negativeSpeed.amountSigned=-20,"Minus sign was lost on enemy Speed")
        negativeCooldown := CardPolicy("Cooldown II " sign " 15%",true,"buff")
        AssertLearning(negativeCooldown.kind="buff" && negativeCooldown.amountSigned=-15,"Minus sign was lost on Cooldown reduction")
        count += 2
    }
    positiveCooldown := CardPolicy("Cooldown II +15% Unit Cooldown",false,"debuff")
    AssertLearning(positiveCooldown.kind="debuff" && positiveCooldown.amountSigned=15,"Positive Cooldown increase was treated as a buff")
    count += 1
    numeric := CardPolicy("Attack 2 +20%",true,"buff")
    AssertLearning(numeric.tier=2 && numeric.amount=20,"Numeric tier was mistaken for effect amount")
    AssertLearning(CardPolicy("Attack +20%",true,"buff").tier=1,"Percentage mistaken for tier")
    AssertLearning(ChooseBestCard([secretShield,unreadableGreen,secretDeath])=2,"Unreadable green lost to secret-rate red cards")
    AssertLearning(ChooseBestCard([unreadable,secretDeath,unreadableGreen])=3,"Green lost when another card was unreadable")
    AssertLearning(FallbackCardChoice([speed,unreadableGreen,secretShield])=2,"Fallback failed unconditional green-first rule")
    AssertLearning(ChooseBestCard([speed,CardPolicy("Enemy Regen +5",false,"debuff")])=2,"Speed beat an unranked debuff")
    AssertLearning(ChooseBestCard([speed,speed,secretHealth])=3,"Speed ordinary alternatives suppressed the only non-Speed choice")
    AssertLearning(ChooseBestCard([speed,unreadable])=0 && FallbackCardChoice([speed,unreadable])=2,"Unreadable card did not beat Speed in the fallback")
    AssertLearning(ChooseBestCard([speed,speed,speed])=0 && FallbackCardChoice([speed,speed,speed])=0,"All-Speed offer must wait without clicking")
    for wording in ["-40% magical resist","Magical Resist -40%","-25% physical resist","Physical Resist -25%","-20% speed","Enemy Speed -20%","Speed III -20%","Magical Resist II -40%","Enemy Speed " Chr(0x2212) "20%"] {
        reduction := CardPolicy(wording,false,"debuff")
        AssertLearning(reduction.kind="buff" && reduction.enemyReduction,"Enemy stat reduction was not a buff: " wording)
        AssertLearning(!CardIsSpeed(reduction),"Negative Speed incorrectly hit the Speed-last restriction")
        AssertLearning(ChooseBestCard([secretShield,reduction,speed])=2,"Negative enemy effect lost to a red debuff")
        AssertLearning(ChooseBestCard([reduction,double])=2,"Enemy reduction overrode Double Attack")
        count += 4
    }
    for wording in ["Enemy Speed +20%","Speed III +10%","Speed","Enemy Speed +20% -30% Secret Portal Drop Rate"] {
        positiveSpeed := CardPolicy(wording,true,"buff")
        AssertLearning(positiveSpeed.kind="debuff" && CardIsSpeed(positiveSpeed),"Non-negative Speed escaped last-place rule: " wording)
        AssertLearning(FallbackCardChoice([positiveSpeed,secretHealth])=2,"Positive Speed beat another debuff")
        count += 2
    }
    AssertLearning(CardPolicy("Cooldown II -15% Unit Attack Speed",true,"buff").stat="cooldown","Attack Speed body replaced the Cooldown title")
    count += 1
    resistMix := CardPolicy("50% magical resist and 50% physical resist",false,"debuff")
    resistMagic150 := CardPolicy("150% magical resist",false,"debuff")
    AssertLearning(resistMix.resistance.known && resistMix.resistance.total=100 && resistMix.resistance.peak=50,"Combined resistance amounts were not added")
    AssertLearning(ChooseBestCard([resistMagic150,resistMix])=2 && ChooseBestCard([resistMix,resistMagic150])=1,"50+50 resistance did not beat 150 magical in both positions")
    AssertLearning(ChooseBestCard([CardPolicy("100% magical resist",false,"debuff"),resistMix])=2,"Equal totals did not prefer the lower highest individual increase")
    AssertLearning(ChooseBestCard([resistMix,CardPolicy("25% magical resist",false,"debuff")])=1,"Shared resistance lost to a smaller sole resistance")
    ; Reported rule: shared 50 physical + 50 magic beats any sole resist debuff.
    sharedShot := CardPolicy("+ Resistant Enemies I +50 Enemy Physical Resist +50 Enemy Magic Resist",false,"debuff")
    for sole in ["+100 Enemy Physical Resist","+75 Enemy Physical Resist","+75 Enemy Magic Resist","+25 Enemy Magic Resist"] {
        soleCard := CardPolicy(sole,false,"debuff")
        AssertLearning(ChooseBestCard([soleCard,sharedShot])=2 && ChooseBestCard([sharedShot,soleCard])=1,"Sole resistance beat shared physical+magic: " sole)
        count += 1
    }
    ; The reported offer: red Enemy Health, green Range, red shared resist.
    shotHealth := CardPolicy("+ Enemy Health I +50% Enemy Health",false,"debuff"),shotHealth.effectInk := "debuff"
    shotRange := CardPolicy("+ Range I +15% Range",true,"buff"),shotRange.effectInk := "buff"
    shotResist := sharedShot.Clone(),shotResist.effectInk := "debuff"
    AssertLearning(ChooseBestCard([shotHealth,shotRange,shotResist])=2 && FallbackCardChoice([shotHealth,shotRange,shotResist])=2,"Green Range lost to a red card")
    ; Green pixels alone (OCR unreadable) still mark the only green card.
    for greenIndex in [1,2,3] {
        pixels := PixelOnlyInkFixture(greenIndex)
        AssertLearning(PixelGreenCards(pixels).Length=1 && PixelGreenCards(pixels)[1]=greenIndex,"Pixel green card not found at " greenIndex)
        offer := ReadWordColourCards([],pixels,{cw:800,ch:600})
        AssertLearning(ChooseBestCard(offer)=greenIndex,"Unreadable green card lost at " greenIndex)
        count += 2
    }
    AssertLearning(PixelGreenCards(PixelOnlyInkFixture(0)).Length=0,"Red-only cards were read as green")
    green := PixelGreenCards(PixelOnlyInkFixture(3,true))
    AssertLearning(green.Length=1 && green[1]=3,"Red scenery outside the right card hid its green effect")
    count += 1
    AssertLearning(ChooseBestCard([CardPolicy("150% physical resist",false,"debuff"),CardPolicy("50% magical resist",false,"debuff")])=2,"Fixed physical/magical order overrode resistance amount")
    for wording in ["50% physical and magical resist","Physical and Magical Resist III +50%","Physical Resist +50% Magical Resist +50%","+50 Enemy Physical Resist +50 Enemy Magic Resist","Resistant Enemies I +50% physical resist and +50% magical resist"] {
        combined := CardPolicy(wording,false,"debuff")
        AssertLearning(combined.resistance.known && combined.resistance.physical=50 && combined.resistance.magical=50 && combined.resistance.total=100,"Resistance wording misread: " wording)
        count += 1
    }
    for wording in ["Physical Resistance 150%","Physical Resistance 150","Magical Resistance 150%","Enemy Physical Resistance 200"] {
        effect := CardPolicy(wording,false,"debuff")
        AssertLearning(effect.resistance.known && effect.resistance.total=(InStr(wording,"200")?200:150),"First digit of resistance amount was mistaken for a card tier: " wording)
        count += 1
    }
    AssertLearning(ChooseBestCard([CardPolicy("Physical Resistance 150%",false,"debuff"),resistMix])=2,"Bare 150% resistance beat 50+50 after OCR omitted plus sign")
    count += 1
    unequal := CardPolicy("Physical Resist +25% Magical Resist +75%",false,"debuff")
    AssertLearning(unequal.resistance.known && unequal.resistance.physical=25 && unequal.resistance.magical=75 && unequal.resistance.total=100,"Different per-stat suffix amounts were swapped or merged")
    decimal := CardPolicy("12.5% physical resist and 37.5% magical resist",false,"debuff")
    AssertLearning(decimal.resistance.total=50 && decimal.resistance.peak=37.5,"Decimal resistance amounts were not preserved")
    AssertLearning(ChooseBestCard([CardPolicy("50% magical resist",false,"debuff"),decimal])=2,"Decimal tie-break failed")
    repeated := CardPolicy("Magical Resist II +50% magical resist",false,"debuff")
    AssertLearning(repeated.resistance.total=50,"Title/body repetition double-counted resistance")
    rewardResist := CardPolicy("50% magical resist and 50% physical resist +30% Secret Portal Drop Rate",false,"debuff")
    AssertLearning(rewardResist.secretPortal && rewardResist.resistance.total=100,"Secret reward percentage inflated resistance")
    partial := CardPolicy("50% physical resist and magical resist unreadable",false,"debuff")
    AssertLearning(!ParseResistanceEffects("50% physical resist and unknown magical resist").known,"Unreadable second amount was treated as a known zero")
    AssertLearning(ChooseBestCard([resistMix,regen])=1 && ChooseBestCard([resistMix,normalHealth])=2,"Health > resistance > regen order broken within the caps")
    AssertLearning(ChooseBestCard([resistMix,unreadableGreen])=2 && ChooseBestCard([resistMix,double])=2,"Resistance amount overrode buff-first or Double Attack")
    AssertLearning(ChooseBestCard([speed,resistMagic150])=2,"Resistance change broke positive Speed-last")
    reduction := CardPolicy("-40% magical resist",false,"debuff")
    AssertLearning(reduction.kind="buff" && ChooseBestCard([resistMix,reduction])=2,"Negative resistance stopped being a buff")
    count += 15
    blessingsI := CardPolicy("Random Blessings I grants random buffs",true,"buff")
    blessingsII := CardPolicy("Random Blessings II grants random buffs",true,"buff")
    bossI := CardPolicy("Boss Damage I +20% damage to bosses",true,"buff")
    bossII := CardPolicy("Boss Damage II +40% physical damage against bosses",true,"buff")
    AssertLearning(blessingsI.stat="random blessings" && blessingsI.tier=1 && blessingsII.tier=2,"Random Blessings title/tiers not recognized")
    AssertLearning(bossII.stat="boss damage" && bossII.tier=2 && bossII.amount=40,"Boss-only physical damage was misclassified as Attack/resistance")
    AssertLearning(BuffTitleTier("Boss Damage ll")=2 && BuffTitleTier("Random Blessing II")=2,"New buff OCR title variants not recognized")
    AssertLearning(ChooseBestCard([blessingsI,double,CardPolicy("Attack X +500%",true,"buff")])=2,"Double Attack did not beat Random Blessings and every Attack tier")
    AssertLearning(ChooseBestCard([blessingsII,rangeI])=2,"Random Blessings beat Range")
    AssertLearning(ChooseBestCard([unreadableGreen,blessingsI])=2,"Unreadable green beat Random Blessings")
    AssertLearning(ChooseBestCard([CardPolicy("Yen II +30% Unit Yen",true,"buff"),unreadableGreen])=2,"Yen beat another green card")
    AssertLearning(ChooseBestCard([blessingsI,blessingsII])=2,"Random Blessings II did not beat I")
    AssertLearning(ChooseBestCard([bossI,bossII])=2,"Boss Damage II did not beat I when no other buff exists")
    AssertLearning(ChooseBestCard([bossII,attackI])=2,"Boss Damage II incorrectly beat Attack I")
    AssertLearning(ChooseBestCard([bossII,unreadableGreen])=2,"Boss Damage beat an unreadable green-word buff")
    AssertLearning(ChooseBestCard([secretShield,bossI])=2,"Last-priority buff incorrectly lost to a red debuff")
    AssertLearning(CardPolicy("+30% damage against bosses",true,"buff").stat="boss damage","Boss-only body wording fell back to general Attack")
    AssertLearning(CardPolicy("Attack I damage to all enemies including bosses",true,"buff").stat="attack","General Attack was incorrectly marked boss-only")
    AssertLearning(CardPolicy("Random Blessings 2 +30%",true,"buff").amount=30,"New numeric tier was mistaken for the amount")
    forbiddenBlessing := CardPolicy("Random Blessings II Enemy Speed +25%",true,"buff")
    AssertLearning(CardIsSpeed(forbiddenBlessing) && ChooseBestCard([forbiddenBlessing,attackI])=2,"Random Blessings bypassed the positive Speed ban")
    count += 13
    all := [attackI,cooldownII,rangeIII,double,unreadableGreen,unreadable,secretShield,secretDeath,normalHealth,speed,secretHealth,CardPolicy("-20% speed",false,"debuff"),blessingsI,bossII]
    for a in all {
        for b in all {
            for c in all {
                offer := [a,b,c],picked := FallbackCardChoice(offer),hasGreen := false,hasNonSpeed := false
                for candidate in offer
                    if candidate.kind="buff"
                        hasGreen := true
                if hasGreen
                    AssertLearning(offer[picked].kind="buff","Exhaustive offer violated green-first")
                else {
                    for candidate in offer
                        if !CardIsSpeed(candidate)
                            hasNonSpeed := true
                    if hasNonSpeed
                        AssertLearning(!picked || !CardIsSpeed(offer[picked]),"Exhaustive offer selected forbidden positive Speed")
                }
            }
        }
    }
    count += 18+all.Length**3
    for colour in [0xE0B020,0xA040E0,0x20C0D0,0xE02020,0x20E020,0xE0E0E0,0x808080] {
        AssertLearning(HasCardChoice(CentreCardFixture(colour)),"Centre-only card shape was missed")
        count += 1
    }
    AssertLearning(!HasCardChoice(CentreCardFixture(0xB020E0,false)),"One world edge falsely triggered a card")
    AssertLearning(!HasCardChoice(CentreCardFixture(0xB020E0,true,false)),"Bright world terrain falsely triggered a card")
    words := [{x:148,y:310,w:130,h:10,text:"Enemy Speed +25%"},{x:340,y:310,w:120,h:10,text:"Health +20%"},
        {x:522,y:310,w:130,h:10,text:"50% Physical Resist"},{x:522,y:335,w:130,h:10,text:"50% Magic Resist"},
        {x:642,y:380,w:23,h:10,text:"Enemy"},{x:670,y:380,w:25,h:10,text:"Speed"},{x:645,y:400,w:22,h:10,text:"Health"},
        {x:150,y:220,w:130,h:10,text:"Secret Portal Drop"}]
    ink := WordInkFixture(words)
    classified := ReadWordColourCards(words,ink,{cw:800,ch:600})
    AssertLearning(classified[1].kind="debuff" && CardIsSpeed(classified[1]),"Red Speed words were hidden by a green card frame/reward")
    AssertLearning(classified[2].kind="buff" && ChooseBestCard(classified)=2,"Green Health words lost to Speed or a red frame")
    AssertLearning(classified[3].kind="debuff" && classified[3].resistance.known && classified[3].resistance.total=100 && !CardIsSpeed(classified[3]),"Right-panel Speed words entered the third card or resistance amounts were lost")
    AssertLearning(!HasCardChoice(RightPanelOnlyFixture()),"Right-side modifiers were treated as selectable cards")
    AssertLearning(FallbackCardChoice([CardPolicy("Enemy Speed +25%",true,"buff"),CardPolicy("Enemy Health +20%",false,"debuff")])=2,"Speed ban failed when colour was incorrectly green")
    AssertLearning(FallbackCardChoice([CardPolicy("Enemy Speed +25%",false,"debuff")])=0,"Single unavoidable Speed was clicked")
    ; Exact reported offer: two red debuffs and a green Speed reduction.
    for greenIndex in [1,2,3] {
        for effectText in ["-20% Enemy Speed","20% Enemy Speed","unreadable effect"] {
            sample := []
            for index,left in [148,340,522]
                sample.Push({x:left,y:310,w:135,h:10,text:index=greenIndex?effectText:index=1?"Cooldown +15%":"Enemy Health +50%",ink:index=greenIndex?0x20E020:0xE02020})
            offer := ReadWordColourCards(sample,GreenFirstWordFixture(sample),{cw:800,ch:600})
            AssertLearning(CardHasGreenEffect(offer[greenIndex]) && ChooseBestCard(offer)=greenIndex,"Single green effect lost to red cards, including an OCR-lost minus")
            AssertLearning(FallbackCardChoice(offer)=greenIndex && !CardIsSpeed(offer[greenIndex]),"Green Speed reduction was blocked in fallback/confirmation")
            count += 2
        }
    }
    for amountText in ["-20%","20%"] {
        sample := [{x:148,y:310,w:135,h:10,text:"Cooldown +15%",ink:0xE02020},
            {x:340,y:210,w:120,h:10,text:"Enemy Speed",ink:0xEEEEEE},
            {x:370,y:330,w:45,h:10,text:amountText,ink:0x20E020},
            {x:522,y:310,w:140,h:10,text:"Enemy Health +50%",ink:0xE02020}]
        offer := ReadWordColourCards(sample,GreenFirstWordFixture(sample),{cw:800,ch:600})
        AssertLearning(offer[1].effectInk="debuff" && offer[2].effectInk="buff" && ChooseBestCard(offer)=2,"Percentage-only green words were ignored")
        count += 1
    }
    fakeRedBuff := CardPolicy("Attack X +500%",true,"buff"),fakeRedBuff.effectInk := "debuff"
    soleGreen := CardPolicy("Enemy Speed +20%",false,"debuff"),soleGreen.effectInk := "buff"
    AssertLearning(ChooseBestCard([fakeRedBuff,soleGreen,secretShield])=2,"Text-derived kinds overruled observed green/red word colours")
    greenBoss := bossII.Clone(),greenBoss.effectInk := "buff"
    AssertLearning(ChooseBestCard([greenBoss,fakeRedBuff,soleGreen])=3,"Two green cards were compared with a red card or Boss Damage priority changed")
    AssertLearning(ChooseBestCard([greenBoss,fakeRedBuff,secretShield])=1,"The sole green Boss Damage card lost to red cards")
    wrongRedBuff := unreadableGreen.Clone(),wrongRedBuff.effectInk := "debuff"
    AssertLearning(ChooseBestCard([wrongRedBuff,speed])=0 && FallbackCardChoice([wrongRedBuff,speed])=1,"Unreadable red card did not beat Speed, or red words were read as a buff")
    wrongRedSpeed := CardPolicy("-20% Enemy Speed",true,"buff"),wrongRedSpeed.effectInk := "debuff"
    AssertLearning(CardIsSpeed(wrongRedSpeed) && FallbackCardChoice([wrongRedSpeed])=0,"Red Speed words were allowed by a guessed minus sign")
    count += 3
    observedRange := rangeI.Clone(),observedRange.effectInk := "buff"
    observedCooldown := cooldownI.Clone(),observedCooldown.effectInk := "buff"
    AssertLearning(ChooseBestCard([observedRange,observedCooldown,fakeRedBuff])=2,"Cooldown priority compared against a red card or lost inside the green-only set")
    for kind in ["buff","debuff"] {
        blank := CardPolicy("unreadable",kind="buff",kind),blank.effectInk := kind
        AssertLearning(ChooseBestCard([blank,blank.Clone(),blank.Clone()])=2,"Three unreadable " kind " cards did not pick the middle card")
        count += 1
    }
    count += 1
    greenRandom := blessingsI.Clone(),greenRandom.effectInk := "buff"
    AssertLearning(ChooseBestCard([greenBoss,greenRandom,soleGreen])=2,"Random Blessings did not rank first within the green-only set")
    greenYen := CardPolicy("Yen II +30% Unit Yen",true,"buff"),greenYen.effectInk := "buff"
    greenUnknown := unreadableGreen.Clone(),greenUnknown.effectInk := "buff"
    for offer in [[greenYen,greenUnknown,greenBoss],[greenBoss,greenYen,greenUnknown],[greenUnknown,greenBoss,greenYen]] {
        selected := ChooseBestCard(offer)
        AssertLearning(offer[selected].stat="unknown" && FallbackCardChoice(offer)=selected,"Unreadable green lost to Yen or Boss Damage")
    }
    AssertLearning(ChooseBestCard([soleGreen,greenYen,greenBoss])=1,"Green Speed lost to Yen or Boss Damage")
    AssertLearning(ChooseBestCard([greenBoss,greenYen])=2,"Boss Damage was not the last green buff")
    locked := greenYen.Clone(),locked.index := 1
    promoted := PreferVerifiedGreenChoice([greenYen,greenUnknown,greenBoss],locked)
    AssertLearning(promoted.index=2,"A locked Yen card blocked newly verified unreadable green words")
    locked := greenBoss.Clone(),locked.index := 1
    promoted := PreferVerifiedGreenChoice([greenBoss,soleGreen,fakeRedBuff],locked)
    AssertLearning(promoted.index=2,"A locked Boss card blocked a verified green Speed buff")
    count += 3
    gResistancePreference := "balanced"
    ; The reported loss: 230% Health, 100/100 resist. Health +200 would reach
    ; 430% (over 300); shared resist reaches 150/150 (at its cap) and wins.
    lossHealth := CardPolicy("+ Enemy Health III +200% Enemy Health",false,"debuff")
    lossResist := CardPolicy("+ Resistant Enemies II +50 Enemy Physical Resist +50 Enemy Magic Resist",false,"debuff")
    lossRegen := CardPolicy("+ Regenerating Enemies +5.0% Enemy Regen",false,"debuff")
    gMatchModifiers := {health:230,healthKnown:true,physical:100,magical:100,regen:0}
    AssertLearning(ChooseBestCard([lossHealth,lossResist,lossRegen])=2,"Reported loss repeated: Health +200 past the cap beat resistance within it")
    AssertLearning(FallbackCardChoice([lossHealth,lossResist,lossRegen])=2,"Fallback ignored the projected caps")
    ; Health landing exactly on 300% is still within its cap.
    gMatchModifiers := {health:250,healthKnown:true,physical:0,magical:0,regen:0}
    AssertLearning(ChooseBestCard([resistMix,normalHealth])=2,"Health reaching exactly 300% lost its priority")
    gMatchModifiers := {health:260,healthKnown:true,physical:0,magical:0,regen:0}
    AssertLearning(ChooseBestCard([normalHealth,resistMix])=2,"Health past 300% still beat resistance within its cap")
    ; Both past their caps: the one least far over wins (330/300 vs 200/150).
    gMatchModifiers := {health:280,healthKnown:true,physical:150,magical:150,regen:0}
    AssertLearning(ChooseBestCard([resistMix,normalHealth])=2,"Over-cap comparison did not take the card least past its cap")
    AssertLearning(ChooseBestCard([lossHealth,resistMix])=2,"Health +200 (480/300) beat resistance at 200/150")
    ; Over-cap Health/resistance still beat regen past 2%; Shield/Explosive Death beat everything red.
    AssertLearning(ChooseBestCard([lossRegen,lossHealth])=2,"Over-cap regen beat over-cap Health")
    AssertLearning(ChooseBestCard([lossHealth,CardPolicy("+3 Enemy Shield",false,"debuff")])=2,"Shield lost to Health past its cap")
    ; Regen: any amount while the total stays within 2%, never past it.
    halfRegen := CardPolicy("+0.5% Enemy Regen",false,"debuff"),oneRegen := CardPolicy("+1% Enemy Regen",false,"debuff")
    gMatchModifiers := {health:0,healthKnown:true,physical:0,magical:0,regen:1.5}
    AssertLearning(ChooseBestCard([speed,halfRegen])=2 && DebuffOutlook(halfRegen).group=5,"0.5 regen reaching exactly 2% was refused")
    AssertLearning(DebuffOutlook(oneRegen).group=7,"Regen past 2% stayed within its cap")
    gMatchModifiers := {health:0,healthKnown:true,physical:0,magical:0,regen:1}
    AssertLearning(DebuffOutlook(oneRegen).group=5,"1% regen within the 2% total was refused")
    ; Unreadable amounts assume the worst case.
    AssertLearning(DebuffOutlook(CardPolicy("Enemy Health",false,"debuff")).group=6,"Unread Health amount was treated as safe")
    AssertLearning(DebuffOutlook(CardPolicy("Enemy Regen",false,"debuff")).group=7,"Unread regen amount was treated as safe")
    ; Existing resistance rules still apply between resistance cards.
    gMatchModifiers := {health:250,healthKnown:true,physical:200,magical:50,regen:0}
    AssertLearning(ChooseBestCard([CardPolicy("150% physical resist",false,"debuff"),resistMix])=2,"Shared resistance lost to 150 sole physical when both are past the cap")
    AssertLearning(ChooseBestCard([resistMix,CardPolicy("100% magical resist",false,"debuff")])=2,"Shared resistance pushed physical past its cap while 100 magical stayed within it")
    AssertLearning(ChooseBestCard([CardPolicy("100% physical resist",false,"debuff"),CardPolicy("100% magical resist",false,"debuff")])=2,"Resistance within its cap lost to resistance past it")
    gResistancePreference := "magic"
    AssertLearning(ChooseBestCard([resistMix,CardPolicy("150% physical resist",false,"debuff")])=2,"Magic-team preference failed to avoid magical resistance")
    gResistancePreference := "physical"
    AssertLearning(ChooseBestCard([resistMix,resistMagic150])=2,"Physical-team preference failed to avoid physical resistance")
    gResistancePreference := "balanced"
    ResetMatchCardContext()
    modifiers := ParseMatchModifiers([{text:"Enemy Health: +100.0%"},{text:"Physical Resistance: +200"},{text:"Magic Resistance: +50"}])
    AssertLearning(modifiers.healthKnown && modifiers.health=100 && modifiers.physical=200 && modifiers.magical=50,"Screenshot right-panel values misread: health=" modifiers.health " known=" modifiers.healthKnown " physical=" modifiers.physical " magic=" modifiers.magical)
    ; End-screen panel from the reported loss, plus a regen row.
    modifiers := ParseMatchModifiers([{text:"Enemy Speed: -25.0%"},{text:"Enemy Health: +430.0%"},{text:"Enemy Shields: +3"},
        {text:"Physical Resistance: +100"},{text:"Magic Resistance: +100"},{text:"Enemy Regen: +0.5%"}])
    AssertLearning(modifiers.health=430 && modifiers.physical=100 && modifiers.magical=100 && modifiers.regenKnown && modifiers.regen=0.5,"Level Modifiers totals misread")
    ; Card wording ("+50% Enemy Health") leaking into the panel crop is not a total.
    modifiers := ParseMatchModifiers([{text:"+50% Enemy Health"},{text:"+75 Enemy Magic Resist"},{text:"+0.5% Enemy Regen"}])
    AssertLearning(!modifiers.healthKnown && !modifiers.magicalKnown && !modifiers.regenKnown,"Card text was read as a Level Modifiers total")
    if FileExist(A_ScriptDir "\cache\provided-modifiers-upscaled.tsv") {
        actual := ParseMatchModifiers(ParseOcrRows(FileRead(A_ScriptDir "\cache\provided-modifiers-upscaled.tsv","UTF-8"),0,0))
        AssertLearning(actual.healthKnown && actual.health=100 && actual.physical=200 && actual.magical=50,"Actual attached screenshot OCR: health=" actual.health " known=" actual.healthKnown " physical=" actual.physical " magical=" actual.magical)
        count += 1
    }
    count += 16
    parsed := ParseOcrRows("33`t22`t72`t38`tPlay`n33`t92`t166`t38`tPlay Here",100,200)
    AssertLearning(parsed.Length=2 && parsed[1].x=133 && parsed[1].y=222 && parsed[2].text="Play Here","OCR crop coordinates were translated incorrectly")
    count += 1
    current := {map:"snowy",w:1415,h:1121,dpi:96,px:650,py:530,hx:1,hy:0,scene:"101111001"}
    old := current.Clone()
    AssertLearning(PlacementContextMatches(old,current),"Matching placement context rejected")
    count += 1
    for field, value in Map("map","sand","w",1400,"dpi",120,"px",670,"hx",-1,"scene","010000110") {
        changed := current.Clone(), changed.%field% := value
        AssertLearning(!PlacementContextMatches(changed,current),"Unsafe placement context accepted: " field)
        count += 1
    }
    originalFile := LEARNING_FILE, originalProfile := gPlacementProfile
    originalButtons := BUTTONS_FILE
    testFile := A_ScriptDir "\learning-test-" DllCall("GetCurrentProcessId") ".ini"
    try {
        LEARNING_FILE := testFile
        BUTTONS_FILE := A_ScriptDir "\missing-buttons-test.ini"
        AssertLearning(ButtonPosition("LobbyPlay",&rx,&ry) && rx=88 && ry=278,"Missing button file must not break the first Play button")
        count += 1
        geometry := {w:1415,h:1121,dpi:96}
        AssertLearning(SaveButtonRecord("LobbyPlay",{x:155,y:534},geometry,"test",testFile),"Button save failed")
        saved := ReadButtonRecord("LobbyPlay",geometry,testFile)
        AssertLearning(saved && saved.x=155 && saved.y=534,"Application-window coordinates did not survive reload")
        count += 1
        AssertLearning(!ReadButtonRecord("LobbyPlay",{w:1401,h:1114,dpi:96},testFile),"Button from another window size was reused")
        count += 1
        AssertLearning(!ReadButtonRecord("LobbyPlay",{w:1415,h:1121,dpi:120},testFile),"Button from another DPI was reused")
        count += 1
        AssertLearning(!SaveButtonRecord("bad",{x:-1,y:40},geometry,"test",testFile),"Out-of-window coordinate was saved")
        count += 1
        ; Persistence tests clear RAM before reading, proving the file is used.
        bits := "11111111111001011000101111001010"
        card := CardPolicy("Enemy physical and magical resist +30%")
        RememberCard(bits,card,"test")
        gCardMemory.Clear()
        reloaded := ReadCardMemory(bits)
        AssertLearning(reloaded && reloaded.kind="debuff" && reloaded.rank=CardRank("debuff","physical and magical resist") && reloaded.amount=30,"Card did not survive a cold-cache reload")
        count += 1
        AssertLearning(reloaded.resistance.known && reloaded.resistance.total=60,"Resistance total did not survive a cold-cache reload")
        resistBits := "11110101011001011000101111001010"
        RememberCard(resistBits,resistMix,"test")
        gCardMemory.Clear()
        resistReloaded := ReadCardMemory(resistBits)
        AssertLearning(resistReloaded && resistReloaded.resistance.total=100 && ChooseBestCard([resistMagic150,resistReloaded])=2,"Reloaded resistance card used the old fixed order")
        count += 2
        tierBits := "11110111011001011000101111001010"
        RememberCard(tierBits,cooldownII,"test")
        gCardMemory.Clear()
        tierReloaded := ReadCardMemory(tierBits)
        AssertLearning(tierReloaded && tierReloaded.tier=2 && tierReloaded.stat="cooldown","Buff tier did not survive cold reload")
        count += 1
        secretBits := "11110111111001011000101111001010"
        RememberCard(secretBits,secretShield,"test")
        gCardMemory.Clear()
        rewardReloaded := ReadCardMemory(secretBits)
        AssertLearning(rewardReloaded && rewardReloaded.secretPortal,"Secret-rate card reward did not survive reload")
        count += 1
        AssertLearning(!ReadCardMemory("00000000000000000000000000000000"),"Blank card image was learned")
        count += 1
        gPlacementProfile := "profile.test-map-view"
        unit := {slot:1,name:"Bulby"}
        WritePlacementRecords(unit,[{x:600,y:500,good:2,bad:0}])
        restored := ReadPlacementRecords(unit)
        AssertLearning(restored.Length=1 && restored[1].x=600 && restored[1].good=2,"Confirmed placement did not survive reload")
        count += 1
        RememberPlacement(unit,{memoryIndex:1},false)
        AssertLearning(ReadPlacementRecords(unit)[1].bad=1,"Rejected cached placement was not tracked")
        count += 1
        AssertLearning(ReadPlacementRecords({slot:2,name:"Elyssia"}).Length=0,"Placement records leaked between units")
        count += 1
    } finally {
        LEARNING_FILE := originalFile, gPlacementProfile := originalProfile
        BUTTONS_FILE := originalButtons
        gCardMemory.Clear(), gButtonMemory.Clear()
        try FileDelete testFile
    }
    return count
}

class CardBorderFixture {
    valid := true
    __New(green) {
        this.green := green
    }
    AtRef(x,y) {
        if Abs(x-123)<=2 || Abs(x-296)<=2
            return this.green?0x20E020:0xE02020
        return this.green?0xE02020:0x20E020
    }
}

class CentreCardFixture {
    valid := true
    __New(colour,both := true,dark := true) {
        this.colour := colour,this.both := both,this.dark := dark
    }
    AtRef(x,y) {
        if (Abs(x-314)<=2 || (this.both && Abs(x-488)<=2)) && y>=195 && y<=410
            return this.colour
        return this.dark?0x181818:0xB0B0B0
    }
}

class RedHintCardFixture extends CentreCardFixture {
    __New() {
        super.__New(0x20E020)
    }
    AtRef(x,y) {
        if (Abs(x-314)<=2 || Abs(x-488)<=2) && y=205
            return 0xE02020
        return super.AtRef(x,y)
    }
}

class WordInkFixture {
    valid := true
    __New(words) {
        this.words := words
    }
    AtRef(x,y) {
        for word in this.words {
            if x>=word.x && x<=word.x+word.w && y>=word.y && y<=word.y+word.h
                return word.x=340 || word.y=220 || word.y=400?0x20E020:0xE02020
        }
        return 0x181818
    }
}
class PixelOnlyInkFixture {
    valid := true
    __New(greenIndex,rightScenery := false) {
        this.greenIndex := greenIndex
        this.rightScenery := rightScenery
    }
    AtRef(x,y) {
        if this.rightScenery && x>=643
            return 0xF01818
        for index,left in [129,320,512]
            if x>=left+30 && x<=left+130 && y>=205 && y<=250
                return index=this.greenIndex?0x10F010:0xF01818
        return 0x181818
    }
}
class RightPanelOnlyFixture {
    valid := true
    AtRef(x,y) => x>635?0xE02020:0x181818
}

class GreenFirstWordFixture {
    valid := true
    __New(words) {
        this.words := words
    }
    AtRef(x,y) {
        for word in this.words
            if x>=word.x && x<=word.x+word.w && y>=word.y && y<=word.y+word.h
                return word.ink
        return 0x181818
    }
}

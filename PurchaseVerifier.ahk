; The one place that decides "did this click buy a unit?".
;
; Evidence, strongest first:
;  1. Slot counter: holding a unit shows "n/max" above its hotbar card (also
;     when the slot is full). Read before the click and after it: n+1 means
;     bought, n unchanged means refused.
;  2. Yen: the Yen before the click against the Yen after it (each needs two
;     agreeing reads). A drop of at least PURCHASE_YEN_DROP_FRACTION of the
;     unit's cost means bought, no drop means refused.
;  3. Unit panel (weak): the side panel also opens on an already placed unit,
;     so it counts only when no recorded unit lies within the CandidateOccupied
;     radius of the click point.
; DecidePurchase is a pure function over that evidence. The probes press only
; the unit's slot key and Q (to read a counter); they never press F, change the
; phase or write placement state. Placement.ahk acts on the verdict.
global PURCHASE_YEN_DROP_FRACTION := 0.5
; Probes after the first one, while the verdict stays unknown.
global PURCHASE_REPROBE_LIMIT := 3
; OCR passes per state read; two consecutive agreeing Yen reads end it earlier.
global PURCHASE_READ_ATTEMPTS := 4
; Pause after a click before reading the result (the game updates the HUD).
global PURCHASE_SETTLE_MS := 300
; Words closer than this (reference px) belong to one counter ("0", "/", "3").
global COUNTER_WORD_GAP := 10
; A counter belongs to the slot whose HOTBAR_SLOT_X is within this distance.
global COUNTER_SLOT_GAP := 30
global COUNTER_MAX_PLAUSIBLE := 99

; All fields a verdict can use. counterBefore/counterAfter are {n,max} or 0;
; yen values are -1 when unreadable.
NewPurchaseEvidence() {
    return {counterBefore:0,counterAfter:0,yenBefore:-1,yenAfter:-1,cost:0,panelSeen:false,recordedNearby:false}
}

; The verdict with the evidence that produced it: {verdict,by}. verdict is
; "confirmed", "denied" or "unknown"; by is a plain-text reason for the log.
; Rule order (the first rule that can decide wins):
;  1. counter before and after readable (same max): after=before+1 confirmed,
;     after=before denied (any other change is not trusted, next rule)
;  2. Yen before and after readable and the cost known: a drop of at least
;     PURCHASE_YEN_DROP_FRACTION*cost confirmed, otherwise denied
;  3. a unit panel with no recorded unit nearby: confirmed
;  4. unknown
JudgePurchase(ev) {
    global PURCHASE_YEN_DROP_FRACTION
    before := ev.counterBefore,after := ev.counterAfter
    if IsObject(before) && IsObject(after) && before.max=after.max {
        if after.n=before.n+1
            return {verdict:"confirmed",by:"slot counter " before.n "/" before.max " -> " after.n "/" after.max}
        if after.n=before.n
            return {verdict:"denied",by:"slot counter stayed at " after.n "/" after.max}
    }
    if ev.yenBefore>=0 && ev.yenAfter>=0 && ev.cost>0 {
        drop := ev.yenBefore-ev.yenAfter
        if drop>=PURCHASE_YEN_DROP_FRACTION*ev.cost
            return {verdict:"confirmed",by:"Yen " ev.yenBefore " -> " ev.yenAfter " (cost " ev.cost ")"}
        return {verdict:"denied",by:"Yen " ev.yenBefore " -> " ev.yenAfter " (cost " ev.cost "), no drop"}
    }
    if ev.panelSeen && !ev.recordedNearby
        return {verdict:"confirmed",by:"unit panel (no recorded unit nearby)"}
    return {verdict:"unknown",by:""}
}

DecidePurchase(ev) {
    return JudgePurchase(ev).verdict
}

; Words of the hotbar strip ({l,r,text} in reference px) to the counters they
; spell: [{x,n,max}]. Words close together are rejoined first, so "0 / 3" and
; "0/3" read the same; anything that is not n/max with n <= max is ignored.
ParseCounterWords(words) {
    global COUNTER_WORD_GAP,COUNTER_MAX_PLAUSIBLE
    sorted := []
    for word in words {
        at := sorted.Length+1
        for index,other in sorted
            if word.l<other.l {
                at := index
                break
            }
        sorted.InsertAt(at,word)
    }
    clusters := [],current := 0
    for word in sorted {
        if current && word.l-current.r<=COUNTER_WORD_GAP {
            current.text .= word.text,current.r := Max(current.r,word.r)
        } else {
            current := {l:word.l,r:word.r,text:word.text}
            clusters.Push(current)
        }
    }
    found := []
    for cluster in clusters {
        if !RegExMatch(cluster.text,"(\d+)\s*/\s*(\d+)",&match) || StrLen(match[1])>3 || StrLen(match[2])>3
            continue
        n := Integer(match[1]),cap := Integer(match[2])
        if cap>=1 && cap<=COUNTER_MAX_PLAUSIBLE && n<=cap
            found.Push({x:(cluster.l+cluster.r)/2,n:n,max:cap})
    }
    return found
}

; The counter of one slot: the counter centred over that slot's card (the same
; x mapping the cost reader uses). A counter over no slot at all is accepted
; only when it is the only one in the strip (the held unit's). A counter that
; sits over a different slot is never taken for this one.
SlotCounterFromWords(words,slot) {
    global HOTBAR_SLOT_X,COUNTER_SLOT_GAP
    found := ParseCounterWords(words)
    best := false,gap := COUNTER_SLOT_GAP
    for counter in found {
        if HOTBAR_SLOT_X.Has(slot) && Abs(counter.x-HOTBAR_SLOT_X[slot])<gap
            gap := Abs(counter.x-HOTBAR_SLOT_X[slot]),best := counter
    }
    if best
        return {n:best.n,max:best.max}
    if found.Length=1 {
        for centre in HOTBAR_SLOT_X
            if Abs(found[1].x-centre)<COUNTER_SLOT_GAP
                return false
        return {n:found[1].n,max:found[1].max}
    }
    return false
}

; The counter value all reads agree on, or false (none read, or they differ).
AgreedCounter(reads) {
    if !reads.Length
        return false
    for read in reads
        if read.n!=reads[1].n || read.max!=reads[1].max
            return false
    return reads[1]
}

; One fresh OCR pass of the hotbar: Yen, this unit's cost and its slot counter.
ReadHotbarPass(unit) {
    global gLastOcrRect
    gLastOcrRect := ""
    read := ReadPlacementMoney()
    return {yen:read.yen,cost:UnitPlacementCost(unit,read),counter:SlotCounterFromWords(read.counterWords,unit.slot)}
}

; The hotbar state with the safety the verdict needs: Yen is believed only
; when two consecutive passes agree (two unreadable passes in a row end the
; read with Yen -1), the counter only when every pass that read one agrees.
; At most PURCHASE_READ_ATTEMPTS passes.
ReadPurchaseState(unit) {
    global gRunning,PURCHASE_READ_ATTEMPTS
    state := {yen:-1,cost:0,counter:false}
    previous := -2,counters := []
    Loop PURCHASE_READ_ATTEMPTS {
        if !gRunning
            break
        pass := ReadHotbarPass(unit)
        if pass.cost>0
            state.cost := pass.cost
        if pass.counter
            counters.Push(pass.counter)
        if pass.yen=previous {
            state.yen := pass.yen
            break
        }
        previous := pass.yen
    }
    state.counter := AgreedCounter(counters)
    return state
}

; Gathers the evidence for the purchase click that is pending at point and
; returns JudgePurchase's verdict plus the evidence. point carries what was
; read before the click (counterBefore, yenBefore, cost). The counter shows
; only while the unit is held, so when it cannot be read the unit's slot key is
; pressed once to read it, and Q drops the hold again.
ProbePurchase(unit,point) {
    global gRunning,PURCHASE_SETTLE_MS
    ev := NewPurchaseEvidence()
    if point.HasProp("counterBefore")
        ev.counterBefore := point.counterBefore
    if point.HasProp("yenBefore")
        ev.yenBefore := point.yenBefore
    if point.HasProp("cost")
        ev.cost := point.cost
    if !ActionPause(PURCHASE_SETTLE_MS)
        return {verdict:"unknown",by:"",evidence:ev}
    state := ReadPurchaseState(unit)
    if !state.counter && gRunning {
        if SelectPlacementUnit(unit) && ActionPause(PURCHASE_SETTLE_MS) {
            held := ReadPurchaseState(unit)
            CancelUnitPreview()
            state.counter := held.counter
            if state.yen<0
                state.yen := held.yen
            if state.cost<=0
                state.cost := held.cost
        }
    }
    ev.counterAfter := state.counter,ev.yenAfter := state.yen
    if ev.cost<=0
        ev.cost := state.cost
    ; Weak evidence: only where no recorded unit could own the panel.
    ev.recordedNearby := CandidateOccupied(point.x,point.y)
    ev.panelSeen := !ev.recordedNearby && HasUnitPanel()
    judged := JudgePurchase(ev)
    judged.evidence := ev
    return judged
}

; The slot counter right now, read the way the audit needs it: select the
; unit, read the hotbar, drop the hold with Q. {n,max}, or false when the
; counter cannot be read (or the run stopped). One attempt; callers bound
; their own retries.
ProbeSlotCounter(unit) {
    global gRunning,PURCHASE_SETTLE_MS
    if !gRunning || !SelectPlacementUnit(unit)
        return false
    counter := false
    if ActionPause(PURCHASE_SETTLE_MS)
        counter := ReadPurchaseState(unit).counter
    CancelUnitPreview()
    return counter
}

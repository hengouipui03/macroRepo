"""Exercise the shared panel detector with a different device's UI layout."""
from pathlib import Path
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = '\n'.join(function(file,name) for file,name in [
    ('Placement.ahk','UnitPanelColourHits'),('Placement.ahk','HasUnitPanel'),
    ('Placement.ahk','UnitPanelRegion'),('Placement.ahk','WaitForUnitPanel'),
    ('Learning.ahk','NormalizeWords'),('AAPathMacro.ahk','RGB'),
    ('AAPathMacro.ahk','IsUiYellow'),('AAPathMacro.ahk','IsBubbleRed'),
    ('AAPathMacro.ahk','IsUiRed'),('AAPathMacro.ahk','IsUiGreen')])

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global gRunning := true,gUnitPanelLayout := 0,gUnitPanelClose := 0,REF_W := 800,REF_H := 600,reads := 0
try {
    if HasUnitPanel()
        throw Error("fixture unexpectedly matched the old fixed panel position")
    if !WaitForUnitPanel(10)
        throw Error("panel was not learned from UPG/Sell/Upgrade on the other layout")
    if !HasUnitPanel()
        throw Error("learned panel regions were not reused")
    previous := reads
    if !WaitForUnitPanel(10) || reads!=previous
        throw Error("known panel performed OCR again instead of reusing its regions")
    FileAppend "PASS: different-device UPG/Sell/Upgrade layout learned once; the shared pixel detector reuses it for purchase confirmation.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack,"*"
    ExitApp 1
}
GetClient(&cx,&cy,&cw,&ch) {
    cx := 0,cy := 0,cw := 1280,ch := 720
    return true
}
WaitFor(test,*) => test.Call()
HasCardChoice(*) => false
Log(*) => 0
ReadOcrRows(*) {
    global reads
    reads += 1
    return [{x:224,y:360,w:112,h:24,text:"UPG [7]"},
            {x:40,y:516,w:184,h:36,text:"Sell: 1000 Yen"},
            {x:256,y:516,w:176,h:48,text:"Upgrade: 3000 Yen"}]
}
class RefPixels {
    valid := true
    __New(*) {
    }
    AtRef(x,y) {
        if x>=140 && x<=210 && y>=300 && y<=320
            return 0xFFD520
        if x>=25 && x<=140 && y>=430 && y<=460
            return 0xEE3030
        if x>=160 && x<=270 && y>=430 && y<=470
            return 0x20DD30
        return 0x151515
    }
}
'''

if __name__ == '__main__':
    target = ROOT/'cache'/'unit-panel-regression.ahk'
    target.write_text(fixture+'\n'+logic,encoding='utf-8-sig')
    result = subprocess.run([str(RUNTIME),'/ErrorStdOut=UTF-8',str(target)],capture_output=True,timeout=30)
    print(result.stdout.decode('utf-8-sig'),end='')
    print(result.stderr.decode('utf-8-sig'),end='')
    raise SystemExit(result.returncode)

"""Focused UPG OCR fallback; all window reads and game input are simulated.

OCR rows reproduce Windows OCR on cache/upgrade-native.bmp: 4x returns
only 'UPG', while 2x returns 'UPG [9)'. No screenshot is edited or captured.
"""
import subprocess
from UpgradeRegressionTests import ROOT, RUNTIME, function

logic = '\n'.join(function(file, name) for file, name in [
    ('PlacedUnits.ahk', 'ReadUnitUpgradeState'),
    ('PlacedUnits.ahk', 'ParseUpgradeState'),
    ('Learning.ahk', 'NormalizeWords'),
    ('Learning.ahk', 'ParseOcrRows'),
])

fixture = r'''
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global REF_W := 800,REF_H := 600,calls := [],scaledText := "UPG",nativeText := "UPG [9)",fullText := "Damage 5000",changing := false,signatureReads := 0
try {
    state := ReadUnitUpgradeState(true)
    Assert(state.level=9,"4x OCR omitted the digit; focused 2x OCR did not recover UPG 9")
    Assert(calls.Length=2 && calls[1].scale=4 && calls[2].scale=2 && calls[2].x1=137,"fallback did not stay inside the UPG heading")
    Assert(state.signature="stable-heading" && state.canUpgrade,"OCR fallback lost the existing readiness/signature checks")

    nativeText := "UPG",calls := []
    state := ReadUnitUpgradeState(true)
    Assert(state.level=-1,"missing digits were guessed from damage or cost")
    Assert(calls.Length=3 && calls[3].x1=0,"existing full-panel fallback was removed")

    nativeText := "UPG [9)",changing := true,signatureReads := 0
    state := ReadUnitUpgradeState(true)
    Assert(state.level=-1 && state.signature="","changing heading bypassed the upgrade guard")

    changing := false,scaledText := "UPG MAX",nativeText := "UPG"
    state := ReadUnitUpgradeState(true)
    Assert(state.maxed,"fallback discarded an already recognized MAX heading")

    changing := false,fullText := "UPG [5]",calls := []
    state := ReadUnitUpgradeState(false)
    Assert(state.level=5 && calls.Length=1 && calls[1].x1=0,"MAX upgrade reader changed")
    FileAppend "PASS: actual 4x OCR missing digit recovered by focused 2x; no guessed number; existing full-panel, stable-heading and MAX behavior retained.`n","*","UTF-8"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message "`n" err.Stack "`n","*","UTF-8"
    ExitApp 1
}
Assert(condition,message) {
    if !condition
        throw Error(message)
}
WindowGeometry() => {cw:800,ch:600}
UnitPanelRegion(name) => name="header"?[137,210,215,246]:[145,340,265,395]
UnitUpgradeButtonReady(*) => true
UpgradeHeaderSignature(*) {
    global signatureReads
    signatureReads += 1
    return changing?"changed-" signatureReads:"stable-heading"
}
ReadOcrRows(x1,y1,x2,y2,words := false,scale := 2) {
    calls.Push({x1:x1,scale:scale})
    if x1=137 {
        text := scale=4?scaledText:nativeText
        return ParseOcrRows("8`t9`t68`t20`t" text,137,210)
    }
    return [{x:145,y:215,w:68,h:20,text:fullText}]
}
'''

if __name__ == '__main__':
    target = ROOT/'cache'/'upgrade-ocr-fallback-regression.ahk'
    target.write_text(fixture+'\n'+logic, encoding='utf-8-sig')
    result = subprocess.run([str(RUNTIME), '/ErrorStdOut=UTF-8', str(target)],
                            capture_output=True, timeout=30)
    print(result.stdout.decode('utf-8-sig'), end='')
    print(result.stderr.decode('utf-8-sig'), end='')
    raise SystemExit(result.returncode)

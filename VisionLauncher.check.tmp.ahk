#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, Off
global VISION_PYTHON := A_ScriptDir "\missing-pythonw.exe",gVision := 0,gVisionFailed := false,fakeMode := "real",logs := []
VisionPythonCandidates() {
    global VISION_PYTHON,fakeMode
    if fakeMode="all-fail"
        return [{exe:"bad",args:""}]
    if fakeMode="fallback"
        return [{exe:"bad",args:""},{exe:"good",args:""}]
    candidates := [],seen := Map()
    AddCandidate(exe,args := "") {
        key := StrLower(exe " " args)
        if !seen.Has(key) {
            candidates.Push({exe:exe,args:args})
            seen[key] := true
        }
    }
    for exe in [A_ScriptDir "\.venv\Scripts\pythonw.exe",A_ScriptDir "\python\pythonw.exe"]
        if FileExist(exe)
            AddCandidate(exe)
    AddCandidate(VISION_PYTHON)
    ; A laptop may have several Python installations. The PATH default may
    ; not be the one with OpenCV, so test each available windowless runtime.
    root := EnvGet("LOCALAPPDATA") "\Programs\Python"
    Loop Files root "\*", "D" {
        exe := A_LoopFileFullPath "\pythonw.exe"
        if FileExist(exe)
            AddCandidate(exe)
    }
    AddCandidate("pyw.exe","-3")
    return candidates
}

VisionExec(command) {
    global fakeMode
    if fakeMode!="real"
        return FakeProcess(InStr(command,Chr(34) "bad" Chr(34)))
    return ComObject("WScript.Shell").Exec(command)
}

VisionProcessError(process,reply := "") {
    detail := Trim(reply)
    if process {
        try {
            if process.Status!=0 {
                errorText := Trim(process.StdErr.ReadAll())
                if errorText!=""
                    detail := errorText
            }
        }
    }
    detail := RegExReplace(detail,"[\r\n\t]+"," | ")
    return detail!=""?SubStr(detail,-1400):"process ended without a startup reply"
}

StartVisionProcess() {
    global gVision
    script := A_ScriptDir "\MinimapVision.py",q := Chr(34)
    if !FileExist(script) {
        Log("Vision startup failed: MinimapVision.py is missing from the macro folder.")
        return false
    }
    for candidate in VisionPythonCandidates() {
        process := 0,reply := ""
        try {
            command := q candidate.exe q (candidate.args!=""?" " candidate.args:"") " -I -u " q script q
            process := VisionExec(command)
            process.StdIn.WriteLine("ping")
            reply := process.StdOut.ReadLine()
            if SubStr(reply,1,3)="ok`t" {
                gVision := process
                Log("Python minimap vision ready: " candidate.exe)
                return true
            }
            Log("Vision startup: " candidate.exe ": " VisionProcessError(process,reply))
        } catch as err {
            Log("Vision startup: " candidate.exe ": " err.Message " | " VisionProcessError(process,reply))
        }
        if process {
            try {
                if process.Status=0
                    process.Terminate()
            }
        }
    }
    Log("No Python runtime could start minimap vision. Install the vision requirements using the laptop's Python, then restart the macro. See the startup errors above.")
    return false
}

ResetVisionFailure() {
    global gVisionFailed
    gVisionFailed := false
}

VisionRequest(line) {
    global gVision,gVisionFailed
    if gVisionFailed
        return false
    wasCritical := A_IsCritical
    Critical "On"
    try {
        if !gVision || gVision.Status!=0 {
            if !StartVisionProcess() {
                gVisionFailed := true
                return false
            }
        }
        gVision.StdIn.WriteLine(line)
        reply := gVision.StdOut.ReadLine()
        if reply=""
            throw Error(VisionProcessError(gVision))
    } catch as err {
        gVisionFailed := true
        Log("Python minimap vision unavailable (" err.Message "); using the AHK pixel reader.")
        return false
    } finally Critical wasCritical
    fields := Map("status",StrSplit(reply,"`t")[1])
    for part in StrSplit(reply,"`t") {
        if A_Index>1 && (equals := InStr(part,"="))
            fields[SubStr(part,1,equals-1)] := SubStr(part,equals+1)
    }
    if fields["status"]="fail"
        Log("Minimap vision: " (fields.Has("reason")?fields["reason"]:reply))
    return fields
}

VisionOk(reply) {
    return reply && reply["status"]="ok"
}

VisionClose(*) {
    global gVision
    if gVision && gVision.Status=0 {
        try gVision.StdIn.WriteLine("quit")
        Sleep 50
        try gVision.Terminate()
    }
    gVision := 0
}

try {
    Assert(VisionOk(VisionRequest("ping")),"Missing PATH default did not recover using another installed Python")
    VisionClose()
    fakeMode := "fallback",logs := [],gVisionFailed := false
    Assert(VisionOk(VisionRequest("ping")),"Import failure did not try the next runtime")
    Assert(InStr(logs[1],"No module named 'cv2'"),"Startup error discarded the missing dependency")
    VisionClose()
    fakeMode := "all-fail",logs := [],gVisionFailed := false
    Assert(!VisionRequest("ping") && gVisionFailed,"All failed runtimes did not report failure")
    before := logs.Length
    Assert(!VisionRequest("ping") && logs.Length=before,"Failed start was repeatedly retried inside the run")
    ResetVisionFailure(),fakeMode := "fallback"
    Assert(VisionOk(VisionRequest("ping")),"Starting again did not retry after setup was fixed")
    VisionClose()
    FileAppend "PASS: real installed-runtime recovery; dependency error preserved; failed default tries next runtime; failure latches per run; restarting retries.`n","*"
    ExitApp 0
} catch as err {
    FileAppend "FAIL: " err.Message " (line " err.Line ")`n","*"
    ExitApp 1
}
Assert(value,message) {
    if !value
        throw Error(message)
}
Log(message) {
    global logs
    logs.Push(message)
}
class FakeInput {
    WriteLine(*) => 0
}
class FakeOutput {
    __New(text) {
        this.text := text
    }
    ReadLine() => this.text
    ReadAll() => this.text
}
class FakeProcess {
    __New(bad) {
        this.Status := bad?1:0
        this.StdIn := FakeInput()
        this.StdOut := FakeOutput(bad?"":"ok`tready=1")
        this.StdErr := FakeOutput(bad?"ModuleNotFoundError: No module named 'cv2'":"")
    }
    Terminate() {
        this.Status := 1
    }
}

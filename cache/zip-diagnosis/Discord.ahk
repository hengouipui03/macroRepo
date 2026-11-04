; Discord match results: WIN or LOSS with a screenshot of Roblox, posted to the
; webhook saved in settings.ini when a match ends. MinimapVision.py sends it.
global SETTINGS_FILE := A_ScriptDir "\settings.ini"
global gWebhookEdit := 0, gWebhookEnabled := 0, gWebhookInfo := 0
global gMatchReported := false

BuildDiscordTab(app) {
    global gWebhookEdit,gWebhookEnabled,gWebhookInfo,SETTINGS_FILE
    app.AddText("x28 y140 w414", "Discord webhook URL — posts WIN or LOSS with a screenshot when a match ends.")
    gWebhookEdit := AddReadableEdit(app,"x28 y164 w414",MemoryRead("discord","webhook","",SETTINGS_FILE))
    gWebhookEnabled := app.AddCheckbox("x28 y198 w300" (MemoryRead("discord","enabled","1",SETTINGS_FILE)="1"?" Checked":""),"Post match results")
    app.AddButton("x28 y226 w120","Save").OnEvent("Click",SaveWebhook)
    app.AddButton("x160 y226 w150","Send test message").OnEvent("Click",TestWebhook)
    gWebhookInfo := app.AddText("x28 y266 w414 h40","")
    app.AddText("x28 y316 w414 h60","In Discord: Server Settings → Integrations → Webhooks → New Webhook → Copy Webhook URL, then paste it above and Save. The URL is kept only in settings.ini in this folder.")
}

IsWebhookUrl(url) {
    return RegExMatch(url,"^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+$")
}

SaveWebhook(*) {
    global gWebhookEdit,gWebhookEnabled,gWebhookInfo,SETTINGS_FILE
    url := Trim(gWebhookEdit.Value)
    if url!="" && !IsWebhookUrl(url) {
        gWebhookInfo.Value := "That is not a Discord webhook URL (https://discord.com/api/webhooks/...). Not saved."
        return
    }
    IniWrite url,SETTINGS_FILE,"discord","webhook"
    IniWrite gWebhookEnabled.Value?"1":"0",SETTINGS_FILE,"discord","enabled"
    gWebhookInfo.Value := url="" ? "Webhook cleared; no results will be posted." : "Saved. Results post " (gWebhookEnabled.Value?"after every match.":"only when enabled.")
}

TestWebhook(*) {
    global gWebhookEdit,gWebhookInfo
    url := Trim(gWebhookEdit.Value)
    if !IsWebhookUrl(url) {
        gWebhookInfo.Value := "Paste a Discord webhook URL first."
        return
    }
    gWebhookInfo.Value := "Sending test…"
    gWebhookInfo.Value := PostToWebhook(url,"AA Path Macro test message") ? "Test posted. Check the Discord channel." : "Test failed; see the Activity tab."
}

PostToWebhook(url,text) {
    if !FindRoblox() || !GetClient(&cx,&cy,&cw,&ch) {
        Log("Discord: Roblox is not open, so there is no screenshot to send.")
        return false
    }
    reply := VisionRequest("discord " cx " " cy " " cw " " ch " " url " " text)
    if !VisionOk(reply)
        return false
    Log('Discord: posted "' text '" with a screenshot.')
    return true
}

; Once per match: a defeat shows Next before Replay, so Replay without that
; Next is treated as a win. The screenshot shows the actual end screen.
ReportMatchResult(won) {
    global gMatchReported,SETTINGS_FILE
    if gMatchReported
        return
    gMatchReported := true
    url := MemoryRead("discord","webhook","",SETTINGS_FILE)
    if url="" || MemoryRead("discord","enabled","1",SETTINGS_FILE)!="1"
        return
    PostToWebhook(url,won?"Result: WIN":"Result: LOSS")
}

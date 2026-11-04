; Unit setup is separate from learned game data and Discord settings.
global UNIT_SETTINGS_FILE := A_ScriptDir "\unit_settings.ini"
global gUnitSettingsReady := false

SavedUnitNumber(slot, key, fallback, low, high) {
    global UNIT_SETTINGS_FILE
    try value := IniRead(UNIT_SETTINGS_FILE,"Unit" slot,key,fallback)
    catch
        return fallback
    return IsInteger(value) ? Max(low,Min(high,Integer(value))) : fallback
}

LoadUnitSettings(slot) {
    global UNIT_SETTINGS_FILE
    try name := IniRead(UNIT_SETTINGS_FILE,"Unit" slot,"name","Unit " slot)
    catch
        name := "Unit " slot
    return {enabled:SavedUnitNumber(slot,"enabled",1,0,1),hill:SavedUnitNumber(slot,"hill",0,0,1),hybrid:SavedUnitNumber(slot,"hybrid",0,0,1),name:name,
        count:SavedUnitNumber(slot,"count",1,0,30),
        priority:SavedUnitNumber(slot,"priority",slot,1,99),
        target:SavedUnitNumber(slot,"target",99,0,99)}
}

QueueUnitSettingsSave(*) {
    global gUnitSettingsReady
    if gUnitSettingsReady
        SetTimer SaveUnitSettings,-200
}

SaveUnitSettings(*) {
    global UNIT_SETTINGS_FILE,gUnitSettingsReady,gUnitControls
    if !gUnitSettingsReady || gUnitControls.Length!=6
        return false
    SetTimer SaveUnitSettings,0
    try {
        for unit in gUnitControls {
            section := "Unit" unit.slot
            IniWrite unit.enabled.Value,UNIT_SETTINGS_FILE,section,"enabled"
            if unit.HasProp("hill")
                IniWrite unit.hill.Value,UNIT_SETTINGS_FILE,section,"hill"
            if unit.HasProp("hybrid")
                IniWrite unit.hybrid.Value && !unit.hill.Value,UNIT_SETTINGS_FILE,section,"hybrid"
            IniWrite unit.name.Value,UNIT_SETTINGS_FILE,section,"name"
            for field,bounds in Map("count",[0,30],"priority",[1,99],"target",[0,99]) {
                value := unit.%field%.Value
                ; An empty edit while typing must not erase the last number.
                if IsInteger(value)
                    IniWrite Max(bounds[1],Min(bounds[2],Integer(value))),UNIT_SETTINGS_FILE,section,field
            }
        }
        return true
    } catch as err {
        Notify("Could not save unit settings: " err.Message)
        return false
    }
}

FlushUnitSettings(*) {
    SaveUnitSettings()
    return 0
}

UnitPlacementModeChanged(slot,mode,*) {
    global gUnitControls
    unit := gUnitControls[slot]
    if unit.%mode%.Value
        unit.%(mode="hill"?"hybrid":"hill")%.Value := 0
    QueueUnitSettingsSave()
}

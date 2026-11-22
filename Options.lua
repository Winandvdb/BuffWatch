-- Buff Sentinel: options panel (Esc > Options > AddOns > Buff Sentinel), its Buff list
-- page, and /bsent.
local _, ns = ...
local Print = ns.Print

local settingObjs = {}  -- key -> Settings setting, so slash commands stay in sync
local buffSettings = {} -- the Buff list's per-buff checkboxes (reset ticks them all again)
local mainCategory
local category, layout  -- the page the helpers below add to

local function OnSettingChanged()
    ns.ApplyLayout()
    ns.Update()
end

local function Register(key, varType, label)
    local setting = Settings.RegisterAddOnSetting(category, "BuffSentinel_" .. key, key,
        ns.db, varType, label, ns.DEFAULTS[key])
    setting:SetValueChangedCallback(OnSettingChanged)
    settingObjs[key] = setting
    return setting
end

local function AddCheckbox(key, label, tooltip)
    Settings.CreateCheckbox(category, Register(key, "boolean", label), tooltip)
end

local function AddSlider(key, label, tooltip, minValue, maxValue, step, formatter)
    local options = Settings.CreateSliderOptions(minValue, maxValue, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
    Settings.CreateSlider(category, Register(key, "number", label), options, tooltip)
end

local function GetModeOptions()
    local container = Settings.CreateControlTextContainer()
    for _, m in ipairs(ns.MODES) do container:Add(m[1], m[2]) end
    return container:GetData()
end

local function AddHeader(text)
    if layout and CreateSettingsListSectionHeaderInitializer then
        pcall(function() layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text)) end)
    end
end

-- One checkbox per buff name: ticked = it counts for its group (the default).
local function AddBuffCheckbox(cat, name)
    local key = ns.NameKey(cat, name)
    local var = "BuffSentinel_buff_" .. (key:gsub("[^%w]", "_"))
    local setting = Settings.RegisterAddOnSetting(category, var, key, ns.db.buffOn, "boolean", name, true)
    setting:SetValueChangedCallback(function()
        ns.RebuildTracked()
        ns.Update()
    end)
    Settings.CreateCheckbox(category, setting,
        string.format("Counts for %s. Untick it to ignore this buff (for example to require one particular elixir).", cat.label))
    buffSettings[#buffSettings + 1] = setting
end

-- The Buff list: every group for your class, when to track it, and which of its buffs count.
local function BuildBuffList()
    local _, class = UnitClass("player")
    for _, cat in ipairs(ns.CATEGORIES) do
        if ns.CategoryForClass(cat, class) then
            AddHeader(cat.label)
            local tip = cat.tip or cat.label
            if cat.self then tip = tip .. "\n\nOnly tracked once you know the spell." end
            if cat.items then tip = tip .. "\n\nOnly tracked while you carry the item." end
            Settings.CreateDropdown(category, Register("mode_" .. cat.key, "string", "When to track"), GetModeOptions, tip)
            local names = ns.CategoryNames(cat, class)
            if not cat.noPicker and #names > 1 then
                for _, name in ipairs(names) do AddBuffCheckbox(cat, name) end
            end
        end
    end
end

function ns.CreateOptions()
    if mainCategory or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
    local ok, err = pcall(function()
        mainCategory, layout = Settings.RegisterVerticalLayoutCategory("Buff Sentinel")
        category = mainCategory
        AddHeader("Warnings")
        AddSlider("warnMin", "Warn before it runs out",
            "Warn, and show the bar, when a buff has less than this many minutes left.",
            1, 30, 1, function(v) return string.format("%d min", v) end)
        AddSlider("chargeWarn", "Poison charge warning",
            "Warn when a rogue poison has fewer than this many charges left.",
            1, 100, 1, function(v) return string.format("%d", v) end)
        AddCheckbox("sound", "Warning sound", "Play a sound with each warning.")
        AddCheckbox("raidWarning", "Center-screen warning", "Show warnings as big text in the middle of the screen.")
        AddCheckbox("chat", "Chat warning", "Also print warnings in the chat window.")
        AddCheckbox("combatCheck", "Check when entering combat",
            "Entering combat: warn about a missing weapon poison/enchant, and inside dungeons and raids about missing buffs (at most once a minute).")
        AddCheckbox("quietInCombat", "Hold warnings during combat",
            "During a fight, 'running out' and 'worn off' warnings wait, and buff bars are hidden (weapon poison / enchant bars stay). A second after combat ends you get one warning with what still matters, for example 'After combat: Well Fed has worn off, Blessing of Might: 1:30 left'.")
        AddCheckbox("instanceCheck", "Check when entering a dungeon or raid", "List what's missing a few seconds after you zone in.")
        AddCheckbox("readyCheck", "Check on ready checks", "List what's missing, and what runs out within 10 minutes, when a ready check starts.")

        AddHeader("Display")
        AddCheckbox("onlyWhenNeeded", "Only show when needed",
            "Hide the bars of buffs that are fine. A bar appears when a buff is missing or below the warning time. While this panel is open, or the frame is unlocked, all bars are shown.")
        AddCheckbox("showMissing", "Show missing buffs", "Show a red bar for each tracked buff you don't have.")
        AddCheckbox("clickable", "Click a bar to fix it",
            "Out of combat, click a bar to fix it when it's clear what to do: cast your own buff on yourself (armors, Inner Fire, Aspects, tracking, your class's blessing, Fortitude ...), use the sleeping bag or Elemental Attractor / Arcane Censer, equip the Argent Dawn Commission, or put the poison or oil that was on a weapon back on (if it's in your bags). Hover a bar to see what a click does. Food, flasks and elixirs aren't clickable (Buff Sentinel can't know which one you want). During combat bars can't be clicked.")
        AddCheckbox("sleepTimer", "Sleeping bag timer",
            "While you sleep in the Cozy Sleeping Bag: how long you've slept, your stacks and a countdown to the next stack. The countdown learns the time between stacks from what it sees (shows 'learning' until then). At 3/3 stacks it shows how long Well-Rested lasts, as sleeping now refreshes it. Getting up (no longer resting) or combat ends the timer.")
        AddCheckbox("locked", "Lock frame", "Unlock to drag the frame somewhere else (all bars are shown while unlocked).")
        AddSlider("scale", "Scale", "Size of the frame.", 0.5, 2, 0.05,
            function(v) return string.format("%d%%", v * 100 + 0.5) end)
        AddSlider("width", "Width", "Width of the frame in pixels.", 140, 400, 10,
            function(v) return string.format("%d px", v) end)

        -- the Buff list on its own page (or below, if this client has no sub-pages)
        if Settings.RegisterVerticalLayoutSubcategory then
            local sub, subLayout = Settings.RegisterVerticalLayoutSubcategory(mainCategory, "Buff list")
            if sub then category, layout = sub, subLayout end
        end
        if category == mainCategory then AddHeader("Buff list") end
        BuildBuffList()
        category = mainCategory

        Settings.RegisterAddOnCategory(mainCategory)
    end)
    if not ok then
        mainCategory = nil
        Print("|cffff5555could not create the options panel:|r " .. tostring(err))
    end
end

local function OpenOptions()
    if mainCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(mainCategory:GetID())
        return true
    end
    return false
end

local function SetOption(key, value)
    if settingObjs[key] then
        settingObjs[key]:SetValue(value) -- runs OnSettingChanged
    else
        ns.db[key] = value
        OnSettingChanged()
    end
end
ns.SetOption = SetOption -- (Alt+Right-click on a bar: keeps the options panel in sync)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function GroupKeys()
    local _, class = UnitClass("player")
    local keys = {}
    for _, cat in ipairs(ns.CATEGORIES) do
        if not cat.weapon and ns.CategoryForClass(cat, class) then keys[#keys + 1] = cat.key end
    end
    return table.concat(keys, ", ")
end

local function ShowHelp()
    Print("commands (or Esc > Options > AddOns > Buff Sentinel):")
    print("  /bsent options         - open the options panel")
    print("  /bsent lock | unlock   - lock/unlock the frame (drag to move when unlocked)")
    print("  /bsent test            - preview bars and the sleep timer (time runs x20)")
    print("  /bsent status          - what is tracked here and now, and the learned sleep timings")
    print("  /bsent auras           - list your buffs with spell IDs (out of combat)")
    print("  /bsent add <group> <buff name or spell ID>    - count another buff for a group")
    print("  /bsent remove <group> <buff name or spell ID> - undo that")
    print("     groups: " .. GroupKeys())
    print("  /bsent here <group>    - only track that group in the dungeon/raid you're in (again to undo)")
    print("  /bsent undo            - track the group you last hid (Alt+Right-click on a bar hides a group)")
    print("  /bsent sleepreset      - forget the learned sleeping bag stack timings")
    print("  /bsent castlog         - for 2 min, print casts, buffs, resting and the bag (to debug the sleep timer)")
    print("  /bsent weapons         - what the game reports for your weapon enchants")
    print("  /bsent reset           - reset position and settings (added buff names are kept)")
end

SLASH_BUFFSENTINEL1 = "/bsent"
SLASH_BUFFSENTINEL2 = "/buffsentinel"
SlashCmdList.BUFFSENTINEL = function(msg)
    if not ns.db then return end
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "options" or cmd == "config" or cmd == "" then
        if cmd == "" then ShowHelp() end
        OpenOptions()
    elseif cmd == "lock" then
        SetOption("locked", true); Print("frame locked.")
    elseif cmd == "unlock" then
        SetOption("locked", false); Print("frame unlocked: all bars shown, drag to move. /bsent lock when done.")
    elseif cmd == "test" then
        ns.SetTest(not ns.IsTest())
        Print(ns.IsTest() and "test mode ON. /bsent test again to stop." or "test mode OFF.")
    elseif cmd == "status" then
        ns.Status()
    elseif cmd == "undo" then
        ns.UndoHide()
    elseif cmd == "auras" or cmd == "buffs" then
        ns.ListAuras()
    elseif cmd == "add" or cmd == "remove" then
        local key, value = rest:match("^(%S+)%s+(.+)$")
        key = key and key:lower()
        if not key or not ns.CATEGORY_BY_KEY[key] or ns.CATEGORY_BY_KEY[key].weapon then
            Print("usage: /bsent " .. cmd .. " <group> <buff name or spell ID>; groups: " .. GroupKeys())
            return
        end
        if cmd == "add" then
            ns.AddName(key, value)
            Print(string.format("%s now also counts for %s.", value, ns.CATEGORY_BY_KEY[key].label))
        else
            ns.RemoveName(key, value)
            Print(string.format("%s removed from %s.", value, ns.CATEGORY_BY_KEY[key].label))
        end
    elseif cmd == "here" then
        local key = rest:lower()
        local cat = ns.CATEGORY_BY_KEY[key]
        if not cat then
            Print("usage: /bsent here <group>; groups: " .. GroupKeys())
            return
        end
        local result, name = ns.ToggleHere(key)
        if not result then
            Print("you're not in a dungeon or raid.")
            return
        end
        local list = ns.HereList(key)
        Print(string.format("%s %s %s. %s is now tracked in: %s", cat.label,
            result == "added" and "will be tracked in" or "no longer limited to", name, cat.label,
            list ~= "" and list or "every dungeon and raid (its usual setting)"))
        ns.Update()
    elseif cmd == "castlog" or cmd == "log" then
        if ns.ToggleCastLog() then
            Print("logging for 2 minutes: put the sleeping bag down, lie in it, wait for a stack. /bsent castlog again to stop.")
        end
    elseif cmd == "sleepreset" then
        ns.g.sleepFirst, ns.g.sleepInterval = nil, nil
        Print("sleeping bag timings forgotten; they are learned again on your next sleep.")
    elseif cmd == "weapons" or cmd == "debug" then
        ns.WeaponsDebug()
    elseif cmd == "reset" then
        ns.ResetSettings()
        for key, setting in pairs(settingObjs) do
            pcall(setting.SetValue, setting, ns.db[key])
        end
        for _, setting in ipairs(buffSettings) do pcall(setting.SetValue, setting, true) end
        OnSettingChanged()
        Print("settings reset.")
    else
        ShowHelp()
    end
end

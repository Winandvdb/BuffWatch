-- BuffWatch: temporary weapon enchants (rogue poisons, stones, oils) per hand.
-- Ported from PoisonWatch: the precise time comes from the API, the name and
-- charges from each weapon's own tooltip (the only per-weapon source for them).
local _, ns = ...
local Readable, Num = ns.Readable, ns.Num

local W = {}
ns.Weapons = W

W.SLOTS = {
    { key = "mh", label = "Main Hand", short = "MH", invSlot = 16 },
    { key = "oh", label = "Off Hand",  short = "OH", invSlot = 17 },
}

---------------------------------------------------------------------------
-- Tooltip reading
---------------------------------------------------------------------------
local scanTip = CreateFrame("GameTooltip", "BuffWatchScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

function W.GetTooltipLines(invSlot)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
        local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", invSlot)
        if ok and type(data) == "table" and data.lines then
            for _, line in ipairs(data.lines) do
                local text = line.leftText
                if Readable(text) and type(text) == "string" then lines[#lines + 1] = text end
            end
            return lines
        end
    end
    -- fallback: classic hidden-tooltip scan
    scanTip:ClearLines()
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    local ok = pcall(scanTip.SetInventoryItem, scanTip, "player", invSlot)
    if ok then
        for i = 1, scanTip:NumLines() do
            local fs = _G["BuffWatchScanTipTextLeft" .. i]
            local text = fs and fs:GetText()
            if Readable(text) then lines[#lines + 1] = text end
        end
    end
    scanTip:Hide()
    return lines
end

local UNIT_SECONDS = { sec = 1, second = 1, seconds = 1, min = 60, mins = 60, minute = 60, minutes = 60,
                       hr = 3600, hour = 3600, hours = 3600, day = 86400, days = 86400 }

-- drop colour codes and resolve plural codes like "|4Charge:Charges;"
local function CleanText(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("|4[^:;]*:([^;]*);", "%1")
    return text
end

-- name, charges, seconds (coarse) of the temporary enchant on that weapon, or nil.
-- The line looks like "Instant Poison IV (30 min) (130 Charges)".
function W.ReadTooltipEnchant(invSlot)
    local lines = W.GetTooltipLines(invSlot)
    for i = 2, #lines do
        local text = CleanText(lines[i])
        local lower = text:lower()
        local charges = tonumber(lower:match("(%d+)%s*charges?"))
        local seconds
        for n, unit in lower:gmatch("%((%d+)%s*(%a+)%.?%)") do
            if UNIT_SECONDS[unit] then
                seconds = tonumber(n) * UNIT_SECONDS[unit]
                break
            end
        end
        if charges or seconds then
            local name = text:match("^(.-)%s*%(") or "Enchant"
            if name == "" then name = "Enchant" end
            return name, charges, seconds
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- API reading
---------------------------------------------------------------------------
-- has (true/false/nil = unknown), ms, charges
local function ReadLegacyAPI(info)
    if not GetWeaponEnchantInfo then return nil end
    local ok, hasMH, mhMs, mhCh, _, hasOH, ohMs, ohCh = pcall(GetWeaponEnchantInfo)
    if not ok then return nil end
    local has, ms, ch
    if info.key == "mh" then has, ms, ch = hasMH, mhMs, mhCh else has, ms, ch = hasOH, ohMs, ohCh end
    if Readable(has) then
        has = has and true or false
    else
        has = nil
    end
    return has, Num(ms), Num(ch)
end

function W.ReadSlotAPI(info)
    if C_PaperDollInfo and C_PaperDollInfo.GetTemporaryEnchantmentInfo then
        local ok, e = pcall(C_PaperDollInfo.GetTemporaryEnchantmentInfo, info.invSlot)
        if ok then
            if e == nil then return false end
            if type(e) == "table" then
                local ch = Num(e.charges)
                if not ch or ch == 0 then
                    local _, _, legacyCh = ReadLegacyAPI(info)
                    ch = legacyCh
                end
                return true, Num(e.remainingTimeMs), ch
            end
        end
    end
    return ReadLegacyAPI(info)
end

-- per-slot cache: last readable values, so secret/unreadable moments keep working
local cache = { mh = {}, oh = {} }
local TOOLTIP_INTERVAL = 0.5

function W.ResetCache()
    cache.mh, cache.oh = {}, {}
end

function W.TooltipChanged()
    cache.mh.tipAt, cache.oh.tipAt = nil, nil
end

-- { has, remaining (sec), charges, name } for one hand
function W.ReadSlot(info, now)
    local c = cache[info.key]
    local apiHas, apiMs, apiCharges = W.ReadSlotAPI(info)

    if not c.tipAt or now - c.tipAt >= TOOLTIP_INTERVAL or (apiHas == false and c.tipName) then
        c.tipAt = now
        local n, ch, sec = W.ReadTooltipEnchant(info.invSlot)
        if n or apiHas == false then
            c.tipName, c.tipCharges, c.tipSeconds = n, ch, sec
        end
    end

    local has
    if apiHas ~= nil then has = apiHas or (c.tipName ~= nil) else has = (c.tipName ~= nil) end

    if not has then
        c.expiresAt, c.charges = nil, nil
        return { has = false, remaining = 0, charges = 0 }
    end

    if apiMs and apiMs > 0 then
        c.expiresAt = now + apiMs / 1000
    elseif c.tipSeconds and (not c.expiresAt or math.abs((c.expiresAt - now) - c.tipSeconds) > 60) then
        c.expiresAt = now + c.tipSeconds
    end
    local remaining = c.expiresAt and math.max(0, c.expiresAt - now) or 0

    local charges = c.tipCharges or apiCharges or c.charges or 0
    c.charges = charges

    return { has = true, remaining = remaining, charges = charges, name = c.tipName or "Enchant" }
end

-- Is there a weapon in that slot (shields and off-hand items don't count)?
function W.HasWeapon(invSlot)
    local link = GetInventoryItemLink("player", invSlot)
    if not Readable(link) or not link then return false end
    if invSlot == 17 then
        local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        local equipLoc
        if getInstant then
            local ok, _, _, _, loc = pcall(getInstant, link)
            if ok and Readable(loc) then equipLoc = loc end
        end
        if not equipLoc then
            local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            if getInfo then
                local ok, _, _, _, _, _, _, _, _, loc = pcall(getInfo, link)
                if ok and Readable(loc) then equipLoc = loc end
            end
        end
        if equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then return false end
    end
    return true
end

-- /bwatch weapons: what the game reports for each hand
function W.Debug()
    for _, info in ipairs(W.SLOTS) do
        local has, ms, ch = W.ReadSlotAPI(info)
        ns.Print(string.format("%s API: has=%s ms=%s charges=%s", info.label, tostring(has), tostring(ms), tostring(ch)))
        local n, tch, sec = W.ReadTooltipEnchant(info.invSlot)
        ns.Print(string.format("%s tooltip: %s, charges=%s, seconds=%s", info.label, tostring(n), tostring(tch), tostring(sec)))
        ns.Print(string.format("%s weapon detected: %s", info.label, tostring(W.HasWeapon(info.invSlot))))
    end
end

-- BuffWatch core: reads your buffs, decides what matters right now (leveling,
-- dungeon, raid), warns before things run out and shows a bar per buff that
-- is missing or low. Also times your sleep in the Cozy Sleeping Bag.
local _, ns = ...
local Readable, Num, Print, FormatTime = ns.Readable, ns.Num, ns.Print, ns.FormatTime
local W = ns.Weapons

local BW = CreateFrame("Frame", "BuffWatchFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
ns.frame = BW

ns.DEFAULTS = {
    warnMin        = 3,     -- minutes: warn when less than this remains
    chargeWarn     = 20,    -- poisons: warn when charges drop below this
    sound          = true,
    raidWarning    = true,  -- big center-screen text
    chat           = true,
    combatCheck    = true,  -- entering combat: warn about missing weapon enchants (and buffs in instances)
    instanceCheck  = true,  -- entering a dungeon/raid: list what's missing
    readyCheck     = true,  -- ready check: list what's missing or low
    showMissing    = true,  -- show a bar for buffs that are missing
    onlyWhenNeeded = true,  -- hide bars of buffs that are fine
    sleepTimer     = true,
    locked         = true,  -- unlocked = all bars shown so the frame can be placed
    scale          = 1,
    width          = 230,
    point          = { "CENTER", "UIParent", "CENTER", 0, -140 },
}
-- "mode_<key>" defaults are added per class at login

local db            -- this character's settings (BuffWatchDB)
local g             -- shared by all characters (BuffWatchGlobal): added names/IDs, learned IDs, sleep timings
local playerClass
local state = {}    -- group key -> { has, expires, permanent, maxTime, icon, name, stacks, had, lastRem, warnedLow }
local wstate = { mh = {}, oh = {} }
local nameToCat = {} -- lower-case buff name -> group key (this class's groups)
local idToCat = {}   -- buff spell ID -> group key (ids fields and IDs you added)
local anyName = {}   -- lower-case names of every group for every class (never learned as the bag's buff)
local containsList = {} -- { part, key }: name parts (the `contains` field), checked after exact names
local knownNames = {}   -- self groups: the names of theirs you know as spells
local tracked = {}  -- groups that apply to you now (class + known spell)
local testMode, testStart = false, 0
local scanDirty, lastScan, scannedOnce = true, 0, false
local lastCombatWarn = 0
local sleep         -- active sleeping session { start, lastGainAt, gains, resumed }
local bagSnapshot   -- buff names on you when the bag was used (to learn its buff)
ns.quietUntil = 0

for _, cat in ipairs(ns.CATEGORIES) do state[cat.key] = {} end

---------------------------------------------------------------------------
-- Warnings
---------------------------------------------------------------------------
local function PlayWarnSound()
    if not db.sound then return end
    if SOUNDKIT and SOUNDKIT.RAID_WARNING then
        PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    else
        PlaySound(8959, "Master")
    end
end

function ns.Warn(msg)
    if db.raidWarning and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
    end
    if db.chat then Print("|cffff5555" .. msg .. "|r") end
    PlayWarnSound()
end

local function IsDead()
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    return ok and Readable(dead) and dead and true or false
end

---------------------------------------------------------------------------
-- Game info (all guarded: a missing or secret value never breaks anything)
---------------------------------------------------------------------------
local function ItemCount(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not fn then return 0 end
    local ok, n = pcall(fn, id)
    return ok and Num(n) or 0
end

-- seconds until the item can be used again (0 = ready), nil = unknown
local function ItemCooldown(id)
    local fn = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
    if not fn then return nil end
    local ok, start, dur = pcall(fn, id)
    if not ok then return nil end
    start, dur = Num(start), Num(dur)
    if not start or not dur then return nil end
    if start > 0 and dur > 1.5 then return math.max(0, start + dur - GetTime()) end
    return 0
end

-- the first of the group's items you carry, or nil
function ns.OwnedItem(cat)
    for _, id in ipairs(cat.items or {}) do
        if ItemCount(id) > 0 then return id end
    end
    return nil
end

local function ItemIcon(id)
    local fn = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
    if not fn then return nil end
    local ok, icon = pcall(fn, id)
    return ok and Readable(icon) and icon or nil
end

local function CanGainXP()
    if IsXPUserDisabled then
        local ok, off = pcall(IsXPUserDisabled)
        if ok and Readable(off) and off then return false end
    end
    -- (a fixed cap: on Forever's modern client the expansion max-level APIs
    -- may not report Classic's 60)
    local lvl = Num(UnitLevel("player")) or 1
    return lvl < ns.MAX_LEVEL
end

local function GetContext()
    local ok, _, itype = pcall(IsInInstance)
    if not ok or not Readable(itype) then itype = nil end
    local instanceID
    if itype == "party" or itype == "raid" then
        local ok2, _, _, _, _, _, _, _, id = pcall(GetInstanceInfo)
        instanceID = ok2 and Num(id) or nil
    end
    return { leveling = CanGainXP(), dungeon = itype == "party", raid = itype == "raid", instanceID = instanceID }
end
ns.GetContext = GetContext

local function ModeOn(mode, ctx)
    if mode == "always" then return true
    elseif mode == "leveling" then return ctx.leveling
    elseif mode == "leveling_instances" then return ctx.leveling or ctx.dungeon or ctx.raid
    elseif mode == "instances" then return ctx.dungeon or ctx.raid
    elseif mode == "raids" then return ctx.raid
    elseif mode == "world" then return not (ctx.dungeon or ctx.raid)
    end
    return false
end

local function CatOn(cat, ctx)
    if not tracked[cat.key] then return false end
    if cat.weapon and ns.weaponOff then return false end
    -- limited to certain instances (the instances field, plus /bwatch here)?
    local fixed, mine = cat.instances, g.instances[cat.key]
    if (fixed and #fixed > 0) or (mine and next(mine)) then
        local id = ctx.instanceID
        local ok = id and mine and mine[id]
        if not ok and id and fixed then
            for _, v in ipairs(fixed) do if v == id then ok = true break end end
        end
        if not ok then return false end
    end
    return ModeOn(db["mode_" .. cat.key], ctx) and true or false
end
ns.CatOn = CatOn

-- classes in your group, refreshed at most every 3 s
local giverCache, giverAt = {}, -10
local function GiverPresent(class)
    if class == playerClass then return true end
    local now = GetTime()
    if now - giverAt > 3 then
        giverAt = now
        wipe(giverCache)
        local n = Num(GetNumGroupMembers and GetNumGroupMembers()) or 0
        local raid = IsInRaid and IsInRaid()
        if not Readable(raid) then raid = false end
        for i = 1, n do
            local u = raid and ("raid" .. i) or ("party" .. i)
            if UnitExists(u) then
                local _, c = UnitClass(u)
                if Readable(c) and c then giverCache[c] = true end
            end
        end
    end
    return giverCache[class] == true
end
function ns.ResetGivers() giverAt = -10 end

-- Is the buff worth reporting as missing right now?
local function MissingCounts(cat)
    if cat.items and not ns.OwnedItem(cat) then return false end
    if cat.manaOnly and not ns.MANA_CLASSES[playerClass] then return false end
    if cat.giver and not GiverPresent(cat.giver) then return false end
    return true
end

-- Do you know this spell as a castable (non-passive) spell?
local function KnowsSpell(name)
    if not (C_Spell and C_Spell.GetSpellInfo) then return false end
    local ok, info = pcall(C_Spell.GetSpellInfo, name)
    if not ok or type(info) ~= "table" then return false end
    local id = Num(info.spellID)
    if not id then return false end
    local known
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok2, k = pcall(C_SpellBook.IsSpellKnown, id)
        if ok2 and Readable(k) then known = k end
    end
    if known == nil and IsSpellKnown then
        local ok2, k = pcall(IsSpellKnown, id)
        if ok2 and Readable(k) then known = k end
    end
    -- granted spells can read as not known; a spellbook slot counts too
    if not known and C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell then
        local ok2, slot = pcall(C_SpellBook.FindSpellBookSlotForSpell, id, false, false, false)
        if ok2 and Readable(slot) and slot then known = true end
    end
    if not known then return false end
    local passive
    if C_Spell.IsSpellPassive then
        local ok2, p = pcall(C_Spell.IsSpellPassive, id)
        if ok2 and Readable(p) then passive = p end
    end
    return passive ~= true
end

-- Is this buff ticked in the Buff list? (stored only when unticked: new buffs are on)
function ns.NameKey(cat, name) return cat.key .. ":" .. name end
function ns.NameOn(cat, name)
    return not (db and db.buffOn and db.buffOn[ns.NameKey(cat, name)] == false)
end

-- Which groups apply to you (class, known spells), and the name/ID lookups.
function ns.RebuildTracked()
    wipe(tracked)
    wipe(nameToCat)
    wipe(idToCat)
    wipe(anyName)
    wipe(containsList)
    wipe(knownNames)
    for _, cat in ipairs(ns.CATEGORIES) do
        if ns.CategoryForClass(cat, playerClass) then
            for _, part in ipairs(cat.contains or {}) do
                containsList[#containsList + 1] = { part:lower(), cat.key }
            end
        end
        for _, n in ipairs(cat.names or {}) do anyName[n:lower()] = true end
        for _, set in pairs(cat.nameSets or {}) do
            for _, n in ipairs(set) do anyName[n:lower()] = true end
        end
        if ns.CategoryForClass(cat, playerClass) then
            for _, id in ipairs(cat.ids or {}) do idToCat[id] = cat.key end
            for v in pairs(g.extra[cat.key] or {}) do
                if type(v) == "number" then idToCat[v] = cat.key end
            end
            -- the names ticked in the Buff list (all of them by default)
            local names = {}
            for _, n in ipairs(ns.CategoryNames(cat, playerClass)) do
                if ns.NameOn(cat, n) then names[#names + 1] = n end
            end
            local on = true
            if cat.self then
                local known = {}
                for _, n in ipairs(names) do
                    if KnowsSpell(n) then known[#known + 1] = n end
                end
                knownNames[cat.key] = known
                on = #known > 0
            end
            tracked[cat.key] = on
            for _, n in ipairs(names) do nameToCat[n:lower()] = nameToCat[n:lower()] or cat.key end
            for v in pairs(g.extra[cat.key] or {}) do
                if type(v) == "string" then
                    nameToCat[v:lower()] = cat.key
                    anyName[v:lower()] = true
                end
            end
        end
    end
    scanDirty = true
end

function ns.IsTracked(key) return tracked[key] end

-- What a missing group is called on its bar: the buff you had last ("Find
-- Minerals", "Blessing of Might"), else the spells of it you know, else the
-- group's name.
local function MissingLabel(cat, s)
    if s.name then return s.name end
    local known = knownNames[cat.key]
    if known and #known > 0 then return table.concat(known, " / ", 1, math.min(#known, 2)) end
    return cat.label
end

local function SpellIcon(name)
    if not (name and C_Spell and C_Spell.GetSpellTexture) then return nil end
    local ok, icon = pcall(C_Spell.GetSpellTexture, name)
    return ok and Readable(icon) and icon or nil
end

local function MissingIcon(cat, s)
    if s.icon then return s.icon end
    local known = knownNames[cat.key]
    return SpellIcon(s.name or (known and known[1])) or cat.icon
end

-- Which group a buff belongs to: a listed spell ID, then exact name, then name
-- part. A spell ID learned from an earlier name match is only used when the
-- name can't be read (combat), so unticking a buff in the Buff list, or a
-- changed name list, takes effect even for buffs seen before.
local function KeyFor(name, id)
    local key = id and idToCat[id]
    if key then return key end
    if not name then return id and g.learned[id] or nil end
    local lower = name:lower()
    key = nameToCat[lower]
    if key then return key end
    for _, c in ipairs(containsList) do
        if lower:find(c[1], 1, true) then return c[2] end
    end
    return nil
end

---------------------------------------------------------------------------
-- Sleeping bag: its spell, learning its buff, the sleep timer
---------------------------------------------------------------------------
local function LoadBagSpell()
    if ns.bagSpellName then return end
    local fn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not fn then return end
    local ok, name, id = pcall(fn, ns.SLEEPING_BAG_ITEM)
    if ok and Readable(name) and type(name) == "string" then
        ns.bagSpellName = name
        ns.bagSpellID = Num(id)
    elseif C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, ns.SLEEPING_BAG_ITEM)
    end
end

local function IsBagSpell(spellID)
    spellID = Num(spellID)
    if not spellID then return false end
    if ns.bagSpellID and spellID == ns.bagSpellID then return true end
    if ItemCount(ns.SLEEPING_BAG_ITEM) == 0 then return false end -- (no bag: not worth looking up)
    LoadBagSpell()
    if ns.bagSpellID and spellID == ns.bagSpellID then return true end
    if ns.bagSpellName and C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        local n = ok and type(info) == "table" and info.name
        if Readable(n) and n == ns.bagSpellName then return true end
    end
    return false
end

local function StopSleep() sleep = nil end

-- Are you in a rested area (an inn, a city, or the sleeping bag's own)? You
-- can't be sleeping in the bag outside one. (Unknown = no.)
local function IsResting_()
    if not IsResting then return false end
    local ok, r = pcall(IsResting)
    return ok and Readable(r) and r and true or false
end
ns.StopSleep = StopSleep

local function Average(old, v)
    if not old then return v end
    return (old + v) / 2
end

-- A new stack (or a refresh) of the sleeping bag buff: learn the timings.
local function OnSleepStack(now)
    if not sleep then
        -- already asleep before a /reload, or the bag wasn't seen being used
        sleep = { start = now, lastGainAt = now, gains = 1, resumed = true }
        return
    end
    local v
    if sleep.lastGainAt then
        v = now - sleep.lastGainAt
        if v >= 5 and v <= 7200 then g.sleepInterval = Average(g.sleepInterval, v) end
    elseif not sleep.resumed then
        v = now - sleep.start
        if v >= 5 and v <= 7200 then g.sleepFirst = Average(g.sleepFirst, v) end
    end
    sleep.lastGainAt = now
    sleep.gains = sleep.gains + 1
end

-- seconds until the next stack, and the full wait (nil = not learned yet)
local function SleepNext(now)
    if not sleep then return nil end
    local base, wait
    if sleep.lastGainAt then
        base, wait = sleep.lastGainAt, g.sleepInterval or g.sleepFirst
    else
        base, wait = sleep.start, g.sleepFirst or g.sleepInterval
    end
    if not wait then return nil end
    return math.max(0, base + wait - now), wait, now - base
end

local function CurrentBuffNames()
    local names = {}
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return names end
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or type(a) ~= "table" then break end
        if Readable(a.name) and type(a.name) == "string" then names[a.name] = true end
    end
    return names
end

local function OnBagUsed()
    local now = GetTime()
    if sleep and not sleep.resumed and now - sleep.start < 3 then return end -- (channel start + succeeded)
    ns.bagUsedAt = now
    bagSnapshot = CurrentBuffNames()
    if db.sleepTimer then
        sleep = { start = now, gains = 0 }
    end
    scanDirty = true
end

---------------------------------------------------------------------------
-- Buff scan
---------------------------------------------------------------------------
local function ScanAuras(now)
    local found, complete = {}, true
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return found, false end
    if bagSnapshot and ns.bagUsedAt and now - ns.bagUsedAt > 600 then bagSnapshot = nil end
    local candidates
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or type(a) ~= "table" then break end
        local name = Readable(a.name) and type(a.name) == "string" and a.name or nil
        local id = Num(a.spellId)
        if not name and not id then complete = false end
        local key = KeyFor(name, id)
        if key and state[key] and not (ns.CATEGORY_BY_KEY[key] or {}).weapon then
            -- remember the ID of a name match, so it still counts if only the ID is readable
            if id and name and not idToCat[id] then g.learned[id] = key end
            local exp, dur = Num(a.expirationTime), Num(a.duration)
            local rem
            if exp then rem = (exp == 0) and math.huge or (exp - now) end
            local f = found[key]
            if not f or (rem and (not f.rem or rem > f.rem)) then
                found[key] = { rem = rem, exp = exp, dur = dur, name = name,
                               icon = Readable(a.icon) and a.icon or nil, stacks = Num(a.applications) }
            end
        elseif name and bagSnapshot and not bagSnapshot[name] and not anyName[name:lower()] then
            -- a new, longer buff right after using the bag, not cast by someone
            -- else and not one of our known buffs: maybe the bag's own buff
            local dur = Num(a.duration)
            local src = Readable(a.sourceUnit) and a.sourceUnit or nil
            local fromOther = src and src ~= "player"
            if dur and (dur == 0 or dur >= 300) and not fromOther then
                candidates = candidates or {}
                candidates[#candidates + 1] = name
            end
        end
    end
    if candidates and #candidates == 1 and not found.sleep then
        local name = candidates[1]
        g.extra.sleep = g.extra.sleep or {}
        g.extra.sleep[name] = true
        bagSnapshot = nil
        ns.RebuildTracked()
        Print(string.format("learned the sleeping bag buff: |cffffff00%s|r. (Wrong? /bwatch remove sleep %s)", name, name))
    end
    if found.sleep then bagSnapshot = nil end
    return found, complete
end

-- Names of the minimap tracking types that are on (lower case). Tries the
-- modern C_Minimap API, the older globals, and finally the classic single
-- tracking icon compared to each spell's icon.
local function ActiveTracking(cat)
    local active = {}
    local numFn = (C_Minimap and C_Minimap.GetNumTrackingTypes) or GetNumTrackingTypes
    local infoFn = (C_Minimap and C_Minimap.GetTrackingInfo) or GetTrackingInfo
    if numFn and infoFn then
        local ok, n = pcall(numFn)
        n = ok and Num(n) or 0
        for i = 1, n do
            local ok2, a, _, c = pcall(infoFn, i)
            if ok2 then
                local name, on
                if type(a) == "table" then name, on = a.name, a.active else name, on = a, c end
                if Readable(name) and type(name) == "string" and Readable(on) and on then
                    active[name:lower()] = { icon = type(a) == "table" and Readable(a.texture) and a.texture or nil }
                end
            end
        end
    end
    if GetTrackingTexture and C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(GetTrackingTexture)
        if ok and Readable(tex) and tex then
            for _, n in ipairs(ns.CategoryNames(cat, playerClass)) do
                local ok2, icon = pcall(C_Spell.GetSpellTexture, n)
                if ok2 and Readable(icon) and icon and icon == tex then active[n:lower()] = { icon = tex } end
            end
        end
    end
    return active
end

-- Tracking groups: a tracking type that's on counts like a buff without a time limit.
local function AddTracking(found)
    for _, cat in ipairs(ns.CATEGORIES) do
        if cat.tracking and tracked[cat.key] and not found[cat.key] then
            local active = ActiveTracking(cat)
            for _, n in ipairs(ns.CategoryNames(cat, playerClass)) do
                local hit = ns.NameOn(cat, n) and active[n:lower()]
                if hit then
                    found[cat.key] = { exp = 0, rem = math.huge, name = n, icon = hit.icon }
                    break
                end
            end
        end
    end
end

local function UpdateBuffState(now)
    local found, complete = ScanAuras(now)
    AddTracking(found)
    for _, cat in ipairs(ns.CATEGORIES) do
        if not cat.weapon then
            local s, f = state[cat.key], found[cat.key]
            if f then
                local wasHas, prevStacks = s.has, (s.has and s.stacks) or 0
                s.has = true
                if f.exp == 0 then
                    s.permanent, s.expires = true, nil
                elseif f.exp then
                    s.permanent, s.expires = false, f.exp
                elseif s.expires and s.expires <= now then
                    s.expires = nil -- end time hidden (combat) and the old one has passed: unknown
                end
                if f.dur and f.dur > 0 then s.maxTime = f.dur end
                s.icon = f.icon or s.icon
                s.name = f.name or s.name
                if f.stacks then s.stacks = f.stacks end
                if cat.key == "sleep" and sleep and not IsResting_() then
                    StopSleep() -- out of a rested area: not sleeping, whatever the buff does
                end
                if cat.key == "sleep" and scannedOnce and db.sleepTimer and IsResting_() then
                    if not wasHas and not sleep then
                        -- the buff just appeared: you lay down (works even when using
                        -- the bag isn't seen, e.g. when it's clicked as a placed object)
                        sleep = { start = now, gains = 0 }
                    elseif (f.stacks or 0) > prevStacks or not wasHas then
                        -- (Well-Rested gains stacks while you sleep: the count is the signal;
                        -- its timer refreshing with each stack isn't counted twice)
                        OnSleepStack(now)
                    end
                end
            elseif complete or not s.has or (s.expires and s.expires <= now) then
                s.has, s.expires, s.permanent, s.stacks = false, nil, nil, nil
                if cat.key == "sleep" then StopSleep() end
            end
        end
    end
    scannedOnce = true
end

local function Remaining(s, now)
    if not s.has then return nil end
    if s.permanent then return math.huge end
    if s.expires then return math.max(0, s.expires - now) end
    return nil
end

---------------------------------------------------------------------------
-- Warning checks
---------------------------------------------------------------------------
-- The warning time for one buff: never more than a quarter of its full
-- duration, so a 2-minute buff doesn't warn the moment it's cast.
local function WarnSecFor(s, warnSec)
    if s.maxTime and s.maxTime > 0 then return math.min(warnSec, s.maxTime / 4) end
    return warnSec
end

local function CheckBuffWarnings(cat, s, rem, on, warnSec, now)
    warnSec = WarnSecFor(s, warnSec)
    local quiet = not on or cat.warn == false or now < ns.quietUntil or IsDead()
    if s.has then
        if not s.had or (s.lastRem and rem and rem > s.lastRem + 5) then s.warnedLow = false end
        if not quiet and not s.warnedLow and rem and rem > 0 and rem <= warnSec then
            s.warnedLow = true
            ns.Warn(string.format("%s: %s left!", s.name or cat.label, FormatTime(rem)))
        end
    elseif s.had and not quiet then
        ns.Warn(string.format("%s has worn off!", s.name or cat.label))
    end
    s.had = s.has
    s.lastRem = rem
end

local function WeaponLabel(info)
    if playerClass == "ROGUE" then return info.label .. " poison" end
    return info.label .. " enchant"
end

local function CheckWeaponWarnings(info, s, d, on, warnSec, now)
    local itemID = GetInventoryItemID("player", info.invSlot)
    if not Readable(itemID) then itemID = s.itemID end
    local quiet = not on or now < ns.quietUntil or IsDead()

    if d.has then
        if (s.lastRemaining and d.remaining > s.lastRemaining + 5)
            or (s.lastCharges and d.charges > s.lastCharges) then
            -- freshly applied: what's left now is the full duration
            s.warnedTime, s.warnedCharges = false, false
            s.maxTime = d.remaining
            s.maxCharges = d.charges
        elseif not s.had then
            -- first seen (login, swap): the full duration isn't known. Rogue poisons
            -- last 30 min; other enchants (5-minute shaman imbues) start from what's left
            s.warnedTime, s.warnedCharges = false, false
            s.maxTime = playerClass == "ROGUE" and math.max(d.remaining, 1800) or d.remaining
            s.maxCharges = d.charges
        end
        s.maxTime = math.max(s.maxTime or 0, d.remaining)
        s.maxCharges = math.max(s.maxCharges or 0, d.charges)
        warnSec = WarnSecFor(s, warnSec) -- (never more than a quarter of the full duration)

        if not quiet and not s.warnedTime and d.remaining > 0 and d.remaining <= warnSec then
            s.warnedTime = true
            ns.Warn(string.format("%s: %s left!", WeaponLabel(info), FormatTime(d.remaining)))
        end
        if not quiet and not s.warnedCharges and d.charges > 0 and d.charges < db.chargeWarn then
            s.warnedCharges = true
            ns.Warn(string.format("%s: only %d charges left!", WeaponLabel(info), d.charges))
        end
    elseif not quiet and s.had and s.itemID == itemID and itemID
        and ((s.lastRemaining or 0) < 5 or (s.lastCharges or 0) <= 1) then
        -- same weapon, enchant was about to end and is now gone
        ns.Warn(string.format("%s has worn off!", WeaponLabel(info)))
    end

    s.had = d.has
    s.itemID = itemID
    s.lastRemaining = d.has and d.remaining or nil
    s.lastCharges = d.has and d.charges or nil
end

-- What's missing (and, with lowSec, what runs out within lowSec seconds).
-- buffsOnlyInInstance: only weapons count outside dungeons and raids.
local function MissingList(lowSec, buffsOnlyInInstance)
    local ctx, now = GetContext(), GetTime()
    local inInst = ctx.dungeon or ctx.raid
    local missing, low = {}, {}
    for _, cat in ipairs(ns.CATEGORIES) do
        if CatOn(cat, ctx) then
            if cat.weapon then
                for _, info in ipairs(W.SLOTS) do
                    if W.HasWeapon(info.invSlot) then
                        local d = W.ReadSlot(info, now)
                        if not d.has then
                            missing[#missing + 1] = WeaponLabel(info)
                        elseif lowSec and d.remaining <= lowSec then
                            low[#low + 1] = string.format("%s (%s)", WeaponLabel(info), FormatTime(d.remaining))
                        end
                    end
                end
            elseif cat.warn ~= false and (inInst or not buffsOnlyInInstance) then
                local s = state[cat.key]
                if not s.has then
                    if MissingCounts(cat) then missing[#missing + 1] = MissingLabel(cat, s) end
                else
                    local rem = Remaining(s, now)
                    if lowSec and rem and rem <= lowSec then
                        low[#low + 1] = string.format("%s (%s)", s.name or cat.label, FormatTime(rem))
                    end
                end
            end
        end
    end
    return missing, low
end

local function CombatCheck()
    if not db.combatCheck or testMode or IsDead() then return end
    local now = GetTime()
    if now - lastCombatWarn < 60 then return end
    local missing = MissingList(nil, true)
    if #missing > 0 then
        lastCombatWarn = now
        ns.Warn("Missing: " .. table.concat(missing, ", "))
    end
end

local function ReportGroupCheck(withLow)
    if testMode or IsDead() then return end
    UpdateBuffState(GetTime())
    local missing, low = MissingList(withLow and 600 or nil, false)
    if #missing > 0 then ns.Warn("Missing: " .. table.concat(missing, ", ")) end
    if #low > 0 then Print("running low: " .. table.concat(low, ", ")) end
end

---------------------------------------------------------------------------
-- Lost on death: while you're dead the normal warnings stay quiet (every
-- buff dropping would warn at once). Instead, what was up when you died is
-- remembered, and shortly after you're back on your feet one warning lists
-- what's still gone: "Lost on death: Find Minerals, Well Fed, Fortitude".
---------------------------------------------------------------------------
local deathSnapshot -- { { key, name } or { weapon = slot info, name } } taken when you died
local wasDead = false
local revivePending = false
local REVIVE_DELAY = 2 -- seconds: lets the buff scan catch up (auto-applied buffs come back)

-- Called the moment you die (PLAYER_DEAD), or by the update loop as a fallback.
-- `state` still holds the last scan from while you were alive.
local function TakeDeathSnapshot()
    if deathSnapshot or testMode then return end
    local snap = {}
    for _, cat in ipairs(ns.CATEGORIES) do
        if cat.weapon then
            for _, info in ipairs(W.SLOTS) do
                if wstate[info.key].had then snap[#snap + 1] = { weapon = info, name = WeaponLabel(info) } end
            end
        elseif tracked[cat.key] and state[cat.key].has then
            snap[#snap + 1] = { key = cat.key, name = state[cat.key].name or cat.label }
        end
    end
    deathSnapshot = snap
end

local function ReportLostOnDeath()
    revivePending = false
    if IsDead() then return end -- died again (or still a ghost): keep the snapshot for the next revive
    local snap = deathSnapshot
    deathSnapshot = nil
    if not snap or #snap == 0 or testMode then return end
    local now = GetTime()
    UpdateBuffState(now) -- a fresh read: anything already back on doesn't count
    local ctx = GetContext()
    local weaponCat = ns.CATEGORY_BY_KEY.weapon
    local lost = {}
    for _, item in ipairs(snap) do
        if item.weapon then
            if weaponCat and CatOn(weaponCat, ctx) and W.HasWeapon(item.weapon.invSlot)
                and not W.ReadSlot(item.weapon, now).has then
                lost[#lost + 1] = item.name
            end
        else
            local cat = ns.CATEGORY_BY_KEY[item.key]
            local s = state[item.key]
            if cat and s and not s.has and cat.warn ~= false and CatOn(cat, ctx) and MissingCounts(cat) then
                lost[#lost + 1] = item.name
            end
        end
    end
    if #lost > 0 then ns.Warn("Lost on death: " .. table.concat(lost, ", ")) end
end

-- Dead -> alive: report once, after the delay.
local function OnRevived()
    if revivePending or not deathSnapshot then return end
    revivePending = true
    C_Timer.After(REVIVE_DELAY, function()
        local ok, err = pcall(ReportLostOnDeath)
        if not ok then Print("|cffff5555error:|r " .. tostring(err)) end
    end)
end

-- Run every update (before the buff scan): catches the change either way.
local function CheckDeathState()
    local dead = IsDead()
    if dead and not wasDead then
        TakeDeathSnapshot() -- (normally PLAYER_DEAD already took it)
    elseif wasDead and not dead then
        OnRevived()
    end
    wasDead = dead
end

---------------------------------------------------------------------------
-- UI, in the game's own modern HUD style (as HealKit does it): icons in the
-- action-bar icon frame, bars in the bronze unit-frame trim, filled with the
-- cast bar's art. Every atlas is checked first; a missing one falls back to
-- a plain texture, so a different client never breaks the display.
---------------------------------------------------------------------------
local ROW_H, PAD = 24, 3
local rows = {}

local function HasAtlas(name)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return false end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and info ~= nil
end

local function FirstAtlas(...)
    for i = 1, select("#", ...) do
        local name = select(i, ...)
        if HasAtlas(name) then return name end
    end
    return nil
end

local ART -- filled on first use (atlases are only checked once the UI exists)
local function GetArt()
    if ART then return ART end
    ART = {
        slot     = FirstAtlas("ui-hud-actionbar-iconframe-slot"),
        iconRing = FirstAtlas("UI-HUD-ActionBar-IconFrame"),
        fill     = FirstAtlas("ui-castingbar-filling-standard"),
        fillLow  = FirstAtlas("ui-castingbar-filling-interrupted", "ui-castingbar-interrupted"),
        fillChan = FirstAtlas("ui-castingbar-filling-channel"),
        barBg    = FirstAtlas("ui-castingbar-background"),
        spark    = FirstAtlas("ui-castingbar-pip"),
    }
    return ART
end

-- The bronze trim: Blizzard's unit-frame trim cut out of the player frame art
-- (file 8036209, stored 2x). Coordinates measured by HealKit (FrameArt.lua).
local TRIM_FILE, TRIM_FW, TRIM_FH, TRIM_C = 8036209, 2048, 1024, 6
local TRIM = {
    cornerTR = { 379, 23, 390, 34 }, cornerBR = { 379, 108, 390, 119 },
    top = { 350, 23, 351, 34 }, bottom = { 350, 108, 351, 119 }, right = { 379, 70, 390, 71 },
}
local TRIM_INSET = 3.5
local function TrimCoords(tex, r, mirror)
    local l, t = (1203 + r[1]) / TRIM_FW, (1 + r[2]) / TRIM_FH
    local rr, bb = (1203 + r[3] + 1) / TRIM_FW, (1 + r[4] + 1) / TRIM_FH
    if mirror then tex:SetTexCoord(rr, l, t, bb) else tex:SetTexCoord(l, rr, t, bb) end
end

local function TrimBorder(parent)
    local t = {}
    for _, k in ipairs({ "TL", "TR", "BL", "BR", "T", "B", "L", "R" }) do
        local tex = parent:CreateTexture(nil, "BORDER", nil, 2)
        tex:SetTexture(TRIM_FILE)
        tex:SetVertexColor(0.85, 0.85, 0.85) -- HealKit's default brightness: full gold reads too shiny
        t[k] = tex
    end
    TrimCoords(t.TR, TRIM.cornerTR) TrimCoords(t.TL, TRIM.cornerTR, true)
    TrimCoords(t.BR, TRIM.cornerBR) TrimCoords(t.BL, TRIM.cornerBR, true)
    TrimCoords(t.T, TRIM.top) TrimCoords(t.B, TRIM.bottom)
    TrimCoords(t.R, TRIM.right) TrimCoords(t.L, TRIM.right, true)
    local C = TRIM_C
    t.TL:SetSize(C, C) t.TL:SetPoint("TOPLEFT")
    t.TR:SetSize(C, C) t.TR:SetPoint("TOPRIGHT")
    t.BL:SetSize(C, C) t.BL:SetPoint("BOTTOMLEFT")
    t.BR:SetSize(C, C) t.BR:SetPoint("BOTTOMRIGHT")
    t.T:SetPoint("TOPLEFT", t.TL, "TOPRIGHT") t.T:SetPoint("BOTTOMRIGHT", t.TR, "BOTTOMLEFT")
    t.B:SetPoint("TOPLEFT", t.BL, "TOPRIGHT") t.B:SetPoint("BOTTOMRIGHT", t.BR, "BOTTOMLEFT")
    t.L:SetPoint("TOPLEFT", t.TL, "BOTTOMLEFT") t.L:SetPoint("BOTTOMRIGHT", t.BL, "TOPRIGHT")
    t.R:SetPoint("TOPLEFT", t.TR, "BOTTOMLEFT") t.R:SetPoint("BOTTOMRIGHT", t.BR, "TOPRIGHT")
    return t
end

local function CreateRow()
    local art = GetArt()
    local row = CreateFrame("Frame", nil, BW)
    row:SetHeight(ROW_H)

    -- icon: action-bar slot, the icon, the action-bar ring over it
    row.slot = CreateFrame("Frame", nil, row)
    row.slot:SetSize(ROW_H, ROW_H)
    row.slot:SetPoint("LEFT")
    local slotBg = row.slot:CreateTexture(nil, "BACKGROUND")
    slotBg:SetAllPoints()
    if art.slot then slotBg:SetAtlas(art.slot) else slotBg:SetColorTexture(0, 0, 0, 0.6) end
    row.icon = row.slot:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("TOPLEFT", 1, -1)
    row.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    row.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94) -- (a slight crop keeps the corners under the ring)
    if art.iconRing then
        local ring = row.slot:CreateTexture(nil, "OVERLAY")
        ring:SetAtlas(art.iconRing)
        ring:SetPoint("TOPLEFT")
        ring:SetSize(ROW_H * 46 / 45, ROW_H)
    end

    -- bar: bronze trim around a cast-bar fill
    row.frame = CreateFrame("Frame", nil, row)
    row.frame:SetPoint("TOPLEFT", row.slot, "TOPRIGHT", 3, 0)
    row.frame:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    TrimBorder(row.frame)

    row.bar = CreateFrame("StatusBar", nil, row.frame)
    row.bar:SetPoint("TOPLEFT", TRIM_INSET, -TRIM_INSET)
    row.bar:SetPoint("BOTTOMRIGHT", -TRIM_INSET, TRIM_INSET)
    row.bar:SetMinMaxValues(0, 1)
    row.bar:SetStatusBarTexture(art.fill or "Interface\\TargetingFrame\\UI-StatusBar")
    row.barBg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.barBg:SetAllPoints()
    if art.barBg then row.barBg:SetAtlas(art.barBg) else row.barBg:SetColorTexture(0, 0, 0, 0.7) end
    -- missing buffs: a calm dark-red wash instead of a flashing red bar
    row.missingBg = row.bar:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.missingBg:SetAllPoints()
    row.missingBg:SetColorTexture(0.16, 0.02, 0.02, 0.9)
    row.missingBg:Hide()

    row.spark = row.bar:CreateTexture(nil, "OVERLAY")
    if art.spark then
        row.spark:SetAtlas(art.spark)
        row.spark:SetSize(6, ROW_H - 4)
    else
        row.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
        row.spark:SetBlendMode("ADD")
        row.spark:SetSize(14, ROW_H + 4)
    end
    row.spark:Hide()

    -- text on its own layer above the spark
    local text = CreateFrame("Frame", nil, row.bar)
    text:SetAllPoints()
    text:SetFrameLevel(row.bar:GetFrameLevel() + 2)
    row.name = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.time = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.time:SetPoint("RIGHT", -4, 0)
    row.time:SetJustifyH("RIGHT")
    row.name:SetPoint("RIGHT", row.time, "LEFT", -4, 0)
    row.fillKind = "fill"
    return row
end

-- the fill art for a state ("fill" gold, "fillLow" red, "fillChan" green);
-- without the art, the classic texture tinted to the same colour
local FALLBACK_COLOR = { fill = { 1, 0.7, 0 }, fillLow = { 0.85, 0.1, 0.1 }, fillChan = { 0, 0.8, 0 } }
local function SetFill(row, kind)
    local art = GetArt()
    local atlas = art[kind]
    if row.fillKind ~= kind then
        row.fillKind = kind
        if atlas then
            row.bar:SetStatusBarTexture(atlas)
        elseif art.fill and kind ~= "fill" then
            row.bar:SetStatusBarTexture(art.fill) -- tinted below
        else
            row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        end
    end
    if atlas then
        row.bar:SetStatusBarColor(1, 1, 1)
    else
        local c = FALLBACK_COLOR[kind]
        row.bar:SetStatusBarColor(c[1], c[2], c[3])
    end
end

local function SetBarValue(row, v)
    v = math.max(0, math.min(1, v or 0))
    row.bar:SetValue(v)
    local w = row.bar:GetWidth()
    if v > 0.005 and v < 0.995 and w and w > 0 then
        row.spark:ClearAllPoints()
        row.spark:SetPoint("CENTER", row.bar, "LEFT", w * v, 0)
        row.spark:Show()
    else
        row.spark:Hide()
    end
end

local function SavePosition()
    local p, _, rp, x, y = BW:GetPoint()
    if p then db.point = { p, "UIParent", rp, x, y } end
end

-- (Edit Mode drags the frame and calls this when it lets go)
function ns.StopMoving()
    BW:StopMovingOrSizing()
    SavePosition()
end

function ns.ApplyLayout()
    BW:SetScale(db.scale)
    BW:SetWidth(db.width)
    BW:ClearAllPoints()
    local p = db.point
    BW:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    BW:EnableMouse(not db.locked)
    if BW.SetBackdropColor then
        if db.locked then
            BW:SetBackdropColor(0, 0, 0, 0)
            BW:SetBackdropBorderColor(0, 0, 0, 0)
        else
            BW:SetBackdropColor(0, 0, 0, 0.5)
            BW:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
    end
end

local function BuildUI()
    if BW.SetBackdrop then
        BW:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
    end
    BW:SetFrameStrata("MEDIUM")
    BW:SetClampedToScreen(true)
    BW:SetMovable(true)
    BW:RegisterForDrag("LeftButton")
    BW:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
    BW:SetScript("OnDragStop", function() ns.StopMoving() end)
    BW:SetScript("OnEnter", function(self)
        if db.locked then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("BuffWatch")
        GameTooltip:AddLine("Drag to move (or use Edit Mode). /bwatch lock to lock.", 1, 1, 1)
        GameTooltip:Show()
    end)
    BW:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ns.ApplyLayout()
end

local function ChargeColor(ch)
    if ch < db.chargeWarn then return 1, 0.15, 0.15 end
    if ch < db.chargeWarn * 2 then return 1, 0.65, 0 end
    return 0.55, 0.75, 1
end

-- Entry kinds: "missing", "buff", "sleeping"
local function SetRow(row, e, flash, warnSec)
    row.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.name:SetTextColor(1, 1, 1)
    row.time:SetTextColor(1, 1, 1)
    row.icon:SetAlpha(1)

    if e.kind == "missing" then
        row.missingBg:Show()
        row.icon:SetDesaturated(true)
        row.icon:SetAlpha(0.8)
        SetBarValue(row, 0) -- empty: nothing left of it
        row.name:SetTextColor(1, 0.45, 0.4)
        row.name:SetText(e.label)
        if e.timeText then
            row.time:SetText(e.timeText)
        else
            row.time:SetText("Missing")
            row.time:SetTextColor(1, 0.45, 0.4, flash and 1 or 0.6) -- (a gentle pulse, only the word)
        end
        return
    end

    row.missingBg:Hide()
    row.icon:SetDesaturated(false)

    if e.kind == "sleeping" then
        SetFill(row, "fillChan")
        SetBarValue(row, e.progress)
        row.name:SetText(e.label)
        row.time:SetText(e.timeText or "")
        return
    end

    local rem = e.remaining
    local ws = e.warnSec or warnSec
    SetFill(row, (rem and rem ~= math.huge and rem <= ws) and "fillLow" or "fill")
    if not rem or rem == math.huge then
        SetBarValue(row, 1)
    else
        SetBarValue(row, rem / math.max(e.maxTime or rem, 1))
    end

    local label = e.label
    if e.charges and e.charges > 0 then
        local cr, cg, cb = ChargeColor(e.charges)
        if e.charges < db.chargeWarn and flash then cr, cg, cb = 1, 1, 0 end
        label = string.format("%s |cff%02x%02x%02x%d|r", label,
            math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255), e.charges)
    end
    row.name:SetText(label)
    row.time:SetText(FormatTime(rem))
    if e.low and flash then row.time:SetTextColor(1, 0.82, 0) end
end

---------------------------------------------------------------------------
-- Building the list of bars
---------------------------------------------------------------------------
local function SleepEntry(now, cat)
    local s = state.sleep
    local stacks = (s.has and s.stacks) or 0
    local elapsed = now - sleep.start
    local left, wait, since = SleepNext(now)
    local label = string.format("Sleeping %s", FormatTime(elapsed))
    if stacks > 0 then label = label .. string.format(" - %d stack%s", stacks, stacks == 1 and "" or "s") end
    local e = { kind = "sleeping", label = label, icon = ItemIcon(ns.SLEEPING_BAG_ITEM) or cat.icon, sort = 0 }
    if left then
        if since > wait * 1.5 + 30 then
            e.timeText, e.progress = "max?", 1 -- no new stack for a long time
        else
            e.timeText = "next " .. FormatTime(left)
            e.progress = math.min(1, since / math.max(wait, 1))
        end
    else
        e.timeText, e.progress = "learning", 0
    end
    return e
end

local function BuildEntries(now, warnSec, preview)
    local ctx = GetContext()
    local entries = {}
    local dead = IsDead()

    for _, cat in ipairs(ns.CATEGORIES) do
        local on = CatOn(cat, ctx) and not dead
        if cat.weapon then
            if on then
                for _, info in ipairs(W.SLOTS) do
                    if W.HasWeapon(info.invSlot) then
                        local d = W.ReadSlot(info, now)
                        local s = wstate[info.key]
                        CheckWeaponWarnings(info, s, d, on, warnSec, now)
                        local icon = GetInventoryItemTexture("player", info.invSlot)
                        if not Readable(icon) then icon = nil end
                        if d.has then
                            local ws = WarnSecFor(s, warnSec)
                            local low = (d.remaining > 0 and d.remaining <= ws)
                                or (d.charges > 0 and d.charges < db.chargeWarn)
                            if preview or not db.onlyWhenNeeded or low then
                                entries[#entries + 1] = { kind = "buff", label = d.name .. " (" .. info.short .. ")",
                                    icon = icon, remaining = d.remaining, maxTime = s.maxTime, charges = d.charges,
                                    maxCharges = s.maxCharges, low = low, warnSec = ws, sort = low and 1 or 2 }
                            end
                        elseif db.showMissing or preview then
                            entries[#entries + 1] = { kind = "missing", label = WeaponLabel(info), icon = icon, sort = 0 }
                        end
                    end
                end
            end
        elseif tracked[cat.key] then
            local s = state[cat.key]
            local rem = Remaining(s, now)
            CheckBuffWarnings(cat, s, rem, on, warnSec, now)
            if cat.key == "sleep" and sleep and db.sleepTimer and db["mode_sleep"] ~= "off" and not dead then
                entries[#entries + 1] = SleepEntry(now, cat)
            end
            if on then
                if s.has then
                    local ws = WarnSecFor(s, warnSec)
                    local low = rem and rem <= ws
                    if preview or not db.onlyWhenNeeded or low then
                        entries[#entries + 1] = { kind = "buff", label = s.name or cat.label, icon = s.icon or cat.icon,
                            remaining = rem, maxTime = s.maxTime, low = low, warnSec = ws, sort = low and 1 or 2 }
                    end
                elseif (db.showMissing or preview) and MissingCounts(cat)
                    and not (cat.key == "sleep" and sleep) -- (asleep: the timer bar says it all)
                    and not (cat.combatOnly and not InCombatLockdown()) then
                    local e = { kind = "missing", label = MissingLabel(cat, s), icon = MissingIcon(cat, s), sort = 0 }
                    local item = cat.items and ns.OwnedItem(cat)
                    if item then
                        e.icon = ItemIcon(item) or cat.icon
                        local cd = ItemCooldown(item)
                        if cd and cd > 0 then e.timeText = "ready in " .. FormatTime(cd)
                        elseif cd then e.timeText = "|cff00ff00ready|r" end
                    end
                    entries[#entries + 1] = e
                end
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.sort ~= b.sort then return a.sort < b.sort end
        local ra, rb = a.remaining or math.huge, b.remaining or math.huge
        if ra ~= rb then return ra < rb end
        return (a.label or "") < (b.label or "")
    end)
    return entries
end

local function TestEntries(now)
    local t = (now - testStart) * 20 -- time runs x20
    local warnSec = db.warnMin * 60
    local food = math.max(0, 900 - t)
    local poison = math.max(0, 400 - t)
    return {
        { kind = "missing", label = "Flask", icon = "Interface\\Icons\\INV_Potion_62", sort = 0 },
        { kind = "sleeping", label = string.format("Sleeping %s - %d stacks", FormatTime(t), math.floor(t / 300)),
          icon = "Interface\\Icons\\INV_Misc_Bag_08", timeText = "next " .. FormatTime(300 - t % 300),
          progress = (t % 300) / 300, sort = 0 },
        { kind = "buff", label = "Well Fed", icon = "Interface\\Icons\\Spell_Misc_Food", remaining = food,
          maxTime = 900, low = food <= warnSec, sort = 1 },
        { kind = "buff", label = "Instant Poison VI (MH)", icon = "Interface\\Icons\\Ability_Poisons", remaining = poison,
          maxTime = 1800, charges = math.max(0, 40 - math.floor(t / 15)), maxCharges = 115, low = true, sort = 1 },
    }
end

local function UpdateUnsafe()
    local now = GetTime()
    if not testMode then CheckDeathState() end -- (before the scan: `state` is still from before a death)
    if scanDirty or now - lastScan >= 1 then
        scanDirty = false
        lastScan = now
        UpdateBuffState(now)
    end
    local warnSec = db.warnMin * 60
    local preview = testMode or not db.locked or ns.editMode or (SettingsPanel and SettingsPanel:IsShown())
    local entries = testMode and TestEntries(now) or BuildEntries(now, warnSec, preview)
    if preview and #entries == 0 then
        -- unlocked with nothing tracked here: still something to grab and move
        entries[1] = { kind = "sleeping", label = "BuffWatch: nothing to track here",
                       icon = "Interface\\Icons\\Spell_Misc_Food", timeText = "", progress = 0, sort = 0 }
    end
    local flash = (math.floor(now * 2) % 2) == 0

    for i, e in ipairs(entries) do
        local row = rows[i]
        if not row then
            row = CreateRow()
            rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", BW, "TOPLEFT", PAD, -PAD - (i - 1) * (ROW_H + PAD))
        row:SetPoint("TOPRIGHT", BW, "TOPRIGHT", -PAD, -PAD - (i - 1) * (ROW_H + PAD))
        SetRow(row, e, flash, warnSec)
        row:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide() end

    -- nothing to show: invisible and click-through (not :Hide(), that stops OnUpdate)
    if #entries == 0 then
        BW:SetAlpha(0)
        BW:EnableMouse(false)
    else
        BW:SetAlpha(1)
        BW:EnableMouse(not db.locked)
    end
    BW:SetHeight(math.max(#entries, 1) * (ROW_H + PAD) + PAD)
end

-- Errors are hidden by the game by default: report each new one once.
local lastError
function ns.Update()
    if not db then return end
    local ok, err = pcall(UpdateUnsafe)
    if not ok and err ~= lastError then
        lastError = err
        Print("|cffff5555error:|r " .. tostring(err) .. " - /bwatch status helps when reporting this.")
    end
end

local elapsedAcc = 0
local function OnUpdate(_, elapsed)
    elapsedAcc = elapsedAcc + elapsed
    if elapsedAcc < 0.25 then return end
    elapsedAcc = 0
    ns.Update()
end

---------------------------------------------------------------------------
-- Commands used by Options.lua
---------------------------------------------------------------------------
function ns.SetTest(on)
    testMode = on
    testStart = GetTime()
    ns.Update()
end
function ns.IsTest() return testMode end

-- Added names (strings) and spell IDs (numbers) live in g.extra[key].
function ns.AddName(key, value)
    local cat = ns.CATEGORY_BY_KEY[key]
    if not cat or cat.weapon then return false end
    g.extra[key] = g.extra[key] or {}
    g.extra[key][tonumber(value) or value] = true
    ns.RebuildTracked()
    return true
end

function ns.RemoveName(key, value)
    local cat = ns.CATEGORY_BY_KEY[key]
    if not cat then return false end
    local id = tonumber(value)
    local extra = g.extra[key]
    if extra then
        if id then
            extra[id] = nil
        else
            for v in pairs(extra) do
                if type(v) == "string" and v:lower() == value:lower() then extra[v] = nil end
            end
        end
    end
    -- forget automatically learned IDs of this group (still-listed names relearn them)
    for learnedID, k in pairs(g.learned) do
        if k == key and (not id or learnedID == id) then g.learned[learnedID] = nil end
    end
    ns.RebuildTracked()
    return true
end

function ns.ListAuras()
    if InCombatLockdown() then Print("buff names can be hidden in combat; try again out of combat.") end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then Print("aura API not available.") return end
    local now = GetTime()
    Print("your buffs:")
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok or type(a) ~= "table" then break end
        local name = Readable(a.name) and a.name or "(hidden)"
        local id = Num(a.spellId)
        local exp = Num(a.expirationTime)
        local key = KeyFor(Readable(a.name) and type(a.name) == "string" and a.name or nil, id)
        local rem = exp and (exp == 0 and "no time limit" or FormatTime(exp - now)) or "?"
        local stacks = Num(a.applications)
        if stacks and stacks > 1 then rem = rem .. ", " .. stacks .. " stacks" end
        local dur = Num(a.duration)
        if dur and dur > 0 then rem = rem .. " of " .. FormatTime(dur) end
        print(string.format("  %s (spell %s) - %s%s", name, tostring(id or "?"), rem,
            key and ("  |cff33ff99[" .. key .. "]|r") or ""))
    end
end

function ns.Status()
    local ctx = GetContext()
    Print(string.format("class %s, leveling: %s, dungeon: %s, raid: %s", tostring(playerClass),
        tostring(ctx.leveling), tostring(ctx.dungeon), tostring(ctx.raid)))
    if ns.weaponOff then print("  weapons: left to PoisonWatch (it is enabled)") end
    local now = GetTime()
    for _, cat in ipairs(ns.CATEGORIES) do
        if ns.CategoryForClass(cat, playerClass) then
            local s = state[cat.key]
            local info
            if not tracked[cat.key] then
                info = "|cff888888spell not known|r"
            elseif cat.weapon then
                info = CatOn(cat, ctx) and "on" or "off here"
            else
                info = (CatOn(cat, ctx) and "on" or "off here") .. ", "
                    .. (s.has and ("up, " .. FormatTime(Remaining(s, now))) or "not up")
            end
            print(string.format("  %s [%s] mode %s: %s", cat.label, cat.key, tostring(db["mode_" .. cat.key]), info))
        end
    end
    Print(string.format("sleep: %s (resting: %s), first stack after %s, then every %s",
        sleep and ("asleep " .. FormatTime(now - sleep.start)) or "not sleeping", tostring(IsResting_()),
        g.sleepFirst and FormatTime(g.sleepFirst) or "?", g.sleepInterval and FormatTime(g.sleepInterval) or "?"))
end

function ns.WeaponsDebug() W.Debug() end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function InitDB()
    local isNew = type(BuffWatchDB) ~= "table" -- (a new character starts on today's defaults)
    BuffWatchDB = isNew and {} or BuffWatchDB
    for _, cat in ipairs(ns.CATEGORIES) do
        ns.DEFAULTS["mode_" .. cat.key] = ns.DefaultMode(cat, playerClass)
    end
    for k, v in pairs(ns.DEFAULTS) do
        if BuffWatchDB[k] == nil then
            BuffWatchDB[k] = (type(v) == "table") and { unpack(v) } or v
        end
    end
    db = BuffWatchDB
    ns.db = db
    BuffWatchGlobal = type(BuffWatchGlobal) == "table" and BuffWatchGlobal or {}
    g = BuffWatchGlobal
    ns.g = g
    g.extra = type(g.extra) == "table" and g.extra or {}
    g.learned = type(g.learned) == "table" and g.learned or {}
    g.instances = type(g.instances) == "table" and g.instances or {} -- group key -> { [instanceID] = name }
    db.buffOn = type(db.buffOn) == "table" and db.buffOn or {}      -- "group:Buff Name" -> false when unticked
    db.scale = math.max(0.5, math.min(2, tonumber(db.scale) or 1))
    db.width = math.max(140, math.min(400, tonumber(db.width) or 230))
    db.warnMin = math.max(1, math.min(30, tonumber(db.warnMin) or 3))
    -- defaults that changed since this character's settings were saved: a group
    -- still on its old default moves to the new one (your own choices stay)
    local ver = isNew and ns.DEFAULTS_VERSION or (tonumber(db.defaultsVersion) or 1)
    for v = ver + 1, ns.DEFAULTS_VERSION do
        for _, change in ipairs(ns.DEFAULT_CHANGES[v] or {}) do
            for _, cat in ipairs(ns.CATEGORIES) do
                local k = "mode_" .. cat.key
                if change.applies(cat, playerClass) and db[k] == change.old and ns.DEFAULTS[k] ~= change.old then
                    db[k] = ns.DEFAULTS[k]
                end
            end
        end
    end
    db.defaultsVersion = ns.DEFAULTS_VERSION
    -- a mode name from an older or newer version: back to the default
    local valid = {}
    for _, m in ipairs(ns.MODES) do valid[m[1]] = true end
    for _, cat in ipairs(ns.CATEGORIES) do
        if not valid[db["mode_" .. cat.key]] then db["mode_" .. cat.key] = ns.DEFAULTS["mode_" .. cat.key] end
    end
end

function ns.ResetSettings()
    -- (in place: the options panel is bound to these tables)
    local buffOn = db.buffOn
    for k in pairs(db) do db[k] = nil end
    for k, v in pairs(ns.DEFAULTS) do db[k] = (type(v) == "table") and { unpack(v) } or v end
    wipe(buffOn)
    db.buffOn = buffOn
    db.defaultsVersion = ns.DEFAULTS_VERSION
    ns.RebuildTracked()
end

-- /bwatch here <group>: limit a group to the current dungeon/raid, or undo that.
-- Returns "added" / "removed" / nil (not in an instance), and the instance name.
function ns.ToggleHere(key)
    local ok, name, _, _, _, _, _, _, id = pcall(GetInstanceInfo)
    id = ok and Num(id) or nil
    local ctx = GetContext()
    if not id or not (ctx.dungeon or ctx.raid) then return nil end
    name = Readable(name) and name or tostring(id)
    g.instances[key] = g.instances[key] or {}
    local list = g.instances[key]
    if list[id] then
        list[id] = nil
        if not next(list) then g.instances[key] = nil end
        return "removed", name
    end
    list[id] = name
    return "added", name
end

-- the instances a group is limited to, as text ("" = every one)
function ns.HereList(key)
    local names = {}
    for _, n in pairs(g.instances[key] or {}) do names[#names + 1] = tostring(n) end
    table.sort(names)
    return table.concat(names, ", ")
end

local function OnEvent(self, event, arg1, arg2, arg3)
    if event == "PLAYER_LOGIN" then
        local _, class = UnitClass("player")
        playerClass = Readable(class) and class or "UNKNOWN"
        InitDB()
        local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
        -- PoisonWatch only runs for rogues: only then leave weapons to it
        if playerClass == "ROGUE" and isLoaded and isLoaded("PoisonWatch") then
            ns.weaponOff = true
            Print("PoisonWatch is enabled too, so BuffWatch leaves your poisons to it. Disable PoisonWatch in the AddOns list to use BuffWatch's poison bars instead.")
        end
        LoadBagSpell()
        ns.RebuildTracked()
        BuildUI()
        if ns.CreateOptions then ns.CreateOptions() end

        if self.RegisterUnitEvent then
            self:RegisterUnitEvent("UNIT_AURA", "player")
            self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
            self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
            self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
        else
            self:RegisterEvent("UNIT_AURA")
            self:RegisterEvent("UNIT_INVENTORY_CHANGED")
            self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
        end
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                             "READY_CHECK", "PLAYER_STARTED_MOVING", "GROUP_ROSTER_UPDATE", "SPELLS_CHANGED",
                             "PLAYER_LEVEL_UP", "GET_ITEM_INFO_RECEIVED", "MINIMAP_UPDATE_TRACKING",
                             "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_UPDATE_RESTING" }) do
            pcall(self.RegisterEvent, self, e)
        end
        self:SetScript("OnUpdate", OnUpdate)
        ns.quietUntil = GetTime() + 5
        ns.Update()

    elseif event == "UNIT_AURA" then
        if arg1 == "player" then scanDirty = true end
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then W.TooltipChanged() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- (arg1 unit, arg2 cast GUID, arg3 spell ID)
        if arg1 == "player" and IsBagSpell(arg3) then OnBagUsed() end
    elseif event == "PLAYER_UPDATE_RESTING" then
        if not IsResting_() then StopSleep() end
    elseif event == "PLAYER_STARTED_MOVING" then
        StopSleep()
    elseif event == "PLAYER_REGEN_DISABLED" then
        StopSleep()
        pcall(CombatCheck)
    elseif event == "PLAYER_REGEN_ENABLED" or event == "MINIMAP_UPDATE_TRACKING" then
        scanDirty = true
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.quietUntil = GetTime() + 5
        StopSleep()
        scanDirty = true
        C_Timer.After(8, function()
            if not db.instanceCheck then return end
            local ctx = GetContext()
            if ctx.dungeon or ctx.raid then pcall(ReportGroupCheck, false) end
        end)
    elseif event == "READY_CHECK" then
        if db.readyCheck then pcall(ReportGroupCheck, true) end
    elseif event == "PLAYER_DEAD" then
        TakeDeathSnapshot()
        wasDead = true
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        -- (PLAYER_ALIVE also fires when you release and become a ghost: still dead, so wait)
        if not IsDead() then
            wasDead = false
            OnRevived()
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        ns.ResetGivers()
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_LEVEL_UP" then
        ns.RebuildTracked()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if arg1 == ns.SLEEPING_BAG_ITEM and not ns.bagSpellName then LoadBagSpell() end
    end
end

local lastEventError
BW:RegisterEvent("PLAYER_LOGIN")
BW:SetScript("OnEvent", function(self, event, ...)
    local ok, err = pcall(OnEvent, self, event, ...)
    if not ok and err ~= lastEventError then
        lastEventError = err
        Print("|cffff5555error (" .. tostring(event) .. "):|r " .. tostring(err))
    end
end)

-- BuffWatch: shared helpers and the table of buff groups it tracks.
-- To add a buff or a class, add or edit an entry in ns.CATEGORIES below.
local _, ns = ...

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- The Forever client is a modern client: some values can be "secret"
-- (unreadable by addons, mostly in combat). Comparing one throws an error.
local issecret = issecretvalue or issecret or function() return false end
ns.issecret = issecret

function ns.Readable(v)
    if v == nil then return false end
    if issecret(v) then return false end
    return true
end

function ns.Num(v)
    if not ns.Readable(v) then return nil end
    return tonumber(v)
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99BuffWatch|r: " .. msg)
end

function ns.FormatTime(sec)
    if not sec then return "?" end
    if sec == math.huge then return "on" end
    sec = math.floor(sec)
    if sec <= 0 then return "0:00" end
    if sec >= 3600 then
        return string.format("%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60)
    end
    return string.format("%d:%02d", sec / 60, sec % 60)
end

---------------------------------------------------------------------------
-- When a group is tracked. "Leveling" = your character can still gain
-- experience (below max level and XP not turned off).
---------------------------------------------------------------------------
ns.MODES = {
    { "off",                "Off" },
    { "leveling",           "While leveling" },
    { "leveling_instances", "Leveling + dungeons & raids" },
    { "instances",          "Dungeons & raids" },
    { "world",              "Outside dungeons & raids" },
    { "raids",              "Raids only" },
    { "always",             "Always" },
}

ns.SLEEPING_BAG_ITEM = 211527 -- Cozy Sleeping Bag
ns.MAX_LEVEL = 60              -- "leveling" groups switch off at this level

local ALL_BUT = function(...)
    local t = { WARRIOR = true, ROGUE = true, HUNTER = true, MAGE = true, WARLOCK = true,
                PRIEST = true, DRUID = true, PALADIN = true, SHAMAN = true }
    for _, c in ipairs({ ... }) do t[c] = nil end
    return t
end

ns.MANA_CLASSES = { PRIEST = true, MAGE = true, WARLOCK = true, DRUID = true, PALADIN = true, SHAMAN = true, HUNTER = true }

---------------------------------------------------------------------------
-- Buff groups. A group is "up" when any buff with one of its names is on you
-- (upper/lower case doesn't matter; only whole names match). Fields:
--   key, label, icon, tip  - id, name in the options, fallback icon, help text
--   names     - buff names that count
--   ids       - buff spell IDs that count (for buffs that share a name)
--   contains  - lower-case name parts: a buff whose name contains one counts
--               (checked after exact names, for buffs whose name isn't known)
--   nameSets + setsByClass - instead of names: named lists, picked per class
--   combatOnly - only shown as missing while you're in combat
--   minDuration - a matching buff whose full duration is shorter (seconds)
--               doesn't count (e.g. the eating buff before Well Fed)
--   warn      - false: show the bar, but no low / worn-off warnings
--               (the warning time is never more than a quarter of the
--               buff's full duration, so short buffs don't warn at once)
--   mode      - default "when to track" (see ns.MODES); your own class's
--               buffs (giver = you, or self) default to "always"
--   modeByClass - default mode for particular classes
--   classes   - only for these classes (nil = every class)
--   self      - your own spell: only tracked once you know one of its names
--               as a castable spell (not too low, talent taken, racial owned)
--   giver     - cast by that class: only reported missing while someone of
--               that class is in your group (or you are that class)
--   manaOnly  - only for classes that use mana
--   item / items - only tracked while you carry (one of) these item(s)
--   instances - only in these instances (instance IDs); empty = every one.
--               In game: /bwatch here <group> adds or removes the current one
--   noPicker  - no per-buff checkboxes in the options' Buff list
--   tracking  - minimap tracking (Find Herbs ...), read from the tracking
--               menu as well as from your buffs
--   weapon    - temporary weapon enchants per hand (Weapons.lua)
-- Unknown fields are ignored; a misspelled buff name just never matches.
-- In game: /bwatch add <group key> <buff name or spell ID> adds a name.
---------------------------------------------------------------------------
ns.CATEGORIES = {
    -- Leveling ---------------------------------------------------------------
    { key = "sleep", label = "Sleeping Bag", mode = "leveling", item = ns.SLEEPING_BAG_ITEM,
      icon = "Interface\\Icons\\INV_Misc_Bag_08",
      tip = "The Cozy Sleeping Bag's buff, plus a timer while you sleep that counts down to your next stack. Only reported missing while the bag is in your bags; the row then shows when the bag can be used again. If the buff isn't recognised, BuffWatch learns its name the first time you use the bag.",
      names = { "Well-Rested", "Well Rested", "Cozy Sleeping Bag", "Sleeping Bag" },
      ids = { 429959 }, -- Well-Rested (seen in game: 1:20:00 after sleeping)
      contains = { "sleep", "cozy", "rested" }, -- any buff whose name contains one of these
      noPicker = true }, -- (its names are guesses: no per-buff ticks in the Buff list)

    { key = "food", label = "Food (Well Fed)", mode = "leveling_instances",
      icon = "Interface\\Icons\\Spell_Misc_Food",
      tip = "Any Well Fed style food buff.",
      minDuration = 120, -- (the short buff while you're still eating doesn't count: only the real one)
      names = { "Well Fed", "Increased Agility", "Increased Intellect", "Increased Stamina",
                "Increased Strength", "Increased Spirit" },
      ids = { 18194 } }, -- Nightfin Soup ("Mana Regeneration", same name as Mageblood)

    { key = "gathering", label = "Gathering tracking", mode = "world", self = true, tracking = true,
      icon = "Interface\\Icons\\INV_Misc_Flower_02",
      tip = "Find Herbs or Find Minerals (only one can be on at a time; either counts). Only tracked once you know one of them. Tracking is lost when you die: this reminds you to turn it back on.",
      names = { "Find Herbs", "Find Minerals", "Find Fish" } },

    -- WoW Forever: Unstable Magic ------------------------------------------
    { key = "attractor", label = "Magical Awareness (Unstable Magic)", mode = "instances",
      items = { 281371, 275730 }, -- Elemental Attractor (Horde), Arcane Censer (Alliance)
      icon = "Interface\\Icons\\Spell_Arcane_Arcane04",
      tip = "The 2-hour buff from the Elemental Attractor / Arcane Censer that lets you collect Motes of Unstable Magic. Only while you carry one of them. By default in every dungeon and raid; to limit it to the dungeons where motes drop, stand in one and type /bwatch here attractor (again to remove it).",
      names = { "Magical Awareness" },
      ids = { 1297774 } },

    -- Raid consumables -----------------------------------------------------
    { key = "flask", label = "Flask", mode = "raids",
      icon = "Interface\\Icons\\INV_Potion_62",
      tip = "Flask of the Titans, Distilled Wisdom, Supreme Power, Chromatic Resistance or Petrification.",
      names = { "Flask of the Titans", "Distilled Wisdom", "Supreme Power", "Chromatic Resistance", "Petrification" } },

    { key = "elixir", label = "Elixir", mode = "raids",
      icon = "Interface\\Icons\\INV_Potion_32",
      tip = "Physical classes: Mongoose, Giants, Brute Force, Greater Agility. Casters: Greater Arcane, Shadow Power, Greater Firepower, Frost Power, Sages, Mageblood. Druids, paladins and shamans: any of them.",
      nameSets = {
          physical = { "Elixir of the Mongoose", "Elixir of the Giants", "Elixir of Brute Force", "Greater Agility" },
          caster   = { "Greater Arcane Elixir", "Shadow Power", "Greater Firepower", "Fire Power", "Frost Power",
                       "Elixir of the Sages" },
      },
      ids = { 24363 }, -- Mageblood Potion ("Mana Regeneration", same name as Nightfin Soup)
      setsByClass = {
          WARRIOR = { "physical" }, ROGUE = { "physical" }, HUNTER = { "physical" },
          MAGE = { "caster" }, WARLOCK = { "caster" }, PRIEST = { "caster" },
          DRUID = { "physical", "caster" }, PALADIN = { "physical", "caster" }, SHAMAN = { "physical", "caster" },
      } },

    { key = "zanza", label = "Zanza", mode = "raids",
      icon = "Interface\\Icons\\INV_Potion_30",
      tip = "Spirit, Swiftness or Sheen of Zanza.",
      names = { "Spirit of Zanza", "Swiftness of Zanza", "Sheen of Zanza" } },

    -- Group buffs from other players ----------------------------------------
    { key = "fort", label = "Fortitude", mode = "instances", giver = "PRIEST",
      icon = "Interface\\Icons\\Spell_Holy_WordFortitude",
      tip = "Power Word / Prayer of Fortitude. Only reported missing when a priest is in your group (or you are one).",
      names = { "Power Word: Fortitude", "Prayer of Fortitude" } },

    { key = "motw", label = "Mark of the Wild", mode = "instances", giver = "DRUID",
      icon = "Interface\\Icons\\Spell_Nature_Regeneration",
      tip = "Mark / Gift of the Wild. Only reported missing when a druid is in your group (or you are one).",
      names = { "Mark of the Wild", "Gift of the Wild" } },

    { key = "int", label = "Arcane Intellect", mode = "instances", giver = "MAGE", manaOnly = true,
      icon = "Interface\\Icons\\Spell_Holy_MagicalSentry",
      tip = "Arcane Intellect / Brilliance. Mana users only; only reported missing when a mage is in your group (or you are one).",
      names = { "Arcane Intellect", "Arcane Brilliance" } },

    { key = "blessing", label = "Paladin blessing", mode = "instances", giver = "PALADIN",
      icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings",
      tip = "Any (Greater) Blessing. Only reported missing when a paladin is in your group (or you are one).",
      names = { "Blessing of Kings", "Greater Blessing of Kings", "Blessing of Might", "Greater Blessing of Might",
                "Blessing of Wisdom", "Greater Blessing of Wisdom", "Blessing of Salvation", "Greater Blessing of Salvation",
                "Blessing of Light", "Greater Blessing of Light", "Blessing of Sanctuary", "Greater Blessing of Sanctuary" } },

    -- Class self buffs (only once you know the spell) ------------------------
    { key = "shout", label = "Battle Shout", mode = "always", classes = { WARRIOR = true }, self = true,
      warn = false,       -- 2 minutes, drops between every pull: bar only
      combatOnly = true,  -- only shown missing while you're in combat
      icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
      names = { "Battle Shout" } },

    { key = "aspect", label = "Aspect", mode = "always", classes = { HUNTER = true }, self = true,
      icon = "Interface\\Icons\\Ability_Hunter_AspectOfTheMonkey",
      tip = "Any Aspect.",
      names = { "Aspect of the Hawk", "Aspect of the Monkey", "Aspect of the Cheetah", "Aspect of the Pack",
                "Aspect of the Wild", "Aspect of the Beast" } },

    { key = "trueshot", label = "Trueshot Aura", mode = "always", classes = { HUNTER = true }, self = true,
      icon = "Interface\\Icons\\Ability_TrueShot",
      names = { "Trueshot Aura" } },

    { key = "magearmor", label = "Mage armor", mode = "always", classes = { MAGE = true }, self = true,
      icon = "Interface\\Icons\\Spell_Frost_FrostArmor02",
      tip = "Frost, Ice or Mage Armor.",
      names = { "Frost Armor", "Ice Armor", "Mage Armor", "Molten Armor" } },

    { key = "demonarmor", label = "Demon armor", mode = "always", classes = { WARLOCK = true }, self = true,
      icon = "Interface\\Icons\\Spell_Shadow_RagingScream",
      tip = "Demon Skin or Demon Armor.",
      names = { "Demon Skin", "Demon Armor" } },

    { key = "innerfire", label = "Inner Fire", mode = "always", classes = { PRIEST = true }, self = true,
      icon = "Interface\\Icons\\Spell_Holy_InnerFire",
      names = { "Inner Fire" } },

    { key = "touchweak", label = "Touch of Weakness", mode = "always", classes = { PRIEST = true }, self = true,
      icon = "Interface\\Icons\\Spell_Shadow_DeadofNight",
      names = { "Touch of Weakness" } },

    { key = "shadowguard", label = "Shadowguard", mode = "always", classes = { PRIEST = true }, self = true,
      icon = "Interface\\Icons\\Spell_Nature_LightningShield",
      names = { "Shadowguard" } },

    { key = "thorns", label = "Thorns", mode = "always", classes = { DRUID = true }, self = true,
      icon = "Interface\\Icons\\Spell_Nature_Thorns",
      names = { "Thorns" } },

    { key = "shield", label = "Lightning / Water Shield", mode = "always", classes = { SHAMAN = true }, self = true,
      icon = "Interface\\Icons\\Spell_Nature_LightningShield",
      names = { "Lightning Shield", "Water Shield" } },

    -- Weapon enchants ---------------------------------------------------------
    { key = "weapon", label = "Weapon poison / oil / imbue", mode = "raids", weapon = true,
      classes = ALL_BUT("HUNTER", "DRUID"),
      modeByClass = { ROGUE = "always", SHAMAN = "always" },
      icon = "Interface\\Icons\\Ability_Poisons",
      tip = "Temporary weapon enchants on your main and off hand: rogue poisons (time and charges), shaman imbues, sharpening stones, weightstones and oils. This replaces PoisonWatch: while PoisonWatch is enabled, BuffWatch leaves weapons to it.",
      names = {} },
}

ns.CATEGORY_BY_KEY = {}
for _, cat in ipairs(ns.CATEGORIES) do
    ns.CATEGORY_BY_KEY[cat.key] = cat
    if cat.item and not cat.items then cat.items = { cat.item } end -- (one form for the code)
end

-- The buff names that count for this group for your class.
function ns.CategoryNames(cat, class)
    if cat.nameSets then
        local out = {}
        local sets = (cat.setsByClass and cat.setsByClass[class]) or {}
        if #sets == 0 then
            sets = {} -- unknown class: any of them
            for name in pairs(cat.nameSets) do sets[#sets + 1] = name end
        end
        for _, setName in ipairs(sets) do
            for _, n in ipairs(cat.nameSets[setName] or {}) do out[#out + 1] = n end
        end
        return out
    end
    return cat.names or {}
end

-- Does this group apply to your class at all (shown in the options)?
function ns.CategoryForClass(cat, class)
    return cat.classes == nil or cat.classes[class] == true
end

-- Default "when to track". Your own class's buffs (a paladin's blessing, a
-- priest's Fortitude, every self buff) are tracked everywhere.
function ns.DefaultMode(cat, class)
    if cat.modeByClass and cat.modeByClass[class] then return cat.modeByClass[class] end
    if cat.giver and cat.giver == class then return "always" end
    if cat.self then return "always" end
    return cat.mode or "off"
end

-- Defaults that changed: saved settings still on an old default move to the
-- new one (a choice you made yourself is kept). Version -> list of
-- { group key, old default, applies(cat, class) }.
ns.DEFAULT_CHANGES = {
    [2] = { -- 1.1: your own class's buffs everywhere instead of dungeons & raids only
        { old = "instances", applies = function(cat, class) return (cat.giver == class) or cat.self end },
    },
}
ns.DEFAULTS_VERSION = 2

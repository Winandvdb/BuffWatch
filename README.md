# Buff Sentinel

Buff tracker for **WoW Forever** (interface 16001). Warns before your buffs run out and shows a bar for every buff
that is missing or running low, in the game's own modern HUD style.

## What it tracks
- **Leveling** (until you can't gain XP at level 60): the Cozy Sleeping Bag's **Well-Rested** buff, with a sleep timer
  ("Sleeping 4:12 - 2/3 stacks", counting down to the next stack; at 3/3 it shows how long Well-Rested lasts, as
  sleeping then refreshes it), and **food** (Well Fed), with an eating timer ("Eating - Well Fed in 0:07").
- **Dungeons & raids**: food, flask, elixirs (physical or caster, per class), Zanza, Fortitude, Mark of the Wild,
  Arcane Intellect, paladin blessings and auras (group buffs are only reported missing when that class is in your group).
- **Unstable Magic**: Magical Awareness from the Elemental Attractor / Arcane Censer, while you carry one.
- **Argent Dawn**: reminds you to equip the Argent Dawn Commission (or Seal / Rune of the Dawn) in Stratholme,
  Scholomance and the Plaguelands, so Scourgestones drop. Only while you carry one.
- **Gathering**: Find Herbs / Find Minerals, outside dungeons and raids.
- **Your class's own buffs**, everywhere: armors, Inner Fire, Aspects, shields, Thorns, your own blessing, and more
  (only once you know the spell).
- **Weapon enchants**: rogue poisons with time and charges (replaces PoisonWatch), shaman imbues, stones and oils.

After you die, one warning lists everything you lost: "Lost on death: Find Minerals, Well Fed, Fortitude".

During a fight, "running out" and "worn off" warnings wait and buff bars are hidden (weapon enchant bars stay); when
combat ends you get one warning with what still matters ("After combat: Well Fed has worn off, Blessing of Might: 1:30 left"). WoW Forever hides your buffs from
addons in combat: Buff Sentinel keeps what it saw before the fight and never reports a buff missing that it can't see.

**Click a bar to fix it** (out of combat), when it's clear what to do: your own buffs are cast on you (armors,
Inner Fire, Aspects, tracking, your class's blessing or Fortitude), the sleeping bag and Elemental Attractor /
Arcane Censer are used, the Argent Dawn Commission is equipped, and the poison or oil that was on a weapon is put
back on (if it's in your bags). Hover a bar to see what a click does. Food, flasks and elixirs aren't clickable.

**Alt+Right-click a bar to hide it**: that group is no longer tracked (When to track: Off). `/bsent undo` brings the
last one back, or turn it on again in the Buff list.

## Install
Copy the `BuffSentinel` folder to `World of Warcraft\_forever_\Interface\AddOns\` and restart the game.
Rogues: disable PoisonWatch, Buff Sentinel leaves poisons to it while it's enabled.

## Settings
Esc > Options > AddOns > Buff Sentinel. The **Buff list** page sets, per buff group, when it's tracked (while leveling,
dungeons & raids, outside them, always ...) and which buffs count. Move the bars in Edit Mode or with `/bsent unlock`.

## Commands
| Command | |
|---|---|
| `/bsent` | help and options |
| `/bsent test` | preview the bars |
| `/bsent status` | what is tracked here and now |
| `/bsent auras` | your buffs with spell IDs (out of combat) |
| `/bsent add <group> <name or ID>` / `remove` | count another buff for a group |
| `/bsent here <group>` | only track a group in the dungeon you're in (again to undo) |
| `/bsent castlog` | for 2 minutes, print casts, buffs, resting and the sleeping bag (debugging the sleep timer) |
| `/bsent undo` | track the group you last hid with Alt+Right-click again |
| `/bsent lock` / `unlock` / `reset` | frame and settings |

## Adding buffs
Everything lives in one table in `Data.lua` (`ns.CATEGORIES`): a buff group is a list of buff names (or spell IDs)
plus optional rules such as which classes, which class casts it, or an item you must carry. Unknown buffs and spells
are simply ignored.

Buff names are matched in English.

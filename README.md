# BuffWatch

Buff tracker for **WoW Forever** (interface 16001). Warns before your buffs run out and shows a bar for every buff
that is missing or running low, in the game's own modern HUD style.

## What it tracks
- **Leveling** (until you can't gain XP at level 60): the Cozy Sleeping Bag's **Well-Rested** buff, with a sleep timer
  that counts down to your next stack, and **food** (Well Fed).
- **Dungeons & raids**: food, flask, elixirs (physical or caster, per class), Zanza, Fortitude, Mark of the Wild,
  Arcane Intellect, paladin blessings (group buffs are only reported missing when that class is in your group).
- **Unstable Magic**: Magical Awareness from the Elemental Attractor / Arcane Censer, while you carry one.
- **Gathering**: Find Herbs / Find Minerals, outside dungeons and raids.
- **Your class's own buffs**, everywhere: armors, Inner Fire, Aspects, shields, Thorns, your own blessing, and more
  (only once you know the spell).
- **Weapon enchants**: rogue poisons with time and charges (replaces PoisonWatch), shaman imbues, stones and oils.

After you die, one warning lists everything you lost: "Lost on death: Find Minerals, Well Fed, Fortitude".

During a fight, "running out" and "worn off" warnings wait; when combat ends you get one warning with what still
matters ("After combat: Well Fed has worn off, Blessing of Might: 1:30 left"). WoW Forever hides your buffs from
addons in combat: BuffWatch keeps what it saw before the fight and never reports a buff missing that it can't see.

## Install
Copy the `BuffWatch` folder to `World of Warcraft\_forever_\Interface\AddOns\` and restart the game.
Rogues: disable PoisonWatch, BuffWatch leaves poisons to it while it's enabled.

## Settings
Esc > Options > AddOns > BuffWatch. The **Buff list** page sets, per buff group, when it's tracked (while leveling,
dungeons & raids, outside them, always ...) and which buffs count. Move the bars in Edit Mode or with `/bwatch unlock`.

## Commands
| Command | |
|---|---|
| `/bwatch` | help and options |
| `/bwatch test` | preview the bars |
| `/bwatch status` | what is tracked here and now |
| `/bwatch auras` | your buffs with spell IDs (out of combat) |
| `/bwatch add <group> <name or ID>` / `remove` | count another buff for a group |
| `/bwatch here <group>` | only track a group in the dungeon you're in (again to undo) |
| `/bwatch lock` / `unlock` / `reset` | frame and settings |

## Adding buffs
Everything lives in one table in `Data.lua` (`ns.CATEGORIES`): a buff group is a list of buff names (or spell IDs)
plus optional rules such as which classes, which class casts it, or an item you must carry. Unknown buffs and spells
are simply ignored.

Buff names are matched in English.

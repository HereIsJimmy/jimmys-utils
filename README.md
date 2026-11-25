<p align="center">
  <img src="docs/logo.png" alt="Jimmy's Utils logo" width="160">
</p>

<h1 align="center">Jimmy's Utils</h1>

<p align="center">
  A small toolbox addon for <b>World of Warcraft: Forever</b>: stat weight scores on tooltips, a target range indicator,
  a recipe lookup and mailbox helpers.
</p>

---

## Features

| Feature | What it does |
| --- | --- |
| **Stat weights** | Adds a score line to the tooltip of every equippable item: a weighted sum of its stats, using weights you choose. Multiple scales (named sets of weights), listed in the tooltip at once (one score line each; hide the ones you do not want to see), an optional per-stat breakdown (hold Alt by default). Pawn scale tags can be imported and exported. |
| **Auction house scores** | The Browse tab of the auction house gets one score column per scale listed in the tooltips (the first three), scored exactly like the tooltips (a random suffix counts: every item key is scored on its own). Click a column's header to sort the loaded results by that scale's score, highest first; click it again, or one of the auction house's own headers, to go back. Items that are not equippable, or not loaded yet, have an empty cell. Switch it off with the check box in the Stat Weights tab of the settings. |
| **Resizable auction house** | Drag the grip in the bottom right corner of the auction house window to make it larger (up to the size of the screen); the lists and columns grow with it, and the size is remembered. Right-click the grip for the default size. On by default; switch it off with the check box in the Stat Weights tab of the settings. |
| **Range check** | Shows the icon of a spell you pick next to your target's nameplate (or at a fixed spot on screen), tinted red while the target is out of range. |
| **Recipe lookup** | Hover an item and press a key (or `/ju recipes <item>`) to list every recipe that uses it (the recipes nobody knows are listed too, in grey, after the known ones) with the materials each one needs, which of your characters know them, and Wowhead links (the exact page of the item that teaches it, and the recipe's spell page) for each. Each recipe your characters know shows its **skill-up chance**, `(NN%)`, in the official difficulty colors. A check box at the top keeps only the recipes of your character's professions, profession buttons above the list filter it to one profession, and professions can be hidden for good in the Recipes tab of the settings. Double-click a recipe to open it in your profession window. The window can be resized with the grip in its bottom right corner (double-click the grip for the default size). |
| **Recent mail recipients** | A panel next to the Send Mail tab with the last 10 characters you mailed. Click a name to fill in the "To:" box. |
| **Mailbox button** | A small icon in the mailbox title bar that opens the materials window. |
| **Materials in your mail** | `/ju materials` lists the recipes that use items waiting in your mailbox, with how many of each ingredient (bags, bank and mail) you have, how many you still need, and which recipes are already craftable. It also shows what your other characters on the realm could craft, from their saved bags, bank and mail (including items you mail them), and which need the mail sent first. Each recipe shows that character's skill-up chance. Profession buttons above the list filter it to one profession, and professions can be hidden for good in the Mail tab of the settings. The window can be resized with the grip in its bottom right corner (double-click the grip for the default size). |
| **Crafting profit** | With [Auctionator](https://www.curseforge.com/wow/addons/auctionator) installed, every recipe shows what it earns when crafted and sold at the auction house (the result's auction price x the items made x 0.95, minus what the ingredients cost; Auctionator's own formula). The recipes window and the materials window show it on each recipe and have a **Sort: Name / Sort: Profit** button, and the profession window's own recipe list can be sorted by profit too: its **Filter** menu gets a "Sort by (Jimmy's Utils)" section (Default or Crafting profit; not while the gamepad interface is on, and not with SkillUp Forever loaded, which sorts that list itself). `/ju profit` lists the open profession's recipes by profit in chat. Recipes whose result has no price show `?`; when only some ingredients have no price yet (vendor items Auctionator has not seen) the profit is shown greyed with a `~` and counts them as free. Switch it off in the Recipes tab of the settings; without Auctionator none of it shows and your choices are kept. |
| **Profession window** | An option in the Recipes tab of the settings (off by default) that keeps Blizzard's profession window open when you open other windows (character, spellbook, merchant, friends...) instead of closing or pushing it aside, and lets you drag it by its title bar; its position is saved. To do that the addon takes the window out of the game's window manager, which cannot be undone while the game runs: turning the option off needs a `/reload`, and Blizzard's behaviour comes back clean on the next load. |
| **Settings profiles** | Named sets of the settings of the whole addon (what is on or off, the display settings, the options of the recipes and materials windows, the minimap button...). Each character uses one profile: switch it in the **Profiles** tab and every setting changes at once; changes you make are kept in the profile you use. Create, copy, rename and delete profiles, and **Export** / **Import** any of them as a text string to share or move to another account. Stat weight scales are not part of a profile (they have their own Pawn import and export). `/ju profile` does the same in chat. |
| **Map pin** | `/ju pin 45.2 67.8` puts the map pin in your current zone at those coordinates (as the map shows them), or `/ju pin` alone where you stand, and turns on its in-world arrow; `/ju pin clear` removes it. |

Every feature can be switched on or off on its own. A minimap button (also listed in the addon compartment) opens the settings
with a left-click and the mail materials with a right-click.

## Importing Pawn scales

The **Stat Weights** tab has **Import** and **Export** buttons that read and write the scale tags of [Pawn](https://www.curseforge.com/wow/addons/pawn):

```
( Pawn: v1: "Warrior: Fury": Strength=1.5, Stamina=0.25, HitRating=2 )
```

**Import** opens a box: paste the tag and click **Import**. The tag becomes a new scale of that name (cut to 32 characters) and is switched to; the scale has exactly the
weights of the tag. If a scale of that name exists, the button asks for a second click and then replaces the weights the tag can express (the "Equip" effects and detected stats, which Pawn has no name for, are kept). **Export** shows the active scale as a tag, selected, ready
for Ctrl+C. `/ju scale import <tag>` and `/ju scale export` do the same in chat, but the chat takes at most 255 characters, so long tags need the buttons.

Only the stats this addon has are imported; the rest is skipped and listed in the chat message (`Imported 5 stats ...; skipped: FeralAp, Speed.`). `Class=` and `Spec=` are not stats and are not imported, and a value of `X` means "ignore this stat", as in Pawn.
Tags of a newer version than `v1` are refused. The names are not case sensitive.

**Tags with `Class=`:** Pawn writes only what you changed from its class template (the template's own values are left out of the tag, and Pawn's import puts them back). The templates are not
part of this addon, so such a tag imports only the weights it lists and the import warns that the other stats are missing (if nothing usable is listed, the import says so). For a complete
scale, in Pawn create the scale as an empty (custom) scale with no class, or use a tag made by a website, which lists every stat, and export that.

| Pawn name | Stat |
| --- | --- |
| `Strength`, `Agility`, `Stamina`, `Intellect`, `Spirit` | the primary stats |
| `Armor` | Armor |
| `HitRating`, `CritRating`, `HasteRating`, `ExpertiseRating`, `ArmorPenetration` | Hit, Critical Strike, Haste, Expertise, Armor Penetration |
| `SpellPenetration` | Spell Penetration |
| `Ap`, `Rap` | Attack Power, Ranged Attack Power |
| `SpellDamage`, `Healing` (and `SpellPower`) | Spell Power, Bonus Healing and Spell Damage, as Pawn scores them (see below) |
| `DefenseRating`, `DodgeRating`, `ParryRating`, `BlockRating`, `BlockValue` | Defense, Dodge, Parry, Block, Block Value |
| `Mp5`, `Hp5` | Mana per 5 sec., Health per 5 sec. |
| `FireResist`, `NatureResist`, `FrostResist`, `ShadowResist`, `ArcaneResist` | the resistances |
| `Dps` | Damage per Second |

Not imported: `FeralAp`, the spell damage of one school (`FireSpellDamage`...), `Speed`, `MeleeDps`, `MainHandDps`, `OffHandDps`, `RangedDps`, `MinDamage`, `MaxDamage`, the `Is...` flags and every other name not in the table. An export leaves out the stats Pawn has no name for (the "Equip" effects read from tooltip text, and detected stats).

**Spell power:** Pawn scores "+X damage and healing" as `SpellDamage` X plus `Healing` X, a healing-only line as `Healing` and a damage-only line as `SpellDamage`. Here Spell Power is the combined line, Bonus Healing the
healing-only line and Spell Damage the damage-only line. An import sets Spell Power to `SpellDamage` + `Healing` (+ `SpellPower`, the Wrath name), Bonus Healing to `Healing` and Spell Damage to `SpellDamage`. An export writes
`Healing` from Bonus Healing and `SpellDamage` from Spell Damage, or, when that is 0, from Spell Power minus Bonus Healing. This is exact for scales where Spell Power = Spell Damage + Bonus Healing (what an import makes) and an
approximation for others.

## Installation

**CurseForge:** install *Jimmy's Utils* with the CurseForge app.

**Manually:**

1. Download the latest release zip.
2. Extract it into `World of Warcraft\_forever_\Interface\AddOns\`, so that
   `_forever_\Interface\AddOns\JimmysUtils\JimmysUtils.toc` exists. The folder must be named `JimmysUtils`.
3. Restart the game.

Upgrading from **Jimmy's Stat Weights**? Your weights aren't picked up automatically; see
[Saved data](docs/GUIDE.md#saved-data) in the guide to move them over.

## Getting started

- Type `/ju` (or click the minimap button) to open the settings. It has one tab per feature (plus a last one, **Profiles**), and the first check box of each tab
  turns that feature on or off. Drag the grip in its bottom right corner to make the window larger (double-click it to go back to
  the default size); the lists grow with it and the size is remembered.
- **Stat weights:** set your weights on the *Stat Weights* tab, e.g. `/ju set crit 1.5`.
- **Range check:** pick a spell on the *Range Check* tab or with `/ju range <spell name>`. Enemy nameplates must be shown (V).
- **Recipe lookup:** bind a key under
  *Options > Keybindings > AddOns > Jimmy's Utils: Find recipes using hovered item*.
- **Mail:** the recent recipients panel appears on its own on the Send Mail tab; `/ju materials` opens the materials window.
- **Profiles:** the *Profiles* tab keeps named sets of all these settings: pick one to switch every setting at once (each character remembers its own), or **New** / **Export** to save and share the settings you have now.

## Commands

| Command | Effect |
| --- | --- |
| `/ju` | Open or close the settings |
| `/ju help` | List all commands |
| `/ju status` | Show which features are on |
| `/ju stats on\|off` | Stat weight scores on tooltips |
| `/ju set <stat> <number>` | Set a stat weight |
| `/ju scale [new\|copy\|rename\|delete\|show\|hide] <name>` | Manage stat weight scales; rename gives the active scale a new name (your other characters keep it as their active or hidden scale); show / hide lists a scale in item tooltips or leaves it out for this character |
| `/ju scale import <tag>` | Create a scale from a [Pawn scale tag](#importing-pawn-scales) (`/ju scale export` prints the active scale as one) |
| `/ju profile [<name>\|new\|copy\|rename\|delete\|export\|import]` | Settings profiles (the whole addon's settings, not the scales): list them, switch this character to one, save the current settings as a new one, copy, rename or delete, export one as a text string or import one. `/ju profile` used to be an unlisted alias of `/ju scale`; scales are only managed with `/ju scale` now |
| `/ju range` | Toggle the range check |
| `/ju range <spell>` | Choose the spell the range check uses |
| `/ju range size <12-128>` | Icon size |
| `/ju range nameplate\|screen` | Show it on the target's nameplate or at a fixed spot |
| `/ju recipes <item>` | Recipes that use an item (link, ID or name) |
| `/ju recipes on\|off` | Recipe lookup |
| `/ju mail on\|off` | Mail features |
| `/ju materials` | Open or close the materials window |
| `/ju profit [name]` | List the open profession's recipes by crafting profit, or show where one recipe's numbers come from (needs Auctionator) |
| `/ju minimap` | Show or hide the minimap button |
| `/ju pin` | Put the map pin where you stand |
| `/ju pin <x> <y>` | Put the map pin at those coordinates (0-100) of your current zone |
| `/ju pin clear` | Remove the map pin |

The complete list, with every option explained, is in the [full guide](docs/GUIDE.md).

## Compatibility

- Built for the **WoW Forever** client (interface `16001`).
- No library dependencies. [Auctionator](https://www.curseforge.com/wow/addons/auctionator) is optional: it gives the prices of the crafting profit.
- Settings are saved account-wide (settings profiles and which one each character uses, stat weight scales, recipes, mail recipients, each character's bags, bank and mailbox, the account bank) (including which scale each character has active and which scales each character hides from its tooltips) and per character (range spell). `/ju recipes forget <character>` also removes that character's saved items.

## Known limitations

- Addons can't open web pages, so Wowhead links are shown in a box to copy (Ctrl+C) and paste into your browser.
- The recipe lookup only knows the recipes in the bundled game data (see below) and the ones your profession windows show; a recipe in neither is unknown to it. A recipe that only the bundled data lists is not saved and shows under the client's name for its profession when the addon can tell it, else under the English one. The skill-up chances and the exact recipe-item links come from the same bundled data; a chance needs the character's profession skill, which is saved when you log in or open the profession window.
- The skill-up chance is the Classic formula applied to the game's own thresholds, not a number the game reports; where the game's difficulty color disagrees with the table, the chance is shown as `(?)` in the game's color.
- The auction house sorts its results on the server and hands them to the game page by page; sorting by a score only reorders the pages loaded so far (scroll down to load more, they are sorted in as they arrive), so rows can move when a page arrives. Scores come from the item key's tooltip data, which has no upgrade or scaling bonuses: an item whose level is set by such a bonus is scored by its base stats.
- The game only gives addons the first 50 letters of the inbox, so the materials window can miss items in older mail.
- The bags, bank and mail of your other characters are only as fresh as their last visit: log in on a character and open its bank (and mailbox) once to save them. The bank can only be read while it is open.

## Feedback

Found a bug or have an idea? [Open an issue](../../issues) with what you did, what you expected, and any error text
(`/console scriptErrors 1` shows Lua errors in game).

## License

Released under the [GNU General Public License v3.0](LICENSE).

The file `Data/RecipeData.lua` is generated from Blizzard's game data (the SkillLineAbility, ItemXItemEffect, ItemEffect, SpellReagents, SpellEffect and SkillLine tables of the WoW Forever client: skill-up thresholds, teaching items, skill lines and their names, ingredients, outputs and how many items a craft makes) as published by [wago.tools](https://wago.tools); the data belongs to Blizzard Entertainment. `python -I tools/gen_recipe_data.py` regenerates it.

*World of Warcraft is a trademark of Blizzard Entertainment, Inc. This addon is not affiliated with or endorsed by Blizzard.*

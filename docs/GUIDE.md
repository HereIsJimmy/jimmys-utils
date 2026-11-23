# Jimmy's Utils - full guide

A World of Warcraft: Forever addon with six small utilities (and a minimap button that opens the options window and the mail
materials, see [Minimap button](#minimap-button)):

- **Stat Weight** - adds one line to the tooltip of every equippable item:

  ```
  Stat Weight (Default)                      123.4
  ```

  The number is a weighted sum of the item's stats, using coefficients you choose. Higher is better for the weights you set.
- **Range check** - a small indicator that shows the icon of a spell you pick while your target is within range of it, and
  tints it red while it is not.
- **Recipe lookup** - point at an item and press a key (or type `/ju recipes <item>`) to list every recipe that uses it as an
  ingredient, the materials each one needs and which of your characters know it (the recipes nobody knows are listed too, in grey).
- **Recent mail recipients** - a small panel docked next to the Send Mail tab of the mailbox that lists the last 10 characters
  you sent mail to; click a name to fill in the "To:" box.
- **Recipe materials in your mail** - a window that lists the recipes your characters know which use items waiting in your
  mailbox, with how many of each ingredient they have (bags, bank and mail, saved for the characters you are not playing) and how many they
  still lack, so you can see which of your other characters could craft something with the mail.
- **Crafting profit** - with Auctionator installed, what a recipe earns when crafted and sold at the auction house, shown in the recipes
  window, the materials window and the profession window's own recipe list (through its Filter menu), see [Crafting profit](#crafting-profit).

Each of the four features (stat weight scores, range check, recipe lookup, mail) can be switched on and off on its own, see
[Feature toggles](#feature-toggles).

(It used to be called Jimmy's Stat Weights. The saved variables keep their old names, but the client names the saved file after the
addon folder, so existing data is not picked up automatically: see [Saved data](#saved-data) to move it over.)

## Installation

Copy the `JimmysUtils` folder into the Forever client's `World of Warcraft\_forever_\Interface\AddOns\` directory, so that
`_forever_\Interface\AddOns\JimmysUtils\JimmysUtils.toc` exists. The folder name must stay `JimmysUtils`, matching the
`.toc` file. Restart the client to pick up a newly added addon; `/reload` is enough after updating it.

## Usage

Open the options window with `/ju` (it toggles, and also works during combat), or with the **Open Jimmy's Utils** button
under **Game Menu > Options > AddOns > Jimmy's Utils**. It is a small movable window with four tabs, **Stat Weights**,
**Range Check**, **Recipes** and **Mail** (the last tab used is remembered); close it with its close button or Escape.

### Feature toggles

The first widget of every tab is the check box that switches that feature on or off. All of them start on, take effect at once (no
`/reload`), are remembered and have a chat command:

| Tab | Check box | Command | When it is off |
| --- | --- | --- | --- |
| Stat Weights | Enable stat weights | `/ju stats on` / `off` | No score lines (and no breakdown) are added to item tooltips. Profiles and weights can still be edited, and `/ju dump` still works |
| Range Check | Enable range check | `/ju range` (toggles) | The indicator is hidden and not updated |
| Recipes | Enable recipe lookup | `/ju recipes on` / `off` | Recipes are not saved, the key binding and `/ju recipes <item>` only say "Recipe lookup is off. Turn it on with /ju recipes on." and the recipes window (and the Wowhead link popup) closes. The saved recipes are kept (`/ju recipes status` and `forget` still work, and the mail materials keep using them) |
| Mail | Enable mail features (recent recipients and mail materials) | `/ju mail on` / `off` | The recent recipients panel is hidden and no recipients are recorded, the inbox is not scanned for materials, `/ju materials` says "Mail features are off. Turn them on with /ju mail on." and the materials window closes. The saved list and the last scan are kept |

Turning a feature back on resumes it where it can: tooltips at once, the range indicator at once, recipe saving at once, the mail panel the next time the Send Mail tab shows, and the mailbox is read at once when it is
open. `/ju status` prints one line per feature, on or off.

### Minimap button

A round button with the addon's icon (a gold gear) sits on the edge of the minimap:

- **Left-click** opens or closes the options window.
- **Right-click** opens or closes the **Materials in your mail** window, exactly like `/ju materials` (so with the mail features off it says
  "Mail features are off. Turn them on with /ju mail on." instead).
- **Drag** it with the left button to move it around the minimap; the position is saved as an angle and is not clamped to the screen.
  With a square minimap (a minimap addon that sets `GetMinimapShape`) it follows the square.
- Hovering shows a tooltip with these three hints.

Hide or show it with the **Show minimap button** check box at the bottom of the options window (under the tabs; it belongs to the addon,
not to a tab) or with `/ju minimap`; `/ju minimap reset` moves it back to its default place (bottom left). The addon also has an entry in
the minimap's addon compartment menu (the button that lists addons): left-click opens the options window, right-click the materials, and the
tooltip is the same. That entry does not depend on the minimap button being shown.

### Map pin

`/ju pin <x> <y>` puts the map pin (the waypoint you get by shift-clicking the map) in the zone you are in, at the coordinates the map shows (percent,
0 to 100), and turns on its arrow in the world, like setting it on the map yourself. For example `/ju pin 45.2 67.8` prints
`Map pin set in <zone> at 45.2, 67.8.` followed by a link you can shift-click to share. The coordinates can be written `45.2 67.8`, `45.2, 67.8`,
`45.2,67.8` or `45 67`, and with decimal commas when a space separates the numbers (`45,2 67,8`). Anything else prints the usage, and a number outside
0 to 100 says so. `/ju pin` with nothing after it puts the pin where you stand (inside instances, where the game does not give your position,
it says so). `/ju pin clear` (or `/ju pin remove`) takes the pin away and turns its arrow off.

If the client does not know which zone you are in, or does not allow a pin in it (some zones and instances do not), the command says so and does nothing.
The command works on the zone you are standing in, not on the map window you have open. Nothing is saved.

### Stat Weights tab

There you can:

- switch the score lines on item tooltips on or off (the first check box; see [Feature toggles](#feature-toggles)),
- create, copy, switch and delete profiles (Delete asks for a second click; each character remembers its own active profile;
  profiles themselves are shared account-wide),
- choose how many decimals the score shows, whether a score of 0 is hidden, whether "Equip:" text is read, and when the per-stat
  breakdown is displayed,
- edit the weights. The **Weights** list shows only the stats that currently have a weight; type a new number in a weight box
  and press Enter to change it. Click the **x** next to a stat (or type `0`) to remove it from the list, which sets its weight
  to 0 and makes it ignored,
- add a stat: pick it in the dropdown under the list (it offers every stat that has no weight yet, including stats detected on
  items), type its weight (default 1) and click **Add**.

By default primary stats (Strength, Agility, Stamina, Intellect, Spirit) have a weight of 1 and everything else 0.
Blizzard's **Defaults > All Settings** only resets this addon's display options, never your weights; use **Reset weights** (it asks for a second click)
(or `/ju reset`) for that.

The profile name is shown in the tooltip line only when you have more than one profile.

### Range Check tab

- **Enable range check** (the first check box) turns the indicator on or off.
- **Spell**: pick a spell from the dropdown (it lists the harmful spells in your spellbook that have a range, with their icons;
  **None** at the top clears the choice), or type a spell name, spell ID or shift-clicked spell link into the box and click **Set**
  (or press Enter). A typed spell is always accepted, with a warning if it is not harmful, has no range or is not known by the
  character, since the indicator would then never show. The chosen spell is stored per character, because spells depend on your
  class, as its base spell so it keeps working when a talent overrides it. The current spell is shown with its icon.
- **Position**: **On target nameplate** (the default) shows the indicator just to the right of your target's nameplate health
  bar and moves it along with the plate; **Fixed on screen** keeps it at a spot you choose. The nameplate mode needs enemy
  nameplates to be shown (default key V); without a nameplate for the target (nameplates off, target out of view) the indicator
  is hidden. On a nameplate the indicator follows the plate's scale and transparency (smaller far away, faded without line of
  sight) and moves out of the way of the crowd control icons Blizzard shows next to the health bar. The mode is shared by all
  your characters, and settings saved by older versions switch to the nameplate mode.
- **Lock position** (fixed on screen only; disabled in nameplate mode): while unlocked the indicator is always shown (even when
  disabled or without a spell or target) with a faint background and a label, and can be dragged with the left mouse button. Lock
  it again when it is where you want it.
- **Size**: type the icon size in pixels, any whole number from 12 to 128 (Enter or clicking away applies it, Escape
  cancels), or use `/ju range size <12-128>`. **Reset position** (fixed on screen only) puts the screen position back at the default spot
  (slightly below the screen center). The size and the screen position are shared by all your characters.

The range check is meant for enemies. The indicator is only shown when the feature is enabled, a spell is chosen, your target is alive and attackable, and, in nameplate mode, the target has a nameplate. It shows the
spell's icon (with a thin black border): in its normal colours when the target is within range of the spell, tinted red when it is not.
It follows talent and form overrides of the spell, and shows a question mark if the client gives no icon. It stays hidden if the game cannot give
a range for the spell (for example a spell without range, or one your character does not know). It works in combat.

### Recipes tab and recipe lookup

Jimmy's Utils saves, account-wide, the recipes of your characters: their ingredients and whether each character knows them. Two
sources feed it. The bundled game data (`Data/RecipeData.lua`) lists the recipes of each profession with their ingredients and
output; for each profession of the character, `IsPlayerSpell` tells which of those recipes it knows, so no profession window is needed.
Only recipes the character knows are saved from it (never the unknown ones), and a recipe the character no longer knows is unmarked.
Whenever one of **your own** profession windows opens (or its list updates) the recipes it lists are read too: that covers recipes
the bundled data misses, and a recipe saved from a window keeps its richer data (for example slots with a choice of items). Linked
professions, guild and guild member windows, runeforging and NPC crafting windows are ignored. A profession window that is still
loading is waited for, and closing the window cancels a pending scan. The profession window's own settings are never changed.

The **Enable recipe lookup** check box at the top of the tab (or `/ju recipes on` / `off`) switches both the saving and the lookup:
see [Feature toggles](#feature-toggles).

To look an item up:

- **Key binding**: hover an item (bags, equipment, vendors, item links in chat...) and press the key you assigned to "Jimmy's
  Utils: Find recipes using hovered item" under **Options > Keybindings > AddOns**. No key is assigned by default.
- **Slash command**: `/ju recipes <item link | item ID | item name>`. Shift-click an item into the chat box to get a link. A name
  is matched against the names of ingredients saved so far, case-insensitively for ASCII letters (other characters must match as
  they are): an exact match first, then a part of the name. When
  several items match, up to five are listed in chat with their IDs; use the ID or a longer name.

A window titled "Recipes using <item>" lists every recipe that uses the item as a basic ingredient: the saved recipes (optional
and finishing reagents are not saved) and every recipe of the bundled game data whose ingredients include it (see Data source below),
including the ones none of your characters knows. Each row has the recipe icon and name, the quantity of the item it needs (`x2`), and a line with its
profession and either `Known: Jamie, Khaz` (characters of your current realm are shown without their realm) or `Not known by your characters`.
Under it comes the full list of materials for one craft with their quantities, for example `Silverleaf x1, Earthroot x1, Empty
Vial x1`; an ingredient is green when the character you are playing has enough of it for one craft (bags, bank, reagent bank and account bank together), orange when you have some but not enough (then it shows what you have against what is needed, e.g. `Silverleaf (1/3)`), and red when you have none, and the colors follow your bags while the window is open; the tooltip says how many you have. The list follows the order of the recipe's ingredient slots. A slot
that accepts several items (for example the quality tiers of an herb) shows the first one followed by `(any quality)`. Recipes
saved before the slots were kept list their ingredients by name instead. An item name the client has not given yet shows as
`item:<id>` and is filled in, and the window refreshed, as soon as the client reports it. The row grows to fit a long list, so
nothing is cut off. Recipes somebody knows come first, then the ones nobody knows (their name is grey), each group sorted by profession and name. Hovering a row shows the
tooltip of the item the recipe makes (or of the recipe itself when it makes no item), followed by the materials, the list of
characters that know it (or "Not known by your characters."), the skill-up chance, and, only when the game gave one, the "Where to get it" text. The footer shows how many recipes are saved
and from which professions (the recipes only the bundled data lists are not saved and not counted there).

After a recipe's name the row shows its **skill-up chance**, for example `(88%)`, in the official difficulty colors: orange when it is
a sure skill-up (100%), yellow, green, and grey (0%). It is the chance for the character you are playing when it knows the recipe,
otherwise for the character that knows the recipe and has the best chance; the tooltip names that character. A recipe none of your
characters know shows no chance (the game data does not say what skill is needed to learn it). Nothing is shown either while the skill of
the characters that know it has not been seen (the skill is saved at login and when you open the profession window).

Every row has a small **Wowhead** button. The client cannot open web pages, so it opens a small window titled "Wowhead links" with
the recipe's name and two boxes to copy from. When the bundled data knows which item teaches the recipe (see [Skill-up chance and
recipe items](#skill-up-chance-and-recipe-items)) the first box, **Recipe item**, is the exact page of that item
(`https://www.wowhead.com/forever/item=<item ID>`). Otherwise an addon cannot ask which item teaches a recipe, so the first box,
**Recipe item (search)**, is a Wowhead search for that item's name, which is the profession's prefix plus the recipe name
(`https://www.wowhead.com/forever/search?q=Recipe%3A+Minor+Healing+Potion`, with spaces as `+` and other characters
percent-encoded). The second box, **Recipe spell**, is the page of the recipe's spell
(`https://www.wowhead.com/forever/spell=<recipe ID>`). Recipes the game data has no teaching item for (taught by a trainer, a quest...) have no item, so the window shows only the spell page for those.
The prefixes (used only for the search) are:

| Profession | Prefix |
|---|---|
| Alchemy, Cooking | `Recipe` |
| Blacksmithing | `Plans` |
| Leatherworking, Tailoring | `Pattern` |
| Engineering | `Schematic` |
| Enchanting | `Formula` |
| First Aid | `Manual` |
| Jewelcrafting | `Design` |
| Inscription | `Technique` |

For any other profession, or a client in another language (profession names are compared in English), the first box searches the
plain recipe name and is labelled **Search**. The first box is selected: press Ctrl+C and paste into your browser (the window then
closes by itself; Escape closes it too). The boxes cannot be edited. Without a recipe ID only the search box is shown. The base
address is the `WOWHEAD_BASE` constant and the prefixes are the `RECIPE_ITEM_PREFIXES` table at the top of `Recipes.lua`.

**Double-click a row** to open that recipe in your profession window (`C_TradeSkillUI.OpenRecipe`, the same call Blizzard's
recipe tracker uses). This works only for recipes the character you are playing knows; the row's tooltip says
"Double-click to open it in your profession window." on those. For other recipes a chat line says who knows it.

**Profession filter.** When the results hold recipes of more than one profession, a row of small buttons appears above the list
(**All** and one per profession, wrapping onto more rows when they do not fit); click one to list only that profession's recipes. The choice
is kept until you close the game and goes back to **All** when its profession is not in the results of the next lookup.

**Only my professions.** The check box at the top of the window, under the item, keeps only the recipes of the professions the character
you are playing has (**Only Jamie's professions**; a long name makes it **Only my professions**). A recipe of the bundled data counts by its skill line,
any other saved recipe by the profession name it was saved under; a recipe the character knows always counts, and when the client does not give the
character's professions (not loaded yet) the check box filters nothing. The choice is saved for your whole account (`recipeLookup.onlyMyProfessions`, off by default),
and switching it refreshes the window and goes back to the top of the list. It is applied first: the professions hidden in the settings are dropped
from what it leaves (so the *x2* counts below only count those recipes), and the profession buttons are built from what remains. When it leaves nothing, the
window says *None of these recipes belong to your professions.*

**Profession names.** A bundled recipe is shown under the name the client gives its skill line when the addon can tell it: the name of one of
your character's professions, or the spelling the saved recipes of that skill line use; otherwise under the English name from the bundled data.
Names are compared without regard to case, so they meet the ones already saved (a client in another language therefore shows one button per
profession, not two).

**Hiding professions for good.** Under **Professions shown in the window** on the Recipes tab, right under the saved recipes, there is one check box per
profession found in the saved recipes or in the bundled recipes (so every profession button of the window can be hidden); uncheck one to leave that profession out of this window (checked means shown). The choice is saved for your whole
account (`recipeLookup.hiddenProfessions`) and an open window follows at once. Hidden professions are dropped before the buttons are built, so the
buttons only offer what is left. A small line above the buttons says *Professions can be hidden permanently in the settings (/ju).* in grey while the
buttons are shown, and, in orange, *Hidden in the settings: Alchemy x2, Cooking* whenever something is hidden (even with no buttons; *x2* is the number of that profession's recipes left out of this window, and a hidden profession with none is just its name, after the others); when hiding leaves
no recipe, the window says they are all hidden by the profession settings. The materials window has its own list, on the Mail tab.

**Recipes nobody knows.** The window does not need the profession windows for them: every recipe of the bundled game data that uses the item is
listed, after the known ones, with its name in grey, the status `Not known by your characters` and the materials colored by what you have. Nothing is
saved for them, and the materials window and the saved-recipe counts stay on the recipes your characters know. A recipe whose name the client has
not loaded yet shows as `Recipe <id>`; the name is asked for (a few times per session at most) and the window is refreshed when it arrives.
Its Wowhead links work as for any row. Double-clicking opens only recipes the character you are playing knows; for the others a chat line says
who knows it (or that nobody does). Recipes that another character knows always show `Known: <name>`. `/ju recipes status` still shows whether
`C_TradeSkillUI.GetAllRecipeIDs` exists and, for an open profession window, how many recipes it returns and how many are not learned.

The **Recipes** tab explains this, shows the current key (or how to set one), the number of saved recipes per profession, and has
a **Forget saved recipes** button (it asks for a second click). Saved recipes are listed under Saved data below. A character that
drops a profession is taken off the recipes of that profession when the game reports its professions (at login and when skills change).

**Resizing.** The recipes window has a grip in its bottom right corner (like the chat frame's): drag it to make the window wider or taller (the default size is the smallest, the largest is twice that or what the screen holds), double-click it to go back to the default size. Everything in the window follows the width; the size is remembered for all your characters (`recipeLookup.size`).

#### Skill-up chance and recipe items

The game does not tell addons the chance of a skill-up, only the colour of a recipe (orange, yellow, green or grey). Jimmy's Utils
bundles the thresholds of every profession recipe, taken from the game's own data, and uses the Classic rule: below the yellow skill
a recipe is orange and always gives a skill-up; from the yellow skill to the grey skill the chance falls in a straight line from 100%
to 0% (`(grey - skill) / (grey - yellow)`; green is halfway between yellow and grey, rounded down); from the grey skill on it is 0%.
There is no skill-up at the profession's maximum skill, so a profession at its maximum shows 0%. For example Minor Healing Potion
(yellow 55, green 75, grey 95) at skill 60 shows `(88%)` in yellow, at skill 75 `(50%)` in green and at skill 95 `(0%)` in grey.
The percentage is rounded, but is never shown as 0% or 100% unless it is exactly that (`<1%`, `99%`).

Each character's skill in each profession is saved account-wide (`recipeSkill`): from the profession window when you open it and from the
skill list at login and whenever a skill changes, so the chance follows a skill-up while the window is open. While the profession window is
open the game's own colour of each recipe is also used as a cross-check: when the table and the game disagree about the colour (for example
the game says orange but the table says yellow), the game's colour is used and the number is replaced by `(?)`. The same happens for a
recipe the table has no thresholds for, when the game's colour is known. With neither, nothing is shown. The tooltip line reads, for example,
`Skill-up chance: 88% (yellow 55, green 75, grey 95; your skill 60)`.

The same data names the item that teaches each recipe (the lowest item ID when several do), which is what the **Recipe item** box of the
Wowhead window shows. Recipes the game data has no teaching item for (trainer, quest...) show only the spell page: there is no item to search for.

**Data source.** `Data/RecipeData.lua` is generated and must not be edited. It holds `ns.RecipeThresholds[spellID] = { yellow, grey }`,
`ns.RecipeTeachers[spellID] = itemID` (the recipe ID the profession window uses is the spell ID), `ns.RecipeSkillLines[spellID] = skillLineID` (a sorted list `{ line, line }` for the few recipes that belong to several),
`ns.RecipeReagents[spellID] = { itemID, count, itemID, count, ... }`, `ns.RecipeOutputs[spellID] = itemID`, `ns.RecipeOutputCounts[spellID] = count` (only for the recipes that make more than one item) and `ns.SkillLineNames[skillLineID] = "Alchemy"` (the English name of
each skill line the recipes use), taken from the SkillLineAbility, ItemXItemEffect, ItemEffect, SpellReagents, SpellEffect and SkillLine tables of the WoW Forever client build named in the file's header, as published by wago.tools. They are
Blizzard's game data; this addon is not affiliated with or endorsed by Blizzard. To regenerate it for a newer client build, change the `BUILD`
constant in `tools/gen_recipe_data.py` and run, from the addon folder, `python -I tools/gen_recipe_data.py` (Python 3, standard library only;
`--cache <folder>` keeps the downloaded CSV files, `--refresh` downloads them again). The script refuses to write the file if it no longer
finds the known recipes it checks against.

### Per-stat breakdown

The breakdown (one gray line per weighted stat, e.g. `Strength  25 x 1 = 25`) can be set to always show, to show while holding
Shift, Alt or Ctrl (default: Alt), or to never show. Tooltips of bag and equipped items refresh on their own, so pressing the key
while hovering works; for tooltips that don't refresh (e.g. a clicked chat link), hold the key before opening the tooltip.

### Recipe materials in your mail

While the mailbox is open, the addon keeps a record of the inbox (the letters the client has loaded, up to 50). `/ju materials` opens a
window titled **Materials in your mail** that lists the recipes which use items from that mail, grouped by character: **the current
character first** (`Jamie (this character)`), then **your other characters on the same realm** that know such a recipe, by name (mail cannot
cross realms, so characters of other realms are never listed). Each recipe has a header with its icon, name and profession, and either
**Craftable** (green) or **Missing N items** (orange: the total number of ingredient items still lacking for one craft), followed by one
line per ingredient:

```
Silverleaf  3/5 (2 in mail) - need 2 more
```

After the recipe's name the header shows the **skill-up chance** of the character the group is about, for example `(88%)`, in the
official difficulty colors (orange 100%, yellow, green, grey 0%); see [Skill-up chance and recipe items](#skill-up-chance-and-recipe-items).
Nothing is shown when that character's skill in the profession has not been saved yet. The header's tooltip has the numbers.

`3/5` is what the character has against what one craft needs. A line is red while something is missing and green when there is enough.
`(COD)` marks ingredients that come in a letter with a cash on delivery request. An ingredient that comes in several interchangeable items
(for example the quality tiers of an herb) is one line, marked `(any quality)`: what the character has of all of them is added up against the
quantity the recipe needs, as in the game's own recipe tracker, and the name shown is the item it has most of. Recipes saved by an older
version have one line per item until their profession window is opened again. Within a character, craftable recipes come first, then the
ones with the fewest missing items, then by name. Double-click a recipe's header to open it in your profession window (only recipes of the
current character: for another character's recipe the chat says who knows it; log in to that character to craft it).

When the recipes shown belong to more than one profession, a row of **profession buttons** (**All** and one per profession) sits above the
list; click one to see only that profession's recipes in every character's group (a character with none is hidden). The choice is kept for
the session and goes back to **All** when its profession leaves the list, for example after checking **Only my recipes**.
Professions can also be hidden for good with the check boxes under **Professions shown in the window** on the **Mail** tab of the settings (saved
for your whole account as `mailMaterials.hiddenProfessions`, separate from the recipes window's list); the same line above the buttons tells which are hidden.

What counts for each character:

| | Counts | Shown as |
|---|---|---|
| **Current character** | its bags and reagent bag (live), its **saved bank** and the **saved account bank**, and the mailbox you have open. Until its bank has been saved once, the game's own live count (with the bank and account bank) is used instead, and the saved account bank is not added on top | `(N in mail)` |
| **Another character** | its **saved bags, bank and account bank** (what its last visit saw), its **own saved mailbox**, and the items in the mailbox you have open, which could be sent to it | `(N in their mail)` and `(N in your mail)` |

A recipe is listed for a character when one of its ingredients is in the mailbox you have open or in that character's own saved mailbox. When
a character needs items from the mailbox you have open to complete a recipe (its own items fall short), the recipe says **Craftable after
mail** (hover it for "Craftable after sending the mail items."): send those items to that character first. The current character's own mail
is never counted twice. The grey line under each character's name says how old what is known of its items is: `bags 2 hours ago, bank 3 days
ago, mail 1 day ago, account bank 1 day ago`, or `bank never seen - open the bank on that character` when its bank was never opened with this
addon (the bank of the current character: `open your bank to include it`), or `mailbox never seen` (with `(items sent 5 minutes ago)` for
items you mailed to it from another character since its last scan).

The check box **Only <name>'s recipes** at the top of the window ("Only my recipes" when the name does not fit; saved, off by default) limits the list to the current character.

- **Resizing.** A grip in the bottom right corner (like the chat frame's) resizes the window: drag it, double-click it to go back to the default size, which is also the smallest (the largest is twice that or what the screen holds). The rows follow the width, a taller window shows more of them, and the size is remembered with the position (`mailMaterials.size`).
- **Opening it.** Only `/ju materials` opens it (and closes it again); it never opens by itself. Close it with its close button or Escape.
  While it is open it follows mailbox and bag changes. It can be moved; its position is remembered. Until you move it, it sits to the
  right of the mailbox, the open letter and the recent recipients panel.
- **Away from the mailbox.** The last scan of each character's mailbox is saved (when, and which items), so `/ju materials` also works
  elsewhere, and the window says how old the mail data is ("From your mailbox, 5 minutes ago"). The bag counts of the current character are
  always current and follow bag changes while the window is open. The snapshot of a mailbox is only refreshed at that character's mailbox.
- **Saved items of your characters.** The addon saves what each character carries, account-wide (see Saved data): the bags on login and
  whenever they change; the bank (the character's bank tabs) **only while the bank is open**, and it keeps the last snapshot after closing
  it; the account (warband) bank when you visit a bank that can show it, one snapshot for every character; and each character's mailbox. A
  character's data is only as fresh as its last visit. Items you mail to one of your other characters (a recipient written as `Name`, the WoW Forever two-part `Name Surname`, or
  either with `-Realm`, in any case, on the current realm; the first name is what identifies the character) are added to that character's saved mailbox when the game confirms the letter; the
  character's next scan of its own mailbox replaces everything.
- **Forgetting a character.** `/ju recipes forget <character>` removes the character's recipes together with its saved profession skills, bags, bank and
  mailbox. Characters that are not saved as knowing a recipe are not listed anyway. Forgetting the character you are playing (or every recipe)
  does not last: the next learning pass saves the recipes that character knows again automatically, and the command's answer says so.
- **More than 50 letters.** The client lists at most 50 letters at a time; the window then says "Only the first 50 mails are scanned; take some
  mail to see the rest."
- **Recipes.** The recipes are the ones saved by the recipe lookup.
  Without any (for every character that is shown), the window says so.
- **Limits.** Mail sent to one of your characters is added to its saved mailbox when the game confirms the letter. If you close the mailbox before the
  confirmation arrives, the letter is not recorded (the addon forgets unconfirmed letters when the mailbox closes), and mail that is returned to you,
  or that a character takes out of its mailbox, is only noticed at that character's next mailbox visit. Other characters' bags, bank and mailbox are as old as
  their last visit (the window shows how old), and the account bank is one shared snapshot.

The **Mail** tab ends with a one-line reminder of the `/ju materials` command.

### Crafting profit

With [Auctionator](https://www.curseforge.com/wow/addons/auctionator) installed (an optional dependency), Jimmy's Utils reads its prices through
Auctionator's public API and shows what a recipe earns when its result is sold at the auction house. The formula is Auctionator's own:

```
profit = auction price of the result x items made x 0.95 - cost of the ingredients
```

An ingredient costs its vendor price when Auctionator knows one, else its auction price (a vendor price more than five times the auction price is
passed over for the auction price, as Auctionator does). An ingredient slot with alternative items (the quality tiers of an herb) counts at its
cheapest priced item. The number of items a craft makes is read from the profession window when a recipe is saved (`outputCount`), from the bundled data
(`ns.RecipeOutputCounts`, only the recipes that make more than one) for a recipe that was never saved, and is 1 when nothing says. When the result
has no price the profit is unknown and shows as a grey `?`; a price of 0 counts as no price. Vendor-only ingredients (thread, vials, flux) often have no
price until Auctionator has seen them at a merchant, so when only some ingredients are unpriced the profit is *partial*: those ingredients count as free and
the profit is shown greyed with a `~` before it. A profit of 0 or more is green, a loss red.
The tooltip of a recipe (in the recipes window and the materials window) adds what the ingredients cost, what the result sells for, how old
the oldest auction data used is and, for a partial profit, which ingredients have no price yet (visit a vendor or scan the auction house). Items are priced by
their base item ID, so gear with a random suffix gets the price of its base item. Prices are read again on every refresh of a window; Auctionator's own data only changes when you scan the auction house.

- **Recipes window and materials window.** When prices are available a **Sort: Name** / **Sort: Profit** button appears in the header (the choice is saved
  for all your characters, with each window's settings: `recipeLookup.sortProfit`, `mailMaterials.sortProfit`) and every recipe shows its profit on its
  second line. Sorted by profit the most profitable recipes come first (a partial profit counts with its value, after a fully priced one of the same value), then the losses, and the recipes whose profit is unknown last, each group in the window's usual order;
  in the materials window this orders the recipes inside each character's group.
- **Blizzard's recipe list.** The **Filter** menu of the profession window's recipe list gets a **Sort by (Jimmy's Utils)** section with the radios
  **Default** (the client's own order) and **Crafting profit** (saved as `profit.listSort`: `blizzard` or `profit`; shown only while profits are available).
  With the profit sort the learned recipes are listed flat by profit, highest first (a partial profit counts with its value, recipes whose profit is unknown
  last, ties by name), then Blizzard's own divider and the unlearned recipes in the client's order. The list is flat while it is sorted: the client's category headers
  are not shown and so a category's collapsed state is not remembered (the client's own list comes back, as it was, with **Default**); your favorites are listed
  first (sorted too) as well as in their place, because the client selects them by that row. It reorders the client's own list: the rows are the client's, so a click on
  one is the client's own click, and the addon never selects a recipe or rebuilds the page itself. A list that is already in that order is left alone (which
  keeps the selection), the profession window of another player or an NPC keeps the client's list, and if the sort ever fails it turns itself off with one
  message. It does not re-sort on its own when a price changes: it follows the next time the client rebuilds its list or you choose the radio again. The
  section is not added while the gamepad interface is on (the client opens that menu itself and a section added by an addon would taint it; it comes
  back for mouse and keyboard); under the gamepad interface the **Sort the profession window's recipe list by profit** check box in the *Recipes* tab does the same
  as the menu (and is how to go back to Default there). **SkillUp Forever** sorts this list itself (its own *Sort by* has *Highest craft profit*): while it is loaded this addon
  never touches the list, and the radio is shown disabled saying so.
- **`/ju profit`** lists the learned recipes of the open profession in chat, in the order of the Filter-menu sort (by profit, highest first, a partial profit by
  its value, unknown last, then by name) with their value, cost and profit; `/ju profit <name>` shows where one recipe's numbers come from (the price of its
  result by link and by item ID, and every ingredient's vendor and auction price).
- **Option.** *Recipes* tab: **Show crafting profit (needs Auctionator)**, on by default. Off hides the sort buttons and the profits, puts the client's order back
  in the profession list and reads nothing from Auctionator.
- **Without Auctionator** (not loaded, loaded after this addon, or its price database not made yet at login: the addon notices) all of that behaves as if it were off: the Filter menu has no section and
  the list is the client's, the windows sort by name without their sort buttons, and the option shows unchecked and greyed out with a note. Nothing you chose is
  overwritten (the option, the list sort and the windows' sorts stay saved), so it all comes back as it was once Auctionator is there.

### Mail tab and recent mail recipients

Whenever a letter is sent successfully, its recipient goes to the top of a list of the last 10 recipients of the realm you are on
(the list is account-wide, one list per realm, so your characters on a realm share it). While the **Send Mail** tab of the mailbox
is showing, a small panel titled **Recent recipients** is docked to the right of the mailbox window (or of the open letter, while one
is open) with that list:

- **Left-click** a name to put it in the "To:" box (only the text is set: the focus and cursor are left alone).
- **Right-click** a name to take it off the list.
- A name is stored as you typed it (trimmed); sending to the same name again, in any capitalization, moves it to the top and keeps the
  newest spelling. The count shown on the **Mail** tab and by `/ju mail` is the number of names saved for the realm. `Name` and `Name-Realm` count as different recipients. Your current character is never listed (on WoW Forever, its full `Name Surname` or `Name-Surname`, with or without the realm). A letter that fails
  to send, or that is still being sent when you close the mailbox, is not added.

The **Mail** tab has an **Enable mail features (recent recipients and mail materials)** check box, the master switch of both mail
features (while it is off the panel is hidden, no recipients are recorded and the mailbox is not scanned for materials; what was saved is
kept), a **Clear recent recipients** button, which empties the list of the current realm, and the **Professions shown in the window** check boxes of the
materials window (see [Recipe materials in your mail](#recipe-materials-in-your-mail)).

### Mailbox button

A small button is added to Blizzard's mailbox. It is shown only while the mail features are on (it appears or disappears at once when
you switch them with `/ju mail on` / `off` or the check box).

- The button has the addon's icon in the title bar of the mailbox, just left of its close button. It shows on both the
  **Inbox** and the **Send Mail** tab, opens or closes the **Materials in your mail** window exactly like `/ju materials`, and has the tooltip
  "Materials in your mail" (recipes your characters know that use items in your mail). The window still never opens by itself.

## Slash commands

`/ju` or `/jimmysutils` (`/jsw` and `/statweights` still work as aliases):

| Command | Effect |
| --- | --- |
| `/ju` or `/ju config` | Open or close the options window |
| `/ju help` | List the commands |
| `/ju status` | Show whether each feature (stat weight scores, range check, recipe lookup, mail) is on or off |
| `/ju stats` | Show whether the stat weight scores on item tooltips are on |
| `/ju stats on` / `/ju stats off` | Turn the stat weight scores on item tooltips on or off |
| `/ju list` | Show the non-zero weights of the active profile |
| `/ju set <stat> <number>` | Set a weight. `<stat>` is a stat key, a label, or a unique label prefix (case-insensitive); `,` is accepted as decimal separator. Example: `/ju set crit 1.5` |
| `/ju profile` | Show the active profile and all profiles |
| `/ju profile <name>` | Switch to a profile (an existing profile name always wins, so a profile called "New Tank" can be selected) |
| `/ju profile new <name>` | Create a profile with the default weights and switch to it |
| `/ju profile copy <name>` | Copy the active profile and switch to the copy |
| `/ju profile delete <name>` | Delete a profile (the last one cannot be deleted) |
| `/ju reset` | Reset the active profile's weights to the defaults |
| `/ju dump <item link>` | Shift-click an item into the chat box to see what the API reports for it and how it is scored |
| `/ju range` | Turn the range check indicator on or off (it toggles) |
| `/ju range <spell name or id>` | Choose the spell the indicator checks (this character) |
| `/ju range clear` | Forget the chosen spell (a spell literally named "clear" can be set by its ID) |
| `/ju range unlock` / `/ju range lock` | Allow dragging the indicator / fix it in place (fixed screen position only) |
| `/ju range size <12-128>` | Icon size in pixels |
| `/ju range nameplate` / `/ju range screen` | Show the indicator on the target's nameplate (default) / at a fixed spot on the screen (a spell literally named "nameplate" or "screen" can be set by its ID) |
| `/ju recipes on` / `/ju recipes off` | Turn the recipe lookup (learning recipes and the lookup) on or off; the saved recipes are kept |
| `/ju recipes <item link \| item ID \| item name>` | Open the list of saved recipes that use the item as an ingredient |
| `/ju recipes` | The same for the item you are pointing at (prints the usage when there is none) |
| `/ju recipes status` | Show how many recipes are saved, per profession and per character, and what the client gives the addon: whether `GetAllRecipeIDs` exists and, with a profession window open, how many recipes it and `GetFilteredRecipeIDs` return and how many are not learned (`scan` still works as an alias; this command does not save anything itself) |
| `/ju recipes forget` | Ask to delete the saved recipes; `/ju recipes forget confirm` really deletes them |
| `/ju recipes forget <character>` | Ask to remove one character (`Name`, or `Name-Realm` when the name exists on several realms) from the saved recipes, together with its saved bags, bank and mailbox; add `confirm` to do it |
| `/ju mail` | Show whether the mail features (recent recipients and mail materials) are on, how many recipients are saved for this realm, and the usage |
| `/ju mail on` / `/ju mail off` | Turn the mail features on or off: the recent recipients panel and its recording, and the mailbox scan and window of the mail materials |
| `/ju mail clear` | Forget the recent recipients of the current realm |
| `/ju minimap` | Show or hide the minimap button (prints which) |
| `/ju minimap reset` | Move the minimap button back to its default place (bottom left) |
| `/ju pin` | Put the map pin where you stand, in your current zone, and turn on its arrow |
| `/ju pin <x> <y>` | Put the map pin in your current zone at those coordinates (percent as the map shows them, 0-100, e.g. `/ju pin 45.2 67.8`) and turn on its arrow; prints the zone and a link to share |
| `/ju pin clear` | Remove the map pin (`/ju pin remove` does the same) |
| `/ju materials` | Open or close the window with the recipes your mail has materials for, for this character and your other characters on this realm (check box **Only my recipes** for this character alone) (works away from the mailbox, from the saved scans; says so when the mail features are off) |

## How the score is computed

```
score = sum over all stats on the item of (stat value x your weight for that stat)
```

Stats with a weight of 0 do not contribute. The tooltip line is hidden for items whose score is 0 unless you turn off
"Hide score when 0".

## Forever-specific notes

- **Primary source: `C_Item.GetItemStats`.** Forever removed the old global `GetItemStats`/`GetItemInfo`, so the addon reads item
  stats from the `C_Item` namespace. Stat names come from the client's own global strings and are therefore localized.
- **"Equip:" text fallback (English clients only).** Some effects (for example "Equip: Improves your chance to hit by 1%") may not
  appear in the API result. If the option is enabled and the client locale is `enUS` or `enGB`, such lines are read from the tooltip
  text. Effects in the same unit as an API stat (attack power, spell power, bonus healing, mana/health per 5 sec., block value,
  spell penetration) count under that stat with its weight and show as e.g. `Mana per 5 sec. (Equip)` in the breakdown, so there
  is only one weight to set. Percentage effects (hit, crit, haste, dodge/parry reduction, dodge, parry, block) and defense skill
  differ in unit from the API's ratings, so they have their own "(Equip)" entries under "Equip effects" in the options window. Equip
  text is only used when the API reported none of the stats it corresponds to, so nothing is counted twice.
- **Secret values.** Forever uses the same restriction system as the Midnight client. Any value from tooltip data that is a secret
  value is ignored rather than processed, and the addon only uses `TooltipDataProcessor.AddTooltipPostCall`, so it does not taint
  Blizzard tooltips.
- **Range check.** It reads `C_Spell.IsSpellInRange(spell, "target")` about ten times a second, and only while you have a target.
  If the game ever returns that result as a secret value, the addon does not branch on it; it colours the icon with
  `SetVertexColorFromBoolean` (white in range, red out of range) instead. In nameplate mode the addon finds the plate with
  `C_NamePlate.GetNamePlateForUnit("target")` (inside a `pcall`), parents its own indicator frame to it and anchors it to the
  plate's health bar; it only reads Blizzard's nameplate frames and never modifies or hooks them. It re-anchors on target changes
  and on `NAME_PLATE_UNIT_ADDED` / `NAME_PLATE_UNIT_REMOVED`. The icon is `C_Spell.GetSpellTexture(spell)`, refreshed when the spell changes and on
  `SPELLS_CHANGED`, with the question mark icon as a fallback.
- **Recipe data.** Scanning is a trailing debounce: half a second after the last of `TRADE_SKILL_SHOW`, `TRADE_SKILL_LIST_UPDATE`,
  `TRADE_SKILL_DATA_SOURCE_CHANGED` and `NEW_RECIPE_LEARNED` (each registered only if the client has it; `TRADE_SKILL_CLOSE` cancels
  it), and only once `IsTradeSkillReady` is true and `IsDataSourceChanging` is false. A plain list update is skipped when the
  profession, the number of recipes and the number learned are unchanged since the last scan this session; the other events always
  rescan. Each recipe's profession comes from `GetProfessionInfoByRecipeID` (parent profession name first), else from
  `GetBaseProfessionInfo`; a recipe whose profession cannot be found is not saved. The recipe IDs come from `C_TradeSkillUI.GetAllRecipeIDs()` when the
  client has it, else from `GetFilteredRecipeIDs()`. The second one follows the window's filters (search text, "show unlearned",
  ...), so when it is used a recipe missing from the list is not treated as unlearned. Recipe details come from `GetRecipeInfo`,
  `GetRecipeSchematic(recipeID, false)` (basic slots, plus modifying slots the recipe requires; a `variableQuantities` entry for the
  very item wins over the slot's quantity) and, for recipes the character does not know, `GetRecipeSourceText`. Every call goes
  through `pcall` and any secret value is skipped, never compared or concatenated.
  Without a window, `PLAYER_LOGIN`, `SKILL_LINES_CHANGED`, `SPELLS_CHANGED`, `LEARNED_SPELL_IN_SKILL_LINE` and `NEW_RECIPE_LEARNED` schedule
  a pass (a one second trailing debounce) that goes through the bundled recipes of each profession's skill line (the `skillLine` that
  `GetProfessionInfo` returns) with `IsPlayerSpell` (an answer that is not a plain boolean is ignored). A known recipe is marked as known and, when no
  window saved it, saved from the bundle (name from `C_Spell.GetSpellName`, asked for with `C_Spell.RequestLoadSpellData` and retried on
  `SPELL_DATA_LOAD_RESULT` and on a timer; each spell is asked for five times per session at most, and events do not reset that; a recipe is never
  saved without a name); a saved recipe of that skill line the character does not know is unmarked, unless `IsPlayerSpell` says no to every
  recipe of the line (the spells are probably not loaded yet): nothing in that line is unmarked, and the pass is repeated up to five times before
  the answer is trusted. A recipe in several skill lines is indexed under each of them. At `PLAYER_LOGIN` and `SKILL_LINES_CHANGED` the
  character is also taken off the recipes of professions it no longer has: a bundled recipe is kept while the character has any of its skill
  lines (when the client gives the skill line of every profession), any other recipe by the profession name it was saved under.
- **Recent mail recipients.** The recipient is read from a `hooksecurefunc("SendMail", ...)` hook, which runs after Blizzard's own call and
  changes nothing about it; it joins a queue of at most three unconfirmed letters, the oldest of which is confirmed by `MAIL_SEND_SUCCESS` or dropped by a
  `MAIL_FAILED` without an item ID (inbox failures carry one and are ignored); `MAIL_SHOW` and `MAIL_CLOSED` empty the queue. The panel is a child of
  `MailFrame` and follows `SendMailFrame` with `HookScript` on `OnShow` / `OnHide`; filling the "To:" box is a plain `SetText` on
  `SendMailNameEditBox`; focus and cursor are never changed. The panel re-anchors to `OpenMailFrame` while a letter is open. A recipient that is a secret value is ignored, never compared or concatenated. `MailFrame` belongs to
  `Blizzard_MailFrame`, which is always loaded; if it is not there when the addon starts, the panel is created when that addon loads.
- **Mailbox button (Mail.lua).** A plain child frame created by the addon: the materials icon (20x20, `RIGHT` of
  `MailFrame.CloseButton` with x -2; fallback `MailFrameCloseButton`, then the top right corner of `MailFrame`). It is created when the mailbox exists (at
  load and at `ADDON_LOADED` "Blizzard_MailFrame") and is shown or hidden by `ns.SetMailEnabled`. Nothing of Blizzard's letter frame (`OpenMailFrame`) is hooked
  for it. Its click calls `ns.HandleMaterialsCommand("")`.
- **Recipe materials in your mail.** Every `MAIL_INBOX_UPDATE` (it fires repeatedly) reads the inbox at once and replaces the snapshot, so the last state
  before the mailbox closes is never lost; only the refresh of an open window waits half a second after the last one. Nothing is read
  after `MAIL_CLOSED`, and nothing before the first `MAIL_SHOW` (so after a `/reload` at an open mailbox it starts working at the next visit). It reads `GetInboxNumItems()` (the second result, the total, tells when there are more letters than listed),
  `GetInboxHeaderInfo(i)` (the cash on delivery amount and the attachment count) and `GetInboxItem(i, 1..ATTACHMENTS_MAX_RECEIVE)` (16 when the global is
  missing); currencies and anything that is a secret value (or not a plain number) are skipped, and a secret COD amount counts as no COD. The live count of the
  current character comes from `C_Item.GetItemCount(id, includeBank, false, includeBank, includeAccountBank)` inside a `pcall` (falling back to `GetItemCount(id, includeBank)`), where the bank flags
  are false (bags and reagent bag only) when the character's bank was saved, and the saved bank and account bank are added; when it was not, everything is true and nothing saved is
  added (so the account bank is never counted twice); `BAG_UPDATE_DELAYED` refreshes an open
  window. The window is its own frame (`JimmysUtilsMailMaterialsFrame`); nothing of
  Blizzard's code is hooked or replaced.
  The recipes' ingredient slots are saved by the recipe scan (`slots` next to the flat `reagents` map) following `required` / `reagentType` like Blizzard's recipe tracker. Without a saved position the window is placed right of the mailbox, the open letter (46 px right of the mailbox, 338 wide) and the recent recipients panel docked to it, or at the right edge of a screen too narrow for that. Owned counts and item names are asked once per refresh.
- **Item snapshots (`Inventory.lua`).** This client has no separate reagent bank: the reagent bag is container `Enum.BagIndex.ReagentBag` (5), the
  character bank is a set of tabs (`CharacterBankTab_1..9`, container IDs 6 to 14, listed by `C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character)`) and the
  account (warband) bank is `AccountBankTab_1..9` (IDs 15 to 23, `Enum.BankType.Account`; `C_Bank.CanViewBank` says whether it can be read). The bags are the
  containers 0 to `NUM_TOTAL_EQUIPPED_BAG_SLOTS` (5), read with `C_Container.GetContainerNumSlots` / `GetContainerItemInfo(bag, slot)` (`itemID`, `stackCount`)
  inside `pcall`s, skipping secret values. They are rescanned on `PLAYER_ENTERING_WORLD`, `BAG_UPDATE_DELAYED` (one scan one second after the first event of a
  burst) and `PLAYER_LOGOUT`. The bank is only readable while it is open (after `BANKFRAME_CLOSED` the client says it cannot be viewed): `BANKFRAME_OPENED` sets a flag and scans,
  every `BAG_UPDATE_DELAYED` while the flag is set rescans it at once (so the last change before closing is kept), the per-slot events (`PLAYERBANKSLOTS_CHANGED`,
  `PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED`, `BANK_TABS_CHANGED`, `BAG_CONTAINER_UPDATE`) rescan it on the next frame, `PLAYER_LOGOUT` rescans it if it is open, and `BANKFRAME_CLOSED`
  clears the flag without reading. A scan that reads nothing never replaces a snapshot. Without `C_Bank` the tabs named in `Enum.BagIndex` are used. The
  data is validated at load (bad entries dropped); the old per-character `mailItems` is moved into `inventory[character].mail` once `GetNormalizedRealmName()` answers (at load, or
  at `PLAYER_ENTERING_WORLD`; it stays where it is until then): if the character already has a snapshot made only of sent items, the old scan is the base and the sent items are added on top.
- **Mail sent to your own characters.** The `SendMail` hook (Mail.lua) reads the letter's attachments with `GetSendMailItem(1..ATTACHMENTS_MAX_SEND)` (name, itemID, texture, count,
  quality; Blizzard's mail frame only empties them when `MAIL_SEND_SUCCESS` arrives, so they are still there when the hook runs) and queues them with the recipient in the same
  first-in first-out queue as the recent recipients; `MAIL_SEND_SUCCESS` takes the oldest entry and, when its recipient (case-insensitive `Name` or `Name Surname`, optionally `-Realm` of this
  realm, compared by first name, never the current character) is a character the addon knows, adds the items to that character's mail snapshot (`sentTime`; `GetSendMailCOD() > 0` also marks them COD; realms are compared without spaces, hyphens and case); `MAIL_FAILED` without an item ID,
  `MAIL_SHOW` and `MAIL_CLOSED` drop queued letters. Nothing is read while the mail features are off.
- **Inspecting the API.** If a score looks wrong, shift-click the item and run `/ju dump <item link>`. It prints the raw
  `C_Item.GetItemStats` table, the "Equip:" effects that were parsed, and the final calculation.
- **Detected stats.** Any stat the API reports that is not in the built-in list (for example socket counts or stats new to Forever)
  is remembered automatically and is offered under "Other stats detected on items" in the options window's Add dropdown, where you can give it a weight.

## Testing in game

A quick first session:

1. Turn on Lua error popups with `/console scriptErrors 1` (or use an error catcher such as BugSack) and `/reload`. Logging in
   should show no errors from this addon.
2. Hover equippable items in your bags and on your character. Items with weighted stats show the `Stat Weight` line; hold Alt
   (the default) to see the breakdown.
3. Shift-click items into the chat box and run `/ju dump <item link>` on a few of them: a weapon, and items with "Equip:" hit, crit,
   spell power or mp5 lines. The output shows whether `C_Item.GetItemStats` reports those stats or the addon reads them from the
   "Equip:" text (text-read mp5, spell power etc. are scored under the main stat and marked `(Equip)` in the breakdown; hit/crit
   percentages use their own "(Equip)" weights). Check that no stat is counted twice.
4. Look under "Other stats detected on items" in the options window's Add dropdown for stat names the built-in list doesn't know yet.
5. Open `/ju`, change a weight and check that the tooltip follows. Create, switch and delete a profile.
6. Range check: open the **Range Check** tab, pick a spell, target an enemy and walk in and out of range; the icon should
   turn red when out of range and back to normal when in range. By default the indicator sits next to the target's nameplate (enemy nameplates must be shown, default key V): target different
   enemies and check that it follows, and that it hides when the target has no nameplate. Switch the **Position** to **Fixed on
   screen**, unlock the indicator, drag it, lock it, and `/reload` to confirm the position is kept. Repeat in combat.
7. Hover items during combat as well. There should be no errors, even if the line is skipped because the game hides a value from
   addons.
8. Recipe lookup: run `/ju recipes status` to see what was saved (the Recipes tab shows
   the same counts) and what the client gives the addon. If it says nothing is saved, the client did not give the addon a recipe list: see "Recipe data" above and
   report which of `C_TradeSkillUI.GetAllRecipeIDs` / `GetFilteredRecipeIDs` exist. Assign a key under Keybindings > AddOns, hover an
   ingredient in your bags and press it; also try `/ju recipes <item link>` and `/ju recipes <part of a name>`. Check that
   each row lists the materials of one craft with the looked-up item highlighted (the Wowhead popup offers "Recipe item (search)" and "Recipe spell"), and that the Known list names your characters.
9. Mail: open a mailbox, go to the **Send Mail** tab and send a letter to another character; the panel to the right of the mailbox
   should list that name afterwards (not before the mail went out, and not for a letter that failed, for example with a full
   mailbox). Click the name to fill in the "To:" box (also while a letter is open: check the panel does not cover it), right-click it to remove it, and check `/ju mail off` (the panel disappears, new recipients are not recorded, `/ju materials` says the mail features are off),
   `/ju mail on` and `/ju mail clear`.
   Mailbox button: open the mailbox and check the small icon button just left of its close button on both tabs (tooltip "Materials in your mail"; a click
   opens and closes the materials window like `/ju materials`, and nothing opens by itself). Open a letter with items or money and check that the addon adds no button
   to it, then check `/ju mail off` hides the icon at once and `/ju mail on` brings it back.
   Also try each feature's off switch (`/ju stats off`, `/ju range`, `/ju recipes off`, `/ju mail off`, or the check boxes) and `/ju status`.
10. Recipe materials: open the bank (and the account bank) once on each character, then send one of your characters a letter holding an ingredient of a recipe it knows (or
    use mail you already have). Log in on another character of the same realm: `/ju materials` should list it under its own header with `bags ... ago, bank ... ago`, and with the
    first character's mail items marked `(N in your mail)` and **Craftable after mail** when they are needed. Mail yourself items from one character to another and check they appear as `(N in their mail)` there. Open the mailbox: nothing should open by itself. Type `/ju materials`: the
    **Materials in your mail** window should list the recipe and show the ingredient counts. Check the numbers against your bags, that a COD
    letter is marked, that **Craftable** appears when nothing is missing, that double-click opens the recipe, that taking the mail out of the
    inbox updates the counts while the window is open, and that `/ju materials` also works away from the mailbox (it then says how old the data is).
11. Minimap button: check the icon looks right in the border, that dragging moves it around the minimap (and the position survives `/reload`),
    left-click toggles the options window, right-click the materials window, the tooltip text, `/ju minimap` and `/ju minimap reset`, the
    check box at the bottom of the options window, and the entry (icon and tooltip) in the minimap's addon compartment menu.
12. Skill-up chances: open a profession window, then `/ju recipes <an ingredient>`. Recipes should show `(NN%)` after their name in the
    window's colors (compare them with the colors in the profession window itself), and the tooltip should read `Skill-up chance: ...`.
    Craft something until the skill goes up with the lookup window open: the chance follows. Check a recipe whose item you know (the
    Wowhead window's first box should be `item=...`), and one with no teaching item, such as a trainer recipe (only the spell page is shown).
13. Map pin: in a zone with a map (say Elwynn Forest), `/ju pin 45.2 67.8` should set the pin where the map shows 45.2, 67.8 (open the map with M and compare),
    turn on the arrow in the world, and print the zone and a shift-clickable link. Try `45,2 67,8`, `45 67`, `/ju pin` alone (the pin should land under your arrow on the map), a bad value (`/ju pin 120 5`, `/ju pin a b`)
    for the messages, a zone or instance that does not allow pins (the command should say so), and `/ju pin clear` with and without a pin.
14. On a non-English client the "Equip:" fallback is off; note which effects only appear as "Equip:" text.
15. Crafting profit (with Auctionator and some auction house scans): open a profession and its **Filter** menu: it should end with **Sort by (Jimmy's Utils)**
    (Default, Crafting profit); choosing Crafting profit should reorder the recipe list (learned recipes by profit, then the unlearned ones) without losing your
    selection, and Default should put the client's order back. `/ju profit` lists the same order in chat. Compare a recipe's profit with Auctionator's own line in the
    recipe's window. `/ju recipes <item>` and `/ju materials` should show a profit on each recipe and a **Sort** button. Untick **Show crafting profit** in the Recipes
    tab (or disable Auctionator and `/reload`): all of that disappears, the list is Blizzard's again and nothing errors; enable Auctionator again and your choices are back.

## Files

- `Stats.lua` - stat definitions and labels
- `Core.lua` - saved variables, profiles, weights, settings, the stat weights on/off, slash commands (including `/ju status` and `/ju stats`)
- `Tooltip.lua` - stat collection, scoring and the tooltip line
- `RangeCheck.lua` - the range check indicator, its settings and the `/ju range` command
- `Recipes.lua` - recipe scanning and saved data, the skill-up chance, item lookup, the results window, the key binding function and `/ju recipes`
- `Data/RecipeData.lua` - generated: the skill thresholds and teaching item of every profession recipe (Blizzard's game data via wago.tools)
- `tools/gen_recipe_data.py` - the generator of `Data/RecipeData.lua` (not loaded by the game)
- `Mail.lua` - the recent mail recipients: capture, saved list, the panel next to the mailbox and `/ju mail`
- `Inventory.lua` - the saved bags, bank, account bank and mailbox of each character, and mail sent to your own characters
- `MailMaterials.lua` - the recipe materials in your mail: inbox scan, the window (grouped by character) and `/ju materials`
- `Minimap.lua` - the minimap button, its saved position, the addon compartment callbacks and `/ju minimap`
- `Profit.lua` - the crafting profit from Auctionator's prices (the formula, its text, the sort order), the sort of the profession window's recipe list and `/ju profit`
- `Pin.lua` - the map pin command, `/ju pin`
- `Media\MinimapIcon.tga` - the icon of the minimap button and of the addon compartment entry (64x64, 32-bit with alpha)
- `Bindings.xml` - the "Find recipes using hovered item" key binding (loaded automatically, not listed in the `.toc`)
- `Options.lua` - the options window (all tabs and the footer check box) and its Settings > AddOns entry

### Saved data

Saved data lives in `JimmysStatWeightsDB` (account-wide: profiles, settings, detected stats, `stats` with the on/off of the tooltip scores, range check options (`range`, including its on/off), `recipeLookup` with the on/off of the recipe lookup, its `hiddenProfessions`, `onlyMyProfessions` (the check box of the recipes window) and the `size` of that window, last tab, and the
saved recipes: `recipes`, `recipeKnownBy` with the characters that know each recipe as `Name-Realm`, and `itemNames` with the names
of ingredients, and `recipeSkill` with each character's rank and maximum in each profession; and the recent mail recipients: `mail` with the on/off setting of both mail features and `mailRecipients` with one list of names per realm; and `mailMaterials` with the position of
the materials window, its `size`, `showOthers`, `hiddenProfessions` and `sortProfit`; and `profit` with the on/off of the crafting profit and the sort of the profession list (`enabled`, `listSort`); `inventory` with, per character (`Name-Realm`), the item counts in its `bags` and `bank` and the last scan of its `mail`
(with the times they were seen), and `accountBank` with the account bank's items; and `minimap` with `hide` and the `angle` of the minimap button) and `JimmysStatWeightsCharDB` (per character: the active profile, and the range check spell; older versions also kept `mailItems`, the last scan of the mailbox, here: it is moved into `inventory` at load). The variable names are unchanged from the
addon's previous name, but the client stores them in a file named after the addon folder, i.e. now
`WTF\Account\<account>\SavedVariables\JimmysUtils.lua` and `WTF\Account\<account>\<realm>\<character>\SavedVariables\JimmysUtils.lua`.
To keep the data of the old Jimmy's Stat Weights, log out and rename its `JimmysStatWeights.lua` files (the account-wide one and the
per-character ones) to `JimmysUtils.lua`, and remove the old `JimmysStatWeights` addon folder so both are not loaded.

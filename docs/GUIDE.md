# Jimmy's Utils - full guide

A World of Warcraft: Forever addon with five small utilities (and a minimap button that opens the options window and the mail
materials, see [Minimap button](#minimap-button)):

- **Stat Weight** - adds one line to the tooltip of every equippable item:

  ```
  Stat Weight (Default)                      123.4
  ```

  The number is a weighted sum of the item's stats, using coefficients you choose. Higher is better for the weights you set.
- **Range check** - a small indicator that shows the icon of a spell you pick while your target is within range of it, and
  tints it red while it is not.
- **Recipe lookup** - point at an item and press a key (or type `/ju recipes <item>`) to list the recipes that use it as an
  ingredient, which of your characters know each one and, where the client allows it, where to get the recipes nobody knows.
- **Recent mail recipients** - a small panel docked next to the Send Mail tab of the mailbox that lists the last 10 characters
  you sent mail to; click a name to fill in the "To:" box.
- **Recipe materials in your mail** - a window that lists the recipes your character knows which use items waiting in your
  mailbox, with how many of each ingredient you have and how many you still lack.

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
| Recipes | Enable recipe lookup | `/ju recipes on` / `off` | Profession windows are not scanned, the key binding and `/ju recipes <item>` only say "Recipe lookup is off. Turn it on with /ju recipes on." and the recipes window (and the Wowhead link popup) closes. The saved recipes are kept (`/ju recipes status` and `forget` still work, and the mail materials keep using them) |
| Mail | Enable mail features (recent recipients and mail materials) | `/ju mail on` / `off` | The recent recipients panel is hidden and no recipients are recorded, the inbox is not scanned for materials, `/ju materials` says "Mail features are off. Turn them on with /ju mail on." and the materials window closes. The saved list and the last scan are kept |

Turning a feature back on resumes it where it can: tooltips at once, the range indicator at once, the recipe scan the next time a
profession window updates or opens, the mail panel the next time the Send Mail tab shows, and the mailbox is read at once when it is
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

The addon has no recipe database. The game only lists a profession's recipes while its window is open, so every time you open
one of **your own** profession windows (or its list updates) Jimmy's Utils reads the recipes, their ingredients and whether this
character knows them, and saves them account-wide. Open each profession of each character once to fill the data. Linked
professions, guild and guild member windows, runeforging and NPC crafting windows are ignored. A profession window that is still
loading is waited for, and closing the window cancels a pending scan. The profession window's own settings are never changed.

The **Enable recipe lookup** check box at the top of the tab (or `/ju recipes on` / `off`) switches both the scanning and the lookup:
see [Feature toggles](#feature-toggles).

To look an item up:

- **Key binding**: hover an item (bags, equipment, vendors, item links in chat...) and press the key you assigned to "Jimmy's
  Utils: Find recipes using hovered item" under **Options > Keybindings > AddOns**. No key is assigned by default.
- **Slash command**: `/ju recipes <item link | item ID | item name>`. Shift-click an item into the chat box to get a link. A name
  is matched against the names of ingredients saved so far, case-insensitively for ASCII letters (other characters must match as
  they are): an exact match first, then a part of the name. When
  several items match, up to five are listed in chat with their IDs; use the ID or a longer name.

A window titled "Recipes using <item>" lists every saved recipe that uses the item as a basic ingredient (optional and finishing
reagents are not saved): the recipe icon and name, its profession, the quantity needed (`x2`), and either `Known: Jamie, Khaz`
(characters of your current realm are shown without their realm) or `Not known` followed by where the game says to get the
recipe, or `source unknown` when it did not say. Recipes somebody knows come first, then the rest sorted by profession and name.
Hovering a row shows the tooltip of the item the recipe makes (or of the recipe itself when it makes no item), followed by the full
source text and the list of characters that know it. The footer shows how many recipes are saved and from which professions.

Every row has a small **Wowhead** button. The client cannot open web pages, so it opens a small window titled "Wowhead links" with
the recipe's name and two boxes to copy from: **Recipe page** (`https://www.wowhead.com/forever/spell=<recipe ID>`) and **Search**
(`https://www.wowhead.com/forever/search?q=<recipe name>`, with spaces as `+` and other characters percent-encoded). The first box
is selected: press Ctrl+C and paste into your browser (the window then closes by itself; Escape closes it too). The boxes cannot
be edited. Without a recipe ID only the search box is shown. The base address is the `WOWHEAD_BASE` constant at the top of
`Recipes.lua`. Recipes nobody knows and without source text say `source unknown (see Wowhead)`.

**Double-click a row** to open that recipe in your profession window (`C_TradeSkillUI.OpenRecipe`, the same call Blizzard's
recipe tracker uses). This works only for recipes the character you are playing knows; the row's tooltip says
"Double-click to open it in your profession window." on those. For other recipes a chat line says who knows it.

**Where to get a recipe nobody knows.** That text only exists if the client gives addons recipes the character has not learned.
Forever's own profession window hides them, so it may be that every recipe the addon sees is already known by the character
that scanned it. Recipes that another character knows always show `Known: <name>`. To find out what your client does, open a
profession window and type `/ju recipes status`: it shows whether `C_TradeSkillUI.GetAllRecipeIDs` exists and, for the open
window, how many recipes `GetAllRecipeIDs` and `GetFilteredRecipeIDs` return and how many of them are not learned.

The **Recipes** tab explains this, shows the current key (or how to set one), the number of saved recipes per profession, and has
a **Forget saved recipes** button (it asks for a second click). Saved recipes are listed under Saved data below. A character that
drops a profession is taken off the recipes of that profession when the game reports its professions (at login and when skills change).

### Per-stat breakdown

The breakdown (one gray line per weighted stat, e.g. `Strength  25 x 1 = 25`) can be set to always show, to show while holding
Shift, Alt or Ctrl (default: Alt), or to never show. Tooltips of bag and equipped items refresh on their own, so pressing the key
while hovering works; for tooltips that don't refresh (e.g. a clicked chat link), hold the key before opening the tooltip.

### Recipe materials in your mail

While the mailbox is open, the addon keeps a record of the inbox (the letters the client has loaded, up to 50). `/ju materials` opens a
window titled **Materials in your mail** that lists the recipes **the current character knows** which use items from that mail. Each recipe has a
header with its icon, name and profession, and either **Craftable** (green) or **Missing N items** (orange: the total number of
ingredient items still lacking for one craft), followed by one line per ingredient:

```
Silverleaf  3/5 (2 in mail) - need 2 more
```

`3/5` is what you have against what one craft needs. What you have is what is in your bags, bank, reagent bank and account bank plus
what is in the mail (the part from the mail is shown in brackets; bank counts can be out of date away from the bank). A line is red
while something is missing and green when there is enough. `(COD)` marks ingredients that come in a letter with a cash on delivery
request. An ingredient that comes in several interchangeable items (for example the quality tiers of an herb) is one line, marked
`(any quality)`: what you have of all of them is added up against the quantity the recipe needs, as in the game's own recipe tracker, and the
name shown is the item you have most of. Recipes saved by an older version have one line per item until their profession window is opened
again. Craftable recipes come first, then the ones with the fewest missing items, then by name. Double-click a recipe's header to open
it in your profession window.

- **Opening it.** Only `/ju materials` opens it (and closes it again); it never opens by itself. Close it with its close button or Escape.
  While it is open it follows mailbox and bag changes. It can be moved; its position is remembered. Until you move it, it sits to the
  right of the mailbox, the open letter and the recent recipients panel.
- **Away from the mailbox.** The last scan is saved per character (when, and which items), so `/ju materials` also works elsewhere,
  and the window says how old the mail data is ("From your mailbox, 5 minutes ago"). The ingredient counts in your bags are always current
  and follow bag changes while the window is open. The snapshot is only refreshed at a mailbox.
- **More than 50 letters.** The client lists at most 50 letters at a time; the window then says "Only the first 50 mails are scanned; take some
  mail to see the rest."
- **Recipes.** The recipes are the ones saved by the recipe lookup, so open each of your profession windows once. Without any, the
  window says so.

The **Mail** tab ends with a one-line reminder of the `/ju materials` command.

### Mail tab and recent mail recipients

Whenever a letter is sent successfully, its recipient goes to the top of a list of the last 10 recipients of the realm you are on
(the list is account-wide, one list per realm, so your characters on a realm share it). While the **Send Mail** tab of the mailbox
is showing, a small panel titled **Recent recipients** is docked to the right of the mailbox window (or of the open letter, while one
is open) with that list:

- **Left-click** a name to put it in the "To:" box (only the text is set: the focus and cursor are left alone).
- **Right-click** a name to take it off the list.
- A name is stored as you typed it (trimmed); sending to the same name again, in any capitalization, moves it to the top and keeps the
  newest spelling. The count shown on the **Mail** tab and by `/ju mail` is the number of names saved for the realm. `Name` and `Name-Realm` count as different recipients. Your current character is never listed. A letter that fails
  to send, or that is still being sent when you close the mailbox, is not added.

The **Mail** tab has an **Enable mail features (recent recipients and mail materials)** check box, the master switch of both mail
features (while it is off the panel is hidden, no recipients are recorded and the mailbox is not scanned for materials; what was saved is
kept), and a **Clear recent recipients** button, which empties the list of the current realm.

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
| `/ju recipes status` | Show how many recipes are saved, per profession and per character, and what the client gives the addon: whether `GetAllRecipeIDs` exists and, with a profession window open, how many recipes it and `GetFilteredRecipeIDs` return and how many are not learned (`scan` still works as an alias; recipes are saved when you open a profession window, this command does not save anything itself) |
| `/ju recipes forget` | Ask to delete the saved recipes; `/ju recipes forget confirm` really deletes them |
| `/ju recipes forget <character>` | Ask to remove one character (`Name`, or `Name-Realm` when the name exists on several realms) from the saved recipes; add `confirm` to do it |
| `/ju mail` | Show whether the mail features (recent recipients and mail materials) are on, how many recipients are saved for this realm, and the usage |
| `/ju mail on` / `/ju mail off` | Turn the mail features on or off: the recent recipients panel and its recording, and the mailbox scan and window of the mail materials |
| `/ju mail clear` | Forget the recent recipients of the current realm |
| `/ju minimap` | Show or hide the minimap button (prints which) |
| `/ju minimap reset` | Move the minimap button back to its default place (bottom left) |
| `/ju materials` | Open or close the window with the recipes your mail has materials for (works away from the mailbox, from the last scan; says so when the mail features are off) |

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
- **Recent mail recipients.** The recipient is read from a `hooksecurefunc("SendMail", ...)` hook, which runs after Blizzard's own call and
  changes nothing about it; it joins a queue of at most three unconfirmed letters, the oldest of which is confirmed by `MAIL_SEND_SUCCESS` or dropped by a
  `MAIL_FAILED` without an item ID (inbox failures carry one and are ignored); `MAIL_SHOW` and `MAIL_CLOSED` empty the queue. The panel is a child of
  `MailFrame` and follows `SendMailFrame` with `HookScript` on `OnShow` / `OnHide`; filling the "To:" box is a plain `SetText` on
  `SendMailNameEditBox`; focus and cursor are never changed. The panel re-anchors to `OpenMailFrame` while a letter is open. A recipient that is a secret value is ignored, never compared or concatenated. `MailFrame` belongs to
  `Blizzard_MailFrame`, which is always loaded; if it is not there when the addon starts, the panel is created when that addon loads.
- **Recipe materials in your mail.** Every `MAIL_INBOX_UPDATE` (it fires repeatedly) reads the inbox at once and replaces the snapshot, so the last state
  before the mailbox closes is never lost; only the refresh of an open window waits half a second after the last one. Nothing is read
  after `MAIL_CLOSED`, and nothing before the first `MAIL_SHOW` (so after a `/reload` at an open mailbox it starts working at the next visit). It reads `GetInboxNumItems()` (the second result, the total, tells when there are more letters than listed),
  `GetInboxHeaderInfo(i)` (the cash on delivery amount and the attachment count) and `GetInboxItem(i, 1..ATTACHMENTS_MAX_RECEIVE)` (16 when the global is
  missing); currencies and anything that is a secret value (or not a plain number) are skipped, and a secret COD amount counts as no COD. Owned counts
  come from `C_Item.GetItemCount(id, true, false, true, true)` inside a `pcall`, falling back to `GetItemCount(id, true)`; `BAG_UPDATE_DELAYED` refreshes an open
  window. The window is its own frame (`JimmysUtilsMailMaterialsFrame`); nothing of
  Blizzard's code is hooked or replaced.
  The recipes' ingredient slots are saved by the recipe scan (`slots` next to the flat `reagents` map) following `required` / `reagentType` like Blizzard's recipe tracker. Without a saved position the window is placed right of the mailbox, the open letter (46 px right of the mailbox, 338 wide) and the recent recipients panel docked to it, or at the right edge of a screen too narrow for that. Owned counts and item names are asked once per refresh.
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
8. Recipe lookup: open each of your profession windows once, then run `/ju recipes status` to see what was saved (the Recipes tab shows
   the same counts) and what the client gives the addon. If it says nothing is saved, the client did not give the addon a recipe list: see "Recipe data" above and
   report which of `C_TradeSkillUI.GetAllRecipeIDs` / `GetFilteredRecipeIDs` exist. Assign a key under Keybindings > AddOns, hover an
   ingredient in your bags and press it; also try `/ju recipes <item link>` and `/ju recipes <part of a name>`. Check that
   recipes you have not learned show where to get them (or "source unknown") and that the Known list names your characters.
9. Mail: open a mailbox, go to the **Send Mail** tab and send a letter to another character; the panel to the right of the mailbox
   should list that name afterwards (not before the mail went out, and not for a letter that failed, for example with a full
   mailbox). Click the name to fill in the "To:" box (also while a letter is open: check the panel does not cover it), right-click it to remove it, and check `/ju mail off` (the panel disappears, new recipients are not recorded, `/ju materials` says the mail features are off),
   `/ju mail on` and `/ju mail clear`.
   Also try each feature's off switch (`/ju stats off`, `/ju range`, `/ju recipes off`, `/ju mail off`, or the check boxes) and `/ju status`.
10. Recipe materials: open your profession windows once, then send one of your characters a letter holding an ingredient of a recipe it knows (or
    use mail you already have). Open the mailbox: nothing should open by itself. Type `/ju materials`: the
    **Materials in your mail** window should list the recipe and show the ingredient counts. Check the numbers against your bags, that a COD
    letter is marked, that **Craftable** appears when nothing is missing, that double-click opens the recipe, that taking the mail out of the
    inbox updates the counts while the window is open, and that `/ju materials` also works away from the mailbox (it then says how old the data is).
11. Minimap button: check the icon looks right in the border, that dragging moves it around the minimap (and the position survives `/reload`),
    left-click toggles the options window, right-click the materials window, the tooltip text, `/ju minimap` and `/ju minimap reset`, the
    check box at the bottom of the options window, and the entry (icon and tooltip) in the minimap's addon compartment menu.
12. On a non-English client the "Equip:" fallback is off; note which effects only appear as "Equip:" text.

## Files

- `Stats.lua` - stat definitions and labels
- `Core.lua` - saved variables, profiles, weights, settings, the stat weights on/off, slash commands (including `/ju status` and `/ju stats`)
- `Tooltip.lua` - stat collection, scoring and the tooltip line
- `RangeCheck.lua` - the range check indicator, its settings and the `/ju range` command
- `Recipes.lua` - recipe scanning and saved data, item lookup, the results window, the key binding function and `/ju recipes`
- `Mail.lua` - the recent mail recipients: capture, saved list, the panel next to the mailbox and `/ju mail`
- `MailMaterials.lua` - the recipe materials in your mail: inbox scan, per-character snapshot, the window and `/ju materials`
- `Minimap.lua` - the minimap button, its saved position, the addon compartment callbacks and `/ju minimap`
- `Media\MinimapIcon.tga` - the icon of the minimap button and of the addon compartment entry (64x64, 32-bit with alpha)
- `Bindings.xml` - the "Find recipes using hovered item" key binding (loaded automatically, not listed in the `.toc`)
- `Options.lua` - the options window (all tabs and the footer check box) and its Settings > AddOns entry

### Saved data

Saved data lives in `JimmysStatWeightsDB` (account-wide: profiles, settings, detected stats, `stats` with the on/off of the tooltip scores, range check options (`range`, including its on/off), `recipeLookup` with the on/off of the recipe lookup, last tab, and the
saved recipes: `recipes`, `recipeKnownBy` with the characters that know each recipe as `Name-Realm`, and `itemNames` with the names
of ingredients; and the recent mail recipients: `mail` with the on/off setting of both mail features and `mailRecipients` with one list of names per realm; and `mailMaterials` with the position of
the materials window; and `minimap` with `hide` and the `angle` of the minimap button) and `JimmysStatWeightsCharDB` (per character: the active profile, the range check spell and `mailItems`, the last scan of the mailbox). The variable names are unchanged from the
addon's previous name, but the client stores them in a file named after the addon folder, i.e. now
`WTF\Account\<account>\SavedVariables\JimmysUtils.lua` and `WTF\Account\<account>\<realm>\<character>\SavedVariables\JimmysUtils.lua`.
To keep the data of the old Jimmy's Stat Weights, log out and rename its `JimmysStatWeights.lua` files (the account-wide one and the
per-character ones) to `JimmysUtils.lua`, and remove the old `JimmysStatWeights` addon folder so both are not loaded.

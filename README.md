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
| **Stat weights** | Adds a score line to the tooltip of every equippable item: a weighted sum of its stats, using weights you choose. Multiple profiles, an optional per-stat breakdown (hold Alt by default). |
| **Range check** | Shows the icon of a spell you pick next to your target's nameplate (or at a fixed spot on screen), tinted red while the target is out of range. |
| **Recipe lookup** | Hover an item and press a key (or `/ju recipes <item>`) to list the recipes that use it with the materials each one needs, which of your characters know them, and Wowhead links (a search for the item that teaches it, and the recipe's spell page) for each. Double-click a recipe to open it in your profession window. |
| **Recent mail recipients** | A panel next to the Send Mail tab with the last 10 characters you mailed. Click a name to fill in the "To:" box. |
| **Materials in your mail** | `/ju materials` lists the recipes that use items waiting in your mailbox, with how many of each ingredient (bags, bank and mail) you have, how many you still need, and which recipes are already craftable. It also shows what your other characters on the realm could craft, from their saved bags, bank and mail (including items you mail them), and which need the mail sent first. |

Every feature can be switched on or off on its own. A minimap button (also listed in the addon compartment) opens the settings
with a left-click and the mail materials with a right-click.

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

- Type `/ju` (or click the minimap button) to open the settings. It has one tab per feature, and the first check box of each tab
  turns that feature on or off.
- **Stat weights:** set your weights on the *Stat Weights* tab, e.g. `/ju set crit 1.5`.
- **Range check:** pick a spell on the *Range Check* tab or with `/ju range <spell name>`. Enemy nameplates must be shown (V).
- **Recipe lookup:** open each of your profession windows once so the addon can learn your recipes, then bind a key under
  *Options > Keybindings > AddOns > Jimmy's Utils: Find recipes using hovered item*.
- **Mail:** the recent recipients panel appears on its own on the Send Mail tab; `/ju materials` opens the materials window.

## Commands

| Command | Effect |
| --- | --- |
| `/ju` | Open or close the settings |
| `/ju help` | List all commands |
| `/ju status` | Show which features are on |
| `/ju stats on\|off` | Stat weight scores on tooltips |
| `/ju set <stat> <number>` | Set a stat weight |
| `/ju profile [new\|copy\|delete] <name>` | Manage stat weight profiles |
| `/ju range` | Toggle the range check |
| `/ju range <spell>` | Choose the spell the range check uses |
| `/ju range size <12-128>` | Icon size |
| `/ju range nameplate\|screen` | Show it on the target's nameplate or at a fixed spot |
| `/ju recipes <item>` | Recipes that use an item (link, ID or name) |
| `/ju recipes on\|off` | Recipe lookup |
| `/ju mail on\|off` | Mail features |
| `/ju materials` | Open or close the materials window |
| `/ju minimap` | Show or hide the minimap button |

The complete list, with every option explained, is in the [full guide](docs/GUIDE.md).

## Compatibility

- Built for the **WoW Forever** client (interface `16001`).
- No library dependencies.
- Settings are saved account-wide (stat weight profiles, recipes, mail recipients, each character's bags, bank and mailbox, the account bank) and per character (active profile,
  range spell). `/ju recipes forget <character>` also removes that character's saved items.

## Known limitations

- Addons can't open web pages, so Wowhead links are shown in a box to copy (Ctrl+C) and paste into your browser.
- The recipe lookup only knows recipes from profession windows you have opened; it has no built-in recipe database.
- The game only gives addons the first 50 letters of the inbox, so the materials window can miss items in older mail.
- The bags, bank and mail of your other characters are only as fresh as their last visit: log in on a character and open its bank (and mailbox) once to save them. The bank can only be read while it is open.

## Feedback

Found a bug or have an idea? [Open an issue](../../issues) with what you did, what you expected, and any error text
(`/console scriptErrors 1` shows Lua errors in game).

## License

Released under the [GNU General Public License v3.0](LICENSE).

*World of Warcraft is a trademark of Blizzard Entertainment, Inc. This addon is not affiliated with or endorsed by Blizzard.*

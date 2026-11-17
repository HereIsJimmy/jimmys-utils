"""Generates Data/RecipeData.lua: when each profession recipe stops giving skill-ups, and the item that teaches it.

Run it from the addon folder with:  python -I tools/gen_recipe_data.py [--cache DIR] [--refresh]

The data is Blizzard's game data (DB2 tables) for the WoW Forever client, downloaded as CSV from wago.tools:
  SkillLineAbility  one row per ability of a skill line: Spell, SkillLine, MinSkillLineRank (orange),
                    TrivialSkillLineRankLow (yellow) and TrivialSkillLineRankHigh (grey)
  ItemXItemEffect   which item effects an item has (ItemID, ItemEffectID)
  ItemEffect        what an effect does: TriggerType 6 ("on learn") with the SpellID it teaches

The downloaded files are untrusted: they are kept in their own cache folder and only parsed as data (csv module).
Python standard library only.
"""
import argparse
import csv
import datetime
import os
import sys
import tempfile
import urllib.parse
import urllib.request

# The Forever client build the tables are taken from (the client's UI source is 1.60.1 (70862); wago.tools has later builds).
BUILD = "1.60.1.70938"
BASE_URL = "https://wago.tools/db2/%s/csv"
TABLES = {
    "SkillLineAbility": ("Spell", "SkillLine", "MinSkillLineRank", "TrivialSkillLineRankLow", "TrivialSkillLineRankHigh"),
    "ItemXItemEffect": ("ItemID", "ItemEffectID"),
    "ItemEffect": ("ID", "TriggerType", "SpellID"),
}

# Skill lines whose abilities are recipes of a profession window. The gathering abilities of Mining, Herbalism, Skinning and
# Fishing are not recipes; Mining is here for smelting, and its gathering abilities have no thresholds, so they are skipped below.
PROFESSION_SKILL_LINES = {
    164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy", 185: "Cooking", 129: "First Aid", 197: "Tailoring",
    202: "Engineering", 333: "Enchanting", 186: "Mining", 40: "Poisons", 755: "Jewelcrafting", 773: "Inscription",
}
LEARN_TRIGGER = 6  # ItemEffect.TriggerType "on learn": using the item teaches SpellID

# Known entries the downloaded data must agree with, so a changed table layout is noticed instead of written out.
SANITY_THRESHOLDS = {2330: (55, 95)}  # Minor Healing Potion: yellow 55, grey 95
SANITY_TEACHERS = {6617: 5640, 2335: 2555}  # Recipe: Rage Potion, Recipe: Swiftness Potion

OUTPUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Data", "RecipeData.lua")


def download(table, cache_dir, refresh):
    path = os.path.join(cache_dir, table + ".csv")
    if os.path.exists(path) and not refresh:
        return path
    url = BASE_URL % urllib.parse.quote(table) + "?" + urllib.parse.urlencode({"build": BUILD})
    request = urllib.request.Request(url, headers={"User-Agent": "recipe-data-generator"})
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read()
    if not body.lstrip(b"\xef\xbb\xbf").strip():
        raise SystemExit("%s: empty answer from %s" % (table, url))
    tmp = path + ".part"
    with open(tmp, "wb") as fh:
        fh.write(body)
    os.replace(tmp, path)
    return path


def read_table(table, cache_dir, refresh):
    path = download(table, cache_dir, refresh)
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        missing = [name for name in TABLES[table] if name not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit("%s: columns missing in %s: %s (has: %s)" % (table, path, ", ".join(missing), ", ".join(reader.fieldnames or [])))
        return list(reader)


def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def build(cache_dir, refresh):
    abilities = read_table("SkillLineAbility", cache_dir, refresh)
    item_effects = read_table("ItemXItemEffect", cache_dir, refresh)
    effects = read_table("ItemEffect", cache_dir, refresh)

    stats = {"rows": 0, "no_thresholds": 0, "invalid": 0, "conflicting": 0}
    found = {}  # spell -> set of (yellow, grey) seen for it
    for row in abilities:
        if to_int(row["SkillLine"]) not in PROFESSION_SKILL_LINES:
            continue
        spell = to_int(row["Spell"])
        yellow, grey = to_int(row["TrivialSkillLineRankLow"]), to_int(row["TrivialSkillLineRankHigh"])
        if spell is None or spell <= 0:
            stats["invalid"] += 1
            continue
        stats["rows"] += 1
        values = found.setdefault(spell, set())
        if yellow is None or grey is None:
            stats["invalid"] += 1
        elif yellow == 0 and grey == 0:
            stats["no_thresholds"] += 1
        elif yellow <= 0 or grey < yellow:
            stats["invalid"] += 1
        else:
            values.add((yellow, grey))

    thresholds = {}
    for spell, values in found.items():
        if len(values) == 1:
            thresholds[spell] = next(iter(values))
        elif len(values) > 1:
            stats["conflicting"] += 1  # the same spell with different thresholds: which one applies cannot be told

    learn_spell = {}  # ItemEffect ID -> the spell it teaches
    for row in effects:
        if to_int(row["TriggerType"]) == LEARN_TRIGGER:
            effect, spell = to_int(row["ID"]), to_int(row["SpellID"])
            if effect is not None and spell is not None and spell > 0:
                learn_spell[effect] = spell
    teachers = {}  # recipe spell -> lowest item ID that teaches it
    for row in item_effects:
        spell = learn_spell.get(to_int(row["ItemEffectID"]))
        item = to_int(row["ItemID"])
        if spell in found and item is not None and item > 0:
            if spell not in teachers or item < teachers[spell]:
                teachers[spell] = item

    for spell, expected in SANITY_THRESHOLDS.items():
        if thresholds.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d has thresholds %s, expected %s" % (spell, thresholds.get(spell), expected))
    for spell, expected in SANITY_TEACHERS.items():
        if teachers.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d is taught by item %s, expected %s" % (spell, teachers.get(spell), expected))
    return thresholds, teachers, stats


def render(thresholds, teachers):
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "local addonName, ns = ...",
        "",
        "-- Generated by tools/gen_recipe_data.py. Do not edit; run `python -I tools/gen_recipe_data.py` to regenerate it.",
        "-- Source: Blizzard game data (DB2 tables) via wago.tools, WoW Forever build %s." % BUILD,
        "--   SkillLineAbility, ItemXItemEffect and ItemEffect: " + (BASE_URL % "<table>") + "?build=" + BUILD,
        "-- Generated: %s. %d recipes with skill-up thresholds, %d recipes with a teaching item." % (today, len(thresholds), len(teachers)),
        "-- ns.RecipeThresholds[spellID] = { yellow, grey }: the skill where the recipe turns yellow and where it turns grey (orange",
        "--   is below yellow, green is floor((yellow + grey) / 2)). ns.RecipeTeachers[spellID] = lowest item ID that teaches it.",
        "",
        "ns.RecipeThresholds = {",
    ]
    for spell in sorted(thresholds):
        lines.append("[%d]={%d,%d}," % ((spell,) + thresholds[spell]))
    lines += ["}", "", "ns.RecipeTeachers = {"]
    for spell in sorted(teachers):
        lines.append("[%d]=%d," % (spell, teachers[spell]))
    lines += ["}", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "jimmysutils-recipedata", BUILD),
                        help="folder for the downloaded CSV files (default: a folder in the temp directory)")
    parser.add_argument("--refresh", action="store_true", help="download the CSV files again")
    args = parser.parse_args()

    os.makedirs(args.cache, exist_ok=True)
    thresholds, teachers, stats = build(args.cache, args.refresh)
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="ascii", newline="\n") as fh:
        fh.write(render(thresholds, teachers))
    print("build %s: %d recipes with thresholds, %d teaching items (profession rows %d, without thresholds %d, invalid %d, conflicting %d)"
          % (BUILD, len(thresholds), len(teachers), stats["rows"], stats["no_thresholds"], stats["invalid"], stats["conflicting"]))
    print("wrote", OUTPUT)


if __name__ == "__main__":
    sys.exit(main())

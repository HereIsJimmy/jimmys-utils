"""Generates Data/RecipeData.lua: when each profession recipe stops giving skill-ups, the item that teaches it, and what it
needs and makes (so the addon can tell which recipes a character knows without opening the profession windows).

Run it from the addon folder with:  python -I tools/gen_recipe_data.py [--cache DIR] [--refresh]

The data is Blizzard's game data (DB2 tables) for the WoW Forever client, downloaded as CSV from wago.tools:
  SkillLineAbility  one row per ability of a skill line: Spell, SkillLine, MinSkillLineRank (orange),
                    TrivialSkillLineRankLow (yellow) and TrivialSkillLineRankHigh (grey)
  ItemXItemEffect   which item effects an item has (ItemID, ItemEffectID)
  ItemEffect        what an effect does: TriggerType 6 ("on learn") with the SpellID it teaches
  SpellReagents     the ingredients of a spell: Reagent_0..7 (item IDs) and ReagentCount_0..7
  SpellEffect       what a spell does: Effect 24 ("create item") with the item it makes in EffectItemType
  SkillLine         the name of a skill line (DisplayName_lang, English here), for the lines the recipes belong to

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
REAGENT_SLOTS = 8  # SpellReagents has Reagent_0..7 and ReagentCount_0..7
TABLES = {
    "SkillLineAbility": ("Spell", "SkillLine", "MinSkillLineRank", "TrivialSkillLineRankLow", "TrivialSkillLineRankHigh"),
    "ItemXItemEffect": ("ItemID", "ItemEffectID"),
    "ItemEffect": ("ID", "TriggerType", "SpellID"),
    "SpellReagents": ("SpellID",) + tuple("Reagent_%d" % i for i in range(REAGENT_SLOTS)) + tuple("ReagentCount_%d" % i for i in range(REAGENT_SLOTS)),
    "SpellEffect": ("SpellID", "EffectIndex", "Effect", "EffectItemType"),
    "SkillLine": ("ID", "DisplayName_lang"),
}

# Skill lines whose abilities are recipes of a profession window. The gathering abilities of Mining, Herbalism, Skinning and
# Fishing are not recipes; Mining is here for smelting, and its gathering abilities have no thresholds, so they are skipped below.
PROFESSION_SKILL_LINES = {
    164: "Blacksmithing", 165: "Leatherworking", 171: "Alchemy", 185: "Cooking", 129: "First Aid", 197: "Tailoring",
    202: "Engineering", 333: "Enchanting", 186: "Mining", 40: "Poisons", 755: "Jewelcrafting", 773: "Inscription",
}
LEARN_TRIGGER = 6  # ItemEffect.TriggerType "on learn": using the item teaches SpellID
CREATE_ITEM_EFFECT = 24  # SpellEffect.Effect "create item": EffectItemType is the item the spell makes

# Known entries the downloaded data must agree with, so a changed table layout is noticed instead of written out.
SANITY_THRESHOLDS = {2330: (55, 95)}  # Minor Healing Potion: yellow 55, grey 95
SANITY_TEACHERS = {6617: 5640, 2335: 2555}  # Recipe: Rage Potion, Recipe: Swiftness Potion
SANITY_REAGENTS = {6617: [5635, 1, 2450, 1, 3371, 1], 3170: [2447, 1, 2449, 2, 3371, 1]}  # Rage Potion, Weak Troll's Blood Potion
SANITY_OUTPUTS = {6617: 5631, 3170: 3382}
SANITY_SKILL_LINES = {6617: [171], 3170: [171], 2538: [185], 2657: [186], 461692: [165, 197]}  # Alchemy, Cooking, Mining, one in two lines
# More ingredient and output samples, from other professions: Cooking 2538 and Mining (smelting) 2657
SANITY_REAGENTS.update({2538: [2672, 1], 2657: [2770, 1]})
SANITY_OUTPUTS.update({2538: 2679, 2657: 2840})
SANITY_LINE_NAMES = {171: "Alchemy", 185: "Cooking", 186: "Mining", 165: "Leatherworking", 197: "Tailoring"}

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
    spell_reagents = read_table("SpellReagents", cache_dir, refresh)
    spell_effects = read_table("SpellEffect", cache_dir, refresh)
    skill_line_rows = read_table("SkillLine", cache_dir, refresh)

    stats = {"rows": 0, "no_thresholds": 0, "invalid": 0, "conflicting": 0, "several_lines": 0, "bad_reagents": 0}
    found = {}  # spell -> set of (yellow, grey) seen for it
    lines_of = {}  # spell -> set of profession skill lines it is an ability of
    for row in abilities:
        skill_line = to_int(row["SkillLine"])
        if skill_line not in PROFESSION_SKILL_LINES:
            continue
        spell = to_int(row["Spell"])
        yellow, grey = to_int(row["TrivialSkillLineRankLow"]), to_int(row["TrivialSkillLineRankHigh"])
        if spell is None or spell <= 0:
            stats["invalid"] += 1
            continue
        stats["rows"] += 1
        lines_of.setdefault(spell, set()).add(skill_line)
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

    seen_reagent_rows = set()
    reagents = {}  # recipe spell -> [item, count, item, count, ...] in slot order, equal items added up
    for row in spell_reagents:
        spell = to_int(row["SpellID"])
        if spell not in found:
            continue
        if spell in reagents or spell in seen_reagent_rows:
            raise SystemExit("SpellReagents has several rows for spell %d: the ingredients cannot be told apart" % spell)
        seen_reagent_rows.add(spell)
        counts = {}
        for i in range(REAGENT_SLOTS):
            item, count = to_int(row["Reagent_%d" % i]), to_int(row["ReagentCount_%d" % i])
            if item is None or count is None or item < 0 or count < 0:
                stats["bad_reagents"] += 1
            elif item > 0 and count > 0:
                counts[item] = counts.get(item, 0) + count
        if counts:
            reagents[spell] = [value for item, count in counts.items() for value in (item, count)]  # dicts keep insertion order

    outputs = {}  # recipe spell -> the item its first "create item" effect makes
    first_effect = {}
    for row in spell_effects:
        spell, index, effect, item = to_int(row["SpellID"]), to_int(row["EffectIndex"]), to_int(row["Effect"]), to_int(row["EffectItemType"])
        if spell in found and effect == CREATE_ITEM_EFFECT and item is not None and item > 0:
            if spell not in first_effect or (index or 0) < first_effect[spell]:
                first_effect[spell] = index or 0
                outputs[spell] = item

    # Recipes: spells with skill-up thresholds or ingredients. Gathering abilities have neither and are left out.
    skill_lines = {}  # recipe spell -> sorted list of its profession skill lines (several when a spell belongs to more than one)
    for spell in found:
        if spell in thresholds or spell in reagents:
            skill_lines[spell] = sorted(lines_of[spell])
            if len(lines_of[spell]) > 1:
                stats["several_lines"] += 1
    outputs = {spell: item for spell, item in outputs.items() if spell in skill_lines}

    # English names of the skill lines the recipes belong to (the addon prefers the client's own name when it knows one).
    used_lines = {line for lines in skill_lines.values() for line in lines}
    line_names = {}
    for row in skill_line_rows:
        line, name = to_int(row["ID"]), (row["DisplayName_lang"] or "").strip()
        if line in used_lines and name:
            line_names[line] = name
    missing_lines = sorted(used_lines - set(line_names))
    if missing_lines:
        raise SystemExit("SkillLine has no name for the skill lines %s" % ", ".join(str(line) for line in missing_lines))
    for line, expected in SANITY_LINE_NAMES.items():
        if line_names.get(line) != expected:
            raise SystemExit("sanity check failed: skill line %d is named %s, expected %s" % (line, line_names.get(line), expected))

    for spell, expected in SANITY_THRESHOLDS.items():
        if thresholds.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d has thresholds %s, expected %s" % (spell, thresholds.get(spell), expected))
    for spell, expected in SANITY_TEACHERS.items():
        if teachers.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d is taught by item %s, expected %s" % (spell, teachers.get(spell), expected))
    for spell, expected in SANITY_REAGENTS.items():
        if reagents.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d has ingredients %s, expected %s" % (spell, reagents.get(spell), expected))
    for spell, expected in SANITY_OUTPUTS.items():
        if outputs.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d makes item %s, expected %s" % (spell, outputs.get(spell), expected))
    for spell, expected in SANITY_SKILL_LINES.items():
        if skill_lines.get(spell) != expected:
            raise SystemExit("sanity check failed: spell %d is in skill line %s, expected %s" % (spell, skill_lines.get(spell), expected))
    return thresholds, teachers, skill_lines, reagents, outputs, line_names, stats


def pack(lines, entries, width=118):
    """Appends the entries (strings) to lines, as many as fit on a line."""
    current = ""
    for entry in entries:
        if current and len(current) + len(entry) > width:
            lines.append(current)
            current = ""
        current += entry
    if current:
        lines.append(current)


def render(thresholds, teachers, skill_lines, reagents, outputs, line_names):
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    lines = [
        "local addonName, ns = ...",
        "",
        "-- Generated by tools/gen_recipe_data.py. Do not edit; run `python -I tools/gen_recipe_data.py` to regenerate it.",
        "-- Source: Blizzard game data (DB2 tables) via wago.tools, WoW Forever build %s." % BUILD,
        "--   SkillLineAbility, ItemXItemEffect, ItemEffect, SpellReagents, SpellEffect and SkillLine: " + (BASE_URL % "<table>") + "?build=" + BUILD,
        "-- Generated: %s. %d recipes with skill-up thresholds, %d recipes with a teaching item, %d recipes with a skill line," % (today, len(thresholds), len(teachers), len(skill_lines)),
        "--   %d with ingredients and %d with an item they make; %d skill line names." % (len(reagents), len(outputs), len(line_names)),
        "-- ns.RecipeThresholds[spellID] = { yellow, grey }: the skill where the recipe turns yellow and where it turns grey (orange",
        "--   is below yellow, green is floor((yellow + grey) / 2)). ns.RecipeTeachers[spellID] = lowest item ID that teaches it.",
        "-- ns.RecipeSkillLines[spellID] = the profession skill line (GetProfessionInfo's skillLine) the recipe belongs to, or a sorted",
        "--   list { line, line } for the few recipes that belong to several.",
        "-- ns.RecipeReagents[spellID] = { itemID, count, itemID, count, ... } (flat); ns.RecipeOutputs[spellID] = the item it makes.",
        "-- ns.SkillLineNames[skillLine] = the English name of the skill line (only the lines the recipes belong to).",
        "",
        "ns.RecipeThresholds = {",
    ]
    for spell in sorted(thresholds):
        lines.append("[%d]={%d,%d}," % ((spell,) + thresholds[spell]))
    lines += ["}", "", "ns.RecipeTeachers = {"]
    for spell in sorted(teachers):
        lines.append("[%d]=%d," % (spell, teachers[spell]))
    lines += ["}", "", "ns.RecipeSkillLines = {"]
    pack(lines, [("[%d]=%d," % (spell, skill_lines[spell][0])) if len(skill_lines[spell]) == 1
                 else ("[%d]={%s}," % (spell, ",".join(str(line) for line in skill_lines[spell]))) for spell in sorted(skill_lines)])
    lines += ["}", "", "ns.RecipeReagents = {"]
    for spell in sorted(reagents):
        lines.append("[%d]={%s}," % (spell, ",".join(str(value) for value in reagents[spell])))
    lines += ["}", "", "ns.RecipeOutputs = {"]
    pack(lines, ["[%d]=%d," % (spell, outputs[spell]) for spell in sorted(outputs)])
    lines += ["}", "", "ns.SkillLineNames = {"]
    pack(lines, ['[%d]="%s",' % (line, line_names[line].replace("\\", "\\\\").replace('"', '\\"')) for line in sorted(line_names)])
    lines += ["}", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cache", default=os.path.join(tempfile.gettempdir(), "jimmysutils-recipedata", BUILD),
                        help="folder for the downloaded CSV files (default: a folder in the temp directory)")
    parser.add_argument("--refresh", action="store_true", help="download the CSV files again")
    args = parser.parse_args()

    os.makedirs(args.cache, exist_ok=True)
    thresholds, teachers, skill_lines, reagents, outputs, line_names, stats = build(args.cache, args.refresh)
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="ascii", newline="\n") as fh:
        fh.write(render(thresholds, teachers, skill_lines, reagents, outputs, line_names))
    print("build %s: %d recipes with thresholds, %d teaching items (profession rows %d, without thresholds %d, invalid %d, conflicting %d)"
          % (BUILD, len(thresholds), len(teachers), stats["rows"], stats["no_thresholds"], stats["invalid"], stats["conflicting"]))
    print("%d skill lines (%d recipes in several), %d with ingredients (%d bad slots), %d with an output, %d skill line names"
          % (len(skill_lines), stats["several_lines"], len(reagents), stats["bad_reagents"], len(outputs), len(line_names)))
    print("wrote", OUTPUT)


if __name__ == "__main__":
    sys.exit(main())

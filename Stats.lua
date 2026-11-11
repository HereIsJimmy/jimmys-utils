local addonName, ns = ...

--[[
	Stat definitions.

	ns.STAT_GROUPS   ordered list of { id, label } used to organise the stat lists of the options window.
	ns.STATS         ordered list of { key, group, label, default, covers?, patterns? }.
	ns.STATS_BY_KEY  lookup of the above by key.

	Keys are the global-string names returned by C_Item.GetItemStats. English "Equip:"
	tooltip lines are read with `patterns` and only used when the API reported none of
	the stats listed in `covers`. Same-unit effects (Attack Power, Spell Power, mp5, ...)
	carry their patterns on the main stat and are scored under its weight. Percentage
	effects and defense skill (the API reports defense rating) are "parsed" pseudo-stats
	(JSW_EQUIP_*) that keep their own "(Equip)" entries.
]]

ns.STAT_GROUPS = {
	{ id = "primary", label = "Primary stats" },
	{ id = "secondary", label = "Secondary stats" },
	{ id = "defense", label = "Defensive stats" },
	{ id = "resist", label = "Resistances" },
	{ id = "weapon", label = "Weapon" },
	{ id = "parsed", label = "Equip effects (read from tooltip text)" },
	{ id = "detected", label = "Other stats detected on items" },
}

ns.STATS = {}
ns.STATS_BY_KEY = {}

local function AddStat(group, key, label, default, covers, patterns)
	local stat = {
		key = key,
		group = group,
		label = label,
		default = default,
		covers = covers,
		patterns = patterns,
	}
	ns.STATS[#ns.STATS + 1] = stat
	ns.STATS_BY_KEY[key] = stat
end

-- Primary
AddStat("primary", "ITEM_MOD_STRENGTH_SHORT", "Strength", 1)
AddStat("primary", "ITEM_MOD_AGILITY_SHORT", "Agility", 1)
AddStat("primary", "ITEM_MOD_STAMINA_SHORT", "Stamina", 1)
AddStat("primary", "ITEM_MOD_INTELLECT_SHORT", "Intellect", 1)
AddStat("primary", "ITEM_MOD_SPIRIT_SHORT", "Spirit", 1)

-- Secondary
AddStat("secondary", "ITEM_MOD_HIT_RATING_SHORT", "Hit", 0)
AddStat("secondary", "ITEM_MOD_CRIT_RATING_SHORT", "Critical Strike", 0)
AddStat("secondary", "ITEM_MOD_HASTE_RATING_SHORT", "Haste", 0)
AddStat("secondary", "ITEM_MOD_EXPERTISE_RATING_SHORT", "Expertise", 0)
AddStat("secondary", "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT", "Armor Penetration", 0)
AddStat("secondary", "ITEM_MOD_ATTACK_POWER_SHORT", "Attack Power", 0,
	{ "ITEM_MOD_ATTACK_POWER_SHORT" },
	{ "^%+(%d+) attack power$" })
AddStat("secondary", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT", "Ranged Attack Power", 0,
	{ "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
	{ "^%+(%d+) ranged attack power$" })
AddStat("secondary", "ITEM_MOD_SPELL_POWER_SHORT", "Spell Power", 0,
	{ "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" },
	{
		"^increases damage and healing done by magical spells and effects by up to (%d+)$",
		"^increases spell power by (%d+)$",
	})
AddStat("secondary", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT", "Spell Damage", 0)
AddStat("secondary", "ITEM_MOD_SPELL_HEALING_DONE_SHORT", "Bonus Healing", 0,
	{ "ITEM_MOD_SPELL_HEALING_DONE_SHORT" },
	{
		"^increases healing done by spells and effects by up to (%d+)$",
		"^increases healing done by up to (%d+) and damage done by up to %d+ for all magical spells and effects$",
	})
AddStat("secondary", "ITEM_MOD_SPELL_PENETRATION_SHORT", "Spell Penetration", 0,
	{ "ITEM_MOD_SPELL_PENETRATION_SHORT" },
	{ "^decreases the magical resistances of your spell targets by (%d+)$" })
AddStat("secondary", "ITEM_MOD_MANA_REGENERATION_SHORT", "Mana per 5 sec.", 0,
	{ "ITEM_MOD_MANA_REGENERATION_SHORT", "ITEM_MOD_POWER_REGEN0_SHORT" },
	{
		"^restores (%d+) mana per 5 sec$",
		"^restores (%d+) mana every 5 sec$",
	})
AddStat("secondary", "ITEM_MOD_HEALTH_REGEN_SHORT", "Health per 5 sec.", 0,
	{ "ITEM_MOD_HEALTH_REGEN_SHORT", "ITEM_MOD_HEALTH_REGENERATION_SHORT" },
	{
		"^restores (%d+) health per 5 sec$",
		"^restores (%d+) health every 5 sec$",
	})

-- Defense
AddStat("defense", "RESISTANCE0_NAME", "Armor", 0)
AddStat("defense", "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT", "Defense", 0)
AddStat("defense", "ITEM_MOD_DODGE_RATING_SHORT", "Dodge", 0)
AddStat("defense", "ITEM_MOD_PARRY_RATING_SHORT", "Parry", 0)
AddStat("defense", "ITEM_MOD_BLOCK_RATING_SHORT", "Block", 0)
AddStat("defense", "ITEM_MOD_BLOCK_VALUE_SHORT", "Block Value", 0,
	{ "ITEM_MOD_BLOCK_VALUE_SHORT" },
	{ "^increases the block value of your shield by (%d+)$" })

-- Resistances
AddStat("resist", "RESISTANCE6_NAME", "Arcane Resistance", 0)
AddStat("resist", "RESISTANCE2_NAME", "Fire Resistance", 0)
AddStat("resist", "RESISTANCE4_NAME", "Frost Resistance", 0)
AddStat("resist", "RESISTANCE3_NAME", "Nature Resistance", 0)
AddStat("resist", "RESISTANCE5_NAME", "Shadow Resistance", 0)

-- Weapon
AddStat("weapon", "ITEM_MOD_DAMAGE_PER_SECOND_SHORT", "Damage per Second", 0)

-- Parsed "Equip:" effects that have no same-unit main stat (English client only)
AddStat("parsed", "JSW_EQUIP_HIT_PCT", "Hit chance % (Equip)", 0,
	{ "ITEM_MOD_HIT_RATING_SHORT", "ITEM_MOD_HIT_MELEE_RATING_SHORT", "ITEM_MOD_HIT_RANGED_RATING_SHORT", "ITEM_MOD_HIT_SPELL_RATING_SHORT" },
	{
		"^improves your chance to hit by ([%d%.]+)%%$",
		"^improves your chance to hit with spells by ([%d%.]+)%%$",
		"^improves your chance to hit with all spells and attacks by ([%d%.]+)%%$",
	})
AddStat("parsed", "JSW_EQUIP_CRIT_PCT", "Critical strike % (Equip)", 0,
	{ "ITEM_MOD_CRIT_RATING_SHORT", "ITEM_MOD_CRIT_MELEE_RATING_SHORT", "ITEM_MOD_CRIT_RANGED_RATING_SHORT", "ITEM_MOD_CRIT_SPELL_RATING_SHORT" },
	{
		"^improves your chance to get a critical strike by ([%d%.]+)%%$",
		"^improves your chance to get a critical strike with spells by ([%d%.]+)%%$",
		"^improves your chance to get a critical strike with all spells and attacks by ([%d%.]+)%%$",
	})
AddStat("parsed", "JSW_EQUIP_HASTE_PCT", "Haste % (Equip)", 0,
	{ "ITEM_MOD_HASTE_RATING_SHORT" },
	{
		"^increases your attack and casting speed by ([%d%.]+)%%$",
		"^increases your haste by ([%d%.]+)%%$",
	})
AddStat("parsed", "JSW_EQUIP_EXPERTISE_PCT", "Dodge/Parry reduction % (Equip)", 0,
	{ "ITEM_MOD_EXPERTISE_RATING_SHORT" },
	{ "^reduces chance to be dodged or parried by ([%d%.]+)%%$" })
AddStat("parsed", "JSW_EQUIP_DEFENSE", "Defense (Equip)", 0,
	{ "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT" },
	{ "^increased defense %+(%d+)$" })
AddStat("parsed", "JSW_EQUIP_DODGE_PCT", "Dodge % (Equip)", 0,
	{ "ITEM_MOD_DODGE_RATING_SHORT" },
	{ "^increases your chance to dodge an attack by ([%d%.]+)%%$" })
AddStat("parsed", "JSW_EQUIP_PARRY_PCT", "Parry % (Equip)", 0,
	{ "ITEM_MOD_PARRY_RATING_SHORT" },
	{ "^increases your chance to parry an attack by ([%d%.]+)%%$" })
AddStat("parsed", "JSW_EQUIP_BLOCK_PCT", "Block % (Equip)", 0,
	{ "ITEM_MOD_BLOCK_RATING_SHORT" },
	{ "^increases your chance to block attacks with a shield by ([%d%.]+)%%$" })

-- Other names clients use for a stat in the list (Classic reports mp5 as POWER_REGEN0).
local STAT_ALIASES = {
	ITEM_MOD_POWER_REGEN0_SHORT = "ITEM_MOD_MANA_REGENERATION_SHORT",
	ITEM_MOD_HEALTH_REGENERATION_SHORT = "ITEM_MOD_HEALTH_REGEN_SHORT",
}

-- Keys named in any `covers` list, built on first use.
local coverKeys

local function IsCoverKey(key)
	if not coverKeys then
		coverKeys = {}
		for _, stat in ipairs(ns.STATS) do
			for _, coverKey in ipairs(stat.covers or {}) do
				coverKeys[coverKey] = true
			end
		end
	end
	return coverKeys[key] == true
end

-- Some clients report a stat without the _SHORT suffix (Classic: ITEM_MOD_SPELL_HEALING_DONE)
-- or under another name. Returns the key the stat list knows it by, or the key unchanged.
function ns.NormalizeStatKey(key)
	if STAT_ALIASES[key] then
		return STAT_ALIASES[key]
	end
	local short = key .. "_SHORT"
	if not ns.STATS_BY_KEY[key] and STAT_ALIASES[short] then
		return STAT_ALIASES[short]
	end
	if not ns.STATS_BY_KEY[key] and (ns.STATS_BY_KEY[short] or IsCoverKey(short)) then
		return short
	end
	return key
end

-- Returns the localized global string for a stat key, or nil when it is unusable.
local function GetGlobalLabel(key)
	local text = _G[key]
	if type(text) == "string" and text ~= "" and not text:find("%", 1, true) then
		return text
	end
end

-- "ITEM_MOD_CRIT_RATING_SHORT" -> "Crit Rating"
local function PrettifyKey(key)
	local text = key:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_", " ")
	text = text:gsub("(%a)([%w]*)", function(first, rest)
		return first:upper() .. rest:lower()
	end)
	return text
end

function ns.GetStatLabel(key)
	if type(key) ~= "string" then
		return tostring(key)
	end

	local stat = ns.STATS_BY_KEY[key]
	if stat then
		-- Parsed pseudo-stats have fixed labels; everything else prefers the client's own text.
		if stat.group ~= "parsed" then
			return GetGlobalLabel(key) or stat.label
		end
		return stat.label
	end

	return GetGlobalLabel(key) or PrettifyKey(key)
end

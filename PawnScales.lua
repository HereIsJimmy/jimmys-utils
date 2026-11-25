local addonName, ns = ...

--[[
	Pawn scale tags: the text Pawn (VgerMods) uses to share a stat scale, imported as and exported from a stat weight scale.

		( Pawn: v1: "Name": Strength=1.5, Stamina=1, HitRating=2 )

	ns.ParsePawnTag(text)           -> name, weights, skipped, meta | nil, error. weights is { [statKey] = number } (zero weights
	                                   left out); skipped lists the names in the tag that were not imported (Pawn stats this addon
	                                   has no stat for, and entries that are not Name=Number); meta = { class = "Warrior" | nil }.
	ns.ImportPawnScale(text, replace) -> true, scaleName, info | false, error, info. Creates the scale and makes it the active one.
	                                   A scale of that name (any spelling) is only replaced when `replace` is true (otherwise
	                                   info.exists names it), and then only the weights Pawn can express are overwritten or cleared:
	                                   the ones it has no name for (the "(Equip)" effects, detected stats) are kept, nothing else
	                                   of the scale changes. info = { count, skipped, name, replaced, shortened, exists, kept,
	                                   classTemplate, class }.
	ns.GetPawnTag(name)             -> tag, skipped | nil, error. The active scale when name is nil. skipped lists the weighted
	                                   stats that have no Pawn name (they are left out of the tag).
	ns.FormatPawnImport(name, info) -> the chat line that reports an import.
	ns.IsPawnKey(key)               -> whether a Pawn tag can express the stat of that key.
	ns.PAWN_CLASS_WARNING           -> the warning shown after importing a tag with Class=.

	The tag format and the stat names are Pawn's (Pawn.lua: PawnParseScaleTag, PawnGetScaleTag). Class= and Spec= are not
	stats and are not imported, a value of X means "ignore this stat" and is skipped, version 1 is the only one that exists.

	Class tags: a tag with Class= only lists what differs from Pawn's class template (PawnGetScaleTag leaves out the values that equal
	the template's; Pawn's import puts the template back). The templates are not part of this addon, so such a tag imports only the
	listed weights and info.classTemplate is set, so the import can warn that the other stats are missing. A tag from a scale that has
	no class (an empty/custom scale in Pawn) or one made by a website lists every stat and imports completely.

	Spell power follows Pawn's scoring. Pawn counts "+X damage and healing" as SpellDamage = X plus Healing = X, a healing-only line
	as Healing and a damage-only line as SpellDamage. Here ITEM_MOD_SPELL_POWER_SHORT is the combined line, ITEM_MOD_SPELL_HEALING_DONE_SHORT
	the healing-only line and ITEM_MOD_SPELL_DAMAGE_DONE_SHORT the damage-only line. Import: SPELL_POWER = SpellDamage + Healing (+ the
	Wrath stat SpellPower), HEALING_DONE = Healing, SPELL_DAMAGE_DONE = SpellDamage. Export: Healing = the HEALING_DONE weight,
	SpellDamage = the SPELL_DAMAGE_DONE weight when it is not 0, else SPELL_POWER - HEALING_DONE. That is exact when SPELL_POWER =
	SPELL_DAMAGE_DONE + HEALING_DONE (what an import makes, and the usual healer or caster scale), an approximation otherwise (a
	scale that weighs the combined line differently from its parts cannot be written as a Pawn tag). (Pawn's SpellDamageNoHealing is a
	tooltip pattern, not a stat of a tag.)
]]

local PAWN_TAG_VERSION = 1

-- { Pawn name, stat key }. A key that appears twice is written under the first name.
local PAWN_STATS = {
	{ "Strength", "ITEM_MOD_STRENGTH_SHORT" },
	{ "Agility", "ITEM_MOD_AGILITY_SHORT" },
	{ "Stamina", "ITEM_MOD_STAMINA_SHORT" },
	{ "Intellect", "ITEM_MOD_INTELLECT_SHORT" },
	{ "Spirit", "ITEM_MOD_SPIRIT_SHORT" },
	{ "Armor", "RESISTANCE0_NAME" },
	{ "HitRating", "ITEM_MOD_HIT_RATING_SHORT" },
	{ "CritRating", "ITEM_MOD_CRIT_RATING_SHORT" },
	{ "HasteRating", "ITEM_MOD_HASTE_RATING_SHORT" },
	{ "ExpertiseRating", "ITEM_MOD_EXPERTISE_RATING_SHORT" },
	{ "ArmorPenetration", "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT" },
	{ "SpellPenetration", "ITEM_MOD_SPELL_PENETRATION_SHORT" },
	{ "Ap", "ITEM_MOD_ATTACK_POWER_SHORT" },
	{ "Rap", "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
	{ "SpellDamage", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" }, -- the three spell stats are read and written by the spell power model
	{ "SpellPower", "ITEM_MOD_SPELL_POWER_SHORT" },
	{ "Healing", "ITEM_MOD_SPELL_HEALING_DONE_SHORT" },
	{ "DefenseRating", "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT" },
	{ "DodgeRating", "ITEM_MOD_DODGE_RATING_SHORT" },
	{ "ParryRating", "ITEM_MOD_PARRY_RATING_SHORT" },
	{ "BlockRating", "ITEM_MOD_BLOCK_RATING_SHORT" },
	{ "BlockValue", "ITEM_MOD_BLOCK_VALUE_SHORT" },
	{ "Mp5", "ITEM_MOD_MANA_REGENERATION_SHORT" },
	{ "Hp5", "ITEM_MOD_HEALTH_REGEN_SHORT" },
	{ "FireResist", "RESISTANCE2_NAME" },
	{ "NatureResist", "RESISTANCE3_NAME" },
	{ "FrostResist", "RESISTANCE4_NAME" },
	{ "ShadowResist", "RESISTANCE5_NAME" },
	{ "ArcaneResist", "RESISTANCE6_NAME" },
	{ "Dps", "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" },
}

-- Names in a tag that describe the scale, not a stat.
local NOT_STATS = { class = true, spec = true }

local SPELL_POWER_KEY = "ITEM_MOD_SPELL_POWER_SHORT" -- "+X damage and healing"
local HEALING_KEY = "ITEM_MOD_SPELL_HEALING_DONE_SHORT" -- healing only
local DAMAGE_KEY = "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" -- damage only
local SPELL_STAT_BY_PAWN = { spelldamage = "damage", spellpower = "power", healing = "healing" } -- lowercase Pawn name -> role

ns.PAWN_CLASS_WARNING = "Pawn class scales only list the weights you changed from Pawn's class template; the other stats are missing."

local KEY_BY_PAWN = {} -- lowercase Pawn name -> stat key
local PAWN_BY_KEY = {} -- stat key -> Pawn name (the stats written one to one; the spell stats are written by AddSpellStats)
local PAWN_KEYS = { [SPELL_POWER_KEY] = true, [HEALING_KEY] = true, [DAMAGE_KEY] = true } -- the stat keys a tag can express
for _, entry in ipairs(PAWN_STATS) do
	KEY_BY_PAWN[entry[1]:lower()] = entry[2]
	PAWN_KEYS[entry[2]] = true
	if not PAWN_BY_KEY[entry[2]] and not SPELL_STAT_BY_PAWN[entry[1]:lower()] then
		PAWN_BY_KEY[entry[2]] = entry[1]
	end
end

function ns.IsPawnKey(key)
	return PAWN_KEYS[key] == true
end

-- The names Pawn uses, in the order of the table above (for the documentation and the tests).
function ns.GetPawnStatNames()
	local names = {}
	for _, entry in ipairs(PAWN_STATS) do
		names[#names + 1] = entry[1]
	end
	return names
end

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

local function IsFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Sums and differences of weights without the noise of floating point (0.2 + 0.1).
local function Round(value)
	local rounded = math.floor(value * 1e9 + 0.5) / 1e9
	return rounded ~= 0 and rounded or 0
end

-- A weight as Pawn reads it back: no exponent (its value pattern has room for a sign in front only), no trailing noise.
local function FormatPawnNumber(value)
	local text = string.format("%.14g", value)
	if text:find("e", 1, true) then
		if math.abs(value) >= 1 then
			text = string.format("%.0f", value)
		else
			text = string.format("%.12f", value):gsub("0+$", ""):gsub("%.$", "")
		end
	end
	if text == "-0" or text == "" then
		text = "0"
	end
	return text
end

-- The first `limit` UTF-8 characters of a text.
local function CutCharacters(text, limit)
	local count = 0
	for start in text:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
		count = count + 1
		if count > limit then
			return text:sub(1, start - 1)
		end
	end
	return text
end

--------------------------------------------------------------------------------
-- Import
--------------------------------------------------------------------------------

function ns.ParsePawnTag(text)
	if type(text) ~= "string" or text:match("^%s*$") then
		return nil, "Paste a Pawn scale tag first."
	end

	local version, name, body = text:match('^%s*%(%s*Pawn%s*:%s*v(%d+)%s*:%s*"([^"]+)"%s*:%s*(.+)%s*%)%s*$')
	if not version then
		return nil, "That is not a Pawn scale tag. It looks like: ( Pawn: v1: \"Name\": Strength=1, Stamina=0.5 )"
	end
	if (tonumber(version) or 0) > PAWN_TAG_VERSION then
		return nil, "This Pawn scale tag is version " .. version .. "; only version " .. PAWN_TAG_VERSION .. " tags can be imported."
	end
	name = Trim(name:gsub("%s+", " "))
	if name == "" then
		return nil, "The Pawn scale tag has no name."
	end

	local weights, skipped, seen, meta = {}, {}, {}, {}
	local spell = {} -- the spell stats of the tag, put together at the end
	local function Skip(label)
		local lowered = label:lower()
		if not seen[lowered] then
			seen[lowered] = true
			skipped[#skipped + 1] = label
		end
	end

	for pair in body:gmatch("[^,]+") do
		local stat, label = pair:match("^%s*([%a%d]+)%s*=%s*([%a%d ]-)%s*$")
		if stat and NOT_STATS[stat:lower()] then
			-- Class= and Spec= say which character the scale is for; a class means the tag lacks the class template's values
			if stat:lower() == "class" then
				meta.class = label ~= "" and label or true
			end
		else
			local value
			stat, value = pair:match("^%s*([%a%d]+)%s*=%s*(%-?[%d%.a-zA-Z]+)%s*$")
			if not stat then
				local fragment = Trim(pair)
				if fragment ~= "" then
					Skip(fragment)
				end
			elseif value:lower() ~= "x" then -- X: Pawn ignores the stat
				local key = KEY_BY_PAWN[stat:lower()]
				local number = tonumber(value)
				if key and IsFiniteNumber(number) then
					local role = SPELL_STAT_BY_PAWN[stat:lower()]
					if role then
						spell[role] = number
					else
						weights[key] = number ~= 0 and number or nil
					end
				else
					Skip(stat)
				end
			end
		end
	end

	-- Pawn scores "+X damage and healing" as SpellDamage + Healing, so the combined line weighs both.
	local damage, healing, power = spell.damage or 0, spell.healing or 0, spell.power or 0
	local combined = Round(damage + healing + power)
	weights[SPELL_POWER_KEY] = combined ~= 0 and combined or nil
	weights[HEALING_KEY] = healing ~= 0 and healing or nil
	weights[DAMAGE_KEY] = damage ~= 0 and damage or nil
	-- How many stats of the tag were usable (as Pawn counts them: SpellDamage and Healing are two, not three).
	meta.count = 0
	for key in pairs(weights) do
		if key ~= SPELL_POWER_KEY and key ~= HEALING_KEY and key ~= DAMAGE_KEY then
			meta.count = meta.count + 1
		end
	end
	for _, number in pairs(spell) do
		if number ~= 0 then
			meta.count = meta.count + 1
		end
	end
	return name, weights, skipped, meta
end

-- Creates the scale described by a tag (or, with `replace`, overwrites the weights of the one of that name) and makes it the active one.
function ns.ImportPawnScale(text, replace)
	local name, weights, skipped, meta = ns.ParsePawnTag(text)
	if not name then
		return false, weights -- the second value of a failed parse is the message
	end

	local info = { count = meta.count, skipped = skipped }
	if meta.class then
		info.classTemplate = true
		info.class = meta.class ~= true and meta.class or nil
	end

	local shortened = Trim(CutCharacters(name, ns.MAX_PROFILE_NAME))
	if shortened ~= name then
		name = shortened
		info.shortened = true
	end
	info.name = name

	if info.count == 0 then
		if info.classTemplate then
			return false, "The tag has no stat weights this addon can use. " .. ns.PAWN_CLASS_WARNING
				.. " In Pawn, create the scale as an empty (custom) scale without a class, or use a tag made by a website (it lists every stat).", info
		end
		return false, "The tag has no stat weights this addon can use.", info
	end

	local existing = ns.FindProfileName(name)
	if existing then
		if replace ~= true then
			info.exists = existing
			return false, "A scale named \"" .. existing .. "\" already exists.", info
		end
		-- Only what a tag can say is replaced; the weights Pawn has no name for stay.
		local old = ns.GetProfileWeights(existing)
		info.kept = 0
		for key, value in pairs(old or {}) do
			if not PAWN_KEYS[key] and IsFiniteNumber(value) and value ~= 0 then
				info.kept = info.kept + 1
			end
		end
		ns.ReplaceProfileWeights(existing, weights, ns.IsPawnKey)
		name = existing
		info.replaced = true
	else
		local ok, err = ns.CreateProfile(name)
		if not ok then
			return false, err, info
		end
		ns.ReplaceProfileWeights(name, weights)
	end
	ns.SetActiveProfile(name)
	info.name = name
	return true, name, info
end

-- "Imported 5 stats into scale "Tank"; skipped: FeralAp, Speed."
function ns.FormatPawnImport(name, info)
	local count = info and info.count or 0
	local text = string.format("Imported %d %s into scale \"%s\"", count, count == 1 and "stat" or "stats", tostring(name))
	if info and info.replaced then
		text = text .. " (its weights were replaced)"
	end
	if info and info.kept and info.kept > 0 then
		text = text .. " (kept " .. info.kept .. " weight" .. (info.kept == 1 and "" or "s") .. " Pawn has no name for)"
	end
	if info and info.shortened then
		text = text .. " (the name was cut to " .. ns.MAX_PROFILE_NAME .. " characters)"
	end
	if info and info.skipped and #info.skipped > 0 then
		text = text .. "; skipped: " .. table.concat(info.skipped, ", ")
	end
	text = text .. "."
	if info and info.classTemplate then
		text = text .. " Warning: " .. ns.PAWN_CLASS_WARNING
	end
	return text
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------

function ns.GetPawnTag(name)
	local scale
	if name == nil then
		scale = ns.GetActiveProfileName()
	else
		scale = ns.FindProfileName(name)
	end
	local weights = scale and ns.GetProfileWeights(scale)
	if not weights then
		return nil, "Scale not found."
	end

	local entries, skipped = {}, {}
	local function Weight(key)
		local weight = weights[key]
		return IsFiniteNumber(weight) and weight or 0
	end
	-- The spell stats become SpellDamage and Healing (see the top of the file); written once, where the first of the three is listed.
	local spellDone = false
	local function AddSpellStats()
		spellDone = true
		local healing = Weight(HEALING_KEY)
		local damage = Weight(DAMAGE_KEY)
		if damage == 0 then
			damage = Round(Weight(SPELL_POWER_KEY) - healing)
		end
		if damage ~= 0 then
			entries[#entries + 1] = "SpellDamage=" .. FormatPawnNumber(damage)
		end
		if healing ~= 0 then
			entries[#entries + 1] = "Healing=" .. FormatPawnNumber(healing)
		end
	end
	local function Add(key)
		local weight = weights[key]
		if not IsFiniteNumber(weight) or weight == 0 then
			return
		end
		if key == SPELL_POWER_KEY or key == HEALING_KEY or key == DAMAGE_KEY then
			if not spellDone then
				AddSpellStats()
			end
			return
		end
		local pawnName = PAWN_BY_KEY[key]
		if pawnName then
			entries[#entries + 1] = pawnName .. "=" .. FormatPawnNumber(weight)
		else
			skipped[#skipped + 1] = ns.GetStatLabel(key)
		end
	end

	local listed = {}
	for _, stat in ipairs(ns.STATS) do
		listed[stat.key] = true
		Add(stat.key)
	end
	-- Weights on stats that are not in the static list (detected stats) have no Pawn name either.
	local extra = {}
	for key in pairs(weights) do
		if not listed[key] then
			extra[#extra + 1] = key
		end
	end
	table.sort(extra, function(a, b)
		local la, lb = ns.GetStatLabel(a):lower(), ns.GetStatLabel(b):lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	for _, key in ipairs(extra) do
		Add(key)
	end

	if #entries == 0 then
		local message = "Scale \"" .. scale .. "\" has no weights that Pawn has a name for."
		if #skipped > 0 then
			message = message .. " (Left out: " .. table.concat(skipped, ", ") .. ".)"
		end
		return nil, message
	end

	-- A quote or a line break in the name would break the tag.
	local tagName = scale:gsub("\"", "'"):gsub("%s", " ")
	return "( Pawn: v" .. PAWN_TAG_VERSION .. ": \"" .. tagName .. "\": " .. table.concat(entries, ", ") .. " )", skipped
end

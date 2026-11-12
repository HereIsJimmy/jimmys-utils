local addonName, ns = ...

--[[
	Data layer (SavedVariables, profiles, weights, settings) and slash commands.

	The SavedVariables keep their original variable names (the addon used to be "Jimmy's Stat Weights"). The
	client names the saved file after the addon folder, so the data now lives in WTF\...\SavedVariables\JimmysUtils.lua.
	To keep data from the old addon, rename its JimmysStatWeights.lua files (account-wide and per character) to
	JimmysUtils.lua and remove the old JimmysStatWeights folder.

	JimmysStatWeightsDB = {
		dbVersion = 2,
		profiles = { ["Default"] = { weights = { [statKey] = number } } }, -- only non-zero weights stored
		discovered = { [statKey] = true },
		settings = { decimals = 1, hideZero = true, breakdown = "alt", parseEquipText = true },
		optionsTab = "stats", -- last tab of the options window ("stats" | "range" | "recipes" | "mail")
		stats = { enabled }, -- show the stat weight score on item tooltips (the profile editing always works)
		range = { enabled, locked, size, anchor, point, x, y }, -- validated in RangeCheck.lua
		recipeLookup = { enabled }, -- scan professions and answer the recipe lookup, validated in Recipes.lua
		recipes, recipeKnownBy, itemNames, -- saved recipes, validated in Recipes.lua
		mail = { enabled }, -- master switch of the recent recipients and the mail materials, validated in Mail.lua
		mailRecipients = { [realmKey] = { names } }, -- recent mail recipients, validated in Mail.lua
		mailMaterials = { position, showOthers }, -- the "materials in your mail" window, validated in MailMaterials.lua
		inventory = { ["Name-Realm"] = { bags, bagsTime, bank, bankTime, mail } }, -- item snapshots (and the last scan of the mailbox) per character, validated in Inventory.lua
		accountBank = { items, time }, -- the account bank, validated in Inventory.lua
		minimap = { hide, angle }, -- the minimap button, validated in Minimap.lua
	}
	JimmysStatWeightsCharDB = { profile = "Default", rangeSpell = spellID }
	-- (older versions also kept mailItems here: the last scan of the mailbox, now db.inventory[character].mail)
]]

local DB_VERSION = 2
local DEFAULT_PROFILE = "Default"
local MAX_PROFILE_NAME = 32
local CHAT_PREFIX = "|cff66c7ffJimmy's Utils|r: "

local DEFAULT_SETTINGS = {
	decimals = 1,
	hideZero = true,
	breakdown = "alt",
	parseEquipText = true,
}
ns.DEFAULT_SETTINGS = DEFAULT_SETTINGS

local DEFAULT_STATS = {
	enabled = true,
}

local BREAKDOWN_MODES = { always = true, shift = true, alt = true, ctrl = true, never = true }

local OPTIONS_TABS = { stats = true, range = true, recipes = true, mail = true }
local DEFAULT_TAB = "stats"

-- Set in ADDON_LOADED.
local db, charDb

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

local function IsFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function SortedKeys(tbl)
	local keys = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		local la, lb = a:lower(), b:lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return keys
end

-- Formats a number compactly: at most `maxDecimals` decimals, trailing zeros dropped.
function ns.FormatNumber(value, maxDecimals)
	if not IsFiniteNumber(value) then
		return "0"
	end
	local text = string.format("%." .. (maxDecimals or 3) .. "f", value)
	if text:find(".", 1, true) then
		text = text:gsub("0+$", "")
		text = text:gsub("%.$", "")
	end
	if text == "-0" or text == "" then
		text = "0"
	end
	return text
end

-- The panel templates draw a slightly see-through background; put a solid layer under it so the addon's windows
-- are opaque. Only touches the addon's own frames.
function ns.MakeOpaque(frame)
	if not frame or frame.jimmysOpaque then
		return
	end
	local host = frame.Bg or frame
	local solid = host:CreateTexture(nil, "BACKGROUND", nil, -8)
	solid:SetAllPoints(host)
	solid:SetColorTexture(0.06, 0.06, 0.07, 1)
	frame.jimmysOpaque = solid
end

function ns.Print(msg)
	local text = CHAT_PREFIX .. tostring(msg)
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage(text)
	else
		print(text)
	end
end

function ns.NotifyConfigChanged()
	if ns.RefreshOptions then
		ns.RefreshOptions()
	end
end

--------------------------------------------------------------------------------
-- SavedVariables
--------------------------------------------------------------------------------

local function GetDefaultWeights()
	local weights = {}
	for _, stat in ipairs(ns.STATS) do
		if stat.default ~= 0 then
			weights[stat.key] = stat.default
		end
	end
	return weights
end

-- dbVersion 2 merged the same-unit "(Equip)" pseudo-stats into their main stats.
local MERGED_STATS = {
	JSW_EQUIP_AP = "ITEM_MOD_ATTACK_POWER_SHORT",
	JSW_EQUIP_RAP = "ITEM_MOD_RANGED_ATTACK_POWER_SHORT",
	JSW_EQUIP_SPELL_POWER = "ITEM_MOD_SPELL_POWER_SHORT",
	JSW_EQUIP_HEALING = "ITEM_MOD_SPELL_HEALING_DONE_SHORT",
	JSW_EQUIP_MP5 = "ITEM_MOD_MANA_REGENERATION_SHORT",
	JSW_EQUIP_HP5 = "ITEM_MOD_HEALTH_REGEN_SHORT",
	JSW_EQUIP_BLOCK_VALUE = "ITEM_MOD_BLOCK_VALUE_SHORT",
	JSW_EQUIP_SPELL_PEN = "ITEM_MOD_SPELL_PENETRATION_SHORT",
}

local function CopyWeights(source)
	local weights = {}
	for key, value in pairs(source) do
		weights[key] = value
	end
	return weights
end

-- Fills missing fields and drops malformed ones so the rest of the addon can trust the data.
local function InitSavedVariables()
	if type(JimmysStatWeightsDB) ~= "table" then
		JimmysStatWeightsDB = {}
	end
	if type(JimmysStatWeightsCharDB) ~= "table" then
		JimmysStatWeightsCharDB = {}
	end
	db = JimmysStatWeightsDB
	charDb = JimmysStatWeightsCharDB

	local storedVersion = db.dbVersion
	-- Never lower the version, so data from a newer build is not migrated again after a downgrade.
	if type(storedVersion) ~= "number" or storedVersion < DB_VERSION then
		db.dbVersion = DB_VERSION
	end

	-- Profiles
	if type(db.profiles) ~= "table" then
		db.profiles = {}
	end
	for name, profile in pairs(db.profiles) do
		if type(name) ~= "string" or type(profile) ~= "table" then
			db.profiles[name] = nil
		else
			if type(profile.weights) ~= "table" then
				profile.weights = {}
			end
			for key, value in pairs(profile.weights) do
				if type(key) ~= "string" or not IsFiniteNumber(value) or value == 0 then
					profile.weights[key] = nil
				end
			end
		end
	end
	if next(db.profiles) == nil then
		db.profiles[DEFAULT_PROFILE] = { weights = GetDefaultWeights() }
	end

	-- Weights set on a merged "(Equip)" stat move to its main stat; an explicit main weight wins.
	if type(storedVersion) ~= "number" or storedVersion < 2 then
		for _, profile in pairs(db.profiles) do
			local weights = profile.weights
			for oldKey, newKey in pairs(MERGED_STATS) do
				if weights[oldKey] ~= nil then
					if weights[newKey] == nil then
						weights[newKey] = weights[oldKey]
					end
					weights[oldKey] = nil
				end
			end
		end
	end

	-- Discovered stat keys
	if type(db.discovered) ~= "table" then
		db.discovered = {}
	end
	for key, value in pairs(db.discovered) do
		if type(key) ~= "string" or value ~= true then
			db.discovered[key] = nil
		end
	end

	-- Settings
	if type(db.settings) ~= "table" then
		db.settings = {}
	end
	for name, default in pairs(DEFAULT_SETTINGS) do
		if type(db.settings[name]) ~= type(default) then
			db.settings[name] = default
		end
	end
	if not IsFiniteNumber(db.settings.decimals) then
		db.settings.decimals = DEFAULT_SETTINGS.decimals
	end
	db.settings.decimals = math.max(0, math.min(3, math.floor(db.settings.decimals)))
	if not BREAKDOWN_MODES[db.settings.breakdown] then
		db.settings.breakdown = DEFAULT_SETTINGS.breakdown
	end

	-- Stat weight scores on tooltips: on/off
	if type(db.stats) ~= "table" then
		db.stats = {}
	end
	for name, default in pairs(DEFAULT_STATS) do
		if type(db.stats[name]) ~= type(default) then
			db.stats[name] = default
		end
	end

	-- Last tab of the options window
	if not OPTIONS_TABS[db.optionsTab] then
		db.optionsTab = DEFAULT_TAB
	end

	-- Active profile of this character
	if type(charDb.profile) ~= "string" or not db.profiles[charDb.profile] then
		if db.profiles[DEFAULT_PROFILE] then
			charDb.profile = DEFAULT_PROFILE
		else
			charDb.profile = SortedKeys(db.profiles)[1]
		end
	end
end

--------------------------------------------------------------------------------
-- Profiles
--------------------------------------------------------------------------------

function ns.GetActiveProfileName()
	return charDb.profile
end

function ns.GetActiveProfile()
	return db.profiles[charDb.profile]
end

function ns.GetProfileNames()
	return SortedKeys(db.profiles)
end

-- Case-insensitive lookup of an existing profile name; returns the stored spelling.
local function FindProfileName(name)
	if type(name) ~= "string" then
		return nil
	end
	if db.profiles[name] then
		return name
	end
	local lowered = name:lower()
	for existing in pairs(db.profiles) do
		if existing:lower() == lowered then
			return existing
		end
	end
end

function ns.SetActiveProfile(name)
	if type(name) ~= "string" or not db.profiles[name] then
		return false, "Profile not found."
	end
	charDb.profile = name
	return true
end

function ns.CreateProfile(name, copyFromName)
	if type(name) ~= "string" then
		return false, "Invalid profile name."
	end
	name = Trim(name)
	-- Count UTF-8 characters, not bytes, to match the edit box's letter limit.
	local length = select(2, name:gsub("[^\128-\191]", ""))
	if length == 0 or length > MAX_PROFILE_NAME then
		return false, "Profile names must be 1-" .. MAX_PROFILE_NAME .. " characters long."
	end
	if FindProfileName(name) then
		return false, "A profile named \"" .. name .. "\" already exists."
	end

	local weights
	if copyFromName == nil then
		weights = GetDefaultWeights()
	else
		local source = db.profiles[copyFromName]
		if not source then
			return false, "Profile to copy not found."
		end
		weights = CopyWeights(source.weights)
	end
	db.profiles[name] = { weights = weights }
	return true
end

function ns.DeleteProfile(name)
	if type(name) ~= "string" or not db.profiles[name] then
		return false, "Profile not found."
	end
	if next(db.profiles, next(db.profiles)) == nil then
		return false, "You cannot delete the last remaining profile."
	end

	db.profiles[name] = nil
	-- Other characters fall back to a valid profile when they next load.
	if charDb.profile == name then
		charDb.profile = SortedKeys(db.profiles)[1]
	end
	return true
end

--------------------------------------------------------------------------------
-- Weights
--------------------------------------------------------------------------------

function ns.GetWeight(key)
	return ns.GetActiveProfile().weights[key] or 0
end

function ns.SetWeight(key, value)
	if type(key) ~= "string" or not IsFiniteNumber(value) then
		return
	end
	local weights = ns.GetActiveProfile().weights
	if value == 0 then
		weights[key] = nil
	else
		weights[key] = value
	end
end

function ns.ResetActiveProfile()
	ns.GetActiveProfile().weights = GetDefaultWeights()
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function ns.GetSetting(name)
	return db.settings[name]
end

function ns.SetSetting(name, value)
	local default = DEFAULT_SETTINGS[name]
	if default == nil or type(value) ~= type(default) then
		return
	end
	if name == "decimals" then
		if not IsFiniteNumber(value) then
			return
		end
		value = math.max(0, math.min(3, math.floor(value)))
	elseif name == "breakdown" and not BREAKDOWN_MODES[value] then
		return
	end
	db.settings[name] = value
end

function ns.ResetSettings()
	for name, default in pairs(DEFAULT_SETTINGS) do
		db.settings[name] = default
	end
end

--------------------------------------------------------------------------------
-- Stat weight scores on/off
--------------------------------------------------------------------------------

-- Are the score lines added to item tooltips? The profiles, weights and /ju dump work either way.
function ns.IsStatsEnabled()
	return db ~= nil and db.stats.enabled == true
end

function ns.SetStatsEnabled(enabled)
	if not db or type(enabled) ~= "boolean" then
		return false
	end
	db.stats.enabled = enabled
	return true
end

--------------------------------------------------------------------------------
-- Options window tab
--------------------------------------------------------------------------------

function ns.GetOptionsTab()
	return db.optionsTab
end

function ns.SetOptionsTab(tab)
	if OPTIONS_TABS[tab] then
		db.optionsTab = tab
	end
end

--------------------------------------------------------------------------------
-- Discovered stats
--------------------------------------------------------------------------------

-- Remembers an API stat key that is not in ns.STATS so it shows up in the options window.
function ns.RecordDiscoveredKey(key)
	if type(key) ~= "string" or #key > 64 or not key:find("^[%w_]+$") then
		return
	end
	if ns.STATS_BY_KEY[key] or db.discovered[key] then
		return
	end
	db.discovered[key] = true
	ns.NotifyConfigChanged()
end

function ns.GetDiscoveredKeys()
	local keys = {}
	for key in pairs(db.discovered) do
		-- Keys recorded before they were mapped to another name are skipped too.
		if not ns.STATS_BY_KEY[key] and ns.NormalizeStatKey(key) == key then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys, function(a, b)
		local la, lb = ns.GetStatLabel(a):lower(), ns.GetStatLabel(b):lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return keys
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local HELP_LINES = {
	"/ju - open or close the options window (aliases: /jimmysutils, /jsw, /statweights)",
	"/ju status - show which features (stat weight scores, range check, recipe lookup, mail) are on or off",
	"/ju stats - show whether the stat weight scores on item tooltips are on; /ju stats on | off - turn them on or off",
	"/ju list - show the non-zero weights of the active profile",
	"/ju set <stat> <number> - set a weight (stat key, label or unique label prefix)",
	"/ju profile - show profiles; /ju profile <name> - switch to a profile",
	"/ju profile new <name> - create a profile with default weights and switch to it",
	"/ju profile copy <name> - copy the active profile and switch to the copy",
	"/ju profile delete <name> - delete a profile",
	"/ju reset - reset the active profile's weights to the defaults",
	"/ju dump <item link> - show what the API reports for an item and how it is scored",
	"/ju range - turn the range check indicator on or off",
	"/ju range <spell name or id> - choose the spell the indicator checks",
	"/ju range clear - forget the chosen spell",
	"/ju range unlock | lock - allow dragging the indicator / fix it in place",
	"/ju range nameplate | screen - show the indicator on the target's nameplate / at a fixed spot on the screen",
	"/ju range size <12-128> - icon size in pixels",
	"/ju recipes on | off - turn the recipe lookup (learning recipes from profession windows, the lookup and its key binding) on or off",
	"/ju recipes <item link | item ID | item name> - list the saved recipes that use an item as an ingredient",
	"/ju recipes - the same for the item you are pointing at (also: the key binding under Options > Keybindings > AddOns)",
	"/ju recipes status - show what is saved and what the client gives the addon (recipes are learned whenever you open a profession window)",
	"/ju recipes forget - delete the saved recipes (asks you to repeat it with confirm)",
	"/ju recipes forget <character> - remove one character (Name or Name-Realm) from the saved recipes, with its saved bags, bank and mail (asks for confirm too)",
	"/ju mail - show whether the mail features (recent recipients and mail materials) are on; /ju mail on | off - turn them on or off",
	"/ju mail clear - forget the recent mail recipients of this realm",
	"/ju minimap - show or hide the minimap button; /ju minimap reset - move it back to its default place",
	"/ju materials - open or close the window listing the recipes your mail has materials for, for this character and (with the check box in the window) your other characters on this realm; bags, bank and the mail of each character count (also works away from the mailbox; needs the mail features on)",
}

-- Every stat the user might want to address: the static list, then detected and stored keys.
local function GetKnownStatKeys()
	local keys, seen = {}, {}
	local function Add(key)
		if not seen[key] then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	for _, stat in ipairs(ns.STATS) do
		Add(stat.key)
	end
	for _, key in ipairs(ns.GetDiscoveredKeys()) do
		Add(key)
	end
	return keys
end

-- Matches user text against stat keys, then exact labels, then unique label prefixes.
-- Returns key on success, or nil and an error message.
function ns.FindStat(text)
	local query = Trim(text):lower()
	if query == "" then
		return nil, "No stat given."
	end

	local keys = GetKnownStatKeys()

	for _, key in ipairs(keys) do
		if key:lower() == query then
			return key
		end
	end
	-- Old "(Equip)" keys from before the merge, e.g. in macros.
	for oldKey, newKey in pairs(MERGED_STATS) do
		if oldKey:lower() == query then
			return newKey
		end
	end

	local exact, prefix = {}, {}
	for _, key in ipairs(keys) do
		local label = ns.GetStatLabel(key):lower()
		if label == query then
			exact[#exact + 1] = key
		elseif label:sub(1, #query) == query then
			prefix[#prefix + 1] = key
		end
	end

	local matches = #exact > 0 and exact or prefix
	if #matches == 1 then
		return matches[1]
	elseif #matches == 0 then
		return nil, "No stat matches \"" .. Trim(text) .. "\". Use /ju list or the options window to see stat names."
	end

	local labels = {}
	for _, key in ipairs(matches) do
		labels[#labels + 1] = ns.GetStatLabel(key)
	end
	return nil, "\"" .. Trim(text) .. "\" is ambiguous: " .. table.concat(labels, ", ") .. "."
end

local function PrintList()
	ns.Print("Weights of profile \"" .. ns.GetActiveProfileName() .. "\":")
	local weights = ns.GetActiveProfile().weights
	local shown = 0
	local function PrintWeight(key)
		local weight = weights[key]
		if weight and weight ~= 0 then
			print("  " .. ns.GetStatLabel(key) .. ": " .. ns.FormatNumber(weight, 4))
			shown = shown + 1
		end
	end

	local listed = {}
	for _, stat in ipairs(ns.STATS) do
		listed[stat.key] = true
		PrintWeight(stat.key)
	end
	-- Weights on stats that are not in the static list (detected stats).
	local extra = {}
	for key in pairs(weights) do
		if not listed[key] then
			extra[#extra + 1] = key
		end
	end
	table.sort(extra, function(a, b)
		return ns.GetStatLabel(a):lower() < ns.GetStatLabel(b):lower()
	end)
	for _, key in ipairs(extra) do
		PrintWeight(key)
	end

	if shown == 0 then
		print("  (all weights are 0)")
	end
end

local function PrintProfiles()
	ns.Print("Active profile: " .. ns.GetActiveProfileName())
	local names = ns.GetProfileNames()
	for _, name in ipairs(names) do
		print("  " .. (name == ns.GetActiveProfileName() and "> " or "  ") .. name)
	end
end

local function HandleSet(rest)
	local statText, numberText = rest:match("^(.-)%s+(%S+)$")
	local value = numberText and tonumber((numberText:gsub(",", ".")))
	if not statText or Trim(statText) == "" or not IsFiniteNumber(value) then
		ns.Print("Usage: /ju set <stat> <number>")
		return
	end

	local key, err = ns.FindStat(statText)
	if not key then
		ns.Print(err)
		return
	end

	ns.SetWeight(key, value)
	ns.Print(ns.GetStatLabel(key) .. " weight set to " .. ns.FormatNumber(value, 4) .. " (profile \"" .. ns.GetActiveProfileName() .. "\").")
	ns.NotifyConfigChanged()
end

local function HandleProfile(rest)
	if rest == "" then
		PrintProfiles()
		return
	end

	-- An existing profile name wins over sub-commands, so "New Tank" or
	-- "Delete Old" switch to those profiles instead of creating/deleting.
	local existing = FindProfileName(rest)
	if existing then
		ns.SetActiveProfile(existing)
		ns.Print("Switched to profile \"" .. existing .. "\".")
		ns.NotifyConfigChanged()
		return
	end

	local sub, arg = rest:match("^(%S+)%s*(.-)$")
	sub = sub:lower()

	if sub == "new" or sub == "copy" then
		if arg == "" then
			ns.Print("Usage: /ju profile " .. sub .. " <name>")
			return
		end
		local ok, err
		if sub == "new" then
			ok, err = ns.CreateProfile(arg)
		else
			ok, err = ns.CreateProfile(arg, ns.GetActiveProfileName())
		end
		if not ok then
			ns.Print(err)
			return
		end
		ns.SetActiveProfile(FindProfileName(arg))
		ns.Print("Created and switched to profile \"" .. ns.GetActiveProfileName() .. "\".")
	elseif sub == "delete" then
		local name = FindProfileName(arg)
		if not name then
			ns.Print(arg == "" and "Usage: /ju profile delete <name>" or "Profile not found.")
			return
		end
		local ok, err = ns.DeleteProfile(name)
		if not ok then
			ns.Print(err)
			return
		end
		ns.Print("Deleted profile \"" .. name .. "\". Active profile: \"" .. ns.GetActiveProfileName() .. "\".")
	else
		local name = FindProfileName(rest)
		if not name then
			ns.Print("Profile not found. Use /ju profile to list profiles.")
			return
		end
		ns.SetActiveProfile(name)
		ns.Print("Switched to profile \"" .. name .. "\".")
	end
	ns.NotifyConfigChanged()
end

local function OnOff(value)
	return value and "on" or "off"
end

local function HandleStats(rest)
	local lowered = Trim(rest):lower()
	if lowered == "on" or lowered == "off" then
		ns.SetStatsEnabled(lowered == "on")
		ns.Print("Stat weight scores on item tooltips " .. (lowered == "on" and "enabled." or "disabled."))
		ns.NotifyConfigChanged()
	elseif lowered == "" then
		ns.Print("Stat weight scores on item tooltips are " .. OnOff(ns.IsStatsEnabled()) .. ".")
		ns.Print("Usage: /ju stats on | off")
	else
		ns.Print("Usage: /ju stats on | off")
	end
end

-- One line per feature: on or off.
local function PrintStatus()
	ns.Print("Features:")
	print("  Stat weights (tooltip scores): " .. OnOff(ns.IsStatsEnabled()))
	print("  Range check: " .. (ns.GetRangeSetting and OnOff(ns.GetRangeSetting("enabled")) or "not available"))
	print("  Recipe lookup: " .. (ns.IsRecipeLookupEnabled and OnOff(ns.IsRecipeLookupEnabled()) or "not available"))
	print("  Mail (recent recipients and materials): " .. (ns.IsMailEnabled and OnOff(ns.IsMailEnabled()) or "not available"))
end

-- Prints what the API reports for an item, which "Equip:" lines were parsed, and the score.
local function HandleDump(rest)
	local link = rest:match("(|c%x+|Hitem:.-|h.-|h|r)") or rest:match("(|Hitem:.-|h.-|h)") or rest:match("(item:%d[%d:%-]*)")
	if not link then
		local itemID = tonumber(rest)
		if itemID then
			link = "item:" .. itemID
		end
	end
	if not link then
		ns.Print("Usage: /ju dump <shift-clicked item link>")
		return
	end

	ns.Print("Dump for " .. link .. " (equippable: " .. tostring(C_Item.IsEquippableItem(link)) .. ")")

	local apiStats = C_Item.GetItemStats(link)
	print("  C_Item.GetItemStats:")
	if type(apiStats) ~= "table" or IsSecret(apiStats) or next(apiStats) == nil then
		print("    (nothing)")
	else
		local keys = {}
		for key in pairs(apiStats) do
			if type(key) == "string" and not IsSecret(key) then
				keys[#keys + 1] = key
			end
		end
		table.sort(keys)
		for _, key in ipairs(keys) do
			local value = apiStats[key]
			local normalized = ns.NormalizeStatKey(key)
			local known = normalized ~= key and " -> " .. normalized
				or ns.STATS_BY_KEY[key] and "" or " [not in stat list]"
			print("    " .. key .. " = " .. (IsSecret(value) and "<secret>" or tostring(value)) .. " (" .. ns.GetStatLabel(key) .. ")" .. known)
		end
	end

	local lines
	local data = C_TooltipInfo and C_TooltipInfo.GetHyperlink and C_TooltipInfo.GetHyperlink(link)
	if type(data) == "table" and not IsSecret(data) then
		lines = data.lines
	end
	local stats = ns.CollectItemStats(link, lines)

	print("  Parsed \"Equip:\" stats:")
	local parsed = type(lines) == "table" and ns.ParseEquipLines(lines)
	if parsed and next(parsed) then
		for _, stat in ipairs(ns.STATS) do
			if parsed[stat.key] then
				-- Same-unit effects are scored under the main stat, so mark them as read from text.
				local suffix = stat.group == "parsed" and "" or " (Equip)"
				local entry = stats and stats[stat.key]
				local note = ""
				if not (entry and entry.source == "text") then
					note = (entry and entry.source == "api") and " (ignored: the game reports this stat)" or " (not used)"
				end
				print("    " .. stat.label .. suffix .. " = " .. ns.FormatNumber(parsed[stat.key], 4) .. note)
			end
		end
	else
		print("    (nothing" .. (lines and "" or "; tooltip lines unavailable") .. ")")
	end

	if not stats then
		print("  No stats could be read from this item.")
		return
	end
	local total, breakdown = ns.ComputeScore(stats)
	print("  Score with profile \"" .. ns.GetActiveProfileName() .. "\": " .. ns.FormatNumber(total, 4))
	for _, entry in ipairs(breakdown) do
		print("    " .. entry.label .. ": " .. ns.FormatNumber(entry.value, 3) .. " x " .. ns.FormatNumber(entry.weight, 3)
			.. " = " .. ns.FormatNumber(entry.contribution, 3) .. " (" .. entry.source .. ")")
	end
end

SLASH_JIMMYSUTILS1 = "/ju"
SLASH_JIMMYSUTILS2 = "/jimmysutils"
SLASH_JIMMYSUTILS3 = "/jsw"
SLASH_JIMMYSUTILS4 = "/statweights"
SlashCmdList["JIMMYSUTILS"] = function(msg)
	local command, rest = Trim(msg or ""):match("^(%S*)%s*(.-)$")
	command = command:lower()

	if command == "" or command == "config" or command == "options" then
		if ns.ToggleOptions then
			ns.ToggleOptions()
		else
			ns.Print("The options window is not available.")
		end
	elseif command == "help" then
		for _, line in ipairs(HELP_LINES) do
			print("  " .. line)
		end
	elseif command == "status" then
		PrintStatus()
	elseif command == "stats" then
		HandleStats(rest)
	elseif command == "list" then
		PrintList()
	elseif command == "set" then
		HandleSet(rest)
	elseif command == "profile" then
		HandleProfile(rest)
	elseif command == "reset" then
		ns.ResetActiveProfile()
		ns.Print("Weights of profile \"" .. ns.GetActiveProfileName() .. "\" reset to the defaults.")
		ns.NotifyConfigChanged()
	elseif command == "dump" then
		HandleDump(rest)
	elseif command == "range" then
		if ns.HandleRangeCommand then
			ns.HandleRangeCommand(rest)
		else
			ns.Print("The range check is not available.")
		end
	elseif command == "recipes" then
		if ns.HandleRecipesCommand then
			ns.HandleRecipesCommand(rest)
		else
			ns.Print("The recipe lookup is not available.")
		end
	elseif command == "mail" then
		if ns.HandleMailCommand then
			ns.HandleMailCommand(rest)
		else
			ns.Print("The recent mail recipients are not available.")
		end
	elseif command == "minimap" then
		if ns.HandleMinimapCommand then
			ns.HandleMinimapCommand(rest)
		else
			ns.Print("The minimap button is not available.")
		end
	elseif command == "materials" then
		if ns.HandleMaterialsCommand then
			ns.HandleMaterialsCommand(rest)
		else
			ns.Print("The mail materials are not available.")
		end
	else
		ns.Print("Unknown command \"" .. command .. "\". Type /ju help for a list of commands.")
	end
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, loadedName)
	if loadedName ~= addonName then
		return
	end
	self:UnregisterEvent("ADDON_LOADED")

	InitSavedVariables()
	ns.InitTooltip()
	if ns.InitRangeCheck then
		ns.InitRangeCheck(db, charDb)
	end
	if ns.InitRecipes then
		ns.InitRecipes(db)
	end
	if ns.InitInventory then
		ns.InitInventory(db, charDb)
	end
	if ns.InitMail then
		ns.InitMail(db)
	end
	if ns.InitMailMaterials then
		ns.InitMailMaterials(db, charDb)
	end
	if ns.InitMinimap then
		ns.InitMinimap(db)
	end
	if ns.InitOptions then
		ns.InitOptions()
	end
end)

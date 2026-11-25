local addonName, ns = ...

--[[
	Data layer (SavedVariables, profiles, weights, settings) and slash commands.

	The SavedVariables keep their original variable names (the addon used to be "Jimmy's Stat Weights"). The
	client names the saved file after the addon folder, so the data now lives in WTF\...\SavedVariables\JimmysUtils.lua.
	To keep data from the old addon, rename its JimmysStatWeights.lua files (account-wide and per character) to
	JimmysUtils.lua and remove the old JimmysStatWeights folder.

	JimmysStatWeightsDB = {
		dbVersion = 2,
		profiles = { ["Default"] = { weights = { [statKey] = number }, hiddenFor = { ["Name-Realm"] = true } } }, -- only non-zero weights stored; hiddenFor: the characters that leave the scale out of their item tooltips (absent: shown to everyone)
		activeProfile = { ["Name-Realm"] = scaleName }, -- the scale each character has active (a character without an entry, or with one for a scale that is gone, uses Default)
		discovered = { [statKey] = true },
		settings = { decimals = 1, hideZero = true, breakdown = "alt", parseEquipText = true },
		optionsTab = "stats", -- last tab of the options window ("stats" | "range" | "recipes" | "mail" | "profiles")
		optionsSize = { width, height }, -- size of the (resizable) options window, only saved when it differs from the default; cleaned at load
		profileRenames = { [oldName] = newName }, -- scales that were renamed; only read to move the choices a character still keeps in its own saved variables (see below)
		stats = { enabled }, -- show the stat weight score on item tooltips (the profile editing always works)
		range = { enabled, locked, size, anchor, point, x, y }, -- validated in RangeCheck.lua
		recipeLookup = { enabled, hiddenProfessions = { [lowercase profession] = true } }, -- scan professions and answer the recipe lookup; the professions the recipes window leaves out; validated in Recipes.lua
		recipes, recipeKnownBy, itemNames, recipeSkill, -- saved recipes and the profession skill per character, validated in Recipes.lua
		mail = { enabled }, -- master switch of the recent recipients and the mail materials, validated in Mail.lua
		mailRecipients = { [realmKey] = { names } }, -- recent mail recipients, validated in Mail.lua
		mailMaterials = { position, showOthers, hiddenProfessions = { [lowercase profession] = true }, sortProfit }, -- the "materials in your mail" window, the professions it leaves out and its profit sort, validated in MailMaterials.lua
		profit = { enabled, listSort }, -- crafting profit from Auctionator prices and the sort of the profession window's recipe list, validated in Profit.lua
		auctionScores = { enabled, sortProfile }, -- stat weight score columns in the auction house's Browse tab and the profile it is sorted by, validated in AuctionScores.lua
		auctionHouseSize = { enabled, width, height }, -- the resizable auction house window (the grip in its corner) and the size it was left at, validated in AuctionHouseResize.lua
		professionWindow = { detached, position = { point, relPoint, x, y } }, -- keep the profession window out of Blizzard's panel layout (movable), validated in ProfessionWindow.lua
		inventory = { ["Name-Realm"] = { bags, bagsTime, bank, bankTime, mail } }, -- item snapshots (and the last scan of the mailbox) per character, validated in Inventory.lua
		accountBank = { items, time }, -- the account bank, validated in Inventory.lua
		minimap = { hide, angle }, -- the minimap button, validated in Minimap.lua
		settingsProfiles = { ["Name"] = { settings = {...}, stats = {...}, range = {...}, ... } }, -- the settings profiles: named snapshots of the settings of the whole addon (not the scales, see below), validated in SettingsProfiles.lua
		activeSettingsProfile = { ["Name-Realm"] = profileName }, -- the settings profile each character uses (a character without an entry uses Default)
	}
	JimmysStatWeightsCharDB = { rangeSpell = spellID }
	-- The choices per character live in the account data (like Pawn's PerCharacterOptions), keyed by ns.GetCharacterKey(): the active scale in
	-- db.activeProfile and the hidden scales in each scale's hiddenFor. A rename moves the scale's table and rewrites db.activeProfile, so every
	-- character follows it at once. Older versions kept `profile` and `hiddenProfiles` in the character's own saved variables; the first time
	-- the character's key is known they are moved into the account data (through db.profileRenames, which is only kept for that: renames
	-- done since the character last loaded) and removed. A character whose key is already in the account data keeps that data. While the realm
	-- is not known yet (early in the login) the legacy fields are used as they are.
	-- (older versions also kept mailItems here: the last scan of the mailbox, now db.inventory[character].mail)
	-- Not to be confused with the settings profiles of SettingsProfiles.lua (db.settingsProfiles, db.activeSettingsProfile): those hold the
	-- settings of the whole addon, the "profiles" of the options window's Profiles tab and of /ju profile. The stat weight scales above
	-- are called "scales" wherever the player sees them (/ju scale) and stay "profiles" in the code (db.profiles, ns.*Profile*).
]]

local DB_VERSION = 2
local DEFAULT_PROFILE = "Default"
local MAX_PROFILE_NAME = 32
ns.MAX_PROFILE_NAME = MAX_PROFILE_NAME -- the longest scale name (UTF-8 characters); PawnScales.lua shortens imported names to it
local OPTIONS_WIDTH, OPTIONS_HEIGHT = 400, 510
ns.OPTIONS_WIDTH, ns.OPTIONS_HEIGHT = OPTIONS_WIDTH, OPTIONS_HEIGHT -- the default (and smallest) size of the options window (Options.lua)
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
ns.BREAKDOWN_MODES = BREAKDOWN_MODES -- the settings profiles (SettingsProfiles.lua) clean the setting with it

local OPTIONS_TABS = { stats = true, range = true, recipes = true, mail = true, profiles = true }
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

-- The key a profession goes by in the sets of hidden professions: its name trimmed and lowercased, so spellings of one
-- profession meet. nil for anything that cannot be a key (not text, empty, longer than 64 bytes). Every save, comparison and
-- validation of those sets uses it.
local MAX_PROFESSION_KEY = 64
function ns.ProfessionKey(name)
	if type(name) ~= "string" then
		return nil
	end
	local key = Trim(name):lower()
	if key == "" or #key > MAX_PROFESSION_KEY then
		return nil
	end
	return key
end

-- A saved set of hidden professions, { [lowercase profession] = true }, cleaned for use: only keys that are professions
-- (ns.ProfessionKey) with the value true stay, normalized and merged when two spellings meet. Always returns a new table, never nil.
function ns.CleanProfessionSet(set)
	local clean = {}
	if type(set) == "table" then
		for key, value in pairs(set) do
			key = value == true and ns.ProfessionKey(key) or nil
			if key then
				clean[key] = true
			end
		end
	end
	return clean
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

-- The sizes a resizable window of this addon may have: at least its default size, at most twice that and what the screen holds.
-- Returns minWidth, minHeight, maxWidth, maxHeight.
function ns.GetWindowBounds(defaultWidth, defaultHeight)
	local maxWidth, maxHeight = defaultWidth * 2, defaultHeight * 2
	if UIParent and UIParent.GetWidth then
		local ok, width, height = pcall(function() return UIParent:GetWidth(), UIParent:GetHeight() end)
		if ok and not IsSecret(width) and IsFiniteNumber(width) and width > 0 then
			maxWidth = math.max(defaultWidth, math.min(maxWidth, math.floor(width - 20)))
		end
		if ok and not IsSecret(height) and IsFiniteNumber(height) and height > 0 then
			maxHeight = math.max(defaultHeight, math.min(maxHeight, math.floor(height - 20)))
		end
	end
	return defaultWidth, defaultHeight, maxWidth, maxHeight
end

-- A saved window size { width, height } as it should be kept: whole numbers inside ns.GetWindowBounds, or nil when it is not a size
-- (or is the default one).
function ns.CleanWindowSize(size, defaultWidth, defaultHeight)
	if type(size) ~= "table" or IsSecret(size) or not IsFiniteNumber(size[1]) or not IsFiniteNumber(size[2]) then
		return nil
	end
	local minWidth, minHeight, maxWidth, maxHeight = ns.GetWindowBounds(defaultWidth, defaultHeight)
	local width = math.max(minWidth, math.min(maxWidth, math.floor(size[1] + 0.5)))
	local height = math.max(minHeight, math.min(maxHeight, math.floor(size[2] + 0.5)))
	if width == defaultWidth and height == defaultHeight then
		return nil
	end
	return { width, height }
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

-- A setting that a settings profile holds changed (set by the player or by a slash command): the active profile of the character follows.
-- Called by every setter of those settings; a no-op where SettingsProfiles.lua is not loaded.
function ns.SettingsChanged()
	if ns.SyncSettingsProfile then
		ns.SyncSettingsProfile()
	end
end

-- The profiles, weights or display settings changed: the score columns of the auction house follow.
local function ScoresChanged()
	if ns.RefreshAuctionScores then
		ns.RefreshAuctionScores()
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

-- The name a scale goes by now: `name` itself when a scale of that name exists, else what db.profileRenames says it became (followed along a
-- chain of renames; a loop in the data ends the walk). Returns the last name reached, which may still not exist.
local function ResolveRenamedProfile(profiles, renames, name)
	local seen = {}
	while type(name) == "string" and not profiles[name] and not seen[name] do
		seen[name] = true
		local nextName = renames[name]
		if type(nextName) ~= "string" then
			break
		end
		name = nextName
	end
	return name
end

-- The saved map of renamed scales, { [oldName] = newName }, cleaned for use: text names only, an old name that is not a scale any more,
-- and every entry pointing straight at the scale it ended up as (chains followed). Entries that lead nowhere (a deleted scale, a loop)
-- are dropped. Always returns a new table, never nil.
local function CleanProfileRenames(profiles, renames)
	local clean = {}
	if type(renames) ~= "table" then
		return clean
	end
	local MAX_BYTES = MAX_PROFILE_NAME * 4 -- UTF-8 characters take up to four bytes
	for oldName, newName in pairs(renames) do
		if type(oldName) == "string" and type(newName) == "string" and oldName ~= "" and #oldName <= MAX_BYTES
			and #newName <= MAX_BYTES and not profiles[oldName] then
			local target = ResolveRenamedProfile(profiles, renames, newName)
			if profiles[target] then
				clean[oldName] = target
			end
		end
	end
	return clean
end

-- A saved set of characters, { ["Name-Realm"] = true }, cleaned for use: text keys with the value true only. Returns a new table, or nil
-- when nothing is left (the scales that nobody hides do not carry an empty table).
local function CleanCharacterSet(set)
	if type(set) ~= "table" then
		return nil
	end
	local clean
	for key, value in pairs(set) do
		if type(key) == "string" and key ~= "" and value == true then
			clean = clean or {}
			clean[key] = true
		end
	end
	return clean
end

-- The scale this character had before the choices moved into the account data: the stored name, followed through db.profileRenames; nil
-- when it is not a scale.
local function LegacyActiveName()
	if type(charDb.profile) ~= "string" then
		return nil
	end
	local name = ResolveRenamedProfile(db.profiles, db.profileRenames, charDb.profile)
	return db.profiles[name] and name or nil
end

-- Brings the legacy fields of this character (charDb.profile, charDb.hiddenProfiles) to a clean form: names resolved through the renames,
-- only scales that exist, only true values. A field that is not usable becomes nil.
local function CleanLegacyChoices()
	charDb.profile = LegacyActiveName()
	if type(charDb.hiddenProfiles) == "table" then
		local hidden = {}
		for name, value in pairs(charDb.hiddenProfiles) do
			if type(name) == "string" and value == true then
				name = ResolveRenamedProfile(db.profiles, db.profileRenames, name)
				if db.profiles[name] then
					hidden[name] = true
				end
			end
		end
		charDb.hiddenProfiles = hidden
	else
		charDb.hiddenProfiles = nil
	end
end

-- The key of this character ("Name-Realm"), once the realm is known; MigrateCharacter has moved its legacy choices by then.
local charKey

-- Moves the legacy choices of the character `key` into the account data and removes them from charDb. A character that already has account
-- data (an active scale, or a scale hidden for it) keeps it: the legacy values are stale then (saved by an older build) and only dropped.
local function MigrateCharacter(key)
	CleanLegacyChoices()
	local hasAccountData = db.activeProfile[key] ~= nil
	if not hasAccountData then
		for _, profile in pairs(db.profiles) do
			if profile.hiddenFor and profile.hiddenFor[key] then
				hasAccountData = true
				break
			end
		end
	end
	if not hasAccountData then
		db.activeProfile[key] = charDb.profile
		for name in pairs(charDb.hiddenProfiles or {}) do
			local profile = db.profiles[name]
			profile.hiddenFor = profile.hiddenFor or {}
			profile.hiddenFor[key] = true
		end
	end
	charDb.profile = nil
	charDb.hiddenProfiles = nil
end

-- The key of the character that is logged in, or nil while the realm is not known yet (ns.GetCharacterKey, Recipes.lua, resolves it when
-- called). The first time it is known the legacy choices of the character are moved into the account data.
local function CurrentKey()
	if not charKey and db and ns.GetCharacterKey then
		local key = ns.GetCharacterKey()
		if type(key) == "string" and key ~= "" then
			charKey = key
			MigrateCharacter(key)
		end
	end
	return charKey
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
	charKey = nil

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

	-- Size of the options window (nil: the default size)
	db.optionsSize = ns.CleanWindowSize(db.optionsSize, OPTIONS_WIDTH, OPTIONS_HEIGHT)

	-- Scales that were renamed (only needed by characters that still have legacy choices in their own saved variables)
	db.profileRenames = CleanProfileRenames(db.profiles, db.profileRenames)

	-- The characters that hide each scale
	for _, profile in pairs(db.profiles) do
		profile.hiddenFor = CleanCharacterSet(profile.hiddenFor)
	end

	-- The active scale of each character: text keys, scales that exist
	local active = {}
	if type(db.activeProfile) == "table" then
		for key, name in pairs(db.activeProfile) do
			if type(key) == "string" and key ~= "" and type(name) == "string" and db.profiles[name] then
				active[key] = name
			end
		end
	end
	db.activeProfile = active

	-- This character may have been away while one of its scales was renamed: the legacy choices follow the renames. With the realm
	-- known they move into the account data right away; else that happens the first time it is known (CurrentKey).
	CleanLegacyChoices()
	CurrentKey()
end

--------------------------------------------------------------------------------
-- Profiles
--------------------------------------------------------------------------------

-- The scale a character without a (usable) choice has: Default, else the first one by name.
local function FallbackProfileName()
	if db.profiles[DEFAULT_PROFILE] then
		return DEFAULT_PROFILE
	end
	return SortedKeys(db.profiles)[1]
end

function ns.GetActiveProfileName()
	local key = CurrentKey()
	local name
	if key then
		name = db.activeProfile[key]
	else
		name = charDb.profile
	end
	if type(name) == "string" and db.profiles[name] then
		return name
	end
	return FallbackProfileName()
end

function ns.GetActiveProfile()
	return db.profiles[ns.GetActiveProfileName()]
end

function ns.GetProfileNames()
	return SortedKeys(db.profiles)
end

-- The weights table of a profile (nil when it does not exist).
function ns.GetProfileWeights(name)
	local profile = type(name) == "string" and db.profiles[name]
	return profile and profile.weights or nil
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

ns.FindProfileName = FindProfileName

function ns.SetActiveProfile(name)
	if type(name) ~= "string" or not db.profiles[name] then
		return false, "Scale not found."
	end
	local key = CurrentKey()
	if key then
		db.activeProfile[key] = name
	else
		charDb.profile = name -- the realm is not known yet: kept like older versions did, moved when it is
	end
	return true
end

-- Does this character leave the (existing) profile out of its item tooltips?
local function IsHiddenHere(name)
	local key = CurrentKey()
	if key then
		local hiddenFor = db.profiles[name].hiddenFor
		return hiddenFor ~= nil and hiddenFor[key] == true
	end
	return type(charDb.hiddenProfiles) == "table" and charDb.hiddenProfiles[name] == true
end

-- Is the profile listed in item tooltips (by this character)? Unknown profiles are not.
function ns.IsProfileShown(name)
	return type(name) == "string" and db.profiles[name] ~= nil and not IsHiddenHere(name)
end

-- Hiding a profile only leaves it out of the tooltips; its weights are kept.
function ns.SetProfileShown(name, shown)
	local existing = FindProfileName(name)
	if not existing then
		return false, "Scale not found."
	end
	local key = CurrentKey()
	if key then
		local profile = db.profiles[existing]
		if shown then
			if profile.hiddenFor then
				profile.hiddenFor[key] = nil
				if next(profile.hiddenFor) == nil then
					profile.hiddenFor = nil
				end
			end
		else
			profile.hiddenFor = profile.hiddenFor or {}
			profile.hiddenFor[key] = true
		end
	elseif shown then
		if charDb.hiddenProfiles then
			charDb.hiddenProfiles[existing] = nil
		end
	else
		charDb.hiddenProfiles = charDb.hiddenProfiles or {}
		charDb.hiddenProfiles[existing] = true
	end
	ScoresChanged()
	return true
end

-- The profiles listed in item tooltips, sorted like GetProfileNames.
function ns.GetShownProfileNames()
	local names = {}
	for _, name in ipairs(SortedKeys(db.profiles)) do
		if not IsHiddenHere(name) then
			names[#names + 1] = name
		end
	end
	return names
end

-- The scale name as it is kept (trimmed), or nil and an error message when it cannot be one.
local function ValidateProfileName(name)
	if type(name) ~= "string" then
		return nil, "Invalid scale name."
	end
	name = Trim(name)
	-- Count UTF-8 characters, not bytes, to match the edit box's letter limit.
	local length = select(2, name:gsub("[^\128-\191]", ""))
	if length == 0 or length > MAX_PROFILE_NAME then
		return nil, "Scale names must be 1-" .. MAX_PROFILE_NAME .. " characters long."
	end
	return name
end

function ns.CreateProfile(name, copyFromName)
	local err
	name, err = ValidateProfileName(name)
	if not name then
		return false, err
	end
	if FindProfileName(name) then
		return false, "A scale named \"" .. name .. "\" already exists."
	end

	local weights
	if copyFromName == nil then
		weights = GetDefaultWeights()
	else
		local source = db.profiles[copyFromName]
		if not source then
			return false, "Scale to copy not found."
		end
		weights = CopyWeights(source.weights)
	end
	db.profiles[name] = { weights = weights } -- no hiddenFor: shown to every character
	if type(charDb.hiddenProfiles) == "table" then
		charDb.hiddenProfiles[name] = nil
	end
	-- The name now means this scale, not the one that used to have it.
	db.profileRenames[name] = nil
	ScoresChanged()
	return true
end

-- Gives a scale another name: its table moves (so the weights and the characters that hide it go along), the active scale of every character
-- and the scale the auction house is sorted by follow. The name is checked like a new one; it may only match the scale itself (a change of
-- case). `old` has to be the stored spelling. Returns true, or false and an error message.
function ns.RenameProfile(old, new)
	if type(old) ~= "string" or not db.profiles[old] then
		return false, "Scale not found."
	end
	local name, err = ValidateProfileName(new)
	if not name then
		return false, err
	end
	if name == old then
		return false, "The scale is already named \"" .. old .. "\"."
	end
	local lowered = name:lower()
	for existing in pairs(db.profiles) do
		if existing ~= old and existing:lower() == lowered then
			return false, "A scale named \"" .. existing .. "\" already exists."
		end
	end

	db.profiles[name] = db.profiles[old]
	db.profiles[old] = nil
	for key, active in pairs(db.activeProfile) do
		if active == old then
			db.activeProfile[key] = name
		end
	end
	-- The legacy choices of this character, while its realm is not known (no key to move them to yet)
	if charDb.profile == old then
		charDb.profile = name
	end
	if type(charDb.hiddenProfiles) == "table" then
		charDb.hiddenProfiles[name] = charDb.hiddenProfiles[old]
		charDb.hiddenProfiles[old] = nil
	end
	local scores = db.auctionScores
	if type(scores) == "table" and scores.sortProfile == old then
		scores.sortProfile = name
	end

	-- Remember it for the characters that still keep legacy choices under the old name (not moved into the account data yet): the new name is
	-- a scale again (not a name that used to be), whatever pointed at the old name points at the new one, and the old name leads to it.
	local renames = db.profileRenames
	renames[name] = nil
	for from, to in pairs(renames) do
		if to == old then
			renames[from] = name
		end
	end
	renames[old] = name
	ScoresChanged()
	return true
end

function ns.DeleteProfile(name)
	if type(name) ~= "string" or not db.profiles[name] then
		return false, "Scale not found."
	end
	if next(db.profiles, next(db.profiles)) == nil then
		return false, "You cannot delete the last remaining scale."
	end

	db.profiles[name] = nil -- the characters that hide it go with it
	for key, active in pairs(db.activeProfile) do
		if active == name then
			db.activeProfile[key] = nil -- they use the fallback (Default, else the first scale) from now on
		end
	end
	local scores = db.auctionScores
	if type(scores) == "table" and scores.sortProfile == name then
		scores.sortProfile = nil
	end
	if type(charDb.hiddenProfiles) == "table" then
		charDb.hiddenProfiles[name] = nil
	end
	if charDb.profile == name then
		charDb.profile = nil
	end
	-- Nothing is left for the old names of this scale to lead to.
	for from, to in pairs(db.profileRenames) do
		if to == name then
			db.profileRenames[from] = nil
		end
	end
	ScoresChanged()
	return true
end

-- Replaces the weights of a scale with the given ones (key -> number); only finite non-zero numbers under string keys are kept.
-- The name has to be the stored spelling. Used by the Pawn import. With `replaceable` (a function of a stat key), only the weights
-- of the keys it accepts are replaced or cleared; the others stay as they are.
function ns.ReplaceProfileWeights(name, weights, replaceable)
	local profile = type(name) == "string" and db.profiles[name]
	if not profile then
		return false, "Scale not found."
	end
	local clean = {}
	if type(replaceable) == "function" then
		for key, value in pairs(profile.weights) do
			if not replaceable(key) then
				clean[key] = value
			end
		end
	end
	if type(weights) == "table" then
		for key, value in pairs(weights) do
			if type(key) == "string" and IsFiniteNumber(value) and value ~= 0 then
				clean[key] = value
			end
		end
	end
	profile.weights = clean
	ScoresChanged()
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
	ScoresChanged()
end

function ns.ResetActiveProfile()
	ns.GetActiveProfile().weights = GetDefaultWeights()
	ScoresChanged()
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
	ScoresChanged()
	ns.SettingsChanged()
end

function ns.ResetSettings()
	for name, default in pairs(DEFAULT_SETTINGS) do
		db.settings[name] = default
	end
	ScoresChanged()
	ns.SettingsChanged()
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
	ScoresChanged()
	ns.SettingsChanged()
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

-- The saved size of the options window as width, height (nil when it has the default size).
function ns.GetOptionsSize()
	local size = db and db.optionsSize
	if size then
		return size[1], size[2]
	end
end

-- Saves the size of the options window, kept inside ns.GetWindowBounds (nothing is saved for the default size).
function ns.SetOptionsSize(width, height)
	if db then
		db.optionsSize = ns.CleanWindowSize({ width, height }, OPTIONS_WIDTH, OPTIONS_HEIGHT)
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
	"/ju list - show the non-zero weights of the active scale",
	"/ju set <stat> <number> - set a weight (stat key, label or unique label prefix)",
	"/ju scale - show the stat weight scales; /ju scale <name> - switch to a scale",
	"/ju scale new <name> - create a scale with default weights and switch to it",
	"/ju scale copy <name> - copy the active scale and switch to the copy",
	"/ju scale rename <new name> - rename the active scale (your other characters follow the new name when they log in)",
	"/ju scale delete <name> - delete a scale",
	"/ju scale show <name> | hide <name> - list a scale in item tooltips / leave it out (its weights are kept)",
	"/ju scale import <Pawn scale tag> - create a scale from a Pawn tag and switch to it; import replace <tag> overwrites a scale of the same name (chat takes at most 255 characters: for long tags use the Import button of the options window)",
	"/ju scale export [<name>] - print the active (or the named) scale as a Pawn scale tag (the Export button of the options window gives one you can copy)",
	"/ju reset - reset the active scale's weights to the defaults",
	"/ju dump <item link> - show what the API reports for an item and how it is scored",
	"/ju range - turn the range check indicator on or off",
	"/ju range <spell name or id> - choose the spell the indicator checks",
	"/ju range clear - forget the chosen spell",
	"/ju range unlock | lock - allow dragging the indicator / fix it in place",
	"/ju range nameplate | screen - show the indicator on the target's nameplate / at a fixed spot on the screen",
	"/ju range size <12-128> - icon size in pixels",
	"/ju recipes on | off - turn the recipe lookup (saving recipes, the lookup and its key binding) on or off",
	"/ju recipes <item link | item ID | item name> - list the saved recipes that use an item as an ingredient",
	"/ju recipes - the same for the item you are pointing at (also: the key binding under Options > Keybindings > AddOns)",
	"/ju recipes status - show what is saved and what the client gives the addon",
	"/ju recipes forget - delete the saved recipes (asks you to repeat it with confirm)",
	"/ju recipes forget <character> - remove one character (Name or Name-Realm) from the saved recipes, with its saved bags, bank and mail (asks for confirm too)",
	"/ju mail - show whether the mail features (recent recipients and mail materials) are on; /ju mail on | off - turn them on or off",
	"/ju mail clear - forget the recent mail recipients of this realm",
	"/ju minimap - show or hide the minimap button; /ju minimap reset - move it back to its default place",
	"/ju profile - show the settings profiles (the whole addon's settings, not the stat weight scales); /ju profile <name> - switch this character to a profile",
	"/ju profile new <name> - save the current settings as a new profile and switch to it; /ju profile copy <name> - copy the active profile and switch to the copy",
	"/ju profile rename <new name> - rename the active profile; /ju profile delete <name> - delete a profile (the characters that used it fall back to Default)",
	"/ju profile export [<name>] - print the active (or the named) profile as a text string; /ju profile import <string> - create a profile from one; import replace <string> overwrites a profile of the same name (chat takes at most 255 characters: for long strings use the Import button of the options window's Profiles tab)",
	"/ju profit - list the open profession's learned recipes by crafting profit in chat (needs Auctionator); /ju profit <name> shows a recipe's prices",
	"/ju pin - put the map pin where you stand",
	"/ju pin <x> <y> - put the map pin in your current zone at those coordinates (percent, as the map shows them; for example /ju pin 45.2 67.8)",
	"/ju pin clear - remove the map pin",
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
	ns.Print("Weights of scale \"" .. ns.GetActiveProfileName() .. "\":")
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
	ns.Print("Active scale: " .. ns.GetActiveProfileName())
	local names = ns.GetProfileNames()
	for _, name in ipairs(names) do
		print("  " .. (name == ns.GetActiveProfileName() and "> " or "  ") .. name .. (ns.IsProfileShown(name) and "" or " (hidden from tooltips)"))
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
	ns.Print(ns.GetStatLabel(key) .. " weight set to " .. ns.FormatNumber(value, 4) .. " (scale \"" .. ns.GetActiveProfileName() .. "\").")
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
		ns.Print("Switched to scale \"" .. existing .. "\".")
		ns.NotifyConfigChanged()
		return
	end

	local sub, arg = rest:match("^(%S+)%s*(.-)$")
	sub = sub:lower()

	if sub == "new" or sub == "copy" then
		if arg == "" then
			ns.Print("Usage: /ju scale " .. sub .. " <name>")
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
		ns.Print("Created and switched to scale \"" .. ns.GetActiveProfileName() .. "\".")
	elseif sub == "rename" then
		if arg == "" then
			ns.Print("Usage: /ju scale rename <new name>")
			return
		end
		local old = ns.GetActiveProfileName()
		local ok, err = ns.RenameProfile(old, arg)
		if not ok then
			ns.Print(err)
			return
		end
		ns.Print("Renamed scale \"" .. old .. "\" to \"" .. ns.GetActiveProfileName() .. "\".")
	elseif sub == "delete" then
		local name = FindProfileName(arg)
		if not name then
			ns.Print(arg == "" and "Usage: /ju scale delete <name>" or "Scale not found.")
			return
		end
		local ok, err = ns.DeleteProfile(name)
		if not ok then
			ns.Print(err)
			return
		end
		ns.Print("Deleted scale \"" .. name .. "\". Active scale: \"" .. ns.GetActiveProfileName() .. "\".")
	elseif sub == "show" or sub == "hide" then
		local name = FindProfileName(arg)
		if not name then
			ns.Print(arg == "" and "Usage: /ju scale " .. sub .. " <name>" or "Scale not found.")
			return
		end
		ns.SetProfileShown(name, sub == "show")
		if sub == "show" then
			ns.Print("Scale \"" .. name .. "\" is listed in item tooltips.")
		else
			ns.Print("Scale \"" .. name .. "\" is left out of item tooltips (its weights are kept).")
		end
	elseif sub == "import" then
		-- "import replace <tag>" overwrites the weights of a scale of the same name (the options window asks for a second click instead).
		local replace, tag = false, arg
		local flag, remainder = arg:match("^(%a+)%s+(.*)$")
		if flag and flag:lower() == "replace" then
			replace, tag = true, remainder
		end
		if Trim(tag) == "" then
			ns.Print("Usage: /ju scale import <Pawn scale tag> (the tag looks like ( Pawn: v1: \"Name\": Strength=1, Stamina=0.5 ))")
			return
		end
		local ok, result, info = ns.ImportPawnScale(tag, replace)
		if not ok then
			ns.Print(result)
			if info and info.exists then
				ns.Print("Use /ju scale import replace <tag> to replace its weights.")
			end
			return
		end
		ns.Print(ns.FormatPawnImport(result, info))
	elseif sub == "export" then
		local name
		if arg ~= "" then
			name = FindProfileName(arg)
			if not name then
				ns.Print("Scale not found.")
				return
			end
		end
		local tag, skipped = ns.GetPawnTag(name)
		if not tag then
			ns.Print(skipped)
			return
		end
		ns.Print("Pawn scale tag of \"" .. (name or ns.GetActiveProfileName()) .. "\" (the Export button of the options window gives one you can copy):")
		print("  " .. tag)
		if #skipped > 0 then
			ns.Print("Not in the tag (Pawn has no name for them): " .. table.concat(skipped, ", ") .. ".")
		end
		return
	else
		local name = FindProfileName(rest)
		if not name then
			ns.Print("Scale not found. Use /ju scale to list scales.")
			return
		end
		ns.SetActiveProfile(name)
		ns.Print("Switched to scale \"" .. name .. "\".")
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
	print("  Score with scale \"" .. ns.GetActiveProfileName() .. "\": " .. ns.FormatNumber(total, 4))
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
	elseif command == "scale" then
		HandleProfile(rest)
	elseif command == "profile" then -- the settings profiles (it used to be an unlisted alias of /ju scale)
		if ns.HandleSettingsProfileCommand then
			ns.HandleSettingsProfileCommand(rest)
		else
			ns.Print("The settings profiles are not available.")
		end
	elseif command == "reset" then
		ns.ResetActiveProfile()
		ns.Print("Weights of scale \"" .. ns.GetActiveProfileName() .. "\" reset to the defaults.")
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
	elseif command == "profit" then
		if ns.HandleProfitCommand then
			ns.HandleProfitCommand(rest)
		else
			ns.Print("Crafting profit is not available.")
		end
	elseif command == "pin" then
		if ns.HandlePinCommand then
			ns.HandlePinCommand(rest)
		else
			ns.Print("The map pin is not available.")
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
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, loadedName)
	if event == "PLAYER_LOGIN" then
		-- The realm is known by now: the choices that older versions kept in the character's own saved variables move into the account data
		-- (when the realm was already known at load, that happened then).
		self:UnregisterEvent("PLAYER_LOGIN")
		if db then
			CurrentKey()
		end
		return
	end
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
	if ns.InitProfit then
		ns.InitProfit(db)
	end
	if ns.InitProfessionWindow then
		ns.InitProfessionWindow(db)
	end
	if ns.InitAuctionScores then
		ns.InitAuctionScores(db)
	end
	if ns.InitAuctionHouseResize then
		ns.InitAuctionHouseResize(db)
	end
	if ns.InitMinimap then
		ns.InitMinimap(db)
	end
	if ns.InitSettingsProfiles then
		ns.InitSettingsProfiles(db) -- after the features: it snapshots (and applies) their settings
	end
	if ns.InitOptions then
		ns.InitOptions()
	end
end)

local addonName, ns = ...

--[[
	Recipe lookup: lists the recipes that use an item as an ingredient, with the materials each one needs and who knows it.
	It lists every recipe: the saved ones and, from the bundled data, the ones nobody among the player's characters knows.

	The game only lists a profession's recipes while its window is open, so whenever one of the player's own profession windows
	opens (or its list updates) the recipes are read and saved account-wide. Without a window the character's recipes are learned
	from the bundled data (Data/RecipeData.lua): at login and when skills or spells change, IsPlayerSpell tells which of the bundled
	recipes of each of the character's professions it knows (ns.LearnKnownRecipes). That only adds the recipes the character
	knows (never the unknown ones) and marks or unmarks who knows them; the window scan stays the fallback for recipes the bundle
	lacks and is richer where both saved a recipe.

	Saved data (validated in ns.InitRecipes, all keys are additive and optional):
		JimmysStatWeightsDB.recipes = { [recipeID] = { name, icon, profession, output = itemID, reagents = { [itemID] = quantity },
			slots = { { items = { itemID, ... }, quantity = n } }, source = text } }
			(source is the game's "where to get it" text; it is kept, but the window only shows it in a row's tooltip when there is one)
		JimmysStatWeightsDB.recipeKnownBy = { [recipeID] = { ["Name-Realm"] = true } }
		JimmysStatWeightsDB.itemNames = { [itemID] = name } -- names of ingredients, so a name can be looked up offline
		JimmysStatWeightsDB.recipeSkill = { ["Name-Realm"] = { [lowercase profession] = { rank, max, time } } } -- profession skill per character, for the skill-up chance
		JimmysStatWeightsDB.recipeLookup = { enabled = true, hiddenProfessions = { [lowercase profession] = true }, onlyMyProfessions = false } -- off: no recipes are learned and the lookup is closed; what is saved is kept; hiddenProfessions: professions the recipes window leaves out (Options > Recipes); onlyMyProfessions: the check box of the window, only the recipes of the professions the current character has

	Only basic reagent slots are saved (optional and finishing slots are skipped). The index reagent item -> recipes is kept
	in memory and rebuilt at load and after every scan. "reagents" is the flat map of every ingredient item (what the index
	uses); "slots" keeps how they group: the items of one slot are interchangeable choices (for example the quality tiers of an
	herb) that together must reach the slot's quantity, as in Blizzard's own recipe tracker. Recipes saved before "slots" existed
	have none until they are scanned again.

	Skill-up chance: Data/RecipeData.lua (generated, see tools/gen_recipe_data.py) has the skill where each recipe turns yellow and
	grey, the item that teaches it, its skill line, ingredients and output. With the skill each character had the last time its professions were read (recipeSkill) that
	gives the chance of a skill-up (ns.GetSkillUpChance); the difficulty the open profession window reports is kept for the session
	and only used to cross-check the data.

	Profession filter: when the results hold more than one profession the window shows a button bar (ns.CreateProfessionFilter,
	also used by the materials window) with "All" and one button per profession; a click lists only that profession's recipes.
	The selection is kept for the session (not saved) and falls back to "All" when the profession leaves the results.
	Professions can also be hidden for good (recipeLookup.hiddenProfessions, set in Options > Recipes; the materials window has its
	own set): their recipes are dropped before the bar is built, so the bar only offers what is left. A line above the buttons
	says where to hide professions, or (orange) which ones are hidden.

	All recipes that use the item: the window merges the saved recipes with every bundled recipe whose ingredients include the item
	(a reverse index of ns.RecipeReagents, built the first time it is needed). A saved record wins (it may have alternative-item
	slots from a profession window); the bundled data fills the rest: one single-item slot per ingredient, the output, the icon of
	the output item or of the spell. Nothing is saved for them. The spell name comes from the client; while it is missing the row
	says "Recipe <id>", the name is requested (a few times per session at most) and the open window is refreshed when
	SPELL_DATA_LOAD_RESULT brings it. The profession of a bundled recipe is the localized name of its skill line when it is known at
	runtime (the character's own professions, else the saved recipes of that skill line), else the bundled English name
	(ns.SkillLineNames); names are compared with ns.ProfessionKey, so they meet the saved ones. A recipe nobody knows is listed after
	the known ones, its name grey and its status "Not known by your characters". The materials window and the saved-recipe counts
	only ever use saved, known recipes.

	"Only my professions": a check box at the top of the window (recipeLookup.onlyMyProfessions, saved for all characters) keeps
	only the recipes of the professions the current character has: a bundled recipe by its skill line, any other by the profession
	name it was saved under, and a recipe the current character knows always counts. It is applied first; the professions hidden in
	the settings are dropped from what is left (so the counts of the orange line come from it), and the bar is built from what
	remains after both. When the character's professions cannot be read (not loaded yet, secret) the check box filters nothing.

	The rows of the open window are built once per item and kept (rowCache) until something that shapes them changes (the saved
	recipes, the professions or the skills, a spell name arriving, the window being opened on an item); BAG_UPDATE_DELAYED only
	recolors the materials of the rows shown. Names of ingredients are only saved for items the saved recipes use; the others
	are requested and shown without being saved.

	Every API result is read through pcall and skipped when it is a secret value; nothing is branched on a secret.
	The profession window's own settings (for example "show unlearned") are never changed.
]]

local FRAME_NAME = "JimmysUtilsRecipesFrame"
local SCROLL_NAME = "JimmysUtilsRecipesScroll"

local FRAME_WIDTH = 380
local FRAME_HEIGHT = 360
local LIST_WIDTH = 316 -- scroll frame width (frame minus margins and the scroll bar)
local LIST_LEFT = 14
local CHECK_TOP = 62 -- where the "only my professions" check box starts (below the header)
local CHECK_SIZE = 22
local CHECK_LABEL_WIDTH = FRAME_WIDTH - 12 - CHECK_SIZE - 4 - 16 -- room for the label of the check box
local FILTER_TOP = CHECK_TOP + CHECK_SIZE + 2 -- where the filter bar (its info line) starts, below the check box
local LIST_TOP = FILTER_TOP + 4 -- where the list starts below the top of the window; with the profession filter bar it starts below that
local ROW_TOP_HEIGHT = 40 -- name line and detail line, above the materials
local ROW_BOTTOM_PADDING = 6
local MATERIALS_MIN_HEIGHT = 12 -- one line of the small font
local MATERIALS_WIDTH = LIST_WIDTH - 8
local ROW_ICON_SIZE = 32
local HEADER_ICON_SIZE = 28
local QTY_WIDTH = 40
local DETAIL_HEIGHT = 18
local QUESTION_ICON = 134400 -- INV_Misc_QuestionMark

local SCAN_DELAY = 0.5 -- seconds; the profession events come in bursts
local NAME_RETRY_DELAY = 2 -- item names that are not cached yet are asked for again after this long
local MAX_MATCHES = 5 -- items listed in chat when a name matches several
local MAX_NOT_READY_RETRIES = 20 -- how often a scan waits for a profession window that is still loading
local LEARN_DELAY = 1 -- seconds; the spell and skill events come in bursts at login
local MAX_LEARN_RETRIES = 5 -- how often a spell name is asked for, and how often a pass waits for the spells to load, per session

local WOWHEAD_BASE = "https://www.wowhead.com/forever/"
local LINK_POPUP_NAME = "JimmysUtilsLinkPopup"
local LINK_POPUP_WIDTH = 360
local LINK_POPUP_HEIGHT = 170
local LINK_BOX_WIDTH = 320
local LINK_BUTTON_WIDTH = 60
local LINK_BUTTON_HEIGHT = 18

local CHANCE_GAP = 4 -- between a recipe name and its skill-up chance
local ROW_NAME_AREA = LIST_WIDTH - (2 + ROW_ICON_SIZE + 6) - (4 + QTY_WIDTH + 4) -- where the name and the chance of a row fit

-- The official difficulty colors (the client's own globals when they exist) by skill-up category.
local DIFFICULTY_COLORS = {
	orange = { global = "DIFFICULT_DIFFICULTY_COLOR", fallback = { 1, 0.5, 0.25 } },
	yellow = { global = "FAIR_DIFFICULTY_COLOR", fallback = { 1, 1, 0 } },
	green = { global = "EASY_DIFFICULTY_COLOR", fallback = { 0.25, 0.75, 0.25 } },
	grey = { global = "TRIVIAL_DIFFICULTY_COLOR", fallback = { 0.5, 0.5, 0.5 } },
}
-- Enum.TradeskillRelativeDifficulty (Optimal, Medium, Easy, Trivial) as a category.
local DIFFICULTY_CATEGORIES = { [0] = "orange", [1] = "yellow", [2] = "green", [3] = "grey" }

local KNOWN_NAME_COLOR = { 1, 0.82, 0 }
local UNKNOWN_NAME_COLOR = { 0.72, 0.72, 0.72 }
local KNOWN_TEXT_COLOR = "ff33ff33"
local UNKNOWN_TEXT_COLOR = "ffff9933"
local GREY_TEXT_COLOR = "ff999999"
local ENOUGH_TEXT_COLOR = "ff40ff40" -- a material you have enough of for one craft
local MISSING_TEXT_COLOR = "ffff9020" -- a material you have some of, but too little
local NONE_TEXT_COLOR = "ffff3030" -- a material you have none of

-- Prefix of the name of the item that teaches a recipe, by (lowercase) profession: "Recipe: Minor Healing Potion". Recipes of
-- other professions, or of a client in another language, have no prefix here and are searched by their plain name.
local RECIPE_ITEM_PREFIXES = {
	["alchemy"] = "Recipe",
	["cooking"] = "Recipe",
	["blacksmithing"] = "Plans",
	["leatherworking"] = "Pattern",
	["tailoring"] = "Pattern",
	["engineering"] = "Schematic",
	["enchanting"] = "Formula",
	["first aid"] = "Manual",
	["jewelcrafting"] = "Design",
	["inscription"] = "Technique",
}

-- Calls that, when they return true, mean the open window is not the player's own profession.
local SKIP_CHECKS = { "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting", "IsRuneforging" }
local SCAN_EVENTS = {
	"TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED", "TRADE_SKILL_CLOSE",
	"PLAYER_LOGIN", "SKILL_LINES_CHANGED", "ITEM_DATA_LOAD_RESULT", "BAG_UPDATE_DELAYED",
	"LEARNED_SPELL_IN_SKILL_LINE", "SPELLS_CHANGED", "SPELL_DATA_LOAD_RESULT",
}

local DEFAULT_LOOKUP = {
	enabled = true,
	onlyMyProfessions = false,
}

-- Set in ns.InitRecipes.
local db, recipes, knownBy, itemNames, skills
local lookup -- db.recipeLookup
local liveDifficulty = {} -- [character][recipeID] = { difficulty, skill }: what the profession window said in this session (not saved)
local reagentIndex = {} -- [itemID] = sorted list of recipe IDs that use it
local hovered = {} -- ["game" | "ref"] = itemID shown by that tooltip
local scanTimer -- the pending scan timer (a trailing debounce)
local scanToken = 0 -- invalidates timers that were replaced or cancelled
local scanForce = false -- an event that always rescans is waiting in the debounce
local notReadyRetries = 0
local lastSignature = {} -- ["Name-Realm|profession"] = "recipes|learned" of the last scan in this session
local pendingNames = {} -- ingredient item IDs whose names the client has not given yet
local nameRetryPending = false
local namesRefreshPending = false
local pendingSpells = {} -- recipe IDs the character knows whose spell names the client has not given yet
local learnTimer -- the pending learning pass (a trailing debounce)
local learnToken = 0 -- invalidates timers that were replaced or cancelled
local spellAttempts = {} -- [recipeID] = how often the spell's name was asked for; kept for the session so a name that never comes is given up on
local lineAttempts = {} -- [skillLine] = how often a pass found no known recipe at all in it (the spells may not be loaded yet)
local viewAttempts = {} -- [recipeID] = how often the window asked for the name of a bundled recipe's spell (kept for the session)
local viewPending = {} -- [recipeID] = true while such a request waits for SPELL_DATA_LOAD_RESULT
local viewRetryPending = false
local viewRefreshPending = false
local rowCache -- { itemID, rows }: the rows ns.GetRecipeRows built for the item of the open window
local function InvalidateRows()
	rowCache = nil
end
local ScheduleLearn, CancelLearn -- defined with the learning below
local initialized = false
local window, ui

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

-- A positive whole number that is not a secret value (item, recipe and spell IDs).
local function IsID(value)
	if IsSecret(value) or type(value) ~= "number" then
		return false
	end
	return value == value and value > 0 and value < 2 ^ 31 and value == math.floor(value)
end

-- A whole skill level (0 up to a few thousand) that is not a secret value.
local function IsSkillValue(value)
	if IsSecret(value) or type(value) ~= "number" then
		return false
	end
	return value == value and value >= 0 and value <= 10000 and value == math.floor(value)
end

-- The string itself, or nil for anything else (including secret values and empty strings).
local function PlainString(value)
	if IsSecret(value) or type(value) ~= "string" or value == "" then
		return nil
	end
	return value
end

local function PlainTable(value)
	if IsSecret(value) or type(value) ~= "table" then
		return nil
	end
	return value
end

local function Wipe(tbl)
	for key in pairs(tbl) do
		tbl[key] = nil
	end
end

-- "Name-Realm" of the current character (just "Name" when the realm is not known yet).
local function GetCharacterKey()
	if not UnitName then
		return nil
	end
	local ok, name = pcall(UnitName, "player")
	name = ok and PlainString(name) or nil
	if not name then
		return nil
	end

	local realm
	if GetNormalizedRealmName then
		local okRealm, value = pcall(GetNormalizedRealmName)
		realm = okRealm and PlainString(value) or nil
	end
	if not realm and GetRealmName then
		local okRealm, value = pcall(GetRealmName)
		realm = okRealm and PlainString(value) or nil
		realm = realm and realm:gsub("%s", "") or nil
	end
	if realm then
		return name .. "-" .. realm, realm
	end
	return name
end

ns.GetCharacterKey = GetCharacterKey

-- Character name as shown to the player: the realm is dropped for characters of the current realm.
local function FormatCharacter(key, ownRealm)
	local name, realm = key:match("^([^%-]+)%-(.+)$")
	if name and realm == ownRealm then
		return name
	end
	return key
end

local function ReadItemName(itemID)
	if not C_Item then
		return nil
	end
	local name
	if C_Item.GetItemNameByID then
		local ok, value = pcall(C_Item.GetItemNameByID, itemID)
		name = ok and PlainString(value) or nil
	end
	if not name and C_Item.GetItemInfo then
		local ok, value = pcall(C_Item.GetItemInfo, itemID)
		name = ok and PlainString(value) or nil
	end
	return name
end

local function ReadItemIcon(itemID)
	if C_Item and C_Item.GetItemIconByID then
		local ok, value = pcall(C_Item.GetItemIconByID, itemID)
		if ok and not IsSecret(value) and (type(value) == "number" or type(value) == "string") then
			return value
		end
	end
end

-- Name of an item: the client's answer when it has one (remembered for ingredients), else the saved name.
function ns.GetItemName(itemID)
	if not IsID(itemID) then
		return nil
	end
	local name = ReadItemName(itemID)
	if name then
		if itemNames and reagentIndex[itemID] then
			itemNames[itemID] = name
		end
		return name
	end
	return itemNames and itemNames[itemID] or nil
end

--------------------------------------------------------------------------------
-- Saved data and the ingredient index
--------------------------------------------------------------------------------

local function BuildIndex()
	InvalidateRows()
	reagentIndex = {}
	for recipeID, record in pairs(recipes) do
		for itemID in pairs(record.reagents) do
			local list = reagentIndex[itemID]
			if not list then
				list = {}
				reagentIndex[itemID] = list
			end
			list[#list + 1] = recipeID
		end
	end
	for _, list in pairs(reagentIndex) do
		table.sort(list)
	end
end

-- The saved slots of a recipe as they should be kept, or nil when they are missing or cannot be trusted (every item of
-- a slot must be an ingredient of the recipe, so the slots and the flat ingredient map agree).
local function CleanSlots(slots, reagents)
	if type(slots) ~= "table" then
		return nil
	end
	local clean = {}
	for _, slot in ipairs(slots) do
		if type(slot) ~= "table" or type(slot.items) ~= "table" or not IsID(slot.quantity) then
			return nil
		end
		local items = {}
		for _, itemID in ipairs(slot.items) do
			if not IsID(itemID) or not reagents[itemID] then
				return nil
			end
			items[#items + 1] = itemID
		end
		if #items == 0 then
			return nil
		end
		clean[#clean + 1] = { items = items, quantity = slot.quantity }
	end
	if #clean == 0 then
		return nil
	end
	return clean
end

-- Fills missing tables and drops malformed entries, so the rest of the code can trust the data.
local function InitData(database)
	db = database
	for _, key in ipairs({ "recipes", "recipeKnownBy", "itemNames", "recipeSkill" }) do
		if type(db[key]) ~= "table" then
			db[key] = {}
		end
	end
	recipes, knownBy, itemNames, skills = db.recipes, db.recipeKnownBy, db.itemNames, db.recipeSkill

	if type(db.recipeLookup) ~= "table" then
		db.recipeLookup = {}
	end
	lookup = db.recipeLookup
	for name, default in pairs(DEFAULT_LOOKUP) do
		if type(lookup[name]) ~= type(default) then
			lookup[name] = default
		end
	end
	lookup.hiddenProfessions = ns.CleanProfessionSet(lookup.hiddenProfessions)

	for recipeID, record in pairs(recipes) do
		local valid = IsID(recipeID) and type(record) == "table"
			and type(record.name) == "string" and record.name ~= ""
			and type(record.profession) == "string" and type(record.reagents) == "table"
		if valid then
			for itemID, quantity in pairs(record.reagents) do
				if not IsID(itemID) or not IsID(quantity) then
					record.reagents[itemID] = nil
				end
			end
			valid = next(record.reagents) ~= nil
		end
		if not valid then
			recipes[recipeID] = nil
		else
			if type(record.icon) ~= "number" and type(record.icon) ~= "string" then
				record.icon = nil
			end
			record.slots = CleanSlots(record.slots, record.reagents)
			if not IsID(record.output) then
				record.output = nil
			end
			if type(record.source) ~= "string" or record.source == "" then
				record.source = nil
			end		end
	end

	for recipeID, characters in pairs(knownBy) do
		if not recipes[recipeID] or type(characters) ~= "table" then
			knownBy[recipeID] = nil
		else
			for character, flag in pairs(characters) do
				if type(character) ~= "string" or flag ~= true then
					characters[character] = nil
				end
			end
			if next(characters) == nil then
				knownBy[recipeID] = nil
			end
		end
	end

	for itemID, name in pairs(itemNames) do
		if not IsID(itemID) or type(name) ~= "string" or name == "" then
			itemNames[itemID] = nil
		end
	end

	for character, professions in pairs(skills) do
		if type(character) ~= "string" or type(professions) ~= "table" then
			skills[character] = nil
		else
			for profession, entry in pairs(professions) do
				local valid = type(profession) == "string" and profession ~= "" and type(entry) == "table"
					and IsSkillValue(entry.rank) and IsSkillValue(entry.max) and entry.max > 0 and entry.rank <= entry.max
				if not valid then
					professions[profession] = nil
				elseif type(entry.time) ~= "number" or entry.time ~= entry.time then
					entry.time = 0
				end
			end
			if next(professions) == nil then
				skills[character] = nil
			end
		end
	end

	BuildIndex()
end

-- Number of saved recipes and a sorted list of { name, count } per profession.
function ns.GetRecipeSummary()
	local total, counts = 0, {}
	if recipes then
		for _, record in pairs(recipes) do
			total = total + 1
			counts[record.profession] = (counts[record.profession] or 0) + 1
		end
	end
	local professions = {}
	for name, count in pairs(counts) do
		professions[#professions + 1] = { name = name, count = count }
	end
	table.sort(professions, function(a, b)
		local la, lb = a.name:lower(), b.name:lower()
		if la ~= lb then
			return la < lb
		end
		return a.name < b.name
	end)
	return total, professions
end

local RefreshWindow -- defined with the window below

-- Names of the professions in a set of hidden ones ({ [lowercase profession] = true }), sorted: spelled as the saved recipes
-- spell them, or (for a profession no saved recipe has) the lowercase key with a capital letter at the start and after each
-- space (only plain ASCII letters change, so accented words are left alone).
function ns.GetHiddenProfessionNames(set)
	local spelled = {}
	local _, professions = ns.GetRecipeSummary()
	for _, profession in ipairs(professions) do
		local key = ns.ProfessionKey(profession.name)
		if key and not spelled[key] then
			spelled[key] = Trim(profession.name)
		end
	end
	local names = {}
	for key in pairs(set or {}) do
		local capitalized = key:gsub("^%l", string.upper):gsub(" %l", string.upper)
		names[#names + 1] = spelled[key] or capitalized
	end
	table.sort(names, function(a, b)
		local la, lb = a:lower(), b:lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return names
end

-- The saved set of professions the recipes window leaves out: { [lowercase profession] = true } (the live table).
function ns.GetHiddenRecipeProfessions()
	return lookup and lookup.hiddenProfessions or {}
end

-- Hides or shows a profession in the recipes window and refreshes the window when it is open. Returns false for a name that
-- is not usable or before the data is loaded.
function ns.SetRecipeProfessionHidden(profession, hidden)
	local key = ns.ProfessionKey(profession)
	if not lookup or not key then
		return false
	end
	lookup.hiddenProfessions[key] = hidden and true or nil
	if window and window:IsShown() then
		RefreshWindow()
	end
	return true
end

-- Tells the open windows that the saved recipes changed.
local function NotifyChanged()
	InvalidateRows()
	if window and window:IsShown() then
		RefreshWindow()
	end
	if ns.RefreshRecipesPage then
		ns.RefreshRecipesPage()
	end
	if ns.RefreshMailMaterials then
		ns.RefreshMailMaterials()
	end
end

-- Deletes every saved recipe, who knows it, and the remembered item names. Returns how many recipes were saved.
function ns.ForgetRecipes()
	if not db then
		return 0
	end
	local count = ns.GetRecipeSummary()
	Wipe(recipes)
	Wipe(knownBy)
	Wipe(itemNames)
	Wipe(skills)
	Wipe(liveDifficulty)
	Wipe(pendingNames)
	Wipe(pendingSpells)
	Wipe(spellAttempts)
	Wipe(lineAttempts)
	Wipe(lastSignature)
	CancelLearn()
	BuildIndex()
	NotifyChanged()
	return count
end

local function SetKnown(recipeID, character, known)
	local characters = knownBy[recipeID]
	if known then
		if not characters then
			characters = {}
			knownBy[recipeID] = characters
		end
		characters[character] = true
	elseif characters then
		characters[character] = nil
		if next(characters) == nil then
			knownBy[recipeID] = nil
		end
	end
end

-- Characters ("Name-Realm") that appear in the saved known-by data or the saved items and match the text: a full "Name-Realm" or just
-- "Name" (case-insensitive; only ASCII letters change case, other characters are compared as they are).
function ns.FindSavedCharacters(text)
	local matches, seen = {}, {}
	local query = Trim(text or ""):lower()
	if query == "" then
		return matches
	end
	local withRealm = query:find("-", 1, true) ~= nil
	local function Consider(character)
		if not seen[character] then
			seen[character] = true
			local lowered = character:lower()
			local name = lowered:match("^([^%-]+)") or lowered
			if (withRealm and lowered == query) or (not withRealm and name == query) then
				matches[#matches + 1] = character
			end
		end
	end
	for _, characters in pairs(knownBy or {}) do
		for character in pairs(characters) do
			Consider(character)
		end
	end
	for character in pairs(skills or {}) do
		Consider(character)
	end
	-- Characters with saved bags, bank or mail but no recipes can be forgotten too.
	for _, character in ipairs(ns.GetInventoryCharacters and ns.GetInventoryCharacters() or {}) do
		Consider(character)
	end
	table.sort(matches)
	return matches
end

-- Removes a character ("Name-Realm", as returned by FindSavedCharacters) from every recipe, and its saved profession skills,
-- bags, bank and mailbox (Inventory.lua). Returns how many recipes it was known for.
function ns.ForgetCharacter(character)
	local count = 0
	for recipeID, characters in pairs(knownBy) do
		if characters[character] then
			count = count + 1
			SetKnown(recipeID, character, false)
		end
	end
	local forgotInventory = ns.ForgetInventory and ns.ForgetInventory(character) or false
	local forgotSkills = skills[character] ~= nil
	skills[character] = nil
	liveDifficulty[character] = nil
	if count > 0 or forgotInventory or forgotSkills then
		Wipe(lastSignature)
		NotifyChanged()
	end
	return count
end

--------------------------------------------------------------------------------
-- Scanning the open profession window
--------------------------------------------------------------------------------

-- True when the open window is not the player's own profession (linked, guild, guild member, runeforging or NPC
-- crafting). A secret answer or a failing call counts as true, because the code cannot tell.
local function ScanBlocked()
	for _, name in ipairs(SKIP_CHECKS) do
		local fn = C_TradeSkillUI[name]
		if fn then
			local ok, result = pcall(fn)
			if not ok or IsSecret(result) or result then
				return true
			end
		end
	end
	return false
end

-- False while the window is still loading its data.
local function IsWindowReady()
	local ready = C_TradeSkillUI.IsTradeSkillReady
	if ready then
		local ok, result = pcall(ready)
		if ok and not IsSecret(result) and result == false then
			return false
		end
	end
	local changing = C_TradeSkillUI.IsDataSourceChanging
	if changing then
		local ok, result = pcall(changing)
		if ok and not IsSecret(result) and result then
			return false
		end
	end
	return true
end

-- The recipe IDs of the open profession, and whether the list is complete (GetAllRecipeIDs ignores the window's
-- filters, GetFilteredRecipeIDs does not).
local function GetRecipeIDs()
	local candidates = {
		{ fn = C_TradeSkillUI.GetAllRecipeIDs, complete = true },
		{ fn = C_TradeSkillUI.GetFilteredRecipeIDs, complete = false },
	}
	for _, candidate in ipairs(candidates) do
		if candidate.fn then
			local ok, ids = pcall(candidate.fn)
			ids = ok and PlainTable(ids) or nil
			if ids and #ids > 0 then
				return ids, candidate.complete
			end
		end
	end
end

-- Name of a profession from a ProfessionInfo: the parent profession ("Alchemy") rather than an expansion's skill line.
local function ProfessionNameOf(info)
	info = PlainTable(info)
	if not info then
		return nil
	end
	return PlainString(info.parentProfessionName) or PlainString(info.professionName)
end

-- Profession of the open window.
local function GetBaseProfessionName()
	if C_TradeSkillUI.GetBaseProfessionInfo then
		local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
		if ok then
			return ProfessionNameOf(info)
		end
	end
end

-- Profession a recipe belongs to; nil when it cannot be told.
local function GetRecipeProfession(recipeID, fallback)
	if C_TradeSkillUI.GetProfessionInfoByRecipeID then
		local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID)
		local name = ok and ProfessionNameOf(info) or nil
		if name then
			return name
		end
	end
	return fallback
end

-- The quantity of an item in a slot: a variable quantity for that very item, else the slot's quantity.
local function GetSlotQuantity(slot, itemID)
	local variable = PlainTable(slot.variableQuantities)
	if variable then
		for _, entry in ipairs(variable) do
			entry = PlainTable(entry)
			local reagent = entry and PlainTable(entry.reagent)
			if reagent and IsID(reagent.itemID) and reagent.itemID == itemID and IsID(entry.quantity) then
				return entry.quantity
			end
		end
	end
	return slot.quantityRequired
end

-- { [itemID] = quantity } of the basic reagents of a schematic, and the list of its slots ({ items = { itemID, ... },
-- quantity } each; the items of a slot are alternatives), or nil when it cannot be read. Optional and finishing slots are
-- skipped; a modifying slot the recipe requires counts as basic. A basic slot the client says is not required stays in the
-- flat map (the ingredient index) but is not a slot, because it does not count toward crafting.
local function ReadReagents(schematic)
	local slots = PlainTable(schematic.reagentSlotSchematics)
	if not slots then
		return nil
	end
	local types = Enum and Enum.CraftingReagentType
	local basic, modifying = types and types.Basic, types and types.Modifying

	local reagents, craftSlots = {}, {}
	for _, slot in ipairs(slots) do
		slot = PlainTable(slot)
		if slot then
			local use = true
			local reagentType = slot.reagentType
			if basic ~= nil and reagentType ~= nil then
				if IsSecret(reagentType) then
					use = false
				elseif reagentType ~= basic then
					local required = slot.required
					use = modifying ~= nil and reagentType == modifying and not IsSecret(required) and required == true
				end
			end
			local list = use and PlainTable(slot.reagents) or nil
			if list then
				local items, slotQuantity = {}, nil
				for _, reagent in ipairs(list) do
					reagent = PlainTable(reagent)
					local itemID = reagent and reagent.itemID
					if IsID(itemID) then
						local quantity = GetSlotQuantity(slot, itemID)
						if IsID(quantity) then
							reagents[itemID] = (reagents[itemID] or 0) + quantity
							items[#items + 1] = itemID
							slotQuantity = slotQuantity or quantity
						end
					end
				end
				local notRequired = not IsSecret(slot.required) and slot.required == false
				if #items > 0 and not (basic ~= nil and reagentType == basic and notRequired) then
					craftSlots[#craftSlots + 1] = { items = items, quantity = IsID(slot.quantityRequired) and slot.quantityRequired or slotQuantity }
				end
			end
		end
	end
	return reagents, craftSlots
end

local function ReadOutput(schematic, recipeID)
	if IsID(schematic.outputItemID) then
		return schematic.outputItemID
	end
	if C_TradeSkillUI.GetRecipeOutputItemData then
		local ok, data = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
		data = ok and PlainTable(data) or nil
		if data and IsID(data.itemID) then
			return data.itemID
		end
	end
end

-- { name, icon, learned, difficulty } of a recipe (difficulty = Enum.TradeskillRelativeDifficulty, nil when the client does not
-- say), or nil when the name or the learned flag cannot be read.
local function ReadRecipeInfo(recipeID)
	local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
	info = ok and PlainTable(info) or nil
	if not info then
		return nil
	end
	local name, learned = PlainString(info.name), info.learned
	if not name or IsSecret(learned) then
		return nil
	end
	local icon = info.icon
	if IsSecret(icon) or (type(icon) ~= "number" and type(icon) ~= "string") then
		icon = nil
	end
	local difficulty = info.relativeDifficulty
	if IsSecret(difficulty) or type(difficulty) ~= "number" or not DIFFICULTY_CATEGORIES[difficulty] then
		difficulty = nil
	end
	return { name = name, icon = icon, learned = learned and true or false, difficulty = difficulty }
end

-- Saves the skill of a character in a profession ("Alchemy" or any case). Returns true when the saved rank or maximum changed.
local function SetSavedSkill(character, profession, rank, max)
	if not (skills and character and type(profession) == "string" and profession ~= ""
		and IsSkillValue(rank) and IsSkillValue(max) and max > 0 and rank <= max) then
		return false
	end
	local professions = skills[character]
	if not professions then
		professions = {}
		skills[character] = professions
	end
	local key = profession:lower()
	local entry = professions[key]
	local changed = not entry or entry.rank ~= rank or entry.max ~= max
	if not entry then
		entry = {}
		professions[key] = entry
	end
	entry.rank, entry.max, entry.time = rank, max, time and time() or 0
	return changed
end

-- The skill of the open profession: its name, rank and maximum, or nil when the client does not say.
local function ReadOpenProfessionSkill()
	if not C_TradeSkillUI.GetBaseProfessionInfo then
		return nil
	end
	local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
	info = ok and PlainTable(info) or nil
	local name = ProfessionNameOf(info)
	if name and IsSkillValue(info.skillLevel) and IsSkillValue(info.maxSkillLevel) and info.maxSkillLevel > 0 then
		return name, info.skillLevel, info.maxSkillLevel
	end
end

-- Keeps what the open profession window says: the skill of the character, and the difficulty of each recipe (this session only,
-- to cross-check the bundled data). Returns true when something the skill-up chances use changed.
local function RecordProfessionWindow(character, infos)
	local profession, rank, max = ReadOpenProfessionSkill()
	if not profession then
		return false
	end
	local changed = SetSavedSkill(character, profession, rank, max)
	local live = liveDifficulty[character]
	if not live then
		live = {}
		liveDifficulty[character] = live
	end
	for recipeID, info in pairs(infos) do
		if info.difficulty ~= nil then
			local previous = live[recipeID]
			if not previous or previous.difficulty ~= info.difficulty or previous.skill ~= rank then
				changed = true
			end
			live[recipeID] = { difficulty = info.difficulty, skill = rank }
		end
	end
	return changed
end

-- Saves one recipe. Returns the profession it was saved under, or nil when nothing usable was read (including when
-- its profession is not known).
local function ScanRecipe(recipeID, info, baseProfession, character, usedItems)
	local profession = GetRecipeProfession(recipeID, baseProfession)
	if not profession then
		return nil
	end

	local existing = recipes[recipeID]
	local reagents, slots, output
	local okSchematic, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	schematic = okSchematic and PlainTable(schematic) or nil
	if schematic then
		reagents, slots = ReadReagents(schematic)
		output = ReadOutput(schematic, recipeID)
	end
	if (not reagents or next(reagents) == nil) and existing then
		reagents = existing.reagents
		slots = existing.slots
	end
	-- A window that gives no output keeps the saved one, else the bundled one.
	if not output then
		local bundled = ns.RecipeOutputs and ns.RecipeOutputs[recipeID]
		output = existing and existing.output or (IsID(bundled) and bundled or nil)
	end
	if slots and #slots == 0 then
		slots = nil
	end
	if not reagents or next(reagents) == nil then
		return nil
	end

	-- Where to get the recipe only matters while somebody does not know it; an older text is kept when none is offered.
	local source = existing and existing.source or nil
	if not info.learned and C_TradeSkillUI.GetRecipeSourceText then
		local okSource, text = pcall(C_TradeSkillUI.GetRecipeSourceText, recipeID)
		text = okSource and PlainString(text) or nil
		if text then
			source = text
		end
	end

	recipes[recipeID] = {
		name = info.name,
		icon = info.icon or (existing and existing.icon) or nil,
		profession = profession,
		output = output,
		reagents = reagents,
		slots = slots,
		source = source,
	}
	SetKnown(recipeID, character, info.learned)

	for itemID in pairs(reagents) do
		usedItems[itemID] = true
	end
	return profession
end

-- Remembers the names of ingredients so they can be found by name later. Names the client has not cached yet are
-- requested and stay pending: they are tried again after a moment and whenever the client reports an item as loaded.
local function TryFillName(itemID)
	local name = ReadItemName(itemID)
	if name then
		-- Only the ingredients of saved recipes are kept; the others (bundled recipes in the window) are shown without being saved.
		if reagentIndex[itemID] then
			itemNames[itemID] = name
		end
		pendingNames[itemID] = nil
		return true
	end
	return false
end

local function FillItemNames(items)
	for itemID in pairs(items) do
		if not itemNames[itemID] and not TryFillName(itemID) then
			pendingNames[itemID] = true
			if C_Item and C_Item.RequestLoadItemDataByID then
				pcall(C_Item.RequestLoadItemDataByID, itemID)
			end
		end
	end
	if next(pendingNames) and not nameRetryPending and C_Timer and C_Timer.After then
		nameRetryPending = true
		C_Timer.After(NAME_RETRY_DELAY, function()
			nameRetryPending = false
			for itemID in pairs(pendingNames) do
				TryFillName(itemID)
			end
			NotifyChanged()
		end)
	end
end

-- ITEM_DATA_LOAD_RESULT: an ingredient whose name was missing may be known now.
local function OnItemDataLoaded(itemID)
	if IsID(itemID) and pendingNames[itemID] and TryFillName(itemID) and not namesRefreshPending then
		if C_Timer and C_Timer.After then
			namesRefreshPending = true
			C_Timer.After(0, function()
				namesRefreshPending = false
				NotifyChanged()
			end)
		else
			NotifyChanged()
		end
	end
end

-- Is the recipe lookup on? When it is off no recipe is learned and the lookup does not answer (what is saved is kept).
function ns.IsRecipeLookupEnabled()
	return lookup ~= nil and lookup.enabled == true
end

-- Saves the recipes of the open profession window. Returns true and the number of recipes read, or false when the
-- window is not usable (not the player's own profession, no recipe list). With skipUnchanged the scan is also skipped
-- (false, "unchanged") when the profession, the number of recipes and the number learned are the same as at the last
-- scan of this profession in this session.
function ns.ScanRecipes(skipUnchanged)
	if not db or not ns.IsRecipeLookupEnabled() or not C_TradeSkillUI or ScanBlocked() then
		return false
	end
	local ids, complete = GetRecipeIDs()
	local character = GetCharacterKey()
	if not ids or not character then
		return false
	end
	local baseProfession = GetBaseProfessionName()

	local seen, order, infos, learnedCount = {}, {}, {}, 0
	for _, recipeID in ipairs(ids) do
		if IsID(recipeID) and not seen[recipeID] then
			seen[recipeID] = true
			order[#order + 1] = recipeID
			local info = ReadRecipeInfo(recipeID)
			infos[recipeID] = info
			if info and info.learned then
				learnedCount = learnedCount + 1
			end
		end
	end

	-- Every scan reads the skill and the difficulties; the windows only change when those did.
	local skillChanged = RecordProfessionWindow(character, infos)

	local signatureKey = character .. "|" .. (baseProfession or "?")
	local signature = #order .. "|" .. learnedCount
	if skipUnchanged and lastSignature[signatureKey] == signature then
		if skillChanged then
			NotifyChanged()
		end
		return false, "unchanged"
	end
	lastSignature[signatureKey] = signature

	local usedItems, identified, read = {}, {}, 0
	for _, recipeID in ipairs(order) do
		if infos[recipeID] then
			local profession = ScanRecipe(recipeID, infos[recipeID], baseProfession, character, usedItems)
			if profession then
				identified[profession] = true
				read = read + 1
			end
		end
	end

	-- A complete list that no longer holds a saved recipe of a profession seen in it means the character does not know it.
	if complete then
		for recipeID, record in pairs(recipes) do
			if identified[record.profession] and not seen[recipeID] then
				SetKnown(recipeID, character, false)
			end
		end
	end

	BuildIndex()
	FillItemNames(usedItems)
	NotifyChanged()
	return true, read
end

-- The professions the character has, as a list of { name, rank, max, skillLine } (the others are nil when the client does not
-- say); nil unless the list can be read reliably.
local function ReadOwnProfessions()
	if not (GetProfessions and GetProfessionInfo) then
		return nil
	end
	local results = { pcall(GetProfessions) }
	if not results[1] then
		return nil
	end
	local list = {}
	for position = 2, 8 do
		local index = results[position]
		if index ~= nil then
			if IsSecret(index) or type(index) ~= "number" then
				return nil
			end
			local ok, name, _, rank, max, _, _, skillLine = pcall(GetProfessionInfo, index)
			name = ok and PlainString(name) or nil
			if not name then
				return nil
			end
			list[#list + 1] = { name = name, rank = IsSkillValue(rank) and rank or nil, max = IsSkillValue(max) and max or nil,
				skillLine = IsID(skillLine) and skillLine or nil }
		end
	end
	-- No professions at all is more likely a list that has not loaded yet than a character without any.
	if #list == 0 then
		return nil
	end
	return list
end

-- The profession skill lines of a bundled recipe (ns.RecipeSkillLines gives one ID, or a list for the few recipes in several), as a
-- list; nil for a recipe the bundle does not have.
local function GetRecipeLines(recipeID)
	local value = ns.RecipeSkillLines and ns.RecipeSkillLines[recipeID]
	if IsID(value) then
		return { value }
	end
	value = PlainTable(value)
	if value then
		local lines = {}
		for _, line in ipairs(value) do
			if IsID(line) then
				lines[#lines + 1] = line
			end
		end
		if #lines > 0 then
			return lines
		end
	end
end

-- Takes this character off the recipes and the skills of professions it no longer has, and saves the skill it has in the ones
-- it does. A bundled recipe is the character's while it has any of the recipe's skill lines (when the client gave the skill line of
-- every profession); any other recipe is told by the profession name it was saved under.
local function SyncOwnProfessions()
	local character = db and GetCharacterKey()
	local list = character and ReadOwnProfessions()
	if not list then
		return
	end
	InvalidateRows() -- the professions name the bundled recipes' professions
	local names, ownedLines, linesKnown = {}, {}, true
	for _, profession in ipairs(list) do
		names[profession.name:lower()] = true
		if profession.skillLine then
			ownedLines[profession.skillLine] = true
		else
			linesKnown = false
		end
	end
	local changed = false
	for recipeID, characters in pairs(knownBy) do
		local record = recipes[recipeID]
		if characters[character] and record then
			local lines = linesKnown and GetRecipeLines(recipeID)
			local owned
			if lines then
				owned = false
				for _, line in ipairs(lines) do
					owned = owned or ownedLines[line] == true
				end
			else
				owned = names[record.profession:lower()] == true
			end
			if not owned then
				SetKnown(recipeID, character, false)
				changed = true
			end
		end
	end
	local saved = skills[character]
	if saved then
		for key in pairs(saved) do
			if not names[key] then
				saved[key] = nil
				changed = true
			end
		end
		if next(saved) == nil then
			skills[character] = nil
		end
	end
	local skillChanged = false
	for _, profession in ipairs(list) do
		if profession.rank and profession.max and SetSavedSkill(character, profession.name, profession.rank, profession.max) then
			skillChanged = true
		end
	end
	if changed then
		Wipe(lastSignature)
	end
	if changed or skillChanged then
		NotifyChanged()
	end
end

--------------------------------------------------------------------------------
-- Learning the recipes without opening the profession windows
--------------------------------------------------------------------------------

-- The bundled recipes of a profession skill line (a sorted list of recipe IDs, nil for a line without any). The index is built
-- from ns.RecipeSkillLines the first time it is needed.
local bundleSource, bundleLines
local function GetBundledRecipes(skillLine)
	local source = ns.RecipeSkillLines
	if type(source) ~= "table" then
		return nil
	end
	if bundleSource ~= source then
		bundleSource, bundleLines = source, {}
		for recipeID in pairs(source) do
			for _, line in ipairs(IsID(recipeID) and GetRecipeLines(recipeID) or {}) do
				local list = bundleLines[line]
				if not list then
					list = {}
					bundleLines[line] = list
				end
				list[#list + 1] = recipeID
			end
		end
		for _, list in pairs(bundleLines) do
			table.sort(list)
		end
	end
	return bundleLines[skillLine]
end

-- true or false when the character knows the recipe's spell or not, nil when the client does not give a plain boolean.
local function IsRecipeKnown(recipeID)
	local ok, result = pcall(IsPlayerSpell, recipeID)
	if ok and not IsSecret(result) and type(result) == "boolean" then
		return result
	end
	return nil
end

local function ReadSpellName(recipeID)
	if C_Spell and C_Spell.GetSpellName then
		local ok, value = pcall(C_Spell.GetSpellName, recipeID)
		local name = ok and PlainString(value) or nil
		if name then
			return name
		end
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, recipeID)
		info = ok and PlainTable(info) or nil
		local name = info and PlainString(info.name) or nil
		if name then
			return name
		end
	end
	if GetSpellInfo then
		local ok, value = pcall(GetSpellInfo, recipeID)
		return ok and PlainString(value) or nil
	end
end

local function ReadSpellIcon(recipeID)
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, value = pcall(C_Spell.GetSpellTexture, recipeID)
		if ok and not IsSecret(value) and (type(value) == "number" or type(value) == "string") then
			return value
		end
	end
end

-- { [itemID] = quantity } and the slots (one single-item slot per ingredient) of a bundled recipe, or nil without usable data.
local function GetBundledReagents(recipeID)
	local flat = ns.RecipeReagents and ns.RecipeReagents[recipeID]
	if type(flat) ~= "table" then
		return nil
	end
	local reagents, slots = {}, {}
	for position = 1, #flat, 2 do
		local itemID, quantity = flat[position], flat[position + 1]
		if not (IsID(itemID) and IsID(quantity)) or reagents[itemID] then
			return nil
		end
		reagents[itemID] = quantity
		slots[#slots + 1] = { items = { itemID }, quantity = quantity }
	end
	if #slots == 0 then
		return nil
	end
	return reagents, slots
end

local function GetBundledOutput(recipeID)
	local output = ns.RecipeOutputs and ns.RecipeOutputs[recipeID]
	if IsID(output) then
		return output
	end
end

-- The bundled recipes that use an item (a sorted list of recipe IDs, nil for an item none of them uses). The index is built from
-- ns.RecipeReagents the first time it is needed.
local usersSource, usersIndex
local function GetBundledUsers(itemID)
	local source = ns.RecipeReagents
	if type(source) ~= "table" then
		return nil
	end
	if usersSource ~= source then
		usersSource, usersIndex = source, {}
		for recipeID, flat in pairs(source) do
			if IsID(recipeID) and type(flat) == "table" then
				for position = 1, #flat, 2 do
					local item = flat[position]
					if IsID(item) then
						local list = usersIndex[item]
						if not list then
							list = {}
							usersIndex[item] = list
						end
						if list[#list] ~= recipeID then
							list[#list + 1] = recipeID
						end
					end
				end
			end
		end
		for _, list in pairs(usersIndex) do
			table.sort(list)
		end
	end
	return usersIndex[itemID]
end

-- The current character's professions as { lines = { [skillLine] = true }, keys = { [ns.ProfessionKey] = true }, names = { [skillLine] =
-- the client's name }, linesKnown, readable } (linesKnown is false when the client did not give the skill line of every profession;
-- readable is false, and the sets are empty, when the professions cannot be read).
local function ReadOwnSets()
	local own = { lines = {}, keys = {}, names = {}, linesKnown = true, readable = false }
	local list = ReadOwnProfessions()
	own.readable = list ~= nil
	for _, profession in ipairs(list or {}) do
		local key = ns.ProfessionKey(profession.name)
		if key then
			own.keys[key] = true
		end
		if profession.skillLine then
			own.lines[profession.skillLine] = true
			local name = Trim(profession.name)
			if name ~= "" then
				own.names[profession.skillLine] = name
			end
		else
			own.linesKnown = false
		end
	end
	return own
end

-- Is a row (GetRecipeRows) a recipe of the character's professions? Always when the character knows it; else by its skill lines when
-- it has them and the client gave all of the character's, else by the profession name (as SyncOwnProfessions does).
local function IsOwnRecipe(entry, own)
	if entry.knownHere then
		return true
	end
	if own.linesKnown and entry.lines then
		for _, line in ipairs(entry.lines) do
			if own.lines[line] then
				return true
			end
		end
		return false
	end
	local key = ns.ProfessionKey(entry.profession)
	return key ~= nil and own.keys[key] == true
end

-- The name each profession skill line goes by at runtime: the client's own name for the character's professions, else the spelling
-- the saved recipes of that skill line use (the most common one). A line without either is not in the list.
local function BuildLineNames(own)
	local names, counts = {}, {}
	for line, name in pairs(own.names) do
		names[line] = name
	end
	for recipeID, record in pairs(recipes) do
		local lines = GetRecipeLines(recipeID)
		local line = lines and #lines == 1 and lines[1] or nil
		local spelled = Trim(record.profession)
		if line and not names[line] and spelled ~= "" then
			counts[line] = counts[line] or {}
			counts[line][spelled] = (counts[line][spelled] or 0) + 1
		end
	end
	for line, spellings in pairs(counts) do
		local best, bestCount
		for spelled, count in pairs(spellings) do
			if not best or count > bestCount or (count == bestCount and spelled < best) then
				best, bestCount = spelled, count
			end
		end
		names[line] = best
	end
	return names
end

-- The profession a bundled recipe is shown under: the runtime name of its skill line, else the bundled English name. For the few
-- recipes in several lines the character's own line comes first, then one with a runtime name, then the first.
local function BundledProfession(lines, lineNames, own)
	local chosen
	for _, line in ipairs(lines or {}) do
		if own.lines[line] then
			chosen = line
			break
		end
	end
	for _, line in ipairs(chosen and {} or lines or {}) do
		if lineNames[line] then
			chosen = line
			break
		end
	end
	chosen = chosen or (lines and lines[1])
	if not chosen then
		return "Unknown"
	end
	local english = ns.SkillLineNames and PlainString(ns.SkillLineNames[chosen])
	return lineNames[chosen] or english or ("Profession " .. chosen)
end

-- The skill lines of the bundled recipes the window can list (the ones with ingredients), as a set. Built once per bundled table.
local reagentLinesSource, reagentLines
local function GetBundledReagentLines()
	local source = ns.RecipeReagents
	if type(source) ~= "table" then
		return {}
	end
	if reagentLinesSource ~= source then
		reagentLinesSource, reagentLines = source, {}
		for recipeID in pairs(source) do
			for _, line in ipairs(IsID(recipeID) and GetRecipeLines(recipeID) or {}) do
				reagentLines[line] = true
			end
		end
	end
	return reagentLines
end

-- The names of the professions the recipes window can show, sorted, one per ns.ProfessionKey: the saved recipes' professions (as
-- spelled there) and those of the bundled recipes (the runtime or saved name of the skill line, else the English one). Options >
-- Recipes lists them so that every profession button of the window can be hidden.
function ns.GetRecipeWindowProfessions()
	local list, seen = {}, {}
	local function Add(name)
		local key = ns.ProfessionKey(name)
		if key and not seen[key] then
			seen[key] = true
			list[#list + 1] = { key = key, label = Trim(name) }
		end
	end
	local _, saved = ns.GetRecipeSummary()
	for _, profession in ipairs(saved) do
		Add(profession.name)
	end
	local lineNames = BuildLineNames(ReadOwnSets())
	for line in pairs(GetBundledReagentLines()) do
		Add(lineNames[line] or (ns.SkillLineNames and PlainString(ns.SkillLineNames[line])) or ("Profession " .. line))
	end
	table.sort(list, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.label < b.label
	end)
	local names = {}
	for i, item in ipairs(list) do
		names[i] = item.label
	end
	return names
end

local function SameReagents(a, b)
	for itemID, quantity in pairs(a) do
		if b[itemID] ~= quantity then
			return false
		end
	end
	for itemID in pairs(b) do
		if not a[itemID] then
			return false
		end
	end
	return true
end

-- A saved recipe made from the bundled data for a recipe the character knows. Returns the record, or nil and why: "name" when the
-- client has no name for the spell yet (it is asked for), "data" when the bundle has no ingredients for it.
local function CreateBundledRecord(recipeID, profession)
	local reagents, slots = GetBundledReagents(recipeID)
	if not reagents then
		return nil, "data"
	end
	local name = ReadSpellName(recipeID)
	if not name then
		return nil, "name"
	end
	local output = GetBundledOutput(recipeID)
	return {
		name = name,
		icon = (output and ReadItemIcon(output)) or ReadSpellIcon(recipeID),
		profession = profession,
		output = output,
		reagents = reagents,
		slots = slots,
	}
end

-- Fills what a saved recipe is missing from the bundled data (a record from a profession window is richer and stays as it is).
-- Returns true when something was added.
local function FillFromBundle(recipeID, record)
	local changed = false
	if not record.output then
		record.output = GetBundledOutput(recipeID)
		changed = record.output ~= nil
	end
	if not record.icon then
		record.icon = (record.output and ReadItemIcon(record.output)) or ReadSpellIcon(recipeID)
		changed = changed or record.icon ~= nil
	end
	if not record.slots then
		local reagents, slots = GetBundledReagents(recipeID)
		if reagents and SameReagents(reagents, record.reagents) then
			record.slots = slots
			changed = true
		end
	end
	return changed
end

-- Learns which recipes the character knows from the bundled data (ns.RecipeSkillLines, ns.RecipeReagents, ns.RecipeOutputs): for
-- each of its professions, IsPlayerSpell tells which of that skill line's recipes it knows, outside any profession window. A known
-- recipe is marked as known (and saved from the bundle when no profession window saved it); a saved recipe of that skill line the
-- character does not know is unmarked (unless no recipe of the line at all is known, which looks like spells that are not loaded yet:
-- then nothing in that line is unmarked and the pass is repeated a few times). Unknown recipes are never saved. Recipes the bundle
-- does not have are left to the window scan. Returns true when something changed.
function ns.LearnKnownRecipes()
	if not (db and IsPlayerSpell and ns.IsRecipeLookupEnabled()) then
		return false
	end
	local character = GetCharacterKey()
	local list = character and ReadOwnProfessions()
	if not list then
		return false
	end

	local changed, added, waiting, usedItems = false, false, false, {}
	Wipe(pendingSpells)
	for _, profession in ipairs(list) do
		local line = profession.skillLine
		local bundled = line and GetBundledRecipes(line)
		local answers, trusted = {}, true
		for _, recipeID in ipairs(bundled or {}) do
			answers[recipeID] = IsRecipeKnown(recipeID)
		end
		if bundled then
			local anyKnown = false
			for _, recipeID in ipairs(bundled) do
				anyKnown = anyKnown or answers[recipeID] == true
			end
			if anyKnown then
				lineAttempts[line] = nil
			else
				local attempts = lineAttempts[line] or 0
				if attempts < MAX_LEARN_RETRIES then
					lineAttempts[line] = attempts + 1
					trusted, waiting = false, true
				end
			end
		end
		for _, recipeID in ipairs(bundled or {}) do
			local known = answers[recipeID]
			if known == true then
				local record = recipes[recipeID]
				if record then
					changed = FillFromBundle(recipeID, record) or changed
				else
					local why
					record, why = CreateBundledRecord(recipeID, profession.name)
					if record then
						recipes[recipeID] = record
						for itemID in pairs(record.reagents) do
							usedItems[itemID] = true
						end
						added, changed = true, true
					elseif why == "name" then
						-- Ask for the name (a few times per session at most), and come back when it is there.
						local attempts = spellAttempts[recipeID] or 0
						if attempts < MAX_LEARN_RETRIES then
							spellAttempts[recipeID] = attempts + 1
							if C_Spell and C_Spell.RequestLoadSpellData then
								pcall(C_Spell.RequestLoadSpellData, recipeID)
							end
							pendingSpells[recipeID] = true
							waiting = true
						end
					end
					if record then
						spellAttempts[recipeID] = nil
					end
				end
				local characters = knownBy[recipeID]
				if record and not (characters and characters[character]) then
					SetKnown(recipeID, character, true)
					changed = true
				end
			elseif known == false and trusted then
				local characters = knownBy[recipeID]
				if characters and characters[character] then
					SetKnown(recipeID, character, false)
					changed = true
				end
			end
		end
	end

	if added then
		BuildIndex()
		FillItemNames(usedItems)
	end
	if changed then
		NotifyChanged()
	end
	-- Names or spells the client has not loaded yet: SPELL_DATA_LOAD_RESULT brings the pass back, and so does a timer. Both are
	-- bounded by the attempt counters, which events do not reset.
	if waiting then
		ScheduleLearn(NAME_RETRY_DELAY)
	end
	return changed
end

-- The pass runs a moment after the last event that may have changed what the character knows (a trailing debounce).
ScheduleLearn = function(delay)
	if learnTimer and learnTimer.Cancel then
		pcall(learnTimer.Cancel, learnTimer)
	end
	learnTimer = nil
	learnToken = learnToken + 1
	local token = learnToken
	local function Fire()
		if token == learnToken then
			learnTimer = nil
			ns.LearnKnownRecipes()
		end
	end
	if C_Timer and C_Timer.NewTimer then
		learnTimer = C_Timer.NewTimer(delay or LEARN_DELAY, Fire)
	elseif C_Timer and C_Timer.After then
		C_Timer.After(delay or LEARN_DELAY, Fire)
	else
		ns.LearnKnownRecipes()
	end
end

CancelLearn = function()
	if learnTimer and learnTimer.Cancel then
		pcall(learnTimer.Cancel, learnTimer)
	end
	learnTimer = nil
	learnToken = learnToken + 1 -- a timer that cannot be cancelled does nothing when it fires
end

-- The scan runs a moment after the last profession event (a trailing debounce). Events that mean something changed
-- (the window opened, its data source changed, a recipe was learned) always rescan; a plain list update is skipped when
-- the cheap signature is unchanged.
local function StartScanTimer()
	scanToken = scanToken + 1
	local token = scanToken
	local function Fire()
		if token == scanToken then
			scanTimer = nil
			ns.RunScheduledScan()
		end
	end
	if C_Timer and C_Timer.NewTimer then
		scanTimer = C_Timer.NewTimer(SCAN_DELAY, Fire)
	elseif C_Timer and C_Timer.After then
		C_Timer.After(SCAN_DELAY, Fire)
	else
		return false
	end
	return true
end

local function CancelScan()
	if scanTimer and scanTimer.Cancel then
		pcall(scanTimer.Cancel, scanTimer)
	end
	scanTimer = nil
	scanToken = scanToken + 1 -- a timer that cannot be cancelled does nothing when it fires
	scanForce = false
	notReadyRetries = 0
end

local function ScheduleScan(force)
	if force then
		scanForce = true
	end
	notReadyRetries = 0
	if scanTimer and scanTimer.Cancel then
		pcall(scanTimer.Cancel, scanTimer)
	end
	scanTimer = nil
	if not StartScanTimer() then
		ns.RunScheduledScan()
	end
end

-- What the scan timer does: wait while the window is still loading, else scan.
function ns.RunScheduledScan()
	if not ns.IsRecipeLookupEnabled() then
		scanForce, notReadyRetries = false, 0
		return
	end
	if not IsWindowReady() and notReadyRetries < MAX_NOT_READY_RETRIES and StartScanTimer() then
		notReadyRetries = notReadyRetries + 1
		return
	end
	local force = scanForce
	scanForce, notReadyRetries = false, 0
	if C_TradeSkillUI then
		ns.ScanRecipes(not force)
	end
end

--------------------------------------------------------------------------------
-- Finding the item
--------------------------------------------------------------------------------

-- Item ID of a shift-clicked link, "item:123" or a plain number; nil for anything else.
local function ParseItemID(text)
	local id = text:match("|Hitem:(%d+)") or text:match("^item:(%d+)") or text:match("^(%d+)$")
	id = tonumber(id)
	if IsID(id) then
		return id
	end
end

-- Saved ingredient names that equal the text, else the ones that contain it. string.lower only changes ASCII letters in
-- this client, so case-insensitivity holds for ASCII; other characters must match as they are.
local function FindItemsByName(text)
	local query = Trim(text)
	query = Trim(query:match("^%[(.*)%]$") or query):lower()
	if query == "" then
		return {}
	end

	local exact, partial = {}, {}
	for itemID, name in pairs(itemNames or {}) do
		local lowered = name:lower()
		if lowered == query then
			exact[#exact + 1] = { itemID = itemID, name = name }
		elseif lowered:find(query, 1, true) then
			partial[#partial + 1] = { itemID = itemID, name = name }
		end
	end
	local matches = #exact > 0 and exact or partial
	table.sort(matches, function(a, b)
		local la, lb = a.name:lower(), b.name:lower()
		if la ~= lb then
			return la < lb
		end
		return a.itemID < b.itemID
	end)
	return matches
end

-- Item ID for a link, an ID or a saved item name. When the text names several items (or none) it returns nil and the
-- list of { itemID, name } candidates.
function ns.ResolveRecipeItem(text)
	if type(text) ~= "string" then
		return nil, {}
	end
	local id = ParseItemID(Trim(text))
	if id then
		return id
	end
	local matches = FindItemsByName(text)
	if #matches == 1 then
		return matches[1].itemID
	end
	return nil, matches
end

-- Recipe IDs (sorted) that use the item.
function ns.GetRecipesUsing(itemID)
	local list = reagentIndex[itemID]
	local copy = {}
	if list then
		for i, recipeID in ipairs(list) do
			copy[i] = recipeID
		end
	end
	return copy
end

-- Opens the profession window on a recipe, the way Blizzard's recipe tracker does. Only for recipes the current
-- character knows; otherwise says who knows it. Returns true when the game was asked to open it.
function ns.OpenRecipeInProfession(entry)
	if type(entry) ~= "table" or type(entry.recipeID) ~= "number" then
		return false
	end
	if not entry.knownHere then
		if entry.known then
			ns.Print(string.format("%s isn't known by this character. Known by: %s.", entry.name, table.concat(entry.knownBy, ", ")))
		else
			ns.Print(string.format("%s isn't known by any of your characters.", entry.name))
		end
		return false
	end
	local open = C_TradeSkillUI and C_TradeSkillUI.OpenRecipe
	if type(open) ~= "function" or not pcall(open, entry.recipeID) then
		ns.Print("Couldn't open the profession window for " .. entry.name .. ".")
		return false
	end
	return true
end

-- The saved recipes a character ("Name-Realm") knows, sorted by recipe ID: { recipeID, name, icon, profession, output,
-- reagents = { [itemID] = quantity }, slots = { { items = { itemID, ... }, quantity } } } (copies; the slots of a recipe
-- saved without them are one per ingredient).
function ns.GetKnownRecipes(character)
	local list = {}
	if not (type(character) == "string" and recipes) then
		return list
	end
	for recipeID, record in pairs(recipes) do
		if (knownBy[recipeID] or {})[character] == true then
			local reagents = {}
			for itemID, quantity in pairs(record.reagents) do
				reagents[itemID] = quantity
			end
			-- Recipes saved before the slots were kept have none: each ingredient then counts as a slot of its own.
			local slots = {}
			for _, slot in ipairs(record.slots or {}) do
				local items = {}
				for i, itemID in ipairs(slot.items) do
					items[i] = itemID
				end
				slots[#slots + 1] = { items = items, quantity = slot.quantity }
			end
			if #slots == 0 then
				for itemID, quantity in pairs(record.reagents) do
					slots[#slots + 1] = { items = { itemID }, quantity = quantity }
				end
				table.sort(slots, function(a, b)
					return a.items[1] < b.items[1]
				end)
			end
			list[#list + 1] = {
				recipeID = recipeID,
				name = record.name,
				icon = record.icon,
				profession = record.profession,
				output = record.output,
				reagents = reagents,
				slots = slots,
			}
		end
	end
	table.sort(list, function(a, b)
		return a.recipeID < b.recipeID
	end)
	return list
end

-- The same for the current character.
function ns.GetKnownRecipesHere()
	return ns.GetKnownRecipes(GetCharacterKey())
end

-- Every character ("Name-Realm") that is saved as knowing a recipe, sorted.
function ns.GetKnownRecipeCharacters()
	local seen, list = {}, {}
	for _, characters in pairs(knownBy or {}) do
		for character in pairs(characters) do
			if not seen[character] then
				seen[character] = true
				list[#list + 1] = character
			end
		end
	end
	table.sort(list)
	return list
end

--------------------------------------------------------------------------------
-- Skill-up chance
--------------------------------------------------------------------------------

-- { yellow, grey } the bundled data has for a recipe, or nil. Green is halfway between them, rounded down.
local function GetThresholds(recipeID)
	local entry = IsID(recipeID) and ns.RecipeThresholds and ns.RecipeThresholds[recipeID] or nil
	if type(entry) == "table" and IsSkillValue(entry[1]) and IsSkillValue(entry[2]) and entry[1] > 0 and entry[2] >= entry[1] then
		return entry[1], entry[2]
	end
end

-- The chance (0 to 1) that crafting a recipe at a skill raises the skill, and the color category ("orange", "yellow", "green" or
-- "grey") it has at that skill, then the thresholds the data has for it (yellow, green, grey; nil without data).
--	difficulty: Enum.TradeskillRelativeDifficulty the client reported at this very skill, or nil when it is not known
--	maxSkill: the highest skill the profession allows now, or nil; there is no skill-up at it
-- Orange is always 100% and grey 0%; yellow and green fall linearly from 100% at the yellow skill to 0% at the grey one (the
-- Classic rule). The chance is nil (and the category the client's) when the data and the client disagree about the color, and
-- when only the client's color is known. Nothing is returned when the skill is unusable or neither says anything.
function ns.GetSkillUpChance(recipeID, skill, difficulty, maxSkill)
	if not IsSkillValue(skill) then
		return nil
	end
	local yellow, grey = GetThresholds(recipeID)
	local green = yellow and math.floor((yellow + grey) / 2) or nil
	local live = not IsSecret(difficulty) and type(difficulty) == "number" and DIFFICULTY_CATEGORIES[difficulty] or nil

	-- No skill-up at the maximum skill, whatever the recipe says.
	if IsSkillValue(maxSkill) and maxSkill > 0 and skill >= maxSkill then
		return 0, "grey", yellow, green, grey
	end

	local category
	if yellow then
		if skill < yellow then
			category = "orange"
		elseif skill >= grey then
			category = "grey"
		elseif skill < green then
			category = "yellow"
		else
			category = "green"
		end
	end

	if live == "grey" then
		return 0, "grey", yellow, green, grey -- the client says nothing is gained, which is certain
	elseif live == "orange" and not yellow then
		return 1, "orange" -- orange is always a sure skill-up
	elseif live and live ~= category then
		return nil, live, yellow, green, grey -- no data, or data that disagrees with the client: trust the client's color only
	elseif not category then
		return nil
	elseif category == "orange" then
		return 1, category, yellow, green, grey
	elseif category == "grey" then
		return 0, category, yellow, green, grey
	end
	local chance = (grey - skill) / (grey - yellow)
	return math.min(1, math.max(0, chance)), category, yellow, green, grey
end

-- The color of a category as r, g, b: the client's own difficulty color when it has one.
function ns.GetSkillUpColor(category)
	local color = DIFFICULTY_COLORS[category] or DIFFICULTY_COLORS.grey
	local global = _G[color.global]
	if type(global) == "table" and not IsSecret(global) then
		local r, g, b = global.r, global.g, global.b
		if type(r) == "number" and type(g) == "number" and type(b) == "number"
			and not IsSecret(r) and not IsSecret(g) and not IsSecret(b) then
			return r, g, b
		end
	end
	return color.fallback[1], color.fallback[2], color.fallback[3]
end

local function ColorCode(category)
	local r, g, b = ns.GetSkillUpColor(category)
	local function Byte(value)
		return math.floor(math.min(1, math.max(0, value)) * 255 + 0.5)
	end
	return string.format("ff%02x%02x%02x", Byte(r), Byte(g), Byte(b))
end

-- "37%" for a chance: rounded, but never 0% or 100% unless it is exactly that ("<1%", "99%").
local function FormatChance(chance)
	local percent = math.floor(chance * 100 + 0.5)
	if chance > 0 and percent < 1 then
		return "<1%"
	elseif chance < 1 and percent > 99 then
		return "99%"
	end
	return percent .. "%"
end

-- What a character's skill-up chance for a recipe of a profession is: { recipeID, character, name (as shown), isOwn, chance,
-- category, skill, max, yellow, green, grey, live (the client's color was used) }, or nil when the character's skill in the
-- profession is not known (or neither the data nor the client says anything about the recipe). It also works for recipes the
-- character does not know (what the chance would be).
local function SkillUpAt(recipeID, profession, character, ownKey, ownRealm)
	local professions = type(character) == "string" and skills[character] or nil
	local saved = professions and professions[profession:lower()] or nil
	if not saved then
		return nil
	end
	-- The client's color only counts at the skill it was read at.
	local live = liveDifficulty[character] and liveDifficulty[character][recipeID] or nil
	local difficulty = live and live.skill == saved.rank and live.difficulty or nil
	local chance, category, yellow, green, grey = ns.GetSkillUpChance(recipeID, saved.rank, difficulty, saved.max)
	if not category then
		return nil
	end
	if ownKey == nil then
		ownKey, ownRealm = GetCharacterKey()
	end
	return {
		recipeID = recipeID, character = character, name = FormatCharacter(character, ownRealm), isOwn = character == ownKey,
		chance = chance, category = category, skill = saved.rank, max = saved.max,
		yellow = yellow, green = green, grey = grey, live = difficulty ~= nil,
	}
end

-- The same for a saved recipe (nil for any other).
function ns.GetRecipeSkillUp(recipeID, character)
	local record = recipes and recipes[recipeID]
	return record and SkillUpAt(recipeID, record.profession, character) or nil
end

-- The skill-up chance to show for a recipe of a profession, among `characters` (a table keyed by "Name-Realm", the characters that
-- know the recipe): the current character's when it is one of them, else the best of the others that have the profession (highest chance; unknown chances last; then by name). The current
-- character's key and realm are optional (they are read when not given).
local function FindBestSkillUp(recipeID, profession, characters, ownKey, ownRealm)
	if ownKey == nil then
		ownKey, ownRealm = GetCharacterKey()
	end
	local own = ownKey and characters[ownKey] and SkillUpAt(recipeID, profession, ownKey, ownKey, ownRealm) or nil
	if own then
		return own
	end
	local best
	for character in pairs(characters) do
		local info = character ~= ownKey and SkillUpAt(recipeID, profession, character, ownKey, ownRealm) or nil
		if info then
			local better = not best
			if best then
				local a, b = info.chance or -1, best.chance or -1
				better = a > b or (a == b and info.character < best.character)
			end
			if better then
				best = info
			end
		end
	end
	return best
end

-- The same for a saved recipe, among the characters that know it.
function ns.GetBestRecipeSkillUp(recipeID)
	local record = recipes and recipes[recipeID]
	return record and FindBestSkillUp(recipeID, record.profession, knownBy[recipeID] or {}) or nil
end

-- "(37%)" in the color of the category ("(?)" when the chance is not known) for ns.GetRecipeSkillUp's answer; nil for no answer.
function ns.FormatSkillUp(info)
	if type(info) ~= "table" then
		return nil
	end
	local text = "(" .. (info.chance and FormatChance(info.chance) or "?") .. ")"
	return "|c" .. ColorCode(info.category) .. text .. "|r"
end

-- Adds the skill-up lines of ns.GetRecipeSkillUp's answer to a tooltip.
function ns.AddSkillUpTooltip(tooltip, info)
	if type(info) ~= "table" or not tooltip then
		return
	end
	local parts = {}
	if info.yellow then
		parts[#parts + 1] = string.format("yellow %d, green %d, grey %d", info.yellow, info.green, info.grey)
	end
	parts[#parts + 1] = string.format("%s skill %d", info.isOwn and "your" or "their", info.skill)
	local label = info.isOwn and "Skill-up chance" or ("Skill-up chance for " .. info.name)
	local value = info.chance and FormatChance(info.chance) or "unknown"
	local r, g, b = ns.GetSkillUpColor(info.category)
	tooltip:AddLine(string.format("%s: %s (%s)", label, value, table.concat(parts, "; ")), r, g, b, true)
	if info.max and info.skill >= info.max then
		tooltip:AddLine(string.format("%s skill is at its maximum (%d); train to learn more.", info.isOwn and "Your" or "Their", info.max), 0.6, 0.6, 0.6, true)
	elseif not info.chance and info.live then
		tooltip:AddLine("The chance is unknown: the game's color and this addon's data do not agree.", 0.6, 0.6, 0.6, true)
	end
end

-- Puts the skill-up text of a row after the recipe's name when both fit in `width`, else at the right end of the name's room.
-- `name` is anchored from `left` to `right` (the region after it), `chance` is a font string; text nil hides it.
function ns.PlaceSkillUpText(name, chance, left, right, width, text)
	name:ClearAllPoints()
	name:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, 0)
	if not text then
		chance:SetText("")
		chance:Hide()
		name:SetPoint("RIGHT", right, "LEFT", -4, 0)
		return
	end
	chance:SetText(text)
	local function Width(fontString)
		local ok, value = pcall(function() return fontString:GetStringWidth() end)
		if ok and not IsSecret(value) and type(value) == "number" and value == value then
			return value
		end
	end
	local nameWidth, chanceWidth = Width(name), Width(chance)
	chance:ClearAllPoints()
	if nameWidth and chanceWidth and nameWidth + CHANCE_GAP + chanceWidth <= width then
		chance:SetPoint("TOPLEFT", name, "TOPLEFT", nameWidth + CHANCE_GAP, 0)
		name:SetPoint("RIGHT", right, "LEFT", -4, 0)
	else
		chance:SetPoint("TOPRIGHT", right, "TOPLEFT", -4, 0)
		name:SetPoint("RIGHT", chance, "LEFT", -4, 0)
	end
	chance:Show()
end

-- The materials of one craft, for the rows: { { items = { itemID, ... }, quantity, highlight } }. Without saved slots (recipes
-- saved before they were kept) it is one entry per ingredient sorted by name; the entry holding the looked-up item is highlighted.
local function BuildMaterials(record, itemID)
	local materials = {}
	if record.slots then
		for _, slot in ipairs(record.slots) do
			local items, highlight = {}, false
			for i, slotItem in ipairs(slot.items) do
				items[i] = slotItem
				if slotItem == itemID then
					highlight = true
				end
			end
			materials[#materials + 1] = { items = items, quantity = slot.quantity, highlight = highlight }
		end
	else
		local keys = {}
		for id, quantity in pairs(record.reagents) do
			materials[#materials + 1] = { items = { id }, quantity = quantity, highlight = id == itemID }
			keys[id] = (ns.GetItemName(id) or ("item:" .. id)):lower()
		end
		table.sort(materials, function(a, b)
			local ka, kb = keys[a.items[1]], keys[b.items[1]]
			if ka ~= kb then
				return ka < kb
			end
			return a.items[1] < b.items[1]
		end)
	end
	return materials
end

-- The rows of the recipes window for an item: every saved recipe that uses it and every bundled recipe that uses it, known
-- recipes first, then by profession and name. { recipeID, name, icon, profession, quantity, output, source, materials, knownBy
-- (names), known, knownHere, skillUp, lines (the skill lines of a recipe the bundle has), saved, nameMissing }.
-- A saved record wins over the bundled data. A bundled recipe nobody knows has no characters (known is false); its name
-- is "Recipe <id>" with nameMissing set while the client has not given the spell's name.
function ns.GetRecipeRows(itemID)
	local rows = {}
	local ownKey, ownRealm = GetCharacterKey()
	local ids, listed = {}, {}
	for _, list in ipairs({ reagentIndex[itemID] or {}, GetBundledUsers(itemID) or {} }) do
		for _, recipeID in ipairs(list) do
			if not listed[recipeID] then
				listed[recipeID] = true
				ids[#ids + 1] = recipeID
			end
		end
	end
	local lineNames, own -- made when the first bundled recipe needs them
	for _, recipeID in ipairs(ids) do
		local record = recipes[recipeID]
		local lines = GetRecipeLines(recipeID)
		local entry
		if record then
			entry = {
				name = record.name,
				icon = record.icon,
				profession = record.profession,
				quantity = record.reagents[itemID],
				output = record.output,
				source = record.source,
				materials = record.reagents[itemID] and BuildMaterials(record, itemID),
				saved = true,
			}
		else
			local reagents, slots = GetBundledReagents(recipeID)
			if reagents and reagents[itemID] then
				if not lineNames then
					own = ReadOwnSets()
					lineNames = BuildLineNames(own)
				end
				local name = ReadSpellName(recipeID)
				local output = GetBundledOutput(recipeID)
				entry = {
					name = name or ("Recipe " .. recipeID),
					nameMissing = name == nil,
					icon = (output and ReadItemIcon(output)) or ReadSpellIcon(recipeID),
					profession = BundledProfession(lines, lineNames, own),
					quantity = reagents[itemID],
					output = output,
					materials = BuildMaterials({ reagents = reagents, slots = slots }, itemID),
					saved = false,
				}
			end
		end
		if entry and entry.quantity then
			local characters = {}
			local knowers = knownBy[recipeID]
			for character in pairs(knowers or {}) do
				characters[#characters + 1] = FormatCharacter(character, ownRealm)
			end
			table.sort(characters, function(a, b)
				local la, lb = a:lower(), b:lower()
				if la ~= lb then
					return la < lb
				end
				return a < b
			end)
			entry.recipeID = recipeID
			entry.knownBy = characters
			entry.known = #characters > 0
			entry.knownHere = ownKey ~= nil and (knowers or {})[ownKey] == true
			entry.lines = lines
			-- Only for the characters that know it: a recipe nobody knows shows no chance (the data does not say what skill it
			-- needs to be learned, so a chance for a character that cannot learn it yet would be wrong).
			entry.skillUp = entry.known and FindBestSkillUp(recipeID, entry.profession, knowers, ownKey, ownRealm) or nil
			rows[#rows + 1] = entry
		end
	end
	table.sort(rows, function(a, b)
		if a.known ~= b.known then
			return a.known
		end
		local pa, pb = a.profession:lower(), b.profession:lower()
		if pa ~= pb then
			return pa < pb
		end
		local na, nb = a.name:lower(), b.name:lower()
		if na ~= nb then
			return na < nb
		end
		return a.recipeID < b.recipeID
	end)
	return rows
end

--------------------------------------------------------------------------------
-- Hovered item
--------------------------------------------------------------------------------

local function GetTooltipKind(tooltip)
	if tooltip == GameTooltip then
		return "game"
	elseif ItemRefTooltip and tooltip == ItemRefTooltip then
		return "ref"
	end
end

-- Item tooltip post-call: remembers which item the main tooltips show. Comparison tooltips are ignored.
local function OnTooltipSetItem(tooltip, data)
	if not tooltip or IsSecret(tooltip) then
		return
	end
	local kind = GetTooltipKind(tooltip)
	if not kind then
		return
	end
	data = PlainTable(data)
	local itemID
	if data then
		if IsID(data.id) then
			itemID = data.id
		elseif PlainString(data.hyperlink) then
			itemID = ParseItemID(data.hyperlink)
		end
	end
	hovered[kind] = itemID
end

local function WatchTooltip(tooltip, kind)
	if not (tooltip and tooltip.HookScript) then
		return
	end
	local function Forget()
		hovered[kind] = nil
	end
	-- Not every client has every script; a missing one is simply not hooked.
	pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", Forget)
	pcall(tooltip.HookScript, tooltip, "OnHide", Forget)
end

-- Item ID of the item whose tooltip is on screen, or nil.
function ns.GetHoveredItemID()
	local tooltips = { game = GameTooltip, ref = ItemRefTooltip }
	for _, kind in ipairs({ "game", "ref" }) do
		local tooltip = tooltips[kind]
		if hovered[kind] and tooltip and tooltip:IsShown() then
			return hovered[kind]
		end
	end
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function SetWindowTitle(frame, text)
	local container = frame.TitleContainer
	if container and container.TitleText then
		container.TitleText:SetText(text)
	elseif type(frame.SetTitle) == "function" then
		frame:SetTitle(text)
	else
		if not frame.titleText then
			frame.titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			frame.titleText:SetPoint("TOP", frame, "TOP", 0, -5)
		end
		frame.titleText:SetText(text)
	end
end

-- "Silverleaf x1" for one entry of a row's materials, or "Silverleaf (1/3)" when you have some but not enough (owned is
-- optional); a slot with several choices says "(any quality)" after the name of the first one. The name is "item:<id>"
-- until the client has given it.
local function FormatMaterial(material, owned)
	local itemID = material.items[1]
	local text = ns.GetItemName(itemID) or ("item:" .. itemID)
	if #material.items > 1 then
		text = text .. " (any quality)"
	end
	if owned and owned > 0 and owned < material.quantity then
		return text .. " (" .. owned .. "/" .. material.quantity .. ")"
	end
	return text .. " x" .. material.quantity
end

-- How many of an item the current character has: bags, bank, reagent bank and account bank (bank counts may be from
-- the last visit). 0 when the client does not tell.
local function OwnedCount(itemID)
	local ok, count
	if C_Item and C_Item.GetItemCount then
		ok, count = pcall(C_Item.GetItemCount, itemID, true, false, true, true)
	end
	if not ok and GetItemCount then
		ok, count = pcall(GetItemCount, itemID, true)
	end
	if not ok or IsSecret(count) or type(count) ~= "number" then
		return 0
	end
	return count
end

-- What the current character has of a material (all its interchangeable items together), cached per refresh.
local function MaterialOwned(material, cache)
	local total = 0
	for _, itemID in ipairs(material.items) do
		local count = cache and cache[itemID]
		if not count then
			count = OwnedCount(itemID)
			if cache then
				cache[itemID] = count
			end
		end
		total = total + count
	end
	return total
end

-- Color of a material for what you have of it: green when enough for one craft, orange when some, red when none.
local function MaterialColor(owned, quantity)
	if owned >= quantity then
		return ENOUGH_TEXT_COLOR
	elseif owned > 0 then
		return MISSING_TEXT_COLOR
	end
	return NONE_TEXT_COLOR
end

-- The materials of a row as one colored text.
local function FormatMaterials(materials, cache)
	local parts = {}
	for i, material in ipairs(materials) do
		local owned = MaterialOwned(material, cache)
		parts[i] = "|c" .. MaterialColor(owned, material.quantity) .. FormatMaterial(material, owned) .. "|r"
	end
	return table.concat(parts, "|c" .. GREY_TEXT_COLOR .. ", |r")
end

-- Asks the client for the names of the materials it has not given yet (once each: the ones already asked for arrive with
-- ITEM_DATA_LOAD_RESULT, which refreshes the window).
local function RequestMaterialNames(entries)
	local missing
	for _, entry in ipairs(entries) do
		for _, material in ipairs(entry.materials) do
			local itemID = material.items[1]
			if not pendingNames[itemID] and not ns.GetItemName(itemID) then
				missing = missing or {}
				missing[itemID] = true
			end
		end
	end
	if missing then
		FillItemNames(missing)
	end
end

local NOT_KNOWN_TEXT = "Not known by your characters"

local function FormatDetail(row)
	local status
	if row.known then
		status = "|c" .. KNOWN_TEXT_COLOR .. "Known: " .. table.concat(row.knownBy, ", ") .. "|r"
	else
		status = "|c" .. UNKNOWN_TEXT_COLOR .. NOT_KNOWN_TEXT .. "|r"
	end
	return "|c" .. GREY_TEXT_COLOR .. row.profession .. "|r  " .. status
end

-- The profession filter bar of the results windows (this one and the materials window): an "All" button, then one button per
-- profession found in the unfiltered results, sorted by name, in rows that wrap at the width given. It hides itself when
-- the results hold fewer than two professions. The selection (nil is "All") lives with the bar, so it is kept for the session
-- only; a profession that is gone from the results falls back to "All". Professions are compared without regard to case and
-- labeled with the first spelling seen.
--	options: parent (the window), left and top (where the bar starts), width (room for a row), listTop (where the list starts
--	when there is no bar; with a bar it starts below it), onChange (called after a click changed the selection) and hidden
--	(optional: returns the set of professions hidden in the settings, { [lowercase profession] = true }).
--	The caller drops the entries of hidden professions before it calls Update, so the bar is built from what is left.
--	filter:Update(names, hiddenCounts) lays the buttons out for the professions named (duplicates allowed) and returns the
--	distance from the top of the window to the list, which the caller sets as the top of its scroll frame (every refresh).
--	hiddenCounts (optional) is { [lowercase profession] = number of that profession's recipes the caller dropped }.
--	filter:Matches(profession) tells whether a recipe of that profession passes the current selection.
--	Info line: a small line at the top of the bar's area, shown while the bar is shown or a profession is hidden. Grey, it says
--	that professions can be hidden in the settings; with hidden professions it is orange and names them, each followed by
--	" x2" (the recipes dropped) when it had any; those come first. The bar and the list
--	start below it (filter.infoHeight is its height, 0 when it is not shown).
local FILTER_BUTTON_HEIGHT = 18
local FILTER_BUTTON_MIN_WIDTH = 40
local FILTER_BUTTON_PADDING = 16 -- added to the text width
local FILTER_GAP_X = 4
local FILTER_GAP_Y = 2
local FILTER_LIST_GAP = 4 -- between the last row of buttons and the list
local FILTER_INFO_MIN_HEIGHT = 12 -- one line of the small font
local FILTER_INFO_GAP = 2 -- between the info line and the bar
local FILTER_INFO_HINT = "Professions can be hidden permanently in the settings (/ju)."
local FILTER_INFO_HIDDEN = "Hidden in the settings: "
local FILTER_INFO_GREY = { 0.5, 0.5, 0.5 }
-- The orange of MISSING_TEXT_COLOR as red, green and blue fractions.
local FILTER_INFO_ORANGE = {
	tonumber(MISSING_TEXT_COLOR:sub(3, 4), 16) / 255,
	tonumber(MISSING_TEXT_COLOR:sub(5, 6), 16) / 255,
	tonumber(MISSING_TEXT_COLOR:sub(7, 8), 16) / 255,
}

-- "Hidden in the settings: Alchemy x2, Cooking", or, when the list would be long, "... Alchemy x2, Cooking and 3 more" (at least
-- one label is always shown). `names` holds the labels in the order to show; `fits(text)` tells whether a text is no wider than
-- the line. The first `keep` labels (the professions with hidden recipes) are never cut: when they alone do not fit, the line
-- wraps instead.
local function FormatHiddenInfo(names, fits, keep)
	local count = #names
	local text
	for shown = count, math.max(1, math.min(keep or 0, count)), -1 do
		local list = {}
		for index = 1, shown do
			list[index] = (names[index]:gsub("|", "||")) -- the text reads escape codes
		end
		text = FILTER_INFO_HIDDEN .. table.concat(list, ", ") .. (shown < count and (" and " .. (count - shown) .. " more") or "")
		if fits(text) then
			break
		end
	end
	return text
end

function ns.CreateProfessionFilter(options)
	local filter = { selected = nil, height = 0, buttons = {} }
	local parent = options.parent
	-- Text is measured on a font string of the buttons' font; a button's own text may not be sized yet.
	local measure = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	measure:Hide()

	-- The info line above the bar. No fixed height: it is as tall as its wrapped text (one line when the wording fits).
	local info = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	info:SetPoint("TOPLEFT", parent, "TOPLEFT", options.left, -options.top)
	info:SetWidth(options.width)
	info:SetJustifyH("LEFT")
	info:SetJustifyV("TOP")
	info:SetWordWrap(true)
	info:Hide()
	filter.info = info
	filter.infoHeight = 0
	-- The width of a candidate text is measured on a hidden font string of the same font, against the width of the line.
	local infoMeasure = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	infoMeasure:Hide()
	local function InfoFits(text)
		infoMeasure:SetText(text)
		local width = infoMeasure:GetStringWidth()
		return type(width) ~= "number" or width <= options.width
	end

	local function AcquireButton(index)
		local button = filter.buttons[index]
		if button then
			return button
		end
		button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		button:SetHeight(FILTER_BUTTON_HEIGHT)
		button:SetNormalFontObject("GameFontNormalSmall")
		button:SetScript("OnClick", function(self)
			filter.selected = self.key
			if options.onChange then
				options.onChange()
			end
		end)
		button:SetScript("OnEnter", function(self)
			if GameTooltip then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(self.key and ("Show only " .. self.text .. " recipes") or "Show all recipes")
				GameTooltip:Show()
			end
		end)
		button:SetScript("OnLeave", function()
			if GameTooltip then
				GameTooltip:Hide()
			end
		end)
		filter.buttons[index] = button
		return button
	end

	function filter:Matches(profession)
		return self.selected == nil or ns.ProfessionKey(profession) == self.selected
	end

	function filter:Update(names, hiddenCounts)
		-- One entry per profession, whatever the case: { key = lowercase, label = the saved spelling }
		local found, list = {}, {}
		for _, name in ipairs(names) do
			local key = ns.ProfessionKey(name)
			if key and not found[key] then
				found[key] = true
				list[#list + 1] = { key = key, label = Trim(name) }
			end
		end
		table.sort(list, function(a, b)
			if a.key ~= b.key then
				return a.key < b.key
			end
			return a.label < b.label
		end)
		-- A profession that is gone from the results, or a bar with nothing to choose from, goes back to "All".
		if #list < 2 or (self.selected and not found[self.selected]) then
			self.selected = nil
		end

		-- The info line: orange with the hidden professions, else grey while the bar is shown, else not at all.
		local hidden = options.hidden and options.hidden() or nil
		local hiddenNames = hidden and next(hidden) ~= nil and ns.GetHiddenProfessionNames(hidden) or {}
		if #hiddenNames > 0 then
			-- Professions with dropped recipes first ("Alchemy x2"), then the others; each group stays sorted by name.
			local counted, plain = {}, {}
			local keep
			for _, name in ipairs(hiddenNames) do
				local count = hiddenCounts and hiddenCounts[ns.ProfessionKey(name) or ""]
				if type(count) == "number" and count > 0 then
					counted[#counted + 1] = name .. " x" .. count
				else
					plain[#plain + 1] = name
				end
			end
			keep = #counted
			for _, name in ipairs(plain) do
				counted[#counted + 1] = name
			end
			info:SetText(FormatHiddenInfo(counted, InfoFits, keep))
			info:SetTextColor(FILTER_INFO_ORANGE[1], FILTER_INFO_ORANGE[2], FILTER_INFO_ORANGE[3])
		elseif #list >= 2 then
			info:SetText(FILTER_INFO_HINT)
			info:SetTextColor(FILTER_INFO_GREY[1], FILTER_INFO_GREY[2], FILTER_INFO_GREY[3])
		end
		local barTop = options.top
		if #hiddenNames > 0 or #list >= 2 then
			local textHeight = info:GetStringHeight()
			self.infoHeight = math.max(FILTER_INFO_MIN_HEIGHT, math.ceil(type(textHeight) == "number" and textHeight or 0))
			info:Show()
			barTop = options.top + self.infoHeight + FILTER_INFO_GAP
		else
			self.infoHeight = 0
			info:Hide()
		end

		if #list < 2 then
			self.height = 0
			for _, button in ipairs(self.buttons) do
				button:Hide()
			end
			if self.infoHeight > 0 then
				return options.top + self.infoHeight + FILTER_LIST_GAP
			end
			return options.listTop
		end

		table.insert(list, 1, { key = nil, label = "All" })
		local x, row = 0, 0
		for index, item in ipairs(list) do
			local button = AcquireButton(index)
			local text = item.label:gsub("|", "||") -- the text of a button and a tooltip reads escape codes
			button.key, button.text = item.key, text
			button:SetText(text)
			measure:SetText(text)
			local width = math.max(FILTER_BUTTON_MIN_WIDTH, math.ceil(measure:GetStringWidth() or 0) + FILTER_BUTTON_PADDING)
			button:SetWidth(width)
			if x > 0 and x + width > options.width then
				x = 0
				row = row + 1
			end
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", parent, "TOPLEFT", options.left + x, -(barTop + row * (FILTER_BUTTON_HEIGHT + FILTER_GAP_Y)))
			x = x + width + FILTER_GAP_X
			if item.key == self.selected then
				button:LockHighlight()
			else
				button:UnlockHighlight()
			end
			button:Show()
		end
		for index = #list + 1, #self.buttons do
			self.buttons[index]:Hide()
		end
		self.height = (row + 1) * FILTER_BUTTON_HEIGHT + row * FILTER_GAP_Y
		return barTop + self.height + FILTER_LIST_GAP
	end

	return filter
end

local function AcquireRow(index)
	local row = ui.rows[index]
	if row then
		return row
	end

	row = {}
	-- A Button, so the row gets OnDoubleClick (opens the recipe in the profession window).
	row.frame = CreateFrame("Button", nil, ui.scrollChild)
	row.frame:SetSize(LIST_WIDTH, ROW_TOP_HEIGHT + MATERIALS_MIN_HEIGHT + ROW_BOTTOM_PADDING)
	row.frame:EnableMouse(true)
	if row.frame.RegisterForClicks then
		row.frame:RegisterForClicks("LeftButtonUp")
	end
	row.frame:SetScript("OnDoubleClick", function()
		if row.entry then
			ns.OpenRecipeInProfession(row.entry)
		end
	end)

	row.icon = row.frame:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
	row.icon:SetPoint("TOPLEFT", row.frame, "TOPLEFT", 2, -4)

	row.qty = row.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.qty:SetPoint("TOPRIGHT", row.frame, "TOPRIGHT", -4, -4)
	row.qty:SetWidth(QTY_WIDTH)
	row.qty:SetHeight(14)
	row.qty:SetJustifyH("RIGHT")

	row.name = row.frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
	row.name:SetPoint("RIGHT", row.qty, "LEFT", -4, 0)
	row.name:SetHeight(14)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	-- The skill-up chance, after the name (or at the end of its room when the name is long); it brings its own colors.
	row.chance = row.frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.chance:SetHeight(14)
	row.chance:SetJustifyH("LEFT")
	row.chance:SetWordWrap(false)
	row.chance:Hide()

	row.detail = row.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
	row.detail:SetPoint("RIGHT", row.frame, "RIGHT", -(LINK_BUTTON_WIDTH + 8), 0)
	row.detail:SetHeight(DETAIL_HEIGHT)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetJustifyV("MIDDLE")
	row.detail:SetWordWrap(false)

	-- The materials of one craft, under the name and the detail line; it wraps and the row grows with it.
	row.materials = row.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.materials:SetPoint("TOPLEFT", row.frame, "TOPLEFT", 4, -ROW_TOP_HEIGHT)
	row.materials:SetWidth(MATERIALS_WIDTH)
	row.materials:SetJustifyH("LEFT")
	row.materials:SetJustifyV("TOP")
	row.materials:SetWordWrap(true)

	-- Shows the Wowhead links of the recipe; the detail text beside it stops before it.
	row.link = CreateFrame("Button", nil, row.frame, "UIPanelButtonTemplate")
	row.link:SetSize(LINK_BUTTON_WIDTH, LINK_BUTTON_HEIGHT)
	row.link:SetPoint("TOPRIGHT", row.frame, "TOPRIGHT", -4, -(ROW_TOP_HEIGHT - LINK_BUTTON_HEIGHT - 2))
	row.link:SetNormalFontObject("GameFontNormalSmall")
	row.link:SetText("Wowhead")
	row.link:SetScript("OnClick", function()
		if row.entry then
			ns.ShowWowheadLinks(row.entry.recipeID, row.entry.name, row.entry.profession)
		end
	end)

	-- The tooltip of what the recipe makes, or of the recipe itself when it makes no item.
	row.frame:SetScript("OnEnter", function(self)
		local entry = row.entry
		if not (entry and GameTooltip) then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if entry.output and GameTooltip.SetItemByID then
			pcall(GameTooltip.SetItemByID, GameTooltip, entry.output)
		elseif GameTooltip.SetSpellByID then
			pcall(GameTooltip.SetSpellByID, GameTooltip, entry.recipeID)
		end
		-- The detail line of the row may be cut short, so the tooltip carries the characters and the whole list of materials.
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Materials for one craft:", 1, 1, 1)
		for _, material in ipairs(entry.materials) do
			local owned = MaterialOwned(material)
			local text = FormatMaterial(material) .. " (you have " .. owned .. ")"
			if owned >= material.quantity then
				GameTooltip:AddLine(text, 0.25, 1, 0.25, true)
			elseif owned > 0 then
				GameTooltip:AddLine(FormatMaterial(material, owned), 1, 0.56, 0.13, true)
			else
				GameTooltip:AddLine(text, 1, 0.19, 0.19, true)
			end
		end
		if entry.skillUp then
			GameTooltip:AddLine(" ")
			ns.AddSkillUpTooltip(GameTooltip, entry.skillUp)
		end
		-- Only when the game gave one.
		if entry.source then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Where to get it:", 1, 0.6, 0.2)
			GameTooltip:AddLine(entry.source, 1, 1, 1, true)
		end
		GameTooltip:AddLine(" ")
		if entry.known then
			GameTooltip:AddLine("Known by: " .. table.concat(entry.knownBy, ", "), 0.2, 1, 0.2, true)
		else
			GameTooltip:AddLine(NOT_KNOWN_TEXT .. ".", 1, 0.6, 0.2, true)
		end
		if entry.knownHere then
			GameTooltip:AddLine("Double-click to open it in your profession window.", 0.6, 0.8, 1, true)
		end
		GameTooltip:Show()
	end)
	row.frame:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)

	ui.rows[index] = row
	return row
end

local EMPTY_TEXT = "No recipes use this item."
local EMPTY_HIDDEN_TEXT = "The recipes that use this item are all hidden by the profession settings (/ju)."
local EMPTY_NOT_MINE_TEXT = "None of these recipes belong to your professions."

-- Puts the top of the list `top` below the top of the window (it moves down with the filter bar).
local function PlaceScroll(top)
	ui.scroll:ClearAllPoints()
	ui.scroll:SetPoint("TOPLEFT", window, "TOPLEFT", LIST_LEFT, -top)
	ui.scroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -36, 36)
end

-- Asks the client for the spell names of the bundled recipes it has not given yet (a few times per spell and session; the answer
-- is SPELL_DATA_LOAD_RESULT, which refreshes the window, and a timer asks again for the ones that never came).
local function RequestSpellNames(entries)
	local asked = false
	for _, entry in ipairs(entries) do
		local recipeID = entry.recipeID
		if entry.nameMissing and not viewPending[recipeID] then
			local attempts = viewAttempts[recipeID] or 0
			if attempts < MAX_LEARN_RETRIES then
				viewAttempts[recipeID] = attempts + 1
				viewPending[recipeID] = true
				if C_Spell and C_Spell.RequestLoadSpellData then
					pcall(C_Spell.RequestLoadSpellData, recipeID)
				end
				asked = true
			end
		end
	end
	if asked and not viewRetryPending and C_Timer and C_Timer.After then
		viewRetryPending = true
		C_Timer.After(NAME_RETRY_DELAY, function()
			viewRetryPending = false
			Wipe(viewPending)
			InvalidateRows() -- a name may be there without its event
			if window and window:IsShown() then
				RefreshWindow()
			end
		end)
	end
end

-- SPELL_DATA_LOAD_RESULT: a spell name the window asked for is there; the window is refreshed once for a burst of answers.
local function OnViewSpellLoaded(spellID, success)
	if IsSecret(spellID) or IsSecret(success) or not viewPending[spellID] then
		return
	end
	viewPending[spellID] = nil
	if success ~= true then
		return
	end
	InvalidateRows()
	if viewRefreshPending then
		return
	end
	local function Refresh()
		viewRefreshPending = false
		if window and window:IsShown() then
			RefreshWindow()
		end
	end
	if C_Timer and C_Timer.After then
		viewRefreshPending = true
		C_Timer.After(0, Refresh)
	else
		Refresh()
	end
end

-- The label of the "only my professions" check box: "Only <name>'s professions", or "Only my professions" when that would be cut.
local function UpdateOnlyMineLabel()
	local key = GetCharacterKey()
	local name = key and key:match("^([^%-]+)")
	local label = "Only my professions"
	if name then
		local long = "Only " .. (name:gsub("|", "||")) .. "'s professions"
		ui.measure:SetText(long)
		local width = ui.measure:GetStringWidth()
		if type(width) ~= "number" or width <= CHECK_LABEL_WIDTH then
			label = long
		end
	end
	ui.onlyMine.Text:SetText(label)
end

RefreshWindow = function()
	if not ui or not ui.itemID then
		return
	end
	local itemID = ui.itemID
	local itemName = ns.GetItemName(itemID) or ("Item " .. itemID)

	SetWindowTitle(window, "Recipes using " .. itemName)
	ui.itemIcon:SetTexture(ReadItemIcon(itemID) or QUESTION_ICON)
	ui.itemName:SetText(itemName)

	local found
	if rowCache and rowCache.itemID == itemID then
		found = rowCache.rows
	else
		found = ns.GetRecipeRows(itemID)
		rowCache = { itemID = itemID, rows = found }
	end
	RequestSpellNames(found)
	-- "Only my professions" is applied first; everything below works on what it leaves.
	local onlyMine = lookup ~= nil and lookup.onlyMyProfessions == true
	ui.onlyMine:SetChecked(onlyMine)
	UpdateOnlyMineLabel()
	local pool = found
	local own = onlyMine and ReadOwnSets() or nil
	if own and own.readable then -- (without the professions there is nothing to filter by: everything is shown)
		pool = {}
		for _, entry in ipairs(found) do
			if IsOwnRecipe(entry, own) then
				pool[#pool + 1] = entry
			end
		end
	end
	-- Professions hidden in the settings are dropped next; everything below works on what is left.
	local hidden = ns.GetHiddenRecipeProfessions()
	local all, hiddenCounts = {}, {} -- hiddenCounts: recipes dropped per hidden profession
	for _, entry in ipairs(pool) do
		local key = ns.ProfessionKey(entry.profession) or ""
		if hidden[key] then
			hiddenCounts[key] = (hiddenCounts[key] or 0) + 1
		else
			all[#all + 1] = entry
		end
	end
	RequestMaterialNames(all)
	-- The filter bar offers the professions of every result left; the list shows the selected one. The list moves down with
	-- the info line and the bar.
	local professions = {}
	for _, entry in ipairs(all) do
		professions[#professions + 1] = entry.profession
	end
	PlaceScroll(ui.filter:Update(professions, hiddenCounts))
	local entries = {}
	for _, entry in ipairs(all) do
		if ui.filter:Matches(entry.profession) then
			entries[#entries + 1] = entry
		end
	end
	local child = ui.scrollChild
	child:SetWidth(LIST_WIDTH)
	local top = 0
	local owned = {} -- item counts, asked once per refresh
	for i, entry in ipairs(entries) do
		local row = AcquireRow(i)
		row.entry = entry
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -top)
		row.icon:SetTexture(entry.icon or QUESTION_ICON)
		row.name:SetText(entry.name)
		local color = entry.known and KNOWN_NAME_COLOR or UNKNOWN_NAME_COLOR
		row.name:SetTextColor(color[1], color[2], color[3])
		row.qty:SetText("x" .. entry.quantity)
		ns.PlaceSkillUpText(row.name, row.chance, row.icon, row.qty, ROW_NAME_AREA, ns.FormatSkillUp(entry.skillUp))
		row.detail:SetText(FormatDetail(entry))
		row.materials:SetText(FormatMaterials(entry.materials, owned))
		-- The row is as tall as its materials need, so a long list is never cut off or drawn over the next row.
		local textHeight = math.max(MATERIALS_MIN_HEIGHT, math.ceil(row.materials:GetStringHeight() or 0))
		local height = ROW_TOP_HEIGHT + textHeight + ROW_BOTTOM_PADDING
		row.frame:SetHeight(height)
		row.frame:Show()
		top = top + height
	end
	for i = #entries + 1, #ui.rows do
		ui.rows[i].entry = nil
		ui.rows[i].frame:Hide()
	end
	child:SetHeight(math.max(ROW_TOP_HEIGHT + MATERIALS_MIN_HEIGHT + ROW_BOTTOM_PADDING, top))
	ui.entries = entries
	-- Nothing left because of the check box or the hidden professions is not a missing-data problem: another text, grey like other notices.
	if #entries == 0 and #found > 0 and #pool == 0 then
		ui.emptyText:SetText(EMPTY_NOT_MINE_TEXT)
		ui.emptyText:SetTextColor(0.5, 0.5, 0.5)
	elseif #entries == 0 and #pool > 0 and #all == 0 then
		ui.emptyText:SetText(EMPTY_HIDDEN_TEXT)
		ui.emptyText:SetTextColor(0.5, 0.5, 0.5)
	else
		ui.emptyText:SetText(EMPTY_TEXT)
		ui.emptyText:SetTextColor(1, 0.19, 0.19)
	end
	ui.emptyText:SetShown(#entries == 0)

	local total, professions = ns.GetRecipeSummary()
	if total == 0 then
		ui.footer:SetText("No recipes saved yet")
	else
		local names = {}
		for _, profession in ipairs(professions) do
			names[#names + 1] = profession.name
		end
		ui.footer:SetText(string.format("%d recipe%s saved from %s", total, total == 1 and "" or "s", table.concat(names, ", ")))
	end
end

-- What BAG_UPDATE_DELAYED does: the rows are the same, only what the character has of each material changed, so only the colors (and
-- the heights, when a text wraps differently) of the rows shown are recomputed.
local function RefreshOwnedCounts()
	local entries = ui and ui.itemID and ui.entries
	if not (entries and rowCache and rowCache.itemID == ui.itemID) then
		RefreshWindow()
		return
	end
	local owned, moved = {}, false
	for i, entry in ipairs(entries) do
		local row = ui.rows[i]
		row.materials:SetText(FormatMaterials(entry.materials, owned))
		local height = ROW_TOP_HEIGHT + math.max(MATERIALS_MIN_HEIGHT, math.ceil(row.materials:GetStringHeight() or 0)) + ROW_BOTTOM_PADDING
		if height ~= row.frame:GetHeight() then
			row.frame:SetHeight(height)
			moved = true
		end
	end
	if moved then
		local top = 0
		for i = 1, #entries do
			local row = ui.rows[i]
			row.frame:ClearAllPoints()
			row.frame:SetPoint("TOPLEFT", ui.scrollChild, "TOPLEFT", 0, -top)
			top = top + row.frame:GetHeight()
		end
		ui.scrollChild:SetHeight(math.max(ROW_TOP_HEIGHT + MATERIALS_MIN_HEIGHT + ROW_BOTTOM_PADDING, top))
	end
end

local function BuildWindow()
	if window then
		return
	end

	window = CreateFrame("Frame", FRAME_NAME, UIParent, "DefaultPanelFlatTemplate")
	if ns.MakeOpaque then ns.MakeOpaque(window) end
	local frame = window
	-- New frames start shown; hide it so the first Show() fires OnShow.
	frame:Hide()
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	SetWindowTitle(frame, "Recipes")

	-- Escape closes the window, like Blizzard's own panels.
	if UISpecialFrames and not tContains(UISpecialFrames, FRAME_NAME) then
		table.insert(UISpecialFrames, FRAME_NAME)
	end

	ui = { rows = {} }

	-- The title strip drags the window.
	local drag = CreateFrame("Frame", nil, frame)
	drag:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -26, 0)
	drag:SetHeight(24)
	drag:SetFrameLevel(frame:GetFrameLevel() + 5)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	drag:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
	end)

	ui.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	ui.closeButton:SetSize(24, 24)
	ui.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

	-- Header: the item the list is about
	ui.itemIcon = frame:CreateTexture(nil, "ARTWORK")
	ui.itemIcon:SetSize(HEADER_ICON_SIZE, HEADER_ICON_SIZE)
	ui.itemIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -32)

	ui.itemName = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	ui.itemName:SetPoint("LEFT", ui.itemIcon, "RIGHT", 8, 0)
	ui.itemName:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	ui.itemName:SetHeight(HEADER_ICON_SIZE)
	ui.itemName:SetJustifyH("LEFT")
	ui.itemName:SetWordWrap(false)

	-- Only the recipes of the professions the current character has. A row of its own under the header; the info line, the bar and
	-- the list start below it.
	ui.onlyMine = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	ui.onlyMine:SetSize(CHECK_SIZE, CHECK_SIZE)
	ui.onlyMine:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -CHECK_TOP)
	ui.onlyMine.Text:SetFontObject("GameFontHighlightSmall")
	ui.onlyMine.Text:SetWidth(CHECK_LABEL_WIDTH)
	ui.onlyMine.Text:SetWordWrap(false)
	ui.onlyMine.Text:SetJustifyH("LEFT")
	ui.onlyMine.Text:SetText("Only my professions")
	ui.measure = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall") -- measures the label
	ui.measure:Hide()
	ui.onlyMine:SetScript("OnClick", function(self)
		if lookup then
			lookup.onlyMyProfessions = self:GetChecked() and true or false
		end
		ui.scroll:SetVerticalScroll(0)
		RefreshWindow()
	end)
	ui.onlyMine:HookScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Only my professions")
			GameTooltip:AddLine("Only list the recipes of the professions this character has. Saved for all your characters.", 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end
	end)
	ui.onlyMine:HookScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)

	-- List. Named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.scroll = CreateFrame("ScrollFrame", SCROLL_NAME, frame, "UIPanelScrollFrameTemplate")
	PlaceScroll(LIST_TOP)

	-- Filter bar between the header and the list; it only shows when the results hold more than one profession.
	ui.filter = ns.CreateProfessionFilter({
		parent = frame, left = 16, top = FILTER_TOP, width = FRAME_WIDTH - 32, listTop = LIST_TOP,
		hidden = ns.GetHiddenRecipeProfessions,
		onChange = function()
			ui.scroll:SetVerticalScroll(0)
			RefreshWindow()
		end,
	})

	ui.scrollChild = CreateFrame("Frame", nil, ui.scroll)
	ui.scrollChild:SetSize(LIST_WIDTH, ROW_TOP_HEIGHT + MATERIALS_MIN_HEIGHT + ROW_BOTTOM_PADDING)
	ui.scroll:SetScrollChild(ui.scrollChild)
	ui.emptyText = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.emptyText:SetPoint("TOPLEFT", ui.scrollChild, "TOPLEFT", 4, -4)
	ui.emptyText:SetWidth(LIST_WIDTH - 12)
	ui.emptyText:SetJustifyH("LEFT")
	ui.emptyText:SetJustifyV("TOP")
	ui.emptyText:SetText(EMPTY_TEXT)
	ui.emptyText:SetTextColor(1, 0.19, 0.19)
	ui.emptyText:Hide()

	ui.footer = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 14)
	ui.footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 14)
	ui.footer:SetHeight(14)
	ui.footer:SetJustifyH("LEFT")
	ui.footer:SetWordWrap(false)

	frame:SetScript("OnShow", RefreshWindow)
	frame:SetScript("OnHide", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
end

-- Opens the window with the recipes that use the item.
function ns.ShowRecipes(itemID)
	if not IsID(itemID) or not ns.IsRecipeLookupEnabled() then
		return false
	end
	BuildWindow()
	if ui.itemID ~= itemID then
		ui.scroll:SetVerticalScroll(0)
		ui.filter.selected = nil -- a new item starts unfiltered
	end
	ui.itemID = itemID
	InvalidateRows() -- the rows are built again when the window is opened on an item
	if window:IsShown() then
		RefreshWindow()
	else
		window:Show() -- OnShow refreshes
	end
	window:Raise()
	return true
end

-- Window and widget table, for tests.
function ns.GetRecipesWindow()
	return window, ui
end

--------------------------------------------------------------------------------
-- Wowhead links
--------------------------------------------------------------------------------

-- The client cannot open web pages, so the links are shown in a small window to copy from.

local function StripColors(text)
	text = tostring(text or "")
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")
	return Trim(text)
end

-- Text for a URL: color codes removed, spaces as +, every other byte that is not a letter or digit as %XX (UTF-8 bytes).
function ns.EncodeUrlText(text)
	text = StripColors(text)
	return (text:gsub("[^A-Za-z0-9]", function(char)
		if char == " " then
			return "+"
		end
		return string.format("%%%02X", char:byte())
	end))
end

-- Name of the item that teaches a recipe, "<prefix>: <recipe name>" (for example "Recipe: Minor Healing Potion"), or nil when
-- the profession is not one with a known prefix.
function ns.GetRecipeItemName(name, profession)
	if type(profession) ~= "string" then
		return nil
	end
	local prefix = RECIPE_ITEM_PREFIXES[StripColors(profession):lower()]
	name = StripColors(name)
	if not prefix or name == "" then
		return nil
	end
	return prefix .. ": " .. name
end

-- Page of the recipe's spell (nil without a recipe ID), the page of the item that teaches it when the bundled data knows it
-- (Data/RecipeData.lua) or else a search for that item (its plain name when the profession has no known prefix), whether that
-- is a search for the item's name, and the ID of the teaching item (nil when it is not known). A recipe the bundled data knows
-- without a teaching item is taught by a trainer: there is no item to search for, so the second URL is nil.
function ns.GetWowheadUrls(recipeID, name, profession)
	local spellUrl
	if IsID(recipeID) then
		spellUrl = WOWHEAD_BASE .. "spell=" .. string.format("%d", recipeID)
	end
	local teacher = IsID(recipeID) and ns.RecipeTeachers and ns.RecipeTeachers[recipeID] or nil
	if IsID(teacher) then
		return spellUrl, WOWHEAD_BASE .. "item=" .. string.format("%d", teacher), false, teacher
	end
	if IsID(recipeID) and ns.RecipeThresholds and ns.RecipeThresholds[recipeID] then
		return spellUrl, nil, false, nil
	end
	local itemName = ns.GetRecipeItemName(name, profession)
	return spellUrl, WOWHEAD_BASE .. "search?q=" .. ns.EncodeUrlText(itemName or name), itemName ~= nil
end

local linkPopup, linkUI

-- A box that always shows its URL: typing is undone and the text stays selected.
local function CreateLinkBox(parent)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(LINK_BOX_WIDTH, 20)
	box:SetAutoFocus(false)
	box:SetTextInsets(2, 2, 0, 0)
	box:SetMaxLetters(0)
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput and self.url then
			self:SetText(self.url)
			self:HighlightText()
		end
	end)
	box:SetScript("OnEditFocusGained", function(self)
		self:HighlightText()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		if linkPopup then
			linkPopup:Hide()
		end
	end)
	-- Ctrl+C copies the text in the box; the popup has done its job, so it goes away a moment later.
	pcall(box.SetScript, box, "OnKeyDown", function(_, key)
		if key == "C" and IsControlKeyDown and IsControlKeyDown() then
			ns.Print("Link copied.")
			if C_Timer and C_Timer.After then
				C_Timer.After(0.1, function()
					if linkPopup then
						linkPopup:Hide()
					end
				end)
			end
		end
	end)
	return box
end

local function BuildLinkPopup()
	if linkPopup then
		return
	end

	linkPopup = CreateFrame("Frame", LINK_POPUP_NAME, UIParent, "DefaultPanelFlatTemplate")
	if ns.MakeOpaque then ns.MakeOpaque(linkPopup) end
	local frame = linkPopup
	frame:Hide()
	frame:SetSize(LINK_POPUP_WIDTH, LINK_POPUP_HEIGHT)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 140)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	SetWindowTitle(frame, "Wowhead links")
	if UISpecialFrames and not tContains(UISpecialFrames, LINK_POPUP_NAME) then
		table.insert(UISpecialFrames, LINK_POPUP_NAME)
	end

	linkUI = {}

	local drag = CreateFrame("Frame", nil, frame)
	drag:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -26, 0)
	drag:SetHeight(24)
	drag:SetFrameLevel(frame:GetFrameLevel() + 5)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	drag:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
	end)

	linkUI.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	linkUI.closeButton:SetSize(24, 24)
	linkUI.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

	linkUI.name = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	linkUI.name:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -32)
	linkUI.name:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -32)
	linkUI.name:SetHeight(14)
	linkUI.name:SetJustifyH("LEFT")
	linkUI.name:SetWordWrap(false)

	-- The recipe item (its page or a search) comes first (it is the one selected); the spell page of the recipe is below it.
	linkUI.searchLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	linkUI.searchBox = CreateLinkBox(frame)
	linkUI.pageLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	linkUI.pageLabel:SetText("Recipe spell")
	linkUI.pageBox = CreateLinkBox(frame)

	linkUI.hint = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	linkUI.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 12)
	linkUI.hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 12)
	linkUI.hint:SetHeight(26)
	linkUI.hint:SetJustifyH("LEFT")
	linkUI.hint:SetJustifyV("BOTTOM")
	linkUI.hint:SetText("Press Ctrl+C to copy, then paste in your browser.\nRecipes taught by a trainer have no item; use the spell page.")

	frame:SetScript("OnHide", function()
		linkUI.pageBox:ClearFocus()
		linkUI.searchBox:ClearFocus()
	end)
end

-- Shows the links of a recipe: the page of the item that teaches it when it is known, else a search for it (by the plain
-- recipe name when the profession has no known prefix), and the page of its spell. Without a usable recipe ID only the search link is shown.
function ns.ShowWowheadLinks(recipeID, name, profession)
	BuildLinkPopup()
	local spellUrl, searchUrl, itemSearch, teacher = ns.GetWowheadUrls(recipeID, name, profession)
	local ui = linkUI

	ui.name:SetText(StripColors(name))

	ui.pageBox.url, ui.searchBox.url = spellUrl, searchUrl
	-- Trainer recipes have no item: only the spell page is shown, in the first place, and the popup is shorter.
	local pageTop = -88
	if searchUrl then
		ui.searchLabel:SetText(teacher and "Recipe item" or (itemSearch and "Recipe item (search)" or "Search"))
		ui.searchLabel:ClearAllPoints()
		ui.searchLabel:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 16, -48)
		ui.searchBox:ClearAllPoints()
		ui.searchBox:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 20, -62)
		ui.searchBox:SetText(searchUrl)
		ui.searchBox:SetCursorPosition(0)
		ui.searchLabel:Show()
		ui.searchBox:Show()
		linkPopup:SetHeight(LINK_POPUP_HEIGHT)
	else
		ui.searchBox:ClearFocus()
		ui.searchLabel:Hide()
		ui.searchBox:Hide()
		pageTop = -48
		linkPopup:SetHeight(LINK_POPUP_HEIGHT - 40)
	end

	if spellUrl then
		ui.pageLabel:ClearAllPoints()
		ui.pageLabel:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 16, pageTop)
		ui.pageBox:ClearAllPoints()
		ui.pageBox:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 20, pageTop - 14)
		ui.pageBox:SetText(spellUrl)
		ui.pageBox:SetCursorPosition(0)
		ui.pageLabel:Show()
		ui.pageBox:Show()
	else
		ui.pageLabel:Hide()
		ui.pageBox:Hide()
	end

	linkPopup:Show()
	linkPopup:Raise()
	local focus = searchUrl and ui.searchBox or ui.pageBox
	focus:SetFocus()
	focus:HighlightText()
	return true
end

-- Popup and widget table, for tests.
function ns.GetLinkPopup()
	return linkPopup, linkUI
end

--------------------------------------------------------------------------------
-- Switching the lookup on and off
--------------------------------------------------------------------------------

-- Turns the recipe lookup on or off. Off stops what is pending and closes its windows; the saved recipes stay.
function ns.SetRecipeLookupEnabled(enabled)
	if not lookup or type(enabled) ~= "boolean" then
		return false
	end
	lookup.enabled = enabled
	if enabled then
		ScheduleLearn()
	else
		CancelScan()
		CancelLearn()
		Wipe(lastSignature)
		if window then
			window:Hide()
		end
		if linkPopup then
			linkPopup:Hide()
		end
	end
	return true
end

-- Prints why nothing happens and returns false while the lookup is off.
local function CheckLookupEnabled()
	if ns.IsRecipeLookupEnabled() then
		return true
	end
	ns.Print("Recipe lookup is off. Turn it on with /ju recipes on.")
	return false
end

--------------------------------------------------------------------------------
-- Key binding and slash command
--------------------------------------------------------------------------------

function ns.FindRecipesHovered()
	if not CheckLookupEnabled() then
		return
	end
	local itemID = ns.GetHoveredItemID()
	if itemID then
		ns.ShowRecipes(itemID)
	else
		ns.Print("Hover an item first, then press the key. You can also type /ju recipes <item link, ID or name>.")
	end
end

-- Called by Bindings.xml.
function JimmysUtils_FindRecipesHovered()
	ns.FindRecipesHovered()
end

BINDING_HEADER_JIMMYSUTILS = "Jimmy's Utils"
BINDING_NAME_JIMMYSUTILS_RECIPES = "Jimmy's Utils: Find recipes using hovered item"

-- "12 recipes, 3 not learned" for one of the recipe list functions of the open profession window.
local function DescribeList(fn)
	if not fn then
		return "missing"
	end
	local ok, ids = pcall(fn)
	ids = ok and PlainTable(ids) or nil
	if not ids then
		return "unavailable (error or secret value)"
	end
	local total, unlearned = 0, 0
	for _, recipeID in ipairs(ids) do
		if IsID(recipeID) then
			total = total + 1
			local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
			info = okInfo and PlainTable(info) or nil
			if info and not IsSecret(info.learned) and not info.learned then
				unlearned = unlearned + 1
			end
		end
	end
	return string.format("%d recipe%s, %d not learned", total, total == 1 and "" or "s", unlearned)
end

-- What the client gives the addon, so the player can tell whether recipes nobody knows can be listed at all.
local function PrintDiagnostic()
	if not C_TradeSkillUI then
		print("  C_TradeSkillUI is missing.")
		return
	end
	print("  C_TradeSkillUI.GetAllRecipeIDs: " .. (C_TradeSkillUI.GetAllRecipeIDs and "exists" or "missing"))
	print("  C_TradeSkillUI.GetFilteredRecipeIDs: " .. (C_TradeSkillUI.GetFilteredRecipeIDs and "exists" or "missing"))
	local all = C_TradeSkillUI.GetAllRecipeIDs and DescribeList(C_TradeSkillUI.GetAllRecipeIDs)
	local filtered = C_TradeSkillUI.GetFilteredRecipeIDs and DescribeList(C_TradeSkillUI.GetFilteredRecipeIDs)
	local ids = GetRecipeIDs()
	if not ids then
		print("  No profession window with recipes is open. Open one and run this again to see what the client gives the addon.")
		return
	end
	print("  Open profession: " .. (GetBaseProfessionName() or "unknown"))
	if all then
		print("  GetAllRecipeIDs: " .. all)
	end
	if filtered then
		print("  GetFilteredRecipeIDs: " .. filtered)
	end
end

local function PrintSaved()
	local total, professions = ns.GetRecipeSummary()
	if total == 0 then
		ns.Print("No recipes saved yet.")
	else
		ns.Print(string.format("%d recipe%s saved:", total, total == 1 and "" or "s"))
		for _, profession in ipairs(professions) do
			print("  " .. profession.name .. ": " .. profession.count)
		end

		local _, ownRealm = GetCharacterKey()
		local perCharacter = {}
		for _, characters in pairs(knownBy) do
			for character in pairs(characters) do
				perCharacter[character] = (perCharacter[character] or 0) + 1
			end
		end
		local names = {}
		for character in pairs(perCharacter) do
			names[#names + 1] = character
		end
		table.sort(names)
		if #names > 0 then
			local parts = {}
			for _, character in ipairs(names) do
				parts[#parts + 1] = FormatCharacter(character, ownRealm) .. " " .. perCharacter[character]
			end
			print("  Known by: " .. table.concat(parts, ", "))
		end
	end
	PrintDiagnostic()
end

local forgetHint = "/ju recipes forget confirm"
local RELEARN_NOTE = " This is the character you are playing, so the recipes it knows will be saved again automatically."

-- Two-step removal of one character from the saved recipes: "forget <character>", then "forget <character> confirm".
local function HandleForgetCharacter(arg)
	local stripped = arg:match("^(.-) confirm$")
	local name, confirmed = stripped or arg, stripped ~= nil
	local matches = ns.FindSavedCharacters(name)
	local _, ownRealm = GetCharacterKey()
	if #matches == 0 then
		ns.Print("No saved recipe is known by \"" .. name .. "\".")
	elseif #matches > 1 then
		ns.Print("Several characters match \"" .. name .. "\", use Name-Realm:")
		for _, character in ipairs(matches) do
			print("  " .. character)
		end
	elseif not confirmed then
		local count = 0
		for _, characters in pairs(knownBy) do
			if characters[matches[1]] then
				count = count + 1
			end
		end
		ns.Print(string.format("%s is saved as knowing %d recipe%s. Type /ju recipes forget %s confirm to remove them.",
			FormatCharacter(matches[1], ownRealm), count, count == 1 and "" or "s", matches[1]))
	else
		local count = ns.ForgetCharacter(matches[1])
		ns.Print(string.format("Removed %s from %d recipe%s.", FormatCharacter(matches[1], ownRealm), count, count == 1 and "" or "s")
			.. (matches[1] == GetCharacterKey() and RELEARN_NOTE or ""))
	end
end

function ns.HandleRecipesCommand(rest)
	rest = Trim(rest or "")
	local lowered = rest:lower():gsub("%s+", " ")

	if lowered == "on" or lowered == "off" then
		ns.SetRecipeLookupEnabled(lowered == "on")
		ns.Print("Recipe lookup " .. (lowered == "on" and "enabled." or "disabled. The saved recipes are kept."))
		ns.NotifyConfigChanged()
	elseif rest == "" then
		if not CheckLookupEnabled() then
			return
		end
		local itemID = ns.GetHoveredItemID()
		if itemID then
			ns.ShowRecipes(itemID)
		else
			ns.Print("Usage: /ju recipes <item link | item ID | item name>, or hover an item and press the key binding. Also: /ju recipes on | off, /ju recipes status, /ju recipes forget [character].")
		end
	elseif lowered == "status" or lowered == "scan" then
		ns.Print("Recipe lookup is " .. (ns.IsRecipeLookupEnabled() and "on." or "off. Turn it on with /ju recipes on."))
		PrintSaved()
	elseif lowered == "forget" then
		local total = ns.GetRecipeSummary()
		ns.Print(string.format("This deletes all %d saved recipes. Type %s to continue, or /ju recipes forget <character> to remove one character.", total, forgetHint))
	elseif lowered == "forget confirm" then
		local count = ns.ForgetRecipes()
		ns.Print(string.format("Forgot %d saved recipe%s.", count, count == 1 and "" or "s")
			.. " The recipes the character you are playing knows will be saved again automatically.")
	elseif lowered:find("^forget ") then
		HandleForgetCharacter(lowered:sub(8))
	elseif CheckLookupEnabled() then
		local itemID, matches = ns.ResolveRecipeItem(rest)
		if itemID then
			ns.ShowRecipes(itemID)
		elseif #matches == 0 then
			ns.Print("No saved ingredient matches \"" .. rest .. "\". Use an item link or ID.")
		else
			ns.Print("Several items match \"" .. rest .. "\", be more specific or use the item ID:")
			for i = 1, math.min(#matches, MAX_MATCHES) do
				print("  [" .. matches[i].itemID .. "] " .. matches[i].name)
			end
			if #matches > MAX_MATCHES then
				print("  ... and " .. (#matches - MAX_MATCHES) .. " more")
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

function ns.InitRecipes(database)
	if initialized then
		return
	end
	initialized = true

	InitData(database)

	-- The main tooltips tell which item the player points at.
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipSetItem)
	end
	WatchTooltip(GameTooltip, "game")
	WatchTooltip(ItemRefTooltip, "ref")

	local driver = CreateFrame("Frame")
	for _, event in ipairs(SCAN_EVENTS) do
		-- An event this client does not have must not stop the others from being registered.
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript("OnEvent", function(_, event, ...)
		-- Off: nothing is learned and the saved recipes are left alone. The names of the items asked for earlier still arrive.
		if not ns.IsRecipeLookupEnabled() and event ~= "ITEM_DATA_LOAD_RESULT" then
			return
		end
		if event == "TRADE_SKILL_CLOSE" then
			CancelScan()
		elseif event == "TRADE_SKILL_LIST_UPDATE" then
			ScheduleScan(false)
		elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
			ScheduleScan(true)
		elseif event == "NEW_RECIPE_LEARNED" then
			ScheduleScan(true)
			ScheduleLearn()
		elseif event == "PLAYER_LOGIN" or event == "SKILL_LINES_CHANGED" then
			SyncOwnProfessions()
			ScheduleLearn()
		elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "SPELLS_CHANGED" then
			ScheduleLearn()
		elseif event == "SPELL_DATA_LOAD_RESULT" then
			-- A spell name that was missing may be there now; a failed load is left to the timer, which gives up after a few tries.
			local spellID, success = ...
			if not IsSecret(spellID) and not IsSecret(success) and success == true and pendingSpells[spellID] then
				ScheduleLearn()
			end
			OnViewSpellLoaded(spellID, success)
		elseif event == "ITEM_DATA_LOAD_RESULT" then
			OnItemDataLoaded((...))
		elseif event == "BAG_UPDATE_DELAYED" then
			-- The colors of the materials follow what you have; only the open window needs it.
			if window and window:IsShown() then
				RefreshOwnedCounts()
			end
		end
	end)
end

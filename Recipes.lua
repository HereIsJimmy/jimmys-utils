local addonName, ns = ...

--[[
	Recipe lookup: lists the recipes that use an item as an ingredient, and where to get the ones no character knows.

	The game only lists a profession's recipes while its window is open, so there is no bundled database: whenever one of
	the player's own profession windows opens (or its list updates) the recipes are read and saved account-wide.

	Saved data (validated in ns.InitRecipes, all keys are additive and optional):
		JimmysStatWeightsDB.recipes = { [recipeID] = { name, icon, profession, output = itemID, reagents = { [itemID] = quantity },
			slots = { { items = { itemID, ... }, quantity = n } }, source = text } }
		JimmysStatWeightsDB.recipeKnownBy = { [recipeID] = { ["Name-Realm"] = true } }
		JimmysStatWeightsDB.itemNames = { [itemID] = name } -- names of ingredients, so a name can be looked up offline
		JimmysStatWeightsDB.recipeLookup = { enabled = true } -- off: no recipes are learned and the lookup is closed; what is saved is kept

	Only basic reagent slots are saved (optional and finishing slots are skipped). The index reagent item -> recipes is kept
	in memory and rebuilt at load and after every scan. "reagents" is the flat map of every ingredient item (what the index
	uses); "slots" keeps how they group: the items of one slot are interchangeable choices (for example the quality tiers of an
	herb) that together must reach the slot's quantity, as in Blizzard's own recipe tracker. Recipes saved before "slots" existed
	have none until they are scanned again.

	Every API result is read through pcall and skipped when it is a secret value; nothing is branched on a secret.
	The profession window's own settings (for example "show unlearned") are never changed.
]]

local FRAME_NAME = "JimmysUtilsRecipesFrame"
local SCROLL_NAME = "JimmysUtilsRecipesScroll"

local FRAME_WIDTH = 380
local FRAME_HEIGHT = 360
local LIST_WIDTH = 316 -- scroll frame width (frame minus margins and the scroll bar)
local ROW_HEIGHT = 46
local ROW_ICON_SIZE = 32
local HEADER_ICON_SIZE = 28
local QTY_WIDTH = 40
local DETAIL_HEIGHT = 26
local QUESTION_ICON = 134400 -- INV_Misc_QuestionMark

local SCAN_DELAY = 0.5 -- seconds; the profession events come in bursts
local NAME_RETRY_DELAY = 2 -- item names that are not cached yet are asked for again after this long
local MAX_MATCHES = 5 -- items listed in chat when a name matches several
local MAX_NOT_READY_RETRIES = 20 -- how often a scan waits for a profession window that is still loading

local WOWHEAD_BASE = "https://www.wowhead.com/forever/"
local LINK_POPUP_NAME = "JimmysUtilsLinkPopup"
local LINK_POPUP_WIDTH = 360
local LINK_POPUP_HEIGHT = 150
local LINK_BOX_WIDTH = 320
local LINK_BUTTON_WIDTH = 60
local LINK_BUTTON_HEIGHT = 18

local KNOWN_NAME_COLOR = { 1, 0.82, 0 }
local UNKNOWN_NAME_COLOR = { 0.72, 0.72, 0.72 }
local KNOWN_TEXT_COLOR = "ff33ff33"
local UNKNOWN_TEXT_COLOR = "ffff9933"
local GREY_TEXT_COLOR = "ff999999"

-- Calls that, when they return true, mean the open window is not the player's own profession.
local SKIP_CHECKS = { "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting", "IsRuneforging" }
local SCAN_EVENTS = {
	"TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED", "TRADE_SKILL_CLOSE",
	"PLAYER_LOGIN", "SKILL_LINES_CHANGED", "ITEM_DATA_LOAD_RESULT",
}

local DEFAULT_LOOKUP = {
	enabled = true,
}

-- Set in ns.InitRecipes.
local db, recipes, knownBy, itemNames
local lookup -- db.recipeLookup
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
	for _, key in ipairs({ "recipes", "recipeKnownBy", "itemNames" }) do
		if type(db[key]) ~= "table" then
			db[key] = {}
		end
	end
	recipes, knownBy, itemNames = db.recipes, db.recipeKnownBy, db.itemNames

	if type(db.recipeLookup) ~= "table" then
		db.recipeLookup = {}
	end
	lookup = db.recipeLookup
	for name, default in pairs(DEFAULT_LOOKUP) do
		if type(lookup[name]) ~= type(default) then
			lookup[name] = default
		end
	end

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
			end
		end
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

-- Tells the open windows that the saved recipes changed.
local function NotifyChanged()
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
	Wipe(pendingNames)
	Wipe(lastSignature)
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
	-- Characters with saved bags, bank or mail but no recipes can be forgotten too.
	for _, character in ipairs(ns.GetInventoryCharacters and ns.GetInventoryCharacters() or {}) do
		Consider(character)
	end
	table.sort(matches)
	return matches
end

-- Removes a character ("Name-Realm", as returned by FindSavedCharacters) from every recipe, and its saved bags, bank
-- and mailbox (Inventory.lua). Returns how many recipes it was known for.
function ns.ForgetCharacter(character)
	local count = 0
	for recipeID, characters in pairs(knownBy) do
		if characters[character] then
			count = count + 1
			SetKnown(recipeID, character, false)
		end
	end
	local forgotInventory = ns.ForgetInventory and ns.ForgetInventory(character) or false
	if count > 0 or forgotInventory then
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

-- { name, icon, learned } of a recipe, or nil when the name or the learned flag cannot be read.
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
	return { name = name, icon = icon, learned = learned and true or false }
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
		output = output or existing.output
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
		itemNames[itemID] = name
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

	local signatureKey = character .. "|" .. (baseProfession or "?")
	local signature = #order .. "|" .. learnedCount
	if skipUnchanged and lastSignature[signatureKey] == signature then
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

-- Professions the character has, as a set of lowercase names; nil unless the list can be read reliably.
local function GetOwnProfessionNames()
	if not (GetProfessions and GetProfessionInfo) then
		return nil
	end
	local results = { pcall(GetProfessions) }
	if not results[1] then
		return nil
	end
	local names, count = {}, 0
	for position = 2, 8 do
		local index = results[position]
		if index ~= nil then
			if IsSecret(index) or type(index) ~= "number" then
				return nil
			end
			local ok, name = pcall(GetProfessionInfo, index)
			name = ok and PlainString(name) or nil
			if not name then
				return nil
			end
			names[name:lower()] = true
			count = count + 1
		end
	end
	-- No professions at all is more likely a list that has not loaded yet than a character without any.
	if count == 0 then
		return nil
	end
	return names
end

-- Takes this character off the recipes of professions it no longer has.
local function PruneStaleProfessions()
	local character = db and GetCharacterKey()
	local names = character and GetOwnProfessionNames()
	if not names then
		return
	end
	local changed = false
	for recipeID, characters in pairs(knownBy) do
		local record = recipes[recipeID]
		if characters[character] and record and not names[record.profession:lower()] then
			SetKnown(recipeID, character, false)
			changed = true
		end
	end
	if changed then
		Wipe(lastSignature)
		NotifyChanged()
	end
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

-- One entry per recipe using the item, known recipes first, then by profession and name.
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

function ns.GetRecipeRows(itemID)
	local rows = {}
	local ownKey, ownRealm = GetCharacterKey()
	for _, recipeID in ipairs(reagentIndex[itemID] or {}) do
		local record = recipes[recipeID]
		if record then
			local characters = {}
			local knownHere = ownKey ~= nil and (knownBy[recipeID] or {})[ownKey] == true
			for character in pairs(knownBy[recipeID] or {}) do
				characters[#characters + 1] = FormatCharacter(character, ownRealm)
			end
			table.sort(characters, function(a, b)
				local la, lb = a:lower(), b:lower()
				if la ~= lb then
					return la < lb
				end
				return a < b
			end)
			rows[#rows + 1] = {
				recipeID = recipeID,
				name = record.name,
				icon = record.icon,
				profession = record.profession,
				quantity = record.reagents[itemID],
				output = record.output,
				source = record.source,
				knownBy = characters,
				known = #characters > 0,
				knownHere = knownHere,
			}
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

-- Single line of text for a row: the source text can span several lines.
local function FlattenText(text)
	text = text:gsub("|n", ", "):gsub("%s*[\r\n]+%s*", ", "):gsub("%s+", " ")
	return Trim(text)
end

local function FormatDetail(row)
	local status
	if row.known then
		status = "|c" .. KNOWN_TEXT_COLOR .. "Known: " .. table.concat(row.knownBy, ", ") .. "|r"
	elseif row.source then
		status = "|c" .. UNKNOWN_TEXT_COLOR .. "Not known|r |c" .. GREY_TEXT_COLOR .. "\226\128\148|r " .. FlattenText(row.source)
	else
		status = "|c" .. UNKNOWN_TEXT_COLOR .. "Not known|r |c" .. GREY_TEXT_COLOR .. "\226\128\148 source unknown (see Wowhead)|r"
	end
	return "|c" .. GREY_TEXT_COLOR .. row.profession .. "|r  " .. status
end

local function AcquireRow(index)
	local row = ui.rows[index]
	if row then
		return row
	end

	row = {}
	-- A Button, so the row gets OnDoubleClick (opens the recipe in the profession window).
	row.frame = CreateFrame("Button", nil, ui.scrollChild)
	row.frame:SetSize(LIST_WIDTH, ROW_HEIGHT)
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

	row.detail = row.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
	row.detail:SetPoint("RIGHT", row.frame, "RIGHT", -(LINK_BUTTON_WIDTH + 8), 0)
	row.detail:SetHeight(DETAIL_HEIGHT)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetJustifyV("TOP")

	-- Shows the Wowhead links of the recipe; the detail text above stops before it.
	row.link = CreateFrame("Button", nil, row.frame, "UIPanelButtonTemplate")
	row.link:SetSize(LINK_BUTTON_WIDTH, LINK_BUTTON_HEIGHT)
	row.link:SetPoint("BOTTOMRIGHT", row.frame, "BOTTOMRIGHT", -4, 4)
	row.link:SetNormalFontObject("GameFontNormalSmall")
	row.link:SetText("Wowhead")
	row.link:SetScript("OnClick", function()
		if row.entry then
			ns.ShowWowheadLinks(row.entry.recipeID, row.entry.name)
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
		-- The status line of the row may be cut short, so the tooltip carries the full source and the characters.
		if entry.source then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Where to get it:", 1, 0.6, 0.2)
			GameTooltip:AddLine(entry.source, 1, 1, 1, true)
		end
		if entry.known then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Known by: " .. table.concat(entry.knownBy, ", "), 0.2, 1, 0.2, true)
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

RefreshWindow = function()
	if not ui or not ui.itemID then
		return
	end
	local itemID = ui.itemID
	local itemName = ns.GetItemName(itemID) or ("Item " .. itemID)

	SetWindowTitle(window, "Recipes using " .. itemName)
	ui.itemIcon:SetTexture(ReadItemIcon(itemID) or QUESTION_ICON)
	ui.itemName:SetText(itemName)

	local entries = ns.GetRecipeRows(itemID)
	local child = ui.scrollChild
	child:SetWidth(LIST_WIDTH)
	for i, entry in ipairs(entries) do
		local row = AcquireRow(i)
		row.entry = entry
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row.icon:SetTexture(entry.icon or QUESTION_ICON)
		row.name:SetText(entry.name)
		local color = entry.known and KNOWN_NAME_COLOR or UNKNOWN_NAME_COLOR
		row.name:SetTextColor(color[1], color[2], color[3])
		row.qty:SetText("x" .. entry.quantity)
		row.detail:SetText(FormatDetail(entry))
		row.frame:Show()
	end
	for i = #entries + 1, #ui.rows do
		ui.rows[i].entry = nil
		ui.rows[i].frame:Hide()
	end
	child:SetHeight(math.max(ROW_HEIGHT, #entries * ROW_HEIGHT))
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

	-- List. Named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.scroll = CreateFrame("ScrollFrame", SCROLL_NAME, frame, "UIPanelScrollFrameTemplate")
	ui.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -68)
	ui.scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 36)

	ui.scrollChild = CreateFrame("Frame", nil, ui.scroll)
	ui.scrollChild:SetSize(LIST_WIDTH, ROW_HEIGHT)
	ui.scroll:SetScrollChild(ui.scrollChild)
	ui.emptyText = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.emptyText:SetPoint("TOPLEFT", ui.scrollChild, "TOPLEFT", 4, -4)
	ui.emptyText:SetWidth(LIST_WIDTH - 12)
	ui.emptyText:SetJustifyH("LEFT")
	ui.emptyText:SetJustifyV("TOP")
	ui.emptyText:SetText("No saved recipes use this item. Open your profession windows so Jimmy's Utils can learn their recipes.")
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
	end
	ui.itemID = itemID
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

-- Page of the recipe (nil without a recipe ID) and a search for its name.
function ns.GetWowheadUrls(recipeID, name)
	local pageUrl
	if IsID(recipeID) then
		pageUrl = WOWHEAD_BASE .. "spell=" .. string.format("%d", recipeID)
	end
	return pageUrl, WOWHEAD_BASE .. "search?q=" .. ns.EncodeUrlText(name)
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

	linkUI.pageLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	linkUI.pageLabel:SetText("Recipe page")
	linkUI.pageBox = CreateLinkBox(frame)
	linkUI.searchLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	linkUI.searchLabel:SetText("Search")
	linkUI.searchBox = CreateLinkBox(frame)

	linkUI.hint = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	linkUI.hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 12)
	linkUI.hint:SetHeight(12)
	linkUI.hint:SetJustifyH("LEFT")
	linkUI.hint:SetText("Press Ctrl+C to copy, then paste in your browser.")

	frame:SetScript("OnHide", function()
		linkUI.pageBox:ClearFocus()
		linkUI.searchBox:ClearFocus()
	end)
end

-- Shows the links of a recipe. Without a usable recipe ID only the search link is shown.
function ns.ShowWowheadLinks(recipeID, name)
	BuildLinkPopup()
	local pageUrl, searchUrl = ns.GetWowheadUrls(recipeID, name)
	local ui = linkUI

	ui.name:SetText(StripColors(name))

	local searchLabelY, searchBoxY = -48, -62
	ui.pageBox.url, ui.searchBox.url = pageUrl, searchUrl
	if pageUrl then
		ui.pageLabel:ClearAllPoints()
		ui.pageLabel:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 16, -48)
		ui.pageBox:ClearAllPoints()
		ui.pageBox:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 20, -62)
		ui.pageBox:SetText(pageUrl)
		ui.pageBox:SetCursorPosition(0)
		ui.pageLabel:Show()
		ui.pageBox:Show()
		searchLabelY, searchBoxY = -88, -102
	else
		ui.pageLabel:Hide()
		ui.pageBox:Hide()
	end
	ui.searchLabel:ClearAllPoints()
	ui.searchLabel:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 16, searchLabelY)
	ui.searchBox:ClearAllPoints()
	ui.searchBox:SetPoint("TOPLEFT", linkPopup, "TOPLEFT", 20, searchBoxY)
	ui.searchBox:SetText(searchUrl)
	ui.searchBox:SetCursorPosition(0)

	linkPopup:Show()
	linkPopup:Raise()
	local first = pageUrl and ui.pageBox or ui.searchBox
	first:SetFocus()
	first:HighlightText()
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
	if not enabled then
		CancelScan()
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
		ns.Print("No recipes saved yet. Open your profession windows so Jimmy's Utils can learn their recipes.")
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
		ns.Print(string.format("Removed %s from %d recipe%s.", FormatCharacter(matches[1], ownRealm), count, count == 1 and "" or "s"))
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
		ns.Print(string.format("Forgot %d saved recipe%s.", count, count == 1 and "" or "s"))
	elseif lowered:find("^forget ") then
		HandleForgetCharacter(lowered:sub(8))
	elseif CheckLookupEnabled() then
		local itemID, matches = ns.ResolveRecipeItem(rest)
		if itemID then
			ns.ShowRecipes(itemID)
		elseif #matches == 0 then
			ns.Print("No saved ingredient matches \"" .. rest .. "\". Use an item link or ID, or open your profession windows so Jimmy's Utils can learn their recipes.")
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
		elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "NEW_RECIPE_LEARNED" then
			ScheduleScan(true)
		elseif event == "PLAYER_LOGIN" or event == "SKILL_LINES_CHANGED" then
			PruneStaleProfessions()
		elseif event == "ITEM_DATA_LOAD_RESULT" then
			OnItemDataLoaded((...))
		end
	end)
end

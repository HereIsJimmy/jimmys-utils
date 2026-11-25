local addonName, ns = ...

--[[
	Crafting profit: what a recipe earns when its result is sold on the auction house, from Auctionator's prices (an optional
	dependency; its public API v1 is called with the caller ID "JimmysUtils", every call through pcall). Without Auctionator, or with
	the option off (Options > Recipes), nothing here answers and every part of the interface that shows a profit stays hidden.

	The formula is Auctionator's own (Source_Mainline/CraftingInfo/Professions.lua):
		profit = auction price of the result x items made x 0.95 - cost of the ingredients
	An ingredient is priced at its vendor price when Auctionator knows one, else at its auction price (a vendor price more than five
	times the auction price is not used, as Auctionator does). An ingredient slot with alternative items (the quality tiers of an
	herb) counts at its cheapest priced item, times the slot's quantity. When the result or any ingredient has no price the profit is
	unknown ("missing"); a price of 0 counts as no price. How many items a craft makes comes from the recipe record (outputCount, set
	from the schematic by Recipes.lua), else the bundled ns.RecipeOutputCounts, else 1.
	Vendor-only ingredients (thread, vials, flux) often have no price until Auctionator has seen them at a merchant, so a recipe whose
	result is priced but some ingredients are not gets a partial profit: the unpriced ingredients count as free, the answer has
	missing = true and partial = true, and it is shown greyed with a "~" before it (the tooltip lists the ingredients that have no price
	yet). Without a result price nothing can be said and the profit is unknown. Items are priced by their base item ID, so gear with a
	random suffix or bonus IDs gets the price of its base item.

	Prices are read through a small cache that lives for a refresh of a window (ns.ResetProfitCache) and, failing that, a couple of
	seconds, so a long list does not ask Auctionator over and over but a price that changed is picked up soon.

	Saved data (validated in ns.InitProfit):
		JimmysStatWeightsDB.profit = { enabled = true, listSort = "blizzard" | "profit" }
		-- enabled: the option; listSort: how Blizzard's own recipe list is ordered (see below). The sort order of the recipes window
		-- and of the materials window is saved with those windows (recipeLookup.sortProfit, mailMaterials.sortProfit). An older
		-- version also kept the settings of a panel docked to the profession window (panelOpen, sort, descending, onlyProfitable,
		-- hideUnpriced): they are removed at load.

	Without Auctionator (not loaded, or loaded after this addon: ADDON_LOADED "Auctionator" re-evaluates everything) every profit
	feature behaves as if it were off, and nothing the player chose is overwritten: the saved option, listSort and the windows'
	sortProfit stay as they are and apply again as soon as the prices are there.

	/ju profit lists the learned recipes of the open profession in the order of the Filter-menu sort, and /ju profit <name> shows where a
	recipe's numbers come from.

	Blizzard's recipe list: Blizzard's own Filter menu of the crafting page gets a "Sort by (Jimmy's Utils)" section with the radios
	"Default" (Blizzard's order) and "Crafting profit" (the setting listSort, only while profits are available). It is done the way SkillUp Forever
	does it, which is proven on this client: when the list's ScrollBox is given a data provider by the client, a flat provider of the
	client's own node data (never tables of ours: the selection keeps them for the craft path to read) replaces it: the learned recipes
	by profit, then the client's divider and the unlearned ones in the client's order. Nothing else of Blizzard's state is written:
	never CraftingPage:Init, never a selection (a click on a row is the client's own), only SetDataProvider, which a flag keeps from
	handling its own reassignment. The client's provider is remembered and put back for "Default", and a provider that holds
	the rows already shown is not replaced (that would clear the selection). Linked, guild and NPC windows keep the client's list;
	a failure turns the sort off with one message. The menu section is not added while the gamepad interface is on (the client's own
	gamepad footer opens that menu, and a section built by addon code taints it). While SkillUp Forever is loaded it sorts this list
	itself, so this addon never touches it and the profit radio is shown disabled (Default shows selected). The client selects a row by
	its recipe and favoritesInstance, so the favourites copies it lists (first, as the favourites category) are in the new list too, first,
	sorted like the rest. The same choice is a check box in Options > Recipes (the way back to Default under the gamepad interface).
]]

local CALLER_ID = "JimmysUtils"
local AH_CUT = 0.95 -- what is left of a sale after the auction house takes its cut (Auctionator's AfterAHCut)
local VENDOR_LIMIT = 5 -- a vendor price above this many times the auction price is not used
local CACHE_SECONDS = 2

local GREEN = "ff33ff33"
local RED = "ffff4040"
local GREY = "ff999999"

local DEFAULTS = {
	enabled = true,
	listSort = "blizzard",
}
local LIST_SORTS = { blizzard = true, profit = true }
ns.PROFIT_LIST_SORTS = LIST_SORTS -- the settings profiles (SettingsProfiles.lua) clean the setting with it
-- Settings of the panel docked to the profession window that an older version kept; removed at load.
local OLD_SETTINGS = { "panelOpen", "sort", "descending", "onlyProfitable", "hideUnpriced" }

-- Set in ns.InitProfit.
local settings
local initialized = false
local attached = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

-- A real number that is not a secret value.
local function PlainNumber(value)
	return not IsSecret(value) and type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

-- A positive whole number that is not a secret value (item and recipe IDs, quantities).
local function IsID(value)
	return PlainNumber(value) and value > 0 and value < 2 ^ 31 and value == math.floor(value)
end

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

-- The text with its "|" doubled, so recipe names never start an escape sequence.
local function Escape(text)
	return (tostring(text):gsub("|", "||"))
end

--------------------------------------------------------------------------------
-- Auctionator
--------------------------------------------------------------------------------

-- Auctionator's API v1 table, or nil while it is not there (or cannot be trusted). Auctionator's database of prices is made after its
-- files are loaded (the price calls answer nil until then), so it counts as not there until the database is.
local function GetAPI()
	local auctionator = Auctionator
	if type(auctionator) ~= "table" or IsSecret(auctionator) or auctionator.Database == nil then
		return nil
	end
	local api = auctionator.API
	api = type(api) == "table" and not IsSecret(api) and api.v1 or nil
	if type(api) == "table" and not IsSecret(api)
		and type(api.GetAuctionPriceByItemID) == "function" and type(api.GetVendorPriceByItemID) == "function" then
		return api
	end
end

-- Is Auctionator (its price API) loaded? The option does not matter here.
function ns.IsAuctionatorLoaded()
	return GetAPI() ~= nil
end

-- The option (Options > Recipes), true until it is switched off.
function ns.IsProfitEnabled()
	return settings ~= nil and settings.enabled == true
end

-- Can a profit be shown: Auctionator is there and the option is on.
function ns.IsProfitAvailable()
	return settings ~= nil and settings.enabled == true and GetAPI() ~= nil
end

local cache = { ah = {}, vendor = {}, age = {}, exact = {}, link = {}, linkData = {} }
local cacheStamp

-- Forgets the prices read so far (windows call it before they read a list again).
function ns.ResetProfitCache()
	cache = { ah = {}, vendor = {}, age = {}, exact = {}, link = {}, linkData = {} }
	cacheStamp = type(GetTime) == "function" and GetTime() or 0
end

local function GetCache()
	local now = type(GetTime) == "function" and GetTime() or 0
	if cacheStamp == nil or now < cacheStamp or now - cacheStamp > CACHE_SECONDS then
		ns.ResetProfitCache()
	end
	return cache
end

-- One call of the API: its answer, or nil when it is missing or fails.
local function Call(api, name, itemID)
	local fn = api[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, CALLER_ID, itemID)
	if ok then
		return value
	end
end

-- A price in copper: a plain number above 0, else nil. Answers are cached (false stands for "no price").
local function Price(api, kind, name, itemID)
	local prices = GetCache()[kind]
	local value = prices[itemID]
	if value == nil then
		local read = Call(api, name, itemID)
		value = PlainNumber(read) and read > 0 and read or false
		prices[itemID] = value
	end
	return value or nil
end

local function AuctionPrice(api, itemID)
	return Price(api, "ah", "GetAuctionPriceByItemID", itemID)
end

local function VendorPrice(api, itemID)
	return Price(api, "vendor", "GetVendorPriceByItemID", itemID)
end

-- Days since the item was seen at the auction house, or nil.
local function AuctionAge(api, itemID)
	local ages = GetCache().age
	local value = ages[itemID]
	if value == nil then
		local read = Call(api, "GetAuctionAgeByItemID", itemID)
		value = PlainNumber(read) and read >= 0 and read or false
		ages[itemID] = value
	end
	return value or nil
end

local function AuctionExact(api, itemID)
	local exact = GetCache().exact
	local value = exact[itemID]
	if value == nil then
		value = Call(api, "IsAuctionDataExactByItemID", itemID) == true
		exact[itemID] = value
	end
	return value
end

-- The link of what a recipe makes: the profession window's (GetRecipeOutputItemData), else the item's own (GetItemInfo), else nil.
-- Auctionator prices crafted gear by its link (item level), so the result is priced the way its own profession panel does.
local function OutputLink(recipeID, output)
	if C_TradeSkillUI and C_TradeSkillUI.GetRecipeOutputItemData and IsID(recipeID) then
		local ok, data = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
		data = ok and PlainTable(data) or nil
		local link = data and PlainString(data.hyperlink) or nil
		if link and not (IsID(data.itemID) and data.itemID ~= output) then
			return link
		end
	end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if type(getInfo) == "function" then
		local ok, _, link = pcall(getInfo, output)
		if ok and PlainString(link) then
			return link
		end
	end
end

-- The auction price of a recipe's result, by its link when there is one (else by item ID), and the age and exactness of that price.
local function ResultPrice(api, recipeID, output)
	local links = GetCache().link
	local key = recipeID .. ":" .. output
	local link = links[key]
	if link == nil then
		link = OutputLink(recipeID, output) or false
		links[key] = link
	end
	if link then
		local price = Price(api, "ah", "GetAuctionPriceByItemLink", link)
		if price then
			-- The age and the exactness of a link's price are cached like the price.
			local data = GetCache().linkData[link]
			if not data then
				local age = Call(api, "GetAuctionAgeByItemLink", link)
				data = { age = PlainNumber(age) and age >= 0 and age or nil, exact = Call(api, "IsAuctionDataExactByItemLink", link) == true }
				GetCache().linkData[link] = data
			end
			return price, data.age, data.exact
		end
	end
	local price = AuctionPrice(api, output)
	if price then
		return price, AuctionAge(api, output), AuctionExact(api, output)
	end
end

-- What one ingredient costs: its vendor price when Auctionator knows one, else its auction price (the vendor price is passed over
-- when it is more than VENDOR_LIMIT times the auction price). Returns the price (nil without any) and whether it is an auction price.
local function UnitCost(api, itemID)
	local vendor, auction = VendorPrice(api, itemID), AuctionPrice(api, itemID)
	if vendor and not (auction and vendor > VENDOR_LIMIT * auction) then
		return vendor, false
	end
	return auction, auction ~= nil
end

-- The slots of a recipe record: the saved ones, else the bundled recipe's, else one slot per ingredient (sorted by item).
local function SlotsOf(record, recipeID)
	local slots = {}
	if type(record.slots) == "table" then
		for _, slot in ipairs(record.slots) do
			if type(slot) == "table" and type(slot.items) == "table" and IsID(slot.quantity) then
				local items = {}
				for _, itemID in ipairs(slot.items) do
					if IsID(itemID) then
						items[#items + 1] = itemID
					end
				end
				if #items > 0 then
					slots[#slots + 1] = { items = items, quantity = slot.quantity }
				end
			end
		end
	end
	-- A record without slots: the bundled recipe's, when it has the same ingredients, else one slot per ingredient.
	if #slots == 0 and type(record.reagents) == "table" and ns.GetBundledSlots then
		for _, slot in ipairs(ns.GetBundledSlots(recipeID, record.reagents) or {}) do
			slots[#slots + 1] = slot
		end
	end
	if #slots == 0 and type(record.reagents) == "table" then
		local ids = {}
		for itemID, quantity in pairs(record.reagents) do
			if IsID(itemID) and IsID(quantity) then
				ids[#ids + 1] = itemID
			end
		end
		table.sort(ids)
		for _, itemID in ipairs(ids) do
			slots[#slots + 1] = { items = { itemID }, quantity = record.reagents[itemID] }
		end
	end
	return slots
end

-- The crafting profit of a recipe, or nil when profits are not available or the recipe has no record. `record` is the addon's recipe
-- record ({ output, outputCount, reagents = { [itemID] = quantity }, slots = { { items = { itemID, ... }, quantity } } }); without
-- one the saved recipe, else the bundled data's, is used (ns.GetRecipeRecord). Returns
--	{ recipeID, profit, cost, value, count, age, missing, exact }
--	profit = value x 0.95 - cost, in copper (nil when the result has no price or the recipe no ingredients)
--	cost = what the ingredients cost, value = the auction price of the result x count (nil without a price), count = items made by
--	one craft
--	missing = true when the result or any ingredient has no price: the profit is unknown, or only partial
--	partial = true when the result is priced but some ingredients are not: profit and cost then count those as free, and
--	unpriced lists one item ID of each of them (without a result price cost is nil as soon as an ingredient has no price)
--	age = days since the oldest auction price used was seen (nil when Auctionator does not say), exact = every auction price used is
--	exact data (not an estimate)
function ns.GetRecipeProfit(recipeID, record)
	if not ns.IsProfitAvailable() then
		return nil
	end
	local api = GetAPI()
	if record == nil and ns.GetRecipeRecord then
		record = ns.GetRecipeRecord(recipeID)
	end
	record = PlainTable(record)
	if not record then
		return nil
	end

	local count = 1
	if IsID(record.outputCount) then
		count = record.outputCount
	elseif ns.RecipeOutputCounts and IsID(ns.RecipeOutputCounts[recipeID]) then
		count = ns.RecipeOutputCounts[recipeID]
	end
	local output = record.output
	if not IsID(output) and ns.RecipeOutputs and IsID(recipeID) and IsID(ns.RecipeOutputs[recipeID]) then
		output = ns.RecipeOutputs[recipeID]
	end

	local age, exact = nil, true
	local function UseAuctionData(itemID)
		local days = AuctionAge(api, itemID)
		if days and (age == nil or days > age) then
			age = days
		end
		if not AuctionExact(api, itemID) then
			exact = false
		end
	end

	local value
	local resultPrice, resultAge, resultExact
	if IsID(output) then
		resultPrice, resultAge, resultExact = ResultPrice(api, recipeID, output)
	end
	if resultPrice then
		value = resultPrice * count
		age = resultAge
		exact = resultExact == true
	end

	local cost, unpriced = 0, {}
	local slots = SlotsOf(record, recipeID)
	for _, slot in ipairs(slots) do
		local cheapest, cheapestItem, fromAuction
		for _, itemID in ipairs(slot.items) do
			local price, auction = UnitCost(api, itemID)
			if price and (cheapest == nil or price < cheapest) then
				cheapest, cheapestItem, fromAuction = price, itemID, auction
			end
		end
		if cheapest then
			cost = cost + cheapest * slot.quantity
			if fromAuction then
				UseAuctionData(cheapestItem)
			end
		else
			unpriced[#unpriced + 1] = slot.items[1]
		end
	end

	local info = { recipeID = recipeID, count = count, value = value, age = age, exact = exact }
	if #slots > 0 and (#unpriced == 0 or value) then
		info.cost = cost
	end
	if info.value and info.cost then
		info.profit = info.value * AH_CUT - info.cost
	end
	info.partial = info.profit ~= nil and #unpriced > 0
	info.unpriced = #unpriced > 0 and unpriced or nil
	info.missing = info.profit == nil or info.partial
	return info
end

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

-- Money as text: the client's coin string (with the gold, silver and copper icons) when it has one, else plain "1g 2s 3c".
local function FormatCoin(copper)
	copper = math.floor((PlainNumber(copper) and copper or 0) + 0.5)
	if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		local ok, text = pcall(C_CurrencyInfo.GetCoinTextureString, copper)
		if ok and PlainString(text) then
			return text
		end
	end
	if GetMoneyString then
		local ok, text = pcall(GetMoneyString, copper)
		if ok and PlainString(text) then
			return text
		end
	end
	local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = gold .. "g"
	end
	if silver > 0 then
		parts[#parts + 1] = silver .. "s"
	end
	if copper % 100 > 0 or #parts == 0 then
		parts[#parts + 1] = (copper % 100) .. "c"
	end
	return table.concat(parts, " ")
end

ns.FormatProfitCoin = FormatCoin

-- The profit of ns.GetRecipeProfit's answer as colored money: green from 0 up, red below it ("-" before the amount), grey "?" when
-- it is not known (no result price, or no answer), and all grey with a "~" before it when it is only partial.
function ns.FormatProfit(info)
	local profit = type(info) == "table" and info.profit or nil
	if not PlainNumber(profit) then
		return "|c" .. GREY .. "?|r"
	end
	local rounded = math.floor(math.abs(profit) + 0.5)
	if info.partial then
		return "|c" .. GREY .. "~" .. (profit < 0 and rounded > 0 and "-" or "") .. FormatCoin(rounded) .. "|r"
	end
	if profit < 0 and rounded > 0 then
		return "|c" .. RED .. "-" .. FormatCoin(rounded) .. "|r"
	end
	return "|c" .. GREEN .. FormatCoin(rounded) .. "|r"
end

-- Adds the profit lines of ns.GetRecipeProfit's answer to a tooltip.
function ns.AddProfitTooltip(tooltip, info)
	if not tooltip or type(info) ~= "table" then
		return
	end
	tooltip:AddLine(" ")
	tooltip:AddLine("Crafting profit: " .. ns.FormatProfit(info), 1, 1, 1)
	if info.cost then
		tooltip:AddLine((info.partial and "Ingredients cost at least " or "Ingredients cost ") .. FormatCoin(info.cost), 0.8, 0.8, 0.8)
	end
	if info.value then
		local text = "Sells for " .. FormatCoin(info.value)
		if info.count and info.count > 1 then
			text = text .. " (" .. info.count .. " made)"
		end
		tooltip:AddLine(text .. ", " .. math.floor(AH_CUT * 100 + 0.5) .. "% after the auction house cut", 0.8, 0.8, 0.8, true)
	end
	if info.partial then
		tooltip:AddLine("Partial profit: the ingredients below count as free.", 1, 0.6, 0.2, true)
	elseif info.missing then
		tooltip:AddLine("Auctionator has no price for the result or for an ingredient, so the profit is unknown.", 1, 0.6, 0.2, true)
	end
	local listed = 0
	for _, itemID in ipairs(info.unpriced or {}) do
		listed = listed + 1
		if listed <= 5 then
			tooltip:AddLine((ns.GetItemName and ns.GetItemName(itemID) or ("item:" .. itemID)) .. " \226\128\148 no price yet \226\128\148 visit a vendor or scan the AH", 1, 0.6, 0.2, true)
		end
	end
	if listed > 5 then
		tooltip:AddLine("... and " .. (listed - 5) .. " more", 1, 0.6, 0.2)
	end
	if info.age then
		local days = math.floor(info.age)
		tooltip:AddLine("Oldest auction data used: " .. (days < 1 and "less than a day" or (days .. (days == 1 and " day" or " days"))), 0.6, 0.6, 0.6)
	end
end

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

-- The profit of an answer, nil when it is not known.
local function ProfitOf(info)
	local profit = type(info) == "table" and info.profit or nil
	if PlainNumber(profit) then
		return profit
	end
end

-- Does the answer `a` come before `b` when the most profitable come first and the unknown profits last? A partial profit counts
-- with its value (after a fully priced one of the same value). true or false when they differ, nil when they rank the same (the
-- caller then uses its own order).
function ns.CompareProfit(a, b)
	local pa, pb = ProfitOf(a), ProfitOf(b)
	if pa == pb then
		-- Equal values: a fully priced profit before a partial one.
		if pa ~= nil and (a.partial or false) ~= (b.partial or false) then
			return not a.partial
		end
		return nil
	elseif pa == nil then
		return false
	elseif pb == nil then
		return true
	end
	return pa > pb
end

-- A copy of the list ordered by profit (see ns.CompareProfit) that keeps the list's own order among equals. infoOf(item) gives the
-- answer of ns.GetRecipeProfit for an item.
function ns.SortByProfit(list, infoOf)
	local ordered = {}
	for index, item in ipairs(list) do
		ordered[index] = { item = item, index = index, info = infoOf(item) }
	end
	table.sort(ordered, function(a, b)
		local before = ns.CompareProfit(a.info, b.info)
		if before ~= nil then
			return before
		end
		return a.index < b.index
	end)
	local sorted = {}
	for index, entry in ipairs(ordered) do
		sorted[index] = entry.item
	end
	return sorted
end

--------------------------------------------------------------------------------
-- The recipes of the open profession
--------------------------------------------------------------------------------

-- The learned recipes of the open profession with their profits: { recipeID, name, icon, output, info }. Returns nil and a reason
-- ("closed": no list to read, "foreign": not the player's own profession) when there is nothing to list.
local function CollectRecipes()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo) then
		return nil, "closed"
	end
	if ns.IsOwnTradeSkillOpen and not ns.IsOwnTradeSkillOpen() then
		return nil, "foreign"
	end
	local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	ids = ok and PlainTable(ids) or nil
	if not ids or #ids == 0 then
		return nil, "closed"
	end
	ns.ResetProfitCache()
	local list, seen = {}, {}
	for _, recipeID in ipairs(ids) do
		if IsID(recipeID) and not seen[recipeID] then
			seen[recipeID] = true
			local okInfo, recipeInfo = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
			recipeInfo = okInfo and PlainTable(recipeInfo) or nil
			local name = recipeInfo and PlainString(recipeInfo.name) or nil
			local learned = recipeInfo and recipeInfo.learned
			if name and not IsSecret(learned) and learned == true then
				local icon = recipeInfo.icon
				if IsSecret(icon) or (type(icon) ~= "number" and type(icon) ~= "string") then
					icon = nil
				end
				local record = ns.GetRecipeRecord and ns.GetRecipeRecord(recipeID) or nil
				if not record and ns.ReadRecipeSchematic then
					record = ns.ReadRecipeSchematic(recipeID)
				end
				list[#list + 1] = {
					recipeID = recipeID, name = name, icon = icon,
					output = record and IsID(record.output) and record.output or nil,
					info = record and ns.GetRecipeProfit(recipeID, record) or nil,
				}
			end
		end
	end
	return list
end

--------------------------------------------------------------------------------
-- Blizzard's recipe list, sorted by crafting profit
--------------------------------------------------------------------------------

local recipeList -- ProfessionsFrame.CraftingPage.RecipeList
local replacing = false -- our own SetDataProvider is running: its OnDataProviderReassigned is not the client's
local nativeProvider -- the last provider the client gave the list
local builtProviders = setmetatable({}, { __mode = "k" }) -- the providers this addon built
local listOwner = {} -- the owner of our callback on the ScrollBox (another addon's callback has its own)
local filterMenu -- the Menu.ModifyMenu registration, nil while it is withdrawn

-- Is SkillUp Forever loaded? It sorts this list itself, so this addon leaves it alone.
local function SkillUpLoaded()
	local loaded
	if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
		local ok, value = pcall(C_AddOns.IsAddOnLoaded, "SkillUpForever")
		loaded = ok and value
	elseif type(IsAddOnLoaded) == "function" then
		local ok, value = pcall(IsAddOnLoaded, "SkillUpForever")
		loaded = ok and value
	end
	return not IsSecret(loaded) and loaded == true
end

-- Is the gamepad interface on?
local function GamepadUI()
	if InputUtil and type(InputUtil.IsGamepadUIEnabled) == "function" then
		local ok, value = pcall(InputUtil.IsGamepadUIEnabled)
		return ok and not IsSecret(value) and value == true
	end
	return false
end

-- Should the list be sorted by profit now?
local function WantProfitList()
	return settings ~= nil and settings.listSort == "profit" and ns.IsProfitAvailable() and not SkillUpLoaded()
		and ns.IsOwnTradeSkillOpen ~= nil and ns.IsOwnTradeSkillOpen()
end

-- The recipes of a provider's nodes, depth first: the client's own node data tables, learned and unlearned apart, and the favourites
-- copies (favoritesInstance) apart from both. A recipe seen twice is skipped (a favourites copy is another row than the recipe's own).
-- The client finds the row it selects by its recipe and favoritesInstance, so the copies have to be in the new list too.
local function CollectListRecipes(node, learned, unlearned, seen, favorites)
	for _, child in ipairs(node:GetNodes()) do
		local data = child:GetData()
		local info = type(data) == "table" and not IsSecret(data) and data.recipeInfo or nil
		if type(data) == "table" and not info then
			CollectListRecipes(child, learned, unlearned, seen, favorites)
		elseif type(info) == "table" and not IsSecret(info) and IsID(info.recipeID) and not IsSecret(info.learned)
			and not IsSecret(info.favoritesInstance) then
			if info.favoritesInstance then
				if info.learned and not seen["f" .. info.recipeID] then
					seen["f" .. info.recipeID] = true
					favorites[#favorites + 1] = data
				end
			elseif not seen[info.recipeID] then
				seen[info.recipeID] = true
				local list = info.learned and learned or unlearned
				list[#list + 1] = data
			end
		end
	end
end

-- The profit of a recipe for the list: the saved or bundled recipe's, else the open window's schematic.
local function ListProfit(recipeID)
	local record = ns.GetRecipeRecord and ns.GetRecipeRecord(recipeID) or nil
	if not record and ns.ReadRecipeSchematic then
		record = ns.ReadRecipeSchematic(recipeID)
	end
	return record and ns.GetRecipeProfit(recipeID, record) or nil
end

local function CompareNames(a, b)
	if type(strcmputf8i) == "function" then
		return strcmputf8i(a, b)
	end
	a, b = a:lower(), b:lower()
	return a < b and -1 or (a > b and 1 or 0)
end

-- A flat provider holding the client's learned recipes by profit (highest first, a partial profit by its value, unknown last, then by
-- name and recipe ID), then the client's divider and its unlearned recipes in the client's order.
local function BuildSortedProvider(source)
	local learned, unlearned, seen, favorites = {}, {}, {}, {}
	CollectListRecipes(source:GetRootNode(), learned, unlearned, seen, favorites)
	-- (the prices come from the cache, which runs out after a couple of seconds: the client builds this list on every Init)
	local function Keyed(list)
		local keyed = {}
		for index, data in ipairs(list) do
			local info = data.recipeInfo
			keyed[index] = { data = data, info = ListProfit(info.recipeID), name = PlainString(info.name) or "", id = info.recipeID }
		end
		table.sort(keyed, function(a, b)
			local before = ns.CompareProfit(a.info, b.info)
			if before ~= nil then
				return before
			end
			local byName = CompareNames(a.name, b.name)
			if byName ~= 0 then
				return byName < 0
			end
			return a.id < b.id
		end)
		return keyed
	end
	local keyed = Keyed(learned)

	local sorted = CreateTreeDataProvider()
	for _, entry in ipairs(Keyed(favorites)) do
		sorted:Insert(entry.data)
	end
	for _, entry in ipairs(keyed) do
		sorted:Insert(entry.data)
	end
	-- Blizzard's divider template draws the "Unlearned" label itself.
	if #unlearned > 0 then
		sorted:Insert({ isDivider = true, dividerHeight = (#keyed > 0 or #favorites > 0) and 70 or 30 })
		for _, data in ipairs(unlearned) do
			sorted:Insert(data)
		end
	end
	return sorted
end

-- What a row is: its recipe (and whether it is the favourites copy), its category, or its spacer. Dividers and categories are new
-- tables on every build, so rows compare by this, not by table.
local function RowKey(data)
	local info = type(data) == "table" and data.recipeInfo or nil
	if info then
		return "r" .. tostring(info.recipeID) .. (info.favoritesInstance and "f" or "") .. (info.learned and "" or "u")
	end
	if type(data) == "table" and data.categoryInfo then
		return "c" .. tostring(data.categoryInfo.categoryID)
	end
	data = type(data) == "table" and data or {}
	return ("s%s:%s:%s"):format(tostring(data.dividerHeight), tostring(data.topPadding), tostring(data.bottomPadding))
end

-- Whether two providers hold the same rows in the same order, depth first. A provider that holds the rows already shown is not
-- put in: replacing it clears the client's row selection, and only the client's own Init selects again.
local function SameRows(a, b)
	local left, right = {}, {}
	local function Walk(node, out)
		for _, child in ipairs(node:GetNodes()) do
			out[#out + 1] = RowKey(child:GetData())
			Walk(child, out)
		end
	end
	Walk(a:GetRootNode(), left)
	Walk(b:GetRootNode(), right)
	if #left ~= #right then
		return false
	end
	for index = 1, #left do
		if left[index] ~= right[index] then
			return false
		end
	end
	return true
end

-- Gives the ScrollBox a provider (the only thing of Blizzard's state this addon writes). Returns false when that failed.
local function SetListProvider(scrollBox, provider)
	local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
	replacing = true
	local ok, err = pcall(scrollBox.SetDataProvider, scrollBox, provider, retain)
	replacing = false
	return ok, err
end

-- Sorting failed: the setting goes back to the client's order, with one message.
local function SortFailed(err)
	settings.listSort = "blizzard"
	if ns.SettingsChanged then
		ns.SettingsChanged()
	end
	ns.Print("Sorting the profession list by crafting profit failed and has been turned off: " .. tostring(err))
end

-- OnDataProviderReassigned (and a change of the setting): puts the sorted provider in place of the client's, or the client's back.
-- Rebuilt from the client's own provider, so a redraw never sorts or copies our own rows.
local function ApplyList(scrollBox)
	if replacing or SkillUpLoaded() then
		return
	end
	local source = scrollBox:GetDataProvider()
	if not (type(source) == "table" and source.GetRootNode) then
		return
	end
	-- A provider the client built replaces the one we kept; ours replacing itself does not.
	if not builtProviders[source] then
		nativeProvider = source
	end
	local base = builtProviders[source] and nativeProvider or source
	local built
	if WantProfitList() then
		local ok, result = pcall(BuildSortedProvider, base)
		if ok then
			built = result
		else
			SortFailed(result)
		end
	end
	if not built then
		if builtProviders[source] and nativeProvider then
			local ok, err = SetListProvider(scrollBox, nativeProvider)
			if not ok then
				ns.Print("Putting the profession list back failed: " .. tostring(err))
			end
		end
		return
	end
	if SameRows(source, built) then
		return
	end
	builtProviders[built] = true
	local ok, err = SetListProvider(scrollBox, built)
	if not ok then
		-- It may have failed after the list took our provider: then ours stays marked as ours and the client's is put back.
		local okCurrent, current = pcall(scrollBox.GetDataProvider, scrollBox)
		if okCurrent and current == built then
			if nativeProvider then
				SetListProvider(scrollBox, nativeProvider)
			end
		else
			builtProviders[built] = nil
		end
		SortFailed(err)
	end
end

-- Applies the setting to the list as it is now (never through the crafting page's Init), when the list is up and the window has its
-- profession; a list that is not shown is done when the client gives it its next provider.
local function ApplyCurrentList()
	if not (recipeList and type(recipeList.ScrollBox) == "table") then
		return
	end
	local okVisible, visible = pcall(function() return recipeList:IsVisible() end)
	if okVisible and visible and ProfessionsFrame and ProfessionsFrame.professionInfo then
		pcall(ApplyList, recipeList.ScrollBox)
	end
end

local function SetListSort(mode)
	if not (settings and LIST_SORTS[mode]) or (mode == "profit" and SkillUpLoaded()) then
		return
	end
	settings.listSort = mode
	ApplyCurrentList()
	if ns.RefreshRecipesPage then
		ns.RefreshRecipesPage() -- the check box of the Recipes tab follows the menu
	end
	if ns.SettingsChanged then
		ns.SettingsChanged()
	end
end

-- Stores a sort mode from a settings profile ("blizzard" or "profit"), even while SkillUp Forever sorts the list (SetListSort does not take
-- "profit" then: the check box is greyed out): the choice is kept and shows again when it does not. Applied to the list like a choice made
-- in the menu. Returns false for a bad call.
function ns.ApplyProfitListSort(mode)
	if not (settings and LIST_SORTS[mode]) then
		return false
	end
	if settings.listSort ~= mode then
		settings.listSort = mode
		ApplyCurrentList()
		if ns.RefreshRecipesPage then
			ns.RefreshRecipesPage()
		end
		if ns.SettingsChanged then
			ns.SettingsChanged()
		end
	end
	return true
end

-- The check box of the Recipes tab (and the gamepad interface, whose menu this addon does not touch): the profit sort of the list on
-- or off. Not while SkillUp Forever sorts the list.
function ns.IsProfitListSorted()
	return settings ~= nil and settings.listSort == "profit" and not SkillUpLoaded()
end

function ns.IsProfitListSortBlocked()
	return SkillUpLoaded()
end

function ns.SetProfitListSort(enabled)
	SetListSort(enabled and "profit" or "blizzard")
end

local SKILLUP_TEXT = "Crafting profit (SkillUp Forever sorts this list)"

-- The "Sort by" section at the bottom of Blizzard's Filter menu. The same menu serves other recipe lists, so only the crafting
-- page's dropdown gets it, and only while profits are available.
local function AddFilterMenu(owner, rootDescription)
	if not (recipeList and owner == recipeList.FilterDropdown and ns.IsProfitAvailable()) then
		return
	end
	rootDescription:CreateDivider()
	rootDescription:CreateTitle("Sort by (Jimmy's Utils)")
	local function IsSelected(mode)
		-- SkillUp Forever sorts the list: that is Default as far as this addon goes, whatever is saved.
		return (SkillUpLoaded() and "blizzard" or settings.listSort) == mode
	end
	local function Select(mode)
		SetListSort(mode)
		return MenuResponse and MenuResponse.Refresh
	end
	rootDescription:CreateRadio("Default", IsSelected, Select, "blizzard")
	if SkillUpLoaded() then
		local radio = rootDescription:CreateRadio(SKILLUP_TEXT, IsSelected, Select, "profit")
		if radio and radio.SetEnabled then
			radio:SetEnabled(false)
		end
	else
		rootDescription:CreateRadio("Crafting profit", IsSelected, Select, "profit")
	end
end

-- Blizzard's Filter menu is opened by the client's own gamepad footer. A section built by addon code taints that menu and the
-- gamepad frame manager then writes its state as ours, which the next secure reader has refused. With the gamepad interface on the
-- client's own filters still show; the modification is withdrawn then and put back for mouse and keyboard.
local function SyncFilterMenu()
	if GamepadUI() then
		if filterMenu then
			filterMenu:Unregister()
			filterMenu = nil
		end
	elseif not filterMenu and Menu and type(Menu.ModifyMenu) == "function" then
		local ok, registration = pcall(Menu.ModifyMenu, "MENU_PROFESSIONS_FILTER", AddFilterMenu)
		filterMenu = ok and registration or nil
	end
end

-- Hooks the crafting page's recipe list once the profession window exists.
local function AttachRecipeList(window)
	local page = window.CraftingPage
	local list = type(page) == "table" and not IsSecret(page) and page.RecipeList or nil
	local scrollBox = type(list) == "table" and list.ScrollBox or nil
	if type(scrollBox) ~= "table" or type(scrollBox.RegisterCallback) ~= "function" then
		return
	end
	recipeList = list
	scrollBox:RegisterCallback("OnDataProviderReassigned", function(_, box)
		ApplyList(box or scrollBox)
	end, listOwner)
	SyncFilterMenu()
	ApplyCurrentList()
end

-- Hooks the profession window's recipe list once the window exists. Returns true once that is done (also when it already was).
local function Attach()
	if attached then
		return true
	end
	local frame = ProfessionsFrame
	if type(frame) ~= "table" or IsSecret(frame) then
		return false
	end
	attached = true
	AttachRecipeList(frame)
	return true
end

--------------------------------------------------------------------------------
-- /ju profit: what the numbers are made of, in the chat
--------------------------------------------------------------------------------

-- Plain money text (no icons, so it can be copied): "1g 2s 3c", "-" for nil.
local function Money(copper)
	if not PlainNumber(copper) then
		return "-"
	end
	local sign = copper < 0 and "-" or ""
	copper = math.floor(math.abs(copper) + 0.5)
	local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local text = rest .. "c"
	if gold > 0 or silver > 0 then
		text = silver .. "s " .. text
	end
	if gold > 0 then
		text = gold .. "g " .. text
	end
	return sign .. text
end

local function ItemLabel(itemID)
	local name = ns.GetItemName and ns.GetItemName(itemID) or nil
	return (PlainString(name) or "item") .. " (" .. tostring(itemID) .. ")"
end

-- The detail of one recipe: where the result's price comes from and what each slot costs.
local function PrintRecipeDetail(entry)
	local api = GetAPI()
	local record = ns.GetRecipeRecord and ns.GetRecipeRecord(entry.recipeID) or nil
	local source = record and "saved or bundled" or nil
	if not record and ns.ReadRecipeSchematic then
		record = ns.ReadRecipeSchematic(entry.recipeID)
		source = record and "profession window" or nil
	end
	local info = entry.info or {}
	ns.Print(Escape(entry.name) .. " (recipe " .. tostring(entry.recipeID) .. ", data: " .. (source or "none") .. ")")
	if not record then
		return
	end
	local output = record.output
	if IsID(output) then
		local link = OutputLink(entry.recipeID, output)
		local byLink = link and Call(api, "GetAuctionPriceByItemLink", link) or nil
		local byID = Call(api, "GetAuctionPriceByItemID", output)
		ns.Print(string.format("  makes %s x%s: by link %s, by item ID %s%s", ItemLabel(output), tostring(info.count or 1),
			Money(byLink), Money(byID), link and "" or " (no link)"))
	else
		ns.Print("  makes no known item")
	end
	for _, slot in ipairs(SlotsOf(record, entry.recipeID)) do
		local parts = {}
		for _, itemID in ipairs(slot.items) do
			local vendor = Call(api, "GetVendorPriceByItemID", itemID)
			local auction = Call(api, "GetAuctionPriceByItemID", itemID)
			local unit = UnitCost(api, itemID)
			parts[#parts + 1] = string.format("%s vendor %s, AH %s, used %s", ItemLabel(itemID), Money(vendor), Money(auction), Money(unit))
		end
		ns.Print("  " .. slot.quantity .. "x " .. table.concat(parts, " | or "))
	end
	ns.Print(string.format("  value %s, x0.95 = %s, cost %s, profit %s%s", Money(info.value),
		Money(info.value and info.value * AH_CUT), Money(info.cost), Money(info.profit), info.partial and " (partial)" or ""))
end

-- /ju profit: the learned recipes of the open profession in the order of the Filter-menu sort (by profit, highest first, partial profits
-- by their value, unknown last, then by name) and their numbers. /ju profit <text>: the detail of the recipes whose name contains the text.
function ns.HandleProfitCommand(rest)
	rest = (rest or ""):match("^%s*(.-)%s*$")
	if not GetAPI() then
		ns.Print("Crafting profit needs Auctionator.")
		return
	end
	local list, reason = CollectRecipes()
	if not list then
		ns.Print(reason == "foreign" and "Crafting profit is only listed for your own professions." or "Open one of your professions first.")
		return
	end
	if rest ~= "" then
		local wanted, found = rest:lower(), 0
		for _, entry in ipairs(list) do
			if entry.name:lower():find(wanted, 1, true) then
				found = found + 1
				if found <= 5 then
					PrintRecipeDetail(entry)
				end
			end
		end
		if found == 0 then
			ns.Print("No recipe of this profession matches \"" .. Escape(rest) .. "\".")
		elseif found > 5 then
			ns.Print("... and " .. (found - 5) .. " more; type more of the name.")
		end
		return
	end
	table.sort(list, function(a, b)
		local before = ns.CompareProfit(a.info, b.info)
		if before ~= nil then
			return before
		end
		local byName = CompareNames(a.name, b.name)
		if byName ~= 0 then
			return byName < 0
		end
		return a.recipeID < b.recipeID
	end)
	ns.Print(string.format("%d learned recipes, by profit:", #list))
	for index, entry in ipairs(list) do
		local info = entry.info or {}
		ns.Print(string.format("%d. %s: profit %s%s, value %s (x%s), cost %s", index, Escape(entry.name), Money(info.profit),
			info.partial and " (partial)" or "", Money(info.value), tostring(info.count or 1), Money(info.cost)))
	end
	ns.Print("/ju profit <name> shows where a recipe's numbers come from.")
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- The prices came, went or were switched off: everything that shows a profit follows (the saved choices are never changed here). Off puts
-- the client's order back in its list and hides the sort buttons of the windows; on sorts again.
local function RefreshProfitUI()
	ns.ResetProfitCache()
	ApplyCurrentList()
	if ns.RefreshRecipesWindow then
		ns.RefreshRecipesWindow()
	end
	if ns.RefreshMailMaterials then
		ns.RefreshMailMaterials()
	end
	if ns.RefreshRecipesPage then
		ns.RefreshRecipesPage()
	end
end

-- Switches the crafting profit on or off (the option).
function ns.SetProfitEnabled(enabled)
	if not settings or type(enabled) ~= "boolean" then
		return false
	end
	settings.enabled = enabled
	RefreshProfitUI()
	if ns.SettingsChanged then
		ns.SettingsChanged()
	end
	return true
end

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db)
	if type(db.profit) ~= "table" then
		db.profit = {}
	end
	settings = db.profit
	for name, default in pairs(DEFAULTS) do
		if type(settings[name]) ~= type(default) then
			settings[name] = default
		end
	end
	for _, name in ipairs(OLD_SETTINGS) do
		settings[name] = nil
	end
	if not LIST_SORTS[settings.listSort] then
		settings.listSort = DEFAULTS.listSort
	end
end

function ns.InitProfit(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)

	local driver = CreateFrame("Frame")
	-- An event this client does not have must not stop the others from being registered.
	for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "INPUT_DEVICE_INTERFACE_TRANSITION" }) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript("OnEvent", function(_, event, loadedName)
		if event == "ADDON_LOADED" then
			if loadedName == "Blizzard_Professions" then
				Attach()
			elseif loadedName == "Auctionator" then
				RefreshProfitUI() -- the prices are there now
			end
		elseif event == "PLAYER_LOGIN" then
			RefreshProfitUI() -- Auctionator's database of prices is made by now
		else
			SyncFilterMenu()
		end
	end)
	Attach()
end

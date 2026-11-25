local addonName, ns = ...

--[[
	Stat weight scores in the auction house: Blizzard's Browse tab (AuctionHouseFrame.BrowseResultsFrame, from the load-on-demand
	addon Blizzard_AuctionHouseUI) gets one score column per profile shown in the tooltips (the first MAX_COLUMNS in the order of
	ns.GetShownProfileNames; more shown profiles are simply not listed), and clicking the header of one of them sorts the results
	by that profile's score, highest first. The columns are left out while none of the loaded results is equipment (a search for
	reagents, say); while that can't be told yet (a search with no rows so far) the last state is kept, so they don't flicker.

	Scores: a browse row is an item key (item ID, item level, random suffix), so each equippable row is scored from the tooltip
	data of its exact key (C_TooltipInfo.GetItemKey) through the same ns.CollectItemStats and ns.ComputeScore as the item
	tooltips, so a column shows what the tooltip of that item shows (decimals and "Hide score when 0" apply too). The stats are
	cached per item key; the scores are computed from the cached stats. Items that are not equippable have an empty cell (the
	item class data of C_Item.GetItemInfoInstant says so), and so do items the client has not loaded yet: the item data is
	requested and the list is refreshed (a moment after the data arrives) when it comes. "Not scorable" is only remembered for an
	item whose data is loaded, so a row is never left blank for good because the client was slow. The link the stats are read
	from is found the way Blizzard's own auction tooltip finds it: C_AuctionHouse.GetItemKeySampleLink of the item key, else the
	hyperlink of its tooltip data; no link yet means the item is not ready (nothing is built by hand). Battle pets and the like
	are never scored.

	Columns: Blizzard's own layout function is wrapped, not replaced: the wrapper calls it, then appends the score columns after
	its columns. The wrapper is handed to the item list through its own SetTableBuilderLayout (the browse frame's
	SetupTableBuilder, which Blizzard runs again when the category changes, is hooked to wrap the new layout). The headers are
	Blizzard's own AuctionHouseTableHeaderStringTemplate, built unsortable (no sort order) and then enabled: the "owner" given to
	the header is a small table of ours, so the header's own OnClick ends in our SetSortOrder and its arrow follows our
	GetSortOrderState; nothing is ever sent to the auction house. The cells are plain frames of ours from a small pool of ours (the
	column's cell pool is set after Blizzard's AddColumn), so there is no XML template and no global mixin.

	Sorting: the browse frame keeps its rows in the array browseResults, which the item list reads by index (and by row table: a
	selected row is the table itself, so the row to buy is whatever table Blizzard handed out, whatever its position). With a
	sort on, that array is reordered in place after every UpdateBrowseResults (hooksecurefunc: the first page, each page that
	arrives while scrolling, a full update) and the list is marked dirty so it redraws. Rows without a score come after the
	scored ones, ties keep Blizzard's order (every row gets a sequence number when first seen). Only the pages loaded so far
	are sorted: the results still come from the server in Blizzard's order, page by page, so rows of a later page can move up
	into the sorted list when they arrive. Clicking the same header again, or any of Blizzard's own sort headers (its browse
	frame's SetSortOrder is hooked), puts the sort off, and the rows go back to Blizzard's order. The array is never touched
	while no sort is on. Only hooksecurefunc and Blizzard's public SetTableBuilderLayout / DirtyScrollFrame are used; no function
	of Blizzard's is replaced.

	Saved data (validated in ns.InitAuctionScores):
		JimmysStatWeightsDB.auctionScores = { enabled = true, sortProfile = nil }
		-- enabled: the option "Show stat weight scores in the auction house"; sortProfile: the profile the list is sorted by.
		-- The setting is account-wide, so the sort profile is only forgotten when its profile is deleted. While the columns are
		-- not shown (the option or the tooltip scores are off, the profile is hidden for this character, or it is not among the
		-- first MAX_COLUMNS) the choice is kept but does nothing.
]]

local IsSecret = issecretvalue or function() return false end

local BLIZZARD_ADDON = "Blizzard_AuctionHouseUI"
local HEADER_TEMPLATE = "AuctionHouseTableHeaderStringTemplate"
local MAX_COLUMNS = 3 -- the Name column keeps about 140 px of the list with three
local CELL_PADDING = 4
local COLUMN_SLACK = 2 -- on top of the widest score and the cell padding, so rounding never cuts a digit
local SCORE_SAMPLE_DIGITS = 4 -- the columns are as narrow as a score with four digits before the point allows
local FALLBACK_CHAR_WIDTH = 7 -- used when the client can't measure text
local HEADER_CHARS = 7 -- at most; longer profile names are cut (the tooltip of the header has the full name)
local MIN_HEADER_CHARS = 3
local RESOLVE_PER_PASS = 300 -- item keys read from the client per sort pass; the rest follows on the next pass
local PASS_DELAY = 0.05
local ITEM_DATA_DELAY = 0.25 -- item data arrives in bursts: one refresh for all of it
local MAX_REQUESTS = 3 -- requests for the data of one item before it is given up on
local MAX_CACHED = 6000
local SCORE_COLOR = { 0.4, 0.78, 1 } -- the color of the tooltip line

local DEFAULTS = {
	enabled = true,
}

-- Set in ns.InitAuctionScores.
local settings
local initialized = false

local browse -- AuctionHouseFrame.BrowseResultsFrame, once it exists
local queued = false -- a refresh is waiting on a timer
local queuedForce = false
local builtSignature -- the profiles of the columns the layout was last built with
local fetchBudget -- item keys that may still be read in the current sort pass (nil: unlimited)
local deferred = false -- the last sort pass stopped reading item keys because of the budget
local broken = false -- adding the columns failed once: they stay off until the next /reload
local resultsHaveGear = true -- the browse results hold equipment (kept while that can't be told, e.g. a search with no rows yet)
local stale = false -- results changed while the Browse list was not on screen: caught up when it shows
local scanResults = false -- the current results are a scan of the whole auction house (Auctionator's autoscan): no columns for them
local queryHooked = false

local wrappers = setmetatable({}, { __mode = "k" }) -- the layout functions this addon made
local order = setmetatable({}, { __mode = "k" }) -- the sequence number of every row seen by a sort: Blizzard's order
local reordered = setmetatable({}, { __mode = "k" }) -- the browseResults arrays this addon put in sorted order
local hookedHeaders = setmetatable({}, { __mode = "k" })
local nextOrder = 0
local scoreHeaders = {} -- the headers of the current layout

local statsCache = {} -- [item key string] = stats table, or false for "no stats"
local cached = 0
local cachedParse -- the "Equip: text" setting the cache was filled with
local pending = {} -- [itemID] = true while the client is asked for its data
local requests = {} -- [itemID] = how often its data was asked for

--------------------------------------------------------------------------------
-- Which profiles have a column, and which one the list is sorted by
--------------------------------------------------------------------------------

-- The profiles that get a column, in column order: none while the option or the tooltip scores are off, or while no browse result
-- is equipment.
local function ColumnProfiles()
	local names = {}
	if settings and settings.enabled and not broken and resultsHaveGear and not scanResults and ns.IsStatsEnabled() then
		for _, name in ipairs(ns.GetShownProfileNames()) do
			if #names < MAX_COLUMNS then
				names[#names + 1] = name
			end
		end
	end
	return names
end

-- (the decimals are in it: the width of the columns follows them)
local function Signature()
	return table.concat(ColumnProfiles(), "\n") .. "\n" .. tostring(ns.GetSetting("decimals"))
end

-- The profile the list is sorted by right now (nil: Blizzard's order).
local function ActiveSortProfile()
	local profile = settings and settings.sortProfile
	if not profile then
		return nil
	end
	for _, name in ipairs(ColumnProfiles()) do
		if name == profile then
			return profile
		end
	end
end

-- A profile that was deleted can no longer be the sort (one that is only hidden on this character keeps the choice, which then does
-- nothing: the setting is account-wide).
local function CleanSortProfile()
	if settings and settings.sortProfile and not ns.GetProfileWeights(settings.sortProfile) then
		settings.sortProfile = nil
	end
end

--------------------------------------------------------------------------------
-- Scores
--------------------------------------------------------------------------------

local function IsNumber(value)
	return not IsSecret(value) and type(value) == "number" and value == value
end

-- The cache key of an item key ("itemID:itemLevel:itemSuffix"); nil for what is not scored (battle pets, malformed keys).
local function KeyOf(itemKey)
	if type(itemKey) ~= "table" or IsSecret(itemKey) then
		return nil
	end
	local itemID, level, suffix, pet = itemKey.itemID, itemKey.itemLevel or 0, itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0
	if not (IsNumber(itemID) and IsNumber(level) and IsNumber(suffix) and IsNumber(pet)) or itemID <= 0 or pet ~= 0 then
		return nil
	end
	return itemID .. ":" .. level .. ":" .. suffix
end

-- Item types that have an equip location but never stats worth a column (and that IsEquippableItem would not call equipment).
local NOT_EQUIPMENT = { INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true }

-- Whether an item is equipment, from the item class data the client always has (C_Item.GetItemInfoInstant: no item data needs to be
-- loaded): true or false, or nil while the client does not know the item at all. The second result says whether the data of the item
-- is loaded, which "not equipment" must wait for before it is believed.
local function EquipmentState(itemID)
	local state
	if C_Item and C_Item.GetItemInfoInstant then
		local ok, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, itemID)
		if ok and not IsSecret(equipLoc) and type(equipLoc) == "string" then
			state = equipLoc ~= "" and not NOT_EQUIPMENT[equipLoc]
		end
	elseif C_Item and C_Item.IsEquippableItem then
		local ok, equippable = pcall(C_Item.IsEquippableItem, itemID)
		if ok and not IsSecret(equippable) and type(equippable) == "boolean" then
			state = equippable
		end
	end
	local loaded = true
	if C_Item and C_Item.IsItemDataCachedByID then
		local ok, cachedData = pcall(C_Item.IsItemDataCachedByID, itemID)
		loaded = not ok or IsSecret(cachedData) or cachedData == true
	end
	return state, loaded
end

-- Whether the loaded browse results hold any equipment: true at the first equipment row, false when every row is known not to be,
-- nil when it can't be told (no rows yet, or an item the client does not know at all).
local function ResultsHoldGear()
	local list = browse and browse.browseResults
	if type(list) ~= "table" or IsSecret(list) or #list == 0 then
		return nil
	end
	local unknown = false
	for index = 1, #list do
		local row = list[index]
		local itemKey = type(row) == "table" and not IsSecret(row) and row.itemKey
		if KeyOf(itemKey) then
			local equipment = EquipmentState(itemKey.itemID)
			if equipment then
				return true
			elseif equipment == nil then
				unknown = true
			end
		end
	end
	if unknown then
		return nil
	end
	return false
end

-- Takes the gear state of the current results; true when the columns change because of it.
local function UpdateGearState()
	if scanResults then
		return false -- (a scan holds everything: it says nothing about the searches around it)
	end
	local gear = ResultsHoldGear()
	if gear ~= nil and gear ~= resultsHaveGear then
		resultsHaveGear = gear
		return true
	end
	return false
end

-- The tooltip data of the exact item key (its random suffix and level), nil while the client has not loaded the item.
local function GetTooltipData(itemKey)
	if not (C_TooltipInfo and C_TooltipInfo.GetItemKey) then
		return nil
	end
	local ok, data = pcall(C_TooltipInfo.GetItemKey, itemKey.itemID, itemKey.itemLevel or 0, itemKey.itemSuffix or 0)
	if ok and type(data) == "table" and not IsSecret(data) then
		return data
	end
end

-- The link ns.CollectItemStats needs, found the way Blizzard's auction house tooltip does (Blizzard_AuctionHouseUtil.lua): a sample link
-- of the item key (it carries the key's random suffix), else the hyperlink of the tooltip data of the key. nil when there is none yet.
local function ResolveLink(data, itemKey)
	if C_AuctionHouse and C_AuctionHouse.GetItemKeySampleLink then
		local ok, link = pcall(C_AuctionHouse.GetItemKeySampleLink, itemKey)
		if ok and type(link) == "string" and not IsSecret(link) and link ~= "" then
			return link
		end
	end
	local hyperlink = data.hyperlink
	if type(hyperlink) == "string" and not IsSecret(hyperlink) and hyperlink ~= "" then
		return hyperlink
	end
end

-- Whether tooltip data looks like the item was not fully there when it was made (no lines but the name, or the client's placeholder).
local function LooksIncomplete(data)
	local lines = data.lines
	if type(lines) ~= "table" or IsSecret(lines) or #lines <= 1 then
		return true
	end
	local placeholder = _G.RETRIEVING_ITEM_INFO
	if type(placeholder) == "string" then
		for _, line in ipairs(lines) do
			if type(line) == "table" and not IsSecret(line) and line.leftText == placeholder then
				return true
			end
		end
	end
	return false
end

-- The data of the item is not here yet: ask for it (a few times at most) and refresh when it arrives.
local function RequestItem(itemID)
	local count = requests[itemID] or 0
	if count >= MAX_REQUESTS then
		return
	end
	requests[itemID] = count + 1
	pending[itemID] = true
	if C_Item and C_Item.RequestLoadItemDataByID then
		pcall(C_Item.RequestLoadItemDataByID, itemID)
	end
end

local function Remember(key, stats)
	if cached >= MAX_CACHED then
		statsCache, cached = {}, 0
	end
	statsCache[key] = stats
	cached = cached + 1
end

-- The stats of an item key as the tooltip reads them: a table, or nil for no stats, a row that is not scored or an item that is not
-- loaded yet. The second result is true while more can come (the data was asked for, or this pass ran out of its budget).
local function ResolveStats(itemKey)
	local key = KeyOf(itemKey)
	if not key then
		return nil
	end
	-- Reading the "Equip:" text is part of the stats.
	local parse = ns.GetSetting("parseEquipText")
	if cachedParse ~= parse then
		statsCache, cached, cachedParse = {}, 0, parse
	end

	local known = statsCache[key]
	if known ~= nil then
		return known or nil
	end
	local itemID = itemKey.itemID
	local equipment, loaded = EquipmentState(itemID)
	if equipment == false and loaded then
		Remember(key, false) -- known not to be equipment, and the item data is here to say so
		return nil
	end
	if fetchBudget then
		if fetchBudget <= 0 then
			deferred = true
			return nil, true
		end
		fetchBudget = fetchBudget - 1
	end
	if equipment == nil or not loaded then
		RequestItem(itemID) -- not known or not loaded yet: never remembered as "no stats"
		return nil, true
	end

	local data = GetTooltipData(itemKey)
	if not data then
		RequestItem(itemID)
		return nil, true
	end
	local link = ResolveLink(data, itemKey)
	local stats
	if link then
		local ok, result = pcall(ns.CollectItemStats, link, data.lines)
		if ok and type(result) == "table" then
			stats = result
		end
	end
	if not stats and (not link or LooksIncomplete(data)) and (requests[itemID] or 0) < MAX_REQUESTS then
		-- The data of the item looks unfinished: ask again (a few times at most) before giving it up as "no stats".
		RequestItem(itemID)
		return nil, true
	end
	Remember(key, stats or false)
	return stats
end

-- The score of a browse row for a profile (a number), nil when the row has none.
local function RowScore(row, profile)
	if type(row) ~= "table" or IsSecret(row) then
		return nil
	end
	local weights = ns.GetProfileWeights(profile)
	if not weights then
		return nil
	end
	local stats = ResolveStats(row.itemKey)
	if not stats then
		return nil
	end
	return (ns.ComputeScore(stats, weights))
end

-- The text of a cell: the tooltip's number (rounded first so nothing prints "-0.0"; 0 is left out with "Hide score when 0").
local function FormatScore(total)
	if not total then
		return ""
	end
	local decimals = ns.GetSetting("decimals")
	if math.abs(total) < 0.5 * 10 ^ -decimals then
		total = 0
	end
	if total == 0 and ns.GetSetting("hideZero") then
		return ""
	end
	return string.format("%." .. decimals .. "f", total)
end

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

local function RefreshArrows()
	for _, header in ipairs(scoreHeaders) do
		if type(header.UpdateArrow) == "function" then
			pcall(header.UpdateArrow, header)
		end
	end
end

local function MarkDirty()
	local list = browse and browse.ItemList
	if type(list) == "table" and type(list.DirtyScrollFrame) == "function" then
		list:DirtyScrollFrame()
	end
end

-- (defined under Refreshing)
local Schedule

-- Puts the browse rows in the order of the sort profile (highest score first, rows without a score last, ties in Blizzard's order),
-- or back in Blizzard's order when no sort is on and this addon had reordered them. `force` redraws the list even when the order did
-- not change (the scores themselves may have).
local function ApplySort(force)
	local list = browse and browse.browseResults
	if type(list) ~= "table" or IsSecret(list) then
		return
	end
	local profile = ActiveSortProfile()
	if not profile and not reordered[list] then
		if force then
			MarkDirty()
		end
		return
	end

	local count = #list
	local entries = {}
	for index = 1, count do
		local row = list[index]
		if type(row) ~= "table" or IsSecret(row) then
			return -- not a list of rows this addon knows: leave it alone
		end
		if profile and not order[row] then
			nextOrder = nextOrder + 1
			order[row] = nextOrder
		end
		entries[index] = { row = row, index = index, seq = order[row] or math.huge }
	end

	if profile then
		fetchBudget, deferred = RESOLVE_PER_PASS, false
		for _, entry in ipairs(entries) do
			entry.score = RowScore(entry.row, profile)
		end
		fetchBudget = nil
		table.sort(entries, function(a, b)
			local sa, sb = a.score, b.score
			if sa ~= nil and sb ~= nil then
				if sa ~= sb then
					return sa > sb
				end
			elseif sa ~= nil or sb ~= nil then
				return sa ~= nil
			end
			if a.seq ~= b.seq then
				return a.seq < b.seq
			end
			return a.index < b.index
		end)
	else
		table.sort(entries, function(a, b)
			if a.seq ~= b.seq then
				return a.seq < b.seq
			end
			return a.index < b.index
		end)
	end

	local changed = false
	for index, entry in ipairs(entries) do
		if list[index] ~= entry.row then
			list[index] = entry.row
			changed = true
		end
	end
	reordered[list] = profile and true or nil

	if changed or force then
		MarkDirty()
	end
	if profile and deferred then
		Schedule(true, PASS_DELAY) -- the rest of the item keys
	end
end

-- Click on a score header: that profile's sort goes on, or off when it already is.
local function ToggleSort(profile)
	if not settings then
		return
	end
	if settings.sortProfile == profile then
		settings.sortProfile = nil
	else
		settings.sortProfile = profile
	end
	ApplySort()
	RefreshArrows()
end

--------------------------------------------------------------------------------
-- Columns
--------------------------------------------------------------------------------

-- A profile name cut to at most `chars` characters (the last two of them "..").
local function CutName(name, chars)
	local length = select(2, name:gsub("[^\128-\191]", ""))
	if length <= chars then
		return name
	end
	local char = "[\1-\127\194-\244][\128-\191]*"
	return name:match("^(" .. string.rep(char, chars - 2) .. ")") .. ".."
end

-- The width of a text in a font string, nil when the client can't tell.
local function MeasureText(fontString, text)
	local ok, width = pcall(function()
		fontString:SetText(text)
		return fontString:GetStringWidth()
	end)
	if ok and not IsSecret(width) and type(width) == "number" and width > 0 then
		return width
	end
end

local cellFont
local measureString -- a hidden font string in the font of the cells

local function CellFont()
	cellFont = cellFont or (_G.Number13FontWhite and "Number13FontWhite" or "GameFontHighlightSmall")
	return cellFont
end

-- The width of a score column: the widest score with four digits before the point, at the current decimals, plus the cell padding.
local function ColumnWidth()
	local decimals = ns.GetSetting("decimals")
	local sample = string.rep("8", SCORE_SAMPLE_DIGITS)
	if type(decimals) == "number" and decimals > 0 then
		sample = sample .. "." .. string.rep("8", decimals)
	end
	if not measureString then
		pcall(function()
			local frame = CreateFrame("Frame", nil, UIParent)
			frame:Hide()
			measureString = frame:CreateFontString(nil, "OVERLAY", CellFont())
		end)
	end
	local width = measureString and MeasureText(measureString, sample) or #sample * FALLBACK_CHAR_WIDTH
	return math.ceil(width) + 2 * CELL_PADDING + COLUMN_SLACK
end

-- Puts the longest part of the profile name that fits the column in its header.
local function FitHeaderText(header, profile, width)
	local ok, fontString = pcall(function()
		return header:GetFontString()
	end)
	if not ok or type(fontString) ~= "table" then
		fontString = nil
	end
	for chars = HEADER_CHARS, MIN_HEADER_CHARS, -1 do
		local text = CutName(profile, chars)
		local measured = fontString and MeasureText(fontString, text)
		if not measured then
			-- Nothing to measure with: as many characters as the fallback width allows.
			chars = math.max(MIN_HEADER_CHARS, math.min(HEADER_CHARS, math.floor(width / FALLBACK_CHAR_WIDTH)))
			header:SetText(CutName(profile, chars))
			return
		end
		if measured <= width or chars == MIN_HEADER_CHARS then
			header:SetText(text)
			return
		end
	end
end

-- What Blizzard's header calls its owner: its click ends in SetSortOrder (with no sort order, which is ours to read as "this column")
-- and its arrow follows GetSortOrderState. The profile is in `jsProfile`.
local function NewHeaderOwner(profile)
	local owner = { jsProfile = profile }
	function owner:SetSortOrder()
		ToggleSort(self.jsProfile)
	end
	function owner:GetSortOrderState()
		if ActiveSortProfile() == self.jsProfile and AuctionHouseSortOrderState then
			return AuctionHouseSortOrderState.PrimaryReversed -- highest first: the arrow's own direction
		end
		return AuctionHouseSortOrderState and AuctionHouseSortOrderState.None or nil
	end
	return owner
end

local function HeaderEnter(header)
	local owner = header.owner
	if type(owner) ~= "table" or not owner.jsProfile then
		return
	end
	GameTooltip:SetOwner(header, "ANCHOR_RIGHT")
	GameTooltip:SetText(owner.jsProfile)
	GameTooltip:AddLine("Stat weight score of this scale. Click to sort the loaded results by it, highest first; click again to go back to the auction house's order.", 1, 1, 1, true)
	GameTooltip:Show()
end

local function HeaderLeave(header)
	local owner = header.owner
	if type(owner) == "table" and owner.jsProfile then
		GameTooltip:Hide()
	end
end

-- The cells: plain frames showing the score of their row for the profile of their column (given as the cell's init argument).
local cellPool = { free = {} }

local function CellInit(cell, profile)
	cell.jsProfile = profile
end

-- (defined under Refreshing)
local BrowseShown

local function CellPopulate(cell, rowData)
	-- Blizzard's list fills its rows even while the Browse tab is hidden (results of another addon's scan): those wait.
	if scanResults then
		cell.Text:SetText("")
		return
	end
	if not BrowseShown() then
		stale = true
		cell.Text:SetText("")
		return
	end
	cell.Text:SetText(FormatScore(RowScore(rowData, cell.jsProfile)))
end

local function NewCell()
	local cell = CreateFrame("Frame", nil, UIParent)
	cell.Text = cell:CreateFontString(nil, "OVERLAY", CellFont())
	cell.Text:SetPoint("LEFT", cell, "LEFT", 0, 0)
	cell.Text:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
	cell.Text:SetJustifyH("RIGHT")
	cell.Text:SetTextColor(SCORE_COLOR[1], SCORE_COLOR[2], SCORE_COLOR[3])
	cell.Init = CellInit
	cell.Populate = CellPopulate
	return cell
end

function cellPool:Acquire()
	return table.remove(self.free) or NewCell()
end

function cellPool:Release(cell)
	cell:Hide()
	cell:ClearAllPoints()
	cell.rowData = nil
	self.free[#self.free + 1] = cell
end

local function AddScoreColumn(tableBuilder, profile, width)
	local owner = NewHeaderOwner(profile)
	local column = tableBuilder:AddColumn()
	column:ConstructHeader("BUTTON", HEADER_TEMPLATE, owner, CutName(profile, HEADER_CHARS), nil)
	local header = column:GetHeaderFrame()
	FitHeaderText(header, profile, width)
	-- Built without a sort order the header is disabled: ours is clickable.
	header:SetEnabled(true)
	if not hookedHeaders[header] then
		hookedHeaders[header] = true
		header:HookScript("OnEnter", HeaderEnter)
		header:HookScript("OnLeave", HeaderLeave)
	end
	scoreHeaders[#scoreHeaders + 1] = header

	column.args = { profile }
	column.pool = cellPool
	column:SetFixedConstraints(width, 0)
	column:SetCellPadding(CELL_PADDING, CELL_PADDING)
end

-- Appends the score columns to a table builder that Blizzard's layout has just filled.
local function AddScoreColumns(tableBuilder)
	scoreHeaders = {}
	builtSignature = Signature()
	local profiles = ColumnProfiles()
	if #profiles == 0 then
		return
	end
	local columns = tableBuilder:GetColumns()
	local before = #columns
	local ok, err = pcall(function()
		local width = ColumnWidth()
		for _, profile in ipairs(profiles) do
			AddScoreColumn(tableBuilder, profile, width)
		end
	end)
	if not ok then
		-- Take back what was added: a half-built column would break the list.
		for index = #columns, before + 1, -1 do
			local header = columns[index].GetHeaderFrame and columns[index]:GetHeaderFrame()
			if header then
				header:Hide()
			end
			columns[index] = nil
		end
		scoreHeaders = {}
		broken = true
		builtSignature = Signature()
		ns.Print("The stat weight columns of the auction house could not be added and are off until you reload the interface: " .. tostring(err))
		Schedule(true) -- the sort has no column to be on
		return
	end
	-- (a header built without a sort order starts with its arrow hidden)
	RefreshArrows()
end

-- Blizzard's layout function with the score columns after its own.
local function MakeLayout(blizzardLayout)
	local function Layout(tableBuilder)
		blizzardLayout(tableBuilder)
		AddScoreColumns(tableBuilder)
	end
	wrappers[Layout] = true
	return Layout
end

-- Hands the item list our wrapper of its current layout (unless it already holds one).
local function WrapLayout()
	local list = browse and browse.ItemList
	if type(list) ~= "table" or type(list.SetTableBuilderLayout) ~= "function" then
		return
	end
	local current = list.tableBuilderLayoutFunction
	if type(current) == "function" and not wrappers[current] then
		list:SetTableBuilderLayout(MakeLayout(current))
	end
end

-- Builds the columns again (the profiles changed): the item list does it at once when it is shown, else when it shows.
local function RebuildLayout()
	local list = browse and browse.ItemList
	if type(list) ~= "table" or type(list.SetTableBuilderLayout) ~= "function" then
		return
	end
	WrapLayout()
	local current = list.tableBuilderLayoutFunction
	if type(current) == "function" then
		list:SetTableBuilderLayout(current)
	end
end

--------------------------------------------------------------------------------
-- Refreshing
--------------------------------------------------------------------------------

-- Whether Blizzard's Browse list is on screen. It receives every page of results even while hidden, which is what other addons'
-- scans (Auctionator's, an empty search of the whole auction house) are made of: none of that is scored or sorted until it shows.
function BrowseShown()
	if not browse then
		return false
	end
	local ok, visible = pcall(function()
		return browse:IsVisible()
	end)
	return not ok or visible == true
end

local function DoRefresh(force)
	if not settings then
		return
	end
	CleanSortProfile()
	if not browse then
		return
	end
	if not BrowseShown() then
		stale = true
		return
	end
	stale = false
	UpdateGearState()
	if Signature() ~= builtSignature then
		RebuildLayout()
	end
	ApplySort(force)
	RefreshArrows()
end

-- Refreshes on a timer, so a burst of changes (typing a weight, item data arriving) is one refresh.
function Schedule(force, delay)
	queuedForce = queuedForce or force
	if queued then
		return
	end
	queued = true
	local function Run()
		queued = false
		local redraw = queuedForce
		queuedForce = false
		DoRefresh(redraw)
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(delay or 0, Run)
	else
		Run()
	end
end

-- The profiles, their weights, the display settings or the tooltip switch changed.
function ns.RefreshAuctionScores()
	if not settings then
		return
	end
	CleanSortProfile()
	if browse then
		Schedule(true)
	end
end

function ns.IsAuctionScoresEnabled()
	return settings ~= nil and settings.enabled == true
end

function ns.SetAuctionScoresEnabled(enabled)
	if not settings or type(enabled) ~= "boolean" then
		return false
	end
	settings.enabled = enabled
	DoRefresh(true)
	if ns.SettingsChanged then
		ns.SettingsChanged()
	end
	return true
end

--------------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------------

-- Blizzard has new rows (the first page, one that arrived while scrolling, a full update).
local function OnResultsChanged()
	if not BrowseShown() then
		stale = true -- (another addon's scan, or a search made from another tab)
		return
	end
	-- No equipment in the results (reagents, consumables...), or a scan of the whole house: the columns go, and come back with the
	-- first search that has gear.
	UpdateGearState()
	if Signature() ~= builtSignature then
		RebuildLayout()
		RefreshArrows()
	end
	ApplySort()
end

-- One of Blizzard's own sort headers was clicked: the auction house sorts again, so our sort is off.
local function OnBlizzardSort()
	if settings and settings.sortProfile then
		settings.sortProfile = nil
		ApplySort()
		RefreshArrows()
	end
end

local function IsEmptyList(value)
	return value == nil or (type(value) == "table" and not IsSecret(value) and next(value) == nil)
end

-- Whether a browse query asks for the whole auction house: no text, no category, no filter (what Auctionator's autoscan sends; a
-- search from Blizzard's own Browse tab always has a category or the filters of its filter menu).
local function IsWholeHouseQuery(query)
	if type(query) ~= "table" or IsSecret(query) then
		return false
	end
	local text = query.searchString
	if IsSecret(text) or (text ~= nil and text ~= "") then
		return false
	end
	if not (IsEmptyList(query.itemClassFilters) and IsEmptyList(query.filters)) then
		return false
	end
	return not (IsNumber(query.minLevel) and query.minLevel > 0) and not (IsNumber(query.maxLevel) and query.maxLevel > 0)
end

-- Every browse query, whoever sends it: a scan of the whole house turns the columns off until the next real search.
local function OnBrowseQuery(query)
	local ok, whole = pcall(IsWholeHouseQuery, query)
	whole = ok and whole or false
	if whole ~= scanResults then
		scanResults = whole
		if browse then
			DoRefresh(true) -- at once: the first page can come before a timer would run
		end
	end
end

local function HookQueries()
	if queryHooked or not (C_AuctionHouse and type(C_AuctionHouse.SendBrowseQuery) == "function") then
		return
	end
	queryHooked = pcall(hooksecurefunc, C_AuctionHouse, "SendBrowseQuery", OnBrowseQuery)
	-- The favorites list fills the same browse results, and is never a scan.
	if queryHooked and type(C_AuctionHouse.SearchForFavorites) == "function" then
		pcall(hooksecurefunc, C_AuctionHouse, "SearchForFavorites", function()
			OnBrowseQuery(nil)
		end)
	end
end

local function HookMethod(frame, name, hook)
	if type(frame[name]) == "function" then
		pcall(hooksecurefunc, frame, name, hook)
	end
end

local function Attach()
	HookQueries()
	if browse then
		return true
	end
	local frame = AuctionHouseFrame
	local browseFrame = type(frame) == "table" and not IsSecret(frame) and frame.BrowseResultsFrame or nil
	if type(browseFrame) ~= "table" or IsSecret(browseFrame) or type(browseFrame.ItemList) ~= "table" then
		return false
	end
	browse = browseFrame
	-- Blizzard sets up a new layout when the category changes: wrap that one too.
	HookMethod(browseFrame, "SetupTableBuilder", WrapLayout)
	HookMethod(browseFrame, "UpdateBrowseResults", OnResultsChanged)
	HookMethod(browseFrame, "SetSortOrder", OnBlizzardSort)
	pcall(browseFrame.HookScript, browseFrame, "OnShow", function()
		if stale then
			DoRefresh(true)
		end
	end)
	WrapLayout()
	if BrowseShown() then
		ApplySort()
	else
		stale = true
	end
	return true
end

local function OnEvent(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == BLIZZARD_ADDON then
			Attach()
		end
	elseif browse and type(arg1) == "number" and pending[arg1] then
		-- The data of an item we asked for (or are waiting for) is there.
		pending[arg1] = nil
		Schedule(true, ITEM_DATA_DELAY)
	end
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db)
	if type(db.auctionScores) ~= "table" then
		db.auctionScores = {}
	end
	settings = db.auctionScores
	for name, default in pairs(DEFAULTS) do
		if type(settings[name]) ~= type(default) then
			settings[name] = default
		end
	end
	if type(settings.sortProfile) ~= "string" then
		settings.sortProfile = nil
	end
	CleanSortProfile()
end

function ns.InitAuctionScores(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)

	local driver = CreateFrame("Frame")
	-- An event this client does not have must not stop the others from being registered.
	for _, event in ipairs({ "ADDON_LOADED", "ITEM_DATA_LOAD_RESULT", "GET_ITEM_INFO_RECEIVED", "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript("OnEvent", OnEvent)
	HookQueries() -- (before the auction house UI loads, so its first query is seen too)
	Attach()
end

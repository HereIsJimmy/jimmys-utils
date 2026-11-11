local addonName, ns = ...

--[[
	Scoring and tooltip display.

	Item tooltip data may contain "secret values" that addons must not do string
	operations on or hand back to C_Item.*, so everything read from tooltip data is
	checked with issecretvalue first.
]]

local IsSecret = issecretvalue or function() return false end

local LINE_COLOR = { 0.4, 0.78, 1 }
local BREAKDOWN_COLOR = { 0.7, 0.7, 0.7 }

--------------------------------------------------------------------------------
-- Reading "Equip:" lines
--------------------------------------------------------------------------------

-- Flat list of { key, pattern } in definition order, built on first use.
local equipPatterns

local function GetEquipPatterns()
	if not equipPatterns then
		equipPatterns = {}
		for _, stat in ipairs(ns.STATS) do
			if stat.patterns then
				for _, pattern in ipairs(stat.patterns) do
					equipPatterns[#equipPatterns + 1] = { key = stat.key, pattern = pattern }
				end
			end
		end
	end
	return equipPatterns
end

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

-- Returns key, value for the first pattern matching the normalized effect text.
local function MatchEquipText(text)
	for _, entry in ipairs(GetEquipPatterns()) do
		local value = tonumber(text:match(entry.pattern))
		if value then
			return entry.key, value
		end
	end
end

-- Reads English "Equip: ..." lines from tooltip data lines.
-- Returns { [parsedKey] = value } or nil when nothing matched.
function ns.ParseEquipLines(lines)
	if type(lines) ~= "table" or IsSecret(lines) then
		return nil
	end

	local prefix = ITEM_SPELL_TRIGGER_ONEQUIP
	if type(prefix) ~= "string" or prefix == "" or IsSecret(prefix) then
		prefix = "Equip:"
	end

	local result
	for _, line in ipairs(lines) do
		local text = not IsSecret(line) and type(line) == "table" and line.leftText
		if text and not IsSecret(text) and type(text) == "string" then
			-- Drop color codes, then require the "Equip:" prefix at the very start.
			text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
			text = text:gsub("|cn[^:]*:", "") -- named colors, e.g. |cnGREEN_FONT_COLOR:
			text = text:gsub("|r", "")
			if text:sub(1, #prefix) == prefix then
				text = Trim(text:sub(#prefix + 1)):lower()
				text = Trim(text:gsub("%.$", ""))
				local key, value = MatchEquipText(text)
				if key then
					result = result or {}
					result[key] = (result[key] or 0) + value
				end
			end
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Stats and score
--------------------------------------------------------------------------------

local function HasAnyKey(stats, keys)
	for _, key in ipairs(keys) do
		if stats[key] then
			return true
		end
	end
	return false
end

-- Returns { [key] = { value = number, source = "api" | "text" } } or nil when nothing was read.
-- Text values are stored under the key their pattern belongs to, which is the main stat for
-- same-unit effects (e.g. "Restores 5 mana per 5 sec" counts as ITEM_MOD_MANA_REGENERATION_SHORT).
-- `lines` (tooltip data lines) is optional; without it only API stats are used.
function ns.CollectItemStats(link, lines)
	if type(link) ~= "string" or IsSecret(link) then
		return nil
	end

	local stats = {}

	local apiStats = C_Item.GetItemStats(link)
	if type(apiStats) == "table" and not IsSecret(apiStats) then
		for key, value in pairs(apiStats) do
			if type(key) == "string" and not IsSecret(key) and not IsSecret(value) and type(value) == "number" then
				key = ns.NormalizeStatKey(key)
				stats[key] = { value = value, source = "api" }
				if not ns.STATS_BY_KEY[key] then
					ns.RecordDiscoveredKey(key)
				end
			end
		end
	end

	-- Equip: lines only fill gaps the API leaves, so nothing is counted twice.
	if lines and ns.GetSetting("parseEquipText") then
		local locale = GetLocale()
		if locale == "enUS" or locale == "enGB" then
			local parsed = ns.ParseEquipLines(lines)
			if parsed then
				for key, value in pairs(parsed) do
					local stat = ns.STATS_BY_KEY[key]
					if stat and not stats[key] and not (stat.covers and HasAnyKey(stats, stat.covers)) then
						stats[key] = { value = value, source = "text" }
					end
				end
			end
		end
	end

	if next(stats) == nil then
		return nil
	end
	return stats
end

-- Returns total, breakdown where breakdown holds one entry per non-zero weight,
-- sorted by absolute contribution (largest first).
function ns.ComputeScore(stats)
	local total = 0
	local breakdown = {}

	for key, entry in pairs(stats) do
		local weight = ns.GetWeight(key)
		if weight ~= 0 then
			local contribution = entry.value * weight
			total = total + contribution
			local label = ns.GetStatLabel(key)
			-- Parsed pseudo-stats already say "(Equip)" in their own label.
			local stat = ns.STATS_BY_KEY[key]
			if entry.source == "text" and not (stat and stat.group == "parsed") then
				label = label .. " (Equip)"
			end
			breakdown[#breakdown + 1] = {
				key = key,
				label = label,
				value = entry.value,
				weight = weight,
				contribution = contribution,
				source = entry.source,
			}
		end
	end

	table.sort(breakdown, function(a, b)
		local ca, cb = math.abs(a.contribution), math.abs(b.contribution)
		if ca ~= cb then
			return ca > cb
		end
		return a.key < b.key
	end)

	return total, breakdown
end

--------------------------------------------------------------------------------
-- Tooltip
--------------------------------------------------------------------------------

-- Finds the item link behind an item tooltip: instance GUID first, then the
-- hyperlink, then the plain item ID. Returns nil when only secret values are available.
local function ResolveItemLink(data)
	local guid = data.guid
	if not IsSecret(guid) and type(guid) == "string" and guid ~= "" then
		local link = C_Item.GetItemLinkByGUID(guid)
		if type(link) == "string" and not IsSecret(link) then
			return link
		end
	end

	local hyperlink = data.hyperlink
	if type(hyperlink) == "string" and not IsSecret(hyperlink) then
		return hyperlink
	end

	local id = data.id
	if type(id) == "number" and not IsSecret(id) then
		local _, link = C_Item.GetItemInfo(id)
		if type(link) == "string" and not IsSecret(link) then
			return link
		end
	end
end

local function ShouldShowBreakdown()
	local mode = ns.GetSetting("breakdown")
	if mode == "always" then
		return true
	elseif mode == "shift" then
		return IsShiftKeyDown()
	elseif mode == "alt" then
		return IsAltKeyDown()
	elseif mode == "ctrl" then
		return IsControlKeyDown()
	end
	return false
end

local function OnTooltipSetItem(tooltip, data)
	if not tooltip or IsSecret(tooltip) or not data or IsSecret(data) or type(data) ~= "table" then
		return
	end
	if tooltip.IsForbidden and tooltip:IsForbidden() then
		return
	end
	if not tooltip.AddDoubleLine then
		return
	end
	if not ns.IsStatsEnabled() then
		return
	end

	local link = ResolveItemLink(data)
	if not link or not C_Item.IsEquippableItem(link) then
		return
	end

	local stats = ns.CollectItemStats(link, data.lines)
	if not stats then
		return
	end

	local total, breakdown = ns.ComputeScore(stats)

	-- Round first so a total that displays as 0 counts as 0 (and never prints "-0.0").
	local decimals = ns.GetSetting("decimals")
	if math.abs(total) < 0.5 * 10 ^ -decimals then
		total = 0
	end
	if total == 0 and ns.GetSetting("hideZero") then
		return
	end

	local label = "Stat Weight"
	if #ns.GetProfileNames() > 1 then
		label = label .. " (" .. ns.GetActiveProfileName() .. ")"
	end
	tooltip:AddDoubleLine(label, string.format("%." .. decimals .. "f", total),
		LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], 1, 1, 1)

	if ShouldShowBreakdown() then
		for _, entry in ipairs(breakdown) do
			tooltip:AddDoubleLine("  " .. entry.label,
				ns.FormatNumber(entry.value) .. " x " .. ns.FormatNumber(entry.weight) .. " = " .. ns.FormatNumber(entry.contribution),
				BREAKDOWN_COLOR[1], BREAKDOWN_COLOR[2], BREAKDOWN_COLOR[3],
				BREAKDOWN_COLOR[1], BREAKDOWN_COLOR[2], BREAKDOWN_COLOR[3])
		end
	end
end

local registered = false

function ns.InitTooltip()
	if registered then
		return
	end
	registered = true
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipSetItem)
end

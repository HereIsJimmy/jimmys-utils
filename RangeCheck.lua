local addonName, ns = ...

--[[
	Range check indicator: a small frame that shows the icon of a spell the player picked, in its normal colours
	while the current target is within range of that spell and tinted red while it is not.

	Saved data (validated in ns.InitRangeCheck):
		JimmysStatWeightsDB.range = { enabled = true, locked = true, size = 32, anchor = "nameplate", point = "CENTER", x = 0, y = -120 }
		JimmysStatWeightsCharDB.rangeSpell = spellID  -- per character, spells are class specific

	The indicator is meant for enemies: it needs a living, attackable target, and the spell list only offers harmful
	spells. The chosen spell is stored as its base spell ID, so it keeps working when a talent or form overrides it.

	Position: anchor = "nameplate" (default) puts the indicator to the right of the target's nameplate health bar,
	re-anchored when the target or the nameplates change; without a nameplate it is hidden. anchor = "screen" keeps it at
	the saved screen position (point/x/y), which can be dragged while unlocked. Blizzard's nameplate frames are only
	read (the indicator is parented to the plate and anchored to it), never modified or hooked.

	The indicator is a plain frame that never touches protected frames, so it works in combat.
	C_Spell.IsSpellInRange is allowed for tainted code; if its result is ever a secret value the
	code does not branch on it but lets the icon follow it with SetVertexColorFromBoolean.
	The icon is C_Spell.GetSpellTexture(spell), which follows talent and form overrides; a missing one is
	replaced by the question mark icon.
]]

local FRAME_NAME = "JimmysUtilsRangeFrame"
local UPDATE_INTERVAL = 0.1

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Colour mixins with GetRGBA, like CreateColor(): built by hand if the client does not provide CreateColor.
local function NewColor(r, g, b, a)
	if CreateColor then
		return CreateColor(r, g, b, a)
	end
	return {
		GetRGB = function() return r, g, b end,
		GetRGBA = function() return r, g, b, a end,
	}
end
local IN_RANGE = NewColor(1, 1, 1, 1) -- the icon as it is
local OUT_OF_RANGE = NewColor(1, 0.2, 0.2, 1) -- tinted red

local DEFAULTS = {
	enabled = true,
	locked = true,
	size = 32,
	anchor = "nameplate",
	point = "CENTER",
	x = 0,
	y = -120,
}
-- Icon size in pixels: any whole number in this range (typed in the options window or with /ju range size).
ns.RANGE_SIZE_MIN, ns.RANGE_SIZE_MAX = 12, 128
local ANCHOR_MODES = { nameplate = true, screen = true }
local PLATE_OFFSET = 4 -- gap between the nameplate health bar and the indicator
local PLATE_LEVEL_BOOST = 10 -- frame levels above the nameplate

function ns.IsValidRangeSize(value)
	return type(value) == "number" and value == math.floor(value)
		and value >= ns.RANGE_SIZE_MIN and value <= ns.RANGE_SIZE_MAX
end

local ANCHOR_POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true,
	LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local MAX_OFFSET = 10000
local PLACEHOLDER_ALPHA = 0.35 -- the icon shown while the indicator is unlocked with nothing to report

-- Set in ns.InitRangeCheck.
local settings, charDb
local indicator, driver
local screenLevel -- frame level of the indicator while it is a child of UIParent
local attachedPlate -- the nameplate the indicator is currently parented to (nameplate mode), or nil
local shownIcon -- the texture last set on the icon
local attachedAnchor -- the frame of that plate the indicator is anchored to
local refreshPending = false -- a deferred re-query of the target's plate is scheduled
local warnedPlateError = false
local elapsed = 0

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

-- The icon of a spell (it follows overrides), or the question mark when the client gives none (or a secret).
local function GetSpellIcon(spellID)
	if spellID and C_Spell and C_Spell.GetSpellTexture then
		local icon = C_Spell.GetSpellTexture(spellID)
		if not IsSecret(icon) and ((type(icon) == "number" and icon > 0) or (type(icon) == "string" and icon ~= "")) then
			return icon
		end
	end
	return FALLBACK_ICON
end

--------------------------------------------------------------------------------
-- Spells
--------------------------------------------------------------------------------

-- Returns the SpellInfo table for a spell ID or name, or nil.
local function GetSpellInfo(identifier)
	if not (C_Spell and C_Spell.GetSpellInfo) then
		return nil
	end
	local info = C_Spell.GetSpellInfo(identifier)
	if type(info) == "table" and not IsSecret(info) and type(info.name) == "string" and not IsSecret(info.name) then
		return info
	end
end

function ns.GetRangeSpell()
	return charDb and charDb.rangeSpell
end

-- SpellInfo of the chosen spell, or nil when none is chosen or it is unknown to the client.
function ns.GetRangeSpellInfo()
	local spellID = ns.GetRangeSpell()
	return spellID and GetSpellInfo(spellID) or nil
end

-- Stores the spell. Returns true, or false and an error message.
function ns.SetRangeSpell(spellID)
	if not charDb then
		return false, "The range check is not ready yet."
	end
	if spellID == nil then
		charDb.rangeSpell = nil
		ns.UpdateRangeCheck()
		return true
	end
	if not IsFiniteNumber(spellID) or spellID < 1 or spellID ~= math.floor(spellID) then
		return false, "Invalid spell."
	end
	local info = GetSpellInfo(spellID)
	if not info then
		return false, "Unknown spell: " .. tostring(spellID) .. "."
	end
	charDb.rangeSpell = spellID
	ns.UpdateRangeCheck()
	return true
end

-- Sets the spell from text typed by the user: a spell name, a spell ID or a shift-clicked spell link.
-- Returns true and the message to show, or false and an error message.
function ns.SetRangeSpellByText(text)
	text = Trim(tostring(text or ""))
	if text == "" then
		return false, "Type a spell name or ID."
	end

	local identifier = tonumber(text:match("|Hspell:(%d+)")) or tonumber(text)
	if identifier == nil then
		identifier = text
	end
	local info = GetSpellInfo(identifier)
	if not info then
		return false, "Unknown spell \"" .. text .. "\"."
	end

	local spellID = info.spellID or (type(identifier) == "number" and identifier) or nil
	if not spellID then
		return false, "Unknown spell \"" .. text .. "\"."
	end
	-- Names resolve to the overriding spell; keep the base spell so the choice survives the override ending.
	local book = C_SpellBook
	if book and book.FindBaseSpellByID then
		local base = book.FindBaseSpellByID(spellID)
		if type(base) == "number" and not IsSecret(base) then
			spellID = base
		end
	end
	local ok, err = ns.SetRangeSpell(spellID)
	if not ok then
		return false, err
	end

	-- The spell is accepted anyway; these only explain why the indicator may never show.
	local warnings = {}
	if C_Spell.SpellHasRange then
		local hasRange = C_Spell.SpellHasRange(spellID)
		if not IsSecret(hasRange) and hasRange == false then
			warnings[#warnings + 1] = "it has no range, so the indicator will stay hidden"
		end
	end
	if C_Spell.IsSpellHarmful then
		local harmful = C_Spell.IsSpellHarmful(spellID)
		if not IsSecret(harmful) and harmful == false then
			warnings[#warnings + 1] = "it is not a harmful spell and the indicator only shows for enemy targets"
		end
	end
	local isKnown = book and (book.IsSpellKnownOrInSpellBook or book.IsSpellKnown)
	if isKnown then
		local known = isKnown(spellID)
		if not IsSecret(known) and known == false then
			warnings[#warnings + 1] = "this character does not know it"
		end
	end

	local message = info.name .. " (" .. tostring(spellID) .. ") is now the range check spell."
	if #warnings > 0 then
		message = message .. " Warning: " .. table.concat(warnings, "; ") .. "."
	end
	return true, message, #warnings > 0
end

-- Harmful spells of the player's spellbook that have a range: list of { spellID, name, iconID }, sorted by name.
function ns.GetRangeSpellList()
	local list, seen = {}, {}
	local book = C_SpellBook
	if not (book and book.GetNumSpellBookSkillLines and book.GetSpellBookSkillLineInfo and book.GetSpellBookItemInfo) then
		return list
	end

	local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
	local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
	local hasRange = C_Spell and C_Spell.SpellHasRange
	local isHarmful = C_Spell and C_Spell.IsSpellHarmful
	-- A secret answer is never branched on: the spell stays listed.
	local function Yes(value)
		return IsSecret(value) or value == true
	end

	for lineIndex = 1, book.GetNumSpellBookSkillLines() or 0 do
		local line = book.GetSpellBookSkillLineInfo(lineIndex)
		if type(line) == "table" and not line.shouldHide and not line.offSpecID then
			local offset, count = line.itemIndexOffset or 0, line.numSpellBookItems or 0
			for slot = offset + 1, offset + count do
				local item = book.GetSpellBookItemInfo(slot, bank)
				if type(item) == "table" and item.itemType == spellType and not item.isPassive and not item.isOffSpec then
					-- The base spell, so the choice keeps working when the spell is overridden.
					local spellID = item.actionID or item.spellID
					if spellID and not seen[spellID] then
						seen[spellID] = true
						local listed = (not hasRange or Yes(hasRange(spellID))) and (not isHarmful or Yes(isHarmful(spellID)))
						if listed and type(item.name) == "string" and item.name ~= "" then
							list[#list + 1] = { spellID = spellID, name = item.name, iconID = item.iconID }
						end
					end
				end
			end
		end
	end

	table.sort(list, function(a, b)
		local la, lb = a.name:lower(), b.name:lower()
		if la ~= lb then
			return la < lb
		end
		return a.spellID < b.spellID
	end)
	return list
end

--------------------------------------------------------------------------------
-- Indicator
--------------------------------------------------------------------------------

-- A target the indicator could be about: it exists, can be attacked and is alive.
-- Secret answers count as "yes", so the indicator is still shown and judged by the range result.
local function HasUsableTarget()
	local exists = UnitExists("target")
	if not IsSecret(exists) and not exists then
		return false
	end
	local canAttack = UnitCanAttack("player", "target")
	if not IsSecret(canAttack) and not canAttack then
		return false
	end
	local dead = UnitIsDead("target")
	if not IsSecret(dead) and dead then
		return false
	end
	return true
end

local function HasTarget()
	local exists = UnitExists("target")
	return IsSecret(exists) or exists and true or false
end

-- Anchoring ----------------------------------------------------------------------------------------

-- Fixed screen position: child of UIParent at the saved point/offset.
local function AnchorToScreen()
	attachedPlate, attachedAnchor = nil, nil
	-- Off the plate first: clamping is only allowed once the indicator is no longer attached to a nameplate.
	indicator:ClearAllPoints()
	indicator:SetParent(UIParent)
	indicator:SetFrameStrata("MEDIUM")
	indicator:SetFrameLevel(screenLevel)
	indicator:SetClampedToScreen(true)
	indicator:SetPoint(settings.point, UIParent, settings.point, settings.x, settings.y)
end

-- Nameplate mode with nothing to attach to: back under UIParent, without a position, hidden.
local function Detach()
	attachedPlate, attachedAnchor = nil, nil
	indicator:Hide()
	indicator:SetParent(UIParent)
	indicator:ClearAllPoints()
end

-- Looks the target's plate up again on the next frame (the plate may not be complete yet, or is being recycled).
local function ScheduleRefresh()
	if refreshPending or not (C_Timer and C_Timer.After) then
		return
	end
	refreshPending = true
	C_Timer.After(0, function()
		refreshPending = false
		ns.UpdateRangeCheck()
	end)
end

-- The plate of `unit`, or nil (nameplates off, out of view, forbidden, or the unit is rejected by the API).
local function GetPlate(unit)
	if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
		return nil
	end
	local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit, false)
	if not ok then
		if not warnedPlateError then
			warnedPlateError = true
			ns.Print("The nameplate position is not available on this client. Use /ju range screen to place the range check on the screen.")
		end
		return nil
	end
	if type(plate) == "table" and not IsSecret(plate) then
		return plate
	end
	return nil
end

-- Reads a frame of Blizzard's nameplate: is it a frame that is shown (a secret answer counts as not shown) and,
-- for `needsWidth`, wider than 0 (a width that cannot be read does not rule it out).
local function IsShownFrame(frame, needsWidth)
	if type(frame) ~= "table" or IsSecret(frame) or not frame.IsShown then
		return false
	end
	local ok, shown = pcall(frame.IsShown, frame)
	if not ok or IsSecret(shown) or not shown then
		return false
	end
	if needsWidth and frame.GetWidth then
		local okWidth, width = pcall(frame.GetWidth, frame)
		if okWidth and type(width) == "number" and not IsSecret(width) and width <= 0 then
			return false
		end
	end
	return true
end

-- The frame the indicator sits to the right of: the crowd control icons or the loss of control icon when Blizzard
-- shows them (they start at the right edge of the health bar), else the health bar, the UnitFrame or the plate.
-- The second result is true while the plate has no UnitFrame yet.
local function FindPlateAnchor(plate)
	local unitFrame = plate.UnitFrame
	if type(unitFrame) ~= "table" then
		return plate, true
	end
	local auras = unitFrame.AurasFrame
	if type(auras) == "table" then
		if IsShownFrame(auras.CrowdControlListFrame, true) then
			return auras.CrowdControlListFrame, false
		end
		if IsShownFrame(auras.LossOfControlFrame, false) then
			return auras.LossOfControlFrame, false
		end
	end
	local container = unitFrame.HealthBarsContainer
	if type(container) == "table" then
		return container, false
	end
	return unitFrame, false
end

-- Puts the indicator to the right of the target's nameplate. The plate and its children are only read. Without a
-- plate, or while the feature is off, the indicator is detached and hidden. Nothing is touched when the plate and the
-- anchor frame are the same as the last time.
local function AnchorToTargetPlate()
	local plate = settings.enabled and GetPlate("target") or nil
	if not plate then
		Detach()
		return
	end

	local anchorTo, noUnitFrame = FindPlateAnchor(plate)
	if plate == attachedPlate and anchorTo == attachedAnchor then
		return
	end

	attachedPlate, attachedAnchor = plate, anchorTo
	-- Nameplates are restricted regions: the client refuses to clamp anything attached to them ("Can't clamp
	-- restricted regions"). Turn clamping off while the indicator is still a child of UIParent, then attach it.
	indicator:ClearAllPoints()
	indicator:SetParent(UIParent)
	indicator:SetClampedToScreen(false)
	indicator:SetParent(plate)
	indicator:SetFrameStrata(plate:GetFrameStrata())
	indicator:SetFrameLevel(plate:GetFrameLevel() + PLATE_LEVEL_BOOST)
	indicator:ClearAllPoints()
	indicator:SetPoint("LEFT", anchorTo, "RIGHT", PLATE_OFFSET, 0)
	if noUnitFrame then
		ScheduleRefresh()
	end
end

-- Cheap check for the periodic update: only the anchor frame can change while the plate stays (crowd control icons
-- appear and disappear); the indicator then moves next to the other frame.
local function ReanchorOnPlate()
	if not attachedPlate then
		return
	end
	local anchorTo = FindPlateAnchor(attachedPlate)
	if anchorTo ~= attachedAnchor then
		attachedAnchor = anchorTo
		indicator:ClearAllPoints()
		indicator:SetPoint("LEFT", anchorTo, "RIGHT", PLATE_OFFSET, 0)
	end
end

-- Shows the icon of the chosen spell; the texture is only set again when it changed.
local function UpdateIcon()
	local icon = GetSpellIcon(charDb.rangeSpell)
	if icon ~= shownIcon then
		shownIcon = icon
		indicator.icon:SetTexture(icon)
	end
end

local function UpdateIndicator()
	if not indicator then
		return
	end
	UpdateIcon()

	-- In nameplate mode there is nothing to show without a plate to sit on.
	local onScreen = settings.anchor == "screen"
	local shown = false
	if (onScreen or attachedPlate) and settings.enabled and charDb.rangeSpell and HasUsableTarget() then
		local result = C_Spell.IsSpellInRange(charDb.rangeSpell, "target")
		if IsSecret(result) then
			-- No branching on the secret: the icon takes its colour from the result.
			indicator.icon:SetAlpha(1)
			indicator.icon:SetVertexColorFromBoolean(result, IN_RANGE, OUT_OF_RANGE)
			shown = true
		elseif result == true or result == false then
			indicator.icon:SetAlpha(1)
			indicator.icon:SetVertexColor((result and IN_RANGE or OUT_OF_RANGE):GetRGBA())
			shown = true
		end
		-- nil: the check was invalid (unknown spell, no valid target), nothing to report.
	end

	if shown then
		indicator:Show()
	elseif onScreen and not settings.locked then
		-- Unlocked: keep a faint placeholder up (even when disabled or without a spell or target) so it can be positioned.
		indicator.icon:SetAlpha(PLACEHOLDER_ALPHA)
		indicator.icon:SetVertexColor(IN_RANGE:GetRGBA())
		indicator:Show()
	else
		indicator:Hide()
	end
end

local function OnUpdate(_, delta)
	elapsed = elapsed + delta
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0
	if settings.anchor == "nameplate" then
		ReanchorOnPlate()
	end
	UpdateIndicator()
end

local function ApplyPosition()
	if settings.anchor == "screen" then
		AnchorToScreen()
	else
		AnchorToTargetPlate()
	end
end

-- Re-evaluates everything: where the indicator sits (nameplate mode: on the target's plate, found again unless
-- `keepAnchor`), whether the periodic update is needed, then the icon itself.
local function Refresh(keepAnchor)
	if not (indicator and settings) then
		return
	end
	if settings.anchor == "nameplate" and not keepAnchor then
		AnchorToTargetPlate()
	end
	-- The periodic update only runs while there is something to watch.
	if settings.enabled and charDb.rangeSpell and HasTarget() then
		driver:SetScript("OnUpdate", OnUpdate)
	else
		driver:SetScript("OnUpdate", nil)
	end
	elapsed = 0
	UpdateIndicator()
end

function ns.UpdateRangeCheck()
	Refresh(false)
end

-- Dragging only exists at the fixed screen position; on a nameplate the lock setting has no effect.
local function ApplyLayout()
	indicator:SetSize(settings.size, settings.size)
	ApplyPosition()
	local movable = settings.anchor == "screen" and not settings.locked
	indicator:EnableMouse(movable)
	indicator.background:SetShown(movable)
	indicator.label:SetShown(movable)
end

-- Remembers where the indicator was dropped, as an offset from the screen center.
local function SavePosition()
	local x, y = indicator:GetCenter()
	local centerX, centerY = UIParent:GetCenter()
	if not (IsFiniteNumber(x) and IsFiniteNumber(y) and IsFiniteNumber(centerX) and IsFiniteNumber(centerY)) then
		return
	end
	settings.point = "CENTER"
	settings.x = math.floor((x - centerX) * 10 + 0.5) / 10
	settings.y = math.floor((y - centerY) * 10 + 0.5) / 10
	ApplyPosition()
end

local function CreateIndicator()
	indicator = CreateFrame("Frame", FRAME_NAME, UIParent)
	indicator:Hide()
	indicator:SetFrameStrata("MEDIUM")
	screenLevel = indicator:GetFrameLevel()
	indicator:SetMovable(true)
	indicator:SetClampedToScreen(true)
	indicator:RegisterForDrag("LeftButton")
	indicator:SetScript("OnDragStart", function(self)
		if not settings.locked then
			self:StartMoving()
		end
	end)
	indicator:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)

	indicator.background = indicator:CreateTexture(nil, "BACKGROUND")
	indicator.background:SetAllPoints(indicator)
	indicator.background:SetColorTexture(0, 0, 0, 0.35)

	-- A 1 px black border around the icon.
	indicator.border = indicator:CreateTexture(nil, "BACKGROUND", nil, -1)
	indicator.border:SetPoint("TOPLEFT", indicator, "TOPLEFT", -1, 1)
	indicator.border:SetPoint("BOTTOMRIGHT", indicator, "BOTTOMRIGHT", 1, -1)
	indicator.border:SetColorTexture(0, 0, 0, 1)

	indicator.icon = indicator:CreateTexture(nil, "ARTWORK")
	indicator.icon:SetAllPoints(indicator)
	indicator.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trims the border drawn into spell icons

	indicator.label = indicator:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	indicator.label:SetPoint("BOTTOM", indicator, "TOP", 0, 2)
	indicator.label:SetText("Range check - drag to move")
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function ns.GetRangeSetting(name)
	return settings and settings[name]
end

-- Only the options the user can change directly: enabled, locked, size and anchor.
function ns.SetRangeSetting(name, value)
	if not settings or (name ~= "enabled" and name ~= "locked" and name ~= "size" and name ~= "anchor") then
		return false
	end
	if type(value) ~= type(DEFAULTS[name]) or (name == "size" and not ns.IsValidRangeSize(value))
		or (name == "anchor" and not ANCHOR_MODES[value]) then
		return false
	end
	settings[name] = value
	ApplyLayout()
	Refresh(true) -- ApplyLayout already placed the indicator
	return true
end

function ns.ResetRangePosition()
	if not settings then
		return
	end
	settings.point, settings.x, settings.y = DEFAULTS.point, DEFAULTS.x, DEFAULTS.y
	ApplyPosition()
end

--------------------------------------------------------------------------------
-- Slash command: /ju range ...
--------------------------------------------------------------------------------

function ns.HandleRangeCommand(rest)
	rest = Trim(rest or "")
	local lowered = rest:lower()

	if rest == "" then
		ns.SetRangeSetting("enabled", not settings.enabled)
		if settings.enabled then
			if ns.GetRangeSpell() then
				ns.Print("Range check enabled.")
			else
				ns.Print("Range check enabled. Pick a spell with /ju range <spell name or id> or in the options window.")
			end
		else
			ns.Print("Range check disabled.")
		end
	elseif lowered == "clear" then
		ns.SetRangeSpell(nil)
		ns.Print("Range check spell cleared.")
	elseif lowered == "nameplate" then
		ns.SetRangeSetting("anchor", "nameplate")
		ns.Print("Range check now sits on the target's nameplate (enemy nameplates must be shown, default key V).")
	elseif lowered == "screen" then
		ns.SetRangeSetting("anchor", "screen")
		ns.Print("Range check now sits at a fixed spot on the screen (/ju range unlock to move it).")
	elseif lowered == "unlock" then
		ns.SetRangeSetting("locked", false)
		if settings.anchor == "screen" then
			ns.Print("Range check unlocked: drag it with the left mouse button, then /ju range lock.")
		else
			ns.Print("Range check unlocked, but it can only be dragged at a fixed screen position: use /ju range screen.")
		end
	elseif lowered == "lock" then
		ns.SetRangeSetting("locked", true)
		ns.Print("Range check locked.")
	elseif lowered:match("^size%f[%s%z]") then
		local size = tonumber(Trim(rest:sub(5)))
		if not ns.SetRangeSetting("size", size) then
			ns.Print(string.format("Usage: /ju range size <%d-%d> (now %d).", ns.RANGE_SIZE_MIN, ns.RANGE_SIZE_MAX, settings.size))
			return
		end
		ns.Print(string.format("Range check icon size set to %d.", size))
	else
		local ok, message = ns.SetRangeSpellByText(rest)
		ns.Print(message)
		if not ok then
			return
		end
	end
	ns.NotifyConfigChanged()
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db, characterDb)
	if type(db.range) ~= "table" then
		db.range = {}
	end
	settings = db.range
	for name, default in pairs(DEFAULTS) do
		if type(settings[name]) ~= type(default) then
			settings[name] = default
		end
	end
	if not ns.IsValidRangeSize(settings.size) then
		settings.size = DEFAULTS.size
	end
	if not ANCHOR_MODES[settings.anchor] then
		settings.anchor = DEFAULTS.anchor
	end
	if not ANCHOR_POINTS[settings.point] then
		settings.point = DEFAULTS.point
	end
	for _, name in ipairs({ "x", "y" }) do
		local value = settings[name]
		if not IsFiniteNumber(value) then
			settings[name] = DEFAULTS[name]
		else
			settings[name] = math.max(-MAX_OFFSET, math.min(MAX_OFFSET, value))
		end
	end

	charDb = characterDb
	local spellID = charDb.rangeSpell
	if not IsFiniteNumber(spellID) or spellID < 1 or spellID ~= math.floor(spellID) then
		charDb.rangeSpell = nil
	end
end

local initialized = false

function ns.InitRangeCheck(db, characterDb)
	if initialized then
		return
	end
	initialized = true

	InitData(db, characterDb)
	CreateIndicator()
	ApplyLayout()

	driver = CreateFrame("Frame")
	driver:RegisterEvent("PLAYER_TARGET_CHANGED")
	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:RegisterEvent("SPELLS_CHANGED")
	driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	driver:SetScript("OnEvent", function(_, event, unit)
		if event == "NAME_PLATE_UNIT_REMOVED" and attachedPlate and unit ~= nil and GetPlate(unit) == attachedPlate then
			-- Our plate is going away (it is recycled for another unit): let go of it, look again on the next frame.
			Detach()
			Refresh(true)
			ScheduleRefresh()
			return
		end
		ns.UpdateRangeCheck()
	end)

	ns.UpdateRangeCheck()
end

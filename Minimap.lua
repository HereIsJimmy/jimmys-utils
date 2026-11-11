local addonName, ns = ...

--[[
	Minimap button: a round button on the edge of the minimap. Left-click opens or closes the options window, right-click
	opens or closes the "materials in your mail" window (the same as /ju materials, so it says so when the mail features are
	off), dragging with the left button moves it around the minimap. The addon compartment entry (the menu of the minimap's
	addon button, filled from the .toc fields IconTexture and AddonCompartmentFunc*) does the same.

	Saved data (validated in InitData):
		JimmysStatWeightsDB.minimap = { hide = false, angle = 225 } -- angle: degrees around the minimap center, 0 is east

	The button is a plain child of Minimap (nothing of Blizzard's code is hooked or replaced). It sits at the angle on a circle
	just outside the minimap edge; with a square minimap (GetMinimapShape() == "SQUARE", set by minimap addons) it follows the
	square instead. It is not clamped to the screen.
]]

local BUTTON_NAME = "JimmysUtilsMinimapButton"
local ICON = "Interface\\AddOns\\JimmysUtils\\Media\\MinimapIcon"
local BORDER = "Interface\\Minimap\\MiniMap-TrackingBorder"
local BACKGROUND = "Interface\\Minimap\\UI-Minimap-Background"
local HIGHLIGHT = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

local BUTTON_SIZE = 31
local ICON_SIZE = 20
local BORDER_SIZE = 53
local RADIUS_MARGIN = 5 -- the button's center sits this far outside the minimap edge
local DEFAULT_MINIMAP_SIZE = 140 -- when the client cannot tell
local CLICK_SUPPRESS_SECONDS = 0.2 -- a click right after a drag is the end of the drag, not a click

local DEFAULT_ANGLE = 225 -- bottom left
local DEFAULTS = {
	hide = false,
	angle = DEFAULT_ANGLE,
}

-- Set in ns.InitMinimap.
local settings
local button
local initialized = false
local dragging = false
local suppressUntil = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

local function PlainNumber(value)
	return not IsSecret(value) and type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

local function Now()
	return GetTime and GetTime() or 0
end

-- Is this a usable angle (a number from 0 to 360)?
local function IsValidAngle(value)
	return PlainNumber(value) and value >= 0 and value <= 360
end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- Moves the button to the saved angle.
local function UpdatePosition()
	if not (button and settings) then
		return
	end
	local width = Minimap:GetWidth()
	if not (PlainNumber(width) and width > 0) then
		width = DEFAULT_MINIMAP_SIZE
	end
	local radius = width / 2 + RADIUS_MARGIN
	local angle = math.rad(settings.angle)
	local x, y = math.cos(angle) * radius, math.sin(angle) * radius
	if GetMinimapShape and GetMinimapShape() == "SQUARE" then
		local diagonal = math.sqrt(2 * radius * radius) - 1
		x = math.max(-radius, math.min(math.cos(angle) * diagonal, radius))
		y = math.max(-radius, math.min(math.sin(angle) * diagonal, radius))
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging: the angle of the cursor around the center of the minimap.
local function FollowCursor()
	if not (GetCursorPosition and settings) then
		return
	end
	local centerX, centerY = Minimap:GetCenter()
	local cursorX, cursorY = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	if not (PlainNumber(centerX) and PlainNumber(centerY) and PlainNumber(cursorX) and PlainNumber(cursorY)
		and PlainNumber(scale) and scale > 0) then
		return
	end
	settings.angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
	UpdatePosition()
end

function ns.GetMinimapAngle()
	return settings and settings.angle
end

-- Moves the button to an angle in degrees (0 to 360). Returns true when it was valid.
function ns.SetMinimapAngle(angle)
	if not settings or not IsValidAngle(angle) then
		return false
	end
	settings.angle = angle
	UpdatePosition()
	return true
end

-- Puts the button back at its default place.
function ns.ResetMinimapButton()
	if not settings then
		return false
	end
	settings.angle = DEFAULT_ANGLE
	UpdatePosition()
	return true
end

--------------------------------------------------------------------------------
-- Showing and hiding
--------------------------------------------------------------------------------

function ns.IsMinimapButtonShown()
	return settings ~= nil and settings.hide == false
end

function ns.SetMinimapButtonShown(shown)
	if not settings or type(shown) ~= "boolean" then
		return false
	end
	settings.hide = not shown
	if button then
		button:SetShown(shown)
		if shown then
			UpdatePosition()
		end
	end
	return true
end

-- The button, for tests.
function ns.GetMinimapButton()
	return button
end

--------------------------------------------------------------------------------
-- Actions (the button and the addon compartment share them)
--------------------------------------------------------------------------------

local function OpenSettings()
	if ns.ToggleOptions then
		ns.ToggleOptions()
	end
end

-- The same as /ju materials, so it explains itself while the mail features are off.
local function OpenMaterials()
	if ns.HandleMaterialsCommand then
		ns.HandleMaterialsCommand("")
	end
end

local function ShowTooltip(owner)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:SetText("Jimmy's Utils", 1, 1, 1)
	GameTooltip:AddLine("Left-click: settings", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: materials in your mail", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function HideTooltip()
	if GameTooltip then
		GameTooltip:Hide()
	end
end

-- Addon compartment (named in the .toc): (addonName, buttonName) for a click, (addonName, menuButton) for enter and leave.
function JimmysUtils_OnAddonCompartmentClick(_, buttonName)
	if buttonName == "RightButton" then
		OpenMaterials()
	else
		OpenSettings()
	end
end

function JimmysUtils_OnAddonCompartmentEnter(_, menuButton)
	if menuButton then
		ShowTooltip(menuButton)
	end
end

function JimmysUtils_OnAddonCompartmentLeave()
	HideTooltip()
end

--------------------------------------------------------------------------------
-- Button
--------------------------------------------------------------------------------

local function PlaceIcon(offsetX, offsetY)
	button.icon:ClearAllPoints()
	button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", offsetX, offsetY)
end

local function CreateButton()
	button = CreateFrame("Button", BUTTON_NAME, Minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(ICON_SIZE, ICON_SIZE)
	background:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
	background:SetTexture(BACKGROUND)

	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetSize(ICON_SIZE, ICON_SIZE)
	button.icon:SetTexture(ICON)
	PlaceIcon(7, -5)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(BORDER_SIZE, BORDER_SIZE)
	border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	border:SetTexture(BORDER)

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(button)
	highlight:SetTexture(HIGHLIGHT)
	highlight:SetBlendMode("ADD")

	button:SetScript("OnClick", function(_, mouseButton)
		if dragging or Now() < suppressUntil then
			return
		end
		if mouseButton == "RightButton" then
			OpenMaterials()
		else
			OpenSettings()
		end
	end)

	button:SetScript("OnDragStart", function(self)
		dragging = true
		HideTooltip()
		self:SetScript("OnUpdate", FollowCursor)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		dragging = false
		suppressUntil = Now() + CLICK_SUPPRESS_SECONDS
		UpdatePosition()
	end)

	-- The icon sinks a little while the mouse is down, like the other minimap buttons.
	button:SetScript("OnMouseDown", function()
		PlaceIcon(8, -6)
	end)
	button:SetScript("OnMouseUp", function()
		PlaceIcon(7, -5)
	end)

	button:SetScript("OnEnter", function(self)
		if not dragging then
			ShowTooltip(self)
		end
	end)
	button:SetScript("OnLeave", HideTooltip)
	button:SetScript("OnHide", function(self)
		self:SetScript("OnUpdate", nil)
		dragging = false
		HideTooltip()
	end)

	-- The minimap may be resized or moved by the interface after the addon loaded.
	button:RegisterEvent("PLAYER_ENTERING_WORLD")
	button:SetScript("OnEvent", UpdatePosition)

	button:SetShown(settings.hide == false)
	UpdatePosition()
end

--------------------------------------------------------------------------------
-- Command: /ju minimap ...
--------------------------------------------------------------------------------

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

local function PrintUsage()
	ns.Print("Usage: /ju minimap (show or hide the button) | /ju minimap reset (move it back to its default place)")
end

function ns.HandleMinimapCommand(rest)
	if not settings then
		ns.Print("The minimap button is not ready yet.")
		return
	end
	local lowered = Trim(rest or ""):lower()

	if lowered == "" then
		ns.SetMinimapButtonShown(not ns.IsMinimapButtonShown())
		ns.Print("Minimap button " .. (ns.IsMinimapButtonShown() and "shown." or "hidden. Type /ju minimap to show it again."))
	elseif lowered == "reset" then
		ns.ResetMinimapButton()
		ns.Print("Minimap button moved back to its default place.")
	else
		PrintUsage()
		return
	end
	ns.NotifyConfigChanged()
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db)
	if type(db.minimap) ~= "table" then
		db.minimap = {}
	end
	settings = db.minimap
	for name, default in pairs(DEFAULTS) do
		if type(settings[name]) ~= type(default) then
			settings[name] = default
		end
	end
	if not IsValidAngle(settings.angle) then
		settings.angle = DEFAULT_ANGLE
	end
end

function ns.InitMinimap(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)
	if Minimap then
		CreateButton()
	end
end

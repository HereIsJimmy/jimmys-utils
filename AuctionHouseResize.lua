local addonName, ns = ...

--[[
	A resizable auction house: a grip in the bottom right corner of Blizzard's AuctionHouseFrame (from the load-on-demand addon
	Blizzard_AuctionHouseUI) resizes the whole window. Dragging it makes the window larger (never smaller than Blizzard's size,
	never larger than the screen), a right-click on it goes back to the default size, and the size is saved and applied each time
	the window opens. On by default; the option is in the Stat Weights tab of the settings.

	What follows the size by itself: nearly every part of the window is anchored to its edges (the Browse results, the buy and sell
	frames, the Auctions tabs, and the tab frames of Auctionator, which anchors to the same edges), so they stretch with it. Two
	things need help (three, with the pictures):
		- The categories list on the left has a fixed height (the Browse results and the WoW Token page take theirs from it). It
		  gets the height it had when this addon attached plus the height the window gained.
		- The item lists (Browse results, buy lists, the Auctions tabs) work out their column widths only when their table layout
		  is marked dirty: their own SetTableBuilderLayout marks it (and rebuilds at once while the list is shown, or when it is
		  next shown). So after a change of width every item list under the window is handed its current layout function again.
		  That function is whatever the list has now (the score columns of AuctionScores.lua wrap it; they stay). The lists are
		  found by looking at the descendants of the window for the two fields they have; during a drag this is done at most every
		  0.1 s, and once more when the button is let go.
		- Blizzard's panels (AuctionHouseBackgroundTemplate) draw their background picture at the atlas's own size from their top
		  left corner. While the window is larger than its default size the picture is also anchored to the panel's bottom right
		  corner, so it stretches over the panel; at the default size it is put back exactly as Blizzard draws it.

	Sizing is done by hand (SetSize from the cursor position), not with StartSizing: that could re-anchor a window the panel manager
	positions, or mark it as placed by the user. The panel manager anchors the window by its top left corner (area "doublewide":
	TOPLEFT of UIParent) each time it opens or another panel opens beside it, so a change of size grows it to the right and
	downwards, and the manager keeps it on the screen when it is taller (it moves it up). The anchors of Blizzard's window are never
	touched here.

	Bounds: the minimum is the size the window has when this addon attaches (800 x 538 in the client); the maximum is the screen
	(UIParent) minus a margin, and while dragging also what is left between the window's top left corner and the edges of the
	screen, so the grip cannot be dragged out of reach.

	Disabled (the option off): the grip is hidden and the window and its categories list go back to their default sizes. The saved
	size is kept, so turning the option on again brings it back.

	Saved data (validated in ns.InitAuctionHouseResize):
		JimmysStatWeightsDB.auctionHouseSize = { enabled = true, width = nil, height = nil }
		-- width and height are whole numbers, never below the default size; nil means the default. Settings profiles carry
		-- only "enabled": the size of a window is not part of a profile (like the sizes of the other windows).
]]

local IsSecret = issecretvalue or function() return false end

local BLIZZARD_ADDON = "Blizzard_AuctionHouseUI"
local FALLBACK_WIDTH, FALLBACK_HEIGHT = 800, 538 -- Blizzard's size of the window, when it can't be read
local FALLBACK_CATEGORIES_HEIGHT = 438
local SCREEN_MARGIN = 40 -- the window is never larger than the screen minus this
local EDGE_MARGIN = 10 -- what a drag leaves between the window and the right and bottom edges of the screen
local GRIP_SIZE = 16
local GRIP_LEVEL = 100 -- above the window's own controls (and Auctionator's, which sit in the corner)
local LAYOUT_INTERVAL = 0.1 -- seconds between the layouts of the item lists during a drag
local MAX_DEPTH = 6 -- levels of frames looked at under the window for item lists
local MAX_FRAMES = 4000
local TEXTURE_UP = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up"
local TEXTURE_DOWN = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down"
local TEXTURE_HIGHLIGHT = "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight"

local DEFAULTS = {
	enabled = true,
}

-- Set in ns.InitAuctionHouseResize.
local settings
local initialized = false

local frame -- AuctionHouseFrame, once it exists
local grip
local categories -- AuctionHouseFrame.CategoriesList (nil when this client has none)
local defaultWidth, defaultHeight = FALLBACK_WIDTH, FALLBACK_HEIGHT
local categoriesHeight = FALLBACK_CATEGORIES_HEIGHT -- its height at the default size
local drag -- { startX, startY, width, height, scale, bounds..., elapsed, dirty, lists } while the grip is held

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function IsNumber(value)
	return type(value) == "number" and not IsSecret(value) and value == value and value ~= math.huge and value ~= -math.huge
end

local function Round(value)
	return math.floor(value + 0.5)
end

-- Calls a method of a widget; ok is false when it is missing or fails.
local function Call(object, method, ...)
	local ok, fn = pcall(function() return object[method] end)
	if not ok or type(fn) ~= "function" then
		return false
	end
	return pcall(fn, object, ...)
end

-- A number from a widget method, or nil.
local function Measure(object, method)
	local ok, value = Call(object, method)
	if ok and IsNumber(value) then
		return value
	end
end

local function EffectiveScale(object)
	local scale = Measure(object, "GetEffectiveScale")
	return scale and scale > 0 and scale or 1
end

--------------------------------------------------------------------------------
-- Item lists
--------------------------------------------------------------------------------

local function IsItemList(candidate)
	-- (a widget answers a name it does not have with nil; the pcall is for the odd one that does not)
	local ok, found = pcall(function()
		return type(candidate.SetTableBuilderLayout) == "function" and type(candidate.tableBuilderLayoutFunction) == "function"
	end)
	return ok and found == true
end

-- Whether a frame is one of Blizzard's panels with a background picture (AuctionHouseBackgroundTemplate: the item lists, the buy and
-- sell frames). Its picture is drawn at the atlas's own size from its top left corner, so it does not follow a larger window.
local function HasBackground(candidate)
	local ok, found = pcall(function()
		local background = candidate.Background
		return type(candidate.backgroundAtlas) == "string" and type(background) == "table" and type(background.SetAtlas) == "function"
	end)
	return ok and found == true
end

-- Every item list among the descendants of the window, and (second result) every panel with a background picture. The lists
-- themselves are not looked into (their rows are many).
local function FindItemLists()
	local lists, panels, visited = {}, {}, 0
	local function Walk(parent, depth)
		local ok, children = pcall(function() return { parent:GetChildren() } end)
		if not ok then
			return
		end
		for _, child in ipairs(children) do
			if visited >= MAX_FRAMES then
				return
			end
			if type(child) == "table" and not IsSecret(child) then
				visited = visited + 1
				if HasBackground(child) then
					panels[#panels + 1] = child
				end
				if IsItemList(child) then
					lists[#lists + 1] = child
				elseif depth < MAX_DEPTH then
					Walk(child, depth + 1)
				end
			end
		end
	end
	Walk(frame, 1)
	return lists, panels
end

-- Stretches the background pictures of the panels over the whole panel (`stretch`), or puts them back as Blizzard draws them (the
-- atlas's own size from the top left corner, AuctionHouseBackgroundMixin.OnLoad), which is right at the default size.
local function StretchBackgrounds(stretch)
	local _, panels = FindItemLists()
	for _, panel in ipairs(panels) do
		pcall(function()
			local background = panel.Background
			local x, y = tonumber(panel.backgroundXOffset) or 0, tonumber(panel.backgroundYOffset) or 0
			background:ClearAllPoints()
			background:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 3, y - 3)
			if stretch and panel.ScrollBox then
				-- A list: Blizzard's picture stops at the rows' right edge and leaves the scroll bar its own strip.
				background:SetPoint("BOTTOMRIGHT", panel.ScrollBox, "BOTTOMRIGHT", 0, 0)
			elseif stretch then
				background:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -3, 3)
			else
				background:SetAtlas(panel.backgroundAtlas, true)
			end
		end)
	end
end

-- Whether the window is larger than Blizzard's size (its backgrounds are stretched then).
local function IsEnlarged()
	local width, height = Measure(frame, "GetWidth"), Measure(frame, "GetHeight")
	return (width and Round(width) > defaultWidth) or (height and Round(height) > defaultHeight) or false
end

-- Hands every list its current layout function again: that marks the layout dirty, so the columns are worked out from the new width
-- (at once while the list is shown, else when it is shown next).
local function RelayoutLists(lists)
	for _, list in ipairs(lists or FindItemLists()) do
		local ok, layout = pcall(function() return list.tableBuilderLayoutFunction end)
		if ok and type(layout) == "function" then
			pcall(list.SetTableBuilderLayout, list, layout)
		end
	end
end

--------------------------------------------------------------------------------
-- Size
--------------------------------------------------------------------------------

-- The largest size the screen holds. `room` (while dragging): also no larger than what is left to the edges of the screen from the
-- window's top left corner.
local function MaxSize(room)
	local maxWidth, maxHeight = defaultWidth * 2, defaultHeight * 2
	local screenWidth, screenHeight = Measure(UIParent, "GetWidth"), Measure(UIParent, "GetHeight")
	local ratio = EffectiveScale(UIParent) / EffectiveScale(frame) -- UIParent units in the units of the window
	if screenWidth and screenWidth > 0 then
		maxWidth = math.floor(screenWidth * ratio - SCREEN_MARGIN)
	end
	if screenHeight and screenHeight > 0 then
		maxHeight = math.floor(screenHeight * ratio - SCREEN_MARGIN)
	end
	if room then
		local left, top = Measure(frame, "GetLeft"), Measure(frame, "GetTop")
		if left and screenWidth then
			maxWidth = math.min(maxWidth, math.floor(screenWidth * ratio - left - EDGE_MARGIN))
		end
		if top then
			maxHeight = math.min(maxHeight, math.floor(top - EDGE_MARGIN))
		end
	end
	return math.max(defaultWidth, maxWidth), math.max(defaultHeight, maxHeight)
end

local function Clamp(width, height, maxWidth, maxHeight)
	return math.max(defaultWidth, math.min(maxWidth, Round(width))), math.max(defaultHeight, math.min(maxHeight, Round(height)))
end

-- Puts the window (and the categories list) at a size. Returns whether anything changed.
local function SetFrameSize(width, height)
	local changed = false
	if Measure(frame, "GetWidth") ~= width or Measure(frame, "GetHeight") ~= height then
		changed = Call(frame, "SetSize", width, height) or changed
	end
	if categories then
		local wanted = categoriesHeight + (height - defaultHeight)
		if Measure(categories, "GetHeight") ~= wanted then
			changed = Call(categories, "SetHeight", wanted) or changed
		end
	end
	return changed
end

-- The saved size inside the bounds (a missing one is the default).
local function SavedSize()
	local maxWidth, maxHeight = MaxSize(false)
	return Clamp(settings.width or defaultWidth, settings.height or defaultHeight, maxWidth, maxHeight)
end

-- Gives the window the size it should have now: the saved one while the option is on, else the default one.
local function Apply()
	if not (frame and settings) then
		return
	end
	local width, height = defaultWidth, defaultHeight
	if settings.enabled then
		width, height = SavedSize()
	end
	local changed = SetFrameSize(width, height)
	if grip then
		grip:SetShown(settings.enabled == true)
	end
	StretchBackgrounds(IsEnlarged())
	if changed then
		RelayoutLists()
	end
end

-- The window's size is what the user chose: saved (the default size is saved as nothing).
local function SaveSize()
	local width, height = Measure(frame, "GetWidth"), Measure(frame, "GetHeight")
	if not (width and height) then
		return
	end
	width, height = Round(width), Round(height)
	settings.width = width ~= defaultWidth and width or nil
	settings.height = height ~= defaultHeight and height or nil
end

--------------------------------------------------------------------------------
-- The grip
--------------------------------------------------------------------------------

local function StopDrag()
	if not drag then
		return
	end
	drag = nil
	grip:SetScript("OnUpdate", nil)
	grip.texture:SetTexture(TEXTURE_UP)
	SaveSize()
	StretchBackgrounds(IsEnlarged())
	RelayoutLists()
end

local function OnUpdate(_, elapsed)
	if not drag then
		return
	end
	-- The button was let go somewhere the grip did not hear of (the game lost focus, say).
	if type(IsMouseButtonDown) == "function" and not IsMouseButtonDown("LeftButton") then
		StopDrag()
		return
	end
	local cursorX, cursorY = GetCursorPosition()
	if not (IsNumber(cursorX) and IsNumber(cursorY)) then
		return
	end
	-- The cursor moves in screen pixels; the window is sized in its own units.
	local width, height = Clamp(drag.width + (cursorX - drag.cursorX) / drag.scale, drag.height + (drag.cursorY - cursorY) / drag.scale,
		drag.maxWidth, drag.maxHeight)
	if SetFrameSize(width, height) then
		drag.dirty = true
	end
	drag.elapsed = drag.elapsed + (IsNumber(elapsed) and elapsed or 0)
	if drag.dirty and drag.elapsed >= LAYOUT_INTERVAL then
		drag.elapsed, drag.dirty = 0, false
		RelayoutLists(drag.lists)
	end
end

local function StartDrag()
	local cursorX, cursorY = GetCursorPosition()
	local width, height = Measure(frame, "GetWidth"), Measure(frame, "GetHeight")
	if not (settings.enabled and IsNumber(cursorX) and IsNumber(cursorY) and width and height) then
		return
	end
	local maxWidth, maxHeight = MaxSize(true)
	drag = {
		cursorX = cursorX, cursorY = cursorY, width = width, height = height, scale = EffectiveScale(frame),
		maxWidth = math.max(maxWidth, Round(width)), maxHeight = math.max(maxHeight, Round(height)), -- (never below where it is)
		elapsed = 0, dirty = false, lists = FindItemLists(),
	}
	grip.texture:SetTexture(TEXTURE_DOWN)
	StretchBackgrounds(true) -- (anchored to the panels' corners, the pictures follow the drag by themselves)
	grip:SetScript("OnUpdate", OnUpdate)
end

-- Right-click: the default size.
local function ResetSize()
	settings.width, settings.height = nil, nil
	if settings.enabled then
		Apply()
	end
end

local function ShowTooltip(owner)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:SetText("Drag to resize the auction house.", 1, 1, 1)
	GameTooltip:AddLine("Right-click: default size.", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function CreateGrip()
	local button = CreateFrame("Button", nil, frame)
	button:SetSize(GRIP_SIZE, GRIP_SIZE)
	button:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
	button:SetFrameLevel(frame:GetFrameLevel() + GRIP_LEVEL)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button.texture = button:CreateTexture(nil, "ARTWORK")
	button.texture:SetAllPoints(button)
	button.texture:SetTexture(TEXTURE_UP)
	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(button)
	highlight:SetTexture(TEXTURE_HIGHLIGHT)
	button:SetScript("OnMouseDown", function(_, mouseButton)
		if mouseButton == "LeftButton" then
			StartDrag()
		end
	end)
	button:SetScript("OnMouseUp", function(_, mouseButton)
		if mouseButton == "LeftButton" then
			StopDrag()
		elseif mouseButton == "RightButton" and not drag then
			ResetSize()
		end
	end)
	button:SetScript("OnHide", StopDrag)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	return button
end

--------------------------------------------------------------------------------
-- Attaching to Blizzard's window
--------------------------------------------------------------------------------

local function Attach()
	if frame then
		return true
	end
	local window = AuctionHouseFrame
	if type(window) ~= "table" or IsSecret(window) then
		return false
	end
	frame = window
	-- The default size is what the window has now (nothing has resized it yet).
	local width, height = Measure(frame, "GetWidth"), Measure(frame, "GetHeight")
	defaultWidth = width and width > 0 and Round(width) or FALLBACK_WIDTH
	defaultHeight = height and height > 0 and Round(height) or FALLBACK_HEIGHT
	local list = frame.CategoriesList
	if type(list) == "table" and not IsSecret(list) then
		categories = list
		local listHeight = Measure(categories, "GetHeight")
		categoriesHeight = listHeight and listHeight > 0 and listHeight or FALLBACK_CATEGORIES_HEIGHT
	end
	grip = CreateGrip()
	pcall(frame.HookScript, frame, "OnShow", Apply)
	pcall(frame.HookScript, frame, "OnHide", StopDrag)
	Apply()
	return true
end

local function OnEvent(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == BLIZZARD_ADDON then
		Attach()
	end
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function ns.IsAuctionHouseResizeEnabled()
	return settings ~= nil and settings.enabled == true
end

function ns.SetAuctionHouseResizeEnabled(enabled)
	if not settings or type(enabled) ~= "boolean" then
		return false
	end
	settings.enabled = enabled
	Apply()
	if ns.SettingsChanged then
		ns.SettingsChanged()
	end
	return true
end

-- A saved dimension as it should be kept: a whole number, never below Blizzard's size (the real default is only known once the window
-- exists, and is checked again then); nil when it is not a number.
local function CleanDimension(value, minimum)
	if not IsNumber(value) then
		return nil
	end
	return math.max(minimum, Round(value))
end

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db)
	if type(db.auctionHouseSize) ~= "table" then
		db.auctionHouseSize = {}
	end
	settings = db.auctionHouseSize
	for name, default in pairs(DEFAULTS) do
		if type(settings[name]) ~= type(default) then
			settings[name] = default
		end
	end
	settings.width = CleanDimension(settings.width, FALLBACK_WIDTH)
	settings.height = CleanDimension(settings.height, FALLBACK_HEIGHT)
end

function ns.InitAuctionHouseResize(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)

	local driver = CreateFrame("Frame")
	pcall(driver.RegisterEvent, driver, "ADDON_LOADED")
	driver:SetScript("OnEvent", OnEvent)
	Attach()
end

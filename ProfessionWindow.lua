local addonName, ns = ...

--[[
	Profession window that stays put: with the option on (Options > Recipes, off by default) Blizzard's profession window
	(ProfessionsFrame, from the load-on-demand addon Blizzard_Professions) is taken out of Blizzard's UI panel manager, so opening
	the character panel, the spellbook, a merchant, the friends list... never closes it or pushes it aside, and it can be dragged
	by its title bar to wherever you like. Its position is saved. Off gives the window back to Blizzard's panel manager, but only
	after a /reload (see below).

	How: Blizzard registers the window with RegisterUIPanel, which keeps its layout in UIPanelWindows.ProfessionsFrame and copies it
	to the frame's "UIPanelLayout-*" attributes the first time the manager asks. A frame the manager knows nothing about is shown
	and hidden with a plain Show/Hide, so detaching is: keep the original layout table, set UIPanelWindows.ProfessionsFrame to nil
	and clear the frame's "UIPanelLayout-defined" and "UIPanelLayout-area" attributes. Escape still closes the window (its own
	escape handler, not the manager's). Only HookScript is used on Blizzard's frames; none of its functions is replaced.

	Trade-off (taint): UIPanelWindows is a table of Blizzard's secure code and the layout attributes are read by the panel manager,
	so writing them from an addon makes the manager's data tainted for the rest of the session. That is the price of the feature, and
	it cannot be undone from addon code: putting the table and the attributes back would only write them again from tainted code.
	So the feature only ever detaches (when the option is on, once the window is hidden and out of combat) and never re-attaches:
	turning the option off keeps the window detached for the rest of the session ("takes effect after /reload") and the next load
	simply does not detach it, which is the only way Blizzard's behaviour comes back clean. With the option off from the start,
	nothing of Blizzard's is written at all.

	The switch is made only while the window is hidden and out of combat: the manager keeps the window it shows as its "left" panel,
	and taking the registration away from a window it holds would leave that state stale. Turning the option on while the window is
	open waits for its next hide (the switch runs a moment after it, once the manager has finished hiding the window); in combat it
	waits for PLAYER_REGEN_ENABLED. Without Blizzard_Professions nothing happens until it loads.

	While detached the window is movable and clamped to the screen, is put at its saved position every time it shows (by default
	where Blizzard puts a left panel) and is dragged with the left mouse button by its title bar: TitleContainer, or else the top
	strip of the frame. The drag is the frame's own StartMoving, and its position is saved when the button is released;
	SetUserPlaced(false) keeps the client's layout cache from fighting it. While not detached none of this does anything.

	Saved data (validated in ns.InitProfessionWindow):
		JimmysStatWeightsDB.professionWindow = { detached = false, position = { point, relPoint, x, y } }
		-- position is relative to UIParent and absent until the window was moved
]]

local PANEL_ADDON = "Blizzard_Professions"
local PANEL_NAME = "ProfessionsFrame"
local TITLE_HEIGHT = 30 -- the strip of the frame's top edge that drags it when there is no TitleContainer
local MAX_OFFSET = 10000
-- Where Blizzard puts a left panel: 16 px from the screen's left edge plus the registration's xoffset of 35, and 116 px down.
local DEFAULT_POSITION = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 51, y = -116 }
local VALID_POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Set in ns.InitProfessionWindow.
local settings
local initialized = false
local hooked = false
local detached = false -- whether the window is out of the panel manager in this session (it stays so when the option goes off)
local dragging = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

-- A real number that is not a secret value.
local function PlainNumber(value)
	return not IsSecret(value) and type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

-- The profession window once Blizzard_Professions made it.
local function GetFrame()
	local frame = ProfessionsFrame
	if IsSecret(frame) or type(frame) ~= "table" or type(frame.GetName) ~= "function" then
		return nil
	end
	return frame
end

-- Calls a method of a client frame, which may be missing or fail on this client. Returns true and its results, or false.
local function Call(frame, method, ...)
	local fn = frame and frame[method]
	if type(fn) ~= "function" then
		return false
	end
	return pcall(fn, frame, ...)
end

local function InCombat()
	if type(InCombatLockdown) ~= "function" then
		return false
	end
	local ok, locked = pcall(InCombatLockdown)
	return ok and locked and true or false
end

-- Runs `fn` on the next frame (never inside Blizzard's own hide code), or at once without timers.
local function Defer(fn)
	if C_Timer and C_Timer.After then
		C_Timer.After(0, fn)
	else
		fn()
	end
end

--------------------------------------------------------------------------------
-- Position and dragging (only while detached)
--------------------------------------------------------------------------------

local function ApplyPosition(frame)
	local position = settings and settings.position or DEFAULT_POSITION
	Call(frame, "ClearAllPoints")
	Call(frame, "SetPoint", position.point, UIParent, position.relPoint, position.x, position.y)
end

local function SavePosition(frame)
	local ok, point, relative, relPoint, x, y = Call(frame, "GetPoint", 1)
	if not ok or (relative ~= nil and relative ~= UIParent) then
		return
	end
	if VALID_POINTS[point] and VALID_POINTS[relPoint] and PlainNumber(x) and PlainNumber(y)
		and math.abs(x) <= MAX_OFFSET and math.abs(y) <= MAX_OFFSET then
		settings.position = { point = point, relPoint = relPoint, x = x, y = y }
	end
end

-- Whether the cursor is in the top strip of the frame (used for the frame itself, which has no title bar of its own to hook).
local function InTitleStrip(frame)
	local okTop, top = Call(frame, "GetTop")
	local okScale, scale = Call(frame, "GetEffectiveScale")
	local _, cursorY = GetCursorPosition()
	if not (okTop and okScale and PlainNumber(top) and PlainNumber(scale) and scale > 0 and PlainNumber(cursorY)) then
		return false
	end
	return cursorY / scale >= top - TITLE_HEIGHT
end

local function StopDrag(frame)
	if not dragging then
		return
	end
	dragging = false
	Call(frame, "StopMovingOrSizing")
	Call(frame, "SetUserPlaced", false) -- our own anchor is the saved one, not the client's layout cache
	SavePosition(frame)
end

local function OnMouseDown(source, button)
	local frame = GetFrame()
	if not detached or dragging or button ~= "LeftButton" or not frame then
		return
	end
	if source == frame and not InTitleStrip(frame) then
		return
	end
	if Call(frame, "StartMoving") then
		dragging = true
	end
end

local function OnMouseUp(_, button)
	local frame = GetFrame()
	if frame and dragging and button == "LeftButton" then
		StopDrag(frame)
	end
end

--------------------------------------------------------------------------------
-- Detaching from Blizzard's panel manager
--------------------------------------------------------------------------------

local function Detach(frame)
	if type(UIPanelWindows) == "table" then
		UIPanelWindows[PANEL_NAME] = nil
	end
	Call(frame, "SetAttribute", "UIPanelLayout-defined", nil)
	Call(frame, "SetAttribute", "UIPanelLayout-area", nil)
	Call(frame, "SetMovable", true)
	Call(frame, "SetClampedToScreen", true)
	Call(frame, "SetUserPlaced", false)
	detached = true
end

-- There is no Attach on purpose (see the top of the file): once detached the window stays so until the next load.

-- Detaches the window when the option is on and it is safe: hidden and out of combat. Otherwise the hide hook or the end of the
-- combat calls this again. With the option off nothing is ever done.
local function Sync()
	local frame = GetFrame()
	if not frame or detached or not (settings ~= nil and settings.detached == true) then
		return
	end
	local okShown, shown = Call(frame, "IsShown")
	if not okShown or shown or InCombat() then
		return
	end
	Detach(frame)
end

-- Hooks the window once it exists.
local function HookFrame()
	local frame = GetFrame()
	if hooked or not frame or type(frame.HookScript) ~= "function" then
		return
	end
	hooked = true
	Call(frame, "HookScript", "OnShow", function(self)
		if detached then
			ApplyPosition(self)
		end
	end)
	Call(frame, "HookScript", "OnHide", function(self)
		StopDrag(self)
		if not detached and settings ~= nil and settings.detached == true then
			Defer(Sync) -- the manager is still hiding it
		end
	end)
	Call(frame, "HookScript", "OnMouseDown", OnMouseDown)
	Call(frame, "HookScript", "OnMouseUp", OnMouseUp)
	-- The title bar, when the frame has one (mouse events do not reach the frame through a child that takes the mouse).
	local title = frame.TitleContainer
	if type(title) == "table" and not IsSecret(title) then
		Call(title, "HookScript", "OnMouseDown", OnMouseDown)
		Call(title, "HookScript", "OnMouseUp", OnMouseUp)
	end
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function ns.IsProfessionWindowDetached()
	return settings ~= nil and settings.detached == true
end

-- Whether the option is off but the window is still detached in this session (it takes a /reload to give it back to Blizzard).
function ns.ProfessionWindowNeedsReload()
	return detached and not (settings ~= nil and settings.detached == true)
end

-- Switches the option. On: the window is detached when it is hidden and out of combat (see the top of the file). Off: nothing is
-- touched, a window that is already detached stays so until /reload. Returns true (or false for a bad call) and whether a /reload
-- is needed for the window to go back to Blizzard's panel manager.
function ns.SetProfessionWindowDetached(enabled)
	if not settings or type(enabled) ~= "boolean" then
		return false
	end
	settings.detached = enabled
	HookFrame()
	Sync()
	if ns.SettingsChanged then
		ns.SettingsChanged()
	end
	return true, ns.ProfessionWindowNeedsReload()
end

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db)
	if type(db.professionWindow) ~= "table" then
		db.professionWindow = {}
	end
	settings = db.professionWindow
	if type(settings.detached) ~= "boolean" then
		settings.detached = false
	end
	local position = settings.position
	if type(position) ~= "table" or not VALID_POINTS[position.point] or not VALID_POINTS[position.relPoint]
		or not PlainNumber(position.x) or not PlainNumber(position.y)
		or math.abs(position.x) > MAX_OFFSET or math.abs(position.y) > MAX_OFFSET then
		settings.position = nil
	else
		settings.position = { point = position.point, relPoint = position.relPoint, x = position.x, y = position.y }
	end
end

function ns.InitProfessionWindow(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)

	local driver = CreateFrame("Frame")
	-- An event this client does not have must not stop the others from being registered.
	for _, event in ipairs({ "ADDON_LOADED", "PLAYER_REGEN_ENABLED" }) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript("OnEvent", function(_, event, loadedName)
		if event == "ADDON_LOADED" then
			if loadedName == PANEL_ADDON then
				HookFrame()
				Sync()
			end
		else
			Sync() -- combat is over
		end
	end)
	HookFrame()
	Sync()
end

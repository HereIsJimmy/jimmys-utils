local addonName, ns = ...

--[[
	Map pin: /ju pin <x> <y> puts the map pin (the "user waypoint" that shift-clicking the map sets) in the zone the character is
	in, at coordinates given in percent like the map shows them (0-100). /ju pin alone puts it where the character stands
	(C_Map.GetPlayerMapPosition). The in-world arrow is turned on too, so the pin is tracked without opening the map.
	/ju pin clear (or remove) takes the pin away again.

	Nothing is saved and nothing is hooked: the command only calls C_Map and C_SuperTrack. Every API result is checked for
	secret values before it is used, and every call is protected, because the client may not allow a pin in some zones.
]]

local IsSecret = issecretvalue or function() return false end

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

local USAGE = "Usage: /ju pin <x> <y> - for example /ju pin 45.2 67.8 (coordinates of the current zone, 0-100). /ju pin alone pins where you stand; /ju pin clear removes the pin."

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

-- A plain decimal number: digits with an optional fraction and sign, no exponent, no hex. Returns nil for anything else.
local function ParseNumber(token)
	if not (token:match("^[+-]?%d+$") or token:match("^[+-]?%d*%.%d+$")) then
		return nil
	end
	return tonumber(token)
end

-- "45.2 67.8", "45.2, 67.8", "45.2,67.8", "45 67" and "45,2 67,8" (decimal commas). Returns x, y in percent, or nil and
-- "format" (not two numbers) or "range" (a number outside 0-100).
function ns.ParsePinCoordinates(text)
	text = Trim(tostring(text or ""))
	local tokens = {}
	for token in text:gmatch("%S+") do
		tokens[#tokens + 1] = token
	end

	local first, second
	if #tokens == 2 then
		-- The first number may be followed by a separating comma; a single comma left in a number is a decimal comma.
		first = tokens[1]:gsub(",$", "")
		second = tokens[2]
		if select(2, first:gsub(",", "")) > 1 or select(2, second:gsub(",", "")) > 1 then
			return nil, "format"
		end
		first, second = first:gsub(",", "."), second:gsub(",", ".")
	elseif #tokens == 1 and select(2, tokens[1]:gsub(",", "")) == 1 then
		first, second = tokens[1]:match("^([^,]*),([^,]*)$")
	end
	if not first or not second then
		return nil, "format"
	end

	local x, y = ParseNumber(first), ParseNumber(second)
	if not x or not y then
		return nil, "format"
	end
	if x < 0 or x > 100 or y < 0 or y > 100 then
		return nil, "range"
	end
	return x, y
end

-- At most one decimal, without a trailing ".0".
local function FormatCoordinate(value)
	return (("%.1f"):format(value):gsub("%.0$", ""))
end

--------------------------------------------------------------------------------
-- Command: /ju pin ...
--------------------------------------------------------------------------------

-- Calls a client function and returns its first result, or nil when it is missing, raises, or the result is secret.
local function SafeCall(fn, ...)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if not ok or IsSecret(result) then
		return nil
	end
	return result
end

local function SetSuperTracked(enabled)
	if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
		pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, enabled)
	end
end

local function ClearPin()
	if not (C_Map and C_Map.ClearUserWaypoint) then
		ns.Print("The map pin is not available.")
		return
	end
	-- Only a plain false means there is no pin; anything else (including a secret value) just clears.
	if C_Map.HasUserWaypoint then
		local ok, has = pcall(C_Map.HasUserWaypoint)
		if ok and not IsSecret(has) and has == false then
			ns.Print("There is no map pin.")
			return
		end
	end
	pcall(C_Map.ClearUserWaypoint)
	SetSuperTracked(false)
	ns.Print("Map pin removed.")
end

-- Where the player stands on the map, in percent (x, y), or nil when the client does not say (inside instances, for example).
local function ReadPlayerPosition(mapID)
	local position = SafeCall(C_Map.GetPlayerMapPosition, mapID, "player")
	if type(position) ~= "table" then
		return nil
	end
	local x, y
	if type(position.GetXY) == "function" then
		local ok, px, py = pcall(position.GetXY, position)
		if ok then
			x, y = px, py
		end
	else
		x, y = position.x, position.y
	end
	if IsSecret(x) or IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y
		or x < 0 or x > 1 or y < 0 or y > 1 or (x == 0 and y == 0) then
		return nil
	end
	return x * 100, y * 100
end

-- Puts the pin at x, y (percent) of the current zone; without x and y, where the player stands.
local function SetPin(x, y)
	if not (C_Map and C_Map.SetUserWaypoint and C_Map.GetBestMapForUnit and CreateVector2D) then
		ns.Print("The map pin is not available.")
		return
	end

	local mapID = SafeCall(C_Map.GetBestMapForUnit, "player")
	if type(mapID) ~= "number" then
		ns.Print("Can't tell which zone you are in.")
		return
	end

	local info = SafeCall(C_Map.GetMapInfo, mapID)
	local zone = type(info) == "table" and info.name
	if type(zone) ~= "string" or IsSecret(zone) or zone == "" then
		zone = nil
	end

	if x == nil then
		x, y = ReadPlayerPosition(mapID)
		if not x then
			ns.Print("Can't tell where you are on the map" .. (zone and (" of " .. zone) or "") .. ".")
			return
		end
	end

	if C_Map.CanSetUserWaypointOnMap then
		local ok, allowed = pcall(C_Map.CanSetUserWaypointOnMap, mapID)
		if ok and (IsSecret(allowed) or allowed ~= true) then
			ns.Print("A map pin can't be placed in " .. (zone or "this zone") .. ".")
			return
		end
	end

	local point
	if UiMapPoint and UiMapPoint.CreateFromCoordinates then
		local ok, result = pcall(UiMapPoint.CreateFromCoordinates, mapID, x / 100, y / 100)
		point = ok and result or nil
	else
		point = { uiMapID = mapID, position = CreateVector2D(x / 100, y / 100) }
	end
	if not point or not pcall(C_Map.SetUserWaypoint, point) then
		ns.Print("The map pin could not be set.")
		return
	end

	SetSuperTracked(true)
	if PlaySound and SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK then
		pcall(PlaySound, SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK)
	end

	local message = "Map pin set " .. (zone and ("in " .. zone .. " ") or "") .. "at " .. FormatCoordinate(x) .. ", " .. FormatCoordinate(y) .. "."
	local link = SafeCall(C_Map.GetUserWaypointHyperlink)
	if type(link) == "string" and link ~= "" then
		message = message .. " " .. link
	end
	ns.Print(message)
end

function ns.HandlePinCommand(rest)
	local text = Trim(rest or "")
	local lowered = text:lower()
	if lowered == "clear" or lowered == "remove" then
		ClearPin()
		return
	end
	if text == "" then
		SetPin()
		return
	end

	local x, y = ns.ParsePinCoordinates(text)
	if not x then
		if y == "range" then
			ns.Print("Coordinates go from 0 to 100.")
		else
			ns.Print(USAGE)
		end
		return
	end
	SetPin(x, y)
end

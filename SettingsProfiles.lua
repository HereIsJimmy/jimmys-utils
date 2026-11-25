local addonName, ns = ...

--[[
	Settings profiles: named snapshots of the settings of the whole addon. A character uses one profile; switching it applies the
	profile to the live settings in one go. Every profile can be exported as a text string and imported again (any account).
	(Not to be confused with the stat weight "scales", which the code calls profiles: db.profiles, ns.*Profile*, Core.lua.)

	Saved data (account wide, validated in ns.InitSettingsProfiles):
		JimmysStatWeightsDB.settingsProfiles = { ["Name"] = profile }
		JimmysStatWeightsDB.activeSettingsProfile = { ["Name-Realm"] = "Name" } -- keyed by ns.GetCharacterKey(), like the active scale

	A profile is a table with the same section names as the saved variables, each holding only the settings listed below (every
	one of them is always present in a clean profile; a missing or invalid value is the default):
		settings        decimals, hideZero, breakdown, parseEquipText     (the display of the stat weight scores)
		stats           enabled                                           (stat weight scores on item tooltips)
		range           enabled, locked, size, anchor                     (range check; not the position point/x/y, not the spell)
		recipeLookup    enabled, onlyMyProfessions, sortProfit, hiddenProfessions   (recipe lookup and the recipes window; not its size)
		mail            enabled                                           (recent recipients and mail materials)
		mailMaterials   showOthers, sortProfit, hiddenProfessions         (the materials window; not its position and size)
		profit          enabled, listSort                                 (crafting profit)
		auctionScores   enabled                                           (score columns of the auction house; not the sort, which names a scale)
		auctionHouseSize enabled                                          (the resizable auction house window; not its size)
		professionWindow detached                                         (not its position)
		minimap         hide                                              (not the angle)
	Never part of a profile: the stat weight scales and everything that names one (the active scale, the scales a character hides,
	auctionScores.sortProfile), saved data (recipes, who knows them, skills, item names, inventories, mail recipients, mail snapshots),
	window sizes and positions, the minimap angle, the range spell (class specific, in the character's own saved variables), the
	options window's last tab and size, and the migration maps.

	The live settings stay where they are (db.settings, db.range, ...), so the rest of the addon is unchanged. The active profile is a
	snapshot kept in step with them: every setter of those settings calls ns.SettingsChanged (Core.lua), which ends in
	ns.SyncSettingsProfile; PLAYER_LOGOUT takes a last snapshot. Applying a profile goes through the same setters, so their side
	effects happen (minimap button, range frames, columns of the auction house...); the sync is paused meanwhile.

	Without a known realm there is no character key: nothing is written under a nil key and nothing is synced until a profile has been
	switched explicitly (pendingName); at PLAYER_LOGIN (or at load, when the realm is known) the character's profile is applied if it
	differs from the live settings, and a profile switched meanwhile becomes the character's.

	Export string: "JU1:" .. checksum (8 hex digits) .. ":" .. base64 of the text of { n = name, p = profile }. The text is a plain
	serialization (strings, numbers, booleans, nested tables, keys sorted) that Deserialize reads with its own small parser: nothing of
	the input is ever run. Import cleans every value like the load does, ignores (and reports) what it does not know and limits the
	size, the depth and the number of values.
]]

local DEFAULT_NAME = "Default"
local MAX_NAME = ns.MAX_PROFILE_NAME or 32
local FORMAT_VERSION = 1
local FORMAT_PREFIX = "JU" .. FORMAT_VERSION .. ":"
local MAX_ENCODED = 16384 -- characters of an import string (a profile with every profession hidden is about 1 KB)
local MAX_DEPTH = 6
local MAX_NODES = 2000
local MAX_STRING = 200
local MAX_REPORTED = 12 -- unknown keys listed in a message

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

local function IsFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- The names of a table sorted like the scales: ignoring case, then by spelling.
local function SortedKeys(tbl)
	local keys = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		local la, lb = a:lower(), b:lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return keys
end

-- The first `limit` characters of a UTF-8 text.
local function CutCharacters(text, limit)
	local count = 0
	for start in text:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
		count = count + 1
		if count > limit then
			return text:sub(1, start - 1)
		end
	end
	return text
end

-- The well-formed UTF-8 characters of a text, in order (a stray or overlong byte is dropped), without control characters and "|" (which
-- would start a colour or link code where the name is shown).
local function CleanText(text)
	local out, index, length = {}, 1, #text
	local function Continues(from, count)
		for offset = from, from + count - 1 do
			local byte = text:byte(offset)
			if not byte or byte < 128 or byte > 191 then
				return false
			end
		end
		return true
	end
	while index <= length do
		local byte = text:byte(index)
		local size
		if byte < 128 then
			size = (byte >= 32 and byte ~= 127 and byte ~= 124) and 1 or 0
			if size == 0 then
				index = index + 1
			end
		elseif byte >= 194 and byte <= 223 and Continues(index + 1, 1) then
			size = 2
		elseif byte >= 224 and byte <= 239 and Continues(index + 1, 2) then
			size = 3
		elseif byte >= 240 and byte <= 244 and Continues(index + 1, 3) then
			size = 4
		else
			size = 0
			index = index + 1
		end
		if size > 0 then
			out[#out + 1] = text:sub(index, index + size - 1)
			index = index + size
		end
	end
	return table.concat(out)
end

-- A key of an import string as it is shown in a message: only plain characters, cut short.
local function DisplayKey(key)
	if type(key) ~= "string" then
		return "?"
	end
	return (CutCharacters(key, 40):gsub("[^%w_%.%-]", "?"))
end

local function Call(name, ...)
	local fn = ns[name]
	if fn then
		return fn(...)
	end
end

--------------------------------------------------------------------------------
-- What a profile holds
--------------------------------------------------------------------------------

local function CleanBoolean(value)
	if type(value) == "boolean" then
		return value
	end
end

local function CleanDecimals(value)
	if IsFiniteNumber(value) then
		return math.max(0, math.min(3, math.floor(value)))
	end
end

local function CleanBreakdown(value)
	if type(value) == "string" and ns.BREAKDOWN_MODES and ns.BREAKDOWN_MODES[value] then
		return value
	end
end

local function CleanRangeSize(value)
	if ns.IsValidRangeSize(value) then
		return value
	end
end

local function CleanAnchor(value)
	if type(value) == "string" and ns.RANGE_ANCHOR_MODES and ns.RANGE_ANCHOR_MODES[value] then
		return value
	end
end

local function CleanListSort(value)
	if type(value) == "string" and ns.PROFIT_LIST_SORTS and ns.PROFIT_LIST_SORTS[value] then
		return value
	end
end

-- A set of hidden professions: a new table with the usable entries only (nil when it is not a table).
local function CleanProfessionSet(value)
	if type(value) == "table" then
		return ns.CleanProfessionSet(value)
	end
end

-- Does the set `wanted` differ from the live one? (Both { [key] = true }.)
local function SameSet(a, b)
	for key in pairs(a) do
		if not b[key] then
			return false
		end
	end
	for key in pairs(b) do
		if not a[key] then
			return false
		end
	end
	return true
end

-- Makes the live set of hidden professions equal to `wanted` through its setter (which refreshes the windows).
local function ApplySet(getName, setName, wanted)
	local live = Call(getName)
	if type(live) ~= "table" then
		return
	end
	local current = {}
	for key in pairs(live) do
		current[key] = true
	end
	for key in pairs(current) do
		if not wanted[key] then
			Call(setName, key, false)
		end
	end
	for key in pairs(wanted) do
		if not current[key] then
			Call(setName, key, true)
		end
	end
end

local function Field(key, default, clean, apply)
	return { key = key, default = default, clean = clean, apply = apply }
end

-- Applies a field through ns.<setter>(name, value).
local function Through(setter, name)
	return function(value)
		return Call(setter, name, value)
	end
end

-- The sections and fields of a profile, in the order they are applied. `default` is the value of a fresh install (the same as the
-- DEFAULTS of each feature; a test compares them); a function default makes a new table. `clean` returns the usable value or nil.
local SECTIONS = {
	{ key = "settings", fields = {
		Field("decimals", 1, CleanDecimals, Through("SetSetting", "decimals")),
		Field("hideZero", true, CleanBoolean, Through("SetSetting", "hideZero")),
		Field("breakdown", "alt", CleanBreakdown, Through("SetSetting", "breakdown")),
		Field("parseEquipText", true, CleanBoolean, Through("SetSetting", "parseEquipText")),
	} },
	{ key = "stats", fields = {
		Field("enabled", true, CleanBoolean, function(value) return Call("SetStatsEnabled", value) end),
	} },
	{ key = "range", fields = {
		Field("enabled", true, CleanBoolean, Through("SetRangeSetting", "enabled")),
		Field("locked", true, CleanBoolean, Through("SetRangeSetting", "locked")),
		Field("size", 32, CleanRangeSize, Through("SetRangeSetting", "size")),
		Field("anchor", "nameplate", CleanAnchor, Through("SetRangeSetting", "anchor")),
	} },
	{ key = "recipeLookup", fields = {
		Field("enabled", true, CleanBoolean, function(value) return Call("SetRecipeLookupEnabled", value) end),
		Field("onlyMyProfessions", false, CleanBoolean, Through("SetRecipeWindowOption", "onlyMyProfessions")),
		Field("sortProfit", false, CleanBoolean, Through("SetRecipeWindowOption", "sortProfit")),
		Field("hiddenProfessions", function() return {} end, CleanProfessionSet, function(value)
			ApplySet("GetHiddenRecipeProfessions", "SetRecipeProfessionHidden", value)
		end),
	} },
	{ key = "mail", fields = {
		Field("enabled", true, CleanBoolean, function(value) return Call("SetMailEnabled", value) end),
	} },
	{ key = "mailMaterials", fields = {
		Field("showOthers", true, CleanBoolean, Through("SetMaterialsOption", "showOthers")),
		Field("sortProfit", false, CleanBoolean, Through("SetMaterialsOption", "sortProfit")),
		Field("hiddenProfessions", function() return {} end, CleanProfessionSet, function(value)
			ApplySet("GetHiddenMaterialProfessions", "SetMaterialProfessionHidden", value)
		end),
	} },
	{ key = "profit", fields = {
		Field("enabled", true, CleanBoolean, function(value) return Call("SetProfitEnabled", value) end),
		Field("listSort", "blizzard", CleanListSort, function(value) return Call("ApplyProfitListSort", value) end),
	} },
	{ key = "auctionScores", fields = {
		Field("enabled", true, CleanBoolean, function(value) return Call("SetAuctionScoresEnabled", value) end),
	} },
	{ key = "auctionHouseSize", fields = {
		Field("enabled", true, CleanBoolean, function(value) return Call("SetAuctionHouseResizeEnabled", value) end),
	} },
	{ key = "professionWindow", fields = {
		-- Returns what the setter returns: ok, and whether a /reload is needed to give the window back to Blizzard.
		Field("detached", false, CleanBoolean, function(value) return Call("SetProfessionWindowDetached", value) end),
	} },
	{ key = "minimap", fields = {
		Field("hide", false, CleanBoolean, function(value) return Call("SetMinimapButtonShown", not value) end),
	} },
}
local SECTION_BY_KEY = {}
for _, section in ipairs(SECTIONS) do
	SECTION_BY_KEY[section.key] = section
	section.byKey = {}
	for _, field in ipairs(section.fields) do
		section.byKey[field.key] = field
	end
end

local function DefaultValue(field)
	if type(field.default) == "function" then
		return field.default()
	end
	return field.default
end

-- Every setting a profile holds, as "section.field", sorted.
function ns.GetSettingsProfileKeys()
	local keys = {}
	for _, section in ipairs(SECTIONS) do
		for _, field in ipairs(section.fields) do
			keys[#keys + 1] = section.key .. "." .. field.key
		end
	end
	table.sort(keys)
	return keys
end

-- The profile that `raw` says, cleaned like the saved variables are at load: a new table with every section and field, only what is
-- known, a missing or unusable value replaced by the default. With `report` (a table) it notes what was not usable: report.unknown (keys
-- the addon does not know), report.invalid (known keys whose value was not usable), each capped, and report.unknownTotal.
local function CleanProfile(raw, report)
	local clean = {}
	local source = type(raw) == "table" and raw or {}
	local function Note(list, text)
		report[list] = report[list] or {}
		if #report[list] < MAX_REPORTED then
			report[list][#report[list] + 1] = text
		end
		if list == "unknown" then
			report.unknownTotal = (report.unknownTotal or 0) + 1
		end
	end
	for _, section in ipairs(SECTIONS) do
		local rawSection = source[section.key]
		local isTable = type(rawSection) == "table"
		if report and rawSection ~= nil and not isTable then
			Note("invalid", section.key)
		end
		local values = {}
		for _, field in ipairs(section.fields) do
			local value
			if isTable then
				local given = rawSection[field.key]
				value = field.clean(given)
				if report and value == nil and given ~= nil then
					Note("invalid", section.key .. "." .. field.key)
				end
			end
			if value == nil then
				value = DefaultValue(field)
			end
			values[field.key] = value
		end
		clean[section.key] = values
		if report and isTable then
			for key in pairs(rawSection) do
				if not section.byKey[key] then
					Note("unknown", section.key .. "." .. DisplayKey(key))
				end
			end
		end
	end
	if report and type(raw) == "table" then
		for key in pairs(raw) do
			if not SECTION_BY_KEY[key] then
				Note("unknown", DisplayKey(key))
			end
		end
	end
	return clean
end

--------------------------------------------------------------------------------
-- Serialization
--------------------------------------------------------------------------------

local function SerializeString(text)
	return '"' .. (text:gsub('[%c"\\]', function(char)
		if char == '"' or char == "\\" then
			return "\\" .. char
		end
		return string.format("\\%03d", char:byte())
	end)) .. '"'
end

local function SerializeValue(value, out)
	local kind = type(value)
	if kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif kind == "number" then
		if not IsFiniteNumber(value) then
			error("not a finite number")
		end
		out[#out + 1] = string.format("%.14g", value)
	elseif kind == "string" then
		out[#out + 1] = SerializeString(value)
	elseif kind == "table" then
		local keys = {}
		for key in pairs(value) do
			if type(key) == "string" then
				keys[#keys + 1] = key
			end
		end
		table.sort(keys)
		out[#out + 1] = "{"
		for index, key in ipairs(keys) do
			if index > 1 then
				out[#out + 1] = ","
			end
			if key:match("^[%a_][%w_]*$") then
				out[#out + 1] = key
			else
				out[#out + 1] = "[" .. SerializeString(key) .. "]"
			end
			out[#out + 1] = "="
			SerializeValue(value[key], out)
		end
		out[#out + 1] = "}"
	else
		error("cannot serialize a " .. kind)
	end
end

-- The text of a value: strings, numbers, booleans and tables with text keys; keys sorted, so the same profile is always the same text.
local function Serialize(value)
	local out = {}
	SerializeValue(value, out)
	return table.concat(out)
end

-- Reads the text Serialize makes and nothing else. Returns the value, or nil and a message. Never runs any of the text; nested at most
-- MAX_DEPTH deep, at most MAX_NODES values, strings of at most MAX_STRING bytes, no repeated key, no control characters.
local function Deserialize(text)
	local pos, nodes, length = 1, 0, #text
	local function Fail(message)
		error({ message = message }, 0)
	end

	local function ParseString()
		pos = pos + 1 -- the opening quote
		local parts, total = {}, 0
		while true do
			local stop = text:find('[\\"%c]', pos)
			if not stop then
				Fail("a text is not closed")
			end
			if stop > pos then
				parts[#parts + 1] = text:sub(pos, stop - 1)
				total = total + (stop - pos)
				if total > MAX_STRING then
					Fail("a text is too long")
				end
			end
			local char = text:sub(stop, stop)
			if char == '"' then
				pos = stop + 1
				break
			elseif char == "\\" then
				local following = text:sub(stop + 1, stop + 1)
				if following == "\\" or following == '"' then
					parts[#parts + 1] = following
					pos = stop + 2
				else
					local digits = text:match("^%d%d%d", stop + 1)
					local code = digits and tonumber(digits)
					if not code or code > 255 then
						Fail("a text has a bad escape")
					end
					parts[#parts + 1] = string.char(code)
					pos = stop + 4
				end
				total = total + 1
			else
				Fail("a text has a control character")
			end
			if total > MAX_STRING then
				Fail("a text is too long")
			end
		end
		return table.concat(parts)
	end

	local ParseValue
	local function ParseTable(depth)
		pos = pos + 1 -- the brace
		local result = {}
		if text:sub(pos, pos) == "}" then
			pos = pos + 1
			return result
		end
		while true do
			local key
			local identifier = text:match("^[%a_][%w_]*", pos)
			if identifier then
				if #identifier > MAX_STRING then
					Fail("a name is too long")
				end
				key = identifier
				pos = pos + #identifier
			elseif text:sub(pos, pos + 1) == '["' then
				pos = pos + 1
				key = ParseString()
				if text:sub(pos, pos) ~= "]" then
					Fail("a name is not closed")
				end
				pos = pos + 1
			else
				Fail("a name was expected")
			end
			if text:sub(pos, pos) ~= "=" then
				Fail("an = was expected")
			end
			pos = pos + 1
			if result[key] ~= nil then
				Fail("a name is repeated")
			end
			result[key] = ParseValue(depth + 1)
			local char = text:sub(pos, pos)
			pos = pos + 1
			if char == "}" then
				return result
			elseif char ~= "," then
				Fail("a , or } was expected")
			end
		end
	end

	ParseValue = function(depth)
		if depth > MAX_DEPTH then
			Fail("it is nested too deep")
		end
		nodes = nodes + 1
		if nodes > MAX_NODES then
			Fail("it holds too many values")
		end
		local char = text:sub(pos, pos)
		if char == "{" then
			return ParseTable(depth)
		elseif char == '"' then
			return ParseString()
		elseif text:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif text:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		end
		local token = text:match("^%-?%d[%d%.eE%+%-]*", pos)
		local number = token and tonumber(token)
		if not IsFiniteNumber(number) then
			Fail("a value was expected")
		end
		pos = pos + #token
		return number
	end

	local ok, result = pcall(function()
		local value = ParseValue(1)
		if pos ~= length + 1 then
			Fail("there is more after the end")
		end
		return value
	end)
	if ok then
		return result
	end
	return nil, type(result) == "table" and result.message or "it cannot be read"
end

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_VALUE = {}
for index = 1, #BASE64 do
	BASE64_VALUE[BASE64:byte(index)] = index - 1
end

local function Base64Encode(data)
	local out = {}
	for index = 1, #data, 3 do
		local a, b, c = data:byte(index, index + 2)
		local number = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = math.floor(number / 262144) + 1
		local c2 = math.floor(number / 4096) % 64 + 1
		local c3 = math.floor(number / 64) % 64 + 1
		local c4 = number % 64 + 1
		if c then
			out[#out + 1] = BASE64:sub(c1, c1) .. BASE64:sub(c2, c2) .. BASE64:sub(c3, c3) .. BASE64:sub(c4, c4)
		elseif b then
			out[#out + 1] = BASE64:sub(c1, c1) .. BASE64:sub(c2, c2) .. BASE64:sub(c3, c3)
		else
			out[#out + 1] = BASE64:sub(c1, c1) .. BASE64:sub(c2, c2)
		end
	end
	return table.concat(out)
end

-- The bytes of a base64 text without padding (only the 64 characters), or nil when its length cannot be one.
local function Base64Decode(text)
	local remainder = #text % 4
	if remainder == 1 then
		return nil
	end
	local out = {}
	for index = 1, #text, 4 do
		local v1, v2, v3, v4 = BASE64_VALUE[text:byte(index)], BASE64_VALUE[text:byte(index + 1)] , BASE64_VALUE[text:byte(index + 2)], BASE64_VALUE[text:byte(index + 3)]
		if not v1 or not v2 then
			return nil
		end
		if v4 then
			local number = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
			out[#out + 1] = string.char(math.floor(number / 65536), math.floor(number / 256) % 256, number % 256)
		elseif v3 then
			local number = v1 * 4096 + v2 * 64 + v3
			out[#out + 1] = string.char(math.floor(number / 1024), math.floor(number / 4) % 256)
		else
			out[#out + 1] = string.char(v1 * 4 + math.floor(v2 / 16))
		end
	end
	return table.concat(out)
end

-- Adler-32 of a text as eight hex digits: it tells a damaged or cut string from a good one.
local function Checksum(text)
	local a, b = 1, 0
	for index = 1, #text do
		a = (a + text:byte(index)) % 65521
		b = (b + a) % 65521
	end
	return string.format("%04x%04x", b, a)
end

local function Encode(payload)
	local text = Serialize(payload)
	return FORMAT_PREFIX .. Checksum(text) .. ":" .. Base64Encode(text)
end

-- The payload ({ n = name, p = profile }) of an export string, or nil and a message. Whitespace (line breaks from pasting) is ignored.
local function Decode(input)
	if type(input) ~= "string" then
		return nil, "Paste a profile string first."
	end
	local text = input:gsub("%s+", "")
	if text == "" then
		return nil, "Paste a profile string first."
	end
	local version = text:match("^JU(%d+):")
	if not version then
		return nil, "That is not a profile string. It starts with " .. FORMAT_PREFIX
	end
	if tonumber(version) ~= FORMAT_VERSION then
		return nil, "That profile string is from another version of the addon (it starts with JU" .. DisplayKey(version) .. ":); this one reads " .. FORMAT_PREFIX
	end
	if #text > MAX_ENCODED then
		return nil, "That profile string is far too long to be one."
	end
	local checksum, body = text:match("^JU%d+:(%x%x%x%x%x%x%x%x):([A-Za-z0-9%+/]+)$")
	if not checksum then
		return nil, "That profile string is damaged or cut short."
	end
	local data = Base64Decode(body)
	if not data or Checksum(data) ~= checksum:lower() then
		return nil, "That profile string is damaged or cut short."
	end
	local payload, err = Deserialize(data)
	if type(payload) ~= "table" then
		return nil, "That profile string cannot be read" .. (err and (": " .. err) or "") .. "."
	end
	if type(payload.p) ~= "table" then
		return nil, "That profile string holds no profile."
	end
	return payload
end

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

-- Set in ns.InitSettingsProfiles.
local db, profiles, active
local resolved = false -- the character's profile has been looked up (its key was known) and applied if it differed
local applying = false -- a profile is being applied: the setters it calls must not write into the profile
local pendingName -- the profile switched to while the key was not known; it becomes the character's once it is

-- The key of the character, or nil while the realm is not known.
local function CurrentKey()
	local key = ns.GetCharacterKey and ns.GetCharacterKey()
	if type(key) == "string" and key ~= "" then
		return key
	end
end

-- The profile of the live settings (a new table).
local function Snapshot()
	return CleanProfile(db)
end

local function FallbackName()
	if profiles[DEFAULT_NAME] then
		return DEFAULT_NAME
	end
	return SortedKeys(profiles)[1]
end

-- The name of the profile this character uses: the one switched to while the key was unknown, else its entry, else the fallback
-- (Default, else the first by name). Never writes.
local function ActiveName()
	local name
	if pendingName and not resolved then
		name = pendingName
	else
		local key = CurrentKey()
		name = key and active[key] or pendingName
	end
	if type(name) == "string" and profiles[name] then
		return name
	end
	return FallbackName()
end

local function FindName(name)
	if type(name) ~= "string" or not profiles then
		return nil
	end
	if profiles[name] then
		return name
	end
	local lowered = name:lower()
	for existing in pairs(profiles) do
		if existing:lower() == lowered then
			return existing
		end
	end
end

-- The profile name as it is kept (trimmed), or nil and a message.
local function ValidateName(name)
	if type(name) ~= "string" then
		return nil, "Invalid profile name."
	end
	name = Trim(name)
	-- UTF-8 characters, not bytes, like the scale names and the edit box's letter limit.
	local length = select(2, name:gsub("[^\128-\191]", ""))
	if length == 0 or length > MAX_NAME then
		return nil, "Profile names must be 1-" .. MAX_NAME .. " characters long."
	end
	return name
end

-- Makes the live settings those of `profile` (through the setters of each feature). Returns whether the profession window needs a
-- /reload to be given back to Blizzard, and the list of settings that could not be applied.
local function Apply(profile)
	local needsReload, failed = false, {}
	applying = true
	for _, section in ipairs(SECTIONS) do
		local live = db[section.key]
		local values = profile[section.key]
		if type(live) == "table" and type(values) == "table" then
			for _, field in ipairs(section.fields) do
				local value = values[field.key]
				local current = live[field.key]
				local same
				if type(value) == "table" then
					same = type(current) == "table" and SameSet(current, value)
				else
					same = current == value
				end
				if not same then
					local ok, result, reload = pcall(field.apply, value)
					if not ok then
						failed[#failed + 1] = section.key .. "." .. field.key
					elseif section.key == "professionWindow" and reload == true then
						needsReload = true
					end
				end
			end
		end
	end
	applying = false
	return needsReload, failed
end

local function SameProfile(a, b)
	return Serialize(a) == Serialize(b)
end

-- Writes the live settings into the profile of the character (see the top of the file for when this is skipped).
local function SyncNow()
	if not db or applying then
		return
	end
	local key = CurrentKey()
	local name
	if key and resolved then
		name = ActiveName()
		active[key] = name
	elseif pendingName and profiles[pendingName] then
		name = pendingName
	else
		return -- nothing says whose profile the live settings are (never written under a nil key)
	end
	profiles[name] = Snapshot()
end

function ns.SyncSettingsProfile()
	SyncNow()
end

-- Looks up the profile of the character once its key is known and applies it when the live settings differ. Does nothing before.
local function Resolve()
	if resolved or not db then
		return
	end
	local key = CurrentKey()
	if not key then
		return
	end
	resolved = true
	local name = pendingName and profiles[pendingName] and pendingName or active[key]
	pendingName = nil
	if type(name) ~= "string" or not profiles[name] then
		name = FallbackName()
	end
	active[key] = name
	if not SameProfile(Snapshot(), profiles[name]) then
		local needsReload, failed = Apply(profiles[name])
		if needsReload then
			ns.Print(ns.PROFESSION_WINDOW_RELOAD or "Takes effect after /reload.")
		end
		if #failed > 0 then
			ns.Print("Some settings of the profile \"" .. name .. "\" could not be applied: " .. table.concat(failed, ", ") .. ".")
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function ns.GetSettingsProfileNames()
	return profiles and SortedKeys(profiles) or {}
end

function ns.GetActiveSettingsProfileName()
	if not db then
		return nil
	end
	return ActiveName()
end

-- Case-insensitive lookup of a profile name; returns the stored spelling.
function ns.FindSettingsProfileName(name)
	return FindName(name)
end

-- The profile as a table (a copy), or nil.
function ns.GetSettingsProfile(name)
	local existing = FindName(name)
	return existing and CleanProfile(profiles[existing]) or nil
end

-- Makes a profile the one this character uses and applies it. Returns true, nil and whether a /reload is needed for the profession
-- window; or false and a message.
function ns.SetActiveSettingsProfile(name)
	local existing = db and type(name) == "string" and profiles[name] and name
	if not existing then
		return false, "Profile not found."
	end
	Resolve()
	SyncNow() -- the profile that is left keeps the last state
	local key = CurrentKey()
	if key then
		active[key] = existing
	else
		pendingName = existing -- the key is not known yet: the choice is kept until it is
	end
	local needsReload, failed = Apply(profiles[existing])
	return true, #failed > 0 and ("Could not apply: " .. table.concat(failed, ", ") .. ".") or nil, needsReload
end

-- Saves a new profile under `name`: a copy of the profile `sourceName`, or (without one) of the current settings. Does not switch to it.
function ns.CreateSettingsProfile(name, sourceName)
	if not db then
		return false, "Profiles are not available."
	end
	local err
	name, err = ValidateName(name)
	if not name then
		return false, err
	end
	local existing = FindName(name)
	if existing then
		return false, "A profile named \"" .. existing .. "\" already exists."
	end
	local profile
	if sourceName == nil then
		profile = Snapshot()
	else
		local source = profiles[sourceName]
		if not source then
			return false, "Profile to copy not found."
		end
		Resolve()
		SyncNow() -- (the active profile is up to date)
		profile = CleanProfile(profiles[sourceName])
	end
	profiles[name] = profile
	return true, name
end

-- Gives a profile another name; the characters that use it follow. `old` has to be the stored spelling.
function ns.RenameSettingsProfile(old, new)
	if not db or type(old) ~= "string" or not profiles[old] then
		return false, "Profile not found."
	end
	local name, err = ValidateName(new)
	if not name then
		return false, err
	end
	if name == old then
		return false, "The profile is already named \"" .. old .. "\"."
	end
	local lowered = name:lower()
	for existing in pairs(profiles) do
		if existing ~= old and existing:lower() == lowered then
			return false, "A profile named \"" .. existing .. "\" already exists."
		end
	end
	profiles[name] = profiles[old]
	profiles[old] = nil
	for key, used in pairs(active) do
		if used == old then
			active[key] = name
		end
	end
	if pendingName == old then
		pendingName = name
	end
	return true, name
end

-- Deletes a profile (never the last). The characters that used it use Default (else the first profile) from now on; this one gets it
-- applied at once. Returns true, nil and whether a /reload is needed; or false and a message.
function ns.DeleteSettingsProfile(name)
	if not db or type(name) ~= "string" or not profiles[name] then
		return false, "Profile not found."
	end
	if next(profiles, next(profiles)) == nil then
		return false, "You cannot delete the last remaining profile."
	end
	Resolve()
	local current = ActiveName()
	if current ~= name then
		SyncNow()
	end
	profiles[name] = nil
	for key, used in pairs(active) do
		if used == name then
			active[key] = nil
		end
	end
	if pendingName == name then
		pendingName = nil
	end
	local needsReload
	if current == name then
		local fallback = FallbackName()
		local key = CurrentKey()
		if key then
			active[key] = fallback
		else
			pendingName = fallback
		end
		needsReload = Apply(profiles[fallback])
	end
	return true, nil, needsReload
end

-- The export string of a profile (the active one without a name), or nil and a message.
function ns.ExportSettingsProfile(name)
	if not db then
		return nil, "Profiles are not available."
	end
	local existing
	if name == nil then
		existing = ActiveName()
	else
		existing = FindName(name)
	end
	if not existing then
		return nil, "Profile not found."
	end
	if existing == ActiveName() then
		Resolve()
		SyncNow()
	end
	local ok, text = pcall(Encode, { n = existing, p = CleanProfile(profiles[existing]) })
	if not ok then
		return nil, "The profile could not be exported."
	end
	return text, existing
end

-- Creates a profile from an export string; with `replace` it overwrites the profile of the same name instead (applying it at once when it
-- is the one in use). The name is the one in the string (cut to the length limit), or `nameOverride` when given (typed names have to be
-- valid). Does not switch to it. Returns true, the name and an info table; or false, a message and (when the name is taken) info.exists.
-- info.unknown / info.unknownTotal: keys the string has that this version does not know (ignored), info.invalid: known keys whose
-- value was not usable (the default is used), info.shortened: the name was cut.
function ns.ImportSettingsProfile(text, nameOverride, replace)
	if not db then
		return false, "Profiles are not available."
	end
	local payload, err = Decode(text)
	if not payload then
		return false, err
	end
	local info = {}
	local report = {}
	local profile = CleanProfile(payload.p, report)
	info.unknown, info.unknownTotal, info.invalid = report.unknown, report.unknownTotal, report.invalid

	local name
	if type(nameOverride) == "string" and Trim(nameOverride) ~= "" then
		local valid, nameErr = ValidateName(nameOverride)
		if not valid then
			return false, nameErr, info
		end
		name = valid
	else
		local given = type(payload.n) == "string" and payload.n or ""
		given = Trim(CleanText(given))
		local cut = Trim(CutCharacters(given, MAX_NAME))
		if cut ~= given then
			info.shortened = true
		end
		name = cut ~= "" and cut or "Imported"
	end
	info.name = name

	local existing = FindName(name)
	if existing then
		if replace ~= true then
			info.exists = existing
			return false, "A profile named \"" .. existing .. "\" already exists.", info
		end
		Resolve()
		local wasActive = existing == ActiveName()
		if not wasActive then
			SyncNow()
		end
		profiles[existing] = profile
		info.replaced = true
		info.name = existing
		if wasActive then
			local needsReload = Apply(profile)
			info.needsReload = needsReload
		end
		return true, existing, info
	end
	profiles[name] = profile
	return true, name, info
end

-- "Imported profile "X" (it is in the list; pick it to use it); ignored: a.b, c."
function ns.FormatSettingsProfileImport(name, info)
	info = info or {}
	local text = string.format("Imported profile \"%s\"", tostring(name))
	if info.replaced then
		text = text .. " (the profile of that name was replaced)"
	end
	if info.shortened then
		text = text .. " (the name was cut to " .. MAX_NAME .. " characters)"
	end
	text = text .. ". It is in the list of profiles; pick it to use it."
	if info.unknown and #info.unknown > 0 then
		local more = (info.unknownTotal or #info.unknown) - #info.unknown
		text = text .. " Ignored (this version does not know them): " .. table.concat(info.unknown, ", ")
			.. (more > 0 and (" and " .. more .. " more") or "") .. "."
	end
	if info.invalid and #info.invalid > 0 then
		text = text .. " Not usable, so the default was used: " .. table.concat(info.invalid, ", ") .. "."
	end
	return text
end

--------------------------------------------------------------------------------
-- Slash command: /ju profile ...
--------------------------------------------------------------------------------

local function PrintProfiles()
	local current = ActiveName()
	ns.Print("Active profile: " .. current .. " (the settings profiles cover the whole addon; the stat weight scales are /ju scale)")
	for _, name in ipairs(SortedKeys(profiles)) do
		print("  " .. (name == current and "> " or "  ") .. name)
	end
end

-- Switches to a profile and says so.
local function SwitchTo(name)
	local ok, err, needsReload = ns.SetActiveSettingsProfile(name)
	if not ok then
		ns.Print(err)
		return false
	end
	ns.Print("Switched to profile \"" .. name .. "\".")
	if err then
		ns.Print(err)
	end
	if needsReload then
		ns.Print(ns.PROFESSION_WINDOW_RELOAD or "Takes effect after /reload.")
	end
	return true
end

function ns.HandleSettingsProfileCommand(rest)
	rest = Trim(rest or "")
	if not db then
		ns.Print("The settings profiles are not available.")
		return
	end
	if rest == "" then
		PrintProfiles()
		return
	end

	-- An existing profile name wins over sub-commands, so "New Tank" or "Delete Old" switch to those profiles.
	local existing = FindName(rest)
	if existing then
		SwitchTo(existing)
		ns.NotifyConfigChanged()
		return
	end

	local sub, arg = rest:match("^(%S+)%s*(.-)$")
	sub = sub:lower()

	if sub == "switch" then
		local name = FindName(arg)
		if not name then
			ns.Print(arg == "" and "Usage: /ju profile switch <name>" or "Profile not found. Use /ju profile to list profiles.")
			return
		end
		SwitchTo(name)
	elseif sub == "new" or sub == "copy" then
		if arg == "" then
			ns.Print("Usage: /ju profile " .. sub .. " <name>")
			return
		end
		local ok, result = ns.CreateSettingsProfile(arg, sub == "copy" and ActiveName() or nil)
		if not ok then
			ns.Print(result)
			return
		end
		SwitchTo(result)
	elseif sub == "rename" then
		if arg == "" then
			ns.Print("Usage: /ju profile rename <new name>")
			return
		end
		local old = ActiveName()
		local ok, result = ns.RenameSettingsProfile(old, arg)
		if not ok then
			ns.Print(result)
			return
		end
		ns.Print("Renamed profile \"" .. old .. "\" to \"" .. result .. "\".")
	elseif sub == "delete" then
		local name = FindName(arg)
		if not name then
			ns.Print(arg == "" and "Usage: /ju profile delete <name>" or "Profile not found. Use /ju profile to list profiles.")
			return
		end
		local ok, err, needsReload = ns.DeleteSettingsProfile(name)
		if not ok then
			ns.Print(err)
			return
		end
		ns.Print("Deleted profile \"" .. name .. "\". Active profile: \"" .. ActiveName() .. "\".")
		if needsReload then
			ns.Print(ns.PROFESSION_WINDOW_RELOAD or "Takes effect after /reload.")
		end
	elseif sub == "export" then
		local name
		if arg ~= "" then
			name = FindName(arg)
			if not name then
				ns.Print("Profile not found. Use /ju profile to list profiles.")
				return
			end
		end
		local exported, shown = ns.ExportSettingsProfile(name)
		if not exported then
			ns.Print(shown)
			return
		end
		ns.Print("Profile string of \"" .. shown .. "\" (the Export button of the options window's Profiles tab gives one you can copy):")
		print("  " .. exported)
		return
	elseif sub == "import" then
		-- "import replace <string>" overwrites a profile of the same name (the options window asks for a second click instead).
		local replace, text = false, arg
		local flag, remainder = arg:match("^(%a+)%s+(.*)$")
		if flag and flag:lower() == "replace" then
			replace, text = true, remainder
		end
		if Trim(text) == "" then
			ns.Print("Usage: /ju profile import <profile string> (it starts with " .. FORMAT_PREFIX .. "; chat takes at most 255 characters: for a long one use the Import button of the options window's Profiles tab)")
			return
		end
		local ok, result, info = ns.ImportSettingsProfile(text, nil, replace)
		if not ok then
			ns.Print(result)
			if info and info.exists then
				ns.Print("Use /ju profile import replace <string> to replace it.")
			end
			return
		end
		ns.Print(ns.FormatSettingsProfileImport(result, info))
		if info.needsReload then
			ns.Print(ns.PROFESSION_WINDOW_RELOAD or "Takes effect after /reload.")
		end
	else
		ns.Print("Profile not found. Use /ju profile to list profiles (the stat weight scales are /ju scale).")
		return
	end
	ns.NotifyConfigChanged()
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local driver

-- Called once the features have loaded their settings (Core.lua); may be called again over other saved variables.
function ns.InitSettingsProfiles(database)
	db = database
	resolved, applying, pendingName = false, false, nil

	if type(db.settingsProfiles) ~= "table" then
		db.settingsProfiles = {}
	end
	for name, profile in pairs(db.settingsProfiles) do
		if type(name) ~= "string" or ValidateName(name) ~= name or type(profile) ~= "table" then
			db.settingsProfiles[name] = nil
		else
			db.settingsProfiles[name] = CleanProfile(profile)
		end
	end
	profiles = db.settingsProfiles
	if next(profiles) == nil then
		profiles[DEFAULT_NAME] = Snapshot() -- first run: what is set now
	end

	local clean = {}
	if type(db.activeSettingsProfile) == "table" then
		for key, name in pairs(db.activeSettingsProfile) do
			if type(key) == "string" and key ~= "" and type(name) == "string" and profiles[name] then
				clean[key] = name
			end
		end
	end
	db.activeSettingsProfile = clean
	active = clean

	Resolve() -- with the realm known; else at PLAYER_LOGIN

	if not driver and CreateFrame then
		driver = CreateFrame("Frame")
		driver:RegisterEvent("PLAYER_LOGIN")
		driver:RegisterEvent("PLAYER_LOGOUT")
		driver:SetScript("OnEvent", function(_, event)
			if event == "PLAYER_LOGIN" then
				Resolve()
			else
				SyncNow() -- the last snapshot, for a setting that has no hook
			end
		end)
	end
end

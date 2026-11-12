local addonName, ns = ...

--[[
	Recent mail recipients: a small panel docked to the right side of the mailbox window that lists the last 10
	characters you sent mail to (per realm). Clicking a name fills the "To:" box of the Send Mail tab.

	Saved data (validated in InitData):
		JimmysStatWeightsDB.mail = { enabled = true } -- master switch of the mail features: this panel and MailMaterials.lua
		JimmysStatWeightsDB.mailRecipients = { [realmKey] = { "Newest", "Older", ... } } -- account-wide, max 10 per realm

	Capture: hooksecurefunc on SendMail queues the recipient (a short first-in first-out queue, since a second letter can
	be sent before the first is confirmed); MAIL_SEND_SUCCESS moves the oldest queued recipient into the history,
	MAIL_FAILED without an item ID drops it (with an item ID it is an inbox failure and the queue is left alone), and
	MAIL_SHOW and MAIL_CLOSED forget the queue. The attachments of each letter (GetSendMailItem) are queued with its recipient and,
	when the letter is confirmed and goes to one of your other characters on the realm, handed to ns.RecordSentMail
	(Inventory.lua) so that character's mailbox snapshot counts them. Only hooksecurefunc and HookScript are used on Blizzard's code, so nothing
	of it is replaced or tainted. Secret values are never branched on: a secret recipient is ignored. While the feature is
	off nothing is recorded (the queue still follows the mails, so it stays in step) and the panel stays hidden.

	The panel (parented to MailFrame, anchored to its right side, or to the right side of OpenMailFrame while a letter
	is open, which sits there) is shown only while the Send Mail tab (SendMailFrame) is shown and the feature is enabled. MailFrame lives in Blizzard_MailFrame, which is always loaded; ADDON_LOADED is
	watched anyway in case it is not there yet when the addon starts.
]]

local FRAME_NAME = "JimmysUtilsMailRecentFrame"
local MAX_RECIPIENTS = 10
local MAX_NAME_BYTES = 80 -- "Name-Realm" is far shorter; anything longer is not a character name
local PANEL_WIDTH = 150
local PANEL_OFFSET_X = 2
local MAX_QUEUED = 3 -- letters sent but not yet confirmed that are remembered
local DEFAULT_SEND_ATTACHMENTS = 12 -- ATTACHMENTS_MAX_SEND
local MAX_SEND_ATTACHMENTS = 64
local PADDING = 8
local TITLE_HEIGHT = 24 -- the rows start this far below the top of the panel
local ROW_HEIGHT = 18

local DEFAULTS = {
	enabled = true,
}

local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 14,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Set in ns.InitMail.
local settings, history
local panel -- nil until MailFrame exists
local rows = {}
local queue = {} -- the SendMail calls that are not confirmed yet, oldest first: { recipient = name (false: not a usable name), items = { [itemID] = quantity } or nil, cod = bool }
local initialized = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

-- The trimmed recipient as typed, or nil when it is not a usable name (not text, secret, empty, absurdly long or
-- holding control characters or "|", which would be read as an escape sequence when shown).
local function NormalizeName(text)
	if IsSecret(text) or type(text) ~= "string" then
		return nil
	end
	local name = Trim(text)
	if name == "" or #name > MAX_NAME_BYTES or name:find("[%c|]") then
		return nil
	end
	return name
end

-- The items attached to the letter being sent: { [itemID] = quantity }, or nil when there are none. GetSendMailItem returns
-- name, itemID, texture, count, quality; every result is read through pcall and a secret or odd one is skipped.
local function ReadSendItems()
	if type(GetSendMailItem) ~= "function" then
		return nil
	end
	local max = ATTACHMENTS_MAX_SEND
	if IsSecret(max) or type(max) ~= "number" or max < 1 or max > MAX_SEND_ATTACHMENTS then
		max = DEFAULT_SEND_ATTACHMENTS
	end
	local items = {}
	for index = 1, max do
		local ok, _, itemID, _, count = pcall(GetSendMailItem, index)
		if ok and not IsSecret(itemID) and not IsSecret(count) and type(itemID) == "number" and type(count) == "number"
			and itemID > 0 and count > 0 and itemID == math.floor(itemID) and count == math.floor(count) then
			items[itemID] = (items[itemID] or 0) + count
		end
	end
	if next(items) == nil then
		return nil
	end
	return items
end

-- Does the letter being written ask for cash on delivery? (GetSendMailCOD returns the amount in copper; a secret or odd answer
-- counts as no.)
local function ReadSendCOD()
	if type(GetSendMailCOD) ~= "function" then
		return false
	end
	local ok, amount = pcall(GetSendMailCOD)
	return ok and not IsSecret(amount) and type(amount) == "number" and amount > 0
end

-- A realm name without spaces, or nil when the client gave nothing usable.
local function CleanRealm(value)
	if IsSecret(value) or type(value) ~= "string" then
		return nil
	end
	value = (value:gsub("%s", ""))
	if value == "" then
		return nil
	end
	return value
end

local function GetRealmKey()
	local normalized = GetNormalizedRealmName and CleanRealm(GetNormalizedRealmName())
	return normalized or (GetRealmName and CleanRealm(GetRealmName())) or "Unknown"
end

-- Is this name the current character ("Name" or "Name-Realm", any case)?
local function IsSelf(name)
	local player = UnitName and UnitName("player")
	if IsSecret(player) or type(player) ~= "string" or player == "" then
		return false
	end
	local lowered = name:lower()
	player = player:lower()
	if lowered == player then
		return true
	end
	local realms = {}
	if GetNormalizedRealmName then
		realms[#realms + 1] = CleanRealm(GetNormalizedRealmName())
	end
	if GetRealmName then
		realms[#realms + 1] = CleanRealm(GetRealmName())
	end
	for _, realm in ipairs(realms) do
		if lowered == player .. "-" .. realm:lower() then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- History
--------------------------------------------------------------------------------

local RefreshPanel -- defined below, the history changes call back into it

local function Changed()
	RefreshPanel()
	if ns.RefreshMailPage then
		ns.RefreshMailPage()
	end
end

-- The names of this realm that are listed, most recent first. A new table every time.
function ns.GetMailRecipients()
	local names = {}
	local list = history and history[GetRealmKey()]
	if type(list) == "table" then
		for _, name in ipairs(list) do
			if not IsSelf(name) then
				names[#names + 1] = name
			end
		end
	end
	return names
end

-- How many names are saved for this realm (the current character's own entry, if an alt left one, included).
function ns.GetMailRecipientCount()
	local list = history and history[GetRealmKey()]
	return type(list) == "table" and #list or 0
end

-- Puts a name at the top of this realm's list (a different spelling of a name already there replaces it).
-- Returns true when it was stored.
function ns.AddMailRecipient(text)
	local name = NormalizeName(text)
	if not history or not name or IsSelf(name) then
		return false
	end

	local key = GetRealmKey()
	local list = history[key]
	if type(list) ~= "table" then
		list = {}
		history[key] = list
	end
	local lowered = name:lower()
	for index = #list, 1, -1 do
		if list[index]:lower() == lowered then
			table.remove(list, index)
		end
	end
	table.insert(list, 1, name)
	while #list > MAX_RECIPIENTS do
		table.remove(list)
	end
	Changed()
	return true
end

-- Takes a name off this realm's list. Returns true when it was there.
function ns.RemoveMailRecipient(text)
	local list = history and history[GetRealmKey()]
	if type(list) ~= "table" or type(text) ~= "string" then
		return false
	end
	local lowered = text:lower()
	local removed = false
	for index = #list, 1, -1 do
		if list[index]:lower() == lowered then
			table.remove(list, index)
			removed = true
		end
	end
	if #list == 0 then
		history[GetRealmKey()] = nil
	end
	if removed then
		Changed()
	end
	return removed
end

-- Empties this realm's list. Returns how many names were removed.
function ns.ClearMailRecipients()
	if not history then
		return 0
	end
	local key = GetRealmKey()
	local list = history[key]
	local count = type(list) == "table" and #list or 0
	history[key] = nil
	Changed()
	return count
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

function ns.IsMailEnabled()
	return settings ~= nil and settings.enabled == true
end

local UpdateVisibility -- defined below

function ns.SetMailEnabled(enabled)
	if not settings or type(enabled) ~= "boolean" then
		return false
	end
	settings.enabled = enabled
	UpdateVisibility()
	-- The mail materials follow the same switch (they close, or catch up with an open mailbox).
	if ns.OnMailEnabledChanged then
		ns.OnMailEnabledChanged(enabled)
	end
	return true
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

-- Copies a name into the To: box of the Send Mail tab. Nothing else is touched (no cursor or focus changes: those
-- could taint Blizzard's shared autocomplete state).
local function UseRecipient(name)
	local box = SendMailNameEditBox
	if box then
		box:SetText(name)
	end
end

local function CreateRow(index)
	local offset = TITLE_HEIGHT + (index - 1) * ROW_HEIGHT
	local row = CreateFrame("Button", nil, panel)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -offset)
	row:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PADDING, -offset)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
	row.highlight:SetAllPoints(row)
	row.highlight:SetColorTexture(1, 1, 1, 0.15)

	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)

	row:SetScript("OnClick", function(self, button)
		local name = self.name
		if not name then
			return
		end
		if button == "RightButton" then
			if GameTooltip then
				GameTooltip:Hide()
			end
			ns.RemoveMailRecipient(name)
		else
			UseRecipient(name)
		end
	end)
	row:SetScript("OnEnter", function(self)
		if self.name and GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Click to send to " .. self.name .. ". Right-click to remove.", 1, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
	return row
end

-- Shows the names of this realm and sizes the panel to them.
function RefreshPanel()
	if not panel then
		return
	end
	local names = ns.GetMailRecipients()
	for index = 1, MAX_RECIPIENTS do
		local row = rows[index]
		if names[index] then
			if not row then
				row = CreateRow(index)
				rows[index] = row
			end
			row.name = names[index]
			row.text:SetText(names[index])
			row:Show()
		elseif row then
			row.name = nil
			row:Hide()
		end
	end
	panel.empty:SetShown(#names == 0)
	panel:SetHeight(TITLE_HEIGHT + math.max(#names, 1) * ROW_HEIGHT + PADDING)
end

-- Docks the panel to the right of the mailbox, or of the open letter while there is one (OpenMailFrame sits at the
-- mailbox's right edge and would be covered).
local function UpdateAnchor()
	if not panel then
		return
	end
	local target = MailFrame
	if OpenMailFrame and OpenMailFrame:IsShown() then
		target = OpenMailFrame
	end
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", target, "TOPRIGHT", PANEL_OFFSET_X, 0)
end

-- The panel is up while the feature is on and the Send Mail tab is showing (it hides with the mailbox as its child).
function UpdateVisibility()
	if not panel then
		return
	end
	UpdateAnchor()
	if settings and settings.enabled and SendMailFrame and SendMailFrame:IsShown() then
		RefreshPanel()
		panel:Show()
	else
		panel:Hide()
	end
end

local function CreatePanel()
	panel = CreateFrame("Frame", FRAME_NAME, MailFrame, "BackdropTemplate")
	panel:Hide()
	panel:SetWidth(PANEL_WIDTH)
	panel:SetHeight(TITLE_HEIGHT + ROW_HEIGHT + PADDING)
	panel:EnableMouse(true) -- clicks on the panel's gaps do not fall through to the world
	if panel.SetBackdrop then
		panel:SetBackdrop(BACKDROP)
		panel:SetBackdropColor(0.05, 0.05, 0.05, 1)
		panel:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	end

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING + 2, -8)
	title:SetText("Recent recipients")

	panel.empty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING + 2, -(TITLE_HEIGHT + 2))
	panel.empty:SetText("No recipients yet.")
end

-- Builds the panel and follows the Send Mail tab. Returns true once that is done (also when it already was).
local function Attach()
	if panel then
		return true
	end
	if not (MailFrame and SendMailFrame) then
		return false
	end
	CreatePanel()
	SendMailFrame:HookScript("OnShow", UpdateVisibility)
	SendMailFrame:HookScript("OnHide", UpdateVisibility)
	if OpenMailFrame and OpenMailFrame.HookScript then
		OpenMailFrame:HookScript("OnShow", UpdateAnchor)
		OpenMailFrame:HookScript("OnHide", UpdateAnchor)
	end
	UpdateVisibility()
	return true
end

--------------------------------------------------------------------------------
-- Commands: /ju mail ...
--------------------------------------------------------------------------------

local function PrintUsage()
	ns.Print("Usage: /ju mail on | off | clear")
end

function ns.HandleMailCommand(rest)
	if not settings then
		ns.Print("The recent mail recipients are not ready yet.")
		return
	end
	rest = Trim(rest or "")
	local lowered = rest:lower()

	if rest == "" then
		ns.Print(string.format("Mail features (recent recipients and mail materials) are %s (%d saved for this realm).",
			settings.enabled and "on" or "off", ns.GetMailRecipientCount()))
		PrintUsage()
		return
	elseif lowered == "on" or lowered == "off" then
		ns.SetMailEnabled(lowered == "on")
		ns.Print("Mail features (recent recipients and mail materials) " .. (lowered == "on" and "enabled." or "disabled."))
	elseif lowered == "clear" then
		local count = ns.ClearMailRecipients()
		ns.Print(string.format("Cleared %d recent mail recipient%s of this realm.", count, count == 1 and "" or "s"))
	else
		PrintUsage()
		return
	end
	ns.NotifyConfigChanged()
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- A list as it should be saved: only usable names, no duplicates, newest first, at most MAX_RECIPIENTS.
local function CleanList(list)
	local indexes = {}
	for index in pairs(list) do
		if type(index) == "number" and index >= 1 and index == math.floor(index) then
			indexes[#indexes + 1] = index
		end
	end
	table.sort(indexes)

	local clean, seen = {}, {}
	for _, index in ipairs(indexes) do
		local name = NormalizeName(list[index])
		if name and #clean < MAX_RECIPIENTS and not seen[name:lower()] then
			seen[name:lower()] = true
			clean[#clean + 1] = name
		end
	end
	return clean
end

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db)
	if type(db.mail) ~= "table" then
		db.mail = {}
	end
	settings = db.mail
	for name, default in pairs(DEFAULTS) do
		if type(settings[name]) ~= type(default) then
			settings[name] = default
		end
	end

	if type(db.mailRecipients) ~= "table" then
		db.mailRecipients = {}
	end
	history = db.mailRecipients
	for realm, list in pairs(history) do
		if type(realm) ~= "string" or realm == "" or type(list) ~= "table" then
			history[realm] = nil
		else
			local clean = CleanList(list)
			history[realm] = #clean > 0 and clean or nil
		end
	end
end

function ns.InitMail(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)

	if hooksecurefunc and type(SendMail) == "function" then
		hooksecurefunc("SendMail", function(recipient)
			-- An unusable recipient still takes its place in the queue, so the confirmations stay in step. The attachments
			-- are read now: Blizzard's mail frame empties them only when MAIL_SEND_SUCCESS arrives.
			if #queue >= MAX_QUEUED then
				table.remove(queue, 1)
			end
			local name = NormalizeName(recipient) or false
			local items = name and settings and settings.enabled and ReadSendItems() or nil
			queue[#queue + 1] = { recipient = name, items = items, cod = items ~= nil and ReadSendCOD() }
		end)
	end

	local driver = CreateFrame("Frame")
	driver:RegisterEvent("MAIL_SHOW")
	driver:RegisterEvent("MAIL_CLOSED")
	driver:RegisterEvent("MAIL_SEND_SUCCESS")
	driver:RegisterEvent("MAIL_FAILED")
	driver:SetScript("OnEvent", function(self, event, arg1)
		if event == "ADDON_LOADED" then
			if arg1 == "Blizzard_MailFrame" and Attach() then
				self:UnregisterEvent("ADDON_LOADED")
			end
		elseif event == "MAIL_SEND_SUCCESS" then
			local sent = table.remove(queue, 1)
			if sent and sent.recipient and settings.enabled then
				ns.AddMailRecipient(sent.recipient)
				-- Items sent to one of your other characters will be in its mailbox (Inventory.lua).
				if sent.items and ns.RecordSentMail then
					ns.RecordSentMail(sent.recipient, sent.items, sent.cod)
				end
			end
		elseif event == "MAIL_FAILED" then
			-- Failures to take an item out of the inbox carry the item's ID; only a failed letter has none.
			if arg1 == nil then
				table.remove(queue, 1)
			end
		elseif event == "MAIL_CLOSED" then
			queue = {}
		elseif event == "MAIL_SHOW" then
			queue = {}
			if Attach() then
				UpdateVisibility()
			end
		end
	end)

	if not Attach() then
		driver:RegisterEvent("ADDON_LOADED")
	end
end

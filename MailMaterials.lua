local addonName, ns = ...

--[[
	Recipe materials in your mail: scans the inbox for items that are ingredients of recipes the CURRENT character knows
	and lists those recipes in a window, with how many of each ingredient you have (bags, bank and mail) against how many the
	recipe needs. A recipe with nothing missing is marked "Craftable".

	Saved data (validated in InitData):
		JimmysStatWeightsDB.mailMaterials = { position = { point, relPoint, x, y } } -- position of the window
		JimmysStatWeightsCharDB.mailItems = { time = time(), counts = { [itemID] = quantity }, cod = { [itemID] = true }, partial = bool }

	The snapshot is what the last scan of this character's mailbox found, so the window also works away from the mailbox.
	"partial" means the client holds more mails than the inbox lists (it lists at most 50 at a time).

	Scanning: every MAIL_INBOX_UPDATE reads the inbox at once and replaces the snapshot (it is cheap, and the last read before the
	mailbox closes must not be lost); only the refresh of an open window waits for the end of the burst (a trailing
	debounce). Nothing is read after MAIL_CLOSED, and nothing before the first MAIL_SHOW. Every API result is read through pcall;
	secret values are skipped and never branched on (a secret COD amount counts as no COD).
	The recipes come from Recipes.lua (ns.GetKnownRecipesHere): their ingredient slots, where the items of one slot are
	interchangeable (quality tiers) and together must reach the slot's quantity. Item names come from ns.GetItemName, and a
	double-click on a recipe uses ns.OpenRecipeInProfession.

	The window opens only with /ju materials (a toggle); a scan never opens it. It follows the mail and the bags while it is open.

	The mail features have one switch (JimmysStatWeightsDB.mail.enabled, see Mail.lua): while it is off the inbox is not scanned,
	the window does not open (/ju materials says so) and an open window is closed. The last snapshot is kept.
]]

local FRAME_NAME = "JimmysUtilsMailMaterialsFrame"
local SCROLL_NAME = "JimmysUtilsMailMaterialsScroll"

local FRAME_WIDTH = 420
local FRAME_HEIGHT = 400
local LIST_WIDTH = 356 -- scroll frame width (frame minus margins and the scroll bar)
local HEADER_HEIGHT = 34
local HEADER_ICON_SIZE = 28
local LINE_HEIGHT = 14
local BLOCK_GAP = 10
local STATUS_WIDTH = 110
local QUESTION_ICON = 134400 -- INV_Misc_QuestionMark

-- Without a saved position the window sits right of everything the mailbox can show: the mailbox, the open letter beside it
-- and the recent recipients panel docked to the letter (see Mail.lua).
local DEFAULT_POSITION = { point = "CENTER", relPoint = "CENTER", x = 150, y = 0 } -- when the screen size is unknown
local MAX_OFFSET = 10000
local MAILBOX_LEFT = 16 -- where MailFrame starts and how wide it is, when the client cannot tell
local MAILBOX_WIDTH = 384
local OPEN_MAIL_GAP = 46 -- OpenMailFrame sits this far right of MailFrame, and is this wide
local OPEN_MAIL_WIDTH = 338
local RECIPIENTS_PANEL_WIDTH = 152 -- the recent recipients panel and its gap
local POSITION_MARGIN = 8

local SCAN_DELAY = 0.5 -- seconds; MAIL_INBOX_UPDATE comes in bursts
local DEFAULT_ATTACHMENTS = 16 -- ATTACHMENTS_MAX_RECEIVE
local MAX_ATTACHMENTS = 64

local GREEN = "ff33ff33"
local RED = "ffff4040"
local ORANGE = "ffff9933"

local VALID_POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Set in ns.InitMailMaterials.
local settings, charDb
local window, ui
local initialized = false
local refreshTimer -- the pending refresh timer (a trailing debounce)
local refreshToken = 0 -- invalidates timers that were replaced or cancelled
local refreshPending = false
local bagRefreshPending = false
local mailClosed = true -- until MAIL_SHOW: nothing is scanned without a mailbox visit

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

-- A real number that is not a secret value.
local function PlainNumber(value)
	return not IsSecret(value) and type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

-- A positive whole number that is not a secret value (item IDs and quantities).
local function IsID(value)
	return PlainNumber(value) and value > 0 and value < 2 ^ 31 and value == math.floor(value)
end

-- Is the master switch of the mail features on? (Mail.lua owns it; without that file there is nothing to ask.)
local function MailOn()
	return ns.IsMailEnabled == nil or ns.IsMailEnabled()
end

local function Now()
	if time then
		return time()
	end
	return os and os.time and os.time() or 0
end

-- The text with its "|" doubled, so item names never start an escape sequence.
local function Escape(text)
	return (tostring(text):gsub("|", "||"))
end

local function SetWindowTitle(frame, text)
	local container = frame.TitleContainer
	if container and container.TitleText then
		container.TitleText:SetText(text)
	elseif type(frame.SetTitle) == "function" then
		frame:SetTitle(text)
	else
		if not frame.titleText then
			frame.titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			frame.titleText:SetPoint("TOP", frame, "TOP", 0, -5)
		end
		frame.titleText:SetText(text)
	end
end

-- "less than a minute", "5 minutes", "2 hours", "3 days".
local function FormatAge(seconds)
	if seconds < 60 then
		return "less than a minute"
	elseif seconds < 3600 then
		local minutes = math.floor(seconds / 60)
		return minutes .. (minutes == 1 and " minute" or " minutes")
	elseif seconds < 86400 then
		local hours = math.floor(seconds / 3600)
		return hours .. (hours == 1 and " hour" or " hours")
	end
	local days = math.floor(seconds / 86400)
	return days .. (days == 1 and " day" or " days")
end

--------------------------------------------------------------------------------
-- Owned items
--------------------------------------------------------------------------------

-- How many of an item the character has in bags, bank, reagent bank and account bank (the bank counts may be stale away
-- from the bank). 0 when the client cannot tell.
local function GetOwned(itemID)
	if C_Item and C_Item.GetItemCount then
		local ok, count = pcall(C_Item.GetItemCount, itemID, true, false, true, true)
		if ok and PlainNumber(count) then
			return math.max(0, count)
		end
	end
	if GetItemCount then
		local ok, count = pcall(GetItemCount, itemID, true)
		if ok and PlainNumber(count) then
			return math.max(0, count)
		end
	end
	return 0
end

--------------------------------------------------------------------------------
-- Scanning the inbox
--------------------------------------------------------------------------------

local function GetMaxAttachments()
	local max = ATTACHMENTS_MAX_RECEIVE
	if IsID(max) and max <= MAX_ATTACHMENTS then
		return max
	end
	return DEFAULT_ATTACHMENTS
end

-- Reads the loaded inbox. Returns counts ({ [itemID] = total quantity }), cod ({ [itemID] = true } for items that come
-- with a cash on delivery request) and partial (the client holds more mails than it lists), or nil when the inbox cannot
-- be read.
local function ReadInbox()
	if type(GetInboxNumItems) ~= "function" or type(GetInboxItem) ~= "function" then
		return nil
	end
	local ok, numItems, totalItems = pcall(GetInboxNumItems)
	if not ok or not PlainNumber(numItems) then
		return nil
	end
	numItems = math.max(0, math.floor(numItems))
	local partial = PlainNumber(totalItems) and totalItems > numItems or false
	local attachments = GetMaxAttachments()

	local counts, cod = {}, {}
	for index = 1, numItems do
		local isCod, hasItems = false, true
		if type(GetInboxHeaderInfo) == "function" then
			local okHeader, _, _, _, _, _, codAmount, _, itemCount = pcall(GetInboxHeaderInfo, index)
			if okHeader then
				isCod = PlainNumber(codAmount) and codAmount > 0
				if PlainNumber(itemCount) and itemCount == 0 then
					hasItems = false
				end
			end
		end
		if hasItems then
			for attachment = 1, attachments do
				local okItem, _, itemID, _, count, _, _, isCurrency = pcall(GetInboxItem, index, attachment)
				-- A currency, or one that cannot be told apart from an item, is not a material.
				if okItem and not IsSecret(isCurrency) and not isCurrency and IsID(itemID) and IsID(count) then
					counts[itemID] = (counts[itemID] or 0) + count
					if isCod then
						cod[itemID] = true
					end
				end
			end
		end
	end
	return counts, cod, partial
end

local RefreshWindow -- defined with the window below

-- Scans the inbox now and saves the result as this character's snapshot. Returns true when it was saved.
function ns.ScanMailbox()
	if not charDb or not MailOn() then
		return false
	end
	local counts, cod, partial = ReadInbox()
	if not counts then
		return false
	end
	charDb.mailItems = { time = Now(), counts = counts, cod = cod, partial = partial }
	return true
end

--------------------------------------------------------------------------------
-- Matching recipes
--------------------------------------------------------------------------------

-- Owned counts and item names are asked once per call, however many recipes share an ingredient.
local function CachedOwned(cache, itemID)
	local owned = cache.owned[itemID]
	if owned == nil then
		owned = GetOwned(itemID)
		cache.owned[itemID] = owned
	end
	return owned
end

local function CachedName(cache, itemID)
	local name = cache.names[itemID]
	if not name then
		name = ns.GetItemName and ns.GetItemName(itemID) or ("Item " .. itemID)
		cache.names[itemID] = name
	end
	return name
end

-- The recipes the current character knows that use something from the snapshot, best first (craftable, then fewest
-- missing items, then name). Returns a table:
--	entries = { { recipeID, name, icon, profession, output, knownHere = true, missing = items missing in total, craftable,
--		reagents = { { itemID, itemIDs, name, need, owned, mail, have, missing, cod } } } }
-- One reagent line per ingredient slot: the items of a slot are alternatives (quality tiers), so what is owned and in the mail
-- is added up over them and compared with the slot's quantity; itemID is the one shown (the one there is most of).
--	snapshot = the saved snapshot or nil, noRecipes = true when the character has no saved recipes
function ns.GetMailMaterials()
	local snapshot = charDb and charDb.mailItems or nil
	local known = ns.GetKnownRecipesHere and ns.GetKnownRecipesHere() or {}
	local result = { entries = {}, snapshot = snapshot, noRecipes = #known == 0 }
	if not snapshot then
		return result
	end

	local cache = { owned = {}, names = {} }
	local counts, cod = snapshot.counts, snapshot.cod
	for _, recipe in ipairs(known) do
		local inMail = false
		for _, slot in ipairs(recipe.slots) do
			for _, itemID in ipairs(slot.items) do
				if (counts[itemID] or 0) > 0 then
					inMail = true
				end
			end
		end
		if inMail then
			local reagents, missingTotal = {}, 0
			for _, slot in ipairs(recipe.slots) do
				local owned, mail, isCod = 0, 0, false
				local shown, shownHave = slot.items[1], -1
				for _, itemID in ipairs(slot.items) do
					local itemOwned, itemMail = CachedOwned(cache, itemID), counts[itemID] or 0
					owned = owned + itemOwned
					mail = mail + itemMail
					if itemMail > 0 and cod[itemID] then
						isCod = true
					end
					if itemOwned + itemMail > shownHave then
						shown, shownHave = itemID, itemOwned + itemMail
					end
				end
				local name = CachedName(cache, shown)
				if #slot.items > 1 then
					name = name .. " (any quality)"
				end
				local have = owned + mail
				local missing = math.max(0, slot.quantity - have)
				missingTotal = missingTotal + missing
				reagents[#reagents + 1] = {
					itemID = shown,
					itemIDs = slot.items,
					name = name,
					sortKey = name:lower(),
					need = slot.quantity,
					owned = owned,
					mail = mail,
					have = have,
					missing = missing,
					cod = isCod,
				}
			end
			table.sort(reagents, function(a, b)
				if a.sortKey ~= b.sortKey then
					return a.sortKey < b.sortKey
				end
				return a.itemID < b.itemID
			end)
			result.entries[#result.entries + 1] = {
				recipeID = recipe.recipeID,
				name = recipe.name,
				sortKey = recipe.name:lower(),
				icon = recipe.icon,
				profession = recipe.profession,
				output = recipe.output,
				knownHere = true,
				known = true,
				knownBy = {},
				missing = missingTotal,
				craftable = missingTotal == 0,
				reagents = reagents,
			}
		end
	end

	table.sort(result.entries, function(a, b)
		if a.craftable ~= b.craftable then
			return a.craftable
		end
		if a.missing ~= b.missing then
			return a.missing < b.missing
		end
		if a.sortKey ~= b.sortKey then
			return a.sortKey < b.sortKey
		end
		return a.recipeID < b.recipeID
	end)
	return result
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function FormatReagent(reagent)
	local text = string.format("%s  %d/%d", Escape(reagent.name), reagent.have, reagent.need)
	if reagent.mail > 0 then
		text = text .. string.format(" (%d in mail)", reagent.mail)
	end
	if reagent.cod then
		text = text .. " (COD)"
	end
	if reagent.missing > 0 then
		text = text .. string.format(" \226\128\147 need %d more", reagent.missing)
	end
	return "|c" .. (reagent.missing > 0 and RED or GREEN) .. text .. "|r"
end

local function FormatStatus(entry)
	if entry.craftable then
		return "|c" .. GREEN .. "Craftable|r"
	end
	return "|c" .. ORANGE .. string.format("Missing %d item%s", entry.missing, entry.missing == 1 and "" or "s") .. "|r"
end

local function AcquireBlock(index)
	local block = ui.blocks[index]
	if block then
		return block
	end

	block = { lines = {} }
	-- A Button, so the header gets OnDoubleClick (opens the recipe in the profession window).
	block.header = CreateFrame("Button", nil, ui.scrollChild)
	block.header:SetSize(LIST_WIDTH, HEADER_HEIGHT)
	block.header:EnableMouse(true)
	if block.header.RegisterForClicks then
		block.header:RegisterForClicks("LeftButtonUp")
	end
	block.header:SetScript("OnDoubleClick", function()
		if block.entry then
			ns.OpenRecipeInProfession(block.entry)
		end
	end)

	block.highlight = block.header:CreateTexture(nil, "HIGHLIGHT")
	block.highlight:SetAllPoints(block.header)
	block.highlight:SetColorTexture(1, 1, 1, 0.1)

	block.icon = block.header:CreateTexture(nil, "ARTWORK")
	block.icon:SetSize(HEADER_ICON_SIZE, HEADER_ICON_SIZE)
	block.icon:SetPoint("TOPLEFT", block.header, "TOPLEFT", 2, -3)

	block.status = block.header:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	block.status:SetPoint("TOPRIGHT", block.header, "TOPRIGHT", -4, -4)
	block.status:SetWidth(STATUS_WIDTH)
	block.status:SetHeight(14)
	block.status:SetJustifyH("RIGHT")

	block.name = block.header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	block.name:SetPoint("TOPLEFT", block.icon, "TOPRIGHT", 6, 0)
	block.name:SetPoint("RIGHT", block.status, "LEFT", -4, 0)
	block.name:SetHeight(14)
	block.name:SetJustifyH("LEFT")
	block.name:SetWordWrap(false)

	block.profession = block.header:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	block.profession:SetPoint("TOPLEFT", block.name, "BOTTOMLEFT", 0, -2)
	block.profession:SetPoint("RIGHT", block.header, "RIGHT", -4, 0)
	block.profession:SetHeight(12)
	block.profession:SetJustifyH("LEFT")
	block.profession:SetWordWrap(false)

	block.header:SetScript("OnEnter", function(self)
		local entry = block.entry
		if not (entry and GameTooltip) then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if entry.output and GameTooltip.SetItemByID then
			pcall(GameTooltip.SetItemByID, GameTooltip, entry.output)
		elseif GameTooltip.SetSpellByID then
			pcall(GameTooltip.SetSpellByID, GameTooltip, entry.recipeID)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Double-click to open it in your profession window.", 0.6, 0.8, 1, true)
		GameTooltip:Show()
	end)
	block.header:SetScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)

	ui.blocks[index] = block
	return block
end

local function AcquireLine(block, index)
	local line = block.lines[index]
	if not line then
		line = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		line:SetWidth(LIST_WIDTH - HEADER_ICON_SIZE - 12)
		line:SetHeight(LINE_HEIGHT)
		line:SetJustifyH("LEFT")
		line:SetWordWrap(false)
		block.lines[index] = line
	end
	return line
end

-- Fills the window. `data` is ns.GetMailMaterials() when the caller has it already.
RefreshWindow = function(data)
	if not (window and ui) then
		return
	end
	data = data or ns.GetMailMaterials()
	local snapshot = data.snapshot

	if snapshot then
		local age = math.max(0, Now() - snapshot.time)
		ui.source:SetText("From your mailbox, " .. FormatAge(age) .. " ago")
	else
		ui.source:SetText("Your mailbox has not been scanned yet.")
	end
	ui.partial:SetShown(snapshot ~= nil and snapshot.partial == true)

	local child = ui.scrollChild
	child:SetWidth(LIST_WIDTH)
	local y = 0
	for index, entry in ipairs(data.entries) do
		local block = AcquireBlock(index)
		block.entry = entry
		block.header:ClearAllPoints()
		block.header:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
		block.icon:SetTexture(entry.icon or QUESTION_ICON)
		block.name:SetText(Escape(entry.name))
		block.profession:SetText(Escape(entry.profession))
		block.status:SetText(FormatStatus(entry))
		block.header:Show()
		y = y + HEADER_HEIGHT + 2

		for lineIndex, reagent in ipairs(entry.reagents) do
			local line = AcquireLine(block, lineIndex)
			line:ClearAllPoints()
			line:SetPoint("TOPLEFT", child, "TOPLEFT", HEADER_ICON_SIZE + 10, -y)
			line:SetText(FormatReagent(reagent))
			line:Show()
			y = y + LINE_HEIGHT
		end
		for lineIndex = #entry.reagents + 1, #block.lines do
			block.lines[lineIndex]:Hide()
		end
		y = y + BLOCK_GAP
	end
	for index = #data.entries + 1, #ui.blocks do
		local block = ui.blocks[index]
		block.entry = nil
		block.header:Hide()
		for _, line in ipairs(block.lines) do
			line:Hide()
		end
	end
	child:SetHeight(math.max(HEADER_HEIGHT, y))

	local empty
	if data.noRecipes then
		empty = "Open your profession windows once so recipes can be learned."
	elseif not snapshot then
		empty = "Open your mailbox to scan it for recipe materials."
	elseif #data.entries == 0 then
		empty = "No mail items are used by your known recipes."
	end
	ui.emptyText:SetText(empty or "")
	ui.emptyText:SetShown(empty ~= nil)
end

local function SavePosition()
	local point, relative, relPoint, x, y = window:GetPoint(1)
	if relative ~= nil and relative ~= UIParent then
		return
	end
	if VALID_POINTS[point] and VALID_POINTS[relPoint] and PlainNumber(x) and PlainNumber(y) then
		settings.position = { point = point, relPoint = relPoint, x = x, y = y }
	end
end

-- The frame's right edge in screen units, or nil when the client has not placed it.
local function RightEdgeOf(frame)
	if not (frame and frame.GetRight) then
		return nil
	end
	local ok, right = pcall(frame.GetRight, frame)
	if ok and PlainNumber(right) then
		return right
	end
end

-- Where the window goes without a saved position: right of the mailbox, the open letter and the recent recipients panel
-- docked to the letter, so it covers none of them. When the screen is too narrow for that it goes to the right edge.
local function GetDefaultPosition()
	local uiWidth = UIParent and UIParent:GetWidth()
	if not PlainNumber(uiWidth) or uiWidth <= 0 then
		return DEFAULT_POSITION
	end
	local mailRight = RightEdgeOf(MailFrame)
	if not mailRight then
		local width = MailFrame and MailFrame.GetWidth and MailFrame:GetWidth()
		mailRight = MAILBOX_LEFT + (PlainNumber(width) and width > 0 and width or MAILBOX_WIDTH)
	end
	local letterWidth = OpenMailFrame and OpenMailFrame.GetWidth and OpenMailFrame:GetWidth()
	if not (PlainNumber(letterWidth) and letterWidth > 0) then
		letterWidth = OPEN_MAIL_WIDTH
	end
	local left = mailRight + OPEN_MAIL_GAP + letterWidth + RECIPIENTS_PANEL_WIDTH + POSITION_MARGIN
	left = math.max(0, math.min(left, uiWidth - FRAME_WIDTH))
	return { point = "CENTER", relPoint = "CENTER", x = left + FRAME_WIDTH / 2 - uiWidth / 2, y = 0 }
end

local function ApplyPosition()
	local position = settings and settings.position or GetDefaultPosition()
	window:ClearAllPoints()
	window:SetPoint(position.point, UIParent, position.relPoint, position.x, position.y)
end

local function BuildWindow()
	if window then
		return
	end

	window = CreateFrame("Frame", FRAME_NAME, UIParent, "DefaultPanelFlatTemplate")
	local frame = window
	-- New frames start shown; hide it so the first Show() fires OnShow.
	frame:Hide()
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	ApplyPosition()
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	SetWindowTitle(frame, "Materials in your mail")

	-- Escape closes the window, like Blizzard's own panels.
	if UISpecialFrames and not tContains(UISpecialFrames, FRAME_NAME) then
		table.insert(UISpecialFrames, FRAME_NAME)
	end

	ui = { blocks = {} }

	-- The title strip drags the window.
	local drag = CreateFrame("Frame", nil, frame)
	drag:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -26, 0)
	drag:SetHeight(24)
	drag:SetFrameLevel(frame:GetFrameLevel() + 5)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	drag:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)

	ui.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	ui.closeButton:SetSize(24, 24)
	ui.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

	-- Where the numbers come from, and a note when the mailbox could not be read completely.
	ui.source = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.source:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -32)
	ui.source:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -32)
	ui.source:SetHeight(14)
	ui.source:SetJustifyH("LEFT")
	ui.source:SetWordWrap(false)

	ui.partial = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.partial:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -46)
	ui.partial:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -46)
	ui.partial:SetHeight(14)
	ui.partial:SetJustifyH("LEFT")
	ui.partial:SetWordWrap(false)
	ui.partial:SetTextColor(1, 0.6, 0.2)
	ui.partial:SetText("Only the first 50 mails are scanned; take some mail to see the rest.")
	ui.partial:Hide()

	-- List. Named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.scroll = CreateFrame("ScrollFrame", SCROLL_NAME, frame, "UIPanelScrollFrameTemplate")
	ui.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -66)
	ui.scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 36)

	ui.scrollChild = CreateFrame("Frame", nil, ui.scroll)
	ui.scrollChild:SetSize(LIST_WIDTH, HEADER_HEIGHT)
	ui.scroll:SetScrollChild(ui.scrollChild)
	ui.emptyText = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.emptyText:SetPoint("TOPLEFT", ui.scrollChild, "TOPLEFT", 4, -4)
	ui.emptyText:SetWidth(LIST_WIDTH - 12)
	ui.emptyText:SetJustifyH("LEFT")
	ui.emptyText:SetJustifyV("TOP")
	ui.emptyText:Hide()

	ui.footer = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 14)
	ui.footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 14)
	ui.footer:SetHeight(14)
	ui.footer:SetJustifyH("LEFT")
	ui.footer:SetWordWrap(false)
	ui.footer:SetText("Double-click a recipe to open it in your profession window.")

	frame:SetScript("OnShow", function()
		RefreshWindow()
	end)
	frame:SetScript("OnHide", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)
end

-- Opens the window (refreshing it when it is already open).
function ns.ShowMailMaterials()
	if not MailOn() then
		return false
	end
	BuildWindow()
	if window:IsShown() then
		RefreshWindow()
		window:Raise()
		return true
	end
	if not (settings and settings.position) then
		ApplyPosition() -- the mailbox may have been moved since
	end
	window:Show() -- OnShow refreshes
	window:Raise()
	return true
end

function ns.HideMailMaterials()
	if window then
		window:Hide()
	end
end

function ns.ToggleMailMaterials()
	if window and window:IsShown() then
		window:Hide()
	else
		return ns.ShowMailMaterials()
	end
end


-- Window and widget table, for tests.
function ns.GetMailMaterialsWindow()
	return window, ui
end

-- The saved recipes or the mail changed: a window that is open follows.
function ns.RefreshMailMaterials()
	if window and window:IsShown() then
		RefreshWindow()
	end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function CancelRefresh()
	if refreshTimer and refreshTimer.Cancel then
		pcall(refreshTimer.Cancel, refreshTimer)
	end
	refreshTimer = nil
	refreshPending = false
	refreshToken = refreshToken + 1 -- a timer that cannot be cancelled does nothing when it fires
end

-- The inbox has stopped changing: update the window if it is open.
local function OnRefresh()
	if window and window:IsShown() then
		RefreshWindow()
	end
end

local function ScheduleRefresh()
	if not (window and window:IsShown()) then
		return
	end
	CancelRefresh()
	refreshPending = true
	local token = refreshToken
	local function Fire()
		if token == refreshToken then
			refreshTimer = nil
			refreshPending = false
			OnRefresh()
		end
	end
	if C_Timer and C_Timer.NewTimer then
		refreshTimer = C_Timer.NewTimer(SCAN_DELAY, Fire)
	elseif C_Timer and C_Timer.After then
		C_Timer.After(SCAN_DELAY, Fire)
	else
		Fire()
	end
end

-- Bag changes come in bursts too: the open window is refreshed once, on the next frame.
local function ScheduleBagRefresh()
	if bagRefreshPending or not (window and window:IsShown()) then
		return
	end
	bagRefreshPending = true
	local function Fire()
		bagRefreshPending = false
		ns.RefreshMailMaterials()
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0, Fire)
	else
		Fire()
	end
end

-- Mail.lua: the master switch of the mail features was flipped. Off closes the window; on reads an open mailbox at once
-- (otherwise the snapshot would wait for the next inbox update).
function ns.OnMailEnabledChanged(enabled)
	if not enabled then
		ns.HideMailMaterials()
	elseif not mailClosed and ns.ScanMailbox() then
		ScheduleRefresh()
	end
end

--------------------------------------------------------------------------------
-- Command: /ju materials ...
--------------------------------------------------------------------------------

local function Trim(text)
	return (text:match("^%s*(.-)%s*$"))
end

local function PrintUsage()
	ns.Print("Usage: /ju materials (open or close the window)")
end

function ns.HandleMaterialsCommand(rest)
	if not settings then
		ns.Print("The mail materials are not ready yet.")
		return
	end
	local lowered = Trim(rest or ""):lower():gsub("%s+", " ")

	if lowered == "" then
		if not MailOn() then
			ns.HideMailMaterials()
			ns.Print("Mail features are off. Turn them on with /ju mail on.")
			return
		end
		ns.ToggleMailMaterials()
	else
		PrintUsage()
	end
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- A saved snapshot as it should be kept, or nil when it cannot be trusted.
local function CleanSnapshot(raw)
	if type(raw) ~= "table" or not PlainNumber(raw.time) or raw.time < 0 or type(raw.counts) ~= "table" then
		return nil
	end
	local counts, cod = {}, {}
	for itemID, quantity in pairs(raw.counts) do
		if IsID(itemID) and IsID(quantity) then
			counts[itemID] = quantity
		end
	end
	if type(raw.cod) == "table" then
		for itemID, flag in pairs(raw.cod) do
			if flag == true and counts[itemID] then
				cod[itemID] = true
			end
		end
	end
	return { time = raw.time, counts = counts, cod = cod, partial = raw.partial == true }
end

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(db, characterDb)
	if type(db.mailMaterials) ~= "table" then
		db.mailMaterials = {}
	end
	settings = db.mailMaterials
	settings.autoShow = nil -- an earlier version opened the window by itself; it is a command now
	local position = settings.position
	if type(position) ~= "table" or not VALID_POINTS[position.point] or not VALID_POINTS[position.relPoint]
		or not PlainNumber(position.x) or not PlainNumber(position.y)
		or math.abs(position.x) > MAX_OFFSET or math.abs(position.y) > MAX_OFFSET then
		settings.position = nil
	else
		settings.position = { point = position.point, relPoint = position.relPoint, x = position.x, y = position.y }
	end

	charDb = characterDb
	charDb.mailItems = CleanSnapshot(charDb.mailItems)
end

function ns.InitMailMaterials(db, characterDb)
	if initialized then
		return
	end
	initialized = true

	InitData(db, characterDb)

	local driver = CreateFrame("Frame")
	-- An event this client does not have must not stop the others from being registered.
	for _, event in ipairs({ "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED", "BAG_UPDATE_DELAYED" }) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript("OnEvent", function(self, event)
		if event == "MAIL_SHOW" then
			mailClosed = false
		elseif event == "MAIL_INBOX_UPDATE" then
			-- Read at once (the snapshot must hold the last state the mailbox was in); only the window waits.
			if not mailClosed and ns.ScanMailbox() then
				ScheduleRefresh()
			end
		elseif event == "MAIL_CLOSED" then
			mailClosed = true
			local wasPending = refreshPending
			CancelRefresh()
			if wasPending and window and window:IsShown() then
				RefreshWindow() -- the open window shows the final state
			end
		elseif event == "BAG_UPDATE_DELAYED" then
			ScheduleBagRefresh()
		end
	end)
end

local addonName, ns = ...

--[[
	Recipe materials in your mail: scans the inbox for items that are ingredients of recipes your characters know and lists
	those recipes in a window, with how many of each ingredient the character has (bags, bank and mail) against how many the
	recipe needs. A recipe with nothing missing is marked "Craftable". The window groups the recipes by character: the current
	character first, then the other characters of the current realm (mail cannot cross realms), unless the "Show other
	characters" check box is off.

	Saved data (validated in InitData):
		JimmysStatWeightsDB.mailMaterials = { position = { point, relPoint, x, y }, showOthers = true } -- window position, other characters shown
		JimmysStatWeightsDB.inventory[character].mail = { time = time(), counts = { [itemID] = quantity }, cod = { [itemID] = true }, partial = bool }

	The snapshot of the mailbox lives with the other item snapshots of the character (Inventory.lua: ns.GetMailSnapshot /
	ns.SetMailSnapshot; older versions kept it in JimmysStatWeightsCharDB.mailItems, moved at load). It is what the last scan of
	that character's mailbox found (plus items mailed to it since, Mail.lua), so the window also works away from the mailbox.
	"partial" means the client holds more mails than the inbox lists (it lists at most 50 at a time).

	What each character has: the current character counts the bags live (C_Item.GetItemCount) plus the saved bank and account
	bank snapshots (the live count with bank is used for a part that was never saved), and the mailbox you have open (a scan of
	it is always the current character's). Another character counts its saved bags, bank, account bank and its own saved
	mailbox, and the items in the mailbox you have open are "sendable": they make a recipe appear for that character and count
	towards it, marked "(N in your mail)", and a recipe that needs them is "Craftable after mail" (send the items first).
	A recipe is listed for a character when one of its ingredients is in the open mailbox or in that character's own mailbox.

	Scanning: every MAIL_INBOX_UPDATE reads the inbox at once and replaces the snapshot (it is cheap, and the last read before the
	mailbox closes must not be lost); only the refresh of an open window waits for the end of the burst (a trailing
	debounce). Nothing is read after MAIL_CLOSED, and nothing before the first MAIL_SHOW. Every API result is read through pcall;
	secret values are skipped and never branched on (a secret COD amount counts as no COD).
	The recipes come from Recipes.lua (ns.GetKnownRecipes): their ingredient slots, where the items of one slot are
	interchangeable (quality tiers) and together must reach the slot's quantity. Item names come from ns.GetItemName, and a
	double-click on a recipe uses ns.OpenRecipeInProfession (it only opens recipes of the current character).

	The window opens only with /ju materials (a toggle); a scan never opens it. It follows the mail and the bags while it is open.

	The mail features have one switch (JimmysStatWeightsDB.mail.enabled, see Mail.lua): while it is off the inbox is not scanned,
	the window does not open (/ju materials says so) and an open window is closed. The last snapshot is kept.
]]

local FRAME_NAME = "JimmysUtilsMailMaterialsFrame"
local SCROLL_NAME = "JimmysUtilsMailMaterialsScroll"

local FRAME_WIDTH = 420
local FRAME_HEIGHT = 416
local LIST_WIDTH = 356 -- scroll frame width (frame minus margins and the scroll bar)
local HEADER_HEIGHT = 34
local HEADER_ICON_SIZE = 28
local LINE_HEIGHT = 14
local BLOCK_GAP = 10
local STATUS_WIDTH = 120
local GROUP_TITLE_HEIGHT = 15 -- a character's name; the line under it about what is known of its items follows (as tall as its text)
local GROUP_INFO_MIN_HEIGHT = 12
local GROUP_INFO_GAP = 6
local GROUP_GAP = 6
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
local settings
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

-- The live count the client gives for the current character. The bank parts are asked for only when no snapshot of them is
-- saved (the client's bank counts may be stale away from the bank, so a saved snapshot is preferred); the bags and the reagent
-- bag are always live. 0 when the client cannot tell.
local function GetLiveCount(itemID, withBank, withAccountBank)
	if C_Item and C_Item.GetItemCount then
		local ok, count = pcall(C_Item.GetItemCount, itemID, withBank, false, withBank, withAccountBank)
		if ok and PlainNumber(count) then
			return math.max(0, count)
		end
	end
	if GetItemCount then
		local ok, count = pcall(GetItemCount, itemID, withBank)
		if ok and PlainNumber(count) then
			return math.max(0, count)
		end
	end
	return 0
end

local function SavedCount(items, itemID)
	return items and items[itemID] or 0
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

-- Scans the inbox now and saves the result as the snapshot of this character's mailbox. Returns true when it was saved.
function ns.ScanMailbox()
	local key = ns.GetCharacterKey and ns.GetCharacterKey()
	if not (key and ns.SetMailSnapshot and MailOn()) then
		return false
	end
	local counts, cod, partial = ReadInbox()
	if not counts then
		return false
	end
	return ns.SetMailSnapshot(key, { time = Now(), counts = counts, cod = cod, partial = partial })
end

--------------------------------------------------------------------------------
-- Matching recipes
--------------------------------------------------------------------------------

-- Item names are asked once per call, however many recipes share an ingredient.
local function CachedName(cache, itemID)
	local name = cache.names[itemID]
	if not name then
		name = ns.GetItemName and ns.GetItemName(itemID) or ("Item " .. itemID)
		cache.names[itemID] = name
	end
	return name
end

-- "Name" and "Realm" of a "Name-Realm" key (no realm for a plain name).
local function SplitKey(key)
	local name, realm = key:match("^([^%-]+)%-(.+)$")
	if name then
		return name, realm
	end
	return key, nil
end

-- The recipes of one character that use something in its own mailbox or in the open one, best first (craftable, then fewest
-- missing items, then name). `who` says whose items count:
--	isOwn, key, name
--	owned(itemID) = bags, bank and account bank of the character
--	theirCounts / theirCod = the character's own mailbox (another character only)
--	mailCounts / mailCod = the mailbox that is open: the current character's mail, or for another character what could be sent
-- One reagent line per ingredient slot: the items of a slot are alternatives (quality tiers), so what is owned and in the mail
-- is added up over them and compared with the slot's quantity; itemID is the one shown (the one there is most of).
local function BuildEntries(recipes, who, cache)
	local entries = {}
	local theirCounts, theirCod = who.theirCounts or {}, who.theirCod or {}
	local mailCounts, mailCod = who.mailCounts or {}, who.mailCod or {}
	local ownedCache = {}
	local function Owned(itemID)
		local owned = ownedCache[itemID]
		if owned == nil then
			owned = who.owned(itemID)
			ownedCache[itemID] = owned
		end
		return owned
	end

	for _, recipe in ipairs(recipes) do
		local inMail = false
		for _, slot in ipairs(recipe.slots) do
			for _, itemID in ipairs(slot.items) do
				if (theirCounts[itemID] or 0) > 0 or (mailCounts[itemID] or 0) > 0 then
					inMail = true
				end
			end
		end
		if inMail then
			local reagents, missingTotal, needsMail = {}, 0, false
			for _, slot in ipairs(recipe.slots) do
				local owned, their, mail, isCod = 0, 0, 0, false
				local shown, shownHave = slot.items[1], -1
				for _, itemID in ipairs(slot.items) do
					local itemOwned, itemTheirs, itemMail = Owned(itemID), theirCounts[itemID] or 0, mailCounts[itemID] or 0
					owned = owned + itemOwned
					their = their + itemTheirs
					mail = mail + itemMail
					if (itemTheirs > 0 and theirCod[itemID]) or (itemMail > 0 and mailCod[itemID]) then
						isCod = true
					end
					if itemOwned + itemTheirs + itemMail > shownHave then
						shown, shownHave = itemID, itemOwned + itemTheirs + itemMail
					end
				end
				local name = CachedName(cache, shown)
				if #slot.items > 1 then
					name = name .. " (any quality)"
				end
				local have = owned + their + mail
				local missing = math.max(0, slot.quantity - have)
				missingTotal = missingTotal + missing
				-- Another character needs the items of the open mailbox sent to it when what it has itself falls short.
				local needsSend = not who.isOwn and mail > 0 and owned + their < slot.quantity
				needsMail = needsMail or needsSend
				reagents[#reagents + 1] = {
					itemID = shown,
					itemIDs = slot.items,
					name = name,
					sortKey = name:lower(),
					need = slot.quantity,
					owned = owned,
					theirMail = their,
					mail = mail,
					have = have,
					missing = missing,
					cod = isCod,
					needsSend = needsSend,
				}
			end
			table.sort(reagents, function(a, b)
				if a.sortKey ~= b.sortKey then
					return a.sortKey < b.sortKey
				end
				return a.itemID < b.itemID
			end)
			entries[#entries + 1] = {
				recipeID = recipe.recipeID,
				name = recipe.name,
				sortKey = recipe.name:lower(),
				icon = recipe.icon,
				profession = recipe.profession,
				output = recipe.output,
				isOwn = who.isOwn,
				characterKey = who.key,
				knownHere = who.isOwn,
				known = true,
				knownBy = who.isOwn and {} or { who.name },
				missing = missingTotal,
				craftable = missingTotal == 0,
				needsMail = missingTotal == 0 and needsMail,
				reagents = reagents,
			}
		end
	end

	table.sort(entries, function(a, b)
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
	return entries
end

-- What the recipes of the characters of this realm can make with the mail. Returns a table:
--	entries = the current character's recipes that use something in its mailbox (see BuildEntries; each entry also has
--		knownHere = true, missing = items missing in total, craftable, reagents = { { itemID, itemIDs, name, need, owned, mail,
--		theirMail, have, missing, cod } })
--	characters = { { key, name, isOwn, bagsTime, bankTime, mailTime, mailSentTime, entries } }: the current character first
--		(always there), then the other characters of the realm that have entries, by name; none of them when the "Show other
--		characters" setting is off
--	snapshot = the saved snapshot of the current mailbox or nil, noRecipes = true when the character has no saved recipes,
--	accountTime = when the account bank was last seen
function ns.GetMailMaterials()
	local ownKey, ownRealm
	if ns.GetCharacterKey then
		ownKey, ownRealm = ns.GetCharacterKey()
	end
	local snapshot = ownKey and ns.GetMailSnapshot and ns.GetMailSnapshot(ownKey) or nil
	local known = ns.GetKnownRecipesHere and ns.GetKnownRecipesHere() or {}
	local account = ns.GetAccountBank and ns.GetAccountBank() or nil
	local accountItems = account and account.items or nil
	local result = {
		entries = {}, characters = {}, snapshot = snapshot, noRecipes = #known == 0,
		accountTime = account and account.time or nil,
	}
	local cache = { names = {} }

	-- The current character: the bags are live, the bank parts come from what was saved (when its bank was never saved the
	-- client's live count with every bank part is used instead), and the open mailbox is its mail.
	local ownInventory = ownKey and ns.GetInventory and ns.GetInventory(ownKey) or nil
	local ownBank = ownInventory and ownInventory.bank or nil
	local own = {
		key = ownKey, name = ownKey and SplitKey(ownKey) or "", isOwn = true,
		bagsTime = ownInventory and ownInventory.bagsTime or nil, bankTime = ownInventory and ownInventory.bankTime or nil,
		entries = {},
	}
	if snapshot then
		own.entries = BuildEntries(known, {
			key = ownKey, name = own.name, isOwn = true,
			owned = function(itemID)
				if ownBank == nil then
					-- No saved bank: the client's own count with every bank part, and nothing saved added (that would count the
					-- account bank twice).
					return GetLiveCount(itemID, true, true)
				end
				return GetLiveCount(itemID, false, accountItems == nil) + SavedCount(ownBank, itemID) + SavedCount(accountItems, itemID)
			end,
			mailCounts = snapshot.counts, mailCod = snapshot.cod,
		}, cache)
	end
	result.entries = own.entries
	result.characters[1] = own

	-- The other characters of this realm (mail cannot cross realms).
	if ownKey and not (settings and settings.showOthers == false) and ns.GetKnownRecipeCharacters and ns.GetKnownRecipes then
		local others = {}
		for _, key in ipairs(ns.GetKnownRecipeCharacters()) do
			local name, realm = SplitKey(key)
			if key ~= ownKey and realm == ownRealm then
				others[#others + 1] = { key = key, name = name, sortKey = name:lower() }
			end
		end
		table.sort(others, function(a, b)
			if a.sortKey ~= b.sortKey then
				return a.sortKey < b.sortKey
			end
			return a.key < b.key
		end)
		-- "No recipes" is about every character that is shown, not only this one.
		if #others > 0 then
			result.noRecipes = false
		end
		for _, other in ipairs(others) do
			local inventory = ns.GetInventory and ns.GetInventory(other.key) or nil
			local bags, bank = inventory and inventory.bags or nil, inventory and inventory.bank or nil
			local theirs = inventory and inventory.mail or nil
			local entries = BuildEntries(ns.GetKnownRecipes(other.key), {
				key = other.key, name = other.name, isOwn = false,
				owned = function(itemID)
					return SavedCount(bags, itemID) + SavedCount(bank, itemID) + SavedCount(accountItems, itemID)
				end,
				theirCounts = theirs and theirs.counts, theirCod = theirs and theirs.cod,
				mailCounts = snapshot and snapshot.counts, mailCod = snapshot and snapshot.cod,
			}, cache)
			if #entries > 0 then
				result.characters[#result.characters + 1] = {
					key = other.key, name = other.name, isOwn = false,
					bagsTime = inventory and inventory.bagsTime or nil, bankTime = inventory and inventory.bankTime or nil,
					mailSeen = theirs ~= nil, mailTime = theirs and theirs.time or nil, mailSentTime = theirs and theirs.sentTime or nil,
					entries = entries,
				}
			end
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local DASH = "\226\128\147"

local function FormatReagent(reagent, isOwn)
	local text = string.format("%s  %d/%d", Escape(reagent.name), reagent.have, reagent.need)
	if reagent.theirMail > 0 then
		text = text .. string.format(" (%d in their mail)", reagent.theirMail)
	end
	if reagent.mail > 0 then
		-- The current character's own mail is just "mail"; for another character it is the mail you have open.
		text = text .. string.format(isOwn and " (%d in mail)" or " (%d in your mail)", reagent.mail)
	end
	if reagent.cod then
		text = text .. " (COD)"
	end
	if reagent.missing > 0 then
		text = text .. string.format(" " .. DASH .. " need %d more", reagent.missing)
	end
	return "|c" .. (reagent.missing > 0 and RED or GREEN) .. text .. "|r"
end

local function FormatStatus(entry)
	if entry.craftable then
		return "|c" .. GREEN .. (entry.needsMail and "Craftable after mail" or "Craftable") .. "|r"
	end
	return "|c" .. ORANGE .. string.format("Missing %d item%s", entry.missing, entry.missing == 1 and "" or "s") .. "|r"
end

local function Ago(timestamp)
	return FormatAge(math.max(0, Now() - timestamp)) .. " ago"
end

-- The grey line under a character's name: how old what is known of its items is.
-- Something the addon has no data for: red, so it stands out as something to fix.
local function NoData(text)
	return "|cffff3030" .. text .. "|r"
end

local function FormatGroupInfo(group, accountTime)
	local parts = {}
	if group.isOwn then
		-- The bags are read live; only the bank and the account bank are saved.
		if group.bankTime then
			parts[#parts + 1] = "bank " .. Ago(group.bankTime)
		end
	else
		parts[#parts + 1] = group.bagsTime and ("bags " .. Ago(group.bagsTime)) or NoData("bags never seen")
		if group.bankTime then
			parts[#parts + 1] = "bank " .. Ago(group.bankTime)
		end
		local mail
		if group.mailTime then
			mail = "mail " .. Ago(group.mailTime)
		else
			mail = NoData("mailbox never seen")
		end
		if group.mailSentTime and (not group.mailTime or group.mailSentTime > group.mailTime) then
			mail = mail .. " (items sent " .. Ago(group.mailSentTime) .. ")"
		end
		parts[#parts + 1] = mail
	end
	if accountTime then
		parts[#parts + 1] = "account bank " .. Ago(accountTime)
	end
	if not group.bankTime then
		parts[#parts + 1] = NoData("bank never seen " .. DASH .. (group.isOwn and " open your bank to include it" or " open the bank on that character"))
	end
	return table.concat(parts, ", ")
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
		if entry.isOwn then
			GameTooltip:AddLine("Double-click to open it in your profession window.", 0.6, 0.8, 1, true)
		else
			local who = entry.knownBy[1] or "another character"
			GameTooltip:AddLine("Known by " .. Escape(who) .. "; log in to that character to craft it.", 0.6, 0.8, 1, true)
			if entry.needsMail then
				GameTooltip:AddLine("Craftable after sending the mail items.", 0.2, 1, 0.2, true)
			end
		end
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

-- How tall the wrapped text of a font string is (a line when the client cannot tell).
local function InfoHeight(fontString)
	if fontString.GetStringHeight then
		local ok, height = pcall(fontString.GetStringHeight, fontString)
		if ok and PlainNumber(height) and height > 0 then
			return math.max(GROUP_INFO_MIN_HEIGHT, math.ceil(height))
		end
	end
	return GROUP_INFO_MIN_HEIGHT
end

-- The name of a character and the line about its items, above its recipes.
local function AcquireGroup(index)
	local group = ui.groups[index]
	if not group then
		group = {}
		group.title = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		group.title:SetWidth(LIST_WIDTH - 4)
		group.title:SetHeight(14)
		group.title:SetJustifyH("LEFT")
		group.title:SetWordWrap(false)
		group.info = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		group.info:SetWidth(LIST_WIDTH - 4) -- no fixed height: it is as tall as the wrapped text
		group.info:SetJustifyH("LEFT")
		group.info:SetJustifyV("TOP")
		group.info:SetWordWrap(true)
		ui.groups[index] = group
	end
	return group
end

-- Fills the window. `data` is ns.GetMailMaterials() when the caller has it already.
RefreshWindow = function(data)
	if not (window and ui) then
		return
	end
	data = data or ns.GetMailMaterials()
	local snapshot = data.snapshot
	local showOthers = not (settings and settings.showOthers == false)

	ui.showOthers:SetChecked(showOthers)
	if snapshot and snapshot.time then
		ui.source:SetText("From your mailbox, " .. Ago(snapshot.time))
	elseif snapshot then
		ui.source:SetText("Your mailbox has not been scanned yet (mail sent to you is counted).")
	else
		ui.source:SetText("Your mailbox has not been scanned yet.")
	end
	ui.partial:SetShown(snapshot ~= nil and snapshot.partial == true)

	local child = ui.scrollChild
	child:SetWidth(LIST_WIDTH)
	local y = 0
	local groupIndex, blockIndex = 0, 0
	for _, character in ipairs(data.characters or {}) do
		if #character.entries > 0 then
			groupIndex = groupIndex + 1
			local group = AcquireGroup(groupIndex)
			group.title:ClearAllPoints()
			group.title:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
			group.title:SetText(Escape(character.name) .. (character.isOwn and " (this character)" or ""))
			group.title:Show()
			group.info:ClearAllPoints()
			group.info:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -(y + 15))
			group.info:SetText(FormatGroupInfo(character, data.accountTime))
			group.info:Show()
			y = y + GROUP_TITLE_HEIGHT + InfoHeight(group.info) + GROUP_INFO_GAP

			for _, entry in ipairs(character.entries) do
				blockIndex = blockIndex + 1
				local block = AcquireBlock(blockIndex)
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
					line:SetText(FormatReagent(reagent, entry.isOwn))
					line:Show()
					y = y + LINE_HEIGHT
				end
				for lineIndex = #entry.reagents + 1, #block.lines do
					block.lines[lineIndex]:Hide()
				end
				y = y + BLOCK_GAP
			end
			y = y + GROUP_GAP
		end
	end
	for index = groupIndex + 1, #ui.groups do
		ui.groups[index].title:Hide()
		ui.groups[index].info:Hide()
	end
	for index = blockIndex + 1, #ui.blocks do
		local block = ui.blocks[index]
		block.entry = nil
		block.header:Hide()
		for _, line in ipairs(block.lines) do
			line:Hide()
		end
	end
	child:SetHeight(math.max(HEADER_HEIGHT, y))

	local empty
	if blockIndex == 0 then
		if data.noRecipes then
			empty = "Open your profession windows once so recipes can be learned."
		elseif not snapshot then
			empty = "Open your mailbox to scan it for recipe materials."
		elseif showOthers then
			empty = "No mail items are used by the recipes of your characters on this realm."
		else
			empty = "No mail items are used by your known recipes."
		end
	end
	ui.emptyText:SetText(empty or "")
	-- Missing data (no recipes learned, mailbox never scanned) is something to fix, so it is red; the rest stays grey.
	if blockIndex == 0 and (data.noRecipes or not snapshot) then
		ui.emptyText:SetTextColor(1, 0.19, 0.19)
	else
		ui.emptyText:SetTextColor(0.5, 0.5, 0.5)
	end
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
	if ns.MakeOpaque then ns.MakeOpaque(window) end
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

	ui = { blocks = {}, groups = {} }

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

	-- Whether the recipes of your other characters on this realm are listed too.
	ui.showOthers = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	ui.showOthers:SetSize(22, 22)
	ui.showOthers:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -46) -- a row of its own, so no text next to it can be cut
	ui.showOthers.Text:SetFontObject("GameFontHighlightSmall")
	ui.showOthers.Text:SetText("Show other characters")
	ui.showOthers:SetChecked(true)
	ui.showOthers:SetScript("OnClick", function(self)
		if settings then
			settings.showOthers = self:GetChecked() and true or false
		end
		RefreshWindow()
	end)
	ui.showOthers:HookScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Show other characters")
			GameTooltip:AddLine("Also list the recipes of your other characters on this realm that can use the mail, counting their saved bags, bank and mail.", 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end
	end)
	ui.showOthers:HookScript("OnLeave", function()
		if GameTooltip then
			GameTooltip:Hide()
		end
	end)

	ui.partial = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.partial:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -70)
	ui.partial:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -70)
	ui.partial:SetHeight(14)
	ui.partial:SetJustifyH("LEFT")
	ui.partial:SetWordWrap(false)
	ui.partial:SetTextColor(1, 0.6, 0.2)
	ui.partial:SetText("Only the first 50 mails are scanned; take some mail to see the rest.")
	ui.partial:Hide()

	-- List. Named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.scroll = CreateFrame("ScrollFrame", SCROLL_NAME, frame, "UIPanelScrollFrameTemplate")
	ui.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -86)
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
	ui.footer:SetText("Double-click one of your recipes to open it in your profession window.")

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

-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data. (The saved mailbox
-- snapshots are validated and migrated by Inventory.lua.)
local function InitData(db)
	if type(db.mailMaterials) ~= "table" then
		db.mailMaterials = {}
	end
	settings = db.mailMaterials
	settings.autoShow = nil -- an earlier version opened the window by itself; it is a command now
	if type(settings.showOthers) ~= "boolean" then
		settings.showOthers = true
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

function ns.InitMailMaterials(db)
	if initialized then
		return
	end
	initialized = true

	InitData(db)

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

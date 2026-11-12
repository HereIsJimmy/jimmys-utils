local addonName, ns = ...

--[[
	Item snapshots of your characters, so the materials window can tell what a character that is not logged in owns.

	Saved data (validated in ns.InitInventory, account-wide):
		JimmysStatWeightsDB.inventory = { ["Name-Realm"] = {
			bags = { [itemID] = quantity }, bagsTime = time(),   -- backpack, bags and the reagent bag
			bank = { [itemID] = quantity }, bankTime = time(),   -- the character's bank tabs (or bank and bank bags)
			mail = { counts = { [itemID] = n }, cod = { [itemID] = true }, time = time(), partial = bool, sentTime = time() },
		} }
		JimmysStatWeightsDB.accountBank = { items = { [itemID] = quantity }, time = time() } -- the account (warband) bank, shared by everyone

	"mail" is the last scan of that character's mailbox (written by MailMaterials.lua while the mailbox is open) plus the items
	you mailed to it since from another character (Mail.lua, ns.RecordSentMail: they raise the counts and set sentTime; a new
	scan of the mailbox replaces everything). A snapshot made only of sent items has no time. Older versions kept the current
	character's scan in JimmysStatWeightsCharDB.mailItems; it is moved here at load.

	Scanning (C_Container, every call through pcall, secret values skipped and never branched on):
	- Bags: container IDs Backpack (0) to NUM_TOTAL_EQUIPPED_BAG_SLOTS (4 bags and the reagent bag, ID 5), rescanned on
	  PLAYER_ENTERING_WORLD and BAG_UPDATE_DELAYED (coalesced: one scan per SCAN_DELAY) and on PLAYER_LOGOUT.
	- Bank: only readable while the bank is open (once BANKFRAME_CLOSED has fired the client says it cannot be viewed). Scanned
	  on BANKFRAME_OPENED, at once on every BAG_UPDATE_DELAYED while it is open (so the last change before it closes is kept),
	  on the next frame after the per-slot events (PLAYERBANKSLOTS_CHANGED, PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED,
	  BANK_TABS_CHANGED, BAG_CONTAINER_UPDATE) and on PLAYER_LOGOUT; nothing is scanned after it closes and the last snapshot
	  is kept. This client has no separate
	  reagent bank: its bank tabs are the containers CharacterBankTab_1..9 (IDs 6 to 14), listed by
	  C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character); without C_Bank the Enum.BagIndex names are tried.
	- Account bank: the tabs AccountBankTab_1..9 (IDs 15 to 23), Enum.BankType.Account, read together with the bank when the
	  open bank can show it (C_Bank.CanViewBank).
	A scan that cannot read anything (loading screens, a closed bank) saves nothing, so an older snapshot is never replaced by
	an empty one.
]]

local SCAN_DELAY = 1 -- seconds; container events come in bursts
local MAX_SLOTS = 300 -- no container has more
local DEFAULT_LAST_BAG = 4
local MAX_TABS = 9
local MAX_ATTACHMENTS_RECORDED = 64

-- Set in ns.InitInventory.
local db, inventory, legacyDb
local initialized = false
local bankOpen = false
local scanPending = false
local bankScanPending = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local IsSecret = issecretvalue or function() return false end

local function PlainNumber(value)
	return not IsSecret(value) and type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

-- A positive whole number that is not a secret value (item IDs and quantities).
local function IsID(value)
	return PlainNumber(value) and value > 0 and value < 2 ^ 31 and value == math.floor(value)
end

local function Now()
	if time then
		return time()
	end
	return os and os.time and os.time() or 0
end

-- "Name-Realm" of the current character and its realm (nil when the client does not say).
local function OwnKey()
	if ns.GetCharacterKey then
		return ns.GetCharacterKey()
	end
	return nil
end

local function Notify()
	if ns.RefreshMailMaterials then
		ns.RefreshMailMaterials()
	end
end

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

-- A map { [itemID] = quantity } as it should be kept (bad entries dropped), or nil when it is not a table.
local function CleanItems(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local items = {}
	for itemID, quantity in pairs(raw) do
		if IsID(itemID) and IsID(quantity) then
			items[itemID] = quantity
		end
	end
	return items
end

local function CleanTime(value)
	if PlainNumber(value) and value >= 0 then
		return value
	end
	return nil
end

-- A saved mailbox snapshot as it should be kept, or nil when it cannot be trusted.
local function CleanMail(raw)
	if type(raw) ~= "table" or type(raw.counts) ~= "table" then
		return nil
	end
	local scanned, sent = CleanTime(raw.time), CleanTime(raw.sentTime)
	if not scanned and not sent then
		return nil
	end
	local counts = CleanItems(raw.counts)
	local cod = {}
	if type(raw.cod) == "table" then
		for itemID, flag in pairs(raw.cod) do
			if flag == true and counts[itemID] then
				cod[itemID] = true
			end
		end
	end
	return { counts = counts, cod = cod, time = scanned, partial = raw.partial == true, sentTime = sent }
end

local function CleanEntry(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local entry = {}
	local bags, bank = CleanItems(raw.bags), CleanItems(raw.bank)
	if bags and CleanTime(raw.bagsTime) then
		entry.bags, entry.bagsTime = bags, raw.bagsTime
	end
	if bank and CleanTime(raw.bankTime) then
		entry.bank, entry.bankTime = bank, raw.bankTime
	end
	entry.mail = CleanMail(raw.mail)
	if entry.bags or entry.bank or entry.mail then
		return entry
	end
	return nil
end

-- The saved record of a character, creating it when asked.
local function GetEntry(key, create)
	if not inventory or type(key) ~= "string" or key == "" then
		return nil
	end
	local entry = inventory[key]
	if not entry and create then
		entry = {}
		inventory[key] = entry
	end
	return entry
end

-- What is saved for a character ("Name-Realm"): { bags, bagsTime, bank, bankTime, mail } (read only), or nil.
function ns.GetInventory(key)
	return GetEntry(key, false)
end

-- The account bank: { items, time } (read only), or nil when it was never seen.
function ns.GetAccountBank()
	return db and db.accountBank or nil
end

-- The saved mailbox of a character: { counts, cod, time, partial, sentTime }, or nil.
function ns.GetMailSnapshot(key)
	local entry = GetEntry(key, false)
	return entry and entry.mail or nil
end

-- Replaces the saved mailbox of a character (nil removes it).
function ns.SetMailSnapshot(key, snapshot)
	if snapshot == nil then
		local entry = GetEntry(key, false)
		if entry then
			entry.mail = nil
			if not (entry.bags or entry.bank) then
				inventory[key] = nil
			end
		end
		return true
	end
	local entry = GetEntry(key, true)
	if not entry then
		return false
	end
	entry.mail = snapshot
	return true
end

-- Removes everything saved for a character. Returns true when there was something.
function ns.ForgetInventory(key)
	if inventory and type(key) == "string" and inventory[key] then
		inventory[key] = nil
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- Mail sent to your own characters
--------------------------------------------------------------------------------

local function SplitKey(key)
	local name, realm = key:match("^([^%-]+)%-(.+)$")
	if name then
		return name, realm
	end
	return key, nil
end

-- A realm as the client writes it into a key: no spaces or hyphens, any case.
local function NormalizeRealm(realm)
	if realm == nil then
		return nil
	end
	return (realm:gsub("[%s%-]", ""):lower())
end

-- The keys of every character this addon has saved something for (items or mail), sorted.
function ns.GetInventoryCharacters()
	local list = {}
	for key in pairs(inventory or {}) do
		list[#list + 1] = key
	end
	table.sort(list)
	return list
end

-- The character ("Name-Realm") on the current realm that a letter to `recipient` ("Name" or "Name-Realm", any case) goes to,
-- among the characters this addon knows. Never the current character.
function ns.FindOwnCharacter(recipient)
	if IsSecret(recipient) or type(recipient) ~= "string" then
		return nil
	end
	local ownKey, ownRealm = OwnKey()
	local name, realm = SplitKey((recipient:gsub("^%s+", ""):gsub("%s+$", "")))
	if name == "" then
		return nil
	end
	local ownNormalized = NormalizeRealm(ownRealm)
	if realm and (not ownNormalized or NormalizeRealm(realm) ~= ownNormalized) then
		return nil
	end

	local candidates = {}
	for key in pairs(inventory or {}) do
		candidates[key] = true
	end
	if ns.GetKnownRecipeCharacters then
		for _, key in ipairs(ns.GetKnownRecipeCharacters()) do
			candidates[key] = true
		end
	end
	local found
	for key in pairs(candidates) do
		local keyName, keyRealm = SplitKey(key)
		local sameRealm = NormalizeRealm(keyRealm) == ownNormalized
		if key ~= ownKey and sameRealm and keyName:lower() == name:lower() then
			if not found or key < found then
				found = key
			end
		end
	end
	return found
end

-- Items you just mailed to `recipient` ({ [itemID] = quantity }): when that is one of your own characters on this realm they
-- are added to what is saved for its mailbox (marked COD when the letter asked for cash on delivery). Returns the character's
-- key, or nil when nothing was recorded.
function ns.RecordSentMail(recipient, items, cod)
	if not inventory or type(items) ~= "table" then
		return nil
	end
	local key = ns.FindOwnCharacter(recipient)
	if not key then
		return nil
	end
	local added = {}
	local total = 0
	for itemID, quantity in pairs(items) do
		if IsID(itemID) and IsID(quantity) and total < MAX_ATTACHMENTS_RECORDED then
			added[itemID] = quantity
			total = total + 1
		end
	end
	if total == 0 then
		return nil
	end
	local entry = GetEntry(key, true)
	local mail = entry.mail
	if not mail then
		mail = { counts = {}, cod = {}, partial = false }
		entry.mail = mail
	end
	for itemID, quantity in pairs(added) do
		mail.counts[itemID] = (mail.counts[itemID] or 0) + quantity
		if cod == true then
			mail.cod[itemID] = true
		end
	end
	mail.sentTime = Now()
	Notify()
	return key
end

--------------------------------------------------------------------------------
-- Reading containers
--------------------------------------------------------------------------------

local function ContainerApiReady()
	return C_Container ~= nil and type(C_Container.GetContainerNumSlots) == "function"
		and type(C_Container.GetContainerItemInfo) == "function"
end

-- Adds the items of one container to `items`. Returns true when the container could be read (it exists and has slots).
local function ReadContainer(bagID, items)
	local ok, numSlots = pcall(C_Container.GetContainerNumSlots, bagID)
	if not ok or not PlainNumber(numSlots) or numSlots <= 0 then
		return false
	end
	numSlots = math.min(math.floor(numSlots), MAX_SLOTS)
	for slot = 1, numSlots do
		local okInfo, info = pcall(C_Container.GetContainerItemInfo, bagID, slot)
		if okInfo and type(info) == "table" and not IsSecret(info) then
			local itemID, count = info.itemID, info.stackCount
			if IsID(itemID) and IsID(count) then
				items[itemID] = (items[itemID] or 0) + count
			end
		end
	end
	return true
end

local function GetBagIDs()
	local first = Enum and Enum.BagIndex and Enum.BagIndex.Backpack
	if not PlainNumber(first) then
		first = 0
	end
	local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS
	if not IsID(last) then
		last = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
	end
	if not IsID(last) then
		last = IsID(NUM_BAG_SLOTS) and NUM_BAG_SLOTS or DEFAULT_LAST_BAG
	end
	local ids = {}
	for id = first, last do
		ids[#ids + 1] = id
	end
	return ids
end

-- The container IDs of the purchased bank tabs of a bank type ("Character" or "Account"). Returns the list, or nil when the
-- client cannot say or the bank cannot be viewed.
local function GetTabIDs(typeName)
	local bankType = Enum and Enum.BankType and Enum.BankType[typeName]
	if C_Bank and bankType ~= nil then
		if type(C_Bank.CanViewBank) == "function" then
			local ok, can = pcall(C_Bank.CanViewBank, bankType)
			if ok and not IsSecret(can) and can == false then
				return nil
			end
		end
		if type(C_Bank.FetchPurchasedBankTabIDs) == "function" then
			local ok, list = pcall(C_Bank.FetchPurchasedBankTabIDs, bankType)
			if ok and type(list) == "table" and not IsSecret(list) then
				local ids = {}
				for _, id in ipairs(list) do
					if IsID(id) then
						ids[#ids + 1] = id
					end
				end
				return ids
			end
		end
	end
	-- No C_Bank: the tabs that the BagIndex enum names (CharacterBankTab_1 .. 9).
	local indexes = Enum and Enum.BagIndex
	if not indexes then
		return nil
	end
	local ids, named = {}, false
	for tab = 1, MAX_TABS do
		local id = indexes[typeName .. "BankTab_" .. tab]
		if id ~= nil then
			named = true
			if IsID(id) then
				ids[#ids + 1] = id
			end
		end
	end
	return named and ids or nil
end

-- Reads the tabs of a bank type. Returns items, read (how many containers could be read) and expected (how many tabs were
-- listed), or nil when this client has no such bank.
local function ReadBank(typeName)
	local ids = GetTabIDs(typeName)
	if not ids then
		return nil
	end
	local items, read = {}, 0
	for _, id in ipairs(ids) do
		if ReadContainer(id, items) then
			read = read + 1
		end
	end
	return items, read, #ids
end

-- Reads the bags of the current character and saves them. Returns true when they were saved.
function ns.ScanBags()
	local key = OwnKey()
	if not (inventory and key and ContainerApiReady()) then
		return false
	end
	local items, readable = {}, 0
	for _, id in ipairs(GetBagIDs()) do
		if ReadContainer(id, items) then
			readable = readable + 1
		end
	end
	-- The backpack always exists; without it the client is not ready (loading screen) and nothing is saved.
	if readable == 0 then
		return false
	end
	local entry = GetEntry(key, true)
	entry.bags, entry.bagsTime = items, Now()
	return true
end

-- Reads the bank (and the account bank) and saves them. Only while the bank is open (it cannot be read afterwards, and the
-- client then says it cannot be viewed). An empty list of tabs is a real answer; tabs that cannot be read are not.
-- Returns true when something was saved.
function ns.ScanBank()
	if not (bankOpen and inventory and ContainerApiReady()) then
		return false
	end
	local saved = false
	local key = OwnKey()

	local items, read, expected = ReadBank("Character")
	if items and key and (read > 0 or expected == 0) then
		local entry = GetEntry(key, true)
		entry.bank, entry.bankTime = items, Now()
		saved = true
	end

	items, read, expected = ReadBank("Account")
	if items and (read > 0 or expected == 0) then
		db.accountBank = { items = items, time = Now() }
		saved = true
	end
	return saved
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function ScanBankNow()
	bankScanPending = false
	if ns.ScanBank() then
		Notify()
	end
end

local function RunScan()
	scanPending = false
	ns.ScanBags()
end

-- Container changes come in bursts: the first one starts a timer and the scan reads whatever is there when it fires.
local function ScheduleScan()
	if scanPending then
		return
	end
	scanPending = true
	if C_Timer and C_Timer.After then
		C_Timer.After(SCAN_DELAY, RunScan)
	else
		RunScan()
	end
end

-- Events about single bank slots arrive in storms (one per slot): the bank is read once, on the next frame. The bank cannot
-- be read after it closes, so none of this waits for the bags' timer.
local function ScheduleBankScan()
	if not bankOpen or bankScanPending then
		return
	end
	bankScanPending = true
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function()
			if bankScanPending then
				ScanBankNow()
			end
		end)
	else
		ScanBankNow()
	end
end

local function OnEvent(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		bankOpen, bankScanPending = false, false
		ns.MigrateLegacyMail()
		ScheduleScan()
	elseif event == "BAG_UPDATE_DELAYED" then
		-- Fires once at the end of a burst: while the bank is open it is read at once, so the last change before it closes is kept.
		if bankOpen then
			ScanBankNow()
		end
		ScheduleScan()
	elseif event == "BANKFRAME_OPENED" then
		bankOpen = true
		ScanBankNow()
		ScheduleScan()
	elseif event == "BANKFRAME_CLOSED" then
		bankOpen, bankScanPending = false, false
	elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED"
		or event == "BANK_TABS_CHANGED" or event == "BAG_CONTAINER_UPDATE" then
		ScheduleBankScan()
	elseif event == "PLAYER_LOGOUT" then
		ns.ScanBags()
		if bankOpen then
			ScanBankNow()
		end
	end
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- Has the client told the realm yet? (Without it the character's key would be a fallback that Recipes.lua does not use.)
local function RealmKnown()
	if type(GetNormalizedRealmName) ~= "function" then
		local key = OwnKey()
		return key ~= nil and key:find("-", 1, true) ~= nil
	end
	local ok, realm = pcall(GetNormalizedRealmName)
	return ok and not IsSecret(realm) and type(realm) == "string" and realm ~= ""
end

-- Moves the mailbox snapshot older versions kept per character into the account-wide record. It waits until the realm is
-- known (PLAYER_ENTERING_WORLD asks again) and leaves the old snapshot where it is until then. When the character already has
-- a snapshot made of sent items only, the old scan is the base and the sent items are added on top; a snapshot with a scan
-- time that is not older than the old one is kept. Returns true when it moved.
function ns.MigrateLegacyMail()
	local characterDb = legacyDb
	if not (inventory and type(characterDb) == "table" and characterDb.mailItems ~= nil) then
		return false
	end
	local clean = CleanMail(characterDb.mailItems)
	if not clean then
		characterDb.mailItems = nil
		return false
	end
	local key = OwnKey()
	if not (key and RealmKnown()) then
		return false
	end
	local entry = GetEntry(key, true)
	local existing = entry.mail
	if not existing then
		entry.mail = clean
	elseif not existing.time then
		for itemID, quantity in pairs(existing.counts) do
			clean.counts[itemID] = (clean.counts[itemID] or 0) + quantity
			if existing.cod[itemID] then
				clean.cod[itemID] = true
			end
		end
		clean.sentTime = existing.sentTime
		entry.mail = clean
	elseif clean.time and existing.time < clean.time then
		entry.mail = clean
	end
	characterDb.mailItems = nil
	return true
end


-- Fills missing fields and drops malformed ones so the rest of the feature can trust the data.
local function InitData(database, characterDb)
	db = database
	if type(db.inventory) ~= "table" then
		db.inventory = {}
	end
	inventory = db.inventory
	for key, raw in pairs(inventory) do
		if type(key) ~= "string" or key == "" then
			inventory[key] = nil
		else
			inventory[key] = CleanEntry(raw)
		end
	end

	local bank = db.accountBank
	if type(bank) == "table" and type(bank.items) == "table" and CleanTime(bank.time) then
		db.accountBank = { items = CleanItems(bank.items), time = bank.time }
	else
		db.accountBank = nil
	end

	legacyDb = characterDb
	ns.MigrateLegacyMail()
end

function ns.InitInventory(database, characterDb)
	if initialized then
		return
	end
	initialized = true

	InitData(database, characterDb)

	local driver = CreateFrame("Frame")
	-- An event this client does not have must not stop the others from being registered.
	for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
		"PLAYERBANKSLOTS_CHANGED", "PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", "BANK_TABS_CHANGED", "BAG_CONTAINER_UPDATE",
		"PLAYER_LOGOUT" }) do
		pcall(driver.RegisterEvent, driver, event)
	end
	driver:SetScript("OnEvent", OnEvent)
end

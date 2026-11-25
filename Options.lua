local addonName, ns = ...

-- Options window: a small movable frame with five tabs, one per feature and a last one for the settings profiles, each starting with
-- the checkbox that switches the feature on or off. "Stat Weights" holds the scale
-- controls (a scale is what the code calls a profile; Import and Export read and write Pawn scale tags), the display settings (and the check box of the auction house score columns) and the list of stats that have a weight; "Range Check"
-- holds the settings of the range indicator; "Recipes" explains the recipe lookup, shows
-- its key binding and what is saved, switches the crafting profit (Auctionator prices) and the movable profession window on and off and can forget the saved recipes; "Mail" switches the
-- mail features (the recent mail recipients list and the "materials in your mail" window) on, clears the list and mentions the
-- "materials in your mail" command; "Profiles" keeps named sets of the settings of the whole addon (not the scales): one is used by each
-- character, switched with a dropdown, created, copied, renamed, deleted, imported and exported as text (SettingsProfiles.lua; the dialog of
-- the Pawn scale tags serves for the text). The Recipes and Mail tabs also list the professions of the saved recipes with a check
-- box each, to hide a profession from the recipes window or the materials window. A strip under the pages holds the check box of the minimap button. It is built lazily
-- the first time it is opened and refreshed from the saved data every time it
-- is shown, because profile switches change every weight and new stats can be
-- detected on items between two openings. Settings > AddOns keeps a tiny canvas
-- entry whose only job is to open the window.
-- The window is resizable: a grip in the bottom right corner (the chat frame's look) sizes it, its default size is its minimum and the
-- maximum is twice that or what the screen holds (ns.GetWindowBounds); the size is saved in the account data (ns.SetOptionsSize) and a
-- double-click on the grip goes back to the default size. Everything is anchored to the edges of the window, so the scroll lists (the
-- weights, the Recipes page) grow with it and the controls stay where they are; what is sized by a number (the width of the lists and
-- of the texts in them, the columns of the profession check boxes) is set again when the width changes (ApplyWidth).

local FRAME_NAME = "JimmysUtilsFrame"
local PANEL_NAME = "JimmysUtilsOptionsPanel"
local SCROLL_NAME = "JimmysUtilsListScroll"
local CATEGORY_NAME = "Jimmy's Utils"

local FRAME_WIDTH = ns.OPTIONS_WIDTH or 400 -- the default size is also the smallest one: the grip in the bottom right corner makes the window larger
local FRAME_HEIGHT = ns.OPTIONS_HEIGHT or 510 -- 458 px of page, the tab area above it and the footer below it
local FOOTER_HEIGHT = 30 -- the strip under the pages holds what belongs to no tab (the minimap button check box)
local TAB_AREA = 22 -- the pages start this far below the top of the window; the tab buttons sit above them
local TAB_BUTTON_WIDTH = 72 -- used when a label can't be measured: 12 + 5 x 72 + 4 x 4 px fit in the 400 px window
local TAB_BUTTON_MIN_WIDTH = 52 -- tabs fit their label: about 86 + 86 + 56 + 52 + 60 px plus gaps for the five tabs, inside 400 px
local TAB_BUTTON_PADDING = 16 -- (if the labels are wider than that the row is squeezed to the window, see BuildWindow)
local TAB_BUTTON_X = 12 -- clear of the window border
local TAB_BUTTON_HEIGHT = 22
local LIST_WIDTH = 350 -- scroll frame width at the default window size (frame minus margins and the scroll bar)
local LIST_MARGIN = FRAME_WIDTH - LIST_WIDTH
local ROW_HEIGHT = 20
local EDIT_WIDTH = 60
local WEIGHT_MAX_LETTERS = 24
local REMOVE_SIZE = 18
local ADD_MENU_HEIGHT = 300
local DEFAULT_ADD_WEIGHT = "1"

local BREAKDOWN_OPTIONS = {
	{ value = "always", label = "Always" },
	{ value = "shift", label = "Hold Shift" },
	{ value = "alt", label = "Hold Alt" },
	{ value = "ctrl", label = "Hold Ctrl" },
	{ value = "never", label = "Never" },
}

local panel -- the Settings > AddOns canvas frame (created in ns.InitOptions)
local window -- the options window, nil until it is first opened
local ui -- widget table, nil until the window has been built
local initialized = false
local deleteArmed = false -- the Delete button is waiting for its confirming click
local deleteToken = 0 -- invalidates the pending auto-disarm timer
local resetArmed = false -- the same for the Reset weights button
local resetToken = 0
local forgetArmed = false -- the same for the Forget saved recipes button
local forgetToken = 0
local profileDeleteArmed = false -- the same for the Delete button of the Profiles tab
local profileDeleteToken = 0
local needsPrune = false -- a weight was typed as 0; its row goes once no box is focused

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local CONFIRM_SECONDS = 4
local FORGET_LABEL = "Forget saved recipes"

-- Compact number format: at most 6 decimals, trailing zeros dropped.
local function FormatNumber(value)
	if type(value) ~= "number" or value == 0 then
		return "0"
	end
	local text = string.format("%.6f", value)
	text = text:gsub("0+$", "")
	text = text:gsub("%.$", "")
	-- Too small for 6 decimals (or too large to be typed back): scientific
	-- notation, so a tiny weight never looks like 0.
	if text == "0" or text == "-0" or text == "" or #text > 20 then
		return (string.format("%.3g", value))
	end
	return text
end

local function ParseNumber(text)
	text = (text or ""):gsub(",", "."):gsub("^%s+", ""):gsub("%s+$", "")
	local value = tonumber(text)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

local function SetStatus(message)
	if ui then
		ui.status:SetText(message or "")
	end
end

-- The width of the scroll lists (and what is sized from it) follows the width of the window; the rest of the layout is anchored to its edges.
local function ListWidth()
	return (window and window:GetWidth() or FRAME_WIDTH) - LIST_MARGIN
end

local function SetRecipesStatus(message)
	if ui and ui.recipesStatus then
		ui.recipesStatus:SetText(message or "")
	end
end

local PROFESSION_WINDOW_RELOAD = "Takes effect after /reload: the profession window goes back to Blizzard's layout."
ns.PROFESSION_WINDOW_RELOAD = PROFESSION_WINDOW_RELOAD -- the settings profiles say the same when they turn the option off

-- Back to the unarmed Delete, Reset weights and Forget saved recipes buttons. Does nothing
-- (and keeps any other status message) when none of them is armed.
local function DisarmConfirms()
	if not (deleteArmed or resetArmed or forgetArmed or profileDeleteArmed) then
		return
	end
	if deleteArmed then
		deleteArmed = false
		deleteToken = deleteToken + 1
	end
	if resetArmed then
		resetArmed = false
		resetToken = resetToken + 1
	end
	if forgetArmed then
		forgetArmed = false
		forgetToken = forgetToken + 1
	end
	if profileDeleteArmed then
		profileDeleteArmed = false
		profileDeleteToken = profileDeleteToken + 1
	end
	if ui then
		ui.deleteButton:SetText("Delete")
		ui.resetButton:SetText("Reset weights")
		SetStatus(nil)
		if ui.forgetButton then
			ui.forgetButton:SetText(FORGET_LABEL)
			SetRecipesStatus(nil)
		end
		if ui.profilesDelete then
			ui.profilesDelete:SetText("Delete")
			if ui.profilesStatus then
				ui.profilesStatus:SetText("")
			end
		end
	end
end

local function ShowTooltip(owner, title, detail)
	if not GameTooltip then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(title, 1, 1, 1)
	if detail then
		GameTooltip:AddLine(detail, 0.7, 0.7, 0.7, true)
	end
	GameTooltip:Show()
end

local function HideTooltip()
	if GameTooltip then
		GameTooltip:Hide()
	end
end

--------------------------------------------------------------------------------
-- Weight rows (pooled)
--------------------------------------------------------------------------------

local LayoutWeights -- defined below, the weight boxes call back into it

local function AnyWeightFocus()
	if not ui then
		return false
	end
	for _, row in ipairs(ui.rows) do
		if row.edit:HasFocus() then
			return true
		end
	end
	return false
end

-- Drops the rows whose weight was typed as 0. Waits while a box is being edited,
-- so a row never moves away under a box the user is about to type in.
local function TryPrune()
	if needsPrune and ui and window and window:IsShown() and not AnyWeightFocus() then
		LayoutWeights()
	end
end

local function RequestPrune()
	if C_Timer and C_Timer.After then
		-- One frame later, so a click from this box into another has settled.
		C_Timer.After(0, TryPrune)
	else
		TryPrune()
	end
end

-- A weight box remembers which stat and profile it was focused for, and only
-- writes if the user actually typed, so a stale box can never touch another
-- profile/stat and merely focusing a box never rewrites (rounds) a weight.
local function CommitWeight(edit)
	local key, profile = edit.focusKey, edit.focusProfile
	if edit.dirty and key and profile == ns.GetActiveProfileName() then
		local value = ParseNumber(edit:GetText())
		if value and value ~= ns.GetWeight(key) then
			ns.SetWeight(key, value)
			if value == 0 then
				needsPrune = true
			end
		end
	end
	edit.dirty = false
	edit.focusKey, edit.focusProfile = nil, nil
	-- Re-display the normalized stored value (also reverts invalid/stale input).
	local rowKey = edit.statKey
	if rowKey then
		edit:SetText(FormatNumber(ns.GetWeight(rowKey)))
		edit:SetCursorPosition(0)
	end
	if needsPrune then
		RequestPrune()
	end
end

local function RevertWeight(edit)
	edit.dirty = false
	local key = edit.statKey
	if key then
		edit:SetText(FormatNumber(ns.GetWeight(key)))
		edit:SetCursorPosition(0)
	end
end

-- Drop the focus of any weight box (committing a typed value in the context it
-- was typed in). Call before the window changes the data under the boxes.
local function ClearWeightFocus()
	if not ui then
		return
	end
	for _, row in ipairs(ui.rows) do
		if row.edit:HasFocus() then
			row.edit:ClearFocus()
		end
	end
end

-- Sets a stat's weight to 0, which takes its row out of the list.
local function RemoveStat(key)
	if not key then
		return
	end
	ClearWeightFocus()
	DisarmConfirms()
	ns.SetWeight(key, 0)
	LayoutWeights()
end

local function AcquireRow(index)
	local row = ui.rows[index]
	if row then
		return row
	end

	local child = ui.scrollChild
	row = {}

	row.frame = CreateFrame("Frame", nil, child)
	row.frame:SetHeight(ROW_HEIGHT)
	row.frame:EnableMouse(true)

	row.remove = CreateFrame("Button", nil, row.frame, "UIPanelCloseButtonNoScripts")
	row.remove:SetSize(REMOVE_SIZE, REMOVE_SIZE)
	row.remove:SetPoint("RIGHT", row.frame, "RIGHT", -2, 0)
	-- The template sits on a very high frame level; keep it with its row.
	row.remove:SetFrameLevel(row.frame:GetFrameLevel() + 2)

	row.edit = CreateFrame("EditBox", nil, row.frame, "InputBoxTemplate")
	row.edit:SetSize(EDIT_WIDTH, 20)
	row.edit:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
	row.edit:SetAutoFocus(false)
	row.edit:SetMaxLetters(WEIGHT_MAX_LETTERS)
	row.edit:SetTextInsets(2, 2, 0, 0)
	-- HookScript keeps any handler the template already installs.
	row.edit:HookScript("OnEditFocusGained", function(self)
		self.focusKey = self.statKey
		self.focusProfile = ns.GetActiveProfileName()
		self.dirty = false
	end)
	row.edit:HookScript("OnTextChanged", function(self, userInput)
		if userInput then
			self.dirty = true
		end
	end)
	row.edit:SetScript("OnEnterPressed", function(self)
		CommitWeight(self)
		self:ClearFocus()
	end)
	row.edit:SetScript("OnEscapePressed", function(self)
		RevertWeight(self)
		self:ClearFocus()
	end)
	-- HookScript keeps the template's own focus-lost handler (clears the highlight).
	row.edit:HookScript("OnEditFocusLost", CommitWeight)

	row.label = row.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.label:SetPoint("LEFT", row.frame, "LEFT", 4, 0)
	row.label:SetPoint("RIGHT", row.edit, "LEFT", -10, 0)
	row.label:SetJustifyH("LEFT")
	row.label:SetJustifyV("MIDDLE")
	row.label:SetWordWrap(false)
	row.label:SetHeight(ROW_HEIGHT)

	row.remove:SetScript("OnClick", function()
		RemoveStat(row.edit.statKey)
	end)
	row.remove:SetScript("OnEnter", function(self)
		ShowTooltip(self, "Remove", "Sets this weight to 0 and takes the stat off the list.")
	end)
	row.remove:SetScript("OnLeave", HideTooltip)

	-- The whole row explains itself: the label may be cut short.
	row.frame:SetScript("OnEnter", function(self)
		local key = row.edit.statKey
		if key then
			ShowTooltip(self, ns.GetStatLabel(key), key)
		end
	end)
	row.frame:SetScript("OnLeave", HideTooltip)

	ui.rows[index] = row
	return row
end

-- Ordered list of stat keys that belong to a group.
local function GetGroupKeys(groupID)
	local keys = {}
	if groupID == "detected" then
		for _, key in ipairs(ns.GetDiscoveredKeys() or {}) do
			keys[#keys + 1] = key
		end
	else
		for _, stat in ipairs(ns.STATS or {}) do
			if stat.group == groupID then
				keys[#keys + 1] = stat.key
			end
		end
	end
	return keys
end

-- Keys with a non-zero weight in the active profile: group order, then the stat
-- list order, detected stats last (by label). Weights on keys the addon no
-- longer lists anywhere come last so they can still be removed.
local function GetWeightedKeys()
	local weights = ns.GetActiveProfile().weights
	local keys, listed = {}, {}
	for _, group in ipairs(ns.STAT_GROUPS or {}) do
		for _, key in ipairs(GetGroupKeys(group.id)) do
			if not listed[key] and (weights[key] or 0) ~= 0 then
				listed[key] = true
				keys[#keys + 1] = key
			end
		end
	end

	local extra = {}
	for key, value in pairs(weights) do
		if not listed[key] and value ~= 0 then
			extra[#extra + 1] = key
		end
	end
	table.sort(extra, function(a, b)
		local la, lb = ns.GetStatLabel(a):lower(), ns.GetStatLabel(b):lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	for _, key in ipairs(extra) do
		keys[#keys + 1] = key
	end
	return keys
end

-- Re-lay out the pooled rows for the current data.
LayoutWeights = function()
	if not ui then
		return
	end
	needsPrune = false

	local child = ui.scrollChild
	child:SetWidth(ListWidth())

	local keys = GetWeightedKeys()
	ui.listKeys = keys
	for i, key in ipairs(keys) do
		local row = AcquireRow(i)
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row.frame:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)
		row.label:SetText(ns.GetStatLabel(key))

		-- A focused box that now stands for another stat or profile must
		-- commit (or revert) in its old context before it is reused.
		if row.edit:HasFocus()
			and (row.edit.statKey ~= key or row.edit.focusProfile ~= ns.GetActiveProfileName()) then
			row.edit:ClearFocus()
		end
		row.edit.statKey = key
		-- Do not overwrite what the user is typing right now.
		if not row.edit:HasFocus() then
			row.edit:SetText(FormatNumber(ns.GetWeight(key)))
			row.edit:SetCursorPosition(0)
		end
		row.frame:Show()
	end

	for i = #keys + 1, #ui.rows do
		local row = ui.rows[i]
		if row.edit:HasFocus() then
			row.edit:ClearFocus()
		end
		row.edit.statKey = nil
		row.frame:Hide()
	end

	if #keys == 0 then
		ui.emptyText:Show()
	else
		ui.emptyText:Hide()
	end
	child:SetHeight(math.max(ROW_HEIGHT, #keys * ROW_HEIGHT))
end

--------------------------------------------------------------------------------
-- Profile row
--------------------------------------------------------------------------------

local function RefreshProfileButtons()
	local count = #ns.GetProfileNames()
	ui.deleteButton:SetEnabled(count > 1)
end

-- The "Show in tooltip" check box follows the active profile; the dropdown marks hidden profiles.
local function RefreshProfileShown()
	ui.profileShown:SetChecked(ns.IsProfileShown(ns.GetActiveProfileName()) and true or false)
	ui.profileDropdown:GenerateMenu()
end

-- The stat picked in the Add dropdown stops being a candidate once it has a
-- weight (another profile, a reset, a slash command).
local function RefreshAddSelection()
	if ui.selectedKey and ns.GetWeight(ui.selectedKey) ~= 0 then
		ui.selectedKey = nil
	end
	ui.addDropdown:GenerateMenu()
end

-- Refresh everything that depends on which profile is active.
local function RefreshProfileDependent()
	DisarmConfirms()
	RefreshProfileShown()
	RefreshProfileButtons()
	RefreshAddSelection()
	LayoutWeights()
end

local function CreateOrCopyProfile(copyActive)
	ClearWeightFocus()
	DisarmConfirms()
	local name = ui.nameBox:GetText() or ""
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		SetStatus("Type a name for the new scale first.")
		return
	end

	local ok, err = ns.CreateProfile(name, copyActive and ns.GetActiveProfileName() or nil)
	if ok then
		ok, err = ns.SetActiveProfile(name)
	end
	if not ok then
		SetStatus(err or "Could not create the scale.")
		return
	end

	SetStatus(nil)
	ui.nameBox:SetText("")
	ui.nameBox:ClearFocus()
	RefreshProfileDependent()
end

-- The Rename button: the active scale gets the name typed in the box.
local function RenameActiveProfile()
	ClearWeightFocus()
	DisarmConfirms()
	local name = ui.nameBox:GetText() or ""
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		SetStatus("Type the new name of the scale first.")
		return
	end

	local ok, err = ns.RenameProfile(ns.GetActiveProfileName(), name)
	if not ok then
		SetStatus(err or "Could not rename the scale.")
		return
	end

	SetStatus(nil)
	ui.nameBox:SetText("")
	ui.nameBox:ClearFocus()
	RefreshProfileDependent()
end

-- Two-step delete: the first click arms the button, a second click deletes.
local function DeleteActiveProfile()
	local name = ns.GetActiveProfileName()
	if not deleteArmed then
		DisarmConfirms()
		deleteArmed = true
		deleteToken = deleteToken + 1
		ui.deleteButton:SetText("Confirm?")
		SetStatus(string.format('Click again to delete scale "%s".', tostring(name)))
		if C_Timer and C_Timer.After then
			local token = deleteToken
			C_Timer.After(CONFIRM_SECONDS, function()
				if deleteArmed and deleteToken == token then
					DisarmConfirms()
				end
			end)
		end
		return
	end

	DisarmConfirms()
	ClearWeightFocus()
	local ok, err = ns.DeleteProfile(name)
	if not ok then
		SetStatus(err or "Could not delete the scale.")
		return
	end
	SetStatus(nil)
	RefreshProfileDependent()
end

-- Same two-step confirmation for resetting the weights of the active profile.
local function ResetActiveWeights()
	if not resetArmed then
		DisarmConfirms()
		resetArmed = true
		resetToken = resetToken + 1
		ui.resetButton:SetText("Confirm?")
		SetStatus(string.format('Click again to reset the weights of scale "%s".', tostring(ns.GetActiveProfileName())))
		if C_Timer and C_Timer.After then
			local token = resetToken
			C_Timer.After(CONFIRM_SECONDS, function()
				if resetArmed and resetToken == token then
					DisarmConfirms()
				end
			end)
		end
		return
	end

	DisarmConfirms()
	ClearWeightFocus()
	ns.ResetActiveProfile()
	SetStatus(nil)
	RefreshProfileDependent()
end

--------------------------------------------------------------------------------
-- Add a stat
--------------------------------------------------------------------------------

-- Fills the Add dropdown: every stat whose weight is 0, under its group title.
local function BuildAddMenu(_, rootDescription)
	rootDescription:SetScrollMode(ADD_MENU_HEIGHT)
	local weights = ns.GetActiveProfile().weights
	for _, group in ipairs(ns.STAT_GROUPS or {}) do
		local free = {}
		for _, key in ipairs(GetGroupKeys(group.id)) do
			if (weights[key] or 0) == 0 then
				free[#free + 1] = key
			end
		end
		if #free > 0 then
			rootDescription:CreateTitle(tostring(group.label or group.id))
			for _, key in ipairs(free) do
				rootDescription:CreateRadio(ns.GetStatLabel(key), function(statKey)
					return ui and ui.selectedKey == statKey
				end, function(statKey)
					DisarmConfirms()
					ui.selectedKey = statKey
				end, key)
			end
		end
	end
end

local function AddSelectedStat()
	ClearWeightFocus()
	DisarmConfirms()
	local key = ui.selectedKey
	if not key then
		SetStatus("Pick a stat to add first.")
		ns.Print("Pick a stat in the Add dropdown first.")
		return
	end

	-- The weight appeared meanwhile (profile switch, slash command): never overwrite it.
	if ns.GetWeight(key) ~= 0 then
		RefreshAddSelection()
		SetStatus(ns.GetStatLabel(key) .. " already has a weight.")
		ns.Print(ns.GetStatLabel(key) .. " already has a weight in this scale; edit it in the list.")
		return
	end

	local value = ParseNumber(ui.addBox:GetText())
	if not value or value == 0 then
		SetStatus("Type a weight other than 0.")
		ns.Print("A weight must be a number other than 0 (" .. ns.GetStatLabel(key) .. " was not added).")
		return
	end

	ns.SetWeight(key, value)
	SetStatus(nil)
	ui.selectedKey = nil
	ui.addBox:SetText(DEFAULT_ADD_WEIGHT)
	ui.addBox:ClearFocus()
	ui.addDropdown:GenerateMenu()
	LayoutWeights()

	-- Show the new row; the scroll range is only updated a frame later.
	local index
	for i, listed in ipairs(ui.listKeys or {}) do
		if listed == key then
			index = i
			break
		end
	end
	if index then
		local function ScrollToRow()
			if not (ui and ui.scroll) then
				return
			end
			local range = ui.scroll:GetVerticalScrollRange() or 0
			ui.scroll:SetVerticalScroll(math.max(0, math.min(range, (index - 3) * ROW_HEIGHT)))
		end
		if C_Timer and C_Timer.After then
			C_Timer.After(0, ScrollToRow)
		else
			ScrollToRow()
		end
	end
end

--------------------------------------------------------------------------------
-- Widget factories
--------------------------------------------------------------------------------

local function CreateLabel(parent, text, x, y)
	local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	label:SetText(text)
	return label
end

local function CreateCheckbox(parent, text, x, y, settingName, tooltip)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(26, 26)
	check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	check.Text:SetFontObject("GameFontHighlightSmall")
	check.Text:SetText(text)
	check:SetScript("OnClick", function(self)
		DisarmConfirms()
		ns.SetSetting(settingName, self:GetChecked() and true or false)
	end)
	if tooltip then
		check:HookScript("OnEnter", function(self)
			ShowTooltip(self, text, tooltip)
		end)
		check:HookScript("OnLeave", HideTooltip)
	end
	check.settingName = settingName
	return check
end

-- Radio dropdown over a list of { value, label } options bound to a setting.
local function CreateSettingDropdown(parent, x, y, width, settingName, options, getValue)
	local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	dropdown:SetWidth(width)
	dropdown:SetDefaultText("-")
	dropdown:SetupMenu(function(_, rootDescription)
		for _, option in ipairs(options) do
			rootDescription:CreateRadio(option.label, function(value)
				return getValue() == value
			end, function(value)
				DisarmConfirms()
				ns.SetSetting(settingName, value)
			end, option.value)
		end
	end)
	return dropdown
end

local function CreateButton(parent, text, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 24)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	return button
end

--------------------------------------------------------------------------------
-- Tabs and the Range Check page
--------------------------------------------------------------------------------

local TABS = {
	{ id = "stats", label = "Stat Weights" },
	{ id = "range", label = "Range Check" },
	{ id = "recipes", label = "Recipes" },
	{ id = "mail", label = "Mail" },
	{ id = "profiles", label = "Profiles" }, -- always the last one
}

local SPELL_ICON_SIZE = 24
local SPELL_MENU_HEIGHT = 20 * 12
local RANGE_BOX_LETTERS = 64
local POSITION_MODES = {
	{ id = "nameplate", label = "On target nameplate" },
	{ id = "screen", label = "Fixed on screen" },
}
local ERROR_COLOR = { 1, 0.2, 0.2 }
local INFO_COLOR = { 0.7, 0.7, 0.7 }

local function SetRangeStatus(message, isError)
	if ui and ui.rangeStatus then
		local color = isError and ERROR_COLOR or INFO_COLOR
		ui.rangeStatus:SetTextColor(color[1], color[2], color[3])
		ui.rangeStatus:SetText(message or "")
	end
end

-- Menu text of a spell: its icon, then its name.
local function SpellMenuText(spell)
	if spell.iconID then
		return string.format("|T%s:16|t %s", tostring(spell.iconID), spell.name)
	end
	return spell.name
end

-- Shows one page and marks its tab button; the choice is remembered in the saved data.
local function SelectTab(id)
	if not ui then
		return
	end
	if id ~= "range" and id ~= "recipes" and id ~= "mail" and id ~= "profiles" then
		id = "stats"
	end

	if ui.currentTab ~= id then
		-- Leaving a page: commit what is being typed there.
		ClearWeightFocus()
		DisarmConfirms()
		ui.nameBox:ClearFocus()
		ui.addBox:ClearFocus()
		ui.rangeBox:ClearFocus()
		ui.profilesNameBox:ClearFocus()
		HideTooltip()
		ui.currentTab = id
	end
	ns.SetOptionsTab(id)

	ui.statsPage:SetShown(id == "stats")
	ui.rangePage:SetShown(id == "range")
	ui.recipesPage:SetShown(id == "recipes")
	ui.mailPage:SetShown(id == "mail")
	ui.profilesPage:SetShown(id == "profiles")
	for _, tab in ipairs(ui.tabs) do
		if tab.id == id then
			tab.button:LockHighlight()
			tab.button:SetNormalFontObject("GameFontHighlight")
		else
			tab.button:UnlockHighlight()
			tab.button:SetNormalFontObject("GameFontNormal")
		end
	end
end

local function RefreshRangePage()
	if not (ui and ui.rangeEnable) then
		return
	end

	ui.rangeEnable:SetChecked(ns.GetRangeSetting("enabled") and true or false)
	ui.rangeLock:SetChecked(ns.GetRangeSetting("locked") and true or false)
	ui.rangeSpellDropdown:GenerateMenu()
	if not (ui.rangeSizeBox.HasFocus and ui.rangeSizeBox:HasFocus()) then
		ui.rangeShowCurrentSize()
	end
	ui.rangePositionDropdown:GenerateMenu()

	-- Dragging and the saved screen position only matter at the fixed screen position.
	local onScreen = ns.GetRangeSetting("anchor") == "screen"
	ui.rangeLock:SetEnabled(onScreen)
	ui.rangeLock.Text:SetFontObject(onScreen and "GameFontHighlightSmall" or "GameFontDisableSmall")
	ui.rangeReset:SetEnabled(onScreen)

	local spellID = ns.GetRangeSpell()
	local info = ns.GetRangeSpellInfo()
	if info then
		ui.rangeIcon:SetTexture(info.iconID)
		ui.rangeIcon:Show()
		ui.rangeSpellText:SetText(info.name .. "  |cff999999(" .. tostring(spellID) .. ")|r")
	elseif spellID then
		ui.rangeIcon:Hide()
		ui.rangeSpellText:SetText("Unknown spell (" .. tostring(spellID) .. ")")
	else
		ui.rangeIcon:Hide()
		ui.rangeSpellText:SetText("None chosen")
	end
end

local function SetRangeSpellFromBox()
	local ok, message, warned = ns.SetRangeSpellByText(ui.rangeBox:GetText())
	if ok then
		ui.rangeBox:SetText("")
		ui.rangeBox:ClearFocus()
		SetRangeStatus(message, warned)
		if warned then
			ns.Print(message)
		end
	else
		SetRangeStatus(message, true)
		ns.Print(message)
	end
	RefreshRangePage()
end

-- Check box that calls `onClick(checked)`.
local function CreateToggle(parent, text, x, y, onClick, tooltip)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(26, 26)
	check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	check.Text:SetFontObject("GameFontHighlightSmall")
	check.Text:SetText(text)
	check:SetScript("OnClick", function(self)
		SetRangeStatus(nil)
		onClick(self:GetChecked() and true or false)
	end)
	if tooltip then
		check:HookScript("OnEnter", function(self)
			ShowTooltip(self, text, tooltip)
		end)
		check:HookScript("OnLeave", HideTooltip)
	end
	return check
end

local function BuildRangePage(page)
	ui.rangeEnable = CreateToggle(page, "Enable range check", 12, -32, function(checked)
		ns.SetRangeSetting("enabled", checked)
	end, "Shows the icon of the chosen spell while your target is within range of it, tinted red when it is not.")

	-- Spell
	local spellHeader = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	spellHeader:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -66)
	spellHeader:SetText("Spell")

	ui.rangeSpellDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.rangeSpellDropdown:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -86)
	ui.rangeSpellDropdown:SetPoint("TOPRIGHT", page, "TOPRIGHT", -14, -86)
	ui.rangeSpellDropdown:SetDefaultText("Choose a spell...")
	ui.rangeSpellDropdown:SetupMenu(function(_, rootDescription)
		rootDescription:SetScrollMode(SPELL_MENU_HEIGHT)
		rootDescription:CreateRadio("None", function()
			return ns.GetRangeSpell() == nil
		end, function()
			ns.SetRangeSpell(nil)
			SetRangeStatus(nil)
			RefreshRangePage()
		end)
		local spells = ns.GetRangeSpellList()
		if #spells == 0 then
			rootDescription:CreateTitle("No harmful spells with a range found")
			return
		end
		for _, spell in ipairs(spells) do
			rootDescription:CreateRadio(SpellMenuText(spell), function(spellID)
				return ns.GetRangeSpell() == spellID
			end, function(spellID)
				local ok, err = ns.SetRangeSpell(spellID)
				SetRangeStatus(not ok and err or nil, true)
				RefreshRangePage()
			end, spell.spellID)
		end
	end)

	local typeLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	typeLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -120)
	typeLabel:SetText("Or type a spell name or ID:")

	ui.rangeSetButton = CreateButton(page, "Set", 70, SetRangeSpellFromBox)
	ui.rangeSetButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -136)

	ui.rangeBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.rangeBox:SetHeight(20)
	ui.rangeBox:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -138)
	ui.rangeBox:SetPoint("TOPRIGHT", ui.rangeSetButton, "TOPLEFT", -28, -2)
	ui.rangeBox:SetAutoFocus(false)
	ui.rangeBox:SetMaxLetters(RANGE_BOX_LETTERS)
	ui.rangeBox:SetTextInsets(2, 2, 0, 0)
	ui.rangeBox:SetScript("OnEnterPressed", SetRangeSpellFromBox)
	ui.rangeBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	local currentLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	currentLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -172)
	currentLabel:SetText("Current spell:")

	ui.rangeIcon = page:CreateTexture(nil, "ARTWORK")
	ui.rangeIcon:SetSize(SPELL_ICON_SIZE, SPELL_ICON_SIZE)
	ui.rangeIcon:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -190)

	ui.rangeSpellText = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	ui.rangeSpellText:SetPoint("LEFT", ui.rangeIcon, "RIGHT", 8, 0)
	ui.rangeSpellText:SetPoint("RIGHT", page, "RIGHT", -16, 0)
	ui.rangeSpellText:SetJustifyH("LEFT")
	ui.rangeSpellText:SetWordWrap(false)

	-- Indicator
	local indicatorHeader = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	indicatorHeader:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -234)
	indicatorHeader:SetText("Indicator")

	local positionLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	positionLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -262)
	positionLabel:SetText("Position:")

	ui.rangePositionDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.rangePositionDropdown:SetPoint("TOPLEFT", page, "TOPLEFT", 72, -256)
	ui.rangePositionDropdown:SetWidth(180)
	ui.rangePositionDropdown:SetDefaultText("-")
	ui.rangePositionDropdown:SetupMenu(function(_, rootDescription)
		for _, mode in ipairs(POSITION_MODES) do
			rootDescription:CreateRadio(mode.label, function(value)
				return ns.GetRangeSetting("anchor") == value
			end, function(value)
				SetRangeStatus(nil)
				ns.SetRangeSetting("anchor", value)
				RefreshRangePage()
			end, mode.id)
		end
	end)

	ui.rangeLock = CreateToggle(page, "Lock position", 12, -292, function(checked)
		ns.SetRangeSetting("locked", checked)
	end, "Unlock to drag the indicator with the left mouse button. Only used with the fixed screen position.")

	ui.rangeReset = CreateButton(page, "Reset position", 130, function()
		ns.ResetRangePosition()
		SetRangeStatus("Position reset.", false)
	end)
	ui.rangeReset:SetPoint("TOPLEFT", page, "TOPLEFT", 190, -293)

	local sizeLabel = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	sizeLabel:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -330)
	sizeLabel:SetText("Size:")

	-- Typed size in pixels, applied on Enter or when the box loses focus; anything invalid puts the current size back.
	ui.rangeSizeBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.rangeSizeBox:SetSize(40, 20)
	ui.rangeSizeBox:SetPoint("TOPLEFT", page, "TOPLEFT", 66, -326)
	ui.rangeSizeBox:SetAutoFocus(false)
	ui.rangeSizeBox:SetMaxLetters(3)
	if ui.rangeSizeBox.SetNumeric then
		ui.rangeSizeBox:SetNumeric(true)
	end
	ui.rangeSizeBox:SetTextInsets(2, 2, 0, 0)
	local function ShowCurrentSize()
		ui.rangeSizeBox:SetText(tostring(ns.GetRangeSetting("size")))
	end
	local function ApplySizeBox(self)
		local size = tonumber(self:GetText())
		if size == ns.GetRangeSetting("size") then
			return
		end
		if ns.SetRangeSetting("size", size) then
			SetRangeStatus(string.format("Icon size set to %d.", size), false)
		else
			SetRangeStatus(string.format("Size must be a whole number from %d to %d.", ns.RANGE_SIZE_MIN, ns.RANGE_SIZE_MAX), true)
			ShowCurrentSize()
		end
	end
	ui.rangeSizeBox:SetScript("OnEnterPressed", function(self)
		ApplySizeBox(self)
		self:ClearFocus()
	end)
	ui.rangeSizeBox:SetScript("OnEditFocusLost", ApplySizeBox)
	ui.rangeSizeBox:SetScript("OnEscapePressed", function(self)
		ShowCurrentSize()
		self:ClearFocus()
	end)
	ui.rangeShowCurrentSize = ShowCurrentSize

	local sizeUnit = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	sizeUnit:SetPoint("LEFT", ui.rangeSizeBox, "RIGHT", 6, 0)
	sizeUnit:SetText(string.format("px (%d-%d)", ns.RANGE_SIZE_MIN, ns.RANGE_SIZE_MAX))

	-- Fixed box of 5 lines (60 px) below the size dropdown; it ends above the status line at the bottom of the page.
	local hint = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -360)
	hint:SetPoint("TOPRIGHT", page, "TOPRIGHT", -22, -360)
	hint:SetHeight(60)
	if hint.SetMaxLines then
		hint:SetMaxLines(5)
	end
	hint:SetJustifyH("LEFT")
	hint:SetJustifyV("TOP")
	hint:SetText("Shows the spell icon, red when out of range. Meant for enemies: needs a chosen spell and a living, attackable target. Nameplate mode needs enemy nameplates shown (default key V). Unlocked on the screen it is always shown so it can be moved.")

	ui.rangeStatus = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.rangeStatus:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.rangeStatus:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 12)
	ui.rangeStatus:SetHeight(24)
	ui.rangeStatus:SetJustifyH("LEFT")
	ui.rangeStatus:SetJustifyV("MIDDLE")
end

--------------------------------------------------------------------------------
-- Recipes page
--------------------------------------------------------------------------------

local RECIPES_BINDING = "JIMMYSUTILS_RECIPES"
local RECIPES_HELP = "Jimmy's Utils remembers the recipes of your professions and which of your characters know them. "
	.. "Point at an item and press the key below (or type "
	.. "/ju recipes <item link, ID or name>) to list every recipe that uses it as an ingredient, from the game data "
	.. "as well as the ones you saved."
local RECIPES_NOTE = "Who knows a recipe is always shown; a recipe none of your characters knows is listed in grey. "
	.. "The check box at the top of the window keeps only the recipes of your current character's professions."

-- "Professions shown in the window": one check box per profession found in the saved recipes (checked = shown; unchecking
-- hides the profession from the feature's window, see Recipes.lua and MailMaterials.lua), in columns. A profession that is
-- hidden but has no saved recipe any more is listed too (unchecked), so it can be shown again. With nothing saved and nothing
-- hidden a grey line says so. section:Refresh() rebuilds the check boxes from the saved data and returns how tall the section
-- is (so a scrolling page can size its content). `width` is a number, or a function that returns it when the window can be resized. `getHidden()` returns the saved set { [lowercase profession] = true }
-- and `setHidden(profession, hidden)` saves one change and refreshes the open window. `getProfessions()` (optional) returns the
-- names to list instead of the saved recipes' professions (the Recipes tab adds the professions of the bundled recipes).
local PROFESSIONS_HEADER = "Professions shown in the window"
local PROFESSIONS_NONE = "No recipes are saved yet, so there are no professions to choose from."
local PROFESSIONS_HEADER_HEIGHT = 20 -- the header line, and the notice or the first row under it
local PROFESSION_ROW_HEIGHT = 22
local PROFESSION_CHECK_SIZE = 22
local PROFESSION_TWO_COLUMNS_MAX = 12 -- more professions than this use three columns
local PROFESSION_LABEL_PADDING = 28 -- the check box and the gap before its label

local function BuildProfessionSection(parent, x, y, width, getHidden, setHidden, getProfessions)
	local section = { checks = {} }

	section.header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	section.header:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	section.header:SetText(PROFESSIONS_HEADER)

	section.none = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	section.none:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - PROFESSIONS_HEADER_HEIGHT)
	section.none:SetWidth(type(width) == "function" and width() or width)
	section.none:SetHeight(36)
	section.none:SetJustifyH("LEFT")
	section.none:SetJustifyV("TOP")
	section.none:SetText(PROFESSIONS_NONE)
	section.none:SetTextColor(0.5, 0.5, 0.5)

	local function AcquireCheck(index)
		local check = section.checks[index]
		if check then
			return check
		end
		check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
		check:SetSize(PROFESSION_CHECK_SIZE, PROFESSION_CHECK_SIZE)
		check.Text:SetFontObject("GameFontHighlightSmall")
		check.Text:SetWordWrap(false)
		check:SetScript("OnClick", function(self)
			DisarmConfirms()
			setHidden(self.profession, not self:GetChecked())
		end)
		check:HookScript("OnEnter", function(self)
			ShowTooltip(self, self.label, "Checked: this profession is listed in the window. Unchecked: it is hidden. Saved for all your characters.")
		end)
		check:HookScript("OnLeave", HideTooltip)
		section.checks[index] = check
		return check
	end

	function section:Refresh()
		local hidden = getHidden()
		-- One entry per profession whatever the case, labeled with the first spelling saved.
		local list, seen = {}, {}
		local names = {}
		if getProfessions then
			names = getProfessions()
		else
			local _, professions = ns.GetRecipeSummary()
			for _, profession in ipairs(professions) do
				names[#names + 1] = profession.name
			end
		end
		for _, name in ipairs(names) do
			local key = ns.ProfessionKey(name)
			if key and not seen[key] then
				seen[key] = true
				list[#list + 1] = { key = key, label = name:match("^%s*(.-)%s*$") }
			end
		end
		local extra = {}
		for key in pairs(hidden) do
			if not seen[key] then
				extra[#extra + 1] = key
			end
		end
		if #extra > 0 then
			local names = ns.GetHiddenProfessionNames(hidden) -- sorted like the keys, spelled as saved
			for _, name in ipairs(names) do
				local key = ns.ProfessionKey(name)
				if key and not seen[key] then
					seen[key] = true
					list[#list + 1] = { key = key, label = name }
				end
			end
		end
		table.sort(list, function(a, b)
			if a.key ~= b.key then
				return a.key < b.key
			end
			return a.label < b.label
		end)

		local columns = #list > PROFESSION_TWO_COLUMNS_MAX and 3 or 2
		local fullWidth = type(width) == "function" and width() or width
		section.none:SetWidth(fullWidth)
		local columnWidth = math.floor(fullWidth / columns)
		for index, item in ipairs(list) do
			local check = AcquireCheck(index)
			local row = math.floor((index - 1) / columns)
			local column = (index - 1) % columns
			check.profession, check.label = item.key, item.label
			check.Text:SetWidth(columnWidth - PROFESSION_LABEL_PADDING)
			check.Text:SetText((item.label:gsub("|", "||")))
			check:ClearAllPoints()
			check:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 4 + column * columnWidth, y - PROFESSIONS_HEADER_HEIGHT - row * PROFESSION_ROW_HEIGHT)
			check:SetChecked(not hidden[item.key])
			check:Show()
		end
		for index = #list + 1, #section.checks do
			section.checks[index]:Hide()
		end
		section.none:SetShown(#list == 0)
		if #list == 0 then
			return PROFESSIONS_HEADER_HEIGHT + 36
		end
		return PROFESSIONS_HEADER_HEIGHT + math.ceil(#list / columns) * PROFESSION_ROW_HEIGHT
	end

	return section
end

local RECIPES_SCROLL_NAME = "JimmysUtilsRecipesPageScroll"
local RECIPES_SCROLL_TOP = 152 -- below the enable check box, the crafting profit and profession window check boxes and the note
local RECIPES_SCROLL_BOTTOM = 44 -- above the forget button and the status line
local function RecipesTextWidth() -- the scroll frame is 310 wide at the default window size (page minus margins and the scroll bar)
	return ListWidth() - 12
end
local RECIPES_PROFESSIONS_TOP = 102 -- where the professions section starts inside the scrolling content: right under the saved recipes
local RECIPES_REST_GAP = 12 -- between the professions section and the texts below it (they move down with its height)
local RECIPES_REST_HEIGHT = 266 -- the lookup header and help, the key binding and the note, below the section

local function GetBindingDescription()
	local keys = {}
	if GetBindingKey then
		for _, key in ipairs({ GetBindingKey(RECIPES_BINDING) }) do
			keys[#keys + 1] = GetBindingText and GetBindingText(key) or key
		end
	end
	local label = BINDING_NAME_JIMMYSUTILS_RECIPES or "Jimmy's Utils: Find recipes using hovered item"
	if #keys == 0 then
		return label .. "\nKey: not set \226\128\148 set it in Options > Keybindings > AddOns"
	end
	return label .. "\nKey: " .. table.concat(keys, ", ")
end

local function RefreshRecipesPage()
	if not (ui and ui.recipesCounts) then
		return
	end

	ui.recipesEnable:SetChecked(ns.IsRecipeLookupEnabled() and true or false)
	ui.recipesBinding:SetText(GetBindingDescription())
	ui.professionWindow:SetChecked(ns.IsProfessionWindowDetached ~= nil and ns.IsProfessionWindowDetached() and true or false)

	-- Crafting profit needs Auctionator's prices: without it the check box shows unchecked and greyed out and says why (the saved choice
	-- is kept, and shows again when Auctionator is there).
	local priced = ns.IsAuctionatorLoaded ~= nil and ns.IsAuctionatorLoaded()
	ui.profitEnable:SetChecked(priced and ns.IsProfitEnabled ~= nil and ns.IsProfitEnabled() and true or false)
	ui.profitEnable:SetEnabled(priced and true or false)
	if priced then
		ui.profitEnable.Text:SetTextColor(1, 1, 1)
	else
		ui.profitEnable.Text:SetTextColor(0.5, 0.5, 0.5)
	end
	ui.profitNote:SetShown(not priced)
	-- The sort of the profession window's list: the Filter menu does it too, but not under the gamepad interface. Not while SkillUp
	-- Forever sorts the list, and not without prices.
	local blocked = ns.IsProfitListSortBlocked ~= nil and ns.IsProfitListSortBlocked()
	local listSortable = priced and not blocked
	ui.listSortEnable:SetChecked(listSortable and ns.IsProfitListSorted ~= nil and ns.IsProfitListSorted() and true or false)
	ui.listSortEnable:SetEnabled(listSortable and true or false)
	if listSortable then
		ui.listSortEnable.Text:SetTextColor(1, 1, 1)
	else
		ui.listSortEnable.Text:SetTextColor(0.5, 0.5, 0.5)
	end

	local total, professions = ns.GetRecipeSummary()
	if total == 0 then
		ui.recipesCounts:SetText("Nothing saved yet.")
		ui.recipesCounts:SetTextColor(1, 0.19, 0.19) -- no data: red
	else
		ui.recipesCounts:SetTextColor(1, 1, 1)
		-- One wrapped line, so any number of professions fits.
		local parts = {}
		for _, profession in ipairs(professions) do
			parts[#parts + 1] = profession.name .. " " .. profession.count
		end
		ui.recipesCounts:SetText(table.concat(parts, ", ") .. "\nTotal: " .. total)
	end
	ui.forgetButton:SetEnabled(total > 0)

	-- New professions can appear with every scan, so the check boxes are rebuilt each time. The texts under the section move
	-- down with it and the page scrolls to fit them.
	local used = ui.recipesProfessions:Refresh()
	local restTop = RECIPES_PROFESSIONS_TOP + used + RECIPES_REST_GAP
	for _, item in ipairs(ui.recipesRest) do
		item.widget:ClearAllPoints()
		item.widget:SetPoint("TOPLEFT", ui.recipesContent, "TOPLEFT", 4, -(restTop + item.offset))
	end
	ui.recipesContent:SetHeight(restTop + RECIPES_REST_HEIGHT + 8)
end

-- Same two-step confirmation for forgetting every saved recipe.
local function ForgetSavedRecipes()
	if not forgetArmed then
		DisarmConfirms()
		forgetArmed = true
		forgetToken = forgetToken + 1
		ui.forgetButton:SetText("Confirm?")
		SetRecipesStatus(string.format("Click again to delete %d saved recipes.", (ns.GetRecipeSummary())))
		if C_Timer and C_Timer.After then
			local token = forgetToken
			C_Timer.After(CONFIRM_SECONDS, function()
				if forgetArmed and forgetToken == token then
					DisarmConfirms()
				end
			end)
		end
		return
	end

	DisarmConfirms()
	local count = ns.ForgetRecipes()
	RefreshRecipesPage()
	SetRecipesStatus(string.format("Forgot %d saved recipes.", count))
end

local function BuildRecipesPage(page)
	ui.recipesEnable = CreateToggle(page, "Enable recipe lookup", 12, -32, function(checked)
		DisarmConfirms()
		ns.SetRecipeLookupEnabled(checked)
	end, "Saves recipes and answers the lookup (key binding and /ju recipes). Off stops both and closes the recipes window; the saved recipes are kept. The same as /ju recipes on and off.")

	-- What a recipe earns when crafted and sold at the auction house (Profit.lua); the prices come from Auctionator.
	ui.profitEnable = CreateToggle(page, "Show crafting profit (needs Auctionator)", 12, -58, function(checked)
		if ns.SetProfitEnabled then
			ns.SetProfitEnabled(checked)
		end
	end, "Shows what a recipe earns when crafted and sold at the auction house, from Auctionator's prices: in the recipes window and the materials window (with a button to sort by profit) and as a sort in the profession window's Filter menu. Needs the Auctionator addon.")
	ui.listSortEnable = CreateToggle(page, "Sort the profession window's recipe list by profit", 12, -84, function(checked)
		if ns.SetProfitListSort then
			ns.SetProfitListSort(checked)
		end
	end, "Sorts the recipe list of the profession window by crafting profit (learned recipes first, then the unlearned ones as the game lists them). The same as Sort by in its Filter menu, which is not offered under the gamepad interface. SkillUp Forever sorts this list itself while it is loaded.")
	-- Keeps Blizzard's profession window out of its panel layout (ProfessionWindow.lua).
	ui.professionWindow = CreateToggle(page, "Keep the profession window open (movable)", 12, -124, function(checked)
		if ns.SetProfessionWindowDetached then
			local _, needsReload = ns.SetProfessionWindowDetached(checked)
			if needsReload then
				SetRecipesStatus(PROFESSION_WINDOW_RELOAD)
				ns.Print(PROFESSION_WINDOW_RELOAD)
			else
				SetRecipesStatus(nil)
			end
		end
	end, "The profession window stops being part of Blizzard's panel layout: opening other windows (character, spellbook, merchant, friends...) no longer closes it or pushes it aside, and you can drag it by its title bar; its position is saved. This changes how the game manages that window (the addon has to take it out of the game's window manager, which cannot be undone while the game runs), so turning it off needs a /reload. Turning it on while the window is open or you are in combat takes effect when the window is closed or combat ends.")
	ui.profitNote = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.profitNote:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -110)
	ui.profitNote:SetText("Auctionator is not loaded, so there are no prices.")
	ui.profitNote:Hide()

	-- Everything under the check box scrolls: the page has no room left for the professions section after the texts. The
	-- scroll frame is named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.recipesScroll = CreateFrame("ScrollFrame", RECIPES_SCROLL_NAME, page, "UIPanelScrollFrameTemplate")
	ui.recipesScroll:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -RECIPES_SCROLL_TOP)
	ui.recipesScroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -36, RECIPES_SCROLL_BOTTOM)
	local content = CreateFrame("Frame", nil, ui.recipesScroll)
	content:SetSize(ListWidth(), RECIPES_PROFESSIONS_TOP + RECIPES_REST_HEIGHT)
	ui.recipesScroll:SetScrollChild(content)
	ui.recipesContent = content

	-- Inside the scrolling content, text 4 px from its left. Saved recipes first, then the professions section (so its header
	-- and first rows are in view without scrolling), then the texts that explain the lookup; those are placed by
	-- RefreshRecipesPage, below the section.
	local savedHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	savedHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -2)
	savedHeader:SetText("Saved recipes")

	ui.recipesCounts = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.recipesCounts:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -22)
	ui.recipesCounts:SetWidth(RecipesTextWidth())
	ui.recipesCounts:SetHeight(72)
	ui.recipesCounts:SetJustifyH("LEFT")
	ui.recipesCounts:SetJustifyV("TOP")

	-- Which professions the recipes window lists (saved account-wide).
	ui.recipesProfessions = BuildProfessionSection(content, 4, -RECIPES_PROFESSIONS_TOP, RecipesTextWidth,
		ns.GetHiddenRecipeProfessions, ns.SetRecipeProfessionHidden, ns.GetRecipeWindowProfessions)

	local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetText("Recipe lookup")

	local help = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetWidth(RecipesTextWidth())
	help:SetHeight(98)
	help:SetJustifyH("LEFT")
	help:SetJustifyV("TOP")
	help:SetText(RECIPES_HELP)

	local bindingHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	bindingHeader:SetText("Key binding")

	ui.recipesBinding = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.recipesBinding:SetWidth(RecipesTextWidth())
	ui.recipesBinding:SetHeight(42)
	ui.recipesBinding:SetJustifyH("LEFT")
	ui.recipesBinding:SetJustifyV("TOP")

	local note = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	note:SetWidth(RecipesTextWidth())
	note:SetHeight(72)
	note:SetJustifyH("LEFT")
	note:SetJustifyV("TOP")
	note:SetText(RECIPES_NOTE)

	ui.recipesTexts = { ui.recipesCounts, help, ui.recipesBinding, note } -- sized by the window's width (ApplyWidth)

	-- Offsets from the top of that block: header 0, help 20 (98 tall), binding header 126, binding 146 (42), note 194 (72).
	ui.recipesRest = {
		{ widget = header, offset = 0 }, { widget = help, offset = 20 }, { widget = bindingHeader, offset = 126 },
		{ widget = ui.recipesBinding, offset = 146 }, { widget = note, offset = 194 },
	}
	for _, item in ipairs(ui.recipesRest) do
		item.widget:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -(RECIPES_PROFESSIONS_TOP + RECIPES_REST_GAP + item.offset))
	end

	ui.forgetButton = CreateButton(page, FORGET_LABEL, 150, ForgetSavedRecipes)
	ui.forgetButton:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 12)

	ui.recipesStatus = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.recipesStatus:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.recipesStatus:SetPoint("BOTTOMRIGHT", ui.forgetButton, "BOTTOMLEFT", -6, 0)
	ui.recipesStatus:SetHeight(24)
	ui.recipesStatus:SetJustifyH("LEFT")
	ui.recipesStatus:SetJustifyV("MIDDLE")
end

--------------------------------------------------------------------------------
-- Mail page
--------------------------------------------------------------------------------

local MAIL_HINT = "Lists the last 10 characters you sent mail to on this realm, in a panel next to the Send Mail tab "
	.. "of the mailbox. Click a name to fill in the To: box, right-click it to take it off the list. "
	.. "Off: nothing is recorded or scanned. The same as /ju mail on, off and clear."

local MATERIALS_HINT = "Type /ju materials to see recipe materials found in your mail. It needs the checkbox above (or /ju mail on)."

local function SetMailStatus(message)
	if ui and ui.mailStatus then
		ui.mailStatus:SetText(message or "")
	end
end

local function RefreshMailPage()
	if not (ui and ui.mailEnable) then
		return
	end

	ui.mailEnable:SetChecked(ns.IsMailEnabled() and true or false)
	local count = ns.GetMailRecipientCount()
	ui.mailCount:SetText(string.format("Saved for this realm: %d", count))
	ui.mailClear:SetEnabled(count > 0)
	ui.mailProfessions:Refresh() -- new professions can appear with every scan
end

local function BuildMailPage(page)
	ui.mailEnable = CreateToggle(page, "Enable mail features (recent recipients and mail materials)", 12, -32, function(checked)
		SetMailStatus(nil)
		ns.SetMailEnabled(checked)
	end, "Switches both mail features: the panel with the last 10 characters you sent mail to, next to the Send Mail tab of the mailbox, and the scan of your mailbox for recipe materials (/ju materials). Off records and scans nothing, hides the panel and the Materials button of the mailbox, and closes the materials window.")

	ui.mailCount = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.mailCount:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -70)

	ui.mailClear = CreateButton(page, "Clear recent recipients", 170, function()
		local count = ns.ClearMailRecipients()
		SetMailStatus(string.format("Cleared %d recipient%s.", count, count == 1 and "" or "s"))
		RefreshMailPage()
	end)
	ui.mailClear:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -92)

	-- Fixed box of 5 lines (60 px) below the button.
	local hint = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -124)
	hint:SetPoint("TOPRIGHT", page, "TOPRIGHT", -22, -124)
	hint:SetHeight(60)
	if hint.SetMaxLines then
		hint:SetMaxLines(5)
	end
	hint:SetJustifyH("LEFT")
	hint:SetJustifyV("TOP")
	hint:SetText(MAIL_HINT)

	-- Materials in your mail: ends at -238, well above the status line at the bottom of the page.
	local materialsHeader = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	materialsHeader:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -196)
	materialsHeader:SetText("Materials in your mail")

	local materialsHint = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	materialsHint:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -214)
	materialsHint:SetPoint("TOPRIGHT", page, "TOPRIGHT", -22, -214)
	materialsHint:SetHeight(24)
	if materialsHint.SetMaxLines then
		materialsHint:SetMaxLines(2)
	end
	materialsHint:SetJustifyH("LEFT")
	materialsHint:SetJustifyV("TOP")
	materialsHint:SetText(MATERIALS_HINT)

	-- Which professions the materials window lists (saved account-wide): the header at -250, the rows from -270 on, 22 px each;
	-- six rows (twelve professions in two columns, up to eighteen in three) end at -402, above the status line at the bottom.
	ui.mailProfessions = BuildProfessionSection(page, 18, -250, function() return ListWidth() + 10 end,
		ns.GetHiddenMaterialProfessions, ns.SetMaterialProfessionHidden)

	ui.mailStatus = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.mailStatus:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.mailStatus:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 12)
	ui.mailStatus:SetHeight(24)
	ui.mailStatus:SetJustifyH("LEFT")
	ui.mailStatus:SetJustifyV("MIDDLE")
	ui.mailStatus:SetTextColor(INFO_COLOR[1], INFO_COLOR[2], INFO_COLOR[3])
end

--------------------------------------------------------------------------------
-- Window construction
--------------------------------------------------------------------------------

-- The window has another width: what is sized by a number instead of by its anchors (the scroll lists and the texts in them) follows it.
-- The check boxes of the professions are laid out in columns, so the pages that have them are laid out again too (see OnSizeChanged).
local function ApplyWidth()
	if not (ui and window and ui.recipesContent) then
		return
	end
	ui.laidOutWidth = window:GetWidth()
	ui.scrollChild:SetWidth(ListWidth())
	ui.recipesContent:SetWidth(ListWidth())
	for _, text in ipairs(ui.recipesTexts) do
		text:SetWidth(RecipesTextWidth())
	end
end

local function SetWindowTitle(frame, text)
	local container = frame.TitleContainer
	if container and container.TitleText then
		container.TitleText:SetText(text)
	elseif type(frame.SetTitle) == "function" then
		frame:SetTitle(text)
	else
		local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", frame, "TOP", 0, -5)
		title:SetText(text)
	end
end

--------------------------------------------------------------------------------
-- Profiles page
--------------------------------------------------------------------------------

local PROFILES_HELP = "A profile is a named set of this addon's settings: what is switched on or off (tooltip scores, range check, "
	.. "recipe lookup, mail, crafting profit, the minimap button...), the display settings and the options of the recipes and "
	.. "materials windows. Each character uses one profile and follows it: change a setting on any tab and the profile of this "
	.. "character changes with it; switch profile and all of them change at once. Export gives a profile as text to share or keep.\n\n"
	.. "Not part of a profile: the stat weight scales (Stat Weights tab; they have their own Pawn import and export), window "
	.. "positions and sizes, saved recipes and mail, and the range check spell."

local ShowImportDialog -- defined with the dialog below

local function SetProfilesStatus(message, isError)
	if ui and ui.profilesStatus then
		local color = isError and ERROR_COLOR or INFO_COLOR
		ui.profilesStatus:SetTextColor(color[1], color[2], color[3])
		ui.profilesStatus:SetText(message or "")
	end
end

local function RefreshProfilesPage()
	if not (ui and ui.profilesDropdown) then
		return
	end
	ui.profilesDropdown:GenerateMenu()
	ui.profilesDelete:SetEnabled(#ns.GetSettingsProfileNames() > 1)
end

-- What a switch (or a delete, or an import over the active profile) says when the profession window needs a /reload to go back.
local function ProfilesReloadNote(message, needsReload)
	if needsReload then
		ns.Print(PROFESSION_WINDOW_RELOAD)
		return message .. " " .. PROFESSION_WINDOW_RELOAD
	end
	return message
end

-- Switches this character to a profile: all its settings are applied, so every page is refreshed.
local function SwitchSettingsProfile(name)
	ClearWeightFocus()
	DisarmConfirms()
	local ok, err, needsReload = ns.SetActiveSettingsProfile(name)
	if not ok then
		SetProfilesStatus(err or "Could not switch profile.", true)
		return
	end
	ns.RefreshOptions()
	RefreshProfilesPage()
	SetProfilesStatus(ProfilesReloadNote(err or string.format('Switched to profile "%s".', name), needsReload), err ~= nil)
end

local function ProfileNameFromBox()
	return (ui.profilesNameBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- The New and Copy buttons: the name typed in the box is saved as a profile (from the current settings, or a copy of the active
-- profile) and the character switches to it.
local function CreateSettingsProfileFromBox(copyActive)
	DisarmConfirms()
	local name = ProfileNameFromBox()
	if name == "" then
		SetProfilesStatus("Type a name for the new profile first.", true)
		return
	end
	local ok, result = ns.CreateSettingsProfile(name, copyActive and ns.GetActiveSettingsProfileName() or nil)
	if ok then
		ok, result = ns.SetActiveSettingsProfile(name)
	end
	if not ok then
		SetProfilesStatus(result or "Could not create the profile.", true)
		return
	end
	ui.profilesNameBox:SetText("")
	ui.profilesNameBox:ClearFocus()
	RefreshProfilesPage()
	SetProfilesStatus(string.format('Saved the settings as profile "%s" and switched to it.', ns.GetActiveSettingsProfileName()), false)
end

-- The Rename button: the active profile gets the name typed in the box.
local function RenameSettingsProfile()
	DisarmConfirms()
	local name = ProfileNameFromBox()
	if name == "" then
		SetProfilesStatus("Type the new name of the profile first.", true)
		return
	end
	local old = ns.GetActiveSettingsProfileName()
	local ok, result = ns.RenameSettingsProfile(old, name)
	if not ok then
		SetProfilesStatus(result or "Could not rename the profile.", true)
		return
	end
	ui.profilesNameBox:SetText("")
	ui.profilesNameBox:ClearFocus()
	RefreshProfilesPage()
	SetProfilesStatus(string.format('Renamed profile "%s" to "%s".', old, result), false)
end

-- Two-step delete of the active profile: the first click arms the button, a second click deletes. The characters that used it fall back
-- to Default (else the first profile).
local function DeleteSettingsProfile()
	local name = ns.GetActiveSettingsProfileName()
	if not profileDeleteArmed then
		DisarmConfirms()
		profileDeleteArmed = true
		profileDeleteToken = profileDeleteToken + 1
		ui.profilesDelete:SetText("Confirm?")
		SetProfilesStatus(string.format('Click again to delete profile "%s".', tostring(name)), true)
		if C_Timer and C_Timer.After then
			local token = profileDeleteToken
			C_Timer.After(CONFIRM_SECONDS, function()
				if profileDeleteArmed and profileDeleteToken == token then
					DisarmConfirms()
				end
			end)
		end
		return
	end

	DisarmConfirms()
	local ok, err, needsReload = ns.DeleteSettingsProfile(name)
	if not ok then
		SetProfilesStatus(err or "Could not delete the profile.", true)
		return
	end
	ns.RefreshOptions()
	RefreshProfilesPage()
	SetProfilesStatus(ProfilesReloadNote(string.format('Deleted profile "%s"; now using "%s".', name, ns.GetActiveSettingsProfileName()), needsReload), false)
end

local function BuildProfilesPage(page)
	local header = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -37)
	header:SetText("Profile of this character")

	-- Profile row (the dropdown takes what the Delete button leaves, like the scale row of the Stat Weights tab)
	ui.profilesDelete = CreateButton(page, "Delete", 82, DeleteSettingsProfile)
	ui.profilesDelete:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -61)
	ui.profilesDelete:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Delete the profile", "Deletes the active profile (click twice). The characters that used it use Default from then on. The last profile cannot be deleted.")
	end)
	ui.profilesDelete:HookScript("OnLeave", HideTooltip)

	ui.profilesDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.profilesDropdown:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -60)
	ui.profilesDropdown:SetPoint("TOPRIGHT", ui.profilesDelete, "TOPLEFT", -16, 1)
	ui.profilesDropdown:SetDefaultText("-")
	ui.profilesDropdown:SetupMenu(function(_, rootDescription)
		rootDescription:SetScrollMode(20 * 12)
		for _, name in ipairs(ns.GetSettingsProfileNames()) do
			rootDescription:CreateRadio(name, function(profileName)
				return ns.GetActiveSettingsProfileName() == profileName
			end, SwitchSettingsProfile, name)
		end
	end)

	-- Name row: the New, Copy and Rename buttons use the name typed in the box
	local renameButton = CreateButton(page, "Rename", 64, RenameSettingsProfile)
	renameButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -92)
	renameButton:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Rename the profile", "Gives the active profile the name typed in the box. Your other characters follow the new name.")
	end)
	renameButton:HookScript("OnLeave", HideTooltip)
	local copyButton = CreateButton(page, "Copy", 46, function()
		CreateSettingsProfileFromBox(true)
	end)
	copyButton:SetPoint("RIGHT", renameButton, "LEFT", -4, 0)
	copyButton:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Copy the profile", "Saves a copy of the active profile under the name typed in the box and switches to the copy.")
	end)
	copyButton:HookScript("OnLeave", HideTooltip)
	local newButton = CreateButton(page, "New", 46, function()
		CreateSettingsProfileFromBox(false)
	end)
	newButton:SetPoint("RIGHT", copyButton, "LEFT", -4, 0)
	newButton:HookScript("OnEnter", function(self)
		ShowTooltip(self, "New profile", "Saves the settings as they are now under the name typed in the box and switches to that profile.")
	end)
	newButton:HookScript("OnLeave", HideTooltip)

	ui.profilesNameBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.profilesNameBox:SetHeight(20)
	ui.profilesNameBox:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -94)
	ui.profilesNameBox:SetPoint("TOPRIGHT", newButton, "TOPLEFT", -10, -2)
	ui.profilesNameBox:SetAutoFocus(false)
	ui.profilesNameBox:SetMaxLetters(32)
	ui.profilesNameBox:SetTextInsets(2, 2, 0, 0)
	ui.profilesNameBox:SetScript("OnEnterPressed", function()
		CreateSettingsProfileFromBox(false)
	end)
	ui.profilesNameBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	-- Import and export (the box of the Pawn scale tags serves for these strings too)
	ui.profilesImport = CreateButton(page, "Import", 90, function()
		DisarmConfirms()
		ShowImportDialog("profile", "import")
	end)
	ui.profilesImport:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -126)
	ui.profilesImport:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Import a profile", "Creates a profile from a profile string that you paste in. It is added to the list; pick it to use it.")
	end)
	ui.profilesImport:HookScript("OnLeave", HideTooltip)
	ui.profilesExport = CreateButton(page, "Export", 90, function()
		DisarmConfirms()
		ShowImportDialog("profile", "export")
	end)
	ui.profilesExport:SetPoint("LEFT", ui.profilesImport, "RIGHT", 4, 0)
	ui.profilesExport:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Export the profile", "Shows the active profile as a text string that you can copy (Ctrl+C) to keep or share, and import on another account.")
	end)
	ui.profilesExport:HookScript("OnLeave", HideTooltip)

	-- What a profile covers (wraps at the right edge of the window)
	ui.profilesHelp = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.profilesHelp:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -166)
	ui.profilesHelp:SetPoint("TOPRIGHT", page, "TOPRIGHT", -22, -166)
	ui.profilesHelp:SetHeight(180)
	ui.profilesHelp:SetJustifyH("LEFT")
	ui.profilesHelp:SetJustifyV("TOP")
	ui.profilesHelp:SetText(PROFILES_HELP)

	ui.profilesStatus = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.profilesStatus:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.profilesStatus:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 12)
	ui.profilesStatus:SetHeight(24)
	ui.profilesStatus:SetJustifyH("LEFT")
	ui.profilesStatus:SetJustifyV("MIDDLE")
	ui.profilesStatus:SetTextColor(INFO_COLOR[1], INFO_COLOR[2], INFO_COLOR[3])
end

--------------------------------------------------------------------------------
-- Pawn scale tags and profile strings: the Import and Export box
--------------------------------------------------------------------------------

local PAWN_DIALOG_WIDTH = 340
local PAWN_DIALOG_HEIGHT = 244
local PAWN_NAME_ROW = 30 -- the profile import has a row for the name: the box is this much taller
local PAWN_BOX_WIDTH = 308
local PAWN_BOX_HEIGHT = 100

local function SetPawnMessage(text, isError)
	local color = isError and ERROR_COLOR or INFO_COLOR
	ui.pawn.message:SetText(text or "")
	ui.pawn.message:SetTextColor(color[1], color[2], color[3])
end

-- Back to the plain Import button after a "Confirm?" (a scale of that name exists and waits for the second click).
local function DisarmPawnReplace()
	local dialog = ui and ui.pawn
	if dialog and dialog.armed then
		dialog.armed = false
		dialog.token = dialog.token + 1
		dialog.importButton:SetText("Import")
		SetPawnMessage(nil)
	end
end

-- The Import button waits for a second click ("Confirm?") before it overwrites what has the same name; goes back after a few seconds.
local function ArmPawnReplace(message)
	local dialog = ui.pawn
	DisarmPawnReplace()
	dialog.armed = true
	dialog.token = dialog.token + 1
	dialog.importButton:SetText("Confirm?")
	SetPawnMessage(message, true)
	if C_Timer and C_Timer.After then
		local token = dialog.token
		C_Timer.After(CONFIRM_SECONDS, function()
			if dialog.armed and dialog.token == token then
				DisarmPawnReplace()
			end
		end)
	end
end

-- The Import button: the scale of the pasted tag is created and made the active one. A scale of that name is only
-- overwritten (its weights) after a second click, like Delete.
local function ImportPawnText()
	local dialog = ui.pawn
	ClearWeightFocus()
	local ok, result, info = ns.ImportPawnScale(dialog.box:GetText(), dialog.armed)
	if not ok then
		if info and info.exists then
			ArmPawnReplace(string.format('A scale named "%s" exists. Click again to replace its weights with the tag\'s.', info.exists))
		else
			SetPawnMessage(result, true)
		end
		return
	end

	DisarmPawnReplace()
	DisarmConfirms()
	ns.Print(ns.FormatPawnImport(result, info))
	dialog.frame:Hide()
	SetStatus(info and info.classTemplate and ns.PAWN_CLASS_WARNING or nil)
	RefreshProfileDependent()
end

-- The Import button for a profile string: a new profile (named by the box, else by the string) is added; one of that name is only
-- replaced after a second click. The character keeps its profile (unless the replaced one is the one in use).
local function ImportProfileText()
	local dialog = ui.pawn
	local ok, result, info = ns.ImportSettingsProfile(dialog.box:GetText(), dialog.nameBox:GetText(), dialog.armed)
	if not ok then
		if info and info.exists then
			ArmPawnReplace(string.format('A profile named "%s" exists. Click again to replace it with the one in the string.', info.exists))
		else
			SetPawnMessage(result, true)
		end
		return
	end

	DisarmPawnReplace()
	DisarmConfirms()
	ns.Print(ns.FormatSettingsProfileImport(result, info))
	dialog.frame:Hide()
	if info.replaced then
		ns.RefreshOptions() -- (the profile in use may have changed every setting)
	end
	RefreshProfilesPage()
	local ignored = info.unknownTotal or 0
	local message = string.format('Imported profile "%s"%s. Pick it in the list to use it.', result,
		ignored > 0 and string.format(" (%d unknown setting%s ignored)", ignored, ignored == 1 and "" or "s") or "")
	SetProfilesStatus(ProfilesReloadNote(message, info.needsReload), false)
end

local function BuildPawnDialog()
	if ui.pawn then
		return ui.pawn
	end
	local dialog = { armed = false, token = 0 }
	ui.pawn = dialog

	-- A plain frame on top of the options window (not a StaticPopup, so no global names are needed).
	local frame = CreateFrame("Frame", nil, window, "DefaultPanelFlatTemplate")
	dialog.frame = frame
	if ns.MakeOpaque then ns.MakeOpaque(frame) end
	frame:Hide()
	frame:SetSize(PAWN_DIALOG_WIDTH, PAWN_DIALOG_HEIGHT)
	frame:SetPoint("CENTER", window, "CENTER", 0, 20)
	frame:SetFrameStrata("DIALOG")
	frame:SetFrameLevel(window:GetFrameLevel() + 30)
	frame:SetToplevel(true)
	frame:EnableMouse(true)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetSize(24, 24)
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function()
		frame:Hide()
	end)

	dialog.hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	dialog.hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -32)
	dialog.hint:SetWidth(PAWN_BOX_WIDTH)
	dialog.hint:SetHeight(28)
	dialog.hint:SetJustifyH("LEFT")
	dialog.hint:SetJustifyV("TOP")
	if dialog.hint.SetMaxLines then
		dialog.hint:SetMaxLines(2)
	end

	-- The text lives in a multi-line edit box inside a scroll frame (mouse wheel; the cursor scrolls into view).
	dialog.scroll = CreateFrame("ScrollFrame", nil, frame)
	dialog.scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -66)
	dialog.scroll:SetSize(PAWN_BOX_WIDTH, PAWN_BOX_HEIGHT)
	local back = frame:CreateTexture(nil, "BACKGROUND")
	back:SetColorTexture(0, 0, 0, 0.6)
	back:SetPoint("TOPLEFT", dialog.scroll, "TOPLEFT", -4, 4)
	back:SetPoint("BOTTOMRIGHT", dialog.scroll, "BOTTOMRIGHT", 4, -4)

	local box = CreateFrame("EditBox", nil, dialog.scroll)
	dialog.box = box
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetMaxLetters(0)
	box:SetTextInsets(2, 2, 2, 2)
	box:SetSize(PAWN_BOX_WIDTH, PAWN_BOX_HEIGHT)
	dialog.scroll:SetScrollChild(box)

	dialog.scroll:EnableMouse(true)
	dialog.scroll:SetScript("OnMouseDown", function()
		box:SetFocus()
	end)
	dialog.scroll:EnableMouseWheel(true)
	dialog.scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange() or 0
		self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 24)))
	end)
	box:SetScript("OnCursorChanged", function(self, _, y, _, height)
		if type(y) ~= "number" or type(height) ~= "number" then
			return
		end
		local scroll = dialog.scroll
		local top, view = scroll:GetVerticalScroll() or 0, scroll:GetHeight() or PAWN_BOX_HEIGHT
		y = -y
		if y < top then
			scroll:SetVerticalScroll(y)
		elseif y + height > top + view then
			scroll:SetVerticalScroll(y + height - view)
		end
	end)
	box:SetScript("OnTextChanged", function(self, userInput)
		if not userInput then
			return
		end
		if dialog.mode == "export" then
			-- The exported text is read only: typing is undone and the tag stays selected.
			self:SetText(dialog.tag or "")
			self:HighlightText()
		else
			DisarmPawnReplace()
			SetPawnMessage(nil)
		end
	end)
	box:SetScript("OnEditFocusGained", function(self)
		if dialog.mode == "export" then
			self:HighlightText()
		end
	end)
	box:SetScript("OnEscapePressed", function()
		frame:Hide()
	end)

	-- The name of the profile that is imported (empty: the name in the string); only shown for those.
	dialog.nameLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	dialog.nameLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -180)
	dialog.nameLabel:SetText("Name (optional):")
	dialog.nameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	dialog.nameBox:SetHeight(20)
	dialog.nameBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 120, -176)
	dialog.nameBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -176)
	dialog.nameBox:SetAutoFocus(false)
	dialog.nameBox:SetMaxLetters(32)
	dialog.nameBox:SetTextInsets(2, 2, 0, 0)
	dialog.nameBox:SetScript("OnTextChanged", function(_, userInput)
		if userInput then
			DisarmPawnReplace()
			SetPawnMessage(nil)
		end
	end)
	dialog.nameBox:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	dialog.nameBox:SetScript("OnEscapePressed", function()
		frame:Hide()
	end)

	dialog.message = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	dialog.message:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -172)
	dialog.message:SetWidth(PAWN_BOX_WIDTH)
	dialog.message:SetHeight(30)
	dialog.message:SetJustifyH("LEFT")
	dialog.message:SetJustifyV("TOP")
	if dialog.message.SetMaxLines then
		dialog.message:SetMaxLines(3)
	end

	dialog.cancelButton = CreateButton(frame, "Cancel", 84, function()
		frame:Hide()
	end)
	dialog.cancelButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 12)
	dialog.importButton = CreateButton(frame, "Import", 84, function()
		if dialog.kind == "profile" then
			ImportProfileText()
		else
			ClearWeightFocus()
			ImportPawnText()
		end
	end)
	dialog.importButton:SetPoint("RIGHT", dialog.cancelButton, "LEFT", -6, 0)

	frame:SetScript("OnHide", function()
		box:ClearFocus()
		dialog.nameBox:ClearFocus()
		DisarmPawnReplace()
	end)
	return dialog
end

-- Opens the box. kind "pawn": a Pawn scale tag of the active scale ("import" to paste one, "export" to copy it); kind "profile": the
-- text string of a settings profile (the active one is exported).
ShowImportDialog = function(kind, mode)
	local dialog = BuildPawnDialog()
	DisarmPawnReplace()
	dialog.kind = kind
	dialog.mode = mode
	dialog.scroll:SetVerticalScroll(0)
	-- The profile import has a row for the name, which moves the message down and makes the box taller.
	local withName = kind == "profile" and mode == "import"
	dialog.nameLabel:SetShown(withName)
	dialog.nameBox:SetShown(withName)
	dialog.nameBox:SetText("")
	dialog.frame:SetHeight(withName and PAWN_DIALOG_HEIGHT + PAWN_NAME_ROW or PAWN_DIALOG_HEIGHT)
	dialog.message:ClearAllPoints()
	dialog.message:SetPoint("TOPLEFT", dialog.frame, "TOPLEFT", 16, withName and -172 - PAWN_NAME_ROW or -172)
	if mode == "export" then
		dialog.importButton:Hide()
		dialog.cancelButton:SetText("Close")
		local tag, skipped
		if kind == "profile" then
			SetWindowTitle(dialog.frame, "Export profile")
			dialog.hint:SetText("Press Ctrl+C to copy the string, then keep it or share it. The Import button of the Profiles tab reads it again.")
			tag, skipped = ns.ExportSettingsProfile()
		else
			SetWindowTitle(dialog.frame, "Export Pawn scale")
			dialog.hint:SetText("Press Ctrl+C to copy the tag, then paste it into Pawn or share it.")
			tag, skipped = ns.GetPawnTag()
		end
		dialog.tag = tag
		dialog.box:SetText(tag or "")
		dialog.box:SetCursorPosition(0)
		if not tag then
			SetPawnMessage(skipped, true)
		elseif kind ~= "profile" and #skipped > 0 then
			SetPawnMessage("Not in the tag (Pawn has no name for them): " .. table.concat(skipped, ", ") .. ".", false)
		elseif kind == "profile" then
			SetPawnMessage(string.format('Profile "%s": only settings are in the string, no scales.', skipped), false)
		else
			SetPawnMessage(nil)
		end
	else
		if kind == "profile" then
			SetWindowTitle(dialog.frame, "Import profile")
			dialog.hint:SetText("Paste a profile string (it starts with JU1:), then click Import. It is added to the list of profiles.")
		else
			SetWindowTitle(dialog.frame, "Import Pawn scale")
			dialog.hint:SetText("Paste a Pawn scale tag, like ( Pawn: v1: \"Name\": Strength=1, ... ), then click Import.")
		end
		dialog.tag = nil
		dialog.importButton:Show()
		dialog.cancelButton:SetText("Cancel")
		dialog.box:SetText("")
		SetPawnMessage(nil)
	end
	dialog.frame:Show()
	dialog.frame:Raise()
	dialog.box:SetFocus()
	if mode == "export" then
		dialog.box:HighlightText()
	end
end

-- Dialog and widget table, for tests.
function ns.GetPawnDialog()
	return ui and ui.pawn
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
	local savedWidth, savedHeight = ns.GetOptionsSize()
	frame:SetSize(savedWidth or FRAME_WIDTH, savedHeight or FRAME_HEIGHT)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	SetWindowTitle(frame, CATEGORY_NAME)

	-- Escape closes the window, like Blizzard's own panels.
	if UISpecialFrames then
		local registered = false
		for _, name in ipairs(UISpecialFrames) do
			if name == FRAME_NAME then
				registered = true
				break
			end
		end
		if not registered then
			table.insert(UISpecialFrames, FRAME_NAME)
		end
	end

	ui = { rows = {}, listKeys = {} }

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
	end)

	ui.closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	ui.closeButton:SetSize(24, 24)
	ui.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

	-- Each tab is a page that fills the window below the tab buttons.
	local function CreatePage()
		local created = CreateFrame("Frame", nil, frame)
		created:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TAB_AREA)
		created:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, FOOTER_HEIGHT)
		return created
	end
	local page = CreatePage()
	ui.statsPage = page
	ui.rangePage = CreatePage()
	ui.recipesPage = CreatePage()
	ui.mailPage = CreatePage()
	ui.profilesPage = CreatePage()

	ui.tabs = {}
	for index, tab in ipairs(TABS) do
		local button = CreateButton(frame, tab.label, TAB_BUTTON_WIDTH, function()
			SelectTab(tab.id)
			RefreshRangePage()
			RefreshRecipesPage()
			RefreshMailPage()
			RefreshProfilesPage()
		end)
		button:SetHeight(TAB_BUTTON_HEIGHT)
		-- Each tab is as wide as its label plus padding (TAB_BUTTON_WIDTH when the client can't measure the text yet).
		local measured, textWidth = pcall(function()
			return button:GetFontString():GetStringWidth()
		end)
		if measured and type(textWidth) == "number" and textWidth > 0 then
			button:SetWidth(math.max(TAB_BUTTON_MIN_WIDTH, math.ceil(textWidth) + TAB_BUTTON_PADDING))
		end
		button:SetFrameLevel(frame:GetFrameLevel() + 6)
		if index == 1 then
			button:SetPoint("TOPLEFT", frame, "TOPLEFT", TAB_BUTTON_X, -27)
		else
			button:SetPoint("LEFT", ui.tabs[index - 1].button, "RIGHT", 4, 0)
		end
		ui.tabs[index] = { id = tab.id, button = button }
	end
	-- Too wide for the window (labels of another font or language)? Squeeze the buttons evenly so the row ends inside the window.
	do
		local gaps, labels = 4 * (#TABS - 1), 0
		for _, tab in ipairs(ui.tabs) do
			labels = labels + tab.button:GetWidth()
		end
		local room = FRAME_WIDTH - 2 * TAB_BUTTON_X - gaps
		if labels > room then
			for _, tab in ipairs(ui.tabs) do
				tab.button:SetWidth(math.floor(tab.button:GetWidth() * room / labels))
			end
		end
	end

	-- Footer: the minimap button belongs to the addon as a whole, not to a tab.
	ui.minimapEnable = CreateToggle(frame, "Show minimap button", 12, -(FRAME_HEIGHT - FOOTER_HEIGHT), function(checked)
		ns.SetMinimapButtonShown(checked)
	end, "Shows the button on the edge of the minimap: left-click opens this window, right-click the materials in your mail, drag moves it. The same as /ju minimap.")
	-- (at the default size the check box sits where the page ends; it stays at the bottom when the window is made taller)
	ui.minimapEnable:ClearAllPoints()
	ui.minimapEnable:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, FOOTER_HEIGHT - 26)

	-- On/off of the score lines; the rest of the page (scales and weights) is editable either way.
	ui.statsEnable = CreateToggle(page, "Enable stat weights", 12, -32, function(checked)
		DisarmConfirms()
		ns.SetStatsEnabled(checked)
	end, "Adds the stat weight score line to item tooltips. Off adds nothing; your scales and weights are kept and can still be edited here. The same as /ju stats on and off.")

	-- Scale row (the stat weight scales are called profiles in the code)
	ui.deleteButton = CreateButton(page, "Delete", 82, DeleteActiveProfile)
	ui.deleteButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -61)

	-- (272 px wide at the default window size; it grows with the window up to the Delete button)
	ui.profileDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.profileDropdown:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -60)
	ui.profileDropdown:SetPoint("TOPRIGHT", ui.deleteButton, "TOPLEFT", -16, 1)
	ui.profileDropdown:SetDefaultText("-")
	ui.profileDropdown:SetupMenu(function(_, rootDescription)
		rootDescription:SetScrollMode(20 * 12)
		for _, name in ipairs(ns.GetProfileNames()) do
			rootDescription:CreateRadio(name .. (ns.IsProfileShown(name) and "" or " (hidden)"), function(profileName)
				return ns.GetActiveProfileName() == profileName
			end, function(profileName)
				ClearWeightFocus()
				DisarmConfirms()
				local ok, err = ns.SetActiveProfile(profileName)
				if ok then
					SetStatus(nil)
				else
					SetStatus(err or "Could not switch scale.")
				end
				-- The dropdown updates its own text after a selection.
				ui.profileShown:SetChecked(ns.IsProfileShown(ns.GetActiveProfileName()) and true or false)
				RefreshProfileButtons()
				RefreshAddSelection()
				LayoutWeights()
			end, name)
		end
	end)

	-- Name row: the box takes what the buttons leave (the New, Copy and Rename buttons use the name typed in it)
	local renameButton = CreateButton(page, "Rename", 64, RenameActiveProfile)
	renameButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -92)
	renameButton:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Rename the scale", "Gives the active scale the name typed in the box. Your other characters follow the new name.")
	end)
	renameButton:HookScript("OnLeave", HideTooltip)
	local copyButton = CreateButton(page, "Copy", 46, function()
		CreateOrCopyProfile(true)
	end)
	copyButton:SetPoint("RIGHT", renameButton, "LEFT", -4, 0)
	local newButton = CreateButton(page, "New", 46, function()
		CreateOrCopyProfile(false)
	end)
	newButton:SetPoint("RIGHT", copyButton, "LEFT", -4, 0)

	ui.nameBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.nameBox:SetHeight(20)
	ui.nameBox:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -94)
	ui.nameBox:SetPoint("TOPRIGHT", newButton, "TOPLEFT", -10, -2)
	ui.nameBox:SetAutoFocus(false)
	ui.nameBox:SetMaxLetters(32)
	ui.nameBox:SetTextInsets(2, 2, 0, 0)
	ui.nameBox:SetScript("OnEnterPressed", function()
		CreateOrCopyProfile(false)
	end)
	ui.nameBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	-- Tooltip visibility of the active profile (each character has its own; the weights are kept either way)
	ui.profileShown = CreateToggle(page, "Show in tooltip", 12, -120, function(checked)
		DisarmConfirms()
		ns.SetProfileShown(ns.GetActiveProfileName(), checked)
		ui.profileDropdown:GenerateMenu()
	end, "Lists the active scale in item tooltips, one score line per listed scale. Unchecked, the scale is left out of the tooltips but keeps its weights. Each character remembers its own choice. The same as /ju scale show and hide.")

	-- Pawn scale tags: the box that pastes one in, the box that shows the active scale as one (PawnScales.lua)
	ui.pawnExportButton = CreateButton(page, "Export", 70, function()
		ClearWeightFocus()
		DisarmConfirms()
		ShowImportDialog("pawn", "export")
	end)
	ui.pawnExportButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -121)
	ui.pawnExportButton:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Export as a Pawn scale", "Shows the active scale as a Pawn scale tag that you can copy (Ctrl+C) and paste into Pawn or share. Stats Pawn has no name for are left out.")
	end)
	ui.pawnExportButton:HookScript("OnLeave", HideTooltip)
	ui.pawnImportButton = CreateButton(page, "Import", 70, function()
		ClearWeightFocus()
		DisarmConfirms()
		ShowImportDialog("pawn", "import")
	end)
	ui.pawnImportButton:SetPoint("RIGHT", ui.pawnExportButton, "LEFT", -4, 0)
	ui.pawnImportButton:HookScript("OnEnter", function(self)
		ShowTooltip(self, "Import a Pawn scale", "Creates a scale from a Pawn scale tag that you paste in, and switches to it. Stats this addon has no equivalent for are skipped.")
	end)
	ui.pawnImportButton:HookScript("OnLeave", HideTooltip)

	-- The same scores as columns of the auction house's Browse tab (AuctionScores.lua)
	ui.auctionScores = CreateToggle(page, "Show stat weight scores in the auction house", 12, -146, function(checked)
		DisarmConfirms()
		if ns.SetAuctionScoresEnabled then
			ns.SetAuctionScoresEnabled(checked)
		end
	end, "Adds one score column per listed scale (up to three) to the Browse tab of the auction house, scored like the tooltips. Click the header of a column to sort the loaded results by that scale's score, highest first; click it again, or one of the auction house's own headers, to go back. Needs the stat weight scores above to be enabled.")

	-- The auction house window can be resized with a grip in its corner (AuctionHouseResize.lua)
	ui.auctionResize = CreateToggle(page, "Resizable auction house window (drag its bottom-right corner)", 12, -172, function(checked)
		DisarmConfirms()
		if ns.SetAuctionHouseResizeEnabled then
			ns.SetAuctionHouseResizeEnabled(checked)
		end
	end, "Adds a grip to the bottom-right corner of the auction house window: drag it to make the window larger (the lists and columns grow with it); right-click it to go back to the default size. The size is remembered. Turning this off gives the window its default size back.")

	-- Display settings (two rows)
	ui.hideZero = CreateCheckbox(page, "Hide score when 0", 12, -198, "hideZero",
		"Do not add the score line to tooltips (or the score to the auction house columns) when the score is 0.")
	ui.parseEquipText = CreateCheckbox(page, "Read Equip: text", 196, -198, "parseEquipText",
		"Read 'Equip:' lines for stats the API doesn't report (English client).")

	CreateLabel(page, "Decimals:", 18, -232)
	local decimalOptions = {}
	for n = 0, 3 do
		decimalOptions[#decimalOptions + 1] = { value = n, label = tostring(n) }
	end
	ui.decimalsDropdown = CreateSettingDropdown(page, 72, -226, 70, "decimals", decimalOptions, function()
		return tonumber(ns.GetSetting("decimals"))
	end)

	CreateLabel(page, "Breakdown:", 196, -232)
	ui.breakdownDropdown = CreateSettingDropdown(page, 260, -226, 106, "breakdown", BREAKDOWN_OPTIONS, function()
		return ns.GetSetting("breakdown")
	end)

	-- Weights
	local header = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -260)
	header:SetText("Weights")

	-- Named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.scroll = CreateFrame("ScrollFrame", SCROLL_NAME, page, "UIPanelScrollFrameTemplate")
	ui.scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -280)
	ui.scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -36, 80)

	ui.scrollChild = CreateFrame("Frame", nil, ui.scroll)
	ui.scrollChild:SetSize(ListWidth(), ROW_HEIGHT)
	ui.scroll:SetScrollChild(ui.scrollChild)
	ui.emptyText = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.emptyText:SetPoint("TOPLEFT", ui.scrollChild, "TOPLEFT", 4, -4)
	ui.emptyText:SetJustifyH("LEFT")
	ui.emptyText:SetText("No weights set. Add a stat below.")
	ui.emptyText:Hide()

	-- Add row
	-- (the weight box and the Add button stay at the right edge, the dropdown takes the room in between: 230 px at the default window size)
	ui.addButton = CreateButton(page, "Add", 56, AddSelectedStat)
	ui.addButton:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 45)

	ui.addBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.addBox:SetSize(EDIT_WIDTH, 20)
	ui.addBox:SetPoint("BOTTOMRIGHT", ui.addButton, "BOTTOMLEFT", -8, 2)
	ui.addBox:SetAutoFocus(false)
	ui.addBox:SetMaxLetters(WEIGHT_MAX_LETTERS)
	ui.addBox:SetTextInsets(2, 2, 0, 0)
	ui.addBox:SetText(DEFAULT_ADD_WEIGHT)
	ui.addBox:SetScript("OnEnterPressed", AddSelectedStat)
	ui.addBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	ui.addDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.addDropdown:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 14, 44)
	ui.addDropdown:SetPoint("BOTTOMRIGHT", ui.addBox, "BOTTOMLEFT", -16, -3)
	ui.addDropdown:SetDefaultText("Add a stat...")
	ui.addDropdown:SetupMenu(BuildAddMenu)

	-- Bottom row: reset button and the status line left of it
	ui.resetButton = CreateButton(page, "Reset weights", 110, ResetActiveWeights)
	ui.resetButton:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 12)

	ui.status = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.status:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.status:SetPoint("BOTTOMRIGHT", ui.resetButton, "BOTTOMLEFT", -6, 0)
	ui.status:SetHeight(24)
	ui.status:SetJustifyH("LEFT")
	ui.status:SetJustifyV("MIDDLE")
	ui.status:SetTextColor(1, 0.2, 0.2)

	BuildRangePage(ui.rangePage)
	BuildRecipesPage(ui.recipesPage)
	BuildMailPage(ui.mailPage)
	BuildProfilesPage(ui.profilesPage)

	-- Resizable from the grip in the bottom right corner, like the chat frame and the recipes window. The default size is the smallest one.
	-- A double-click on the grip goes back to the default size. The page, its scroll lists and the controls anchored to its edges follow.
	local function Bounds()
		return ns.GetWindowBounds(FRAME_WIDTH, FRAME_HEIGHT)
	end
	frame:SetResizable(true)
	frame:SetResizeBounds(Bounds())
	ui.grip = CreateFrame("Button", nil, frame)
	ui.grip:SetSize(16, 16)
	ui.grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
	ui.grip:SetFrameLevel(frame:GetFrameLevel() + 10)
	ui.grip:EnableMouse(true)
	ui.grip:RegisterForClicks("LeftButtonUp")
	ui.grip.texture = ui.grip:CreateTexture(nil, "ARTWORK")
	ui.grip.texture:SetAllPoints(ui.grip)
	ui.grip.texture:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	local gripHighlight = ui.grip:CreateTexture(nil, "HIGHLIGHT")
	gripHighlight:SetAllPoints(ui.grip)
	gripHighlight:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	-- Lets go of the grip: the size is kept inside the bounds and saved (nothing is saved for the default size).
	local function StopSizing()
		ui.sizing = false
		ui.grip.texture:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
		frame:StopMovingOrSizing()
		local minWidth, minHeight, maxWidth, maxHeight = Bounds()
		local width = math.max(minWidth, math.min(maxWidth, math.floor(frame:GetWidth() + 0.5)))
		local height = math.max(minHeight, math.min(maxHeight, math.floor(frame:GetHeight() + 0.5)))
		if width ~= frame:GetWidth() or height ~= frame:GetHeight() then
			frame:SetSize(width, height)
		end
		ns.SetOptionsSize(width, height)
	end
	ui.grip:SetScript("OnMouseDown", function(_, mouseButton)
		if mouseButton == "LeftButton" then
			ui.sizing = true
			ui.grip.texture:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
			frame:SetResizeBounds(Bounds())
			frame:StartSizing("BOTTOMRIGHT")
		end
	end)
	ui.grip:SetScript("OnMouseUp", StopSizing)
	ui.grip:SetScript("OnDoubleClick", function()
		frame:StopMovingOrSizing()
		frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
		StopSizing()
	end)
	ui.grip:SetScript("OnEnter", function(self)
		ShowTooltip(self, "Resize", "Drag to resize the window. Double-click to go back to the default size.")
	end)
	ui.grip:SetScript("OnLeave", HideTooltip)
	-- A new width is laid out again (the lists and the columns of the professions); a new height only shows more of the lists.
	ApplyWidth()
	frame:SetScript("OnSizeChanged", function(_, newWidth)
		if ui.laidOutWidth == newWidth then
			return
		end
		ApplyWidth()
		if ui.relayoutPending then
			return
		end
		local function Relayout()
			ui.relayoutPending = false
			if frame:IsShown() then
				RefreshRecipesPage()
				RefreshMailPage()
				RefreshProfilesPage()
			end
		end
		if C_Timer and C_Timer.After then
			ui.relayoutPending = true
			C_Timer.After(0, Relayout)
		else
			Relayout()
		end
	end)

	-- Everything the handlers need exists now.
	frame:SetScript("OnShow", function()
		ns.RefreshOptions()
	end)
	frame:SetScript("OnHide", function()
		ClearWeightFocus()
		DisarmConfirms()
		if ui then
			if ui.sizing then
				StopSizing() -- the window was closed while the grip was held
			end
			if ui.pawn then
				ui.pawn.frame:Hide()
			end
			ui.nameBox:ClearFocus()
			ui.addBox:ClearFocus()
			ui.rangeBox:ClearFocus()
			ui.profilesNameBox:ClearFocus()
			HideTooltip()
		end
	end)
end

local function RefreshWindow()
	if not ui then
		return
	end

	ui.statsEnable:SetChecked(ns.IsStatsEnabled() and true or false)
	ui.auctionScores:SetChecked(ns.IsAuctionScoresEnabled ~= nil and ns.IsAuctionScoresEnabled() and true or false)
	ui.auctionResize:SetChecked(ns.IsAuctionHouseResizeEnabled ~= nil and ns.IsAuctionHouseResizeEnabled() and true or false)
	ui.minimapEnable:SetChecked(ns.IsMinimapButtonShown() and true or false)
	ui.hideZero:SetChecked(ns.GetSetting("hideZero") and true or false)
	ui.parseEquipText:SetChecked(ns.GetSetting("parseEquipText") and true or false)
	ui.decimalsDropdown:GenerateMenu()
	ui.breakdownDropdown:GenerateMenu()

	RefreshProfileDependent()
	RefreshRangePage()
	RefreshRecipesPage()
	RefreshMailPage()
	RefreshProfilesPage()
	SelectTab(ns.GetOptionsTab())
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function ns.RefreshOptions()
	if ui and window and window:IsShown() then
		RefreshWindow()
	end
end

-- The recent recipients changed (mail was sent, a name was removed or the list was cleared): only the Mail page follows.
function ns.RefreshMailPage()
	if ui and window and window:IsShown() then
		RefreshMailPage()
	end
end

-- The saved recipes changed (a profession was scanned or they were forgotten): only the Recipes page needs to follow.
function ns.RefreshRecipesPage()
	if ui and window and window:IsShown() then
		RefreshRecipesPage()
		-- The Mail tab lists the same professions: it follows too, with its layout.
		if ui.mailProfessions then
			ui.mailProfessions:Refresh()
		end
	end
end

-- The window and its widget table (nil until it is first opened), for tests.
function ns.GetOptionsWindow()
	return window, ui
end

-- Opens the window if it is closed, closes it if it is open.
function ns.ToggleOptions()
	BuildWindow()
	if window:IsShown() then
		window:Hide()
	else
		window:Show()
	end
end

local function OpenOptions()
	BuildWindow()
	if not window:IsShown() then
		window:Show()
	end
	window:Raise()
end

function ns.InitOptions()
	if initialized then
		return
	end
	initialized = true
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
		return
	end

	-- The canvas entry only points to the window.
	panel = CreateFrame("Frame", PANEL_NAME, UIParent)
	panel.name = CATEGORY_NAME
	-- New frames start shown; the Settings panel shows it when its category is opened.
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
	title:SetText(CATEGORY_NAME)

	local description = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	description:SetWidth(520)
	description:SetJustifyH("LEFT")
	description:SetText("Adds a weighted stat score to item tooltips, a range check indicator for your target, a recipe lookup, a list of recent mail recipients and the recipe materials in your mail. They are set up in their own window (also opened with /ju).")

	local openButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	openButton:SetSize(240, 26)
	openButton:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -16)
	openButton:SetText("Open " .. CATEGORY_NAME)
	openButton:SetScript("OnClick", OpenOptions)
	panel.openButton = openButton

	-- Only invoked by Blizzard's global "reset all settings to defaults" (canvas
	-- panels have no Defaults button of their own), so it must not wipe the
	-- user's weights; the window's "Reset weights" button does that.
	function panel:OnDefault()
		ns.ResetSettings()
		ns.RefreshOptions()
	end

	-- Edits are applied immediately, nothing to commit or refresh.
	function panel:OnCommit()
	end

	function panel:OnRefresh()
	end

	local category = Settings.RegisterCanvasLayoutCategory(panel, CATEGORY_NAME)
	Settings.RegisterAddOnCategory(category)
	ns.settingsCategory = category
end

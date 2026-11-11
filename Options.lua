local addonName, ns = ...

-- Options window: a small movable frame with four tabs, one per feature, each starting with
-- the checkbox that switches the feature on or off. "Stat Weights" holds the profile
-- controls, the display settings and the list of stats that have a weight; "Range Check"
-- holds the settings of the range indicator; "Recipes" explains the recipe lookup, shows
-- its key binding and what is saved, and can forget the saved recipes; "Mail" switches the
-- mail features (the recent mail recipients list and the "materials in your mail" window) on, clears the list and mentions the
-- "materials in your mail" command. A strip under the pages holds the check box of the minimap button. It is built lazily
-- the first time it is opened and refreshed from the saved data every time it
-- is shown, because profile switches change every weight and new stats can be
-- detected on items between two openings. Settings > AddOns keeps a tiny canvas
-- entry whose only job is to open the window.

local FRAME_NAME = "JimmysUtilsFrame"
local PANEL_NAME = "JimmysUtilsOptionsPanel"
local SCROLL_NAME = "JimmysUtilsListScroll"
local CATEGORY_NAME = "Jimmy's Utils"

local FRAME_WIDTH = 360
local FRAME_HEIGHT = 510 -- 458 px of page, the tab area above it and the footer below it
local FOOTER_HEIGHT = 30 -- the strip under the pages holds what belongs to no tab (the minimap button check box)
local TAB_AREA = 22 -- the pages start this far below the top of the window; the tab buttons sit above them
local TAB_BUTTON_WIDTH = 84 -- four tabs: 4 x 84 + 3 x 4 px fit in the 360 px window
local TAB_BUTTON_X = 6
local TAB_BUTTON_HEIGHT = 22
local LIST_WIDTH = 310 -- scroll frame width (frame minus margins and the scroll bar)
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

local function SetRecipesStatus(message)
	if ui and ui.recipesStatus then
		ui.recipesStatus:SetText(message or "")
	end
end

-- Back to the unarmed Delete, Reset weights and Forget saved recipes buttons. Does nothing
-- (and keeps any other status message) when none of them is armed.
local function DisarmConfirms()
	if not (deleteArmed or resetArmed or forgetArmed) then
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
	if ui then
		ui.deleteButton:SetText("Delete")
		ui.resetButton:SetText("Reset weights")
		SetStatus(nil)
		if ui.forgetButton then
			ui.forgetButton:SetText(FORGET_LABEL)
			SetRecipesStatus(nil)
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
	row.frame:SetSize(LIST_WIDTH, ROW_HEIGHT)
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
	child:SetWidth(LIST_WIDTH)

	local keys = GetWeightedKeys()
	ui.listKeys = keys
	for i, key in ipairs(keys) do
		local row = AcquireRow(i)
		row.frame:ClearAllPoints()
		row.frame:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
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
	ui.profileDropdown:GenerateMenu()
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
		SetStatus("Type a name for the new profile first.")
		return
	end

	local ok, err = ns.CreateProfile(name, copyActive and ns.GetActiveProfileName() or nil)
	if ok then
		ok, err = ns.SetActiveProfile(name)
	end
	if not ok then
		SetStatus(err or "Could not create the profile.")
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
		SetStatus(string.format('Click again to delete profile "%s".', tostring(name)))
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
		SetStatus(err or "Could not delete the profile.")
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
		SetStatus(string.format('Click again to reset the weights of profile "%s".', tostring(ns.GetActiveProfileName())))
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
		ns.Print(ns.GetStatLabel(key) .. " already has a weight in this profile; edit it in the list.")
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
	if id ~= "range" and id ~= "recipes" and id ~= "mail" then
		id = "stats"
	end

	if ui.currentTab ~= id then
		-- Leaving a page: commit what is being typed there.
		ClearWeightFocus()
		DisarmConfirms()
		ui.nameBox:ClearFocus()
		ui.addBox:ClearFocus()
		ui.rangeBox:ClearFocus()
		HideTooltip()
		ui.currentTab = id
	end
	ns.SetOptionsTab(id)

	ui.statsPage:SetShown(id == "stats")
	ui.rangePage:SetShown(id == "range")
	ui.recipesPage:SetShown(id == "recipes")
	ui.mailPage:SetShown(id == "mail")
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
	ui.rangeSpellDropdown:SetWidth(332)
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

	ui.rangeBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.rangeBox:SetSize(224, 20)
	ui.rangeBox:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -138)
	ui.rangeBox:SetAutoFocus(false)
	ui.rangeBox:SetMaxLetters(RANGE_BOX_LETTERS)
	ui.rangeBox:SetTextInsets(2, 2, 0, 0)
	ui.rangeBox:SetScript("OnEnterPressed", SetRangeSpellFromBox)
	ui.rangeBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	ui.rangeSetButton = CreateButton(page, "Set", 70, SetRangeSpellFromBox)
	ui.rangeSetButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -136)

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
	hint:SetWidth(320)
	hint:SetHeight(60)
	if hint.SetMaxLines then
		hint:SetMaxLines(5)
	end
	hint:SetJustifyH("LEFT")
	hint:SetJustifyV("TOP")
	hint:SetText("Shows the spell icon, red when out of range. Meant for enemies: needs a chosen spell and a living, attackable target. Nameplate mode needs enemy nameplates shown (default key V). Unlocked on the screen it is always shown so it can be moved.")

	ui.rangeStatus = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.rangeStatus:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.rangeStatus:SetWidth(328)
	ui.rangeStatus:SetHeight(24)
	ui.rangeStatus:SetJustifyH("LEFT")
	ui.rangeStatus:SetJustifyV("MIDDLE")
end

--------------------------------------------------------------------------------
-- Recipes page
--------------------------------------------------------------------------------

local RECIPES_BINDING = "JIMMYSUTILS_RECIPES"
local RECIPES_HELP = "Jimmy's Utils learns the recipes of your professions whenever you open a profession window, "
	.. "and remembers which of your characters know them. Point at an item and press the key below (or type "
	.. "/ju recipes <item link, ID or name>) to list the saved recipes that use it as an ingredient, and where to get "
	.. "the ones nobody knows."
local RECIPES_NOTE = "Who knows a recipe is always shown. Where to get a recipe that no character knows only works if the "
	.. "client gives addons recipes you have not learned, which Forever's own profession window hides: open a profession "
	.. "window and type /ju recipes status to see whether it does."

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

	local total, professions = ns.GetRecipeSummary()
	if total == 0 then
		ui.recipesCounts:SetText("Nothing saved yet. Open a profession window to learn its recipes.")
	else
		-- One wrapped line, so any number of professions fits.
		local parts = {}
		for _, profession in ipairs(professions) do
			parts[#parts + 1] = profession.name .. " " .. profession.count
		end
		ui.recipesCounts:SetText(table.concat(parts, ", ") .. "\nTotal: " .. total)
	end
	ui.forgetButton:SetEnabled(total > 0)
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
	end, "Learns the recipes of your profession windows and answers the lookup (key binding and /ju recipes). Off stops both and closes the recipes window; the saved recipes are kept. The same as /ju recipes on and off.")

	local header = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -60)
	header:SetText("Recipe lookup")

	local help = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -80)
	help:SetWidth(324)
	help:SetHeight(98)
	help:SetJustifyH("LEFT")
	help:SetJustifyV("TOP")
	help:SetText(RECIPES_HELP)

	local bindingHeader = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	bindingHeader:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -186)
	bindingHeader:SetText("Key binding")

	ui.recipesBinding = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.recipesBinding:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -206)
	ui.recipesBinding:SetWidth(324)
	ui.recipesBinding:SetHeight(42)
	ui.recipesBinding:SetJustifyH("LEFT")
	ui.recipesBinding:SetJustifyV("TOP")

	local savedHeader = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	savedHeader:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -256)
	savedHeader:SetText("Saved recipes")

	ui.recipesCounts = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ui.recipesCounts:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -276)
	ui.recipesCounts:SetWidth(324)
	ui.recipesCounts:SetHeight(72)
	ui.recipesCounts:SetJustifyH("LEFT")
	ui.recipesCounts:SetJustifyV("TOP")

	local note = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -354)
	note:SetWidth(324)
	note:SetHeight(60)
	note:SetJustifyH("LEFT")
	note:SetJustifyV("TOP")
	note:SetText(RECIPES_NOTE)

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
end

local function BuildMailPage(page)
	ui.mailEnable = CreateToggle(page, "Enable mail features (recent recipients and mail materials)", 12, -32, function(checked)
		SetMailStatus(nil)
		ns.SetMailEnabled(checked)
	end, "Switches both mail features: the panel with the last 10 characters you sent mail to, next to the Send Mail tab of the mailbox, and the scan of your mailbox for recipe materials (/ju materials). Off records and scans nothing, hides the panel and closes the materials window.")

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
	hint:SetWidth(320)
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
	materialsHint:SetWidth(320)
	materialsHint:SetHeight(24)
	if materialsHint.SetMaxLines then
		materialsHint:SetMaxLines(2)
	end
	materialsHint:SetJustifyH("LEFT")
	materialsHint:SetJustifyV("TOP")
	materialsHint:SetText(MATERIALS_HINT)

	ui.mailStatus = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	ui.mailStatus:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 16, 12)
	ui.mailStatus:SetWidth(328)
	ui.mailStatus:SetHeight(24)
	ui.mailStatus:SetJustifyH("LEFT")
	ui.mailStatus:SetJustifyV("MIDDLE")
	ui.mailStatus:SetTextColor(INFO_COLOR[1], INFO_COLOR[2], INFO_COLOR[3])
end

--------------------------------------------------------------------------------
-- Window construction
--------------------------------------------------------------------------------

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

local function BuildWindow()
	if window then
		return
	end

	window = CreateFrame("Frame", FRAME_NAME, UIParent, "DefaultPanelFlatTemplate")
	local frame = window
	-- New frames start shown; hide it so the first Show() fires OnShow.
	frame:Hide()
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
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

	ui.tabs = {}
	for index, tab in ipairs(TABS) do
		local button = CreateButton(frame, tab.label, TAB_BUTTON_WIDTH, function()
			SelectTab(tab.id)
			RefreshRangePage()
			RefreshRecipesPage()
			RefreshMailPage()
		end)
		button:SetHeight(TAB_BUTTON_HEIGHT)
		button:SetFrameLevel(frame:GetFrameLevel() + 6)
		if index == 1 then
			button:SetPoint("TOPLEFT", frame, "TOPLEFT", TAB_BUTTON_X, -27)
		else
			button:SetPoint("LEFT", ui.tabs[index - 1].button, "RIGHT", 4, 0)
		end
		ui.tabs[index] = { id = tab.id, button = button }
	end

	-- Footer: the minimap button belongs to the addon as a whole, not to a tab.
	ui.minimapEnable = CreateToggle(frame, "Show minimap button", 12, -(FRAME_HEIGHT - FOOTER_HEIGHT), function(checked)
		ns.SetMinimapButtonShown(checked)
	end, "Shows the button on the edge of the minimap: left-click opens this window, right-click the materials in your mail, drag moves it. The same as /ju minimap.")

	-- On/off of the score lines; the rest of the page (profiles and weights) is editable either way.
	ui.statsEnable = CreateToggle(page, "Enable stat weights", 12, -32, function(checked)
		DisarmConfirms()
		ns.SetStatsEnabled(checked)
	end, "Adds the stat weight score line to item tooltips. Off adds nothing; your profiles and weights are kept and can still be edited here. The same as /ju stats on and off.")

	-- Profile row
	ui.profileDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.profileDropdown:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -60)
	ui.profileDropdown:SetWidth(232)
	ui.profileDropdown:SetDefaultText("-")
	ui.profileDropdown:SetupMenu(function(_, rootDescription)
		rootDescription:SetScrollMode(20 * 12)
		for _, name in ipairs(ns.GetProfileNames()) do
			rootDescription:CreateRadio(name, function(profileName)
				return ns.GetActiveProfileName() == profileName
			end, function(profileName)
				ClearWeightFocus()
				DisarmConfirms()
				local ok, err = ns.SetActiveProfile(profileName)
				if ok then
					SetStatus(nil)
				else
					SetStatus(err or "Could not switch profile.")
				end
				-- The dropdown updates its own text after a selection.
				RefreshProfileButtons()
				RefreshAddSelection()
				LayoutWeights()
			end, name)
		end
	end)

	ui.deleteButton = CreateButton(page, "Delete", 82, DeleteActiveProfile)
	ui.deleteButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -61)

	-- Name row
	ui.nameBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.nameBox:SetSize(168, 20)
	ui.nameBox:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -94)
	ui.nameBox:SetAutoFocus(false)
	ui.nameBox:SetMaxLetters(32)
	ui.nameBox:SetTextInsets(2, 2, 0, 0)
	ui.nameBox:SetScript("OnEnterPressed", function()
		CreateOrCopyProfile(false)
	end)
	ui.nameBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	local copyButton = CreateButton(page, "Copy", 70, function()
		CreateOrCopyProfile(true)
	end)
	copyButton:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -92)
	local newButton = CreateButton(page, "New", 66, function()
		CreateOrCopyProfile(false)
	end)
	newButton:SetPoint("RIGHT", copyButton, "LEFT", -4, 0)

	-- Display settings (two rows)
	ui.hideZero = CreateCheckbox(page, "Hide score when 0", 12, -120, "hideZero",
		"Do not add the score line to tooltips when the score is 0.")
	ui.parseEquipText = CreateCheckbox(page, "Read Equip: text", 176, -120, "parseEquipText",
		"Read 'Equip:' lines for stats the API doesn't report (English client).")

	CreateLabel(page, "Decimals:", 18, -154)
	local decimalOptions = {}
	for n = 0, 3 do
		decimalOptions[#decimalOptions + 1] = { value = n, label = tostring(n) }
	end
	ui.decimalsDropdown = CreateSettingDropdown(page, 72, -148, 70, "decimals", decimalOptions, function()
		return tonumber(ns.GetSetting("decimals"))
	end)

	CreateLabel(page, "Breakdown:", 176, -154)
	ui.breakdownDropdown = CreateSettingDropdown(page, 240, -148, 106, "breakdown", BREAKDOWN_OPTIONS, function()
		return ns.GetSetting("breakdown")
	end)

	-- Weights
	local header = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -182)
	header:SetText("Weights")

	-- Named so the template's "$parentScrollBar" children get a unique, namespaced global name.
	ui.scroll = CreateFrame("ScrollFrame", SCROLL_NAME, page, "UIPanelScrollFrameTemplate")
	ui.scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -202)
	ui.scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -36, 80)

	ui.scrollChild = CreateFrame("Frame", nil, ui.scroll)
	ui.scrollChild:SetSize(LIST_WIDTH, ROW_HEIGHT)
	ui.scroll:SetScrollChild(ui.scrollChild)
	ui.emptyText = ui.scrollChild:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	ui.emptyText:SetPoint("TOPLEFT", ui.scrollChild, "TOPLEFT", 4, -4)
	ui.emptyText:SetJustifyH("LEFT")
	ui.emptyText:SetText("No weights set. Add a stat below.")
	ui.emptyText:Hide()

	-- Add row
	ui.addDropdown = CreateFrame("DropdownButton", nil, page, "WowStyle1DropdownTemplate")
	ui.addDropdown:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 14, 44)
	ui.addDropdown:SetWidth(190)
	ui.addDropdown:SetDefaultText("Add a stat...")
	ui.addDropdown:SetupMenu(BuildAddMenu)

	ui.addBox = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
	ui.addBox:SetSize(EDIT_WIDTH, 20)
	ui.addBox:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 220, 47)
	ui.addBox:SetAutoFocus(false)
	ui.addBox:SetMaxLetters(WEIGHT_MAX_LETTERS)
	ui.addBox:SetTextInsets(2, 2, 0, 0)
	ui.addBox:SetText(DEFAULT_ADD_WEIGHT)
	ui.addBox:SetScript("OnEnterPressed", AddSelectedStat)
	ui.addBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)

	ui.addButton = CreateButton(page, "Add", 56, AddSelectedStat)
	ui.addButton:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -16, 45)

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

	-- Everything the handlers need exists now.
	frame:SetScript("OnShow", function()
		ns.RefreshOptions()
	end)
	frame:SetScript("OnHide", function()
		ClearWeightFocus()
		DisarmConfirms()
		if ui then
			ui.nameBox:ClearFocus()
			ui.addBox:ClearFocus()
			ui.rangeBox:ClearFocus()
			HideTooltip()
		end
	end)
end

local function RefreshWindow()
	if not ui then
		return
	end

	ui.statsEnable:SetChecked(ns.IsStatsEnabled() and true or false)
	ui.minimapEnable:SetChecked(ns.IsMinimapButtonShown() and true or false)
	ui.hideZero:SetChecked(ns.GetSetting("hideZero") and true or false)
	ui.parseEquipText:SetChecked(ns.GetSetting("parseEquipText") and true or false)
	ui.decimalsDropdown:GenerateMenu()
	ui.breakdownDropdown:GenerateMenu()

	RefreshProfileDependent()
	RefreshRangePage()
	RefreshRecipesPage()
	RefreshMailPage()
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
	end
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

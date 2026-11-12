local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")

local SAVE_FILE = "FrozenIslandToolsUI.json"
local config = HttpService:JSONDecode("{}")

if isfile and readfile then
	pcall(function()
		if isfile(SAVE_FILE) then
			local data = HttpService:JSONDecode(readfile(SAVE_FILE))
			if type(data) == "table" then
				config = data
			end
		end
	end)
end

local saveQueued = false
local function saveSettings()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(0.5, function()
		saveQueued = false
		if writefile then
			pcall(function()
				writefile(SAVE_FILE, HttpService:JSONEncode(config))
			end)
		end
	end)
end

local function pickByName(tools, name)
	for _, tool in ipairs(tools) do
		if tool.Name == name then
			return tool
		end
	end
	return nil
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local blocksFolder = workspace:WaitForChild("FrozenIsland_Blocks")

local previousGui = playerGui:FindFirstChild("FrozenIslandToolsUI")
if previousGui then
	previousGui:Destroy()
end

local excludedHex = Color3.fromRGB(99, 95, 98):ToHex():upper()
local enabledColors = {}

if type(config.colors) == "table" then
	for _, hex in ipairs(config.colors) do
		enabledColors[hex] = true
	end
end

local highlightingEnabled = false
local autoMineEnabled = false
local autoTeleportEnabled = false
local autoBoxEnabled = false
local selectedTool
local mineGeneration = 0
local boxGeneration = 0
local toggleKey = Enum.KeyCode.R

if config.toggleKey then
	local ok, key = pcall(function()
		return Enum.KeyCode[config.toggleKey]
	end)
	if ok and key then
		toggleKey = key
	end
end

local waitingForKey = false
local uiVisible = true
local visibilityGeneration = 0

local colorData = {}
local partsByHex = {}
local lastColorSignature
local lastCountSignature
local refreshHighlights
local highlights = {}
local watchedParts = {}
local toolLabels = {}
local colorRefreshPending = false
local toolRefreshPending = false
local refreshColors
local refreshTools
local scheduleColorRefresh
local scheduleToolRefresh

local globalConnections = {}
globalConnections.npcBox = { enabled = false, interval = 0.25 }
globalConnections.fish = { enabled = false }
local backpackConnections = {}
local characterConnections = {}
local playerConnections = {}
local folderConnections = {}

local MAX_HIGHLIGHTS = 30
local MINE_INTERVAL = 0.2
local TELEPORT_INTERVAL = 0.25
local TELEPORT_MIN_DISTANCE = 12
local CHEVRON_DOWN = "  ▾"
local CHEVRON_UP = "  ▴"

local BLACK = Color3.fromRGB(14, 14, 16)
local ROW = Color3.fromRGB(26, 26, 29)
local ROW_HOVER = Color3.fromRGB(38, 36, 39)
local OUTLINE = Color3.fromRGB(58, 58, 62)
local ACCENT = Color3.fromRGB(214, 62, 58)
local MUTED_RED = Color3.fromRGB(168, 48, 46)
local ACTIVE_GREEN = Color3.fromRGB(38, 74, 55)
local WHITE = Color3.fromRGB(242, 242, 244)
local MUTED = Color3.fromRGB(165, 165, 170)
local DIM = Color3.fromRGB(128, 128, 133)

local PANEL_BASE = Color3.fromRGB(16, 16, 18)
local themeUpdaters = {}

local function mutedRed()
	return MUTED_RED
end

local function panelGradientColors(accent)
	local bottom = Color3.new(accent.R * 0.33, accent.G * 0.19, accent.B * 0.19)
	local mid = PANEL_BASE:Lerp(bottom, 0.33)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, PANEL_BASE),
		ColorSequenceKeypoint.new(0.55, PANEL_BASE),
		ColorSequenceKeypoint.new(0.8, mid),
		ColorSequenceKeypoint.new(1, bottom),
	})
end

local function applyAccent(color)
	ACCENT = color
	MUTED_RED = Color3.new(color.R * 0.78, color.G * 0.78, color.B * 0.78)
	for _, update in ipairs(themeUpdaters) do
		update()
	end
	config.accent = color:ToHex()
	saveSettings()
end

local function make(className, parent, properties)
	local object = Instance.new(className)
	for property, value in pairs(properties or {}) do
		object[property] = value
	end
	object.Parent = parent
	return object
end

local function addCorner(object, radius)
	return make("UICorner", object, { CornerRadius = UDim.new(0, radius) })
end

local function addStroke(object, color, transparency)
	return make("UIStroke", object, {
		Color = color,
		Transparency = transparency or 0,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local activeTweens = setmetatable({}, { __mode = "k" })

local function animate(object, duration, properties)
	local names = {}
	for name in pairs(properties) do
		table.insert(names, name)
	end
	table.sort(names)
	local key = table.concat(names, ",")

	local perObject = activeTweens[object]
	if not perObject then
		perObject = {}
		activeTweens[object] = perObject
	end
	if perObject[key] then
		perObject[key]:Cancel()
	end

	local tween = TweenService:Create(
		object,
		TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		properties
	)
	perObject[key] = tween
	tween.Completed:Connect(function()
		if perObject[key] == tween then
			perObject[key] = nil
		end
	end)
	tween:Play()
	return tween
end

local function addHover(button, normalColor, hoverColor)
	button.MouseEnter:Connect(function()
		local color = typeof(hoverColor) == "function" and hoverColor() or hoverColor
		animate(button, 0.12, { BackgroundColor3 = color })
	end)
	button.MouseLeave:Connect(function()
		animate(button, 0.16, { BackgroundColor3 = normalColor })
	end)
end

local gui = make("ScreenGui", playerGui, {
	Name = "FrozenIslandToolsUI",
	ResetOnSpawn = false,
	DisplayOrder = 50,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local window = make("CanvasGroup", gui, {
	Name = "WindowGroup",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.fromOffset(760, 480),
	BackgroundTransparency = 1,
	GroupTransparency = 0,
	Visible = true,
})
local uiScale = make("UIScale", window, { Scale = 1 })

local panel = make("Frame", window, {
	Name = "Card",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = BLACK,
	BorderSizePixel = 0,
	ClipsDescendants = true,
})
addCorner(panel, 16)
addStroke(panel, Color3.fromRGB(70, 66, 68), 0.1)
local panelGradient = make("UIGradient", panel, {
	Rotation = 90,
	Color = panelGradientColors(ACCENT),
})
table.insert(themeUpdaters, function()
	panelGradient.Color = panelGradientColors(ACCENT)
end)

local accentLine = make("Frame", panel, {
	Size = UDim2.new(1, 0, 0, 2),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 10,
})
make("UIGradient", accentLine, {
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0),
		NumberSequenceKeypoint.new(0.75, 0),
		NumberSequenceKeypoint.new(1, 1),
	}),
})
table.insert(themeUpdaters, function()
	accentLine.BackgroundColor3 = ACCENT
end)

local dragHandle = make("Frame", panel, {
	Name = "DragHandle",
	Size = UDim2.new(1, -70, 0, 64),
	BackgroundTransparency = 1,
	Active = true,
	ZIndex = 8,
})

local titleDot = make("Frame", panel, {
	Position = UDim2.fromOffset(30, 30),
	Size = UDim2.fromOffset(8, 8),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 9,
})
addCorner(titleDot, 4)
table.insert(themeUpdaters, function()
	titleDot.BackgroundColor3 = ACCENT
end)

make("TextLabel", panel, {
	Position = UDim2.fromOffset(46, 20),
	Size = UDim2.fromOffset(520, 28),
	BackgroundTransparency = 1,
	Text = "Time Wasting Simulator",
	TextColor3 = WHITE,
	Font = Enum.Font.GothamBold,
	TextSize = 22,
	TextXAlignment = Enum.TextXAlignment.Left,
	Active = false,
	ZIndex = 9,
})

local closeButton = make("TextButton", panel, {
	Position = UDim2.new(1, -52, 0, 18),
	Size = UDim2.fromOffset(32, 32),
	BackgroundColor3 = ROW,
	BorderSizePixel = 0,
	Text = "✕",
	TextColor3 = MUTED,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	AutoButtonColor = false,
	ZIndex = 12,
})
addCorner(closeButton, 16)
addStroke(closeButton, OUTLINE, 0.3)
addHover(closeButton, ROW, mutedRed)

make("Frame", panel, {
	Position = UDim2.fromOffset(28, 64),
	Size = UDim2.new(1, -56, 0, 1),
	BackgroundColor3 = Color3.fromRGB(70, 66, 68),
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	ZIndex = 3,
})

local tabBar = make("Frame", panel, {
	Position = UDim2.fromOffset(28, 72),
	Size = UDim2.fromOffset(704, 35),
	BackgroundTransparency = 1,
	ZIndex = 4,
})

local tabSpecs = {
	{ id = "mining", label = "MINING" },
	{ id = "box", label = "BOX" },
	{ id = "fishing", label = "FISHING" },
	{ id = "mopping", label = "MOPPING" },
	{ id = "farm", label = "FARM" },
    { id = "planetarium", label = "PLANETARIUM" },
	{ id = "character", label = "CHARACTER" },
	{ id = "background", label = "BACKGROUND" },
	{ id = "settings", label = "SETTINGS" },
}
local pages = {}
local tabButtons = {}
local TAB_IDLE = Color3.fromRGB(140, 140, 145)
local PAGE_Y = 118
local TAB_PITCH = 78
local TAB_WIDTH = 76
local INDICATOR_WIDTH = 50
local INDICATOR_INSET = (TAB_WIDTH - INDICATOR_WIDTH) / 2

local tabIndicator = make("Frame", tabBar, {
	Position = UDim2.fromOffset(INDICATOR_INSET, 32),
	Size = UDim2.fromOffset(INDICATOR_WIDTH, 3),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 6,
})
addCorner(tabIndicator, 2)
table.insert(themeUpdaters, function()
	tabIndicator.BackgroundColor3 = ACCENT
end)

for index, spec in ipairs(tabSpecs) do
	tabButtons[spec.id] = make("TextButton", tabBar, {
		Position = UDim2.fromOffset((index - 1) * TAB_PITCH, 0),
		Size = UDim2.fromOffset(TAB_WIDTH, 31),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = spec.label,
		TextColor3 = TAB_IDLE,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		AutoButtonColor = false,
		ZIndex = 5,
	})

	pages[spec.id] = make("CanvasGroup", panel, {
		Name = spec.id .. "Page",
		Position = UDim2.fromOffset(28, PAGE_Y),
		Size = UDim2.fromOffset(704, 340),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ClipsDescendants = false,
		ZIndex = 2,
	})
end

local activeTab
local function selectTab(tabId)
	if activeTab == tabId then
		return
	end
	activeTab = tabId

	for _, spec in ipairs(tabSpecs) do
		local isActive = spec.id == tabId
		local page = pages[spec.id]
		animate(tabButtons[spec.id], 0.2, {
			TextColor3 = isActive and WHITE or TAB_IDLE,
		})

		if isActive then
			page.Visible = true
			page.GroupTransparency = 1
			page.Position = UDim2.fromOffset(28, PAGE_Y + 8)
			animate(page, 0.26, {
				GroupTransparency = 0,
				Position = UDim2.fromOffset(28, PAGE_Y),
			})
		else
			page.Visible = false
		end
	end

	for index, spec in ipairs(tabSpecs) do
		if spec.id == tabId then
			animate(tabIndicator, 0.26, {
				Position = UDim2.fromOffset((index - 1) * TAB_PITCH + INDICATOR_INSET, 32),
			})
			break
		end
	end
end

for _, spec in ipairs(tabSpecs) do
	local button = tabButtons[spec.id]
	button.Activated:Connect(function()
		selectTab(spec.id)
	end)
	button.MouseEnter:Connect(function()
		if activeTab ~= spec.id then
			animate(button, 0.12, { TextColor3 = Color3.fromRGB(200, 200, 204) })
		end
	end)
	button.MouseLeave:Connect(function()
		if activeTab ~= spec.id then
			animate(button, 0.16, { TextColor3 = TAB_IDLE })
		end
	end)
end

local miningPage = pages.mining

local subSpecs = {
	{ id = "mine", label = "AUTO MINE" },
	{ id = "ores", label = "ORES" },
	{ id = "counts", label = "COUNTS" },
	{ id = "teleport", label = "TELEPORT" },
}
local subPages = {}
local subButtons = {}
local SUB_PITCH = 108
local SUB_WIDTH = 100
local SUB_INDICATOR_WIDTH = 40
local SUB_INDICATOR_INSET = (SUB_WIDTH - SUB_INDICATOR_WIDTH) / 2
local SUB_PAGE_Y = 38

local subBar = make("Frame", miningPage, {
	Name = "SubTabBar",
	Size = UDim2.fromOffset(704, 32),
	BackgroundTransparency = 1,
	ZIndex = 4,
})

local subIndicator = make("Frame", subBar, {
	Position = UDim2.fromOffset(SUB_INDICATOR_INSET, 29),
	Size = UDim2.fromOffset(SUB_INDICATOR_WIDTH, 2),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
	ZIndex = 6,
})
addCorner(subIndicator, 1)
table.insert(themeUpdaters, function()
	subIndicator.BackgroundColor3 = ACCENT
end)

for index, spec in ipairs(subSpecs) do
	subButtons[spec.id] = make("TextButton", subBar, {
		Position = UDim2.fromOffset((index - 1) * SUB_PITCH, 0),
		Size = UDim2.fromOffset(SUB_WIDTH, 28),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = spec.label,
		TextColor3 = TAB_IDLE,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		AutoButtonColor = false,
		ZIndex = 5,
	})

	subPages[spec.id] = make("CanvasGroup", miningPage, {
		Name = spec.id .. "SubPage",
		Position = UDim2.fromOffset(0, SUB_PAGE_Y),
		Size = UDim2.fromOffset(704, 302),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ClipsDescendants = false,
		ZIndex = 2,
	})
end

local blocksLabel = make("TextLabel", miningPage, {
	Name = "BlocksMinedLabel",
	Position = UDim2.new(1, -260, 0, 0),
	Size = UDim2.fromOffset(260, 28),
	BackgroundTransparency = 1,
	Text = "blocks mined: --",
	TextColor3 = MUTED,
	Font = Enum.Font.GothamMedium,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Right,
	Active = false,
	ZIndex = 9,
})

local activeSub
local function selectSubTab(subId)
	if activeSub == subId then
		return
	end
	activeSub = subId

	for index, spec in ipairs(subSpecs) do
		local isActive = spec.id == subId
		local page = subPages[spec.id]
		animate(subButtons[spec.id], 0.2, {
			TextColor3 = isActive and WHITE or TAB_IDLE,
		})

		if isActive then
			page.Visible = true
			page.GroupTransparency = 1
			page.Position = UDim2.fromOffset(0, SUB_PAGE_Y + 8)
			animate(page, 0.26, {
				GroupTransparency = 0,
				Position = UDim2.fromOffset(0, SUB_PAGE_Y),
			})
			animate(subIndicator, 0.26, {
				Position = UDim2.fromOffset((index - 1) * SUB_PITCH + SUB_INDICATOR_INSET, 29),
			})
		else
			page.Visible = false
		end
	end
end

for _, spec in ipairs(subSpecs) do
	local button = subButtons[spec.id]
	button.Activated:Connect(function()
		selectSubTab(spec.id)
	end)
	button.MouseEnter:Connect(function()
		if activeSub ~= spec.id then
			animate(button, 0.12, { TextColor3 = Color3.fromRGB(200, 200, 204) })
		end
	end)
	button.MouseLeave:Connect(function()
		if activeSub ~= spec.id then
			animate(button, 0.16, { TextColor3 = TAB_IDLE })
		end
	end)
end

local function createRow(parent, y, title, subtitle)
	local row = make("Frame", parent, {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundColor3 = ROW,
		BorderSizePixel = 0,
		ClipsDescendants = false,
	})
	addCorner(row, 10)
	addStroke(row, OUTLINE, 0.2)

	make("TextLabel", row, {
		Position = UDim2.fromOffset(20, subtitle and 8 or 0),
		Size = UDim2.new(0.55, -20, 0, subtitle and 21 or 56),
		BackgroundTransparency = 1,
		Text = title,
		TextColor3 = WHITE,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	})

	local subtitleLabel
	if subtitle then
		subtitleLabel = make("TextLabel", row, {
			Position = UDim2.fromOffset(20, 29),
			Size = UDim2.new(0.65, -20, 0, 17),
			BackgroundTransparency = 1,
			Text = subtitle,
			TextColor3 = DIM,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
	end
	return row, subtitleLabel
end

local OFF_TRACK = Color3.fromRGB(36, 36, 38)
local OFF_KNOB = Color3.fromRGB(135, 135, 138)
local ON_KNOB = Color3.fromRGB(252, 244, 244)

local function createSwitch(row, initialValue, onChanged)
	local value = initialValue
	local track = make("TextButton", row, {
		Position = UDim2.new(1, -76, 0.5, -15),
		Size = UDim2.fromOffset(58, 30),
		BackgroundColor3 = value and MUTED_RED or OFF_TRACK,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
	})
	addCorner(track, 15)
	addStroke(track, Color3.fromRGB(86, 86, 88), 0.3)
	local knob = make("Frame", track, {
		Position = UDim2.fromOffset(value and 32 or 4, 4),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = value and ON_KNOB or OFF_KNOB,
		BorderSizePixel = 0,
	})
	addCorner(knob, 11)

	table.insert(themeUpdaters, function()
		if value then
			track.BackgroundColor3 = MUTED_RED
		end
	end)

	track.Activated:Connect(function()
		value = not value
		animate(track, 0.18, { BackgroundColor3 = value and MUTED_RED or OFF_TRACK })
		animate(knob, 0.18, {
			Position = UDim2.fromOffset(value and 32 or 4, 4),
			BackgroundColor3 = value and ON_KNOB or OFF_KNOB,
		})
		if onChanged then
			onChanged(value)
		end
	end)
end

local function createValueButton(row, valueText, width)
	local button = make("TextButton", row, {
		Position = UDim2.new(1, -(width + 12), 0.5, -19),
		Size = UDim2.fromOffset(width, 38),
		BackgroundColor3 = Color3.fromRGB(32, 32, 34),
		BorderSizePixel = 0,
		Text = valueText,
		TextColor3 = Color3.fromRGB(200, 200, 204),
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		AutoButtonColor = false,
	})
	addCorner(button, 8)
	addStroke(button, Color3.fromRGB(70, 70, 73), 0.25)
	make("UIPadding", button, {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	})
	addHover(button, Color3.fromRGB(32, 32, 34), ROW_HOVER)
	return button
end

local function createDropdownList(page, y)
	local list = make("ScrollingFrame", page, {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.fromOffset(704, 0),
		BackgroundColor3 = Color3.fromRGB(24, 24, 26),
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Color3.fromRGB(125, 125, 128),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ClipsDescendants = true,
		ZIndex = 8,
	})
	addCorner(list, 10)
	addStroke(list, OUTLINE, 0.2)
	make("UIListLayout", list, {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
	make("UIPadding", list, {
		PaddingTop = UDim.new(0, 5),
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
	})
	return list
end

local colorPage = subPages.ores

local colorRow = createRow(colorPage, 0, "Colors")
local colorDropdown = createValueButton(colorRow, "Choose colors" .. CHEVRON_DOWN, 265)
local colorList = createDropdownList(colorPage, 62)

local colorSwitchRow, colorStatus = createRow(colorPage, 64, "Highlight", "Highlights off")
local colorDropdownOpen = false

local function updateColorDropdownText()
	local count = 0
	for hex in pairs(colorData) do
		if enabledColors[hex] then
			count += 1
		end
	end
	local label = count == 0 and "Choose colors" or string.format("%d selected", count)
	colorDropdown.Text = label .. (colorDropdownOpen and CHEVRON_UP or CHEVRON_DOWN)
end

local setGotoDropdownOpen

local function setColorDropdownOpen(open)
	colorDropdownOpen = open
	animate(colorList, 0.22, { Size = UDim2.fromOffset(704, open and 140 or 0) })
	if open and setGotoDropdownOpen then
		setGotoDropdownOpen(false)
	end
	updateColorDropdownText()
end

local gotoSelected
local gotoDropdownOpen = false
local latestEntries = {}
local lastGotoSignature

local gotoRow, gotoStatus = createRow(colorPage, 128, "Go to color", "Choose a color")
local gotoDropdown = createValueButton(gotoRow, "Choose" .. CHEVRON_DOWN, 190)
gotoDropdown.Position = UDim2.new(1, -(190 + 12 + 104 + 10), 0.5, -19)
gotoDropdown.TextTruncate = Enum.TextTruncate.AtEnd

local gotoButton = make("TextButton", gotoRow, {
	Position = UDim2.new(1, -(104 + 12), 0.5, -19),
	Size = UDim2.fromOffset(104, 38),
	BackgroundColor3 = Color3.fromRGB(40, 38, 40),
	BorderSizePixel = 0,
	Text = "TELEPORT",
	TextColor3 = Color3.fromRGB(228, 228, 230),
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	AutoButtonColor = false,
})
addCorner(gotoButton, 8)
addStroke(gotoButton, OUTLINE, 0.2)
addHover(gotoButton, Color3.fromRGB(40, 38, 40), mutedRed)

local gotoList = createDropdownList(colorPage, 190)

local function updateGotoDropdownText()
	local label = gotoSelected and gotoSelected.name or "Choose"
	gotoDropdown.Text = label .. (gotoDropdownOpen and CHEVRON_UP or CHEVRON_DOWN)
end

setGotoDropdownOpen = function(open)
	gotoDropdownOpen = open
	animate(gotoList, 0.22, { Size = UDim2.fromOffset(704, open and 100 or 0) })
	if open then
		setColorDropdownOpen(false)
	end
	updateGotoDropdownText()
end

local function gotoSignature(entries)
	local pieces = {}
	for _, entry in ipairs(entries) do
		table.insert(pieces, entry.hex)
	end
	table.insert(pieces, gotoSelected and gotoSelected.hex or "-")
	return table.concat(pieces, "|")
end

local function rebuildGotoOptions(entries)
	lastGotoSignature = gotoSignature(entries)
	for _, child in ipairs(gotoList:GetChildren()) do
		if child:IsA("GuiButton") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		make("TextLabel", gotoList, {
			Size = UDim2.new(1, -12, 0, 30),
			BackgroundTransparency = 1,
			Text = "No colors found",
			TextColor3 = MUTED,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			ZIndex = 9,
		})
		gotoList.CanvasSize = UDim2.new(0, 0, 0, 40)
		updateGotoDropdownText()
		return
	end

	for index, entry in ipairs(entries) do
		local isSelected = gotoSelected ~= nil and gotoSelected.hex == entry.hex
		local row = make("TextButton", gotoList, {
			LayoutOrder = index,
			Size = UDim2.new(1, -4, 0, 31),
			BackgroundColor3 = isSelected and ACTIVE_GREEN or ROW,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 9,
		})
		addCorner(row, 7)
		local swatch = make("Frame", row, {
			Position = UDim2.new(0, 12, 0.5, -7),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = entry.color,
			BorderSizePixel = 0,
			ZIndex = 10,
		})
		addCorner(swatch, 4)
		addStroke(swatch, Color3.fromRGB(255, 255, 255), 0.75)
		make("TextLabel", row, {
			Position = UDim2.fromOffset(38, 0),
			Size = UDim2.new(1, -130, 1, 0),
			BackgroundTransparency = 1,
			Text = entry.label,
			TextColor3 = isSelected and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 10,
		})
		make("TextLabel", row, {
			Position = UDim2.new(1, -92, 0, 0),
			Size = UDim2.fromOffset(78, 31),
			BackgroundTransparency = 1,
			Text = isSelected and "SELECTED" or "",
			TextColor3 = Color3.fromRGB(198, 232, 205),
			Font = Enum.Font.GothamBold,
			TextSize = 9,
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 10,
		})
		row.Activated:Connect(function()
			gotoSelected = { hex = entry.hex, name = entry.name }
			config.gotoHex = entry.hex
			config.gotoName = entry.name
			saveSettings()
			gotoStatus.Text = entry.name .. " selected"
			setGotoDropdownOpen(false)
			task.defer(function()
				if gui.Parent then
					rebuildGotoOptions(latestEntries)
				end
			end)
		end)
		addHover(row, isSelected and ACTIVE_GREEN or ROW, isSelected and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
	end
	gotoList.CanvasSize = UDim2.new(0, 0, 0, #entries * 35 + 10)
	updateGotoDropdownText()
end

gotoDropdown.Activated:Connect(function()
	setGotoDropdownOpen(not gotoDropdownOpen)
end)

local countsList = createDropdownList(subPages.counts, 0)
countsList.Size = UDim2.fromOffset(704, 296)
countsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
countsList.CanvasSize = UDim2.new(0, 0, 0, 0)
countsList.ScrollingDirection = Enum.ScrollingDirection.Y
countsList:FindFirstChildOfClass("UIPadding").PaddingBottom = UDim.new(0, 5)

local function rebuildCountRows(entries)
	for _, child in ipairs(countsList:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		make("TextLabel", countsList, {
			Size = UDim2.new(1, -12, 0, 30),
			BackgroundTransparency = 1,
			Text = "No colors found",
			TextColor3 = MUTED,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			ZIndex = 9,
		})
		return
	end

	local enabledEntries = {}
	local disabledEntries = {}
	for _, entry in ipairs(entries) do
		table.insert(enabledColors[entry.hex] and enabledEntries or disabledEntries, entry)
	end
	local function byCount(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.label < b.label
	end
	table.sort(enabledEntries, byCount)
	table.sort(disabledEntries, byCount)

	local order = 0
	local function addHeader(text)
		order += 1
		make("TextLabel", countsList, {
			LayoutOrder = order,
			Size = UDim2.new(1, -12, 0, 22),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = DIM,
			Font = Enum.Font.GothamBold,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 9,
		})
	end

	local function addRow(entry, isEnabled)
		order += 1
		local row = make("Frame", countsList, {
			LayoutOrder = order,
			Size = UDim2.new(1, -4, 0, 31),
			BackgroundColor3 = isEnabled and ACTIVE_GREEN or ROW,
			BorderSizePixel = 0,
			ZIndex = 9,
		})
		addCorner(row, 7)
		local swatch = make("Frame", row, {
			Position = UDim2.new(0, 12, 0.5, -7),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = entry.color,
			BorderSizePixel = 0,
			ZIndex = 10,
		})
		addCorner(swatch, 4)
		addStroke(swatch, Color3.fromRGB(255, 255, 255), 0.75)
		make("TextLabel", row, {
			Position = UDim2.fromOffset(38, 0),
			Size = UDim2.new(1, -176, 1, 0),
			BackgroundTransparency = 1,
			Text = entry.label,
			TextColor3 = isEnabled and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 10,
		})
		if isEnabled then
			make("TextLabel", row, {
				Position = UDim2.new(1, -128, 0, 0),
				Size = UDim2.fromOffset(40, 31),
				BackgroundTransparency = 1,
				Text = "ON",
				TextColor3 = Color3.fromRGB(198, 232, 205),
				Font = Enum.Font.GothamBold,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 10,
			})
		end
		make("TextLabel", row, {
			Position = UDim2.new(1, -80, 0, 0),
			Size = UDim2.fromOffset(66, 31),
			BackgroundTransparency = 1,
			Text = tostring(entry.count),
			TextColor3 = WHITE,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 10,
		})
	end

	if #enabledEntries > 0 then
		addHeader("ENABLED")
		for _, entry in ipairs(enabledEntries) do
			addRow(entry, true)
		end
	end
	if #disabledEntries > 0 then
		addHeader("DISABLED")
		for _, entry in ipairs(disabledEntries) do
			addRow(entry, false)
		end
	end
end

local minePage = subPages.mine

local mineSwitchRow, mineStatus = createRow(minePage, 0, "Auto mine", "Off")
local teleportSwitchRow, blockTeleportStatus = createRow(minePage, 64, "Teleport to blocks", "Off")
local toolRow = createRow(minePage, 128, "Tool")
local toolDropdown = createValueButton(toolRow, "Scanning tools" .. CHEVRON_DOWN, 265)
local toolList = createDropdownList(minePage, 190)
local toolDropdownOpen = false

local function updateToolDropdownText()
	local label = selectedTool and toolLabels[selectedTool] or "No tools found"
	toolDropdown.Text = label .. (toolDropdownOpen and CHEVRON_UP or CHEVRON_DOWN)
end

local function setToolDropdownOpen(open)
	toolDropdownOpen = open
	animate(toolList, 0.22, { Size = UDim2.fromOffset(704, open and 100 or 0) })
	updateToolDropdownText()
end

local boxPage = pages.box
local boxSwitchRow, boxStatus = createRow(boxPage, 38, "Auto box", "Off")

local teleportPage = subPages.teleport

local function createTeleportRow(y, title, coords)
	local row = createRow(teleportPage, y, title, coords)
	local button = make("TextButton", row, {
		Position = UDim2.new(1, -132, 0.5, -19),
		Size = UDim2.fromOffset(114, 38),
		BackgroundColor3 = Color3.fromRGB(40, 38, 40),
		BorderSizePixel = 0,
		Text = "TELEPORT",
		TextColor3 = Color3.fromRGB(228, 228, 230),
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		AutoButtonColor = false,
	})
	addCorner(button, 8)
	addStroke(button, OUTLINE, 0.2)
	addHover(button, Color3.fromRGB(40, 38, 40), mutedRed)
	return button
end

local shopTeleport = createTeleportRow(0, "Mine Shop", "-481, 1053, -649")
local mineTeleport = createTeleportRow(64, "Mine", "949, 1183, -464")

local function teleportTo(x, y, z)
	local character = player.Character or player.CharacterAdded:Wait()
	local root = character:WaitForChild("HumanoidRootPart")
	root.CFrame = CFrame.new(x, y, z)
end

shopTeleport.Activated:Connect(function()
	teleportTo(-481, 1053, -649)
end)
mineTeleport.Activated:Connect(function()
	teleportTo(949, 1183, -464)
end)

local settingsStatus, keyButton

do
local settingsPage = pages.settings

local keyRow
keyRow, settingsStatus = createRow(settingsPage, 0, "Toggle key", "Press the key to show or hide this UI")
keyButton = createValueButton(keyRow, toggleKey.Name, 155)

keyButton.Activated:Connect(function()
	waitingForKey = true
	keyButton.Text = "Press a key..."
	settingsStatus.Text = "Press any key to set the UI toggle"
end)

local ACCENT_PRESETS = {
	Color3.fromRGB(214, 62, 58),
	Color3.fromRGB(230, 126, 34),
	Color3.fromRGB(235, 190, 50),
	Color3.fromRGB(60, 185, 100),
	Color3.fromRGB(40, 180, 190),
	Color3.fromRGB(66, 133, 244),
	Color3.fromRGB(150, 90, 230),
	Color3.fromRGB(232, 90, 160),
}

local presetRow = createRow(settingsPage, 64, "Accent color", "Pick a preset")
local SWATCH_SIZE = 26
local SWATCH_PITCH = 34
for index, presetColor in ipairs(ACCENT_PRESETS) do
	local swatch = make("TextButton", presetRow, {
		Position = UDim2.new(1, -(18 + SWATCH_SIZE + (#ACCENT_PRESETS - index) * SWATCH_PITCH), 0.5, -SWATCH_SIZE / 2),
		Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE),
		BackgroundColor3 = presetColor,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
	})
	addCorner(swatch, SWATCH_SIZE / 2)
	local stroke = addStroke(swatch, WHITE, 0.7)
	table.insert(themeUpdaters, function()
		local selected = ACCENT:ToHex() == presetColor:ToHex()
		stroke.Transparency = selected and 0 or 0.7
		stroke.Thickness = selected and 2 or 1
	end)
	swatch.MouseEnter:Connect(function()
		animate(swatch, 0.12, { Size = UDim2.fromOffset(SWATCH_SIZE + 2, SWATCH_SIZE + 2) })
	end)
	swatch.MouseLeave:Connect(function()
		animate(swatch, 0.16, { Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE) })
	end)
	swatch.Activated:Connect(function()
		applyAccent(presetColor)
	end)
end

local hexRow, hexStatus = createRow(settingsPage, 128, "Custom color", "Enter a hex code, e.g. #D63E3A")
local hexPreview = make("Frame", hexRow, {
	Position = UDim2.new(1, -(120 + 12 + 10 + 22), 0.5, -11),
	Size = UDim2.fromOffset(22, 22),
	BackgroundColor3 = ACCENT,
	BorderSizePixel = 0,
})
addCorner(hexPreview, 6)
addStroke(hexPreview, WHITE, 0.75)

local hexBox = make("TextBox", hexRow, {
	Position = UDim2.new(1, -(120 + 12), 0.5, -19),
	Size = UDim2.fromOffset(120, 38),
	BackgroundColor3 = Color3.fromRGB(32, 32, 34),
	BorderSizePixel = 0,
	Text = "#" .. ACCENT:ToHex():upper(),
	PlaceholderText = "#D63E3A",
	PlaceholderColor3 = DIM,
	TextColor3 = Color3.fromRGB(200, 200, 204),
	Font = Enum.Font.GothamMedium,
	TextSize = 12,
	ClearTextOnFocus = false,
})
addCorner(hexBox, 8)
addStroke(hexBox, Color3.fromRGB(70, 70, 73), 0.25)

hexBox.FocusLost:Connect(function()
	local cleaned = (hexBox.Text:gsub("[%s#]", ""))
	if cleaned:match("^%x%x%x%x%x%x$") then
		local ok, color = pcall(Color3.fromHex, "#" .. cleaned)
		if ok and typeof(color) == "Color3" then
			hexStatus.Text = "Enter a hex code, e.g. #D63E3A"
			applyAccent(color)
			return
		end
	end
	hexStatus.Text = "Invalid hex code"
	hexBox.Text = "#" .. ACCENT:ToHex():upper()
end)

table.insert(themeUpdaters, function()
	hexPreview.BackgroundColor3 = ACCENT
	hexBox.Text = "#" .. ACCENT:ToHex():upper()
end)

local okAccent, savedAccent = false, nil
if config.accent then
	okAccent, savedAccent = pcall(Color3.fromHex, config.accent)
end
applyAccent(okAccent and typeof(savedAccent) == "Color3" and savedAccent or ACCENT)

local LINK = "https://guns.lol/Limpan"
local creditRow, creditStatus = createRow(settingsPage, 192, "Credits", "UI and script by Limpan")
local linkButton = make("TextButton", creditRow, {
	Position = UDim2.new(1, -(150 + 12), 0.5, -19),
	Size = UDim2.fromOffset(150, 38),
	BackgroundColor3 = Color3.fromRGB(40, 38, 40),
	BorderSizePixel = 0,
	Text = "guns.lol/Limpan",
	TextColor3 = Color3.fromRGB(228, 228, 230),
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	AutoButtonColor = false,
})
addCorner(linkButton, 8)
addStroke(linkButton, OUTLINE, 0.2)
addHover(linkButton, Color3.fromRGB(40, 38, 40), mutedRed)

linkButton.Activated:Connect(function()
	local opened = pcall(function()
		GuiService:OpenBrowserWindow(LINK)
	end)
	local copied = false
	if setclipboard then
		copied = pcall(setclipboard, LINK)
	end
	if copied then
		creditStatus.Text = "Link copied to clipboard"
	elseif opened then
		creditStatus.Text = "Opening link..."
	else
		creditStatus.Text = LINK
	end
end)	
end

local dragging = false
local dragStart
local startPosition
local dragInput

dragHandle.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPosition = window.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end
end)

dragHandle.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
	end
end)

local function setWindowVisible(visible)
	if uiVisible == visible then
		return
	end
	uiVisible = visible
	visibilityGeneration += 1
	local generation = visibilityGeneration

	if visible then
		window.Visible = true
		window.GroupTransparency = 1
		uiScale.Scale = 0.96
		animate(window, 0.22, { GroupTransparency = 0 })
		animate(uiScale, 0.22, { Scale = 1 })
	else
		local fade = animate(window, 0.17, { GroupTransparency = 1 })
		animate(uiScale, 0.17, { Scale = 0.96 })
		fade.Completed:Connect(function()
			if generation == visibilityGeneration and not uiVisible then
				window.Visible = false
			end
		end)
	end
end

closeButton.Activated:Connect(function()
	setWindowVisible(false)
end)

table.insert(globalConnections, UserInputService.InputChanged:Connect(function(input)
	if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseMovement) then
		local delta = input.Position - dragStart
		window.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end
end))

table.insert(globalConnections, UserInputService.InputBegan:Connect(function(input, processed)
	if waitingForKey then
		if input.KeyCode ~= Enum.KeyCode.Unknown then
			toggleKey = input.KeyCode
			config.toggleKey = toggleKey.Name
			saveSettings()
			waitingForKey = false
			keyButton.Text = toggleKey.Name
			settingsStatus.Text = string.format("The %s key toggles this window", toggleKey.Name)
		end
		return
	end

	if not processed and input.KeyCode == toggleKey then
		setWindowVisible(not uiVisible)
	end
end))

local function colorKey(color)
	return color:ToHex():upper()
end

local ORE_NAMES = {
	["shamrock"] = "Emerald",
	["black"] = "Coal",
	["toothpaste"] = "Diamond",
	["deep orange"] = "Palladium",
	["hot pink"] = "Amethyst",
	["institutional white"] = "Unobtainium",
	["oyster"] = "Platinum",
	["pastel green"] = "Jade",
	["persimmon"] = "Ruby",
	["smoky grey"] = "Titanium",
	["smoky gray"] = "Titanium",
	["new yeller"] = "Gold",
	["cyan"] = "Kyanite",
	["medium brown"] = "Tough Stone",
	["light grey metallic"] = "Moonstone",
	["light gray metallic"] = "Moonstone",
	["light grey"] = "Moonite",
	["light gray"] = "Moonite",
}

local function colorDisplayName(color)
	local name = BrickColor.new(color).Name
	return ORE_NAMES[name:lower()] or name
end

local function rebuildColorOptions(entries)
	for _, child in ipairs(colorList:GetChildren()) do
		if child:IsA("GuiButton") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	if #entries == 0 then
		make("TextLabel", colorList, {
			Size = UDim2.new(1, -12, 0, 30),
			BackgroundTransparency = 1,
			Text = "No eligible colors found",
			TextColor3 = MUTED,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			ZIndex = 9,
		})
		colorList.CanvasSize = UDim2.new(0, 0, 0, 40)
		return
	end

	for index, entry in ipairs(entries) do
		local isEnabled = enabledColors[entry.hex] == true
		local row = make("TextButton", colorList, {
			LayoutOrder = index,
			Size = UDim2.new(1, -4, 0, 31),
			BackgroundColor3 = isEnabled and ACTIVE_GREEN or ROW,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 9,
		})
		addCorner(row, 7)
		local swatch = make("Frame", row, {
			Position = UDim2.new(0, 12, 0.5, -7),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = entry.color,
			BorderSizePixel = 0,
			ZIndex = 10,
		})
		addCorner(swatch, 4)
		addStroke(swatch, Color3.fromRGB(255, 255, 255), 0.75)
		make("TextLabel", row, {
			Position = UDim2.fromOffset(38, 0),
			Size = UDim2.new(1, -100, 1, 0),
			BackgroundTransparency = 1,
			Text = entry.label,
			TextColor3 = isEnabled and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 10,
		})
		make("TextLabel", row, {
			Position = UDim2.new(1, -62, 0, 0),
			Size = UDim2.fromOffset(48, 31),
			BackgroundTransparency = 1,
			Text = isEnabled and "ON" or "",
			TextColor3 = Color3.fromRGB(198, 232, 205),
			Font = Enum.Font.GothamBold,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 10,
		})
		row.Activated:Connect(function()
			if enabledColors[entry.hex] then
				enabledColors[entry.hex] = nil
			else
				enabledColors[entry.hex] = true
			end
			local list = {}
			for hex in pairs(enabledColors) do
				table.insert(list, hex)
			end
			config.colors = list
			saveSettings()
			scheduleColorRefresh()
		end)
		addHover(row, isEnabled and ACTIVE_GREEN or ROW, isEnabled and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
	end
	colorList.CanvasSize = UDim2.new(0, 0, 0, #entries * 35 + 10)
end

local function colorsSignature(entries, withCounts)
	local pieces = {}
	for _, entry in ipairs(entries) do
		table.insert(pieces, string.format(
			"%s:%s:%s",
			entry.hex,
			enabledColors[entry.hex] and "1" or "0",
			withCounts and tostring(entry.count) or ""
		))
	end
	return table.concat(pieces, "|")
end

refreshHighlights = function()
	local shown = {}
	local enabledHexes = {}
	local totalMatches = 0
	for hex in pairs(enabledColors) do
		local list = partsByHex[hex]
		if list and #list > 0 then
			table.insert(enabledHexes, hex)
			totalMatches += #list
		end
	end
	table.sort(enabledHexes)

	if highlightingEnabled and #enabledHexes > 0 then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local origin = root and root.Position

		local ordered = {}
		for _, hex in ipairs(enabledHexes) do
			local list = table.clone(partsByHex[hex])
			if origin then
				local distances = {}
				for _, part in ipairs(list) do
					local offset = part.Position - origin
					distances[part] = offset:Dot(offset)
				end
				table.sort(list, function(a, b)
					return distances[a] < distances[b]
				end)
			end
			table.insert(ordered, list)
		end

		local shownCount = 0
		local index = 1
		local progressed = true
		while progressed and shownCount < MAX_HIGHLIGHTS do
			progressed = false
			for _, list in ipairs(ordered) do
				local part = list[index]
				if part and shownCount < MAX_HIGHLIGHTS then
					progressed = true
					shownCount += 1
					shown[part] = true
					local highlight = highlights[part]
					if not highlight then
						highlight = Instance.new("Highlight")
						highlight.Name = "BlockColorFilterHighlight"
						highlight.Adornee = part
						highlight.Parent = workspace
						highlights[part] = highlight
					end
					highlight.FillColor = part.Color
					highlight.OutlineColor = part.Color
					highlight.FillTransparency = 0.4
					highlight.OutlineTransparency = 0
				end
			end
			index += 1
		end
	end

	for part, highlight in pairs(highlights) do
		if not shown[part] then
			highlight:Destroy()
			highlights[part] = nil
		end
	end

	if not highlightingEnabled then
		colorStatus.Text = "Highlights off"
	elseif #enabledHexes == 0 then
		colorStatus.Text = "Choose colors above"
	elseif totalMatches > MAX_HIGHLIGHTS then
		colorStatus.Text = string.format("Showing nearest %d of %d parts", MAX_HIGHLIGHTS, totalMatches)
	else
		colorStatus.Text = string.format("Showing %d part(s)", totalMatches)
	end
end

refreshColors = function()
	local currentParts = {}
	colorData = {}
	partsByHex = {}

	for _, instance in ipairs(blocksFolder:GetDescendants()) do
		if instance:IsA("BasePart") then
			currentParts[instance] = true
			local hex = colorKey(instance.Color)
			if hex ~= excludedHex then
				local info = colorData[hex]
				if not info then
					info = {
						hex = hex,
						color = instance.Color,
						name = colorDisplayName(instance.Color),
						label = string.format("%s  (#%s)", colorDisplayName(instance.Color), hex),
						count = 0,
					}
					colorData[hex] = info
					partsByHex[hex] = {}
				end
				info.count += 1
				table.insert(partsByHex[hex], instance)
			end
			if not watchedParts[instance] then
				watchedParts[instance] = instance:GetPropertyChangedSignal("Color"):Connect(scheduleColorRefresh)
			end
		end
	end

	for part, connection in pairs(watchedParts) do
		if not currentParts[part] then
			connection:Disconnect()
			watchedParts[part] = nil
		end
	end

	local entries = {}
	for _, info in pairs(colorData) do
		table.insert(entries, info)
	end
	table.sort(entries, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.label < b.label
	end)

	latestEntries = entries

	local colorSignature = colorsSignature(entries, false)
	if colorSignature ~= lastColorSignature then
		lastColorSignature = colorSignature
		rebuildColorOptions(entries)
	end
	local countSignature = colorsSignature(entries, true)
	if countSignature ~= lastCountSignature then
		lastCountSignature = countSignature
		rebuildCountRows(entries)
	end
	if gotoSignature(entries) ~= lastGotoSignature then
		rebuildGotoOptions(entries)
	end
	updateColorDropdownText()
	refreshHighlights()
end

scheduleColorRefresh = function()
	if colorRefreshPending then
		return
	end
	colorRefreshPending = true
	task.defer(function()
		colorRefreshPending = false
		if refreshColors and gui.Parent then
			refreshColors()
		end
	end)
end

createSwitch(colorSwitchRow, false, function(value)
	highlightingEnabled = value
	scheduleColorRefresh()
end)

colorDropdown.Activated:Connect(function()
	setColorDropdownOpen(not colorDropdownOpen)
end)

local function collectTools()
	local tools = {}
	local seen = {}
	local function addFrom(container)
		if not container then
			return
		end
		for _, item in ipairs(container:GetChildren()) do
			if item:IsA("Tool") and not seen[item] then
				seen[item] = true
				table.insert(tools, item)
			end
		end
	end
	addFrom(player:FindFirstChildOfClass("Backpack"))
	addFrom(player.Character)
	table.sort(tools, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return tools, seen
end

local function rebuildToolOptions(tools)
	for _, child in ipairs(toolList:GetChildren()) do
		if child:IsA("GuiButton") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	if #tools == 0 then
		make("TextLabel", toolList, {
			Size = UDim2.new(1, -12, 0, 30),
			BackgroundTransparency = 1,
			Text = "No tools in inventory",
			TextColor3 = MUTED,
			Font = Enum.Font.Gotham,
			TextSize = 11,
			ZIndex = 9,
		})
		toolList.CanvasSize = UDim2.new(0, 0, 0, 40)
		updateToolDropdownText()
		return
	end

	for index, tool in ipairs(tools) do
		local isSelected = selectedTool == tool
		local row = make("TextButton", toolList, {
			LayoutOrder = index,
			Size = UDim2.new(1, -4, 0, 31),
			BackgroundColor3 = isSelected and ACTIVE_GREEN or ROW,
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 9,
		})
		addCorner(row, 7)
		make("TextLabel", row, {
			Position = UDim2.fromOffset(14, 0),
			Size = UDim2.new(1, -112, 1, 0),
			BackgroundTransparency = 1,
			Text = toolLabels[tool],
			TextColor3 = isSelected and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
			Font = Enum.Font.Gotham,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 10,
		})
		make("TextLabel", row, {
			Position = UDim2.new(1, -92, 0, 0),
			Size = UDim2.fromOffset(78, 31),
			BackgroundTransparency = 1,
			Text = isSelected and "SELECTED" or "",
			TextColor3 = Color3.fromRGB(198, 232, 205),
			Font = Enum.Font.GothamBold,
			TextSize = 9,
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 10,
		})
		row.Activated:Connect(function()
			if selectedTool ~= tool then
				selectedTool = tool
				mineGeneration += 1
			end
			config.mineTool = tool.Name
			saveSettings()
			setToolDropdownOpen(false)
			scheduleToolRefresh()
		end)
		addHover(row, isSelected and ACTIVE_GREEN or ROW, isSelected and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
	end
	toolList.CanvasSize = UDim2.new(0, 0, 0, #tools * 35 + 10)
	updateToolDropdownText()
end

refreshTools = function()
	local tools, seen = collectTools()
	toolLabels = {}
	local duplicateCounts = {}
	for _, tool in ipairs(tools) do
		local key = tool.Name:lower()
		duplicateCounts[key] = (duplicateCounts[key] or 0) + 1
		toolLabels[tool] = duplicateCounts[key] == 1 and tool.Name or string.format("%s (%d)", tool.Name, duplicateCounts[key])
	end

	if selectedTool and not seen[selectedTool] then
		selectedTool = nil
		mineGeneration += 1
	end

	local preferred = config.mineTool and pickByName(tools, config.mineTool)
	if preferred and (not selectedTool or selectedTool.Name ~= config.mineTool) then
		selectedTool = preferred
		mineGeneration += 1
	end

	if not selectedTool and #tools > 0 then
		for _, tool in ipairs(tools) do
			if tool.Name:lower():find("pickaxe", 1, true) then
				selectedTool = tool
				break
			end
		end
		selectedTool = selectedTool or tools[1]
	end

	rebuildToolOptions(tools)
	if autoMineEnabled and not selectedTool then
		mineStatus.Text = "Choose a tool"
	elseif not autoMineEnabled then
		mineStatus.Text = "Off"
	end
end

scheduleToolRefresh = function()
	if toolRefreshPending then
		return
	end
	toolRefreshPending = true
	task.defer(function()
		toolRefreshPending = false
		if refreshTools and gui.Parent then
			refreshTools()
		end
	end)
end

toolDropdown.Activated:Connect(function()
	setToolDropdownOpen(not toolDropdownOpen)
end)

createSwitch(mineSwitchRow, false, function(value)
	if autoMineEnabled ~= value then
		autoMineEnabled = value
		mineGeneration += 1
	end
	mineStatus.Text = value and (selectedTool and "Starting..." or "Choose a tool") or "Off"
end)

createSwitch(teleportSwitchRow, false, function(value)
	autoTeleportEnabled = value
	blockTeleportStatus.Text = value and "Starting..." or "Off"
end)

createSwitch(boxSwitchRow, false, function(value)
	if autoBoxEnabled ~= value then
		autoBoxEnabled = value
		boxGeneration += 1
	end
	boxStatus.Text = value and "Starting..." or "Off"
end)

;(function()
	local npcClickRow, npcClickStatus = createRow(boxPage, 102, "Auto box quest", "Off")
	local boxesValueText = make("TextLabel", boxPage, {
		Name = "BoxesDeliveredLabel",
		Position = UDim2.new(1, -260, 0, 0),
		Size = UDim2.fromOffset(260, 28),
		BackgroundTransparency = 1,
		Text = "boxes delivered: --",
		TextColor3 = MUTED,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		Active = false,
		ZIndex = 9,
	})

	createSwitch(npcClickRow, false, function(value)
		globalConnections.npcBox.enabled = value
		npcClickStatus.Text = value and "Starting..." or "Off"
	end)

	local function getNpcBoxDetector()
		local npc = workspace:FindFirstChild("npc_becuz_why_not")
		local box = npc and npc:FindFirstChild("box")
		return box and box:FindFirstChild("ClickDetector")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			if globalConnections.npcBox.enabled then
				local detector = getNpcBoxDetector()
				if not detector then
					npcClickStatus.Text = "NPC box not found"
				elseif not fireclickdetector then
					npcClickStatus.Text = "fireclickdetector unavailable"
				else
					fireclickdetector(detector)
					npcClickStatus.Text = "Clicking NPC box"
				end
			end
			task.wait(globalConnections.npcBox.interval)
		end
	end)

	local boxesValueLabel

	local function findBoxesValueLabel()
		local main = workspace:FindFirstChild("MainPlace")
		local boxValue = main and main:FindFirstChild("BoxValue")
		local value = boxValue and boxValue:FindFirstChild("YourBoxesValue")
		local surface = value and value:FindFirstChild("SurfaceGui")
		local label = surface and surface:FindFirstChild("TextLabel")
		if label and label:IsA("TextLabel") then
			return label
		end
		return nil
	end

	local function updateBoxesText()
		boxesValueText.Text = "boxes delivered: " .. (boxesValueLabel and boxesValueLabel.Text or "--")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			local label = findBoxesValueLabel()
			if label ~= boxesValueLabel then
				if globalConnections.npcBox.connection then
					globalConnections.npcBox.connection:Disconnect()
					globalConnections.npcBox.connection = nil
				end
				boxesValueLabel = label
				if label then
					globalConnections.npcBox.connection = label:GetPropertyChangedSignal("Text"):Connect(updateBoxesText)
				end
			end
			updateBoxesText()
			task.wait(1)
		end
	end)
end)()

;(function()
	local KEYWORD = "box carrier"
	local enabled = false

	local equipRow, equipStatus = createRow(boxPage, 166, "Auto equip", "Off")
	local lastStatus
	local function setStatus(text)
		if lastStatus ~= text then
			lastStatus = text
			equipStatus.Text = text
		end
	end

	local function matches(item)
		return item:IsA("Tool") and item.Name:lower():find(KEYWORD, 1, true) ~= nil
	end

	local function findMatch(container)
		if container then
			for _, item in ipairs(container:GetChildren()) do
				if matches(item) then
					return item
				end
			end
		end
		return nil
	end

	createSwitch(equipRow, false, function(value)
		enabled = value
		setStatus(value and "Starting..." or "Off")
	end)

	task.spawn(function()
		while gui.Parent == playerGui do
			if enabled then
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if not (character and humanoid) or humanoid.Health <= 0 then
					setStatus("Waiting for character...")
				else
					local held = findMatch(character)
					if held then
						setStatus("Equipped " .. held.Name)
					else
						local tool = findMatch(player:FindFirstChildOfClass("Backpack"))
						if tool then
							setStatus("Equipping " .. tool.Name .. "...")
							humanoid:EquipTool(tool)
						else
							setStatus("Waiting for Box Carrier")
						end
					end
				end
			end
			task.wait(0.25)
		end
	end)

	gui.Destroying:Connect(function()
		enabled = false
	end)
end)()

;(function()
	local questRow, questStatus = createRow(minePage, 192, "Auto mine quest", "Off")
	local questState = { enabled = false, interval = 0.25 }

	createSwitch(questRow, false, function(value)
		questState.enabled = value
		questStatus.Text = value and "Starting..." or "Off"
	end)

	local function getPickaxeNpcDetector()
		local npc = workspace:FindFirstChild("npc_becuz_why_not")
		local pickaxeNpc = npc and npc:FindFirstChild("FreePickaxeNPC")
		return pickaxeNpc and pickaxeNpc:FindFirstChild("ClickDetector")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			if questState.enabled then
				local detector = getPickaxeNpcDetector()
				if not detector then
					questStatus.Text = "NPC pickaxe not found"
				elseif not fireclickdetector then
					questStatus.Text = "fireclickdetector unavailable"
				else
					fireclickdetector(detector)
					questStatus.Text = "Clicking NPC pickaxe"
				end
			end
			task.wait(questState.interval)
		end
	end)

	gui.Destroying:Connect(function()
		questState.enabled = false
	end)
end)()

;(function()
	local VirtualInputManager = game:GetService("VirtualInputManager")
	local fishState = globalConnections.fish
	fishState.tool = nil
	local fishPage = pages.fishing

	local fishSwitchRow, fishStatus = createRow(fishPage, 38, "Auto fish", "Off")
	local rodRow = createRow(fishPage, 102, "Rod")
	local rodButton = createValueButton(rodRow, "No rod selected" .. CHEVRON_DOWN, 265)
	local teleportRow = createRow(fishPage, 166, "Fish location", "Teleports here when auto fish starts")
	local questRow, questStatus = createRow(fishPage, 230, "Auto fishing quest", "Off")
	local rodList = createDropdownList(fishPage, 164)
	local rodDropdownOpen = false
	local setLocationOpen

	local caughtLabel = make("TextLabel", fishPage, {
		Name = "FishesCaughtLabel",
		Position = UDim2.new(1, -260, 0, 0),
		Size = UDim2.fromOffset(260, 28),
		BackgroundTransparency = 1,
		Text = "fishes caught: --",
		TextColor3 = MUTED,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		Active = false,
		ZIndex = 9,
	})

	local function cast(x, y, z)
		return CFrame.new(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end

	local LOCATIONS = {
		{
			name = "Normal pond",
			position = Vector3.new(-43, 748, 203),
			cast = cast(-45.794429779052734, 742.702392578125, 204.17762756347656),
			water = { "SkyIsland", "CloudsWater" },
		},
		{
			name = "Sky",
			position = Vector3.new(113, 905, 274),
			cast = cast(114.66998291015625, 901.9917602539062, 275.0465393066406),
			water = { "SkyIsland", "Ground", "CloudsWater" },
		},
		{
			name = "Lava",
			position = Vector3.new(-10, -283, 17),
			cast = cast(-10.903992652893066, -288.572509765625, 18.689739227294922),
			water = { "Sewers", "LavaWater" },
		},
		{
			name = "Sewer",
			position = Vector3.new(-4, -223, -9),
			cast = cast(-3.5957908630371094, -226.57249450683594, -6.208518981933594),
			water = { "Sewers", "SewageWater", "SewerWater" },
		},
				{
			name = "Cave",
			position = Vector3.new(915, 1248, -459),
			cast = cast(915.5115356445312, 1243.9998779296875, -459.937255859375),
			water = { "Frozen Island", "cave thing", "FrozenWater" },
		},
	}
	fishState.location = LOCATIONS[1]
	for _, location in ipairs(LOCATIONS) do
		if location.name == config.fishLocation then
			fishState.location = location
		end
	end

	local function findWater(path)
		local current = workspace
		for _, name in ipairs(path) do
			current = current and current:FindFirstChild(name)
		end
		return current
	end
	local LOOP_INTERVAL = 0.1
	local CAST_INTERVAL = 0.5
	local CLICK_HOLD = 0.03

	local fishRemote
	local hookInstalled = false
	local hookFailed = false
	local lastStatus

	local function setStatus(text)
		if lastStatus ~= text then
			lastStatus = text
			fishStatus.Text = text
		end
	end

	local function updateRodText()
		local label = fishState.tool and (toolLabels[fishState.tool] or fishState.tool.Name) or "No rod selected"
		rodButton.Text = label .. (rodDropdownOpen and CHEVRON_UP or CHEVRON_DOWN)
	end

	local function setRodDropdownOpen(open)
		rodDropdownOpen = open
		animate(rodList, 0.22, { Size = UDim2.fromOffset(704, open and 100 or 0) })
		if open and setLocationOpen then
			setLocationOpen(false)
		end
		updateRodText()
	end

	local function rebuildRodOptions(tools)
		for _, child in ipairs(rodList:GetChildren()) do
			if child:IsA("GuiButton") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		if #tools == 0 then
			make("TextLabel", rodList, {
				Size = UDim2.new(1, -12, 0, 30),
				BackgroundTransparency = 1,
				Text = "No tools in inventory",
				TextColor3 = MUTED,
				Font = Enum.Font.Gotham,
				TextSize = 11,
				ZIndex = 9,
			})
			rodList.CanvasSize = UDim2.new(0, 0, 0, 40)
			updateRodText()
			return
		end

		for index, tool in ipairs(tools) do
			local isSelected = fishState.tool == tool
			local row = make("TextButton", rodList, {
				LayoutOrder = index,
				Size = UDim2.new(1, -4, 0, 31),
				BackgroundColor3 = isSelected and ACTIVE_GREEN or ROW,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				ZIndex = 9,
			})
			addCorner(row, 7)
			make("TextLabel", row, {
				Position = UDim2.fromOffset(14, 0),
				Size = UDim2.new(1, -112, 1, 0),
				BackgroundTransparency = 1,
				Text = toolLabels[tool] or tool.Name,
				TextColor3 = isSelected and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 10,
			})
			make("TextLabel", row, {
				Position = UDim2.new(1, -92, 0, 0),
				Size = UDim2.fromOffset(78, 31),
				BackgroundTransparency = 1,
				Text = isSelected and "SELECTED" or "",
				TextColor3 = Color3.fromRGB(198, 232, 205),
				Font = Enum.Font.GothamBold,
				TextSize = 9,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 10,
			})
			row.Activated:Connect(function()
				fishState.tool = tool
				config.rod = tool.Name
				saveSettings()
				setRodDropdownOpen(false)
				scheduleToolRefresh()
			end)
			addHover(row, isSelected and ACTIVE_GREEN or ROW, isSelected and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
		end
		rodList.CanvasSize = UDim2.new(0, 0, 0, #tools * 35 + 10)
		updateRodText()
	end

	local function refreshRods()
		local tools, seen = collectTools()
		if fishState.tool and not seen[fishState.tool] then
			fishState.tool = nil
		end
		local preferred = config.rod and pickByName(tools, config.rod)
		if preferred and (not fishState.tool or fishState.tool.Name ~= config.rod) then
			fishState.tool = preferred
		end
		if not fishState.tool then
			for _, tool in ipairs(tools) do
				if tool.Name:lower():find("rod", 1, true) then
					fishState.tool = tool
					break
				end
			end
		end
		rebuildRodOptions(tools)
		if not fishState.enabled then
			setStatus("Off")
		end
	end

	local baseRefreshTools = refreshTools
	refreshTools = function()
		baseRefreshTools()
		refreshRods()
	end

	rodButton.Activated:Connect(function()
		setRodDropdownOpen(not rodDropdownOpen)
	end)

	local function installHook()
		if hookInstalled then
			return
		end
		if not (hookmetamethod and newcclosure and getnamecallmethod) then
			hookFailed = true
			return
		end
		hookInstalled = true
		local old
		old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			if fishState.enabled and self == fishRemote and getnamecallmethod() == "FireServer" then
				local args = table.pack(...)
				if args[1] == "Catch" and args[2] == false then
					args[2] = true
					return old(self, table.unpack(args, 1, args.n))
				end
			end
			return old(self, ...)
		end))
	end

	createSwitch(fishSwitchRow, false, function(value)
		fishState.enabled = value
		fishState.pendingTeleport = value
		if value then
			installHook()
			setStatus("Starting...")
		else
			setStatus("Off")
		end
	end)

	local function addTeleportButton(offsetFromRight, text, x, y, z)
		local button = make("TextButton", teleportRow, {
			Position = UDim2.new(1, -offsetFromRight, 0.5, -19),
			Size = UDim2.fromOffset(100, 38),
			BackgroundColor3 = Color3.fromRGB(40, 38, 40),
			BorderSizePixel = 0,
			Text = text,
			TextColor3 = Color3.fromRGB(228, 228, 230),
			Font = Enum.Font.GothamBold,
			TextSize = 10,
			AutoButtonColor = false,
		})
		addCorner(button, 8)
		addStroke(button, OUTLINE, 0.2)
		addHover(button, Color3.fromRGB(40, 38, 40), mutedRed)
		button.Activated:Connect(function()
			teleportTo(x, y, z)
		end)
	end
		local locationButton = createValueButton(teleportRow, "", 190)
	locationButton.Position = UDim2.new(1, -(190 + 12 + 100 + 10), 0.5, -19)
	local locationList = createDropdownList(fishPage, 228)
	local locationOpen = false

	local function updateLocationText()
		locationButton.Text = fishState.location.name .. (locationOpen and CHEVRON_UP or CHEVRON_DOWN)
	end

	local function rebuildLocationOptions()
		for _, child in ipairs(locationList:GetChildren()) do
			if child:IsA("GuiButton") then
				child:Destroy()
			end
		end
		for index, location in ipairs(LOCATIONS) do
			local isSelected = fishState.location == location
			local row = make("TextButton", locationList, {
				LayoutOrder = index,
				Size = UDim2.new(1, -4, 0, 31),
				BackgroundColor3 = isSelected and ACTIVE_GREEN or ROW,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				ZIndex = 9,
			})
			addCorner(row, 7)
			make("TextLabel", row, {
				Position = UDim2.fromOffset(14, 0),
				Size = UDim2.new(1, -112, 1, 0),
				BackgroundTransparency = 1,
				Text = location.name,
				TextColor3 = isSelected and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 10,
			})
			make("TextLabel", row, {
				Position = UDim2.new(1, -92, 0, 0),
				Size = UDim2.fromOffset(78, 31),
				BackgroundTransparency = 1,
				Text = isSelected and "SELECTED" or "",
				TextColor3 = Color3.fromRGB(198, 232, 205),
				Font = Enum.Font.GothamBold,
				TextSize = 9,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 10,
			})
			row.Activated:Connect(function()
				fishState.location = location
				config.fishLocation = location.name
				saveSettings()
				setLocationOpen(false)
				rebuildLocationOptions()
			end)
			addHover(row, isSelected and ACTIVE_GREEN or ROW, isSelected and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
		end
		locationList.CanvasSize = UDim2.new(0, 0, 0, #LOCATIONS * 35 + 10)
		updateLocationText()
	end

	setLocationOpen = function(open)
		locationOpen = open
		animate(locationList, 0.22, { Size = UDim2.fromOffset(704, open and 150 or 0) })
		if open then
			setRodDropdownOpen(false)
		end
		updateLocationText()
	end

	locationButton.Activated:Connect(function()
		setLocationOpen(not locationOpen)
	end)
	rebuildLocationOptions()
	addTeleportButton(112, "SHOP", 37, 756, 348)

	local questState = { enabled = false, interval = 0.25 }
	createSwitch(questRow, false, function(value)
		questState.enabled = value
		questStatus.Text = value and "Starting..." or "Off"
	end)

	local function getLeaderDetector()
		local area = workspace:FindFirstChild("NeutralArea")
		local leader = area and area:FindFirstChild("leader_null")
		return leader and leader:FindFirstChild("ClickDetector")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			if questState.enabled then
				local detector = getLeaderDetector()
				if not detector then
					questStatus.Text = "Quest NPC not found"
				elseif not fireclickdetector then
					questStatus.Text = "fireclickdetector unavailable"
				else
					fireclickdetector(detector)
					questStatus.Text = "Clicking quest NPC"
				end
			end
			task.wait(questState.interval)
		end
	end)

	local caughtValueLabel
	local caughtConnection

	local function findCaughtLabel()
		local main = workspace:FindFirstChild("MainPlace")
		local boxValue = main and main:FindFirstChild("BoxValue")
		local value = boxValue and boxValue:FindFirstChild("YourFishingQuestDiffValue")
		local surface = value and value:FindFirstChild("SurfaceGui")
		local label = surface and surface:FindFirstChild("TextLabel")
		if label and label:IsA("TextLabel") then
			return label
		end
		return nil
	end

	local function updateCaughtText()
		caughtLabel.Text = "fishes caught: " .. (caughtValueLabel and caughtValueLabel.Text or "--")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			local label = findCaughtLabel()
			if label ~= caughtValueLabel then
				if caughtConnection then
					caughtConnection:Disconnect()
					caughtConnection = nil
				end
				caughtValueLabel = label
				if label then
					caughtConnection = label:GetPropertyChangedSignal("Text"):Connect(updateCaughtText)
				end
			end
			updateCaughtText()
			task.wait(1)
		end
	end)

	gui.Destroying:Connect(function()
		questState.enabled = false
		if caughtConnection then
			caughtConnection:Disconnect()
			caughtConnection = nil
		end
	end)

	local function click()
		VirtualInputManager:SendMouseButtonEvent(500, 500, 0, true, game, 0)
		task.wait(CLICK_HOLD)
		VirtualInputManager:SendMouseButtonEvent(500, 500, 0, false, game, 0)
	end

	task.spawn(function()
		local lastRod
		local lastLocation
		local remote
		local water
		local lastCast = 0

		while gui.Parent == playerGui do
			if fishState.enabled then
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local backpack = player:FindFirstChildOfClass("Backpack")
				local rod = fishState.tool

				if rod ~= lastRod then
					lastRod = rod
					remote = nil
					fishRemote = nil
				end
				
				local location = fishState.location
				if location ~= lastLocation then
					lastLocation = location
					water = nil
				end

				local root = character and character:FindFirstChild("HumanoidRootPart")
				if fishState.pendingTeleport and root then
					fishState.pendingTeleport = false
					root.CFrame = CFrame.new(location.position)
					root.AssemblyLinearVelocity = Vector3.zero
					task.wait(0.5)
				end

				if not (character and humanoid) then
					setStatus("Waiting for character...")
				elseif not rod then
					setStatus("Choose a rod")
				elseif rod.Parent ~= character and not (backpack and rod.Parent == backpack) then
					setStatus("Rod no longer in inventory")
				elseif rod.Parent ~= character then
					setStatus("Equipping " .. rod.Name .. "...")
					humanoid:EquipTool(rod)
				else
					if not (remote and remote.Parent) then
						local scanner = rod:FindFirstChild("HitScanner")
						remote = scanner and scanner:FindFirstChild("RemoteEvent")
						fishRemote = remote
					end
					if not (water and water.Parent) then
						water = findWater(location.water)
					end

					if not remote then
						setStatus("Rod has no RemoteEvent")
					elseif not water then
						setStatus("Water not found")
					else
						local now = os.clock()
						if now - lastCast >= CAST_INTERVAL then
							lastCast = now
							remote:FireServer("Cast", location.cast, water)
						end
						pcall(click)
						setStatus(hookFailed and "Fishing (catch hook unavailable)" or "Fishing")
					end
				end
			end
			task.wait(LOOP_INTERVAL)
		end
	end)
end)()

;(function()
	local RunService = game:GetService("RunService")
	local VirtualInputManager = game:GetService("VirtualInputManager")
	local mopPage = pages.mopping
	local state = { enabled = false, tool = nil }

	local SWEEP_INTERVAL = 0.1
	local BUY_RETRY_DELAY = 5

	local mopSwitchRow, mopStatus = createRow(mopPage, 38, "Auto mop", "Off")
	local toolRow = createRow(mopPage, 102, "Tool")
	local toolButton = createValueButton(toolRow, "No tool selected" .. CHEVRON_DOWN, 265)
	local questRow, questStatus = createRow(mopPage, 166, "Auto mop quest", "Off")
	local minigameRow, minigameStatus = createRow(mopPage, 230, "Auto minigame", "Off")
	local toolList = createDropdownList(mopPage, 164)
	local dropdownOpen = false

	local puddlesLabel = make("TextLabel", mopPage, {
		Name = "PuddlesClearedLabel",
		Position = UDim2.new(1, -260, 0, 0),
		Size = UDim2.fromOffset(260, 28),
		BackgroundTransparency = 1,
		Text = "puddles cleared: --",
		TextColor3 = MUTED,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		Active = false,
		ZIndex = 9,
	})

	local lastStatus
	local function setStatus(text)
		if lastStatus ~= text then
			lastStatus = text
			mopStatus.Text = text
		end
	end

	local function updateDropdownText()
		local label = state.tool and (toolLabels[state.tool] or state.tool.Name) or "No tool selected"
		toolButton.Text = label .. (dropdownOpen and CHEVRON_UP or CHEVRON_DOWN)
	end

	local function setDropdownOpen(open)
		dropdownOpen = open
		animate(toolList, 0.22, { Size = UDim2.fromOffset(704, open and 100 or 0) })
		updateDropdownText()
	end

	local function rebuildOptions(tools)
		for _, child in ipairs(toolList:GetChildren()) do
			if child:IsA("GuiButton") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		if #tools == 0 then
			make("TextLabel", toolList, {
				Size = UDim2.new(1, -12, 0, 30),
				BackgroundTransparency = 1,
				Text = "No tools in inventory",
				TextColor3 = MUTED,
				Font = Enum.Font.Gotham,
				TextSize = 11,
				ZIndex = 9,
			})
			toolList.CanvasSize = UDim2.new(0, 0, 0, 40)
			updateDropdownText()
			return
		end

		for index, tool in ipairs(tools) do
			local isSelected = state.tool == tool
			local row = make("TextButton", toolList, {
				LayoutOrder = index,
				Size = UDim2.new(1, -4, 0, 31),
				BackgroundColor3 = isSelected and ACTIVE_GREEN or ROW,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				ZIndex = 9,
			})
			addCorner(row, 7)
			make("TextLabel", row, {
				Position = UDim2.fromOffset(14, 0),
				Size = UDim2.new(1, -112, 1, 0),
				BackgroundTransparency = 1,
				Text = toolLabels[tool] or tool.Name,
				TextColor3 = isSelected and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 10,
			})
			make("TextLabel", row, {
				Position = UDim2.new(1, -92, 0, 0),
				Size = UDim2.fromOffset(78, 31),
				BackgroundTransparency = 1,
				Text = isSelected and "SELECTED" or "",
				TextColor3 = Color3.fromRGB(198, 232, 205),
				Font = Enum.Font.GothamBold,
				TextSize = 9,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 10,
			})
			row.Activated:Connect(function()
				state.tool = tool
				config.mopTool = tool.Name
				saveSettings()
				setDropdownOpen(false)
				scheduleToolRefresh()
			end)
			addHover(row, isSelected and ACTIVE_GREEN or ROW, isSelected and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
		end
		toolList.CanvasSize = UDim2.new(0, 0, 0, #tools * 35 + 10)
		updateDropdownText()
	end

	local function refreshMopTools()
		local tools, seen = collectTools()
		if state.tool and not seen[state.tool] then
			state.tool = nil
		end
		local preferred = config.mopTool and pickByName(tools, config.mopTool)
		if preferred and (not state.tool or state.tool.Name ~= config.mopTool) then
			state.tool = preferred
		end
		if not state.tool then
			for _, tool in ipairs(tools) do
				if tool.Name:lower():find("mop", 1, true) then
					state.tool = tool
					break
				end
			end
		end
		rebuildOptions(tools)
		if not state.enabled then
			setStatus("Off")
		end
	end

	local baseRefreshTools = refreshTools
	refreshTools = function()
		baseRefreshTools()
		refreshMopTools()
	end

	toolButton.Activated:Connect(function()
		setDropdownOpen(not dropdownOpen)
	end)

	local buyAttempted = false
	local lastBuy = 0

	local function tryBuy()
		if not fireclickdetector then
			return false
		end
		if buyAttempted and os.clock() - lastBuy < BUY_RETRY_DELAY then
			return true
		end
		local buyables = workspace:FindFirstChild("Buyables_Important")
		local mopModel = buyables and buyables:FindFirstChild("mop")
		local detector = mopModel and mopModel:FindFirstChild("ClickDetector")
		if not detector then
			return false
		end
		if not buyAttempted then
			buyAttempted = true
			lastBuy = os.clock()
			fireclickdetector(detector)
		end
		return true
	end

	local parts = {}
	local activeCharacter
	local activeHumanoid
	local noclipConnection
	local addedConnection

	local function noclipStep()
		if activeHumanoid and activeHumanoid.Sit then
			activeHumanoid.Sit = false
			activeHumanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		for index = 1, #parts do
			parts[index].CanCollide = false
		end
	end

	local function setStatesEnabled(humanoid, enabled)
		pcall(humanoid.SetStateEnabled, humanoid, Enum.HumanoidStateType.Seated, enabled)
		pcall(humanoid.SetStateEnabled, humanoid, Enum.HumanoidStateType.FallingDown, enabled)
		pcall(humanoid.SetStateEnabled, humanoid, Enum.HumanoidStateType.Ragdoll, enabled)
	end

	local function deactivate()
		if noclipConnection then
			noclipConnection:Disconnect()
			noclipConnection = nil
		end
		if addedConnection then
			addedConnection:Disconnect()
			addedConnection = nil
		end
		if activeHumanoid then
			setStatesEnabled(activeHumanoid, true)
		end
		activeCharacter = nil
		activeHumanoid = nil
		table.clear(parts)
	end

	local function activate(character, humanoid)
		if activeCharacter == character then
			return
		end
		deactivate()
		activeCharacter = character
		activeHumanoid = humanoid
		setStatesEnabled(humanoid, false)
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				parts[#parts + 1] = descendant
			end
		end
		addedConnection = character.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				parts[#parts + 1] = descendant
			end
		end)
		noclipConnection = RunService.Stepped:Connect(noclipStep)
	end

	local function getAboveCFrame(item)
		local cf, size
		if item:IsA("BasePart") then
			cf, size = item.CFrame, item.Size
		else
			cf, size = item:GetBoundingBox()
		end
		return cf * CFrame.new(0, size.Y / 2 + 3, 0)
	end

	local function findNextPuddle(puddles)
		for _, item in ipairs(puddles:GetDescendants()) do
			if item.Name == "Puddle" and (item:IsA("BasePart") or item:IsA("Model")) then
				return item
			end
		end
		return nil
	end

	local function mopPuddle(puddles, puddle, character, humanoid, tool, sweep)
		local elapsed = 0
		while state.enabled
			and gui.Parent == playerGui
			and state.tool == tool
			and character.Parent
			and humanoid.Health > 0
			and puddle:IsDescendantOf(puddles) do
			if tool.Parent ~= character then
				humanoid:EquipTool(tool)
			end

			humanoid.Sit = false
			character:PivotTo(getAboveCFrame(puddle))

			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end

			elapsed += RunService.Heartbeat:Wait()
			if elapsed >= SWEEP_INTERVAL then
				sweep:FireServer()
				elapsed = 0
			end
		end
	end

	createSwitch(mopSwitchRow, false, function(value)
		state.enabled = value
		buyAttempted = false
		setStatus(value and "Starting..." or "Off")
	end)

	local minigameState = { enabled = false }
	local lastMinigameStatus

	local function setMinigameStatus(text)
		if lastMinigameStatus ~= text then
			lastMinigameStatus = text
			minigameStatus.Text = text
		end
	end

	createSwitch(minigameRow, false, function(value)
		minigameState.enabled = value
		setMinigameStatus(value and "Starting..." or "Off")
	end)

	local function clickAt(position)
		VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, true, game, 0)
		task.wait(0.05)
		VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, false, game, 0)
	end

	task.spawn(function()
		local button
		while gui.Parent == playerGui do
			if not minigameState.enabled then
				setMinigameStatus("Off")
			elseif not state.enabled then
				setMinigameStatus("Waiting for auto mop")
			else
				if not (button and button.Parent) then
					local minigame = playerGui:FindFirstChild("MoppingMinigame")
					button = minigame and minigame:FindFirstChild("sweepButton")
				end
				if not button then
					setMinigameStatus("Waiting for minigame")
				elseif button.Visible and button.AbsoluteSize.X > 0 then
					setMinigameStatus("Clicking sweep button")
					pcall(clickAt, button.AbsolutePosition + button.AbsoluteSize / 2)
				else
					setMinigameStatus("Waiting for minigame")
				end
			end
			task.wait(0.05)
		end
	end)

	local questState = { enabled = false, interval = 0.25 }
	local lastQuestStatus

	local function setQuestStatus(text)
		if lastQuestStatus ~= text then
			lastQuestStatus = text
			questStatus.Text = text
		end
	end

	createSwitch(questRow, false, function(value)
		questState.enabled = value
		setQuestStatus(value and "Starting..." or "Off")
	end)

	local function getJanitorDetector()
		local npc = workspace:FindFirstChild("npc_becuz_why_not")
		local janitor = npc and npc:FindFirstChild("janitor")
		return janitor and janitor:FindFirstChild("ClickDetector")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			if questState.enabled then
				local detector = getJanitorDetector()
				if not detector then
					setQuestStatus("NPC janitor not found")
				elseif not fireclickdetector then
					setQuestStatus("fireclickdetector unavailable")
				else
					fireclickdetector(detector)
					setQuestStatus("Clicking NPC janitor")
				end
			end
			task.wait(questState.interval)
		end
	end)

	task.spawn(function()
		while gui.Parent == playerGui do
			if not state.enabled then
				deactivate()
				task.wait(0.25)
			else
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local tool = state.tool
				local backpack = player:FindFirstChildOfClass("Backpack")

				if not (character and humanoid and root) or humanoid.Health <= 0 then
					setStatus("Waiting for character...")
					task.wait(0.25)
				elseif not tool and option.getBuyDetector then
					if tryBuy() then
						setStatus("Buying mop...")
					else
						setStatus("Choose a tool")
					end
					task.wait(0.25)
				elseif tool.Parent ~= character and not (backpack and tool.Parent == backpack) then
					setStatus("Tool no longer in inventory")
					task.wait(0.25)
				else
					local sweep = tool:FindFirstChild("SweepEvent", true)
					local puddles = workspace:FindFirstChild("Puddles")
					if not sweep or not sweep:IsA("RemoteEvent") then
						setStatus("Tool has no SweepEvent")
						task.wait(0.25)
					elseif not puddles then
						setStatus("Puddles folder not found")
						task.wait(0.25)
					else
						activate(character, humanoid)
						if tool.Parent ~= character then
							setStatus("Equipping " .. tool.Name .. "...")
							humanoid:EquipTool(tool)
							task.wait(0.1)
						else
							local puddle = findNextPuddle(puddles)
							if not puddle then
								setStatus("No puddles")
								task.wait(0.25)
							else
								setStatus("Mopping with " .. tool.Name)
								mopPuddle(puddles, puddle, character, humanoid, tool, sweep)
							end
						end
					end
				end
			end
		end
	end)

	local puddlesValueLabel
	local puddlesValueConnection

	local function findPuddlesValueLabel()
		local main = workspace:FindFirstChild("MainPlace")
		local boxValue = main and main:FindFirstChild("BoxValue")
		local value = boxValue and boxValue:FindFirstChild("YourPuddlesClearedVal")
		local surface = value and value:FindFirstChild("SurfaceGui")
		local label = surface and surface:FindFirstChild("TextLabel")
		if label and label:IsA("TextLabel") then
			return label
		end
		return nil
	end

	local function updatePuddlesText()
		puddlesLabel.Text = "puddles cleared: " .. (puddlesValueLabel and puddlesValueLabel.Text or "--")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			local label = findPuddlesValueLabel()
			if label ~= puddlesValueLabel then
				if puddlesValueConnection then
					puddlesValueConnection:Disconnect()
					puddlesValueConnection = nil
				end
				puddlesValueLabel = label
				if label then
					puddlesValueConnection = label:GetPropertyChangedSignal("Text"):Connect(updatePuddlesText)
				end
			end
			updatePuddlesText()
			task.wait(1)
		end
	end)

	gui.Destroying:Connect(function()
		state.enabled = false
		questState.enabled = false
		minigameState.enabled = false
		deactivate()
		if puddlesValueConnection then
			puddlesValueConnection:Disconnect()
			puddlesValueConnection = nil
		end
	end)
end)()

;(function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local planetPage = pages.planetarium
	local state = { enabled = false }

	local REQUIRED_POSITION = Vector3.new(537, 3223, 545)
	local POSITION_TOLERANCE = 1
	local MOVE_DT = 0.04
	local APPROX_STEP = 5
	local PRECISION_START_STEP = 20
	local PITCH_EPSILON = 0.0001
	local INACTIVITY_LIMIT = 5
	local STEP_TIMEOUT = 0.3
	local SOUND_SETTLE = 0.1
	local APPROX_SOUND_WAIT = 0.4

	local KEY_W = Enum.KeyCode.W
	local KEY_A = Enum.KeyCode.A
	local KEY_S = Enum.KeyCode.S
	local KEY_D = Enum.KeyCode.D

	local DIRECTIONS = { KEY_A, KEY_D, KEY_W, KEY_S }
	local OPPOSITE = {
		[KEY_A] = KEY_D,
		[KEY_D] = KEY_A,
		[KEY_W] = KEY_S,
		[KEY_S] = KEY_W,
	}

	local switchRow, statusLabel = createRow(planetPage, 38, "Auto telescope", "Off")
	local _bestRow, bestLabel = createRow(planetPage, 102, "Best found", "No measurement yet")

		local constellationRow, constellationStatus = createRow(planetPage, 166, "Auto constellation quest", "Off")
	local constellationState = { enabled = false, interval = 0.25 }

	createSwitch(constellationRow, false, function(value)
		constellationState.enabled = value
		constellationStatus.Text = value and "Starting..." or "Off"
	end)

	local function getRadioDetector()
		local planetarium = workspace:FindFirstChild("Planetarium")
		local radio = planetarium and planetarium:FindFirstChild("Radio")
		return radio and radio:FindFirstChild("ClickDetector")
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			if constellationState.enabled then
				local detector = getRadioDetector()
				if not detector then
					constellationStatus.Text = "Radio not found"
				elseif not fireclickdetector then
					constellationStatus.Text = "fireclickdetector unavailable"
				else
					fireclickdetector(detector)
					constellationStatus.Text = "Clicking radio"
				end
			end
			task.wait(constellationState.interval)
		end
	end)

	gui.Destroying:Connect(function()
		constellationState.enabled = false
	end)

	local lastStatus
	local function setStatus(text)
		if lastStatus ~= text then
			lastStatus = text
			statusLabel.Text = text
		end
	end

	local Remote, Click, TelescopeSound, CoordLabel

	local function resolve()
		if Remote and Remote.Parent and Click and Click.Parent and TelescopeSound and TelescopeSound.Parent and CoordLabel and CoordLabel.Parent then
			return true
		end
		local remote = ReplicatedStorage:FindFirstChild("TelescopeControls")
		local planetarium = workspace:FindFirstChild("Planetarium")
		local telescope = planetarium and planetarium:FindFirstChild("telescope")
		local lenses = telescope and telescope:FindFirstChild("lenses")
		local coordsPart = lenses and lenses:FindFirstChild("Coords")
		local sound = coordsPart and coordsPart:FindFirstChild("Sound")
		local surface = coordsPart and coordsPart:FindFirstChild("SurfaceGui")
		local label = surface and surface:FindFirstChild("TextLabel")
		local click = telescope and telescope:FindFirstChild("ClickDetector")
		if remote and sound and label and click then
			Remote, TelescopeSound, CoordLabel, Click = remote, sound, label, click
			return true
		end
		return false
	end

	local borders = {}
	local lastValidMeasurement = os.clock()
	local bestPitch = -math.huge
	local bestX, bestY = nil, nil

	local function stopped()
		return not state.enabled or gui.Parent ~= playerGui
	end

	local function getRoot()
		local character = player.Character
		return character and character:FindFirstChild("HumanoidRootPart")
	end

	local function atRequiredPosition()
		local root = getRoot()
		return root ~= nil and (root.Position - REQUIRED_POSITION).Magnitude <= POSITION_TOLERANCE
	end

	local function activateClick()
		if Click and fireclickdetector then
			pcall(function()
				fireclickdetector(Click)
			end)
		end
	end

	local function ensurePosition()
		while not stopped() and not atRequiredPosition() do
			activateClick()
			task.wait(0.25)
		end
	end

	task.spawn(function()
		while gui.Parent == playerGui do
			if state.enabled and Click and not atRequiredPosition() then
				activateClick()
			end
			task.wait(0.25)
		end
	end)

	local function getCoords()
		local numbers = {}
		for value in string.gmatch(CoordLabel.Text, "-?%d+%.?%d*") do
			numbers[#numbers + 1] = tonumber(value)
			if #numbers == 2 then
				break
			end
		end
		if #numbers < 2 then
			return nil, nil
		end
		return numbers[1], numbers[2]
	end

	local function readCoords()
		for _ = 1, 20 do
			local x, y = getCoords()
			if x then
				return x, y
			end
			task.wait(0.03)
		end
		return nil, nil
	end

	local function borderKey(x, y, key)
		return x .. "," .. y .. "," .. key.Name
	end

	local function isBorder(x, y, key)
		return borders[borderKey(x, y, key)] == true
	end

	local function markBorder(x, y, key)
		borders[borderKey(x, y, key)] = true
	end

	local function stepOnce(key)
		local beforeX, beforeY = readCoords()
		if not beforeX then
			return false
		end
		Remote:FireServer({
			ty = 0,
			key = key,
			dt = MOVE_DT,
		})
		local deadline = os.clock() + STEP_TIMEOUT
		repeat
			task.wait(0.03)
			local x, y = getCoords()
			if x and (x ~= beforeX or y ~= beforeY) then
				return true
			end
		until os.clock() >= deadline or stopped()
		return false
	end

	local function moveSteps(key, count)
		local moved = 0
		for _ = 1, count do
			if stopped() then
				break
			end
			ensurePosition()
			local x, y = readCoords()
			if not x then
				break
			end
			if isBorder(x, y, key) then
				break
			end
			if stepOnce(key) then
				moved = moved + 1
			else
				markBorder(x, y, key)
				break
			end
		end
		return moved
	end

	local function navigateTo(targetX, targetY)
		for _ = 1, 600 do
			if stopped() then
				return false
			end
			local x, y = readCoords()
			if not x then
				return false
			end
			if x == targetX and y == targetY then
				return true
			end
			local key
			if x < targetX then
				key = KEY_D
			elseif x > targetX then
				key = KEY_A
			elseif y < targetY then
				key = KEY_W
			else
				key = KEY_S
			end
			ensurePosition()
			if not stepOnce(key) then
				return false
			end
		end
		return false
	end

	local function waitForPitch(timeout, watchdog)
		local deadline = os.clock() + timeout
		while not stopped() do
			if watchdog and os.clock() - lastValidMeasurement > INACTIVITY_LIMIT then
				return nil
			end
			if TelescopeSound.IsPlaying then
				task.wait(SOUND_SETTLE)
				if TelescopeSound.IsPlaying then
					local pitch = TelescopeSound.PlaybackSpeed
					lastValidMeasurement = os.clock()
					return pitch
				end
			end
			if os.clock() >= deadline then
				return nil
			end
			task.wait(0.03)
		end
		return nil
	end

	local function updateBest(pitch, x, y)
		if pitch > bestPitch then
			bestPitch = pitch
			bestX, bestY = x, y
			bestLabel.Text = string.format("X=%s  Y=%s  |  pitch %.4f", tostring(x), tostring(y), pitch)
		end
	end

	local function recordBest(pitch)
		local x, y = readCoords()
		if x then
			updateBest(pitch, x, y)
		end
	end

	local function approximateSearch()
		local referencePitch = nil

		local function approxMove(key)
			local moved = moveSteps(key, APPROX_STEP)
			if stopped() then
				return moved, false
			end
			local pitch = waitForPitch(APPROX_SOUND_WAIT, false)
			if pitch then
				recordBest(pitch)
				if not referencePitch then
					referencePitch = pitch
				elseif math.abs(pitch - referencePitch) > PITCH_EPSILON then
					return moved, true
				end
			end
			return moved, false
		end

		for _, key in ipairs({ KEY_A, KEY_S }) do
			while not stopped() do
				local moved, found = approxMove(key)
				if found then
					return "precision"
				end
				if moved < APPROX_STEP then
					break
				end
			end
		end

		local xKey = KEY_D
		local yKey = KEY_W
		while not stopped() do
			while not stopped() do
				local moved, found = approxMove(xKey)
				if found then
					return "precision"
				end
				if moved < APPROX_STEP then
					break
				end
			end
			if stopped() then
				break
			end
			local movedY, found = approxMove(yKey)
			if found then
				return "precision"
			end
			if movedY == 0 then
				yKey = OPPOSITE[yKey]
				local retried, foundAgain = approxMove(yKey)
				if foundAgain then
					return "precision"
				end
				if retried == 0 then
					yKey = OPPOSITE[yKey]
				end
			end
			xKey = OPPOSITE[xKey]
		end
		return "stopped"
	end

	local function precisionSearch()
		lastValidMeasurement = os.clock()

		local baseline = waitForPitch(math.huge, true)
		if not baseline then
			return stopped() and "stopped" or "restart"
		end

		local currentPitch = baseline
		recordBest(baseline)
		local step = PRECISION_START_STEP
		local visited = {}

		local function posKey(x, y)
			return x .. "," .. y
		end

		while true do
			if stopped() then
				return "stopped"
			end

			local originX, originY = readCoords()
			if not originX then
				return "restart"
			end

			visited[posKey(originX, originY)] = true

			local candidate = nil

			for _, key in ipairs(DIRECTIONS) do
				if stopped() then
					return "stopped"
				end
				if not isBorder(originX, originY, key) then
					local moved = moveSteps(key, step)
					if stopped() then
						return "stopped"
					end
					if moved > 0 then
						local pitch = waitForPitch(math.huge, true)
						if not pitch then
							return stopped() and "stopped" or "restart"
						end
						local newX, newY = readCoords()
						if newX then
							updateBest(pitch, newX, newY)
							if not visited[posKey(newX, newY)] and pitch > currentPitch + PITCH_EPSILON then
								if not candidate or pitch > candidate.pitch then
									candidate = {
										pitch = pitch,
										x = newX,
										y = newY,
										key = key,
										distance = moved,
									}
								end
							end
						end
						if not navigateTo(originX, originY) then
							return stopped() and "stopped" or "restart"
						end
					end
				end
			end

			if candidate then
				if not navigateTo(candidate.x, candidate.y) then
					return stopped() and "stopped" or "restart"
				end
				local pitch = waitForPitch(math.huge, true)
				if not pitch then
					return stopped() and "stopped" or "restart"
				end
				currentPitch = pitch
				recordBest(pitch)
			elseif step > 1 then
				step = math.max(1, math.floor(step / 2))
			else
				if bestX then
					navigateTo(bestX, bestY)
				end
				return "done"
			end
		end
	end

	local function holdAtBest()
		setStatus("Holding at best")
		while not stopped() do
			local pitch = waitForPitch(INACTIVITY_LIMIT, false)
			if stopped() then
				return
			end
			if not pitch then
				return
			end
			if math.abs(pitch - bestPitch) > PITCH_EPSILON then
				return
			end
			task.wait(0.25)
		end
	end

	createSwitch(switchRow, false, function(value)
		if value then
			bestPitch = -math.huge
			bestX, bestY = nil, nil
			bestLabel.Text = "No measurement yet"
			setStatus("Starting...")
		else
			setStatus("Off")
		end
		state.enabled = value
	end)

	task.spawn(function()
		while gui.Parent == playerGui do
			if state.enabled then
				if not resolve() then
					setStatus("Telescope not found")
					task.wait(1)
				elseif not fireclickdetector then
					setStatus("fireclickdetector unavailable")
					task.wait(1)
				else
					borders = {}
					setStatus("Searching (approximate)")
					local ok, err = pcall(function()
						local mode = approximateSearch()
						if mode == "precision" then
							setStatus("Searching (precision)")
							local result = precisionSearch()
							if result == "done" then
								holdAtBest()
							end
						end
					end)
					if not ok then
						warn(err)
						task.wait(0.5)
					end
				end
			else
				task.wait(0.25)
			end
		end
	end)

	gui.Destroying:Connect(function()
		state.enabled = false
	end)
end)()

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

;(function()
	local bgPage = pages.background
	local INTERVAL = 0.25

	local function findPath(root, ...)
		local current = root
		for _, name in ipairs({ ... }) do
			current = current and current:FindFirstChild(name)
		end
		return current
	end

	local function fire(detector)
		if detector and fireclickdetector then
			pcall(fireclickdetector, detector)
		end
	end

	local newCardRow, newCardStatus = createRow(bgPage, 0, "Auto new card", "Off")
	local refreshCardRow, refreshCardStatus = createRow(bgPage, 64, "Auto refresh card", "Off")
	local walletRow, walletStatus = createRow(bgPage, 128, "Auto pickup wallets", "Off")

	local newCardState = { enabled = false }
	local refreshCardState = { enabled = false }
	local walletState = { enabled = false }

	createSwitch(newCardRow, false, function(value)
		newCardState.enabled = value
		newCardStatus.Text = value and "Starting..." or "Off"
	end)
	createSwitch(refreshCardRow, false, function(value)
		refreshCardState.enabled = value
		refreshCardStatus.Text = value and "Starting..." or "Off"
	end)
	createSwitch(walletRow, false, function(value)
		walletState.enabled = value
		walletStatus.Text = value and "Starting..." or "Off"
	end)

	-- generic click loop for the two card buttons
	local function startClickLoop(state, statusLabel, getDetector, foundText, missingText)
		task.spawn(function()
			while gui.Parent == playerGui do
				if state.enabled then
					local detector = getDetector()
					if not detector then
						statusLabel.Text = missingText
					elseif not fireclickdetector then
						statusLabel.Text = "fireclickdetector unavailable"
					else
						fire(detector)
						statusLabel.Text = foundText
					end
				end
				task.wait(INTERVAL)
			end
		end)
	end

	startClickLoop(newCardState, newCardStatus, function()
		return findPath(workspace, "npc_becuz_why_not", "office1", "Hitbox", "ClickDetector")
	end, "Clicking new card", "New card button not found")

	startClickLoop(refreshCardState, refreshCardStatus, function()
		return findPath(workspace, "npc_becuz_why_not", "office2", "Hitbox", "ClickDetector")
	end, "Clicking refresh card", "Refresh card button not found")

	local rainbowRow, rainbowStatus = createRow(bgPage, 192, "Auto rainbow box", "Off")
	local rainbowState = { enabled = false }

	createSwitch(rainbowRow, false, function(value)
		rainbowState.enabled = value
		rainbowStatus.Text = value and "Starting..." or "Off"
	end)

	startClickLoop(rainbowState, rainbowStatus, function()
		return findPath(workspace, "RainbowBox", "ClickDetector")
	end, "Clicking rainbow box", "Waiting for rainbow box")

	-- wallets: instant pickup on ChildAdded + periodic sweep as a fallback
	local function getWalletFolder()
		return findPath(workspace, "Puddles", "Puddles2ElectricBoogaloo")
	end

	local function pickupObject(object)
		local detector = object:FindFirstChildOfClass("ClickDetector")
		if not detector then
			detector = object:WaitForChild("ClickDetector", 2)
		end
		if detector and walletState.enabled then
			fire(detector)
		end
	end

	local walletConnection
	local connectedFolder

	task.spawn(function()
		while gui.Parent == playerGui do
			if walletState.enabled then
				local folder = getWalletFolder()
				if not folder then
					walletStatus.Text = "Wallet folder not found"
				elseif not fireclickdetector then
					walletStatus.Text = "fireclickdetector unavailable"
				else
					if folder ~= connectedFolder then
						if walletConnection then
							walletConnection:Disconnect()
						end
						connectedFolder = folder
						walletConnection = folder.ChildAdded:Connect(function(object)
							task.spawn(pickupObject, object)
						end)
					end
					local count = 0
					for _, object in ipairs(folder:GetChildren()) do
						local detector = object:FindFirstChildOfClass("ClickDetector")
						if detector then
							fire(detector)
							count += 1
						end
					end
					walletStatus.Text = count > 0 and string.format("Picking up %d wallet(s)", count) or "Waiting for wallets"
				end
			end
			task.wait(INTERVAL)
		end
	end)

	gui.Destroying:Connect(function()
		newCardState.enabled = false
		refreshCardState.enabled = false
		walletState.enabled = false
		rainbowState.enabled = false
		if walletConnection then
			walletConnection:Disconnect()
			walletConnection = nil
		end
	end)
end)()

;(function()
	local RunService = game:GetService("RunService")
	local charPage = pages.character

	local state = {
		infJump = false,
		walk = false,
		jump = false,
		walkValue = tonumber(config.walkSpeed) or 50,
		jumpValue = tonumber(config.jumpPower) or 100,
	}

	local WALK_MIN, WALK_MAX = 0, 300
	local JUMP_MIN, JUMP_MAX = 0, 500

	-- slider with a typeable value box; returns a setter
	local function createSlider(row, minValue, maxValue, initial, onChanged)
		local SLIDER_WIDTH = 240
		local value = initial

		local box = make("TextBox", row, {
			Position = UDim2.new(1, -(76 + 20 + SLIDER_WIDTH + 10 + 56), 0.5, -15),
			Size = UDim2.fromOffset(56, 30),
			BackgroundColor3 = Color3.fromRGB(32, 32, 34),
			BorderSizePixel = 0,
			Text = tostring(initial),
			TextColor3 = Color3.fromRGB(200, 200, 204),
			Font = Enum.Font.GothamMedium,
			TextSize = 12,
			ClearTextOnFocus = false,
		})
		addCorner(box, 8)
		addStroke(box, Color3.fromRGB(70, 70, 73), 0.25)

		local track = make("Frame", row, {
			Position = UDim2.new(1, -(76 + 20 + SLIDER_WIDTH), 0.5, -3),
			Size = UDim2.fromOffset(SLIDER_WIDTH, 6),
			BackgroundColor3 = OFF_TRACK,
			BorderSizePixel = 0,
		})
		addCorner(track, 3)

		local fill = make("Frame", track, {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = ACCENT,
			BorderSizePixel = 0,
		})
		addCorner(fill, 3)

		local knob = make("Frame", track, {
			Size = UDim2.fromOffset(16, 16),
			Position = UDim2.new(0, -8, 0.5, -8),
			BackgroundColor3 = ON_KNOB,
			BorderSizePixel = 0,
			ZIndex = 2,
		})
		addCorner(knob, 8)

		table.insert(themeUpdaters, function()
			fill.BackgroundColor3 = ACCENT
		end)

		local hit = make("Frame", row, {
			Position = UDim2.new(1, -(76 + 20 + SLIDER_WIDTH + 8), 0.5, -14),
			Size = UDim2.fromOffset(SLIDER_WIDTH + 16, 28),
			BackgroundTransparency = 1,
			Active = true,
			ZIndex = 3,
		})

		local function setValue(newValue, silent)
			newValue = math.clamp(math.floor(newValue + 0.5), minValue, maxValue)
			value = newValue
			local alpha = (newValue - minValue) / (maxValue - minValue)
			fill.Size = UDim2.fromScale(alpha, 1)
			knob.Position = UDim2.new(alpha, -8, 0.5, -8)
			box.Text = tostring(newValue)
			if not silent and onChanged then
				onChanged(newValue)
			end
		end

		local function setFromX(x)
			local alpha = math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
			setValue(minValue + alpha * (maxValue - minValue))
		end

		local dragging = false
		hit.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				setFromX(input.Position.X)
			end
		end)
		table.insert(globalConnections, UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				setFromX(input.Position.X)
			end
		end))
		table.insert(globalConnections, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end))

		box.FocusLost:Connect(function()
			local typed = tonumber(box.Text)
			if typed then
				setValue(typed)
			else
				box.Text = tostring(value)
			end
		end)

		setValue(initial, true)
		return setValue
	end

	-- humanoid tracking / enforcement
	local humanoid
	local humanoidConnections = {}
	local original = {}

	local function currentHumanoid()
		local character = player.Character
		return character and character:FindFirstChildOfClass("Humanoid")
	end

	local function enforce()
		local h = humanoid
		if not h or not h.Parent then
			return
		end
		if state.walk and h.WalkSpeed ~= state.walkValue then
			h.WalkSpeed = state.walkValue
		end
		if state.jump then
			if not h.UseJumpPower then
				h.UseJumpPower = true
			end
			if h.JumpPower ~= state.jumpValue then
				h.JumpPower = state.jumpValue
			end
		end
	end

	local function bindHumanoid(h)
		disconnectAll(humanoidConnections)
		humanoid = h
		original = {}
		if not h then
			return
		end
		original.walk = h.WalkSpeed
		original.jumpPower = h.JumpPower
		original.useJumpPower = h.UseJumpPower

		-- instant revert if the game (or anything else) changes them
		table.insert(humanoidConnections, h:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
			if state.walk and h.WalkSpeed ~= state.walkValue then
				h.WalkSpeed = state.walkValue
			end
		end))
		table.insert(humanoidConnections, h:GetPropertyChangedSignal("JumpPower"):Connect(function()
			if state.jump and h.JumpPower ~= state.jumpValue then
				h.JumpPower = state.jumpValue
			end
		end))
		table.insert(humanoidConnections, h:GetPropertyChangedSignal("UseJumpPower"):Connect(function()
			if state.jump and not h.UseJumpPower then
				h.UseJumpPower = true
			end
		end))
		enforce()
	end

	local function restoreWalk()
		if humanoid and humanoid.Parent and original.walk then
			humanoid.WalkSpeed = original.walk
		end
	end

	local function restoreJump()
		if humanoid and humanoid.Parent and original.jumpPower then
			humanoid.JumpPower = original.jumpPower
			humanoid.UseJumpPower = original.useJumpPower
		end
	end

	-- rows
	local infRow, infStatus = createRow(charPage, 0, "Infinite jump", "Off")
	local walkRow, walkStatus = createRow(charPage, 64, "Walk speed", "Off")
	local jumpRow, jumpStatus = createRow(charPage, 128, "Jump power", "Off")

	createSwitch(infRow, false, function(value)
		state.infJump = value
		infStatus.Text = value and "Jump in mid-air" or "Off"
	end)

	createSwitch(walkRow, false, function(value)
		state.walk = value
		if value then
			walkStatus.Text = "Locked at " .. state.walkValue
			enforce()
		else
			walkStatus.Text = "Off"
			restoreWalk()
		end
	end)

	createSwitch(jumpRow, false, function(value)
		state.jump = value
		if value then
			jumpStatus.Text = "Locked at " .. state.jumpValue
			enforce()
		else
			jumpStatus.Text = "Off"
			restoreJump()
		end
	end)

	createSlider(walkRow, WALK_MIN, WALK_MAX, math.clamp(state.walkValue, WALK_MIN, WALK_MAX), function(newValue)
		state.walkValue = newValue
		config.walkSpeed = newValue
		saveSettings()
		if state.walk then
			walkStatus.Text = "Locked at " .. newValue
			enforce()
		end
	end)

	createSlider(jumpRow, JUMP_MIN, JUMP_MAX, math.clamp(state.jumpValue, JUMP_MIN, JUMP_MAX), function(newValue)
		state.jumpValue = newValue
		config.jumpPower = newValue
		saveSettings()
		if state.jump then
			jumpStatus.Text = "Locked at " .. newValue
			enforce()
		end
	end)

	-- teleport to player (name or display name, full or just the first letters)
	local tpRow, tpStatus = createRow(charPage, 192, "Teleport to player", "Type a name")

	local tpButton = make("TextButton", tpRow, {
		Position = UDim2.new(1, -(104 + 12), 0.5, -19),
		Size = UDim2.fromOffset(104, 38),
		BackgroundColor3 = Color3.fromRGB(40, 38, 40),
		BorderSizePixel = 0,
		Text = "TELEPORT",
		TextColor3 = Color3.fromRGB(228, 228, 230),
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		AutoButtonColor = false,
	})
	addCorner(tpButton, 8)
	addStroke(tpButton, OUTLINE, 0.2)
	addHover(tpButton, Color3.fromRGB(40, 38, 40), mutedRed)

	local tpBox = make("TextBox", tpRow, {
		Position = UDim2.new(1, -(190 + 12 + 104 + 10), 0.5, -19),
		Size = UDim2.fromOffset(190, 38),
		BackgroundColor3 = Color3.fromRGB(32, 32, 34),
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = "Player name...",
		PlaceholderColor3 = DIM,
		TextColor3 = Color3.fromRGB(200, 200, 204),
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		ClearTextOnFocus = false,
	})
	addCorner(tpBox, 8)
	addStroke(tpBox, Color3.fromRGB(70, 70, 73), 0.25)

	local function findPlayer(query)
		query = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
		if query == "" then
			return nil
		end
		local prefixMatch, substringMatch
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player then
				local name = other.Name:lower()
				local display = other.DisplayName:lower()
				if name == query or display == query then
					return other
				end
				if not prefixMatch and (name:sub(1, #query) == query or display:sub(1, #query) == query) then
					prefixMatch = other
				end
				if not substringMatch and (name:find(query, 1, true) or display:find(query, 1, true)) then
					substringMatch = other
				end
			end
		end
		return prefixMatch or substringMatch
	end

	local function teleportToPlayer()
		local target = findPlayer(tpBox.Text)
		if not target then
			tpStatus.Text = tpBox.Text == "" and "Type a name" or "Player not found"
			return
		end
		local targetRoot = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
		if not targetRoot then
			tpStatus.Text = target.Name .. " has no character"
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			tpStatus.Text = "Waiting for character..."
			return
		end
		root.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 3)
		root.AssemblyLinearVelocity = Vector3.zero
		tpStatus.Text = "Teleported to " .. target.Name
	end

	tpButton.Activated:Connect(teleportToPlayer)
	tpBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			teleportToPlayer()
		end
	end)

	-- infinite jump: one jump per press, with a short cooldown
	local INF_JUMP_COOLDOWN = 0.25
	local lastInfJump = 0

	local function infiniteJump()
		if not state.infJump then
			return
		end
		local now = os.clock()
		if now - lastInfJump < INF_JUMP_COOLDOWN then
			return
		end
		local h = currentHumanoid()
		if h and h.Health > 0 then
			lastInfJump = now
			h:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end

	-- keyboard / gamepad: InputBegan fires once per press, so holding the key does nothing
	table.insert(globalConnections, UserInputService.InputBegan:Connect(function(input)
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
			infiniteJump()
		end
	end))

	-- touch-only devices: the on-screen jump button only exposes JumpRequest
	table.insert(globalConnections, UserInputService.JumpRequest:Connect(function()
		if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
			infiniteJump()
		end
	end))

	-- re-bind on respawn and enforce every physics step
	table.insert(globalConnections, RunService.Stepped:Connect(function()
		local h = currentHumanoid()
		if h ~= humanoid then
			bindHumanoid(h)
		end
		enforce()
	end))

	gui.Destroying:Connect(function()
		state.infJump = false
		state.walk = false
		state.jump = false
		restoreWalk()
		restoreJump()
		disconnectAll(humanoidConnections)
	end)
end)()

;(function()
	local RunService = game:GetService("RunService")
	local farmPage = pages.farm

	-- add more entries here to add more farm tools
	local TOOL_OPTIONS = {
		{
			name = "Neon Scythe",     -- label in the dropdown
			toolName = "Neon Scythe", -- name of the Tool once it's in your inventory
			getBuyDetector = function()
				local buyables = workspace:FindFirstChild("Buyables_Important")
				local item = buyables and buyables:GetChildren()[34]
				return item and item:FindFirstChild("ClickDetector")
			end,
		},
		{
			name = "Treacherous Scythe",
			toolName = "Treacherous Scythe",
			getBuyDetector = nil,
		},
	}

	local state = { enabled = false, option = TOOL_OPTIONS[1] }
	for _, option in ipairs(TOOL_OPTIONS) do
		if option.name == config.farmTool then
			state.option = option
		end
	end

	local FARM_DEPTH = 5        -- studs below the guard's root part
	local ATTACK_INTERVAL = 0.1 -- seconds between attacks
	local EQUIP_INTERVAL = 0.25
	local BUY_INTERVAL = 1      -- seconds between click attempts on the buy button
	local AIM_BIND = "FrozenIslandFarmAim"

	local farmRow, farmStatus = createRow(farmPage, 0, "Auto farm", "Off")
	local toolRow = createRow(farmPage, 64, "Tool")
	local toolButton = createValueButton(toolRow, state.option.name .. CHEVRON_DOWN, 265)
	local toolList = createDropdownList(farmPage, 126)
	local dropdownOpen = false

	local lastStatus
	local function setStatus(text)
		if lastStatus ~= text then
			lastStatus = text
			farmStatus.Text = text
		end
	end

	local function updateDropdownText()
		toolButton.Text = state.option.name .. (dropdownOpen and CHEVRON_UP or CHEVRON_DOWN)
	end

	local function setDropdownOpen(open)
		dropdownOpen = open
		local height = math.min(#TOOL_OPTIONS * 35 + 10, 100)
		animate(toolList, 0.22, { Size = UDim2.fromOffset(704, open and height or 0) })
		updateDropdownText()
	end

	local function rebuildOptions()
		for _, child in ipairs(toolList:GetChildren()) do
			if child:IsA("GuiButton") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		for index, option in ipairs(TOOL_OPTIONS) do
			local isSelected = state.option == option
			local row = make("TextButton", toolList, {
				LayoutOrder = index,
				Size = UDim2.new(1, -4, 0, 31),
				BackgroundColor3 = isSelected and ACTIVE_GREEN or ROW,
				BorderSizePixel = 0,
				Text = "",
				AutoButtonColor = false,
				ZIndex = 9,
			})
			addCorner(row, 7)
			make("TextLabel", row, {
				Position = UDim2.fromOffset(14, 0),
				Size = UDim2.new(1, -112, 1, 0),
				BackgroundTransparency = 1,
				Text = option.name,
				TextColor3 = isSelected and Color3.fromRGB(210, 239, 216) or Color3.fromRGB(222, 222, 224),
				Font = Enum.Font.Gotham,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 10,
			})
			make("TextLabel", row, {
				Position = UDim2.new(1, -92, 0, 0),
				Size = UDim2.fromOffset(78, 31),
				BackgroundTransparency = 1,
				Text = isSelected and "SELECTED" or "",
				TextColor3 = Color3.fromRGB(198, 232, 205),
				Font = Enum.Font.GothamBold,
				TextSize = 9,
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 10,
			})
			row.Activated:Connect(function()
				state.option = option
				config.farmTool = option.name
				saveSettings()
				setDropdownOpen(false)
				rebuildOptions()
			end)
			addHover(row, isSelected and ACTIVE_GREEN or ROW, isSelected and Color3.fromRGB(49, 87, 65) or ROW_HOVER)
		end
		toolList.CanvasSize = UDim2.new(0, 0, 0, #TOOL_OPTIONS * 35 + 10)
		updateDropdownText()
	end

	rebuildOptions()

	toolButton.Activated:Connect(function()
		setDropdownOpen(not dropdownOpen)
	end)

	-- finds the selected option's tool in the character or backpack
	local function findTool(option)
		local needle = option.toolName:lower()
		for _, container in ipairs({ player.Character, player:FindFirstChildOfClass("Backpack") }) do
			if container then
				for _, item in ipairs(container:GetChildren()) do
					if item:IsA("Tool") and item.Name:lower() == needle then
						return item
					end
				end
			end
		end
		return nil
	end

	-- target lookup: closest living SanctuaryGuard, or the closest one if none read as alive
	local guardHealthWarning = false

	local function getTarget(origin)
		local sanctuary = workspace:FindFirstChild("Sanctuary")
		local mobs = sanctuary and sanctuary:FindFirstChild("mobs")
		local mobs2 = mobs and mobs:FindFirstChild("mobs2")

		if not mobs2 then
			return nil, "Mobs folder not found"
		end

		local bestAlive, bestAliveDist
		local bestAny, bestAnyDist

		for _, mob in ipairs(mobs2:GetChildren()) do
			local mobHumanoid = mob:FindFirstChildOfClass("Humanoid")
			local part = mob:FindFirstChild("HumanoidRootPart")
				or mob.PrimaryPart
				or mob:FindFirstChildWhichIsA("BasePart", true)

			if part then
				local distance = (part.Position - origin).Magnitude

				if not bestAny or distance < bestAnyDist then
					bestAny, bestAnyDist = part, distance
				end

				if mobHumanoid and mobHumanoid.Health > 0 then
					if not bestAlive or distance < bestAliveDist then
						bestAlive, bestAliveDist = part, distance
					end
				end
			end
		end

		if bestAlive then
			guardHealthWarning = false
			return bestAlive
		end

		if bestAny then
			guardHealthWarning = true
			return bestAny
		end

		return nil, "Mobs not found"
	end

	local aimPoint
	local autoRotateChanged
	local equipTimer = 0
	local attackTimer = 0
	local buyTimer = BUY_INTERVAL

	local function releaseHumanoid()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and autoRotateChanged then
			humanoid.AutoRotate = true
		end
		autoRotateChanged = nil
		aimPoint = nil
	end

	createSwitch(farmRow, false, function(value)
		state.enabled = value
		equipTimer = 0
		attackTimer = 0
		buyTimer = BUY_INTERVAL
		if value then
			setStatus("Starting...")
		else
			setStatus("Off")
			releaseHumanoid()
		end
	end)

	-- main loop: buy if missing, equip, teleport below the guard, face it, attack
	table.insert(globalConnections, RunService.Heartbeat:Connect(function(dt)
		if not state.enabled then
			return
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local option = state.option

		if not (character and humanoid and root) or humanoid.Health <= 0 then
			aimPoint = nil
			setStatus("Waiting for character...")
			return
		end

		local tool = findTool(option)

		-- not owned yet: click the buy button
		if not tool then
			aimPoint = nil
			buyTimer += dt
			local detector = option.getBuyDetector and option.getBuyDetector()
			if not detector then
				setStatus(option.name .. " buy button not found")
			elseif not fireclickdetector then
				setStatus("fireclickdetector unavailable")
			else
				setStatus("Buying " .. option.name .. "...")
				if buyTimer >= BUY_INTERVAL then
					buyTimer = 0
					pcall(fireclickdetector, detector)
				end
			end
			return
		end

		-- keep the tool equipped
		if tool.Parent ~= character then
			aimPoint = nil
			equipTimer += dt
			if equipTimer >= EQUIP_INTERVAL then
				equipTimer = 0
				humanoid:EquipTool(tool)
			end
			setStatus("Equipping " .. tool.Name .. "...")
			return
		end

		local targetPart, problem = getTarget(root.Position)

		if not targetPart then
			aimPoint = nil

			local portal = workspace.Sanctuary.Statue.Dummy
			root.CFrame = portal.CFrame + Vector3.new(0, 3, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero

			setStatus("Waiting for mobs at portal...")
			return
		end

		local targetPos = targetPart.Position

		local FARM_DEPTH = 5
		local LEFT_OFFSET = 1.2

		-- Face the target while remaining underneath it
		local belowPos = targetPos - Vector3.new(0, FARM_DEPTH, 0)
		local facing = Vector3.new(0, 0, -1)

		-- Left relative to the character's facing direction
		local right = facing:Cross(Vector3.yAxis)
		local leftOffset = -right * LEFT_OFFSET

		local attackPosition = belowPos + leftOffset

		if humanoid.AutoRotate then
			humanoid.AutoRotate = false
			autoRotateChanged = true
		end

		root.CFrame = CFrame.lookAt(attackPosition, targetPos)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		aimPoint = targetPos

		-- attack
		attackTimer += dt
		if attackTimer >= ATTACK_INTERVAL then
			attackTimer = 0
			pcall(function()
				tool:Activate()
			end)
		end
		setStatus(guardHealthWarning and ("Farming (guard health reads 0) with " .. tool.Name) or ("Farming with " .. tool.Name))
	end))

	-- no collision so the ground under the guard doesn't push you around
	table.insert(globalConnections, RunService.Stepped:Connect(function()
		if not state.enabled or not aimPoint then
			return
		end
		local character = player.Character
		if character then
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant:IsA("BasePart") then
					descendant.CanCollide = false
				end
			end
		end
	end))

	-- aim the camera up at the guard after the default camera has updated
	RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 1, function()
		if state.enabled and aimPoint then
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame = CFrame.lookAt(camera.CFrame.Position, aimPoint)
			end
		end
	end)

	gui.Destroying:Connect(function()
		state.enabled = false
		pcall(function()
			RunService:UnbindFromRenderStep(AIM_BIND)
		end)
		releaseHumanoid()
	end)
end)()

local function bindBackpack(backpack)
	disconnectAll(backpackConnections)
	if backpack then
		table.insert(backpackConnections, backpack.ChildAdded:Connect(scheduleToolRefresh))
		table.insert(backpackConnections, backpack.ChildRemoved:Connect(scheduleToolRefresh))
	end
	scheduleToolRefresh()
end

local function bindCharacter(character)
	disconnectAll(characterConnections)
	if character then
		table.insert(characterConnections, character.ChildAdded:Connect(scheduleToolRefresh))
		table.insert(characterConnections, character.ChildRemoved:Connect(scheduleToolRefresh))
	end
	scheduleToolRefresh()
end

local currentBackpack
table.insert(playerConnections, player.ChildAdded:Connect(function(child)
	if child:IsA("Backpack") then
		currentBackpack = child
		bindBackpack(child)
	end
end))
table.insert(playerConnections, player.ChildRemoved:Connect(function(child)
	if child == currentBackpack then
		currentBackpack = nil
		bindBackpack(nil)
	end
end))
table.insert(playerConnections, player.CharacterAdded:Connect(bindCharacter))
table.insert(playerConnections, player.CharacterRemoving:Connect(function()
	bindCharacter(nil)
end))

currentBackpack = player:FindFirstChildOfClass("Backpack")
bindBackpack(currentBackpack)
bindCharacter(player.Character)

local function getPosition(instance)
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local function getTopOffset(block)
	if block:IsA("BasePart") then
		return block.Size.Y / 2 + 3
	end
	return 6
end

local function getTopPosition(block)
	local cf, size
	if block:IsA("BasePart") then
		cf, size = block.CFrame, block.Size
	elseif block:IsA("Model") then
		cf, size = block:GetBoundingBox()
	else
		return nil
	end
	local halfHeight = (
		math.abs(cf.RightVector.Y) * size.X
		+ math.abs(cf.UpVector.Y) * size.Y
		+ math.abs(cf.LookVector.Y) * size.Z
	) / 2
	return Vector3.new(cf.Position.X, cf.Position.Y + halfHeight + 3, cf.Position.Z)
end	

local function findClosestBlock(root)
	local currentFolder = workspace:FindFirstChild("FrozenIsland_Blocks")
	if not currentFolder then
		return nil
	end
	local closestBlock
	local closestDistance = math.huge
	for _, candidate in ipairs(currentFolder:GetChildren()) do
		local position = getPosition(candidate)
		if position then
			local offset = position - root.Position
			local distance = offset:Dot(offset)
			if distance < closestDistance then
				closestBlock = candidate
				closestDistance = distance
			end
		end
	end
	return closestBlock
end

task.spawn(function()
	while gui.Parent == playerGui do
		if autoMineEnabled then
			local generation = mineGeneration
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local tool = selectedTool

			if not character or not root then
				mineStatus.Text = "Waiting for character..."
			elseif not tool then
				mineStatus.Text = "Choose a tool"
			else
				local backpack = player:FindFirstChildOfClass("Backpack")
				local inCharacter = tool.Parent == character
				local inBackpack = backpack and tool.Parent == backpack
				if not inCharacter and not inBackpack then
					mineStatus.Text = "Tool no longer in inventory"
				else
					if inBackpack then
						local humanoid = character:FindFirstChildOfClass("Humanoid")
						if humanoid then
							humanoid:EquipTool(tool)
						end
					end

					local remote = tool:FindFirstChild("RemoteEvent", true)
					if not remote or not remote:IsA("RemoteEvent") then
						mineStatus.Text = "Tool has no RemoteEvent"
					elseif tool.Parent ~= character then
						mineStatus.Text = "Equipping " .. tool.Name .. "..."
					else
						local target = findClosestBlock(root)
						if not target then
							mineStatus.Text = "No nearby blocks"
						elseif autoMineEnabled
							and generation == mineGeneration
							and gui.Parent == playerGui
							and selectedTool == tool
							and tool.Parent == character
							and remote.Parent ~= nil then
							remote:FireServer(target)
							mineStatus.Text = "Mining with " .. tool.Name
						end
					end
				end
			end
		end
		task.wait(MINE_INTERVAL)
	end
end)

task.spawn(function()
	while gui.Parent == playerGui do
		if autoTeleportEnabled then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")

			if not root then
				blockTeleportStatus.Text = "Waiting for character..."
			else
				local block = findClosestBlock(root)
				local topPosition = block and getTopPosition(block)
				if not block or not topPosition then
					blockTeleportStatus.Text = "No blocks found"
				else
					local offset = topPosition - root.Position
					if offset:Dot(offset) > TELEPORT_MIN_DISTANCE * TELEPORT_MIN_DISTANCE and autoTeleportEnabled then
						root.CFrame = CFrame.new(topPosition)
						root.AssemblyLinearVelocity = Vector3.zero
					end
					blockTeleportStatus.Text = "Teleporting to blocks"
				end
			end
		end
		task.wait(TELEPORT_INTERVAL)
	end
end)

do
local function getBoxObjects()
	local main = workspace:FindFirstChild("MainPlace")
	local deliver = main and main:FindFirstChild("DELIVERtm")
	local start = deliver and deliver:FindFirstChild("Start")
	local detector = start and start:FindFirstChild("ClickDetector")
	local deliverPart = deliver and deliver:FindFirstChild("Deliver")
	local hb = deliverPart and deliverPart:FindFirstChild("HB")
	return detector, hb
end

local function boxWait(duration, generation)
	local elapsed = 0
	while elapsed < duration do
		task.wait(0.1)
		elapsed += 0.1
		if not autoBoxEnabled or generation ~= boxGeneration or gui.Parent ~= playerGui then
			return false
		end
	end
	return true
end

local function getRoot()
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

task.spawn(function()
	while gui.Parent == playerGui do
		if autoBoxEnabled then
			local generation = boxGeneration
			local root = getRoot()
			local detector, hb = getBoxObjects()

			if not root then
				boxStatus.Text = "Waiting for character..."
			elseif not detector or not hb then
				boxStatus.Text = "Box objects not found"
			elseif not fireclickdetector then
				boxStatus.Text = "fireclickdetector unavailable"
			else
				boxStatus.Text = "Picking up box..."
				fireclickdetector(detector)

				if boxWait(5, generation) then
					root = getRoot()
					if root and hb.Parent then
						local target = hb:IsA("BasePart") and hb.CFrame or hb:GetPivot()
						boxStatus.Text = "Delivering box..."
						root.CFrame = target + Vector3.new(0, 3, 0)
						root.AssemblyLinearVelocity = Vector3.zero

						if boxWait(1, generation) then
							root = getRoot()
							if root and hb.Parent then
								root.CFrame = target + Vector3.new(10, 3, 0)
								root.AssemblyLinearVelocity = Vector3.zero
								boxStatus.Text = "Delivered, repeating"
							end
						end
					end
				end
			end
		end
		task.wait(0.25)
	end
end)
end

gotoButton.Activated:Connect(function()
	local entry = gotoSelected
	if not entry then
		gotoStatus.Text = "Choose a color first"
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		gotoStatus.Text = "Waiting for character..."
		return
	end

	local closest
	local closestDistance = math.huge
	for _, part in ipairs(partsByHex[entry.hex] or {}) do
		if part.Parent then
			local offset = part.Position - root.Position
			local distance = offset:Dot(offset)
			if distance < closestDistance then
				closest = part
				closestDistance = distance
			end
		end
	end

	if not closest then
		gotoStatus.Text = string.format("No %s blocks found", entry.name)
		return
	end
	root.CFrame = CFrame.new(getTopPosition(closest) or (closest.Position + Vector3.new(0, getTopOffset(closest), 0)))
	root.AssemblyLinearVelocity = Vector3.zero
	gotoStatus.Text = "Teleported to " .. entry.name
end)

task.spawn(function()
	while gui.Parent == playerGui do
		if highlightingEnabled then
			refreshHighlights()
		end
		task.wait(1)
	end
end)

local blocksValueLabel
local blocksValueConnection

local function findBlocksValueLabel()
	local main = workspace:FindFirstChild("MainPlace")
	local box = main and main:FindFirstChild("BoxValue")
	local value = box and box:FindFirstChild("YourBlocksValue")
	local surface = value and value:FindFirstChild("SurfaceGui")
	local label = surface and surface:FindFirstChild("TextLabel")
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

local function updateBlocksText()
	local text = blocksValueLabel and blocksValueLabel.Text or "--"
	blocksLabel.Text = "blocks mined: " .. text
end

task.spawn(function()
	while gui.Parent == playerGui do
		local label = findBlocksValueLabel()
		if label ~= blocksValueLabel then
			if blocksValueConnection then
				blocksValueConnection:Disconnect()
				blocksValueConnection = nil
			end
			blocksValueLabel = label
			if label then
				blocksValueConnection = label:GetPropertyChangedSignal("Text"):Connect(updateBlocksText)
			end
		end
		updateBlocksText()
		task.wait(1)
	end
end)

table.insert(folderConnections, blocksFolder.DescendantAdded:Connect(scheduleColorRefresh))
table.insert(folderConnections, blocksFolder.DescendantRemoving:Connect(scheduleColorRefresh))

if config.gotoHex then
	gotoSelected = { hex = config.gotoHex, name = config.gotoName or config.gotoHex }
	gotoStatus.Text = gotoSelected.name .. " selected"
end

refreshColors()
refreshTools()
selectSubTab("mine")
selectTab("mining")

gui.Destroying:Connect(function()
	autoMineEnabled = false
	autoTeleportEnabled = false
	autoBoxEnabled = false
	globalConnections.npcBox.enabled = false
	globalConnections.fish.enabled = false
	mineGeneration += 1
	boxGeneration += 1
	if blocksValueConnection then
		blocksValueConnection:Disconnect()
		blocksValueConnection = nil
	end
	if globalConnections.npcBox.connection then
		globalConnections.npcBox.connection:Disconnect()
		globalConnections.npcBox.connection = nil
	end
	disconnectAll(globalConnections)
	disconnectAll(folderConnections)
	disconnectAll(backpackConnections)
	disconnectAll(characterConnections)
	disconnectAll(playerConnections)
	for part, connection in pairs(watchedParts) do
		connection:Disconnect()
		watchedParts[part] = nil
	end
	for part, highlight in pairs(highlights) do
		highlight:Destroy()
		highlights[part] = nil
	end
end)

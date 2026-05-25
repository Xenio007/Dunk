--[[
	SatchelController
	Remplace la hotbar Roblox par défaut par un satchel custom stylisé + un
	panneau d'inventaire ouvert via un bouton TopbarPlus.

	Hotbar (9 slots, touches 1–9) :
	  - En haut à gauche de chaque case : touche en Montserrat Extra Bold.
	  - Image au centre : brainrot (tinté par variant), weight (couleur d'origine),
		ou initiales en fallback.

	Inventaire complet (ouvert via l'icône topbar) :
	  - Affiche UNIQUEMENT le surplus (tools qui ne rentrent pas dans la hotbar).
	  - Clic sur un tool = l'équipe/déséquipe (désactivé pour éviter les clics accidentels).
	  - Drag & drop d'une cellule vers la barre pour assigner à un slot.

	Chaque Tool est assigné à un slot fixe qui ne change pas quand le joueur
	équipe/déséquipe (on se base sur Destroying pour libérer le slot).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local SatchelController = Loader.CreateController({
	Name = "SatchelController",
})

-- ===== Config visuelle =====

local HOTBAR_SLOT_COUNT = 9
local SLOT_SIZE = 78
local SLOT_SPACING = 6
local BAR_BOTTOM_OFFSET = 12

local INVENTORY_COL_COUNT = 6
local INVENTORY_CELL_SIZE = 110
local INVENTORY_CELL_PADDING = 8

-- UI scaling responsive : base dimensions conçues pour 1920x1080. Sur des
-- écrans plus petits (mobile notamment), on applique un UIScale < 1 pour que
-- la hotbar et l'inventaire tiennent dans l'écran sans déborder.
local UI_DESIGN_VIEWPORT = Vector2.new(1920, 1080)
local UI_MIN_SCALE = 0.45  -- plancher sur très petits écrans (mobile portrait)
local UI_MAX_SCALE = 1.0   -- jamais plus gros qu'au design original

local function computeUIScale(viewportSize)
	if not viewportSize or viewportSize.X <= 0 then return 1 end
	-- Ratio basé sur la plus petite dimension pour tenir en largeur ET hauteur.
	local rx = viewportSize.X / UI_DESIGN_VIEWPORT.X
	local ry = viewportSize.Y / UI_DESIGN_VIEWPORT.Y
	local s = math.min(rx, ry)
	return math.clamp(s, UI_MIN_SCALE, UI_MAX_SCALE)
end

local FONT_MONTSERRAT_EXTRA_BOLD = Font.new(
	"rbxasset://fonts/families/Montserrat.json",
	Enum.FontWeight.ExtraBold,
	Enum.FontStyle.Normal
)

local SLOT_BG_COLOR = Color3.fromRGB(28, 28, 36)
local SLOT_BG_SELECTED = Color3.fromRGB(60, 60, 78)
local SLOT_STROKE_COLOR = Color3.fromRGB(0, 0, 0)
-- Couleur du contour quand un tool est equipe (selectionne). Blanc pour eviter
-- la confusion avec la couleur de rarete Legendary (gold). La rarete est
-- toujours indiquee sur le contour des slots non selectionnes via getBorderColorFor.
local SLOT_STROKE_SELECTED = Color3.fromRGB(255, 255, 255)

local SLOT_KEYS = {
	{ label = "1", keyCode = Enum.KeyCode.One },
	{ label = "2", keyCode = Enum.KeyCode.Two },
	{ label = "3", keyCode = Enum.KeyCode.Three },
	{ label = "4", keyCode = Enum.KeyCode.Four },
	{ label = "5", keyCode = Enum.KeyCode.Five },
	{ label = "6", keyCode = Enum.KeyCode.Six },
	{ label = "7", keyCode = Enum.KeyCode.Seven },
	{ label = "8", keyCode = Enum.KeyCode.Eight },
	{ label = "9", keyCode = Enum.KeyCode.Nine },
}

-- Icône topbar : petite icone de sac/inventaire.
local INVENTORY_ICON_IMAGE = "rbxassetid://7733658133"

-- ===== Etat =====

local player = Players.LocalPlayer
local playerGui
local hotbarGui
local barFrame
local inventoryGui
local inventoryFrame
local inventoryGrid
local inventoryEmptyLabel
local inventoryOpen = false
local topbarIcon
local slotViews = {}
local WeightsConfig
local BrainrotImages
local BrainrotInfo
local IconModule

local inventoryCells = {}

-- Helper : retourne true si le joueur est actuellement transformé en brainrot
-- (attribut posé par PlayerBrainrotTransform côté serveur, répliqué ici).
-- Utilisé partout où on ouvre / affiche l'inventaire pour bloquer toute
-- interaction avec le Satchel pendant la transformation.
local function isPlayerBrainrot()
	return player:GetAttribute("IsBrainrot") == true
end

-- État du drag & drop depuis l'inventaire vers la hotbar.
local dragState = {
	active = false,
	tool = nil,
	ghost = nil,
	moveConn = nil,
	releaseConn = nil,
}

-- ===== Résolution d'image =====

local function getInitials(name)
	if type(name) ~= "string" or name == "" then return "" end
	local first = string.sub(name, 1, 1):upper()
	local secondWordIndex = string.find(name, " ") or 0
	if secondWordIndex > 0 and secondWordIndex < #name then
		local second = string.sub(name, secondWordIndex + 1, secondWordIndex + 1):upper()
		return first .. second
	end
	return first
end

local function resolveIconFor(tool)
	if not tool or not tool:IsA("Tool") then return nil, nil end
	local name = tool.Name

	if WeightsConfig and WeightsConfig.ByName and WeightsConfig.ByName[name] then
		return WeightsConfig.ByName[name].Image, Color3.fromRGB(255, 255, 255)
	end

	if BrainrotImages then
		local img, tint = BrainrotImages.GetImageAndTint(name)
		if img then
			return img, tint
		end
	end

	if typeof(tool.TextureId) == "string" and tool.TextureId ~= "" then
		return tool.TextureId, Color3.fromRGB(255, 255, 255)
	end

	return nil, nil
end

local function getBorderColorFor(tool)
	if not tool or not tool:IsA("Tool") then return SLOT_STROKE_COLOR end
	local name = tool.Name
	if WeightsConfig and WeightsConfig.ByName and WeightsConfig.ByName[name] then
		local cfg = WeightsConfig.ByName[name]
		local rarityColor = cfg.Rarity and WeightsConfig.RarityColors and WeightsConfig.RarityColors[cfg.Rarity]
		return rarityColor or SLOT_STROKE_COLOR
	end
	-- Brainrot : on prefere la couleur de la RARETE (Common/Uncommon/Rare/...)
	-- car c'est l'info la plus utile a montrer dans la hotbar (les variants sont
	-- deja indiques par la teinte de l'icone elle-meme).
	if BrainrotInfo then
		local info = BrainrotInfo.GetInfo(name)
		if info and info.RarityColor then
			return info.RarityColor
		end
	end
	-- Fallback : teinte du variant si BrainrotInfo n'a pas pu resoudre.
	if BrainrotImages then
		local _, tint = BrainrotImages.GetImageAndTint(name)
		if tint and tint ~= Color3.fromRGB(255, 255, 255) then
			return tint
		end
	end
	return SLOT_STROKE_COLOR
end

-- ===== Hotbar UI =====

local function createSlot(slotIndex)
	local info = SLOT_KEYS[slotIndex]

	local frame = Instance.new("ImageButton")
	frame.Name = "Slot" .. tostring(slotIndex)
	frame.LayoutOrder = slotIndex
	frame.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	frame.BackgroundColor3 = SLOT_BG_COLOR
	-- Transparency identique à celle utilisée par clearSlot pour qu'un slot
	-- jamais rempli (au join du joueur sans brainrots) ait la même apparence
	-- "vide" claire qu'un slot libéré après pose/vente. Sans ça les cases
	-- au join avaient un fond foncé (0.1) au lieu du fond clair (0.35).
	frame.BackgroundTransparency = 0.35
	frame.AutoButtonColor = false
	frame.Image = ""
	frame.BorderSizePixel = 0
	frame.Parent = barFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = SLOT_STROKE_COLOR
	stroke.Thickness = 2
	stroke.Transparency = 0.2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 60, 78)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 24, 32)),
	})
	gradient.Rotation = 90
	gradient.Parent = frame

	local image = Instance.new("ImageLabel")
	image.Name = "Icon"
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Position = UDim2.fromScale(0.5, 0.55)
	image.Size = UDim2.fromScale(0.78, 0.78)
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.Image = ""
	image.ZIndex = 2
	image.Parent = frame

	local initials = Instance.new("TextLabel")
	initials.Name = "Initials"
	initials.AnchorPoint = Vector2.new(0.5, 0.5)
	initials.Position = UDim2.fromScale(0.5, 0.55)
	initials.Size = UDim2.fromScale(0.9, 0.55)
	initials.BackgroundTransparency = 1
	initials.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	initials.TextScaled = true
	initials.TextColor3 = Color3.fromRGB(235, 235, 245)
	initials.Text = ""
	initials.Visible = false
	initials.ZIndex = 2
	initials.Parent = frame

	local keyPadding = math.max(4, math.floor(SLOT_SIZE * 0.08))

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "KeyLabel"
	keyLabel.AnchorPoint = Vector2.new(0, 0)
	keyLabel.Position = UDim2.new(0, keyPadding, 0, keyPadding)
	keyLabel.Size = UDim2.fromScale(0.35, 0.32)
	keyLabel.BackgroundTransparency = 1
	keyLabel.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	keyLabel.TextScaled = true
	keyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	keyLabel.TextXAlignment = Enum.TextXAlignment.Left
	keyLabel.TextYAlignment = Enum.TextYAlignment.Top
	keyLabel.Text = info.label
	keyLabel.ZIndex = 3
	keyLabel.Parent = frame

	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = Color3.fromRGB(0, 0, 0)
	keyStroke.Thickness = 2
	keyStroke.Transparency = 0.1
	keyStroke.Parent = keyLabel

	return {
		frame = frame,
		keyLabel = keyLabel,
		image = image,
		initials = initials,
		stroke = stroke,
		tool = nil,
	}
end

local function createHotbar()
	hotbarGui = Instance.new("ScreenGui")
	hotbarGui.Name = "SatchelHotbar"
	hotbarGui.ResetOnSpawn = false
	hotbarGui.IgnoreGuiInset = true
	-- DisplayOrder supérieur à celui de l'inventaire (20) pour que les slots
	-- de la hotbar captent les clics au lieu du backdrop de l'inventaire.
	-- Sans ça, cliquer la barre pendant que l'inventaire est ouvert fermait
	-- l'inventaire (le clic passait au backdrop full-screen).
	hotbarGui.DisplayOrder = 25
	hotbarGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	hotbarGui.Parent = playerGui

	barFrame = Instance.new("Frame")
	barFrame.Name = "Bar"
	barFrame.AnchorPoint = Vector2.new(0.5, 1)
	barFrame.Position = UDim2.new(0.5, 0, 1, -BAR_BOTTOM_OFFSET)
	barFrame.BackgroundTransparency = 1
	barFrame.AutomaticSize = Enum.AutomaticSize.XY
	barFrame.Size = UDim2.fromOffset(0, SLOT_SIZE)
	barFrame.Parent = hotbarGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, SLOT_SPACING)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = barFrame

	-- UIScale responsive : réduit la hotbar sur les petits écrans (mobile).
	local barScale = Instance.new("UIScale")
	barScale.Name = "ResponsiveScale"
	barScale.Scale = computeUIScale(Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize)
	barScale.Parent = barFrame

	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			barScale.Scale = computeUIScale(Workspace.CurrentCamera.ViewportSize)
		end)
	end

	for i = 1, HOTBAR_SLOT_COUNT do
		slotViews[i] = createSlot(i)
	end
end

-- ===== Inventaire complet UI =====

local function createInventoryPanel()
	inventoryGui = Instance.new("ScreenGui")
	inventoryGui.Name = "SatchelInventory"
	inventoryGui.ResetOnSpawn = false
	inventoryGui.IgnoreGuiInset = true
	inventoryGui.DisplayOrder = 20
	inventoryGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	inventoryGui.Enabled = false
	inventoryGui.Parent = playerGui

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	backdrop.BackgroundTransparency = 0.45
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = 1
	backdrop.Parent = inventoryGui

	inventoryFrame = Instance.new("Frame")
	inventoryFrame.Name = "Panel"
	inventoryFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	inventoryFrame.Position = UDim2.fromScale(0.5, 0.5)
	inventoryFrame.Size = UDim2.fromOffset(780, 540)
	inventoryFrame.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
	inventoryFrame.BackgroundTransparency = 0.05
	inventoryFrame.BorderSizePixel = 0
	inventoryFrame.ZIndex = 2
	inventoryFrame.Parent = inventoryGui

	-- UIScale responsive sur le panel (adapte aussi la taille des cellules
	-- grâce à la propagation du scale aux enfants).
	local panelScale = Instance.new("UIScale")
	panelScale.Name = "ResponsiveScale"
	panelScale.Scale = computeUIScale(Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize)
	panelScale.Parent = inventoryFrame

	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			panelScale.Scale = computeUIScale(Workspace.CurrentCamera.ViewportSize)
		end)
	end

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 16)
	panelCorner.Parent = inventoryFrame

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(0, 0, 0)
	panelStroke.Thickness = 3
	panelStroke.Transparency = 0.2
	panelStroke.Parent = inventoryFrame

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(50, 50, 68)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 20, 28)),
	})
	panelGradient.Rotation = 90
	panelGradient.Parent = inventoryFrame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0, 0)
	title.Position = UDim2.new(0, 24, 0, 18)
	title.Size = UDim2.new(1, -96, 0, 40)
	title.BackgroundTransparency = 1
	title.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "INVENTORY"
	title.ZIndex = 3
	title.Parent = inventoryFrame

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(0, 0, 0)
	titleStroke.Thickness = 2
	titleStroke.Transparency = 0.1
	titleStroke.Parent = title

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -18, 0, 18)
	closeBtn.Size = UDim2.fromOffset(42, 42)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	closeBtn.BorderSizePixel = 0
	closeBtn.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Text = "X"
	closeBtn.AutoButtonColor = true
	closeBtn.ZIndex = 3
	closeBtn.Parent = inventoryFrame

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 10)
	closeCorner.Parent = closeBtn

	local closeStroke = Instance.new("UIStroke")
	closeStroke.Color = Color3.fromRGB(0, 0, 0)
	closeStroke.Thickness = 2
	closeStroke.Transparency = 0.1
	closeStroke.Parent = closeBtn

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	scroll.AnchorPoint = Vector2.new(0.5, 1)
	scroll.Position = UDim2.new(0.5, 0, 1, -18)
	scroll.Size = UDim2.new(1, -36, 1, -88)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = Color3.fromRGB(120, 120, 140)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 3
	scroll.Parent = inventoryFrame

	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(INVENTORY_CELL_PADDING, INVENTORY_CELL_PADDING)
	grid.CellSize = UDim2.fromOffset(INVENTORY_CELL_SIZE, INVENTORY_CELL_SIZE)
	grid.FillDirection = Enum.FillDirection.Horizontal
	grid.FillDirectionMaxCells = INVENTORY_COL_COUNT
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Left
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = scroll

	inventoryGrid = scroll

	inventoryEmptyLabel = Instance.new("TextLabel")
	inventoryEmptyLabel.Name = "Empty"
	inventoryEmptyLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	inventoryEmptyLabel.Position = UDim2.fromScale(0.5, 0.55)
	inventoryEmptyLabel.Size = UDim2.new(1, -40, 0, 40)
	inventoryEmptyLabel.BackgroundTransparency = 1
	inventoryEmptyLabel.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	inventoryEmptyLabel.TextScaled = true
	inventoryEmptyLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
	inventoryEmptyLabel.Text = "No items yet."
	inventoryEmptyLabel.Visible = false
	inventoryEmptyLabel.ZIndex = 4
	inventoryEmptyLabel.Parent = inventoryFrame

	closeBtn.Activated:Connect(function()
		SatchelController:SetInventoryOpen(false)
	end)
	backdrop.Activated:Connect(function()
		-- Évite de fermer l'inventaire si on est en train de drag & drop
		-- (l'Input termine au-dessus du backdrop quand on drop entre panneau et hotbar).
		if dragState.active then return end
		SatchelController:SetInventoryOpen(false)
	end)
end

-- ===== Assignation slot ↔ tool =====

local containerConnections = {}
local toolConnections = {}
local toolToSlotIndex = {}
local knownTools = {}

local refreshInventoryPanel
local applySelection

local function disconnectContainerConnections()
	for _, c in ipairs(containerConnections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(containerConnections)
end

local function disconnectToolConnection(tool)
	local c = toolConnections[tool]
	if c then
		pcall(function() c:Disconnect() end)
		toolConnections[tool] = nil
	end
end

local function clearSlot(slot)
	slot.tool = nil
	slot.image.Image = ""
	slot.image.ImageColor3 = Color3.fromRGB(255, 255, 255)
	slot.initials.Text = ""
	slot.initials.Visible = false
	slot.stroke.Color = SLOT_STROKE_COLOR
	slot.stroke.Thickness = 2
	slot.frame.BackgroundColor3 = SLOT_BG_COLOR
	slot.frame.BackgroundTransparency = 0.35
end

local function fillSlot(slot, tool)
	slot.tool = tool
	local imageId, tint = resolveIconFor(tool)
	if imageId and imageId ~= "" then
		slot.image.Image = imageId
		slot.image.ImageColor3 = tint or Color3.fromRGB(255, 255, 255)
		slot.initials.Visible = false
	else
		slot.image.Image = ""
		slot.initials.Text = getInitials(tool.Name)
		slot.initials.Visible = true
	end
	slot.frame.BackgroundTransparency = 0.1
end

applySelection = function()
	local character = player.Character
	for _, slot in ipairs(slotViews) do
		local tool = slot.tool
		if tool then
			local isEquipped = character and tool.Parent == character
			local targetStrokeColor, targetThickness, targetBg
			if isEquipped then
				targetStrokeColor = SLOT_STROKE_SELECTED
				targetThickness = 3
				targetBg = SLOT_BG_SELECTED
			else
				targetStrokeColor = getBorderColorFor(tool)
				targetThickness = 2
				targetBg = SLOT_BG_COLOR
			end
			-- Optimisation : on écrit la propriété SEULEMENT si elle change.
			-- Roblox traite chaque écriture comme un signal de réplication UI ;
			-- en spam, sauter les writes redondants évite les pics CPU/GPU.
			if slot.stroke.Color ~= targetStrokeColor then
				slot.stroke.Color = targetStrokeColor
			end
			if slot.stroke.Thickness ~= targetThickness then
				slot.stroke.Thickness = targetThickness
			end
			if slot.frame.BackgroundColor3 ~= targetBg then
				slot.frame.BackgroundColor3 = targetBg
			end
		else
			if slot.stroke.Color ~= SLOT_STROKE_COLOR then
				slot.stroke.Color = SLOT_STROKE_COLOR
			end
			if slot.stroke.Thickness ~= 2 then
				slot.stroke.Thickness = 2
			end
			if slot.frame.BackgroundColor3 ~= SLOT_BG_COLOR then
				slot.frame.BackgroundColor3 = SLOT_BG_COLOR
			end
		end
	end
end

local function findEmptySlotIndex()
	for i = 1, HOTBAR_SLOT_COUNT do
		if not slotViews[i].tool then
			return i
		end
	end
	return nil
end

-- Débounce : quand un Equip déclenche en chaîne 4-5 callbacks (Tool sort du
-- Backpack → entre dans Character → réplication), on coalesce TOUS les
-- applySelection / refreshInventoryPanel d'une même frame en UN SEUL appel
-- via task.defer + un flag. Avant : spam 1-9 = 40+ rebuilds UI/sec, freeze
-- visible. Après : 1 seul rebuild par frame max.
local _applyScheduled = false
local _refreshScheduled = false

local function scheduleApplySelection()
	if _applyScheduled then return end
	_applyScheduled = true
	task.defer(function()
		_applyScheduled = false
		applySelection()
	end)
end

local function scheduleRefreshInventory()
	if _refreshScheduled then return end
	if not refreshInventoryPanel then return end
	_refreshScheduled = true
	task.defer(function()
		_refreshScheduled = false
		if refreshInventoryPanel then refreshInventoryPanel() end
	end)
end

local function releaseTool(tool)
	if not tool then return end
	disconnectToolConnection(tool)
	local slotIndex = toolToSlotIndex[tool]
	toolToSlotIndex[tool] = nil
	knownTools[tool] = nil
	if slotIndex and slotViews[slotIndex] and slotViews[slotIndex].tool == tool then
		-- On laisse le slot vide : pas de re-remplissage automatique depuis
		-- l'overflow. Si le joueur veut un autre brainrot dans ce slot, il doit
		-- le glisser lui-même depuis l'inventaire.
		clearSlot(slotViews[slotIndex])
	end
	scheduleApplySelection()
	scheduleRefreshInventory()
end

local function hookTool(tool)
	if toolConnections[tool] then return end
	toolConnections[tool] = tool.Destroying:Connect(function()
		releaseTool(tool)
	end)
end

local function assignTool(tool)
	if not tool or not tool:IsA("Tool") then return end
	if knownTools[tool] then return end
	knownTools[tool] = true
	local slotIndex = findEmptySlotIndex()
	if slotIndex then
		toolToSlotIndex[tool] = slotIndex
		fillSlot(slotViews[slotIndex], tool)
	end
	hookTool(tool)
	scheduleApplySelection()
	scheduleRefreshInventory()
end

local function onContainerChildAdded(child)
	if child:IsA("Tool") then
		assignTool(child)
		-- assignTool déjà schedule applySelection : pas la peine de re-call.
	end
end

local function onContainerChildRemoved(child)
	if child:IsA("Tool") then
		scheduleApplySelection()
	end
end

local function hookContainer(container)
	if not container then return end
	table.insert(containerConnections, container.ChildAdded:Connect(onContainerChildAdded))
	table.insert(containerConnections, container.ChildRemoved:Connect(onContainerChildRemoved))
end

local function rehookAll()
	disconnectContainerConnections()

	local existing = {}
	local bp = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	if bp then
		for _, child in ipairs(bp:GetChildren()) do
			if child:IsA("Tool") then existing[child] = true end
		end
	end
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then existing[child] = true end
		end
	end

	for tool, _ in pairs(knownTools) do
		if not existing[tool] then
			releaseTool(tool)
		end
	end

	hookContainer(bp)
	hookContainer(character)

	if bp then
		for _, child in ipairs(bp:GetChildren()) do
			if child:IsA("Tool") then assignTool(child) end
		end
	end
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then assignTool(child) end
		end
	end

	applySelection()
	if refreshInventoryPanel then refreshInventoryPanel() end
end

-- ===== Interaction =====

-- Cooldown anti-spam : si un joueur martele 1-9, chaque touche déclenche
-- UnequipTools + EquipTool côté client + 4 hooks ChildAdded/Removed sur
-- Backpack/Character + serveur qui re-tag les tools + reload des animations.
-- Sans cooldown, spam 10 touches/s = ~40 callbacks UI/frame + réplication
-- de 80 reparents/s = chute FPS visible. 0.15s laisse une réactivité fluide
-- en jeu normal mais coupe le lag du spam.
local EQUIP_COOLDOWN = 0.15
local lastEquipAt = 0

local function equipOrUnequipTool(tool)
	if not tool then return end
	-- Bloqué pendant les phases où le joueur ne doit pas pouvoir prendre
	-- un tool en main (KickReady, séquence Dunk). Protège aussi contre les
	-- boucles d'événement (equip -> unequip -> equip...) qui font crash le
	-- Studio.
	if _G.SatchelEquipBlocked then return end
	-- Bloqué aussi tant que le joueur est sous forme brainrot : aucun tool
	-- ne doit pouvoir être équipé / déséquipé via les touches 1-9 ou un clic
	-- accidentel sur un slot.
	if isPlayerBrainrot() then return end

	-- Cooldown anti-spam (cf commentaire ci-dessus).
	local now = os.clock()
	if now - lastEquipAt < EQUIP_COOLDOWN then return end
	lastEquipAt = now

	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	if tool.Parent == character then
		humanoid:UnequipTools()
	else
		humanoid:EquipTool(tool)
	end
end

local function equipOrUnequipSlot(slotIndex)
	local slot = slotViews[slotIndex]
	if not slot or not slot.tool then return end
	equipOrUnequipTool(slot.tool)
end

-- ===== Panneau d'inventaire : création de cellule + refresh =====

local function createInventoryCell(tool, orderIndex)
	local cell = Instance.new("ImageButton")
	cell.Name = "Cell_" .. tool.Name
	cell.LayoutOrder = orderIndex
	cell.BackgroundColor3 = SLOT_BG_COLOR
	cell.BackgroundTransparency = 0.05
	cell.AutoButtonColor = false
	cell.Image = ""
	cell.BorderSizePixel = 0
	cell.ZIndex = 4
	cell.Parent = inventoryGrid

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = cell

	local stroke = Instance.new("UIStroke")
	stroke.Color = getBorderColorFor(tool)
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = cell

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 60, 78)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 24, 32)),
	})
	gradient.Rotation = 90
	gradient.Parent = cell

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.44)
	icon.Size = UDim2.fromScale(0.7, 0.6)
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 5
	icon.Parent = cell

	local initials = Instance.new("TextLabel")
	initials.Name = "Initials"
	initials.AnchorPoint = Vector2.new(0.5, 0.5)
	initials.Position = UDim2.fromScale(0.5, 0.44)
	initials.Size = UDim2.fromScale(0.8, 0.45)
	initials.BackgroundTransparency = 1
	initials.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	initials.TextScaled = true
	initials.TextColor3 = Color3.fromRGB(235, 235, 245)
	initials.Text = ""
	initials.Visible = false
	initials.ZIndex = 5
	initials.Parent = cell

	local imageId, tint = resolveIconFor(tool)
	if imageId and imageId ~= "" then
		icon.Image = imageId
		icon.ImageColor3 = tint or Color3.fromRGB(255, 255, 255)
	else
		icon.Image = ""
		initials.Text = getInitials(tool.Name)
		initials.Visible = true
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.new(0.5, 0, 1, -6)
	nameLabel.Size = UDim2.new(1, -10, 0, 16)
	nameLabel.BackgroundTransparency = 1
	nameLabel.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.Text = tool.Name
	nameLabel.ZIndex = 5
	nameLabel.Parent = cell

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = Color3.fromRGB(0, 0, 0)
	nameStroke.Thickness = 1.5
	nameStroke.Transparency = 0.15
	nameStroke.Parent = nameLabel

	-- Badge numéroté affiché quand le tool est dans la hotbar (1–9 en haut à gauche).
	local slotBadge = Instance.new("Frame")
	slotBadge.Name = "SlotBadge"
	slotBadge.AnchorPoint = Vector2.new(0, 0)
	slotBadge.Position = UDim2.fromOffset(6, 6)
	slotBadge.Size = UDim2.fromOffset(26, 26)
	slotBadge.BackgroundColor3 = Color3.fromRGB(255, 215, 64)
	slotBadge.BorderSizePixel = 0
	slotBadge.Visible = false
	slotBadge.ZIndex = 6
	slotBadge.Parent = cell

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(1, 0)
	badgeCorner.Parent = slotBadge

	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Color = Color3.fromRGB(0, 0, 0)
	badgeStroke.Thickness = 1.5
	badgeStroke.Transparency = 0.1
	badgeStroke.Parent = slotBadge

	local badgeText = Instance.new("TextLabel")
	badgeText.Name = "Text"
	badgeText.AnchorPoint = Vector2.new(0.5, 0.5)
	badgeText.Position = UDim2.fromScale(0.5, 0.5)
	badgeText.Size = UDim2.fromScale(0.8, 0.8)
	badgeText.BackgroundTransparency = 1
	badgeText.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
	badgeText.TextScaled = true
	badgeText.TextColor3 = Color3.fromRGB(20, 20, 28)
	badgeText.Text = ""
	badgeText.ZIndex = 7
	badgeText.Parent = slotBadge

	-- ===== Drag & drop =====
	cell.MouseButton1Down:Connect(function()
		SatchelController:_BeginDragPotential(tool, "inventory")
	end)

	cell.MouseEnter:Connect(function()
		TweenService:Create(cell, TweenInfo.new(0.12), {
			BackgroundColor3 = Color3.fromRGB(48, 48, 62),
		}):Play()
	end)
	cell.MouseLeave:Connect(function()
		TweenService:Create(cell, TweenInfo.new(0.12), {
			BackgroundColor3 = SLOT_BG_COLOR,
		}):Play()
	end)

	return {
		cell = cell,
		icon = icon,
		initials = initials,
		stroke = stroke,
		slotBadge = slotBadge,
		badgeText = badgeText,
	}
end

refreshInventoryPanel = function()
	if not inventoryGrid then return end
	-- Optimisation critique : si l'inventaire n'est pas ouvert, on ne fait
	-- AUCUN travail. Tout est rebuilt à l'ouverture (SetInventoryOpen). Sans
	-- cette garde, chaque buy de poids déclenchait 2-4 refreshes complets,
	-- chacun reconstruit toutes les cellules de l'inventaire avec UI tweens.
	-- Sur un client mobile avec 80+ brainrots c'était suffisant pour faire
	-- crasher au moment du buy.
	if not (inventoryGui and inventoryGui.Enabled) then return end

	-- On affiche UNIQUEMENT l'overflow (tools pas en hotbar). Détruit les cellules
	-- devenues inutiles (tool retiré du joueur OU tool maintenant dans un slot).
	for tool, data in pairs(inventoryCells) do
		if not knownTools[tool] or not tool.Parent or toolToSlotIndex[tool] then
			data.cell:Destroy()
			inventoryCells[tool] = nil
		end
	end

	local sorted = {}
	for tool, _ in pairs(knownTools) do
		if not toolToSlotIndex[tool] then
			table.insert(sorted, tool)
		end
	end
	table.sort(sorted, function(a, b)
		return a.Name < b.Name
	end)

	for order, tool in ipairs(sorted) do
		local data = inventoryCells[tool]
		if not data then
			data = createInventoryCell(tool, order)
			inventoryCells[tool] = data
		else
			data.cell.LayoutOrder = order
		end
	end

	if inventoryEmptyLabel then
		inventoryEmptyLabel.Visible = (#sorted == 0)
	end
end

-- ===== Drag & drop : inventaire <-> hotbar <-> hotbar =====

local UserInputServiceLocal = UserInputService
local DRAG_THRESHOLD_PX = 6

-- Déplace un tool de son slot vers l'overflow (le retire de la hotbar).
-- Le tool reste known (visible dans l'inventaire).
local function moveToolToOverflow(tool)
	if not tool then return end
	local slotIndex = toolToSlotIndex[tool]
	if not slotIndex then return end

	toolToSlotIndex[tool] = nil
	clearSlot(slotViews[slotIndex])

	applySelection()
	if refreshInventoryPanel then refreshInventoryPanel() end
end

-- Assigne un tool à un slot donné, en gérant le swap si le slot est déjà occupé.
-- newTool peut venir d'un autre slot (swap) ou de l'overflow (pas de slot précédent).
local function assignToolToSlot(tool, targetSlotIndex)
	if not tool or not targetSlotIndex then return end
	if targetSlotIndex < 1 or targetSlotIndex > HOTBAR_SLOT_COUNT then return end

	local previousSlotIndex = toolToSlotIndex[tool]
	if previousSlotIndex == targetSlotIndex then return end

	-- Tool actuellement dans le slot cible (peut être nil si slot vide).
	local occupant = slotViews[targetSlotIndex].tool

	-- 1) Vide le slot actuel du tool (s'il en avait un).
	if previousSlotIndex then
		clearSlot(slotViews[previousSlotIndex])
	end

	-- 2) Vide le slot cible.
	clearSlot(slotViews[targetSlotIndex])

	-- 3) Place notre tool dans le slot cible.
	toolToSlotIndex[tool] = targetSlotIndex
	fillSlot(slotViews[targetSlotIndex], tool)

	-- 4) Gestion de l'ancien occupant (swap).
	if occupant and occupant ~= tool then
		if previousSlotIndex then
			-- Source venait d'un autre slot : l'occupant prend la place laissée vide.
			toolToSlotIndex[occupant] = previousSlotIndex
			fillSlot(slotViews[previousSlotIndex], occupant)
		else
			-- Source venait de l'overflow : l'occupant retombe en overflow.
			toolToSlotIndex[occupant] = nil
		end
	end

	applySelection()
	if refreshInventoryPanel then refreshInventoryPanel() end
end

local dragPendingConns = {}

local function cancelPendingDrag()
	for _, c in ipairs(dragPendingConns) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(dragPendingConns)
end

local function endDrag()
	if dragState.ghost then
		dragState.ghost:Destroy()
		dragState.ghost = nil
	end
	if dragState.moveConn then
		pcall(function() dragState.moveConn:Disconnect() end)
		dragState.moveConn = nil
	end
	if dragState.releaseConn then
		pcall(function() dragState.releaseConn:Disconnect() end)
		dragState.releaseConn = nil
	end
	dragState.active = false
	dragState.tool = nil
	dragState.origin = nil
end

-- Convertit une position souris (GetMouseLocation, espace viewport complet
-- incluant le topbar) vers l'espace utilisé par AbsolutePosition. Quand un
-- ScreenGui a IgnoreGuiInset=true, son espace de coordonnées commence à Y=0
-- mais sa hauteur est viewport.Y - inset.Y. GetMouseLocation lui retourne
-- dans l'espace viewport complet (0..viewport.Y). Il faut donc soustraire
-- l'inset pour passer d'un espace à l'autre.
local function mouseToAbsoluteSpace(screenPos, guiObject)
	local screen = guiObject
	while screen and not screen:IsA("ScreenGui") do
		screen = screen.Parent
	end
	if screen and screen.IgnoreGuiInset then
		local topInset = game:GetService("GuiService"):GetGuiInset()
		return Vector2.new(screenPos.X - topInset.X, screenPos.Y - topInset.Y)
	end
	return screenPos
end

-- Cherche le slot hotbar sous une position écran.
local function findHotbarSlotAtPosition(screenPos)
	if not barFrame then return nil end
	for i, slot in ipairs(slotViews) do
		local adjusted = mouseToAbsoluteSpace(screenPos, slot.frame)
		local pos = slot.frame.AbsolutePosition
		local size = slot.frame.AbsoluteSize
		if adjusted.X >= pos.X and adjusted.X <= pos.X + size.X
			and adjusted.Y >= pos.Y and adjusted.Y <= pos.Y + size.Y then
			return i, slot
		end
	end
	return nil
end

-- Vérifie si la position écran est au-dessus du panneau inventaire (zone de la grille).
local function isInsideInventoryGrid(screenPos)
	if not inventoryGrid or not inventoryGui or not inventoryGui.Enabled then return false end
	local adjusted = mouseToAbsoluteSpace(screenPos, inventoryGrid)
	local pos = inventoryGrid.AbsolutePosition
	local size = inventoryGrid.AbsoluteSize
	return adjusted.X >= pos.X and adjusted.X <= pos.X + size.X
		and adjusted.Y >= pos.Y and adjusted.Y <= pos.Y + size.Y
end

local function createDragGhost(tool, parentGui)
	local ghost = Instance.new("ImageLabel")
	ghost.Name = "DragGhost"
	ghost.Size = UDim2.fromOffset(80, 80)
	ghost.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
	ghost.BackgroundTransparency = 0.1
	ghost.BorderSizePixel = 0
	ghost.ScaleType = Enum.ScaleType.Fit
	ghost.ZIndex = 100

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = ghost

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 215, 64)
	stroke.Thickness = 3
	stroke.Parent = ghost

	local imageId, tint = resolveIconFor(tool)
	if imageId and imageId ~= "" then
		ghost.Image = imageId
		ghost.ImageColor3 = tint or Color3.fromRGB(255, 255, 255)
	else
		ghost.Image = ""
		local initialsLbl = Instance.new("TextLabel")
		initialsLbl.AnchorPoint = Vector2.new(0.5, 0.5)
		initialsLbl.Position = UDim2.fromScale(0.5, 0.5)
		initialsLbl.Size = UDim2.fromScale(0.9, 0.6)
		initialsLbl.BackgroundTransparency = 1
		initialsLbl.FontFace = FONT_MONTSERRAT_EXTRA_BOLD
		initialsLbl.TextScaled = true
		initialsLbl.TextColor3 = Color3.fromRGB(235, 235, 245)
		initialsLbl.Text = getInitials(tool.Name)
		initialsLbl.ZIndex = 101
		initialsLbl.Parent = ghost
	end

	ghost.Parent = parentGui
	return ghost
end

local function startActualDrag(tool, origin)
	dragState.active = true
	dragState.tool = tool
	dragState.origin = origin

	-- Le ghost va dans l'inventaire si ouvert, sinon dans la hotbar.
	local parentGui = inventoryGui and inventoryGui.Enabled and inventoryGui or hotbarGui
	local ghost = createDragGhost(tool, parentGui)
	dragState.ghost = ghost

	local function updatePosition()
		local mouse = UserInputServiceLocal:GetMouseLocation()
		local absPos = mouseToAbsoluteSpace(mouse, ghost)
		ghost.Position = UDim2.fromOffset(absPos.X - 40, absPos.Y - 40)
	end

	updatePosition()

	dragState.moveConn = UserInputServiceLocal.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			updatePosition()
		end
	end)

	dragState.releaseConn = UserInputServiceLocal.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			SatchelController:_FinishDrag()
		end
	end)
end

-- Commence un drag potentiel. Ne devient un vrai drag qu'après que la souris
-- a bougé au-delà du seuil (DRAG_THRESHOLD_PX). Si l'utilisateur relâche
-- avant d'avoir bougé, c'est un simple clic -> équipe/déséquipe.
-- originKind = "inventory" ou "hotbar"
function SatchelController:_BeginDragPotential(tool, originKind)
	cancelPendingDrag()
	if dragState.active then endDrag() end
	if not tool or not tool:IsA("Tool") then return end

	local startPos = UserInputServiceLocal:GetMouseLocation()
	local started = false

	table.insert(dragPendingConns, UserInputServiceLocal.InputChanged:Connect(function(input)
		if started then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		local pos = UserInputServiceLocal:GetMouseLocation()
		if (pos - startPos).Magnitude >= DRAG_THRESHOLD_PX then
			started = true
			cancelPendingDrag()
			startActualDrag(tool, originKind)
		end
	end))

	table.insert(dragPendingConns, UserInputServiceLocal.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if not started then
			-- Simple clic = équipe / déséquipe (depuis hotbar uniquement ;
			-- depuis l'inventaire on ne fait rien pour éviter les clics accidentels).
			cancelPendingDrag()
			if originKind == "hotbar" then
				equipOrUnequipTool(tool)
			end
		end
	end))
end

function SatchelController:_FinishDrag()
	if not dragState.active then return end
	local tool = dragState.tool
	local origin = dragState.origin
	local mouse = UserInputServiceLocal:GetMouseLocation()
	local targetSlotIndex = findHotbarSlotAtPosition(mouse)
	local droppedInInventory = isInsideInventoryGrid(mouse)

	endDrag()

	if not tool then return end

	if targetSlotIndex then
		-- Drop sur la hotbar -> assigne au slot (swap géré dedans).
		assignToolToSlot(tool, targetSlotIndex)
	elseif droppedInInventory and origin == "hotbar" then
		-- Drop dans l'inventaire depuis la hotbar -> déplace en overflow.
		moveToolToOverflow(tool)
	end
	-- Tout autre drop : on ne change rien.
end


function SatchelController:SetInventoryOpen(open)
	-- Bloque toute ouverture pendant que le joueur est sous forme brainrot.
	-- Toute tentative d'ouverture (raccourci B, topbar icon, code externe)
	-- est convertie en "force-close" pour garantir que rien ne reste affiché.
	if open and isPlayerBrainrot() then
		open = false
	end
	inventoryOpen = open
	if inventoryGui then
		inventoryGui.Enabled = open
	end
	if open then
		refreshInventoryPanel()
	end
	if topbarIcon then
		if open and not topbarIcon.isSelected then
			topbarIcon:select("Inventory", topbarIcon)
		elseif not open and topbarIcon.isSelected then
			topbarIcon:deselect("Inventory", topbarIcon)
		end
	end
end

-- ===== Bouton TopbarPlus =====

local function createTopbarIcon()
	local ok, moduleOrErr = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Icon", 10))
	end)
	if not ok or not moduleOrErr then
		warn("[SatchelController] Impossible de charger TopbarPlus (ReplicatedStorage.Icon).")
		return
	end
	IconModule = moduleOrErr

	topbarIcon = IconModule.new()
	topbarIcon:setName("InventoryIcon")
	topbarIcon:setImage(INVENTORY_ICON_IMAGE)
	topbarIcon:setCaption("Inventory")
	topbarIcon:setOrder(-5)
	topbarIcon:align("Left")
	topbarIcon:bindToggleKey(Enum.KeyCode.B)

	topbarIcon.selected:Connect(function()
		-- Bloque l'ouverture via l'icône topbar (clic ou raccourci B) tant que
		-- le joueur est sous forme brainrot. On force la désélection visuelle
		-- pour que l'icône ne reste pas "appuyée".
		if isPlayerBrainrot() then
			if topbarIcon.isSelected then
				topbarIcon:deselect("Inventory", topbarIcon)
			end
			return
		end
		if not inventoryOpen then
			SatchelController:SetInventoryOpen(true)
		end
	end)
	topbarIcon.deselected:Connect(function()
		if inventoryOpen then
			SatchelController:SetInventoryOpen(false)
		end
	end)
end

-- ===== Désactivation de la Backpack par défaut =====

local function disableDefaultBackpack()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
end

local function keepBackpackHidden()
	-- Désactive la Backpack par défaut une seule fois (et au respawn via
	-- CharacterAdded qui fait un fullRehook). Le loop continu précédent était
	-- une perte inutile : SetCoreGuiEnabled(false) persiste entre les respawns.
	disableDefaultBackpack()
	player.CharacterAdded:Connect(disableDefaultBackpack)
end

-- ===== Cycle de vie =====

function SatchelController:Start()
	playerGui = player:WaitForChild("PlayerGui")

	pcall(function()
		WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig", 10))
	end)
	pcall(function()
		BrainrotImages = require(ReplicatedStorage.Shared:WaitForChild("BrainrotImages", 10))
	end)
	pcall(function()
		BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo", 10))
	end)

	createHotbar()
	createInventoryPanel()
	createTopbarIcon()
	keepBackpackHidden()

	-- ===== Stratégie de synchronisation des tools =====
	-- On utilise une approche multi-couches pour ne jamais rater un tool :
	--  1) CharacterAdded : capte les respawns.
	--  2) player.ChildAdded : capte la (re)création du Backpack.
	--  3) Hook Backpack/Character.ChildAdded via rehookAll (réactif).
	--  4) Polling périodique permanent : sécurité contre les signaux ratés
	--     (réplication tardive, Instance recyclée, etc.). knownTools déduplique.

	local function scanNow()
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			for _, child in ipairs(bp:GetChildren()) do
				if child:IsA("Tool") and not knownTools[child] then
					assignTool(child)
				end
			end
		end
		local character = player.Character
		if character then
			for _, child in ipairs(character:GetChildren()) do
				if child:IsA("Tool") and not knownTools[child] then
					assignTool(child)
				end
			end
		end
	end

	local function fullRehook()
		rehookAll()
		scanNow()
	end

	-- Hook immédiat si character/backpack déjà présents.
	fullRehook()

	player.CharacterAdded:Connect(function()
		player:WaitForChild("Backpack", 10)
		task.wait(0.2)
		fullRehook()
	end)

	-- Capte la (re)création du Backpack (certains games le nettoient au respawn).
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			task.wait(0.1)
			fullRehook()
		end
	end)

	-- Polling de sécurité : passe toutes les 0.5s pendant les 15 premières
	-- secondes (phase critique de chargement du DataService). Après ça, on
	-- arrête le polling : les hooks ChildAdded / CharacterAdded / player.ChildAdded
	-- couvrent tous les cas normaux de la session. Coût évité = 30 itérations
	-- par seconde en moins sur la durée de vie du client.
	task.spawn(function()
		for _ = 1, 30 do
			scanNow()
			task.wait(0.5)
		end
	end)

	for i, slot in ipairs(slotViews) do
		-- Click / drag : on utilise BeginDragPotential qui décide ensuite
		-- entre un simple clic (= équiper) et un drag selon le mouvement.
		slot.frame.MouseButton1Down:Connect(function()
			local tool = slot.tool
			if tool then
				SatchelController:_BeginDragPotential(tool, "hotbar")
			end
			_ = i
		end)
		slot.frame.MouseEnter:Connect(function()
			TweenService:Create(slot.frame, TweenInfo.new(0.12), {
				Size = UDim2.fromOffset(SLOT_SIZE + 4, SLOT_SIZE + 4),
			}):Play()
		end)
		slot.frame.MouseLeave:Connect(function()
			TweenService:Create(slot.frame, TweenInfo.new(0.12), {
				Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
			}):Play()
		end)
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		for i, info in ipairs(SLOT_KEYS) do
			if input.KeyCode == info.keyCode then
				equipOrUnequipSlot(i)
				return
			end
		end
	end)

	player:GetPropertyChangedSignal("Character"):Connect(applySelection)

	-- Reaction à la transformation brainrot : quand l'attribut bascule à true,
	-- on force la fermeture du panneau d'inventaire et on cache la hotbar.
	-- Quand il revient à false (joueur retrouve son character normal), on
	-- restaure la visibilité de la hotbar SAUF si un autre flag UI nous
	-- demande de la garder cachée (ex. KickZoneController via
	-- _G.SatchelEquipBlocked, qui cache le satchel quand on est dans la
	-- zone Kick juste après un dunk).
	local function applyBrainrotState()
		local isBrainrot = isPlayerBrainrot()
		if isBrainrot then
			-- Force la fermeture du panneau d'inventaire et cache la hotbar.
			if inventoryOpen then
				SatchelController:SetInventoryOpen(false)
			end
			if inventoryGui then inventoryGui.Enabled = false end
			if hotbarGui then hotbarGui.Enabled = false end
			-- Cache aussi l'icône topbar (sac à dos en haut à gauche). Sans ça,
			-- l'icône reste cliquable et visible même quand la hotbar est cachée.
			if topbarIcon then
				if topbarIcon.isSelected then
					pcall(function() topbarIcon:deselect("Inventory", topbarIcon) end)
				end
				pcall(function() topbarIcon:setEnabled(false) end)
			end
		else
			-- Réaffiche la hotbar et l'icône topbar uniquement si aucun autre
			-- système ne demande qu'elles restent cachées (KickZone, etc.).
			if not _G.SatchelEquipBlocked then
				if hotbarGui then hotbarGui.Enabled = true end
				if topbarIcon then
					pcall(function() topbarIcon:setEnabled(true) end)
				end
			end
		end
	end

	player:GetAttributeChangedSignal("IsBrainrot"):Connect(applyBrainrotState)
	-- Etat initial (au cas où l'attribut serait déjà set au join, ex. rejoin
	-- pendant qu'une session brainrot du serveur était encore active).
	applyBrainrotState()

	-- Garde-fou contre les écritures externes : pendant que le joueur est sous
	-- forme brainrot, n'importe quel autre controller (KickZoneController,
	-- TopbarPlus, code tiers) pourrait remettre Hotbar/Inventory.Enabled à
	-- true. On observe les changements et on force le retour à false tant que
	-- IsBrainrot est vrai. Sans cette garde, la téléportation du joueur hors
	-- de KickReady pendant la phase WaveChase déclenche un setSatchelVisible(true)
	-- qui rallumait la hotbar visible pendant toute la course.
	if hotbarGui then
		hotbarGui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if hotbarGui.Enabled and isPlayerBrainrot() then
				hotbarGui.Enabled = false
			end
		end)
	end
	if inventoryGui then
		inventoryGui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if inventoryGui.Enabled and isPlayerBrainrot() then
				inventoryGui.Enabled = false
			end
		end)
	end

	print("[SatchelController] Hotbar + inventaire initialisés.")
end

return SatchelController


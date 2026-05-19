--[[
	GamepassShopController
	Côté client des 5 gamepasses / products : StarterPack, CashX2, PowerX2,
	Speed12X, BrainrotLuck.

	Responsabilités :
	  - Brancher les clics des 5 entrées shop (StarterPack ImageButton +
	    4 Frames Gampass.Cash / Gampass1.Power / Gampass1.Speed / Gampass2.Brainrot)
	    sur MarketplaceService:PromptProductPurchase.
	  - Écouter GamepassStateEvent et afficher les icônes des gamepasses actifs
	    dans MainGui.BottomRight (UIListLayout existant).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local GamepassShopController = Loader.CreateController({
	Name = "GamepassShopController",
})

-- Cache local des flags actifs, alimenté par GamepassStateEvent. Utilisé pour
-- court-circuiter un clic sur un deal déjà possédé (évite que Roblox affiche
-- la popup "Vous possédez déjà ce produit").
local activeFlags = {}

-- Mapping : path dans ShopFrame.Scrolling.Deals -> productId
-- Chaque entrée peut être un ImageButton direct (StarterPack) ou une Frame
-- à laquelle on ajoute un listener de clic via un TextButton plein cadre.
local DEAL_PATHS = {
	{ path = { "StarterPack" },          productId = GamepassConfig.PRODUCTS.STARTER_PACK,  flag = "StarterPack" },
	{ path = { "Gampass", "Cash" },      productId = GamepassConfig.PRODUCTS.CASH_X2,       flag = "CashX2" },
	{ path = { "Gampass", "Vip" },       productId = GamepassConfig.PRODUCTS.VIP,           flag = "VIP" },
	{ path = { "Gampass1", "Power" },    productId = GamepassConfig.PRODUCTS.POWER_X2,      flag = "PowerX2" },
	{ path = { "Gampass1", "Speed" },    productId = GamepassConfig.PRODUCTS.SPEED_1_2X,    flag = "Speed12X" },
	{ path = { "Gampass2", "Brainrot" }, productId = GamepassConfig.PRODUCTS.BRAINROT_LUCK, flag = "BrainrotLuck" },
	{ path = { "Gampass2", "Mutation" }, productId = GamepassConfig.PRODUCTS.MUTATION_LUCK, flag = "MutationLuck" },
}

-- Rend une Frame cliquable en y ajoutant un TextButton transparent plein cadre.
-- Retourne la connection pour pouvoir déconnecter plus tard si besoin.
local function makeFrameClickable(frame, onClick)
	if frame:IsA("ImageButton") or frame:IsA("TextButton") then
		return frame.MouseButton1Click:Connect(onClick)
	end
	-- Frame : on ajoute un TextButton invisible plein cadre.
	local existing = frame:FindFirstChild("_GamepassClickCatcher")
	if existing then
		return existing.MouseButton1Click:Connect(onClick)
	end
	local btn = Instance.new("TextButton")
	btn.Name = "_GamepassClickCatcher"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.AutoButtonColor = false
	btn.ZIndex = 100
	btn.Parent = frame
	return btn.MouseButton1Click:Connect(onClick)
end

local function resolvePath(root, path)
	local node = root
	for _, name in ipairs(path) do
		node = node and node:WaitForChild(name, 30)
		if not node then return nil end
	end
	return node
end

-- ===== ICÔNES BOTTOMRIGHT =====

local BOTTOMRIGHT_NAME = "BottomRight"
local ICON_PREFIX = "_GamepassIcon_"

-- Texte de tooltip affiché au hover de chaque icône.
local TOOLTIP_TEXT = {
	CashX2       = "x2 Cash",
	PowerX2      = "x2 Power",
	Speed12X     = "x1.2 Speed",
	BrainrotLuck = "x2 Lucky Brainrot",
	VIP          = "VIP : x1.5 Cash + x2 Luck",
	MutationLuck = "x2 Mutation Luck",
}

local TOOLTIP_FONT = Font.new(
	"rbxasset://fonts/families/Montserrat.json",
	Enum.FontWeight.ExtraBold,
	Enum.FontStyle.Normal
)

-- Ajoute un BillboardGui tooltip enfant de l'icône : visible uniquement au hover.
-- Pas de frame/fond, juste du texte blanc avec contour noir.
local function buildTooltip(icon, text)
	if icon:FindFirstChild("_Tooltip") then
		return
	end
	local tt = Instance.new("Frame")
	tt.Name = "_Tooltip"
	tt.BackgroundTransparency = 1
	tt.Size = UDim2.fromScale(1.6, 0.4)
	-- Positionné au-dessus de l'icône (AnchorPoint bas centre).
	tt.AnchorPoint = Vector2.new(0.5, 1)
	tt.Position = UDim2.new(0.5, 0, 0, -4)
	tt.Visible = false
	tt.ZIndex = 50
	tt.Parent = icon

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = TOOLTIP_FONT
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = 51
	label.Parent = tt

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	-- Hover events : on les place sur l'icône (ImageLabel n'émet pas MouseEnter
	-- directement, mais en Roblox si c'est dans un ScreenGui visible avec
	-- Active=true ça fonctionne).
	icon.Active = true
	icon.MouseEnter:Connect(function()
		tt.Visible = true
	end)
	icon.MouseLeave:Connect(function()
		tt.Visible = false
	end)
end

local function ensureIcon(bottomRight, flag, iconId, layoutOrder)
	local iconName = ICON_PREFIX .. flag
	local existing = bottomRight:FindFirstChild(iconName)
	if existing then
		return existing
	end

	local img = Instance.new("ImageLabel")
	img.Name = iconName
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(0.086, 0.647)
	img.Image = iconId
	img.ScaleType = Enum.ScaleType.Fit
	img.LayoutOrder = layoutOrder or 0

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = img

	img.Parent = bottomRight

	-- Ajoute le tooltip de hover.
	local ttText = TOOLTIP_TEXT[flag]
	if ttText then
		buildTooltip(img, ttText)
	end

	return img
end

local function removeIcon(bottomRight, flag)
	local iconName = ICON_PREFIX .. flag
	local existing = bottomRight:FindFirstChild(iconName)
	if existing then existing:Destroy() end
end

local function syncIcons(bottomRight, flags)
	-- Affiche uniquement les icônes récurrentes (pas le StarterPack qui est
	-- one-shot). Ordre fixe : VIP > Cash > Power > Speed > BrainrotLuck > MutationLuck.
	local ICON_SPEC = {
		{ flag = "VIP",          icon = GamepassConfig.ICONS.VIP,           order = 0 },
		{ flag = "CashX2",       icon = GamepassConfig.ICONS.CASH_X2,       order = 1 },
		{ flag = "PowerX2",      icon = GamepassConfig.ICONS.POWER_X2,      order = 2 },
		{ flag = "Speed12X",     icon = GamepassConfig.ICONS.SPEED_1_2X,    order = 3 },
		{ flag = "BrainrotLuck", icon = GamepassConfig.ICONS.BRAINROT_LUCK, order = 4 },
		{ flag = "MutationLuck", icon = GamepassConfig.ICONS.MUTATION_LUCK, order = 5 },
	}
	for _, spec in ipairs(ICON_SPEC) do
		if flags[spec.flag] then
			ensureIcon(bottomRight, spec.flag, spec.icon, spec.order)
		else
			removeIcon(bottomRight, spec.flag)
		end
	end
end

-- ===== START =====

function GamepassShopController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end

	local shopFrame = mainGui:WaitForChild("ShopFrame", 30)
	local scrolling = shopFrame and shopFrame:WaitForChild("Scrolling", 30)
	local deals = scrolling and scrolling:WaitForChild("Deals", 30)
	if not deals then
		warn("[GamepassShopController] Deals introuvable")
		return
	end

	local bottomRight = mainGui:WaitForChild(BOTTOMRIGHT_NAME, 30)

	-- Branche les entrées shop sur PromptProductPurchase. On ignore les deals
	-- dont productId est nil ou <= 0 (gamepass non encore publiés sur la page
	-- Roblox) : ils restent cliquables visuellement mais ne lancent rien.
	for _, dealSpec in ipairs(DEAL_PATHS) do
		task.spawn(function()
			local target = resolvePath(deals, dealSpec.path)
			if not target then
				warn("[GamepassShopController] Deal introuvable : " .. table.concat(dealSpec.path, "."))
				return
			end
			makeFrameClickable(target, function()
				-- Si le joueur possède déjà ce gamepass/product, on n'affiche pas
				-- la popup d'achat Robux : achats one-shot uniquement.
				if dealSpec.flag and activeFlags[dealSpec.flag] then
					return
				end
				if not dealSpec.productId or dealSpec.productId <= 0 then
					warn("[GamepassShopController] " .. dealSpec.flag .. " : productId non configuré (id à 0 dans GamepassConfig)")
					return
				end
				local ok, err = pcall(function()
					MarketplaceService:PromptProductPurchase(player, dealSpec.productId)
				end)
				if not ok then
					warn("[GamepassShopController] Prompt " .. dealSpec.productId .. " : " .. tostring(err))
				end
			end)
		end)
	end

	-- Écoute les updates d'état des gamepasses pour (dés)afficher les icônes
	-- ET pour maintenir le cache local utilisé au clic.
	local gamepassStateEvent = RemotesAPI.GetEvent("GamepassStateEvent")
	gamepassStateEvent.OnClientEvent:Connect(function(flags)
		activeFlags = flags or {}
		if bottomRight then
			syncIcons(bottomRight, activeFlags)
		end
	end)

	print("[GamepassShopController] Prêt")
end

return GamepassShopController

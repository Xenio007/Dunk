--[[
	ServerLuckController
	Côté client du boost de Luck partagé :

	  - Écoute le RemoteEvent `ServerLuckStateEvent` (server -> all clients)
	    pour connaître le multiplicateur courant et l'heure d'expiration.
	  - Met à jour les labels Luck1 / Luck2 dans le shop ShopFrame.Scrolling.Deals.ServerLuck.
	    Luck1 = multiplicateur actuel (x1, x2, ...), Luck2 = prochain (x2, x3, ...).
	  - Câble le clic sur le bouton de la frame ServerLuck pour prompt le product
	    SERVER_LUCK en Robux.
	  - Affiche/masque une icône "ServerLuck" dans MainGui.BottomRight avec un
	    label du multiplicateur courant + countdown de temps restant.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local ServerLuckController = Loader.CreateController({
	Name = "ServerLuckController",
})

-- État local répliqué du serveur.
local currentMultiplier = 1
local expiresAt = 0         -- timestamp serveur (GetServerTimeNow)
local serverTimeOffset = 0  -- différence entre serverTimeNow et client os.time() au moment du sync

-- UI refs.
local luck1Label
local luck2Label
local maxLabel
local arrowImg
local buyLabel
local buyButton      -- ImageLabel "Buy" du shop (on y ajoute un TextButton plein cadre)
local serverLuckFrame

-- Icône BottomRight.
local iconFrame
local iconCountdownLabel
local iconMultiplierLabel

-- Pas de cap côté config : chaque achat DOUBLE le multiplicateur. Le label
-- "Max" hérité dans le shop est donc masqué en permanence.
local function nextStep(current)
	current = math.max(1, tonumber(current) or 1)
	return current * 2
end

local function formatSeconds(total)
	total = math.max(0, math.floor(total))
	local m = math.floor(total / 60)
	local s = total - m * 60
	return string.format("%d:%02d", m, s)
end

-- ===== SHOP UI =====

local function refreshShopLabels()
	if luck1Label then
		luck1Label.Text = "x" .. tostring(currentMultiplier)
		luck1Label.Visible = true
	end
	if luck2Label then
		luck2Label.Text = "x" .. tostring(nextStep(currentMultiplier))
		luck2Label.Visible = true
	end
	if arrowImg then arrowImg.Visible = true end
	-- Le label "x6 (MAX)" était hardcodé dans le ScreenGui. Plus de cap ->
	-- on le force masqué.
	if maxLabel then maxLabel.Visible = false end
	if buyLabel then buyLabel.Text = "Buy" end
end

local function wireShopButton()
	if not serverLuckFrame and not buyButton then return end
	local host = serverLuckFrame or buyButton
	if host:FindFirstChild("_ServerLuckClickCatcher") then return end

	local btn = Instance.new("TextButton")
	btn.Name = "_ServerLuckClickCatcher"
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.AutoButtonColor = false
	btn.ZIndex = 100
	-- On veut que TOUTE la frame ServerLuck soit cliquable, pas seulement le
	-- bouton Buy. On parente donc au root de la frame plutôt qu'au Buy.
	local target = serverLuckFrame or buyButton
	btn.Parent = target

	btn.MouseButton1Click:Connect(function()
		local productId = GamepassConfig.PRODUCTS.SERVER_LUCK
		if not productId or productId <= 0 then
			warn("[ServerLuckController] SERVER_LUCK productId non configuré")
			return
		end
		local ok, err = pcall(function()
			MarketplaceService:PromptProductPurchase(Players.LocalPlayer, productId)
		end)
		if not ok then
			warn("[ServerLuckController] Prompt " .. productId .. " : " .. tostring(err))
		end
	end)
end

-- ===== ICON BOTTOMRIGHT =====

local ICON_NAME = "_GamepassIcon_ServerLuck"
local ICON_IMAGE = GamepassConfig.ICONS.SERVER_LUCK or GamepassConfig.ICONS.BRAINROT_LUCK

local function ensureIconFrame(bottomRight)
	if iconFrame and iconFrame.Parent then return iconFrame end
	local existing = bottomRight:FindFirstChild(ICON_NAME)
	if existing then existing:Destroy() end

	local frame = Instance.new("Frame")
	frame.Name = ICON_NAME
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(0.086, 0.647)
	frame.LayoutOrder = 6 -- après les autres icônes gamepass

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = frame

	local img = Instance.new("ImageLabel")
	img.Name = "Image"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = ICON_IMAGE
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = frame

	-- Multiplicateur (gros texte en bas de l'icône, ex "x2").
	local multLbl = Instance.new("TextLabel")
	multLbl.Name = "Multiplier"
	multLbl.BackgroundTransparency = 1
	multLbl.AnchorPoint = Vector2.new(0.5, 1)
	multLbl.Position = UDim2.fromScale(0.5, 0.95)
	multLbl.Size = UDim2.fromScale(1, 0.45)
	multLbl.Font = Enum.Font.GothamBlack
	multLbl.Text = "x2"
	multLbl.TextColor3 = Color3.fromRGB(170, 255, 0)
	multLbl.TextScaled = true
	multLbl.TextStrokeTransparency = 0
	multLbl.TextStrokeColor3 = Color3.fromRGB(20, 50, 0)
	multLbl.ZIndex = 2
	multLbl.Parent = frame

	-- Countdown (petit, sous le multiplier).
	local cdLbl = Instance.new("TextLabel")
	cdLbl.Name = "Countdown"
	cdLbl.BackgroundTransparency = 1
	cdLbl.AnchorPoint = Vector2.new(0.5, 0)
	cdLbl.Position = UDim2.fromScale(0.5, 1)
	cdLbl.Size = UDim2.fromScale(1.5, 0.25)
	cdLbl.Font = Enum.Font.GothamBold
	cdLbl.Text = "15:00"
	cdLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	cdLbl.TextScaled = true
	cdLbl.TextStrokeTransparency = 0
	cdLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	cdLbl.ZIndex = 2
	cdLbl.Parent = frame

	frame.Parent = bottomRight

	iconFrame = frame
	iconCountdownLabel = cdLbl
	iconMultiplierLabel = multLbl
	return frame
end

local function updateIconVisibility()
	if not iconFrame then return end
	local active = currentMultiplier > 1 and (expiresAt + serverTimeOffset) > os.time()
	iconFrame.Visible = active
	if active and iconMultiplierLabel then
		iconMultiplierLabel.Text = "x" .. tostring(currentMultiplier)
	end
end

-- Countdown tick (1 Hz pour économiser les frames).
local tickAccumulator = 0
local function onHeartbeat(dt)
	tickAccumulator = tickAccumulator + dt
	if tickAccumulator < 0.5 then return end
	tickAccumulator = 0

	if not iconFrame or not iconFrame.Visible then return end
	if not iconCountdownLabel then return end

	local remaining = (expiresAt + serverTimeOffset) - os.time()
	if remaining <= 0 then
		-- Timer expiré : cache l'icône en attendant la notification serveur.
		iconFrame.Visible = false
	else
		iconCountdownLabel.Text = formatSeconds(remaining)
	end
end

-- ===== LIFECYCLE =====

function ServerLuckController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end

	-- Résolution des références du shop (ne bloque pas si le chemin change).
	task.spawn(function()
		local shopFrame = mainGui:WaitForChild("ShopFrame", 30)
		local scrolling = shopFrame and shopFrame:WaitForChild("Scrolling", 30)
		local deals = scrolling and scrolling:WaitForChild("Deals", 30)
		local slRoot = deals and deals:WaitForChild("ServerLuck", 30)
		if not slRoot then return end
		serverLuckFrame = slRoot

		-- Path : ServerLuck.Frame.Frame
		local inner = slRoot:WaitForChild("Frame", 10)
		inner = inner and inner:WaitForChild("Frame", 10)
		if not inner then return end

		luck1Label = inner:FindFirstChild("Luck1")
		luck2Label = inner:FindFirstChild("Luck2")
		arrowImg   = inner:FindFirstChild("Arrow")
		maxLabel   = inner:FindFirstChild("Max")
		buyButton  = inner:FindFirstChild("Buy")
		if buyButton then
			local frame = buyButton:FindFirstChild("Frame")
			buyLabel = frame and frame:FindFirstChild("TextLabel")
		end

		refreshShopLabels()
		wireShopButton()
	end)

	-- BottomRight : crée l'icône (cachée tant que multiplier <= 1).
	local bottomRight = mainGui:WaitForChild("BottomRight", 30)
	if bottomRight then
		ensureIconFrame(bottomRight)
		updateIconVisibility()
	end

	-- Écoute le state event du serveur.
	local luckStateEvent = RemotesAPI.GetEvent("ServerLuckStateEvent")
	luckStateEvent.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		currentMultiplier = tonumber(payload.Multiplier) or 1
		expiresAt = tonumber(payload.ExpiresAt) or 0
		local serverNow = tonumber(payload.ServerNow) or Workspace:GetServerTimeNow()
		serverTimeOffset = os.time() - serverNow
		refreshShopLabels()
		updateIconVisibility()
	end)

	RunService.Heartbeat:Connect(onHeartbeat)

	print("[ServerLuckController] Prêt")
end

return ServerLuckController

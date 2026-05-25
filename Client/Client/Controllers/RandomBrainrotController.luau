--[[
	RandomBrainrotController (Controller module)
	Gère StarterGui.MainGui.UIRight.RandomBrainrot :

	1. Visibilité géo : invisible dans les pays bloqués pour le casino (random
	   loot box payant). Exception : le UserId du créateur peut toujours le voir
	   (test perso depuis la Belgique).

	2. Sunburst tourne en continu (1 sens, vitesse douce).

	3. 6 ShadowBrainrot enfants : on n'en affiche qu'une seule à la fois,
	   on alterne avec un fondu.

	4. Click -> PromptProductPurchase (productId 3591856301).

	Note : le bouton a été déplacé sous MainGui.UIRight (au lieu de MainGui).
--]]

local Players              = game:GetService("Players")
local LocalizationService  = game:GetService("LocalizationService")
local MarketplaceService   = game:GetService("MarketplaceService")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local RunService           = game:GetService("RunService")
local TweenService         = game:GetService("TweenService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local RandomBrainrotController = Loader.CreateController({
	Name = "RandomBrainrotController",
})

-- ID du Developer Product ouvrant un brainrot aléatoire.
local RANDOM_BRAINROT_PRODUCT_ID = 3591856301

-- Pays où le random reward payant n'est PAS autorisé.
local CASINO_BLOCKED_COUNTRIES = {
	BE = true, NL = true, AU = true, BR = true, CN = true,
	KR = true, JP = true, TR = true, IL = true, IN = true,
}

-- Exception : UserId du créateur (à ajouter si besoin).
local CREATOR_USER_IDS = {
	-- [123456789] = true,
}

function RandomBrainrotController:Start()
	local player    = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[RandomBrainrotController] MainGui introuvable")
		return
	end

	-- Le bouton vit maintenant sous MainGui.UIRight (regroupé avec AutoCollect).
	local uiRight = mainGui:WaitForChild("UIRight", 15)
	if not uiRight then
		warn("[RandomBrainrotController] UIRight introuvable")
		return
	end

	local randomBrainrot = uiRight:WaitForChild("RandomBrainrot", 15)
	if not randomBrainrot or not randomBrainrot:IsA("ImageButton") then
		warn("[RandomBrainrotController] RandomBrainrot button introuvable")
		return
	end

	-- ============================================================
	-- 1) Visibilité géo : on cache par défaut, on révèle si OK.
	-- ============================================================
	randomBrainrot.Visible = false

	local function isAllowed()
		if CREATOR_USER_IDS[player.UserId] then return true end
		local ok, country = pcall(function()
			return LocalizationService:GetCountryRegionForPlayerAsync(player)
		end)
		if not ok or not country then return false end
		if CASINO_BLOCKED_COUNTRIES[string.upper(country)] then return false end
		return true
	end

	task.spawn(function()
		randomBrainrot.Visible = isAllowed()
	end)

	-- ============================================================
	-- 2) Sunburst : rotation continue.
	-- ============================================================
	local sunburst = randomBrainrot:FindFirstChild("Sunburst")
	if sunburst then
		local SPIN_SPEED = 30  -- degrés par seconde
		local lastTick = os.clock()
		RunService.RenderStepped:Connect(function()
			if not randomBrainrot.Visible then
				lastTick = os.clock()
				return
			end
			local now = os.clock()
			local dt = now - lastTick
			lastTick = now
			sunburst.Rotation = (sunburst.Rotation + SPIN_SPEED * dt) % 360
		end)
	end

	-- ============================================================
	-- 3) ShadowBrainrot : on alterne 1 visible à la fois.
	-- ============================================================
	local shadows = {}
	for _, c in ipairs(randomBrainrot:GetChildren()) do
		if c.Name == "ShadowBrainrot" and c:IsA("ImageLabel") then
			table.insert(shadows, c)
		end
	end
	for i, s in ipairs(shadows) do
		s.ImageTransparency = (i == 1) and 0 or 1
		s.Visible = true
	end

	if #shadows > 1 then
		local current = 1
		local SWITCH_INTERVAL = 1.2
		local FADE_DURATION   = 0.25
		task.spawn(function()
			while randomBrainrot.Parent do
				task.wait(SWITCH_INTERVAL)
				if not randomBrainrot.Visible then continue end
				local nextIdx = (current % #shadows) + 1
				local cur = shadows[current]
				local nxt = shadows[nextIdx]
				local info = TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				TweenService:Create(cur, info, { ImageTransparency = 1 }):Play()
				TweenService:Create(nxt, info, { ImageTransparency = 0 }):Play()
				current = nextIdx
			end
		end)
	end

	-- ============================================================
	-- 4) Click -> PromptProductPurchase
	-- ============================================================
	local lastClick = 0
	randomBrainrot.MouseButton1Click:Connect(function()
		local now = os.clock()
		if now - lastClick < 0.5 then return end
		lastClick = now
		if not randomBrainrot.Visible then return end
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, RANDOM_BRAINROT_PRODUCT_ID)
		end)
	end)

	print("[RandomBrainrotController] Prêt")
end

return RandomBrainrotController

--[[
	MenuAnimationController
	Ajoute une animation pop-in à l'ouverture des menus principaux du MainGui.
	Avant : les frames apparaissaient sans transition ("crue"). Après :
	elles scalent de OPEN_FROM à 1.0 avec un easing Back.Out.

	Note : on N'INTERCEPTE PAS la fermeture. Ajouter un tween de close-out
	rentrait en conflit avec le PropertyChangedSignal en mode "deferred"
	(le frame restait visible après clic sur la croix). On laisse donc la
	fermeture naturelle (Visible=false instantané) gérée par UIController.

	Les frames couvertes : IndexFrame, RebirthFrame, ShopFrame, WeightsFrame,
	RunFrame, LikeFrame, GiftFrame, SellFrame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local MenuAnimationController = Loader.CreateController({
	Name = "MenuAnimationController",
})

local MENU_NAMES = {
	["IndexFrame"]   = true,
	["RebirthFrame"] = true,
	["ShopFrame"]    = true,
	["WeightsFrame"] = true,
	["RunFrame"]     = true,
	["LikeFrame"]    = true,
	["GiftFrame"]    = true,
	["SellFrame"]    = true,
}

-- Anim renforcée pour que le pop soit clairement visible à l'œil : on part
-- de 0.5 (au lieu de 0.6) avec une durée légèrement plus longue. Easing Back.Out
-- pour le léger overshoot caractéristique d'un pop-up moderne.
local OPEN_TWEEN  = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_FROM   = 0.5

-- État par frame pour éviter de doubler les tweens.
local frameStates = {}
local frameStates = {}

local function getOrCreateScale(frame)
	local scale = frame:FindFirstChild("_MenuAnimScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "_MenuAnimScale"
		scale.Scale = 1
		scale.Parent = frame
	end
	return scale
end

local function playOpenFor(frame)
	local state = frameStates[frame]
	if not state then
		-- Pas encore attaché (race condition très rare). On crée le scale à la
		-- volée pour que l'anim joue quand même.
		local scale = getOrCreateScale(frame)
		scale.Scale = OPEN_FROM
		TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 }):Play()
		return
	end
	if state.activeTween then
		state.activeTween:Cancel()
		state.activeTween = nil
	end
	state.scale.Scale = OPEN_FROM
	local t = TweenService:Create(state.scale, OPEN_TWEEN, { Scale = 1 })
	state.activeTween = t
	t:Play()
end

-- Expose l'API publique pour que UIController / SpeedShopController puissent
-- déclencher l'anim sans avoir à dupliquer la logique du tween.
MenuAnimationController.PlayPopIn = function(_, frame)
	if typeof(frame) == "Instance" and frame:IsA("GuiObject") then
		playOpenFor(frame)
	end
end

local function attach(frame)
	if frameStates[frame] then return end
	local scale = getOrCreateScale(frame)
	local state = {
		scale = scale,
		activeTween = nil,
	}
	frameStates[frame] = state

	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			playOpenFor(frame)
		else
			-- Fermeture instantanée : on annule le tween en cours pour ne pas
			-- laisser le scale dériver et on reset à 1 pour la prochaine ouverture.
			if state.activeTween then
				state.activeTween:Cancel()
				state.activeTween = nil
			end
			scale.Scale = 1
		end
	end)

	-- Cas où la frame est déjà visible au moment de l'attach (rare, mais
	-- arrive si MenuAnimationController:Start s'exécute après qu'un autre
	-- controller ait déjà ouvert la frame). On joue le pop-in à l'attach
	-- pour ne pas avoir l'apparence "crue" sur ce premier render.
	if frame.Visible then
		playOpenFor(frame)
	end
end

function MenuAnimationController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end

	-- Attache chaque menu existant. Plusieurs frames peuvent partager le même
	-- nom (ex: SellFrame x2), on les attache toutes.
	for _, child in ipairs(mainGui:GetChildren()) do
		if MENU_NAMES[child.Name] and child:IsA("GuiObject") then
			attach(child)
		end
	end

	-- En cas d'ajout dynamique (rare mais safe).
	mainGui.ChildAdded:Connect(function(child)
		if MENU_NAMES[child.Name] and child:IsA("GuiObject") then
			attach(child)
		end
	end)

	print("[MenuAnimationController] Prêt")
end

return MenuAnimationController

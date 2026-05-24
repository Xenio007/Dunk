--[[
	MenuAnimationController
	Ajoute une animation pop-in à l'ouverture des menus principaux du MainGui.
	Avant : les frames apparaissaient sans transition ("crue"). Après :
	elles scalent de 0.6 à 1.0 avec un easing Back.Out.

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
	"IndexFrame", "RebirthFrame", "ShopFrame", "WeightsFrame",
	"RunFrame", "LikeFrame", "GiftFrame", "SellFrame",
}

local OPEN_TWEEN  = TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_FROM   = 0.6

-- État par frame pour éviter de doubler les tweens.
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

local function attach(frame)
	if frameStates[frame] then return end
	local scale = getOrCreateScale(frame)
	local state = {
		scale = scale,
		activeTween = nil,
	}
	frameStates[frame] = state

	local function playOpen()
		if state.activeTween then
			state.activeTween:Cancel()
			state.activeTween = nil
		end
		scale.Scale = OPEN_FROM
		local t = TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 })
		state.activeTween = t
		t:Play()
	end

	frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			playOpen()
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
end

function MenuAnimationController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end

	-- Attache chaque menu existant. Plusieurs frames peuvent partager le même
	-- nom (ex: SellFrame x2), on les attache toutes.
	for _, child in ipairs(mainGui:GetChildren()) do
		for _, name in ipairs(MENU_NAMES) do
			if child.Name == name and (child:IsA("GuiObject")) then
				attach(child)
			end
		end
	end

	-- En cas d'ajout dynamique (rare mais safe).
	mainGui.ChildAdded:Connect(function(child)
		for _, name in ipairs(MENU_NAMES) do
			if child.Name == name and child:IsA("GuiObject") then
				attach(child)
				break
			end
		end
	end)

	print("[MenuAnimationController] Prêt")
end

return MenuAnimationController

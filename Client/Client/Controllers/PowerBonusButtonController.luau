--[[
	PowerBonusButtonController
	Toutes les 5 reps de lift (AddPowerEvent), affiche le ButtonPurpleClick
	existant dans MainGui à une position aléatoire de l'écran et le secoue
	gauche/droite. Click -> +2x PowerPerLift via PowerBonusClaimEvent.

	Le popup "+X Power" est géré côté PowerPopupController : quand le serveur
	refire AddPowerEvent après un claim, le PowerPopupController déclenche
	automatiquement l'animation icone -> YeetLevel.

	Migration 1:1 de StarterPlayerScripts.PowerBonusButtonLocalScript en
	Controller module (Single-Script Architecture).
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local Loader     = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local PowerBonusButtonController = Loader.CreateController({
	Name = "PowerBonusButtonController",
})

local REPS_PER_BONUS = 5
local SHOW_DURATION  = 8

function PowerBonusButtonController:Start()
	local player    = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end
	local button = mainGui:WaitForChild("ButtonPurpleClick", 15)
	if not button then
		warn("[PowerBonusButtonController] ButtonPurpleClick introuvable")
		return
	end

	local addPowerEvent   = RemotesAPI.GetEvent("AddPowerEvent")
	local powerBonusEvent = RemotesAPI.GetEvent("PowerBonusClaimEvent")

	-- Mémorise position et anchor d'origine pour restaurer après l'animation.
	local ORIGINAL_POSITION = button.Position
	local ORIGINAL_ANCHOR   = button.AnchorPoint
	button.Visible = false

	-- UIScale local (n'écrase pas un éventuel UIScale déjà présent).
	local scale = button:FindFirstChild("PowerBonusUIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "PowerBonusUIScale"
		scale.Scale = 1
		scale.Parent = button
	end

	local shakeConn
	local hideTask
	local currentBaseX, currentBaseY = 0.5, 0.5

	local function startShake()
		if shakeConn then shakeConn:Disconnect() end
		local start = os.clock()
		shakeConn = RunService.RenderStepped:Connect(function()
			local t = os.clock() - start
			local offX = math.sin(t * 12) * 8
			local offY = math.sin(t * 18) * 2
			local rot  = math.sin(t * 12) * 3
			button.Position = UDim2.new(currentBaseX, offX, currentBaseY, offY)
			button.Rotation = rot
		end)
	end

	local function stopShake()
		if shakeConn then shakeConn:Disconnect(); shakeConn = nil end
		button.Rotation = 0
	end

	local function hideButton()
		if hideTask then task.cancel(hideTask); hideTask = nil end
		stopShake()
		local tw = TweenService:Create(scale,
			TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Scale = 0 })
		tw:Play()
		tw.Completed:Once(function()
			button.Visible = false
			button.Position = ORIGINAL_POSITION
			button.AnchorPoint = ORIGINAL_ANCHOR
			button.Rotation = 0
			scale.Scale = 1
		end)
	end

	local function showButton()
		-- Position aléatoire à l'écran (marges pour rester lisible). AnchorPoint
		-- 0.5,0.5 pour que la position soit le centre du bouton.
		currentBaseX = 0.18 + math.random() * 0.64
		currentBaseY = 0.20 + math.random() * 0.55
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.fromScale(currentBaseX, currentBaseY)
		button.Visible = true
		scale.Scale = 0
		TweenService:Create(scale,
			TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()
		startShake()
		if hideTask then task.cancel(hideTask) end
		hideTask = task.delay(SHOW_DURATION, hideButton)
	end

	-- ============================================================
	-- Click -> envoie le claim au serveur. Le serveur ajoute le bonus
	-- et refire AddPowerEvent (avec isBonus=true) -> le PowerPopupController
	-- affiche automatiquement le popup "+X Power".
	-- ============================================================
	button.MouseButton1Click:Connect(function()
		if not button.Visible then return end
		powerBonusEvent:FireServer()
		hideButton()
	end)

	-- ============================================================
	-- Compteur de reps : on affiche le bouton tous les 5 lifts normaux.
	-- isBonus=true (claim de bouton) ne compte PAS, sinon spam infini.
	-- ============================================================
	local repCount = 0
	addPowerEvent.OnClientEvent:Connect(function(_gain, isBonus)
		if isBonus then return end
		repCount += 1
		if repCount >= REPS_PER_BONUS then
			repCount = 0
			showButton()
		end
	end)

	-- ============================================================
	-- Déséquipement du poids -> cache le bouton immédiatement
	-- ============================================================
	player.CharacterRemoving:Connect(hideButton)
	
	local function onCharacterAdded(character)
		character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				-- On vérifie si c'est un weight tool via WeightsConfig
				if WeightsConfig.AnimationByWeight[child.Name] then
					hideButton()
				end
			end
		end)
	end
	
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then onCharacterAdded(player.Character) end

	print("[PowerBonusButtonController] Prêt (utilise MainGui.ButtonPurpleClick)")
end

return PowerBonusButtonController

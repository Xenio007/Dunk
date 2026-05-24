--[[
	MissingCashNotifier
	Controller utilitaire : affiche un texte rouge "Missing Cash" en haut de
	l'écran qui apparaît/disparaît en fondu avec un léger pop scale.

	API publique :
		MissingCashNotifier:Show(message) -- message optionnel, défaut "Missing Cash"

	Plusieurs appels rapprochés rejouent l'anim sans empiler des frames.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local MissingCashNotifier = Loader.CreateController({
	Name = "MissingCashNotifier",
})

local screenGui
local label
local scale
local stroke
local activeTween
local hideTask

local SHOW_DURATION = 0.18
local HIDE_DURATION = 0.35
local HOLD_TIME = 1.6

local function ensureBuilt()
	if screenGui and screenGui.Parent then return end
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MissingCashNotifier"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 1500
	screenGui.Enabled = true
	screenGui.Parent = playerGui

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.Position = UDim2.fromScale(0.5, 0.06)
	container.Size = UDim2.fromScale(0.6, 0.08)
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = "Missing Cash"
	label.TextColor3 = Color3.fromRGB(255, 60, 60)
	label.TextScaled = true
	label.TextTransparency = 1
	label.Parent = container

	stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 3
	stroke.Transparency = 1
	stroke.Parent = label

	scale = Instance.new("UIScale")
	scale.Scale = 0.85
	scale.Parent = container
end

local function cancelActive()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	if hideTask then
		task.cancel(hideTask)
		hideTask = nil
	end
end

function MissingCashNotifier:Show(message)
	ensureBuilt()
	cancelActive()

	label.Text = message or "Missing Cash"
	label.TextTransparency = 1
	stroke.Transparency = 1
	scale.Scale = 0.85

	local showInfo = TweenInfo.new(SHOW_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local labelIn = TweenService:Create(label, showInfo, { TextTransparency = 0 })
	local strokeIn = TweenService:Create(stroke, showInfo, { Transparency = 0 })
	local scaleIn = TweenService:Create(scale, showInfo, { Scale = 1 })
	labelIn:Play()
	strokeIn:Play()
	scaleIn:Play()
	activeTween = scaleIn

	hideTask = task.delay(SHOW_DURATION + HOLD_TIME, function()
		hideTask = nil
		local hideInfo = TweenInfo.new(HIDE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local labelOut = TweenService:Create(label, hideInfo, { TextTransparency = 1 })
		local strokeOut = TweenService:Create(stroke, hideInfo, { Transparency = 1 })
		local scaleOut = TweenService:Create(scale, hideInfo, { Scale = 0.92 })
		labelOut:Play()
		strokeOut:Play()
		scaleOut:Play()
		activeTween = scaleOut
	end)
end

function MissingCashNotifier:Start()
	-- Build immediate. Permet à d'autres controllers de Show() sans warmup.
	ensureBuilt()
end

return MissingCashNotifier

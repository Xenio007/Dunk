--[[
	PowerPopupController
	Quand le joueur gagne de la Power :
	1. Une image (icône power) apparaît à un endroit aléatoire de l'écran
	2. Elle vole vers le YeetLevel (en bas à gauche)
	3. Quand elle arrive, elle disparaît, le YeetLevel fait un "bump"

	Migration 1:1 de StarterPlayerScripts.PowerPopup.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local PowerPopupController = Loader.CreateController({
	Name = "PowerPopupController",
})

local ICON_IMAGE = "rbxassetid://135296567981241"
local FLY_DURATION = 0.45
local BUMP_GROW_DURATION = 0.1
local BUMP_SHRINK_DURATION = 0.12

local function formatNumber(n)
	if n >= 1e15 then
		return string.format("%.1fQ", n / 1e15)
	elseif n >= 1e12 then
		return string.format("%.1fT", n / 1e12)
	elseif n >= 1e9 then
		return string.format("%.1fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("%.1fK", n / 1e3)
	else
		return tostring(math.floor(n))
	end
end

function PowerPopupController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local addPowerEvent = RemotesAPI.GetEvent("AddPowerEvent")
	local PowerDisplay = require(ReplicatedStorage:WaitForChild("PowerDisplay"))

	local powerSound = Instance.new("Sound")
	powerSound.Name = "PowerPopSound"
	powerSound.SoundId = "rbxassetid://203620899"
	powerSound.Volume = 0.5
	powerSound.Parent = SoundService

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PowerPopupGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = playerGui

	local mainGui = playerGui:WaitForChild("MainGui")
	local bottomLeft = mainGui:WaitForChild("BottomLeft")
	local yeetLevel = bottomLeft:WaitForChild("YeetLevel")

	local yeetOriginalSize = yeetLevel.Size
	local isBumping = false

	local function bumpYeetLevel()
		if isBumping then return end
		isBumping = true

		local growSize = UDim2.new(
			yeetOriginalSize.X.Scale * 1.25, yeetOriginalSize.X.Offset,
			yeetOriginalSize.Y.Scale * 1.25, yeetOriginalSize.Y.Offset
		)

		local tweenGrow = TweenService:Create(yeetLevel, TweenInfo.new(BUMP_GROW_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = growSize,
		})

		local tweenShrink = TweenService:Create(yeetLevel, TweenInfo.new(BUMP_SHRINK_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			Size = yeetOriginalSize,
		})

		tweenGrow:Play()
		tweenGrow.Completed:Once(function()
			tweenShrink:Play()
			tweenShrink.Completed:Once(function()
				isBumping = false
			end)
		end)
	end

	local function getYeetLevelCenter()
		local absPos = yeetLevel.AbsolutePosition
		local absSize = yeetLevel.AbsoluteSize
		return Vector2.new(absPos.X + absSize.X / 2, absPos.Y + absSize.Y / 2)
	end

	local function showPowerIcon(amount)
		local startX = math.random(15, 85) / 100
		local startY = math.random(10, 60) / 100

		-- Tailles en Scale (fraction de l'écran) pour rester cohérentes sur
		-- toutes les résolutions (mobile / télé / écran ultra-wide).
		local START_SIZE  = UDim2.fromScale(0.18, 0.075)
		local TARGET_SIZE = UDim2.fromScale(0.075, 0.03)

		local container = Instance.new("Frame")
		container.Name = "PowerIconContainer"
		container.Size = START_SIZE
		container.Position = UDim2.new(startX, 0, startY, 0)
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.BackgroundTransparency = 1
		container.ZIndex = 100
		container.Parent = screenGui

		-- Icône : carrée à gauche, hauteur = celle du container.
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Image = ICON_IMAGE
		icon.Size = UDim2.fromScale(1, 1)
		icon.SizeConstraint = Enum.SizeConstraint.RelativeYY -- carré : largeur = hauteur
		icon.Position = UDim2.fromScale(0, 0.5)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.BackgroundTransparency = 1
		icon.ZIndex = 101
		icon.Parent = container

		-- Label : prend toute la place restante à droite de l'icône. L'icône
		-- est carrée donc occupe `heightScale` en X relatif à l'écran. Pour rester
		-- simple on part à 25% depuis la gauche (l'icône fait environ 40% en
		-- largeur du container selon le ratio, légère marge visuelle).
		local label = Instance.new("TextLabel")
		label.Name = "PowerText"
		label.Size = UDim2.fromScale(0.75, 1)
		label.Position = UDim2.fromScale(0.25, 0.5)
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.BackgroundTransparency = 1
		label.Text = "+" .. formatNumber(amount) .. " Power"
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.ExtraBold)
		label.TextScaled = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 101
		label.Parent = container

		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 60, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(242, 255, 0)),
		})
		gradient.Rotation = -90
		gradient.Parent = label

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Thickness = 0.05
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
		stroke.Parent = label

		local screenSize = screenGui.AbsoluteSize
		local targetCenter = getYeetLevelCenter()
		local targetX = targetCenter.X / screenSize.X
		local targetY = targetCenter.Y / screenSize.Y

		local tweenFly = TweenService:Create(container, TweenInfo.new(FLY_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(targetX, 0, targetY, 0),
			Size = TARGET_SIZE,
		})

		tweenFly:Play()
		tweenFly.Completed:Once(function()
			container:Destroy()
			PowerDisplay:AddDisplayedPower(amount)
			powerSound:Play()
			bumpYeetLevel()
		end)
	end

	addPowerEvent.OnClientEvent:Connect(function(amount)
		if typeof(amount) == "number" and amount > 0 then
			showPowerIcon(amount)
		end
	end)
end

return PowerPopupController

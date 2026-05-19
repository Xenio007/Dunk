--[[
	PlotIconController
	Affiche l'icône de la base du joueur quand il est à plus de 29 studs de son plot.
	Chaque joueur ne voit que l'icône de son propre plot.

	Migration 1:1 de StarterPlayerScripts.PlotIconHandler.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local PlotIconController = Loader.CreateController({
	Name = "PlotIconController",
})

local DISTANCE_THRESHOLD = 29
local ANIM_DURATION = 0.35

function PlotIconController:Start()
	local player = Players.LocalPlayer
	local plotsFolder = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")

	-- Cacher toutes les icônes au démarrage
	for i = 1, 5 do
		local plot = plotsFolder:FindFirstChild("Plot" .. i)
		if plot then
			local icon = plot:FindFirstChild("Icon")
			if icon then
				local homeIcon = icon:FindFirstChild("HomeIcon")
				if homeIcon then
					homeIcon.Enabled = false
				end
			end
		end
	end

	local plotNumVal = player:WaitForChild("PlotNumber", 30)
	if not plotNumVal then
		warn("[PlotIconController] Pas de plot assigné, icône désactivée")
		return
	end

	local myPlotNumber = plotNumVal.Value
	local myPlot = plotsFolder:FindFirstChild("Plot" .. myPlotNumber)
	if not myPlot then
		warn("[PlotIconController] Plot" .. myPlotNumber .. " introuvable")
		return
	end

	local iconPart = myPlot:FindFirstChild("Icon")
	if not iconPart then
		warn("[PlotIconController] Icon introuvable dans Plot" .. myPlotNumber)
		return
	end

	local homeIcon = iconPart:FindFirstChild("HomeIcon")
	if not homeIcon then
		warn("[PlotIconController] HomeIcon introuvable")
		return
	end

	local imageLabel = homeIcon:FindFirstChild("ImageLabel")

	local isShowing = false
	local isTweening = false

	if imageLabel then
		imageLabel.Visible = false
		imageLabel.ImageTransparency = 1
		imageLabel.Size = UDim2.new(0.5, 0, 0.5, 0)
		imageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		imageLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
	end

	local tweenInfoIn = TweenInfo.new(ANIM_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local tweenInfoOut = TweenInfo.new(ANIM_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In)

	local function showIcon()
		if isShowing or not imageLabel then return end
		isShowing = true
		isTweening = true

		homeIcon.Enabled = true
		imageLabel.Visible = true
		imageLabel.ImageTransparency = 1
		imageLabel.Size = UDim2.new(0.5, 0, 0.5, 0)

		local tween = TweenService:Create(imageLabel, tweenInfoIn, {
			ImageTransparency = 0,
			Size = UDim2.new(1, 0, 1, 0),
		})
		tween:Play()
		tween.Completed:Once(function()
			isTweening = false
		end)
	end

	local function hideIcon()
		if not isShowing or not imageLabel then return end
		isShowing = false
		isTweening = true

		local tween = TweenService:Create(imageLabel, tweenInfoOut, {
			ImageTransparency = 1,
			Size = UDim2.new(0.5, 0, 0.5, 0),
		})
		tween:Play()
		tween.Completed:Once(function()
			isTweening = false
			if not isShowing then
				imageLabel.Visible = false
				homeIcon.Enabled = false
			end
		end)
	end

	-- Throttle : pas besoin d'évaluer la distance à chaque frame.
	-- 4 évaluations par seconde (250ms) suffisent pour une animation
	-- d'icone qui dure déjà 350ms. Sur 60fps, on économise ~56 calculs
	-- par seconde par joueur connecté.
	local lastEval = 0
	local EVAL_INTERVAL = 0.25

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastEval < EVAL_INTERVAL then return end
		lastEval = now

		local character = player.Character
		if not character then
			if isShowing and not isTweening then hideIcon() end
			return
		end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			if isShowing and not isTweening then hideIcon() end
			return
		end

		-- Distance horizontale uniquement (XZ) pour ignorer la hauteur :
		-- le joueur sur Floor1/Floor2 est vertical par rapport à l'icône,
		-- mais toujours "dans" sa base donc l'icône doit rester cachée.
		local dx = hrp.Position.X - iconPart.Position.X
		local dz = hrp.Position.Z - iconPart.Position.Z
		local distance = math.sqrt(dx * dx + dz * dz)

		if distance > DISTANCE_THRESHOLD then
			if not isShowing and not isTweening then
				showIcon()
			end
		else
			if isShowing and not isTweening then
				hideIcon()
			end
		end
	end)

	print("[PlotIconController] Initialisé pour Plot" .. myPlotNumber)
end

return PlotIconController

--[[
	ChaseVignetteController (Controller module)
	Vignette rouge horror-style PLEIN ÉCRAN, fluide. Un canvas + 4 ImageLabels
	radiaux (texture circle blur de Roblox) tintés en rouge. ColorCorrection
	global pour rougir la scène. Pulse + flickers animés.

	Migration 1:1 de StarterPlayerScripts.ChaseVignetteLocalScript.
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")

local Loader     = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local ChaseVignetteController = Loader.CreateController({
	Name = "ChaseVignetteController",
})

local VIG_COLOR = Color3.fromRGB(110, 18, 18)

function ChaseVignetteController:Start()
	local player    = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local dunkEvent = RemotesAPI.GetEvent("DunkSequenceEvent")

	local gui = Instance.new("ScreenGui")
	gui.Name           = "ChaseVignette"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder   = 1800
	gui.ResetOnSpawn   = false
	gui.Enabled        = false
	-- Sur mobile, les Frames opaques bloquent les inputs (touch). On désactive
	-- l'interaction sur tout le ScreenGui pour que les boutons mobiles (jump,
	-- joystick) restent cliquables à travers la vignette rouge.
	gui.IgnoreGuiInset = true
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.Parent         = playerGui

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	-- Active=false + Interactable=false : la vignette est purement visuelle,
	-- elle ne doit JAMAIS bloquer les inputs (touch sur mobile, clic sur les
	-- boutons GUI au-dessous, etc.).
	root.Active = false
	pcall(function() root.Interactable = false end)
	root.Parent = gui

	-- Bandes verticales (top + bottom) pleine largeur, gradient transparent.
	local function makeVerticalBand(anchorY, side)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = VIG_COLOR
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.fromScale(0, anchorY)
		f.Size = UDim2.fromScale(1, 0.55)
		f.ZIndex = 1
		f.Active = false
		pcall(function() f.Interactable = false end)
		local grad = Instance.new("UIGradient")
		grad.Rotation = 90
		if side == "top" then
			grad.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0.00, 0.00),
				NumberSequenceKeypoint.new(0.20, 0.30),
				NumberSequenceKeypoint.new(0.50, 0.75),
				NumberSequenceKeypoint.new(0.80, 0.95),
				NumberSequenceKeypoint.new(1.00, 1.00),
			})
		else
			grad.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0.00, 1.00),
				NumberSequenceKeypoint.new(0.20, 0.95),
				NumberSequenceKeypoint.new(0.50, 0.75),
				NumberSequenceKeypoint.new(0.80, 0.30),
				NumberSequenceKeypoint.new(1.00, 0.00),
			})
		end
		grad.Parent = f
		f.Parent = root
		return f
	end

	-- Bandes horizontales (left + right) pleine hauteur, gradient horizontal.
	local function makeHorizontalBand(anchorX, side)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = VIG_COLOR
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(anchorX, 0)
		f.Position = UDim2.fromScale(anchorX, 0)
		f.Size = UDim2.fromScale(0.45, 1)
		f.ZIndex = 2
		f.Active = false
		pcall(function() f.Interactable = false end)
		local grad = Instance.new("UIGradient")
		grad.Rotation = 0
		if side == "left" then
			grad.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0.00, 0.00),
				NumberSequenceKeypoint.new(0.20, 0.30),
				NumberSequenceKeypoint.new(0.50, 0.75),
				NumberSequenceKeypoint.new(0.80, 0.95),
				NumberSequenceKeypoint.new(1.00, 1.00),
			})
		else
			grad.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0.00, 1.00),
				NumberSequenceKeypoint.new(0.20, 0.95),
				NumberSequenceKeypoint.new(0.50, 0.75),
				NumberSequenceKeypoint.new(0.80, 0.30),
				NumberSequenceKeypoint.new(1.00, 0.00),
			})
		end
		grad.Parent = f
		f.Parent = root
		return f
	end

	local bandTop    = makeVerticalBand(0, "top")
	local bandBottom = makeVerticalBand(1, "bottom")
	local bandLeft   = makeHorizontalBand(0, "left")
	local bandRight  = makeHorizontalBand(1, "right")
	local bands = { bandTop, bandBottom, bandLeft, bandRight }

	-- Vignette circulaire (texture native Roblox) tintée rouge.
	local vignetteImg = Instance.new("ImageLabel")
	vignetteImg.BackgroundTransparency = 1
	vignetteImg.Size = UDim2.fromScale(1, 1)
	vignetteImg.AnchorPoint = Vector2.new(0.5, 0.5)
	vignetteImg.Position = UDim2.fromScale(0.5, 0.5)
	vignetteImg.Active = false
	pcall(function() vignetteImg.Interactable = false end)
	vignetteImg.Image = "rbxasset://textures/ui/Vignette.png"
	vignetteImg.ImageColor3 = VIG_COLOR
	vignetteImg.ImageTransparency = 0.55
	vignetteImg.ScaleType = Enum.ScaleType.Stretch
	vignetteImg.ZIndex = 3
	vignetteImg.Parent = root

	if not vignetteImg.IsLoaded then
		task.delay(1, function()
			if not vignetteImg.IsLoaded then
				vignetteImg.Image = "rbxassetid://18540847531"
			end
		end)
	end

	-- ColorCorrection global pour rougir la scène 3D.
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "ChaseVignetteCC"
	cc.Brightness = 0
	cc.Contrast   = 0
	cc.Saturation = 0
	cc.TintColor  = Color3.new(1, 1, 1)
	cc.Enabled    = false
	cc.Parent     = Lighting

	local active            = false
	local intensity         = 0
	local targetIntensity   = 0
	local lastFlicker       = 0
	local renderConn

	local function setVisibility(v)
		-- v est le "facteur d'intensité" (0..1). On l'écrase un peu pour
		-- rendre le contour moins agressif sans casser l'effet horror.
		local vDimmed = v * 0.7
		local baseTrans = 1 - vDimmed
		for _, f in ipairs(bands) do
			f.BackgroundTransparency = baseTrans
		end
		vignetteImg.ImageTransparency = math.min(1, 0.55 + (1 - vDimmed) * 0.45)
	end

	local function startAnimation()
		if renderConn then
			targetIntensity = 1
			active = true
			return
		end
		gui.Enabled  = true
		cc.Enabled   = true
		active       = true
		targetIntensity = 1
		local startClock = os.clock()
		renderConn = RunService.RenderStepped:Connect(function(dt)
			local diff = targetIntensity - intensity
			local step = math.min(math.abs(diff), dt * 2.5)
			if diff > 0 then
				intensity = intensity + step
			elseif diff < 0 then
				intensity = intensity - step
			end

			if (not active) and intensity <= 0.001 then
				intensity = 0
				setVisibility(0)
				cc.TintColor  = Color3.new(1, 1, 1)
				cc.Saturation = 0
				cc.Contrast   = 0
				gui.Enabled   = false
				cc.Enabled    = false
				if renderConn then renderConn:Disconnect(); renderConn = nil end
				return
			end

			local t = os.clock() - startClock
			local breathe = 0.5 + 0.5 * math.sin(t * math.pi * 1.2)
			local baseVisibility = 0.55 + 0.30 * breathe

			if os.clock() - lastFlicker > (0.9 + math.random() * 1.2) then
				lastFlicker = os.clock()
			end
			local timeSinceFlicker = os.clock() - lastFlicker
			local flicker = 0
			if timeSinceFlicker < 0.10 then
				flicker = 0.20 * (1 - timeSinceFlicker / 0.10) * math.random()
			end

			local v = math.clamp((baseVisibility + flicker) * intensity, 0, 1)
			setVisibility(v)

			cc.TintColor  = Color3.new(1, 1 - 0.10 * v, 1 - 0.13 * v)
			cc.Saturation = -0.08 * v
			cc.Contrast   = 0.04 * v
		end)
	end

	local function stopAnimation()
		active = false
		targetIntensity = 0
	end

	dunkEvent.OnClientEvent:Connect(function(phase, _data)
		if phase == "WaveChase" then
			startAnimation()
		elseif phase == "BrainrotLost"
			or phase == "BrainrotSold"
			or phase == "End"
		then
			stopAnimation()
		end
	end)

	print("[ChaseVignetteController] Prêt")
end

return ChaseVignetteController

--[[
	SlotUpgradeSignController
	Chaque joueur ne voit que le SlotUpgradeSign de son propre plot.
	Gère l'animation hover sur le bouton Achats et l'achat de slots.

	Migration 1:1 de StarterPlayerScripts.SlotUpgradeSignHandler.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local SlotUpgradeSignController = Loader.CreateController({
	Name = "SlotUpgradeSignController",
})

function SlotUpgradeSignController:Start()
	local player = Players.LocalPlayer
	local plotsFolder = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")
	local buySlotEvent = RemotesAPI.GetEvent("BuySlotEvent")

	local plotNumVal = player:WaitForChild("PlotNumber", 30)
	if not plotNumVal then
		warn("[SlotUpgradeSignController] Pas de plot assigné")
		return
	end

	local myPlotNumber = plotNumVal.Value
	local myPlot = plotsFolder:FindFirstChild("Plot" .. myPlotNumber)
	if not myPlot then
		warn("[SlotUpgradeSignController] Plot" .. myPlotNumber .. " introuvable")
		return
	end

	local sign = myPlot:FindFirstChild("SlotUpgradeSign")
	if not sign then
		warn("[SlotUpgradeSignController] SlotUpgradeSign introuvable dans Plot" .. myPlotNumber)
		return
	end

	-- Rendre visible uniquement le SlotUpgradeSign de mon plot
	for _, child in ipairs(sign:GetChildren()) do
		if child:IsA("BasePart") then
			child.Transparency = 0
		end
	end

	for _, desc in ipairs(sign:GetDescendants()) do
		if desc:IsA("BillboardGui") or desc:IsA("SurfaceGui") then
			desc.Enabled = true
		end
		if desc:IsA("GuiObject") then
			desc.Visible = true
		end
		if desc:IsA("Decal") or desc:IsA("Texture") then
			desc.Transparency = 0
		end
	end

	local hoverSound = Instance.new("Sound")
	hoverSound.SoundId = "rbxassetid://17208339919"
	hoverSound.Volume = 0.5
	hoverSound.Parent = SoundService

	local buySound = Instance.new("Sound")
	buySound.SoundId = "rbxassetid://17208380755"
	buySound.Volume = 0.5
	buySound.Parent = SoundService

	local bbPart = sign:FindFirstChild("BillboardPart")
	if bbPart then
		local gui = bbPart:FindFirstChild("SurfaceGui")
		if gui then
			local achatsBtn = gui:FindFirstChild("Achats")
			if achatsBtn then
				local originalSize = achatsBtn.Size
				local hoverSize = UDim2.new(
					originalSize.X.Scale * 1.1, originalSize.X.Offset,
					originalSize.Y.Scale * 1.1, originalSize.Y.Offset
				)

				local tweenIn = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				local tweenOut = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

				achatsBtn.MouseEnter:Connect(function()
					TweenService:Create(achatsBtn, tweenIn, {Size = hoverSize}):Play()
					hoverSound:Play()
				end)

				achatsBtn.MouseLeave:Connect(function()
					TweenService:Create(achatsBtn, tweenOut, {Size = originalSize}):Play()
				end)

				achatsBtn.MouseButton1Click:Connect(function()
					buySlotEvent:FireServer()
				end)
			end
		end
	end

	buySlotEvent.OnClientEvent:Connect(function(success, message)
		if success then
			buySound:Play()
			print("[SlotUpgrade] " .. message)
		else
			warn("[SlotUpgrade] " .. message)
		end
	end)

	print("[SlotUpgradeSignController] Initialisé pour Plot" .. myPlotNumber)
end

return SlotUpgradeSignController

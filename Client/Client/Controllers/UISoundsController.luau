--[[
	UISoundsController
	Joue automatiquement les sons Hover et Click sur TOUS les boutons de l'UI.
	Utilise les sons existants dans SoundService.UI.

	Migration 1:1 de StarterPlayerScripts.UISounds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local UISoundsController = Loader.CreateController({
	Name = "UISoundsController",
})

local connectedButtons = {}
local hoverSound
local clickSound

local function connectButton(btn)
	if connectedButtons[btn] then return end
	connectedButtons[btn] = true

	btn.MouseEnter:Connect(function()
		hoverSound:Play()
	end)

	btn.MouseButton1Click:Connect(function()
		clickSound:Play()
	end)
end

local function scanForButtons(parent)
	for _, child in ipairs(parent:GetDescendants()) do
		if child:IsA("TextButton") or child:IsA("ImageButton") then
			connectButton(child)
		end
	end

	parent.DescendantAdded:Connect(function(child)
		if child:IsA("TextButton") or child:IsA("ImageButton") then
			connectButton(child)
		end
	end)
end

function UISoundsController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local uiFolder = SoundService:WaitForChild("UI")
	hoverSound = uiFolder:WaitForChild("Hover")
	clickSound = uiFolder:WaitForChild("UI Click")

	scanForButtons(playerGui)

	print("[UISoundsController] Sons UI initialisés sur tous les boutons!")
end

return UISoundsController

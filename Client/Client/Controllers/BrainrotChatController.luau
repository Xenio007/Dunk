--[[
	BrainrotChatController
	Écoute les messages du joueur dans le chat (TextChatService).
	Quand le joueur envoie le nom d'un brainrot, demande au serveur de le placer
	dans son inventaire.

	Migration 1:1 de StarterPlayerScripts.BrainrotChatListener.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local BrainrotChatController = Loader.CreateController({
	Name = "BrainrotChatController",
})

local knownNames = {}
local brainrotsFolder
local spawnEvent

local function rebuildKnownNames()
	table.clear(knownNames)
	for _, rarityFolder in ipairs(brainrotsFolder:GetChildren()) do
		if rarityFolder:IsA("Folder") then
			for _, model in ipairs(rarityFolder:GetChildren()) do
				if model:IsA("Model") then
					knownNames[model.Name:lower()] = model.Name
				end
			end
		end
	end
end

local function trim(s)
	if not s then return "" end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

local function resolveBrainrotName(msg)
	local clean = trim(msg):lower()
	if clean == "" then return nil end

	if knownNames[clean] then return knownNames[clean] end

	for lowerName, realName in pairs(knownNames) do
		if clean == lowerName then return realName end
	end

	return trim(msg)
end

function BrainrotChatController:Start()
	brainrotsFolder = ReplicatedStorage:WaitForChild("Brainrots")
	spawnEvent = RemotesAPI.GetEvent("SpawnBrainrotEvent")

	rebuildKnownNames()

	TextChatService.SendingMessage:Connect(function(message)
		local text = message and message.Text or ""
		local brainrotName = resolveBrainrotName(text)
		if brainrotName then
			spawnEvent:FireServer(brainrotName)
		end
	end)

	brainrotsFolder.DescendantAdded:Connect(function()
		rebuildKnownNames()
	end)
end

return BrainrotChatController

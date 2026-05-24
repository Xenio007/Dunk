--[[
	BrainrotChatController
	Écoute les messages du joueur dans le chat (TextChatService).

	  - "<nom>"           -> demande au serveur d'ajouter le brainrot dans son inventaire
	  - "control <nom>"   -> demande au serveur de spawner ce brainrot et d'en prendre le contrôle
	  - "/c <nom>"        -> idem (alias court)

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
local controlEvent

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

-- Si le message commence par "control " / "/c " / "/control " (insensible à la
-- casse), retourne le reste du message (le nom du brainrot à contrôler).
-- Sinon retourne nil.
local function parseControlPrefix(text)
	if not text or text == "" then return nil end
	local lower = text:lower()
	for _, prefix in ipairs({ "/control ", "/c ", "control " }) do
		if lower:sub(1, #prefix) == prefix then
			return trim(text:sub(#prefix + 1))
		end
	end
	return nil
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
	controlEvent = RemotesAPI.GetEvent("ChatControlBrainrotEvent")

	rebuildKnownNames()

	TextChatService.SendingMessage:Connect(function(message)
		local text = message and message.Text or ""

		-- Préfixe "control" / "/c" : prendre le contrôle d'un brainrot.
		local controlName = parseControlPrefix(text)
		if controlName and controlName ~= "" then
			local brainrotName = resolveBrainrotName(controlName)
			if brainrotName then
				controlEvent:FireServer(brainrotName)
			end
			return
		end

		-- Sinon : nom direct -> ajout à l'inventaire (comportement historique).
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

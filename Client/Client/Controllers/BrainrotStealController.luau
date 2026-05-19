--[[
	BrainrotStealController
	Filtre la visibilité des ProximityPrompt attachés aux brainrots placés :
	  * Le prompt "Take back" (E) n'est visible QUE pour l'owner du plot.
	  * Le prompt "Steal" (F) n'est visible QUE pour les autres joueurs.

	Déclencher le prompt Steal lance directement le popup d'achat Robux
	côté serveur -- aucune UI intermédiaire.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local BrainrotStealController = Loader.CreateController({
	Name = "BrainrotStealController",
})

local REMOVE_PROMPT_NAME = "RemoveBrainrotPrompt"
local STEAL_PROMPT_NAME  = "StealBrainrotPrompt"
local OWNER_ATTR = "OwnerUserId"
local PROMPT_ATTACHMENT_NAME = "BrainrotPromptAttachment"

local localPlayer = Players.LocalPlayer

-- Récupère le conteneur des prompts (Attachment dédiée) pour une primary part.
-- Fallback sur la primary part elle-même (ancien format) si l'attachment
-- n'existe pas encore.
local function getPromptHost(primary)
	local att = primary:FindFirstChild(PROMPT_ATTACHMENT_NAME)
	if att then return att end
	return primary
end

-- Active/désactive les prompts Remove/Steal attachés à une primary part
-- selon que le joueur local est ou non le propriétaire du plot.
local function refreshPromptsOnPart(primary)
	if not primary or not primary:IsA("BasePart") then return end
	local ownerId = primary:GetAttribute(OWNER_ATTR)
	if not ownerId then return end
	local isOwner = (ownerId == localPlayer.UserId)

	local host = getPromptHost(primary)

	local removePrompt = host:FindFirstChild(REMOVE_PROMPT_NAME)
	if removePrompt and removePrompt:IsA("ProximityPrompt") then
		removePrompt.Enabled = isOwner
	end

	local stealPrompt = host:FindFirstChild(STEAL_PROMPT_NAME)
	if stealPrompt and stealPrompt:IsA("ProximityPrompt") then
		stealPrompt.Enabled = not isOwner
	end
end

local function hookPart(primary)
	refreshPromptsOnPart(primary)
	-- Les prompts peuvent apparaître soit directement sur la primary part
	-- (ancien format), soit dans une Attachment enfant (nouveau format).
	local function onDescendant(desc)
		if desc.Name == REMOVE_PROMPT_NAME or desc.Name == STEAL_PROMPT_NAME then
			refreshPromptsOnPart(primary)
		end
	end
	primary.DescendantAdded:Connect(onDescendant)
	primary:GetAttributeChangedSignal(OWNER_ATTR):Connect(function()
		refreshPromptsOnPart(primary)
	end)
end

local function watchPlot(plot)
	for _, desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("BasePart") and desc:GetAttribute(OWNER_ATTR) then
			hookPart(desc)
		end
	end
	plot.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") then
			if desc:GetAttribute(OWNER_ATTR) then
				hookPart(desc)
			else
				desc:GetAttributeChangedSignal(OWNER_ATTR):Once(function()
					hookPart(desc)
				end)
			end
		end
	end)
end

function BrainrotStealController:Start()
	local plots = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")
	for _, plot in ipairs(plots:GetChildren()) do
		task.spawn(watchPlot, plot)
	end
	plots.ChildAdded:Connect(function(plot)
		task.spawn(watchPlot, plot)
	end)
end

return BrainrotStealController

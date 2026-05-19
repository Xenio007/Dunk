--[[
	GroupRewardService
	Gère le bouton Claim de la LikeFrame :
	  - Le client demande la récompense via ClaimGroupRewardEvent.
	  - Le serveur vérifie player:IsInGroup(GROUP_ID).
	    * Si pas dans le groupe : renvoie { ok=false, reason="not_in_group" } au
	      client (qui affichera le popup Roblox pour rejoindre).
	    * Si déjà claimé : renvoie { ok=false, reason="already_claimed" }.
	    * Sinon : donne Gangster Footera, persiste le claim, renvoie ok=true.

	⚠️ REMPLACE GROUP_ID par l'ID de ton groupe Roblox.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local GroupRewardService = Loader.CreateService({
	Name = "GroupRewardService",
})

-- ⚠️ À REMPLACER par l'ID de ton groupe Roblox.
local GROUP_ID = 0

local REWARD_BRAINROT_NAME = "Gangster Footera"

local claimEvent    -- client -> server : demande la récompense
local stateEvent    -- server -> client : {ok=bool, reason?=string, claimed=bool}

local BrainrotService
local DataService

local function sendState(player, payload)
	if not stateEvent then return end
	stateEvent:FireClient(player, payload)
end

local function isPlayerInGroup(player)
	if GROUP_ID <= 0 then
		-- Config non faite : on considère que le joueur est toujours dans le groupe
		-- pour ne pas bloquer le développement. Mets GROUP_ID en production.
		warn("[GroupRewardService] GROUP_ID n'est pas configuré.")
		return true
	end
	local ok, result = pcall(function()
		return player:IsInGroup(GROUP_ID)
	end)
	return ok and result == true
end

local function onClaimRequest(player)
	if not player or not player.Parent then return end

	if DataService:HasClaimedGroupReward(player) then
		sendState(player, { ok = false, reason = "already_claimed", claimed = true })
		return
	end

	if not isPlayerInGroup(player) then
		sendState(player, { ok = false, reason = "not_in_group", claimed = false })
		return
	end

	local tool = BrainrotService:GiveBrainrotByName(player, REWARD_BRAINROT_NAME)
	if not tool then
		sendState(player, { ok = false, reason = "give_failed", claimed = false })
		return
	end

	-- Équipe automatiquement si le character est présent.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function()
			humanoid:EquipTool(tool)
		end)
	end

	DataService:SetClaimedGroupReward(player)
	sendState(player, { ok = true, reason = nil, claimed = true })
	print(string.format("[GroupRewardService] %s a réclamé %s (group reward)",
		player.Name, REWARD_BRAINROT_NAME))
end

function GroupRewardService:Init()
	claimEvent = RemotesAPI.GetEvent("ClaimGroupRewardEvent")
	stateEvent = RemotesAPI.GetEvent("GroupRewardStateEvent")
end

function GroupRewardService:Start()
	BrainrotService = Loader.GetService("BrainrotService")
	DataService = Loader.GetService("DataService")

	claimEvent.OnServerEvent:Connect(onClaimRequest)

	-- Envoie l'état initial (claimed ou non) au join.
	local function hookPlayer(player)
		player:WaitForChild("Cash", 30)
		sendState(player, {
			ok = true,
			reason = "initial",
			claimed = DataService:HasClaimedGroupReward(player),
		})
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(hookPlayer, player)
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(hookPlayer, p)
	end

	print("[GroupRewardService] Prêt")
end

return GroupRewardService

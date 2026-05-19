--[[
	FreeBrainrotService
	Gère le bouton "Buy" du Free item dans ShopFrame :
	  - Quand un joueur clique Buy, il reçoit Burbaloni Luliloli (une seule fois
	    par joueur, persisté via DataService.fc).
	  - Un état claimed est renvoyé au client pour mettre à jour l'UI
	    (bouton -> "Owned", badge Free de UILeft.Shop -> invisible).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local FreeBrainrotService = Loader.CreateService({
	Name = "FreeBrainrotService",
})

local FREE_BRAINROT_NAME = "Burbaloni Luliloli"

local claimEvent     -- client -> server : demande d'achat du Free
local stateEvent     -- server -> client : état claimed initial / mise à jour

local BrainrotService
local DataService

local function sendState(player)
	if not stateEvent then return end
	local claimed = DataService:HasClaimedFree(player)
	stateEvent:FireClient(player, claimed)
end

local function onClaimRequest(player)
	if not player or not player.Parent then return end
	if DataService:HasClaimedFree(player) then
		sendState(player)
		return
	end

	local tool = BrainrotService:GiveBrainrotByName(player, FREE_BRAINROT_NAME)
	if not tool then
		-- Échec (backpack absent, etc.) : on ne marque pas claim pour laisser
		-- le joueur réessayer.
		return
	end

	-- Équipe automatiquement le brainrot dans la main du joueur.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function()
			humanoid:EquipTool(tool)
		end)
	end

	DataService:SetClaimedFree(player)
	sendState(player)
end

function FreeBrainrotService:Init()
	claimEvent = RemotesAPI.GetEvent("ClaimFreeBrainrotEvent")
	stateEvent = RemotesAPI.GetEvent("FreeBrainrotStateEvent")
end

function FreeBrainrotService:Start()
	BrainrotService = Loader.GetService("BrainrotService")
	DataService = Loader.GetService("DataService")

	claimEvent.OnServerEvent:Connect(onClaimRequest)

	local function hookPlayer(player)
		-- On attend que le profil soit chargé (Cash créé par DataService).
		player:WaitForChild("Cash", 30)
		sendState(player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(hookPlayer, player)
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(hookPlayer, p)
	end

	print("[FreeBrainrotService] Prêt")
end

return FreeBrainrotService

--[[
	GamepassService
	Gère l'attribution et la vérification des 5 gamepasses / developer products :
	StarterPack, CashX2, PowerX2, Speed12X, BrainrotLuck.

	Les autres services (BrainrotPlacementService pour CashX2, WeightService pour
	PowerX2, DunkLuckyBlockService pour Speed12X + BrainrotLuck) consultent ce
	service via HasGamepass(player, flagName) pour appliquer leur multiplicateur.

	Expose aussi un RemoteEvent GamepassStateEvent (server->client) pour que
	le client puisse afficher les icônes BottomRight. La liste complète des
	flags actifs est envoyée au client au spawn et à chaque achat.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local GamepassService = Loader.CreateService({
	Name = "GamepassService",
})

local DataService
local BrainrotService
local SpeedConfig
local BrainrotPlacementService
local gamepassStateEvent

-- ===== API publique =====

function GamepassService:HasGamepass(player, flagName)
	if not player or not DataService then return false end
	return DataService:HasGamepass(player, flagName)
end

function GamepassService:GetCashMulti(player)
	return self:HasGamepass(player, "CashX2") and GamepassConfig.CASH_X2_MULT or 1
end

function GamepassService:GetPowerMulti(player)
	return self:HasGamepass(player, "PowerX2") and GamepassConfig.POWER_X2_MULT or 1
end

function GamepassService:GetSpeedMulti(player)
	return self:HasGamepass(player, "Speed12X") and GamepassConfig.SPEED_1_2X_MULT or 1
end

function GamepassService:GetBrainrotLuckMulti(player)
	return self:HasGamepass(player, "BrainrotLuck") and GamepassConfig.BRAINROT_LUCK_MULT or 1
end

-- VIP : multiplicateur de Cash appliqué PAR-DESSUS CashMulti + CashX2 sur les
-- boutons de brainrot placés. Valeur 1.5 par défaut.
function GamepassService:GetVipCashMulti(player)
	return self:HasGamepass(player, "VIP") and GamepassConfig.VIP_CASH_MULT or 1
end

-- VIP : multiplicateur de Luck (pour le weighted pick des brainrots normaux).
-- Se combine avec BrainrotLuck en MULTIPLIANT les deux multiplicateurs.
function GamepassService:GetVipLuckMulti(player)
	return self:HasGamepass(player, "VIP") and GamepassConfig.VIP_LUCK_MULT or 1
end

-- MutationLuck : multiplicateur appliqué aux chances de chaque mutation roll.
-- Avec le gamepass, toutes les mutations sont 2x plus probables.
function GamepassService:GetMutationLuckMulti(player)
	return self:HasGamepass(player, "MutationLuck") and GamepassConfig.MUTATION_LUCK_MULT or 1
end

-- Synchronise les flags avec le client pour qu'il affiche les icônes.
function GamepassService:PushStateToClient(player)
	if not gamepassStateEvent then return end
	if not DataService then return end
	local flags = DataService:GetAllGamepasses(player)
	gamepassStateEvent:FireClient(player, flags)

	-- Expose les flags critiques qui doivent être visibles des AUTRES clients
	-- (chat tags, icônes par-dessus la tête, etc). Les attributes Player sont
	-- répliqués automatiquement à tous les clients par Roblox.
	player:SetAttribute("HasVIP", flags.VIP == true)
end

-- Applique les effets du StarterPack (one-shot : brainrots + speed levels).
local function applyStarterPack(player)
	-- Brainrots (Six Seven + Tung Sahur dans l'inventaire).
	if BrainrotService and BrainrotService.GiveBrainrotByName then
		for _, name in ipairs(GamepassConfig.STARTER_BRAINROTS) do
			BrainrotService:GiveBrainrotByName(player, name)
		end
	end

	-- +N niveaux de Speed (clampe au MAX du SpeedConfig).
	local speedLevelVal = player:FindFirstChild("SpeedLevel")
	if speedLevelVal and SpeedConfig then
		local newLevel = math.min(
			SpeedConfig.MAX_LEVEL,
			(speedLevelVal.Value or 0) + GamepassConfig.STARTER_SPEED_LEVELS
		)
		speedLevelVal.Value = newLevel
	end
end

-- Refresh le CPS de tous les brainrots placés d'un joueur (pour que CashX2
-- s'applique immédiatement après achat, sans attendre un placement).
local function refreshPlayerBrainrotCps(player)
	if not BrainrotPlacementService then return end
	if BrainrotPlacementService.RefreshCpsForPlayer then
		pcall(function() BrainrotPlacementService:RefreshCpsForPlayer(player) end)
	end
end

-- ===== HANDLER PRODUCT RECEIPT =====
-- Appelé par GameService.processReceipt pour les productIds appartenant
-- à GamepassConfig.PRODUCT_ID_SET.
function GamepassService:HandlePurchase(player, productId)
	if not GamepassConfig.PRODUCT_ID_SET[productId] then return false end
	if not DataService then return true end

	local flagName = GamepassConfig.FLAG_FOR_PRODUCT[productId]
	if not flagName then return true end

	-- StarterPack : one-shot. S'il a déjà été acheté, on refuse silencieusement
	-- (Roblox empeche déjà le rachat d'un DP one-shot, mais on double-check).
	if flagName == "StarterPack" then
		if DataService:HasGamepass(player, flagName) then
			return true
		end
		DataService:SetGamepass(player, flagName, true)
		applyStarterPack(player)
		self:PushStateToClient(player)
		return true
	end

	-- Gamepass récurrent : on active le flag et on rafraîchit le client.
	DataService:SetGamepass(player, flagName, true)
	self:PushStateToClient(player)

	-- CashX2 : refresh immédiat des boutons de brainrot placés.
	if flagName == "CashX2" then
		refreshPlayerBrainrotCps(player)
	end

	return true
end

-- ===== LIFECYCLE =====

function GamepassService:Init()
	gamepassStateEvent = RemotesAPI.GetEvent("GamepassStateEvent")
end

function GamepassService:Start()
	DataService = Loader.GetService("DataService")
	BrainrotService = Loader.GetService("BrainrotService")
	BrainrotPlacementService = Loader.GetService("BrainrotPlacementService")
	pcall(function()
		SpeedConfig = require(ReplicatedStorage:WaitForChild("SpeedConfig"))
	end)

	Players.PlayerAdded:Connect(function(player)
		player:WaitForChild("Cash", 30) -- attends le profil
		task.wait(0.5)
		self:PushStateToClient(player)
	end)

	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			p:WaitForChild("Cash", 30)
			task.wait(0.5)
			self:PushStateToClient(p)
		end)
	end

	print("[GamepassService] Prêt")
end

return GamepassService

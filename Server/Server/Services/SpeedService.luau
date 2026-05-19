--[[
	SpeedService
	Écoute BuySpeedEvent (client) pour acheter des améliorations de vitesse
	du brainrot contrôlé pendant la séquence Dunk.

	La valeur persistante est `SpeedLevel` (IntValue sur le player). La vitesse
	effective est calculée via SpeedConfig.GetSpeedForLevel(level).

	Client -> Server (BuySpeedEvent) avec `count` :
		1 (Run1) : achète 1 amélioration (la plus proche disponible)
		N (Run2) : achète N (intermédiaire, géré par le client qui demande)
		MAX (Run3) : achète autant que possible avec le cash actuel
	Server -> Client (BuySpeedEvent) : (success, message, newLevel)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local SpeedConfig = require(ReplicatedStorage:WaitForChild("SpeedConfig"))

local SpeedService = Loader.CreateService({
	Name = "SpeedService",
})

local buySpeedEvent

-- Constantes pour le deuxième bouton (Run2) : achat par paquets de 10.
local MID_PACK_SIZE = 10

local function resolveCount(fromLevel, cash, requestedCount)
	if requestedCount == "MAX" then
		local n = SpeedConfig.GetMaxAffordable(fromLevel, cash)
		return n
	end
	local n = tonumber(requestedCount)
	if not n then return 1 end
	n = math.max(1, math.floor(n))
	return math.min(n, SpeedConfig.MAX_LEVEL - fromLevel)
end

local function onBuySpeed(player, requestedCount)
	local cashVal = player:FindFirstChild("Cash")
	local speedLevelVal = player:FindFirstChild("SpeedLevel")

	if not cashVal or not speedLevelVal then
		buySpeedEvent:FireClient(player, false, "Données non trouvées", 0)
		return
	end

	local currentLevel = speedLevelVal.Value
	if currentLevel >= SpeedConfig.MAX_LEVEL then
		buySpeedEvent:FireClient(player, false, "Vitesse maximum atteinte!", currentLevel)
		return
	end

	-- Traduit la requête (number, ou "MAX") en nombre effectif d'améliorations.
	-- Le nombre est automatiquement clampé par ce que le joueur peut se payer,
	-- ce qui évite les refus d'achat en cas de léger désynchro client/serveur.
	local maxAffordable = SpeedConfig.GetMaxAffordable(currentLevel, cashVal.Value)
	local count
	if requestedCount == "MAX" then
		count = maxAffordable
	elseif requestedCount == "MID" then
		count = math.min(MID_PACK_SIZE, maxAffordable)
	else
		local n = tonumber(requestedCount) or 1
		n = math.max(1, math.floor(n))
		n = math.min(n, SpeedConfig.MAX_LEVEL - currentLevel)
		count = math.min(n, maxAffordable)
	end

	if count <= 0 then
		buySpeedEvent:FireClient(player, false, "Pas assez de Cash!", currentLevel)
		return
	end

	local totalCost, purchasable = SpeedConfig.GetTotalCost(currentLevel, count)
	if purchasable <= 0 then
		buySpeedEvent:FireClient(player, false, "Vitesse maximum atteinte!", currentLevel)
		return
	end

	if cashVal.Value < totalCost then
		buySpeedEvent:FireClient(player, false, "Pas assez de Cash!", currentLevel)
		return
	end

	cashVal.Value = cashVal.Value - totalCost
	speedLevelVal.Value = currentLevel + purchasable

	buySpeedEvent:FireClient(player, true, "+" .. purchasable .. " Speed!", speedLevelVal.Value)
end

-- Accesseur pour les autres services (ex: DunkLuckyBlockService) qui veulent
-- la vitesse effective du brainrot de ce joueur.
function SpeedService:GetBrainrotWalkSpeed(player)
	if not player then return SpeedConfig.BASE_SPEED end
	local speedLevelVal = player:FindFirstChild("SpeedLevel")
	local level = speedLevelVal and speedLevelVal.Value or 0
	return SpeedConfig.GetSpeedForLevel(level)
end

function SpeedService:Init()
	buySpeedEvent = RemotesAPI.GetEvent("BuySpeedEvent")
end

function SpeedService:Start()
	buySpeedEvent.OnServerEvent:Connect(onBuySpeed)
	print("[SpeedService] Prêt")
end

return SpeedService

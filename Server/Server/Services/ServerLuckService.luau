--[[
	ServerLuckService
	Boost temporaire partagé par TOUT le serveur : multiplie la chance de
	tirer un brainrot rare (au dunk) ET la chance de chaque mutation.

	Deux "slots" de boost INDEPENDANTS qui s'empilent multiplicativement :

	  1. SHOP slot   : achat ServerLuck (dev product). Chaque achat double le
	                   multiplier courant ; reset à 15 min ; expiration -> x1.
	  2. EVENT slot  : evénement global (ex: LikeRewardsService cross-server).
	                   Multiplier imposé ; durée imposée ; indépendant du shop.

	Final multiplier = shopMultiplier * eventMultiplier (chacun >=1, donc le
	slot vide vaut x1 et n'affecte rien). Cela répond à la demande explicite
	"player base/shop luck multiplied by the event multiplier".

	Exposé :
	  - GetLuckMulti()           : produit final (>=1)
	  - GetState()               : { Multiplier, ExpiresAt, ServerNow,
	                                  ShopMultiplier, ShopExpiresAt,
	                                  EventMultiplier, EventExpiresAt }
	  - HandlePurchase(player, productId) : route SERVER_LUCK dev product (slot SHOP)
	  - SetEventMultiplierUntil(mult, expiresAt) : pose le slot EVENT (timestamp absolu)
	  - RemoteEvent `ServerLuckStateEvent` (server -> all clients) à chaque changement.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local ServerLuckService = Loader.CreateService({
	Name = "ServerLuckService",
})

-- ===== État : SHOP slot (achat) =====
local shopMultiplier = 1
local shopExpiresAt = 0

-- ===== État : EVENT slot (cross-server) =====
local eventMultiplier = 1
local eventExpiresAt = 0

local luckStateEvent
local expiryTask

local function now()
	return Workspace:GetServerTimeNow()
end

-- Multiplier effectif d'un slot : 1 si timer expiré, sinon la valeur stockée.
local function effectiveShop()
	if shopMultiplier <= 1 then return 1 end
	if now() >= shopExpiresAt then return 1 end
	return shopMultiplier
end

local function effectiveEvent()
	if eventMultiplier <= 1 then return 1 end
	if now() >= eventExpiresAt then return 1 end
	return eventMultiplier
end

local function effectiveTotal()
	return effectiveShop() * effectiveEvent()
end

-- Pour la couche d'affichage (icon countdown, label "x4", etc.) on a besoin
-- d'UN multiplier + UN expiresAt. On choisit le slot avec le timer le plus
-- lointain comme "vue principale" ; le multiplier diffusé reste le produit.
local function pickDisplayExpiresAt()
	local s = effectiveShop() > 1 and shopExpiresAt or 0
	local e = effectiveEvent() > 1 and eventExpiresAt or 0
	return math.max(s, e)
end

local function broadcast(target)
	if not luckStateEvent then return end
	local payload = {
		Multiplier      = effectiveTotal(),
		ExpiresAt       = pickDisplayExpiresAt(),
		ServerNow       = now(),
		ShopMultiplier  = effectiveShop(),
		ShopExpiresAt   = shopExpiresAt,
		EventMultiplier = effectiveEvent(),
		EventExpiresAt  = eventExpiresAt,
	}
	if target then
		luckStateEvent:FireClient(target, payload)
	else
		luckStateEvent:FireAllClients(payload)
	end
end

-- Re-planifie la prochaine expiration : on choisit le timer le plus PROCHE
-- des deux slots non vides pour rallumer broadcast au bon moment, puis on
-- continuera à tourner tant qu'un slot reste actif.
local function nextExpiry()
	local candidates = {}
	if shopMultiplier > 1 and shopExpiresAt > now() then
		table.insert(candidates, shopExpiresAt)
	end
	if eventMultiplier > 1 and eventExpiresAt > now() then
		table.insert(candidates, eventExpiresAt)
	end
	if #candidates == 0 then return 0 end
	table.sort(candidates)
	return candidates[1]
end

local function scheduleExpiry()
	if expiryTask then
		task.cancel(expiryTask)
		expiryTask = nil
	end
	local nx = nextExpiry()
	if nx <= 0 then return end
	local delay = nx - now()
	if delay <= 0 then
		-- Slot déjà expiré : on ne touche pas aux variables (effectiveX gère le
		-- cas), on broadcast pour notifier les clients, puis on ré-essaie pour
		-- l'autre slot s'il reste.
		broadcast()
		scheduleExpiry()
		return
	end
	expiryTask = task.delay(delay, function()
		expiryTask = nil
		broadcast()
		scheduleExpiry()
	end)
end

-- ===== API PUBLIQUE =====

function ServerLuckService:GetLuckMulti()
	return effectiveTotal()
end

function ServerLuckService:GetState()
	return {
		Multiplier      = effectiveTotal(),
		ExpiresAt       = pickDisplayExpiresAt(),
		ServerNow       = now(),
		ShopMultiplier  = effectiveShop(),
		ShopExpiresAt   = shopExpiresAt,
		EventMultiplier = effectiveEvent(),
		EventExpiresAt  = eventExpiresAt,
	}
end

-- Chaque achat DOUBLE simplement le multiplicateur courant du slot SHOP.
-- Pas de cap : si 5 joueurs achètent à la suite, on atteint x32 puis x64 etc.
local function applyPurchase()
	local current = effectiveShop()
	shopMultiplier = math.max(1, current) * 2
	shopExpiresAt = now() + GamepassConfig.SERVER_LUCK_DURATION
	scheduleExpiry()
	broadcast()
end

function ServerLuckService:HandlePurchase(player, productId)
	if productId ~= GamepassConfig.PRODUCTS.SERVER_LUCK then return false end
	applyPurchase()
	return true
end

-- Pose le slot EVENT à partir d'un timestamp absolu (Workspace:GetServerTimeNow).
-- Utilisé par LikeRewardsService quand un MessagingService cross-server arrive
-- avec un ExpiresAt commun à tous les serveurs. On garde la valeur la plus
-- haute si plusieurs événements se chevauchent (math.max sur multiplier ET
-- expiresAt).
function ServerLuckService:SetEventMultiplierUntil(multiplier, expiresAtAbs)
	multiplier = math.max(1, tonumber(multiplier) or 1)
	expiresAtAbs = tonumber(expiresAtAbs) or 0
	if expiresAtAbs <= now() or multiplier <= 1 then
		return false
	end
	-- Pas d'écrasement : on garde le boost le plus fort / le plus long.
	if multiplier > eventMultiplier or now() >= eventExpiresAt then
		eventMultiplier = multiplier
		eventExpiresAt = expiresAtAbs
	else
		eventExpiresAt = math.max(eventExpiresAt, expiresAtAbs)
	end
	scheduleExpiry()
	broadcast()
	return true
end

-- Légacy : conservé pour compatibilité avec un éventuel ancien appelant.
-- Pose dans le slot EVENT à partir d'une durée relative. Préférer
-- SetEventMultiplierUntil avec un timestamp absolu pour la cohérence cross-server.
function ServerLuckService:SetMultiplierUntil(multiplier, durationSeconds)
	multiplier = math.max(1, tonumber(multiplier) or 1)
	durationSeconds = math.max(0, tonumber(durationSeconds) or 0)
	return self:SetEventMultiplierUntil(multiplier, now() + durationSeconds)
end

-- ===== CYCLE DE VIE =====

function ServerLuckService:Init()
	luckStateEvent = RemotesAPI.GetEvent("ServerLuckStateEvent")
end

function ServerLuckService:Start()
	-- Envoie l'état courant aux nouveaux joueurs pour qu'ils affichent le bon
	-- multiplier dès leur spawn.
	Players.PlayerAdded:Connect(function(player)
		task.wait(1)
		if player.Parent then broadcast(player) end
	end)

	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			task.wait(1)
			if p.Parent then broadcast(p) end
		end)
	end

	print("[ServerLuckService] Prêt")
end

return ServerLuckService

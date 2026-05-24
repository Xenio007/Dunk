--[[
	ServerLuckService
	Boost temporaire partagé par TOUT le serveur : multiplie la chance de
	tirer un brainrot rare (au dunk) ET la chance de chaque mutation.

	Règle d'empilement :
	  - Achat 1 (serveur à x1)   -> passe à x2, durée 15 min.
	  - Achat pendant les 15 min -> passe au step suivant (x3, x4, ...), timer
	                                réinitialisé à 15 min complets.
	  - Expiration du timer      -> retour à x1.

	Exposé :
	  - GetLuckMulti()           : retourne le multiplier courant (1 par défaut)
	  - GetState()               : retourne { Multiplier=int, ExpiresAt=timestamp }
	  - HandlePurchase(player, productId) : route SERVER_LUCK dev product
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

-- État global.
local currentMultiplier = 1
local expiresAt = 0 -- timestamp (Workspace:GetServerTimeNow) auquel le boost expire.
local luckStateEvent
local expiryTask

local function now()
	return Workspace:GetServerTimeNow()
end

-- Chaque achat DOUBLE simplement le multiplicateur courant. Pas de cap : si
-- 5 joueurs achètent à la suite, on atteint x32 puis x64 etc.
local function nextMultiplier(current)
	current = math.max(1, tonumber(current) or 1)
	return current * 2
end

-- Diffuse l'état à tous les clients. Utilisé à chaque changement + pour les
-- nouveaux joueurs qui rejoignent.
local function broadcast(target)
	if not luckStateEvent then return end
	local payload = {
		Multiplier = currentMultiplier,
		ExpiresAt  = expiresAt,
		ServerNow  = now(),
	}
	if target then
		luckStateEvent:FireClient(target, payload)
	else
		luckStateEvent:FireAllClients(payload)
	end
end

-- Reset automatique quand le timer expire.
local function scheduleExpiry()
	if expiryTask then
		task.cancel(expiryTask)
		expiryTask = nil
	end
	if expiresAt <= 0 then return end
	local delay = expiresAt - now()
	if delay <= 0 then
		currentMultiplier = 1
		expiresAt = 0
		broadcast()
		return
	end
	expiryTask = task.delay(delay, function()
		expiryTask = nil
		if now() >= expiresAt then
			currentMultiplier = 1
			expiresAt = 0
			broadcast()
		end
	end)
end

-- ===== API PUBLIQUE =====

function ServerLuckService:GetLuckMulti()
	if currentMultiplier <= 1 then return 1 end
	if now() >= expiresAt then
		-- Timer expiré mais pas encore reset (ex : race entre task.delay). On
		-- retourne 1 pour éviter un "faux boost".
		return 1
	end
	return currentMultiplier
end

function ServerLuckService:GetState()
	return {
		Multiplier = currentMultiplier,
		ExpiresAt  = expiresAt,
		ServerNow  = now(),
	}
end

-- Consomme un achat SERVER_LUCK : bump le multiplier et reset le timer à 15 min.
local function applyPurchase()
	currentMultiplier = nextMultiplier(currentMultiplier)
	expiresAt = now() + GamepassConfig.SERVER_LUCK_DURATION
	scheduleExpiry()
	broadcast()
end

-- Appelé par GameService.processReceipt. Retourne true si on a traité l'achat.
function ServerLuckService:HandlePurchase(player, productId)
	if productId ~= GamepassConfig.PRODUCTS.SERVER_LUCK then return false end
	applyPurchase()
	return true
end

-- ===== CYCLE DE VIE =====

function ServerLuckService:Init()
	luckStateEvent = RemotesAPI.GetEvent("ServerLuckStateEvent")
end

function ServerLuckService:Start()
	-- Envoie l'état courant aux nouveaux joueurs pour qu'ils affichent le bon
	-- multiplier dès leur spawn (sinon ils verraient x1 jusqu'au prochain achat).
	Players.PlayerAdded:Connect(function(player)
		task.wait(1) -- laisse le temps au client d'être prêt (le controller doit exister)
		if player.Parent then broadcast(player) end
	end)

	-- Rattrapage Studio.
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			task.wait(1)
			if p.Parent then broadcast(p) end
		end)
	end

	print("[ServerLuckService] Prêt")
end

return ServerLuckService

--[[
	BrainrotDiscoveryService
	Gère l'index de découverte des brainrots : quand un joueur obtient un brainrot
	pour la première fois (quelle que soit la source : chat, dunk, free, steal,
	placement), son fullName est marqué comme "découvert" dans DataService
	(persisté au DataStore) et des attributes `Discovered_<Rarity>` sont posés sur
	le Player pour que l'IndexController côté client colorie les cartes.

	Stratégie :
	  - On observe Backpack + Character du joueur (ChildAdded) pour attraper tous
	    les Tools qui apparaissent, peu importe le service qui les a créés. Ça
	    évite d'avoir à modifier tous les points d'entrée (free, dunk, chat, etc.).
	  - Au spawn du joueur, on re-scanne l'inventaire persisté ET les brainrots
	    déjà placés sur les slots : utile pour les joueurs existants qui ont des
	    brainrots avant l'arrivée de cette feature.
	  - Les attributes sont batchés (one-shot rebuild) plutôt que mis à jour
	    par delta : simplifie la logique et reste largement assez rapide vu
	    qu'il y a au maximum ~200 brainrots par joueur.

	Attributes posés sur le Player (lus par IndexController) :
	  - Discovered_Normal  : "BaseName,BaseName,..."
	  - Discovered_Gold    : idem
	  - Discovered_Diamond, Galaxy, Lava, Rainbow, Hacker : idem
	  - DiscoveredIndex    : laissé vide (compat légacy, IndexController sait gérer)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))

local BrainrotDiscoveryService = Loader.CreateService({
	Name = "BrainrotDiscoveryService",
})

-- Les rarities persistées dans l'index côté client. On fait correspondre chaque
-- Variant de BrainrotInfo à un nom d'attribute Discovered_<Variant>.
local VARIANTS = {
	"Normal", "Gold", "Diamond", "Galaxy", "Lava", "Rainbow", "Hacker",
}

local DataService

-- D5 : tracking des connexions par joueur pour pouvoir les disconnect
-- au PlayerRemoving. Sans ça, chaque CharacterAdded ajoute une nouvelle
-- ChildAdded:Connect sur Backpack/Character qui n'est jamais coupée → fuite
-- mémoire serveur + cascade de callbacks à chaque ajout de Tool (50 connexions
-- actives après 50 respawns d'un même joueur).
local hookConnections = {} -- [userId] = { RBXScriptConnection, ... }

local function disconnectPlayerHooks(userId)
	local conns = hookConnections[userId]
	if not conns then return end
	for _, c in ipairs(conns) do
		if typeof(c) == "RBXScriptConnection" then
			pcall(function() c:Disconnect() end)
		end
	end
	hookConnections[userId] = nil
end

local function trackConnection(player, conn)
	if not conn then return end
	hookConnections[player.UserId] = hookConnections[player.UserId] or {}
	table.insert(hookConnections[player.UserId], conn)
end

-- Retourne un set { variant -> { baseName -> true } } construit à partir des
-- fullNames découverts du joueur.
local function buildDiscoveryBuckets(player)
	local buckets = {}
	for _, v in ipairs(VARIANTS) do buckets[v] = {} end

	if not DataService or not DataService.GetDiscoveredBrainrots then return buckets end

	local discovered = DataService:GetDiscoveredBrainrots(player)
	for fullName in pairs(discovered) do
		local info = BrainrotInfo.GetInfo(fullName)
		if info then
			local v = info.Variant or "Normal"
			if buckets[v] then
				buckets[v][info.BaseName] = true
			end
		end
	end
	return buckets
end

-- Écrit les attributes Discovered_<Variant> depuis les buckets courants. On ne
-- touche un attribute que si sa valeur a changé, pour éviter de notifier
-- inutilement les clients.
local function pushDiscoveredAttributes(player)
	local buckets = buildDiscoveryBuckets(player)
	for _, variant in ipairs(VARIANTS) do
		local names = {}
		for baseName in pairs(buckets[variant]) do
			table.insert(names, baseName)
		end
		table.sort(names)
		local joined = table.concat(names, ",")
		local attrName = "Discovered_" .. variant
		if player:GetAttribute(attrName) ~= joined then
			player:SetAttribute(attrName, joined)
		end
	end
end

-- Marque un brainrot découvert et re-push les attributes si c'est nouveau.
-- Thread-safe : DataService:MarkBrainrotDiscovered renvoie true uniquement à
-- la première découverte, donc on évite les re-push inutiles.
function BrainrotDiscoveryService:MarkDiscovered(player, fullName)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if typeof(fullName) ~= "string" or fullName == "" then return end
	if not DataService then return end
	local isNew = DataService:MarkBrainrotDiscovered(player, fullName)
	if isNew then
		pushDiscoveredAttributes(player)
	end
end

-- Inspecte un container et marque chaque Tool brainrot comme découvert. Utilisé
-- pour le Backpack + Character au spawn du joueur.
local function scanContainer(player, container)
	if not container then return end
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and BrainrotInfo.GetInfo(child.Name) then
			DataService:MarkBrainrotDiscovered(player, child.Name)
		end
	end
end

local function hookContainer(player, container)
	if not container then return end
	scanContainer(player, container)
	local conn = container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and BrainrotInfo.GetInfo(child.Name) then
			BrainrotDiscoveryService:MarkDiscovered(player, child.Name)
		end
	end)
	-- D5 : track la connexion pour la disconnect au PlayerRemoving.
	trackConnection(player, conn)
end

-- Au spawn : récupère tout ce que le joueur a déjà (inventaire persisté +
-- brainrots placés sur les slots du plot) pour marquer en rétroactif. Ça
-- permet aux joueurs existants de voir leur index se remplir au prochain login.
local function importExistingBrainrots(player)
	if not DataService then return end

	-- 1) Inventaire persisté (tools pas forcément encore spawnés).
	local inventory = DataService:GetBrainrotInventory(player)
	for _, entry in ipairs(inventory) do
		DataService:MarkBrainrotDiscovered(player, entry.Name)
	end

	-- 2) Brainrots placés sur les slots (stockés séparément).
	local placed = DataService:GetPlacedBrainrots(player)
	for _, entry in pairs(placed) do
		DataService:MarkBrainrotDiscovered(player, entry.Name)
	end
end

local function onPlayerAdded(player)
	-- D8 : guard d'idempotence. Si onPlayerAdded est appelé deux fois pour le
	-- même joueur (race entre PlayerAdded:Connect et la boucle GetPlayers du
	-- Studio replay), on évite de doubler les hooks.
	if hookConnections[player.UserId] then return end
	hookConnections[player.UserId] = {}

	-- Attend que DataService ait chargé le profil (critère : "Cash" posé par
	-- DataService:onPlayerAdded). Sans ça les API MarkBrainrotDiscovered sont
	-- no-op car le profil est nil.
	if not player:WaitForChild("Cash", 30) then return end

	-- Import initial : tout ce qu'on sait déjà de ce joueur.
	importExistingBrainrots(player)
	pushDiscoveredAttributes(player)

	-- Observe le Backpack et le Character pour attraper tout nouveau brainrot
	-- (chat, free, dunk, steal, etc.) sans avoir à modifier chaque service.
	local function bindCharacter(char)
		hookContainer(player, char)
	end

	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 10)
	if backpack then hookContainer(player, backpack) end

	local childAddedConn = player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			hookContainer(player, child)
		end
	end)
	trackConnection(player, childAddedConn)

	if player.Character then bindCharacter(player.Character) end
	local charAddedConn = player.CharacterAdded:Connect(bindCharacter)
	trackConnection(player, charAddedConn)
end

function BrainrotDiscoveryService:Init()
end

function BrainrotDiscoveryService:Start()
	DataService = Loader.GetService("DataService")

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)

	-- D5 : cleanup des connexions tracées au PlayerRemoving (anti-leak).
	Players.PlayerRemoving:Connect(function(player)
		disconnectPlayerHooks(player.UserId)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	print("[BrainrotDiscoveryService] Prêt")
end

return BrainrotDiscoveryService

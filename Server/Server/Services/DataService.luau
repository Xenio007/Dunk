--[[
	DataService
	Persistence centralisée et optimisée.

	Objectifs:
	  - Un seul DataStore (au lieu de 2) -> moitié moins d'appels.
	  - Schéma compact à clés courtes pour minimiser les octets JSON stockés.
	  - CashMulti n'est PLUS stocké (dérivé de Rebirths + 1).
	  - Brainrots (inventaire + placés) enfin persistés.
	  - Poids possedes stockés en bitmap d'indices (int) plutôt qu'en dict
	    de strings.
	  - UpdateAsync pour éviter les écritures concurrentes / perte de progrès.
	  - Sauvegarde uniquement si dirty -> 0 écriture inutile.

	Schéma stocké (JSON compact) :
		{
			v = 2,                -- version du schéma
			c = <cash>,           -- Cash (number)
			y = <yp>,             -- YeetPower (number)
			r = <rebirths>,       -- Rebirths (int)  → CashMulti = r + 1
			s = <slotLevel>,      -- SlotLevel (int)
			w = <weightBitmap>,   -- Bitmap (int 64 bits) des poids possédés
			e = <equippedIndex>,  -- Index du poids équipé (1-based dans Weights)
			i = { id1, id2, ... },-- Brainrots inventaire : ints encodés
			p = { slotLv = id, ...},-- Brainrots placés : {[slotLevel]=encoded}
		}
	Les clés sont volontairement courtes (1 char). L'espace JSON pour un
	joueur avec 40 brainrots + 20 placés passe d'environ 3.5 Ko à ~400 octets.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local BrainrotUpgrade = require(ReplicatedStorage.Shared:WaitForChild("BrainrotUpgrade"))
local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))

local DataService = Loader.CreateService({
	Name = "DataService",
})

-- ===== CONSTANTS =====

local DATASTORE_NAME = "PlayerSave_v2"
local SCHEMA_VERSION = 2
local AUTOSAVE_INTERVAL = 60 -- filet de sécurité ; la vraie logique est event-driven
local SESSION_LOCK_TIMEOUT = 30 -- secondes avant d'autoriser un bust de lock

-- Délai minimum entre deux écritures DataStore pour un même joueur.
-- Roblox limite UpdateAsync par clef : ~6s d'intervalle recommandé.
-- On debounce donc à 6s : toute modif déclenche un save quasi instantané
-- SI on est au-delà du cooldown, sinon elle est coalescée dans le prochain save.
local MIN_SAVE_INTERVAL = 6

-- Index 1-based des poids dans WeightsConfig.Weights, utilisé pour l'encodage
-- bitmap (`w`) et l'index d'équipement (`e`).
local WEIGHT_INDEX_BY_NAME = {}
for i, cfg in ipairs(WeightsConfig.Weights) do
	WEIGHT_INDEX_BY_NAME[cfg.Name] = i
end

local DEFAULT_WEIGHT_NAME = "Wooden Stick"
local DEFAULT_WEIGHT_INDEX = WEIGHT_INDEX_BY_NAME[DEFAULT_WEIGHT_NAME] or 1

local DEFAULT = {
	v = SCHEMA_VERSION,
	c = 0,         -- Cash
	y = 10,        -- YeetPower
	r = 0,         -- Rebirths
	s = 1,         -- SlotLevel
	sp = 0,        -- SpeedLevel (nombre d'améliorations de vitesse achetées)
	w = 0,         -- weightBitmap (Wooden Stick ajouté ci-dessous)
	e = DEFAULT_WEIGHT_INDEX,
	i = {},        -- inventaire brainrot (ids encodés)
	il = {},       -- niveaux alignés avec `i` (1-75, défaut 1)
	p = {},        -- brainrots placés [slotLevel]=id
	pl = {},       -- niveaux des brainrots placés [slotLevel]=level
	fc = false,    -- Free brainrot claimed (bouton Buy du Free déjà utilisé)
	grc = false,   -- Group reward claimed (bouton Claim de la LikeFrame déjà utilisé)
	gp = {},       -- gamepass flags : { StarterPack=true, CashX2=true, ... }
	-- Timestamp os.time() de la dernière présence online du joueur. Mis à
	-- jour à chaque save (y compris autosave + BindToClose), utilisé par
	-- OfflineEarningsService pour calculer le cash gagné pendant l'absence.
	lo = 0,
	-- Index des brainrots découverts. Clé = fullName ("Tung Sahur", "Gold Bobrito
	-- Bandito", ...) et valeur = true. Persisté pour que l'index de l'UI
	-- garde son état au rejoin. Pour minimiser la taille JSON on stocke les
	-- noms complets tels qu'affichés (suffisamment court vu qu'il n'y a pas
	-- des milliers d'entrées).
	d = {},
}
-- Ajoute "Wooden Stick" (bit correspondant) par défaut.
DEFAULT.w = bit32.bor(DEFAULT.w, bit32.lshift(1, DEFAULT_WEIGHT_INDEX - 1))

-- ===== STATE =====

local dataStore

-- [userId] = profile (table mutable, passée aux autres services)
local profiles = {}
-- [userId] = true si modifié depuis la dernière save
local dirty = {}
-- [userId] = true pendant qu'une save UpdateAsync est en cours
local saveInFlight = {}
-- [userId] = os.clock() de la dernière save réussie (throttle)
local lastSaveAt = {}
-- [userId] = true si un save est déjà programmé (évite le spam)
local saveScheduled = {}
-- [userId] = timestamp os.time() de la dernière présence online lu au
-- chargement (AVANT qu'un save ne l'écrase). Utilisé par OfflineEarningsService
-- pour calculer la durée d'absence même si un save est déclenché tôt.
local loadedLastOnline = {}

-- Forward declarations
local save
local scheduleSave
local markDirty

-- ===== UTILS =====

local function keyFor(userId)
	return "P_" .. tostring(userId)
end

local function cloneDefault()
	local t = table.clone(DEFAULT)
	t.i = {}
	t.il = {}
	t.p = {}
	t.pl = {}
	t.gp = {}
	t.d = {}
	return t
end

-- S'assure que tous les champs attendus existent et sont du bon type.
local function normalize(data)
	if type(data) ~= "table" then return cloneDefault() end
	local out = cloneDefault()

	if type(data.c) == "number" and data.c >= 0 then out.c = data.c end
	if type(data.y) == "number" and data.y >= 0 then out.y = data.y end
	if type(data.r) == "number" and data.r >= 0 then out.r = math.floor(data.r) end
	if type(data.s) == "number" and data.s >= 1 then out.s = math.floor(data.s) end
	if type(data.sp) == "number" and data.sp >= 0 then out.sp = math.floor(data.sp) end
	if type(data.w) == "number" and data.w >= 0 then out.w = math.floor(data.w) end
	if type(data.e) == "number" then out.e = math.floor(data.e) end
	if type(data.lo) == "number" and data.lo >= 0 then out.lo = math.floor(data.lo) end

	-- On s'assure que le poids par défaut est toujours marqué comme possédé.
	out.w = bit32.bor(out.w, bit32.lshift(1, DEFAULT_WEIGHT_INDEX - 1))

	-- Si l'index équipé ne correspond à aucun poids possédé, on retombe
	-- sur le poids par défaut.
	if not WeightsConfig.Weights[out.e]
		or bit32.band(out.w, bit32.lshift(1, out.e - 1)) == 0
	then
		out.e = DEFAULT_WEIGHT_INDEX
	end

	if type(data.i) == "table" then
		local levels = type(data.il) == "table" and data.il or nil
		for idx, id in ipairs(data.i) do
			local n = tonumber(id)
			if n and BrainrotInfo.Decode(n) then
				table.insert(out.i, n)
				local lv = levels and tonumber(levels[idx]) or 1
				table.insert(out.il, BrainrotUpgrade.ClampLevel(lv))
			end
		end
	end

	if data.fc == true then out.fc = true end
	if data.grc == true then out.grc = true end

	-- Index des brainrots découverts : on ne garde que les entrées dont le
	-- fullName est reconnu par BrainrotInfo. Ça nettoie les vieilles sauvegardes
	-- pouvant contenir des noms renommés / supprimés.
	if type(data.d) == "table" then
		for k, v in pairs(data.d) do
			if type(k) == "string" and v == true and BrainrotInfo.GetInfo(k) then
				out.d[k] = true
			end
		end
	end

	-- Gamepass flags : map[string]=true pour chaque flag actif.
	if type(data.gp) == "table" then
		for k, v in pairs(data.gp) do
			if type(k) == "string" and v == true then
				out.gp[k] = true
			end
		end
	end

	if type(data.p) == "table" then
		local placedLevels = type(data.pl) == "table" and data.pl or nil
		for slotLv, id in pairs(data.p) do
			local sl = tonumber(slotLv)
			local n = tonumber(id)
			if sl and n and BrainrotInfo.Decode(n) then
				out.p[sl] = n
				local lv = placedLevels and tonumber(placedLevels[slotLv] or placedLevels[tostring(sl)]) or 1
				out.pl[sl] = BrainrotUpgrade.ClampLevel(lv)
			end
		end
	end

	return out
end

-- ===== PUBLIC READ API (passe par les profils en mémoire) =====

function DataService:GetProfile(player)
	return profiles[player.UserId]
end

-- Marque le profil comme modifié ET programme un save immédiat (debouncé).
function markDirty(userId)
	if not profiles[userId] then return end
	dirty[userId] = true
	scheduleSave(userId)
end

function DataService:MarkDirty(player)
	if player then
		markDirty(player.UserId)
	end
end

-- ===== POIDS (bitmap helpers) =====

function DataService:OwnsWeight(player, weightName)
	local profile = profiles[player.UserId]
	if not profile then return false end
	local idx = WEIGHT_INDEX_BY_NAME[weightName]
	if not idx then return false end
	return bit32.band(profile.w, bit32.lshift(1, idx - 1)) ~= 0
end

function DataService:AddWeight(player, weightName)
	local profile = profiles[player.UserId]
	if not profile then return end
	local idx = WEIGHT_INDEX_BY_NAME[weightName]
	if not idx then return end
	local bit = bit32.lshift(1, idx - 1)
	if bit32.band(profile.w, bit) == 0 then
		profile.w = bit32.bor(profile.w, bit)
		markDirty(player.UserId)
	end
end

function DataService:SetEquippedWeight(player, weightName)
	local profile = profiles[player.UserId]
	if not profile then return end
	local idx = WEIGHT_INDEX_BY_NAME[weightName]
	if not idx then return end
	if profile.e ~= idx then
		profile.e = idx
		markDirty(player.UserId)
	end
end

function DataService:GetEquippedWeight(player)
	local profile = profiles[player.UserId]
	if not profile then return DEFAULT_WEIGHT_NAME end
	local cfg = WeightsConfig.Weights[profile.e]
	return cfg and cfg.Name or DEFAULT_WEIGHT_NAME
end

function DataService:GetOwnedWeightsList(player)
	local profile = profiles[player.UserId]
	local out = {}
	if not profile then return out end
	for i, cfg in ipairs(WeightsConfig.Weights) do
		if bit32.band(profile.w, bit32.lshift(1, i - 1)) ~= 0 then
			table.insert(out, cfg.Name)
		end
	end
	return out
end

-- ===== BRAINROTS INVENTAIRE =====

function DataService:AddBrainrotToInventory(player, fullName, level)
	local profile = profiles[player.UserId]
	if not profile then return end
	local encoded = BrainrotInfo.Encode(fullName)
	if not encoded then return end
	table.insert(profile.i, encoded)
	table.insert(profile.il, BrainrotUpgrade.ClampLevel(level or 1))
	markDirty(player.UserId)
end

-- Retire UN exemplaire du brainrot d'un niveau donné (prioritairement). Si `level`
-- est nil, retire le premier trouvé. Retourne (true, retiredLevel) si retiré.
function DataService:RemoveBrainrotFromInventory(player, fullName, level)
	local profile = profiles[player.UserId]
	if not profile then return false end
	local encoded = BrainrotInfo.Encode(fullName)
	if not encoded then return false end

	if level ~= nil then
		local wanted = BrainrotUpgrade.ClampLevel(level)
		for i = #profile.i, 1, -1 do
			if profile.i[i] == encoded and (profile.il[i] or 1) == wanted then
				table.remove(profile.i, i)
				local lv = table.remove(profile.il, i) or 1
				markDirty(player.UserId)
				return true, lv
			end
		end
	end

	for i = #profile.i, 1, -1 do
		if profile.i[i] == encoded then
			table.remove(profile.i, i)
			local lv = table.remove(profile.il, i) or 1
			markDirty(player.UserId)
			return true, lv
		end
	end
	return false
end

-- Vide complètement l'inventaire. Utilisé par Sell All.
function DataService:ClearBrainrotInventory(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	if #profile.i > 0 then
		table.clear(profile.i)
		table.clear(profile.il)
		markDirty(player.UserId)
	end
end

function DataService:GetBrainrotInventory(player)
	local profile = profiles[player.UserId]
	local out = {}
	if not profile then return out end
	for idx, id in ipairs(profile.i) do
		local name = BrainrotInfo.Decode(id)
		if name then
			table.insert(out, {
				Name = name,
				Level = profile.il[idx] or 1,
			})
		end
	end
	return out
end

-- ===== FREE BRAINROT (shop) =====

function DataService:HasClaimedFree(player)
	local profile = profiles[player.UserId]
	if not profile then return false end
	return profile.fc == true
end

function DataService:SetClaimedFree(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	if profile.fc ~= true then
		profile.fc = true
		markDirty(player.UserId)
	end
end

-- ===== GROUP REWARD (LikeFrame) =====

function DataService:HasClaimedGroupReward(player)
	local profile = profiles[player.UserId]
	if not profile then return false end
	return profile.grc == true
end

function DataService:SetClaimedGroupReward(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	if profile.grc ~= true then
		profile.grc = true
		markDirty(player.UserId)
	end
end

-- ===== GAMEPASS FLAGS =====

function DataService:HasGamepass(player, flagName)
	local profile = profiles[player.UserId]
	if not profile then return false end
	return profile.gp and profile.gp[flagName] == true
end

function DataService:SetGamepass(player, flagName, enabled)
	local profile = profiles[player.UserId]
	if not profile then return end
	if enabled == nil then enabled = true end
	profile.gp = profile.gp or {}
	local current = profile.gp[flagName] == true
	if enabled and not current then
		profile.gp[flagName] = true
		markDirty(player.UserId)
	elseif not enabled and current then
		profile.gp[flagName] = nil
		markDirty(player.UserId)
	end
end

function DataService:GetAllGamepasses(player)
	local profile = profiles[player.UserId]
	local out = {}
	if not profile or not profile.gp then return out end
	for k, v in pairs(profile.gp) do
		if v == true then out[k] = true end
	end
	return out
end

-- ===== BRAINROT DISCOVERY (index) =====

-- Marque un brainrot comme découvert. Retourne true si c'était une nouvelle
-- découverte (premier contact), false si déjà connue.
function DataService:MarkBrainrotDiscovered(player, fullName)
	local profile = profiles[player.UserId]
	if not profile then return false end
	if type(fullName) ~= "string" or fullName == "" then return false end
	if not BrainrotInfo.GetInfo(fullName) then return false end
	profile.d = profile.d or {}
	if profile.d[fullName] then return false end
	profile.d[fullName] = true
	markDirty(player.UserId)
	return true
end

function DataService:IsBrainrotDiscovered(player, fullName)
	local profile = profiles[player.UserId]
	if not profile or not profile.d then return false end
	return profile.d[fullName] == true
end

-- Retourne tous les fullNames découverts sous forme de table-set (k=fullName -> true).
function DataService:GetDiscoveredBrainrots(player)
	local profile = profiles[player.UserId]
	local out = {}
	if not profile or not profile.d then return out end
	for k, v in pairs(profile.d) do
		if v == true then out[k] = true end
	end
	return out
end

-- ===== BRAINROTS PLACÉS =====

function DataService:SetPlacedBrainrot(player, slotLevel, fullName, level)
	local profile = profiles[player.UserId]
	if not profile then return end
	local encoded = BrainrotInfo.Encode(fullName)
	if not encoded then return end
	local lv = BrainrotUpgrade.ClampLevel(level or 1)
	if profile.p[slotLevel] ~= encoded or profile.pl[slotLevel] ~= lv then
		profile.p[slotLevel] = encoded
		profile.pl[slotLevel] = lv
		markDirty(player.UserId)
	end
end

-- Met à jour uniquement le niveau d'un brainrot placé.
function DataService:SetPlacedBrainrotLevel(player, slotLevel, level)
	local profile = profiles[player.UserId]
	if not profile then return end
	if profile.p[slotLevel] == nil then return end
	local lv = BrainrotUpgrade.ClampLevel(level or 1)
	if profile.pl[slotLevel] ~= lv then
		profile.pl[slotLevel] = lv
		markDirty(player.UserId)
	end
end

function DataService:ClearPlacedBrainrot(player, slotLevel)
	local profile = profiles[player.UserId]
	if not profile then return end
	if profile.p[slotLevel] ~= nil or profile.pl[slotLevel] ~= nil then
		profile.p[slotLevel] = nil
		profile.pl[slotLevel] = nil
		markDirty(player.UserId)
	end
end

function DataService:GetPlacedBrainrots(player)
	local profile = profiles[player.UserId]
	local out = {}
	if not profile then return out end
	for slotLv, id in pairs(profile.p) do
		local name = BrainrotInfo.Decode(id)
		if name then
			out[slotLv] = {
				Name = name,
				Level = profile.pl[slotLv] or 1,
			}
		end
	end
	return out
end

-- ===== PERSISTENCE (UpdateAsync + retry) =====

local function pcallUpdate(key, transformer)
	local attempts = 0
	while attempts < 3 do
		attempts += 1
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, transformer)
		end)
		if ok then return true end
		if attempts < 3 then task.wait(1.5 * attempts) end
		if attempts >= 3 then return false, err end
	end
end

-- Charge le profil du joueur depuis le DataStore. Retourne (profile, loaded)
-- où loaded = true si GetAsync a réussi (même si le joueur est nouveau / stored=nil),
-- false uniquement si tous les retries ont échoué (réseau HS).
--
-- CRITIQUE : on ne doit JAMAIS créer un profil vide à partir d'un échec de load,
-- sinon le prochain save va écraser les vraies données du joueur dans le
-- DataStore. Si tous les retries échouent, on kicke le joueur.
local function tryLoad(player)
	local key = keyFor(player.UserId)
	local attempts = 0
	local lastErr
	while attempts < 5 do
		attempts += 1
		local ok, stored = pcall(function()
			return dataStore:GetAsync(key)
		end)
		if ok then
			-- stored peut être nil (nouveau joueur) : c'est un load réussi
			-- qui donne un profil par défaut.
			if stored == nil then
				return cloneDefault(), true
			end
			return normalize(stored), true
		end
		lastErr = stored
		warn(string.format(
			"[DataService] GetAsync tentative %d/5 échouée pour %s : %s",
			attempts, player.Name, tostring(stored)
		))
		if attempts < 5 then
			task.wait(1 + attempts * 2)
		end
	end
	warn(string.format("[DataService] Impossible de charger %s après 5 tentatives : %s",
		player.Name, tostring(lastErr)))
	return nil, false
end

local function load(player)
	local data, ok = tryLoad(player)
	if not ok or not data then
		-- IMPORTANT : on NE crée PAS de profil par défaut ici. Les autres services
		-- verront profiles[userId] == nil et ne feront rien. Le joueur est kické
		-- proprement pour qu'il réessaie sur un serveur qui peut le charger.
		player:Kick("Impossible de charger votre progression (DataStore injoignable). Réessayez dans quelques secondes.")
		return nil
	end

	profiles[player.UserId] = data
	dirty[player.UserId] = false
	-- Snapshot du "last online" chargé depuis le store : survit aux saves
	-- suivants qui vont écraser profile.lo avec os.time().
	loadedLastOnline[player.UserId] = tonumber(data.lo) or 0

	print(string.format(
		"[DataService] LOAD %s (userId=%d) : Cash=%d, Brainrots=%d, Placed=%d",
		player.Name, player.UserId,
		math.floor(data.c or 0), #(data.i or {}),
		(function() local n=0 for _ in pairs(data.p or {}) do n=n+1 end return n end)()
	))

	return data
end

-- Sauvegarde uniquement si dirty. Si forcé, save quand même (déconnexion).
-- Si une save est déjà en cours pour ce joueur, on ATTEND qu'elle se termine
-- avant de lancer la nouvelle : l'in-flight save a capturé le profil avant les
-- dernières modifs, donc il faut une nouvelle écriture pour persister les
-- changements tardifs (placement, steal, etc.).
function save(player, force)
	local userId = player.UserId
	local data = profiles[userId]
	-- CRITIQUE : si le profil n'a jamais été chargé (load échoué + kick), on
	-- ne doit RIEN écrire dans le DataStore, sinon on écraserait les vraies
	-- données avec un état vide.
	if not data then return end

	-- Attend la fin d'une éventuelle save en cours (max 10s pour éviter un blocage
	-- permanent en cas de DataStore HS).
	local waitStart = os.clock()
	while saveInFlight[userId] do
		if os.clock() - waitStart > 10 then
			warn("[DataService] Attente d'une save in-flight trop longue pour " .. player.Name)
			break
		end
		task.wait(0.05)
	end

	-- Re-check : profil toujours présent, et soit force soit dirty.
	data = profiles[userId]
	if not data then return end
	if not force and not dirty[userId] then return end

	saveInFlight[userId] = true
	dirty[userId] = false -- on snapshot le flag ici : tout changement après
	                      -- re-mettra dirty=true et sera pris au prochain save.

	-- Met à jour le timestamp "dernière présence online" avant d'écrire. Au
	-- prochain rejoin on calcule os.time() - lo pour déterminer la durée
	-- d'absence. C'est fait ici plutôt que dans PlayerRemoving pour que même
	-- en cas de crash serveur on ait un timestamp récent (max ~60s d'écart).
	data.lo = os.time()

	local payload = table.clone(data)
	payload.i = table.clone(data.i)
	payload.il = table.clone(data.il)
	payload.p = table.clone(data.p)
	payload.pl = table.clone(data.pl)
	payload.v = SCHEMA_VERSION

	local key = keyFor(userId)
	local ok, err = pcallUpdate(key, function(_old)
		return payload
	end)

	saveInFlight[userId] = false

	if ok then
		lastSaveAt[userId] = os.clock()
		print(string.format(
			"[DataService] SAVE %s (userId=%d) : Cash=%d, Brainrots=%d, Placed=%d" ..
			(force and " [forced]" or ""),
			player.Name, userId,
			math.floor(payload.c or 0), #(payload.i or {}),
			(function() local n=0 for _ in pairs(payload.p or {}) do n=n+1 end return n end)()
		))
	else
		-- Échec : on remet dirty à true et on re-programme un retry.
		dirty[userId] = true
		warn("[DataService] Save échec pour " .. player.Name .. ": " .. tostring(err))
		scheduleSave(userId)
	end
end

-- Programme un save immédiat pour ce joueur, debouncé à MIN_SAVE_INTERVAL.
-- Si le joueur vient d'être sauvé, on attend la fenêtre ; sinon le save part
-- sur la frame suivante. Toutes les modifs pendant l'attente sont coalescées.
function scheduleSave(userId)
	if saveScheduled[userId] then return end
	if not profiles[userId] then return end

	saveScheduled[userId] = true
	task.spawn(function()
		local last = lastSaveAt[userId] or 0
		local remaining = (last + MIN_SAVE_INTERVAL) - os.clock()
		if remaining > 0 then
			task.wait(remaining)
		else
			-- Laisse un heartbeat s'écouler pour coalescer les modifs de la même
			-- frame (ex: place brainrot -> SetPlaced + RemoveFromInventory).
			task.wait()
		end

		saveScheduled[userId] = nil

		local player = Players:GetPlayerByUserId(userId)
		if not player then return end
		if not dirty[userId] then return end
		save(player, false)
	end)
end

function DataService:ForceSave(player)
	save(player, true)
end

-- Retourne le timestamp os.time() de la dernière présence online connue
-- pour ce joueur (0 si nouveau joueur ou profil non chargé). Utilisé par
-- OfflineEarningsService pour calculer la durée d'absence. C'est la valeur
-- LUE au chargement, elle ne change pas après les saves de la session.
function DataService:GetLastOnlineAt(player)
	return tonumber(loadedLastOnline[player.UserId]) or 0
end

-- ===== LIFECYCLE =====

local function onPlayerAdded(player)
	local profile = load(player)
	-- Si le load a échoué, le joueur a été kické : on n'instancie RIEN et on
	-- sort. Les autres services qui attendent Cash/SlotLevel/etc n'auront rien
	-- à restaurer (ce qui est exactement ce qu'on veut : pas de save défaut).
	if not profile then return end

	-- Application des valeurs vers les NumberValue/IntValue attendus par le
	-- reste du code. CashMulti = r + 1 (dérivé, pas stocké).
	local function mk(kind, name, value)
		local v = Instance.new(kind)
		v.Name = name
		v.Value = value
		v.Parent = player
		return v
	end

	local cashVal = mk("NumberValue", "Cash", profile.c)
	local ypVal = mk("NumberValue", "YeetPower", profile.y)
	local rebirthsVal = mk("IntValue", "Rebirths", profile.r)
	local cashMultiVal = mk("IntValue", "CashMulti", profile.r + 1)
	mk("IntValue", "FriendsBoost", 0)
	local slotLevelVal = mk("IntValue", "SlotLevel", profile.s)
	local speedLevelVal = mk("IntValue", "SpeedLevel", profile.sp)

	-- leaderstats : Folder standard Roblox que le PlayerList (Tab) lit
	-- automatiquement pour afficher des stats par joueur. On y met un mirror
	-- du Cash. Vu que les valeurs Cash peuvent largement dépasser 2^31, on
	-- utilise un NumberValue (et non un IntValue qui plafonne à ~2.1B).
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	local cashStat = Instance.new("NumberValue")
	cashStat.Name = "Cash"
	cashStat.Value = profile.c
	cashStat.Parent = leaderstats

	-- Mirror Cash -> leaderstats.Cash (one-way : la source de vérité reste
	-- player.Cash, leaderstats n'est qu'une vitrine pour le PlayerList).
	cashVal:GetPropertyChangedSignal("Value"):Connect(function()
		cashStat.Value = cashVal.Value
	end)

	-- Synchronisation Value -> profile.
	local function sync(valInstance, key)
		valInstance:GetPropertyChangedSignal("Value"):Connect(function()
			local current = profile[key]
			local new = valInstance.Value
			if current ~= new then
				profile[key] = new
				markDirty(player.UserId)
			end
		end)
	end
	sync(cashVal, "c")
	sync(ypVal, "y")
	sync(slotLevelVal, "s")
	sync(speedLevelVal, "sp")

	-- Rebirths + derived CashMulti : on stocke Rebirths, et on met à jour
	-- CashMulti automatiquement (source unique = Rebirths + 1).
	rebirthsVal:GetPropertyChangedSignal("Value"):Connect(function()
		if profile.r ~= rebirthsVal.Value then
			profile.r = rebirthsVal.Value
			markDirty(player.UserId)
		end
		local expected = rebirthsVal.Value + 1
		if cashMultiVal.Value ~= expected then
			cashMultiVal.Value = expected
		end
	end)
end

local function onPlayerRemoving(player)
	-- Save final forcé. La nouvelle version de save() attend proprement la fin
	-- d'une save en cours, donc on ne perd plus de modifs tardives (placement,
	-- steal, achat) qui seraient arrivées pendant la dernière save.
	save(player, true)

	-- Filet de sécurité : si malgré tout dirty est encore true (ex : un
	-- scheduleSave en erreur réseau a reposé le flag), on retente jusqu'à
	-- 10s pour maximiser les chances de persister avant de libérer le profil.
	local userId = player.UserId
	local deadline = os.clock() + 10
	while dirty[userId] and os.clock() < deadline do
		task.wait(0.5)
		save(player, true)
	end

	profiles[player.UserId] = nil
	dirty[player.UserId] = nil
	saveInFlight[player.UserId] = nil
	lastSaveAt[player.UserId] = nil
	saveScheduled[player.UserId] = nil
	loadedLastOnline[player.UserId] = nil
end

-- ===== SERVICE LIFECYCLE =====

function DataService:Init()
	dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
end

-- D8 : guard d'idempotence pour éviter qu'un même joueur soit chargé deux fois
-- (race entre PlayerAdded:Connect et la boucle GetPlayers du Studio replay).
-- Charger 2x un profil cause des appels DataStore concurrents et corrompt le
-- session-locking interne.
local hookedPlayers = {}
local function hookPlayerOnce(player)
	if hookedPlayers[player.UserId] then return end
	hookedPlayers[player.UserId] = true
	onPlayerAdded(player)
end

function DataService:Start()
	Players.PlayerAdded:Connect(hookPlayerOnce)
	Players.PlayerRemoving:Connect(function(player)
		hookedPlayers[player.UserId] = nil
		onPlayerRemoving(player)
	end)

	-- Rattrapage Studio.
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(hookPlayerOnce, p)
	end

	-- Autosave : filet de sécurité. La logique principale est event-driven
	-- (markDirty -> scheduleSave), mais on passe quand même toutes les
	-- AUTOSAVE_INTERVAL secondes sur les profils dirty qui ne seraient pas
	-- encore schédulés (ex : après un échec réseau non retenté).
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, p in ipairs(Players:GetPlayers()) do
				if dirty[p.UserId] and not saveScheduled[p.UserId] then
					scheduleSave(p.UserId)
				end
			end
		end
	end)

	game:BindToClose(function()
		local remaining = 0
		for _, p in ipairs(Players:GetPlayers()) do
			remaining += 1
			task.spawn(function()
				save(p, true)
				remaining -= 1
			end)
		end
		local waitUntil = os.clock() + 25
		while remaining > 0 and os.clock() < waitUntil do
			task.wait(0.1)
		end
	end)

	print("[DataService] Prêt (schema v" .. SCHEMA_VERSION .. ")")
end

return DataService

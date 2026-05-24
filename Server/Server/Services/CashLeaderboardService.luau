--[[
	CashLeaderboardService
	Alimente le leaderboard global « Top Cash » placé sur le spawn
	(Workspace.Spawn.Leaderboards.CashLeaderboard).

	Fonctionnement :
	  - Chaque joueur a un « TotalCps » = somme des CashPerSecond affichés
	    sur les boutons de son plot (donc CPS réel : niveau d'upgrade,
	    CashMulti, gamepass et brainrots exclusifs en %% inclus).
	  - Le serveur écrit ce TotalCps dans un OrderedDataStore global
	    (`CashLeaderboard_v1`) sous la clé = userId, débouncé à 6s pour
	    rester sous les quotas DataStore.
	  - Toutes les 60 secondes, on lit le top 50 du store, on résout les
	    pseudos + avatars, et on peuple les Templates du leaderboard.
	  - Tous les serveurs partagent le même OrderedDataStore -> le même
	    classement apparaît dans toutes les sessions.
]]

local Players          = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))

local CashLeaderboardService = Loader.CreateService({
	Name = "CashLeaderboardService",
})

-- ===== CONFIG =====

-- DataStore : versionner le nom permet un reset propre si on change la métrique.
local STORE_NAME       = "CashLeaderboard_v1"
local TOP_COUNT        = 50
local REFRESH_INTERVAL = 60   -- secondes entre deux fetch top 50
local WRITE_DEBOUNCE   = 6    -- secondes minimum entre deux écritures pour un même joueur
local LEADERBOARD_PATH = { "Spawn", "Leaderboards", "CashLeaderboard" }

-- Couleurs pour les 3 premières positions (or, argent, bronze).
local RANK_COLORS = {
	[1] = Color3.fromRGB(255, 215, 0),    -- or
	[2] = Color3.fromRGB(200, 200, 200),  -- argent
	[3] = Color3.fromRGB(205, 127, 50),   -- bronze
}
local DEFAULT_RANK_COLOR = Color3.fromRGB(255, 255, 255)

-- Slot attributes utilisés pour calculer le TotalCps.
local SLOT_OCCUPIED = "SlotOccupied"
local BTN_CPS_ATTR  = "CashPerSecond"

-- ===== ÉTAT INTERNE =====

local store
local plotsFolder

-- [userId] = lastWrittenCps (pour ne pas re-écrire la même valeur)
local lastWritten = {}
-- [userId] = os.clock() de la dernière écriture réussie
local lastWriteAt = {}
-- [userId] = true si une écriture est déjà schedulée
local writeScheduled = {}

-- ===== UTILS =====

-- Formatte un nombre en notation courte avec UN seul chiffre après la virgule
-- et le suffixe "/S" indiquant que c'est un revenu par seconde.
-- Ex: 222549500 -> "222.5M/S".
local function formatShort(n)
	n = tonumber(n) or 0
	local abs = math.abs(n)
	local sign = n < 0 and "-" or ""
	local value, suffix
	if abs >= 1e15 then
		value, suffix = abs / 1e15, "Q"
	elseif abs >= 1e12 then
		value, suffix = abs / 1e12, "T"
	elseif abs >= 1e9 then
		value, suffix = abs / 1e9, "B"
	elseif abs >= 1e6 then
		value, suffix = abs / 1e6, "M"
	elseif abs >= 1e3 then
		value, suffix = abs / 1e3, "K"
	else
		return string.format("%s%d/S", sign, math.floor(abs + 0.5))
	end
	return string.format("%s%.1f%s/S", sign, value, suffix)
end

-- Trouve le plot d'un joueur en suivant le PlotNumber posé par GameService.
local function getPlayerPlot(player)
	if not plotsFolder then return nil end
	local plotNumVal = player:FindFirstChild("PlotNumber")
	if not plotNumVal then return nil end
	return plotsFolder:FindFirstChild("Plot" .. tostring(plotNumVal.Value))
end

-- Calcule le CPS total affiché actuellement sur le plot d'un joueur.
-- On somme directement les attributs CashPerSecond des boutons : c'est la
-- même valeur que le joueur voit sur le « $X » sous chaque brainrot,
-- donc ça inclut déjà niveau d'upgrade, CashMulti, gamepass et le %% des
-- brainrots exclusifs (calculé par recomputePlotExclusives).
local function computePlayerTotalCps(player)
	local plot = getPlayerPlot(player)
	if not plot then return 0 end

	local total = 0
	for _, desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Parent and desc.Parent.Name == "Buttons" then
			local cps = tonumber(desc:GetAttribute(BTN_CPS_ATTR)) or 0
			if cps > 0 then
				total = total + cps
			end
		end
	end
	return total
end

-- ===== ÉCRITURE OrderedDataStore =====

-- Écrit la valeur dans l'OrderedDataStore. Débouncé à WRITE_DEBOUNCE secondes
-- pour rester loin des quotas Roblox.
local function flushPlayerScore(player)
	if not store or not player or not player.Parent then return end
	local value = computePlayerTotalCps(player)
	value = math.floor(value)
	if value < 0 then value = 0 end

	-- Pas la peine de re-écrire la même valeur.
	if lastWritten[player.UserId] == value then return end

	local ok, err = pcall(function()
		store:SetAsync(tostring(player.UserId), value)
	end)
	if ok then
		lastWritten[player.UserId] = value
		lastWriteAt[player.UserId] = os.clock()
	else
		warn("[CashLeaderboard] SetAsync échec pour " .. player.Name .. " : " .. tostring(err))
	end
end

-- Demande une écriture en respectant le debounce. Sûr à spammer.
local function scheduleWrite(player)
	if not player or not player.Parent then return end
	if writeScheduled[player.UserId] then return end
	writeScheduled[player.UserId] = true

	task.spawn(function()
		local last = lastWriteAt[player.UserId] or 0
		local wait = (last + WRITE_DEBOUNCE) - os.clock()
		if wait > 0 then
			task.wait(wait)
		else
			task.wait()
		end
		writeScheduled[player.UserId] = nil
		if player.Parent then
			flushPlayerScore(player)
		end
	end)
end

-- API publique : appelée par les services qui modifient le CPS d'un joueur
-- (BrainrotPlacementService après placement / retrait / upgrade / steal,
-- GamepassService après achat CashX2, etc.).
function CashLeaderboardService:NotifyCpsChanged(player)
	scheduleWrite(player)
end

-- ===== AFFICHAGE =====

local function getLeaderboardModel()
	local node = Workspace
	for _, name in ipairs(LEADERBOARD_PATH) do
		node = node and node:FindFirstChild(name)
		if not node then return nil end
	end
	return node
end

-- Retourne tous les ScrollingFrame « List » présents dans le modèle, peu
-- importe sur quelle Part ils sont (le modèle peut avoir plusieurs faces
-- d'affichage). On peuple chacun avec le même contenu.
local function getDisplayLists(model)
	local lists = {}
	if not model then return lists end
	for _, desc in ipairs(model:GetDescendants()) do
		if desc.Name == "List" and desc:IsA("ScrollingFrame")
			and desc:FindFirstChild("Template")
		then
			table.insert(lists, desc)
		end
	end
	return lists
end

-- Construit l'image d'avatar standard pour un userId. Si la requête échoue
-- (rare), on retombe sur le placeholder intégré.
local function getAvatarImage(userId)
	local ok, img = pcall(function()
		return Players:GetUserThumbnailAsync(
			userId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size150x150
		)
	end)
	if ok and img then return img end
	return "rbxasset://textures/ui/GuiImagePlaceholder.png"
end

local function getDisplayName(userId)
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(name) == "string" and name ~= "" then return name end
	return "Player"
end

-- Cache des résolutions (userId -> { Name="...", Image="..." }) pour éviter
-- de rappeler GetNameFromUserIdAsync à chaque refresh.
local resolveCache = {}
local function resolveUser(userId)
	local cached = resolveCache[userId]
	if cached then return cached end
	local entry = {
		Name  = getDisplayName(userId),
		Image = getAvatarImage(userId),
	}
	resolveCache[userId] = entry
	return entry
end

-- Vide le contenu d'une List sauf les composants utilitaires (Template,
-- UIListLayout, padding) qu'on conserve pour les prochains refresh.
local function clearList(listFrame)
	local template = listFrame:FindFirstChild("Template")
	for _, child in ipairs(listFrame:GetChildren()) do
		if child ~= template
			and not child:IsA("UIListLayout")
			and not child:IsA("UIGridLayout")
			and not child:IsA("UIPadding")
			and child.Name ~= "InvisPadding"
		then
			child:Destroy()
		end
	end
end

-- Configure une entrée (clone du Template) avec les infos d'un joueur.
local function configureEntry(entry, rank, displayName, value, avatarImage)
	entry.Name = "Rank_" .. rank
	entry.Visible = true
	entry.LayoutOrder = rank

	local numberLabel = entry:FindFirstChild("NumberLabel")
	if numberLabel and numberLabel:IsA("TextLabel") then
		numberLabel.Text = tostring(rank)
		numberLabel.TextColor3 = RANK_COLORS[rank] or DEFAULT_RANK_COLOR
	end

	local frame = entry:FindFirstChild("Frame")
	if frame then
		local nameLabel = frame:FindFirstChild("NameLabel")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = displayName
		end

		local valueLabel = frame:FindFirstChild("Value")
		if valueLabel and valueLabel:IsA("TextLabel") then
			valueLabel.Text = formatShort(value)
		end

		local avatarLabel = frame:FindFirstChild("AvatarLabel")
		if avatarLabel and avatarLabel:IsA("ImageLabel") then
			avatarLabel.Image = avatarImage
		end
	end
end

-- Lit le top du store et redessine les leaderboards visibles.
local function refreshLeaderboard()
	if not store then return end

	local okFetch, pages = pcall(function()
		return store:GetSortedAsync(false, TOP_COUNT)
	end)
	if not okFetch or not pages then
		warn("[CashLeaderboard] GetSortedAsync échec : " .. tostring(pages))
		return
	end

	local okPage, page = pcall(function() return pages:GetCurrentPage() end)
	if not okPage or type(page) ~= "table" then return end

	-- Résout les pseudos / avatars en parallèle avant d'écrire le GUI.
	local entries = {}
	for i, row in ipairs(page) do
		if i > TOP_COUNT then break end
		local userId = tonumber(row.key)
		local value = tonumber(row.value) or 0
		if userId and userId > 0 and value > 0 then
			local info = resolveUser(userId)
			table.insert(entries, {
				Rank = #entries + 1,
				Name = info.Name,
				Value = value,
				Image = info.Image,
			})
		end
	end

	local model = getLeaderboardModel()
	local lists = getDisplayLists(model)
	if #lists == 0 then return end

	for _, listFrame in ipairs(lists) do
		local template = listFrame:FindFirstChild("Template")
		if template then
			template.Visible = false
			clearList(listFrame)

			for _, e in ipairs(entries) do
				local clone = template:Clone()
				configureEntry(clone, e.Rank, e.Name, e.Value, e.Image)
				clone.Parent = listFrame
			end

			-- Force le scroll en haut après un refresh, pour que les serveurs
			-- qui n'ont pas de joueur côté ce panneau voient quand même le top.
			listFrame.CanvasPosition = Vector2.new(0, 0)
		end
	end
end

-- ===== HOOKS JOUEUR =====

local function hookPlayer(player)
	-- Première écriture : on attend que les services place / restaurent le plot,
	-- puis on flush. On schedule plusieurs flush espacés pour rattraper les
	-- changements asynchrones (restoration d'inventaire, recompute exclusifs).
	player:WaitForChild("Cash", 30)

	-- POLISH P1 : flush rapide pour que le nouveau joueur figure dans le top
	-- en moins de ~2-3s au lieu de ~8s. Sans ça, le joueur voit la SurfaceGui
	-- vide ou obsolète le temps que le premier scheduleWrite fire.
	task.delay(2, function()
		if player.Parent then scheduleWrite(player) end
	end)
	task.delay(8, function()
		if player.Parent then scheduleWrite(player) end
	end)
	task.delay(20, function()
		if player.Parent then scheduleWrite(player) end
	end)

	-- POLISH P1 : refresh immédiat du leaderboard pour ce joueur. Sans ça, il
	-- devait attendre jusqu'à 60s (REFRESH_INTERVAL) avant de voir le top à
	-- jour. On débounce de 1.5s avant le refresh pour laisser le temps au flush
	-- ci-dessus de propager son score dans l'OrderedDataStore.
	task.delay(3.5, function()
		if not player.Parent then return end
		local ok, err = pcall(refreshLeaderboard)
		if not ok then
			warn("[CashLeaderboard] Refresh on join échec : " .. tostring(err))
		end
	end)
end

local function onPlayerRemoving(player)
	-- Flush immédiat à la déconnexion (le joueur conserve sa place dans le top).
	flushPlayerScore(player)
	lastWritten[player.UserId] = nil
	lastWriteAt[player.UserId] = nil
	writeScheduled[player.UserId] = nil
end

-- ===== CYCLE DE VIE =====

function CashLeaderboardService:Init()
	local okStore, ds = pcall(function()
		return DataStoreService:GetOrderedDataStore(STORE_NAME)
	end)
	if okStore and ds then
		store = ds
	else
		warn("[CashLeaderboard] Impossible de créer l'OrderedDataStore : " .. tostring(ds))
	end

	local spawnFolder = Workspace:WaitForChild("Spawn", 30)
	plotsFolder = spawnFolder and spawnFolder:WaitForChild("Plots", 30) or nil
end

function CashLeaderboardService:Start()
	-- D8 : guard d'idempotence. hookPlayer yield sur WaitForChild("Cash", 30) ;
	-- sans cette protection, un même joueur peut déclencher deux scheduleWrite
	-- en parallèle qui se chevauchent et causent des SetAsync redondants
	-- (gaspillage de quotas DataStore).
	local hookedPlayers = {}
	local function hookPlayerOnce(p)
		if hookedPlayers[p.UserId] then return end
		hookedPlayers[p.UserId] = true
		hookPlayer(p)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(hookPlayerOnce, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		hookedPlayers[player.UserId] = nil
		onPlayerRemoving(player)
	end)

	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(hookPlayerOnce, p)
	end

	-- Refresh immédiat puis loop périodique sur tous les serveurs.
	task.spawn(function()
		local okFirst, errFirst = pcall(refreshLeaderboard)
		if not okFirst then
			warn("[CashLeaderboard] Refresh initial échec : " .. tostring(errFirst))
		end
		while true do
			task.wait(REFRESH_INTERVAL)
			local ok, err = pcall(refreshLeaderboard)
			if not ok then
				warn("[CashLeaderboard] Refresh échec : " .. tostring(err))
			end
		end
	end)

	-- Filet de sécurité : flush périodique pour les joueurs qui n'auraient pas
	-- déclenché NotifyCpsChanged (ex: leur CPS bouge via un service tiers).
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			for _, p in ipairs(Players:GetPlayers()) do
				scheduleWrite(p)
			end
		end
	end)

	-- Save final propre à la fermeture du serveur.
	game:BindToClose(function()
		for _, p in ipairs(Players:GetPlayers()) do
			flushPlayerScore(p)
		end
	end)

	print("[CashLeaderboardService] Prêt (refresh=" .. REFRESH_INTERVAL .. "s, top=" .. TOP_COUNT .. ")")
end

return CashLeaderboardService

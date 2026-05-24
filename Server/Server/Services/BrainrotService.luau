--[[
	BrainrotService
	Quand un joueur tape le nom d'un brainrot dans le chat, il reçoit un Tool
	avec le modèle du brainrot dans son inventaire (Backpack).

	Migration 1:1 de l'ancien ServerScriptService.BrainrotChatSpawner.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)
local BrainrotLabel = require(ReplicatedStorage.Shared:WaitForChild("BrainrotLabel"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local BrainrotUpgrade = require(ReplicatedStorage.Shared:WaitForChild("BrainrotUpgrade"))

local BrainrotService = Loader.CreateService({
	Name = "BrainrotService",
})

-- Attribut Tool qui retient le niveau d'upgrade du brainrot. 1 par défaut. Le
-- reste du code (placement, label, UI) se base sur cet attribut.
local TOOL_LEVEL_ATTR = "BrainrotLevel"

-- Multiplicateur de prix de vente : CashPerSecond x 10. Doit rester synchronisé
-- avec SellFrameController (affichage côté client).
local SELL_PRICE_MULTIPLIER = 10

-- État interne (rempli dans :Init)
local brainrotsFolder
local spawnEvent
local sellEvent
local sellAllEvent
local DataService

-- Joue l'animation Idle sur un Tool brainrot (si présente). Les brainrots
-- sont des meshes skinnés avec bones : ils s'animent via leur AnimationController
-- même quand tout est ancré / soudé au Handle du Tool.
-- On (re)joue l'anim à la création ET à chaque Equipped : certains tracks
-- se stoppent quand le Tool sort du Workspace (rangement dans le Backpack),
-- donc on relance systématiquement à l'équipement.
local function playToolIdleAnimation(tool)
	if not tool or not tool:IsA("Tool") then return end

	local function ensurePlay()
		local animController = tool:FindFirstChildOfClass("AnimationController")
		if not animController then return end
		local animsFolder = tool:FindFirstChild("Anims")
		local idleAnim = animsFolder and animsFolder:FindFirstChild("Idle")
		if not idleAnim or not idleAnim:IsA("Animation") then return end
		local animator = animController:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = animController
		end
		-- Si un track Idle tourne déjà, on le laisse.
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			if t.Animation == idleAnim and t.IsPlaying then
				return
			end
		end
		local ok, track = pcall(function()
			return animator:LoadAnimation(idleAnim)
		end)
		if not ok or not track then return end
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Idle
		track:Play()
	end

	ensurePlay()
	tool.Equipped:Connect(ensurePlay)
	tool.AncestryChanged:Connect(function()
		if tool:IsDescendantOf(workspace) then
			ensurePlay()
		end
	end)
end

-- Normalise un nom (minuscules, espaces simples)
local function normalize(s)
	if not s then return "" end
	s = tostring(s):lower()
	s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

-- Trouve un brainrot par nom (dans toutes les raretés).
-- Retourne (modelTemplate, rarityFolderName)
local function findBrainrot(query)
	if not query or query == "" then return nil end
	local target = normalize(query)

	local bestPartial, bestPartialRarity

	for _, rarityFolder in ipairs(brainrotsFolder:GetChildren()) do
		if rarityFolder:IsA("Folder") then
			for _, model in ipairs(rarityFolder:GetChildren()) do
				if model:IsA("Model") then
					local n = normalize(model.Name)
					if n == target then
						return model, rarityFolder.Name
					end
					if not bestPartial then
						if n:find(target, 1, true) or target:find(n, 1, true) then
							bestPartial = model
							bestPartialRarity = rarityFolder.Name
						end
					end
				end
			end
		end
	end

	return bestPartial, bestPartialRarity
end

-- Trouve un Tool brainrot correspondant à `fullName` dans le Backpack puis
-- dans le Character du joueur. Retourne nil si aucun match.
local function findBrainrotTool(player, fullName)
	local containers = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then table.insert(containers, backpack) end
	if player.Character then table.insert(containers, player.Character) end

	for _, container in ipairs(containers) do
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child.Name == fullName then
				return child
			end
		end
	end
	return nil
end

-- Vend un brainrot du joueur : supprime le Tool et ajoute le cash correspondant.
local function onSellRequest(player, fullName)
	if typeof(fullName) ~= "string" or fullName == "" or #fullName > 100 then
		return
	end

	local info = BrainrotInfo.GetInfo(fullName)
	if not info then return end

	-- Les brainrots exclusifs (Robux only) ne sont pas vendables.
	if info.ExclusivePercent then return end

	local tool = findBrainrotTool(player, fullName)
	if not tool then return end

	local cashVal = player:FindFirstChild("Cash")
	if not cashVal then return end

	local level = tonumber(tool:GetAttribute(TOOL_LEVEL_ATTR)) or 1
	local cps = BrainrotUpgrade.GetCps(info.CashPerSecond or 0, level)
	local price = cps * SELL_PRICE_MULTIPLIER
	tool:Destroy()
	cashVal.Value = cashVal.Value + price
	DataService:RemoveBrainrotFromInventory(player, fullName, level)
end

-- Vend tous les brainrots du joueur (Backpack + Character). Chaque Tool reconnu
-- par BrainrotInfo est supprimé et son prix (CPS * SELL_PRICE_MULTIPLIER) cumulé.
-- Les brainrots EXCLUSIFS (achetables Robux) sont conservés : ils ne peuvent
-- pas être vendus.
local function onSellAllRequest(player)
	local cashVal = player:FindFirstChild("Cash")
	if not cashVal then return end

	local containers = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then table.insert(containers, backpack) end
	if player.Character then table.insert(containers, player.Character) end

	local total = 0
	for _, container in ipairs(containers) do
		local children = container:GetChildren()
		for _, child in ipairs(children) do
			if child:IsA("Tool") then
				local info = BrainrotInfo.GetInfo(child.Name)
				-- On laisse les exclusifs intacts dans l'inventaire (Robux only).
				if info and not info.ExclusivePercent then
					local level = tonumber(child:GetAttribute(TOOL_LEVEL_ATTR)) or 1
					local cps = BrainrotUpgrade.GetCps(info.CashPerSecond or 0, level)
					total = total + cps * SELL_PRICE_MULTIPLIER
					child:Destroy()
					-- On retire l'exemplaire correspondant du profil persisté.
					-- Important : on ne peut pas appeler ClearBrainrotInventory ici,
					-- sinon les exclusifs (qu'on garde en main) disparaîtraient au
					-- prochain rejoin.
					DataService:RemoveBrainrotFromInventory(player, child.Name, level)
				end
			end
		end
	end

	if total > 0 then
		cashVal.Value = cashVal.Value + total
	end
end

-- Crée un Tool contenant le modèle du brainrot en tant que Handle,
-- en préservant la taille réelle du modèle. Si `level` est fourni, le tool est
-- marqué à ce niveau et son label affiche le niveau correspondant.
local function createBrainrotTool(template, rarity, level)
	level = BrainrotUpgrade.ClampLevel(level or 1)
	local tool = Instance.new("Tool")
	tool.Name = template.Name
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = rarity and (rarity .. " Brainrot") or "Brainrot"
	tool:SetAttribute(TOOL_LEVEL_ATTR, level)

	local clone = template:Clone()

	local primary = clone.PrimaryPart
	if not primary then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				primary = d
				break
			end
		end
	end
	if not primary then
		clone:Destroy()
		tool:Destroy()
		return nil
	end

	primary.Name = "Handle"
	primary.CanCollide = false
	primary.Massless = true
	primary.Anchored = false

	-- D'abord, on nettoie tous les vieux Weld/WeldConstraint/Motor6D du clone
	-- pour repartir d'une base propre. Sinon des liens cassés peuvent laisser
	-- des MeshParts détachés du Handle (visible sur des brainrots avec énormément
	-- de Cube/Part comme La Cucaracha, Pakrahmatmatina, Teddino Rosino).
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Motor6D")
			or d:IsA("ManualWeld") or d:IsA("Snap")
		then
			d:Destroy()
		end
	end

	primary.Parent = tool

	-- Welde TOUTES les BaseParts au Handle (sauf le Handle lui-même). On le
	-- fait AVANT de reparenter pour que les WeldConstraint pointent vers des
	-- parts qui sont déjà ancrées au Handle dès leur création.
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
			d.Anchored = false
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = primary
			wc.Part1 = d
			wc.Parent = primary
		end
	end

	for _, child in ipairs(clone:GetChildren()) do
		child.Parent = tool
	end
	clone:Destroy()

	local size = primary.Size
	local forward = size.Z * 0
	local lift = size.Y * 0
	tool.Grip = CFrame.new(0, lift, -forward)

	-- BillboardGui d'infos au-dessus du brainrot.
	-- Créé ici côté serveur -> répliqué à tous les clients automatiquement.
	-- Visible uniquement quand le Tool est équipé (Handle dans le character),
	-- ce qui correspond bien au comportement "au-dessus du brainrot".
	BrainrotLabel.CreateFromName(primary, template.Name, level)

	-- Lance l'anim Idle : visible quand le Tool est équipé dans les mains.
	playToolIdleAnimation(tool)

	return tool
end

-- Handler d'un message de chat / commande
local function onSpawnRequest(player, brainrotName)
	if typeof(brainrotName) ~= "string" then return end
	if #brainrotName > 100 then return end

	local template, rarity = findBrainrot(brainrotName)
	if not template then
		spawnEvent:FireClient(player, false, "Brainrot introuvable: " .. brainrotName)
		return
	end

	local tool = createBrainrotTool(template, rarity)
	if not tool then
		spawnEvent:FireClient(player, false, "Impossible de créer le tool")
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		tool:Destroy()
		spawnEvent:FireClient(player, false, "Backpack introuvable")
		return
	end

	tool.Parent = backpack
	DataService:AddBrainrotToInventory(player, tool.Name, 1)
	spawnEvent:FireClient(player, true, string.format("%s (%s) ajouté à l'inventaire", template.Name, rarity or "?"))
	print(string.format("[BrainrotService] %s a reçu %s dans son inventaire", player.Name, template.Name))
end

-- API publique : donne un brainrot (Normal) par son nom au joueur. Utilisé
-- par le DunkLuckyBlockService quand le joueur a dunké avec succès et fait
-- franchir la ligne de vente à son brainrot.
function BrainrotService:GiveBrainrotByName(player, brainrotName)
	if typeof(brainrotName) ~= "string" or brainrotName == "" then return nil end
	if not player or not player.Parent then return nil end

	local template, rarity = findBrainrot(brainrotName)
	if not template then return nil end

	local tool = createBrainrotTool(template, rarity)
	if not tool then return nil end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		tool:Destroy()
		return nil
	end

	tool.Parent = backpack
	if DataService and DataService.AddBrainrotToInventory then
		DataService:AddBrainrotToInventory(player, tool.Name, 1)
	end

	-- Marque le brainrot comme découvert dans l'index. Ça double la détection
	-- passive par BrainrotDiscoveryService (via ChildAdded sur Backpack) mais
	-- garantit que les dunks réussis sont toujours comptés, même si le Tool
	-- est immédiatement déplacé vers le Character par EquipTool().
	local okDisc, discovery = pcall(Loader.GetService, "BrainrotDiscoveryService")
	if okDisc and discovery and discovery.MarkDiscovered then
		pcall(function() discovery:MarkDiscovered(player, tool.Name) end)
	end

	return tool
end

-- ===== Cycle de vie =====

-- API publique : expose findBrainrot pour les autres services (lookup
-- de template par nom, pour spawn ou autre).
function BrainrotService:FindTemplate(brainrotName)
	return findBrainrot(brainrotName)
end

function BrainrotService:Init()
	brainrotsFolder = ReplicatedStorage:WaitForChild("Brainrots")
	spawnEvent = RemotesAPI.GetEvent("SpawnBrainrotEvent")
	sellEvent = RemotesAPI.GetEvent("SellBrainrotEvent")
	sellAllEvent = RemotesAPI.GetEvent("SellAllBrainrotsEvent")
end

function BrainrotService:Start()
	DataService = Loader.GetService("DataService")

	spawnEvent.OnServerEvent:Connect(onSpawnRequest)
	sellEvent.OnServerEvent:Connect(onSellRequest)
	sellAllEvent.OnServerEvent:Connect(onSellAllRequest)

	-- Restauration de l'inventaire brainrot à l'arrivée du joueur ET à chaque
	-- respawn : Roblox recrée le Backpack après la mort du character, donc les
	-- Tools non-Archivable sont perdus. On les rend à partir du profil persisté.
	-- Pour éviter les doublons, on ne remet que les brainrots qui ne sont pas
	-- déjà présents dans le Backpack ou le Character.
	local function restoreInventory(player)
		local backpack = player:WaitForChild("Backpack", 30)
		if not backpack then return end

		-- Attendre que WeightService ait placé le poids en slot 1 AVANT de
		-- restaurer les brainrots. Sinon les brainrots prennent le slot 1 et
		-- Roblox ne réassigne pas les slots lors d'un reparenting : le poids
		-- se retrouve coincé en slot 2 dans la hotbar.
		local WeightsConfig
		pcall(function()
			WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))
		end)
		if WeightsConfig then
			local deadline = os.clock() + 5
			while os.clock() < deadline do
				local hasWeight = false
				for _, c in ipairs(backpack:GetChildren()) do
					if c:IsA("Tool") and WeightsConfig.ByName[c.Name] then
						hasWeight = true
						break
					end
				end
				if not hasWeight and player.Character then
					for _, c in ipairs(player.Character:GetChildren()) do
						if c:IsA("Tool") and WeightsConfig.ByName[c.Name] then
							hasWeight = true
							break
						end
					end
				end
				if hasWeight then break end
				task.wait(0.1)
			end
		end

		-- Compte les brainrots actuellement possédés (Backpack + Character), indexés
		-- par (fullName, level) pour éviter de recréer un tool si son exemplaire
		-- exact (même niveau) est déjà là.
		local presentCounts = {}
		local function keyFor(name, lv)
			return name .. "#" .. tostring(lv)
		end
		local function countFrom(container)
			if not container then return end
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and BrainrotInfo.GetInfo(child.Name) then
					local lv = tonumber(child:GetAttribute(TOOL_LEVEL_ATTR)) or 1
					local k = keyFor(child.Name, lv)
					presentCounts[k] = (presentCounts[k] or 0) + 1
				end
			end
		end
		countFrom(backpack)
		countFrom(player.Character)

		local list = DataService:GetBrainrotInventory(player)
		-- Compte par (nom, niveau) le total attendu dans le profil.
		local wanted = {}
		for _, entry in ipairs(list) do
			local k = keyFor(entry.Name, entry.Level)
			wanted[k] = {
				Name = entry.Name,
				Level = entry.Level,
				Count = (wanted[k] and wanted[k].Count or 0) + 1,
			}
		end

		-- Pour chaque brainrot, spawn les exemplaires manquants.
		local spawned, skipped = 0, 0
		for k, entry in pairs(wanted) do
			local missing = entry.Count - (presentCounts[k] or 0)
			if missing > 0 then
				local template, rarity = findBrainrot(entry.Name)
				if template then
					for _ = 1, missing do
						local tool = createBrainrotTool(template, rarity, entry.Level)
						if tool then
							tool.Parent = backpack
							spawned = spawned + 1
						else
							skipped = skipped + 1
						end
					end
				else
					skipped = skipped + missing
				end
			end
		end
		local presentSize = 0
		for _ in pairs(presentCounts) do presentSize = presentSize + 1 end
		if spawned > 0 then
			print(string.format("[BrainrotService] restoreInventory %s : wanted=%d spawned=%d skipped=%d",
				player.Name, #list, spawned, skipped))
		end
	end

	local function hookPlayer(player)
		-- IMPORTANT : on connecte CharacterAdded AVANT d'appeler restoreInventory
		-- pour ne pas rater le premier spawn. Le Character peut apparaître PENDANT
		-- le yield de WaitForChild("Cash") ou le while-loop d'attente du poids,
		-- ce qui détruit le Backpack initial (Roblox le régénère) et avec lui
		-- tous les Tools qu'on aurait déjà insérés. Sans cet ordre, on rate le
		-- respawn et on ne recrée jamais les tools perdus.
		player.CharacterAdded:Connect(function()
			task.wait(0.5)
			restoreInventory(player)
		end)

		-- Attendre que DataService ait chargé le profil avant la première
		-- restauration.
		player:WaitForChild("Cash", 30)

		-- On attend aussi que le Character existe avant de restaurer : sinon
		-- on crée les tools dans un Backpack qui va être détruit juste après.
		if not player.Character then
			player.CharacterAdded:Wait()
			task.wait(0.5) -- laisse Roblox recréer le Backpack
		end

		restoreInventory(player)
	end

	-- D8 : guard d'idempotence pour éviter qu'un même joueur soit hooké deux
	-- fois (race PlayerAdded vs GetPlayers Studio replay). hookPlayer yield sur
	-- WaitForChild("Cash") + WaitForChild("Backpack") + while-loop sur le poids ;
	-- sans guard, deux restoreInventory en parallèle → brainrots dupliqués dans
	-- le Backpack → exploit Cash via la vente.
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
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(hookPlayerOnce, player)
	end

	print("[BrainrotService] Prêt")
end

return BrainrotService

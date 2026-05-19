--[[
	WeightService
	Gère l'achat, l'équipement et l'usage des poids. La persistence est
	déléguée à DataService (un seul DataStore partagé pour tout le joueur).
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)
local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))
local AnimationCache = require(ReplicatedStorage.Shared:WaitForChild("AnimationCache"))

local WeightService = Loader.CreateService({
	Name = "WeightService",
})

-- Références aux remotes et au DataService (résolus dans :Init / :Start).
local weightModels
local buyWeightEvent
local buyWeightRobuxEvent
local equipWeightEvent
local weightDataEvent
local addPowerEvent
local DataService

-- Anti-spam lifting
local LIFT_COOLDOWN = 0.25
local lastLiftTime = {}

-- Constantes pour la pose de cycle de lift côté serveur. Doivent rester
-- cohérentes avec WeightAnimationController côté client.
local MIN_CYCLE_INTERVAL = 0.25
local FALLBACK_CYCLE_LENGTH = 1.0
local LENGTH_WAIT_TIMEOUT = 2.0

-- État des sessions de lift côté serveur. [player.UserId] = {
--     track = AnimationTrack en cours,
--     toolName = string,
--     sessionToken = number,  -- invalidé quand on équipe / déséquipe
-- }
local liftSessions = {}

-- Anti-spam achat (cash) : empêche un joueur d'envoyer 100 buys par seconde
-- ce qui spammerait giveWeightTool et noyerait la réplication client
-- (cause possible de crash client à cause de la cascade d'events Tool).
local BUY_COOLDOWN = 0.5
local lastBuyTime = {}
local lastEquipTime = {}
local EQUIP_COOLDOWN = 0.3

-- Forward declaration : utilisé depuis giveWeightTool mais défini plus bas.
local ensureWeightFirst

-- Forward declarations pour les helpers utilisés dans la section animation
-- avant leur définition réelle (Luau résout les locals à la compilation).
local isWeightTool

-- ===== COMMUNICATION CLIENT =====

local function sendWeightData(player)
	weightDataEvent:FireClient(player, {
		OwnedWeights = DataService:GetOwnedWeightsList(player),
		EquippedWeight = DataService:GetEquippedWeight(player),
	})
end

-- ===== ANIMATION SERVEUR =====
-- Joue / arrête l'animation de lift sur le Humanoid du joueur côté serveur.
-- Le serveur conduit également le cycle (gain de Power + FireClient) ce qui
-- garantit que tous les autres joueurs voient l'animation et que le tempo
-- des cycles est identique pour tout le monde.

local function stopLiftSessionFor(player, reason)
	local session = liftSessions[player.UserId]
	if not session then return end
	-- Invalide les coroutines en cours sur cette session.
	session.sessionToken = (session.sessionToken or 0) + 1
	if session.track then
		pcall(function() session.track:Stop(0) end)
	end
	liftSessions[player.UserId] = nil
	_ = reason
end

local function startLiftSessionFor(player, tool)
	if not player or not player.Parent then return end
	if not tool or not tool:IsA("Tool") then return end

	local config = WeightsConfig.ByName[tool.Name]
	if not config then return end
	local animId = WeightsConfig.AnimationByWeight[tool.Name]
	if not animId then return end

	local character = tool.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- Stop précédent (au cas où un équipement enchaine sans Unequipped clean).
	stopLiftSessionFor(player)

	local anim = AnimationCache.GetAnimation(animId)
	if not anim then return end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	if not ok or not track then return end
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action4
	track:Play(0)

	local session = {
		track = track,
		toolName = tool.Name,
		sessionToken = 1,
	}
	liftSessions[player.UserId] = session
	local mySession = session.sessionToken

	-- Boucle de gain de Power aliée sur la durée réelle de la track.
	task.spawn(function()
		local waited = 0
		while track.Length <= 0 and waited < LENGTH_WAIT_TIMEOUT and liftSessions[player.UserId] == session and session.sessionToken == mySession do
			task.wait(0.05)
			waited += 0.05
		end
		if liftSessions[player.UserId] ~= session or session.sessionToken ~= mySession then return end

		local cycleLength = track.Length > 0 and track.Length or FALLBACK_CYCLE_LENGTH
		if cycleLength < MIN_CYCLE_INTERVAL then
			cycleLength = MIN_CYCLE_INTERVAL
		end

		while liftSessions[player.UserId] == session and session.sessionToken == mySession do
			task.wait(cycleLength)
			if liftSessions[player.UserId] ~= session or session.sessionToken ~= mySession then break end
			if not track.IsPlaying then break end
			if not player.Parent then break end

			-- Vérifie que le tool est toujours équipé.
			local char = player.Character
			if not char then break end
			local currentTool = char:FindFirstChildOfClass("Tool")
			if not currentTool or currentTool.Name ~= session.toolName then break end

			-- Gain Power (même logique que onAddPower).
			if not DataService:OwnsWeight(player, session.toolName) then break end
			if DataService:GetEquippedWeight(player) ~= session.toolName then break end

			local cfg = WeightsConfig.ByName[session.toolName]
			if not cfg or not cfg.PowerPerLift then break end

			local yp = player:FindFirstChild("YeetPower")
			if not yp then break end

			local powerMult = 1
			if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "PowerX2") then
				powerMult = GamepassConfig.POWER_X2_MULT
			end
			local gain = cfg.PowerPerLift * powerMult

			yp.Value = yp.Value + gain
			addPowerEvent:FireClient(player, gain)
		end
	end)
end

-- Hook un Tool de poids côté serveur : Equipped démarre l'animation, Unequipped
-- l'arrête, AncestryChanged gère le cas du Tool détruit / sorti du jeu.
local function bindWeightTool(player, tool)
	if not isWeightTool(tool) then return end

	tool.Equipped:Connect(function()
		startLiftSessionFor(player, tool)
	end)
	tool.Unequipped:Connect(function()
		stopLiftSessionFor(player)
	end)
	tool.AncestryChanged:Connect(function()
		if not tool:IsDescendantOf(game) then
			stopLiftSessionFor(player)
		end
	end)

	-- Si le tool est créé déjà équipé (rare), démarre tout de suite.
	if tool.Parent and tool.Parent:FindFirstChildOfClass("Humanoid") then
		startLiftSessionFor(player, tool)
	end
end

-- ===== TOOL =====

-- Helper: un tool est un poids si son nom apparaît dans la config des poids.
-- Tous les autres tools (brainrots notamment) sont laissés tranquilles.
-- (Déclaré en forward au-dessus pour permettre l'usage dans la section
-- animation serveur située plus haut.)
isWeightTool = function(tool)
	return tool:IsA("Tool") and WeightsConfig.ByName[tool.Name] ~= nil
end

local function giveWeightTool(player, weightName)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	-- CRITIQUE : si un poids est ÉQUIPÉ (dans le character), on le déséquipe
	-- AVANT de le détruire. Détruire un Tool pendant qu'il est équipé déclenche
	-- une cascade de signaux côté client (Tool.Destroying + character.ChildRemoved
	-- + destruction de l'Animation parentée + invalidation de l'AnimationTrack)
	-- qui peut crasher le client. UnequipTools() reparente le tool au backpack
	-- proprement avant qu'on le tue.
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then return end

	local hasEquippedWeight = false
	for _, tool in ipairs(character:GetChildren()) do
		if isWeightTool(tool) then
			hasEquippedWeight = true
			break
		end
	end
	if hasEquippedWeight then
		pcall(function() humanoid:UnequipTools() end)
		-- Laisse Roblox finaliser le déplacement Tool→Backpack et propager
		-- Tool.Unequipped au client AVANT de détruire le tool. 0.25s donne
		-- assez de marge sur connexions lentes pour que le RightGrip Motor6D
		-- soit nettoyé avant qu'on supprime le Handle (sinon état invalide).
		task.wait(0.25)
	end

	-- Désancre tous les Handles avant Destroy : si un ancien client a laissé
	-- un Handle ancré (anciennes versions), le détruire en état ancré +
	-- Motor6D actif crashait. On force Anchored=false serveur-side d'abord.
	local function safeUnanchor(tool)
		for _, d in ipairs(tool:GetDescendants()) do
			if d:IsA("BasePart") then
				pcall(function() d.Anchored = false end)
			end
		end
	end

	-- Ne détruit QUE les tools de poids : brainrots et autres restent intacts.
	for _, tool in ipairs(backpack:GetChildren()) do
		if isWeightTool(tool) then
			safeUnanchor(tool)
			tool:Destroy()
		end
	end
	for _, tool in ipairs(character:GetChildren()) do
		if isWeightTool(tool) then
			safeUnanchor(tool)
			tool:Destroy()
		end
	end

	local model = weightModels:FindFirstChild(weightName)
	if not model then
		warn("[WeightService] Modèle introuvable: " .. weightName)
		return
	end

	local tool = Instance.new("Tool")
	tool.Name = weightName
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- Grip : centre la barre/plate légèrement devant la main, plutôt que collée
	-- au poignet. Le Handle suit naturellement la main droite via Roblox.
	tool.Grip = CFrame.new(0, -0.5, -1)

	local modelClone = model:Clone()
	local primaryPart = modelClone:FindFirstChildWhichIsA("BasePart")
	if not primaryPart then
		modelClone:Destroy()
		tool:Destroy()
		warn("[WeightService] Modèle sans BasePart: " .. weightName)
		return
	end

	primaryPart.Name = "Handle"
	primaryPart.CanCollide = false
	primaryPart.Massless = true
	primaryPart.Anchored = false
	primaryPart.Parent = tool

	-- Reparente les autres parts en weldant chacune au Handle AVANT le reparent.
	-- Déduplique par nom (Bone Barbell a 2 "WeightBar" dans le modèle source).
	local seenNames = { Handle = true }
	for _, child in ipairs(modelClone:GetChildren()) do
		if child:IsA("BasePart") then
			if seenNames[child.Name] then
				child:Destroy()
			else
				seenNames[child.Name] = true
				child.CanCollide = false
				child.Massless = true
				child.Anchored = false
				-- Weld AVANT reparenting : fige la pose actuelle.
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = primaryPart
				wc.Part1 = child
				wc.Parent = primaryPart
				child.Parent = tool
			end
		else
			child.Parent = tool
		end
	end
	modelClone:Destroy()

	tool.Parent = backpack
	bindWeightTool(player, tool)
	ensureWeightFirst(player)
end

-- ===== HOTBAR ORDER =====
-- La hotbar Roblox affiche les tools dans l'ordre des enfants du Backpack.
-- Dès qu'un brainrot (ou tout autre tool) s'ajoute après le poids, le poids
-- peut se retrouver en slot 2+. On force ici le poids à toujours rester en
-- première position par re-parenting complet (guardé par un flag anti-boucle).

local reorderingGuard = {}

ensureWeightFirst = function(player)
	if reorderingGuard[player] then return end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then return end

	local weight
	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:IsA("Tool") and isWeightTool(tool) then
			weight = tool
			break
		end
	end
	if not weight then return end

	-- Déjà en première position ? Rien à faire.
	if backpack:GetChildren()[1] == weight then return end

	-- On ne reparente QUE le poids : juste un Parent = nil puis = backpack
	-- suffit pour le remettre en fin de liste des enfants. Ancienne implémentation
	-- reparentait aussi tous les autres tools pour forcer l'ordre, mais ça
	-- saturait la réplication quand BrainrotService restaure 85+ brainrots :
	-- Roblox écrasait les messages de réplication et le client ne recevait
	-- qu'1 tool sur 85.
	-- Note : avec la hotbar custom SatchelController, l'ordre des enfants du
	-- Backpack n'affecte plus le slot d'affichage, donc ce reparentage est
	-- purement cosmétique pour la hotbar Roblox par défaut (désactivée).
	reorderingGuard[player] = true
	weight.Parent = nil
	weight.Parent = backpack
	reorderingGuard[player] = nil
end

local function watchBackpack(player, backpack)
	-- Defer l'appel pour laisser Roblox finaliser l'ajout / le retrait avant
	-- qu'on ré-ordonne. On hook ChildAdded ET ChildRemoved pour couvrir les
	-- équipements / déséquipements rapides.
	backpack.ChildAdded:Connect(function()
		task.defer(ensureWeightFirst, player)
	end)
	backpack.ChildRemoved:Connect(function()
		task.defer(ensureWeightFirst, player)
	end)
end

-- ===== HANDLERS JOUEUR =====

local function onPlayerReady(player)
	-- Hook le Backpack (présent + futur) pour garder le poids en slot 1.
	local currentBp = player:FindFirstChildOfClass("Backpack")
	if currentBp then watchBackpack(player, currentBp) end
	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			watchBackpack(player, child)
		end
	end)

	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		giveWeightTool(player, DataService:GetEquippedWeight(player))
	end)

	if player.Character then
		task.delay(0.5, function()
			giveWeightTool(player, DataService:GetEquippedWeight(player))
		end)
	end

	task.delay(1, function()
		sendWeightData(player)
	end)
end

local function waitForProfile(player)
	local cash = player:WaitForChild("Cash", 30)
	if not cash then
		warn("[WeightService] Timeout en attendant le profil de " .. player.Name)
		return
	end
	onPlayerReady(player)
end

local function onPlayerAdded(player)
	task.spawn(waitForProfile, player)
end

local function onPlayerRemoving(player)
	lastLiftTime[player.UserId] = nil
	lastBuyTime[player.UserId] = nil
	lastEquipTime[player.UserId] = nil
	reorderingGuard[player] = nil
	stopLiftSessionFor(player)
end

-- ===== REMOTE HANDLERS =====

local function onBuyWithCash(player, weightName)
	if typeof(weightName) ~= "string" then return end
	local config = WeightsConfig.ByName[weightName]
	if not config then return end
	if DataService:OwnsWeight(player, weightName) then return end

	-- Anti-spam : empêche les rebuys ultra-rapides qui causent une cascade
	-- de Tool.Destroying / ChildAdded sur le client (peut crasher).
	local now = tick()
	local last = lastBuyTime[player.UserId] or 0
	if now - last < BUY_COOLDOWN then return end
	lastBuyTime[player.UserId] = now

	if config.Price == 0 then
		DataService:AddWeight(player, weightName)
		DataService:SetEquippedWeight(player, weightName)
		giveWeightTool(player, weightName)
		sendWeightData(player)
		return
	end

	local cashVal = player:FindFirstChild("Cash")
	if not cashVal or cashVal.Value < config.Price then return end

	cashVal.Value = cashVal.Value - config.Price
	DataService:AddWeight(player, weightName)
	DataService:SetEquippedWeight(player, weightName)
	giveWeightTool(player, weightName)
	sendWeightData(player)

	print("[WeightService] " .. player.Name .. " a acheté et équipé " .. weightName .. " pour $" .. config.Price)
end

local function onBuyWithRobux(player, weightName)
	if typeof(weightName) ~= "string" then return end
	local config = WeightsConfig.ByName[weightName]
	if not config or not config.ProductId then return end
	if DataService:OwnsWeight(player, weightName) then return end

	local success, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, config.ProductId)
	end)

	if not success then
		warn("[WeightService] Erreur prompt product: " .. tostring(err))
	end
end

local function onEquip(player, weightName)
	if typeof(weightName) ~= "string" then return end
	local config = WeightsConfig.ByName[weightName]
	if not config then return end
	if not DataService:OwnsWeight(player, weightName) then return end

	-- Anti-spam : équiper en boucle = même cascade Tool.Destroying / ChildAdded
	-- que le buy. On debounce pour protéger le client.
	local now = tick()
	local last = lastEquipTime[player.UserId] or 0
	if now - last < EQUIP_COOLDOWN then return end
	lastEquipTime[player.UserId] = now

	-- Si déjà équipé, on ne refait pas tout le cycle (sinon on détruit puis
	-- recrée le tool inutilement, ce qui dérange l'animation client).
	if DataService:GetEquippedWeight(player) == weightName then
		local character = player.Character
		local hasInChar = false
		if character then
			for _, t in ipairs(character:GetChildren()) do
				if t:IsA("Tool") and t.Name == weightName then hasInChar = true break end
			end
		end
		local bp = player:FindFirstChildOfClass("Backpack")
		local hasInBp = false
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") and t.Name == weightName then hasInBp = true break end
			end
		end
		-- Tool déjà présent quelque part : pas besoin de recréer.
		if hasInChar or hasInBp then
			sendWeightData(player)
			return
		end
	end

	DataService:SetEquippedWeight(player, weightName)
	giveWeightTool(player, weightName)
	sendWeightData(player)

	print("[WeightService] " .. player.Name .. " a équipé " .. weightName)
end

local function onAddPower(player, weightName)
	if typeof(weightName) ~= "string" then return end

	local now = tick()
	local lastTime = lastLiftTime[player.UserId] or 0
	if now - lastTime < LIFT_COOLDOWN then return end
	lastLiftTime[player.UserId] = now

	if not DataService:OwnsWeight(player, weightName) then return end
	if DataService:GetEquippedWeight(player) ~= weightName then return end

	local character = player.Character
	if not character then return end
	local tool = character:FindFirstChildOfClass("Tool")
	if not tool or tool.Name ~= weightName then return end

	local config = WeightsConfig.ByName[weightName]
	if not config or not config.PowerPerLift then return end

	local yeetPower = player:FindFirstChild("YeetPower")
	if not yeetPower then return end

	-- Gamepass PowerX2 : double le gain de Power par lift.
	local powerMult = 1
	if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "PowerX2") then
		powerMult = GamepassConfig.POWER_X2_MULT
	end
	local gain = config.PowerPerLift * powerMult

	yeetPower.Value = yeetPower.Value + gain
	addPowerEvent:FireClient(player, gain)
end

-- ===== API PUBLIQUE =====
-- Appelé par GameService depuis ProcessReceipt.
function WeightService:HandlePurchase(player, productId)
	for _, config in ipairs(WeightsConfig.Weights) do
		if config.ProductId == productId then
			DataService:AddWeight(player, config.Name)
			DataService:SetEquippedWeight(player, config.Name)
			giveWeightTool(player, config.Name)
			DataService:ForceSave(player)
			sendWeightData(player)
			print("[WeightService] " .. player.Name .. " a acheté et équipé " .. config.Name .. " via Robux")
			return true
		end
	end
	return false
end

-- ===== CYCLE DE VIE =====

function WeightService:Init()
	weightModels = ReplicatedStorage:WaitForChild("WeightModels")

	buyWeightEvent = RemotesAPI.GetEvent("BuyWeightEvent")
	buyWeightRobuxEvent = RemotesAPI.GetEvent("BuyWeightRobuxEvent")
	equipWeightEvent = RemotesAPI.GetEvent("EquipWeightEvent")
	weightDataEvent = RemotesAPI.GetEvent("WeightDataEvent")
	addPowerEvent = RemotesAPI.GetEvent("AddPowerEvent")
end

function WeightService:Start()
	DataService = Loader.GetService("DataService")

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	buyWeightEvent.OnServerEvent:Connect(onBuyWithCash)
	buyWeightRobuxEvent.OnServerEvent:Connect(onBuyWithRobux)
	equipWeightEvent.OnServerEvent:Connect(onEquip)
	addPowerEvent.OnServerEvent:Connect(onAddPower)

	-- Filet de sécurité : on ne polle PAS en permanence. Les hooks ChildAdded /
	-- Removed sont suffisants dans 99% des cas. Si un edge case surgit (perte de
	-- signal), on re-ordonne uniquement à l'ajout d'un Backpack (respawn).
	-- Économie : plus de scan toutes les 2s pour tous les joueurs du serveur.

	print("[WeightService] Serveur poids initialisé!")
end

return WeightService

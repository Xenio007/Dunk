--[[
	GameService
	Gère : Rebirth, Skip Rebirth, Friends Boost, Plots, Slots.
	La persistence a été déplacée dans DataService (un seul DataStore,
	schéma compact, brainrots persistés).
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local DataStoreService = game:GetService("DataStoreService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local GameService = Loader.CreateService({
	Name = "GameService",
})

-- ===== IDEMPOTENCE PROCESS RECEIPT =====
-- DataStore qui mémorise les PurchaseId déjà traités. Roblox peut renvoyer
-- le même receipt plusieurs fois (retry réseau, restart serveur, déco entre
-- achat et grant). Sans ce guard, un même achat de Cash peut être crédité
-- 2-3 fois → cash infini exploitable. Avec, on reconnaît le PurchaseId déjà
-- accordé et on répond PurchaseGranted sans rien re-créditer.
local PURCHASE_HISTORY_STORE = DataStoreService:GetDataStore("PurchaseHistory_v1")

-- Retourne :
--   true  : on a déjà traité ce purchase, ne RIEN re-créditer mais répondre PurchaseGranted.
--   false : nouveau purchase, le traiter normalement.
--   nil   : DataStore HS, on n'a aucune certitude. On retourne NotProcessedYet
--           pour que Roblox retente plus tard (jamais grant à l'aveugle).
local function alreadyProcessed(receiptInfo)
	local key = "P_" .. tostring(receiptInfo.PlayerId) .. "_" .. tostring(receiptInfo.PurchaseId)
	local ok, value = pcall(function()
		return PURCHASE_HISTORY_STORE:GetAsync(key)
	 end)
	if not ok then
		warn("[GameService] PurchaseHistory GetAsync KO : " .. tostring(value) ..
			" (PurchaseId=" .. tostring(receiptInfo.PurchaseId) .. ") — receipt mis en attente.")
		return nil
	end
	return value == true
end

-- Marque un PurchaseId comme traité. Doit être appelé JUSTE AVANT chaque
-- return PurchaseGranted dans processReceipt. Le SetAsync est non-bloquant
-- (pcall) : un échec d'écriture n'empêche pas le grant, mais le prochain
-- retry Roblox de ce purchase pourrait re-grant. Acceptable car les retries
-- arrivent rarement et l'écriture finit par réussir au prochain appel.
local function markProcessed(receiptInfo)
	local key = "P_" .. tostring(receiptInfo.PlayerId) .. "_" .. tostring(receiptInfo.PurchaseId)
	pcall(function()
		PURCHASE_HISTORY_STORE:SetAsync(key, true)
	end)
end

-- ===== CONSTANTES =====

local SKIP_REBIRTH_PRODUCT_ID = 3583942557

-- Developer Products qui donnent du Cash (achats directs en Robux)
local CASH_PRODUCTS = {
	[3588152307] = 5000,      -- 5K
	[3588152655] = 20000,     -- 20K
	[3588152877] = 75000,     -- 75K
	[3588153319] = 250000,    -- 250K
	[3588153605] = 1000000,   -- 1M
}
local REBIRTH_BASE_COST = 1000
local REBIRTH_COST_MULTIPLIER = 10
local MAX_PLOTS = 5
local MAX_SLOT_LEVEL = 21

-- Décalages Z par plot (ordre physique de gauche à droite : 5, 3, 1, 2, 4).
-- Les valeurs proviennent du nouveau placement des Plots dans le Workspace.
local PLOT_Z_OFFSETS = {
	[1] = -92,
	[2] = -46,
	[3] = -138,
	[4] = 0,
	[5] = -184,
}

local SLOT_UPGRADE_COSTS = {
	5000000, 25000000, 75000000, 100000000, 250000000,
	750000000, 1000000000, 2000000000, 5000000000, 10000000000,
	25000000000, 50000000000, 100000000000, 200000000000, 500000000000,
	1000000000000, 5000000000000, 10000000000000, 25000000000000, 50000000000000,
}

-- ===== ÉTAT INTERNE =====

local rebirthEvent
local skipRebirthEvent
local getPlayerData
local buySlotEvent

local plotsFolder
local floorsTemplates

local plotOwners = {}
local playerPlot = {}

for i = 1, MAX_PLOTS do
	plotOwners[i] = nil
end

-- ===== HELPERS =====

local function formatNumberShort(num)
	local suffixes = {
		{1e15, "Q"}, {1e12, "T"}, {1e9, "B"}, {1e6, "M"}, {1e3, "K"}
	}
	for _, s in ipairs(suffixes) do
		if num >= s[1] then
			local val = num / s[1]
			if val == math.floor(val) then
				return string.format("%d%s", val, s[2])
			else
				return string.format("%.1f%s", val, s[2])
			end
		end
	end
	return tostring(math.floor(num))
end

local function formatNumber(num)
	return tostring(math.floor(num)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function updateSlotUpgradeSign(plotNumber, slotLevel)
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumber)
	if not plotModel then return end
	local sign = plotModel:FindFirstChild("SlotUpgradeSign")
	if not sign then return end
	local bbPart = sign:FindFirstChild("BillboardPart")
	if not bbPart then return end
	local gui = bbPart:FindFirstChild("SurfaceGui")
	if not gui then return end

	local slotsLabel = gui:FindFirstChild("Slots")
	local achatsBtn = gui:FindFirstChild("Achats")

	local displaySlots = slotLevel + 9
	if slotsLabel then
		if slotLevel >= MAX_SLOT_LEVEL then
			slotsLabel.Text = "Slots " .. displaySlots .. " MAX"
		else
			slotsLabel.Text = "Slots " .. displaySlots
		end
	end

	if achatsBtn then
		local priceLabel = achatsBtn:FindFirstChild("TextLabel")
		if priceLabel then
			if slotLevel >= MAX_SLOT_LEVEL then
				priceLabel.Text = "MAX"
			else
				priceLabel.Text = formatNumberShort(SLOT_UPGRADE_COSTS[slotLevel])
			end
		end
	end
end

local function updatePlotOwnerDisplay(plotNumber, displayName)
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumber)
	if not plotModel then return end
	local deco = plotModel:FindFirstChild("Decorations")
	if not deco then return end
	local plotOwnerPart = deco:FindFirstChild("PlotOwner")
	if not plotOwnerPart then return end
	local gui = plotOwnerPart:FindFirstChild("OwnerGUI")
	if not gui then return end
	local label = gui:FindFirstChild("TextLabel")
	if label then
		label.Text = displayName
	end
end

local function updatePlotMultiDisplay(plotNumber, multiValue)
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumber)
	if not plotModel then return end
	local deco = plotModel:FindFirstChild("Decorations")
	if not deco then return end
	local multiPart = deco:FindFirstChild("CashMultiplier")
	if not multiPart then return end
	local gui = multiPart:FindFirstChild("SurfaceGui")
	if not gui then return end
	local label = gui:FindFirstChild("TextLabel")
	if label then
		label.Text = "x" .. multiValue .. " Multi"
	end
end

-- ===== PLOTS =====

local function assignPlot(player)
	for i = 1, MAX_PLOTS do
		if plotOwners[i] == nil then
			plotOwners[i] = player
			playerPlot[player.UserId] = i
			updatePlotOwnerDisplay(i, player.DisplayName)
			print("[PlotSystem] " .. player.Name .. " assigné au Plot" .. i)
			return i
		end
	end
	warn("[PlotSystem] Aucun plot libre pour " .. player.Name .. " (serveur plein)")
	return nil
end

local function releasePlot(player)
	local plotNum = playerPlot[player.UserId]
	if plotNum then
		updatePlotOwnerDisplay(plotNum, "None")
		updatePlotMultiDisplay(plotNum, 1)
		updateSlotUpgradeSign(plotNum, 1)

		local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNum)
		if plotModel then
			local floorsFolder = plotModel:FindFirstChild("Floors")
			if floorsFolder then
				for _, child in ipairs(floorsFolder:GetChildren()) do
					child:Destroy()
				end
			end
		end

		plotOwners[plotNum] = nil
		playerPlot[player.UserId] = nil
		print("[PlotSystem] Plot" .. plotNum .. " libéré (" .. player.Name .. " parti)")
	end
end

local function teleportToPlot(player, plotNumber)
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumber)
	if not plotModel then return end
	local spawnPart = plotModel:FindFirstChild("SpawnPart")
	if not spawnPart then return end

	local character = player.Character or player.CharacterAdded:Wait()
	local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 10)
	if humanoidRootPart then
		humanoidRootPart.CFrame = spawnPart.CFrame + Vector3.new(0, 3, 0)
	end
end

local function getPlayerPlotNumber(player)
	return playerPlot[player.UserId]
end

-- ===== REBIRTH / BOOSTS =====

local function getRequiredYP(currentRebirths)
	return REBIRTH_BASE_COST * (REBIRTH_COST_MULTIPLIER ^ currentRebirths)
end

local function getNextCashMulti(currentRebirths)
	return currentRebirths + 2
end

local function countFriendsInServer(player)
	local count = 0
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			local success, isFriend = pcall(function()
				return player:IsFriendsWith(otherPlayer.UserId)
			end)
			if success and isFriend then
				count = count + 1
			end
		end
	end
	return count
end

local function updateFriendsBoost(player)
	local friendsBoostVal = player:FindFirstChild("FriendsBoost")
	if not friendsBoostVal then return end
	local friendCount = countFriendsInServer(player)
	friendsBoostVal.Value = friendCount * 5
end

local function updateAllFriendsBoosts()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			updateFriendsBoost(player)
		end)
	end
end

-- ===== FLOORS / SLOTS =====

local function getFloorAndSlotForLevel(level)
	local adjusted = level - 1
	if adjusted <= 10 then
		return 1, adjusted
	else
		return 2, adjusted - 10
	end
end

local function getPlotZOffset(plotNumber)
	return PLOT_Z_OFFSETS[plotNumber] or 0
end

local function placeFloor(plotNumber, floorNumber)
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumber)
	if not plotModel then return end

	local floorsFolder = plotModel:FindFirstChild("Floors")
	if not floorsFolder then
		floorsFolder = Instance.new("Folder")
		floorsFolder.Name = "Floors"
		floorsFolder.Parent = plotModel
	end

	if floorsFolder:FindFirstChild("Floor" .. floorNumber) then return end

	local template = floorsTemplates:FindFirstChild("Floor" .. floorNumber)
	if not template then return end

	local floorModel = Instance.new("Model")
	floorModel.Name = "Floor" .. floorNumber

	local structureFolder = Instance.new("Folder")
	structureFolder.Name = "Structure"
	structureFolder.Parent = floorModel

	local slotsFolder = Instance.new("Folder")
	slotsFolder.Name = "Slots"
	slotsFolder.Parent = floorModel

	local slotBuildsFolder = Instance.new("Folder")
	slotBuildsFolder.Name = "SlotBuilds"
	slotBuildsFolder.Parent = floorModel

	local buttonsFolder = Instance.new("Folder")
	buttonsFolder.Name = "Buttons"
	buttonsFolder.Parent = floorModel

	local zOffset = getPlotZOffset(plotNumber)

	local templateStructure = template:FindFirstChild("Structure")
	if templateStructure then
		for _, part in ipairs(templateStructure:GetChildren()) do
			local clone = part:Clone()
			if clone:IsA("BasePart") then
				clone.CFrame = clone.CFrame + Vector3.new(0, 0, zOffset)
			elseif clone:IsA("Model") then
				clone:PivotTo(clone:GetPivot() + Vector3.new(0, 0, zOffset))
			end
			clone.Parent = structureFolder
		end
	end

	floorModel.Parent = floorsFolder
	print("[SlotSystem] Floor" .. floorNumber .. " placé sur Plot" .. plotNumber)
end

local function placeSlot(plotNumber, floorNumber, slotNumber)
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumber)
	if not plotModel then return end

	local floorsFolder = plotModel:FindFirstChild("Floors")
	if not floorsFolder then return end

	local floorModel = floorsFolder:FindFirstChild("Floor" .. floorNumber)
	if not floorModel then return end

	local template = floorsTemplates:FindFirstChild("Floor" .. floorNumber)
	if not template then return end

	local zOffset = getPlotZOffset(plotNumber)
	local slotName = "Slot" .. slotNumber

	local slotsFolder = floorModel:FindFirstChild("Slots")
	if slotsFolder and not slotsFolder:FindFirstChild(slotName) then
		local templateSlots = template:FindFirstChild("Slots")
		if templateSlots then
			local slotTemplate = templateSlots:FindFirstChild(slotName)
			if slotTemplate then
				local clone = slotTemplate:Clone()
				clone.CFrame = clone.CFrame + Vector3.new(0, 0, zOffset)
				clone.Parent = slotsFolder
			end
		end
	end

	local slotBuildsFolder = floorModel:FindFirstChild("SlotBuilds")
	if slotBuildsFolder and not slotBuildsFolder:FindFirstChild(slotName) then
		local templateSlotBuilds = template:FindFirstChild("SlotBuilds")
		if templateSlotBuilds then
			local sbTemplate = templateSlotBuilds:FindFirstChild(slotName)
			if sbTemplate then
				local clone = sbTemplate:Clone()
				clone:PivotTo(clone:GetPivot() + Vector3.new(0, 0, zOffset))
				clone.Parent = slotBuildsFolder
			end
		end
	end

	local buttonsFolder = floorModel:FindFirstChild("Buttons")
	if buttonsFolder and not buttonsFolder:FindFirstChild(slotName) then
		local templateButtons = template:FindFirstChild("Buttons")
		if templateButtons then
			local btnTemplate = templateButtons:FindFirstChild(slotName)
			if btnTemplate then
				local clone = btnTemplate:Clone()
				clone.CFrame = clone.CFrame + Vector3.new(0, 0, zOffset)
				clone.Parent = buttonsFolder
			end
		end
	end

	print("[SlotSystem] Slot" .. slotNumber .. " (Floor" .. floorNumber .. ") placé sur Plot" .. plotNumber)
end

local function applyAllSlots(plotNumber, slotLevel)
	for level = 2, slotLevel do
		local floorNum, slotNum = getFloorAndSlotForLevel(level)
		if slotNum == 1 then
			placeFloor(plotNumber, floorNum)
		end
		placeSlot(plotNumber, floorNum, slotNum)
	end
end

-- ===== HANDLERS =====

local function onPlayerReady(player)
	-- DataService a déjà créé Cash / YeetPower / Rebirths / CashMulti /
	-- FriendsBoost / SlotLevel à partir du profil persisté.
	local slotLevel = player:FindFirstChild("SlotLevel")
	local slotLevelValue = slotLevel and slotLevel.Value or 1
	local cashMulti = player:FindFirstChild("CashMulti")
	local cashMultiValue = cashMulti and cashMulti.Value or 1

	local plotNum = assignPlot(player)
	if plotNum then
		local plotNumVal = Instance.new("IntValue")
		plotNumVal.Name = "PlotNumber"
		plotNumVal.Value = plotNum
		plotNumVal.Parent = player

		updatePlotMultiDisplay(plotNum, cashMultiValue)
		updateSlotUpgradeSign(plotNum, slotLevelValue)

		if slotLevelValue > 1 then
			applyAllSlots(plotNum, slotLevelValue)
		end

		player.CharacterAdded:Connect(function()
			local pNum = getPlayerPlotNumber(player)
			if pNum then
				task.defer(teleportToPlot, player, pNum)
			end
		end)

		if player.Character then
			task.defer(teleportToPlot, player, plotNum)
		end
	else
		player:Kick("Le serveur est plein (5 plots maximum). Réessaie plus tard!")
		return
	end

	task.delay(1, updateAllFriendsBoosts)
end

local function waitForProfile(player)
	-- On attend que DataService ait créé les Values du joueur.
	local slotLevel = player:WaitForChild("SlotLevel", 30)
	if not slotLevel then
		warn("[GameService] Timeout en attendant le profil de " .. player.Name)
		return
	end
	onPlayerReady(player)
end

local function onPlayerAdded(player)
	task.spawn(waitForProfile, player)
end

local function onPlayerRemoving(player)
	releasePlot(player)
	task.delay(1, updateAllFriendsBoosts)
end

local function onRebirth(player)
	local ypVal = player:FindFirstChild("YeetPower")
	local rebirthsVal = player:FindFirstChild("Rebirths")
	local cashMultiVal = player:FindFirstChild("CashMulti")

	if not ypVal or not rebirthsVal or not cashMultiVal then
		rebirthEvent:FireClient(player, false, "Données non trouvées")
		return
	end

	local requiredYP = getRequiredYP(rebirthsVal.Value)

	if ypVal.Value < requiredYP then
		rebirthEvent:FireClient(player, false, "Pas assez de Yeet Power (" .. formatNumber(ypVal.Value) .. "/" .. formatNumber(requiredYP) .. ")")
		return
	end

	rebirthsVal.Value = rebirthsVal.Value + 1
	cashMultiVal.Value = getNextCashMulti(rebirthsVal.Value - 1)
	ypVal.Value = 0

	local pNum = getPlayerPlotNumber(player)
	if pNum then
		updatePlotMultiDisplay(pNum, cashMultiVal.Value)
	end

	rebirthEvent:FireClient(player, true, "Rebirth " .. rebirthsVal.Value .. " réussi! Nouveau multiplicateur: x" .. cashMultiVal.Value)
	print("[GameService] " .. player.Name .. " a rebirth! Rebirth #" .. rebirthsVal.Value .. ", CashMulti: x" .. cashMultiVal.Value)
end

local function onSkipRebirth(player)
	local success, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, SKIP_REBIRTH_PRODUCT_ID)
	end)
	if not success then
		skipRebirthEvent:FireClient(player, false, "Erreur lors de l'achat: " .. tostring(err))
	end
end

local function onBuySlot(player)
	local cashVal = player:FindFirstChild("Cash")
	local slotLevelVal = player:FindFirstChild("SlotLevel")

	if not cashVal or not slotLevelVal then
		buySlotEvent:FireClient(player, false, "Données non trouvées")
		return
	end

	local currentLevel = slotLevelVal.Value

	if currentLevel >= MAX_SLOT_LEVEL then
		buySlotEvent:FireClient(player, false, "Niveau maximum atteint!")
		return
	end

	local cost = SLOT_UPGRADE_COSTS[currentLevel]
	if not cost then
		buySlotEvent:FireClient(player, false, "Erreur de coût")
		return
	end

	if cashVal.Value < cost then
		buySlotEvent:FireClient(player, false, "Pas assez de Cash! (" .. formatNumberShort(cashVal.Value) .. "/" .. formatNumberShort(cost) .. ")")
		return
	end

	cashVal.Value = cashVal.Value - cost
	slotLevelVal.Value = currentLevel + 1

	local newLevel = slotLevelVal.Value
	local floorNum, slotNum = getFloorAndSlotForLevel(newLevel)

	local pNum = getPlayerPlotNumber(player)
	if pNum then
		updateSlotUpgradeSign(pNum, newLevel)
		if slotNum == 1 then
			placeFloor(pNum, floorNum)
		end
		placeSlot(pNum, floorNum, slotNum)
	end

	buySlotEvent:FireClient(player, true, "Slot " .. newLevel .. " débloqué!")
	print("[GameService] " .. player.Name .. " a acheté Slot " .. newLevel)
end

-- ===== PROCESS RECEIPT =====

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end

	-- IDEMPOTENCE : si on a déjà accordé ce PurchaseId, on confirme à Roblox
	-- qu'il est traité sans rien re-créditer (sinon double-grant à chaque
	-- retry réseau / restart serveur).
	local processed = alreadyProcessed(receiptInfo)
	if processed == true then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	elseif processed == nil then
		-- DataStore HS : on demande un retry plus tard (ne pas grant à l'aveugle).
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Achat direct de Cash en Robux
	local cashReward = CASH_PRODUCTS[receiptInfo.ProductId]
	if cashReward then
		local cashVal = player:FindFirstChild("Cash")
		if not cashVal then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		cashVal.Value = cashVal.Value + cashReward
		print("[GameService] " .. player.Name .. " a acheté " .. cashReward .. " Cash (product " .. receiptInfo.ProductId .. ")")
		markProcessed(receiptInfo)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if receiptInfo.ProductId == SKIP_REBIRTH_PRODUCT_ID then
		local rebirthsVal = player:FindFirstChild("Rebirths")
		local cashMultiVal = player:FindFirstChild("CashMulti")

		if rebirthsVal and cashMultiVal then
			rebirthsVal.Value = rebirthsVal.Value + 1
			cashMultiVal.Value = getNextCashMulti(rebirthsVal.Value - 1)

			local pNum = getPlayerPlotNumber(player)
			if pNum then
				updatePlotMultiDisplay(pNum, cashMultiVal.Value)
			end

			skipRebirthEvent:FireClient(player, true, "Skip Rebirth réussi! Rebirth #" .. rebirthsVal.Value .. ", YeetPower conservé!")
			print("[GameService] " .. player.Name .. " a skip rebirth! Rebirth #" .. rebirthsVal.Value)
			markProcessed(receiptInfo)
		else
			skipRebirthEvent:FireClient(player, false, "Erreur: données non trouvées")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	else
		-- Déléguer à GamepassService si c'est un des 5 gamepasses (Starter,
		-- CashX2, PowerX2, Speed1.2X, BrainrotLuck).
		local okGp, gpService = pcall(Loader.GetService, "GamepassService")
		if okGp and gpService and gpService.HandlePurchase then
			local handled = gpService:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à BrainrotProductService pour les 3 produits Spawn (brainrots Robux)
		local okProd, prodService = pcall(Loader.GetService, "BrainrotProductService")
		if okProd and prodService and prodService.HandlePurchase then
			local handled = prodService:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à RandomBrainrotService pour le produit "random brainrot"
		-- (bouton RandomBrainrot dans MainGui).
		local okRnd, rndService = pcall(Loader.GetService, "RandomBrainrotService")
		if okRnd and rndService and rndService.HandlePurchase then
			local handled = rndService:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à BrainrotPlacementService si c'est un achat de steal
		local okSteal, stealService = pcall(Loader.GetService, "BrainrotPlacementService")
		if okSteal and stealService and stealService.HandlePurchase then
			local handled = stealService:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à BrainrotPlacementService si c'est un upgrade Robux (+3 niveaux)
		if okSteal and stealService and stealService.HandleUpgradePurchase then
			local handled = stealService:HandleUpgradePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à BrainrotPlacementService si c'est un upgrade MAX en Robux
		if okSteal and stealService and stealService.HandleMaxUpgradePurchase then
			local handled = stealService:HandleMaxUpgradePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à WeightService si c'est un achat de poids
		local okGet, weightService = pcall(Loader.GetService, "WeightService")
		if okGet and weightService then
			local handled = weightService:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à ServerLuckService si c'est l'achat du boost de serveur.
		local okSL, serverLuck = pcall(Loader.GetService, "ServerLuckService")
		if okSL and serverLuck and serverLuck.HandlePurchase then
			local handled = serverLuck:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end

		-- Déléguer à OfflineEarningsService pour le product x10 offline.
		local okOff, offlineSvc = pcall(Loader.GetService, "OfflineEarningsService")
		if okOff and offlineSvc and offlineSvc.HandlePurchase then
			local handled = offlineSvc:HandlePurchase(player, receiptInfo.ProductId)
			if handled then
				markProcessed(receiptInfo)
				return Enum.ProductPurchaseDecision.PurchaseGranted
			end
		end
		warn("[GameService] Product inconnu: " .. tostring(receiptInfo.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	markProcessed(receiptInfo)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ===== CYCLE DE VIE =====

function GameService:Init()
	rebirthEvent = RemotesAPI.GetEvent("RebirthEvent")
	skipRebirthEvent = RemotesAPI.GetEvent("SkipRebirthEvent")
	getPlayerData = RemotesAPI.GetFunction("GetPlayerData")
	buySlotEvent = RemotesAPI.GetEvent("BuySlotEvent")

	plotsFolder = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")
	floorsTemplates = ReplicatedStorage:WaitForChild("Floors")
end

-- D8 : guard d'idempotence pour éviter qu'un même joueur soit traité deux fois
-- (une fois par PlayerAdded, une fois par la boucle GetPlayers du Studio replay).
local hookedPlayers = {}
local function hookPlayerOnce(player)
	if hookedPlayers[player.UserId] then return end
	hookedPlayers[player.UserId] = true
	onPlayerAdded(player)
end

function GameService:Start()
	Players.PlayerAdded:Connect(hookPlayerOnce)
	Players.PlayerRemoving:Connect(function(player)
		hookedPlayers[player.UserId] = nil
		onPlayerRemoving(player)
	end)

	-- Rattrapage joueurs déjà connectés (Studio)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(hookPlayerOnce, player)
	end

	rebirthEvent.OnServerEvent:Connect(onRebirth)
	skipRebirthEvent.OnServerEvent:Connect(onSkipRebirth)
	buySlotEvent.OnServerEvent:Connect(onBuySlot)

	getPlayerData.OnServerInvoke = function(player)
		local cashVal = player:FindFirstChild("Cash")
		local ypVal = player:FindFirstChild("YeetPower")
		local rebirthsVal = player:FindFirstChild("Rebirths")
		local cashMultiVal = player:FindFirstChild("CashMulti")
		local friendsBoostVal = player:FindFirstChild("FriendsBoost")
		local slotLevelVal = player:FindFirstChild("SlotLevel")

		return {
			Cash = cashVal and cashVal.Value or 0,
			YeetPower = ypVal and ypVal.Value or 10,
			Rebirths = rebirthsVal and rebirthsVal.Value or 0,
			CashMulti = cashMultiVal and cashMultiVal.Value or 1,
			FriendsBoost = friendsBoostVal and friendsBoostVal.Value or 0,
			SlotLevel = slotLevelVal and slotLevelVal.Value or 1,
		}
	end

	MarketplaceService.ProcessReceipt = processReceipt

	-- Initialiser les panneaux de tous les plots
	for i = 1, MAX_PLOTS do
		updatePlotOwnerDisplay(i, "None")
		updatePlotMultiDisplay(i, 1)
		updateSlotUpgradeSign(i, 1)
	end

	print("[GameService] Serveur initialisé!")
end

return GameService

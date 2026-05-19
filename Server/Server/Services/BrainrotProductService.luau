--[[
	BrainrotProductService
	Gère les 3 "produits" affichés sur le Spawn (Workspace.Spawn.Product 1/2/3).

	Pour chaque produit :
	  - Joue l'animation Idle du brainrot affiché (AnimationController/Anims/Idle)
	    pour qu'il bouge en continu.
	  - Crée un ProximityPrompt sur la plateforme : quand le joueur appuie (E),
	    on propose l'achat du Developer Product correspondant en Robux.
	  - À l'achat confirmé (ProcessReceipt -> HandlePurchase), on donne le
	    brainrot associé au joueur via BrainrotService:GiveBrainrotByName.

	Produits :
	  Product 1 : 3589112098 -> Dragon Cannelloni
	  Product 2 : 3589112684 -> Job Job Job Sahur
	  Product 3 : 3589113190 -> Esok Sekolah
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local BrainrotProductService = Loader.CreateService({
	Name = "BrainrotProductService",
})

-- ===== CONFIG =====

-- Mapping productId -> nom du brainrot à donner.
local PRODUCT_REWARDS = {
	[3589112098] = "Dragon Cannelloni",
	[3589112684] = "Job Job Job Sahur",
	[3589113190] = "Esok Sekolah",
}

-- Mapping nom du Model produit (dans Workspace.Spawn) -> productId + nom brainrot.
local PRODUCTS = {
	{ Model = "Product 1", ProductId = 3589112098, BrainrotName = "Dragon Cannelloni" },
	{ Model = "Product 2", ProductId = 3589112684, BrainrotName = "Job Job Job Sahur" },
	{ Model = "Product 3", ProductId = 3589113190, BrainrotName = "Esok Sekolah" },
}

local PROMPT_NAME = "BuyBrainrotProductPrompt"
local PROMPT_ATTACHMENT_NAME = "BuyBrainrotProductPromptAttachment"
local PROMPT_HEIGHT = 4 -- studs au-dessus de la plateforme
local PROMPT_DISTANCE = 10
local PROMPT_HOLD_DURATION = 0.25

-- Son joué quand un joueur achète un des 3 brainrots.
local PURCHASE_SOUND_ID = "rbxassetid://3406813517"
local PURCHASE_SOUND_VOLUME = 1

-- Set des productIds pour reconnaissance rapide dans HandlePurchase.
local PRODUCT_ID_SET = {}
for id in pairs(PRODUCT_REWARDS) do
	PRODUCT_ID_SET[id] = true
end

-- ===== ÉTAT INTERNE =====

local BrainrotService
local purchaseSound

-- Joue le son d'achat. Clone + Play + Destroy : permet de superposer plusieurs
-- achats simultanés sans se couper l'un l'autre.
local function playPurchaseSound()
	if not purchaseSound then return end
	local s = purchaseSound:Clone()
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
	task.delay(10, function()
		if s and s.Parent then s:Destroy() end
	end)
end

-- ===== HELPERS =====

-- Lance (ou laisse tourner) l'animation Idle d'un brainrot affiché. No-op si
-- l'AnimationController ou l'anim est introuvable.
local function playIdleAnimation(brainrotModel)
	if not brainrotModel or not brainrotModel:IsA("Model") then return end

	local animController = brainrotModel:FindFirstChildOfClass("AnimationController")
		or brainrotModel:FindFirstChildOfClass("Humanoid")
	if not animController then return end

	local animsFolder = brainrotModel:FindFirstChild("Anims")
	if not animsFolder then return end

	local idleAnim = animsFolder:FindFirstChild("Idle")
	if not idleAnim or not idleAnim:IsA("Animation") then return end

	local animator = animController:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = animController
	end

	local ok, track = pcall(function()
		return animator:LoadAnimation(idleAnim)
	 end)
	if not ok or not track then return end

	track.Looped = true
	track.Priority = Enum.AnimationPriority.Idle
	track:Play()
end

-- Trouve le brainrot (Model enfant du Product dont le nom correspond au reward).
local function findBrainrotModel(productModel, brainrotName)
	if not productModel then return nil end
	local direct = productModel:FindFirstChild(brainrotName)
	if direct and direct:IsA("Model") then return direct end
	-- Fallback : premier Model enfant qui a un AnimationController.
	for _, child in ipairs(productModel:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChildOfClass("AnimationController") then
			return child
		end
	end
	return nil
end

-- Retourne la plateforme (plus grande part) du Product pour y parenter le prompt.
local function findPromptHost(productModel)
	if not productModel then return nil end
	local biggest, biggestArea
	for _, child in ipairs(productModel:GetChildren()) do
		if child:IsA("BasePart") then
			local area = child.Size.X * child.Size.Z
			if not biggestArea or area > biggestArea then
				biggest, biggestArea = child, area
			end
		end
	end
	return biggest
end

-- Crée (ou réutilise) le ProximityPrompt sur la plateforme.
local function ensurePrompt(productModel, productId, brainrotName)
	local host = findPromptHost(productModel)
	if not host then
		warn("[BrainrotProductService] Aucune BasePart trouvée pour le prompt de " .. productModel.Name)
		return
	end

	-- Attachment dédié pour placer l'UI du prompt en hauteur (le test de distance
	-- reste basé sur la position monde de l'Attachment).
	local attach = host:FindFirstChild(PROMPT_ATTACHMENT_NAME)
	if not attach then
		attach = Instance.new("Attachment")
		attach.Name = PROMPT_ATTACHMENT_NAME
		attach.Parent = host
	end
	local topY = host.Position.Y + host.Size.Y * 0.5
	attach.WorldPosition = Vector3.new(host.Position.X, topY + PROMPT_HEIGHT, host.Position.Z)

	local prompt = attach:FindFirstChild(PROMPT_NAME)
	if not prompt then
		-- Nettoie un ancien prompt laissé directement sur la part (migration).
		local legacy = host:FindFirstChild(PROMPT_NAME)
		if legacy and legacy:IsA("ProximityPrompt") then
			legacy:Destroy()
		end
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = PROMPT_NAME
		prompt.Parent = attach
	end

	prompt.ActionText = "Acheter"
	prompt.ObjectText = brainrotName
	prompt.HoldDuration = PROMPT_HOLD_DURATION
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true

	prompt.Triggered:Connect(function(player)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
		local ok, err = pcall(function()
			MarketplaceService:PromptProductPurchase(player, productId)
		end)
		if not ok then
			warn("[BrainrotProductService] PromptProductPurchase a échoué (" ..
				tostring(productId) .. ") : " .. tostring(err))
		end
	end)
end

-- ===== API PUBLIQUE =====

-- Appelé par GameService.processReceipt pour les productIds de PRODUCT_REWARDS.
-- Retourne true si le service a géré l'achat (receipt accordé), false sinon.
function BrainrotProductService:HandlePurchase(player, productId)
	local brainrotName = PRODUCT_REWARDS[productId]
	if not brainrotName then return false end

	if not player or not player.Parent then
		-- Le joueur est parti, on accepte quand même pour éviter les retries Roblox.
		return true
	end

	if not BrainrotService or not BrainrotService.GiveBrainrotByName then
		warn("[BrainrotProductService] BrainrotService indisponible pour " .. player.Name)
		return true
	end

	local tool = BrainrotService:GiveBrainrotByName(player, brainrotName)
	if not tool then
		warn("[BrainrotProductService] Impossible de donner " .. brainrotName ..
			" à " .. player.Name)
		return true
	end

	playPurchaseSound()

	print(string.format("[BrainrotProductService] %s a acheté %s (product %d)",
		player.Name, brainrotName, productId))
	return true
end

-- Expose le mapping pour d'autres services (ex: GameService HANDLED check).
function BrainrotProductService:IsHandledProduct(productId)
	return PRODUCT_ID_SET[productId] == true
end

-- ===== CYCLE DE VIE =====

function BrainrotProductService:Init()
	-- Son d'achat : pré-instancié pour que Roblox le pré-charge.
	purchaseSound = Instance.new("Sound")
	purchaseSound.Name = "BrainrotPurchaseSound"
	purchaseSound.SoundId = PURCHASE_SOUND_ID
	purchaseSound.Volume = PURCHASE_SOUND_VOLUME
	purchaseSound.Parent = SoundService
end

function BrainrotProductService:Start()
	BrainrotService = Loader.GetService("BrainrotService")

	local spawnFolder = Workspace:WaitForChild("Spawn", 30)
	if not spawnFolder then
		warn("[BrainrotProductService] Workspace.Spawn introuvable")
		return
	end

	for _, entry in ipairs(PRODUCTS) do
		local productModel = spawnFolder:FindFirstChild(entry.Model)
		if productModel then
			local brainrotModel = findBrainrotModel(productModel, entry.BrainrotName)
			if brainrotModel then
				playIdleAnimation(brainrotModel)
			else
				warn("[BrainrotProductService] Brainrot " .. entry.BrainrotName ..
					" introuvable dans " .. entry.Model)
			end
			ensurePrompt(productModel, entry.ProductId, entry.BrainrotName)
		else
			warn("[BrainrotProductService] " .. entry.Model .. " introuvable dans Workspace.Spawn")
		end
	end

	print("[BrainrotProductService] Prêt")
end

return BrainrotProductService

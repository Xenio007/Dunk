--[[
	GiftService
	Permet à un joueur qui TIENT un brainrot dans sa main de le donner à un
	autre joueur à proximité via un ProximityPrompt "Give brainrot".

	Flux:
	  1. Un ProximityPrompt est attaché au HumanoidRootPart de chaque joueur.
	     La visibilité est gérée côté client (voir GiftController) : le prompt
	     n'est activé chez un observateur que s'il tient lui-même un brainrot
	     ET que la cible n'est pas lui-même.
	  2. Quand un joueur déclenche le prompt sur un autre joueur, le serveur
	     re-valide qu'il a bien un Tool brainrot équipé, crée une offre
	     pendante et envoie un GiftOfferEvent au destinataire.
	  3. Le client destinataire affiche GiftFrame (géré par GiftController)
	     avec Accept / Decline / CloseButton, et renvoie sa réponse via
	     GiftResponseEvent.
	  4. Si Accept : on re-valide que l'émetteur a toujours le brainrot,
	     on retire son Tool + son entrée DataService, et on crée un nouveau
	     Tool équivalent dans le Backpack du receveur.
	  5. Si Decline / CloseButton / timeout 30s : l'offre est simplement
	     nettoyée, aucun brainrot ne change de propriétaire.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))

local GiftService = Loader.CreateService({
	Name = "GiftService",
})

-- ===== CONSTANTS =====

local PROMPT_NAME        = "GiftBrainrotPrompt"
local PROMPT_DISTANCE    = 10
local PROMPT_HOLD        = 0.25
local GIFT_TIMEOUT       = 30           -- secondes avant qu'une offre n'expire
local TOOL_LEVEL_ATTR    = "BrainrotLevel"
local BRAINROTS_FOLDER   = "Brainrots"

-- ===== STATE =====

local DataService
local BrainrotPlacementService
local brainrotsFolder

local giftOfferEvent     -- server -> receiver client (offre reçue)
local giftResponseEvent  -- receiver client -> server (Accept / Decline)
local giftCancelEvent    -- server -> receiver client (timeout / annulation)

-- pendingByReceiver[receiverUserId] = {
--   id, sender, senderUserId, fullName, level, expiresAt
-- }
local pendingByReceiver = {}
local nextOfferId = 0

-- ===== UTILS =====

local function findEquippedBrainrotTool(player)
	local char = player and player.Character
	if not char then return nil end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then return nil end
	if not BrainrotInfo.GetInfo(tool.Name) then return nil end
	return tool
end

local function findTemplateByFullName(fullName)
	if not brainrotsFolder then return nil end
	for _, rarity in ipairs(brainrotsFolder:GetChildren()) do
		if rarity:IsA("Folder") then
			local m = rarity:FindFirstChild(fullName)
			if m and m:IsA("Model") then
				return m
			end
		end
	end
	return nil
end

-- Supprime et notifie toutes les offres en attente liées à `player`, qu'il soit
-- émetteur ou receveur. Utilisé lors du PlayerRemoving.
local function cancelOffersInvolving(player)
	local uid = player.UserId

	-- En tant que receveur.
	if pendingByReceiver[uid] then
		pendingByReceiver[uid] = nil
	end

	-- En tant qu'émetteur.
	for receiverUserId, pending in pairs(pendingByReceiver) do
		if pending.senderUserId == uid then
			pendingByReceiver[receiverUserId] = nil
			local receiver = Players:GetPlayerByUserId(receiverUserId)
			if receiver and giftCancelEvent then
				giftCancelEvent:FireClient(receiver, pending.id)
			end
		end
	end
end

-- ===== PROMPT ATTACHMENT =====

local function attachPromptToCharacter(player, char)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		hrp = char:WaitForChild("HumanoidRootPart", 5)
	end
	if not hrp then return end
	if hrp:FindFirstChild(PROMPT_NAME) then return end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Give brainrot"
	prompt.ObjectText = player.DisplayName
	prompt.HoldDuration = PROMPT_HOLD
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	-- Désactivé par défaut : c'est le client (GiftController) qui l'active
	-- localement selon qu'il tient un brainrot et que la cible n'est pas lui.
	prompt.Enabled = false
	prompt.Parent = hrp

	prompt.Triggered:Connect(function(triggerPlayer)
		GiftService:OfferGift(triggerPlayer, player)
	end)
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(char)
		attachPromptToCharacter(player, char)
	end)
	if player.Character then
		attachPromptToCharacter(player, player.Character)
	end
end

-- ===== PUBLIC API =====

-- Appelé quand un joueur déclenche le prompt Gift sur un autre joueur.
function GiftService:OfferGift(sender, receiver)
	if typeof(sender) ~= "Instance" or not sender:IsA("Player") then return end
	if typeof(receiver) ~= "Instance" or not receiver:IsA("Player") then return end
	if sender == receiver then return end

	-- L'émetteur doit avoir un brainrot équipé dans la main.
	local tool = findEquippedBrainrotTool(sender)
	if not tool then return end

	local info = BrainrotInfo.GetInfo(tool.Name)
	if not info then return end

	-- Les brainrots exclusifs (Robux only) ne peuvent pas être offerts.
	if info.ExclusivePercent then return end

	-- Une seule offre en attente à la fois par receveur : on ignore les
	-- demandes concurrentes plutôt que de les empiler.
	if pendingByReceiver[receiver.UserId] then return end

	local level = tonumber(tool:GetAttribute(TOOL_LEVEL_ATTR)) or 1
	nextOfferId += 1
	local id = nextOfferId

	pendingByReceiver[receiver.UserId] = {
		id           = id,
		sender       = sender,
		senderUserId = sender.UserId,
		fullName     = tool.Name,
		level        = level,
		expiresAt    = os.clock() + GIFT_TIMEOUT,
	}

	giftOfferEvent:FireClient(receiver, {
		Id             = id,
		SenderName     = sender.DisplayName,
		FullName       = tool.Name,
		Level          = level,
		Rarity         = info.RarityType,
		TimeoutSeconds = GIFT_TIMEOUT,
	})

	-- Expiration automatique côté serveur si le receveur ne répond pas.
	task.delay(GIFT_TIMEOUT, function()
		local pending = pendingByReceiver[receiver.UserId]
		if pending and pending.id == id then
			pendingByReceiver[receiver.UserId] = nil
			if receiver and receiver.Parent and giftCancelEvent then
				giftCancelEvent:FireClient(receiver, id)
			end
		end
	end)
end

-- ===== RESPONSE HANDLER =====

local function onGiftResponse(receiver, id, accept)
	if typeof(id) ~= "number" then return end

	local pending = pendingByReceiver[receiver.UserId]
	if not pending or pending.id ~= id then return end
	pendingByReceiver[receiver.UserId] = nil

	if not accept then return end

	-- Re-valide que l'émetteur a toujours le même brainrot équipé au même
	-- niveau. Sinon l'offre est silencieusement abandonnée.
	local sender = pending.sender
	if not sender or not sender.Parent then return end

	local tool = findEquippedBrainrotTool(sender)
	if not tool or tool.Name ~= pending.fullName then return end
	local toolLevel = tonumber(tool:GetAttribute(TOOL_LEVEL_ATTR)) or 1
	if toolLevel ~= pending.level then return end

	local backpack = receiver:FindFirstChildOfClass("Backpack")
	if not backpack then return end

	local template = findTemplateByFullName(pending.fullName)
	if not template then return end

	-- Transfert : retire du profil de l'émetteur, détruit son Tool, puis
	-- reconstruit un Tool propre dans le Backpack du receveur (même nom,
	-- même niveau) et l'enregistre côté DataService.
	DataService:RemoveBrainrotFromInventory(sender, pending.fullName, pending.level)
	tool:Destroy()

	local newTool = BrainrotPlacementService:_buildBrainrotTool(template, pending.fullName, pending.level)
	if newTool then
		newTool.Parent = backpack
		DataService:AddBrainrotToInventory(receiver, pending.fullName, pending.level)
	end
end

-- ===== LIFECYCLE =====

function GiftService:Init()
	brainrotsFolder   = ReplicatedStorage:WaitForChild(BRAINROTS_FOLDER)
	giftOfferEvent    = RemotesAPI.GetEvent("GiftOfferEvent")
	giftResponseEvent = RemotesAPI.GetEvent("GiftResponseEvent")
	giftCancelEvent   = RemotesAPI.GetEvent("GiftCancelEvent")
end

function GiftService:Start()
	DataService = Loader.GetService("DataService")
	BrainrotPlacementService = Loader.GetService("BrainrotPlacementService")

	giftResponseEvent.OnServerEvent:Connect(onGiftResponse)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, p)
	end

	Players.PlayerRemoving:Connect(cancelOffersInvolving)

	print("[GiftService] Prêt")
end

return GiftService

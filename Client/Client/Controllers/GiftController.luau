--[[
	GiftController
	Côté client du système "Give brainrot".

	Responsabilités :
	  1. Activer le ProximityPrompt "Give brainrot" (nom = GiftBrainrotPrompt)
	     attaché au HumanoidRootPart de CHAQUE autre joueur UNIQUEMENT si le
	     joueur local tient un brainrot (Tool reconnu par BrainrotInfo) dans
	     sa main. Le prompt n'est jamais activé sur le joueur local lui-même.
	  2. À la réception d'un GiftOfferEvent, afficher StarterGui.MainGui.GiftFrame
	     en pré-remplissant le texte et en câblant Accept / Decline / CloseButton.
	     Après 30s sans réponse, la frame se cache automatiquement (le serveur
	     ignore de toute façon les réponses expirées).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))

local GiftController = Loader.CreateController({
	Name = "GiftController",
})

-- ===== CONSTANTS =====

local PROMPT_NAME   = "GiftBrainrotPrompt"
local GIFT_TIMEOUT  = 30
local ACCEPT_SOUND  = "rbxassetid://3406813517"
local ACCEPT_VOLUME = 0.8

local localPlayer = Players.LocalPlayer

-- ===== STATE =====

local hasBrainrotEquipped = false
local trackedPrompts = {}   -- prompt -> RBXScriptConnection lists
local currentOfferId = nil
local offerExpireThread = nil

local giftFrame
local giftTextLabel
local acceptButton
local declineButton
local closeButton

local giftOfferEvent
local giftResponseEvent
local giftCancelEvent

-- ===== PROMPT VISIBILITY =====

-- Un prompt est activé ssi :
--   - il appartient au HRP d'un AUTRE joueur (pas le local),
--   - le joueur local tient actuellement un brainrot dans la main.
local function shouldEnablePrompt(prompt)
	if not hasBrainrotEquipped then return false end
	local hrp = prompt.Parent
	if not hrp or not hrp:IsA("BasePart") then return false end
	local character = hrp.Parent
	if not character then return false end
	local targetPlayer = Players:GetPlayerFromCharacter(character)
	if not targetPlayer or targetPlayer == localPlayer then return false end
	return true
end

local function refreshPromptEnabled(prompt)
	local enabled = shouldEnablePrompt(prompt)
	if prompt.Enabled ~= enabled then
		prompt.Enabled = enabled
	end
end

local function refreshAllPrompts()
	for prompt in pairs(trackedPrompts) do
		if prompt.Parent then
			refreshPromptEnabled(prompt)
		else
			trackedPrompts[prompt] = nil
		end
	end
end

local function trackPrompt(prompt)
	if trackedPrompts[prompt] then return end
	trackedPrompts[prompt] = true
	refreshPromptEnabled(prompt)
	prompt.AncestryChanged:Connect(function(_, parent)
		if not parent then
			trackedPrompts[prompt] = nil
		end
	end)
end

local function watchCharacter(player)
	local function onCharacter(char)
		local hrp = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 10)
		if not hrp then return end
		local prompt = hrp:FindFirstChild(PROMPT_NAME) or hrp:WaitForChild(PROMPT_NAME, 10)
		if prompt and prompt:IsA("ProximityPrompt") then
			trackPrompt(prompt)
		end

		-- Le prompt peut être ajouté après le HRP (ordre de création serveur).
		hrp.ChildAdded:Connect(function(child)
			if child.Name == PROMPT_NAME and child:IsA("ProximityPrompt") then
				trackPrompt(child)
			end
		end)
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

-- ===== LOCAL PLAYER : detect equipped brainrot =====

local function hookLocalCharacter(char)
	local function recompute()
		local found = false
		for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") and BrainrotInfo.GetInfo(t.Name) then
				found = true
				break
			end
		end
		if found ~= hasBrainrotEquipped then
			hasBrainrotEquipped = found
			refreshAllPrompts()
		end
	end

	recompute()
	char.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then recompute() end
	end)
	char.ChildRemoved:Connect(function(c)
		if c:IsA("Tool") then recompute() end
	end)
end

-- ===== GIFT FRAME UI =====

local function hideGiftFrame()
	if giftFrame then
		giftFrame.Visible = false
	end
	currentOfferId = nil
	if offerExpireThread then
		task.cancel(offerExpireThread)
		offerExpireThread = nil
	end
end

local function playAcceptSound()
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end
	local sound = Instance.new("Sound")
	sound.SoundId = ACCEPT_SOUND
	sound.Volume = ACCEPT_VOLUME
	sound.PlayOnRemove = false
	sound.Parent = playerGui
	sound:Play()
	sound.Ended:Once(function() sound:Destroy() end)
	-- Filet de sécurité si Ended ne fire pas (sound non chargé).
	task.delay(5, function()
		if sound.Parent then sound:Destroy() end
	end)
end

local function respond(accept)
	local id = currentOfferId
	if not id then return end
	hideGiftFrame()
	if accept then
		playAcceptSound()
	end
	if giftResponseEvent then
		giftResponseEvent:FireServer(id, accept)
	end
end

local function showOffer(payload)
	if not giftFrame or not giftTextLabel then return end
	if type(payload) ~= "table" then return end
	local id = tonumber(payload.Id)
	if not id then return end

	currentOfferId = id
	giftTextLabel.Text = string.format(
		"Accept %s from %s?",
		tostring(payload.FullName or "brainrot"),
		tostring(payload.SenderName or "player")
	)
	giftFrame.Visible = true

	-- Timer client (double du timer serveur). Si on n'a pas répondu à temps,
	-- on cache la frame localement ; le serveur ignorera de toute façon la
	-- réponse tardive.
	if offerExpireThread then
		task.cancel(offerExpireThread)
	end
	local timeout = tonumber(payload.TimeoutSeconds) or GIFT_TIMEOUT
	offerExpireThread = task.delay(timeout, function()
		if currentOfferId == id then
			hideGiftFrame()
		end
	end)
end

local function wireButtons()
	if acceptButton then
		acceptButton.MouseButton1Click:Connect(function()
			respond(true)
		end)
	end
	if declineButton then
		declineButton.MouseButton1Click:Connect(function()
			respond(false)
		end)
	end
	if closeButton then
		closeButton.MouseButton1Click:Connect(function()
			respond(false)
		end)
	end
end

-- ===== LIFECYCLE =====

function GiftController:Start()
	giftOfferEvent    = RemotesAPI.GetEvent("GiftOfferEvent")
	giftResponseEvent = RemotesAPI.GetEvent("GiftResponseEvent")
	giftCancelEvent   = RemotesAPI.GetEvent("GiftCancelEvent")

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainGui   = playerGui:WaitForChild("MainGui")
	giftFrame       = mainGui:WaitForChild("GiftFrame")
	giftTextLabel   = giftFrame:WaitForChild("TextLabel")
	local btnFrame  = giftFrame:WaitForChild("Frame")
	acceptButton    = btnFrame:WaitForChild("Accept")
	declineButton   = btnFrame:WaitForChild("Decline")
	closeButton     = giftFrame:WaitForChild("CloseButton")

	-- État initial : frame cachée.
	giftFrame.Visible = false
	wireButtons()

	giftOfferEvent.OnClientEvent:Connect(showOffer)
	giftCancelEvent.OnClientEvent:Connect(function(id)
		if currentOfferId == id then
			hideGiftFrame()
		end
	end)

	-- Suit le Tool équipé du joueur local.
	localPlayer.CharacterAdded:Connect(hookLocalCharacter)
	if localPlayer.Character then
		hookLocalCharacter(localPlayer.Character)
	end

	-- Suit les prompts sur TOUS les autres joueurs (et futurs joueurs).
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= localPlayer then
			task.spawn(watchCharacter, p)
		end
	end
	Players.PlayerAdded:Connect(function(p)
		if p ~= localPlayer then
			task.spawn(watchCharacter, p)
		end
	end)
end

return GiftController

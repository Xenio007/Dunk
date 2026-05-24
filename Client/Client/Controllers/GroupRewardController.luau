--[[
	GroupRewardController
	Gère le bouton Claim de la LikeFrame.

	Flux :
	  - Au join, on reçoit l'état claimed (true/false) du serveur. Si déjà
	    claimé, on affiche "Claimed" sur le bouton et on le désactive.
	  - Clic Claim :
	      * Fire ClaimGroupRewardEvent au serveur.
	      * Si serveur répond ok=true -> on applique l'état claimed et son.
	      * Si reason="not_in_group" -> on ouvre le POPUP NATIF Roblox via
	        GroupService:PromptJoinAsync (API ajoutée en déc 2024). Si le
	        joueur rejoint dans le popup, on re-fire automatiquement le
	        claim pour lui donner sa récompense sans avoir à recliquer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local SoundService = game:GetService("SoundService")
local GroupService = game:GetService("GroupService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local GroupRewardController = Loader.CreateController({
	Name = "GroupRewardController",
})

-- ⚠️ Doit matcher GROUP_ID dans GroupRewardService. Sert ici à :
--   1) ouvrir le popup natif via GroupService:PromptJoinAsync
--   2) construire l'URL du groupe en fallback (notification).
local GROUP_ID = 652951457

local LABEL_DEFAULT = "Claim"
local LABEL_CLAIMED = "Claimed"

function GroupRewardController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local claimEvent = RemotesAPI.GetEvent("ClaimGroupRewardEvent")
	local stateEvent = RemotesAPI.GetEvent("GroupRewardStateEvent")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end
	local likeFrame = mainGui:WaitForChild("LikeFrame", 30)
	if not likeFrame then return end
	local claimButton = likeFrame:WaitForChild("ClaimButton", 30)
	if not claimButton then return end

	-- Le TextLabel enfant contient le texte (voir hiérarchie LikeFrame).
	local buttonLabel = claimButton:FindFirstChildWhichIsA("TextLabel", true)

	local claimSound = Instance.new("Sound")
	claimSound.Name = "GroupRewardClaimSound"
	claimSound.SoundId = "rbxassetid://3406813517"
	claimSound.Volume = 1
	claimSound.Parent = SoundService

	local isClaimed = false
	local requesting = false
	local stateReceived = false
	-- Verrou pour éviter d'ouvrir 10 popups si le serveur fire not_in_group
	-- plusieurs fois ou si le joueur respamme Claim pendant le popup natif.
	local promptInProgress = false

	local function setLabel(text)
		if buttonLabel and buttonLabel:IsA("TextLabel") then
			buttonLabel.Text = text
		elseif claimButton:IsA("TextButton") then
			claimButton.Text = text
		end
	end

	local function applyState(claimed)
		isClaimed = claimed and true or false
		if isClaimed then
			setLabel(LABEL_CLAIMED)
			claimButton.Active = false
			claimButton.AutoButtonColor = false
		else
			setLabel(LABEL_DEFAULT)
			claimButton.Active = true
			if claimButton:IsA("TextButton") or claimButton:IsA("ImageButton") then
				claimButton.AutoButtonColor = true
			end
		end
	end

	local function notify(title, text)
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = title,
				Text = text,
				Duration = 5,
			})
		end)
	end

	-- Ouvre le popup natif Roblox pour rejoindre le groupe. Yield jusqu'à ce
	-- que le joueur ferme le popup. Si la réponse est Joined ou AlreadyMember,
	-- on re-fire automatiquement le claim pour livrer la récompense.
	local function promptJoinGroup()
		if promptInProgress then return end
		if GROUP_ID <= 0 then
			notify("Configuration", "GROUP_ID non configuré côté client.")
			return
		end
		promptInProgress = true

		local ok, result = pcall(function()
			return GroupService:PromptJoinAsync(GROUP_ID)
		end)

		promptInProgress = false

		if not ok then
			-- Le popup peut échouer si le joueur en a déjà un autre ouvert,
			-- si l'API est temporairement indispo, ou si le groupId est invalide.
			warn("[GroupRewardController] PromptJoinAsync échec : " .. tostring(result))
			notify("Rejoins le groupe",
				"Rejoins le groupe Roblox puis reclique pour recevoir Gangster Footera.")
			return
		end

		-- result est un Enum.GroupMembershipStatus.
		-- Joined : le joueur vient de rejoindre via le popup.
		-- AlreadyMember : il était déjà membre (rare ici car on arrive sur not_in_group).
		-- JoinRequestPending : groupe avec demande d'approbation -> pas claim, on notifie.
		-- None : le joueur a fermé sans rejoindre, ou pas éligible.
		if result == Enum.GroupMembershipStatus.Joined
			or result == Enum.GroupMembershipStatus.AlreadyMember
		then
			-- Re-fire le claim : le serveur va re-check IsInGroup (qui retourne true
			-- maintenant) et donner la récompense. On laisse 1s pour que le cache
			-- d'appartenance Roblox côté serveur se mette à jour.
			requesting = true
			task.delay(1, function()
				if not isClaimed then
					claimEvent:FireServer()
				end
				requesting = false
			end)
		elseif result == Enum.GroupMembershipStatus.JoinRequestPending then
			notify("Demande envoyée",
				"Ta demande d'adhésion est en attente. Reviens claim ta récompense une fois accepté.")
		else
			-- None ou autre : le joueur a annulé / pas éligible. Pas de notif
			-- intrusive, le bouton Claim reste accessible pour ressayer.
		end
	end

	-- État initial : en attendant la réponse serveur, on affiche "Claim".
	applyState(false)

	stateEvent.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then return end

		local wasClaimed = isClaimed
		if payload.claimed ~= nil then
			applyState(payload.claimed)
		end

		-- Cas d'un claim qui vient de réussir.
		if payload.ok and stateReceived and not wasClaimed and isClaimed then
			claimSound:Play()
			notify("Récompense récupérée", "Gangster Footera ajouté à ton inventaire !")
		end

		-- Cas : le joueur n'est pas dans le groupe -> POPUP NATIF.
		if payload.ok == false and payload.reason == "not_in_group" then
			task.spawn(promptJoinGroup)
		end

		if payload.ok == false and payload.reason == "give_failed" then
			notify("Erreur", "Impossible de donner la récompense, réessaie dans un instant.")
		end

		stateReceived = true
	end)

	local function onActivated()
		if isClaimed or requesting then return end
		requesting = true
		claimEvent:FireServer()
		task.delay(1, function()
			requesting = false
		end)
	end

	if claimButton:IsA("TextButton") or claimButton:IsA("ImageButton") then
		claimButton.Activated:Connect(onActivated)
	else
		-- Fallback : si c'est un Frame, on branche sur InputBegan.
		claimButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				onActivated()
			end
		end)
	end
end

return GroupRewardController

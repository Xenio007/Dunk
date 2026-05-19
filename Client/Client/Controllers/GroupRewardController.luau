--[[
	GroupRewardController
	Gère le bouton Claim de la LikeFrame.

	Flux :
	  - Au join, on reçoit l'état claimed (true/false) du serveur. Si déjà
	    claimé, on affiche "Claimed" sur le bouton et on le désactive.
	  - Clic Claim :
	      * Fire ClaimGroupRewardEvent au serveur.
	      * Si serveur répond ok=true -> on applique l'état claimed et son.
	      * Si reason="not_in_group" -> on appelle
	        GroupService:GetGroupsAsync pas nécessaire ici, on affiche le
	        popup Roblox Player -> PromptGroupJoin via le GameInvite n'existe
	        pas ; on utilise à la place l'ouverture de l'URL du groupe via
	        GuiService / ou plus simple : on laisse le joueur aller sur la
	        page. La méthode la plus propre dans Roblox est
	        `SocialService:PromptGameInvite` pour un jeu, mais pour un groupe
	        il n'y a pas de prompt natif moderne : on utilise donc le
	        legacy Player:JoinGroup via la fenêtre intégrée (PromptPurchase
	        fonctionne pour les assets). Concrètement, on ouvre la page du
	        groupe via GuiService:OpenBrowserWindow n'existe pas non plus.

	    En pratique, la façon moderne est d'afficher un message invitant le
	    joueur à rejoindre le groupe (on ne peut plus forcer un popup
	    natif). On utilise donc la notification StarterGui:SetCore
	    "SendNotification" + on re-check lors d'un prochain clic.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local SoundService = game:GetService("SoundService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local GroupRewardController = Loader.CreateController({
	Name = "GroupRewardController",
})

-- ⚠️ Doit matcher GROUP_ID dans GroupRewardService. Utilisé ici uniquement
-- pour construire l'URL du groupe dans la notification.
local GROUP_ID = 0

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

		-- Cas : le joueur n'est pas dans le groupe.
		if payload.ok == false and payload.reason == "not_in_group" then
			local groupUrl = (GROUP_ID > 0)
				and ("https://www.roblox.com/groups/" .. tostring(GROUP_ID))
				or ""
			notify("Rejoins le groupe", "Rejoins notre groupe Roblox puis reclique pour recevoir Gangster Footera." .. (groupUrl ~= "" and (" (" .. groupUrl .. ")") or ""))
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

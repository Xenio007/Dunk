--[[
	FeedbackController
	Ajoute un bouton TopbarPlus "Feedback" qui ouvre la popup native Roblox
	de feedback (SocialService:PromptGameInvitePromptClosed... non : on utilise
	`SocialService:PromptFeedbackSubmissionAsync(localPlayer)` qui affiche le
	dialog officiel pour collecter du feedback.

	Note Roblox : un joueur ne peut soumettre qu'un feedback par jour par expérience.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local FeedbackController = Loader.CreateController({
	Name = "FeedbackController",
})

-- Icone générique "chat / message bulle" (free Roblox asset).
local FEEDBACK_ICON = "rbxassetid://6031229150"

function FeedbackController:Start()
	local ok, Icon = pcall(require, ReplicatedStorage:WaitForChild("Icon", 10))
	if not ok or not Icon then
		warn("[FeedbackController] ReplicatedStorage.Icon (TopbarPlus) introuvable")
		return
	end

	local player = Players.LocalPlayer

	local icon = Icon.new()
		:setName("Feedback")
		:setLabel("Feedback")
		:setRight()
		:setCaption("Feedback")

	icon.selected:Connect(function()
		-- Deselect immédiat pour que le bouton ne reste pas en état "selected".
		icon:deselect()

		if not SocialService or not SocialService.PromptFeedbackSubmissionAsync then
			warn("[FeedbackController] SocialService:PromptFeedbackSubmissionAsync indisponible (client trop ancien ?)")
			return
		end

		local okPrompt, errPrompt = pcall(function()
			SocialService:PromptFeedbackSubmissionAsync(player)
		end)
		if not okPrompt then
			warn("[FeedbackController] PromptFeedbackSubmissionAsync échec : " .. tostring(errPrompt))
		end
	end)

	print("[FeedbackController] Prêt")
end

return FeedbackController

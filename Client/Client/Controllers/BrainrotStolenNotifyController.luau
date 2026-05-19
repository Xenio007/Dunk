--[[
	BrainrotStolenNotifyController
	Affiche un texte rouge dans StarterGui.MainGui.TopBar.Steal.TextLabel quand
	un joueur se fait voler un brainrot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local BrainrotStolenNotifyController = Loader.CreateController({
	Name = "BrainrotStolenNotifyController",
})

local NOTIF_DURATION = 4 -- secondes avant disparition du texte

function BrainrotStolenNotifyController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[BrainrotStolenNotifyController] MainGui introuvable")
		return
	end

	local topBar = mainGui:WaitForChild("TopBar", 15)
	local stealFrame = topBar and topBar:WaitForChild("Steal", 15)
	local label = stealFrame and stealFrame:WaitForChild("TextLabel", 15)
	if not label then
		warn("[BrainrotStolenNotifyController] TopBar.Steal.TextLabel introuvable")
		return
	end

	-- État initial : vide et invisible.
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(255, 40, 40)
	if stealFrame:IsA("GuiObject") then
		stealFrame.Visible = false
	end

	local currentToken = 0

	local function showText(text)
		currentToken += 1
		local myToken = currentToken

		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 40, 40)
		if stealFrame:IsA("GuiObject") then
			stealFrame.Visible = true
		end

		task.delay(NOTIF_DURATION, function()
			if myToken ~= currentToken then return end
			label.Text = ""
			if stealFrame:IsA("GuiObject") then
				stealFrame.Visible = false
			end
		end)
	end

	local notifyEvent = RemotesAPI.GetEvent("BrainrotStolenNotifyEvent")
	notifyEvent.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		local full = tostring(payload.FullName or "your brainrot")
		local thief = tostring(payload.ThiefName or "someone")
		local level = tonumber(payload.Level) or 1
		showText(string.format("%s just stole your %s (Lvl %d)!", thief, full, level))
	end)
end

return BrainrotStolenNotifyController

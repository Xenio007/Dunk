--[[
	RunIndicatorController
	Affiche le bandeau "RUN!!" (MainGui.Run) pendant la phase WaveChase du dunk
	et le cache aux phases qui terminent la course (BrainrotLost / BrainrotSold /
	End). Le bandeau a déjà un LocalScript intégré qui anime sa couleur de fond
	quand sa propriété Visible passe à true, on se contente donc de toggle Visible.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local RunIndicatorController = Loader.CreateController({
	Name = "RunIndicatorController",
})

function RunIndicatorController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end

	local runFrame = mainGui:WaitForChild("Run", 30)
	if not runFrame then
		warn("[RunIndicatorController] MainGui.Run introuvable")
		return
	end

	runFrame.Visible = false

	local dunkEvent = RemotesAPI.GetEvent("DunkSequenceEvent")
	dunkEvent.OnClientEvent:Connect(function(phase)
		if phase == "WaveChase" then
			runFrame.Visible = true
		elseif phase == "BrainrotLost"
			or phase == "BrainrotSold"
			or phase == "End"
		then
			runFrame.Visible = false
		end
	end)

	-- Si le character respawn pendant la course (rare), on remet à zéro.
	player.CharacterAdded:Connect(function()
		runFrame.Visible = false
	end)

	print("[RunIndicatorController] Prêt")
end

return RunIndicatorController

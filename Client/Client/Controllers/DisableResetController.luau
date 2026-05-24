--[[
	DisableResetController
	Désactive définitivement le bouton "Reset Character" du menu Roblox
	(Esc -> Reset Character ou raccourci R). Le joueur ne peut plus se respawn
	lui-même.

	On ré-applique à chaque CharacterAdded car Roblox ré-active parfois le
	callback après un load character.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local DisableResetController = Loader.CreateController({
	Name = "DisableResetController",
})

local function applyDisable()
	-- StarterGui:SetCore prend du temps à être dispo après un join : on retry
	-- en boucle courte jusqu'à succès. La doc Roblox recommande ce pattern.
	local start = os.clock()
	while os.clock() - start < 5 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if ok then return end
		task.wait(0.1)
	end
end

function DisableResetController:Start()
	local player = Players.LocalPlayer
	applyDisable()

	-- Ré-applique au respawn : si quelque chose le ré-active (par ex un autre
	-- script qui fait SetCore(true) puis se termine), on le coupe à nouveau.
	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		applyDisable()
	end)

	print("[DisableResetController] Reset character désactivé")
end

return DisableResetController

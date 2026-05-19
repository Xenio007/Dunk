--[[
	FreeGiftEmoteLoopController (Controller module)
	Joue en boucle côté client l'animation "Idle" de chaque Gangster Footera
	sous Workspace.Spawn.FreeGift, avec un léger décalage entre chacun.

	Migration 1:1 de StarterPlayerScripts.FreeGiftEmoteLoopClient.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local FreeGiftEmoteLoopController = Loader.CreateController({
	Name = "FreeGiftEmoteLoopController",
})

local STAGGER_DELAY = 0.35 -- secondes de décalage entre chaque Gangster

local function playLoopFor(model)
	if not model:IsA("Model") then return end

	local controller = model:FindFirstChildOfClass("AnimationController")
		or model:FindFirstChildOfClass("Humanoid")
	if not controller then return end

	local animator = controller:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end

	local anims = model:FindFirstChild("Anims")
	if not anims then return end

	local animation = anims:FindFirstChild("Idle")
	if not animation then
		for _, child in ipairs(anims:GetChildren()) do
			if child:IsA("Animation") then
				animation = child
				break
			end
		end
	end
	if not animation then return end

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then return end

	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action4
	track:Play()

	track.Stopped:Connect(function()
		if model.Parent and animator.Parent then
			track:Play()
		end
	end)
end

function FreeGiftEmoteLoopController:Start()
	local freeGift = Workspace:WaitForChild("Spawn"):WaitForChild("FreeGift")

	-- Lancement avec stagger sur tous les Gangster Footera déjà présents.
	local index = 0
	for _, child in ipairs(freeGift:GetChildren()) do
		if child.Name == "Gangster Footera" and child:IsA("Model") then
			local delay = index * STAGGER_DELAY
			task.delay(delay, playLoopFor, child)
			index += 1
		end
	end

	-- Nouveaux Gangster Footera ajoutés plus tard.
	freeGift.ChildAdded:Connect(function(child)
		if child.Name == "Gangster Footera" and child:IsA("Model") then
			task.delay(0.2, playLoopFor, child)
		end
	end)
end

return FreeGiftEmoteLoopController

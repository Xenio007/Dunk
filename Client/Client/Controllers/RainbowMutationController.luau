--[[
	RainbowMutationController
	Côté client : cycle la couleur des brainrots Rainbow (tous les BaseParts
	d'un Model dont le nom commence par "Rainbow ") à travers le spectre HSV
	pour un effet arc-en-ciel fluide.

	L'animation est locale au joueur : pas de réplication serveur, chaque
	client anime ses propres instances. C'est purement visuel donc c'est le
	bon endroit.

	Cibles :
	  - Workspace (brainrots placés sur les slots, brainrots en Dunk, etc.)
	  - Backpack + Character du local player (Tools brainrot)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local RainbowMutationController = Loader.CreateController({
	Name = "RainbowMutationController",
})

local RAINBOW_PREFIX = "Rainbow "
-- Vitesse du cycle : 1 tour complet du spectre en ce nombre de secondes.
local CYCLE_DURATION = 3
-- Décalage de teinte (hue) par Part pour donner un effet "onde" dans le mesh
-- plutôt qu'une couleur uniforme qui change d'un coup.
local PER_PART_HUE_OFFSET = 0.05

local player = Players.LocalPlayer

-- [Model] = { parts = {BasePart list with original color snapshot}, hooked = true }
local trackedModels = {}

local function isRainbowTarget(inst)
	if not inst then return false end
	if string.sub(inst.Name, 1, #RAINBOW_PREFIX) ~= RAINBOW_PREFIX then return false end
	return inst:IsA("Model") or inst:IsA("Tool")
end

local function collectParts(model)
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, { part = d, baseHueOffset = (#parts) * PER_PART_HUE_OFFSET })
		end
		-- Une SurfaceAppearance vide override quand même le rendu et empêche
		-- la Color de la BasePart de s'afficher. On la détruit côté client pour
		-- que le cycle rainbow soit visible sur le mesh.
		if d:IsA("SurfaceAppearance") then
			pcall(function() d:Destroy() end)
		end
	end
	return parts
end

local function trackModel(model)
	if trackedModels[model] then return end
	trackedModels[model] = { parts = collectParts(model) }

	-- Si des BaseParts s'ajoutent plus tard (streaming, tool réarmé), on les
	-- ramasse aussi.
	local conn = model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			local entry = trackedModels[model]
			if entry then
				table.insert(entry.parts, { part = d, baseHueOffset = (#entry.parts) * PER_PART_HUE_OFFSET })
			end
		end
	end)

	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(game) then
			trackedModels[model] = nil
			conn:Disconnect()
		end
	end)
end

-- Scan récursif d'un conteneur pour trouver tous les Model/Tool Rainbow.
local function scanContainer(container)
	if not container then return end
	for _, d in ipairs(container:GetDescendants()) do
		if isRainbowTarget(d) then
			trackModel(d)
		end
	end
end

local function hookContainer(container)
	if not container then return end
	scanContainer(container)
	container.DescendantAdded:Connect(function(d)
		if isRainbowTarget(d) then
			trackModel(d)
		end
	end)
end

function RainbowMutationController:Init()
end

function RainbowMutationController:Start()
	hookContainer(Workspace)

	local backpack = player:WaitForChild("Backpack", 30)
	if backpack then hookContainer(backpack) end

	if player.Character then hookContainer(player.Character) end
	player.CharacterAdded:Connect(function(char)
		hookContainer(char)
	end)

	-- Boucle d'animation : update la Color de chaque part tracké à ~30fps.
	-- Anciennement chaque RenderStepped (60fps+) ce qui sur 80+ brainrots
	-- avec multiples parts saturait le main thread du client. 30fps est
	-- visuellement identique pour un cycle de 3 secondes.
	local RAINBOW_FRAME_INTERVAL = 1 / 30
	local lastFrame = 0
	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if now - lastFrame < RAINBOW_FRAME_INTERVAL then return end
		lastFrame = now

		local baseHue = (now / CYCLE_DURATION) % 1
		for model, entry in pairs(trackedModels) do
			if model.Parent then
				for _, pack in ipairs(entry.parts) do
					local part = pack.part
					if part.Parent then
						local h = (baseHue + pack.baseHueOffset) % 1
						part.Color = Color3.fromHSV(h, 0.9, 1)
					end
				end
			else
				trackedModels[model] = nil
			end
		end
	end)

	print("[RainbowMutationController] Prêt")
end

return RainbowMutationController

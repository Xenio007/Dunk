--[[
	AssetPreloadController
	Lance le preload des assets du jeu des que le joueur rejoint (lance le
	controller via le Loader). Tier 1 (essentiel) bloque sur la frame d'init,
	tier 2 + tier 3 sont en arriere-plan.

	Pourquoi : sans ca, les animations / meshes / sons sont charges a la volee
	quand le joueur les rencontre pour la premiere fois -> lag visible (anim
	qui saute, mesh blanc une fraction de seconde, son qui demarre en retard).

	Infra deja existante : ReplicatedStorage.Shared.AssetPreloader fait le
	boulot (avec strategie par plateforme), il manquait juste un appel.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local AssetPreloader = require(ReplicatedStorage.Shared:WaitForChild("AssetPreloader"))

local AssetPreloadController = Loader.CreateController({
	Name = "AssetPreloadController",
})

function AssetPreloadController:Start()
	-- Tier 1 : essentiel. Charge en parallele dans une coroutine pour ne pas
	-- bloquer le Start des autres controllers (LoadingScreen / UI doivent
	-- pouvoir s'afficher pendant le preload).
	task.spawn(function()
		AssetPreloader.PreloadEssential(function(loaded, total)
			-- Hook pour qu'un LoadingScreen puisse afficher la progression.
			_G.AssetPreloadProgress = { loaded = loaded, total = total }
		end)
		print(string.format("[AssetPreloadController] Tier 1 termine (%s)", AssetPreloader.GetPlatform()))
	end)

	-- Tier 2 + 3 : sons, VFX, brainrots premium, weights, anims clones, etc.
	-- Lance immediatement, attend en interne la fin du tier 1.
	AssetPreloader.StartBackground()
end

return AssetPreloadController
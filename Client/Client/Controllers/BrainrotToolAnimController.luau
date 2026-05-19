--[[
	BrainrotToolAnimController
	Note : la lecture de l'anim Idle est maintenant effectuée côté SERVEUR
	(BrainrotService.playToolIdleAnimation crée l'Animator + Play à la création
	du Tool, Equipped et AncestryChanged). Ce fichier est gardé vide pour
	compatibilité historique : il est encore listed dans le Loader, mais ne
	doit rien faire pour éviter de jouer une SECONDE track sur le même
	Animator (ce qui causait des saccades / superpositions visibles surtout
	pour les autres joueurs).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local BrainrotToolAnimController = Loader.CreateController({
	Name = "BrainrotToolAnimController",
})

function BrainrotToolAnimController:Init() end
function BrainrotToolAnimController:Start()
	print("[BrainrotToolAnimController] No-op : anim Idle des brainrots gérée côté serveur (BrainrotService).")
end

return BrainrotToolAnimController

--[[
	Main (serveur)
	Point d'entrée UNIQUE côté serveur pour la Single-Script Architecture.

	À ce stade (Étape 1), le dossier Services est VIDE.
	Ce script ne fait donc rien de visible : il crée juste l'infrastructure
	et attend que l'on ajoute des Services dans les étapes suivantes.

	IMPORTANT : les anciens scripts serveur (GameServer, WeightServer,
	BrainrotChatSpawner) tournent toujours en parallèle. On les migrera un
	par un vers Services/, puis on les désactivera.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local servicesFolder = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")

Loader.BootServer(servicesFolder)

--[[
	Main (client)
	Point d'entrée UNIQUE côté client pour la Single-Script Architecture.

	À ce stade (Étape 1), le dossier Controllers est VIDE.
	Ce script ne fait donc rien de visible.

	IMPORTANT : tous les LocalScripts existants (Hover, UI, UINavigation,
	RebirthGui, WeightShopClient, etc.) tournent toujours en parallèle.
	On les migrera un par un vers Controllers/, puis on les désactivera.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local controllersFolder = playerScripts:WaitForChild("Client"):WaitForChild("Controllers")

Loader.BootClient(controllersFolder)

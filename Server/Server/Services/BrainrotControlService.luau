--[[
	BrainrotControlService
	Handler du remote ChatControlBrainrotEvent : quand un joueur tape
	"control <nom>" ou "/c <nom>" dans le chat, on transforme son character
	en ce brainrot (en réutilisant la phase "BrainrotPicked" du DunkSequenceEvent
	que le client interprète déjà).

	Seul le joueur qui a tapé la commande peut prendre le contrôle pour
	lui-même : le serveur fire client uniquement vers ce joueur.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local SpeedConfig = require(ReplicatedStorage:WaitForChild("SpeedConfig"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))
local PlayerBrainrotTransform = require(script.Parent:WaitForChild("PlayerBrainrotTransform"))

local BrainrotControlService = Loader.CreateService({
	Name = "BrainrotControlService",
})

local controlEvent
local dunkSequenceEvent
local BrainrotService

local function onControlRequest(player, brainrotName)
	if typeof(brainrotName) ~= "string" then return end
	if #brainrotName > 100 then return end

	BrainrotService = BrainrotService or Loader.GetService("BrainrotService")
	if not BrainrotService or not BrainrotService.FindTemplate then return end

	-- Valide que le brainrot existe réellement (sécurité anti-typo).
	local template = BrainrotService:FindTemplate(brainrotName)
	if not template or not template:IsA("Model") then return end

	local char = player.Character
	if not char or not char:FindFirstChild("HumanoidRootPart") then return end

	-- Calcule la WalkSpeed cible (SpeedLevel + gamepass Speed12X) et l'applique
	-- directement sur le Humanoid (côté serveur, donc répliqué).
	local speedLevelVal = player:FindFirstChild("SpeedLevel")
	local targetWalkSpeed = SpeedConfig.GetSpeedForLevel(speedLevelVal and speedLevelVal.Value or 0)
	local DataService = Loader.GetService("DataService")
	if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "Speed12X") then
		targetWalkSpeed = targetWalkSpeed * GamepassConfig.SPEED_1_2X_MULT
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = targetWalkSpeed
		hum.JumpPower = 55
		hum.UseJumpPower = true
	end

	-- TRANSFORMATION CÔTÉ SERVEUR : weld le mesh brainrot sur le HRP du joueur
	-- et cache son corps original. Répliqué à tous les clients.
	PlayerBrainrotTransform.Apply(player, template.Name)

	-- Déclenche aussi la phase "BrainrotPicked" côté client pour les ajustements
	-- UI/caméra (cache la TopBar, applique la caméra Custom, etc.).
	_G.DunkSequenceInProgress = true
	dunkSequenceEvent:FireClient(player, "BrainrotPicked", {
		BrainrotName = template.Name,
		WalkSpeed = targetWalkSpeed,
		JumpPower = 55,
	})
end

local function onPlayerRemoving(player)
	PlayerBrainrotTransform.Remove(player)
end

function BrainrotControlService:Init()
	controlEvent = RemotesAPI.GetEvent("ChatControlBrainrotEvent")
	dunkSequenceEvent = RemotesAPI.GetEvent("DunkSequenceEvent")
end

function BrainrotControlService:Start()
	BrainrotService = Loader.GetService("BrainrotService")
	controlEvent.OnServerEvent:Connect(onControlRequest)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	print("[BrainrotControlService] Prêt")
end

return BrainrotControlService

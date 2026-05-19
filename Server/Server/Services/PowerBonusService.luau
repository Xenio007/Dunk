--[[
	PowerBonusService
	Écoute le `PowerBonusClaimEvent` envoyé par le client quand il clique sur le
	ButtonPurpleClick. Ajoute un bonus de Power au joueur (2x le PowerPerLift
	du poids équipé, multiplié par le gamepass PowerX2 si actif), puis fire
	`AddPowerEvent:FireClient(player, gain, true)` pour que le popup
	(PowerPopupController) s'affiche automatiquement.

	Le second argument `isBonus=true` permet au PowerBonusButtonController
	de ne PAS réincrémenter son compteur de reps quand un bonus est claim.
--]]

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader        = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI    = require(ReplicatedStorage.Shared.RemotesAPI)
local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local PowerBonusService = Loader.CreateService({
	Name = "PowerBonusService",
})

-- Anti-spam clic.
local CLAIM_COOLDOWN = 0.5
-- Multiplicateur du gain par rapport à un lift normal.
local BONUS_MULT     = 2
local lastClaim      = {}

local addPowerEvent
local powerBonusEvent
local DataService

local function onClaim(player)
	local now = tick()
	local last = lastClaim[player.UserId] or 0
	if now - last < CLAIM_COOLDOWN then return end
	lastClaim[player.UserId] = now

	if not DataService then return end

	local weightName = DataService:GetEquippedWeight(player)
	if typeof(weightName) ~= "string" or weightName == "" then return end

	local config = WeightsConfig.ByName[weightName]
	if not config or not config.PowerPerLift then return end

	local yeetPower = player:FindFirstChild("YeetPower")
	if not yeetPower then return end

	-- Gamepass PowerX2 : double le bonus aussi (cohérent avec le gain normal).
	local powerMult = 1
	if DataService.HasGamepass and DataService:HasGamepass(player, "PowerX2") then
		powerMult = GamepassConfig.POWER_X2_MULT
	end
	local gain = config.PowerPerLift * BONUS_MULT * powerMult

	yeetPower.Value = yeetPower.Value + gain
	-- 2e arg `true` => bonus : déclenche le popup mais le client skipe le
	-- compteur de reps pour ne pas reboucler.
	addPowerEvent:FireClient(player, gain, true)
end

function PowerBonusService:Init()
	powerBonusEvent = RemotesAPI.GetEvent("PowerBonusClaimEvent")
	addPowerEvent   = RemotesAPI.GetEvent("AddPowerEvent")
end

function PowerBonusService:Start()
	DataService = Loader.GetService("DataService")

	powerBonusEvent.OnServerEvent:Connect(onClaim)
	Players.PlayerRemoving:Connect(function(p)
		lastClaim[p.UserId] = nil
	end)

	print(string.format("[PowerBonusService] Prêt (bonus = %dx PowerPerLift)", BONUS_MULT))
end

return PowerBonusService

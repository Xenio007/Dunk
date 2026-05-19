--[[
	KickZoneController
	Quand le joueur se trouve dans la zone Workspace.Spawn.Areas.KickReady :
	- Affiche le bouton DunkButton
	- Cache l'inventaire/Backpack de Roblox
	- Déséquipe tout tool et empêche d'équiper

	Migration 1:1 de StarterPlayerScripts.KickZoneHandler.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local KickZoneController = Loader.CreateController({
	Name = "KickZoneController",
})

local function isPointInsidePart(point, part)
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(localPoint.X) <= half.X
		and math.abs(localPoint.Y) <= half.Y
		and math.abs(localPoint.Z) <= half.Z
end

function KickZoneController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[KickZoneController] MainGui introuvable dans PlayerGui après 30s")
		return
	end
	local dunkButton = mainGui:WaitForChild("DunkButton")

	-- Référence au satchel custom (hotbar) : on le cache quand le joueur est
	-- dans la KickReady pour que l'UI ne montre plus d'inventaire.
	local function getSatchelHotbar()
		return playerGui:FindFirstChild("SatchelHotbar")
	end
	local function getSatchelInventory()
		return playerGui:FindFirstChild("SatchelInventory")
	end
	local function setSatchelVisible(visible)
		local hb = getSatchelHotbar()
		if hb then hb.Enabled = visible end
		if not visible then
			-- Force-ferme le panneau d'inventaire s'il était ouvert.
			local inv = getSatchelInventory()
			if inv then inv.Enabled = false end
		end
	end

	local dunkUIScale = dunkButton:FindFirstChildOfClass("UIScale")
	if not dunkUIScale then
		dunkUIScale = Instance.new("UIScale")
		dunkUIScale.Parent = dunkButton
	end
	local hoverTweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local NORMAL_SCALE = dunkUIScale.Scale
	local HOVER_SCALE = NORMAL_SCALE * 0.9

	dunkButton.MouseEnter:Connect(function()
		TweenService:Create(dunkUIScale, hoverTweenInfo, { Scale = HOVER_SCALE }):Play()
	end)
	dunkButton.MouseLeave:Connect(function()
		TweenService:Create(dunkUIScale, hoverTweenInfo, { Scale = NORMAL_SCALE }):Play()
	end)

	local spawnFolder = Workspace:WaitForChild("Spawn")
	local areas = spawnFolder:WaitForChild("Areas")
	local kickReady = areas:WaitForChild("KickReady")

	local inKickZone = false
	local characterConnections = {}

	local function unequipAndReturnTool(character, tool)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:UnequipTools()
		end
		if tool and tool.Parent == character then
			if player:FindFirstChild("Backpack") then
				tool.Parent = player.Backpack
			end
		end
	end

	local function onEnterZone()
		if inKickZone then return end
		inKickZone = true

		-- Flag global lu par SatchelController : bloque les appels à EquipTool
		-- à la source pour éviter les boucles equip/unequip qui crashent Studio.
		_G.SatchelEquipBlocked = true

		if not _G.DunkSequenceInProgress then
			dunkButton.Visible = true
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)

		-- Cache le satchel custom : le joueur ne doit ni voir ni prendre un
		-- tool en main tant qu'il est dans la KickReady.
		setSatchelVisible(false)

		-- Ne pas déséquiper le tool si le joueur vient de gagner un brainrot.
		if _G.DunkKeepEquipped then return end

		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:UnequipTools()
			end
			for _, child in ipairs(character:GetChildren()) do
				if child:IsA("Tool") then
					if player:FindFirstChild("Backpack") then
						child.Parent = player.Backpack
					end
				end
			end
		end
	end

	local function onExitZone()
		if not inKickZone then return end
		inKickZone = false

		_G.SatchelEquipBlocked = false

		dunkButton.Visible = false
		-- La Backpack Roblox native reste désactivée : c'est le SatchelController
		-- qui gère l'inventaire visuel.
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)

		-- Réaffiche le satchel custom quand le joueur sort de la zone.
		setSatchelVisible(true)
	end

	local function hookCharacter(character)
		for _, conn in ipairs(characterConnections) do
			conn:Disconnect()
		end
		table.clear(characterConnections)

		table.insert(characterConnections, character.ChildAdded:Connect(function(child)
			if not inKickZone then return end
			if not child:IsA("Tool") then return end
			-- Pendant la séquence Dunk, on laisse le joueur équiper son
			-- brainrot fraîchement gagné.
			if _G.DunkSequenceInProgress or _G.DunkKeepEquipped then return end
			-- Renvoie le tool immédiatement (sans task.defer) pour éviter
			-- d'empiler des callbacks si le joueur spam une touche.
			unequipAndReturnTool(character, child)
		end))
	end

	if player.Character then
		hookCharacter(player.Character)
	end
	player.CharacterAdded:Connect(hookCharacter)

	RunService.Heartbeat:Connect(function()
		local character = player.Character
		if not character then
			if inKickZone then onExitZone() end
			return
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			if inKickZone then onExitZone() end
			return
		end

		if isPointInsidePart(hrp.Position, kickReady) then
			if not inKickZone then
				onEnterZone()
			elseif not _G.DunkSequenceInProgress and not dunkButton.Visible then
				-- Le DunkLuckyBlockController vient de finir la séquence, on
				-- remet le bouton si le joueur est toujours dans la zone.
				dunkButton.Visible = true
			end
		else
			if inKickZone then
				onExitZone()
			end
		end
	end)

	dunkButton.Visible = false
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)

	print("[KickZoneController] Script initialisé!")
end

return KickZoneController

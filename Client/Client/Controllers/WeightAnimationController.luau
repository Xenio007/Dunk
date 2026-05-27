--[[
	WeightAnimationController
	Quand le joueur équipe un weight tool :
	1. Freeze le joueur (pas de mouvement ni de saut) pour que la pose de
	   lift soit propre et que la caméra ne dérive pas pendant l'animation.
	2. Joue le son de cycle quand le serveur signale un AddPower.
	Quand le joueur déséquipe le tool, tout revient à la normale.

	Attachement du Handle : il n'y a aucun code de placement côté client.
	Le Handle est attaché à la RightHand par le Motor6D RightGrip natif que
	Roblox crée à Tool.Equipped. Cette jointure est simulée localement par
	chaque client (latence zéro pour le propriétaire ET pour les spectateurs)
	et répliquée par le pipeline Tool standard. tool.Grip définit l'offset
	du Handle relatif à la main droite.

	Note : la lecture de l'animation de lift et le calcul des cycles de gain
	de Power sont 100% côté SERVEUR (WeightService). Ce controller ne joue
	PLUS l'animation localement et n'envoie PLUS le AddPowerEvent au serveur.
	Le serveur déclenche addPowerEvent:FireClient à chaque cycle, ce qui
	fait jouer le son ici.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local WeightAnimationController = Loader.CreateController({
	Name = "WeightAnimationController",
})

local BASE_WALK_SPEED = 22
local BASE_JUMP_POWER = 50
local BASE_JUMP_HEIGHT = 7.2
local EQUIP_COOLDOWN = 0.3 -- anti-spam d'équipement rapide

-- ===== Offset visuel du Handle (grip) =====
-- Décale le poids depuis la RightHand vers le centre du corps pour donner
-- l'illusion qu'il est tenu à deux mains (curl barbell). Modifier ça pour
-- ajuster pixel-perfect : X négatif = vers la gauche (centre du torse), Y
-- positif = remonté, Z positif = avance vers la caméra.
--
-- L'offset est appliqué PAR-DESSUS le tool.Grip d'origine du Tool (le Tool
-- conserve sa rotation de base, on ne fait que translater).
--
-- IMPORTANT : ce contrôleur tourne CÔTÉ CLIENT. La modification de tool.Grip
-- ici n'est visible QUE par le propriétaire du tool (pas par les autres
-- joueurs). Si vous voulez que tout le monde voie le centrage, dupliquez la
-- même ligne dans le script SERVEUR qui donne / configure le tool.
local WEIGHT_OFFSET = CFrame.new(-1, 0, 0)

local LIFT_SOUND_ID     = "rbxassetid://15675081158"
local LIFT_SOUND_VOLUME = 0.6

-- Son créé une seule fois, parenté à SoundService pour survivre au respawn
-- et éviter toute création/destruction par cycle (zéro coût en boucle).
local liftSound = SoundService:FindFirstChild("WeightLiftCycleSound")
if not liftSound then
	liftSound = Instance.new("Sound")
	liftSound.Name = "WeightLiftCycleSound"
	liftSound.SoundId = LIFT_SOUND_ID
	liftSound.Volume = LIFT_SOUND_VOLUME
	liftSound.Parent = SoundService
end

function WeightAnimationController:Start()
	local player = Players.LocalPlayer
	local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))
	local addPowerEvent = RemotesAPI.GetEvent("AddPowerEvent")

	-- État par session. Tout est réinitialisé au respawn.
	local currentToolName = nil
	local currentTool = nil
	local originalGrip = nil  -- backup du tool.Grip avant décalage, pour restoration
	local freezeConnection = nil
	local lastEquipTime = 0 -- clock du dernier setupTool réussi, pour le cooldown

	-- Connexions par character (CharacterAdded réinitialise cette liste). Évite
	-- la fuite qui était la cause probable des crashs après plusieurs respawns.
	local characterConns = {}

	local function disconnectCharacterConns()
		for _, c in ipairs(characterConns) do
			if c.Connected then c:Disconnect() end
		end
		table.clear(characterConns)
	end

	local function freezePlayer(humanoid)
		if not humanoid or not humanoid.Parent then return end
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0

		local character = humanoid.Parent
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp then
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			hrp.Anchored = true
		end
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end)

		-- Désactive tous les états qui déclenchent des animations par défaut
		-- (freefall, jump, climb...). Sans ça, si on équipe pendant qu'on saute
		-- ou qu'on tombe, l'anim Freefall du Humanoid se superpose au curl.
		pcall(function()
			for _, stateName in ipairs({
				"Freefall", "Jumping", "FallingDown", "Climbing",
				"Swimming", "Flying", "Ragdoll", "GettingUp",
				"PlatformStanding",
			}) do
				local st = Enum.HumanoidStateType[stateName]
				if st then humanoid:SetStateEnabled(st, false) end
			end
		end)

		if freezeConnection then
			freezeConnection:Disconnect()
			freezeConnection = nil
		end

		freezeConnection = RunService.Heartbeat:Connect(function()
			if not humanoid or not humanoid.Parent then
				if freezeConnection then freezeConnection:Disconnect() freezeConnection = nil end
				return
			end
			humanoid:Move(Vector3.zero)
		end)
	end

	local function unfreezePlayer(humanoid)
		if freezeConnection then
			freezeConnection:Disconnect()
			freezeConnection = nil
		end
		if humanoid and humanoid.Parent then
			local character = humanoid.Parent
			local hrp = character:FindFirstChild("HumanoidRootPart")
			if hrp then
				hrp.Anchored = false
			end
			humanoid.WalkSpeed = BASE_WALK_SPEED
			humanoid.JumpPower = BASE_JUMP_POWER
			humanoid.JumpHeight = BASE_JUMP_HEIGHT

			pcall(function()
				for _, stateName in ipairs({
					"Freefall", "Jumping", "FallingDown", "Climbing", "Swimming",
				}) do
					local st = Enum.HumanoidStateType[stateName]
					if st then humanoid:SetStateEnabled(st, true) end
				end
			end)
		end
	end

	local function applyGripOffset(tool)
		if not tool or not tool.Parent then return end
		-- Sauve le grip d'origine UNE SEULE FOIS pour pouvoir le restaurer
		-- proprement même si le tool est ré-équipé plusieurs fois.
		if originalGrip == nil then
			originalGrip = tool.Grip
		end
		tool.Grip = originalGrip * WEIGHT_OFFSET
	end

	local function restoreGripOffset()
		if currentTool and currentTool.Parent and originalGrip then
			currentTool.Grip = originalGrip
		end
		currentTool = nil
		originalGrip = nil
	end

	local function cleanup(humanoid)
		restoreGripOffset()
		currentToolName = nil
		if humanoid then
			unfreezePlayer(humanoid)
		end
	end

	local function setupTool(tool, humanoid)
		if not tool or not tool.Parent then return end
		if not humanoid or not humanoid.Parent then return end

		-- Ne traite QUE les weight tools connus.
		local animId = WeightsConfig.AnimationByWeight[tool.Name]
		if not animId then return end

		-- Anti-spam : si on a équipé il y a moins de EQUIP_COOLDOWN secondes,
		-- on retire silencieusement le tool pour annuler l'équipement.
		local now = os.clock()
		if now - lastEquipTime < EQUIP_COOLDOWN then
			pcall(function()
				humanoid:UnequipTools()
			end)
			return
		end
		lastEquipTime = now

		cleanup(humanoid)

		currentToolName = tool.Name
		currentTool = tool

		local character = humanoid.Parent
		if not character then return end

		-- Applique l'offset du grip pour centrer le Handle entre les deux mains.
		-- Le Tool relit tool.Grip pour ajuster le Motor6D RightGrip créé par
		-- Roblox à l'équipement, donc l'écriture prend effet immédiatement.
		applyGripOffset(tool)

		-- Freeze le perso pour que la pose de lift soit propre. Le Handle est
		-- déjà attaché à la main droite par le Motor6D RightGrip natif que Roblox
		-- vient de créer pour ce Tool : aucun travail de placement côté client,
		-- aucune latence, et réplication parfaite à tous les autres joueurs.
		freezePlayer(humanoid)
	end

	local function onCharacterAdded(character)
		-- Disconnect les connexions du character précédent AVANT de reset.
		disconnectCharacterConns()

		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then return end

		cleanup(nil)

		table.insert(characterConns, character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				setupTool(child, humanoid)
			end
		end))

		table.insert(characterConns, character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") and child.Name == currentToolName then
				cleanup(humanoid)
			end
		end))

		-- Si le character meurt / disparaît, on cleanup tout.
		table.insert(characterConns, humanoid.Died:Connect(function()
			cleanup(humanoid)
		end))

		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then
				setupTool(child, humanoid)
				break
			end
		end
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		disconnectCharacterConns()
		cleanup(nil)
	end)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	-- Le serveur conduit les cycles de lift et envoie addPowerEvent à chaque
	-- cycle. On joue ici le son associé, et seulement si on est actuellement
	-- en train de lift (pas pour les bonus du PowerBonusButtonController qui
	-- envoient le même event avec isBonus=true).
	addPowerEvent.OnClientEvent:Connect(function(_gain, isBonus)
		if isBonus then return end
		if not currentToolName then return end
		SoundService:PlayLocalSound(liftSound)
	end)
end

return WeightAnimationController

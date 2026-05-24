--[[
	WeightAnimationController
	Quand le joueur équipe un weight tool :
	1. Freeze le joueur (pas de mouvement ni de saut)
	2. Place le weight entre les mains (suivi RenderStepped)
	3. Joue le son de cycle quand le serveur signale un AddPower
	Quand le joueur déséquipe le tool, tout revient à la normale.

	Note : la lecture de l'animation de lift et le calcul des cycles de gain
	de Power sont maintenant 100% côté SERVEUR (WeightService). Ce controller
	ne joue PLUS l'animation localement et n'envoie PLUS le AddPowerEvent au
	serveur. Le serveur déclenche addPowerEvent:FireClient à chaque cycle, ce
	qui fait jouer le son ici. Conséquences positives :
	  - Tous les autres joueurs voient l'anim de lift correctement.
	  - Le tempo des cycles est contrôlé par le serveur (anti-cheat).
	  - Plus de risque de crash lié à la destruction concurrente du Tool /
	    Animation pendant qu'un AnimationTrack tournait côté client.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

-- UnreliableRemoteEvent pour le streaming haute-fréquence du CFrame du Handle.
-- Latence plus basse + pas de re-transmission qu'un RemoteEvent classique.
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local handleCFrameEvent = remotesFolder:WaitForChild("WeightHandleCFrameEvent")

local WeightAnimationController = Loader.CreateController({
	Name = "WeightAnimationController",
})

local BASE_WALK_SPEED = 22
local BASE_JUMP_POWER = 50
local BASE_JUMP_HEIGHT = 7.2
local EQUIP_COOLDOWN = 0.3 -- anti-spam d'équipement rapide

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

	local ANIM_BARBELL = WeightsConfig.ANIM_BARBELL

	-- Liste des poids qui sont des plaques/blocs (orientation différente :
	-- pas de rotation 90° autour de Y dans startBarbellFollow). Tous les autres
	-- sont des barres et reçoivent la rotation pour être horizontales.
	local PLATE_NAMES = {
		["Stone Block"] = true,
		["Copper Plate"] = true,
		["Iron Plate"] = true,
	}

	-- État par session. Tout est réinitialisé au respawn.
	local currentToolName = nil
	local freezeConnection = nil
	local currentWeld = nil
	local barbellHandle = nil      -- Handle de la barbell à tracker chaque frame
	local barbellFollowConn = nil  -- Connexion RunService pour le suivi temps réel
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

	local function removeRightGrip(character)
		local rightHand = character:FindFirstChild("RightHand")
		if rightHand then
			local grip = rightHand:FindFirstChild("RightGrip")
			if grip then grip:Destroy() end
		end
		local rightArm = character:FindFirstChild("Right Arm")
		if rightArm then
			local grip = rightArm:FindFirstChild("RightGrip")
			if grip then grip:Destroy() end
		end
	end

	local function stopBarbellFollow()
		if barbellFollowConn then
			barbellFollowConn:Disconnect()
			barbellFollowConn = nil
		end
		-- Sécurité historique : si une ancienne version du code avait ancré le
		-- Handle, on s'assure qu'il est désancré. La nouvelle implémentation
		-- n'ancre PLUS rien (cf. startBarbellFollow ci-dessous), pour éviter
		-- la contrainte Motor6D RightGrip + Handle ancré qui crashait le client.
		if barbellHandle and barbellHandle.Parent then
			pcall(function() barbellHandle.Anchored = false end)
		end
		barbellHandle = nil
	end

	-- Positionne un weight entre les deux mains chaque frame. Si `isPlate` est
	-- true, le weight est orienté comme un disque/plaque ; sinon comme une barre.
	local function startBarbellFollow(handle, character, isPlate)
		stopBarbellFollow()
		if not handle or not character then return end

		local leftHand = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")
		local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
		if not (leftHand and rightHand) then return end

		-- On mémorise le handle pour pouvoir le désancrer dans stopBarbellFollow
		barbellHandle = handle
		
		-- On l'ancre LOCALEMENT pour qu'il suive précisément sans être soumis à la gravité
		-- et sans interférer avec la physique du personnage.
		handle.Anchored = true

		local function placeNow()
			local lh = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")
			local rh = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
			if not lh or not rh then return end
			local midCFrame = lh.CFrame:Lerp(rh.CFrame, 0.5)
			local direction = (rh.Position - lh.Position)
			if direction.Magnitude > 0.01 then
				direction = direction.Unit
				local up = midCFrame.UpVector
				local look = direction:Cross(up).Unit
				local right = up:Cross(look).Unit
				local targetCFrame = CFrame.fromMatrix(midCFrame.Position, right, up)
				if isPlate then
					handle.CFrame = targetCFrame
				else
					handle.CFrame = targetCFrame * CFrame.Angles(0, math.rad(90), 0)
				end
			else
				handle.CFrame = midCFrame
			end
		end

		-- Placement initial immédiat : sans ça la barre apparait à la position
		-- Tool.Grip natif (main droite seule) pendant 1 frame avant que le
		-- RenderStepped ne la replace.
		placeNow()

		barbellFollowConn = RunService.RenderStepped:Connect(function()
			if not (handle and handle.Parent) or not (character and character.Parent) then
				stopBarbellFollow()
				return
			end
			placeNow()
		end)
	end

	-- ANCIENNE LOGIQUE supprimée : ancrer le Handle + réécrire son CFrame chaque
	-- frame entrait en conflit avec le Motor6D RightGrip créé automatiquement
	-- par Roblox à l'équipement, ce qui crashait le solveur physique du client.

	local function weldWeightToShoulders(tool, character)
		local handle = tool:FindFirstChild("Handle")
		if not handle then return end

		-- Pose un WeldConstraint LeftHand <-> Handle après un petit délai pour
		-- que la pose de lift ait positionné les bras correctement avant que
		-- le weld ne fige la position relative. Pas d'ancrage du Handle = pas
		-- de conflit avec le Motor6D RightGrip natif (donc plus de main toupie).
		-- Le RightGrip natif tient la main droite, notre weld tient la gauche :
		-- prise à deux mains visible localement et répliquée (WeldConstraint
		-- est répliqué par défaut, donc tous les joueurs voient le même résultat).
		task.delay(0.3, function()
			if not tool.Parent or tool.Parent ~= character then return end
			if handle:FindFirstChild("WeightLeftHandWeld") then return end

			local lh = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")
			if not lh then return end

			local weld = Instance.new("WeldConstraint")
			weld.Name = "WeightLeftHandWeld"
			weld.Part0 = lh
			weld.Part1 = handle
			weld.Parent = handle
		end)
	end

	local function removeWeightWeld()
		stopBarbellFollow()
		if currentWeld then
			pcall(function() currentWeld:Destroy() end)
			currentWeld = nil
		end
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

	local function cleanup(humanoid)
		currentToolName = nil
		removeWeightWeld()
		-- Défense en profondeur : assure que `barbellHandle` est bien désancré
		-- même si removeWeightWeld n'a pas tout nettoyé.
		if barbellHandle and barbellHandle.Parent then
			pcall(function() barbellHandle.Anchored = false end)
			barbellHandle = nil
		end
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

		local character = humanoid.Parent
		if not character then return end

		-- Freeze IMMEDIATEMENT, avant le task.wait. Comme ça le perso ne peut
		-- plus bouger ni glisser pendant la frame d'attente.
		freezePlayer(humanoid)

		task.wait() -- laisse Roblox finaliser l'ajout du tool
		if not tool.Parent or tool.Parent ~= character then
			unfreezePlayer(humanoid)
			return
		end

		-- Le SERVEUR ancre + place le Handle entre les deux mains chaque frame.
		-- C'est répliqué à tous les clients (joueur local + spectateurs), donc
		-- tout le monde voit la barre bien centrée à deux mains. On ne fait
		-- plus rien côté client pour le placement.
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

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

		-- IMPORTANT : on n'ancre PLUS le Handle. Roblox crée automatiquement un
		-- Motor6D RightGrip entre RightHand et Handle quand le tool est équipé.
		-- Si le Handle est Anchored=true, ce Motor6D devient une contrainte
		-- physique invalide (RightHand libre + Handle ancré) qui crash le client.
		-- On laisse le Handle suivre la main naturellement via le RightGrip,
		-- positionné par Tool.Grip défini côté serveur.
		barbellHandle = handle

		barbellFollowConn = RunService.RenderStepped:Connect(function()
			-- No-op : le Handle suit la main droite via le Motor6D RightGrip créé
			-- automatiquement par Roblox à l'équipement (positionné par Tool.Grip).
			-- Avant on forçait son CFrame chaque frame pour le placer entre les
			-- deux mains, mais ça impliquait d'ancrer le Handle, ce qui crashait
			-- le solveur physique. On garde la connexion pour pouvoir la disconnecter
			-- proprement via stopBarbellFollow, mais elle ne fait plus rien.
			if not handle.Parent then
				if barbellFollowConn then
					barbellFollowConn:Disconnect()
					barbellFollowConn = nil
				end
			end
		end)
	end

	-- ANCIENNE LOGIQUE supprimée : ancrer le Handle + réécrire son CFrame chaque
	-- frame entrait en conflit avec le Motor6D RightGrip créé automatiquement
	-- par Roblox à l'équipement, ce qui crashait le solveur physique du client.

	local function weldWeightToShoulders(tool, character)
		local handle = tool:FindFirstChild("Handle")
		if not handle then return end

		local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
		if not rightHand then return end

		-- Défense en profondeur : on forçe Anchored=false sur le Handle ET tous
		-- les enfants du tool. Si pour quelque raison le Handle arrivait ancré
		-- (race condition, hot-reload depuis ancienne version), Roblox créerait
		-- un Motor6D RightGrip entre RightHand libre et Handle ancré → crash.
		pcall(function() handle.Anchored = false end)

		removeRightGrip(character)

		-- Neutralise la physique sur tout le tool. Tout reste désancré :
		-- Roblox positionne le tool via le Motor6D RightGrip (cf. Tool.Grip serveur).
		for _, part in ipairs(tool:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Massless = true
				part.Anchored = false
			end
		end

		local animId = WeightsConfig.AnimationByWeight[tool.Name]
		local isBarbell = (animId == ANIM_BARBELL)

		if isBarbell then
			startBarbellFollow(handle, character, false)
		else
			startBarbellFollow(handle, character, true)
		end
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
		weldWeightToShoulders(tool, character)

		-- L'animation de lift et le cycle de gain de Power sont joués par le
		-- SERVEUR (WeightService). Ce client se contente de freeze, weld et
		-- jouer le son sur addPowerEvent. Voir le top du fichier pour le pourquoi.
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

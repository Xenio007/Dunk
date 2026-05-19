--[[
	DunkCloneService
	Crée et orchestre un clone visuel du joueur lors d'une séquence Dunk PERFECT.

	Pipeline :
		1. SpawnClone(player) -> clone le character via :Clone() (tout anchored).
		2. AttachToBlock(clone, block, handName) -> alignement main->block via
		   PivotTo, pas de WeldConstraint (anchored = zéro saccade réseau).
		3. UpdateFlightPose(clone, blockCFrame) -> appelé chaque frame depuis
		   le LuckyBlockService pour suivre la trajectoire du block.
		4. DetachAndDrop(clone, dropDelay) -> bascule en ragdoll physique pour
		   la chute libre.
		5. StandUpAndRun(clone, targetPart, getSpeedFn) -> détruit le clone
		   ragdoll cassé et en spawn un neuf qui court en zigzag vers le target.
		6. BindContinuousSpeed(clone, getSpeedFn) -> sync WalkSpeed temps réel.
		7. Cleanup(clone) -> Destroy + cleanup connexions.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local DunkCloneService = Loader.CreateService({
	Name = "DunkCloneService",
})

-- ===== Constantes =====
local MAX_CLONE_LIFETIME = 60
local ZIGZAG_AMPLITUDE = 6
local ZIGZAG_FREQUENCY = 1.6
local ZIGZAG_WAYPOINT_COUNT = 14
-- Animation Idle au moment de l'attente.
local WAIT_ANIM_ID = "rbxassetid://507766388"
-- Distance d'arrêt avant le centre de KickReady. 0 = pile au centre.
-- Le clone s'arrête donc à l'intérieur de la zone KickReady, côté du joueur.
local STOP_DISTANCE_BEFORE_TARGET = 0
-- Offset du block dans la main droite : Y- = bout des doigts, Z- = devant.
local BLOCK_HAND_OFFSET = CFrame.new(0, -0.6, -0.5)

-- Paramètres pose "Superman" du clone derrière le lucky block.
-- Le block scalé fait ~3.9 studs cubique (LuckyBlocks.Basic, ScaleTo x2).
-- Le clone est placé à l'horizontale (tilt 90°) avec sa tête juste derrière
-- le block et ses deux bras tendus en avant qui touchent la face arrière.
--
-- Distance entre le HRP et le bord arrière du block (positif = derrière).
-- HRP est au centre du torse → tête à ~1.5 studs devant le HRP en R15,
-- bras tendus ajoutent ~2 studs de plus. Le block fait 3.9 studs (= halfSize
-- 1.95). On veut que le bout des mains (HRP + 1.5 tête + 2 bras = 3.5)
-- atteigne pile la face arrière du block. Donc HRP à ~5.4 studs derrière
-- le centre du block (1.95 + 3.5 = 5.45).
local SUPERMAN_HRP_OFFSET = 5.4
-- Hauteur du HRP par rapport au centre du block. 0 = aligné avec le centre.
-- Le clone est presque pile au niveau du centre du block.
local SUPERMAN_VERTICAL_OFFSET = 0
-- Tilt 90° = corps strictement horizontal (pose Superman vraie).
local SUPERMAN_TILT_ANGLE = math.rad(-90)

-- Joints à ragdoll (les principaux uniquement).
local RAGDOLL_JOINTS = {
	Neck = true, Waist = true,
	LeftShoulder = true, RightShoulder = true,
	LeftElbow = true, RightElbow = true,
	LeftHip = true, RightHip = true,
	LeftKnee = true, RightKnee = true,
}

local activeClones = {}

-- ===== Helpers internes =====

local function applyRagdoll(clone)
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.AutoRotate = false
	end

	local createdConstraints = {}
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			local motor = descendant
			if RAGDOLL_JOINTS[motor.Name] and motor.Part0 and motor.Part1 then
				local a0 = Instance.new("Attachment")
				a0.CFrame = motor.C0
				a0.Parent = motor.Part0

				local a1 = Instance.new("Attachment")
				a1.CFrame = motor.C1
				a1.Parent = motor.Part1

				local bsc = Instance.new("BallSocketConstraint")
				bsc.Attachment0 = a0
				bsc.Attachment1 = a1
				bsc.LimitsEnabled = true
				bsc.UpperAngle = 35
				bsc.TwistLimitsEnabled = true
				bsc.TwistLowerAngle = -25
				bsc.TwistUpperAngle = 25
				bsc.Restitution = 0
				bsc.Parent = motor.Part0

				table.insert(createdConstraints, { bsc = bsc, a0 = a0, a1 = a1, motor = motor, wasEnabled = motor.Enabled })
				motor.Enabled = false
			end
		end
	end

	-- Désanchore les parts pour la chute physique.
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = true
			descendant.Massless = false
		end
	end

	return createdConstraints
end

local function stripExtras(clone)
	for _, child in ipairs(clone:GetChildren()) do
		if child:IsA("Tool") or child:IsA("Backpack") then
			child:Destroy()
		end
	end
end

-- Désactive les états du Humanoid qui peuvent faire tomber/ragdoller le clone
-- même à grande vitesse (FallingDown, Ragdoll, PlatformStanding...). Sans ça,
-- au-dessus d'une certaine WalkSpeed le moteur déclenche FallingDown et le
-- character bascule au sol pendant la course.
local function lockCloneHumanoidStates(humanoid)
	if not humanoid then return end
	pcall(function()
		for _, stateName in ipairs({
			"FallingDown", "Ragdoll", "PlatformStanding",
		}) do
			local st = Enum.HumanoidStateType[stateName]
			if st then humanoid:SetStateEnabled(st, false) end
		end
	end)
	humanoid.BreakJointsOnDeath = false
end

-- Prépare un clone désancré pour pouvoir courir à très haute vitesse sans
-- basculer. À grande WalkSpeed, le système physique du Humanoid accélère le
-- HRP brutalement, ce qui fait tomber/coucher le character si :
--   - la masse est répartie sur tout le corps (chaque membre a son propre
--     poids qui rebondit sur les hanches),
--   - les parts ont une friction non triviale qui crée du couple en avant,
--   - la collision corporelle accroche le sol à chaque pas.
-- On rend toutes les parts du corps massless sauf le HRP, on supprime les
-- collisions corps-corps, et on met une friction quasi nulle pour que la
-- locomotion soit propre même à ~150-180 walkspeed.
local function preparePhysicsForRunning(clone)
	local hrp = clone:FindFirstChild("HumanoidRootPart")
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			if d == hrp then
				d.Massless = false
				d.CanCollide = true
			else
				-- Les membres : massless + non collidables entre eux. Le Humanoid
				-- garde un Hip-based controller stable car seul le HRP a de la masse.
				d.Massless = true
				d.CanCollide = false
			end
			-- Friction quasi nulle : densité 1 pour le HRP / 0.7 pour les membres,
			-- friction 0.3, elasticité 0. Évite que les pieds attrapent le sol à
			-- haute vitesse et fassent basculer le character vers l'avant.
			local density = (d == hrp) and 1.0 or 0.01
			d.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0, 1, 1)
		end
	end
end

-- ===== API publique =====

function DunkCloneService:SpawnClone(player)
	assert(player and player.Character, "DunkCloneService:SpawnClone : player et character requis")
	local sourceChar = player.Character
	local sourceHRP = sourceChar:FindFirstChild("HumanoidRootPart")
	if not sourceHRP then return nil end

	-- Force Archivable=true pour permettre le clone (Roblox bloque par défaut).
	local originalArchivable = {}
	originalArchivable[sourceChar] = sourceChar.Archivable
	sourceChar.Archivable = true
	for _, descendant in ipairs(sourceChar:GetDescendants()) do
		originalArchivable[descendant] = descendant.Archivable
		descendant.Archivable = true
	end

	local clone = sourceChar:Clone()

	for inst, val in pairs(originalArchivable) do
		if inst.Parent then inst.Archivable = val end
	end

	if not clone then
		warn("[DunkCloneService] Le character n'a pas pu être cloné")
		return nil
	end
	clone.Name = "DunkClone_" .. player.Name

	-- Garde le script Animate pour les anims Idle/Walk/Run après stand-up.
	for _, child in ipairs(clone:GetChildren()) do
		if (child:IsA("LocalScript") or child:IsA("Script")) and child.Name ~= "Animate" then
			child:Destroy()
		end
	end
	stripExtras(clone)

	-- Toutes parts ANCHORED par défaut. Mode anchored = zéro saccade pendant le vol.
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	clone:PivotTo(sourceHRP.CFrame)
	clone.Parent = Workspace

	Debris:AddItem(clone, MAX_CLONE_LIFETIME)

	activeClones[clone] = {
		connections = {},
		constraints = nil,
		finished = false,
		animateScript = clone:FindFirstChild("Animate"),
	}

	local info = activeClones[clone]
	if info.animateScript then info.animateScript.Disabled = true end

	return clone
end

-- Met les bras du clone en pose Superman : tendus en avant, paumés vers le bas.
-- On modifie les Motor6D ShoulderC0 pour faire pivoter les bras de ~90° vers
-- l'avant (autour de l'axe X local du torse). Compatible R6 (Right Shoulder /
-- Left Shoulder) et R15 (RightShoulder / LeftShoulder, sur UpperTorso).
local function applySupermanArmPose(clone)
	local info = activeClones[clone]
	if not info then return end
	info.armPoseSaved = info.armPoseSaved or {}
	local saved = info.armPoseSaved

	-- R15 : RightShoulder/LeftShoulder sur UpperTorso, parents directs des UpperArm.
	-- R6  : Right Shoulder/Left Shoulder sur Torso, parents directs des Arm.
	local motorsByName = {}
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("Motor6D") then
			motorsByName[d.Name] = d
		end
	end

	local function setShoulder(motor, sideSign)
		-- sideSign : +1 droite, -1 gauche.
		if not motor then return end
		if saved[motor] == nil then
			saved[motor] = motor.C0
		end
		-- Rotation autour de l'axe X local : -90° envoie le bras vers l'avant.
		-- On garde la translation (origine de l'épaule) mais remplace la rotation.
		local origin = motor.C0.Position
		motor.C0 = CFrame.new(origin) * CFrame.Angles(-math.rad(90), 0, 0)
	end

	-- R15 d'abord (UpperArm), R6 fallback (Arm).
	setShoulder(motorsByName["RightShoulder"], 1)
	setShoulder(motorsByName["LeftShoulder"], -1)
	-- R6 : noms avec espace
	setShoulder(motorsByName["Right Shoulder"], 1)
	setShoulder(motorsByName["Left Shoulder"], -1)
end

-- Mémorise l'offset main->HRP pour les updates de vol. Applique aussi la pose
-- des bras en "Superman" pour que les deux bras soient tendus vers l'avant.
function DunkCloneService:AttachToBlock(clone, block, handName)
	local info = activeClones[clone]
	if not info then return end
	handName = handName or "RightHand"

	local blockPart = block and (block:IsA("BasePart") and block or block.PrimaryPart)
	if not blockPart then return end

	local hand = clone:FindFirstChild(handName) or clone:FindFirstChild("RightArm")
	if not hand then return end

	local hrp = clone:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	info.handToHRP = hand.CFrame:ToObjectSpace(hrp.CFrame)
	info.handName = hand.Name

	-- Applique la pose Superman des bras (tendus vers l'avant). Doit être fait
	-- une fois ici, les Motor6D conservent ces C0 modifiés pendant tout le vol.
	applySupermanArmPose(clone)
end

-- Met à jour la pose du clone : il est positionné derrière le block, suspendu
-- en l'air, en POSE SUPERMAN (corps horizontal, tête vers le block, deux bras
-- tendus en avant qui touchent la face arrière du block).
function DunkCloneService:UpdateFlightPose(clone, blockCFrame)
	local info = activeClones[clone]
	if not info then return end
	local hrp = clone:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp.Parent then return end

	-- Détermine la direction "avant" du block (vers où il vole) : on prend le
	-- vecteur de la trajectoire en utilisant la différence frame-à-frame du
	-- block. Si pas dispo (première frame), fallback sur axe -X (le bloc se
	-- déplace toujours vers les X négatifs).
	local blockPos = blockCFrame.Position
	local flightDir
	if info.lastBlockPos then
		local delta = blockPos - info.lastBlockPos
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude > 0.05 then
			flightDir = flat.Unit
		end
	end
	if not flightDir then
		flightDir = Vector3.new(-1, 0, 0)
	end
	info.lastBlockPos = blockPos

	-- HRP placé DERRIÈRE le block (opposé à la direction de vol), à une
	-- distance qui laisse le bout des bras tendus arriver pile sur la face
	-- arrière du block.
	local hrpPos = blockPos
		- flightDir * SUPERMAN_HRP_OFFSET
		+ Vector3.new(0, SUPERMAN_VERTICAL_OFFSET, 0)

	-- Le clone regarde dans la direction de vol (vers le block). On construit
	-- le CFrame pour que le LookVector du HRP soit aligné avec flightDir, puis
	-- on tilt de -90° sur l'axe X local pour mettre le corps à l'horizontale
	-- (pose superman). Le tilt fait que le LookVector pointe vers le bas dans
	-- l'espace local, donc on doit pencher en sens négatif sur X.
	local newHrpCF = CFrame.lookAt(hrpPos, hrpPos + flightDir)
	                * CFrame.Angles(SUPERMAN_TILT_ANGLE, 0, 0)

	local pivotDelta = newHrpCF * hrp.CFrame:Inverse()
	clone:PivotTo(pivotDelta * clone:GetPivot())
end

-- Bascule en "chute" : le clone se laisse tomber au sol via raycast à sa
-- position courante. Plus de ragdoll - juste une téléportation propre debout
-- au sol. À ce moment-là le clone est CACHÉ (transparency 1) jusqu'au
-- StandUpAndRun qui le supprimera et en spawnera un nouveau.
function DunkCloneService:DetachAndDrop(clone, dropDelay)
	local info = activeClones[clone]
	if not info then return end
	dropDelay = math.max(0, dropDelay or 0)

	task.delay(dropDelay, function()
		if not activeClones[clone] then return end
		-- Stoppe le suivi du block.
		info.handToHRP = nil
		info.detached = true
		-- Cache le clone pour qu'on ne le voit pas planer en l'air.
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Transparency = 1
			elseif d:IsA("Decal") or d:IsA("Texture") then
				d.Transparency = 1
			end
		end
	end)
end

-- Spawn un NOUVEAU clone à la position donnée (au sol) puis lance directement
-- la course en zigzag vers le target. C'est la fonction utilisée après la wave
-- pour faire courir un clone propre depuis la position où l'ancien clone est
-- tombé (impactPos du block).
function DunkCloneService:SpawnAndRun(player, spawnPos, targetPart, getSpeedFn)
	if not player or not targetPart or not targetPart:IsA("BasePart") then return end
	if not spawnPos then return end

	local newClone = self:SpawnClone(player)
	if not newClone then return end

	local newHRP = newClone:FindFirstChild("HumanoidRootPart")
	local newHum = newClone:FindFirstChildOfClass("Humanoid")
	if not newHRP or not newHum then
		self:Cleanup(newClone)
		return
	end

	-- DÉSANCHORE pour que le humanoid puisse marcher (SpawnClone met tout anchored)
	-- + prépare la répartition de masse / friction pour ne pas basculer à très
	-- haute vitesse (jusqu'à ~180 walkspeed avec Speed12X au max).
	preparePhysicsForRunning(newClone)

	-- Mesure pieds->HRP pour le placement.
	local function getCloneFootOffset(c)
		local h = c:FindFirstChild("HumanoidRootPart")
		if not h then return 2.5 end
		local minY = math.huge
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("BasePart") then
				local cf = d.CFrame
				local hx, hy, hz = d.Size.X * 0.5, d.Size.Y * 0.5, d.Size.Z * 0.5
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local wp = cf * Vector3.new(sx*hx, sy*hy, sz*hz)
							if wp.Y < minY then minY = wp.Y end
						end
					end
				end
			end
		end
		if minY == math.huge then return 2.5 end
		return h.Position.Y - minY
	end

	-- Position le clone au sol à la position spawnPos.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { newClone }
	local ray = workspace:Raycast(
		spawnPos + Vector3.new(0, 50, 0),
		Vector3.new(0, -200, 0),
		rayParams
	)
	local groundY = ray and ray.Position.Y or spawnPos.Y
	local footOffset = getCloneFootOffset(newClone)
	local targetY = groundY + footOffset + 0.5

	-- Direction de course : vers le target (KickReady).
	local kickReadyCenter = targetPart.Position
	local toCenter = Vector3.new(
		kickReadyCenter.X - spawnPos.X, 0, kickReadyCenter.Z - spawnPos.Z
	)
	local forwardDir
	if toCenter.Magnitude < 1e-3 then
		forwardDir = Vector3.new(-1, 0, 0)
	else
		forwardDir = toCenter.Unit
	end

	newHRP.CFrame = CFrame.lookAt(
		Vector3.new(spawnPos.X, targetY, spawnPos.Z),
		Vector3.new(spawnPos.X, targetY, spawnPos.Z) + forwardDir
	)
	newHRP.AssemblyLinearVelocity = Vector3.zero
	newHRP.AssemblyAngularVelocity = Vector3.zero

	local newInfo = activeClones[newClone]
	if newInfo and newInfo.animateScript and newInfo.animateScript.Parent then
		newInfo.animateScript.Disabled = false
	end

	-- Verrouille les états Humanoid pour éviter le FallingDown / Ragdoll
	-- déclenchés automatiquement par le moteur à haute vitesse.
	lockCloneHumanoidStates(newHum)

	local animator = newHum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = newHum
	end
	local runAnim = Instance.new("Animation")
	runAnim.AnimationId = "rbxassetid://507767714"
	local okLoad, runTrack = pcall(function() return animator:LoadAnimation(runAnim) end)
	if okLoad and runTrack then
		runTrack.Looped = true
		runTrack.Priority = Enum.AnimationPriority.Movement
		runTrack:Play(0.1)
	else
		runTrack = nil
	end

	task.wait(0.05)
	newHum:ChangeState(Enum.HumanoidStateType.Running)

	local sideDir = Vector3.new(-forwardDir.Z, 0, forwardDir.X)
	local endPos = kickReadyCenter - forwardDir * STOP_DISTANCE_BEFORE_TARGET

	local waypoints = {}
	for i = 1, ZIGZAG_WAYPOINT_COUNT do
		local t = i / ZIGZAG_WAYPOINT_COUNT
		local basePos = newHRP.Position:Lerp(endPos, t)
		local endDamp = math.clamp((1 - t) * 1.5, 0, 1)
		local lateralOffset = math.sin(t * math.pi * ZIGZAG_FREQUENCY * 2) * ZIGZAG_AMPLITUDE * endDamp
		table.insert(waypoints, basePos + sideDir * lateralOffset)
	end
	table.insert(waypoints, endPos)

	-- Suivi des waypoints en CONTINU : on appelle Humanoid:Move(direction)
	-- chaque frame vers le waypoint courant. Dès qu'on est assez proche, on
	-- passe au suivant. Pas de MoveToFinished:Wait qui crée une pause de
	-- 0.3s entre chaque segment (et qui timeout si MoveTo ne peut pas finir).
	local WAYPOINT_REACHED_RADIUS = 4
	local currentIdx = 1
	local moveConn
	moveConn = RunService.Heartbeat:Connect(function()
		if not newClone.Parent or (newInfo and newInfo.finished) then
			if moveConn then moveConn:Disconnect() moveConn = nil end
			return
		end
		local speed = (type(getSpeedFn) == "function") and getSpeedFn() or 16
		newHum.WalkSpeed = math.max(0, speed)

		local target = waypoints[currentIdx]
		if not target then
			if moveConn then moveConn:Disconnect() moveConn = nil end
			return
		end

		local pos = newHRP.Position
		local toTarget = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
		local dist = toTarget.Magnitude

		if dist <= WAYPOINT_REACHED_RADIUS then
			currentIdx = currentIdx + 1
			if currentIdx > #waypoints then
				if moveConn then moveConn:Disconnect() moveConn = nil end
				-- Arrivé à la cible finale.
				newHum:Move(Vector3.zero, false)
				newHum.WalkSpeed = 0
				if newInfo then newInfo.arrivedAtTarget = true end
				newHum.AutoRotate = false
				local lookBackDir = -forwardDir
				newHRP.CFrame = CFrame.lookAt(newHRP.Position, newHRP.Position + lookBackDir)
				if runTrack then
					pcall(function() runTrack:Stop(0.2) end)
				end
				local waitAnimInst = Instance.new("Animation")
				waitAnimInst.AnimationId = WAIT_ANIM_ID
				local okWait, waitTrack = pcall(function()
					return animator:LoadAnimation(waitAnimInst)
				end)
				if okWait and waitTrack then
					waitTrack.Looped = true
					waitTrack.Priority = Enum.AnimationPriority.Idle
					waitTrack:Play(0.3)
				end
				return
			end
			target = waypoints[currentIdx]
			toTarget = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
			dist = toTarget.Magnitude
		end

		if dist > 1e-3 then
			newHum:Move(toTarget.Unit, false)
		else
			newHum:Move(Vector3.zero, false)
		end
	end)
	if newInfo then
		table.insert(newInfo.connections, moveConn)
	end

	return newClone
end

function DunkCloneService:StandUpAndRun(clone, targetPart, getSpeedFn)
	local info = activeClones[clone]
	if not info then return end
	if not targetPart or not targetPart:IsA("BasePart") then return end

	-- Récupère la position cible avant de détruire.
	local kickReadyCenter = targetPart.Position

	-- Récupère le player owner pour spawn un nouveau clone.
	local ownerName = clone.Name:gsub("^DunkClone_", "")
	local ownerPlayer = Players:FindFirstChild(ownerName)
	if not ownerPlayer or not ownerPlayer.Character then
		self:Cleanup(clone)
		return
	end

	-- Détruit l'ancien clone buggé.
	activeClones[clone] = nil
	if clone.Parent then clone:Destroy() end

	-- Spawn un NOUVEAU clone frais (pas de ragdoll, position propre).
	local newClone = self:SpawnClone(ownerPlayer)
	if not newClone then return end

	local newHRP = newClone:FindFirstChild("HumanoidRootPart")
	local newHum = newClone:FindFirstChildOfClass("Humanoid")
	if not newHRP or not newHum then
		self:Cleanup(newClone)
		return
	end

	-- DÉSANCHORE pour que le humanoid puisse marcher (SpawnClone met tout anchored).
	-- Même préparation physique que SpawnAndRun pour rester stable à grande vitesse.
	preparePhysicsForRunning(newClone)

	-- Position : devant le centre de KickReady, côté opposé (du côté de l'imp).
	-- Le nouveau clone spawn directement au sol en travers de la KickReady,
	-- prêt à courir.
	local spawnPos = ownerPlayer.Character.HumanoidRootPart.Position
	local toCenter = kickReadyCenter - spawnPos
	local flatToCenter = Vector3.new(toCenter.X, 0, toCenter.Z)
	if flatToCenter.Magnitude < 1e-3 then
		flatToCenter = Vector3.new(-1, 0, 0)
	end
	local forwardDir = flatToCenter.Unit

	-- Spawn le nouveau clone à ~50 studs devant le centre de KickReady
	-- (coté éloigné), pour qu'il coure VERS KickReady.
	local startPos = kickReadyCenter - forwardDir * 50

	-- Mesure pieds->HRP pour le placement.
	local function getCloneFootOffset(c)
		local h = c:FindFirstChild("HumanoidRootPart")
		if not h then return 2.5 end
		local minY = math.huge
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("BasePart") then
				local cf = d.CFrame
				local hx, hy, hz = d.Size.X * 0.5, d.Size.Y * 0.5, d.Size.Z * 0.5
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local wp = cf * Vector3.new(sx*hx, sy*hy, sz*hz)
							if wp.Y < minY then minY = wp.Y end
						end
				end
			end
			end
		end
		if minY == math.huge then return 2.5 end
		return h.Position.Y - minY
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { newClone }
	local ray = workspace:Raycast(
		startPos + Vector3.new(0, 50, 0),
		Vector3.new(0, -200, 0),
		rayParams
	)
	local groundY = ray and ray.Position.Y or kickReadyCenter.Y
	local footOffset = getCloneFootOffset(newClone)
	local targetY = groundY + footOffset + 0.5
	newHRP.CFrame = CFrame.lookAt(
		Vector3.new(startPos.X, targetY, startPos.Z),
		Vector3.new(startPos.X, targetY, startPos.Z) + forwardDir
	)
	newHRP.AssemblyLinearVelocity = Vector3.zero
	newHRP.AssemblyAngularVelocity = Vector3.zero

	local newInfo = activeClones[newClone]
	if newInfo and newInfo.animateScript and newInfo.animateScript.Parent then
		newInfo.animateScript.Disabled = false
	end

	-- Même protection pour le clone reconstruit dans StandUpAndRun.
	lockCloneHumanoidStates(newHum)

	local animator = newHum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = newHum
	end
	local runAnim = Instance.new("Animation")
	runAnim.AnimationId = "rbxassetid://507767714"
	local okLoad, runTrack = pcall(function() return animator:LoadAnimation(runAnim) end)
	if okLoad and runTrack then
		runTrack.Looped = true
		runTrack.Priority = Enum.AnimationPriority.Movement
		runTrack:Play(0.1)
	else
		runTrack = nil
	end

	task.wait(0.1)
	newHum:ChangeState(Enum.HumanoidStateType.Running)

	local sideDir = Vector3.new(-forwardDir.Z, 0, forwardDir.X)
	local endPos = kickReadyCenter - forwardDir * STOP_DISTANCE_BEFORE_TARGET

	local waypoints = {}
	for i = 1, ZIGZAG_WAYPOINT_COUNT do
		local t = i / ZIGZAG_WAYPOINT_COUNT
		local basePos = newHRP.Position:Lerp(endPos, t)
		local endDamp = math.clamp((1 - t) * 1.5, 0, 1)
		local lateralOffset = math.sin(t * math.pi * ZIGZAG_FREQUENCY * 2) * ZIGZAG_AMPLITUDE * endDamp
		table.insert(waypoints, basePos + sideDir * lateralOffset)
	end
	table.insert(waypoints, endPos)

	task.spawn(function()
		for _, wp in ipairs(waypoints) do
			if not newClone.Parent or (newInfo and newInfo.finished) then return end
			local speed = (type(getSpeedFn) == "function") and getSpeedFn() or 16
			newHum.WalkSpeed = math.max(1, speed)
			newHum:MoveTo(wp)
			newHum.MoveToFinished:Wait()
		end

		if not newClone.Parent then return end

		newHum:MoveTo(newHRP.Position)
		newHum.WalkSpeed = 0
		if newInfo then newInfo.arrivedAtTarget = true end

		newHum.AutoRotate = false
		local lookBackDir = -forwardDir
		newHRP.CFrame = CFrame.lookAt(newHRP.Position, newHRP.Position + lookBackDir)

		if runTrack then
			pcall(function() runTrack:Stop(0.2) end)
		end

		local waitAnimInst = Instance.new("Animation")
		waitAnimInst.AnimationId = WAIT_ANIM_ID
		local okWait, waitTrack = pcall(function()
			return animator:LoadAnimation(waitAnimInst)
		end)
		if okWait and waitTrack then
			waitTrack.Looped = true
			waitTrack.Priority = Enum.AnimationPriority.Idle
			waitTrack:Play(0.3)
		end
	end)

	return newClone
end

function DunkCloneService:BindContinuousSpeed(clone, getSpeedFn)
	local info = activeClones[clone]
	if not info then return end
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local conn = RunService.Heartbeat:Connect(function()
		if info.finished or not clone.Parent then return end
		if info.arrivedAtTarget then return end
		local speed = (type(getSpeedFn) == "function") and getSpeedFn() or 16
		humanoid.WalkSpeed = math.max(1, speed)
	end)
	table.insert(info.connections, conn)
end

function DunkCloneService:Cleanup(clone)
	local info = activeClones[clone]
	if not info then return end
	info.finished = true
	for _, conn in ipairs(info.connections) do
		if typeof(conn) == "RBXScriptConnection" then conn:Disconnect() end
	end
	activeClones[clone] = nil
	if clone and clone.Parent then
		clone:Destroy()
	end
end

-- ===== Lifecycle =====

function DunkCloneService:Init() end

function DunkCloneService:Start()
	Players.PlayerRemoving:Connect(function(player)
		for clone in pairs(activeClones) do
			if clone.Name == "DunkClone_" .. player.Name then
				self:Cleanup(clone)
			end
		end
	end)
	print("[DunkCloneService] Prêt")
end

return DunkCloneService

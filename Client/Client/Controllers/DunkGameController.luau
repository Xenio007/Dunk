--[[
	DunkGameController
	Mini-jeu de timing déclenché par le clic sur MainGui.DunkButton.

	Déroulement :
		1. Clic sur DunkButton -> cache le bouton, active DunkGame.
		2. La barre (DunkGame.Bar.MovingBar) se remplit de 0 à 1 puis redescend
		   en boucle (ping-pong).
		3. Le joueur clique à nouveau : on capture la valeur (fill) au moment du clic.
		4. Selon la valeur on affiche un grade dans DunkGame.Message :
			[0.95, 1.00] -> PERFECT
			[0.80, 0.949] -> EXCELLENT
			[0.60, 0.79] -> GREAT
			[0.40, 0.59] -> GOOD
			[0.20, 0.39] -> MID
			[0.00, 0.19] -> BAD
		5. Après un court délai, DunkGame est caché et DunkButton redevient visible
		   (seulement si le joueur est encore dans la zone KickReady).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local DunkGameController = Loader.CreateController({
	Name = "DunkGameController",
})

-- ===== Sons par grade =====
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local GRADE_SOUND = {
	BAD       = "rbxassetid://112094436418581",
	EXCELLENT = "rbxassetid://136993031050456",
	PERFECT   = "rbxassetid://136357088509992",
}

local function playGradeSound(gradeName)
	local id = GRADE_SOUND[gradeName]
	if not id then return end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = 1
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, math.max(s.TimeLength + 0.5, 5))
end

-- Animation jouée sur grade PERFECT (dunk explosif).
local AnimationCache = require(ReplicatedStorage.Shared:WaitForChild("AnimationCache"))
local PERFECT_ANIM_ID = "rbxassetid://137348437963307"
local PERFECT_TAKEOFF_TIME = 5.20   -- moment exact de l'impulsion (matche PERFECT_ROOT_PATH)
local PERFECT_ANIM_DURATION = PERFECT_TAKEOFF_TIME + 0.5  -- anim coupée 0.5s après l'impulsion
local PERFECT_ANIM_RELEASE_TIME = PERFECT_TAKEOFF_TIME + 0.35  -- release juste avant la fin

-- Trajectoire root motion : pas plus amples, mais reste maitrisable.
-- Phase de course rapide jusqu'à t=2.60, puis décélération progressive
-- de 2.90 à 3.70 (plant), arrêt complet de 3.70 à 4.50 (charge avant
-- l'impulsion). À partir de t=4.50, on bascule sur une PARABOLE PHYSIQUE
-- pure (gravité réaliste) au lieu de keyframes : voir getRootOffsetAt().
local PERFECT_ROOT_PATH = {
	{t=0.00, x=0,    y=0   },  -- dribble high
	{t=0.20, x=-0.5, y=0   },
	{t=0.45, x=-1.5, y=0   },  -- step back L
	{t=0.70, x=-2.2, y=0   },
	{t=0.95, x=-3.0, y=0   },  -- step back R
	{t=1.20, x=-3.3, y=0   },  -- gather
	{t=1.50, x=-1.5, y=0.15},  -- run R fwd
	{t=1.85, x=1.5,  y=0.15},
	{t=2.20, x=4.5,  y=0.15},
	{t=2.60, x=6.0,  y=0.15},  -- fin de la course rapide
	{t=2.90, x=7.0,  y=0.08},  -- début décélération
	{t=3.30, x=7.7,  y=0.02},  -- ralentissement
	{t=3.70, x=8.0,  y=0   },  -- plant : fin du ralentissement
	{t=4.10, x=8.0,  y=0   },  -- ARRÊT total (charge avant l'impulsion)
	{t=4.50, x=8.0,  y=0   },  -- fin de la charge, début impulsion physique
}

-- ===== PHYSIQUE DU SAUT (parabole réelle, mouvement réaliste) =====
-- Déroulement en 2 phases :
-- 1) EXTENSION (JUMP_START_TIME -> JUMP_TAKEOFF_TIME, durée EXTENSION_DUR)
--    Les jambes se déplient. Accélération de la vitesse de 0 jusqu'au max,
--    avec un easing quadratique (l'accélération augmente en cours de poussée
--    comme les jambes qui poussent de plus en plus fort).
-- 2) VOL BALISTIQUE (JUMP_TAKEOFF_TIME -> JUMP_END_TIME)
--    Parabole pure : x = vx*t, y = vy*t - 0.5*g*t².
local JUMP_START_TIME    = 4.50  -- début de l'extension (après la charge)
local JUMP_EXTENSION_DUR = 0.18  -- durée de l'extension des jambes
local JUMP_TAKEOFF_TIME  = JUMP_START_TIME + JUMP_EXTENSION_DUR  -- décollage réel
local JUMP_START_X       = 8.0   -- position x au début du saut
local JUMP_VX            = 28.0  -- vitesse horizontale au takeoff (studs/s)
local JUMP_VY            = 22.0  -- vitesse verticale au takeoff (studs/s)
local JUMP_GRAVITY       = 22.0  -- gravité (studs/s²)
local JUMP_END_TIME      = 5.70  -- fin de la trajectoire

local function easeInOutCubic(a)
	if a < 0.5 then return 4 * a * a * a end
	local f = 2 * a - 2
	return 0.5 * f * f * f + 1
end

-- Catmull-Rom interpolation between p1 and p2, with neighbours p0 and p3.
-- C1-continuous: no velocity jump at keyframe boundaries -> trajet ultra fluide.
local function catmullRom(p0, p1, p2, p3, t)
	local t2 = t * t
	local t3 = t2 * t
	return 0.5 * (
		(2 * p1)
		+ (-p0 + p2) * t
		+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
		+ (-p0 + 3 * p1 - 3 * p2 + p3) * t3
	)
end

local function getRootOffsetAt(time)
	-- Phase 1 (avant le saut) : interpolation Catmull-Rom sur les keyframes.
	if time < JUMP_START_TIME then
		local n = #PERFECT_ROOT_PATH
		if time <= PERFECT_ROOT_PATH[1].t then
			return PERFECT_ROOT_PATH[1].x, PERFECT_ROOT_PATH[1].y
		end
		local last = PERFECT_ROOT_PATH[n]
		if time >= last.t then return last.x, last.y end
		for i = 1, n - 1 do
			local a = PERFECT_ROOT_PATH[i]
			local b = PERFECT_ROOT_PATH[i + 1]
			if time >= a.t and time < b.t then
				local alpha = (time - a.t) / (b.t - a.t)
				local p0 = PERFECT_ROOT_PATH[math.max(1, i - 1)]
				local p1 = a
				local p2 = b
				local p3 = PERFECT_ROOT_PATH[math.min(n, i + 2)]
				local x = catmullRom(p0.x, p1.x, p2.x, p3.x, alpha)
				local y = catmullRom(p0.y, p1.y, p2.y, p3.y, alpha)
				return x, y
			end
		end
		return last.x, last.y
	end

	-- Phase 2 (extension des jambes) : vitesse passe de 0 au max progressivement.
	-- Modèle : accélération constante a = v_max / durée_extension. La vitesse
	-- v(t) = a*t croit linéairement, la position est l'intégrale = 0.5*a*t².
	-- C'est le mouvement RÉEL d'un objet poussé par une force constante depuis
	-- l'arrêt (loi de Newton F=ma). Pas de discontinuité de vitesse au décollage
	-- car la vitesse atteint exactement v_max à la fin de l'extension.
	if time < JUMP_TAKEOFF_TIME then
		local te = time - JUMP_START_TIME  -- temps depuis le début de l'extension
		local accelX = JUMP_VX / JUMP_EXTENSION_DUR
		local accelY = JUMP_VY / JUMP_EXTENSION_DUR
		local x = JUMP_START_X + 0.5 * accelX * te * te
		local y = 0.5 * accelY * te * te
		return x, y
	end

	-- Phase 3 (vol balistique) : parabole physique pure depuis le takeoff.
	-- La position et la vitesse au début de cette phase égalent exactement
	-- celles à la fin de la phase 2 -> mouvement parfaitement continu.
	local extEndX = JUMP_START_X + 0.5 * JUMP_VX * JUMP_EXTENSION_DUR
	local extEndY = 0.5 * JUMP_VY * JUMP_EXTENSION_DUR
	local dt = math.min(time, JUMP_END_TIME) - JUMP_TAKEOFF_TIME
	local x = extEndX + JUMP_VX * dt
	local y = extEndY + JUMP_VY * dt - 0.5 * JUMP_GRAVITY * dt * dt
	if y < 0 then y = 0 end
	return x, y
end

local perfectAnim -- Instance Animation pré-créée

local function getPerfectAnimation()
	-- Utilise le cache global : l'Animation est partagée et son contenu (KFS)
	-- a déjà été téléchargé par AssetPreloader au join, donc LoadAnimation est
	-- instantané.
	if perfectAnim then return perfectAnim end
	perfectAnim = AnimationCache.GetAnimation(PERFECT_ANIM_ID)
	return perfectAnim
end

local function loadPerfectTrack(character)
	if not character then return nil, nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return nil, nil end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Désactive le script natif Animate (Idle/Walk) pour ne pas écraser la pose.
	local animateScript = character:FindFirstChild("Animate")
	local animateWasEnabled
	if animateScript and animateScript:IsA("LocalScript") then
		animateWasEnabled = animateScript.Disabled == false
		animateScript.Disabled = true
	end

	-- Stoppe toutes les tracks en cours.
	for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
		pcall(function() t:Stop(0) end)
	end

	local track = animator:LoadAnimation(getPerfectAnimation())
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false

	local cleanup = function()
		if animateScript and animateWasEnabled then
			animateScript.Disabled = false
		end
	end
	return track, cleanup
end

-- ===== Séquence PERFECT complète (caméra côté + block dans main droite + dunk anim) =====
local function playPerfectSequence(player, gradeText, fill)
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	_G.DunkSequenceInProgress = true

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function() humanoid:UnequipTools() end)
	end

	-- Force le character à regarder vers -X (panier).
	local currentPos = hrp.Position
	hrp.CFrame = CFrame.lookAt(currentPos, currentPos + Vector3.new(-1, 0, 0))

	-- ===== Caméra : vue 45° côté, suit le joueur fluide pendant tout le shot.
	-- L'offset caméra est calculé UNE FOIS dans le repère local du joueur,
	-- puis réappliqué chaque frame en repartant de la position actuelle du HRP.
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable

	local cameraStartCFrame = hrp.CFrame
	-- Direction 45° côté droit + face = (Right + Look) normalisé.
	local angleDir = (cameraStartCFrame.RightVector + cameraStartCFrame.LookVector).Unit
	local CAM_DIST = 9    -- distance de la cam (rapprochée du joueur pour plus d'impact)
	local CAM_HEIGHT = 2  -- hauteur au-dessus du joueur
	local LOOK_HEIGHT = -1 -- point visé légèrement sous le joueur -> cam penchée vers le bas
	local sideOffset = angleDir * CAM_DIST + Vector3.new(0, CAM_HEIGHT, 0)

	local function applyCamera()
		local pos = hrp.Position
		local camPos = pos + sideOffset
		local camTarget = pos + Vector3.new(0, LOOK_HEIGHT, 0)
		camera.CFrame = CFrame.new(camPos, camTarget)
	end
	applyCamera()

	-- La cam suit le joueur jusqu'au takeoff puis reste FIGÉE (le joueur
	-- s'envole hors cadre, plus d'impact visuel).
	local cameraFrozen = false
	local frozenCamCFrame

	-- ===== Bandes noires cinématiques (letterbox) =====
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local letterboxGui
	if playerGui then
		letterboxGui = Instance.new("ScreenGui")
		letterboxGui.Name = "DunkLetterbox"
		letterboxGui.IgnoreGuiInset = true
		letterboxGui.ResetOnSpawn = false
		letterboxGui.DisplayOrder = 1000
		letterboxGui.Parent = playerGui

		local topBar = Instance.new("Frame")
		topBar.Name = "TopBar"
		topBar.BackgroundColor3 = Color3.new(0, 0, 0)
		topBar.BorderSizePixel = 0
		topBar.Size = UDim2.new(1, 0, 0.16, 0)
		topBar.Position = UDim2.new(0, 0, -0.16, 0)  -- start hors écran
		topBar.Parent = letterboxGui

		local bottomBar = Instance.new("Frame")
		bottomBar.Name = "BottomBar"
		bottomBar.BackgroundColor3 = Color3.new(0, 0, 0)
		bottomBar.BorderSizePixel = 0
		bottomBar.Size = UDim2.new(1, 0, 0.16, 0)
		bottomBar.Position = UDim2.new(0, 0, 1, 0)    -- start hors écran
		bottomBar.Parent = letterboxGui

		-- Slide-in fluide (0.35s)
		local TweenService = game:GetService("TweenService")
		local info = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(topBar, info, { Position = UDim2.new(0, 0, 0, 0) }):Play()
		TweenService:Create(bottomBar, info, { Position = UDim2.new(0, 0, 0.84, 0) }):Play()
	end

	local camConn = RunService.RenderStepped:Connect(function()
		if cameraFrozen and frozenCamCFrame then
			camera.CFrame = frozenCamCFrame
		else
			applyCamera()
		end
	end)

	local sequenceStart = os.clock()

	-- Au début du saut (t=4.20), fige la cam sur sa pose actuelle. La cam ne
	-- bouge plus pendant que le perso décolle et s'envole vers le panier.
	task.delay(JUMP_START_TIME, function()
		frozenCamCFrame = camera.CFrame
		cameraFrozen = true
	end)

	-- ===== Lucky block en main droite (PERFECT = un seul bras levé) =====
	local heldBlock
	local heldBlockConn
	local rightHand = character:FindFirstChild("RightHand")
	if rightHand then
		local template = ReplicatedStorage:FindFirstChild("LuckyBlocks")
		template = template and template:FindFirstChild("Basic")
		if template then
			heldBlock = template:Clone()
			heldBlock.Name = "DunkHeldBlock"

			if not heldBlock.PrimaryPart then
				for _, d in ipairs(heldBlock:GetDescendants()) do
					if d:IsA("BasePart") then
						heldBlock.PrimaryPart = d
						break
					end
				end
			end

			if heldBlock:IsA("Model") and heldBlock.PrimaryPart then
				local s = heldBlock:GetScale() or 1
				heldBlock:ScaleTo(s * 0.7)
			end

			for _, d in ipairs(heldBlock:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanTouch = false
					d.CanQuery = false
					d.Massless = true
				end
			end

			heldBlock.Parent = Workspace

			local released = false
			heldBlockConn = RunService.RenderStepped:Connect(function()
				if not heldBlock or not heldBlock.Parent then
					if heldBlockConn then heldBlockConn:Disconnect() heldBlockConn = nil end
					return
				end
				if released then return end
				if not rightHand.Parent then return end
				-- Block placé pour que la main soit légèrement EN DEDANS du block
				-- (la main agrippe le block depuis l'intérieur, ce qui est visuellement
				-- plus naturel qu'un block flottant au bout des doigts).
				heldBlock:PivotTo(rightHand.CFrame * CFrame.new(0, -0.3, 0))
			end)

			task.delay(PERFECT_ANIM_RELEASE_TIME, function()
				released = true
				if heldBlockConn then heldBlockConn:Disconnect() heldBlockConn = nil end
				if heldBlock and heldBlock.Parent then
					heldBlock:Destroy()
					heldBlock = nil
				end
			end)
		end
	end

	-- ===== Anchore le HRP : on va piloter sa CFrame frame par frame pour suivre
	-- la trajectoire root motion bakée dans l'animation (recule, court, plant, vol).
	local wasAnchored = hrp.Anchored
	hrp.Anchored = true

	-- Pose de départ + direction "avant" du joueur (LookVector -> vers le panier).
	local startCFrame = hrp.CFrame
	local forwardDir = startCFrame.LookVector
	forwardDir = Vector3.new(forwardDir.X, 0, forwardDir.Z)
	if forwardDir.Magnitude < 1e-3 then
		forwardDir = Vector3.new(-1, 0, 0)
	else
		forwardDir = forwardDir.Unit
	end

	-- ===== Lance l'animation =====
	local track, cleanup = loadPerfectTrack(character)
	if track then
		track:Play(0.05)
		track.Stopped:Once(function()
			track:Destroy()
			if cleanup then cleanup() end
		end)
		-- Coupe l'animation 0.5s après l'impulsion (PERFECT_ANIM_DURATION).
		task.delay(PERFECT_ANIM_DURATION, function()
			pcall(function() track:Stop(0.1) end)
		end)
	end

	-- ===== Son d'impulsion : joué avant le début de la poussée pour que
	-- le "whoosh" colle bien au mouvement (offset négatif sur JUMP_START_TIME).
	task.delay(JUMP_START_TIME - 0.4, function()
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://3802270141"
		s.Volume = 1
		s.Parent = SoundService
		s:Play()
		s.Ended:Once(function() s:Destroy() end)
		Debris:AddItem(s, math.max(s.TimeLength + 0.5, 5))
	end)

	-- ===== Débris autour de la jambe gauche au moment de l'impulsion =====
	-- Spawnés avant le début de la poussée pour que les débris apparaissent
	-- pile au moment où le pied frappe le sol pour le saut.
	task.delay(JUMP_START_TIME - 0.3, function()
		if not character or not character.Parent then return end
		local leftFoot = character:FindFirstChild("LeftFoot")
			or character:FindFirstChild("LeftLowerLeg")
			or character:FindFirstChild("Left Leg")
		if not leftFoot then return end

		-- Position au sol à la verticale du pied gauche.
		-- Raycast EXCLUANT le character pour ne pas frapper le pied/la jambe.
		local footPos = leftFoot.Position
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { character }
		local raycast = Workspace:Raycast(
			footPos + Vector3.new(0, 5, 0),
			Vector3.new(0, -50, 0),
			rayParams
		)
		local groundY = raycast and raycast.Position.Y or (footPos.Y - 2)
		local centerPos = Vector3.new(footPos.X, groundY, footPos.Z)

		local debrisFolder = Instance.new("Folder")
		debrisFolder.Name = "DunkTakeoffDebris"
		debrisFolder.Parent = Workspace

		for i = 1, 14 do
			local angle = (i / 14) * math.pi * 2 + math.random() * 0.3
			local dist = 1.5 + math.random() * 2.5
			local size = 0.4 + math.random() * 0.7
			local d = Instance.new("Part")
			d.Size = Vector3.new(size, size, size)
			-- Pose le cube avec son fond pile au niveau du sol :
			-- centerPos.Y est la position du sol, on monte de size/2 pour que la
			-- face inférieure du cube touche le sol (et pas son centre).
			d.CFrame = CFrame.new(
				centerPos.X + math.cos(angle) * dist,
				centerPos.Y + size * 0.5,
				centerPos.Z + math.sin(angle) * dist
			) * CFrame.Angles(
				math.random() * math.pi * 2,
				math.random() * math.pi * 2,
				math.random() * math.pi * 2
			)
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Material = Enum.Material.Plastic
			d.TopSurface = Enum.SurfaceType.Studs
			d.BottomSurface = Enum.SurfaceType.Studs
			d.Color = Color3.fromRGB(75, 60, 45)
			d.Parent = debrisFolder
		end

		Debris:AddItem(debrisFolder, 8)
	end)

	-- ===== Boucle root motion : suit la trajectoire bakée dans la KFS =====
	-- RenderStepped pour une frame visuelle parfaitement synchronisée avec
	-- l'affichage (60-144 fps) et un mouvement ultra fluide.
	local animStart = sequenceStart
	local rootMotionConn
	rootMotionConn = RunService.RenderStepped:Connect(function()
		if not hrp.Parent then
			rootMotionConn:Disconnect()
			rootMotionConn = nil
			return
		end
		local elapsed = os.clock() - animStart
		if elapsed > PERFECT_ANIM_DURATION then
			rootMotionConn:Disconnect()
			rootMotionConn = nil
			return
		end
		local x, y = getRootOffsetAt(elapsed)
		hrp.CFrame = startCFrame + forwardDir * x + Vector3.new(0, y, 0)
	end)

	-- ===== Fin de séquence : restore tout puis fire serveur =====
	task.delay(PERFECT_ANIM_DURATION, function()
		if rootMotionConn then rootMotionConn:Disconnect() rootMotionConn = nil end
		if camConn then camConn:Disconnect() camConn = nil end
		if heldBlock and heldBlock.Parent then heldBlock:Destroy() end

		-- TP le joueur à sa position de départ avant de dé-anchorer.
		if hrp.Parent then
			hrp.CFrame = startCFrame
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			hrp.Anchored = wasAnchored
		end

		-- Slide-out des bandes noires puis cleanup
		if letterboxGui then
			local TweenService = game:GetService("TweenService")
			local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local top = letterboxGui:FindFirstChild("TopBar")
			local bot = letterboxGui:FindFirstChild("BottomBar")
			if top then TweenService:Create(top, info, { Position = UDim2.new(0, 0, -0.16, 0) }):Play() end
			if bot then TweenService:Create(bot, info, { Position = UDim2.new(0, 0, 1, 0) }):Play() end
			task.delay(0.35, function()
				if letterboxGui and letterboxGui.Parent then letterboxGui:Destroy() end
			end)
		end

		local dunkRequestEvent = RemotesAPI.GetEvent("DunkRequestEvent")
		if dunkRequestEvent then
			dunkRequestEvent:FireServer(gradeText, fill)
		end
	end)
end

-- ===== ANIMATION JUMP-SHOT BASKET =====
-- AssetId Roblox publié (anciennement c'était une KeyframeSequence dans
-- ReplicatedStorage.Shared.Animations.JumpShot, maintenant on utilise
-- directement l'asset publié 109732042578780).
local JUMPSHOT_ANIM_ID = "rbxassetid://109732042578780"

local jumpShotAnim -- Instance Animation pré-cachée

local function getJumpShotAnimation()
	-- Même stratégie : Animation réutilisée via le cache global, préchargée
	-- au join donc LoadAnimation immédiat.
	if jumpShotAnim then return jumpShotAnim end
	jumpShotAnim = AnimationCache.GetAnimation(JUMPSHOT_ANIM_ID)
	return jumpShotAnim
end

-- Joue uniquement la KeyframeSequence sur le character. Désactive les
-- animations natives (Idle/Walk via le script "Animate") et stoppe toutes
-- les tracks en cours pour que rien n'écrase notre pose.
local function playJumpShotAnimation(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local anim = getJumpShotAnimation()
	if not anim then return end

	-- Désactive le script natif "Animate" (qui pilote Idle/Walk/Run/Jump) :
	-- sinon, l'animation Idle continue de tourner et fight notre KFS.
	local animateScript = character:FindFirstChild("Animate")
	local animateWasEnabled
	if animateScript and animateScript:IsA("LocalScript") then
		animateWasEnabled = animateScript.Disabled == false
		animateScript.Disabled = true
	end

	-- Stoppe toutes les tracks d'animation actuellement actives.
	for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
		pcall(function() t:Stop(0) end)
	end

	local track = animator:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false
	track:Play(0.05)

	track.Stopped:Once(function()
		track:Destroy()
		-- Réactive le script Animate pour que Idle/Walk reprennent ensuite.
		if animateScript and animateWasEnabled then
			animateScript.Disabled = false
		end
	end)
end

-- ===== Séquence complète jump-shot (caméra côté + lucky block en main) =====
-- Timing serré pour un saut explosif et naturel (pas de flottement).
local ANIM_DURATION = 1.15         -- durée totale du saut physique (montée + chute)
local ANIM_UP_RATIO = 0.42         -- 42% du temps pour monter, 58% pour redescendre
local ANIM_RELEASE_TIME = 0.45     -- moment du release (juste avant l'apex)

local function playJumpShotSequence(player, gradeText, fill)
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	-- Bloque KickZone de remettre le bouton visible pendant la séquence.
	_G.DunkSequenceInProgress = true

	-- Déséquipe tout outil tenu (brainrot, etc.) pour que les mains soient libres
	-- pendant l'animation jump-shot.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function() humanoid:UnequipTools() end)
	end

	-- Force le character à regarder vers l'avant de l'arène (vers -X = panier)
	-- avant de lancer l'animation. Le tir part toujours dans cette direction
	-- peu importe l'orientation du joueur au moment du clic.
	local currentPos = hrp.Position
	local forwardTarget = currentPos + Vector3.new(-1, 0, 0) -- regarde vers -X
	hrp.CFrame = CFrame.lookAt(currentPos, forwardTarget)

	-- Direction de lancer FIGÉE ici, une fois pour toutes. À partir du moment
	-- où le HRP est anchored et tweené, son LookVector peut être instable
	-- (surtout sur des runs successifs avec tools qui se déséquippent en async).
	-- On utilise donc cette constante pour le lancer du block au release.
	local throwDirection = Vector3.new(-1, 0, 0)

	-- ===== Caméra : vue de profil 45° FIXE (ne suit pas le joueur qui recule) =====
	local camera = Workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable

	-- Calcule la position de la caméra UNE SEULE FOIS à partir de la pose
	-- de départ. La caméra reste ensuite immobile, le joueur peut reculer
	-- librement et sortir/rentrer dans le cadre.
	local cameraStartPos = hrp.Position
	local cameraStartCFrame = hrp.CFrame
	local angleDir = (cameraStartCFrame.RightVector + cameraStartCFrame.LookVector).Unit
	local sideOffset = angleDir * 8 + Vector3.new(0, 2.5, 0)
	local fixedCamPos = cameraStartPos + sideOffset
	local fixedCamTarget = cameraStartPos + Vector3.new(0, 2, 0)
	camera.CFrame = CFrame.new(fixedCamPos, fixedCamTarget)

	-- Garde la caméra fixée à cette position (au cas où un autre script
	-- la modifierait pendant l'anim).
	local camConn = RunService.RenderStepped:Connect(function()
		camera.CFrame = CFrame.new(fixedCamPos, fixedCamTarget)
	end)

	-- ===== Lucky Block tenu à deux mains, puis release main droite =====
	local heldBlock
	local heldBlockConn -- RenderStep qui maintient le block centré entre les mains
	local rightHand = character:FindFirstChild("RightHand")
	local leftHand = character:FindFirstChild("LeftHand")
	if rightHand and leftHand then
		local template = ReplicatedStorage:FindFirstChild("LuckyBlocks")
		template = template and template:FindFirstChild("Basic")
		if template then
			heldBlock = template:Clone()
			heldBlock.Name = "DunkHeldBlock"

			if not heldBlock.PrimaryPart then
				for _, d in ipairs(heldBlock:GetDescendants()) do
					if d:IsA("BasePart") then
						heldBlock.PrimaryPart = d
						break
					end
				end
			end

			if heldBlock:IsA("Model") and heldBlock.PrimaryPart then
				local s = heldBlock:GetScale() or 1
				heldBlock:ScaleTo(s * 0.7)
			end

			-- Anchored = true pour qu'on contrôle sa position via PivotTo
			-- frame par frame (pas de weld). Comme ça on peut le centrer entre
			-- les deux mains avant le release, puis le suivre sur la main droite
			-- uniquement après.
			for _, d in ipairs(heldBlock:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanTouch = false
					d.CanQuery = false
					d.Massless = true
				end
			end

			heldBlock.Parent = Workspace

			-- État : avant release, le block est entre les deux mains.
			-- Après release, le block disparait (la balle est censée quitter
			-- la main à ce moment, le tir physique est fait par le serveur).
			local released = false
			heldBlockConn = RunService.RenderStepped:Connect(function()
				if not heldBlock or not heldBlock.Parent then
					if heldBlockConn then heldBlockConn:Disconnect() heldBlockConn = nil end
					return
				end
				if released then return end
				if not rightHand.Parent or not leftHand.Parent then return end

				-- Position : milieu des deux mains, légèrement abaissé pour que le
				-- block reste au niveau du visage/poitrine quand l'anim lève les
				-- bras (mais pas trop bas, le block doit rester dans les mains).
				local mid = (rightHand.Position + leftHand.Position) * 0.5
				mid = mid - Vector3.new(0, 0.4, 0)
				heldBlock:PivotTo(CFrame.new(mid))
			end)

			-- Au release, on stoppe le suivi des mains et on lance le block en
			-- AVANT comme si le joueur le lançait : trajectoire rectiligne tendue
			-- légèrement vers le haut. Le block se détruit à la fin du vol.
			task.delay(ANIM_RELEASE_TIME, function()
				released = true
				if heldBlockConn then heldBlockConn:Disconnect() heldBlockConn = nil end

				local capturedBlock = heldBlock
				heldBlock = nil  -- libère la réf pour que la cleanup finale ne détruise pas le block en vol
				if not capturedBlock or not capturedBlock.Parent then return end

				-- Position de départ = position courante du block (entre les mains).
				local startPivot = capturedBlock:GetPivot()
				local startPos = startPivot.Position

				-- Direction de lancer : constante FIGÉE au début de la séquence
				-- (vers -X). On NE LIT PAS hrp.CFrame.LookVector ici car le HRP
				-- a été anchoré + tweené et peut donner une direction parasite
				-- sur des runs successifs.
				local flatLook = throwDirection

				-- Sécurité : le block volant ne doit interagir avec rien (pas de
				-- collision, pas de touch event, pas de raycast).
				for _, d in ipairs(capturedBlock:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
						d.CanTouch = false
						d.CanQuery = false
					end
				end

				-- Paramètres du lancer : trajectoire RECTILIGNE sans rotation,
				-- légèrement inclinée vers le haut.
				local THROW_DURATION = 0.55
				local THROW_VX = 32        -- vitesse horizontale (studs/s)
				local THROW_VY = 10        -- vitesse verticale constante (studs/s)

				-- Capture l'orientation initiale pour la conserver pendant le vol.
				local startOrientation = startPivot - startPivot.Position

				-- Filet de sécurité : si quelque chose se passe mal, le block sera
				-- forcément détruit au plus tard après THROW_DURATION + 0.5s.
				Debris:AddItem(capturedBlock, THROW_DURATION + 0.5)

				local throwStart = os.clock()
				local throwConn
				throwConn = RunService.RenderStepped:Connect(function()
					if not capturedBlock or not capturedBlock.Parent then
						if throwConn then throwConn:Disconnect() throwConn = nil end
						return
					end
					local t = os.clock() - throwStart
					if t >= THROW_DURATION then
						if throwConn then throwConn:Disconnect() throwConn = nil end
						if capturedBlock and capturedBlock.Parent then
							capturedBlock:Destroy()
						end
						return
					end
					local x = THROW_VX * t
					local y = THROW_VY * t
					local pos = startPos + flatLook * x + Vector3.new(0, y, 0)
					capturedBlock:PivotTo(CFrame.new(pos) * startOrientation)
				end)
			end)
		end
	end

	-- ===== Lance l'animation =====
	playJumpShotAnimation(character)

	-- ===== Saut physique : recule + monte le HRP via TweenService =====
	-- TweenService offre l'interpolation la plus fluide possible (calculée
	-- nativement par le moteur, pas frame par frame en Lua).
	local TweenService = game:GetService("TweenService")

	local startCFrame = hrp.CFrame
	local wasAnchored = hrp.Anchored
	hrp.Anchored = true

	local backDir = -startCFrame.LookVector
	backDir = Vector3.new(backDir.X, 0, backDir.Z)
	if backDir.Magnitude < 1e-3 then
		backDir = Vector3.new(0, 0, 1)
	else
		backDir = backDir.Unit
	end

	local MAX_UP = 2.2     -- saut plus haut pour qu'on voit le mouvement
	local MAX_BACK = 1.5   -- recul léger comme un vrai jump-shot

	local upDuration = ANIM_DURATION * ANIM_UP_RATIO
	local downDuration = ANIM_DURATION * (1 - ANIM_UP_RATIO)

	-- Phase 1 : MONTE jusqu'au pic du saut.
	-- Quad.Out -> rapide départ (impulsion explosive) puis ralentit en haut.
	local apexCFrame = startCFrame
		+ Vector3.new(0, MAX_UP, 0)
		+ backDir * (MAX_BACK * 0.6)
	local tweenUp = TweenService:Create(
		hrp,
		TweenInfo.new(upDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = apexCFrame }
	)
	tweenUp:Play()

	-- Phase 2 : DESCENTE du pic vers la position finale (au sol, reculé).
	-- Quad.In -> lent au départ puis accélère comme une vraie chute (gravité).
	local endCFrame = startCFrame + backDir * MAX_BACK
	local tweenDown = TweenService:Create(
		hrp,
		TweenInfo.new(downDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ CFrame = endCFrame }
	)

	tweenUp.Completed:Connect(function()
		if hrp.Parent then tweenDown:Play() end
	end)

	-- Restauration finale : TP le joueur à sa position de départ puis dé-anchore.
	task.delay(ANIM_DURATION + 0.05, function()
		if hrp.Parent then
			hrp.CFrame = startCFrame
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			hrp.Anchored = wasAnchored
		end
	end)

	-- À la fin de l'anim : restaure caméra + fire serveur pour le vrai vol.
	task.delay(ANIM_DURATION, function()
		if camConn then
			camConn:Disconnect()
			camConn = nil
		end
		if heldBlock and heldBlock.Parent then
			heldBlock:Destroy()
		end
		-- Le DunkLuckyBlockController prendra le relais caméra via la phase
		-- "Start" du DunkSequenceEvent (Scriptable -> suit le block en vol).
		local dunkRequestEvent = RemotesAPI.GetEvent("DunkRequestEvent")
		if dunkRequestEvent then
			dunkRequestEvent:FireServer(gradeText, fill)
		end
	end)
end

-- ===== Réglages =====

-- Durée d'un aller-retour complet (0 -> 1 -> 0) de la MovingBar, en secondes.
local CYCLE_DURATION = 1.2

-- Temps d'affichage du résultat avant de refermer le mini-jeu.
local RESULT_DISPLAY_TIME = 1.2

-- Grades triés du plus exigeant au plus permissif.
local GRADES = {
	{ min = 0.95, text = "PERFECT",   color = Color3.fromRGB(255, 215, 0) },
	{ min = 0.80, text = "EXCELLENT", color = Color3.fromRGB(120, 230, 80) },
	{ min = 0.60, text = "GREAT",     color = Color3.fromRGB(100, 200, 255) },
	{ min = 0.40, text = "GOOD",      color = Color3.fromRGB(200, 200, 255) },
	{ min = 0.20, text = "MID",       color = Color3.fromRGB(255, 160, 60) },
	{ min = 0.00, text = "BAD",       color = Color3.fromRGB(255, 80, 80) },
}

-- ===== Helpers =====

local function gradeFor(fill)
	for _, g in ipairs(GRADES) do
		if fill >= g.min then
			return g
		end
	end
	return GRADES[#GRADES]
end

-- Ping-pong : retourne une valeur entre 0 et 1 qui oscille sur une période de CYCLE_DURATION.
local function computeFill(elapsed)
	local phase = (elapsed % CYCLE_DURATION) / CYCLE_DURATION
	if phase < 0.5 then
		return phase / 0.5
	else
		return 1 - (phase - 0.5) / 0.5
	end
end

local function isPointInsidePart(point, part)
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(localPoint.X) <= half.X
		and math.abs(localPoint.Y) <= half.Y
		and math.abs(localPoint.Z) <= half.Z
end

-- ===== Lifecycle =====

function DunkGameController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[DunkGameController] MainGui introuvable dans PlayerGui après 30s")
		return
	end
	local dunkButton = mainGui:WaitForChild("DunkButton")

	local dunkGame = playerGui:WaitForChild("DunkGame", 30)
	if not dunkGame then
		warn("[DunkGameController] DunkGame introuvable dans PlayerGui après 30s")
		return
	end
	local bar = dunkGame:WaitForChild("Bar")
	local movingBar = bar:WaitForChild("MovingBar")
	local message = dunkGame:WaitForChild("Message")
	local charging = dunkGame:WaitForChild("Charging")

	-- Zone de jeu pour vérifier si on peut réafficher le bouton à la fin.
	local spawnFolder = Workspace:WaitForChild("Spawn")
	local areas = spawnFolder:WaitForChild("Areas")
	local kickReady = areas:WaitForChild("KickReady")

	-- Overlay transparent plein écran qui capture les clics pendant le mini-jeu.
	local inputCatcher = Instance.new("TextButton")
	inputCatcher.Name = "InputCatcher"
	inputCatcher.BackgroundTransparency = 1
	inputCatcher.Text = ""
	inputCatcher.AutoButtonColor = false
	inputCatcher.Size = UDim2.fromScale(1, 1)
	inputCatcher.Position = UDim2.fromScale(0, 0)
	inputCatcher.AnchorPoint = Vector2.new(0, 0)
	inputCatcher.ZIndex = -10
	inputCatcher.Parent = dunkGame

	-- État initial propre.
	dunkGame.Enabled = false
	message.Visible = false
	charging.Visible = true
	movingBar.Size = UDim2.new(1, 0, 0, 0)

	local isPlaying = false
	local startTime = 0
	local cycleConn

	-- Bloque les contrôles de déplacement (WASD, saut) pendant le mini-jeu.
	-- On freeze aussi WalkSpeed/JumpPower au cas où un input résiduel passe.
	local function freezeCharacter()
		pcall(function()
			local PlayerScripts = player:WaitForChild("PlayerScripts")
			local PlayerModule = require(PlayerScripts:WaitForChild("PlayerModule"))
			local controls = PlayerModule:GetControls()
			controls:Disable()
		end)
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = 0
				humanoid.JumpPower = 0
				humanoid.JumpHeight = 0
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			end
		end
	end

	local function stopCycle()
		if cycleConn then
			cycleConn:Disconnect()
			cycleConn = nil
		end
	end

	local function finishMiniGame(fill)
		if not isPlaying then return end
		isPlaying = false
		stopCycle()

		local grade = gradeFor(fill)
		charging.Visible = false
		message.Text = grade.text
		message.TextColor3 = grade.color
		message.Visible = true

		-- Fige la barre sur la valeur capturée au moment du clic.
		movingBar.Size = UDim2.new(1, 0, fill, 0)

		-- Son spécifique au grade (BAD / EXCELLENT / PERFECT uniquement).
		playGradeSound(grade.text)

		-- Si grade != PERFECT, joue l'animation jump-shot avec caméra côté +
		-- lucky block en main, puis fire le serveur à la fin de l'animation.
		-- Si PERFECT, joue l'animation PERFECT spécifique puis fire le serveur.
		if grade.text ~= "PERFECT" then
			playJumpShotSequence(player, grade.text, fill)
		else
			playPerfectSequence(player, grade.text, fill)
		end

		task.delay(RESULT_DISPLAY_TIME, function()
			dunkGame.Enabled = false
			message.Visible = false
			charging.Visible = true
			movingBar.Size = UDim2.new(1, 0, 0, 0)
			-- Ne réaffiche pas le DunkButton : le DunkLuckyBlockController gère
			-- la fin de séquence (End) pour le réafficher.
		end)
	end

	local function startMiniGame()
		if isPlaying then return end
		isPlaying = true

		-- Fige le joueur sur place pendant le mini-jeu. Il sera défreeze
		-- automatiquement à la phase "End" du DunkLuckyBlockController, car
		-- le takeControl du brainrot enchaine sans transition.
		freezeCharacter()

		dunkButton.Visible = false
		dunkGame.Enabled = true
		message.Visible = false
		charging.Visible = true
		movingBar.Size = UDim2.new(1, 0, 0, 0)

		startTime = os.clock()
		stopCycle()
		cycleConn = RunService.Heartbeat:Connect(function()
			if not isPlaying then return end
			local fill = computeFill(os.clock() - startTime)
			movingBar.Size = UDim2.new(1, 0, fill, 0)
		end)
	end

	-- Démarrage : clic sur DunkButton.
	dunkButton.MouseButton1Click:Connect(startMiniGame)

	-- Stop : clic sur l'overlay pendant que le mini-jeu tourne.
	-- MouseButton1Down pour le timing le plus précis possible (pas au relâchement).
	inputCatcher.MouseButton1Down:Connect(function()
		if not isPlaying then return end
		local fill = computeFill(os.clock() - startTime)
		finishMiniGame(fill)
	end)

	-- Garantit que le DunkButton reste caché tant que le mini-jeu tourne,
	-- même si un autre controller (ex: KickZoneController) le remet visible.
	dunkButton:GetPropertyChangedSignal("Visible"):Connect(function()
		if isPlaying and dunkButton.Visible then
			dunkButton.Visible = false
		end
	end)

	print("[DunkGameController] Script initialisé!")
end

return DunkGameController

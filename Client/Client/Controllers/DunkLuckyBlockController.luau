--[[
	DunkLuckyBlockController
	Côté client de la séquence post-mini-jeu Dunk.

	Écoute DunkSequenceEvent émis par DunkLuckyBlockService :
		Start          -> on cache le DunkButton et on bloque sa réapparition.
		Landed         -> petite secousse de caméra.
		SpinStarted    -> roll des brainrots (silhouettes), caméra fixée.
		BrainrotPicked -> la caméra suit le brainrot contrôlé par le joueur.
		WaveRise       -> zoom caméra sur la wave qui monte depuis sous le sol.
		WaveChase      -> la wave poursuit le brainrot ; caméra revient sur lui.
		BrainrotLost   -> la wave a attrapé le brainrot : perdu, caméra -> character.
		BrainrotSold   -> le serveur a ajouté le brainrot au Backpack.
		End            -> on redonne le contrôle au character et on réaffiche
		                  le DunkButton si le joueur est encore en zone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local DunkLuckyBlockController = Loader.CreateController({
	Name = "DunkLuckyBlockController",
})

-- ===== SONS =====
local FLIGHT_SOUND_ID   = "rbxassetid://139095330035399" -- pendant le vol
local LAND_SOUND_ID     = "rbxassetid://138533090376585" -- impact au sol
local ROLL_TICK_SOUND_ID = "rbxassetid://156286438"      -- tick à chaque brainrot affiché pendant le roll
local WAVE_SOUND_ID     = "rbxassetid://119576268904309" -- ambiance pendant l'animation de la wave
local CHASE_SOUND_ID    = "rbxassetid://1847683499"      -- ambiance pendant la poursuite (WaveChase -> arrivée/touché)

-- Helper : joue un son one-shot à la position donnée (3D) ou globalement (2D).
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local function playSound2D(id, volume)
	if not id or id == "" then return end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 1
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, math.max(s.TimeLength + 0.5, 8))
	return s
end

-- Flag partagé avec KickZoneController : tant que le flag est true, KickZone
-- ne doit pas remettre le DunkButton visible.
_G.DunkSequenceInProgress = _G.DunkSequenceInProgress or false

-- FX d'impact SPAWNÉS LOCALEMENT. Seul le joueur qui a lancé les voit.
-- Dust rond qui s'élance radialement au ras du sol, plus une onde de choc
-- qui s'étend. On supprime les débris verticaux (lignes) pour garder un
-- look plus propre / cartoon.
local function spawnLocalImpactFX(position)
	local attachPart = Instance.new("Part")
	attachPart.Name = "LocalDunkImpactFX"
	attachPart.Size = Vector3.new(1, 1, 1)
	attachPart.Transparency = 1
	attachPart.Anchored = true
	attachPart.CanCollide = false
	attachPart.CanQuery = false
	attachPart.CanTouch = false
	attachPart.Massless = true
	attachPart.Position = position + Vector3.new(0, 0.5, 0)
	attachPart.Parent = Workspace

	local att = Instance.new("Attachment")
	att.Parent = attachPart

	-- Dust burst radial (pas de projection verticale). Les particules partent
	-- à l'horizontale et retombent doucement. Texture smoke ronde intégrée
	-- (pas la slash 241876428 qui dessinait des lignes verticales résiduelles).
	local dust = Instance.new("ParticleEmitter")
	dust.Parent = att
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Lifetime = NumberRange.new(0.6, 1.1)
	dust.Rate = 0
	dust.Speed = NumberRange.new(18, 32)
	dust.SpreadAngle = Vector2.new(0, 180) -- radial horizontal, pas vertical
	dust.EmissionDirection = Enum.NormalId.Top
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(0.4, 6),
		NumberSequenceKeypoint.new(1, 9),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Color = ColorSequence.new(Color3.fromRGB(195, 180, 150))
	dust.Rotation = NumberRange.new(0, 360)
	dust.RotSpeed = NumberRange.new(-90, 90)
	dust.Acceleration = Vector3.new(0, -8, 0)
	dust:Emit(50)

	-- Shockwave ring au sol.
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.4, 2, 2)
	ring.CFrame = CFrame.new(position + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 220, 120)
	ring.Transparency = 0.2
	ring.Parent = Workspace

	RunService.RenderStepped:Wait()
	local TweenService = game:GetService("TweenService")
	TweenService:Create(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, 42, 42),
		Transparency = 1,
	}):Play()

	Debris:AddItem(attachPart, 2.5)
	Debris:AddItem(ring, 0.8)
end

-- ID sonore joué au moment où le brainrot franchit KickReady (confetti + flash).
local SOLD_SOUND_ID = "rbxassetid://109081723292068"

-- Anim "sold" : flash blanc plein écran + confetti qui tombent depuis le
-- haut. Joué quand le brainrot passe la KickReady et revient au joueur.
local function playSoldFeedback(player)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	playSound2D(SOLD_SOUND_ID, 1.0)

	-- Flash blanc : ScreenGui plein écran qui apparaît à opacité max, puis
	-- fade out rapidement. Couche la plus haute (DisplayOrder élevé).
	local flashGui = Instance.new("ScreenGui")
	flashGui.Name = "DunkSoldFlash"
	flashGui.IgnoreGuiInset = true
	flashGui.DisplayOrder = 2000
	flashGui.ResetOnSpawn = false
	flashGui.Parent = playerGui
	Debris:AddItem(flashGui, 1.5)

	local flash = Instance.new("Frame")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	flash.BorderSizePixel = 0
	flash.BackgroundTransparency = 0
	flash.Parent = flashGui

	local TweenService = game:GetService("TweenService")
	TweenService:Create(flash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()

	-- Confetti plein écran : deux canons qui tirent depuis les coins bas,
	-- plus une pluie depuis le haut. Les pièces ont différentes formes
	-- (rectangles étroits, carrés, cercles via UICorner) et des trajectoires
	-- balistiques avec effet de "flutter" (oscillation horizontale).
	local confettiGui = Instance.new("ScreenGui")
	confettiGui.Name = "DunkSoldConfetti"
	confettiGui.IgnoreGuiInset = true
	confettiGui.DisplayOrder = 1999
	confettiGui.ResetOnSpawn = false
	confettiGui.Parent = playerGui
	Debris:AddItem(confettiGui, 6)

	local viewportSize = confettiGui.AbsoluteSize
	local screenW = viewportSize.X > 0 and viewportSize.X or 1920
	local screenH = viewportSize.Y > 0 and viewportSize.Y or 1080

	local COLORS = {
		Color3.fromRGB(255, 80, 100),     -- rouge/rose
		Color3.fromRGB(255, 180, 40),     -- orange
		Color3.fromRGB(255, 230, 60),     -- jaune doré
		Color3.fromRGB(90,  220, 120),    -- vert
		Color3.fromRGB(70,  180, 255),    -- bleu
		Color3.fromRGB(200, 110, 255),    -- violet
		Color3.fromRGB(255, 255, 255),    -- blanc
	}

	-- spawn(kind, params) : kind = "cannon_left" | "cannon_right" | "rain"
	local function spawnPiece(kind)
		local piece = Instance.new("Frame")
		-- 2 formes uniquement : carré ou cercle. Pas de rectangles étroits.
		local shape = math.random(1, 2) -- 1 carré, 2 cercle
		local size = math.random(12, 18)
		piece.Size = UDim2.fromOffset(size, size)
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.BackgroundColor3 = COLORS[math.random(1, #COLORS)]
		piece.BorderSizePixel = 0
		piece.Rotation = math.random(-180, 180)
		piece.ZIndex = 1

		if shape == 2 then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0) -- cercle parfait
			corner.Parent = piece
		end

		-- Léger gradient pour donner de la profondeur au confetti (brillance).
		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(0.5, piece.BackgroundColor3),
			ColorSequenceKeypoint.new(1, Color3.new(0.4, 0.4, 0.4)),
		})
		gradient.Rotation = math.random(0, 180)
		gradient.Parent = piece

		local startX, startY, vx, vy, gravity, spin, lifetime, flutterAmp, flutterFreq
		if kind == "cannon_left" then
			startX = screenW * 0.05
			startY = screenH
			vx = math.random(350, 650)   -- fort vers la droite
			vy = -math.random(700, 1050) -- fort vers le haut
			gravity = 1500
		elseif kind == "cannon_right" then
			startX = screenW * 0.95
			startY = screenH
			vx = -math.random(350, 650)
			vy = -math.random(700, 1050)
			gravity = 1500
		else -- rain
			startX = math.random(-50, screenW + 50)
			startY = -math.random(30, 250)
			vx = (math.random() - 0.5) * 160
			vy = math.random(60, 160)
			gravity = 450 -- plus léger pour les confettis qui planent
		end

		spin = (math.random() - 0.5) * 900
		lifetime = 2.5 + math.random() * 1.5
		flutterAmp = math.random(8, 22)
		flutterFreq = 3 + math.random() * 3

		piece.Position = UDim2.fromOffset(startX, startY)
		piece.Parent = confettiGui

		local px, py = startX, startY
		local rot = piece.Rotation
		local elapsed = 0
		local phaseOffset = math.random() * math.pi * 2
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			vy = vy + gravity * dt
			px = px + vx * dt
			py = py + vy * dt
			rot = rot + spin * dt
			if not piece.Parent then
				conn:Disconnect()
				return
			end
			-- Flutter horizontal : sinusoïde en fonction du temps pour simuler
			-- le balancement d'une feuille.
			local flutter = math.sin(elapsed * flutterFreq + phaseOffset) * flutterAmp
			piece.Position = UDim2.fromOffset(px + flutter, py)
			piece.Rotation = rot
			local t = elapsed / lifetime
			if t > 0.7 then
				piece.BackgroundTransparency = (t - 0.7) / 0.3
			end
			if t >= 1 or py > screenH + 80 then
				conn:Disconnect()
				piece:Destroy()
			end
		end)
	end

	-- Burst initial : deux canons qui tirent 40 pièces chacun depuis les coins bas.
	for _ = 1, 40 do spawnPiece("cannon_left") end
	for _ = 1, 40 do spawnPiece("cannon_right") end

	-- Pluie continue : ~30 pièces qui tombent du haut, pendant 1.5s, par vagues.
	task.spawn(function()
		for wave = 1, 5 do
			for _ = 1, 12 do spawnPiece("rain") end
			task.wait(0.25)
		end
	end)
end

local function shakeCamera(camera, duration, intensity)
	local start = os.clock()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - start
		if t >= duration then
			conn:Disconnect()
			return
		end
		local k = 1 - (t / duration)
		local offX = (math.random() - 0.5) * intensity * k
		local offY = (math.random() - 0.5) * intensity * k
		camera.CFrame = camera.CFrame * CFrame.new(offX, offY, 0)
	end)
end

function DunkLuckyBlockController:Start()
	local player = Players.LocalPlayer
	local camera = Workspace.CurrentCamera
	local playerGui = player:WaitForChild("PlayerGui")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	local dunkButton = mainGui and mainGui:WaitForChild("DunkButton", 30)

	-- TopBar.Top : barre de zones qui affiche la tête du joueur aux positions
	-- correspondant à la rarété où le lucky block va tomber. Visible pendant
	-- tout le vol.
	local topBar = mainGui and mainGui:WaitForChild("TopBar", 15)
	local topFrame = topBar and topBar:WaitForChild("Top", 15)
	local topPlayerImage = topFrame and topFrame:WaitForChild("Player", 15)

	-- Image de la tête du joueur (headshot Roblox).
	if topPlayerImage then
		local Players = game:GetService("Players")
		task.spawn(function()
			local ok, url = pcall(function()
				return Players:GetUserThumbnailAsync(
					player.UserId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size150x150
				)
			end)
			if ok and url then
				topPlayerImage.Image = url
			end
		end)
	end

	-- Mapping piecewise linéaire entre position X monde du lucky block et
	-- position X UI (Scale) de la tête sur TopBar.Top. Les keyframes sont
	-- aux limites de chaque zone (Common, Uncommon, ..., OG) mesurées par
	-- l'utilisateur sur ses W-parts et dans l'UI.
	--
	-- Chaque entrée : { worldX, uiScaleX }. Ordonné du plus proche spawn
	-- (660 monde = 0.103 UI) au plus loin (-2050 monde = 0.904 UI).
	local zoneKeyframes = {
		{ 660,      0.103 },
		{ 564.768,  0.179 },
		{ 395,      0.255 },
		{ 154.768,  0.339 },
		{ -120.232, 0.428 },
		{ -440.231, 0.519 },
		{ -787.231, 0.607 },
		{ -1166.231,0.706 },
		{ -1601.231,0.804 },
		{ -2050,    0.904 },
	}
	local function worldXToUIScaleX(wx)
		if wx >= zoneKeyframes[1][1] then return zoneKeyframes[1][2] end
		if wx <= zoneKeyframes[#zoneKeyframes][1] then return zoneKeyframes[#zoneKeyframes][2] end
		for i = 1, #zoneKeyframes - 1 do
			local a, b = zoneKeyframes[i], zoneKeyframes[i + 1]
			if wx <= a[1] and wx >= b[1] then
				local t = (a[1] - wx) / (a[1] - b[1])
				return a[2] + (b[2] - a[2]) * t
			end
		end
		return zoneKeyframes[#zoneKeyframes][2]
	end

	local dunkSequenceEvent = RemotesAPI.GetEvent("DunkSequenceEvent")

	local StarterGui = game:GetService("StarterGui")

	-- Active/désactive la possibilité de se reset (R ou bouton menu).
	local function setResetEnabled(enabled)
		pcall(function()
			StarterGui:SetCore("ResetButtonCallback", enabled)
		end)
	end

	-- Le preload des LuckyBlocks et brainrots Normal est désormais centralisé
	-- dans ReplicatedStorage.Shared.AssetPreloader (déclenché par le
	-- LoadingScreen au join). On fait juste un warmup GPU local : un clone
	-- caché du LuckyBlock Basic pour forcer la mise en cache de rendu, qui
	-- est distincte du téléchargement des données effectué par PreloadAsync.
	task.spawn(function()
		local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
		local preloaderModule = sharedFolder and sharedFolder:FindFirstChild("AssetPreloader")
		if preloaderModule then
			local AssetPreloader = require(preloaderModule)
			AssetPreloader.WaitForEssential()
		end

		local luckyBlocksFolder = ReplicatedStorage:WaitForChild("LuckyBlocks", 30)
		local basic = luckyBlocksFolder and luckyBlocksFolder:FindFirstChild("Basic")
		if not basic then return end

		-- Warmup clone caché pour forcer le chargement des meshes dans le cache
		-- de rendu (PreloadAsync charge les données mais pas forcément le rendu GPU).
		local warmup = basic:Clone()
		for _, d in ipairs(warmup:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Transparency = 1
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		warmup:PivotTo(CFrame.new(0, -10000, 0))
		warmup.Parent = Workspace
		task.wait(2)
		warmup:Destroy()
	end)

	local currentBrainrot = nil
	local inputConn = nil
	local controlBindings = {}
	local waveSound = nil -- son loópé pendant l'animation de la wave (rise)
	local chaseSound = nil -- son loópé pendant la poursuite (WaveChase -> End/Lost)
	local localWaveModel = nil -- modèle de wave cloné localement (client only)
	local localWaveRiseConn = nil -- RenderStepped pour la montée
	local localWaveChaseConn = nil -- RenderStepped pour le chase

	-- ===== MASQUAGE DU CHARACTER PENDANT LA PHASE BRAINROT =====
	-- Quand le joueur contrôle le brainrot, son character d'origine reste
	-- statique au spawn et est visible à la fois (en plus du clone qui court).
	-- On cache toutes les parts/decals du character pendant la phase, et on
	-- restaure leurs transparences originales à la fin.
	local hiddenCharacterParts = nil -- table { instance = originalTransparency }
	local function hidePlayerCharacter()
		local character = player.Character
		if not character then return end
		hiddenCharacterParts = {}
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("BasePart") then
				hiddenCharacterParts[d] = d.LocalTransparencyModifier
				-- LocalTransparencyModifier ne réplique pas et override la
				-- transparency localement uniquement : parfait pour cacher
				-- côté client sans toucher l'état serveur du character.
				d.LocalTransparencyModifier = 1
			elseif d:IsA("Decal") or d:IsA("Texture") then
				hiddenCharacterParts[d] = d.Transparency
				d.Transparency = 1
			end
		end
		-- Cache aussi les accessoires/handles enfants (chapeaux, etc.).
	end
	local function showPlayerCharacter()
		if not hiddenCharacterParts then return end
		for inst, originalT in pairs(hiddenCharacterParts) do
			if inst and inst.Parent then
				if inst:IsA("BasePart") then
					inst.LocalTransparencyModifier = originalT or 0
				elseif inst:IsA("Decal") or inst:IsA("Texture") then
					inst.Transparency = originalT or 0
				end
			end
		end
		hiddenCharacterParts = nil
	end

	local function destroyLocalWave()
		if localWaveRiseConn then localWaveRiseConn:Disconnect(); localWaveRiseConn = nil end
		if localWaveChaseConn then localWaveChaseConn:Disconnect(); localWaveChaseConn = nil end
		if localWaveModel and localWaveModel.Parent then localWaveModel:Destroy() end
		localWaveModel = nil
	end

	local function releaseControl()
		for _, c in ipairs(controlBindings) do
			if typeof(c) == "RBXScriptConnection" then
				c:Disconnect()
			end
		end
		table.clear(controlBindings)
		if inputConn then
			inputConn:Disconnect()
			inputConn = nil
		end
		currentBrainrot = nil
		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local h = character and character:FindFirstChildOfClass("Humanoid")
		local playerHRP = character and character:FindFirstChild("HumanoidRootPart")
		if h then
			camera.CameraSubject = h
			h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			h:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		end

		-- ===== SÉCURITÉ ANTI-BUG REPRISE DE CONTRÔLE =====
		-- Bug observé : après la séquence dunk, quand le joueur reprend le contrôle
		-- de son perso, il meurt instantanément. Cause probable : vélocité
		-- résiduelle du HRP (tween dunk anim) + fall damage sur la chute. On
		-- zérote la vélocité et on protège les dégâts pendant 1.5s.
		if playerHRP then
			playerHRP.AssemblyLinearVelocity = Vector3.zero
			playerHRP.AssemblyAngularVelocity = Vector3.zero
		end
		if h then
			-- Bloque tout dégât pendant 1.5s : on réenregistre Health à sa valeur
			-- max chaque frame. Suffit pour absorber n'importe quel fall damage.
			local protectStart = os.clock()
			local protectConn
			protectConn = RunService.Heartbeat:Connect(function()
				if not h or not h.Parent then
					protectConn:Disconnect() return
				end
				if os.clock() - protectStart > 1.5 then
					protectConn:Disconnect() return
				end
				if h.Health < h.MaxHealth then
					h.Health = h.MaxHealth
				end
			end)
		end

		-- Réactive les contrôles du PlayerModule.
		pcall(function()
			local PlayerScripts = player:WaitForChild("PlayerScripts")
			local PlayerModule = require(PlayerScripts:WaitForChild("PlayerModule"))
			local controls = PlayerModule:GetControls()
			controls:Enable()
		end)
	end

	local function takeControl(brainrot)
		if not brainrot or not brainrot.Parent then return end
		local humanoid = brainrot:FindFirstChildOfClass("Humanoid")
		local hrp = brainrot:FindFirstChild("HumanoidRootPart")
		if not humanoid or not hrp then return end

		currentBrainrot = brainrot

		-- Caméra sur le brainrot.
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid

		pcall(function()
			local character = player.Character
			local playerHRP = character and character:FindFirstChild("HumanoidRootPart")
			if playerHRP then
				-- Le brainrot doit regarder vers le personnage du joueur (pour savoir
				-- où le ramener). On oriente donc la caméra derrière le brainrot,
				-- face au character.
				local targetDir = (playerHRP.Position - hrp.Position)
				targetDir = Vector3.new(targetDir.X, 0, targetDir.Z)
				if targetDir.Magnitude > 0.1 then
					local lookDir = targetDir.Unit
					local camOffset = -lookDir * 14 + Vector3.new(0, 5, 0)
					camera.CFrame = CFrame.new(hrp.Position + camOffset, hrp.Position)
				end
			end
		end)

		-- Joue l'animation Idle du brainrot en boucle si elle existe.
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		local animsFolder = brainrot:FindFirstChild("Anims") or brainrot:FindFirstChild("Animations")
		if animsFolder then
			local idleAnim = animsFolder:FindFirstChild("Idle") or animsFolder:FindFirstChildWhichIsA("Animation")
			if idleAnim and idleAnim:IsA("Animation") then
				local track = animator:LoadAnimation(idleAnim)
				track.Looped = true
				track.Priority = Enum.AnimationPriority.Idle
				track:Play()
			end
		end

		-- Désactive complètement les contrôles du character (y compris saut)
		-- via PlayerModule pendant qu'on contrôle le brainrot.
		pcall(function()
			local PlayerScripts = player:WaitForChild("PlayerScripts")
			local PlayerModule = require(PlayerScripts:WaitForChild("PlayerModule"))
			local controls = PlayerModule:GetControls()
			controls:Disable()
		end)

		-- Freeze le character du joueur : vitesse nulle et saut désactivé pour
		-- éviter qu'un input résiduel passe.
		local character = player.Character
		if character then
			local playerHum = character:FindFirstChildOfClass("Humanoid")
			if playerHum then
				playerHum.WalkSpeed = 0
				playerHum.JumpPower = 0
				playerHum.JumpHeight = 0
				playerHum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				playerHum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
			end
		end

		-- Déplacement clavier : WASD / flèches dirige le brainrot relatif à
		-- la caméra. On met à jour le MoveVector chaque frame.
		local moveKeys = {
			[Enum.KeyCode.W] = Vector3.new(0, 0, -1),
			[Enum.KeyCode.S] = Vector3.new(0, 0,  1),
			[Enum.KeyCode.A] = Vector3.new(-1, 0, 0),
			[Enum.KeyCode.D] = Vector3.new( 1, 0, 0),
			[Enum.KeyCode.Up]    = Vector3.new(0, 0, -1),
			[Enum.KeyCode.Down]  = Vector3.new(0, 0,  1),
			[Enum.KeyCode.Left]  = Vector3.new(-1, 0, 0),
			[Enum.KeyCode.Right] = Vector3.new( 1, 0, 0),
		}

		inputConn = RunService.RenderStepped:Connect(function()
			if not currentBrainrot or not currentBrainrot.Parent then return end
			local h = currentBrainrot:FindFirstChildOfClass("Humanoid")
			if not h then return end
			local hrp = currentBrainrot:FindFirstChild("HumanoidRootPart")

			-- Pendant l'animation de la wave (rise + showcase), on fige le brainrot :
			-- pas d'input, pas de vélocité, pas de saut. Le flag est levé à
			-- WaveRise et retiré à WaveChase.
			if _G.DunkBrainrotFrozen then
				h:Move(Vector3.zero, false)
				if hrp then
					local vel = hrp.AssemblyLinearVelocity
					hrp.AssemblyLinearVelocity = Vector3.new(0, math.min(vel.Y, 0), 0)
				end
				return
			end

			local move = Vector3.zero
			for key, dir in pairs(moveKeys) do
				if UserInputService:IsKeyDown(key) then
					move = move + dir
				end
			end

			-- Converti le vecteur local caméra en direction world.
			local worldMove = Vector3.zero
			if move.Magnitude > 0 then
				move = move.Unit
				local camCF = camera.CFrame
				local camLook = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
				if camLook.Magnitude > 0.001 then
					camLook = camLook.Unit
					local camRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z).Unit
					worldMove = camRight * move.X + camLook * (-move.Z)
				else
					worldMove = move
				end
			end

			h:Move(worldMove, false)

			-- Préserve la vélocité horizontale en l'air : Humanoid:Move() n'applique
			-- qu'une force très réduite en Freefall, donc le brainrot perd sa vitesse
			-- au décollage. On force AssemblyLinearVelocity à WalkSpeed sur X/Z tant
			-- qu'on tient une direction, et on préserve l'inertie si pas d'input.
			if hrp then
				local state = h:GetState()
				local isAirborne = (state == Enum.HumanoidStateType.Freefall
					or state == Enum.HumanoidStateType.Jumping)
				if isAirborne then
					local vel = hrp.AssemblyLinearVelocity
					if worldMove.Magnitude > 0 then
						-- Oriente la vitesse horizontale dans la direction d'input
						-- à WalkSpeed constant, en gardant la composante verticale.
						local targetHoriz = worldMove.Unit * h.WalkSpeed
						hrp.AssemblyLinearVelocity = Vector3.new(targetHoriz.X, vel.Y, targetHoriz.Z)
					end
					-- Sans input : on laisse l'inertie faire (pas d'override)
				end
			end
		end)

		-- Saut (Space).
		table.insert(controlBindings, UserInputService.InputBegan:Connect(function(input, gpe)
			if gpe then return end
			if not currentBrainrot or not currentBrainrot.Parent then return end
			if _G.DunkBrainrotFrozen then return end
			if input.KeyCode == Enum.KeyCode.Space then
				local h = currentBrainrot:FindFirstChildOfClass("Humanoid")
				if h then
					h.Jump = true
				end
			end
		end))
	end

	local localBlock, localCarrier -- Lucky block cloné localement (client only)
	local localFlightClone -- Clone PERFECT (Superman) cloné localement
	local flightSound -- Sound actif pendant le vol (stoppé à l'impact).

	-- ===== HELPERS POSE SUPERMAN =====
	-- Construit un clone du character du joueur en pose Superman, parenté au
	-- workspace, anchored, prêt à être tweené frame par frame en même temps
	-- que le bloc. Le clone est positionné derrière le bloc, corps horizontal,
	-- les deux bras tendus vers l'avant qui touchent l'arrière du bloc.
	local function destroyFlightClone()
		if localFlightClone and localFlightClone.Parent then
			localFlightClone:Destroy()
		end
		localFlightClone = nil
	end

	-- Mesure dynamiquement, après pose des bras, le "reach" du clone : distance
	-- entre HRP et le centre des deux mains. Sert à placer le HRP à l'exacte
	-- bonne distance derrière le bloc pour que les mains touchent l'arrière.
	local function buildSupermanClone()
		local character = player.Character
		if not character then return nil, 0 end
		local sourceHRP = character:FindFirstChild("HumanoidRootPart")
		if not sourceHRP then return nil, 0 end

		-- Force Archivable=true sur tout l'arbre (Roblox bloque les clones de
		-- character sinon).
		local originalArchivable = {}
		originalArchivable[character] = character.Archivable
		character.Archivable = true
		for _, d in ipairs(character:GetDescendants()) do
			originalArchivable[d] = d.Archivable
			d.Archivable = true
		end

		local clone = character:Clone()

		for inst, val in pairs(originalArchivable) do
			if inst.Parent then inst.Archivable = val end
		end

		if not clone then return nil, 0 end
		clone.Name = "DunkFlightClone_Local"

		-- Strip scripts (sauf Animate qui sera ignoré car humanoid platformstand)
		for _, c in ipairs(clone:GetChildren()) do
			if (c:IsA("LocalScript") or c:IsA("Script")) and c.Name ~= "Animate" then
				c:Destroy()
			elseif c:IsA("Tool") or c:IsA("Backpack") then
				c:Destroy()
			end
		end
		local animateScript = clone:FindFirstChild("Animate")
		if animateScript then animateScript.Disabled = true end

		-- Désactive le humanoid pour qu'il ne rejoue pas d'animations idle/fall
		local hum = clone:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.PlatformStand = true
			hum.AutoRotate = false
			-- Stop tous les animation tracks déjà joués
			local animator = hum:FindFirstChildOfClass("Animator")
			if animator then
				for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
					t:Stop(0)
				end
			end
		end

		-- Initial : tout désancré + sans collision pour que la pose se calcule
		-- via les Motor6D, puis on ré-anchore tout pour figer.
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
			end
		end

		-- Place hors-caméra le temps de poser, puis téléporte au bon endroit.
		clone:PivotTo(CFrame.new(0, -1000, 0))
		clone.Parent = Workspace

		-- ===== POSE DES BRAS (R6 + R15) =====
		-- On modifie les Motor6D des épaules pour tendre les bras vers l'avant.
		-- Pour le R15 : RightShoulder/LeftShoulder reliés à UpperTorso -> UpperArm.
		-- L'orientation par défaut a Up vers le ciel, donc une rotation -90° sur
		-- l'axe X local du shoulder envoie le bras vers l'avant.
		local motorsByName = {}
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("Motor6D") then
				motorsByName[d.Name] = d
			end
		end

		local function poseShoulder(motor)
			if not motor then return end
			local pos = motor.C0.Position
			motor.C0 = CFrame.new(pos) * CFrame.Angles(-math.rad(90), 0, 0)
		end
		-- Bras droits/gauches en R15 et R6.
		poseShoulder(motorsByName["RightShoulder"])
		poseShoulder(motorsByName["LeftShoulder"])
		poseShoulder(motorsByName["Right Shoulder"])
		poseShoulder(motorsByName["Left Shoulder"])
		-- Coudes en R15 : on garde les bras droits (pas de pliure).
		local function straightenElbow(motor)
			if not motor then return end
			local pos = motor.C0.Position
			motor.C0 = CFrame.new(pos)
		end
		straightenElbow(motorsByName["RightElbow"])
		straightenElbow(motorsByName["LeftElbow"])

		-- Une frame de simulation pour que les Motor6D propagent les positions
		-- aux parts. Sans ce wait, les parts gardent leur position initiale.
		RunService.Stepped:Wait()

		-- Calcule la "reach" : distance horizontale entre HRP et le bout des
		-- mains après pose. On prend la moyenne des deux mains.
		local cHRP = clone:FindFirstChild("HumanoidRootPart")
		local rHand = clone:FindFirstChild("RightHand") or clone:FindFirstChild("Right Arm")
		local lHand = clone:FindFirstChild("LeftHand") or clone:FindFirstChild("Left Arm")
		local reach = 4 -- fallback
		if cHRP then
			local hrpCF = cHRP.CFrame
			local samples = {}
			if rHand then table.insert(samples, hrpCF:PointToObjectSpace(rHand.Position)) end
			if lHand then table.insert(samples, hrpCF:PointToObjectSpace(lHand.Position)) end
			if #samples > 0 then
				local sumZ = 0
				for _, p in ipairs(samples) do
					sumZ = sumZ + p.Z
				end
				-- Z local du HRP : -Z = devant. On prend |Z| comme reach.
				reach = math.abs(sumZ / #samples)
			end
		end

		-- Re-anchore tout : la pose est figée, on peut maintenant tweener le
		-- HRP frame par frame sans recalcul des Motor6D.
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end

		return clone, reach
	end

	-- Met à jour la pose du clone Superman en fonction de la position du bloc.
	-- Le clone est placé derrière le bloc, mains tendues qui touchent la face
	-- arrière. La direction "avant" est calculée dynamiquement à partir de la
	-- vitesse du bloc (delta entre frames). Le tilt est de -90° (corps horiz).
	local function updateSupermanCloneCFrame(clone, blockPos, prevBlockPos, blockHalfDepth, reach)
		if not clone or not clone.Parent then return end
		local hrp = clone:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		local flightDir
		if prevBlockPos then
			local delta = blockPos - prevBlockPos
			-- Pour la direction de "l'avant" du clone, on ne considère que la
			-- composante horizontale de la vitesse (X/Z), sinon le clone
			-- inclinerait avec la trajectoire ce qu'on ne veut pas.
			local flat = Vector3.new(delta.X, 0, delta.Z)
			if flat.Magnitude > 0.01 then
				flightDir = flat.Unit
			end
		end
		if not flightDir then
			flightDir = Vector3.new(-1, 0, 0)
		end

		-- HRP placé derrière le bloc à une distance qui aligne EXACTEMENT le
		-- bout des mains avec la face arrière du bloc :
		--   distance = blockHalfDepth + reach
		local hrpPos = blockPos - flightDir * (blockHalfDepth + reach)

		-- Construit le CFrame : LookVector vers flightDir (clone regarde le bloc),
		-- puis tilt de -90° sur X local pour mettre le corps à l'horizontale.
		local newHrpCF = CFrame.lookAt(hrpPos, hrpPos + flightDir)
		                * CFrame.Angles(-math.rad(90), 0, 0)

		local pivotDelta = newHrpCF * hrp.CFrame:Inverse()
		clone:PivotTo(pivotDelta * clone:GetPivot())
	end

	-- Helper : crée un effet d'impact météorite : juste les débris (cubes)
	-- éparpillés autour de la position d'impact, sans disque central pour ne
	-- pas masquer le sol/zone colorée.
	local function spawnCrater(position)
		local craterFolder = Instance.new("Folder")
		craterFolder.Name = "DunkCrater"
		craterFolder.Parent = Workspace

		-- Débris : 14 petits cubes éparpillés autour, en cercle. Pas de disque central.
		for i = 1, 14 do
			local angle = (i / 14) * math.pi * 2 + math.random() * 0.3
			local dist = 6 + math.random() * 4
			local size = 0.6 + math.random() * 0.9
			local debrisPart = Instance.new("Part")
			debrisPart.Size = Vector3.new(size, size, size)
			debrisPart.CFrame = CFrame.new(
				position.X + math.cos(angle) * dist,
				position.Y + size * 0.3,
				position.Z + math.sin(angle) * dist
			) * CFrame.Angles(
				math.random() * math.pi * 2,
				math.random() * math.pi * 2,
				math.random() * math.pi * 2
			)
			debrisPart.Anchored = true
			debrisPart.CanCollide = false
			debrisPart.CanQuery = false
			debrisPart.CanTouch = false
			debrisPart.Material = Enum.Material.Plastic
			debrisPart.TopSurface = Enum.SurfaceType.Studs
			debrisPart.BottomSurface = Enum.SurfaceType.Studs
			debrisPart.Color = Color3.fromRGB(75, 60, 45)
			debrisPart.Parent = craterFolder
		end

		-- Cleanup auto au bout de 8s.
		Debris:AddItem(craterFolder, 8)
	end

	local function destroyLocalBlock()
		if localBlock and localBlock.Parent then localBlock:Destroy() end
		if localCarrier and localCarrier.Parent then localCarrier:Destroy() end
		localBlock, localCarrier = nil, nil
	end

	dunkSequenceEvent.OnClientEvent:Connect(function(phase, data)
		if phase == "Start" then
			_G.DunkSequenceInProgress = true
			if dunkButton then dunkButton.Visible = false end

			-- Affiche la TopBar.Top (barre de zones) pendant tout le vol.
			if topFrame then topFrame.Visible = true end

			-- Désactive le bouton reset pendant toute la séquence.
			setResetEnabled(false)

			-- Son du vol du lucky block : loopé pendant tout le vol, arrêté à Landed.
			if flightSound and flightSound.Parent then flightSound:Destroy() end
			flightSound = Instance.new("Sound")
			flightSound.SoundId = FLIGHT_SOUND_ID
			flightSound.Volume = 0.8
			flightSound.Looped = true
			flightSound.Parent = SoundService
			flightSound:Play()

			-- Récupère les paramètres de vol.
			local launchOrigin  = data.LaunchOrigin
			local impactPos     = data.ImpactPosition
			local landY         = data.LandY
			local flightDuration= data.FlightDuration
			local peakHeight    = data.PeakHeight
			local serverStart   = data.ServerStartTime
			local grade         = data.Grade -- PERFECT bloque la rotation du block

			-- 1) Clone le LuckyBlock Basic LOCALEMENT sur le client qui a lancé.
			-- L'animation sera donc 100% locale, sans réplication réseau : fluidité max.
			destroyLocalBlock()
			local basicTemplate = ReplicatedStorage:WaitForChild("LuckyBlocks"):WaitForChild("Basic")
			localBlock = basicTemplate:Clone()
			localBlock.Name = "LocalDunkLuckyBlock"
			-- Trouve le PrimaryPart si pas défini.
			if not localBlock.PrimaryPart then
				for _, d in ipairs(localBlock:GetDescendants()) do
					if d:IsA("BasePart") then
						localBlock.PrimaryPart = d
						break
					end
				end
			end

			-- Zero-out les PivotOffset sur toutes les parts : les modèles Roblox
			-- ont souvent un pivot décalé au bas du mesh, ce qui fait que les
			-- rotations paraissent déportées. On remet le pivot au centre géométrique.
			for _, d in ipairs(localBlock:GetDescendants()) do
				if d:IsA("BasePart") then
					d.PivotOffset = CFrame.new()
				end
			end

			-- Applique un scale multiplicatif (ScaleTo est absolu, donc on
			-- multiplie la valeur courante pour rendre le block 2x plus gros).
			local currentScale = localBlock:GetScale()
			localBlock:ScaleTo(currentScale * 2)

			-- Centre le pivot du modèle sur le centre de sa bounding box.
			localBlock.WorldPivot = localBlock:GetBoundingBox()

			for _, d in ipairs(localBlock:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
				end
			end
			localBlock.Parent = Workspace

			-- Place la caméra DERRIÈRE le block avant de passer en mode Custom.
			-- La position initiale est celle du block au début du vol (launchOrigin).
			-- Roblox utilisera cette position comme point de départ, puis le joueur
			-- pourra orbiter librement autour du block pendant le vol.
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = CFrame.new(launchOrigin + Vector3.new(15, 6, 0), launchOrigin)

			-- Bascule en Custom avec le block comme sujet : le joueur peut désormais
			-- bouger la caméra autour du block avec la souris pendant le vol.
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = localBlock.PrimaryPart
			_G.DunkBlockCamera = true

			-- Hauteur du block après scale, pour que le block repose au sol à
			-- la fin du vol.
			local _, scaledSize = localBlock:GetBoundingBox()
			local halfBlockY = scaledSize.Y * 0.5
			local effectiveLandY = landY + halfBlockY

			-- 2) Trail carrier local.
			localCarrier = Instance.new("Part")
			localCarrier.Name = "LocalDunkTrailCarrier"
			localCarrier.Size = Vector3.new(0.1, 0.1, 0.1)
			localCarrier.Transparency = 1
			localCarrier.Anchored = true
			localCarrier.CanCollide = false
			localCarrier.CanQuery = false
			localCarrier.CanTouch = false
			localCarrier.Massless = true
			localCarrier.CFrame = CFrame.new(launchOrigin)
			localCarrier.Parent = Workspace

			local att0 = Instance.new("Attachment")
			att0.Position = Vector3.new(0, 1.2, 0)
			att0.Parent = localCarrier
			local att1 = Instance.new("Attachment")
			att1.Position = Vector3.new(0, -1.2, 0)
			att1.Parent = localCarrier

			local trail = Instance.new("Trail")
			trail.Attachment0 = att0
			trail.Attachment1 = att1
			trail.Lifetime = 0.45
			trail.MinLength = 0.1
			trail.LightEmission = 0.8
			trail.FaceCamera = true
			trail.Color = ColorSequence.new(Color3.fromRGB(255, 210, 100))
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.Parent = localCarrier

			local speedAtt = Instance.new("Attachment")
			speedAtt.Parent = localCarrier
			local speed = Instance.new("ParticleEmitter")
			speed.Parent = speedAtt
			speed.Texture = "rbxassetid://243660364"
			speed.Lifetime = NumberRange.new(0.25, 0.4)
			speed.Rate = 50
			speed.Speed = NumberRange.new(0, 0)
			speed.Rotation = NumberRange.new(-5, 5)
			speed.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.6),
				NumberSequenceKeypoint.new(1, 0),
			})
			speed.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(1, 1),
			})
			speed.Color = ColorSequence.new(Color3.fromRGB(255, 240, 180))
			speed.LightEmission = 1
			speed.LightInfluence = 0
			speed.ZOffset = 1

			-- 3) Fonction d'interpolation de la position du bloc.
			-- Trajectoire : LINÉAIRE en horizontal et en chute Y (pas d'easing
			-- qui donnerait une sensation de ralentissement), avec une parabole
			-- sinusïdale pour la HAUTEUR. peakHeight élevé (10% distance, plafond
			-- 60 studs) côté serveur garantit un arc en "U" bien marqué.
			-- La vitesse horizontale et la vitesse de chute restent CONSTANTES,
			-- seule l'élévation forme l'arc.
			local function computePos(t)
				t = math.clamp(t, 0, 1)
				local lerpPos = launchOrigin:Lerp(
					Vector3.new(impactPos.X, launchOrigin.Y, impactPos.Z), t)
				-- Sommet sinus : courbe symétrique en cloche, sommet à t=0.5,
				-- vitesse verticale max au départ (gicle) et à l'arrivée (plonge).
				local parabola = peakHeight * math.sin(math.pi * t)
				local fallY = launchOrigin.Y + (effectiveLandY - launchOrigin.Y) * t
				return Vector3.new(lerpPos.X, fallY + parabola, lerpPos.Z)
			end

			-- ===== CLONE PERFECT (pose Superman) =====
			-- En PERFECT, le client crée un clone du character du joueur en pose
			-- Superman (corps horizontal, deux bras tendus vers l'avant). Le
			-- clone sera animé dans la même RenderStepped que le bloc → synchro
			-- frame parfaite, zéro saccade réseau.
			local flightCloneReach = 0
			local blockHalfDepth = scaledSize.Z * 0.5
			destroyFlightClone()
			if data.IsPerfect then
				local clone, reach = buildSupermanClone()
				if clone then
					localFlightClone = clone
					flightCloneReach = reach
				end
			end

			-- 4) Animation locale du block. La caméra est en mode Custom suivant
			-- le block : le joueur peut orbiter autour librement avec sa souris.
			-- IMPORTANT : on utilise os.clock() (horloge locale) comme base de temps,
			-- PAS workspace:GetServerTimeNow() qui a du jitter réseau. Le temps
			-- local est parfaitement monotone et lisse frame par frame.
			local localStartTime = os.clock()
			local lastBlockPos = launchOrigin
			local flightConn
			flightConn = RunService.RenderStepped:Connect(function()
				if not _G.DunkBlockCamera then
					if flightConn then flightConn:Disconnect() end
					return
				end
				local elapsed = os.clock() - localStartTime
				local t = elapsed / flightDuration

				if t >= 1 then
					t = 1
				end

				local pos = computePos(t)

				-- Met à jour la position UI de la tête du joueur sur TopBar.Top
				-- en fonction de la position X monde du lucky block en vol.
				if topPlayerImage then
					local uiX = worldXToUIScaleX(pos.X)
					local currentPos = topPlayerImage.Position
					topPlayerImage.Position = UDim2.new(uiX, currentPos.X.Offset, currentPos.Y.Scale, currentPos.Y.Offset)
				end

				-- Rotation LENTE sur les 3 axes pendant tout le vol (purement visuelle).
				-- Désactivée en PERFECT : le clone est accroché au block, on veut
				-- pas qu'il soit ballotté par une rotation excessive.
				local spinT = elapsed
				local spinY, spinX, spinZ = 0, 0, 0
				if grade ~= "PERFECT" then
					spinY = spinT * math.pi * 0.7
					spinX = spinT * math.pi * 0.5
					spinZ = spinT * math.pi * 0.4
				end

				if localBlock and localBlock.Parent then
					if t >= 1 then
						-- Atterrissage : block à plat, sans aucune rotation.
						localBlock:PivotTo(CFrame.new(pos))
					else
						localBlock:PivotTo(CFrame.new(pos) * CFrame.Angles(spinX, spinY, spinZ))
					end
				end
				if localCarrier and localCarrier.Parent then
					localCarrier.CFrame = CFrame.new(pos)
				end

				-- Met à jour la pose du clone Superman EN MÊME TEMPS que le bloc.
				-- Même frame, même temps de calcul → synchro parfaite, zéro
				-- saccade. La direction de vol est calculée à partir du delta
				-- de position entre la frame précédente et la frame courante.
				if localFlightClone and localFlightClone.Parent then
					updateSupermanCloneCFrame(
						localFlightClone,
						pos,
						lastBlockPos,
						blockHalfDepth,
						flightCloneReach
					)
				end
				lastBlockPos = pos

				if t >= 1 then
					if flightConn then flightConn:Disconnect() end
				end
			end)

		elseif phase == "Landed" then
			-- Cache la TopBar.Top dès l'impact.
			if topFrame then topFrame.Visible = false end

			-- Le clone Superman du vol est détruit au moment de l'impact.
			-- Le serveur va spawner un autre clone (qui court) un peu plus tard.
			destroyFlightClone()

			-- Arrête le son du vol et joue le son d'impact.
			if flightSound and flightSound.Parent then
				flightSound:Stop()
				flightSound:Destroy()
				flightSound = nil
			end
			playSound2D(LAND_SOUND_ID, 1.0)

			shakeCamera(camera, 0.5, 0.6)
			-- Garde le block AU SOL, figé (freeze) pour qu'on voie bien qu'il
			-- s'est posé. Le serveur déclenchera SpinStarted après ~1s.
			local impactPos = data and data.ImpactPosition
			if localBlock and localBlock.Parent and impactPos then
				local _, scaledSize = localBlock:GetBoundingBox()
				local halfY = scaledSize.Y * 0.5
				localBlock:PivotTo(CFrame.new(impactPos + Vector3.new(0, halfY, 0)))
			end

			-- Spawn les FX d'impact LOCALEMENT (seul ce joueur les voit).
			if impactPos then
				spawnLocalImpactFX(impactPos)
				-- Spawn aussi le cratère de météorite (disque sombre + débris).
				spawnCrater(impactPos)
			end

			-- Transition caméra cinématique : descend du ciel vers une vue rapprochée
			-- devant le block au sol, avec easing cubique pour un mouvement fluide.
			if impactPos then
				local startCF = camera.CFrame
				camera.CameraType = Enum.CameraType.Scriptable
				_G.DunkBlockCamera = true

				-- Position finale : très proche du spin, bas et zoomé sur le brainrot.
				local target = impactPos + Vector3.new(0, 2, 0)
				local endCamPos = target + Vector3.new(7, 1.5, 0)
				local endCF = CFrame.new(endCamPos, target)

				local TWEEN_DURATION = 1.4
				local tweenStart = os.clock()
				local tweenConn
				tweenConn = RunService.RenderStepped:Connect(function()
					local alpha = math.clamp((os.clock() - tweenStart) / TWEEN_DURATION, 0, 1)
					-- Easing cubique out : démarrage rapide, ralentissement en fin.
					local eased = 1 - (1 - alpha) ^ 3
					camera.CFrame = startCF:Lerp(endCF, eased)
					if alpha >= 1 then
						if tweenConn then tweenConn:Disconnect() end
					end
				end)
			end

		elseif phase == "SpinStarted" then
			-- Le serveur a déclenché le spin : on détruit le block local
			-- (posé au sol pendant 1s) pour laisser place au spin roulette.
			destroyLocalBlock()

			-- La caméra est déjà en Scriptable à la bonne position (depuis Landed).
			-- On la lock juste sur le spin mount pour maintenir la vue.
			local spinMount = data and data.SpinMount
			local impactPos = data and data.ImpactPosition
			if spinMount and spinMount:IsA("BasePart") and impactPos then
				camera.CameraType = Enum.CameraType.Scriptable
				_G.DunkBlockCamera = true

				-- Tick sonore à chaque brainrot affiché pendant le roll : le
				-- serveur remplace le modèle enfant du spinMount à chaque "switch",
				-- donc ChildAdded fire pile au bon moment. Volume bas pour rester
				-- agréable même avec des switchs rapides.
				local tickConn = spinMount.ChildAdded:Connect(function(child)
					if child:IsA("Model") or child:IsA("BasePart") then
						playSound2D(ROLL_TICK_SOUND_ID, 0.35)
					end
				end)
				spinMount.AncestryChanged:Connect(function(_, parent)
					if not parent and tickConn then
						tickConn:Disconnect()
						tickConn = nil
					end
				end)

				local spinConn
				spinConn = RunService.RenderStepped:Connect(function()
					if not _G.DunkBlockCamera or not spinMount.Parent then
						if spinConn then spinConn:Disconnect() end
						return
					end
					local target = spinMount.Position + Vector3.new(0, 2, 0)
					local camPos = target + Vector3.new(7, 1.5, 0)
					camera.CFrame = CFrame.new(camPos, target)
				end)
			end

		elseif phase == "BrainrotPicked" then
			-- On libère la caméra du block pour la passer au brainrot.
			_G.DunkBlockCamera = false
			-- Cache le character du joueur (resté statique au spawn) pour qu'on
			-- ne le voie pas en double avec le brainrot/clone qui court.
			hidePlayerCharacter()
			local brainrot = data and data.BrainrotPath
			if brainrot then
				takeControl(brainrot)
			end

		elseif phase == "WaveRise" then
			-- Fige le brainrot pendant l'animation de la wave (montée + showcase).
			_G.DunkBrainrotFrozen = true

			-- Son d'ambiance loopé pendant toute l'animation de la wave
			-- (rise + showcase + chase). Arrêté à BrainrotLost ou End.
			if waveSound and waveSound.Parent then
				waveSound:Stop(); waveSound:Destroy(); waveSound = nil
			end
			waveSound = Instance.new("Sound")
			waveSound.SoundId = WAVE_SOUND_ID
			waveSound.Volume = 0.7
			waveSound.Looped = false
			waveSound.Parent = SoundService
			waveSound:Play()
			waveSound.Ended:Once(function()
				if waveSound and waveSound.Parent then waveSound:Destroy() end
				waveSound = nil
			end)
			-- Zoom caméra sur la wave pendant qu'elle monte depuis sous le sol.
			-- Caméra FIXE : on la positionne une seule fois depuis la position de
			-- surface fournie par le serveur (W-part de la zone). Elle ne suit
			-- PAS la wave pendant qu'elle monte, on voit juste la vague émerger.
			-- La distance de la caméra est proportionnelle à la taille de la wave
			-- pour qu'on voie toujours la wave entièrement (pas de clipping).
			local surfacePos = data and data.SurfacePosition
			local waveHeight = (data and data.WaveHeight) or 10
			local waveLength = (data and data.WaveLength) or 10
			local modelName  = data and data.ModelName
			local startPos   = data and data.StartPos
			local endPos     = data and data.EndPos
			local waveDir    = data and data.Direction
			local riseDuration = (data and data.RiseDuration) or 2.0

			-- Clone le modèle de wave LOCALEMENT (client only). L'animation est
			-- 60fps+ et seul le joueur local voit sa wave : les autres joueurs ne
			-- la voient pas et ne peuvent pas mourir dedans.
			destroyLocalWave()
			if modelName and startPos and endPos and waveDir then
				local wavesFolder = ReplicatedStorage:FindFirstChild("Waves")
				local template = wavesFolder and wavesFolder:FindFirstChild(modelName)
				if template and template:IsA("Model") then
					localWaveModel = template:Clone()
					localWaveModel.Name = "LocalDunkWave"
					if not localWaveModel.PrimaryPart then
						localWaveModel.PrimaryPart = localWaveModel:FindFirstChild("RootPart")
							or localWaveModel:FindFirstChildWhichIsA("BasePart")
					end
					for _, d in ipairs(localWaveModel:GetDescendants()) do
						if d:IsA("BasePart") then
							d.Anchored = true
							d.CanCollide = false
							d.CanTouch = false
							d.CanQuery = false
						end
					end
					local startCF = CFrame.lookAt(startPos, startPos + waveDir, Vector3.new(0, 1, 0))
					localWaveModel:PivotTo(startCF)
					localWaveModel.Parent = Workspace

					-- Anime la montée en RenderStepped (60fps+). Ease in-out cubic.
					local riseStart = os.clock()
					localWaveRiseConn = RunService.RenderStepped:Connect(function()
						if not localWaveModel or not localWaveModel.Parent then
							if localWaveRiseConn then localWaveRiseConn:Disconnect() localWaveRiseConn = nil end
							return
						end
						local t = math.clamp((os.clock() - riseStart) / riseDuration, 0, 1)
						local eased
						if t < 0.5 then
							eased = 4 * t * t * t
						else
							local f = (2 * t - 2)
							eased = 0.5 * f * f * f + 1
						end
						local pos = startPos:Lerp(endPos, eased)
						localWaveModel:PivotTo(CFrame.lookAt(pos, pos + waveDir, Vector3.new(0, 1, 0)))
						if t >= 1 then
							if localWaveRiseConn then localWaveRiseConn:Disconnect() localWaveRiseConn = nil end
						end
					end)
				end
			end

			if surfacePos then
				camera.CameraType = Enum.CameraType.Scriptable
				_G.DunkWaveCamera = true
				-- Distance caméra : on recule proportionnellement à la plus grande
				-- dimension horizontale pour englober la wave tout en restant
				-- proche pour un rendu cinématique.
				local dist = math.max(waveLength, waveHeight) * 0.7 + 6
				local target = surfacePos + Vector3.new(0, waveHeight * 0.5, 0)
				local camPos = target + Vector3.new(dist, waveHeight * 0.25, 0)
				camera.CFrame = CFrame.new(camPos, target)
			end

		elseif phase == "WaveChase" then
			-- Son de poursuite : joue en boucle tant que le brainrot n'est ni
			-- arrivé (BrainrotSold/End) ni touché (BrainrotLost).
			if chaseSound and chaseSound.Parent then
				chaseSound:Stop(); chaseSound:Destroy(); chaseSound = nil
			end
			chaseSound = Instance.new("Sound")
			chaseSound.SoundId = CHASE_SOUND_ID
			chaseSound.Volume = 0.8
			chaseSound.Looped = true
			chaseSound.Parent = SoundService
			chaseSound:Play()

			-- Délai avant que la wave et le brainrot commencent à bouger : laisse
			-- le temps à la caméra de se repositionner et au joueur de réagir.
			local startDelay = (data and data.StartDelay) or 0
			-- Le brainrot reste figé pendant startDelay, puis on le dégele.
			if startDelay > 0 then
				task.delay(startDelay, function()
					_G.DunkBrainrotFrozen = false
				end)
			else
				_G.DunkBrainrotFrozen = false
			end

			-- Chase de la wave : animé localement en RenderStepped (fluide 60fps+).
			local waveDir = data and data.WaveDirection
			local chaseSpeed = (data and data.ChaseSpeed) or 28
			local stopX = data and data.StopX
			if localWaveModel and localWaveModel.Parent and waveDir then
				-- Stoppe la montée si elle tourne encore (safety).
				if localWaveRiseConn then localWaveRiseConn:Disconnect(); localWaveRiseConn = nil end

				local chaseStart = os.clock() + startDelay
				local lastT = chaseStart
				localWaveChaseConn = RunService.RenderStepped:Connect(function()
					if not localWaveModel or not localWaveModel.Parent then
						if localWaveChaseConn then localWaveChaseConn:Disconnect() localWaveChaseConn = nil end
						return
					end
					local now = os.clock()
					if now < chaseStart then return end -- délai : wave immobile
					local dt = now - lastT
					lastT = now
					local waveCF = localWaveModel:GetPivot()
					local newPos = waveCF.Position + waveDir * (chaseSpeed * dt)
					-- Clamp la position X de la wave à stopX pour qu'elle s'arrête
					-- visuellement pile à la même coordonnée que côté serveur.
					if stopX and waveDir.X > 0 and newPos.X > stopX then
						newPos = Vector3.new(stopX, newPos.Y, newPos.Z)
					end
					localWaveModel:PivotTo(CFrame.lookAt(newPos, newPos + waveDir, Vector3.new(0, 1, 0)))
				end)
			end
			-- Retour caméra sur le brainrot : la wave commence sa poursuite.
			-- Transition FLUIDE : on tween la caméra depuis sa position actuelle
			-- (sur la wave) vers une position DERRIÈRE le brainrot, regardant dans
			-- la direction OPPOSÉE à la wave (pour voir où le brainrot doit fuir).
			-- Puis on bascule en Custom pour laisser le joueur piloter la caméra.
			_G.DunkWaveCamera = false
			local brainrot = data and data.BrainrotPath
			local waveDir = data and data.WaveDirection
			if brainrot and brainrot.Parent then
				local hrp = brainrot:FindFirstChild("HumanoidRootPart")
				local hum = brainrot:FindFirstChildOfClass("Humanoid")
				if hrp and hum and waveDir then
					-- Direction "face" du brainrot = opposé de la direction de la wave.
					local faceDir = Vector3.new(waveDir.X, 0, waveDir.Z)
					if faceDir.Magnitude > 1e-3 then
						faceDir = faceDir.Unit
					else
						faceDir = Vector3.new(1, 0, 0)
					end

					-- Caméra derrière le brainrot (côté opposé de faceDir, i.e.
					-- du côté de la wave) regardant vers faceDir.
					local camBackDir = -faceDir
					local target = hrp.Position + Vector3.new(0, 2, 0)
					local endCamPos = target + camBackDir * 14 + Vector3.new(0, 5, 0)
					local endCF = CFrame.new(endCamPos, target)

					camera.CameraType = Enum.CameraType.Scriptable
					local startCF = camera.CFrame
					local TWEEN_DURATION = 0.8
					local tweenStart = os.clock()
					local tweenConn
					tweenConn = RunService.RenderStepped:Connect(function()
						local alpha = math.clamp((os.clock() - tweenStart) / TWEEN_DURATION, 0, 1)
						-- Easing cubique inout : démarrage doux, vitesse au milieu,
						-- arrêt doux à la fin. Très cinématique.
						local eased
						if alpha < 0.5 then
							eased = 4 * alpha * alpha * alpha
						else
							local f = (2 * alpha - 2)
							eased = 0.5 * f * f * f + 1
						end
						-- Cible "vivante" : on recalcule endCF chaque frame à partir
						-- de la position actuelle du brainrot (qui bouge).
						local liveTarget = hrp.Position + Vector3.new(0, 2, 0)
						local liveEndPos = liveTarget + camBackDir * 14 + Vector3.new(0, 5, 0)
						local liveEndCF = CFrame.new(liveEndPos, liveTarget)
						camera.CFrame = startCF:Lerp(liveEndCF, eased)
						if alpha >= 1 then
							if tweenConn then tweenConn:Disconnect() end
							-- Passe en Custom pour que le joueur puisse bouger la caméra.
							camera.CameraType = Enum.CameraType.Custom
							camera.CameraSubject = hum
						end
					end)
				else
					-- Fallback : pas de direction, bascule instantanée.
					camera.CameraType = Enum.CameraType.Custom
					if hum then camera.CameraSubject = hum end
				end
			end

		elseif phase == "BrainrotLost" then
			-- Le brainrot s'est fait attraper : la caméra repasse sur le character
			-- du joueur et on relâche le contrôle. On laisse End faire le reste.
			_G.DunkWaveCamera = false
			_G.DunkBrainrotFrozen = false
			if waveSound and waveSound.Parent then
				waveSound:Stop(); waveSound:Destroy(); waveSound = nil
			end
			if chaseSound and chaseSound.Parent then
				chaseSound:Stop(); chaseSound:Destroy(); chaseSound = nil
			end
			destroyLocalWave()
			-- Restaure la visibilité du character.
			showPlayerCharacter()
			shakeCamera(camera, 0.4, 0.5)
			releaseControl()

		elseif phase == "BrainrotSold" then
			-- Visual feedback : flash blanc plein écran + confetti qui tombent.
			-- Signale au KickZoneController qu'on vient de gagner un brainrot pour
			-- qu'il reste équipé.
			_G.DunkKeepEquipped = true
			if chaseSound and chaseSound.Parent then
				chaseSound:Stop(); chaseSound:Destroy(); chaseSound = nil
			end
			shakeCamera(camera, 0.25, 0.3)
			playSoldFeedback(player)

		elseif phase == "End" then
			_G.DunkBlockCamera = false
			_G.DunkBrainrotFrozen = false
			if waveSound and waveSound.Parent then
				waveSound:Stop(); waveSound:Destroy(); waveSound = nil
			end
			if chaseSound and chaseSound.Parent then
				chaseSound:Stop(); chaseSound:Destroy(); chaseSound = nil
			end
			destroyLocalWave()
			destroyLocalBlock() -- filet de sécurité
			destroyFlightClone() -- filet de sécurité (devrait être déjà détruit)
			-- Restaure la visibilité du character (filet de sécurité si
			-- BrainrotLost n'a pas été émis avant End).
			showPlayerCharacter()
			releaseControl()
			_G.DunkSequenceInProgress = false

			-- Cache la TopBar.Top (barre de zones).
			if topFrame then topFrame.Visible = false end

			-- Safety : si le vol a été interrompu, stoppe quand même le son.
			if flightSound and flightSound.Parent then
				flightSound:Stop()
				flightSound:Destroy()
				flightSound = nil
			end

			-- Réactive le bouton reset.
			setResetEnabled(true)

			-- Restaure la vitesse et saut du character.
			local character = player.Character
			if character then
				local playerHum = character:FindFirstChildOfClass("Humanoid")
				if playerHum then
					playerHum.WalkSpeed = 16
					playerHum.JumpPower = 50
					playerHum.JumpHeight = 7.2
				end
			end
		end
	end)

	-- Sécurité : si le character disparait pendant la séquence, on relibère.
	player.CharacterRemoving:Connect(function()
		-- Le nouveau character réapparaitra avec sa transparence par défaut,
		-- donc on oublie simplement la table de masquage (les références sont
		-- périmées de toute façon).
		hiddenCharacterParts = nil
		if currentBrainrot then
			releaseControl()
			_G.DunkSequenceInProgress = false
		end
	end)

	print("[DunkLuckyBlockController] Script initialisé!")
end

return DunkLuckyBlockController

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
local VFXPlayer = require(ReplicatedStorage.Shared:WaitForChild("VFXPlayer"))

local DunkLuckyBlockController = Loader.CreateController({
	Name = "DunkLuckyBlockController",
})

-- ===== SONS =====
local FLIGHT_SOUND_ID   = "rbxassetid://139095330035399" -- pendant le vol
local LAND_SOUND_ID     = "rbxassetid://138533090376585" -- impact au sol
local ROLL_TICK_SOUND_ID = "rbxassetid://156286438"      -- tick à chaque brainrot affiché pendant le roll
local WAVE_SOUND_ID     = "rbxassetid://119576268904309" -- ambiance pendant l'animation de la wave
local CHASE_SOUND_ID    = "rbxassetid://1847683499"      -- ambiance pendant la poursuite (WaveChase -> arrivée/touché)
local RARITY_CHANGE_SOUND_ID = "rbxassetid://6079105785"  -- joue à chaque changement de skin du Lucky Block en vol

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

-- Helper : joue le RarityChange sound pour un swap de skin du Lucky Block, avec
-- un PitchShiftSoundEffect dont l'octave varie légèrement à chaque swap pour
-- donner un effet musical "qui monte" (anticipation roulette). Le swapIndex
-- commence à 0 et est incrémenté par chaque appel à worldXToRarity → swap.
local function playRarityChangeSound(swapIndex)
	local s = Instance.new("Sound")
	s.SoundId = RARITY_CHANGE_SOUND_ID
	s.Volume = 0.7
	s.Parent = SoundService

	local pitch = Instance.new("PitchShiftSoundEffect")
	-- Step d'environ un semi-ton (~5.95%). 8 changements possibles max sur un
	-- vol → octave maximum ~1.42, qui reste dans la range valide [0.5; 2].
	pitch.Octave = math.clamp(1 + swapIndex * 0.06, 0.5, 2)
	pitch.Priority = 0
	pitch.Enabled = true
	pitch.Parent = s

	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, math.max(s.TimeLength + 0.5, 4))
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

-- ID sonore (générique) joué au moment où le brainrot franchit KickReady
-- (utilisé en fallback si le brainrot n'a pas de sound configuré).
local SOLD_SOUND_ID = "rbxassetid://109081723292068"

-- Cache du module BrainrotsModule (lookup paresseux : peut ne pas exister
-- en dev). Contient les SoundIds par brainrot.
local _brainrotsModule
local function getBrainrotsModule()
	if _brainrotsModule ~= nil then return _brainrotsModule end
	local m = ReplicatedStorage:FindFirstChild("BrainrotsModule")
	if m then
		local ok, mod = pcall(require, m)
		if ok then _brainrotsModule = mod else _brainrotsModule = false end
	else
		_brainrotsModule = false
	end
	return _brainrotsModule
end

-- Récupère l'asset id du Sound spécifique du brainrot via BrainrotsModule.
-- Le module a une table {[name] = { Sound = <number>, ... }}. Match exact
-- d'abord, puis insensible à la casse.
local function getBrainrotSoundId(brainrotName)
	if not brainrotName or brainrotName == "" then return nil end
	local mod = getBrainrotsModule()
	if not mod or type(mod) ~= "table" then return nil end

	local entry = mod[brainrotName]
	if not entry then
		local target = brainrotName:lower()
		for name, e in pairs(mod) do
			if type(name) == "string" and name:lower() == target then
				entry = e
				break
			end
		end
	end
	if type(entry) ~= "table" then return nil end

	-- Le module utilise parfois "Sound" (PascalCase) et parfois "sound".
	local id = entry.Sound or entry.sound
	if type(id) == "number" then
		return "rbxassetid://" .. tostring(id)
	end
	return nil
end

-- Anim "sold" : flash blanc plein écran + confetti qui tombent depuis le
-- haut. Joué quand le brainrot passe la KickReady et revient au joueur.
local function playSoldFeedback(player, brainrotName)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	-- Priorité : son spécifique du brainrot (BrainrotsModule[<Name>].Sound).
	-- Sinon fallback sur le SOLD_SOUND_ID générique.
	local soundId = getBrainrotSoundId(brainrotName)
	if soundId then
		playSound2D(soundId, 1.0)
	else
		playSound2D(SOLD_SOUND_ID, 1.0)
	end

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

	-- ===== SKIN DU LUCKY BLOCK PAR ZONE =====
	-- Pendant le vol, le skin du Lucky Block change selon la zone de rareté
	-- traversée. Les modèles vivent dans ReplicatedStorage.LUCKBLOCK et leur
	-- nom ne suit pas exactement la rareté interne (ex: Uncommun != Uncommon).
	local RARITY_TO_LUCKBLOCK_NAME = {
		Common    = "Basic",
		Uncommon  = "Uncommun",
		Rare      = "Rare",
		Epic      = "Epic",
		Legendary = "Legendary",
		Mythic    = "Mythic",
		Secret    = "Secret",
		God       = "God",
		OG        = "Og",
	}

	-- 10 keyframes définissent les bordures entre les 9 zones, ordonnées du
	-- plus proche du spawn (Common) au plus loin (OG). Segment[i] couvre
	-- l'intervalle [zoneKeyframes[i+1].x, zoneKeyframes[i].x].
	local ZONE_NAMES_ORDER = {
		"Common", "Uncommon", "Rare", "Epic",
		"Legendary", "Mythic", "Secret", "God", "OG",
	}

	local function worldXToRarity(wx)
		if wx >= zoneKeyframes[1][1] then return ZONE_NAMES_ORDER[1] end
		if wx <= zoneKeyframes[#zoneKeyframes][1] then
			return ZONE_NAMES_ORDER[#ZONE_NAMES_ORDER]
		end
		for i = 1, #zoneKeyframes - 1 do
			if wx <= zoneKeyframes[i][1] and wx >= zoneKeyframes[i + 1][1] then
				return ZONE_NAMES_ORDER[i]
			end
		end
		return ZONE_NAMES_ORDER[#ZONE_NAMES_ORDER]
	end

	local function getLuckBlockTemplate(rarity)
		local folder = ReplicatedStorage:FindFirstChild("LUCKBLOCK")
		if not folder then return nil end
		local name = RARITY_TO_LUCKBLOCK_NAME[rarity] or "Basic"
		return folder:FindFirstChild(name) or folder:FindFirstChild("Basic")
	end

	-- ===== CACHE DES SKINS DE LUCKY BLOCK =====
	-- Pour eliminer les saccades dues au cloning runtime a chaque changement
	-- de zone pendant le vol, on preclone TOUS les skins une fois au demarrage
	-- du controller. Pendant le vol, on ne fait que teleporter les clones (pas
	-- de Clone/ScaleTo/iteration runtime sur le frame de rendu).
	local skinCache = {} -- [rarityName] = Model (clone setup, hors-ecran)
	local skinCacheReady = false

	local function isCachedSkin(model)
		if not model then return false end
		for _, c in pairs(skinCache) do
			if c == model then return true end
		end
		return false
	end

	local function hideAllCachedSkins()
		for _, c in pairs(skinCache) do
			if c and c.Parent then
				c:PivotTo(CFrame.new(0, -100000, 0))
			end
		end
	end

	-- Construit un clone du Lucky Block prêt pour le vol :
	-- pivot recentré, scale x2, parts ancrées, no-collision/no-query/no-touch.
	local function setupLocalBlockClone(template)
		local clone = template:Clone()
		clone.Name = "LocalDunkLuckyBlock"
		if not clone.PrimaryPart then
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then
					clone.PrimaryPart = d
					break
				end
			end
		end
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.PivotOffset = CFrame.new()
			end
		end
		local currentScale = clone:GetScale()
		clone:ScaleTo(currentScale * 2)
		clone.WorldPivot = clone:GetBoundingBox()
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		return clone
	end

	local dunkSequenceEvent = RemotesAPI.GetEvent("DunkSequenceEvent")

	local StarterGui = game:GetService("StarterGui")

	-- Active/désactive la possibilité de se reset (R ou bouton menu).
	-- IMPORTANT : par design on ne ré-active PLUS le reset (jamais re-enable)
	-- pour interdire au joueur de respawn manuellement. Le paramètre `enabled`
	-- est ignoré quand il vaut true : on garde toujours false.
	local function setResetEnabled(enabled)
		local _ = enabled
		pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
	end

	-- Le preload des LuckyBlocks et brainrots Normal est desormais centralise
	-- dans ReplicatedStorage.Shared.AssetPreloader (declenche par le
	-- LoadingScreen au join). Apres le preload, on preclone TOUS les skins de
	-- Lucky Block (un par rarete) et on les garde hors-ecran. Au moment d'un
	-- swap pendant le vol, on teleporte le clone deja pret au lieu de cloner
	-- un nouveau modele : zero saccade.
	task.spawn(function()
		local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
		local preloaderModule = sharedFolder and sharedFolder:FindFirstChild("AssetPreloader")
		if preloaderModule then
			local AssetPreloader = require(preloaderModule)
			AssetPreloader.WaitForEssential()
		end

		-- Preclone chaque skin une fois pour la session entiere. setupLocalBlockClone
		-- applique les transforms necessaires (PivotOffset, ScaleTo x2, anchor,
		-- no-collision). On yield (task.wait) entre chaque pour ne pas figer
		-- une seule frame avec 9 ScaleTo successifs.
		for _, rarity in ipairs(ZONE_NAMES_ORDER) do
			if not skinCache[rarity] then
				local template = getLuckBlockTemplate(rarity)
				if template then
					local clone = setupLocalBlockClone(template)
					clone.Name = "DunkSkin_" .. rarity
					clone:PivotTo(CFrame.new(0, -100000, 0))
					clone.Parent = Workspace
					skinCache[rarity] = clone
				end
			end
			task.wait()
		end
		skinCacheReady = true
	end)

	-- ===== TRANSFORMATION EN BRAINROT (mobile-friendly) =====
	-- Au lieu de spawner un brainrot Model séparé avec sa propre physique et
	-- des inputs custom, on transforme le character du joueur en brainrot :
	-- on weld visuellement le mesh du brainrot sur son HRP, on cache son corps,
	-- et il se déplace avec ses contrôles natifs (joystick mobile inclus).
	local attachedBrainrotVisual = nil -- Model du brainrot weldé au character
	local frozenStateConn = nil -- Heartbeat qui maintient WalkSpeed=0 quand frozen
	local savedCharacterStats = nil -- {WalkSpeed, JumpPower, JumpHeight} avant transformation
	local currentBrainrotWalkSpeed = nil -- vitesse cible pendant la transformation
	local waveSound = nil -- son loópé pendant l'animation de la wave (rise)
	local chaseSound = nil -- son loópé pendant la poursuite (WaveChase -> End/Lost)
	local localWaveModel = nil -- modèle de wave cloné localement (client only)
	local localWaveRiseConn = nil -- RenderStepped pour la montée
	local localWaveChaseConn = nil -- RenderStepped pour le chase

	-- Calcule le Y minimum réel d'un modèle dans le monde (itère les 8 coins
	-- de chaque BasePart). Plus fiable que GetBoundingBox() pour les modeles
	-- multi-meshes.
	local function getWorldMinY(model)
		local minY = math.huge
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local cf = d.CFrame
				local hx, hy, hz = d.Size.X * 0.5, d.Size.Y * 0.5, d.Size.Z * 0.5
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local wp = cf * Vector3.new(sx * hx, sy * hy, sz * hz)
							if wp.Y < minY then minY = wp.Y end
						end
					end
				end
			end
		end
		if minY == math.huge then
			return model:GetPivot().Position.Y
		end
		return minY
	end

	-- Cherche un brainrot template par son nom dans ReplicatedStorage.Brainrots.
	-- Match exact d'abord, puis insensible à la casse en fallback.
	local function findBrainrotTemplate(name)
		local brainrotsFolder = ReplicatedStorage:FindFirstChild("Brainrots")
		if not brainrotsFolder then return nil end
		for _, rarityFolder in ipairs(brainrotsFolder:GetChildren()) do
			if rarityFolder:IsA("Folder") then
				local found = rarityFolder:FindFirstChild(name)
				if found and found:IsA("Model") then return found end
			end
		end
		-- Fallback insensible à la casse.
		local target = name:lower()
		for _, rarityFolder in ipairs(brainrotsFolder:GetChildren()) do
			if rarityFolder:IsA("Folder") then
				for _, m in ipairs(rarityFolder:GetChildren()) do
					if m:IsA("Model") and m.Name:lower() == target then
						return m
					end
				end
			end
		end
		return nil
	end

	-- Calcule le bas réel du character (le plus bas point monde de toutes ses
	-- BaseParts). Sert à aligner le bas du mesh brainrot sur les pieds du character.
	local function getCharacterBottomY(character)
		local minY = math.huge
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("BasePart") then
				local bottom = d.Position.Y - d.Size.Y * 0.5
				if bottom < minY then minY = bottom end
			end
		end
		if minY == math.huge then return character:GetPivot().Position.Y end
		return minY
	end

	-- Attache un mesh brainrot (clone du template) au character du joueur via
	-- un WeldConstraint sur le HRP. Le visuel suit toutes les transforms du
	-- character (marche, saut, etc.) sans physique séparée. Y offset calculé
	-- pour que le bas du mesh tombe pile sur les pieds du character.
	local function attachBrainrotVisualToCharacter(brainrotName)
		local template = findBrainrotTemplate(brainrotName)
		if not template then return nil end

		local character = player.Character
		if not character then return nil end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then return nil end

		local visual = template:Clone()
		visual.Name = "PlayerBrainrotVisual"

		-- PrimaryPart fallback.
		if not visual.PrimaryPart then
			for _, d in ipairs(visual:GetDescendants()) do
				if d:IsA("BasePart") then
					visual.PrimaryPart = d
					break
				end
			end
		end
		local visualPrimary = visual.PrimaryPart
		if not visualPrimary then visual:Destroy(); return nil end

		-- Strip Humanoid / AnimationController / scripts existants : on n'a
		-- besoin que du visuel. On recrée un AnimationController plus bas pour
		-- jouer l'idle.
		local oldHum = visual:FindFirstChildOfClass("Humanoid")
		if oldHum then oldHum:Destroy() end
		local oldAC = visual:FindFirstChildOfClass("AnimationController")
		if oldAC then oldAC:Destroy() end
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("Script") or d:IsA("LocalScript") then
				d:Destroy()
			end
		end

		-- Parts setup : non-ancrées, no-collide, massless. On laisse les Motor6D
		-- internes intacts pour que les anims puissent les bouger.
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
			end
		end

		-- Place le visuel sur le HRP pour mesurer le bas réel du mesh.
		visual:PivotTo(hrp.CFrame)
		local visualBottomY = getWorldMinY(visual)
		local charBottomY = getCharacterBottomY(character)
		-- Translate le mesh pour que son bas tombe pile sur les pieds.
		local yOffset = charBottomY - visualBottomY
		visual:PivotTo(hrp.CFrame * CFrame.new(0, yOffset, 0))

		-- Weld TOUTES les parts non-primaires à la primaire AVANT de welder la
		-- primaire au HRP. Sans ça, les parts orphelines (la plupart des brainrots
		-- sont des collections de parts SANS Motor6D ni Welds entre eux) tombent
		-- au sol dès qu'on parente au Workspace : seule la primaire suit le HRP,
		-- le reste se détache. Même logique que l'ancien setupControllableBrainrot.
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") and d ~= visualPrimary then
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = visualPrimary
				wc.Part1 = d
				wc.Parent = visualPrimary
			end
		end

		-- Weld la PrimaryPart du visuel au HRP du character. WeldConstraint
		-- capture la position relative au moment de la création : le yOffset
		-- calculé ci-dessus est donc "figé" et le mesh suivra le HRP partout.
		local weld = Instance.new("WeldConstraint")
		weld.Name = "BrainrotVisualWeld"
		weld.Part0 = hrp
		weld.Part1 = visualPrimary
		weld.Parent = visualPrimary

		-- Animator : joue l'idle du brainrot en boucle si dispo.
		local ac = Instance.new("AnimationController")
		ac.Parent = visual
		local animator = Instance.new("Animator")
		animator.Parent = ac

		local animsFolder = visual:FindFirstChild("Anims") or visual:FindFirstChild("Animations")
		if animsFolder then
			local idleAnim = animsFolder:FindFirstChild("Idle") or animsFolder:FindFirstChildWhichIsA("Animation")
			if idleAnim and idleAnim:IsA("Animation") then
				local track = animator:LoadAnimation(idleAnim)
				track.Looped = true
				track.Priority = Enum.AnimationPriority.Idle
				track:Play()
			end
		end

		visual.Parent = Workspace
		return visual
	end

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
		-- Stoppe la boucle de freeze si elle tourne.
		if frozenStateConn then
			frozenStateConn:Disconnect()
			frozenStateConn = nil
		end

		-- Réactive les contrôles natifs du PlayerModule. DunkGameController les
		-- a desactives via controls:Disable() pendant l'animation de tir et
		-- personne ne les rallume avant ici. Sans ce bloc, joystick mobile et
		-- WASD restent figes apres la sequence (mort par wave OU dunk reussi).
		pcall(function()
			local PlayerScripts = player:WaitForChild("PlayerScripts")
			local PlayerModule = require(PlayerScripts:WaitForChild("PlayerModule"))
			local controls = PlayerModule:GetControls()
			controls:Enable()
		end)

		-- Le visuel brainrot est détruit par le serveur (PlayerBrainrotTransform.Remove).
		-- Le client efface juste sa référence locale.
		attachedBrainrotVisual = nil
		currentBrainrotWalkSpeed = nil

		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local h = character and character:FindFirstChildOfClass("Humanoid")
		local playerHRP = character and character:FindFirstChild("HumanoidRootPart")
		if h then
			camera.CameraSubject = h
			h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			h:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
			-- Force WalkSpeed > 0 immédiatement, car le freezeStateConn a pu
			-- l'ecrire à 0 et le client garde l'autorité sur son Humanoid (network
			-- ownership). Sans ça, le joueur reste figé même après la séquence.
			local StarterPlayer = game:GetService("StarterPlayer")
			h.WalkSpeed = StarterPlayer.CharacterWalkSpeed
			h.JumpPower = StarterPlayer.CharacterJumpPower
			h.JumpHeight = StarterPlayer.CharacterJumpHeight
		end

		-- ===== SÉCURITÉ ANTI-BUG REPRISE DE CONTRÔLE =====
		if playerHRP then
			playerHRP.AssemblyLinearVelocity = Vector3.zero
			playerHRP.AssemblyAngularVelocity = Vector3.zero
		end
		if h then
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

		savedCharacterStats = nil
	end

	local function takeControl(brainrotName, walkSpeed, jumpPower)
		local character = player.Character
		if not character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not hrp then return end

		-- Cleanup au cas où une transformation précédente serait encore active
		-- (cas du fallback dans WaveChase si BrainrotPicked a été raté).
		if frozenStateConn then
			frozenStateConn:Disconnect()
			frozenStateConn = nil
		end

		-- Sauvegarde les stats originales du character pour restauration au End.
		savedCharacterStats = {
			WalkSpeed = humanoid.WalkSpeed,
			JumpPower = humanoid.JumpPower,
			JumpHeight = humanoid.JumpHeight,
		}

		-- Le serveur a déjà weldé le visuel brainrot sur le character et réglé
		-- la WalkSpeed correctement côté serveur. Le client n'a plus besoin de
		-- toucher à humanoid.WalkSpeed (network ownership = client peut quand
		-- même override, mais on évite). On stocke juste la cible pour le
		-- mécanisme de freeze pendant la wave.
		local targetSpeed = tonumber(walkSpeed)
		if not targetSpeed or targetSpeed <= 0 then
			targetSpeed = humanoid.WalkSpeed
			if targetSpeed <= 0 then targetSpeed = 16 end
		end
		local targetJump = tonumber(jumpPower)
		if not targetJump or targetJump <= 0 then
			targetJump = 55
		end
		currentBrainrotWalkSpeed = targetSpeed

		-- Réactive les contrôles natifs du PlayerModule. CRITICAL : DunkGameController
		-- les a desactives via controls:Disable() pendant l'animation de tir, et
		-- personne ne les rallume. Sans ce bloc, le joystick mobile et WASD
		-- restent figes apres la sequence Dunk meme si WalkSpeed > 0.
		pcall(function()
			local PlayerScripts = player:WaitForChild("PlayerScripts")
			local PlayerModule = require(PlayerScripts:WaitForChild("PlayerModule"))
			local controls = PlayerModule:GetControls()
			controls:Enable()
		end)

		-- Force la WalkSpeed/JumpPower côté client. Même si le serveur les a
		-- déjà réglées, le client a network ownership sur son Humanoid et son
		-- cache local peut avoir un WalkSpeed=0 résiduel (depuis le précédent
		-- freezeStateConn) qui écrase la valeur serveur.
		humanoid.WalkSpeed = targetSpeed
		humanoid.JumpPower = targetJump
		humanoid.UseJumpPower = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)

		-- Marker pour les autres logiques (freeze pendant wave, releaseControl).
		-- On utilise une référence vers le visuel server-spawned (s'il existe)
		-- ou un marker truthy pour indiquer qu'une transformation est active.
		attachedBrainrotVisual = character:FindFirstChild("PlayerBrainrotVisual") or true

		-- Caméra : reste sur l'humanoid du character (qui devient le brainrot).
		-- Roblox suit nativement le character donc le joystick mobile / clavier /
		-- gamepad fonctionnent tous sans rien réinventer.
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid

		-- Heartbeat de freeze : tant que _G.DunkBrainrotFrozen est true (pendant
		-- WaveRise + showcase), on remet WalkSpeed=0 et on bloque le saut. Dès
		-- que le flag retombe, on rétablit WalkSpeed=targetSpeed pour relancer
		-- la fuite.
		if frozenStateConn then frozenStateConn:Disconnect() end
		local wasFrozen = false
		frozenStateConn = RunService.Heartbeat:Connect(function()
			if not attachedBrainrotVisual then return end
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not hum then return end
			local frozen = _G.DunkBrainrotFrozen == true
			if frozen and not wasFrozen then
				hum.WalkSpeed = 0
				hum.JumpPower = 0
				hum.JumpHeight = 0
				hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				wasFrozen = true
			elseif not frozen and wasFrozen then
				hum.WalkSpeed = currentBrainrotWalkSpeed or hum.WalkSpeed
				hum.JumpPower = targetJump
				hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				wasFrozen = false
			end
		end)
	end

	local localBlock, localCarrier -- Lucky block cloné localement (client only)
	local currentLuckBlockSkin -- nom de la rareté du skin actuellement affiché (Common, Uncommon, ...)
	local luckyBlockSwapCount -- nombre de swaps de skin depuis le début du vol (sert pour le pitch shift)
	local localFlightClone -- Clone PERFECT (Superman) cloné localement
	local flightSound -- Sound actif pendant le vol (stoppé à l'impact).

	-- ===== HELPERS POSE SUPERMAN =====
	-- Construit un clone du character du joueur en pose Superman, parenté au
	-- workspace, anchored, prêt à être tweené frame par frame en même temps
	-- que le bloc. Le clone est positionné derrière le bloc, corps horizontal,
	-- les deux bras tendus vers l'avant qui touchent l'arrière du bloc.

	-- Forward declaration : poseArmsForward est défini plus bas mais utilisé
	-- dans buildSupermanClone (qui suit immédiatement).
	local poseArmsForward

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

		-- Désactive le humanoid pour qu'il ne rejoue pas d'animations idle/fall.
		-- IMPORTANT : on GARDE le Humanoid (sinon les vêtements layered clothing
		-- et certains accessoires ne se rendent plus). À la place, on détruit
		-- l'Animator : sans Animator, aucune animation ne peut tourner et donc
		-- la pose qu'on applique manuellement reste figée frame par frame.
		local hum = clone:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.PlatformStand = true
			hum.AutoRotate = false
			-- Désactive tous les states pour bloquer toute simulation interne.
			for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
				pcall(function() hum:SetStateEnabled(state, false) end)
			end
			local animator = hum:FindFirstChildOfClass("Animator")
			if animator then
				for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
					t:Stop(0)
				end
				-- Détruit l'Animator : aucune animation ne pourra plus s'exécuter,
				-- donc la pose Motor6D ne sera jamais écrasée.
				animator:Destroy()
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

		-- Stocke les C0 originaux (pour référence/debug, on n'écrit plus dessus).
		local originalC0 = {}
		for name, motor in pairs(motorsByName) do
			originalC0[name] = motor.C0
		end

		-- DÉTRUIRE les Motor6D des bras pour que les parts soient complètement
		-- indépendantes du rig. Sans ça, même si on place les parts manuellement,
		-- la simulation interne peut tenter de les replacer selon C0/C1 du rig
		-- d'origine et les bras restent "collés au corps".
		local armMotorNames = {
			"RightShoulder", "RightElbow", "RightWrist",
			"LeftShoulder",  "LeftElbow",  "LeftWrist",
			"Right Shoulder", "Left Shoulder",  -- R6
		}
		for _, name in ipairs(armMotorNames) do
			local m = motorsByName[name]
			if m then m:Destroy() end
		end

		-- Calcule la "reach" : longueur TOTALE du bras une fois pose en
		-- Superman (du HRP jusqu'au bout de la main). On somme la Size.Y des
		-- parts du bras (UpperArm + LowerArm + Hand pour R15, Arm pour R6) car
		-- poseArmsForward les place bout a bout le long de l'UpVector du HRP.
		-- Sans ce calcul correct, on mesurait la position des mains en pose
		-- defaut (bras le long du corps, ~0.5 stud) au lieu de la pose Superman
		-- (~2.5 studs), donc le HRP etait place trop pres du bloc et les bras
		-- en pose tendus passaient au-dela : les mains se retrouvaient DANS le
		-- bloc et le pivot d'inclinaison se faisait au torse au lieu des mains.
		local function calcArmChainLength(side)
			local upperArm = clone:FindFirstChild(side .. "UpperArm")
			local lowerArm = clone:FindFirstChild(side .. "LowerArm")
			local hand     = clone:FindFirstChild(side .. "Hand")
			local r6Arm    = clone:FindFirstChild(side .. " Arm")
			if upperArm then
				local total = upperArm.Size.Y
				if lowerArm then total = total + lowerArm.Size.Y end
				if hand then total = total + hand.Size.Y end
				return total
			elseif r6Arm then
				return r6Arm.Size.Y
			end
			return nil
		end
		local rightLen = calcArmChainLength("Right")
		local leftLen = calcArmChainLength("Left")
		local reach = 4 -- fallback si aucun bras detecte
		local armSamples = {}
		if rightLen then table.insert(armSamples, rightLen) end
		if leftLen then table.insert(armSamples, leftLen) end
		if #armSamples > 0 then
			local sum = 0
			for _, l in ipairs(armSamples) do sum = sum + l end
			reach = sum / #armSamples
		end

		-- Re-anchore tout : la pose est figée, on peut maintenant tweener le
		-- HRP frame par frame sans recalcul des Motor6D. On GARDE le Humanoid
		-- pour que les vêtements layered clothing et accessoires se rendent
		-- correctement (l'Animator a déjà été détruit, donc rien ne peut plus
		-- bouger les Motor6D).
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end

		return clone, reach
	end

	-- Pose les bras du clone tendus EN DIRECTION DU BLOC (assignation à la
	-- variable forward-declarée plus haut, pour que buildSupermanClone puisse
	-- l'appeler).
	poseArmsForward = function(clone)
		local hrp = clone:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local torsoCF = hrp.CFrame
		local towardBlock = torsoCF.UpVector
		local rightVec = torsoCF.RightVector

		local function placeArmChain(side, sideMul)
			-- Cherche les parts du bras (R15) ou la part R6.
			local upperArm = clone:FindFirstChild(side .. "UpperArm")
			local lowerArm = clone:FindFirstChild(side .. "LowerArm")
			local hand     = clone:FindFirstChild(side .. "Hand")
			local r6Arm    = clone:FindFirstChild(side .. " Arm")

			-- Position de l'épaule dans le repère HRP : sur le côté du torse, au
			-- niveau du milieu du torse (= centre du HRP). Avec Y=0 on est au
			-- niveau des épaules anatomiques.
			local shoulderLocalOffset = Vector3.new(sideMul * 1.0, 0, 0)
			local shoulderWorld = torsoCF * shoulderLocalOffset

			-- Construit l'orientation : longueur de la part (axe Y) alignée avec
			-- towardBlock. La part s'étend depuis l'épaule vers le bloc.
			local function placePartOnAxis(part, distFromShoulder)
				if not part then return end
				local halfY = part.Size.Y * 0.5
				local centerWorld = shoulderWorld + towardBlock * (distFromShoulder + halfY)
				part.CFrame = CFrame.fromMatrix(centerWorld, rightVec, towardBlock)
			end

			if upperArm then
				-- R15 : trois parts placées bout à bout selon Size.Y.
				placePartOnAxis(upperArm, 0)
				local accumLen = upperArm.Size.Y
				if lowerArm then
					placePartOnAxis(lowerArm, accumLen)
					accumLen = accumLen + lowerArm.Size.Y
					if hand then
						placePartOnAxis(hand, accumLen)
					end
				end
			elseif r6Arm then
				-- R6 : une seule part par bras.
				placePartOnAxis(r6Arm, 0)
			end
		end

		placeArmChain("Right",  1)
		placeArmChain("Left",  -1)
	end

	-- Met a jour la pose du clone Superman en fonction de la position du bloc.
	-- IMPORTANT : le pivot d'inclinaison doit etre aux MAINS (au point de
	-- contact avec l'arriere du bloc), pas au centre du corps. Sans ca, quand
	-- le clone s'incline avec la trajectoire, ses mains se decrochent du bloc.
	-- On calcule donc d'abord le point d'ancrage (mains au bord arriere du
	-- bloc), on construit l'orientation cible avec le pitch, puis on place le
	-- HRP en arriere de l'ancrage le long de l'axe "corps -> mains" du clone.
	-- EXTRA_BACK_OFFSET = 0 : les mains touchent EXACTEMENT le centre de la
	-- face arriere du bloc. Pas de marge supplementaire, sinon les mains se
	-- decrochent visiblement du bloc.
	local EXTRA_BACK_OFFSET = 0
	-- Limite l'inclinaison +/- pour que le clone reste lisible. 15 deg donne
	-- Inclinaison subtile qui suggère la trajectoire sans deformer la pose.
	local MAX_PITCH_DEG = 15
	-- Facteur de lissage exponentiel sur le pitch (par seconde). Diminué à 4
	-- pour atténuer les saccades visuelles : la pose suit doucement les
	-- variations de pente plutôt que de coller frame par frame.
	local PITCH_SMOOTHING = 4
	local smoothedPitch = 0
	local lastPitchTime = nil
	local function updateSupermanCloneCFrame(clone, blockPos, prevBlockPos, blockHalfDepth, reach)
		if not clone or not clone.Parent then return end
		local hrp = clone:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		local flightDir
		local targetPitch = 0
		if prevBlockPos then
			local delta = blockPos - prevBlockPos
			local flat = Vector3.new(delta.X, 0, delta.Z)
			local flatMag = flat.Magnitude
			if flatMag > 0.01 then
				flightDir = flat.Unit
				-- Pente : positive en montee, negative en descente.
				targetPitch = math.atan2(delta.Y, flatMag)
			end
		end
		if not flightDir then
			flightDir = Vector3.new(-1, 0, 0)
		end

		-- Lissage exponentiel framerate-independent du pitch.
		local now = os.clock()
		local dt = lastPitchTime and (now - lastPitchTime) or 0
		lastPitchTime = now
		local alpha = 1 - math.exp(-PITCH_SMOOTHING * math.max(dt, 0))
		smoothedPitch = smoothedPitch + (targetPitch - smoothedPitch) * alpha
		local pitchClamped = math.clamp(smoothedPitch, -math.rad(MAX_PITCH_DEG), math.rad(MAX_PITCH_DEG))

		-- Point d'ancrage : ou les mains touchent l'arriere du bloc. C'est ce
		-- point qui doit rester FIXE quand le pitch change.
		local anchorPos = blockPos - flightDir * (blockHalfDepth + EXTRA_BACK_OFFSET)

		-- Construit l'orientation cible du HRP en pose Superman tiltee :
		--   LookVector = -UpVector_original (pointe vers le bas en pitch=0)
		--   UpVector   = flightDir incline du pitch (pointe vers les mains)
		-- Le UpVector du HRP est EXACTEMENT l'axe "corps -> mains" du clone, donc
		-- on s'en sert pour reculer le HRP a partir du point d'ancrage.
		local baseCF = CFrame.lookAt(Vector3.zero, flightDir)
		                * CFrame.Angles(-math.rad(90) + pitchClamped, 0, 0)
		local cloneUp = baseCF.UpVector

		-- HRP = ancrage des mains - reach * direction_corps_vers_mains.
		local hrpPos = anchorPos - cloneUp * reach
		local newHrpCF = baseCF + hrpPos

		local pivotDelta = newHrpCF * hrp.CFrame:Inverse()
		clone:PivotTo(pivotDelta * clone:GetPivot())

		-- Pose les bras tendus vers le bloc apres le PivotTo, pour qu'ils
		-- suivent l'orientation actuelle du HRP.
		poseArmsForward(clone)
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
		-- Si localBlock est un clone du cache, on ne le detruit pas : on le
		-- replanque hors-ecran pour la prochaine fois.
		if localBlock and localBlock.Parent then
			if isCachedSkin(localBlock) then
				localBlock:PivotTo(CFrame.new(0, -100000, 0))
			else
				localBlock:Destroy()
			end
		end
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

			-- 1) Selectionne le skin de la zone de DEPART depuis le cache (preclone
			-- au demarrage du controller). Aucun cloning runtime = aucune saccade.
			-- Fallback : si le cache n'est pas encore pret (debut de session), on
			-- clone a la volee.
			destroyLocalBlock()
			local initialRarity = worldXToRarity(launchOrigin.X)
			hideAllCachedSkins()
			localBlock = skinCache[initialRarity]
			if not localBlock then
				local initialTemplate = getLuckBlockTemplate(initialRarity)
				if not initialTemplate then
					initialTemplate = ReplicatedStorage:WaitForChild("LuckyBlocks"):WaitForChild("Basic")
				end
				localBlock = setupLocalBlockClone(initialTemplate)
				localBlock.Parent = Workspace
			end
			currentLuckBlockSkin = initialRarity
			luckyBlockSwapCount = 0 -- reset compteur pour le pitch shift

			-- Place la caméra DERRIÈRE le block avant de passer en mode Custom.
			-- La position initiale est celle du block au début du vol (launchOrigin).
			-- Roblox utilisera cette position comme point de départ, puis le joueur
			-- pourra orbiter librement autour du block pendant le vol.
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = CFrame.new(launchOrigin + Vector3.new(15, 6, 0), launchOrigin)

			-- Bascule en Custom immédiatement (CameraSubject sera assigné au
			-- localCarrier juste après sa création, plus bas dans cette fonction).
			camera.CameraType = Enum.CameraType.Custom
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

			-- La caméra suit le carrier (qui ne change jamais d'instance), pas
			-- le localBlock qui swap d'instance à chaque zone -> évite les jumps.
			camera.CameraSubject = localCarrier

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
			-- En PERFECT, le client cree un clone du character du joueur en pose
			-- Superman (corps horizontal, deux bras tendus vers l'avant). Le
			-- clone sera anime dans la meme RenderStepped que le bloc -> synchro
			-- frame parfaite, zero saccade reseau.
			local flightCloneReach = 0
			local blockHalfDepth = scaledSize.Z * 0.5
			destroyFlightClone()
			-- Reset du pitch lisse pour que le nouveau vol parte d'une pose neutre.
			smoothedPitch = 0
			lastPitchTime = nil
			if data.IsPerfect then
				local clone, reach = buildSupermanClone()
				if clone then
					localFlightClone = clone
					flightCloneReach = reach
				end
			end

			-- 4) Animation locale du block. La caméra est en mode Custom suivant
			-- le carrier : le joueur peut orbiter autour librement avec sa souris.
			-- IMPORTANT : on utilise BindToRenderStep avec priorité Camera-1 pour
			-- bouger le bloc et le carrier AVANT que la caméra lise leur position.
			-- Sinon la caméra utilise la position de la frame précédente -> jitter
			-- d'1 frame perceptible comme du saccé.
			local localStartTime = os.clock()
			local lastBlockPos = launchOrigin
			local RENDER_STEP_NAME = "DunkLuckyBlockFlight"
			local flightConn = nil -- inutilisé, conservé pour compat avec le code en aval
			local flightActive = true
			RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value - 1, function()
				if not flightActive then return end
				if not _G.DunkBlockCamera then
					flightActive = false
					pcall(function() RunService:UnbindFromRenderStep(RENDER_STEP_NAME) end)
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

				-- Swap du skin du Lucky Block selon la zone (rarete) traversee
				-- pendant le vol. On teleporte le clone deja prepare au demarrage
				-- (cache) et on planque l'ancien hors-ecran. Aucun Clone/ScaleTo
				-- runtime = zero saccade. Le swap n'a lieu QUE quand on franchit
				-- une frontiere de zone (max ~9 fois sur tout le vol).
				local newRarity = worldXToRarity(pos.X)
				if newRarity ~= currentLuckBlockSkin then
					local newBlock = skinCache[newRarity]
					if not newBlock then
						-- Fallback : cache pas pret pour ce skin, on clone a la volee.
						local newTemplate = getLuckBlockTemplate(newRarity)
						if newTemplate then
							newBlock = setupLocalBlockClone(newTemplate)
							newBlock.Parent = Workspace
						end
					end
					if newBlock then
						local oldBlock = localBlock
						localBlock = newBlock
						currentLuckBlockSkin = newRarity
						luckyBlockSwapCount = (luckyBlockSwapCount or 0) + 1
						-- Planque l'ancien hors-ecran (cache) ou detruit (fallback).
						if oldBlock and oldBlock.Parent then
							if isCachedSkin(oldBlock) then
								oldBlock:PivotTo(CFrame.new(0, -100000, 0))
							else
								oldBlock:Destroy()
							end
						end
						if newBlock.PrimaryPart then
							-- Pas de camera.CameraSubject = newBlock : le carrier est déjà
							-- le sujet depuis le début du vol pour éviter les jumps de
							-- caméra à chaque swap de zone.
							VFXPlayer.PlayOnPart("SlapVFX", newBlock.PrimaryPart)
						end
						-- Son RarityChange avec pitch qui monte a chaque swap.
						playRarityChangeSound(luckyBlockSwapCount)
					end
				end

				if localBlock and localBlock.Parent then
					-- Orientation de base : -90 deg sur Y pour que les blocks soient
					-- dans le bon sens (sinon ils apparaissent latéralisés).
					local baseRot = CFrame.Angles(0, math.rad(-90), 0)
					if t >= 1 then
						-- Atterrissage : block à plat, sans spin (mais base rotation).
						localBlock:PivotTo(CFrame.new(pos) * baseRot)
					else
						localBlock:PivotTo(CFrame.new(pos) * baseRot * CFrame.Angles(spinX, spinY, spinZ))
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
					flightActive = false
					pcall(function() RunService:UnbindFromRenderStep(RENDER_STEP_NAME) end)
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
				-- Pose le block au sol AVEC la rotation -90 deg sur Y, comme
				-- pendant le vol, pour qu'il garde la même orientation visuelle.
				localBlock:PivotTo(CFrame.new(impactPos + Vector3.new(0, halfY, 0)) * CFrame.Angles(0, math.rad(-90), 0))
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
			-- On libère la caméra du block.
			_G.DunkBlockCamera = false
			-- Le serveur a déjà weldé le mesh brainrot sur le character et caché
			-- le corps original (via PlayerBrainrotTransform). Le client n'a plus
			-- qu'à ajuster la caméra et hooker le mécanisme de freeze pour les
			-- phases de wave.
			local brainrotName = data and data.BrainrotName
			if brainrotName then
				takeControl(brainrotName, data.WalkSpeed, data.JumpPower)
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
			-- Sécurité : si pour une raison quelconque BrainrotPicked n'a pas été
			-- appliqué (race condition réseau, frame drop), on récupère le contrôle
			-- ici. Sinon le joueur reste sur son character d'origine après la
			-- wave et ne peut pas courir.
			local brainrotNameForControl = data and data.BrainrotName
			if brainrotNameForControl and not attachedBrainrotVisual then
				takeControl(brainrotNameForControl, data.WalkSpeed, data.JumpPower)
			end

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
			-- Retour caméra sur le character (qui est devenu le brainrot via
			-- weld). Transition FLUIDE : on tween la caméra depuis sa position
			-- actuelle (sur la wave) vers une position DERRIÈRE le character,
			-- regardant dans la direction OPPOSÉE à la wave (pour voir où fuir).
			-- Puis on bascule en Custom pour laisser le joueur piloter la caméra.
			_G.DunkWaveCamera = false
			local waveDir = data and data.WaveDirection
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			local hum = character and character:FindFirstChildOfClass("Humanoid")
			if hrp and hum and waveDir then
				local faceDir = Vector3.new(waveDir.X, 0, waveDir.Z)
				if faceDir.Magnitude > 1e-3 then
					faceDir = faceDir.Unit
				else
					faceDir = Vector3.new(1, 0, 0)
				end

				local camBackDir = -faceDir
				camera.CameraType = Enum.CameraType.Scriptable
				local startCF = camera.CFrame
				local TWEEN_DURATION = 0.8
				local tweenStart = os.clock()
				local tweenConn
				tweenConn = RunService.RenderStepped:Connect(function()
					local alpha = math.clamp((os.clock() - tweenStart) / TWEEN_DURATION, 0, 1)
					local eased
					if alpha < 0.5 then
						eased = 4 * alpha * alpha * alpha
					else
						local f = (2 * alpha - 2)
						eased = 0.5 * f * f * f + 1
					end
					-- Cible "vivante" : on recalcule chaque frame depuis la position
					-- actuelle du character (qui bouge).
					local liveCharHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if liveCharHRP then
						local liveTarget = liveCharHRP.Position + Vector3.new(0, 2, 0)
						local liveEndPos = liveTarget + camBackDir * 14 + Vector3.new(0, 5, 0)
						local liveEndCF = CFrame.new(liveEndPos, liveTarget)
						camera.CFrame = startCF:Lerp(liveEndCF, eased)
					end
					if alpha >= 1 then
						if tweenConn then tweenConn:Disconnect() end
						camera.CameraType = Enum.CameraType.Custom
						camera.CameraSubject = hum
					end
				end)
			else
				-- Fallback : pas de direction, bascule instantanée.
				camera.CameraType = Enum.CameraType.Custom
				if hum then camera.CameraSubject = hum end
			end

		elseif phase == "BrainrotLost" then
			-- Le brainrot s'est fait attraper. Le serveur va gérer la restauration
			-- visuelle du character via PlayerBrainrotTransform.Remove.
			_G.DunkWaveCamera = false
			_G.DunkBrainrotFrozen = false
			if waveSound and waveSound.Parent then
				waveSound:Stop(); waveSound:Destroy(); waveSound = nil
			end
			if chaseSound and chaseSound.Parent then
				chaseSound:Stop(); chaseSound:Destroy(); chaseSound = nil
			end
			destroyLocalWave()
			shakeCamera(camera, 0.4, 0.5)
			releaseControl()

			-- Force WalkSpeed/JumpPower pendant 2s pour battre tout cache local
			-- residuel a 0 (depuis le freeze pendant WaveRise).
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum then
				local StarterPlayer = game:GetService("StarterPlayer")
				local forceStart = os.clock()
				local forceConn
				forceConn = RunService.Heartbeat:Connect(function()
					if not hum or not hum.Parent or os.clock() - forceStart > 2.0 then
						if forceConn then forceConn:Disconnect() end
						return
					end
					if hum.WalkSpeed < StarterPlayer.CharacterWalkSpeed then
						hum.WalkSpeed = StarterPlayer.CharacterWalkSpeed
					end
					if hum.JumpPower < StarterPlayer.CharacterJumpPower then
						hum.JumpPower = StarterPlayer.CharacterJumpPower
					end
				end)
			end

		elseif phase == "BrainrotSold" then
			-- Visual feedback : flash blanc plein écran + confetti qui tombent.
			-- Signale au KickZoneController qu'on vient de gagner un brainrot pour
			-- qu'il reste équipé.
			_G.DunkKeepEquipped = true
			if chaseSound and chaseSound.Parent then
				chaseSound:Stop(); chaseSound:Destroy(); chaseSound = nil
			end
			shakeCamera(camera, 0.25, 0.3)
			playSoldFeedback(player, data and data.BrainrotName)

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

			-- Note: WalkSpeed/JumpPower sont déjà restaurés côté serveur dans
			-- DunkLuckyBlockService après PlayerBrainrotTransform.Remove.
		end
	end)

	-- Sécurité : si le character disparait pendant la séquence, on relibère.
	player.CharacterRemoving:Connect(function()
		-- Le nouveau character réapparaitra avec sa transparence par défaut,
		-- donc on oublie simplement la table de masquage (les références sont
		-- périmées de toute façon).
		hiddenCharacterParts = nil
		if attachedBrainrotVisual then
			releaseControl()
			_G.DunkSequenceInProgress = false
		end
	end)

	print("[DunkLuckyBlockController] Script initialisé!")
end

return DunkLuckyBlockController

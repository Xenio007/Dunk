--[[
	DunkLuckyBlockService
	Orchestre toute la séquence côté serveur après que le joueur a terminé
	le mini-jeu Dunk :

		1. Anim courte (placeholder) + lancer du LuckyBlock Basic en "météorite".
		2. Impact au sol : effet de poussière + FX + sons.
		3. Spin : le bloc tourne sur lui-même, une silhouette noire de brainrot
		   cyclée change rapidement (effet de "roulette").
		4. Un brainrot aléatoire (Normal) est choisi ; le joueur prend le
		   contrôle d'un pseudo-personnage qui est ce brainrot.
		5. Quand le brainrot franchit un BlockPart du model Sell, il est ajouté
		   à l'inventaire du joueur et le contrôle retourne à son Character.

	Remotes exposés :
		DunkRequestEvent (Client -> Server) : déclenche la séquence.
		DunkSequenceEvent (Server -> Client) : annonce les étapes ("Start",
			"Landed", "BrainrotPicked", "BrainrotSold", "End") au DunkLuckyBlockController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local SpeedConfig = require(ReplicatedStorage:WaitForChild("SpeedConfig"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local DunkLuckyBlockService = Loader.CreateService({
	Name = "DunkLuckyBlockService",
})

-- Résolu au Start (Loader garantit que tous les services sont chargés avant Start).
local DunkCloneService


-- ===== Constantes =====

-- Zone de dunk côté client (KickReady). On retrouve le même dossier côté serveur
-- pour calculer le point d'impact du LuckyBlock.
local SPAWN_FOLDER_NAME = "Spawn"
local AREAS_FOLDER_NAME = "Areas"
local KICK_READY_NAME    = "KickReady"
local SELL_MODEL_NAME    = "Sell"
local BLOCK_PART_NAME    = "BlockPart"

-- Durée de référence de la chute (ajustée selon la distance dans runSequence).
local FALL_DURATION = 1.5
-- Durée du spin (roulette) avant de révéler le brainrot.
local SPIN_DURATION = 2.2
-- Intervalle de switch du silhouette pendant le spin (ms -> sec).
local SILHOUETTE_SWITCH_MIN = 0.03
local SILHOUETTE_SWITCH_MAX = 0.7
-- Vitesse du brainrot contrôlé : valeur par défaut (SpeedConfig.BASE_SPEED = 13).
-- Est remplacée dynamiquement par la vitesse achetée du joueur (SpeedLevel).
local BRAINROT_WALK_SPEED_DEFAULT = SpeedConfig.BASE_SPEED
-- Durée maximale avant reset automatique (filet de sécurité).
local MAX_SESSION_TIME = 90
-- Collision group utilisé pour que le brainrot contrôlé passe à travers les
-- BlockPart du Sell, sans impacter les autres joueurs.
local BRAINROT_COLLISION_GROUP = "DunkBrainrot"
local BLOCKPART_COLLISION_GROUP = "DunkBlockPart"

-- ===== État interne =====

local dunkRequestEvent
local dunkSequenceEvent
local brainrotsFolder
local luckyBlocksFolder
local wavesFolder
local BrainrotService

-- Mapping rarety -> nom du Model dans ReplicatedStorage.Waves. Les noms des
-- Models ne suivent pas la casse de nos rarities internes, donc on fait un
-- lookup explicite pour matcher ce qu'il y a réellement dans le folder.
local WAVE_MODEL_BY_RARITY = {
	Common    = "Common",
	Uncommon  = "UNCOMMON",
	Rare      = "Rare",
	Epic      = "Epic",
	Legendary = "Legendary",
	Mythic    = "Mythic",
	Secret    = "Secret",
	God       = "God",
	OG        = "OG",
}

-- Mapping rarety -> nom de la BasePart (Workspace.Spawn.Walls.W<Rarity>) qui
-- définit la position d'apparition fixe de la wave. Chaque zone de rareté a
-- son W-part placé à l'endroit exact où la vague doit sortir du sol.
local WAVE_SPAWN_PART_BY_RARITY = {
	Common    = "WCommon",
	Uncommon  = "WUncommon",
	Rare      = "WRare",
	Epic      = "WEpic",
	Legendary = "WLegendary",
	Mythic    = "WMythic",
	Secret    = "WSecret",
	God       = "WGod",
	OG        = "WOg",
}

-- Config de l'anim de wave (feature "chase" après roll).
-- La durée totale (RISE + SHOWCASE) doit correspondre à la durée du son
-- WAVE_SOUND_ID côté client (~2.61s). On a 2.0s de montée + 0.6s de pause.
local WAVE_RISE_DURATION  = 2.0   -- durée montee depuis sous le sol
-- Délai après WaveChase avant que la wave commence réellement à avancer.
-- Laisse au joueur le temps de voir sa caméra se repositionner derrière le
-- brainrot et de réagir avant que la poursuite démarre.
local WAVE_CHASE_START_DELAY = 0.8
local WAVE_SINK_DEPTH     = 40    -- profondeur initiale de la wave sous le sol (fallback, non utilisé si bbox OK)
-- Vitesse de la wave pendant le chase, en studs/s, par rarété.
-- Calibrée pour que la wave mette un temps précis à atteindre X=WAVE_STOP_X
-- (684) depuis son spawn (W-part de la rarété). Une fois ce X atteint la
-- wave s'arrête (clampée à WAVE_STOP_X).
--   Common    : 134.23 studs / 11.3s = 11.88 studs/s
--   Uncommon  : 311.73 studs / 17s   = 18.34 studs/s
--   Rare      : 551.73 studs / 17s   = 32.45 studs/s
--   Epic      : 826.73 studs / 19s   = 43.51 studs/s
--   Legendary : 1146.73 studs / 21s  = 54.61 studs/s
--   Mythic    : 1493.73 studs / 23s  = 64.95 studs/s
--   Secret    : 1880.23 studs / 24s  = 78.34 studs/s
--   God       : 2315.23 studs / 26s  = 89.05 studs/s
--   OG        : 2775.23 studs / 28s  = 99.12 studs/s
local WAVE_STOP_X = 684
local WAVE_CHASE_SPEED_BY_RARITY = {
	Common    = 11.88,
	Uncommon  = 18.34,
	Rare      = 32.45,
	Epic      = 43.51,
	Legendary = 54.61,
	Mythic    = 64.95,
	Secret    = 78.34,
	God       = 89.05,
	OG        = 99.12,
}
local WAVE_CHASE_SPEED_DEFAULT = 30
local function getWaveChaseSpeed(rarity)
	return WAVE_CHASE_SPEED_BY_RARITY[rarity] or WAVE_CHASE_SPEED_DEFAULT
end
local WAVE_SHOWCASE_TIME  = 0.6   -- durée pendant laquelle la caméra reste sur la wave après montee
local WAVE_TOUCH_RADIUS   = 6     -- distance horizontale en studs pour qu'un brainrot soit "touché"

-- [userId] = true tant qu'une séquence est en cours pour ce joueur.
local inSession = {}

-- ===== Helpers =====

local function getKickReady()
	local spawnFolder = Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	if not spawnFolder then return nil end
	local areas = spawnFolder:FindFirstChild(AREAS_FOLDER_NAME)
	if not areas then return nil end
	return areas:FindFirstChild(KICK_READY_NAME)
end

local function getBlockParts()
	-- Ramasse TOUS les BlockPart dans Workspace (pas seulement ceux du Sell)
	-- pour que le brainrot puisse traverser tous les murs nommés "BlockPart".
	local res = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == BLOCK_PART_NAME then
			table.insert(res, d)
		end
	end
	return res
end

-- Récupère uniquement les BlockPart sous le modèle Sell (pour détecter la
-- "franchissement" de la ligne de vente).
local function getSellBlockParts()
	local spawnFolder = Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	if not spawnFolder then return {} end
	local sell = spawnFolder:FindFirstChild(SELL_MODEL_NAME)
	if not sell then return {} end
	local res = {}
	for _, d in ipairs(sell:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == BLOCK_PART_NAME then
			table.insert(res, d)
		end
	end
	return res
end

local function isPointInsidePart(point, part)
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(localPoint.X) <= half.X
		and math.abs(localPoint.Y) <= half.Y
		and math.abs(localPoint.Z) <= half.Z
end

-- Calcule un point de dunk devant le joueur dans la KickReady. Si pas de
-- joueur valide, renvoie le centre de la KickReady.
local function computeImpactPosition(player)
	local kickReady = getKickReady()
	local default = Vector3.new(0, 5, 0)
	if kickReady then
		default = kickReady.Position - Vector3.new(0, kickReady.Size.Y * 0.5, 0)
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return default end

	local look = hrp.CFrame.LookVector
	local target = hrp.Position + Vector3.new(look.X, 0, look.Z).Unit * 10
	if kickReady then
		-- Projete sur le sol de la zone.
		local ground = kickReady.Position.Y - kickReady.Size.Y * 0.5
		target = Vector3.new(target.X, ground, target.Z)
	end
	return target
end

-- ===== Distance / Puissance =====
-- Modèle : interpolation linéaire par morceaux en log(Power). Les courbes
-- sont calibrées pour la nouvelle arène (limite X = -2020, distance max 2680).
-- 120M PERFECT atteint pile le fond de l'arène (scale factor 0.881 appliqué
-- aux anciennes données calibrées pour 3041 studs max).
--
-- PERFECT : (10 -> 51.3), (44.1K -> 492.7), (1M -> 988.5), (120M -> 2679.3)
-- BAD     : (10 -> 1.8),  (44.1K -> 127.1), (1M -> 271.4), (120M -> 801.9)
--
-- À 10 power + PERFECT -> X = 608.7 (atterrit juste devant le joueur).
-- À 1M + PERFECT -> X = -328.5.
-- Pour atteindre le fond (X = -2020) il faut ~120M en PERFECT.
local CURVE_POINTS = {
	PERFECT = { {10, 51.3}, {44100, 492.7}, {1000000, 988.5}, {120000000, 2679.3} },
	BAD     = { {10, 1.8},  {44100, 127.1}, {1000000, 271.4}, {120000000, 801.9} },
}

-- Poids d'interpolation entre BAD (0) et PERFECT (1) pour chaque grade.
local GRADE_WEIGHT = {
	PERFECT   = 1.00,
	EXCELLENT = 0.80,
	GREAT     = 0.60,
	GOOD      = 0.40,
	MID       = 0.20,
	BAD       = 0.00,
}

local function getPlayerPower(player)
	local yp = player:FindFirstChild("YeetPower")
	if yp and yp:IsA("NumberValue") then
		return math.max(0, yp.Value)
	end
	return 10
end

-- Interpolation piecewise en log(P) le long d'une courbe donnée.
local function interpCurve(curve, power)
	local P = math.max(1, power)
	local logP = math.log(P)
	local first = curve[1]
	if logP <= math.log(first[1]) then
		-- Extrapolation vers le bas : prolonge le 1er segment.
		local p1, d1 = curve[1][1], curve[1][2]
		local p2, d2 = curve[2][1], curve[2][2]
		local slope = (d2 - d1) / (math.log(p2) - math.log(p1))
		return math.max(0, d1 + slope * (logP - math.log(p1)))
	end
	for i = 1, #curve - 1 do
		local p1, d1 = curve[i][1], curve[i][2]
		local p2, d2 = curve[i + 1][1], curve[i + 1][2]
		if logP <= math.log(p2) then
			local t = (logP - math.log(p1)) / (math.log(p2) - math.log(p1))
			return d1 + (d2 - d1) * t
		end
	end
	-- Extrapolation vers le haut : prolonge le dernier segment.
	local last = #curve
	local p1, d1 = curve[last - 1][1], curve[last - 1][2]
	local p2, d2 = curve[last][1], curve[last][2]
	local slope = (d2 - d1) / (math.log(p2) - math.log(p1))
	return d2 + slope * (logP - math.log(p2))
end

local function distanceForGrade(grade, power)
	local w = GRADE_WEIGHT[grade]
	if w == nil then w = GRADE_WEIGHT.MID end
	local dBad = interpCurve(CURVE_POINTS.BAD, power)
	local dPerf = interpCurve(CURVE_POINTS.PERFECT, power)
	return dBad + (dPerf - dBad) * w
end

-- Limites X de la zone de jeu : le lucky block doit TOUJOURS atterrir dans
-- une zone de rarété, JAMAIS dans le spawn NI sur l'"Escalier Lobby".
-- La zone Common plate est sur X:[564.8..688.8] Z:[171.2..291.2].
-- L'escalier couvre X:[553.8..811.8] Z:[224.2..238.2] : bande étroite en Z
-- centrée sur la KickReady qu'il faut esquiver.
--   - MAX_X : bord intérieur côté spawn de la zone Common (~685).
--   - MIN_X : fond de l'arène (= bord X- du WOg, X=-2121.2).
local ARENA_MAX_X = 660    -- bord intérieur de la zone Common
local ARENA_MIN_X = -2120  -- fond de l'arène (WOg)

-- Bande Z de l'escalier. Si landing.X tombe dans la range X de l'escalier ET
-- landing.Z est dans cette bande, on décale le Z vers le côté le plus proche
-- pour éviter que le block atterrisse sur l'escalier. Marge de 4 studs pour
-- éviter les bords.
local STAIRS_X_MIN = 553.8
local STAIRS_X_MAX = 811.8
local STAIRS_Z_MIN = 224.2 - 4
local STAIRS_Z_MAX = 238.2 + 4
-- Limites Z de la zone Common (pour ne pas décaler au-delà).
local COMMON_Z_MIN = 171.2 + 6
local COMMON_Z_MAX = 291.2 - 6

-- Calcule la position de chute finale du LuckyBlock : partant du joueur en
-- direction du fond de l'arène (vers X négatif), à la distance déterminée
-- par le grade et la puissance du joueur.
local function computeLandingPosition(player, grade, fallbackPos)
	local power = getPlayerPower(player)
	local dist = distanceForGrade(grade, power)

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local origin
	local forward
	if hrp then
		origin = hrp.Position
		-- Direction : on force X négatif (vers le fond de l'arène).
		forward = Vector3.new(-1, 0, 0)
	else
		origin = fallbackPos
		forward = Vector3.new(-1, 0, 0)
	end

	local landing = origin + forward * dist
	-- Clamp X : on garantit que le block tombe TOUJOURS dans la zone de jeu
	-- (entre WOg au fond et la zone Common côté spawn).
	local clampedX = math.clamp(landing.X, ARENA_MIN_X, ARENA_MAX_X)
	local actualDist = math.abs(origin.X - clampedX)

	-- Dévie le Z si on est sur l'escalier. L'escalier est une bande étroite
	-- centrée sur la KickReady qui recouvre le milieu de la zone Common :
	-- sans déviation, tout tir vers l'avant y atterrirait directement.
	local landingZ = landing.Z
	if clampedX >= STAIRS_X_MIN and clampedX <= STAIRS_X_MAX
		and landingZ >= STAIRS_Z_MIN and landingZ <= STAIRS_Z_MAX
	then
		-- Pousse le Z vers le côté le plus proche hors de la bande escalier,
		-- en restant dans les limites de la zone Common.
		local center = (STAIRS_Z_MIN + STAIRS_Z_MAX) * 0.5
		if landingZ <= center then
			landingZ = STAIRS_Z_MIN - 1
		else
			landingZ = STAIRS_Z_MAX + 1
		end
		landingZ = math.clamp(landingZ, COMMON_Z_MIN, COMMON_Z_MAX)
	end

	-- Raycast vers le bas pour trouver le VRAI sol (les Bases sont souvent
	-- bien plus basses que la zone KickReady).
	local rayOrigin = Vector3.new(clampedX, origin.Y + 200, landingZ)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	-- Exclude le character du joueur et les brainrots contrôlés.
	local excluded = {}
	if char then table.insert(excluded, char) end
	rayParams.FilterDescendantsInstances = excluded
	local ray = Workspace:Raycast(rayOrigin, Vector3.new(0, -1000, 0), rayParams)
	local groundY
	if ray then
		groundY = ray.Position.Y
	else
		local kickReady = getKickReady()
		groundY = kickReady and (kickReady.Position.Y - kickReady.Size.Y * 0.5) or origin.Y
	end

	return Vector3.new(clampedX, groundY, landingZ), actualDist
end

-- Unparente tout les enfants d'un modèle sauf la PrimaryPart, pour n'avoir
-- qu'une partie à manipuler pendant la chute (évite les glitches).
local function flattenToPart(model, scale)
	if model.PrimaryPart then
		if scale then
			model:ScaleTo(scale)
		end
		return
	end
	local biggest
	local biggestVol = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > biggestVol then
				biggestVol = v
				biggest = d
			end
		end
	end
	if biggest then
		model.PrimaryPart = biggest
		if scale then
			model:ScaleTo(scale)
		end
	end
end

-- Fait un unwrap visuel : crée une copie "sombre" du modèle (teinte noire)
-- pour simuler la silhouette tournante pendant le spin.
local function buildSilhouette(template)
	local clone = template:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Color = Color3.fromRGB(8, 8, 12)
			d.Material = Enum.Material.SmoothPlastic
			d.CastShadow = false
			d.Anchored = true
			d.CanCollide = false
			d.Massless = true
		elseif d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") then
			d:Destroy()
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
			d:Destroy()
		elseif d:IsA("ParticleEmitter") or d:IsA("PointLight") or d:IsA("SpotLight") then
			d:Destroy()
		end
	end
	if clone:IsA("Model") then
		flattenToPart(clone, nil)
	end
	return clone
end

-- Crée les particules "poussière de météorite" attachées à la position d'impact.
-- (Non utilisé directement : l'explosion est maintenant spawnée côté client
-- dans DunkLuckyBlockController "Landed" pour que seul le joueur qui lance
-- la voie, et pour que l'anim soit garantie fluide sur sa machine.)
local function spawnImpactFX(position)
	_ = position
end

-- Calcule le Y minimum réel d'un modèle dans le monde, en itérant sur
-- les 8 coins de chaque BasePart. C'est beaucoup plus fiable que
-- Model:GetBoundingBox() qui retourne une BB orientée sur le pivot
-- (donc fausse si le modèle est tourné).
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

-- ===== MUTATIONS =====
-- Après le tirage du brainrot Normal, on peut le "muter" (Gold, Diamond, etc.)
-- pour booster son CPS. Les probabilités sont indépendantes (on teste dans
-- l'ordre du plus rare au moins rare, le premier hit gagne).
local MUTATION_ROLLS = {
	{ name = "Hacker",  chance = 0.001 },  -- 0.1%,  x30 CPS
	{ name = "Rainbow", chance = 0.005 },  -- 0.5%,  x15  CPS
	{ name = "Lava",    chance = 0.025 },  -- 2.5%,  x8   CPS
	{ name = "Galaxy",  chance = 0.05  },  -- 5%,    x6   CPS
	{ name = "Diamond", chance = 0.10  },  -- 10%,   x4   CPS
	{ name = "Gold",    chance = 0.15  },  -- 15%,   x2   CPS
}

-- Tire une mutation ou nil (= reste Normal). Tests indépendants du plus rare
-- au moins rare : si Rainbow sort (0.5%), on s'arrête là. Sinon on tente
-- Lava (2.5%), etc. Cet ordre garantit les probabilités demandées.
-- Le multiplicateur `luckMult` est appliqué à la probabilité de CHAQUE
-- mutation (gamepass MutationLuck = 2x). Les chances sont clampées à 1 pour
-- que des mutations déjà proches de 1 ne dépassent pas 100%.
local function rollMutation(luckMult)
	luckMult = luckMult or 1
	for _, m in ipairs(MUTATION_ROLLS) do
		local chance = math.min(1, m.chance * luckMult)
		if math.random() < chance then
			return m.name
		end
	end
	return nil
end

-- ===== OPENING VFX =====
-- Clone ReplicatedStorage.VFX.OpeningVFX sur une primary part et déclenche
-- ses emitters selon leurs attributs :
--   EmitDelay         : délai avant l'émission (s)
--   EmitCount         : nombre de particules à émettre
--   EmitDuration      : si >0, emitter en mode stream pendant cette durée (s)
--   TimeScale_Start   : valeur initiale de TimeScale (multiplicateur de vitesse)
--   TimeScale_End     : valeur finale de TimeScale après la rampe
--   TimeScale_Duration: durée de la rampe TimeScale_Start -> TimeScale_End (s)
--
-- Retourne la table `emitters` + l'attachment pour permettre un trigger manuel
-- via `triggerOpeningVFXEmit` (utilisé pendant le spin pour re-burst en boucle
-- sans recréer l'attachment).
local function attachOpeningVFX(primary)
	if not primary or not primary:IsA("BasePart") then return nil end
	local template = ReplicatedStorage:FindFirstChild("VFX")
	template = template and template:FindFirstChild("OpeningVFX")
	if not template then return nil end

	local attach = template:Clone()
	attach.Name = "OpeningVFX_Active"
	attach.Visible = true

	local emitters = {}
	for _, d in ipairs(attach:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			d.Enabled = false

			local emitDelay = tonumber(d:GetAttribute("EmitDelay")) or 0
			local emitDuration = tonumber(d:GetAttribute("EmitDuration")) or 0
			local emitCount = tonumber(d:GetAttribute("EmitCount"))
			if emitCount == nil then
				emitCount = d.Rate > 0 and d.Rate or 10
			end

			local tsStart = tonumber(d:GetAttribute("TimeScale_Start"))
			local tsEnd = tonumber(d:GetAttribute("TimeScale_End"))
			local tsDuration = tonumber(d:GetAttribute("TimeScale_Duration")) or 0
			if tsStart ~= nil then
				d.TimeScale = tsStart
			end

			table.insert(emitters, {
				emitter = d,
				delay = math.max(0, emitDelay),
				count = math.max(0, emitCount),
				duration = math.max(0, emitDuration),
				tsStart = tsStart,
				tsEnd = tsEnd,
				tsDuration = math.max(0, tsDuration),
			})
		end
	end

	attach.Parent = primary
	return { attachment = attach, emitters = emitters }
end

-- Déclenche un burst sur un OpeningVFX actif. Appelable en boucle pendant
-- toute la durée du spin pour garder l'effet visible en permanence.
local function triggerOpeningVFXEmit(ctx)
	if not ctx then return end
	for _, e in ipairs(ctx.emitters) do
		if e.tsStart ~= nil and e.tsEnd ~= nil and e.tsEnd ~= e.tsStart and e.tsDuration > 0 then
			task.spawn(function()
				local t0 = os.clock()
				while true do
					if not e.emitter or not e.emitter.Parent then return end
					local alpha = math.clamp((os.clock() - t0) / e.tsDuration, 0, 1)
					e.emitter.TimeScale = e.tsStart + (e.tsEnd - e.tsStart) * alpha
					if alpha >= 1 then break end
					task.wait()
				end
			end)
		end

		task.delay(e.delay, function()
			if not e.emitter or not e.emitter.Parent then return end
			if e.duration > 0 then
				e.emitter.Enabled = true
				if e.count > 0 then e.emitter:Emit(e.count) end
				task.delay(e.duration, function()
					if e.emitter and e.emitter.Parent then
						e.emitter.Enabled = false
					end
				end)
			elseif e.count > 0 then
				e.emitter:Emit(e.count)
			end
		end)
	end
end

-- API one-shot (attach + trigger + cleanup auto). Utilisé pour les appels
-- isolés (ex. vrai brainrot contrôlable).
local function playOpeningVFX(primary)
	local ctx = attachOpeningVFX(primary)
	if not ctx then return end
	triggerOpeningVFXEmit(ctx)
	local maxAliveTime = 0
	for _, e in ipairs(ctx.emitters) do
		local finish = e.delay + e.duration + e.emitter.Lifetime.Max
		if finish > maxAliveTime then maxAliveTime = finish end
	end
	task.delay(maxAliveTime + 0.1, function()
		if ctx.attachment and ctx.attachment.Parent then ctx.attachment:Destroy() end
	end)
end

-- Cherche le brainrot mutant correspondant au baseTemplate dans le folder
-- brainrotsFolder.<Mutation>. Retourne le template mutant ou nil si absent.
local function findMutatedTemplate(baseTemplate, mutation)
	if not baseTemplate or not mutation then return nil end
	local mutFolder = brainrotsFolder and brainrotsFolder:FindFirstChild(mutation)
	if not mutFolder then return nil end
	local mutantName = mutation .. " " .. baseTemplate.Name
	local mutant = mutFolder:FindFirstChild(mutantName)
	if mutant and mutant:IsA("Model") then return mutant end
	return nil
end

-- Retourne tous les brainrots Normal sous forme de liste.
-- Les brainrots EXCLUSIFS (Robux only) sont exclus : ils ne peuvent pas
-- être obtenus via le dunk lucky block.
local function listNormalBrainrots()
	local out = {}
	local normal = brainrotsFolder and brainrotsFolder:FindFirstChild("Normal")
	if not normal then return out end
	for _, m in ipairs(normal:GetChildren()) do
		if m:IsA("Model") and not BrainrotInfo.IsExclusive(m.Name) then
			table.insert(out, m)
			end
	end
	return out
end

-- ===== ZONES DE RARETÉ =====
-- Chaque wall (dans Workspace.Spawn.Walls) représente une zone de rareté. Quand
-- le lucky block atterrit dans/sur une zone, seuls les brainrots de cette
-- rareté peuvent être rollés. Le mapping est fait sur le NOM du wall.
--
-- Mapping exact demandé (les noms des walls sont différents par casse,
-- ex : "Rare" capitalized != "RARE" allcaps) :
--   Common    -> Common
--   Rare      -> Uncommon   (capitalized, plus petit zone)
--   RARE      -> Rare       (allcaps)
--   EPIC      -> Epic
--   Legendary -> Legendary
--   LEGENDARY -> Legendary
--   Mythic    -> Mythic
--   MYTHIC    -> Mythic
--   SECRET    -> Secret
--   GOD       -> God
--   OG        -> OG
-- Clé = nom trimé (exact, casse préservée) pour distinguer Rare vs RARE.
local WALL_NAME_TO_RARITY = {
	["Common"]    = "Common",
	["Rare"]      = "Uncommon",
	["RARE"]      = "Rare",
	["EPIC"]      = "Epic",
	["Legendary"] = "Legendary",
	["LEGENDARY"] = "Legendary",
	["Mythic"]    = "Mythic",
	["MYTHIC"]    = "Mythic",
	["SECRET"]    = "Secret",
	["GOD"]       = "God",
	["OG"]        = "OG",
	-- W-parts (spawn de vagues) : atterrir dessus MONTE la rarété d'un cran.
	-- Rationnel : ces parts marquent l'entrée de la zone SUIVANTE, donc y
	-- atterrir force le roll et la vague de cette zone supérieure (plus risqué
	-- mais plus rewarding). WOg reste OG car il n'y a pas de rarété au-dessus.
	["WCommon"]    = "Uncommon",
	["WUncommon"]  = "Rare",
	["WRare"]      = "Epic",
	["WEpic"]      = "Legendary",
	["WLegendary"] = "Mythic",
	["WMythic"]    = "Secret",
	["WSecret"]    = "God",
	["WGod"]       = "OG",
	["WOg"]        = "OG",
}

-- Retourne la rareté (string) de la zone dans laquelle tombe `pos`, ou nil
-- si aucune zone ne contient cette position. On itère sur tous les descendants
-- de Workspace.Spawn.Walls et on vérifie si le point est à l'intérieur.
local function getRarityForPosition(pos)
	local spawn = Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	if not spawn then return nil end
	local walls = spawn:FindFirstChild("Walls")
	if not walls then return nil end

	-- Parcours de tous les BasePart enfants et choix de celui qui contient `pos`.
	-- Si plusieurs zones se chevauchent, on prend la plus spécifique (plus petite).
	local bestRarity = nil
	local bestVolume = math.huge
	for _, p in ipairs(walls:GetChildren()) do
		if p:IsA("BasePart") then
			-- Trim des espaces en début/fin (les walls ont parfois "EPIC " avec
			-- un espace à la fin). On préserve la casse pour distinguer Rare / RARE.
			local key = string.gsub(p.Name, "^%s*(.-)%s*$", "%1")
			local rarity = WALL_NAME_TO_RARITY[key]
			if rarity then
				-- Check si pos est à l'intérieur de cette part (horizontalement
				-- uniquement : on ignore Y car les walls peuvent avoir des Y variables).
				local localPoint = p.CFrame:PointToObjectSpace(
					Vector3.new(pos.X, p.Position.Y, pos.Z))
				local half = p.Size * 0.5
				if math.abs(localPoint.X) <= half.X
					and math.abs(localPoint.Z) <= half.Z
				then
					local volume = p.Size.X * p.Size.Z
					if volume < bestVolume then
						bestVolume = volume
						bestRarity = rarity
					end
				end
			end
		end
	end
	return bestRarity
end

-- Retourne les templates de brainrots Normal d'une rareté donnée, ainsi
-- qu'une table de poids alignée (poids inversement proportionnel au CPS :
-- plus un brainrot donne d'argent, plus il est rare à roll).
-- Si `luckMult` > 1, les brainrots à haut CPS voient leur poids augmenté
-- (formule inverse : poids = (CPS ^ (luckMult-1)) / CPS) pour doubler les
-- chances de tirer un brainrot cher avec le gamepass BrainrotLuck.
local function listBrainrotsByRarity(rarity, luckMult)
	luckMult = luckMult or 1
	local out = {}
	local weights = {}
	local normal = brainrotsFolder and brainrotsFolder:FindFirstChild("Normal")
	if not normal then return out, weights end

	for _, m in ipairs(normal:GetChildren()) do
		if m:IsA("Model") and not BrainrotInfo.IsExclusive(m.Name) then
			local info = BrainrotInfo.GetInfo(m.Name)
			if info and info.RarityType == rarity then
				table.insert(out, m)
				local cps = math.max(1, info.CashPerSecond or 1)
				-- Base : poids = 1/CPS (plus cher = plus rare).
				-- Avec BrainrotLuck : on multiplie CPS dans le numérateur pour
				-- rendre les brainrots chers plus probables.
				-- luckMult=1 -> 1/CPS (normal). luckMult=2 -> CPS/CPS^2 = 1/CPS
				-- ne change rien... On passe donc par une formule différente :
				-- avec bonus : poids = (1/CPS) * (CPS / maxCps)^(luckMult-1).
				-- Plus simple : on utilise poids = 1/(CPS^(1/luckMult)).
				-- luckMult=1 -> 1/CPS, luckMult=2 -> 1/sqrt(CPS) qui favorise
				-- les gros CPS sans les rendre ultra-probables.
				local weight = 1 / (cps ^ (1 / luckMult))
				table.insert(weights, weight)
			end
		end
	end
	return out, weights
end

-- Tire au sort un brainrot dans une liste pondérée. Retourne le template.
local function weightedPick(templates, weights)
	if #templates == 0 then return nil end
	local total = 0
	for _, w in ipairs(weights) do total = total + w end
	if total <= 0 then
		return templates[math.random(1, #templates)]
	end
	local r = math.random() * total
	local acc = 0
	for i, w in ipairs(weights) do
		acc = acc + w
		if r <= acc then
			return templates[i]
		end
	end
	return templates[#templates]
end

-- ===== WAVE (chase phase) =====

-- Calcule les métriques d'une wave SANS spawner d'objet côté serveur.
-- L'animation visuelle est entièrement faite côté client (voir
-- DunkLuckyBlockController.WaveRise) pour une fluidité 60fps+ et pour que
-- les autres joueurs ne voient pas la wave (chaque joueur a la sienne).
local function computeWaveMetrics(rarity, spawnCenterPos, groundY, targetPos)
	if not wavesFolder then return nil end
	local modelName = WAVE_MODEL_BY_RARITY[rarity]
	if not modelName then return nil end
	local template = wavesFolder:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then return nil end

	-- Clone temporaire pour lire la bbox sans rotation.
	local probe = template:Clone()
	probe:PivotTo(CFrame.new())
	local bbCF, bbSize = probe:GetBoundingBox()
	local probePivotY = 0
	if probe.PrimaryPart then
		probePivotY = probe.PrimaryPart.Position.Y
	end
	local bottomOffset = probePivotY - (bbCF.Position.Y - bbSize.Y * 0.5)
	probe:Destroy()

	local dir = Vector3.new(targetPos.X - spawnCenterPos.X, 0, targetPos.Z - spawnCenterPos.Z)
	if dir.Magnitude < 1e-3 then
		dir = Vector3.new(-1, 0, 0)
	end
	dir = dir.Unit

	local startPivotY = groundY - bbSize.Y + bottomOffset
	local endPivotY = groundY + bottomOffset

	return {
		ModelName    = modelName,
		StartPos     = Vector3.new(spawnCenterPos.X, startPivotY, spawnCenterPos.Z),
		EndPos       = Vector3.new(spawnCenterPos.X, endPivotY, spawnCenterPos.Z),
		Direction    = dir,
		WaveHeight   = bbSize.Y,
		WaveLengthX  = bbSize.X,
		WaveWidthZ   = bbSize.Z,
		BottomOffset = bottomOffset,
	}
end

-- (riseWaveToSurface supprimé : l'animation de la wave est maintenant côté
-- client pour la fluidité. Le serveur attend simplement WAVE_RISE_DURATION.)

-- ===== Séquence principale =====

local function runSequence(player, grade, fill)
	local userId = player.UserId
	if inSession[userId] then return end
	inSession[userId] = true

	grade = grade or "MID"

	local cleanupTasks = {}
	local function cleanup()
		inSession[userId] = nil
		for _, fn in ipairs(cleanupTasks) do
			pcall(fn)
		end
	end

	-- Filet de sécurité : force le cleanup après MAX_SESSION_TIME.
	task.delay(MAX_SESSION_TIME, function()
		if inSession[userId] then
			cleanup()
		end
	end)

	local startPos = computeImpactPosition(player)

	-- 1) Calcule les paramètres de vol. Le LuckyBlock lui-même est spawné
	-- côté CLIENT (le controller) pour que l'animation soit locale au joueur
	-- qui lance, donc parfaitement fluide. Le serveur ne gère que la logique
	-- (quand le brainrot apparait, ligne de vente, etc.).
	local basicTemplate = luckyBlocksFolder and luckyBlocksFolder:FindFirstChild("Basic")
	if not basicTemplate then
		warn("[DunkLuckyBlockService] LuckyBlocks.Basic introuvable")
		cleanup()
		return
	end

	-- Calcule la position d'atterrissage selon grade + power du joueur.
	local landingPos, distance = computeLandingPosition(player, grade, startPos)
	local impactPos = landingPos

	-- Position de départ du projectile (devant le joueur, légèrement en l'air).
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local launchOrigin
	if hrp then
		launchOrigin = hrp.Position + Vector3.new(-3, 4, 0)
	else
		launchOrigin = startPos + Vector3.new(0, 4, 0)
	end

	-- Trajectoire en "U" bien arquée : peakHeight augmenté (~10% de la
	-- distance, plafonné à 60 studs) pour que le bloc décrive un vrai arc
	-- visible et non plus une quasi-ligne droite. La distance et la durée
	-- de vol sont inchangées : seul l'amplitude verticale change.
	local flightDuration = math.clamp(FALL_DURATION + distance * 0.0009, 1.3, 3.5)
	local peakHeight = math.clamp(distance * 0.10, 8, 60)

	-- LandY : position Y où le centre du block doit être posé au sol. Le
	-- client connait la taille réelle du block après son scale local.
	local landY = impactPos.Y

	-- Envoie au client tout ce qu'il faut pour animer le LuckyBlock en LOCAL.
	-- Le client va cloner le LuckyBlock Basic, le scaler, et l'animer à 60+ Hz.
	-- Le clone du joueur (effet flex PERFECT) est ENTIÈREMENT géré côté client
	-- (création + animation dans la même RenderStepped que le bloc) pour une
	-- synchro frame parfaite et zéro saccade réseau. Le serveur indique juste
	-- IsPerfect = true pour que le client crée le clone Superman.
	dunkSequenceEvent:FireClient(player, "Start", {
		ImpactPosition = impactPos,
		LaunchOrigin = launchOrigin,
		LandY = landY,
		FlightDuration = flightDuration,
		PeakHeight = peakHeight,
		ServerStartTime = workspace:GetServerTimeNow(),
		Distance = distance,
		Grade = grade,
		IsPerfect = (grade == "PERFECT"),
	})

	-- ===== CLONE FLEX (PERFECT only) =====
	-- Le clone visuel pendant le VOL est créé et animé 100% côté CLIENT pour
	-- une synchro parfaite avec le bloc (même RenderStepped, même os.clock).
	-- Le serveur n'a plus rien à faire pendant le vol pour le clone.
	local cloneInstance = nil
	local cloneFlightConn = nil

	-- Attend la fin du vol (côté serveur on ne fait que patienter).
	task.wait(flightDuration)

	-- Position de "touchdown" du clone : impactPos. Le clone qui court ensuite
	-- vers KickReady spawnera à cette position.
	local cloneTouchdownPos = (grade == "PERFECT") and impactPos or nil

	-- 2) Impact : les FX sont SPAWNÉS CÔTÉ CLIENT (par le joueur qui lance)
	-- pour que seul lui les voie, et pour garantir un rendu fluide sur sa
	-- machine. Le serveur envoie simplement le signal "Landed".
	dunkSequenceEvent:FireClient(player, "Landed", { ImpactPosition = impactPos })

	-- Laisse le temps au client de voir le block posé au sol avant le roll.
	task.wait(1.0)

	-- 3) Sélection du brainrot final selon la ZONE d'atterrissage.
	-- Le block tombe sur un wall nommé (Common, Rare, RARE, EPIC, Legendary,
	-- MYTHIC, SECRET, GOD, OG...) qui détermine la rareté à roll. Le pool
	-- de cycling (silhouettes) et le brainrot final sont filtrés pour ne
	-- contenir QUE des brainrots de cette rareté. Le roll est pondéré par
	-- 1/CPS : les brainrots qui donnent le plus d'argent sont plus rares.
	local zoneRarity = getRarityForPosition(impactPos)
	local pool, poolWeights
	-- Gamepass BrainrotLuck + VIP + ServerLuck : luck multipliers combinés
	-- (multiplicatif). ServerLuck est commun au serveur ; les deux autres sont
	-- individuels.
	local luckMult = 1
	local DataService2 = Loader.GetService("DataService")
	if DataService2 and DataService2.HasGamepass then
		if DataService2:HasGamepass(player, "BrainrotLuck") then
			luckMult = luckMult * GamepassConfig.BRAINROT_LUCK_MULT
		end
		if DataService2:HasGamepass(player, "VIP") then
			luckMult = luckMult * GamepassConfig.VIP_LUCK_MULT
		end
	end
	local okSL, serverLuck = pcall(Loader.GetService, "ServerLuckService")
	if okSL and serverLuck and serverLuck.GetLuckMulti then
		luckMult = luckMult * serverLuck:GetLuckMulti()
	end
	if zoneRarity then
		pool, poolWeights = listBrainrotsByRarity(zoneRarity, luckMult)
	end
	-- Fallback : si le block atterrit hors zone (ou zone sans brainrot dispo),
	-- on tombe sur tous les brainrots Normal avec un pool uniforme.
	if not pool or #pool == 0 then
		pool = listNormalBrainrots()
		poolWeights = {}
		for i = 1, #pool do poolWeights[i] = 1 end
	end
	if #pool == 0 then
		cleanup()
		return
	end
	local finalTemplate = weightedPick(pool, poolWeights) or pool[math.random(1, #pool)]

	-- Roll de mutation. Si une mutation sort, on remplace finalTemplate par
	-- la version mutante (Gold / Diamond / Galaxy / Lava / Rainbow). Si la
	-- mutante n'existe pas dans le folder correspondant, on garde le Normal.
	local mutationLuck = 1
	if DataService2 and DataService2.HasGamepass and DataService2:HasGamepass(player, "MutationLuck") then
		mutationLuck = mutationLuck * GamepassConfig.MUTATION_LUCK_MULT
	end
	-- ServerLuck booste aussi les mutations (effet serveur-wide).
	if okSL and serverLuck and serverLuck.GetLuckMulti then
		mutationLuck = mutationLuck * serverLuck:GetLuckMulti()
	end
	local mutation = rollMutation(mutationLuck)
	if mutation then
		local mutated = findMutatedTemplate(finalTemplate, mutation)
		if mutated then
			finalTemplate = mutated
		end
	end

	-- 4) Spin : on cycle différents brainrots (en vrai, pas en silhouette) à
	-- l'endroit d'atterrissage. Chaque itération on détruit l'ancien et on en
	-- spawne un nouveau, tous tournant sur eux-mêmes.
	local spinStart = os.clock()

	local spinMount = Instance.new("Part")
	spinMount.Name = "DunkSpinMount"
	spinMount.Size = Vector3.new(0.2, 0.2, 0.2)
	spinMount.Transparency = 1
	spinMount.Anchored = true
	spinMount.CanCollide = false
	spinMount.CanQuery = false
	spinMount.CanTouch = false
	-- Placé au niveau du SOL (Y = groundY = impactPos.Y), pour que le brainrot
	-- repose ses pieds dessus.
	spinMount.CFrame = CFrame.new(impactPos)
	spinMount.Parent = Workspace
	spinMount.Parent = Workspace
	table.insert(cleanupTasks, function() if spinMount.Parent then spinMount:Destroy() end end)

	-- Prévient le client que le spin commence : la caméra se placera devant
	-- la spin pour que le joueur voie les brainrots de face.
	dunkSequenceEvent:FireClient(player, "SpinStarted", {
		SpinMount = spinMount,
		ImpactPosition = impactPos,
	})

	-- Attach l'OpeningVFX UNE SEULE FOIS au spinMount (persiste toute la durée
	-- du spin) et re-trigger ses emitters en boucle. Sans ça, l'attachment
	-- était cloné sur chaque silhouette qui était détruite aussitôt -> les
	-- particles n'avaient pas le temps de vivre, l'effet se voyait à peine.
	local spinVfxCtx = attachOpeningVFX(spinMount)

	-- Pour éviter les glitches : on recycle une seule instance affichée, et
	-- on la replace à chaque switch. On utilise un modèle "display" qui clone
	-- le template choisi à sa taille d'origine (même que le brainrot final).
	-- Si `silhouette` est true, le brainrot est coloré en noir (style roulette).
	local currentDisplay
	local currentBaseRot = CFrame.new()
	local function showBrainrot(template, silhouette)
		if currentDisplay then
			currentDisplay:Destroy()
			currentDisplay = nil
		end
		local clone = template:Clone()
		flattenToPart(clone, nil)

		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
				if silhouette then
					-- Silhouette : on vide la TextureID du MeshPart (pour que la
					-- texture du modèle ne prenne plus le dessus), on force couleur
					-- noire et matériau Neon (effet lumineux monochrome).
					if d:IsA("MeshPart") then
						d.TextureID = ""
					end
					d.Color = Color3.fromRGB(0, 0, 0)
					d.Material = Enum.Material.Neon
					d.CastShadow = false
				end
			elseif silhouette and (d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture")) then
				d:Destroy()
			elseif silhouette and (d:IsA("ParticleEmitter") or d:IsA("PointLight") or d:IsA("SpotLight")) then
				d:Destroy()
			end
		end

		if clone:IsA("Model") and clone.PrimaryPart then
			-- Yaw de 90° vers la droite (autour de Y) pour orienter le brainrot
			-- face à la caméra pendant le roll.
			local yaw90 = CFrame.Angles(0, -math.pi * 0.5, 0)
			currentBaseRot = yaw90 * (template:GetPivot() - template:GetPivot().Position)

			-- Place temporairement à la position cible avec rotation native.
			clone:PivotTo(CFrame.new(spinMount.Position) * currentBaseRot)

			-- Mesure le VRAI point le plus bas en monde (itère sur les coins de
			-- chaque BasePart). GetBoundingBox() est orienté sur le pivot donc
			-- incorrect après rotation ; c'est pour ça que certains brainrots
			-- s'enfonçaient dans le sol.
			local actualBottomY = getWorldMinY(clone)
			local correction = spinMount.Position.Y - actualBottomY
			clone:PivotTo(clone:GetPivot() + Vector3.new(0, correction, 0))
		end
		clone.Parent = spinMount

		currentDisplay = clone
	end

	-- Les brainrots NE tournent PAS sur eux-mêmes pendant le roll : on les
	-- affiche simplement en place, en noir, et on les remplace (cycle) à
	-- intervalle rapide. showBrainrot() se charge déjà du bon placement
	-- (orientation native + correction Y pour que les pieds touchent le sol).
	local spinConn = nil

	-- Cycling des brainrots affichés pendant le spin, en NOIR (silhouette).
	local spinDone = false
	task.spawn(function()
		while not spinDone do
			local elapsed = os.clock() - spinStart
			local progress = math.clamp(elapsed / SPIN_DURATION, 0, 1)
			-- Courbe exponentielle (^5) : le roll garde sa vitesse max très
			-- longtemps, puis ralentit brutalement sur le dernier quart pour un
			-- gros effet de suspense (style machine à sous).
			local eased = progress ^ 5
			local interval = SILHOUETTE_SWITCH_MIN + (SILHOUETTE_SWITCH_MAX - SILHOUETTE_SWITCH_MIN) * eased
			local pick = pool[math.random(1, #pool)]
			showBrainrot(pick, true) -- silhouette noire
			-- Re-burst l'OpeningVFX à chaque switch pour que l'effet soit
			-- TOUJOURS visible, pas seulement sur un brainrot aléatoire.
			if spinVfxCtx then
				triggerOpeningVFXEmit(spinVfxCtx)
			end
			task.wait(interval)
		end
	end)

	task.wait(SPIN_DURATION)
	spinDone = true

	-- Affichage final du VRAI brainrot choisi (couleur normale) quelques frames.
	-- C'est LE SEUL brainrot qui apparait en couleur pendant le roll ; tous
	-- les précédents étaient en silhouette noire.
	showBrainrot(finalTemplate, false)

	-- Ajoute un billboard au-dessus du brainrot choisi dès qu'il apparaît,
	-- pour que le joueur voie immédiatement le nom / rarété / CPS. Le vrai
	-- brainrot contrôlable aura son propre billboard un peu plus tard, mais
	-- on veut pas attendre : le joueur doit savoir tout de suite ce qu'il a
	-- gagné. On parent au currentDisplay qui va être détruit dans la phase
	-- suivante → le billboard part avec.
	if currentDisplay and currentDisplay.PrimaryPart then
		local finalInfo = BrainrotInfo.GetInfo(finalTemplate.Name)
		if finalInfo then
			local bb = Instance.new("BillboardGui")
			bb.Name = "SpinRevealInfo"
			bb.Adornee = currentDisplay.PrimaryPart
			bb.Size = UDim2.fromOffset(260, 100)
			bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.MaxDistance = 400
			bb.Parent = currentDisplay.PrimaryPart

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Vertical
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout.VerticalAlignment = Enum.VerticalAlignment.Top
			layout.Padding = UDim.new(0, 2)
			layout.Parent = bb

			local function mkLabel(text, color, size, order)
				local l = Instance.new("TextLabel")
				l.BackgroundTransparency = 1
				l.Size = UDim2.new(1, 0, 0, size)
				l.Font = Enum.Font.GothamBlack
				l.Text = text
				l.TextColor3 = color
				l.TextScaled = true
				l.TextStrokeTransparency = 0
				l.TextStrokeColor3 = Color3.new(0, 0, 0)
				l.LayoutOrder = order
				l.Parent = bb
			end
			mkLabel(finalInfo.FullName, Color3.fromRGB(255, 255, 255), 36, 1)
			mkLabel(finalInfo.RarityType, finalInfo.RarityColor, 28, 2)
			mkLabel("$" .. BrainrotInfo.FormatShort(finalInfo.CashPerSecond) .. "/s",
				Color3.fromRGB(120, 230, 120), 30, 3)
		end
	end

	-- Pause plus longue pour laisser le joueur voir le brainrot + son billboard.
	task.wait(1.2)

	if spinConn then spinConn:Disconnect(); spinConn = nil end

	-- Cleanup du VFX spin (l'attachment sera détruit quand le spinMount l'est).
	if spinVfxCtx and spinVfxCtx.attachment and spinVfxCtx.attachment.Parent then
		spinVfxCtx.attachment:Destroy()
	end

	-- 5) Reveal : on détruit le display temporaire pour spawner le "vrai"
	-- brainrot contrôlable ci-dessous.
	if currentDisplay then currentDisplay:Destroy() end
	if spinMount.Parent then spinMount:Destroy() end

	local revealFX = Instance.new("Part")
	revealFX.Size = Vector3.new(1, 1, 1)
	revealFX.Transparency = 1
	revealFX.Anchored = true
	revealFX.CanCollide = false
	revealFX.CanQuery = false
	revealFX.CFrame = CFrame.new(impactPos)
	revealFX.Parent = Workspace
	Debris:AddItem(revealFX, 2)
	local revAtt = Instance.new("Attachment", revealFX)
	local flash = Instance.new("ParticleEmitter")
	flash.Parent = revAtt
	-- Texture smoke ronde (intégrée) au lieu de 241876428 qui dessine des
	-- rectangles étirés verticaux -> évite les "lignes" résiduelles.
	flash.Texture = "rbxasset://textures/particles/smoke_main.dds"
	flash.Lifetime = NumberRange.new(0.4, 0.8)
	flash.Rate = 0
	flash.Speed = NumberRange.new(12, 25)
	flash.SpreadAngle = Vector2.new(180, 180)
	flash.Color = ColorSequence.new(Color3.fromRGB(255, 230, 140))
	flash.Size = NumberSequence.new(3, 0.5)
	flash.Rotation = NumberRange.new(0, 360)
	flash.RotSpeed = NumberRange.new(-180, 180)
	flash:Emit(40)

	-- Spawn le brainrot choisi à sa taille d'origine.
	-- On le fait tomber depuis le ciel au-dessus de la position d'atterrissage :
	-- la gravité l'amène au sol au moment même où le joueur prend le contrôle,
	-- ce qui donne un effet "pop out" du lucky block.
	local brainrot = finalTemplate:Clone()
	brainrot.Name = "DunkBrainrot_" .. player.Name
	flattenToPart(brainrot, nil)
	local brPrimary = brainrot.PrimaryPart
	if not brPrimary then
		brainrot:Destroy()
		cleanup()
		return
	end

	-- Calcule la taille réelle (bounding box) pour le placement au sol.
	local _, brSize = brainrot:GetBoundingBox()

	-- Setup physique : primary = HRP (visible mesh), toutes autres parts weldées.
	for _, d in ipairs(brainrot:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = (d == brPrimary)
			d.Massless = (d ~= brPrimary)
			d.CollisionGroup = BRAINROT_COLLISION_GROUP
			-- Élasticité 0 + friction modérée : empêche les rebonds au sol après
			-- un saut. On garde une friction standard pour ne pas glisser.
			-- PhysicalProperties(density, friction, elasticity, frictionWeight, elasticityWeight)
			d.CustomPhysicalProperties = PhysicalProperties.new(1.0, 0.3, 0, 1, 10)
			if d ~= brPrimary then
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = brPrimary
				wc.Part1 = d
				wc.Parent = brPrimary
			end
		end
	end

	-- Renomme en HumanoidRootPart (requis par Humanoid).
	brPrimary.Name = "HumanoidRootPart"
	brainrot.PrimaryPart = brPrimary

	-- BillboardGui Nom / Rarété / CPS au-dessus de la tête, créé AVANT que
	-- le brainrot soit parenté au workspace pour qu'il soit visible dès la
	-- première frame où le brainrot apparaît (sans gap entre la silhouette
	-- qui disparaît et le vrai brainrot).
	local brainrotInfoEarly = BrainrotInfo.GetInfo(finalTemplate.Name)
	if brainrotInfoEarly then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "DunkBrainrotInfo"
		billboard.Adornee = brPrimary
		billboard.Size = UDim2.fromOffset(220, 90)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
		billboard.AlwaysOnTop = true
		billboard.LightInfluence = 0
		billboard.MaxDistance = 300
		billboard.Parent = brPrimary

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Top
		layout.Padding = UDim.new(0, 2)
		layout.Parent = billboard

		local function mk(text, color, size, order)
			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.new(1, 0, 0, size)
			lbl.Font = Enum.Font.GothamBold
			lbl.Text = text
			lbl.TextColor3 = color
			lbl.TextScaled = true
			lbl.TextStrokeTransparency = 0
			lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
			lbl.LayoutOrder = order
			lbl.Parent = billboard
		end
		mk(brainrotInfoEarly.FullName, Color3.fromRGB(255, 255, 255), 32, 1)
		mk(brainrotInfoEarly.RarityType, brainrotInfoEarly.RarityColor, 24, 2)
		mk("$" .. BrainrotInfo.FormatShort(brainrotInfoEarly.CashPerSecond) .. "/s",
			Color3.fromRGB(120, 230, 120), 26, 3)
	end

	-- Spawn au sol : mesure la BB après rotation et ajuste la position Y pour
	-- que le bas touche exactement le sol, peu importe le modèle.
	local originalPivotRot = finalTemplate:GetPivot() - finalTemplate:GetPivot().Position

	-- Calcule la direction vers le PERSONNAGE DU JOUEUR (pas KickReady) pour
	-- que le brainrot regarde son propriétaire dès qu'il apparaît. Fallback
	-- sur KickReady si le character n'est pas dispo.
	local kickReadyPart = getKickReady()
	local playerHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local lookTargetPos = (playerHRP and playerHRP.Position) or (kickReadyPart and kickReadyPart.Position) or impactPos
	local yawRotation = CFrame.new()
	do
		local dirToTarget = Vector3.new(
			lookTargetPos.X - impactPos.X,
			0,
			lookTargetPos.Z - impactPos.Z
		)
		if dirToTarget.Magnitude > 0.1 then
			dirToTarget = dirToTarget.Unit
			local yaw = math.atan2(-dirToTarget.X, -dirToTarget.Z)
			yawRotation = CFrame.Angles(0, yaw, 0)
		end
	end

	-- Placement initial : on applique le yaw AVANT la rotation native pour
	-- faire tourner le brainrot autour de l'axe Y world (il reste debout mais
	-- pointe vers KickReady).
	brainrot:PivotTo(CFrame.new(impactPos) * yawRotation * originalPivotRot)

	-- Correction Y : bas réel (monde) doit être à impactPos.Y.
	local actualBottomY = getWorldMinY(brainrot)
	local correction = impactPos.Y - actualBottomY
	brainrot:PivotTo(brainrot:GetPivot() + Vector3.new(0, correction, 0))

	brainrot.Parent = Workspace
	table.insert(cleanupTasks, function() if brainrot.Parent then brainrot:Destroy() end end)

	-- Ajoute un Humanoid avec paramètres fixes (walkspeed déterminé par le
	-- SpeedLevel du joueur ; base 13, améliorable via le SpeedShop).
	-- Bonus gamepass Speed12X : multiplie la vitesse par 1.2 si le joueur l'a.
	local speedLevelVal = player:FindFirstChild("SpeedLevel")
	local playerSpeed = SpeedConfig.GetSpeedForLevel(speedLevelVal and speedLevelVal.Value or 0)
	local DataService = Loader.GetService("DataService")
	if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "Speed12X") then
		playerSpeed = playerSpeed * GamepassConfig.SPEED_1_2X_MULT
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.WalkSpeed = playerSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 55
	humanoid.HipHeight = 0
	humanoid.MaxHealth = math.huge
	humanoid.Health = math.huge
	humanoid.AutoRotate = true
	humanoid.Parent = brainrot

	-- Supprime l'AnimationController d'origine pour éviter les conflits (on utilise
	-- le Animator sur le Humanoid).
	local oldAC = brainrot:FindFirstChildOfClass("AnimationController")
	if oldAC then oldAC:Destroy() end

	-- Crée un Animator sous le Humanoid et charge l'animation Idle.
	local animator = Instance.new("Animator")
	animator.Parent = humanoid

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

	-- Donne le contrôle réseau au client. Roblox l'auto-assigne si la caméra
	-- suit l'assembly. On utilise SetNetworkOwner pour la fluidité.
	pcall(function()
		brPrimary:SetNetworkOwner(player)
	end)

	-- Désactive la collision des BlockPart pendant que le joueur contrôle
	-- le brainrot, pour qu'il puisse traverser le mur de vente. On restaure
	-- l'état d'origine dans cleanup.
	local blockParts = getBlockParts()
	local originalCollideState = {}
	for _, bp in ipairs(blockParts) do
		originalCollideState[bp] = bp.CanCollide
		bp.CanCollide = false
	end
	table.insert(cleanupTasks, function()
		for bp, state in pairs(originalCollideState) do
			if bp and bp.Parent then
				bp.CanCollide = state
			end
		end
	end)

	-- Caméra : on passe le Humanoid comme CameraSubject via un RemoteEvent.
	dunkSequenceEvent:FireClient(player, "BrainrotPicked", {
		BrainrotPath = brainrot,
		BrainrotName = finalTemplate.Name,
	})


	-- ===== WAVE CHASE =====
	-- Spawn la wave correspondant à la rareté de la zone (ou de finalTemplate).
	-- Elle monte depuis sous le sol, la caméra fait un zoom dessus quelques
	-- fractions de seconde, puis elle avance vers le brainrot. Si elle touche
	-- le brainrot (distance horizontale <= WAVE_TOUCH_RADIUS), le brainrot est
	-- perdu : le joueur ne le reçoit pas dans son inventaire même s'il franchit
	-- ensuite la KickReady.
	local waveRarity = zoneRarity
	if not waveRarity then
		local brInfo = BrainrotInfo.GetInfo(finalTemplate.Name)
		waveRarity = brInfo and brInfo.RarityType or "Common"
	end

	-- Position de spawn FIXE : on regarde Workspace.Spawn.Walls.W<Rarity> qui
	-- définit l'endroit exact où la wave doit sortir pour cette rareté. Chaque
	-- zone (Common, Uncommon, etc.) a son W-part. Fallback sur la logique
	-- "derrière le brainrot" si la part n'existe pas.
	local waveSpawnPos
	local waveGroundY
	local spawnFolder = Workspace:FindFirstChild(SPAWN_FOLDER_NAME)
	local wallsFolder = spawnFolder and spawnFolder:FindFirstChild("Walls")
	local wPartName = WAVE_SPAWN_PART_BY_RARITY[waveRarity]
	local wPart = wallsFolder and wPartName and wallsFolder:FindFirstChild(wPartName)
	if wPart and wPart:IsA("BasePart") then
		waveSpawnPos = wPart.Position
		waveGroundY = wPart.Position.Y + wPart.Size.Y * 0.5
	else
		local waveOffset = 30
		local waveDirFromTarget = Vector3.new(0, 0, 0)
		if kickReadyPart then
			local dx = kickReadyPart.Position.X - impactPos.X
			local dz = kickReadyPart.Position.Z - impactPos.Z
			local mag = math.sqrt(dx*dx + dz*dz)
			if mag > 0.001 then
				waveDirFromTarget = Vector3.new(-dx / mag, 0, -dz / mag)
			end
		end
		waveSpawnPos = impactPos + waveDirFromTarget * waveOffset
		waveGroundY = impactPos.Y
	end

	-- Direction FIXE de la wave : de la W-part vers la position de KickReady.
	-- La wave avance toujours tout droit dans cette direction, elle ne suit
	-- PAS le brainrot (mais le brainrot peut se faire toucher s'il reste sur
	-- sa trajectoire).
	local kickReadyForWave = getKickReady()
	local chaseTargetForDir = (kickReadyForWave and kickReadyForWave.Position) or impactPos
	local fixedDir = Vector3.new(chaseTargetForDir.X - waveSpawnPos.X, 0, chaseTargetForDir.Z - waveSpawnPos.Z)
	if fixedDir.Magnitude < 1e-3 then
		fixedDir = Vector3.new(1, 0, 0)
	else
		fixedDir = fixedDir.Unit
	end

	local waveMetrics = computeWaveMetrics(waveRarity, waveSpawnPos, waveGroundY, waveSpawnPos + fixedDir)
	local waveCaughtBrainrot = false
	local waveChaseConn

	if waveMetrics then
		-- Zoom caméra + animation de la wave : 100% côté client (voir
		-- DunkLuckyBlockController). Le serveur envoie juste les métriques et
		-- garde la logique de détection. Chaque joueur voit SA wave : les autres
		-- joueurs ne la voient pas et ne peuvent pas mourir dedans.
		dunkSequenceEvent:FireClient(player, "WaveRise", {
			ModelName       = waveMetrics.ModelName,
			SpawnPosition   = waveSpawnPos,
			SurfacePosition = Vector3.new(waveSpawnPos.X, waveGroundY, waveSpawnPos.Z),
			Direction       = fixedDir,
			StartPos        = waveMetrics.StartPos,
			EndPos          = waveMetrics.EndPos,
			WaveHeight      = waveMetrics.WaveHeight,
			WaveLength      = math.max(waveMetrics.WaveLengthX, waveMetrics.WaveWidthZ),
			RiseDuration    = WAVE_RISE_DURATION,
			ShowcaseTime    = WAVE_SHOWCASE_TIME,
		})

		-- Attend la fin de l'animation côté client (rise + showcase).
		task.wait(WAVE_RISE_DURATION + WAVE_SHOWCASE_TIME)

		-- Lance la course du nouveau clone vers KickReady en parallèle du chase.
		-- On spawn un NOUVEAU clone à la position mémorisée (cloneTouchdownPos).
		if cloneTouchdownPos and DunkCloneService then
			local kickReadyForRun = getKickReady()
			if kickReadyForRun then
				-- Vitesse = même vitesse que le brainrot du joueur (SpeedLevel
				-- + gamepass Speed12X). Recalculée à chaque frame par
				-- BindContinuousSpeed, donc si le joueur upgrade sa vitesse en
				-- pleine game le clone passe immédiatement à la nouvelle valeur.
				-- Comme le brainrot et le clone partent du même point et vont vers
				-- la même cible à la même vitesse, le clone ne rattrape jamais.
				local function getCurrentSpeed()
					local speedLevelVal = player:FindFirstChild("SpeedLevel")
					local s = SpeedConfig.GetSpeedForLevel(speedLevelVal and speedLevelVal.Value or 0)
					local DataService3 = Loader.GetService("DataService")
					if DataService3 and DataService3.HasGamepass and DataService3:HasGamepass(player, "Speed12X") then
						s = s * GamepassConfig.SPEED_1_2X_MULT
					end
					return s
				end

				task.spawn(function()
					local newClone = DunkCloneService:SpawnAndRun(player, cloneTouchdownPos, kickReadyForRun, getCurrentSpeed)
					if newClone then
						DunkCloneService:BindContinuousSpeed(newClone, getCurrentSpeed)
						_G.DunkCurrentRunningClone = newClone
					end
				end)
			end
		end

		dunkSequenceEvent:FireClient(player, "WaveChase", {
			BrainrotPath = brainrot,
			WaveDirection = fixedDir,
			ChaseSpeed = getWaveChaseSpeed(waveRarity),
			StopX = WAVE_STOP_X,
			StartDelay = WAVE_CHASE_START_DELAY,
		})

		-- Détection serveur : la wave chase côté client, mais le serveur calcule
		-- la même trajectoire mathématiquement (départ = EndPos, direction fixe,
		-- vitesse WAVE_CHASE_SPEED) et vérifie si le brainrot est dans l'OBB
		-- (oriented bounding box) de la wave.
		local chaseStartTime = os.clock() + WAVE_CHASE_START_DELAY
		local chaseStartPos = waveMetrics.EndPos
		local chaseSpeed = getWaveChaseSpeed(waveRarity)
		local halfX = waveMetrics.WaveLengthX * 0.5
		local halfZ = waveMetrics.WaveWidthZ * 0.5
		-- Axes locaux de la wave (orientée avec lookAt vers fixedDir) :
		--   LookVector = fixedDir, RightVector = perp horizontal.
		local rightDir = Vector3.new(-fixedDir.Z, 0, fixedDir.X) -- perp horizontal de fixedDir

		waveChaseConn = RunService.Heartbeat:Connect(function()
			if waveCaughtBrainrot then return end
			if not brPrimary or not brPrimary.Parent then return end

			local elapsed = os.clock() - chaseStartTime
			if elapsed < 0 then return end -- délai de démarrage : wave encore immobile
			local travel = chaseSpeed * elapsed
			local wavePos = chaseStartPos + fixedDir * travel
			-- Clamp la position X de la wave à WAVE_STOP_X pour que la
			-- détection de collision coïncide avec l'arrêt visuel côté client.
			if fixedDir.X > 0 and wavePos.X > WAVE_STOP_X then
				wavePos = Vector3.new(WAVE_STOP_X, wavePos.Y, wavePos.Z)
			end

			-- Vecteur du centre de la wave au brainrot.
			local toBr = brPrimary.Position - wavePos
			local toBrHoriz = Vector3.new(toBr.X, 0, toBr.Z)

			-- Projection sur les axes locaux (right et look = fixedDir).
			local projRight = toBrHoriz:Dot(rightDir)
			local projFwd   = toBrHoriz:Dot(fixedDir)

			if math.abs(projRight) <= halfX and math.abs(projFwd) <= halfZ then
				waveCaughtBrainrot = true
			end
		end)
		table.insert(cleanupTasks, function()
			if waveChaseConn then waveChaseConn:Disconnect() end
		end)
	end

	-- 6) Monitoring : quand le brainrot entre dans la zone KickReady (retour
	-- au joueur), on lui donne le brainrot dans son inventaire et on rend
	-- le contrôle à son character.
	local kickReadyPart = getKickReady()
	local crossed = false
	local monitorConn
	monitorConn = RunService.Heartbeat:Connect(function()
		if crossed then return end
		if not brPrimary or not brPrimary.Parent then return end
		if not kickReadyPart or not kickReadyPart.Parent then return end
		if isPointInsidePart(brPrimary.Position, kickReadyPart) then
			crossed = true
		end
	end)
	table.insert(cleanupTasks, function() if monitorConn then monitorConn:Disconnect() end end)

	-- Attend que le brainrot franchisse la ligne (ou timeout, ou touché par wave).
	local waitStart = os.clock()
	while not crossed and not waveCaughtBrainrot
		and (os.clock() - waitStart) < (MAX_SESSION_TIME - 10)
		and inSession[userId] do
		task.wait(0.1)
	end

	if monitorConn then monitorConn:Disconnect(); monitorConn = nil end
	if waveChaseConn then waveChaseConn:Disconnect(); waveChaseConn = nil end

	if waveCaughtBrainrot then
		dunkSequenceEvent:FireClient(player, "BrainrotLost", {
			BrainrotName = finalTemplate.Name,
		})

		-- Cleanup immédiat du clone : la séquence est terminée (mort).
		local toClean = _G.DunkCurrentRunningClone or cloneInstance
		_G.DunkCurrentRunningClone = nil
		if toClean and DunkCloneService then
			DunkCloneService:Cleanup(toClean)
		end
	elseif crossed then
		-- Le feedback visuel (flash blanc + confettis UI + son) est 100% géré
		-- côté client dans DunkLuckyBlockController "BrainrotSold". Le serveur
		-- ne spawn PAS de particles dans le monde ici pour éviter les traces
		-- bleues verticales qui restaient en scene.

		-- Ajoute le brainrot à l'inventaire du joueur, puis l'équipe.
		if BrainrotService and BrainrotService.GiveBrainrotByName then
			local tool = BrainrotService:GiveBrainrotByName(player, finalTemplate.Name)
			if tool and player.Character then
				local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					pcall(function() humanoid:EquipTool(tool) end)
				end
			end
		end

		dunkSequenceEvent:FireClient(player, "BrainrotSold", {
			BrainrotName = finalTemplate.Name,
		})

		-- Cleanup immédiat du clone : le joueur a réussi son dunk.
		local toClean = _G.DunkCurrentRunningClone or cloneInstance
		_G.DunkCurrentRunningClone = nil
		if toClean and DunkCloneService then
			DunkCloneService:Cleanup(toClean)
		end
	end

	-- Fin : cleanup brainrot + signal End.
	if brainrot.Parent then brainrot:Destroy() end

	-- Sécurité : si le clone n'a pas été cleanup avant, on le fait ici.
	local runningClone = _G.DunkCurrentRunningClone
	if runningClone and DunkCloneService then
		_G.DunkCurrentRunningClone = nil
		DunkCloneService:Cleanup(runningClone)
	end
	if cloneInstance and cloneInstance.Parent and DunkCloneService then
		DunkCloneService:Cleanup(cloneInstance)
	end
	if cloneFlightConn then cloneFlightConn:Disconnect(); cloneFlightConn = nil end

	dunkSequenceEvent:FireClient(player, "End", {})
	cleanup()
end

-- ===== Cycle de vie =====

-- Configure les collision groups partagés :
--   DunkBrainrot  vs Default        -> on collide (sol, murs, etc.)
--   DunkBrainrot  vs DunkBlockPart  -> PAS de collision (passe à travers)
-- Les autres joueurs utilisent Default et donc entrent en collision avec les
-- BlockPart normalement.
local function setupCollisionGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(BRAINROT_COLLISION_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(BLOCKPART_COLLISION_GROUP)
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BRAINROT_COLLISION_GROUP, BLOCKPART_COLLISION_GROUP, false)
	end)
end

-- Assigne les BlockPart du Sell au collision group dédié, pour ne pas collisionner
-- avec les brainrots contrôlés.
local function tagBlockParts()
	for _, bp in ipairs(getBlockParts()) do
		bp.CollisionGroup = BLOCKPART_COLLISION_GROUP
	end
end

function DunkLuckyBlockService:Init()
	dunkRequestEvent = RemotesAPI.GetEvent("DunkRequestEvent")
	dunkSequenceEvent = RemotesAPI.GetEvent("DunkSequenceEvent")
	brainrotsFolder = ReplicatedStorage:WaitForChild("Brainrots")
	luckyBlocksFolder = ReplicatedStorage:WaitForChild("LuckyBlocks")
	wavesFolder = ReplicatedStorage:FindFirstChild("Waves")

	setupCollisionGroups()
end

function DunkLuckyBlockService:Start()
	BrainrotService = Loader.GetService("BrainrotService")
	DunkCloneService = Loader.GetService("DunkCloneService")

	tagBlockParts()

	dunkRequestEvent.OnServerEvent:Connect(function(player, grade, fill)
		-- Validation basique : grade doit être un string connu, fill un number [0,1].
		if typeof(grade) ~= "string" or not GRADE_WEIGHT[grade] then
			grade = "MID"
		end
		if typeof(fill) ~= "number" then
			fill = 0.5
		end
		task.spawn(runSequence, player, grade, fill)
	end)

	Players.PlayerRemoving:Connect(function(player)
		inSession[player.UserId] = nil
	end)

	print("[DunkLuckyBlockService] Prêt")
end

return DunkLuckyBlockService

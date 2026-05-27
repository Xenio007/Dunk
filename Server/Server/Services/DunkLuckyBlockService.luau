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
local PlayerBrainrotTransform = require(script.Parent:WaitForChild("PlayerBrainrotTransform"))

local DunkLuckyBlockService = Loader.CreateService({
	Name = "DunkLuckyBlockService",
})

-- Résolu au Start (Loader garantit que tous les services sont chargés avant Start).
local DunkCloneService


-- ===== Constantes =====

-- Zone de dunk côté client (KickReady). On retrouve le même dossier côté serveur
-- pour calculer le point d'impact du LuckyBlock.
local SPAWN_FOLDER_NAME = "Spawn"

-- Brainrots exclus du pool de tirage. Ces brainrots ont un mesh skinné sans
-- animation Walk : pendant le contrôle ils glissent au sol au lieu de marcher.
-- En attendant un fix d'animation propre, on ne les tire pas. Le filtre
-- s'applique aussi à leurs mutations (Diamond Trulimero, Gold Bananita, etc.).
local EXCLUDED_BRAINROTS = {
	["Trulimero Trulicina"] = true,
	["Bananita Dolphinita"] = true,
	["Orcalero Orcala"]     = true,
	["Chillin Chili"]       = true,
}

-- Renvoie true si le brainrot (ou sa version mutante) est dans la liste
-- d'exclusion. On strip le préfixe de mutation (Diamond / Gold / Galaxy / etc.)
-- pour comparer le nom de base.
local function isBrainrotExcluded(name)
	if not name or name == "" then return false end
	if EXCLUDED_BRAINROTS[name] then return true end
	for excluded in pairs(EXCLUDED_BRAINROTS) do
		-- Match "Diamond Trulimero Trulicina", "Gold Bananita Dolphinita", etc.
		if name:sub(-#excluded) == excluded then return true end
	end
	return false
end
local AREAS_FOLDER_NAME = "Areas"
local KICK_READY_NAME    = "KickReady"
local SELL_MODEL_NAME    = "Sell"
local BLOCK_PART_NAME    = "BlockPart"

-- Durée de référence de la chute (ajustée selon la distance dans runSequence).
-- Augmentée de 1.5 à 2.4s pour ralentir le vol du LuckyBlock dans les airs :
-- le bloc se voyait passer trop vite, le swap de skin par zone n'était pas
-- assez lisible. Avec 2.4s de base + 0.0014 par stud (clamp 2.1 à 5.5),
-- le joueur a le temps de voir le bloc traverser chaque zone de rareté.
local FALL_DURATION = 2.4
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
local setCustomPowerEvent
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

-- POLISH (player feedback) : tsunami instant-death safety buffer.
-- Au moment où la wave commence à bouger (chaseStartTime), si le brainrot
-- spawn dans une rareté proche / si la wave s'élance depuis une W-part
-- adjacente, le hitbox de la wave peut chevaucher la position du brainrot
-- dès la 1re frame -> mort instantanée sans aucune marge de réaction.
--
-- WAVE_TOUCHDOWN_GRACE : durée (s) après chaseStartTime pendant laquelle
-- la collision wave/brainrot est désactivée. Le joueur a au minimum cette
-- fenêtre pour s'écarter de la trajectoire.
--
-- WAVE_MIN_HORIZONTAL_DIST : distance horizontale (studs) minimale entre la
-- position de la wave et celle du brainrot pour autoriser un kill. Filet de
-- sécurité geometrique additionnel : si la wave est physiquement collée au
-- brainrot dès la 1re frame du chase (overlap initial), on attend qu'elle
-- s'éloigne d'abord, sinon le kill ne déclenche jamais sur cette frame.
local WAVE_TOUCHDOWN_GRACE = 0.5
local WAVE_MIN_HORIZONTAL_DIST = 4

-- [userId] = true tant qu'une séquence est en cours pour ce joueur.
local inSession = {}

-- [userId] = clone instance du Dunk Clone qui court vers KickReady. Par-joueur
-- pour éviter les écrasements quand plusieurs joueurs lancent en parallèle
-- (l'ancienne version utilisait _G.DunkCurrentRunningClone qui était global).
local activeRunningClones = {}

-- [userId] = os.clock() de la dernière requête DunkRequestEvent. Anti-spam
-- côté serveur : limite la cadence de tirs même si un exploiteur tente de
-- bypass le mini-jeu côté client en envoyant le remote en boucle.
local lastDunkAt = {}
local DUNK_MIN_INTERVAL = 5 -- secondes minimum entre 2 tirs

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
-- sont calibrées pour la nouvelle arène (limite X = -2020, distance max
-- ~2710 depuis le launch X=690). Pour atteindre le fond (X = -2020) il faut
-- ~120M en PERFECT.
--
-- PERFECT : (10 -> 51.3), (44.1K -> 498), (1M -> 1000), (120M -> 2710)
-- BAD     : (10 -> 1.8),  (44.1K -> 130),  (1M -> 280),  (120M -> 820)
local CURVE_POINTS = {
	PERFECT = { {10, 51.3}, {44100, 498}, {1000000, 1000}, {120000000, 2710} },
	BAD     = { {10, 1.8},  {44100, 130}, {1000000, 280},  {120000000, 820} },
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

-- [userId] = number. Puissance custom choisie par le joueur via le slider
-- SetKickPower (UI client). Le serveur clamp cette valeur dans [0, YeetPower]
-- au moment de l'utiliser, donc un exploiteur ne peut pas tirer plus loin que
-- ce qu'il a réellement en YeetPower.
local customKickPower = {}

local function getPlayerPower(player)
	local yp = player:FindFirstChild("YeetPower")
	local maxP = (yp and yp:IsA("NumberValue")) and math.max(0, yp.Value) or 10
	local custom = customKickPower[player.UserId]
	if typeof(custom) == "number" and custom == custom then
		return math.clamp(custom, 0, maxP)
	end
	return maxP
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
local ARENA_MIN_X = -2020  -- fond de l'arène (longueur max sur X demandée)

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

	-- Pas de déviation Z : le tir va STRICTEMENT tout droit. La gestion
	-- d'escaliers se fait côté design (le joueur doit ajuster son angle).
	local landingZ = landing.Z

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
-- pour booster son CPS. On teste dans l'ordre du plus rare au moins rare,
-- le premier hit gagne.
--
-- Chances cibles (sans gamepass MutationLuck) :
--   Gold    : 1 / 25    = 4%
--   Diamond : 1 / 50    = 2%
--   Lava    : 1 / 100   = 1%
--   Galaxy  : 1 / 250   = 0.4%
--   Hacker  : 1 / 666   ≈ 0.15015%
--   Rainbow : 1 / 5000  = 0.02%
local MUTATION_ROLLS = {
	{ name = "Rainbow", chance = 1 / 2500 },
	{ name = "Hacker",  chance = 1 / 333  },
	{ name = "Galaxy",  chance = 1 / 125  },
	{ name = "Lava",    chance = 1 / 50   },
	{ name = "Diamond", chance = 1 / 25   },
	{ name = "Gold",    chance = 1 / 12   },
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
	if isBrainrotExcluded(baseTemplate.Name) then return nil end
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
		if m:IsA("Model") and not BrainrotInfo.IsExclusive(m.Name)
			and not isBrainrotExcluded(m.Name)
		then
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
		if m:IsA("Model") and not BrainrotInfo.IsExclusive(m.Name)
			and not isBrainrotExcluded(m.Name)
		then
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
	-- Flag local PROPRE à cette session. Évite qu'un timer de fin de session
	-- précédente fire le cleanup d'une session ultérieure (cas des lancers
	-- successifs : Run 1 finit normalement à t=15s, Run 2 démarre à t=20s,
	-- timer de Run 1 fire à t=90s avec inSession=true à cause de Run 2, et
	-- déclenche PlayerBrainrotTransform.Remove sur la session courante).
	local cleanupDone = false
	local function cleanup()
		if cleanupDone then return end
		cleanupDone = true
		inSession[userId] = nil
		for _, fn in ipairs(cleanupTasks) do
			pcall(fn)
		end
	end

	-- Filet de sécurité : force le cleanup après MAX_SESSION_TIME, mais
	-- UNIQUEMENT si cette session-là n'a pas déjà été cleanupée. Le flag
	-- cleanupDone est capturé dans la closure et reste privé à cette session,
	-- donc le timer ne touchera jamais une session ultérieure.
	task.delay(MAX_SESSION_TIME, function()
		if not cleanupDone then
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
	-- En PERFECT : on FORCE X=701 pour que l'animation Superman se joue
	-- toujours sur la meme ligne X (le couloir cinematique). Le Z reste celui
	-- du joueur pour que l'animation parte de l'endroit d'ou il a lance.
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local launchOrigin
	if hrp then
		if grade == "PERFECT" then
			launchOrigin = Vector3.new(701, hrp.Position.Y + 4, hrp.Position.Z)
		else
			launchOrigin = hrp.Position + Vector3.new(-3, 4, 0)
		end
	else
		launchOrigin = startPos + Vector3.new(0, 4, 0)
	end

	-- Vitesse CONSTANTE : la durée du vol est strictement proportionnelle à
	-- la distance, comme un projectile réel (vitesse fixe en studs/s).
	-- Aucun cap : un tir court (~50 studs) prend ~0.25s de vol, un tir long
	-- (~2700 studs) prend ~12s. L'animation s'étire ou se contracte d'elle-même.
	-- Tuning : 124 studs/s (~+18% par rapport à l'ancienne valeur de 105) pour
	-- un vol légèrement plus rapide / plus punchy sans casser la cinématique.
	local FLIGHT_SPEED_STUDS_PER_SEC = 124
	local flightDuration = math.max(0.8, distance / FLIGHT_SPEED_STUDS_PER_SEC)
	-- Arc proportionnel à la distance, sans cap dur mais factor modéré pour
	-- garder un "U" lisible sans monter trop haut. ~12% de la distance,
	-- plancher 12 studs pour les courts tirs.
	local peakHeight = math.max(12, distance * 0.12)

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
	-- l'endroit d'atterrissage. POLISH : depuis le fix anim 2 FPS, le cycling
	-- visuel est 100% local au client (cf. DunkLuckyBlockController "SpinStarted").
	-- Le serveur n'attend plus que SPIN_DURATION puis spawne le brainrot FINAL
	-- en couleur à la position spinMount.

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
	--
	-- POLISH (player feedback) : on envoie aussi la LISTE des noms de brainrots
	-- du pool. Le client va orchestrer le cycling visuel des silhouettes
	-- LOCALEMENT à 60Hz+ (pas de réplication = pas de stutter à 2 FPS comme
	-- avant, où chaque clone.Parent = spinMount partait par le réseau).
	-- Le serveur garde un currentDisplay non visible pour la détection /
	-- compat, mais l'animation perçue est 100% client.
	local poolNames = {}
	for _, t in ipairs(pool) do
		table.insert(poolNames, t.Name)
	end
	dunkSequenceEvent:FireClient(player, "SpinStarted", {
		SpinMount = spinMount,
		ImpactPosition = impactPos,
		PoolNames = poolNames,
		SpinDuration = SPIN_DURATION,
		SwitchMin = SILHOUETTE_SWITCH_MIN,
		SwitchMax = SILHOUETTE_SWITCH_MAX,
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

	-- POLISH (player feedback) : auparavant le serveur faisait l'animation
	-- en spawnant/détruisant des Models inside spinMount à chaque switch.
	-- Comme spinMount.Parent = Workspace, ces changements étaient répliqués
	-- au client à la fréquence réseau (~20Hz max), donc le joueur voyait le
	-- cycling à 2 FPS. Désormais l'animation pendant le spin est 100% côté
	-- client (cf. DunkLuckyBlockController "SpinStarted" : utilise PoolNames
	-- pour cloner les templates LOCALEMENT et swap à 60+Hz). Le serveur ne
	-- repère plus les silhouettes ici ; il se contente d'attendre la fin du
	-- spin avant d'instancier le brainrot FINAL en couleur.
	task.wait(SPIN_DURATION)

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
			-- Taille en STUDS (UDim2.new(scale=studs, 0, ...)) : le billboard a une
			-- taille mondiale fixe qui s'adapte naturellement à la distance, donc
			-- pas de "énorme" billboard quand on est proche.
			bb.Size = UDim2.new(4, 0, 1.6, 0)
			bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.MaxDistance = 200
			bb.Parent = currentDisplay.PrimaryPart

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Vertical
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout.VerticalAlignment = Enum.VerticalAlignment.Top
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Parent = bb

			local function mkLabel(text, color, order)
				local l = Instance.new("TextLabel")
				l.BackgroundTransparency = 1
				l.Size = UDim2.new(1, 0, 1 / 3, 0)
				l.Font = Enum.Font.GothamBlack
				l.Text = text
				l.TextColor3 = color
				l.TextScaled = true
				l.TextStrokeTransparency = 0
				l.TextStrokeColor3 = Color3.new(0, 0, 0)
				l.LayoutOrder = order
				l.Parent = bb
			end
			mkLabel(finalInfo.FullName, Color3.fromRGB(255, 255, 255), 1)
			mkLabel(finalInfo.RarityType, finalInfo.RarityColor, 2)
			mkLabel("$" .. BrainrotInfo.FormatShort(finalInfo.CashPerSecond) .. "/s",
				Color3.fromRGB(120, 230, 120), 3)
		end
	end

	-- Pause plus longue pour laisser le joueur voir le brainrot + son billboard.
	task.wait(1.2)

	if spinVfxCtx and spinVfxCtx.attachment and spinVfxCtx.attachment.Parent then
		spinVfxCtx.attachment:Destroy()
	end

	-- 5) Reveal : on détruit le display temporaire. La transformation
	-- du joueur en brainrot se fait côté client (weld du mesh sur le HRP
	-- du character) pour que les contrôles natifs (joystick mobile inclus)
	-- fonctionnent. Le serveur n'a plus besoin de spawner un Model brainrot
	-- séparé avec sa propre physique.
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

	-- Sauve la position d'origine du joueur (avant la séquence Dunk) pour
	-- pouvoir le ramener à son spawn d'origine en cas de mort par la wave
	-- (BrainrotLost). Sans ça, le joueur reste à impactPos.
	local originalPlayerCFrame = nil
	do
		local _char = player.Character
		local _hrp = _char and _char:FindFirstChild("HumanoidRootPart")
		if _hrp then
			originalPlayerCFrame = _hrp.CFrame
		end
	end

	-- Téléporte le character du joueur à la position d'impact pour qu'il
	-- démarre la phase de fuite à l'endroit où le brainrot est apparu (et
	-- pas à son spawn d'origine après tout le mini-jeu Dunk).
	local playerCharacter = player.Character
	local playerHRP_Tp = playerCharacter and playerCharacter:FindFirstChild("HumanoidRootPart")
	if playerHRP_Tp then
		-- Léger offset Y pour ne pas spawner enfoncé dans le sol.
		playerHRP_Tp.CFrame = CFrame.new(impactPos + Vector3.new(0, 3, 0))
		playerHRP_Tp.AssemblyLinearVelocity = Vector3.zero
		playerHRP_Tp.AssemblyAngularVelocity = Vector3.zero
	end

	-- Met le character du joueur dans le collision group pour qu'il passe
	-- à travers les BlockPart (comme l'ancien brainrot Model).
	if playerCharacter then
		for _, d in ipairs(playerCharacter:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CollisionGroup = BRAINROT_COLLISION_GROUP
			end
		end
	end

	-- Calcule la WalkSpeed cible (SpeedLevel + gamepass Speed12X) et l'applique
	-- DIRECTEMENT côté serveur sur le Humanoid du character. Comme le Humanoid
	-- est répliqué et que le character est network-owned par le client, le
	-- joueur peut bouger immédiatement.
	local speedLevelVal = player:FindFirstChild("SpeedLevel")
	local targetWalkSpeed = SpeedConfig.GetSpeedForLevel(speedLevelVal and speedLevelVal.Value or 0)
	local DataService = Loader.GetService("DataService")
	if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "Speed12X") then
		targetWalkSpeed = targetWalkSpeed * GamepassConfig.SPEED_1_2X_MULT
	end
	if playerCharacter then
		local hum = playerCharacter:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = targetWalkSpeed
			hum.JumpPower = 55
			hum.UseJumpPower = true
		end
	end

	-- TRANSFORMATION CÔTÉ SERVEUR : weld le mesh brainrot sur le HRP du joueur
	-- et cache son corps original. Tout est répliqué à tous les clients
	-- automatiquement.
	PlayerBrainrotTransform.Apply(player, finalTemplate.Name)
	table.insert(cleanupTasks, function()
		PlayerBrainrotTransform.Remove(player)
	end)

	-- Notifie le client uniquement pour les ajustements UI/caméra (cache la
	-- TopBar, repositionne la caméra, etc.). La transformation visuelle est
	-- déjà faite par le serveur ci-dessus.
	dunkSequenceEvent:FireClient(player, "BrainrotPicked", {
		BrainrotName = finalTemplate.Name,
		WalkSpeed = targetWalkSpeed,
		JumpPower = 55,
	})

	-- HRP de référence pour les détections wave/KickReady : c'est le HRP
	-- du character du joueur (qui est devenu le brainrot via weld).
	local trackHRP = playerHRP_Tp


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
		-- Fallback : si la W-part n'existe pas pour cette rareté, on calcule la
		-- direction depuis la KickReady récupérée à la volée. Anciennement le code
		-- référençait `kickReadyPart` qui n'existait PAS dans ce scope, ce qui
		-- levait une erreur runtime et laissait le joueur figé en mode brainrot
		-- (WalkSpeed=0, transformation jamais retirée).
		local kickReadyFallback = getKickReady()
		if kickReadyFallback then
			local dx = kickReadyFallback.Position.X - impactPos.X
			local dz = kickReadyFallback.Position.Z - impactPos.Z
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
						activeRunningClones[userId] = newClone
					end
				end)
			end
		end

		dunkSequenceEvent:FireClient(player, "WaveChase", {
			BrainrotName = finalTemplate.Name,
			WalkSpeed = targetWalkSpeed,
			JumpPower = 55,
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
		-- POLISH : grace period au démarrage où la wave ne peut PAS tuer.
		-- Évite la mort instantanée pile au touchdown si la wave spawn déjà
		-- au contact de la position du brainrot.
		local hitDetectionStartTime = chaseStartTime + WAVE_TOUCHDOWN_GRACE
		local chaseStartPos = waveMetrics.EndPos
		local chaseSpeed = getWaveChaseSpeed(waveRarity)
		-- Hitbox de la wave RESSERÉE par rapport au bounding box du modèle.
		-- Le modèle inclut souvent des effets/éclats qui débordent la silhouette
		-- visible. On prend 45% des dims (au lieu de 50%) pour ne déclencher
		-- BrainrotLost que si la wave touche réellement le brainrot, pas son halo.
		local halfX = waveMetrics.WaveLengthX * 0.6
		local halfZ = waveMetrics.WaveWidthZ * 0.6
		-- Axes locaux de la wave (orientée avec lookAt vers fixedDir) :
		--   LookVector = fixedDir, RightVector = perp horizontal.
		local rightDir = Vector3.new(-fixedDir.Z, 0, fixedDir.X) -- perp horizontal de fixedDir

		waveChaseConn = RunService.Heartbeat:Connect(function()
			if waveCaughtBrainrot then return end
			-- On track le HRP du character du joueur (qui est devenu le brainrot
			-- via le weld côté client). Si le character disparait (mort, leave),
			-- on tente de le récupérer ; sinon on skip cette frame.
			if not trackHRP or not trackHRP.Parent then
				local char = player.Character
				trackHRP = char and char:FindFirstChild("HumanoidRootPart")
				if not trackHRP then return end
			end

			local now = os.clock()
			local elapsed = now - chaseStartTime
			if elapsed < 0 then return end -- délai de démarrage : wave encore immobile
			local travel = chaseSpeed * elapsed
			local wavePos = chaseStartPos + fixedDir * travel
			if fixedDir.X > 0 and wavePos.X > WAVE_STOP_X then
				wavePos = Vector3.new(WAVE_STOP_X, wavePos.Y, wavePos.Z)
			end

			-- POLISH : grace period au touchdown. Tant qu'on n'a pas dépassé
			-- hitDetectionStartTime, la wave est invisible aux yeux du hit-test.
			-- Donne au joueur une fenêtre garantie pour réagir.
			if now < hitDetectionStartTime then return end

			local toBr = trackHRP.Position - wavePos
			local toBrHoriz = Vector3.new(toBr.X, 0, toBr.Z)

			local projRight = toBrHoriz:Dot(rightDir)
			local projFwd   = toBrHoriz:Dot(fixedDir)

			if projFwd > halfZ then return end

			-- Filet supplémentaire : refuse le kill si l'overlap géométrique est
			-- TROP serré (le brainrot est quasi-collé au centre de la wave dès
			-- la 1re frame, ce qui révèle un touchdown defectueux). On laisse la
			-- wave s'éloigner suffisamment avant d'autoriser le hit.
			if toBrHoriz.Magnitude < WAVE_MIN_HORIZONTAL_DIST then return end

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
	-- IMPORTANT : on ATTEND la fin de la phase WaveChase startDelay avant de
	-- démarrer la détection. Sinon, si impactPos est proche/dans KickReady (tir
	-- court), le monitorConn déclenche immédiatement crossed=true alors que
	-- le brainrot est encore frozen à spawn et que le joueur n'a pas eu le
	-- temps de courir, ce qui donne un BrainrotSold prématuré et un retour au
	-- character au lieu d'être en mode brainrot.
	local kickReadyPart2 = getKickReady()
	local crossed = false
	local monitorEnabled = false
	local monitorConn
	monitorConn = RunService.Heartbeat:Connect(function()
		if crossed then return end
		if not monitorEnabled then return end
		-- Re-récupère le HRP du character du joueur (peut changer si respawn).
		if not trackHRP or not trackHRP.Parent then
			local char = player.Character
			trackHRP = char and char:FindFirstChild("HumanoidRootPart")
			if not trackHRP then return end
		end
		if not kickReadyPart2 or not kickReadyPart2.Parent then return end
		if isPointInsidePart(trackHRP.Position, kickReadyPart2) then
			crossed = true
		end
	end)
	table.insert(cleanupTasks, function() if monitorConn then monitorConn:Disconnect() end end)

	-- Active la détection après la phase rise+showcase+startDelay : à ce moment,
	-- le brainrot est dégelé et le joueur peut courir. Tout franchissement de
	-- KickReady avant ce moment est ignoré.
	task.delay(WAVE_CHASE_START_DELAY + 0.2, function()
		monitorEnabled = true
	end)

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
		local toClean = activeRunningClones[userId] or cloneInstance
		activeRunningClones[userId] = nil
		if toClean and DunkCloneService then
			DunkCloneService:Cleanup(toClean)
		end

		-- ===== INSTANT KILL + RESPAWN IMMEDIAT =====
		-- 1) Retire le visuel brainrot weldé. skipRestore=true : on ne restaure
		--    PAS la transparence du character d'origine, sinon il flash 1 frame
		--    en mode "vrai skin" avant que LoadCharacter() le detruise.
		PlayerBrainrotTransform.Remove(player, true)

		-- 2) Tue le joueur via Humanoid.Health = 0 pour declencher le son
		--    de mort natif de Roblox (LoadCharacter() seul court-circuite le
		--    systeme de mort et personne n'entend le "oof").
		local deadChar = player.Character
		local deadHum = deadChar and deadChar:FindFirstChildOfClass("Humanoid")
		if deadHum then
			deadHum.Health = 0
		end

		-- 3) Micro-delai pour laisser le client entendre le son de mort avant
		--    qu'on detruise le character via LoadCharacter().
		task.wait(0.2)

		-- 4) player:LoadCharacter() detruit instantanement l'ancien Character
		--    (corps ragdoll inclus) et en respawn un nouveau, sans attendre
		--    les 5s du Respawn natif.
		player:LoadCharacter()

		-- 5) STOP : on coupe la fonction ici. Sans ce return, la suite de
		--    runSequence (restauration character, teleport vers originalPlayerCFrame)
		--    annulerait le respawn en repositionnant le nouveau character a la
		--    place pre-dunk, donnant l'impression au joueur qu'il n'est jamais mort.
		dunkSequenceEvent:FireClient(player, "End", {})
		cleanup()
		return
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
		local toClean = activeRunningClones[userId] or cloneInstance
		activeRunningClones[userId] = nil
		if toClean and DunkCloneService then
			DunkCloneService:Cleanup(toClean)
		end
	end

	-- Fin : revert la transformation (restaure le character visible et détruit
	-- le visuel brainrot weldé). Restaure aussi le collision group du character.
	PlayerBrainrotTransform.Remove(player)

	local endChar = player.Character
	if endChar then
		for _, d in ipairs(endChar:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CollisionGroup = "Default"
			end
		end
		-- Restaure WalkSpeed/JumpPower par défaut.
		-- Teleporte le joueur a sa position d'origine (avant le tir). Sans ca,
		-- il reste plante a impactPos apres BrainrotLost / BrainrotSold.
		local endHRP = endChar:FindFirstChild("HumanoidRootPart")
		if endHRP and originalPlayerCFrame then
			endHRP.CFrame = originalPlayerCFrame
			endHRP.AssemblyLinearVelocity = Vector3.zero
			endHRP.AssemblyAngularVelocity = Vector3.zero
		end

		local hum = endChar:FindFirstChildOfClass("Humanoid")
		if hum then
			local StarterPlayer = game:GetService("StarterPlayer")
			local targetWS = StarterPlayer.CharacterWalkSpeed
			local targetJP = StarterPlayer.CharacterJumpPower
			local targetJH = StarterPlayer.CharacterJumpHeight
			hum.WalkSpeed = targetWS
			hum.JumpPower = targetJP
			hum.JumpHeight = targetJH
			pcall(function()
				hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
				hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
			end)
			-- Force-overwrite WalkSpeed pendant 1s pour battre le client qui peut
			-- avoir cache un WalkSpeed=0 et l'ecrire en même temps que nous.
			local forceStart = os.clock()
			local forceConn
			forceConn = RunService.Heartbeat:Connect(function()
				if not hum or not hum.Parent or os.clock() - forceStart > 1.0 then
					if forceConn then forceConn:Disconnect() end
					return
				end
				if hum.WalkSpeed < targetWS then hum.WalkSpeed = targetWS end
				if hum.JumpPower < targetJP then hum.JumpPower = targetJP end
			end)
		end
	end

	-- Sécurité : si le clone n'a pas été cleanup avant, on le fait ici.
	local runningClone = activeRunningClones[userId]
	if runningClone and DunkCloneService then
		activeRunningClones[userId] = nil
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
--   DunkBrainrot  vs DunkBrainrot   -> PAS de collision (les joueurs en
--                                     brainrot se traversent entre eux,
--                                     sinon on a des bouchons et collisions
--                                     parasites à plusieurs en parallèle)
--   DunkBrainrot  vs DunkCloneRunner-> PAS de collision (un joueur en
--                                     brainrot doit aussi traverser les
--                                     clones décoratifs des autres)
-- Les autres joueurs (qui ne sont PAS en brainrot) utilisent Default et
-- entrent donc en collision avec les BlockPart normalement.
local function setupCollisionGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(BRAINROT_COLLISION_GROUP)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(BLOCKPART_COLLISION_GROUP)
	end)
	-- Pre-register le DunkCloneRunner ICI pour pouvoir poser les règles
	-- croisées BRAINROT ↔ CLONE_RUNNER dès l'init du serveur, sans dépendre
	-- de l'ordre d'exécution lazy de DunkCloneService.
	pcall(function()
		PhysicsService:RegisterCollisionGroup("DunkCloneRunner")
	end)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BRAINROT_COLLISION_GROUP, BLOCKPART_COLLISION_GROUP, false)
	end)
	-- Brainrot vs Brainrot : les joueurs transformés se traversent.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BRAINROT_COLLISION_GROUP, BRAINROT_COLLISION_GROUP, false)
	end)
	-- Brainrot vs CloneRunner : un brainrot traverse les clones (et
	-- inversement). Cela couvre le cas joueur A en brainrot qui croise le
	-- clone décoratif de joueur B en pleine course.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BRAINROT_COLLISION_GROUP, "DunkCloneRunner", false)
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
	-- Crée le remote SetCustomPowerEvent (slider UI "SetKickPower"). Le client
	-- envoie sa puissance choisie ici ; on la stocke par-joueur pour la lire
	-- dans getPlayerPower au moment du dunk.
	setCustomPowerEvent = RemotesAPI.GetEvent("SetCustomPowerEvent")
	brainrotsFolder = ReplicatedStorage:WaitForChild("Brainrots")
	luckyBlocksFolder = ReplicatedStorage:WaitForChild("LuckyBlocks")
	wavesFolder = ReplicatedStorage:FindFirstChild("Waves")

	setupCollisionGroups()
end

function DunkLuckyBlockService:Start()
	BrainrotService = Loader.GetService("BrainrotService")
	DunkCloneService = Loader.GetService("DunkCloneService")

	tagBlockParts()

	setCustomPowerEvent.OnServerEvent:Connect(function(player, value)
		if typeof(value) ~= "number" or value ~= value then return end
		customKickPower[player.UserId] = math.max(0, value)
	end)

	dunkRequestEvent.OnServerEvent:Connect(function(player, grade, fill)
		-- Validation basique : grade doit être un string connu, fill un number [0,1].
		if typeof(grade) ~= "string" or not GRADE_WEIGHT[grade] then
			grade = "MID"
		end
		-- NaN check (fill ~= fill est true UNIQUEMENT pour NaN) puis clamp [0,1].
		if typeof(fill) ~= "number" or fill ~= fill then
			fill = 0.5
		end
		fill = math.clamp(fill, 0, 1)

		-- Anti-spam serveur : limite la cadence à 1 tir / DUNK_MIN_INTERVAL
		-- secondes même si un exploiteur tente de bypass le mini-jeu de timing
		-- côté client. inSession bloque déjà les concurrents pendant la séquence
		-- en cours, mais ce cooldown empêche de relancer immédiatement après la fin.
		local userId = player.UserId
		local nowClock = os.clock()
		local last = lastDunkAt[userId] or 0
		if nowClock - last < DUNK_MIN_INTERVAL then
			return
		end
		if inSession[userId] then return end
		lastDunkAt[userId] = nowClock

		task.spawn(runSequence, player, grade, fill)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		inSession[userId] = nil
		lastDunkAt[userId] = nil
		customKickPower[userId] = nil
		-- Cleanup d'un éventuel running clone laissé par la session courante.
		local clone = activeRunningClones[userId]
		activeRunningClones[userId] = nil
		if clone and DunkCloneService then
			pcall(function() DunkCloneService:Cleanup(clone) end)
		end
		PlayerBrainrotTransform.Remove(player)
	end)

	print("[DunkLuckyBlockService] Prêt")
end

return DunkLuckyBlockService

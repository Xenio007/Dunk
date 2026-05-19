--[[
	SpeedConfig
	Configuration partagée (client + serveur) pour la vitesse du brainrot
	contrôlé pendant la séquence Dunk.

	Formule :
		- Speed de base = 13 (SpeedLevel 0)
		- Chaque amélioration = +1 speed
		- Max = 150 (SpeedLevel 137)
		- Les 4 premières améliorations (13 -> 14, 15, 16, 17) sont gratuites
		- À partir de speed 18 : prix = BASE_PRICE * MULTIPLIER^(speed - 18)

	Prix vérifiés avec le tableau :
		speed 18 -> 50$,  20 -> 107$,  30 -> 4.9K,  50 -> 10.2M,
		speed 80 -> 972B, 150 -> 401e21
]]

local SpeedConfig = {}

SpeedConfig.BASE_SPEED = 13
SpeedConfig.MAX_SPEED = 150
SpeedConfig.MAX_LEVEL = SpeedConfig.MAX_SPEED - SpeedConfig.BASE_SPEED  -- 137

-- Nombre d'améliorations gratuites au début : 13 -> 14 -> 15 -> 16 -> 17 = 4 free.
SpeedConfig.FREE_UPGRADES = 4

-- À partir de la 5ème amélioration (speed 18), le prix commence à BASE_PRICE
-- et est multiplié par MULTIPLIER à chaque niveau supplémentaire.
SpeedConfig.BASE_PRICE = 50
SpeedConfig.MULTIPLIER = 1.465

-- Retourne la valeur de WalkSpeed correspondant à un niveau.
function SpeedConfig.GetSpeedForLevel(level)
	level = math.max(0, math.min(SpeedConfig.MAX_LEVEL, level or 0))
	return SpeedConfig.BASE_SPEED + level
end

-- Prix pour passer de `level` à `level + 1`. Retourne 0 pour les niveaux gratuits.
function SpeedConfig.GetUpgradeCost(level)
	level = math.max(0, level or 0)
	if level >= SpeedConfig.MAX_LEVEL then
		return math.huge
	end
	if level < SpeedConfig.FREE_UPGRADES then
		return 0
	end
	-- Niveau n (n >= FREE_UPGRADES) : speed = BASE_SPEED + n + 1
	-- Le 1er payant est level=FREE_UPGRADES -> prix = BASE_PRICE (speed 18)
	local exp = level - SpeedConfig.FREE_UPGRADES
	return math.floor(SpeedConfig.BASE_PRICE * (SpeedConfig.MULTIPLIER ^ exp) + 0.5)
end

-- Prix cumulé pour acheter `count` améliorations à partir de `fromLevel`.
-- Les niveaux gratuits sont ignorés dans le cumul.
function SpeedConfig.GetTotalCost(fromLevel, count)
	fromLevel = math.max(0, fromLevel or 0)
	count = math.max(0, count or 0)
	local maxReachable = math.min(count, SpeedConfig.MAX_LEVEL - fromLevel)
	local total = 0
	for i = 0, maxReachable - 1 do
		total = total + SpeedConfig.GetUpgradeCost(fromLevel + i)
	end
	return total, maxReachable
end

-- Nombre maximum d'améliorations achetables avec `cash` à partir de `fromLevel`.
-- Retourne (count, totalCost).
function SpeedConfig.GetMaxAffordable(fromLevel, cash)
	fromLevel = math.max(0, fromLevel or 0)
	cash = math.max(0, cash or 0)
	local total = 0
	local count = 0
	local level = fromLevel
	while level < SpeedConfig.MAX_LEVEL do
		local cost = SpeedConfig.GetUpgradeCost(level)
		if total + cost > cash then break end
		total = total + cost
		count = count + 1
		level = level + 1
	end
	return count, total
end

return SpeedConfig

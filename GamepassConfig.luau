--[[
	GamepassConfig
	Configuration partagée client/serveur des Developer Products de type gamepass
	(achats Robux persistants qui activent un bonus permanent).

	Les 5 products :
	  STARTER_PACK  : donne Six Seven + Tung Sahur + 3 niveaux de Speed (one-shot).
	  CASH_X2       : multiplie par 2 le cash sur chaque bouton de brainrot placé.
	  POWER_X2      : multiplie par 2 le PowerPerLift des poids.
	  SPEED_1_2X    : multiplie par 1.2 la vitesse du brainrot contrôlé.
	  BRAINROT_LUCK : 2x plus de chance d'avoir les meilleurs brainrots au roll.
]]

local GamepassConfig = {}

GamepassConfig.PRODUCTS = {
	STARTER_PACK  = 3588741658,
	CASH_X2       = 3588742362,
	POWER_X2      = 3588745160,
	SPEED_1_2X    = 3588745767,
	BRAINROT_LUCK = 3588747742,
	VIP           = 3590169442,
	MUTATION_LUCK = 3590171987,
	-- ServerLuck n'est PAS un gamepass persistant : c'est un boost temporaire
	-- partagé (15 min) qui s'empile x1 -> x2 -> x3. Il est consommé à l'achat
	-- et n'est donc pas dans les flags persistants `FLAGS`. L'ID reste ici
	-- pour que GameService.processReceipt puisse router l'achat.
	SERVER_LUCK   = 3590166144,
}

-- Icônes affichées dans BottomRight quand le gamepass est actif. On réutilise
-- les mêmes images que celles du shop (ShopFrame.Scrolling.Deals...Content.Icon)
-- pour garantir la cohérence visuelle.
GamepassConfig.ICONS = {
	CASH_X2       = "rbxassetid://106254793390209",
	POWER_X2      = "rbxassetid://135296567981241",
	SPEED_1_2X    = "rbxassetid://86964499984867",
	BRAINROT_LUCK = "rbxassetid://83875465599007",
	VIP           = "rbxassetid://79304377550054",
	MUTATION_LUCK = "rbxassetid://90240660519266",
	SERVER_LUCK   = "rbxassetid://83875465599007", -- fallback ; remplacer si besoin
}

-- Multiplicateurs appliqués par les gamepasses.
GamepassConfig.CASH_X2_MULT        = 2
GamepassConfig.POWER_X2_MULT       = 2
GamepassConfig.SPEED_1_2X_MULT     = 1.2
GamepassConfig.BRAINROT_LUCK_MULT  = 2  -- poids x2 sur les brainrots haut CPS
-- ServerLuck : boost temporaire partagé par TOUT le serveur.
-- Achat x1 -> le serveur passe de 1x à 2x pendant 15 min.
-- Rachat pendant les 15 min -> passe à 3x, timer réinitialisé à 15 min.
-- Rachat suivant (pendant les 15 min) -> 4x, etc. Cap à un multiplicateur max.
GamepassConfig.SERVER_LUCK_DURATION  = 15 * 60  -- 15 minutes
GamepassConfig.SERVER_LUCK_STEPS     = { 1, 2, 3, 4, 6 } -- échelle des multiplicateurs


-- Contenu du StarterPack.
GamepassConfig.STARTER_BRAINROTS = { "Six Seven", "Tung Sahur" }
GamepassConfig.STARTER_SPEED_LEVELS = 3

-- Set des productIds pour reconnaissance rapide. Les IDs à 0 (gamepass non
-- encore publiés) sont ignorés pour éviter des collisions bidons.
GamepassConfig.PRODUCT_ID_SET = {}
for _, id in pairs(GamepassConfig.PRODUCTS) do
	if id and id > 0 then
		GamepassConfig.PRODUCT_ID_SET[id] = true
	end
end

-- Reverse map : productId -> nom de flag. On skip les IDs à 0 (non configurés).
GamepassConfig.FLAG_FOR_PRODUCT = {}
for key, flagName in pairs({
	STARTER_PACK  = "StarterPack",
	CASH_X2       = "CashX2",
	POWER_X2      = "PowerX2",
	SPEED_1_2X    = "Speed12X",
	BRAINROT_LUCK = "BrainrotLuck",
	VIP           = "VIP",
	MUTATION_LUCK = "MutationLuck",
}) do
	local productId = GamepassConfig.PRODUCTS[key]
	if productId and productId > 0 then
		GamepassConfig.FLAG_FOR_PRODUCT[productId] = flagName
	end
end

-- Liste des flags persistants (nom court stocké dans le profil).
GamepassConfig.FLAGS = {
	"StarterPack", "CashX2", "PowerX2", "Speed12X", "BrainrotLuck",
	"VIP", "MutationLuck",
}

return GamepassConfig

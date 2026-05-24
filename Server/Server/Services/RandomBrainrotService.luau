--[[
	RandomBrainrotService
	Gère l'achat du Developer Product RANDOM_BRAINROT_PRODUCT_ID :
	donne un brainrot aléatoire AU CHOIX PARMI L'INDEX DÉCOUVERT du joueur
	(ceux qu'il a déjà trouvés au moins une fois). Probabilité plus faible
	pour les brainrots rares (CPS élevé = poids faible).

	Exposé via :HandlePurchase(player, productId), appelé par GameService
	dans son ProcessReceipt.
--]]

local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader      = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local BrainrotInfo
pcall(function()
	BrainrotInfo = require(ReplicatedStorage.Shared.BrainrotInfo)
end)

local RandomBrainrotService = Loader.CreateService({
	Name = "RandomBrainrotService",
})

-- ============================================================
-- Configuration
-- ============================================================
local RANDOM_BRAINROT_PRODUCT_ID = 3591856301

-- Poids par rarété. Tous les brainrots d'une même rarété ont strictement la
-- même chance d'être tirés ; entre rarétés, la différence vient juste de ce
-- multiplicateur. Plus le poids est haut, plus la rarété est probable.
-- Ratio actuel (du plus probable au moins probable) :
--   Legendary 100 / Mythic 50 / Secret 20 / God 8 / OG 3.
local RARITY_WEIGHTS = {
	Legendary = 100,
	Mythic    = 50,
	Secret    = 20,
	God       = 8,
	OG        = 3,
}

-- Rarétés autorisées pour le random brainrot. Tout ce qui est en dessous
-- (Common, Uncommon, Rare, Epic) ne peut PAS être tiré : la rarété minimum
-- est Legendary.
local ALLOWED_RARITIES = {
	Legendary = true,
	Mythic    = true,
	Secret    = true,
	God       = true,
	OG        = true,
}

-- Variants persistés par BrainrotDiscoveryService dans les attributes
-- Discovered_<Variant>.
local VARIANTS = { "Normal", "Gold", "Diamond", "Galaxy", "Lava", "Rainbow", "Hacker" }

-- ============================================================
-- Récupère l'index découvert du joueur depuis ses attributes.
-- Retourne un set { fullName -> true } reconstruit à partir de
-- BaseName + Variant via BrainrotInfo (même logique que IndexController).
-- ============================================================
local function getDiscoveredFullNames(player)
	local result = {}
	for _, variant in ipairs(VARIANTS) do
		local joined = player:GetAttribute("Discovered_" .. variant)
		if typeof(joined) == "string" and joined ~= "" then
			for baseName in string.gmatch(joined, "([^,]+)") do
				-- Le fullName est reconstructible via BrainrotInfo.
				-- BrainrotInfo expose généralement BuildFullName(baseName, variant).
				local fullName = baseName
				if BrainrotInfo and BrainrotInfo.BuildFullName then
					local ok, n = pcall(BrainrotInfo.BuildFullName, baseName, variant)
					if ok and typeof(n) == "string" and n ~= "" then
						fullName = n
					end
				elseif variant ~= "Normal" then
					-- Fallback : convention courante <Variant> <BaseName>.
					fullName = variant .. " " .. baseName
				end
				result[fullName] = true
			end
		end
	end
	return result
end

-- ============================================================
-- Choix pondéré d'un brainrot.
-- Source par défaut : l'index DÉCOUVERT du joueur (filtré rarité Epic+).
-- Fallback (joueur sans rien dans son index, typiquement nouveau joueur) :
-- la totalité des brainrots Normal de rarété autorisée. Sans ce fallback
-- l'achat échouait silencieusement pour les nouveaux joueurs.
-- Le poids est 1/CPS^HARDNESS dans les deux cas (les brainrots à fort CPS
-- restent rares).
-- ============================================================
local function pickRandomBrainrotForPlayer(player)
	local discovered = getDiscoveredFullNames(player)

	local brainrotsFolder = ReplicatedStorage:FindFirstChild("Brainrots")
	if not brainrotsFolder then return nil end

	local templates = {}
	local weights = {}
	local totalWeight = 0

	-- Helper pour ajouter un model. Si `requireDiscovered` est vrai, le model
	-- doit être dans l'index découvert ; sinon on prend tous les models
	-- valides (rarété autorisée + non exclusifs).
	local function tryAdd(model, requireDiscovered)
		if not model:IsA("Model") then return end
		if requireDiscovered and not discovered[model.Name] then return end
		-- Les brainrots exclusifs (Robux only) ne sont jamais distribués par
		-- le random product.
		if BrainrotInfo and BrainrotInfo.IsExclusive and BrainrotInfo.IsExclusive(model.Name) then
			return
		end
		local rarityType
		if BrainrotInfo and BrainrotInfo.GetInfo then
			local info = BrainrotInfo.GetInfo(model.Name)
			rarityType = info and info.RarityType
		end
		-- Filtre minimum Legendary : on ne tire que dans les rarétés autorisées.
		if not ALLOWED_RARITIES[rarityType or ""] then
			return
		end
		-- Poids = poids de la rarété. Tous les brainrots d'une même rarété ont
		-- exactement le même poids, peu importe leur CPS individuel.
		local weight = RARITY_WEIGHTS[rarityType] or 1
		table.insert(templates, model)
		table.insert(weights, weight)
		totalWeight = totalWeight + weight
	end

	-- Pas de filtrage par index : on tire dans TOUS les brainrots Normal de
	-- rarété autorisée (Legendary+), peu importe que le joueur les ait déjà
	-- découverts ou non. Ratio par rarété défini par RARITY_WEIGHTS.
	local normalFolder = brainrotsFolder:FindFirstChild("Normal")
	if normalFolder then
		for _, m in ipairs(normalFolder:GetChildren()) do
			tryAdd(m, false)
		end
	end

	if #templates == 0 or totalWeight <= 0 then
		return nil
	end

	local r = math.random() * totalWeight
	local acc = 0
	for i, w in ipairs(weights) do
		acc = acc + w
		if r <= acc then
			return templates[i]
		end
	end
	return templates[#templates]
end

-- ============================================================
-- API publique : appelée depuis GameService.processReceipt
-- ============================================================
function RandomBrainrotService:HandlePurchase(player, productId)
	if productId ~= RANDOM_BRAINROT_PRODUCT_ID then return false end
	if not player or not player.Parent then return false end

	local template = pickRandomBrainrotForPlayer(player)
	if not template then
		warn("[RandomBrainrotService] " .. player.Name .. " : aucun brainrot éligible (pool Legendary+ vide?)")
		return false
	end

	local brainrotService = Loader.GetService("BrainrotService")
	if not brainrotService or not brainrotService.GiveBrainrotByName then
		warn("[RandomBrainrotService] BrainrotService introuvable")
		return false
	end

	local tool = brainrotService:GiveBrainrotByName(player, template.Name)
	if not tool then
		warn("[RandomBrainrotService] Échec GiveBrainrotByName pour " .. template.Name)
		return false
	end

	print("[RandomBrainrotService] " .. player.Name .. " a reçu " .. template.Name .. " via product random (depuis index)")
	return true
end

function RandomBrainrotService:Init() end
function RandomBrainrotService:Start()
	print("[RandomBrainrotService] Prêt (productId=" .. RANDOM_BRAINROT_PRODUCT_ID .. ", source=index, weights=per-rarity)")
end

return RandomBrainrotService

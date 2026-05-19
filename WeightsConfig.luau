--[[
	WeightsConfig - Configuration de tous les poids
	Partagé entre client et serveur
]]

local WeightsConfig = {}

-- Ordre d'affichage et données de chaque poids
WeightsConfig.Weights = {
	{
		Name = "Wooden Stick",
		Price = 0,
		Robux = 0,
		ProductId = nil,
		Rarity = "Common",
		Stats = "5 lbs",
		Order = 1,
		Image = "rbxassetid://107028907721174",
	},
	{
		Name = "Bone Barbell",
		Price = 7500,
		Robux = 9,
		ProductId = 3585803809,
		Rarity = "Rare",
		Stats = "10 lbs",
		Order = 2,
		Image = "rbxassetid://135753766638510",
	},
	{
		Name = "Stone Block",
		Price = 75000,
		Robux = 29,
		ProductId = 3585804318,
		Rarity = "Epic",
		Stats = "45 lbs",
		Order = 3,
		Image = "rbxassetid://101593158569292",
	},
	{
		Name = "Copper Plate",
		Price = 500000,
		Robux = 99,
		ProductId = 3585804922,
		Rarity = "Legendary",
		Stats = "135 lbs",
		Order = 4,
		Image = "rbxassetid://102536102526793",
	},
	{
		Name = "Iron Plate",
		Price = 7500000,
		Robux = 199,
		ProductId = 3585805271,
		Rarity = "Mythic",
		Stats = "225 lbs",
		Order = 5,
		Image = "rbxassetid://93625089595931",
	},
	{
		Name = "Ice Barbell",
		Price = 350000000,
		Robux = 349,
		ProductId = 3585805622,
		Rarity = "Godly",
		Stats = "450 lbs",
		Order = 6,
		Image = "rbxassetid://133922560410515",
	},
	{
		Name = "Donut Barbell",
		Price = 6200000000,
		Robux = 499,
		ProductId = 3585805943,
		Rarity = "Secret",
		Stats = "900 lbs",
		Order = 7,
		Image = "rbxassetid://120253465516356",
	},
	{
		Name = "Golden Barbell",
		Price = 85000000000,
		Robux = 579,
		ProductId = 3585806488,
		Rarity = "Divine",
		Stats = "1,800 lbs",
		Order = 8,
		Image = "rbxassetid://87889411450388",
	},
	{
		Name = "Heaven Plate",
		Price = 1200000000000,
		Robux = 795,
		ProductId = 3585807082,
		Rarity = "Rainbow",
		Stats = "4,500 lbs",
		Order = 9,
		Image = "rbxassetid://114811903209527",
	},
	{
		Name = "Mega Golden Barbell",
		Price = 18000000000000,
		Robux = 899,
		ProductId = 3585808478,
		Rarity = "Hacked",
		Stats = "9,000 lbs",
		Order = 10,
		Image = "rbxassetid://74984827849628",
	},
	{
		Name = "Neon Pulse",
		Price = 500000000000000,
		Robux = 1199,
		ProductId = 3585808875,
		Rarity = "Demon",
		Stats = "22,500 lbs",
		Order = 11,
		Image = "rbxassetid://123615680795194",
	},
	{
		Name = "Giant Gold Star Barbell",
		Price = 20000000000000000,
		Robux = 1349,
		ProductId = 3585809443,
		Rarity = "OG",
		Stats = "99,999 lbs",
		Order = 12,
		Image = "rbxassetid://111444149301645",
	},
}

-- Couleurs par rareté
WeightsConfig.RarityColors = {
	Common = Color3.fromRGB(170, 255, 0),
	Rare = Color3.fromRGB(0, 170, 255),
	Epic = Color3.fromRGB(170, 0, 255),
	Legendary = Color3.fromRGB(255, 170, 0),
	Mythic = Color3.fromRGB(255, 0, 85),
	Godly = Color3.fromRGB(0, 255, 255),
	Secret = Color3.fromRGB(255, 105, 180),
	Divine = Color3.fromRGB(255, 215, 0),
	Rainbow = Color3.fromRGB(255, 255, 255),
	Hacked = Color3.fromRGB(0, 255, 0),
	Demon = Color3.fromRGB(255, 0, 0),
	OG = Color3.fromRGB(255, 223, 0),
}

-- Animations par poids (barbell = anim1, plate/block = anim2)
local ANIM_BARBELL = "rbxassetid://82868076090490"
local ANIM_PLATE = "rbxassetid://82868076090490"

-- Expose pour les autres scripts (WeightAnimation etc.)
WeightsConfig.ANIM_BARBELL = ANIM_BARBELL
WeightsConfig.ANIM_PLATE = ANIM_PLATE

WeightsConfig.AnimationByWeight = {
	["Wooden Stick"] = ANIM_BARBELL,
	["Bone Barbell"] = ANIM_BARBELL,
	["Stone Block"] = ANIM_PLATE,
	["Copper Plate"] = ANIM_PLATE,
	["Iron Plate"] = ANIM_PLATE,
	["Ice Barbell"] = ANIM_BARBELL,
	["Donut Barbell"] = ANIM_BARBELL,
	["Golden Barbell"] = ANIM_BARBELL,
	["Heaven Plate"] = ANIM_BARBELL,
	["Mega Golden Barbell"] = ANIM_BARBELL,
	["Neon Pulse"] = ANIM_BARBELL,
	["Giant Gold Star Barbell"] = ANIM_BARBELL,
}

-- Extraire le nombre de lbs depuis le champ Stats (ex: "1,800 lbs" -> 1800)
local function parseLbs(statsStr)
	local numStr = statsStr:gsub(",", ""):match("(%d+)")
	return tonumber(numStr) or 0
end

-- Calculer PowerPerLift pour chaque poids (basé sur les lbs)
for _, w in ipairs(WeightsConfig.Weights) do
	w.PowerPerLift = parseLbs(w.Stats)
end

-- Lookup rapide par nom
WeightsConfig.ByName = {}
for _, w in ipairs(WeightsConfig.Weights) do
	WeightsConfig.ByName[w.Name] = w
end

return WeightsConfig
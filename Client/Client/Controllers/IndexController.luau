--[[
	IndexController
	Gère l'index/collection de brainrots (cartes, onglets, recherche, progression).

	Migration 1:1 de StarterGui.MainGui.IndexFrame.IndexController.
	L'ancien script utilisait script.Parent pour référencer l'IndexFrame ;
	on résout explicitement le chemin via PlayerGui.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local IndexController = Loader.CreateController({
	Name = "IndexController",
})

-- === Constantes (identiques à l'ancien script) ===

local RARITIES = {"Normal", "Gold", "Diamond", "Galaxy", "Lava", "Rainbow", "Hacker"}

local RARITY_COLORS = {
	Normal = Color3.fromRGB(180, 180, 180),
	Gold = Color3.fromRGB(255, 215, 0),
	Diamond = Color3.fromRGB(0, 200, 255),
	Galaxy = Color3.fromRGB(150, 0, 255),
	Lava = Color3.fromRGB(255, 80, 0),
	Rainbow = Color3.fromRGB(255, 100, 200),
	Hacker = Color3.fromRGB(0, 255, 100),
}

local RARITY_REWARDS = {
	Normal = "+0.5x Cash Multi",
	Gold = "+1x Cash Multi",
	Diamond = "+2x Cash Multi",
	Galaxy = "+3x Cash Multi",
	Lava = "+4x Cash Multi",
	Rainbow = "+5x Cash Multi",
	Hacker = "+10x Cash Multi",
}

local RARITY_TYPE_COLORS = {
	Common = Color3.fromRGB(4, 184, 22),
	Uncommon = Color3.fromRGB(255, 239, 10),
	Rare = Color3.fromRGB(82, 137, 255),
	Epic = Color3.fromRGB(129, 79, 255),
	Legendary = Color3.fromRGB(255, 70, 70),
	Mythic = Color3.fromRGB(255, 255, 255),
	Secret = Color3.fromRGB(30, 30, 30),
	God = Color3.fromRGB(255, 255, 255),
	OG = Color3.fromRGB(255, 0, 255),
}

local RARITY_TYPE_ORDER = {
	Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5,
	Mythic = 6, Secret = 7, God = 8, OG = 9,
}

-- Brainrots EXCLUSIFS : ne s'affichent PAS dans l'index. Ce sont les
-- brainrots achetables uniquement en Robux sur le spawn (Product 1/2/3).
local EXCLUSIVE_BRAINROTS = {
	["Dragon Cannelloni"] = true,
	["Esok Sekolah"]      = true,
	["Job Job Job Sahur"] = true,
}

local RARITY_TYPE_BG_COLORS = {
	Common = Color3.fromRGB(0x5E, 0x8C, 0x00),
	Uncommon = Color3.fromRGB(0xA0, 0xA0, 0x01),
	Rare = Color3.fromRGB(0x01, 0x6D, 0xA3),
	Epic = Color3.fromRGB(0x6D, 0x01, 0xA3),
	Legendary = Color3.fromRGB(0xA3, 0x6D, 0x01),
	Mythic = Color3.fromRGB(0x8B, 0x0C, 0x0C),
	Secret = Color3.fromRGB(0x00, 0x00, 0x00),
	God = Color3.fromRGB(0x00, 0x00, 0x4E),
	OG = Color3.fromRGB(0xFF, 0x00, 0x00),
}

local RARITY_GRADIENTS = {
	Common = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0x8B, 0xD1, 0x00)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0x87, 0xCB, 0x00)),
		}),
	},
	Uncommon = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0xEE, 0xE8, 0x44)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0xE7, 0xE7, 0x00)),
		}),
	},
	Rare = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0x32, 0xBB, 0xFE)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0x03, 0x93, 0xDB)),
		}),
	},
	Epic = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0xBB, 0x33, 0xFE)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0x93, 0x03, 0xDB)),
		}),
	},
	Legendary = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0xFF, 0xBB, 0x32)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0xDB, 0x93, 0x02)),
		}),
	},
	Mythic = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0xF7, 0x46, 0x46)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0xBA, 0x18, 0x18)),
		}),
	},
	Secret = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0x63, 0x63, 0x63)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0x17, 0x17, 0x17)),
		}),
	},
	God = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0x13, 0x00, 0xF0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0x8D, 0x00, 0xA5)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0xE1, 0x00, 0x12)),
		}),
	},
	OG = {
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 165, 0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 100, 255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(130, 0, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
		}),
		animated = true,
	},
}

local NORMAL_IMAGES = {
	["Agarrini La Pallini"] = "rbxassetid://119960901071530",
	["Ballerina Cappuccina"] = "rbxassetid://138615997586774",
	["Ballerino Lololo"] = "rbxassetid://131941660341640",
	["Bananita Dolphinita"] = "rbxassetid://125393527414559",
	["Bobrito Bandito"] = "rbxassetid://100975638214483",
	["Boneca Ambalabu"] = "rbxassetid://87060640403512",
	["Bombardiro Crocodilo"] = "rbxassetid://109146139727139",
	["Bombombini Gusini"] = "rbxassetid://93633123318384",
	["Brri Brri Bicus Dicus"] = "rbxassetid://81246183054144",
	["Brr Brr Patapim"] = "rbxassetid://84193682750445",
	["Burbaloni Luliloli"] = "rbxassetid://118303183480599",
	["Cacto Hipopotamo"] = "rbxassetid://85778694198750",
	["Cappuccino Assassino"] = "rbxassetid://93151728232405",
	["Cavallo Virtuoso"] = "rbxassetid://91990976978161",
	["Chef Crabracadabra"] = "rbxassetid://130843868905157",
	["Chimpanzini Bananini"] = "rbxassetid://135804738860885",
	["Cocofanto Elefanto"] = "rbxassetid://90200524490457",
	["Dragon Cannelloni"] = "rbxassetid://115970447630902",
	["Esok Sekolah"] = "rbxassetid://74907657930419",
	["Fluri Flura"] = "rbxassetid://106072330223609",
	["Frigo Camelo"] = "rbxassetid://119031445104683",
	["Gangster Footera"] = "rbxassetid://121768816801900",
	["Garamararam"] = "rbxassetid://103700238368791",
	["Girafa Celeste"] = "rbxassetid://97493978039652",
	["Glorbo Fruttodrillo"] = "rbxassetid://99413861323667",
	["Job Job Job Sahur"] = "rbxassetid://125741754730832",
	["Karkerkar Kurkur"] = "rbxassetid://103845028555133",
	["La Vacca Saturno Saturnita"] = "rbxassetid://92985101252540",
	["Lirili Larila"] = "rbxassetid://96517608886723",
	["Los Tralaleritos"] = "rbxassetid://137931860036968",
	["Madudung"] = "rbxassetid://117380790347663",
	["Matteo"] = "rbxassetid://93666784792688",
	["Odin Din Din Dun"] = "rbxassetid://97618493990610",
	["Orangutini Ananassini"] = "rbxassetid://134808357981370",
	["Orcalero Orcala"] = "rbxassetid://138874619901011",
	["Pandaccini Bananini"] = "rbxassetid://137264963408399",
	["Pipi Kiwi"] = "rbxassetid://116801770352293",
	["Pot Hotspot"] = "rbxassetid://110842727450626",
	["Rhino Toasterino"] = "rbxassetid://125661120786562",
	["Six Seven"] = "rbxassetid://136494980830684",
	["Strawberrelli Flamingelli"] = "rbxassetid://128337067811503",
	["Strawberry Elephant"] = "rbxassetid://109289743907806",
	["Svinina Bombardino"] = "rbxassetid://132984358025514",
	["Ta Ta Ta Ta Sahur"] = "rbxassetid://126208919936860",
	["Tralalero Tralala"] = "rbxassetid://115965086679865",
	["Trippi Troppi"] = "rbxassetid://78453817904722",
	["Trippi Troppi Troppa Trippa"] = "rbxassetid://89405728027542",
	["Trulimero Trulicina"] = "rbxassetid://126063557709183",
	["Tung Sahur"] = "rbxassetid://77661948625916",
	["Zibra Zubra Zibralini"] = "rbxassetid://93439583730251",
	["Tim Cheese"] = "rbxassetid://123085126504398",
	["Talpa Di Fero"] = "rbxassetid://71892938506811",
	["Bambini Crostini"] = "rbxassetid://119870045910284",
	["Avocadini Guffo"] = "rbxassetid://89015298713721",
	["Blueberrinni Octopusini"] = "rbxassetid://89978505575087",
	["Pipi Potato"] = "rbxassetid://119284824719272",
	["Gorillo Watermelondrillo"] = "rbxassetid://98983904785631",
	["Lerulerulerule"] = "rbxassetid://95583740505568",
	["Tigroligre Frutonni"] = "rbxassetid://139820365436789",
	["Tralalita Tralala"] = "rbxassetid://84480007765954",
	["Pakrahmatmamat"] = "rbxassetid://117605897411348",
	["Torrtuginni Dragonfrutini"] = "rbxassetid://106715652688464",
	["Espresso Signora"] = "rbxassetid://91819021257366",
	["Chicleteira Bicicleteira"] = "rbxassetid://133847593115197",
	["Pakrahmatmatina"] = "rbxassetid://135520049239372",
	["Tric Trac Barabum"] = "rbxassetid://134033024238079",
	["Lionel Cactuseli"] = "rbxassetid://105223395131616",
	["Ganganzelli Trulala"] = "rbxassetid://78977970544336",
	["Swag Soda"] = "rbxassetid://76419042633668",
	["Chillin Chili"] = "rbxassetid://92830193182791",
	["La Grande Combinasion"] = "rbxassetid://121304395508496",
	["Tralaledon"] = "rbxassetid://120060311319552",
	["Triplito Tralaleritos"] = "rbxassetid://79887610958495",
	["Chicleteirina Bicicleteirina"] = "rbxassetid://78439025995324",
	["Banana Dancana"] = "rbxassetid://97773231142350",
	["Illuminato Triangolo"] = "rbxassetid://113655593349356",
	["Nyannini Cattalini"] = "rbxassetid://106473881175209",
	["Smurfo Gatto"] = "rbxassetid://91565234964597",
	["Bananini Kittini"] = "rbxassetid://113714779789090",
	["Noo My Examen"] = "rbxassetid://107057357696721",
	["Yess My Examen"] = "rbxassetid://108726439882174",
	["Cachorrito Melonito"] = "rbxassetid://93492318324697",
	["W Or L"] = "rbxassetid://135978788833673",
	["1x1x1x1"] = "rbxassetid://131659670938457",
	["Meowl"] = "rbxassetid://114138541738947",
	["Wristini Rizzini"] = "rbxassetid://135217898791467",
	["Chestini Tralalero"] = "rbxassetid://130284147049083",
	["Skrrtini Driftini"] = "rbxassetid://118108480794631",
	["Pakrahmatmatina Valentina"] = "rbxassetid://134492165319328",
	["Love Love Love Sahur"] = "rbxassetid://131619945495856",
	["Noo My Heart"] = "rbxassetid://106114643672684",
	["Teddino Rosino"] = "rbxassetid://76488293317282",
	["La Cucaracha"] = "rbxassetid://133625725205487",
	["Ranocchio Del Tesoro"] = "rbxassetid://123444558748235",
	["Pinguino Pentadagoro"] = "rbxassetid://113825671631524",
	["Cetriolino Leprechauno"] = "rbxassetid://83057895523340",
	["Lioneo Cactuseli"] = "rbxassetid://105223395131616",
}

local BRAINROT_RARITY_TYPES = {
	["Lirili Larila"] = "Common", ["Trippi Troppi"] = "Common", ["Fluri Flura"] = "Common",
	["Pipi Kiwi"] = "Common", ["Svinina Bombardino"] = "Common", ["Brr Brr Patapim"] = "Common",
	["Boneca Ambalabu"] = "Uncommon", ["Cacto Hipopotamo"] = "Uncommon",
	["Chimpanzini Bananini"] = "Uncommon", ["Frigo Camelo"] = "Uncommon", Garamararam = "Uncommon",
	["Talpa Di Fero"] = "Uncommon",
	["Ta Ta Ta Ta Sahur"] = "Rare", ["Tung Sahur"] = "Rare", ["Trippi Troppi Troppa Trippa"] = "Rare",
	["Bobrito Bandito"] = "Rare", ["Trulimero Trulicina"] = "Rare", Madudung = "Rare",
	["Bananita Dolphinita"] = "Rare",
	["Rhino Toasterino"] = "Epic", ["Orangutini Ananassini"] = "Epic", ["Odin Din Din Dun"] = "Epic",
	["Cappuccino Assassino"] = "Epic", ["Brri Brri Bicus Dicus"] = "Epic", ["Glorbo Fruttodrillo"] = "Epic",
	["Bambini Crostini"] = "Epic", ["Avocadini Guffo"] = "Epic",
	["Gangster Footera"] = "Epic",["Tric Trac Barabum"] = "Epic",
	["Six Seven"] = "Legendary", ["Ballerina Cappuccina"] = "Legendary", ["Chef Crabracadabra"] = "Legendary",
	["Strawberrelli Flamingelli"] = "Legendary", ["Pandaccini Bananini"] = "Legendary", Matteo = "Legendary",
	["Burbaloni Luliloli"] = "Legendary", ["Pipi Potato"] = "Legendary", ["Blueberrinni Octopusini"] = "Legendary",
	["Lionel Cactuseli"] = "Legendary",
	["Bombombini Gusini"] = "Mythic", ["Bombardiro Crocodilo"] = "Mythic", ["Cocofanto Elefanto"] = "Mythic",
	["Girafa Celeste"] = "Mythic", ["Tralalero Tralala"] = "Mythic", ["Orcalero Orcala"] = "Mythic",
	["Cavallo Virtuoso"] = "Mythic", ["Zibra Zubra Zibralini"] = "Mythic", ["Ballerino Lololo"] = "Mythic",
	["Gorillo Watermelondrillo"] = "Mythic", ["Lerulerulerule"] = "Mythic",
	["Ganganzelli Trulala"] = "Mythic", ["Tralaledon"] = "Mythic",
	["Ranocchio Del Tesoro"] = "Mythic", ["Pinguino Pentadagoro"] = "Mythic",
	["Cetriolino Leprechauno"] = "Mythic", ["Lioneo Cactuseli"] = "Legendary",
	["La Vacca Saturno Saturnita"] = "Secret", ["Pot Hotspot"] = "Secret", ["Los Tralaleritos"] = "Secret",
	["Dragon Cannelloni"] = "Secret", ["Esok Sekolah"] = "Secret", ["Job Job Job Sahur"] = "Secret",
	["Agarrini La Pallini"] = "Secret", ["Karkerkar Kurkur"] = "Secret", ["Tralalita Tralala"] = "Secret",
	["Torrtuginni Dragonfrutini"] = "Secret", ["Espresso Signora"] = "Secret", ["Wristini Rizzini"] = "Secret",
	["Strawberry Elephant"] = "Secret",
	["La Grande Combinasion"] = "Secret", ["Triplito Tralaleritos"] = "Secret",
	["Tigroligre Frutonni"] = "God", ["Pakrahmatmamat"] = "God", ["Pakrahmatmatina"] = "God",
	["Chicleteira Bicicleteira"] = "God", ["Cachorrito Melonito"] = "God", ["Noo My Examen"] = "God",
	["Yess My Examen"] = "God", ["Chestini Tralalero"] = "God",
	["Chicleteirina Bicicleteirina"] = "God", ["Chillin Chili"] = "God", ["Swag Soda"] = "God",
	["W Or L"] = "God", ["Teddino Rosino"] = "God", ["Love Love Love Sahur"] = "God",
	["Pakrahmatmatina Valentina"] = "God", ["Noo My Heart"] = "God",
	["Banana Dancana"] = "OG", ["Illuminato Triangolo"] = "OG", ["Nyannini Cattalini"] = "OG",
	["Bananini Kittini"] = "OG", ["Smurfo Gatto"] = "OG", ["Meowl"] = "OG",
	["Skrrtini Driftini"] = "OG", ["La Cucaracha"] = "OG",
}

local hoverTweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function IndexController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[IndexController] MainGui introuvable")
		return
	end
	local indexFrame = mainGui:WaitForChild("IndexFrame")
	local brainrotsFolder = ReplicatedStorage:WaitForChild("Brainrots")

	local basesFrame = indexFrame:WaitForChild("Bases")
	local normalScroll = indexFrame:WaitForChild("Normal")
	local searchBox = indexFrame:WaitForChild("Search"):WaitForChild("TextBox")
	local progressFrame = indexFrame:FindFirstChild("Progress")
	local progressBar = progressFrame and progressFrame:FindFirstChild("Frame")
	local progressText = progressFrame and progressFrame:FindFirstChild("TextLabel")
	local progressInfo = indexFrame:FindFirstChild("ProgressInfo")
	local labelFrame = indexFrame:WaitForChild("Label")
	local labelCompletion = labelFrame:WaitForChild("Completion")
	local labelDiscovered = labelFrame:WaitForChild("Discovered")

	local tempFrame = normalScroll:WaitForChild("Temp")
	tempFrame.Visible = false

	local currentTab = "Normal"
	local scrollFrames = {}
	local allCards = {}
	local discoveredBrainrots = {}
	local ogGradients = {}

	local function getBaseName(brainrotName, rarity)
		if rarity == "Normal" then
			return brainrotName
		end
		local prefix = rarity .. " "
		if string.sub(brainrotName, 1, #prefix) == prefix then
			return string.sub(brainrotName, #prefix + 1)
		end
		return brainrotName
	end

	local function isDiscovered(rarity, brainrotName)
		local baseName = getBaseName(brainrotName, rarity)
		if discoveredBrainrots[rarity] and discoveredBrainrots[rarity][baseName] then
			return true
		end
		return false
	end

	local function loadDiscoveredData()
		for _, rarity in ipairs(RARITIES) do
			discoveredBrainrots[rarity] = {}
		end

		local data = player:GetAttribute("DiscoveredIndex")
		if data and type(data) == "string" and data ~= "" then
			for entry in string.gmatch(data, "[^,]+") do
				local r, n = string.match(entry, "^(.+):(.+)$")
				if r and n and discoveredBrainrots[r] then
					discoveredBrainrots[r][n] = true
				end
			end
		end

		for _, rarity in ipairs(RARITIES) do
			local rarityData = player:GetAttribute("Discovered_" .. rarity)
			if rarityData and type(rarityData) == "string" and rarityData ~= "" then
				for name in string.gmatch(rarityData, "[^,]+") do
					discoveredBrainrots[rarity][name] = true
				end
			end
		end
	end

	local function createScrollFrame(rarity)
		if rarity == "Normal" then
			scrollFrames["Normal"] = normalScroll
			return normalScroll
		end

		local newScroll = normalScroll:Clone()
		newScroll.Name = rarity
		newScroll.Visible = false
		newScroll.CanvasPosition = Vector2.new(0, 0)

		for _, child in ipairs(newScroll:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		newScroll.Parent = indexFrame
		scrollFrames[rarity] = newScroll
		return newScroll
	end

	local function getBrainrotImage(baseName, _rarity)
		return NORMAL_IMAGES[baseName]
	end

	local function getBrainrotRarityType(baseName)
		return BRAINROT_RARITY_TYPES[baseName]
	end

	local function createImageLabel(parent, imageId)
		local imageLabel = Instance.new("ImageLabel")
		imageLabel.Name = "BrainrotImage"
		imageLabel.Size = UDim2.new(0.85, 0, 0.7, 0)
		imageLabel.Position = UDim2.new(0.5, 0, 0.48, 0)
		imageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		imageLabel.BackgroundTransparency = 1
		imageLabel.ZIndex = 5
		imageLabel.ScaleType = Enum.ScaleType.Fit
		imageLabel.Image = imageId or ""
		imageLabel.Parent = parent
		return imageLabel
	end

	local function createBrainrotCard(brainrotModel, rarity, layoutOrder)
		local baseName = getBaseName(brainrotModel.Name, rarity)
		local discovered = isDiscovered(rarity, brainrotModel.Name)

		local card = tempFrame:Clone()
		card.Name = baseName
		card.Visible = true
		card.LayoutOrder = layoutOrder
		card:SetAttribute("HoverSound", "")
		card:SetAttribute("BaseName", baseName)
		card:SetAttribute("Rarity", rarity)
		card:SetAttribute("Discovered", discovered)

		local cardFrame = card:WaitForChild("Frame")
		local itemRarity = cardFrame:WaitForChild("ItemRarity")
		local itemName = cardFrame:WaitForChild("ItemName")
		local imageHolder = cardFrame:WaitForChild("Frame")

		for _, child in ipairs(imageHolder:GetChildren()) do
			if child:IsA("ImageLabel") or child:IsA("ViewportFrame") then
				child:Destroy()
			end
		end

		local imageId = getBrainrotImage(baseName, rarity)

		local rarityType = getBrainrotRarityType(baseName)
		if rarityType then
			itemRarity.Text = rarityType
			itemRarity.TextColor3 = RARITY_TYPE_COLORS[rarityType] or RARITY_COLORS[rarity] or Color3.fromRGB(255, 255, 255)
		else
			itemRarity.Text = rarity
			itemRarity.TextColor3 = RARITY_COLORS[rarity] or Color3.fromRGB(255, 255, 255)
		end

		local bgColor = RARITY_TYPE_BG_COLORS[rarityType or "Common"] or Color3.fromRGB(50, 50, 50)

		local gradientData = RARITY_GRADIENTS[rarityType or "Common"]
		if gradientData then
			local oldGrad = imageHolder:FindFirstChildWhichIsA("UIGradient")
			if oldGrad then oldGrad:Destroy() end

			local gradient = Instance.new("UIGradient")
			gradient.Color = gradientData[1]
			gradient.Rotation = 90
			gradient.Parent = imageHolder

			if gradientData.animated then
				table.insert(ogGradients, gradient)
			end
		end

		if discovered then
			itemName.Text = baseName
			local img = createImageLabel(imageHolder, imageId)
			img.ImageColor3 = Color3.fromRGB(255, 255, 255)
			cardFrame.BackgroundColor3 = bgColor
		else
			itemName.Text = "???"
			local img = createImageLabel(imageHolder, imageId)
			img.ImageColor3 = Color3.fromRGB(0, 0, 0)
			cardFrame.BackgroundColor3 = bgColor
			itemName.TextColor3 = Color3.fromRGB(255, 255, 255)
			itemRarity.TextColor3 = Color3.fromRGB(255, 255, 255)
		end

		return card
	end

	local originalSizes = {}
	local hoverStates = {}

	local function setupHover(card)
		local cardFrame = card:FindFirstChild("Frame")
		if not cardFrame or not (cardFrame:IsA("ImageLabel") or cardFrame:IsA("ImageButton")) then
			return
		end

		originalSizes[card] = cardFrame.Size
		hoverStates[card] = false

		card.MouseEnter:Connect(function()
			hoverStates[card] = true
			TweenService:Create(cardFrame, hoverTweenInfo, {
				Size = originalSizes[card] - UDim2.new(0.04, 0, 0.04, 0)
			}):Play()
		end)

		card.MouseLeave:Connect(function()
			hoverStates[card] = false
			TweenService:Create(cardFrame, hoverTweenInfo, {
				Size = originalSizes[card]
			}):Play()
		end)
	end

	local function populateTab(rarity)
		local scroll = scrollFrames[rarity]
		if not scroll then return end

		local folder = brainrotsFolder:FindFirstChild(rarity)
		if not folder then return end

		allCards[rarity] = {}

		local brainrots = folder:GetChildren()
		table.sort(brainrots, function(a, b)
			local nameA = getBaseName(a.Name, rarity)
			local nameB = getBaseName(b.Name, rarity)
			local typeA = BRAINROT_RARITY_TYPES[nameA] or "Common"
			local typeB = BRAINROT_RARITY_TYPES[nameB] or "Common"
			local orderA = RARITY_TYPE_ORDER[typeA] or 0
			local orderB = RARITY_TYPE_ORDER[typeB] or 0
			if orderA ~= orderB then
				return orderA < orderB
			end
			return a.Name < b.Name
		end)

		for i, brainrotModel in ipairs(brainrots) do
			if brainrotModel:IsA("Model") then
				local baseName = getBaseName(brainrotModel.Name, rarity)
				if baseName ~= rarity and baseName ~= "" and NORMAL_IMAGES[baseName]
					and not EXCLUSIVE_BRAINROTS[baseName] then
					local card = createBrainrotCard(brainrotModel, rarity, i)
					card.Parent = scroll
					setupHover(card)
					table.insert(allCards[rarity], card)
				end
			end
		end
	end

	local function updateProgress()
		local folder = brainrotsFolder:FindFirstChild(currentTab)
		if not folder then return end

		local total = 0
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") then
				local baseName = getBaseName(child.Name, currentTab)
				if baseName ~= currentTab and baseName ~= "" and NORMAL_IMAGES[baseName]
					and not EXCLUSIVE_BRAINROTS[baseName] then
					total = total + 1
				end
			end
		end

		local discovered = 0
		if discoveredBrainrots[currentTab] then
			for _ in pairs(discoveredBrainrots[currentTab]) do
				discovered = discovered + 1
			end
		end

		if progressText then
			progressText.Text = discovered .. " / " .. total
		end

		local ratio = 0
		if total > 0 then
			ratio = discovered / total
		end

		if progressBar then
			TweenService:Create(progressBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
				Size = UDim2.new(math.max(0.01, 1 - ratio), 0, 1, 0)
			}):Play()
		end

		local percent = math.floor(ratio * 100)
		labelCompletion.Text = percent .. "% complete"
		labelDiscovered.Text = discovered .. " / " .. total .. " discovered"

		local reward = RARITY_REWARDS[currentTab] or ""
		if progressInfo then
			progressInfo.Text = "Collect all " .. currentTab .. " Brainrots for " .. reward
		end
	end

	local function updateTabVisuals(button, isSelected)
		local gray = button:FindFirstChild("Gray")
		local green = button:FindFirstChild("Green")
		if gray then gray.Enabled = isSelected end
		if green then green.Enabled = not isSelected end

		local bg = button:FindFirstChild("BG")
		if bg then
			local bgGray = bg:FindFirstChild("Gray")
			local bgGreen = bg:FindFirstChild("Green")
			local bgMythic = bg:FindFirstChild("Mythic")
			if bgGray then bgGray.Enabled = isSelected end
			if bgGreen then bgGreen.Enabled = not isSelected end
			if bgMythic then bgMythic.Enabled = not isSelected end
		end
	end

	local function selectTab(rarity)
		currentTab = rarity

		for r, scroll in pairs(scrollFrames) do
			scroll.Visible = (r == rarity)
			if r == rarity then
				scroll.CanvasPosition = Vector2.new(0, 0)
			end
		end

		for _, r in ipairs(RARITIES) do
			local button = basesFrame:FindFirstChild(r)
			if button then
				updateTabVisuals(button, r == rarity)
			end
		end

		updateProgress()
	end

	local function filterCards(searchText)
		searchText = string.lower(searchText)

		for rarity, cards in pairs(allCards) do
			if rarity == currentTab then
				for _, card in ipairs(cards) do
					if searchText == "" then
						card.Visible = true
					else
						local baseName = card:GetAttribute("BaseName") or card.Name
						card.Visible = string.find(string.lower(baseName), searchText, 1, true) ~= nil
					end
				end
			end
		end
	end

	local function onDiscoveryChanged()
		loadDiscoveredData()

		for rarity, cards in pairs(allCards) do
			for _, card in ipairs(cards) do
				local baseName = card:GetAttribute("BaseName")
				local discovered = false
				if discoveredBrainrots[rarity] and discoveredBrainrots[rarity][baseName] then
					discovered = true
				end

				local cardFrame = card:FindFirstChild("Frame")
				if cardFrame then
					local itemName = cardFrame:FindFirstChild("ItemName")
					local itemRarity = cardFrame:FindFirstChild("ItemRarity")
					local imageHolder = cardFrame:FindFirstChild("Frame")

					local rarityType = getBrainrotRarityType(baseName)
					local bgColor = RARITY_TYPE_BG_COLORS[rarityType or "Common"] or Color3.fromRGB(50, 50, 50)

					if discovered then
						if itemName then itemName.Text = baseName end
						if itemName then itemName.TextColor3 = Color3.fromRGB(255, 255, 255) end
						if itemRarity then
							if rarityType then
								itemRarity.TextColor3 = RARITY_TYPE_COLORS[rarityType] or RARITY_COLORS[rarity] or Color3.fromRGB(255, 255, 255)
							else
								itemRarity.TextColor3 = RARITY_COLORS[rarity] or Color3.fromRGB(255, 255, 255)
							end
						end
						cardFrame.BackgroundColor3 = bgColor
						if imageHolder then
							local img = imageHolder:FindFirstChild("BrainrotImage")
							if img then img.ImageColor3 = Color3.fromRGB(255, 255, 255) end
						end
					else
						if itemName then itemName.Text = "???" end
						if itemName then itemName.TextColor3 = Color3.fromRGB(255, 255, 255) end
						if itemRarity then itemRarity.TextColor3 = Color3.fromRGB(255, 255, 255) end
						cardFrame.BackgroundColor3 = bgColor
						if imageHolder then
							local img = imageHolder:FindFirstChild("BrainrotImage")
							if img then img.ImageColor3 = Color3.fromRGB(0, 0, 0) end
						end
					end

					card:SetAttribute("Discovered", discovered)
				end
			end
		end

		updateProgress()
	end

	loadDiscoveredData()

	for _, rarity in ipairs(RARITIES) do
		createScrollFrame(rarity)
	end

	for _, rarity in ipairs(RARITIES) do
		populateTab(rarity)
	end

	for _, rarity in ipairs(RARITIES) do
		local button = basesFrame:FindFirstChild(rarity)
		if button and button:IsA("ImageButton") then
			button.MouseButton1Click:Connect(function()
				selectTab(rarity)
				filterCards(searchBox.Text)
			end)
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		filterCards(searchBox.Text)
	end)

	player.AttributeChanged:Connect(function(attrName)
		if attrName == "DiscoveredIndex" or string.sub(attrName, 1, 11) == "Discovered_" then
			onDiscoveryChanged()
		end
	end)

	selectTab("Normal")

	if #ogGradients > 0 then
		task.spawn(function()
			while true do
				for _, gradient in ipairs(ogGradients) do
					if gradient and gradient.Parent then
						local offset = gradient.Offset
						gradient.Offset = Vector2.new(offset.X + 0.01, 0)
						if offset.X > 1 then
							gradient.Offset = Vector2.new(-1, 0)
						end
					end
				end
				task.wait(0.03)
			end
		end)
	end

	print("[IndexController] Initialized successfully!")
end

return IndexController

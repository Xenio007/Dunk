--[[
	SellFrameController
	Popule la SellFrame (scroll inventaire) à partir des brainrots (Tool)
	actuellement présents dans le Backpack et le Character du joueur.

	Règles :
	  - Aucun brainrot => le ScrollingFrame reste vide, seul le TextLabel
	    "NoBrainrots" est affiché.
	  - Au moins un brainrot => on clone le Temp pour chaque brainrot unique
	    (groupé par nom complet) avec :
			* Image du brainrot
			* Rareté (texte + couleur)
			* Prix de vente = CashPerSecond x 10 (variant pris en compte)
			* Quantité possédée

	On met aussi à jour le label InventoryValue (somme des prix de vente)
	pour rester cohérent avec l'UI existante.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local SellFrameController = Loader.CreateController({
	Name = "SellFrameController",
})

-- Couleur verte utilisée pour le label de prix (cachée via le gabarit
-- existant) : on la réutilise pour le texte de rareté afin qu'ils soient
-- visuellement cohérents.
local RARITY_TEXT_COLOR = Color3.fromRGB(170, 255, 0)

-- Fond des cartes, aligne sur les couleurs utilisées par l'IndexController
-- pour les cartes de l'index (par type de rareté).
local RARITY_TYPE_BG_COLORS = {
	Common    = Color3.fromRGB(0x80, 0x80, 0x80),
	Uncommon  = Color3.fromRGB(0xA0, 0xA0, 0x01),
	Rare      = Color3.fromRGB(0x01, 0x6D, 0xA3),
	Epic      = Color3.fromRGB(0x6D, 0x01, 0xA3),
	Legendary = Color3.fromRGB(0xA3, 0x6D, 0x01),
	Mythic    = Color3.fromRGB(0x8B, 0x0C, 0x0C),
	Secret    = Color3.fromRGB(0x00, 0x00, 0x00),
	God       = Color3.fromRGB(0x00, 0x00, 0x4E),
	OG        = Color3.fromRGB(0xFF, 0x00, 0x00),
}
local DEFAULT_BG_COLOR = Color3.fromRGB(50, 50, 50)

-- ===== Images des brainrots (base, normal) =====
-- Pour les variants (Gold/Diamond/...), on réutilise l'image de base : c'est
-- ce qui est attendu côté inventaire et ça évite de dupliquer la table
-- d'assets des variants.
local BRAINROT_IMAGES = {
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
}

-- Prix de vente par brainrot : CPS * 10 (demande explicite).
local SELL_PRICE_MULTIPLIER = 10

-- ===== Helpers =====

local function formatCash(n)
	n = n or 0
	if n < 1000 then
		return "$" .. tostring(math.floor(n))
	end
	return "$" .. BrainrotInfo.FormatShort(n)
end

-- Résout les infos d'affichage d'un brainrot à partir de son nom complet.
-- Retourne nil si ce n'est pas un brainrot connu, ou si c'est un brainrot
-- exclusif (achetable uniquement en Robux : il ne doit pas apparaître dans la
-- liste de vente).
local function resolveBrainrot(fullName)
	local info = BrainrotInfo.GetInfo(fullName)
	if not info then return nil end

	-- Les exclusifs (Dragon Cannelloni, Esok Sekolah, Job Job Job Sahur) sont
	-- des brainrots Robux : on ne les affiche pas dans la SellFrame, et ils
	-- ne peuvent pas être vendus.
	if info.ExclusivePercent then return nil end

	return {
		FullName   = fullName,
		BaseName   = info.BaseName,
		Variant    = info.Variant,
		RarityType = info.RarityType,
		Image      = BRAINROT_IMAGES[info.BaseName] or "",
		SellPrice  = (info.CashPerSecond or 0) * SELL_PRICE_MULTIPLIER,
		Color      = BrainrotInfo.GetRarityColor(info.RarityType),
		BgColor    = RARITY_TYPE_BG_COLORS[info.RarityType] or DEFAULT_BG_COLOR,
	}
end

-- Récupère les SellFrames qui contiennent un ScrollingFrame + Temp exploitable.
local function collectSellViews(mainGui)
	local views = {}
	for _, sf in ipairs(mainGui:GetChildren()) do
		if sf.Name == "SellFrame" then
			local scroll = sf:FindFirstChild("ScrollingFrame")
			local temp = scroll and scroll:FindFirstChild("Temp")
			if temp
				and temp:FindFirstChild("BrainrotName")
				and temp:FindFirstChild("BrainrotRarity")
				and temp:FindFirstChild("SellPrice")
				and temp:FindFirstChild("BrainrotImage")
			then
				-- Temp caché : ne sert que de template, jamais visible à l'écran.
				temp.Visible = false
				table.insert(views, {
					frame        = sf,
					scroll       = scroll,
					template     = temp,
					noBrainrots  = sf:FindFirstChild("NoBrainrots"),
					invValue     = sf:FindFirstChild("InventoryValue"),
					sellAll      = sf:FindFirstChild("SellAll"),
				})
			end
		end
	end
	return views
end

-- Nettoie tous les enfants du scroll sauf les layouts, padding et le Temp.
local function clearScroll(scroll, template)
	for _, child in ipairs(scroll:GetChildren()) do
		if child ~= template
			and not child:IsA("UIListLayout")
			and not child:IsA("UIPadding")
			and not child:IsA("UIGridLayout")
			and not child:IsA("LocalScript")
			and child:GetAttribute("SellEntry") == true
		then
			child:Destroy()
		end
	end
end

-- Configure une carte (clone du Temp) pour afficher un brainrot.
local function configureEntry(entry, data, layoutOrder, onSellClicked)
	entry.Name = data.FullName
	entry.Visible = true
	entry.LayoutOrder = layoutOrder
	entry:SetAttribute("SellEntry", true)
	entry:SetAttribute("BrainrotFullName", data.FullName)

	-- Fond coloré par rareté (mêmes teintes que les cartes de l'index).
	if entry:IsA("ImageLabel") or entry:IsA("ImageButton") then
		entry.ImageColor3 = data.BgColor
	end
	entry.BackgroundColor3 = data.BgColor
	local entryBg = entry:FindFirstChild("BG")
	if entryBg then
		if entryBg:IsA("ImageLabel") or entryBg:IsA("ImageButton") then
			entryBg.ImageColor3 = data.BgColor
		end
		if entryBg:IsA("GuiObject") then
			entryBg.BackgroundColor3 = data.BgColor
		end
	end

	local nameLabel = entry:FindFirstChild("BrainrotName")
	if nameLabel then
		nameLabel.Text = data.FullName
	end

	local rarityLabel = entry:FindFirstChild("BrainrotRarity")
	if rarityLabel then
		rarityLabel.Text = data.RarityType or ""
		rarityLabel.TextColor3 = RARITY_TEXT_COLOR
	end

	local priceLabel = entry:FindFirstChild("SellPrice")
	if priceLabel then
		priceLabel.Text = formatCash(data.SellPrice)
	end

	local ownedLabel = entry:FindFirstChild("OwnedAmount")
	if ownedLabel then
		ownedLabel.Text = string.format("Owned: x%d", data.Amount or 1)
	end

	local imgHolder = entry:FindFirstChild("BrainrotImage")
	if imgHolder then
		local inner = imgHolder:FindFirstChildWhichIsA("ImageLabel")
		if inner then
			inner.Image = data.Image
		end
	end

	-- Bouton Sell : vend un exemplaire du brainrot (serveur gère le cash et
	-- la suppression du Tool).
	local sellBtn = entry:FindFirstChild("Sell")
	if sellBtn and (sellBtn:IsA("ImageButton") or sellBtn:IsA("TextButton")) and onSellClicked then
		sellBtn.Active = true
		sellBtn.Activated:Connect(function()
			onSellClicked(data.FullName)
		end)
	end
end

-- ===== Cycle de vie =====

function SellFrameController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[SellFrameController] MainGui introuvable")
		return
	 end

	local views = collectSellViews(mainGui)
	if #views == 0 then
		return
	end

	local sellEvent = RemotesAPI.GetEvent("SellBrainrotEvent")
	local sellAllEvent = RemotesAPI.GetEvent("SellAllBrainrotsEvent")

	local function requestSell(fullName)
		if type(fullName) ~= "string" or fullName == "" then return end
		sellEvent:FireServer(fullName)
	end

	local function requestSellAll()
		sellAllEvent:FireServer()
	end

	-- Branche le bouton "SellAll" des SellFrames (une seule fois par vue).
	for _, view in ipairs(views) do
		local sa = view.sellAll
		if sa and (sa:IsA("ImageButton") or sa:IsA("TextButton")) then
			sa.Active = true
			sa.Activated:Connect(requestSellAll)
		end
	end

	-- Regroupe tous les brainrots (Character + Backpack) par FullName.
	local function gatherBrainrots()
		local grouped = {}
		local order = {}

		local sources = {}
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then table.insert(sources, backpack) end
		if player.Character then table.insert(sources, player.Character) end

		for _, src in ipairs(sources) do
			for _, child in ipairs(src:GetChildren()) do
				if child:IsA("Tool") then
					local data = resolveBrainrot(child.Name)
					if data then
						local entry = grouped[data.FullName]
						if not entry then
							entry = {
								FullName   = data.FullName,
								BaseName   = data.BaseName,
								Variant    = data.Variant,
								RarityType = data.RarityType,
								Image      = data.Image,
								SellPrice  = data.SellPrice,
								Color      = data.Color,
								BgColor    = data.BgColor,
								Amount     = 0,
							}
							grouped[data.FullName] = entry
							table.insert(order, entry)
						end
						entry.Amount = entry.Amount + 1
					end
				end
			end
		end

		return order
	end

	local function rebuildAll()
		local entries = gatherBrainrots()

		-- Tri : prix décroissant, puis nom (pour un affichage stable).
		table.sort(entries, function(a, b)
			if a.SellPrice ~= b.SellPrice then
				return a.SellPrice > b.SellPrice
			end
			return a.FullName < b.FullName
		end)

		local totalValue = 0
		for _, e in ipairs(entries) do
			totalValue = totalValue + (e.SellPrice * e.Amount)
		end

		for _, view in ipairs(views) do
			-- On sauvegarde la position de scroll avant de vider la liste,
			-- pour éviter que le ScrollingFrame ne saute en haut à chaque vente.
			local savedCanvasPos = view.scroll.CanvasPosition

			clearScroll(view.scroll, view.template)

			if #entries == 0 then
				-- Aucun brainrot : on n'ajoute rien dans le scroll et on affiche
				-- le label "NoBrainrots" si présent.
				if view.noBrainrots then
					view.noBrainrots.Visible = true
				end
			else
				if view.noBrainrots then
					view.noBrainrots.Visible = false
				end

				for i, data in ipairs(entries) do
					local entry = view.template:Clone()
					configureEntry(entry, data, i, requestSell)
					entry.Parent = view.scroll
				end
			end

			if view.invValue then
				view.invValue.Text = "Inventory value: " .. formatCash(totalValue)
			end

			-- Restaure la position de scroll. Si la liste a rétréci (vente du
			-- dernier élément visible), on borne au max possible pour ne pas
			-- laisser un offset au-delà du contenu.
			if #entries == 0 then
				view.scroll.CanvasPosition = Vector2.new(0, 0)
			else
				local scroll = view.scroll
				-- Le layout met un frame à recalculer AbsoluteCanvasSize après
				-- l'ajout des enfants. On applique la position immédiatement
				-- (Roblox clampe seul) puis on re-clampe au prochain frame pour
				-- gérer proprement le cas "liste rétrécie".
				scroll.CanvasPosition = savedCanvasPos
				task.defer(function()
					if not scroll.Parent then return end
					local maxY = math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y)
					local maxX = math.max(0, scroll.AbsoluteCanvasSize.X - scroll.AbsoluteWindowSize.X)
					scroll.CanvasPosition = Vector2.new(
						math.clamp(savedCanvasPos.X, 0, maxX),
						math.clamp(savedCanvasPos.Y, 0, maxY)
					)
				end)
			end
		end
	end

	-- ===== Hooks Backpack + Character =====

	local containerConns = {}

	local function disconnectContainer(inst)
		local list = containerConns[inst]
		if not list then return end
		for _, c in ipairs(list) do c:Disconnect() end
		containerConns[inst] = nil
	end

	local function hookContainer(inst)
		if not inst or containerConns[inst] then return end
		local list = {}
		containerConns[inst] = list
		table.insert(list, inst.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				task.defer(rebuildAll)
			end
		end))
		table.insert(list, inst.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				task.defer(rebuildAll)
			end
		end))
	end

	local function hookBackpack()
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then hookContainer(backpack) end
	end

	local function hookCharacter(char)
		if not char then return end
		hookContainer(char)
	end

	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then
			hookContainer(c)
			task.defer(rebuildAll)
		end
	end)
	player.ChildRemoved:Connect(function(c)
		if c:IsA("Backpack") then
			disconnectContainer(c)
		end
	end)

	player.CharacterAdded:Connect(function(char)
		hookCharacter(char)
		task.defer(rebuildAll)
	end)
	player.CharacterRemoving:Connect(function(char)
		disconnectContainer(char)
	end)

	hookBackpack()
	hookCharacter(player.Character)
	rebuildAll()

	print("[SellFrameController] Prêt")
end

return SellFrameController

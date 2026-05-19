--[[
	WeightShopController
	Gère l'UI du shop de poids :
	Popule dynamiquement le ScrollingFrame avec les items,
	gère achat (cash/robux), équipement, et état visuel.

	Migration 1:1 de StarterGui.MainGui.WeightsFrame.WeightShopClient
	(l'ancien script était dupliqué dans RunFrame, on n'en garde qu'une version).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local WeightShopController = Loader.CreateController({
	Name = "WeightShopController",
})

local function formatNumber(num)
	local n = math.floor(num)
	if n >= 1e15 then
		return string.format("%.1fQ", n / 1e15)
	elseif n >= 1e12 then
		return string.format("%.1fT", n / 1e12)
	elseif n >= 1e9 then
		return string.format("%.1fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("%.1fK", n / 1e3)
	else
		return tostring(n)
	end
end

function WeightShopController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[WeightShopController] MainGui introuvable")
		return
	end
	local weightsFrame = mainGui:WaitForChild("WeightsFrame")
	local scrollFrame = weightsFrame:WaitForChild("1")

	local WeightsConfig = require(ReplicatedStorage:WaitForChild("WeightsConfig"))
	local buyWeightEvent = RemotesAPI.GetEvent("BuyWeightEvent")
	local buyWeightRobuxEvent = RemotesAPI.GetEvent("BuyWeightRobuxEvent")
	local equipWeightEvent = RemotesAPI.GetEvent("EquipWeightEvent")
	local weightDataEvent = RemotesAPI.GetEvent("WeightDataEvent")

	local tempItem = scrollFrame:WaitForChild("Temp")
	local buyTempItem = scrollFrame:FindFirstChild("BuyTemp")

	tempItem.Visible = false
	tempItem.Name = "_Temp"
	if buyTempItem then
		buyTempItem.Visible = false
		buyTempItem.Name = "_BuyTemp"
	end

	local ownedWeights = { ["Wooden Stick"] = true }
	local equippedWeight = "Wooden Stick"
	local itemFrames = {}

	-- Anti-spam côté client : empêche les doubles clics qui spammeraient le
	-- serveur. La protection serveur existe déjà (BUY_COOLDOWN) mais ici on
	-- coupe avant même d'envoyer le remote, ce qui évite tout traitement
	-- inutile et coupe le risque de cascade Tool.Destroy/Add côté client.
	local lastClickAt = 0
	local CLICK_COOLDOWN = 0.6
	local function canClick()
		local now = os.clock()
		if now - lastClickAt < CLICK_COOLDOWN then return false end
		lastClickAt = now
		return true
	end

	local function updateItemVisual(weightName)
		local refs = itemFrames[weightName]
		if not refs then return end

		local config = WeightsConfig.ByName[weightName]
		if not config then return end

		local isOwned = ownedWeights[weightName] == true
		local isEquipped = equippedWeight == weightName

		local equipBtn = refs.equipBtn
		local robuxBtn = refs.robuxBtn
		local equippedBtn = refs.equippedBtn

		if isOwned then
			if robuxBtn then
				robuxBtn.Visible = false
			end

			if isEquipped then
				if equipBtn then equipBtn.Visible = false end
				if equippedBtn then equippedBtn.Visible = true end
			else
				if equipBtn then
					equipBtn.Visible = true
					local textLabel = equipBtn:FindFirstChild("TextLabel")
					if textLabel then
						textLabel.Text = "Equip"
					end
				end
				if equippedBtn then equippedBtn.Visible = false end
			end
		else
			if equipBtn then
				equipBtn.Visible = true
				local textLabel = equipBtn:FindFirstChild("TextLabel")
				if textLabel then
					if config.Price == 0 then
						textLabel.Text = "Free"
					else
						textLabel.Text = "$" .. formatNumber(config.Price)
					end
				end
			end
			if robuxBtn then
				robuxBtn.Visible = config.Robux > 0
			end
			if equippedBtn then equippedBtn.Visible = false end
		end
	end

	local function updateAllVisuals()
		for weightName, _ in pairs(itemFrames) do
			updateItemVisual(weightName)
		end
	end

	local function populateShop()
		for _, child in ipairs(scrollFrame:GetChildren()) do
			if child:IsA("ImageButton") or child:IsA("ImageLabel") then
				if child.Name ~= "_Temp" and child.Name ~= "_BuyTemp" and child.Name ~= "ItemName" then
					child:Destroy()
				end
			end
		end
		itemFrames = {}

		local itemNameLabel = scrollFrame:FindFirstChild("ItemName")
		if itemNameLabel then
			itemNameLabel.Visible = false
		end

		for i, config in ipairs(WeightsConfig.Weights) do
			local item = tempItem:Clone()
			item.Name = config.Name
			item.LayoutOrder = i
			item.Visible = true
			item.Parent = scrollFrame

			local frame = item:FindFirstChild("Frame")
			if not frame then continue end

			local itemName = frame:FindFirstChild("ItemName")
			if itemName then
				itemName.Text = config.Name
			end

			local itemRarity = frame:FindFirstChild("ItemRarity")
			if itemRarity then
				itemRarity.Text = config.Rarity
				local rarityColor = WeightsConfig.RarityColors[config.Rarity]
				if rarityColor then
					itemRarity.TextColor3 = rarityColor
				end
			end

			local stats = frame:FindFirstChild("Stats")
			if stats then
				local statsText = stats:FindFirstChild("TextLabel")
				if statsText then
					statsText.Text = config.Stats
				end
			end

			local imageBG = frame:FindFirstChild("ImageBG")
			if imageBG then
				local itemImage = imageBG:FindFirstChild("ItemImage")
				if itemImage and config.Image then
					itemImage.Image = config.Image
				end
			end

			local rarityColor = WeightsConfig.RarityColors[config.Rarity]
			if rarityColor then
				frame.ImageColor3 = rarityColor
			end

			local equipBtn = frame:FindFirstChild("Equip")
			local robuxBtn = frame:FindFirstChild("Robux")
			local equippedBtn = frame:FindFirstChild("Equipped")

			if equipBtn then
				local textLabel = equipBtn:FindFirstChild("TextLabel")
				if textLabel then
					if config.Price == 0 then
						textLabel.Text = "Free"
					else
						textLabel.Text = "$" .. formatNumber(config.Price)
					end
				end
			end

			if robuxBtn then
				local textLabel = robuxBtn:FindFirstChild("TextLabel")
				if textLabel then
					if config.Robux > 0 then
						textLabel.Text = "" .. tostring(config.Robux)
					else
						robuxBtn.Visible = false
					end
				end
			end

			itemFrames[config.Name] = {
				item = item,
				itemFrame = frame,
				equipBtn = equipBtn,
				robuxBtn = robuxBtn,
				equippedBtn = equippedBtn,
			}

			if equipBtn then
				equipBtn.MouseButton1Click:Connect(function()
					if not canClick() then return end
					if ownedWeights[config.Name] then
						equipWeightEvent:FireServer(config.Name)
					else
						buyWeightEvent:FireServer(config.Name)
					end
				end)
			end

			if robuxBtn then
				robuxBtn.MouseButton1Click:Connect(function()
					if not canClick() then return end
					if not ownedWeights[config.Name] then
						buyWeightRobuxEvent:FireServer(config.Name)
					end
				end)
			end
		end

		updateAllVisuals()
	end

	weightDataEvent.OnClientEvent:Connect(function(data)
		ownedWeights = {}
		for _, name in ipairs(data.OwnedWeights) do
			ownedWeights[name] = true
		end
		equippedWeight = data.EquippedWeight

		updateAllVisuals()
	end)

	populateShop()

	print("[WeightShopController] Client poids initialisé!")
end

return WeightShopController

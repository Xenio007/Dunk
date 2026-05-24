--[[
	UIController
	Gère: Navigation des menus (Index, Rebirth, Shop, Weights),
	Affichage temps réel (Cash, YeetPower, FriendsBoost).

	Migration 1:1 de StarterPlayerScripts.UI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local UIController = Loader.CreateController({
	Name = "UIController",
})

local function formatNumber(num)
	local n = math.floor(num)
	if n >= 1e12 then
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

-- LikeFrame & RunFrame & SellFrame : MenuAnimationController gère déjà
-- l'animation pop-in via son PropertyChangedSignal("Visible"). On ne déclenche
-- plus playFramePopIn manuellement ici : faire `Visible = true` suffit.
-- (Avant : double tween en parallèle qui se Cancel mutuellement et donnait
-- l'impression que l'anim ne jouait pas.)

function UIController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local PowerDisplay = require(ReplicatedStorage:WaitForChild("PowerDisplay"))

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[UIController] MainGui introuvable dans PlayerGui après 30s")
		return
	end
	local uiLeft = mainGui:WaitForChild("UILeft")

	local indexFrame = mainGui:WaitForChild("IndexFrame")
	local rebirthFrame = mainGui:WaitForChild("RebirthFrame")
	local shopFrame = mainGui:WaitForChild("ShopFrame")
	local weightsFrame = mainGui:WaitForChild("WeightsFrame")
	local runFrame = mainGui:WaitForChild("RunFrame")
	local likeFrame = mainGui:WaitForChild("LikeFrame")

	-- SellFrame: il peut y avoir plusieurs instances nommées "SellFrame" dans MainGui,
	-- on les récupère toutes pour garder un comportement cohérent.
	local sellFrames = {}
	for _, child in ipairs(mainGui:GetChildren()) do
		if child.Name == "SellFrame" then
			table.insert(sellFrames, child)
		end
	end

	local indexButton = uiLeft:WaitForChild("Index")
	local rebirthButton = uiLeft:WaitForChild("Rebirth")
	local shopButton = uiLeft:WaitForChild("Shop")

	local indexCloseButton = indexFrame:WaitForChild("CloseButton")
	local rebirthCloseButton = rebirthFrame:WaitForChild("CloseButton")
	local shopCloseButton = shopFrame:WaitForChild("CloseButton")
	local weightsCloseButton = weightsFrame:WaitForChild("CloseButton")

	local bottomLeft = mainGui:WaitForChild("BottomLeft")
	local coinsFrame = bottomLeft:WaitForChild("CoinsFrame")
	local insideFrame = coinsFrame:WaitForChild("InsideFrame")
	local coinLabel = insideFrame:WaitForChild("CoinLabel")
	local yeetLevelFrame = bottomLeft:WaitForChild("YeetLevel")
	local yeetLabel = yeetLevelFrame:WaitForChild("TextLabel")
	local friendsBoostFrame = bottomLeft:WaitForChild("FriendsBoost")
	local friendsLabel = friendsBoostFrame:WaitForChild("FriendsLabel")

	pcall(function()
		-- On garde l'ancienne Backpack Roblox désactivée : le SatchelController
		-- fournit une hotbar stylisée maison qui la remplace entièrement.
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)

	indexFrame.Visible = false
	rebirthFrame.Visible = false
	shopFrame.Visible = false
	weightsFrame.Visible = false
	runFrame.Visible = false
	likeFrame.Visible = false
	for _, sf in ipairs(sellFrames) do
		sf.Visible = false
	end

	local allFrames = {indexFrame, rebirthFrame, shopFrame, weightsFrame, runFrame, likeFrame}
	for _, sf in ipairs(sellFrames) do
		table.insert(allFrames, sf)
	end

	local function closeAllExcept(exceptFrame)
		for _, frame in ipairs(allFrames) do
			if frame ~= exceptFrame then
				frame.Visible = false
			end
		end
	end

	local function toggleFrame(frame)
		closeAllExcept(frame)
		frame.Visible = not frame.Visible
	end

	indexButton.Activated:Connect(function()
		toggleFrame(indexFrame)
	end)
	indexCloseButton.Activated:Connect(function()
		indexFrame.Visible = false
	end)

	rebirthButton.Activated:Connect(function()
		toggleFrame(rebirthFrame)
	end)
	rebirthCloseButton.Activated:Connect(function()
		rebirthFrame.Visible = false
	end)

	-- Son joué quand le joueur clique sur le bouton Shop.
	local shopSound = Instance.new("Sound")
	shopSound.Name = "ShopClickSound"
	shopSound.SoundId = "rbxassetid://127488139302452"
	shopSound.Volume = 0.6
	shopSound.Parent = SoundService

	shopButton.Activated:Connect(function()
		-- Le son ne joue qu'à l'ouverture, pas à la fermeture.
		if not shopFrame.Visible then
			shopSound:Play()
		end
		toggleFrame(shopFrame)
	end)
	shopCloseButton.Activated:Connect(function()
		shopFrame.Visible = false
	end)

	-- === WEIGHTS FRAME (TouchPart du WeightShop) ===
	local weightTouchPart = Workspace:WaitForChild("Spawn"):WaitForChild("Shops"):WaitForChild("WeightShop"):WaitForChild("TouchPart")
	local isInWeightZone = false

	weightsCloseButton.Activated:Connect(function()
		weightsFrame.Visible = false
	end)

	weightTouchPart.Touched:Connect(function(hit)
		if isInWeightZone then return end
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			isInWeightZone = true
			closeAllExcept(weightsFrame)
			weightsFrame.Visible = true
		end
	end)

	weightTouchPart.TouchEnded:Connect(function(hit)
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			local stillTouching = false
			for _, part in ipairs(character:GetChildren()) do
				if part:IsA("BasePart") and part ~= hit then
					local touchingParts = part:GetTouchingParts()
					for _, tp in ipairs(touchingParts) do
						if tp == weightTouchPart then
							stillTouching = true
							break
						end
					end
					if stillTouching then break end
				end
			end
			if not stillTouching then
				isInWeightZone = false
				weightsFrame.Visible = false
			end
		end
	end)

	-- === LIKE FRAME (TouchPart 'Group' du FreeGift) ===
	local groupTouchPart = Workspace:WaitForChild("Spawn"):WaitForChild("FreeGift"):WaitForChild("Group")
	local isInGroupZone = false

	-- Bouton de fermeture (croix) de la LikeFrame. Il peut être imbriqué
	-- (ex: LikeFrame.Top.Main.CloseButton), donc on le cherche en récursif.
	local likeCloseBtn = likeFrame:FindFirstChild("CloseButton", true)
	if likeCloseBtn then
		likeCloseBtn.Activated:Connect(function()
			likeFrame.Visible = false
		end)
	end

	groupTouchPart.Touched:Connect(function(hit)
		if isInGroupZone then return end
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			isInGroupZone = true
			closeAllExcept(likeFrame)
			likeFrame.Visible = true
			-- Pas besoin d'appeler playFramePopIn : MenuAnimationController
			-- déclenche l'anim automatiquement via PropertyChangedSignal("Visible").
		end
	end)

	groupTouchPart.TouchEnded:Connect(function(hit)
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			local stillTouching = false
			for _, part in ipairs(character:GetChildren()) do
				if part:IsA("BasePart") and part ~= hit then
					local touchingParts = part:GetTouchingParts()
					for _, tp in ipairs(touchingParts) do
						if tp == groupTouchPart then
							stillTouching = true
							break
						end
					end
					if stillTouching then break end
				end
			end
			if not stillTouching then
				isInGroupZone = false
				likeFrame.Visible = false
			end
		end
	end)

	-- === SELL FRAME (TouchPart du Sell) ===
	local sellTouchPart = Workspace:WaitForChild("Spawn"):WaitForChild("Sell"):WaitForChild("TouchPart")
	local isInSellZone = false

	local function setSellFramesVisible(visible)
		for _, sf in ipairs(sellFrames) do
			sf.Visible = visible
		end
	end

	-- Boutons de fermeture (la croix) des SellFrames
	for _, sf in ipairs(sellFrames) do
		local closeBtn = sf:FindFirstChild("CloseButton")
		if closeBtn then
			closeBtn.Activated:Connect(function()
				setSellFramesVisible(false)
			end)
		end
	end

	sellTouchPart.Touched:Connect(function(hit)
		if isInSellZone then return end
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			isInSellZone = true
			closeAllExcept(nil)
			setSellFramesVisible(true)
		end
	end)

	sellTouchPart.TouchEnded:Connect(function(hit)
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			local stillTouching = false
			for _, part in ipairs(character:GetChildren()) do
				if part:IsA("BasePart") and part ~= hit then
					local touchingParts = part:GetTouchingParts()
					for _, tp in ipairs(touchingParts) do
						if tp == sellTouchPart then
							stillTouching = true
							break
						end
					end
					if stillTouching then break end
				end
			end
			if not stillTouching then
				isInSellZone = false
				setSellFramesVisible(false)
			end
		end
	end)

	-- === AFFICHAGE TEMPS RÉEL ===

	local function updateCashDisplay()
		local cashVal = player:FindFirstChild("Cash")
		if cashVal then
			coinLabel.Text = "$" .. formatNumber(cashVal.Value)
		end
	end

	local function updateYeetDisplay()
		yeetLabel.Text = formatNumber(PowerDisplay.DisplayedPower) .. " Dunk Power"
	end

	local function updateFriendsDisplay()
		local friendsBoostVal = player:FindFirstChild("FriendsBoost")
		if friendsBoostVal then
			local boost = friendsBoostVal.Value
			if boost > 0 then
				friendsLabel.Text = "Friends Boost: +" .. tostring(boost) .. "%"
			else
				friendsLabel.Text = "Friends Boost: +0%"
			end
		end
	end

	local function connectValues()
		local cashVal = player:WaitForChild("Cash", 15)
		local ypVal = player:WaitForChild("YeetPower", 15)
		local friendsBoostVal = player:WaitForChild("FriendsBoost", 15)

		if cashVal then
			cashVal:GetPropertyChangedSignal("Value"):Connect(updateCashDisplay)
			updateCashDisplay()
		end

		if ypVal then
			PowerDisplay:SetDisplayedPower(ypVal.Value)
			PowerDisplay:OnUpdate(function()
				updateYeetDisplay()
			end)
			updateYeetDisplay()

			-- Resync en cas de chute de la vraie valeur serveur (ex: rebirth -> YP = 0).
			-- Les hausses sont laissées au PowerPopupController (anim + AddDisplayedPower).
			ypVal:GetPropertyChangedSignal("Value"):Connect(function()
				local serverValue = ypVal.Value
				if serverValue < PowerDisplay.DisplayedPower then
					PowerDisplay:SetDisplayedPower(serverValue)
				end
			end)
		end

		if friendsBoostVal then
			friendsBoostVal:GetPropertyChangedSignal("Value"):Connect(updateFriendsDisplay)
			updateFriendsDisplay()
		end
	end

	connectValues()

	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		updateCashDisplay()
		updateYeetDisplay()
		updateFriendsDisplay()
	end)

	print("[UIController] Script UI initialisé!")
end

return UIController

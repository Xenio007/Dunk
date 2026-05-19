--[[
	RebirthController
	Gère l'affichage du RebirthFrame et la communication avec le serveur.

	Migration 1:1 de StarterGui.MainGui.RebirthFrame.RebirthGui.
	L'ancien script utilisait script.Parent pour référencer le RebirthFrame ;
	on résout explicitement le chemin via PlayerGui.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local RebirthController = Loader.CreateController({
	Name = "RebirthController",
})

local REBIRTH_BASE_COST = 1000
local REBIRTH_COST_MULTIPLIER = 10

local function getRequiredYP(currentRebirths)
	return REBIRTH_BASE_COST * (REBIRTH_COST_MULTIPLIER ^ currentRebirths)
end

local function getNextCashMulti(currentRebirths)
	return currentRebirths + 2
end

local function formatNumber(num)
	return tostring(math.floor(num)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

function RebirthController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[RebirthController] MainGui introuvable")
		return
	end
	local Parent = mainGui:WaitForChild("RebirthFrame")

	local rebirthEvent = RemotesAPI.GetEvent("RebirthEvent")
	local skipRebirthEvent = RemotesAPI.GetEvent("SkipRebirthEvent")

	local rebirthButton = Parent:WaitForChild("Rebirth")
	local skipButton = Parent:WaitForChild("Skip")
	local cashProgressFrame = Parent:WaitForChild("CashProgress")
	local cashProgressText = cashProgressFrame:WaitForChild("TextLabel")
	local cashProgressBar = cashProgressFrame:WaitForChild("Frame")
	local rewardsFrame = Parent:WaitForChild("Rewards")
	local rewardTemp = rewardsFrame:WaitForChild("Temp")
	rewardTemp.Visible = true

	local greenGradient = rebirthButton:WaitForChild("Green")
	local redGradient = rebirthButton:WaitForChild("Red")
	local rebirthButtonFrame = rebirthButton:WaitForChild("Frame")
	local greenGradientFrame = rebirthButtonFrame:FindFirstChild("Green")
	local redGradientFrame = rebirthButtonFrame:FindFirstChild("Red")
	local rebirthUIStroke = rebirthButton:FindFirstChild("UIStroke")

	local cashProgressGradient = cashProgressFrame:FindFirstChild("UIGradient")

	local isRebirthing = false
	local isSkipping = false

	local rebirthNumberLabel = nil
	for _, child in ipairs(Parent:GetChildren()) do
		if child:IsA("TextLabel") and child.Text:match("^Rebirth") then
			rebirthNumberLabel = child
			break
		end
	end

	local leftLabel, rightLabel = nil, nil
	for _, child in ipairs(rewardTemp:GetChildren()) do
		if child:IsA("TextLabel") then
			local posX = child.Position.X.Scale
			if posX < 0.4 then
				leftLabel = child
			elseif posX > 0.6 then
				rightLabel = child
			end
		end
	end

	local function updateRebirthButton(canDoRebirth)
		if canDoRebirth then
			greenGradient.Enabled = true
			redGradient.Enabled = false
			if greenGradientFrame then greenGradientFrame.Enabled = true end
			if redGradientFrame then redGradientFrame.Enabled = false end
			if rebirthUIStroke then rebirthUIStroke.Color = Color3.fromRGB(170, 255, 0) end
		else
			greenGradient.Enabled = false
			redGradient.Enabled = true
			if greenGradientFrame then greenGradientFrame.Enabled = false end
			if redGradientFrame then redGradientFrame.Enabled = true end
			if rebirthUIStroke then rebirthUIStroke.Color = Color3.fromRGB(255, 0, 4) end
		end
	end

	local function updateProgressBar(currentYP, requiredYP)
		local progress = math.clamp(currentYP / requiredYP, 0, 1)
		cashProgressText.Text = formatNumber(currentYP) .. " / " .. formatNumber(requiredYP) .. " Yeet Power"
		cashProgressBar.Size = UDim2.new(1 - progress, 0, 1, 0)

		if cashProgressGradient then
			cashProgressGradient.Enabled = (currentYP > 0)
		end
		if currentYP <= 0 then
			cashProgressFrame.BackgroundTransparency = 1
		else
			cashProgressFrame.BackgroundTransparency = 0
		end
	end

	local function updateRewards(currentCashMulti, nextCashMulti, currentRebirths)
		if leftLabel then
			leftLabel.Text = "X" .. tostring(currentCashMulti) .. " Cash"
		end
		if rightLabel then
			rightLabel.Text = "X" .. tostring(nextCashMulti) .. " Cash"
		end

		for _, child in ipairs(rewardsFrame:GetChildren()) do
			if child:IsA("Frame") and child.Name ~= "Temp" then
				for _, textLabel in ipairs(child:GetChildren()) do
					if textLabel:IsA("TextLabel") then
						local posX = textLabel.Position.X.Scale
						if posX < 0.4 then
							textLabel.Text = "X" .. tostring(currentCashMulti) .. " Cash"
						elseif posX > 0.6 then
							textLabel.Text = "X" .. tostring(nextCashMulti) .. " Cash"
						end
					end
				end
			end
		end

		if rebirthNumberLabel then
			if currentRebirths == 0 then
				rebirthNumberLabel.Text = "Rebirth 1"
			else
				rebirthNumberLabel.Text = "Rebirth " .. tostring(currentRebirths + 1)
			end
		end
	end

	local function updateDisplay()
		local yeetPowerVal = player:FindFirstChild("YeetPower")
		local rebirthsVal = player:FindFirstChild("Rebirths")
		local cashMultiVal = player:FindFirstChild("CashMulti")

		if not yeetPowerVal or not rebirthsVal or not cashMultiVal then return end

		local currentYP = yeetPowerVal.Value
		local currentRebirths = rebirthsVal.Value
		local requiredYP = getRequiredYP(currentRebirths)

		local currentCashMulti = cashMultiVal.Value
		local nextCashMulti = getNextCashMulti(currentRebirths)

		updateProgressBar(currentYP, requiredYP)
		updateRewards(currentCashMulti, nextCashMulti, currentRebirths)
		updateRebirthButton(currentYP >= requiredYP)
	end

	local function connectLeaderstats()
		local yeetPowerVal = player:WaitForChild("YeetPower", 10)
		local rebirthsVal = player:WaitForChild("Rebirths", 10)
		local cashMultiVal = player:WaitForChild("CashMulti", 10)

		if yeetPowerVal then
			yeetPowerVal:GetPropertyChangedSignal("Value"):Connect(updateDisplay)
		end
		if rebirthsVal then
			rebirthsVal:GetPropertyChangedSignal("Value"):Connect(updateDisplay)
		end
		if cashMultiVal then
			cashMultiVal:GetPropertyChangedSignal("Value"):Connect(updateDisplay)
		end

		updateDisplay()
	end

	rebirthButton.Activated:Connect(function()
		if isRebirthing then return end
		isRebirthing = true

		local yeetPowerVal = player:FindFirstChild("YeetPower")
		local rebirthsVal = player:FindFirstChild("Rebirths")
		local currentRebirths = rebirthsVal and rebirthsVal.Value or 0
		local requiredYP = getRequiredYP(currentRebirths)
		if yeetPowerVal and yeetPowerVal.Value < requiredYP then
			isRebirthing = false
			return
		end

		rebirthEvent:FireServer()
		task.wait(0.5)
		isRebirthing = false
	end)

	rebirthEvent.OnClientEvent:Connect(function(success, message)
		if success then
			print("[RebirthController] " .. tostring(message))
			updateDisplay()
		else
			warn("[RebirthController] Rebirth échoué: " .. tostring(message))
		end
	end)

	skipButton.Activated:Connect(function()
		if isSkipping then return end
		isSkipping = true
		skipRebirthEvent:FireServer()
		task.wait(1)
		isSkipping = false
	end)

	skipRebirthEvent.OnClientEvent:Connect(function(success, message)
		if success then
			print("[RebirthController] " .. tostring(message))
			updateDisplay()
		else
			warn("[RebirthController] Skip Rebirth échoué: " .. tostring(message))
		end
	end)

	connectLeaderstats()

	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		updateDisplay()
	end)

	print("[RebirthController] Initialisé!")
end

return RebirthController

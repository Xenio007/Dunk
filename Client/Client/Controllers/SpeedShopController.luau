--[[
	SpeedShopController
	Gère l'UI du shop de vitesse (RunFrame) et l'ouverture automatique
	quand le joueur touche la SpeedShop.TouchPart.

	La frame contient 3 boutons :
		Run1 -> achète 1 amélioration (prix du niveau courant)
		Run2 -> achète 10 améliorations (pack intermédiaire)
		Run3 -> achète MAX (autant que le cash le permet)

	Le label principal affiche la speed actuelle. Chaque bouton affiche le
	prix total et le nombre exact d'améliorations possibles (clampé au cash
	et au max).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local SpeedConfig = require(ReplicatedStorage:WaitForChild("SpeedConfig"))

local SpeedShopController = Loader.CreateController({
	Name = "SpeedShopController",
})

local MID_PACK_SIZE = 10

local function formatNumber(num)
	local n = math.floor(num)
	if n >= 1e21 then
		return string.format("%.1fSx", n / 1e21)
	elseif n >= 1e18 then
		return string.format("%.1fQi", n / 1e18)
	elseif n >= 1e15 then
		return string.format("%.1fQa", n / 1e15)
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

function SpeedShopController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then return end

	local runFrame = mainGui:WaitForChild("RunFrame", 30)
	if not runFrame then return end

	runFrame.Visible = false

	local closeButton = runFrame:FindFirstChild("CloseButton")
	local scrollFrame = runFrame:FindFirstChild("ScrollingFrame")
	local outer = scrollFrame and scrollFrame:FindFirstChild("Frame")

	-- Structure actuelle :
	--   RunFrame.ScrollingFrame.Frame.Frame (ImageLabel, conteneur principal)
	--     NameLabel (label "Run Speed: XX")
	--     Frame (Frame intermédiaire qui contient les boutons)
	--       Run1, Run2, Run3
	-- On cherche d'abord le conteneur principal (qui a NameLabel), puis on
	-- descend dans son enfant pour trouver les boutons.
	local mainContainer
	local buttonHolder
	if outer then
		for _, child in ipairs(outer:GetChildren()) do
			if child:IsA("ImageLabel") or child:IsA("Frame") then
				-- Recherche récursive : Run1 peut être direct OU dans une sous-Frame.
				local foundRun1 = child:FindFirstChild("Run1", true)
				if foundRun1 then
					mainContainer = child
					buttonHolder = foundRun1.Parent
					break
				end
			end
		end
	end

	if not buttonHolder then
		warn("[SpeedShopController] Impossible de trouver Run1/Run2/Run3 dans RunFrame")
		return
	end

	local run1 = buttonHolder:FindFirstChild("Run1")
	local run2 = buttonHolder:FindFirstChild("Run2")
	local run3 = buttonHolder:FindFirstChild("Run3")
	-- Le NameLabel principal est sur le conteneur parent (pas au même niveau
	-- que les boutons maintenant).
	local mainNameLabel = mainContainer and mainContainer:FindFirstChild("NameLabel")
		or buttonHolder:FindFirstChild("NameLabel")

	local buySpeedEvent = RemotesAPI.GetEvent("BuySpeedEvent")
	local speedLevelVal = player:WaitForChild("SpeedLevel", 30)
	local cashVal = player:WaitForChild("Cash", 30)

	local function captureOriginalLook(button)
		if not button or button:GetAttribute("_OrigCaptured") then return end
		button:SetAttribute("_OrigImageColor3", button.ImageColor3)
		button:SetAttribute("_OrigBgColor3", button.BackgroundColor3)
		-- Capture récursivement : BG, UIGradient, images enfants.
		-- NB : on NE touche PAS aux UIStroke (contours), pour conserver le look
		-- graphique d'origine du bouton.
		for _, d in ipairs(button:GetDescendants()) do
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				d:SetAttribute("_OrigImageColor3", d.ImageColor3)
				d:SetAttribute("_OrigBgColor3", d.BackgroundColor3)
			elseif d:IsA("Frame") then
				d:SetAttribute("_OrigBgColor3", d.BackgroundColor3)
			elseif d:IsA("UIGradient") then
				d:SetAttribute("_OrigEnabled", d.Enabled)
			end
		end
		button:SetAttribute("_OrigCaptured", true)
	end
	captureOriginalLook(run1)
	captureOriginalLook(run2)
	captureOriginalLook(run3)

	local GREY = Color3.fromRGB(130, 130, 130)

	local function setButtonGreyed(button, greyed)
		if not button then return end
		captureOriginalLook(button)

		if greyed then
			button.ImageColor3 = GREY
			button.BackgroundColor3 = GREY
			button.Active = false
			button.AutoButtonColor = false
			-- Désactive les gradients colorés et grise les backgrounds enfants.
			-- Les UIStroke sont laissés intacts pour préserver le contour d'origine.
			for _, d in ipairs(button:GetDescendants()) do
				if d:IsA("ImageLabel") or d:IsA("ImageButton") then
					d.ImageColor3 = GREY
					d.BackgroundColor3 = GREY
				elseif d:IsA("Frame") then
					d.BackgroundColor3 = GREY
				elseif d:IsA("UIGradient") then
					d.Enabled = false
				end
			end
		else
			button.ImageColor3 = button:GetAttribute("_OrigImageColor3") or Color3.new(1, 1, 1)
			button.BackgroundColor3 = button:GetAttribute("_OrigBgColor3") or Color3.new(1, 1, 1)
			button.Active = true
			for _, d in ipairs(button:GetDescendants()) do
				if d:IsA("ImageLabel") or d:IsA("ImageButton") then
					local c = d:GetAttribute("_OrigImageColor3")
					if c then d.ImageColor3 = c end
					local b = d:GetAttribute("_OrigBgColor3")
					if b then d.BackgroundColor3 = b end
				elseif d:IsA("Frame") then
					local b = d:GetAttribute("_OrigBgColor3")
					if b then d.BackgroundColor3 = b end
				elseif d:IsA("UIGradient") then
					local e = d:GetAttribute("_OrigEnabled")
					if e ~= nil then d.Enabled = e end
				end
			end
		end
	end

	-- Remplit le texte + nom d'un bouton pour un nombre d'améliorations donné.
	local function setButtonContent(button, count, totalCost)
		if not button then return end
		local textLabel = button:FindFirstChild("TextLabel")
		local nameLabel = button:FindFirstChild("NameLabel")
		if nameLabel then
			nameLabel.Text = "+" .. count .. " Speed"
		end
		if textLabel then
			if totalCost <= 0 then
				textLabel.Text = "FREE"
			else
				textLabel.Text = "$" .. formatNumber(totalCost)
			end
		end
	end

	-- Stock les counts effectifs de chaque bouton pour les handlers de clic.
	local run1Count, run2Count, run3Count = 0, 0, 0

	local function refreshUI()
		local lv = speedLevelVal.Value
		local cash = cashVal.Value
		local currentSpeed = SpeedConfig.GetSpeedForLevel(lv)

		if mainNameLabel then
			if lv >= SpeedConfig.MAX_LEVEL then
				mainNameLabel.Text = "Run Speed: " .. currentSpeed .. " (MAX)"
			else
				mainNameLabel.Text = "Run Speed: " .. currentSpeed
			end
		end

		-- Niveau MAX atteint : tout afficher "MAX" et griser.
		if lv >= SpeedConfig.MAX_LEVEL then
			if run1 then
				run1.Visible = true
				local tl = run1:FindFirstChild("TextLabel"); if tl then tl.Text = "MAX" end
				local nl = run1:FindFirstChild("NameLabel"); if nl then nl.Text = "MAX" end
				setButtonGreyed(run1, true)
			end
			if run2 then run2.Visible = false end
			if run3 then run3.Visible = false end
			run1Count, run2Count, run3Count = 0, 0, 0
			return
		end

		local maxLeft = SpeedConfig.MAX_LEVEL - lv
		local maxAffordable = SpeedConfig.GetMaxAffordable(lv, cash)

		-- Cas 1 : le joueur ne peut s'offrir AUCUNE amélioration.
		-- On cache Run2 + Run3, et on grise Run1 en affichant son prix.
		if maxAffordable <= 0 then
			local cost1 = SpeedConfig.GetUpgradeCost(lv)
			if run1 then
				run1.Visible = true
				setButtonContent(run1, 1, cost1)
				setButtonGreyed(run1, true)
			end
			if run2 then run2.Visible = false end
			if run3 then run3.Visible = false end
			run1Count, run2Count, run3Count = 1, 0, 0
			return
		end

		-- Cas 2 : calcul normal. Run1=1, Run3=max affordable, Run2=milieu.
		local c1 = 1
		local c3 = maxAffordable
		local c2 = math.ceil((c1 + c3) / 2)

		local cost1 = SpeedConfig.GetTotalCost(lv, c1)
		local cost2 = SpeedConfig.GetTotalCost(lv, c2)
		local cost3 = SpeedConfig.GetTotalCost(lv, c3)

		-- Run1 : toujours visible, grisé SEULEMENT si son coût est trop cher
		-- (ce qui ne devrait pas arriver ici car maxAffordable >= 1 implique
		-- c1=1 affordable, mais on reste défensif).
		if run1 then
			run1.Visible = true
			setButtonContent(run1, c1, cost1)
			setButtonGreyed(run1, cost1 > cash)
		end

		-- Run2 : caché si inutile (<=c1 ou ==c3), grisé si trop cher.
		if run2 then
			if c2 <= c1 or c2 == c3 then
				run2.Visible = false
			else
				run2.Visible = true
				setButtonContent(run2, c2, cost2)
				setButtonGreyed(run2, cost2 > cash)
			end
		end

		-- Run3 : caché si identique à Run1, sinon montré et grisé si trop cher.
		if run3 then
			if c3 <= c1 then
				run3.Visible = false
			else
				run3.Visible = true
				setButtonContent(run3, c3, cost3)
				setButtonGreyed(run3, cost3 > cash)
			end
		end

		run1Count, run2Count, run3Count = c1, c2, c3
	end

	refreshUI()
	speedLevelVal:GetPropertyChangedSignal("Value"):Connect(refreshUI)
	cashVal:GetPropertyChangedSignal("Value"):Connect(refreshUI)

	-- Connections boutons : chaque bouton envoie au serveur le count EXACT
	-- affiché (calculé à partir du cash). Le serveur revalide de toute façon.
	if run1 then
		run1.MouseButton1Click:Connect(function()
			if run1Count > 0 then
				buySpeedEvent:FireServer(run1Count)
			end
		end)
	end
	if run2 then
		run2.MouseButton1Click:Connect(function()
			if run2Count > 0 then
				buySpeedEvent:FireServer(run2Count)
			end
		end)
	end
	if run3 then
		run3.MouseButton1Click:Connect(function()
			if run3Count > 0 then
				buySpeedEvent:FireServer("MAX")
			end
		end)
	end

	if closeButton then
		if closeButton:IsA("ImageButton") or closeButton:IsA("TextButton") then
			closeButton.MouseButton1Click:Connect(function()
				runFrame.Visible = false
			end)
		else
			pcall(function()
				closeButton.Activated:Connect(function()
					runFrame.Visible = false
				end)
			end)
		end
	end

	-- Ouverture automatique quand le joueur entre dans la TouchPart du SpeedShop.
	local spawnFolder = Workspace:WaitForChild("Spawn")
	local shopsFolder = spawnFolder:WaitForChild("Shops")
	local speedShop = shopsFolder:WaitForChild("SpeedShop")
	local touchPart = speedShop:WaitForChild("TouchPart")

	local isInZone = false

	touchPart.Touched:Connect(function(hit)
		if isInZone then return end
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			isInZone = true
			refreshUI()
			runFrame.Visible = true
		end
	end)

	touchPart.TouchEnded:Connect(function(hit)
		local character = player.Character
		if not character then return end
		if hit:IsDescendantOf(character) then
			local stillTouching = false
			for _, part in ipairs(character:GetChildren()) do
				if part:IsA("BasePart") and part ~= hit then
					local touchingParts = part:GetTouchingParts()
					for _, tp in ipairs(touchingParts) do
						if tp == touchPart then
							stillTouching = true
							break
						end
					end
					if stillTouching then break end
				end
			end
			if not stillTouching then
				isInZone = false
				runFrame.Visible = false
			end
		end
	end)

	buySpeedEvent.OnClientEvent:Connect(function(_success, _message, _newLevel)
		refreshUI()
	end)

	print("[SpeedShopController] Prêt (speed actuel: " .. SpeedConfig.GetSpeedForLevel(speedLevelVal.Value) .. ")")
end

return SpeedShopController

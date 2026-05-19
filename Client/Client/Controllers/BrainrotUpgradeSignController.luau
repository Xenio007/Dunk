--[[
	BrainrotUpgradeSignController
	Gère l'affichage et l'interaction des UpgradeSigns placés au-dessus
	des slots du plot du LOCAL player.

	Responsabilités :
	  - Rendre visibles uniquement les signs du plot du joueur courant.
	  - Cacher le bouton (GUI.Enabled=false) quand le slot est vide.
	  - Mettre à jour dynamiquement le prix et les textes quand le slot change.
	  - Cliquer sur Button -> fire BuyUpgradeBrainrotEvent(slotPart).

	Le serveur met à jour les textes sur placement / upgrade / retrait via
	refreshUpgradeSign côté serveur, donc on n'a presque rien à recalculer ici.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local BrainrotUpgrade = require(ReplicatedStorage.Shared:WaitForChild("BrainrotUpgrade"))

local BrainrotUpgradeSignController = Loader.CreateController({
	Name = "BrainrotUpgradeSignController",
})

-- Son joué quand un upgrade réussit (cash ou Robux +3/MAX).
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local UPGRADE_SOUND_ID = "rbxassetid://17208339919"
local HOVER_SCALE      = 1.06
local HOVER_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local UNHOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function playOneShot(id, volume)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.7
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, math.max(s.TimeLength + 0.5, 5))
end

local function playUpgradeSound()
	playOneShot(UPGRADE_SOUND_ID, 0.8)
end

local UPGRADE_SIGN_FOLDER = "UpgradeSigns"
local SIGN_REF_NAME       = "_UpgradeSignRef"
local MAX_SIGN_REF_NAME   = "_MaxUpgradeSignRef"
local SLOT_OCCUPIED_ATTR  = "SlotOccupied"
local SLOT_BRAINROT_ATTR  = "BrainrotFullName"
local SLOT_LEVEL_ATTR     = "BrainrotLevel"

local function updateSignVisualsForSlot(slotPart, buyUpgradeEvent)
	local ref = slotPart:FindFirstChild(SIGN_REF_NAME)
	if not ref or not ref.Value then return end
	local sign = ref.Value
	if not sign:IsA("BasePart") then return end

	local gui = sign:FindFirstChild("UpgradeGUI")
	if not gui then return end

	local occupied = slotPart:GetAttribute(SLOT_OCCUPIED_ATTR) == true
	local fullName = slotPart:GetAttribute(SLOT_BRAINROT_ATTR)
	local isExclusive = type(fullName) == "string" and BrainrotInfo.IsExclusive(fullName)

	-- Pour les exclusifs, on cache complètement le sign d'upgrade : il n'a
	-- aucune action possible (ni cash, ni Robux), inutile de l'afficher.
	gui.Enabled = occupied and not isExclusive

	local button = gui:FindFirstChild("Button")
	if not button then return end

	local level = tonumber(slotPart:GetAttribute(SLOT_LEVEL_ATTR)) or 0
	local priceLabel = button:FindFirstChild("PriceLabel")
	local levelLabel = button:FindFirstChild("LevelLabel")

	if not occupied or type(fullName) ~= "string" or fullName == "" then
		if priceLabel then priceLabel.Text = "" end
		if levelLabel then levelLabel.Text = "" end
		return
	end

	-- Brainrot exclusif : impossible à améliorer en niveau (CPS = % fixe).
	if isExclusive then
		if priceLabel then priceLabel.Text = "" end
		if levelLabel then levelLabel.Text = "Exclusive (Robux)" end
		return
	end

	if BrainrotUpgrade.IsMax(level) then
		if priceLabel then priceLabel.Text = "MAX" end
		if levelLabel then levelLabel.Text = "Lvl " .. level .. " (MAX)" end
		return
	end

	local cost = BrainrotUpgrade.GetUpgradeCostByName(fullName, level)
	if priceLabel then
		priceLabel.Text = "$" .. BrainrotInfo.FormatShort(cost)
	end
	if levelLabel then
		levelLabel.Text = string.format("Lvl %d > Lvl %d", level, level + 1)
	end
end

local function hookSlot(slotPart, buyUpgradeEvent, buyMaxUpgradeEvent, conns)
	-- Initial update + reactive updates.
	updateSignVisualsForSlot(slotPart, buyUpgradeEvent)

	local function refresh()
		updateSignVisualsForSlot(slotPart, buyUpgradeEvent)
	end

	table.insert(conns, slotPart:GetAttributeChangedSignal(SLOT_OCCUPIED_ATTR):Connect(refresh))
	table.insert(conns, slotPart:GetAttributeChangedSignal(SLOT_BRAINROT_ATTR):Connect(refresh))
	table.insert(conns, slotPart:GetAttributeChangedSignal(SLOT_LEVEL_ATTR):Connect(refresh))

	-- Hook the Button (une seule fois, quand il est découvert).
	local ref = slotPart:FindFirstChild(SIGN_REF_NAME)
	if ref and ref.Value then
		local sign = ref.Value
		local gui = sign:FindFirstChild("UpgradeGUI")
		local button = gui and gui:FindFirstChild("Button")
		if button and not button:GetAttribute("_ClickHooked") then
			button:SetAttribute("_ClickHooked", true)
			button.Active = true
			if button:IsA("ImageButton") or button:IsA("TextButton") then
				-- UNIQUEMENT Activated : sur une souris, Activated + MouseButton1Click
				-- fire deux fois pour le même clic. Résultat : double FireServer,
				-- le 1er upgrade passe (cash débité), le 2e voit qu'il manque du
				-- cash et lance le prompt Robux -> bug visible.
				button.Activated:Connect(function()
					-- Bloque le clic côté client si le brainrot placé est exclusif :
					-- inutile d'envoyer la requête au serveur, et ça évite que le
					-- prompt d'achat Robux du fallback se déclenche.
					local fullName = slotPart:GetAttribute(SLOT_BRAINROT_ATTR)
					if type(fullName) == "string" and BrainrotInfo.IsExclusive(fullName) then
						return
					end
					buyUpgradeEvent:FireServer(slotPart)
				end)

				-- Hover : scale la Part du sign principal + joue le son.
				local originalSize = sign.Size
				local hoverSize = originalSize * HOVER_SCALE
				local hoverTween
				button.MouseEnter:Connect(function()
					if hoverTween then hoverTween:Cancel() end
					hoverTween = TweenService:Create(sign, HOVER_TWEEN_INFO, { Size = hoverSize })
					hoverTween:Play()
					playOneShot(UPGRADE_SOUND_ID, 0.6)
				end)
				button.MouseLeave:Connect(function()
					if hoverTween then hoverTween:Cancel() end
					hoverTween = TweenService:Create(sign, UNHOVER_TWEEN_INFO, { Size = originalSize })
					hoverTween:Play()
				end)
			end
		end
	end

	-- Hook du petit sign MAX (panneau carré à droite). Clic -> fire
	-- BuyMaxUpgradeBrainrotEvent(slotPart) -> serveur lance le product MAX.
	local maxRef = slotPart:FindFirstChild(MAX_SIGN_REF_NAME)
	if maxRef and maxRef.Value then
		local maxSign = maxRef.Value
		local gui = maxSign:FindFirstChildOfClass("SurfaceGui")
		local wrapper = gui and gui:FindFirstChild("Wrapper")
		local bg = wrapper and wrapper:FindFirstChild("BG")
		local button = bg and bg:FindFirstChild("Button")

		if button and not button:GetAttribute("_ClickHooked") then
			button:SetAttribute("_ClickHooked", true)

			if button:IsA("ImageButton") or button:IsA("TextButton") then
				-- Clic -> fire server (SANS son, le son est joué au hover).
				-- UNIQUEMENT Activated (voir commentaire plus haut sur le double-fire).
				local function onClick()
					-- Bloque le clic si le brainrot placé est exclusif.
					local fullName = slotPart:GetAttribute(SLOT_BRAINROT_ATTR)
					if type(fullName) == "string" and BrainrotInfo.IsExclusive(fullName) then
						return
					end
					buyMaxUpgradeEvent:FireServer(slotPart)
				end
				button.Activated:Connect(onClick)

				-- Hover : scale la PART elle-même + JOUE le son d'upgrade.
				local originalSize = maxSign.Size
				local hoverSize = originalSize * HOVER_SCALE
				local hoverTween
				local function onEnter()
					if hoverTween then hoverTween:Cancel() end
					hoverTween = TweenService:Create(maxSign, HOVER_TWEEN_INFO, { Size = hoverSize })
					hoverTween:Play()
					playOneShot(UPGRADE_SOUND_ID, 0.6)
				end
				local function onLeave()
					if hoverTween then hoverTween:Cancel() end
					hoverTween = TweenService:Create(maxSign, UNHOVER_TWEEN_INFO, { Size = originalSize })
					hoverTween:Play()
				end
				button.MouseEnter:Connect(onEnter)
				button.MouseLeave:Connect(onLeave)
			end
		end
	end
end

function BrainrotUpgradeSignController:Start()
	local player = Players.LocalPlayer
	local plotsFolder = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")

	local plotNumVal = player:WaitForChild("PlotNumber", 30)
	if not plotNumVal then
		warn("[BrainrotUpgradeSignController] Pas de PlotNumber")
		return
	end

	local myPlot = plotsFolder:WaitForChild("Plot" .. plotNumVal.Value, 30)
	if not myPlot then
		warn("[BrainrotUpgradeSignController] Plot introuvable")
		return
	end

	local buyUpgradeEvent = RemotesAPI.GetEvent("BuyUpgradeBrainrotEvent")
	local buyMaxUpgradeEvent = RemotesAPI.GetEvent("BuyMaxUpgradeBrainrotEvent")

	local conns = {}

	-- Rend visibles tous les signs existants du plot (UpgradeSigns folder).
	local function handleSlot(slotPart)
		if not slotPart:IsA("BasePart") then return end
		if not slotPart.Parent or slotPart.Parent.Name ~= "Slots" then return end
		-- Attend la ref (créée par le serveur dans ensureUpgradeSignForSlot).
		local ref = slotPart:FindFirstChild(SIGN_REF_NAME)
		if not ref then
			table.insert(conns, slotPart.ChildAdded:Connect(function(child)
				if child.Name == SIGN_REF_NAME then
					hookSlot(slotPart, buyUpgradeEvent, buyMaxUpgradeEvent, conns)
				elseif child.Name == MAX_SIGN_REF_NAME then
					hookSlot(slotPart, buyUpgradeEvent, buyMaxUpgradeEvent, conns)
				end
			end))
			return
		end
		hookSlot(slotPart, buyUpgradeEvent, buyMaxUpgradeEvent, conns)
	end

	-- Parcours initial.
	for _, desc in ipairs(myPlot:GetDescendants()) do
		handleSlot(desc)
	end

	-- Nouveaux slots (Floor2 acheté après coup, etc.)
	table.insert(conns, myPlot.DescendantAdded:Connect(function(desc)
		task.wait() -- laisse le serveur initialiser le SIGN_REF
		handleSlot(desc)
	end))

	buyUpgradeEvent.OnClientEvent:Connect(function(success, message)
		if success then
			print("[BrainrotUpgrade] " .. tostring(message))
		else
			warn("[BrainrotUpgrade] " .. tostring(message))
		end
	end)
end

return BrainrotUpgradeSignController

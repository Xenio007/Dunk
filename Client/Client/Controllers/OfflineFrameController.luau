--[[
	OfflineFrameController
	Affiche StarterGui.MainGui.OfflineFrame au rejoin quand le serveur envoie
	une offre d'offline earnings valide (joueur absent >= MIN_OFFLINE_SECONDS).

	Boutons :
	  - Claim       : encaisse le cash tel quel.
	  - Upgrade     : lance le product Robux 3591223850 (x10).
	  - Close       : ferme sans encaisser (rien n'est donné).

	La frame est ignorée (reste Visible=false) si le serveur dit Valid=false
	(joueur pas assez absent, ou aucun brainrot placé).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))

local OfflineFrameController = Loader.CreateController({
	Name = "OfflineFrameController",
})

-- ===== CONFIG =====

-- ID du product x10. Dupliqué ici pour écouter PromptProductPurchaseFinished
-- et savoir si le joueur a fermé le prompt sans acheter (déblocage des boutons).
local OFFLINE_X10_PRODUCT_ID = 3591223850

-- Image de la pièce dorée utilisée par l'anim.
local COIN_IMAGE_ID = "rbxassetid://106254793390209"

-- ===== SFX =====

-- Son d'ouverture de la frame (whoosh).
local OPEN_SOUND_ID    = "rbxassetid://127488139302452"
-- Son de claim (cash register / coin shower).
local CLAIM_SOUND_ID   = "rbxassetid://17208380755"
local UPGRADE_SOUND_ID = "rbxassetid://17208380755"

local function playOneShot(id, volume)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.8
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, math.max(s.TimeLength + 1, 5))
end

-- Format "1h 23m" / "12m 34s" / "45s" pour l'Info label.
local function formatDuration(totalSec)
	totalSec = math.max(0, math.floor(totalSec))
	local hours = math.floor(totalSec / 3600)
	local minutes = math.floor((totalSec % 3600) / 60)
	local seconds = totalSec % 60
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, seconds)
	end
	return string.format("%ds", seconds)
end

-- Anime l'apparition (scale up) et la fermeture (scale down) de la frame.
local function showFrame(frame)
	local uiScale = frame:FindFirstChild("EntranceScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "EntranceScale"
		uiScale.Parent = frame
	end
	uiScale.Scale = 0.6
	frame.Visible = true
	TweenService:Create(uiScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
	playOneShot(OPEN_SOUND_ID, 0.5)
end

local function hideFrame(frame)
	local uiScale = frame:FindFirstChild("EntranceScale")
	if uiScale then
		local tween = TweenService:Create(uiScale, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Scale = 0.6,
		})
		tween.Completed:Once(function()
			frame.Visible = false
		end)
		tween:Play()
	else
		frame.Visible = false
	end
end

-- Anim "cash burst" : vraie physique balistique. Des pièces dorées sont
-- tirées depuis le centre du frame vers le haut avec gravité, spin, et
-- fade en fin de vie. Rendu plein écran dans un ScreenGui dédié pour
-- afficher au-dessus de la OfflineFrame. Tout est nettoyé auto via Debris.
local function playClaimBurst(frame, multiplier)
	local player = Players.LocalPlayer
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	-- ScreenGui dédié : évite les conflits de ZIndex et reste actif même
	-- après fermeture de la OfflineFrame.
	local screen = Instance.new("ScreenGui")
	screen.Name = "OfflineClaimBurst"
	screen.DisplayOrder = 1000
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.Parent = playerGui
	Debris:AddItem(screen, 4)

	-- Centre de lancement : centre de la OfflineFrame (si invisible, centre
	-- de l'écran en fallback).
	local originX, originY
	if frame and frame.AbsoluteSize.Magnitude > 0 then
		local pos = frame.AbsolutePosition + frame.AbsoluteSize * 0.5
		originX, originY = pos.X, pos.Y
	else
		local vs = screen.AbsoluteSize
		originX, originY = vs.X * 0.5, vs.Y * 0.5
	end

	local count = multiplier and multiplier > 1 and 40 or 22
	local coinSize = multiplier and multiplier > 1 and 64 or 56

	for i = 1, count do
		local coin = Instance.new("ImageLabel")
		coin.Name = "Coin"
		coin.Image = COIN_IMAGE_ID
		coin.BackgroundTransparency = 1
		coin.AnchorPoint = Vector2.new(0.5, 0.5)
		coin.Size = UDim2.fromOffset(coinSize, coinSize)
		coin.Position = UDim2.fromOffset(originX, originY)
		coin.ZIndex = 1
		coin.Parent = screen

		-- Velocity initiale : angle majoritairement vers le haut (écart 70°
		-- autour de -90°, soit de -160° à -20°). Vitesse aléatoire.
		local angleDeg = -90 + (math.random() - 0.5) * 160
		local angle = math.rad(angleDeg)
		local speed = math.random(650, 950) * (multiplier and multiplier > 1 and 1.2 or 1)
		local vx = math.cos(angle) * speed
		local vy = math.sin(angle) * speed
		local gravity = 2200
		local spin = (math.random() - 0.5) * 1200 -- deg/s
		local lifetime = 0.9 + math.random() * 0.4

		local px, py = originX, originY
		local rot = 0
		local elapsed = 0
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed = elapsed + dt
			vy = vy + gravity * dt
			px = px + vx * dt
			py = py + vy * dt
			rot = rot + spin * dt

			if not coin.Parent then
				conn:Disconnect()
				return
			end
			coin.Position = UDim2.fromOffset(px, py)
			coin.Rotation = rot

			-- Fade in/out : opaque pendant 70% de la vie, puis fade.
			local t = elapsed / lifetime
			if t > 0.7 then
				coin.ImageTransparency = (t - 0.7) / 0.3
			end
			if t >= 1 then
				conn:Disconnect()
				coin:Destroy()
			end
		end)
	end
end

function OfflineFrameController:Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[OfflineFrameController] MainGui introuvable")
		return
	end

	local frame = mainGui:WaitForChild("OfflineFrame", 30)
	if not frame then
		warn("[OfflineFrameController] OfflineFrame introuvable")
		return
	end

	local earned = frame:WaitForChild("Earned")
	local amountLabel = earned:WaitForChild("Amount")
	local infoLabel = frame:WaitForChild("Info")

	local buttons = frame:WaitForChild("Buttons")
	local claimBtn = buttons:WaitForChild("Claim")
	local upgradeBtn = buttons:WaitForChild("Upgrade")

	local topMain = frame:WaitForChild("Top"):WaitForChild("Main")
	local closeBtn = topMain:WaitForChild("Close")

	-- Pré-masque la frame tant qu'on n'a pas de valeurs valides.
	frame.Visible = false

	local showEvent = RemotesAPI.GetEvent("OfflineEarningsShowEvent")
	local claimEvent = RemotesAPI.GetEvent("OfflineEarningsClaimEvent")
	local upgradeEvent = RemotesAPI.GetEvent("OfflineEarningsUpgradeEvent")
	local dismissEvent = RemotesAPI.GetEvent("OfflineEarningsDismissEvent")
	local grantedEvent = RemotesAPI.GetEvent("OfflineEarningsGrantedEvent")

	-- État courant :
	--   offerActive : une offre est en cours côté serveur, boutons actifs.
	--   upgradePending : le joueur a cliqué sur Upgrade, on attend la réponse
	--                    du product Robux. Les autres boutons sont lockés pour
	--                    éviter un double-débit (Claim simple + x10).
	local offerActive = false
	local upgradePending = false

	claimBtn.Activated:Connect(function()
		if not offerActive or upgradePending then return end
		offerActive = false
		claimEvent:FireServer()
	end)

	upgradeBtn.Activated:Connect(function()
		if not offerActive or upgradePending then return end
		-- On ne ferme pas la frame et on NE consume PAS l'offre. Le prompt
		-- Robux peut être annulé par le joueur : `upgradePending` sera remis
		-- à false par PromptProductPurchaseFinished si l'achat n'est pas
		-- confirmé (ci-dessous), ou par le GrantedEvent en cas de succès.
		upgradePending = true
		upgradeEvent:FireServer()
	end)

	-- Quand le joueur ferme le prompt Robux (qu'il ait acheté ou non), Roblox
	-- fire PromptProductPurchaseFinished. Si purchaseSuccess == false c'est
	-- que le joueur a fermé sans acheter : on débloque les boutons pour qu'il
	-- puisse re-cliquer sur Upgrade ou fallback sur Claim / Close. Si true, le
	-- serveur va nous envoyer GrantedEvent qui fera l'anim et fermera la frame.
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchaseSuccess)
		if userId ~= player.UserId then return end
		if productId ~= OFFLINE_X10_PRODUCT_ID then return end
		if not purchaseSuccess then
			upgradePending = false
		end
	end)

	closeBtn.Activated:Connect(function()
		if not offerActive or upgradePending then return end
		offerActive = false
		-- Le serveur va aussi créditer le cash via dismissEvent et répondre par
		-- grantedEvent : on laisse le grantedEvent jouer l'anim cash burst et
		-- fermer la frame, pour que l'utilisateur voie bien sa récompense.
		dismissEvent:FireServer()
	end)

	showEvent.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if not payload.Valid then return end
		local amount = tonumber(payload.Amount) or 0
		if amount <= 0 then return end

		amountLabel.Text = "$" .. BrainrotInfo.FormatShort(amount)
		infoLabel.Text = string.format("OFFLINE EARNINGS (%s):", formatDuration(tonumber(payload.DurationSec) or 0))

		offerActive = true
		upgradePending = false
		showFrame(frame)
	end)

	-- Le serveur confirme qu'un montant a bien été crédité (claim simple OU x10).
	-- C'est ici qu'on joue l'anim cash + son, et qu'on ferme la frame.
	grantedEvent.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		local multi = tonumber(payload.Multiplier) or 1
		local grantedAmount = tonumber(payload.Amount) or 0

		-- Met à jour le texte affiché avant l'anim (utile pour le x10).
		if grantedAmount > 0 then
			amountLabel.Text = "$" .. BrainrotInfo.FormatShort(grantedAmount)
		end

		offerActive = false
		upgradePending = false

		playOneShot(multi > 1 and UPGRADE_SOUND_ID or CLAIM_SOUND_ID, multi > 1 and 1.0 or 0.8)
		playClaimBurst(frame, multi)

		-- Laisse l'anim se jouer un instant avant de fermer.
		task.delay(0.55, function()
			hideFrame(frame)
		end)
	end)

	print("[OfflineFrameController] Prêt")
end

return OfflineFrameController

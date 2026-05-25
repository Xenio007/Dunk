--[[
	AutoCollectController (Controller module)
	Gère StarterGui.MainGui.UIRight.AutoCollect :

	1. Click -> PromptGamePassPurchase (gamepassId GAMEPASSES.AUTO_COLLECT).
	2. Si le joueur possède déjà le gamepass, on affiche un overlay "Owned"
	   par-dessus le bouton et on ignore les clics (pas de prompt inutile).
	3. Écoute GamepassStateEvent pour basculer l'état live après un achat
	   réussi (le serveur push le flag AutoCollect = true).
	4. Vérifie aussi UserOwnsGamePassAsync au start (filet de sécurité si le
	   server-state event arrive avant que le client ait branché le listener).
--]]

local Players            = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local AutoCollectController = Loader.CreateController({
	Name = "AutoCollectController",
})

local AUTO_COLLECT_GAMEPASS_ID = (GamepassConfig.GAMEPASSES and GamepassConfig.GAMEPASSES.AUTO_COLLECT) or 1822301236
local OWNED_OVERLAY_NAME = "_OwnedOverlay"

-- Crée (une seule fois) un overlay "Owned" par-dessus le bouton. Visibilité
-- pilotée par setOwned().
local function ensureOwnedOverlay(button)
	local existing = button:FindFirstChild(OWNED_OVERLAY_NAME)
	if existing then return existing end

	local frame = Instance.new("Frame")
	frame.Name = OWNED_OVERLAY_NAME
	frame.Size = UDim2.fromScale(1, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.ZIndex = 50
	frame.Visible = false
	frame.Parent = button

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.9, 0.5)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Text = "OWNED"
	label.TextColor3 = Color3.fromRGB(140, 255, 140)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.ZIndex = 51
	label.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(10, 40, 10)
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	return frame
end

function AutoCollectController:Start()
	local player    = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local mainGui = playerGui:WaitForChild("MainGui", 30)
	if not mainGui then
		warn("[AutoCollectController] MainGui introuvable")
		return
	end

	local uiRight = mainGui:WaitForChild("UIRight", 15)
	if not uiRight then
		warn("[AutoCollectController] UIRight introuvable")
		return
	end

	local button = uiRight:WaitForChild("AutoCollect", 15)
	if not button or not button:IsA("ImageButton") then
		warn("[AutoCollectController] AutoCollect button introuvable")
		return
	end

	local overlay = ensureOwnedOverlay(button)
	local owned = false

	local function setOwned(state)
		owned = state == true
		-- Quand le joueur possède le gamepass, on cache complètement le bouton.
		-- L'overlay "OWNED" reste pour le cas où on voudrait re-afficher le bouton
		-- en mode "déjà possédé" mais on ne s'en sert plus ici.
		overlay.Visible = false
		button.Visible = not owned
	end

	-- 1) État initial via UserOwnsGamePassAsync (yield, dans une task).
	task.spawn(function()
		local ok, hasIt = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, AUTO_COLLECT_GAMEPASS_ID)
		end)
		if ok and hasIt then
			setOwned(true)
		end
	end)

	-- 2) Live update : le serveur push le flag AutoCollect quand l'achat se
	-- finalise (PromptGamePassPurchaseFinished côté server -> SetGamepass -> push).
	local gamepassStateEvent = RemotesAPI.GetEvent("GamepassStateEvent")
	gamepassStateEvent.OnClientEvent:Connect(function(flags)
		flags = flags or {}
		setOwned(flags.AutoCollect == true)
	end)

	-- 3) Filet de sécurité : si le push serveur tarde après un achat, on
	-- bascule l'overlay tout de suite côté client.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamepassId, wasPurchased)
		if plr ~= player then return end
		if gamepassId ~= AUTO_COLLECT_GAMEPASS_ID then return end
		if wasPurchased then
			setOwned(true)
		end
	end)

	-- 4) Click handler : prompt l'achat (sauf si déjà owned).
	local lastClick = 0
	button.MouseButton1Click:Connect(function()
		local now = os.clock()
		if now - lastClick < 0.5 then return end
		lastClick = now
		if owned then return end
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, AUTO_COLLECT_GAMEPASS_ID)
		end)
	end)

	print("[AutoCollectController] Prêt (gamepass id=" .. AUTO_COLLECT_GAMEPASS_ID .. ")")
end

return AutoCollectController

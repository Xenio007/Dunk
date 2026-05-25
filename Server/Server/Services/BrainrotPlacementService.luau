--[[
	BrainrotPlacementService
	Server-authoritative brainrot placement / removal / earnings collection.

	Features:
	  - Place a brainrot (currently equipped Tool) on a plot slot via ProximityPrompt.
	  - Remove a placed brainrot via ProximityPrompt (returns it to Backpack).
	  - Each occupied slot accumulates cash (brainrot CPS * elapsed) on its button.
	  - Walking on the button claims the accumulated cash (with CashMulti),
	    plays a "press" animation (client-side) and resets the counter.
	  - One brainrot per slot; invisible / disabled slots are rejected.
	  - Auto cleanup when the plot owner leaves.

	Performance:
	  - Zero per-frame server work. All display updates are reconstructed
	    locally by clients from a handful of attributes (CashPerSecond,
	    AccumStart, ClaimTick, AccumCap).
	  - Base slots AND dynamically added floor slots are handled uniformly
	    via a single DescendantAdded hook per plot.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local BrainrotLabel = require(ReplicatedStorage.Shared:WaitForChild("BrainrotLabel"))
local BrainrotUpgrade = require(ReplicatedStorage.Shared:WaitForChild("BrainrotUpgrade"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local BrainrotPlacementService = Loader.CreateService({
	Name = "BrainrotPlacementService",
})

-- ===== CONSTANTS =====

-- Attributes
local SLOT_OCCUPIED          = "SlotOccupied"
local SLOT_BRAINROT          = "BrainrotFullName"
local SLOT_LEVEL             = "BrainrotLevel"
local SLOT_KEY_ATTR          = "SlotLevelKey"
local BTN_CPS                = "CashPerSecond"
local BTN_ACCUM_START        = "AccumStart"
local BTN_ACCUM_CAP          = "AccumCap"
local BTN_CLAIM_TICK         = "ClaimTick"
local BTN_BASE_Y             = "BaseY"
local TOOL_LEVEL_ATTR        = "BrainrotLevel"

-- Gameplay
local ACCUM_CAP_SECONDS      = 8 * 3600        -- 8h cap per slot
local TOUCH_COOLDOWN         = 0.5             -- min delay between two claims on the same button
local PLACE_PROMPT_DISTANCE  = 8
local REMOVE_PROMPT_DISTANCE = 6

-- Folders
local BRAINROT_ROOT_NAME     = "Brainrots"
local PLACED_FOLDER_NAME     = "PlacedBrainrot"
local PLACED_MARKER_NAME     = "PlacedBrainrotRoot"
local CASH_LABEL_NAME        = "CashLabel"
local PLACE_PROMPT_NAME      = "PlaceBrainrotPrompt"
local REMOVE_PROMPT_NAME     = "RemoveBrainrotPrompt"

-- Steal feature
local STEAL_PROMPT_NAME       = "StealBrainrotPrompt"
local STEAL_PROMPT_DISTANCE   = 6
local PENDING_STEAL_TIMEOUT   = 180   -- secondes avant d'expirer un steal en attente

-- Hauteur (studs) au-dessus de la face top du slot à laquelle afficher les
-- ProximityPrompts (Take back / Steal). Ancrée au slot et non au brainrot,
-- pour que l'UI reste à hauteur raisonnable même pour des gros brainrots.
local PROMPT_ATTACHMENT_NAME  = "BrainrotPromptAttachment"
local PROMPT_ATTACHMENT_HEIGHT = 3

-- Robux Developer Product IDs pour voler un brainrot selon sa rarete.
local STEAL_PRODUCT_IDS = {
	Common    = 3588048899,
	Uncommon  = 3588049177,
	Rare      = 3583954533,
	Epic      = 3583954293,
	Legendary = 3583954437,
	Mythic    = 3585140873,
	Secret    = 3584369014,
	God       = 3584369161,
	OG        = 3584369318,
}

-- Developer Product pour up un brainrot de 3 niveaux (quand le joueur n'a
-- pas assez de cash, le sign d'upgrade propose l'achat Robux à la place).
local UPGRADE_ROBUX_PRODUCT_ID = 3588704736
local UPGRADE_ROBUX_LEVELS = 3

-- Developer Product pour up directement AU MAX : cliquer sur le petit panneau
-- carré à droite du sign principal lance cet achat. Après paiement, le
-- brainrot placé est porté au MAX_LEVEL du module BrainrotUpgrade.
local UPGRADE_MAX_ROBUX_PRODUCT_ID = 3588705463

-- Set pour reconnaître instantanément un productId de steal dans ProcessReceipt.
local STEAL_PRODUCT_ID_SET = {}
for _, id in pairs(STEAL_PRODUCT_IDS) do
	STEAL_PRODUCT_ID_SET[id] = true
end

-- Upgrade sign
local UPGRADE_SIGN_NAME      = "UpgradeSign"
local UPGRADE_GUI_NAME       = "UpgradeGUI"
local UPGRADE_SIGN_FOLDER    = "UpgradeSigns"
local UPGRADE_SIGN_HEIGHT    = -0.6    -- hauteur au-dessus de la top-face du slot
local UPGRADE_SIGN_ROTATION  = 180  -- Rotation en degrés pour faire un demi-tour
local UPGRADE_SIGN_TILT      = 15   -- Inclinaison en degrés (essayez entre 10 et 30)
local UPGRADE_SIGN_OFFSET_Z  = 0.8  -- Déplacement sur l'axe Z (positif pour reculer, négatif pour avancer)

-- ===== INTERNAL STATE =====

local plotsFolder
local brainrotsFolder
local DataService
local upgradeSignTemplate    -- Part (template capturé au :Init)
local buyUpgradeEvent        -- RemoteEvent
local buyMaxUpgradeEvent     -- RemoteEvent (panneau MAX en Robux)
local stealNotifyEvent       -- RemoteEvent (serveur -> victime)

-- [thiefUserId] = { slotPart, ownerId, fullName, level, productId, expiresAt }
-- Un seul steal en attente à la fois par joueur. Écrasé si nouvelle tentative.
local pendingSteals = {}

-- [playerUserId] = { slotPart, expiresAt }
-- Un seul upgrade Robux en attente à la fois par joueur. Utilisé par
-- HandlePurchase pour savoir sur quel slot appliquer les 3 niveaux.
local pendingUpgrades = {}
-- [playerUserId] = { slotPart, expiresAt }
-- Même principe mais pour le produit MAX (panneau carré droite).
local pendingMaxUpgrades = {}
local PENDING_UPGRADE_TIMEOUT = 180

-- D3 : rate limit anti-spam sur les remotes d'upgrade. Sans ça un exploiteur
-- peut spammer BuyUpgrade/BuyMaxUpgrade FireServer à 60Hz pour saturer le
-- serveur (walk descendants du plot à chaque appel + cascade de
-- PromptProductPurchase qui pollue les pendings et race avec le steal).
local lastUpgradeRequestAt = {} -- [userId] = os.clock()
local UPGRADE_REQUEST_COOLDOWN = 0.4

local function rateLimitUpgrade(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	local now = os.clock()
	local last = lastUpgradeRequestAt[player.UserId] or 0
	if now - last < UPGRADE_REQUEST_COOLDOWN then return false end
	lastUpgradeRequestAt[player.UserId] = now
	return true
end

-- buttonPart -> os.clock() of last successful claim. Prevents spam claims.
local lastTouchAt = {}

-- plotModel -> { connections = { RBXScriptConnection, ... } }
local plotState = {}

-- Forward declaration : refreshUpgradeSign est défini après les helpers Upgrade,
-- mais on l'appelle déjà depuis placeBrainrot / RemoveBrainrot / resetPlot.
local refreshUpgradeSign

-- slotPart -> slotLevelKey (used to persist a placed brainrot). The key is a
-- stable identifier independent from the Part's identity : floorNumber * 100
-- + slotNumber. slotLevelKey = 1 is the base slot (Slot1 on Floor1, which has
-- no concept of "bought upgrade" -- always owned).
local function getSlotKey(slotPart)
	local slotsFolder = slotPart.Parent
	if not slotsFolder then return nil end
	local floorModel = slotsFolder.Parent
	if not floorModel then return nil end
	local floorNum = tonumber(string.match(floorModel.Name, "Floor(%d+)"))
	local slotNum = tonumber(string.match(slotPart.Name, "Slot(%d+)"))
	if not floorNum or not slotNum then
		-- Cas du slot statique de base (non inséré dans un Floor dynamique).
		-- On le traite comme (floor=0, slot=baseIndex) pour garantir une clé
		-- unique et stable.
		slotNum = tonumber(string.match(slotPart.Name, "(%d+)")) or 0
		return slotNum
	end
	return floorNum * 100 + slotNum
end

-- ===== UTILS =====

local function isSlotUsable(slotPart)
	-- A slot is usable if it is an actual visible part (opaque enough).
	-- GameService hides/removes slots that aren't unlocked; we respect that.
	return slotPart and slotPart:IsA("BasePart") and slotPart.Transparency < 0.95
end

local function getPlayerPlot(player)
	local plotNumVal = player:FindFirstChild("PlotNumber")
	if not plotNumVal then return nil, nil end
	local plotModel = plotsFolder:FindFirstChild("Plot" .. plotNumVal.Value)
	return plotModel, plotNumVal.Value
end

-- Given a slot Part, return its paired button Part (same sibling structure).
local function getButtonForSlot(slotPart)
	local slotsFolder = slotPart.Parent
	if not slotsFolder then return nil end
	local parent = slotsFolder.Parent
	if not parent then return nil end
	local buttons = parent:FindFirstChild("Buttons")
	if not buttons then return nil end
	local btn = buttons:FindFirstChild(slotPart.Name)
	if btn and btn:IsA("BasePart") then
		return btn
	end
	return nil
end

-- Given a button Part, return its paired slot Part.
local function getSlotForButton(buttonPart)
	local buttonsFolder = buttonPart.Parent
	if not buttonsFolder then return nil end
	local parent = buttonsFolder.Parent
	if not parent then return nil end
	local slots = parent:FindFirstChild("Slots")
	if not slots then return nil end
	local slotPart = slots:FindFirstChild(buttonPart.Name)
	if slotPart and slotPart:IsA("BasePart") then
		return slotPart
	end
	return nil
end

local function findTemplateByFullName(fullName)
	for _, rarity in ipairs(brainrotsFolder:GetChildren()) do
		if rarity:IsA("Folder") then
			local m = rarity:FindFirstChild(fullName)
			if m and m:IsA("Model") then
				return m
			end
		end
	end
	return nil
end

local function findEquippedBrainrotTool(player)
	local char = player.Character
	if not char then return nil end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then return nil end
	if not BrainrotInfo.GetInfo(tool.Name) then return nil end
	return tool
end

local function findAnyBrainrotTool(player)
	-- Character first (equipped), then backpack.
	local equipped = findEquippedBrainrotTool(player)
	if equipped then return equipped end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then return nil end
	for _, t in ipairs(backpack:GetChildren()) do
		if t:IsA("Tool") and BrainrotInfo.GetInfo(t.Name) then
			return t
		end
	end
	return nil
end

-- Multiplicateur de cash du joueur (CashMulti + gamepass CashX2 + VIP). 1 par défaut.
local function getCashMulti(player)
	local mult = 1
	local v = player and player:FindFirstChild("CashMulti")
	if v and v:IsA("ValueBase") then
		mult = tonumber(v.Value) or 1
		if mult < 1 then mult = 1 end
	end
	-- Bonus gamepass CashX2 : double le multiplicateur.
	local gp = _G._GamepassService
	if gp and gp.GetCashMulti then
		mult = mult * gp:GetCashMulti(player)
	else
		-- Fallback direct via DataService si GamepassService pas encore prêt.
		if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "CashX2") then
			mult = mult * GamepassConfig.CASH_X2_MULT
		end
	end
	-- Bonus gamepass VIP : +1.5x Cash. Se combine multiplicativement avec CashX2.
	if gp and gp.GetVipCashMulti then
		mult = mult * gp:GetVipCashMulti(player)
	elseif DataService and DataService.HasGamepass and DataService:HasGamepass(player, "VIP") then
		mult = mult * GamepassConfig.VIP_CASH_MULT
	end
	return mult
end

-- ===== LABEL & PROMPT CREATION =====

local CASH_LABEL_FONT = Font.new(
	"rbxasset://fonts/families/Montserrat.json",
	Enum.FontWeight.ExtraBold,
	Enum.FontStyle.Normal
)

local function createCashLabel(buttonPart)
	local existing = buttonPart:FindFirstChild(CASH_LABEL_NAME)
	if existing then return existing end

	-- Flat on the button's Top face (no levitation): a SurfaceGui renders the
	-- label directly on the part's surface.
	local gui = Instance.new("SurfaceGui")
	gui.Name = CASH_LABEL_NAME
	gui.Face = Enum.NormalId.Top
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 64
	gui.ClipsDescendants = false
	gui.Enabled = false

	local tl = Instance.new("TextLabel")
	tl.Name = "Text"
	tl.BackgroundTransparency = 1
	tl.AnchorPoint = Vector2.new(0.5, 0.5)
	tl.Position = UDim2.fromScale(0.5, 0.5)
	tl.Size = UDim2.fromScale(0.9, 0.75)
	tl.FontFace = CASH_LABEL_FONT
	tl.TextScaled = true
	tl.TextColor3 = Color3.fromRGB(180, 255, 140)
	tl.TextXAlignment = Enum.TextXAlignment.Center
	tl.TextYAlignment = Enum.TextYAlignment.Center
	tl.RichText = false
	tl.Text = "$0"

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(10, 40, 10)
	stroke.Thickness = 3.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = tl

	tl.Parent = gui
	gui.Parent = buttonPart
	return gui
end

local function setCashLabelEnabled(buttonPart, enabled)
	local gui = buttonPart:FindFirstChild(CASH_LABEL_NAME)
	if gui then gui.Enabled = enabled end
end

local function resetButtonAttributes(buttonPart)
	buttonPart:SetAttribute(BTN_CPS, 0)
	buttonPart:SetAttribute(BTN_ACCUM_START, 0)
end

-- ===== CORE ACTIONS =====

local function placeBrainrot(player, slotPart, buttonPart, fullName, template, info, level)
	level = BrainrotUpgrade.ClampLevel(level or 1)
	-- Brainrots exclusifs : pas d'upgrade possible, on les force à afficher la
	-- taille visuelle du niveau MAX directement (impression de brainrot « plein »).
	local isExclusive = info and info.ExclusivePercent ~= nil
	local visualLevel = isExclusive and BrainrotUpgrade.MAX_LEVEL or level
	local clone = template:Clone()

	-- Find a primary part (prefer existing PrimaryPart).
	local primary = clone.PrimaryPart
	if not primary then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then primary = d break end
		end
	end
	if not primary then
		clone:Destroy()
		return false
	end
	clone.PrimaryPart = primary

	-- Anchor every part, disable collisions: the brainrot is static decoration.
	-- CanQuery = false : pour que le brainrot ne bloque PAS les clics sur les
	-- UpgradeSigns derrière lui (raycast de souris passe à travers).
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end

	-- Apply the level-based scale BEFORE any positioning so lift / rotation math
	-- operates on the final bounding box.
	-- Le template a souvent un scale natif ≠ 1 (les artistes dimensionnent chaque
	-- modèle manuellement). `Model:ScaleTo` est ABSOLU, donc pour conserver la
	-- taille visuelle au niveau 1 on stocke ce scale natif et on multiplie par
	-- le facteur d'upgrade. On garde cette base sur le holder pour que les
	-- futurs upgrades puissent refaire le calcul sans dériver.
	local baseScale = clone:GetScale()
	local scaleFactor = BrainrotUpgrade.GetScaleFactor(visualLevel)
	if scaleFactor ~= 1 then
		clone:ScaleTo(baseScale * scaleFactor)
	end

	-- Keep the template's native rotation (artists author each brainrot upright;
	-- forcing a fresh lookAt tips meshes whose visual up-axis is not the pivot's
	-- +Y — the Trippi-style fish is a good example). We ONLY rotate around the
	-- world vertical axis so the brainrot points at its paired button.
	local pivotCF = clone:GetPivot()
	local slotCenter = slotPart.Position

	-- Move the pivot to be right above the slot horizontally. Lift happens after
	-- the yaw so the bbox is measured in the final orientation.
	local xzOffset = Vector3.new(slotCenter.X - pivotCF.X, 0, slotCenter.Z - pivotCF.Z)
	clone:PivotTo(pivotCF + xzOffset)

	-- Determine the template's "native horizontal forward" vector. Several
	-- candidates are tested and we pick whichever has the largest magnitude in
	-- the XZ plane (some meshes have a vertical LookVector, which would
	-- otherwise give us no yaw signal).
	local pv = clone:GetPivot()
	local candidates = {
		{ vec =  pv.LookVector,  offset = 0 },
		{ vec = -pv.LookVector,  offset = math.pi },
		{ vec =  pv.RightVector, offset = -math.pi * 0.5 },
		{ vec = -pv.RightVector, offset =  math.pi * 0.5 },
	}
	local best, bestMag = candidates[1], -1
	for _, c in ipairs(candidates) do
		local flat = Vector3.new(c.vec.X, 0, c.vec.Z)
		local m = flat.Magnitude
		if m > bestMag then best, bestMag = c, m end
	end

	if bestMag > 1e-3 then
		local curFlat = Vector3.new(best.vec.X, 0, best.vec.Z).Unit
		local targetDir = buttonPart.Position - slotCenter
		local targetFlat = Vector3.new(targetDir.X, 0, targetDir.Z)
		if targetFlat.Magnitude > 1e-3 then
			targetFlat = targetFlat.Unit
			-- Yaw from curFlat to targetFlat (signed, around +Y).
			-- +math.pi flips 180° because the template's authored forward axis
			-- faces away from the button in our scene layout.
			local yaw = math.atan2(
				curFlat.Z * targetFlat.X - curFlat.X * targetFlat.Z,
				curFlat.X * targetFlat.X + curFlat.Z * targetFlat.Z
			) - best.offset + math.pi
			if math.abs(yaw) > 1e-4 then
				local rot = CFrame.new(slotCenter) * CFrame.Angles(0, yaw, 0) * CFrame.new(-slotCenter)
				clone:PivotTo(rot * clone:GetPivot())
			end
		end
	end

	-- Feet on slot: lift the model so its world-space lowest point lands on
	-- the slot's top face.
	local minY = math.huge
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			local halfY = d.Size.Y * 0.5
			local y = d.Position.Y - halfY
			if y < minY then minY = y end
		end
	end
	local slotTopY = slotPart.Position.Y + slotPart.Size.Y * 0.5
	local liftY = (slotTopY - minY) + 0.02
	clone:PivotTo(clone:GetPivot() + Vector3.new(0, liftY, 0))

	-- Wrap in a named folder under the slot for clean lookup / removal.
	local holder = Instance.new("Model")
	holder.Name = PLACED_MARKER_NAME
	holder:SetAttribute("OwnerUserId", player.UserId)
	holder:SetAttribute("FullName", fullName)
	holder:SetAttribute("Level", level)
	holder:SetAttribute("BaseScale", baseScale)
	clone.Parent = holder
	holder.PrimaryPart = primary
	holder.Parent = slotPart

	-- Joue l'animation Idle si le brainrot en a une. Les brainrots sont des
	-- meshes skinnés (bones) : ils s'animent même avec toutes les parts
	-- ancrées. On cherche `AnimationController/Anims/Idle` dans le clone ;
	-- no-op si l'un des trois manque.
	do
		local animController = clone:FindFirstChildOfClass("AnimationController")
			or clone:FindFirstChildOfClass("Humanoid")
		local animsFolder = clone:FindFirstChild("Anims")
		local idleAnim = animsFolder and animsFolder:FindFirstChild("Idle")
		if animController and idleAnim and idleAnim:IsA("Animation") then
			local animator = animController:FindFirstChildOfClass("Animator")
			if not animator then
				animator = Instance.new("Animator")
				animator.Parent = animController
			end
			local ok, track = pcall(function()
				return animator:LoadAnimation(idleAnim)
			end)
			if ok and track then
				track.Looped = true
				track.Priority = Enum.AnimationPriority.Idle
				track:Play()
			end
		end
	end

	-- Info billboard on the brainrot itself.
	local label = BrainrotLabel.CreateFromName(primary, fullName, level)

	-- Note : pour les brainrots exclusifs, on appelle BrainrotLabel.UpdateLevelAndCps
	-- avec le fullName après le calcul de leur CPS réel (fait par
	-- recomputePlotExclusives) pour afficher "X%% / s" au lieu de "$X / s".

	-- Scale le label pour matcher l'effet d'un upgrade en session.
	-- En session, chaque upgrade fait un `clone:ScaleTo(...)` qui multiplie aussi
	-- le BillboardGui (Size + StudsOffsetWorldSpace). Au rejoin on recrée le
	-- label from scratch avec ses valeurs par défaut, donc il se retrouve plus
	-- bas que ce à quoi le joueur est habitué. On applique le même scale ici
	-- pour que la position visible soit identique dans les deux cas.
	if label and scaleFactor ~= 1 then
		label.Size = UDim2.fromScale(
			label.Size.X.Scale * scaleFactor,
			label.Size.Y.Scale * scaleFactor
		)
		label.StudsOffsetWorldSpace = label.StudsOffsetWorldSpace * scaleFactor
	end

	-- Expose l'owner & le fullName sur la primary part, pour que le client
	-- puisse filtrer la visibilité des prompts (Remove vs Steal) sans avoir
	-- à remonter jusqu'au holder.
	primary:SetAttribute("OwnerUserId", player.UserId)
	primary:SetAttribute("FullName", fullName)
	primary:SetAttribute("RarityType", info and info.RarityType or "")

	-- Attachment dédiée à l'UI des ProximityPrompts : placée juste au-dessus de
	-- la face top du slot, elle assure que l'UI apparaît toujours à une hauteur
	-- raisonnable pour le joueur, même si le brainrot est immense. Parenter le
	-- prompt à une Attachment plutôt qu'au primary déplace uniquement l'UI ; le
	-- test de distance reste basé sur la position monde de l'Attachment.
	local promptAttachment = Instance.new("Attachment")
	promptAttachment.Name = PROMPT_ATTACHMENT_NAME
	promptAttachment.Parent = primary
	promptAttachment.WorldPosition = Vector3.new(
		slotPart.Position.X,
		slotTopY + PROMPT_ATTACHMENT_HEIGHT,
		slotPart.Position.Z
	)

	-- Remove prompt on the model's primary part (owner only -- filtré côté client).
	local removePrompt = Instance.new("ProximityPrompt")
	removePrompt.Name = REMOVE_PROMPT_NAME
	removePrompt.ActionText = "Take back"
	removePrompt.ObjectText = fullName
	removePrompt.HoldDuration = 0.25
	removePrompt.KeyboardKeyCode = Enum.KeyCode.E
	removePrompt.MaxActivationDistance = REMOVE_PROMPT_DISTANCE
	removePrompt.RequiresLineOfSight = false
	removePrompt.Parent = promptAttachment

	removePrompt.Triggered:Connect(function(triggerPlayer)
		BrainrotPlacementService:RemoveBrainrot(triggerPlayer, slotPart)
	end)

	-- Steal prompt on the model's primary part (non-owners only -- filtré côté
	-- client). Déclenche directement PromptProductPurchase en Robux.
	local stealProductId = info and STEAL_PRODUCT_IDS[info.RarityType]
	if stealProductId then
		local stealPrompt = Instance.new("ProximityPrompt")
		stealPrompt.Name = STEAL_PROMPT_NAME
		stealPrompt.ActionText = "Steal"
		stealPrompt.ObjectText = fullName
		stealPrompt.HoldDuration = 0.5
		stealPrompt.KeyboardKeyCode = Enum.KeyCode.E
		stealPrompt.MaxActivationDistance = STEAL_PROMPT_DISTANCE
		stealPrompt.RequiresLineOfSight = false
		stealPrompt.Parent = promptAttachment

		stealPrompt.Triggered:Connect(function(triggerPlayer)
			BrainrotPlacementService:PromptSteal(triggerPlayer, slotPart)
		end)
	end

	-- Slot state.
	slotPart:SetAttribute(SLOT_OCCUPIED, true)
	slotPart:SetAttribute(SLOT_BRAINROT, fullName)
	slotPart:SetAttribute(SLOT_LEVEL, level)

	-- Button state (enable accumulation).
	-- Pour un brainrot exclusif, le CPS est recalculé dynamiquement par
	-- recomputePlotExclusives en fonction du CPS total de la base. On pose
	-- 0 ici en attendant que le caller appelle la recomputation.
	local cashMulti = getCashMulti(player)
	local cps
	if isExclusive then
		cps = 0
	else
		cps = math.floor(BrainrotUpgrade.GetCps(info.CashPerSecond, level) * cashMulti + 0.5)
	end
	buttonPart:SetAttribute(BTN_CPS, cps)
	buttonPart:SetAttribute(BTN_ACCUM_START, Workspace:GetServerTimeNow())
	setCashLabelEnabled(buttonPart, true)

	-- Disable the place prompt on the slot while occupied.
	-- Visibility is client-owned; we only flip the attribute here and let the
	-- client decide whether to re-enable on its side.
	local placePrompt = slotPart:FindFirstChild(PLACE_PROMPT_NAME)
	if placePrompt then placePrompt.Enabled = false end

	return true
end

-- Recalcule le CPS de tous les brainrots EXCLUSIFS placés sur le plot d'un
-- joueur. Le CPS d'un exclusif = (somme des CPS des brainrots NON exclusifs
-- placés sur le plot) * (pourcentage de l'exclusif / 100). Appelé chaque fois
-- que la composition du plot change (placement, retrait, upgrade) ou que le
-- CashMulti du joueur évolue.
-- D7 : version optimisée. L'ancien code parcourait `plot:GetDescendants()` ce
-- qui peut atteindre 2000+ items quand le plot est plein de brainrots
-- (chaque brainrot a ~80 BaseParts internes). À chaque place/upgrade/claim,
-- on faisait un walk complet -> stutter visible avec 50 joueurs en parallèle.
-- On itere maintenant uniquement les Folders "Slots" qui contiennent <= 21 parts.
local function recomputePlotExclusives(player)
	local plot = getPlayerPlot(player)
	if not plot then return end

	local cashMulti = getCashMulti(player)

	local baseTotal = 0
	local exclusiveSlots = {}

	-- Collecte les Folders "Slots" du plot (statiques + dynamiques par Floor).
	local slotsContainers = {}
	local floorsFolder = plot:FindFirstChild("Floors")
	if floorsFolder then
		for _, floorModel in ipairs(floorsFolder:GetChildren()) do
			local slotsFolder = floorModel:FindFirstChild("Slots")
			if slotsFolder then table.insert(slotsContainers, slotsFolder) end
		end
	end
	local rootSlots = plot:FindFirstChild("Slots")
	if rootSlots then table.insert(slotsContainers, rootSlots) end

	for _, container in ipairs(slotsContainers) do
		for _, desc in ipairs(container:GetChildren()) do
			if desc:IsA("BasePart") and desc:GetAttribute(SLOT_OCCUPIED) then
				local fullName = desc:GetAttribute(SLOT_BRAINROT)
				if type(fullName) == "string" and fullName ~= "" then
					local info = BrainrotInfo.GetInfo(fullName)
					if info then
						if info.ExclusivePercent then
							table.insert(exclusiveSlots, {
								slot = desc,
								info = info,
								fullName = fullName,
							})
						else
							local level = tonumber(desc:GetAttribute(SLOT_LEVEL)) or 1
							local cps = BrainrotUpgrade.GetCps(info.CashPerSecond, level) * cashMulti
							baseTotal = baseTotal + cps
						end
					end
				end
			end
		end
	end

	-- 2) Met à jour le CPS de chaque exclusif et son label.
	for _, entry in ipairs(exclusiveSlots) do
		local slot = entry.slot
		local info = entry.info
		local button = getButtonForSlot(slot)
		if button then
			local newCps = math.floor(baseTotal * (info.ExclusivePercent / 100) + 0.5)
			local oldCps = tonumber(button:GetAttribute(BTN_CPS)) or 0
			if oldCps ~= newCps then
				button:SetAttribute(BTN_CPS, newCps)
			end
		end

		-- Le label de l'exclusif affiche "X%% / s" peu importe son CPS réel.
		local holder = slot:FindFirstChild(PLACED_MARKER_NAME)
		if holder then
			local model = holder:FindFirstChildWhichIsA("Model")
			local primary = model and model.PrimaryPart
			if primary then
				local level = tonumber(slot:GetAttribute(SLOT_LEVEL)) or 1
				BrainrotLabel.UpdateLevelAndCps(primary, level, 0, info.ExclusivePercent)
			end
		end
	end

	-- Le CPS total du joueur a potentiellement changé -> notifie le leaderboard.
	local okLb, lb = pcall(Loader.GetService, "CashLeaderboardService")
	if okLb and lb and lb.NotifyCpsChanged then
		pcall(function() lb:NotifyCpsChanged(player) end)
	end
end

local function removePlacedBrainrot(slotPart, buttonPart)
	local holder = slotPart:FindFirstChild(PLACED_MARKER_NAME)
	if holder then holder:Destroy() end

	slotPart:SetAttribute(SLOT_OCCUPIED, false)
	slotPart:SetAttribute(SLOT_BRAINROT, "")
	slotPart:SetAttribute(SLOT_LEVEL, 0)

	if buttonPart then
		resetButtonAttributes(buttonPart)
		setCashLabelEnabled(buttonPart, false)
	end

	local placePrompt = slotPart:FindFirstChild(PLACE_PROMPT_NAME)
	if placePrompt then placePrompt.Enabled = false end -- client will re-enable if it owns a brainrot tool

	-- Force un refresh de la visibilité des signs (principal + MAX) pour que
	-- le MAX soit caché quand le slot redevient vide.
	if refreshUpgradeSign then
		refreshUpgradeSign(slotPart)
	end
end

-- ===== UPGRADE SIGNS =====

-- Position idéale pour le sign d'un slot : légèrement en avant de la face du
-- slot qui donne sur le bouton, bien en hauteur. Comme ça le joueur qui arrive
-- par le bouton voit le panneau de FACE entre lui et le brainrot.
local function computeSignCFrame(slotPart, buttonPart)
	local slotPos = slotPart.Position
	local topY = slotPos.Y + slotPart.Size.Y * 0.5

	-- Direction du slot vers le bouton (projetée sur le plan XZ).
	local towardsButton
	if buttonPart then
		local delta = buttonPart.Position - slotPos
		towardsButton = Vector3.new(delta.X, 0, delta.Z)
		if towardsButton.Magnitude < 1e-3 then
			towardsButton = Vector3.new(0, 0, 1)
		end
		towardsButton = towardsButton.Unit
	else
		towardsButton = Vector3.new(0, 0, 1)
	end

	-- Le sign se positionne CÔTÉ BOUTON, juste au bord du slot, flottant bien
	-- au-dessus. Sa face avant regarde vers le bouton, donc le joueur qui monte
	-- sur le bouton voit le panneau de face.
	local halfSlot = math.min(slotPart.Size.X, slotPart.Size.Z) * 0.5
	local signHalf = 0.125 -- Size.Z / 2 du sign (0.25)
	local offset = towardsButton * (halfSlot + signHalf + 0.1)
	local pos = Vector3.new(
		slotPos.X + offset.X,
		topY + UPGRADE_SIGN_HEIGHT,
		slotPos.Z + offset.Z
	)

	-- CFrame.lookAt oriente le LookVector (= -Z local) vers `target`. Pour que
	-- la face Front (+Z local) pointe vers le bouton, on cible un point derrière
	-- le panneau (dans la direction opposée au bouton).
	local lookTarget = pos - towardsButton
	local baseCFrame = CFrame.lookAt(pos, lookTarget, Vector3.new(0, 1, 0))

	-- Application du décalage en Z, puis de la rotation de 180° ET de l'inclinaison (Tilt)
	return baseCFrame 
		* CFrame.new(0, 0, UPGRADE_SIGN_OFFSET_Z)
		* CFrame.Angles(0, math.rad(UPGRADE_SIGN_ROTATION), 0)
		* CFrame.Angles(math.rad(UPGRADE_SIGN_TILT), 0, 0)
end

local function getOrCreateSignContainer(plotModel)
	local folder = plotModel:FindFirstChild(UPGRADE_SIGN_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = UPGRADE_SIGN_FOLDER
		folder.Parent = plotModel
	end
	return folder
end

local function signNameForSlot(slotPart)
	local key = getSlotKey(slotPart)
	return "Sign_" .. tostring(key or slotPart:GetDebugId())
end

-- Met à jour les textes de la GUI d'un sign pour refléter l'état courant du slot.
local function updateSignDisplay(sign, slotPart)
	local gui = sign:FindFirstChild(UPGRADE_GUI_NAME)
	if not gui then return end

	local occupied = slotPart:GetAttribute(SLOT_OCCUPIED) == true
	local level = tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 0
	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)

	local button = gui:FindFirstChild("Button")
	if not button then return end

	local priceLabel = button:FindFirstChild("PriceLabel")
	local levelLabel = button:FindFirstChild("LevelLabel")

	if not occupied or type(fullName) ~= "string" or fullName == "" then
		if priceLabel then priceLabel.Text = "" end
		if levelLabel then levelLabel.Text = "Place a brainrot" end
		return
	end

	-- Brainrot exclusif : pas d'upgrade possible. On affiche un message clair.
	if BrainrotInfo.IsExclusive(fullName) then
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

-- Met à jour la visibilité du sign pour l'état courant. Sur occupié -> visible,
-- sinon -> invisible côté GUI ET côté Part (transparent). Le sign disparait
-- donc complètement quand le slot est vide.
local function applySignVisibility(sign, slotPart)
	local gui = sign:FindFirstChild(UPGRADE_GUI_NAME)
	local occupied = slotPart:GetAttribute(SLOT_OCCUPIED) == true
	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	local isExclusive = type(fullName) == "string" and BrainrotInfo.IsExclusive(fullName)
	-- Sign caché si le slot est vide OU si le brainrot est exclusif (Robux only,
	-- pas d'upgrade possible).
	local visible = occupied and not isExclusive
	if gui then
		gui.Enabled = visible
	end
	-- La part est invisible par défaut (Transparency=1) et devient opaque quand
	-- le slot est occupé par un brainrot upgradable.
	if sign:IsA("BasePart") then
		sign.Transparency = visible and 0 or 1
	end
end

function refreshUpgradeSign(slotPart)
	local sign = slotPart:FindFirstChild("_UpgradeSignRef")
	if not sign or not sign.Value then return end
	local signInst = sign.Value
	updateSignDisplay(signInst, slotPart)
	applySignVisibility(signInst, slotPart)

	-- Le sign MAX est visible UNIQUEMENT quand le slot est occupé ET que le
	-- brainrot n'est pas déjà au MAX_LEVEL ET qu'il n'est pas exclusif.
	-- Slot vide -> caché.
	local maxRef = slotPart:FindFirstChild("_MaxUpgradeSignRef")
	if maxRef and maxRef.Value then
		local maxSign = maxRef.Value
		local level = tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 0
		local occupied = slotPart:GetAttribute(SLOT_OCCUPIED) == true
		local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
		local isExclusive = type(fullName) == "string" and BrainrotInfo.IsExclusive(fullName)
		local visible = occupied and not BrainrotUpgrade.IsMax(level) and not isExclusive
		local gui = maxSign:FindFirstChildOfClass("SurfaceGui")
		if gui then gui.Enabled = visible end
		if maxSign:IsA("BasePart") then
			-- Part opaque noire visible, ou complètement cachée.
			maxSign.Transparency = visible and 0 or 1
		end
	end
end

-- Crée (ou réutilise) un sign MAX sur la GAUCHE du sign principal, même taille,
-- avec un fond dégradé violet/mauve (sans coins arrondis), un label "Upgrade Max"
-- et une animation de survol (scale + son) gérée côté client.
-- Un clic lance le product UPGRADE_MAX_ROBUX_PRODUCT_ID qui met le brainrot
-- au MAX_LEVEL après paiement Robux.
local function ensureMaxUpgradeSignForSlot(plotModel, slotPart, mainSign)
	if not slotPart:IsA("BasePart") then return end
	if not slotPart.Parent or slotPart.Parent.Name ~= "Slots" then return end
	if not mainSign or not mainSign:IsA("BasePart") then return end

	local container = getOrCreateSignContainer(plotModel)
	local name = "MaxSign_" .. tostring(getSlotKey(slotPart) or slotPart:GetDebugId())
	local maxSign = container:FindFirstChild(name)
	local mainSize = mainSign.Size

	if not maxSign then
		maxSign = Instance.new("Part")
		maxSign.Name = name
		-- Taille carrée (X=Y=hauteur du sign principal, Z=épaisseur du sign).
		local squareSide = mainSize.Y
		maxSign.Size = Vector3.new(squareSide, squareSide, mainSize.Z)
		maxSign.Anchored = true
		maxSign.CanCollide = false
		maxSign.CanTouch = false
		maxSign.CanQuery = true
		-- Part noire opaque (contour noir visible derrière le dégradé).
		maxSign.Transparency = 0
		maxSign.Material = Enum.Material.SmoothPlastic
		maxSign.Color = Color3.fromRGB(0, 0, 0)
		maxSign.Parent = container

		-- SurfaceGui plein écran, face Front.
		local gui = Instance.new("SurfaceGui")
		gui.Name = "MaxUpgradeGUI"
		gui.Face = Enum.NormalId.Front
		gui.AlwaysOnTop = false
		gui.LightInfluence = 0
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 100
		gui.ClipsDescendants = false
		gui.Enabled = false
		gui.Parent = maxSign

		-- Wrapper qui porte le UIScale (animé au survol côté client).
		local wrapper = Instance.new("Frame")
		wrapper.Name = "Wrapper"
		wrapper.AnchorPoint = Vector2.new(0.5, 0.5)
		wrapper.Position = UDim2.fromScale(0.5, 0.5)
		wrapper.Size = UDim2.fromScale(1, 1)
		wrapper.BackgroundTransparency = 1
		wrapper.Parent = gui

		local uiScale = Instance.new("UIScale")
		uiScale.Name = "HoverScale"
		uiScale.Scale = 1
		uiScale.Parent = wrapper

		-- Fond dégradé violet/mauve (vertical, de bas en haut). PAS de UICorner.
		local bg = Instance.new("Frame")
		bg.Name = "BG"
		bg.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		bg.BackgroundTransparency = 0
		bg.BorderSizePixel = 0
		bg.Size = UDim2.fromScale(1, 1)
		bg.Parent = wrapper

		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90 -- 90° = haut vers bas ; on inverse la ColorSequence pour bas->haut
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.0, Color3.fromRGB(90, 40, 170)),   -- haut : violet profond
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(140, 70, 220)),  -- milieu : mauve
			ColorSequenceKeypoint.new(1.0, Color3.fromRGB(200, 140, 255)), -- bas : mauve clair
		})
		gradient.Parent = bg

		-- Bouton cliquable plein cadre.
		local button = Instance.new("TextButton")
		button.Name = "Button"
		button.BackgroundTransparency = 1
		button.Size = UDim2.fromScale(1, 1)
		button.Text = ""
		button.AutoButtonColor = false
		button.ZIndex = 3
		button.Parent = bg

		-- Contour mauve foncé sur le bouton (UIStroke sur le BG).
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(50, 15, 100)
		stroke.Thickness = 5
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = bg

		local label = Instance.new("TextLabel")
		label.Name = "MaxLabel"
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(0.92, 0.7)
		label.Text = "Upgrade Max"
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.fromRGB(50, 10, 90)
		label.ZIndex = 2
		label.Parent = button
	end

	-- Taille CARRÉE : X = Y = hauteur du sign principal (pour que le carré
	-- s'aligne visuellement avec le sign principal, même hauteur).
	local squareSide = mainSize.Y
	local squareSize = Vector3.new(squareSide, squareSide, mainSize.Z)
	maxSign.Size = squareSize

	-- Positionne le sign MAX à GAUCHE du sign principal, même orientation.
	local mainCF = mainSign.CFrame
	local offsetX = -(mainSize.X * 0.5 + squareSide * 0.5 + 0.15)
	maxSign.CFrame = mainCF * CFrame.new(offsetX, 0, 0)

	-- Référence inverse sur le slot.
	local ref = slotPart:FindFirstChild("_MaxUpgradeSignRef")
	if not ref then
		ref = Instance.new("ObjectValue")
		ref.Name = "_MaxUpgradeSignRef"
		ref.Parent = slotPart
	end
	ref.Value = maxSign

	-- Référence du slot sur le sign (pour que le client retrouve le slot
	-- au clic depuis n'importe quel state, même si la closure est stale).
	local slotRef = maxSign:FindFirstChild("_SlotRef")
	if not slotRef then
		slotRef = Instance.new("ObjectValue")
		slotRef.Name = "_SlotRef"
		slotRef.Parent = maxSign
	end
	-- Garantit que la visibilité initiale du sign MAX est correcte au moment
	-- de la création : si le slot est déjà occupé (restoration) -> visible,
	-- sinon -> caché. refreshUpgradeSign sera rappelé à chaque changement.
	local occupiedNow = slotPart:GetAttribute(SLOT_OCCUPIED) == true
	local levelNow = tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 0
	local visibleNow = occupiedNow and not BrainrotUpgrade.IsMax(levelNow)
	maxSign.Transparency = visibleNow and 0 or 1
	local gui = maxSign:FindFirstChildOfClass("SurfaceGui")
	if gui then gui.Enabled = visibleNow end
end

-- Crée (ou réutilise) un UpgradeSign associé à un slot. Les signs vivent dans
-- le dossier UpgradeSigns du plot pour que GameService / reset n'y touchent pas.
local function ensureUpgradeSignForSlot(plotModel, slotPart)
	if not upgradeSignTemplate then return end
	if not slotPart:IsA("BasePart") then return end
	if not slotPart.Parent or slotPart.Parent.Name ~= "Slots" then return end

	local container = getOrCreateSignContainer(plotModel)
	local name = signNameForSlot(slotPart)
	local sign = container:FindFirstChild(name)
	local buttonPart = getButtonForSlot(slotPart)

	if not sign then
		sign = upgradeSignTemplate:Clone()
		sign.Name = name
		sign.Anchored = true
		sign.CanCollide = false
		sign.CanTouch = false
		sign.CanQuery = true -- nécessaire pour que le clic sur la SurfaceGui fonctionne
		sign.Transparency = 1 -- part reste invisible, seule la SurfaceGui porte le visuel
		sign.Parent = container
	end

	sign.CFrame = computeSignCFrame(slotPart, buttonPart)

	local gui = sign:FindFirstChild(UPGRADE_GUI_NAME)
	if gui and gui:IsA("SurfaceGui") then
		gui.Face = Enum.NormalId.Front
		gui.AlwaysOnTop = false
		gui.Enabled = false
		-- Active le test de clic sur la GUI (obligatoire pour capter les clics
		-- sur une SurfaceGui parentée à une Part du workspace).
		gui.ClipsDescendants = false
	end

	-- Référence inverse : le slot pointe vers son sign (ObjectValue). Utilisé par
	-- refreshUpgradeSign sans avoir à reparcourir le container.
	local ref = slotPart:FindFirstChild("_UpgradeSignRef")
	if not ref then
		ref = Instance.new("ObjectValue")
		ref.Name = "_UpgradeSignRef"
		ref.Parent = slotPart
	end
	ref.Value = sign

	updateSignDisplay(sign, slotPart)
	applySignVisibility(sign, slotPart)

	-- Crée (ou met à jour) le petit sign carré à droite du sign principal.
	ensureMaxUpgradeSignForSlot(plotModel, slotPart, sign)
end

-- Retire les vieux UpgradeSigns statiques de Build/Model/1 (plot1 légacy) pour
-- éviter qu'ils ne cohabitent avec ceux gérés dynamiquement.
local function cleanupLegacyUpgradeSigns(plotModel)
	local build = plotModel:FindFirstChild("Build")
	if not build then return end
	for _, model in ipairs(build:GetChildren()) do
		if model:IsA("Model") then
			for _, sub in ipairs(model:GetChildren()) do
				if sub:IsA("Model") then
					for _, d in ipairs(sub:GetChildren()) do
						if d.Name == UPGRADE_SIGN_NAME and d:IsA("BasePart") then
							d:Destroy()
						end
					end
				end
			end
		end
	end
end

-- ===== INITIALISATION PER SLOT / BUTTON =====

local function initButton(buttonPart)
	if not buttonPart:IsA("BasePart") then return end

	-- D4 : Garde anti-double-init. Sans ça, chaque join (qui appelle
	-- attachPlotWatcher → walkAndInit → initButton) ajoute UN NOUVEAU
	-- Touched:Connect cumulatif → ClaimButton se déclenche N fois par contact,
	-- multipliant le cash per touch -> exploit de cash gratuit + spam serveur.
	if buttonPart:GetAttribute("_BrainrotPlacementInited") then return end
	buttonPart:SetAttribute("_BrainrotPlacementInited", true)

	if buttonPart:GetAttribute(BTN_CPS) == nil      then buttonPart:SetAttribute(BTN_CPS, 0) end
	if buttonPart:GetAttribute(BTN_ACCUM_START) == nil then buttonPart:SetAttribute(BTN_ACCUM_START, 0) end
	if buttonPart:GetAttribute(BTN_ACCUM_CAP) == nil then buttonPart:SetAttribute(BTN_ACCUM_CAP, ACCUM_CAP_SECONDS) end
	if buttonPart:GetAttribute(BTN_CLAIM_TICK) == nil then buttonPart:SetAttribute(BTN_CLAIM_TICK, 0) end
	-- Snapshot the resting Y so the client knows where to return after the dip.
	buttonPart:SetAttribute(BTN_BASE_Y, buttonPart.Position.Y)

	createCashLabel(buttonPart)

	buttonPart.CanTouch = true

	buttonPart.Touched:Connect(function(otherPart)
		local char = otherPart:FindFirstAncestorOfClass("Model")
		if not char then return end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		local player = Players:GetPlayerFromCharacter(char)
		if not player then return end

		BrainrotPlacementService:ClaimButton(player, buttonPart)
	end)
end

local function initSlot(slotPart)
	if not slotPart:IsA("BasePart") then return end

	-- D4 : Garde anti-double-init pour la cohérence avec initButton.
	-- Le prompt Triggered:Connect est déjà protégé par `if not prompt`, mais
	-- on bloque aussi le re-set des attributs / re-create du prompt.
	if slotPart:GetAttribute("_BrainrotPlacementInited") then return end
	slotPart:SetAttribute("_BrainrotPlacementInited", true)

	if slotPart:GetAttribute(SLOT_OCCUPIED) == nil then slotPart:SetAttribute(SLOT_OCCUPIED, false) end
	if slotPart:GetAttribute(SLOT_BRAINROT) == nil then slotPart:SetAttribute(SLOT_BRAINROT, "") end
	if slotPart:GetAttribute(SLOT_LEVEL) == nil then slotPart:SetAttribute(SLOT_LEVEL, 0) end
	local key = getSlotKey(slotPart)
	if key then slotPart:SetAttribute(SLOT_KEY_ATTR, key) end

	local prompt = slotPart:FindFirstChild(PLACE_PROMPT_NAME)
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = PLACE_PROMPT_NAME
		prompt.ActionText = "Place brainrot"
		prompt.ObjectText = ""
		prompt.HoldDuration = 0
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance = PLACE_PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Parent = slotPart

		prompt.Triggered:Connect(function(triggerPlayer)
			BrainrotPlacementService:PlaceBrainrot(triggerPlayer, slotPart)
		end)
	end
	-- Visibility is fully client-owned: the client enables the prompt only if
	-- the local player currently has a brainrot tool equipped AND the slot is
	-- usable + empty. Server keeps it disabled so non-owners never see it.
	prompt.Enabled = false
end

-- ===== PUBLIC API =====

function BrainrotPlacementService:PlaceBrainrot(player, slotPart)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end

	local plot = getPlayerPlot(player)
	if not plot then return end
	if not slotPart:IsDescendantOf(plot) then return end
	if not isSlotUsable(slotPart) then return end
	if slotPart:GetAttribute(SLOT_OCCUPIED) then return end

	local tool = findEquippedBrainrotTool(player) or findAnyBrainrotTool(player)
	if not tool then return end

	local info = BrainrotInfo.GetInfo(tool.Name)
	if not info then return end

	local template = findTemplateByFullName(tool.Name)
	if not template then return end

	local buttonPart = getButtonForSlot(slotPart)
	if not buttonPart then return end

	local toolLevel = BrainrotUpgrade.ClampLevel(tonumber(tool:GetAttribute(TOOL_LEVEL_ATTR)) or 1)

	local ok = placeBrainrot(player, slotPart, buttonPart, tool.Name, template, info, toolLevel)
	if ok then
		DataService:RemoveBrainrotFromInventory(player, tool.Name, toolLevel)
		tool:Destroy()
		local key = getSlotKey(slotPart)
		if key then
			DataService:SetPlacedBrainrot(player, key, tool.Name, toolLevel)
		end
		refreshUpgradeSign(slotPart)
		recomputePlotExclusives(player)
	end
end

function BrainrotPlacementService:RemoveBrainrot(player, slotPart)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end

	local plot = getPlayerPlot(player)
	if not plot then return end
	if not slotPart:IsDescendantOf(plot) then return end
	if not slotPart:GetAttribute(SLOT_OCCUPIED) then return end

	local buttonPart = getButtonForSlot(slotPart)
	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	local level = tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1

	-- Claim any pending cash before returning the brainrot.
	if buttonPart then
		self:ClaimButton(player, buttonPart, true)
	end

	-- SWAP : si le joueur tient un brainrot dans les mains, on l'échange avec
	-- celui du slot. Le brainrot en main est placé sur le slot, celui du slot
	-- est donné au joueur dans son Backpack.
	local heldTool = findEquippedBrainrotTool(player)
	if heldTool then
		local heldName = heldTool.Name
		local heldLevel = BrainrotUpgrade.ClampLevel(tonumber(heldTool:GetAttribute(TOOL_LEVEL_ATTR)) or 1)
		local heldInfo = BrainrotInfo.GetInfo(heldName)
		local heldTemplate = findTemplateByFullName(heldName)

		if heldInfo and heldTemplate and buttonPart then
			-- 1) Retire l'ancien brainrot du slot (visuel + attributs + persistance).
			removePlacedBrainrot(slotPart, buttonPart)
			local key = getSlotKey(slotPart)
			if key then DataService:ClearPlacedBrainrot(player, key) end

			-- 2) Place le brainrot tenu sur le slot.
			local ok = placeBrainrot(player, slotPart, buttonPart, heldName, heldTemplate, heldInfo, heldLevel)
			if ok then
				DataService:RemoveBrainrotFromInventory(player, heldName, heldLevel)
				heldTool:Destroy()
				if key then
					DataService:SetPlacedBrainrot(player, key, heldName, heldLevel)
				end
			end

			-- 3) Donne l'ancien brainrot du slot au joueur dans son Backpack.
			if type(fullName) == "string" and fullName ~= "" then
				local oldTemplate = findTemplateByFullName(fullName)
				if oldTemplate then
					local backpack = player:FindFirstChildOfClass("Backpack")
					if backpack then
						local tool = self:_buildBrainrotTool(oldTemplate, fullName, level)
						if tool then
							tool.Parent = backpack
							DataService:AddBrainrotToInventory(player, fullName, level)
						end
					end
				end
			end

			refreshUpgradeSign(slotPart)
			recomputePlotExclusives(player)
			return
		end
	end

	-- Comportement par défaut : pas de brainrot en main -> simple retrait.
	removePlacedBrainrot(slotPart, buttonPart)

	local key = getSlotKey(slotPart)
	if key then
		DataService:ClearPlacedBrainrot(player, key)
	end

	-- Hand back a fresh Tool to the player (reuse BrainrotService's format).
	if type(fullName) == "string" and fullName ~= "" then
		local template = findTemplateByFullName(fullName)
		if template then
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then
				local tool = self:_buildBrainrotTool(template, fullName, level)
				if tool then
					tool.Parent = backpack
					DataService:AddBrainrotToInventory(player, fullName, level)
				end
			end
		end
	end

	refreshUpgradeSign(slotPart)
	recomputePlotExclusives(player)
end

function BrainrotPlacementService:ClaimButton(player, buttonPart, silent)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if typeof(buttonPart) ~= "Instance" or not buttonPart:IsA("BasePart") then return end

	local plot = getPlayerPlot(player)
	if not plot then return end
	if not buttonPart:IsDescendantOf(plot) then return end

	local now = os.clock()
	local last = lastTouchAt[buttonPart]
	if last and (now - last) < TOUCH_COOLDOWN then return end

	local cps = buttonPart:GetAttribute(BTN_CPS) or 0
	local accumStart = buttonPart:GetAttribute(BTN_ACCUM_START) or 0
	local accumCap = buttonPart:GetAttribute(BTN_ACCUM_CAP) or ACCUM_CAP_SECONDS
	if cps <= 0 or accumStart <= 0 then return end

	local elapsed = Workspace:GetServerTimeNow() - accumStart
	if elapsed > accumCap then elapsed = accumCap end
	if elapsed <= 0 then return end

	-- Pay out exactly what the player sees on the button. The client-side
	-- label jumps by `cps` every whole second (cps * floor(elapsed)); claiming
	-- on fractional elapsed time would credit a slightly different amount than
	-- advertised. Using floor(elapsed) here keeps display and wallet perfectly
	-- in sync.
	local fullSeconds = math.floor(elapsed)
	if fullSeconds <= 0 then return end

	local amount = cps * fullSeconds
	if amount <= 0 then return end

	local cashVal = player:FindFirstChild("Cash")
	if not cashVal then return end

	-- Passive income from brainrots is granted RAW (CPS * elapsed), so the
	-- displayed amount on the button always matches what's advertised on the
	-- brainrot's head label. CashMulti / rebirth bonuses are kept for other
	-- income sources only.
	cashVal.Value = cashVal.Value + amount

	lastTouchAt[buttonPart] = now
	-- Clean reset: the accumulator restarts at exactly "now", so the button
	-- visually restarts at $0 and will tick up to $cps after 1 full second.
	-- The sub-second leftover is dropped on purpose — the wallet gets exactly
	-- what was displayed, nothing more, nothing less.
	buttonPart:SetAttribute(BTN_ACCUM_START, Workspace:GetServerTimeNow())

	if not silent then
		-- Increment tick -> clients play the press animation locally.
		buttonPart:SetAttribute(BTN_CLAIM_TICK, (buttonPart:GetAttribute(BTN_CLAIM_TICK) or 0) + 1)
	end
end

-- ===== INTERNAL : TOOL BUILDER =====

-- Joue l'animation Idle sur un Tool brainrot (même logique que le service
-- principal, dupliqué ici pour éviter la dépendance croisée). On relance à
-- chaque Equipped pour gérer le cas où le track est stoppé en Backpack.
local function playToolIdleAnimation(tool)
	if not tool or not tool:IsA("Tool") then return end

	local function ensurePlay()
		local animController = tool:FindFirstChildOfClass("AnimationController")
		if not animController then return end
		local animsFolder = tool:FindFirstChild("Anims")
		local idleAnim = animsFolder and animsFolder:FindFirstChild("Idle")
		if not idleAnim or not idleAnim:IsA("Animation") then return end
		local animator = animController:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = animController
		end
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			if t.Animation == idleAnim and t.IsPlaying then
				return
			end
		end
		local ok, track = pcall(function()
			return animator:LoadAnimation(idleAnim)
		end)
		if not ok or not track then return end
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Idle
		track:Play()
	end

	ensurePlay()
	tool.Equipped:Connect(ensurePlay)
	tool.AncestryChanged:Connect(function()
		if tool:IsDescendantOf(workspace) then
			ensurePlay()
		end
	end)
end

-- Same shape as BrainrotService.createBrainrotTool (kept local to avoid a
-- circular service dependency and keep placement self-contained).
function BrainrotPlacementService:_buildBrainrotTool(template, fullName, level)
	level = BrainrotUpgrade.ClampLevel(level or 1)
	local info = BrainrotInfo.GetInfo(fullName)

	local tool = Instance.new("Tool")
	tool.Name = fullName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = info and (info.RarityType .. " Brainrot") or "Brainrot"
	tool:SetAttribute(TOOL_LEVEL_ATTR, level)

	local clone = template:Clone()
	local primary = clone.PrimaryPart
	if not primary then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then primary = d break end
		end
	end
	if not primary then
		clone:Destroy() tool:Destroy() return nil
	end

	primary.Name = "Handle"
	primary.CanCollide = false
	primary.Massless = true
	primary.Anchored = false
	primary.Parent = tool

	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
			d.Anchored = false
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = primary
			wc.Part1 = d
			wc.Parent = primary
		end
	end

	for _, child in ipairs(clone:GetChildren()) do
		child.Parent = tool
	end
	clone:Destroy()

	tool.Grip = CFrame.new()

	BrainrotLabel.CreateFromName(primary, fullName, level)

	-- Lance l'anim Idle pour que le brainrot s'anime dans les mains du joueur.
	playToolIdleAnimation(tool)

	return tool
end

-- ===== PLOT WATCHING =====

local function walkAndInit(container, plotModel)
	if not container then return end
	for _, desc in ipairs(container:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Parent then
			local parentName = desc.Parent.Name
			if parentName == "Slots" then
				initSlot(desc)
				if plotModel then ensureUpgradeSignForSlot(plotModel, desc) end
			elseif parentName == "Buttons" then
				initButton(desc)
			end
		end
	end
end

local function attachPlotWatcher(plotModel)
	local state = plotState[plotModel]
	if state then return end
	state = { connections = {} }
	plotState[plotModel] = state

	-- Supprime les signs statiques légacy pour éviter les doublons.
	cleanupLegacyUpgradeSigns(plotModel)

	-- Initial pass (base slots + any already-placed floor slots).
	walkAndInit(plotModel, plotModel)

	-- React to dynamically added floor slots / buttons created by GameService.
	state.connections[1] = plotModel.DescendantAdded:Connect(function(desc)
		if not desc:IsA("BasePart") then return end
		local parent = desc.Parent
		if not parent then return end
		if parent.Name == "Slots" then
			initSlot(desc)
			ensureUpgradeSignForSlot(plotModel, desc)
		elseif parent.Name == "Buttons" then
			initButton(desc)
			-- Le bouton peut arriver après le slot : reposition le sign.
			local slot = getSlotForButton(desc)
			if slot then ensureUpgradeSignForSlot(plotModel, slot) end
		end
	end)
end

local function detachPlotWatcher(plotModel)
	local state = plotState[plotModel]
	if not state then return end
	for _, c in ipairs(state.connections) do
		c:Disconnect()
	end
	plotState[plotModel] = nil
end

local function resetPlot(plotModel)
	-- Remove any lingering placed brainrots and reset slot / button state.
	for _, desc in ipairs(plotModel:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Parent then
			if desc.Parent.Name == "Slots" then
				local btn = getButtonForSlot(desc)
				local holder = desc:FindFirstChild(PLACED_MARKER_NAME)
				if holder then holder:Destroy() end
				desc:SetAttribute(SLOT_OCCUPIED, false)
				desc:SetAttribute(SLOT_BRAINROT, "")
				desc:SetAttribute(SLOT_LEVEL, 0)
				local prompt = desc:FindFirstChild(PLACE_PROMPT_NAME)
				if prompt then prompt.Enabled = false end
				if btn then
					resetButtonAttributes(btn)
					setCashLabelEnabled(btn, false)
				end
				refreshUpgradeSign(desc)
			elseif desc.Parent.Name == "Buttons" then
				lastTouchAt[desc] = nil
			end
		end
	end
end

-- ===== PLAYER LIFECYCLE =====

-- Recalcule le CPS affiché sur chaque bouton occupé du plot d'un joueur
-- en fonction de son CashMulti courant. On NE claim PAS le cash déjà
-- accumulé : on met juste à jour le CPS. Le cash déjà visible sur le
-- bouton reste en place et continue de s'accumuler au nouveau taux. Sans
-- ça, acheter le gamepass CashX2 (ou un rebirth) viderait visuellement
-- tous les boutons, ce qui était perçu comme un reset/bug par le joueur.
local function refreshPlotCpsMultiplier(player)
	local plot = getPlayerPlot(player)
	if not plot then return end

	local cashMulti = getCashMulti(player)

	for _, desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("BasePart")
			and desc.Parent
			and desc.Parent.Name == "Slots"
			and desc:GetAttribute(SLOT_OCCUPIED)
		then
			local fullName = desc:GetAttribute(SLOT_BRAINROT)
			local level = tonumber(desc:GetAttribute(SLOT_LEVEL)) or 1
			local button = getButtonForSlot(desc)
			if button and type(fullName) == "string" and fullName ~= "" then
				local info = BrainrotInfo.GetInfo(fullName)
				if info then
					local cps = math.floor(BrainrotUpgrade.GetCps(info.CashPerSecond, level) * cashMulti + 0.5)
					button:SetAttribute(BTN_CPS, cps)
				end
			end
		end
	end
end

-- API publique : recalcule le CPS de tous les brainrots placés d'un joueur.
-- Appelé par GamepassService après achat de CashX2 pour appliquer le bonus
-- sans attendre un rebirth ou un replacement.
function BrainrotPlacementService:RefreshCpsForPlayer(player)
	refreshPlotCpsMultiplier(player)
	recomputePlotExclusives(player)
	local okLb, lb = pcall(Loader.GetService, "CashLeaderboardService")
	if okLb and lb and lb.NotifyCpsChanged then
		pcall(function() lb:NotifyCpsChanged(player) end)
	end
end

-- ===== AUTO-COLLECT GAMEPASS =====
--
-- Pour les joueurs qui possèdent le gamepass AutoCollect, on claim leurs
-- boutons toutes les `AUTO_COLLECT_INTERVAL` secondes sans qu'ils aient à
-- marcher dessus. Réutilise ClaimButton (en mode silent) pour garder une
-- source de vérité unique : même calcul du cash gagné, même reset de
-- l'accumulateur, même application du cap. La seule différence est qu'on
-- ne joue PAS l'animation "press" du bouton (silent = true) pour ne pas
-- spammer un effet visuel toutes les ticks.
--
-- Source de vérité du flag : Player:GetAttribute("HasAutoCollect").
-- Posé par GamepassService :
--   * au join après UserOwnsGamePassAsync
--   * sur PromptGamePassPurchaseFinished (achat live)
-- Plus rapide qu'un appel DataService:HasGamepass et évite la fenêtre
-- de race entre :Start de DataService et :Start de BrainrotPlacementService.
local AUTO_COLLECT_INTERVAL = 2
local AUTO_COLLECT_ATTR = "HasAutoCollect"

local function playerHasAutoCollect(player)
	-- Fast path : attribute Player (set par GamepassService).
	if player:GetAttribute(AUTO_COLLECT_ATTR) == true then
		return true
	end
	-- Fallback : profil DataService. Couvre le cas où GamepassService n'a
	-- pas encore eu le temps de poser l'attribute (joueur tout juste co).
	if DataService and DataService.HasGamepass and DataService:HasGamepass(player, "AutoCollect") then
		player:SetAttribute(AUTO_COLLECT_ATTR, true) -- self-heal pour les ticks suivants
		return true
	end
	return false
end

local function autoCollectTickForPlayer(player)
	if not playerHasAutoCollect(player) then return end
	local plot = getPlayerPlot(player)
	if not plot then return end
	local floorsFolder = plot:FindFirstChild("Floors")
	local containers = {}
	if floorsFolder then
		for _, floorModel in ipairs(floorsFolder:GetChildren()) do
			local buttons = floorModel:FindFirstChild("Buttons")
			if buttons then table.insert(containers, buttons) end
		end
	end
	local rootButtons = plot:FindFirstChild("Buttons")
	if rootButtons then table.insert(containers, rootButtons) end

	for _, container in ipairs(containers) do
		for _, btn in ipairs(container:GetChildren()) do
			if btn:IsA("BasePart") then
				local cps = btn:GetAttribute(BTN_CPS) or 0
				if cps > 0 then
					-- silent = true : pas d'animation "press" puisque le
					-- joueur n'a pas physiquement marché sur le bouton.
					BrainrotPlacementService:ClaimButton(player, btn, true)
				end
			end
		end
	end
end

local function startAutoCollectLoop()
	task.spawn(function()
		while true do
			task.wait(AUTO_COLLECT_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				-- Wrappe chaque joueur dans un pcall pour qu'une erreur sur
				-- un joueur (ex : plot détruit pendant le walk) n'arrête
				-- pas la boucle pour les autres.
				pcall(autoCollectTickForPlayer, player)
			end
		end
	end)
end

local function onPlayerPlotReady(player)
	local plot = getPlayerPlot(player)
	if not plot then return end
	-- Fresh start: stale state from a previous owner is cleared before arming.
	resetPlot(plot)
	attachPlotWatcher(plot)

	-- Rebirth -> CashMulti change -> update tous les boutons occupés.
	local cashMulti = player:FindFirstChild("CashMulti")
	if cashMulti and cashMulti:IsA("ValueBase") then
		cashMulti:GetPropertyChangedSignal("Value"):Connect(function()
			refreshPlotCpsMultiplier(player)
			recomputePlotExclusives(player)
		end)
	end

	-- Restaure les brainrots placés depuis le profil DataService.
	local placed = DataService:GetPlacedBrainrots(player)
	for _, desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Parent and desc.Parent.Name == "Slots" then
			local key = getSlotKey(desc)
			local entry = key and placed[key]
			if entry and isSlotUsable(desc) and not desc:GetAttribute(SLOT_OCCUPIED) then
				local template = findTemplateByFullName(entry.Name)
				local button = getButtonForSlot(desc)
				local info = BrainrotInfo.GetInfo(entry.Name)
				if template and button and info then
					placeBrainrot(player, desc, button, entry.Name, template, info, entry.Level)
					refreshUpgradeSign(desc)
				end
			end
		end
	end

	-- Une fois TOUS les brainrots restaurés, on calcule le CPS des exclusifs
	-- (qui dépend du total des autres brainrots du plot).
	recomputePlotExclusives(player)
end

local function waitForPlotAndInit(player)
	-- PlotNumber is created by GameService on PlayerAdded.
	local plotNumVal = player:WaitForChild("PlotNumber", 30)
	if not plotNumVal then return end
	onPlayerPlotReady(player)
end

local function onPlayerAdded(player)
	task.spawn(waitForPlotAndInit, player)
end

local function onPlayerRemoving(player)
	local plot = getPlayerPlot(player)
	if plot then
		resetPlot(plot)
		detachPlotWatcher(plot)
	end
end

-- ===== STEAL =====

-- Appelé quand un non-owner déclenche le prompt Steal. Valide la cible puis
-- lance directement le prompt d'achat Robux. Le vol réel ne s'applique que
-- dans ProcessReceipt (via HandlePurchase) pour garantir que les Robux ont
-- bien été débités.
function BrainrotPlacementService:PromptSteal(thief, slotPart)
	if typeof(thief) ~= "Instance" or not thief:IsA("Player") then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end
	if not slotPart:IsDescendantOf(plotsFolder) then return end
	if not slotPart:GetAttribute(SLOT_OCCUPIED) then return end

	local holder = slotPart:FindFirstChild(PLACED_MARKER_NAME)
	if not holder then return end
	local ownerId = holder:GetAttribute("OwnerUserId")
	if not ownerId or ownerId == thief.UserId then return end

	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	local level = BrainrotUpgrade.ClampLevel(tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1)
	local info = BrainrotInfo.GetInfo(fullName)
	if not info then return end

	local productId = STEAL_PRODUCT_IDS[info.RarityType]
	if not productId then return end

	pendingSteals[thief.UserId] = {
		slotPart  = slotPart,
		ownerId   = ownerId,
		fullName  = fullName,
		level     = level,
		productId = productId,
		expiresAt = os.clock() + PENDING_STEAL_TIMEOUT,
	}

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(thief, productId)
	end)
	if not ok then
		pendingSteals[thief.UserId] = nil
		warn("[Steal] PromptProductPurchase a échoué : " .. tostring(err))
	end
end

-- Appelé par GameService.processReceipt pour tout productId appartenant à
-- STEAL_PRODUCT_IDS. Retourne true si le service a géré l'achat (le receipt
-- doit être accordé), false sinon (GameService cherchera un autre handler).
function BrainrotPlacementService:HandlePurchase(player, productId)
	if not STEAL_PRODUCT_ID_SET[productId] then return false end

	local pending = pendingSteals[player.UserId]
	if not pending or pending.productId ~= productId or pending.expiresAt < os.clock() then
		-- Pas de pending valide : on accepte quand même l'achat (pour éviter
		-- que Roblox re-tente en boucle et abuse les Robux du joueur) et on
		-- laisse une trace.
		warn(string.format("[Steal] Achat %d pour %s sans pending valide", productId, player.Name))
		pendingSteals[player.UserId] = nil
		return true
	end

	local slotPart = pending.slotPart
	if not slotPart or not slotPart.Parent then
		pendingSteals[player.UserId] = nil
		warn("[Steal] Slot disparu avant d'appliquer le vol pour " .. player.Name)
		return true
	end

	-- Re-valide : rien n'a changé entre Prompt et Receipt (brainrot toujours
	-- placé, même nom). Si la victime a déjà retiré son brainrot, on refuse
	-- silencieusement mais on accorde tout de même l'achat pour éviter les
	-- retries infinis.
	if not slotPart:GetAttribute(SLOT_OCCUPIED)
		or slotPart:GetAttribute(SLOT_BRAINROT) ~= pending.fullName
	then
		pendingSteals[player.UserId] = nil
		warn("[Steal] La cible a bougé : impossible d'appliquer le vol pour " .. player.Name)
		return true
	end

	local owner = Players:GetPlayerByUserId(pending.ownerId)
	local buttonPart = getButtonForSlot(slotPart)
	local fullName = pending.fullName
	local level = pending.level

	-- Paye l'owner pour les gains déjà accumulés sur son bouton (comme s'il
	-- avait claim juste avant qu'on lui vole son brainrot).
	if owner and buttonPart then
		self:ClaimButton(owner, buttonPart, true)
	end

	-- Retire le brainrot du profil de la victime.
	if owner then
		local key = getSlotKey(slotPart)
		if key then
			DataService:ClearPlacedBrainrot(owner, key)
		end
	end

	-- Prévient la victime qu'on lui a volé son brainrot.
	if owner and stealNotifyEvent then
		local info = BrainrotInfo.GetInfo(fullName)
		stealNotifyEvent:FireClient(owner, {
			FullName   = fullName,
			Level      = level,
			ThiefName  = player.DisplayName,
			Rarity     = info and info.RarityType or nil,
		})
	end

	-- Retire la pièce du slot (destruction du model placé, reset bouton).
	removePlacedBrainrot(slotPart, buttonPart)
	refreshUpgradeSign(slotPart)

	-- L'owner perd un brainrot du plot : ses exclusifs doivent être recalculés.
	if owner then
		recomputePlotExclusives(owner)
	end

	-- Donne le brainrot au voleur : Tool dans Backpack + DataService.
	local template = findTemplateByFullName(fullName)
	if template then
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then
			local tool = self:_buildBrainrotTool(template, fullName, level)
			if tool then
				tool.Parent = backpack
				DataService:AddBrainrotToInventory(player, fullName, level)
			end
		end
	end

	pendingSteals[player.UserId] = nil
	return true
end

function BrainrotPlacementService:_performUpgrade(player, slotPart)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end

	local plot = getPlayerPlot(player)
	if not plot then return end
	if not slotPart:IsDescendantOf(plot) then return end
	if not slotPart:GetAttribute(SLOT_OCCUPIED) then return end

	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	if type(fullName) ~= "string" or fullName == "" then return end

	local info = BrainrotInfo.GetInfo(fullName)
	if not info then return end

	-- Les brainrots exclusifs ne peuvent pas être upgradés : leur CPS est un
	-- pourcentage du total de la base, donc le niveau n'a aucun effet.
	if info.ExclusivePercent then
		buyUpgradeEvent:FireClient(player, false, "Les brainrots exclusifs ne peuvent pas \195\170tre am\195\169lior\195\169s.")
		return
	end

	local currentLevel = BrainrotUpgrade.ClampLevel(tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1)
	if BrainrotUpgrade.IsMax(currentLevel) then
		buyUpgradeEvent:FireClient(player, false, "Niveau maximum atteint !")
		return
	end

	local cost = BrainrotUpgrade.GetUpgradeCost(info.CashPerSecond, currentLevel)
	local cashVal = player:FindFirstChild("Cash")
	if not cashVal then return end
	if cashVal.Value < cost then
		-- Pas assez de cash : on propose au joueur d'acheter +3 niveaux en Robux.
		pendingUpgrades[player.UserId] = {
			slotPart  = slotPart,
			expiresAt = os.clock() + PENDING_UPGRADE_TIMEOUT,
		}
		local ok, err = pcall(function()
			MarketplaceService:PromptProductPurchase(player, UPGRADE_ROBUX_PRODUCT_ID)
		end)
		if not ok then
			pendingUpgrades[player.UserId] = nil
			warn("[Upgrade] PromptProductPurchase a échoué : " .. tostring(err))
			buyUpgradeEvent:FireClient(player, false, string.format("Pas assez de cash : $%s / $%s", BrainrotInfo.FormatShort(cashVal.Value), BrainrotInfo.FormatShort(cost)))
		end
		return
	end

	local newLevel = currentLevel + 1

	-- Débit la banque pour l'upgrade.
	cashVal.Value = cashVal.Value - cost

	self:_applyUpgradeToLevel(player, slotPart, newLevel, fullName, info)

	buyUpgradeEvent:FireClient(player, true, string.format("%s amélioré au niveau %d", fullName, newLevel))
end

-- Spawne l'UpgradeVFX dans le brainrot placé, échelonné selon sa taille.
-- Chaque ParticleEmitter de UpgradeVFX porte des attributs configurés par
-- l'artiste pour orchestrer l'animation d'upgrade :
--   * EmitCount    (nombre, défaut = Rate ou 10) : nombre de particules à émettre
--   * EmitDelay    (secondes, défaut = 0)         : délai avant l'émission
--   * EmitDuration (secondes, défaut = 0)         : si > 0, l'emitter reste
--                                                   activé pendant cette durée
--                                                   (stream continu) ; sinon
--                                                   burst instantané via :Emit.
-- L'attachment est détruit après que tous les delays/durées soient passés ;
-- les particules déjà émises continuent leur vie dans l'espace monde.
local function playUpgradeVfxOnBrainrot(clone, primary)
	local vfxTemplate = ReplicatedStorage:FindFirstChild("VFX")
	vfxTemplate = vfxTemplate and vfxTemplate:FindFirstChild("UpgradeVFX")
	if not vfxTemplate or not primary then return end

	local attach = vfxTemplate:Clone()
	attach.Name = "UpgradeVFX_Active"
	attach.Visible = true

	-- Taille du brainrot : on prend la plus grande dimension de la BB pour
	-- scaler le VFX. Ratio de 1 stud = emitters à leur taille d'origine.
	local _, bbSize
	if clone and clone:IsA("Model") then
		_, bbSize = clone:GetBoundingBox()
	else
		bbSize = primary.Size
	end
	local maxDim = math.max(bbSize.X, bbSize.Y, bbSize.Z)
	-- Scale : ratio sur 6 studs de référence (taille moyenne d'un brainrot).
	-- Plafonné entre 0.5x et 4x pour éviter les cas extrêmes.
	local scale = math.clamp(maxDim / 6, 0.5, 4)

	-- Pré-traite chaque emitter : scale des tailles ET lecture des attributs.
	-- Les emitters sont désactivés par défaut ; on les pilote manuellement via
	-- :Emit (burst) ou Enabled=true pendant EmitDuration (stream).
	-- On track aussi la date à laquelle la DERNIÈRE particule de tout
	-- l'attachment aura fini de vivre : emit_time + Lifetime.Max. En-dessous
	-- de cette date, détruire l'attachment tuerait les particules encore
	-- vivantes (Roblox : quand un ParticleEmitter est détruit, toutes ses
	-- particules actives disparaissent aussi).
	local emitters = {}
	local maxAliveTime = 0
	for _, d in ipairs(attach:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			local oldSeq = d.Size
			local newKeys = {}
			for _, kp in ipairs(oldSeq.Keypoints) do
				table.insert(newKeys, NumberSequenceKeypoint.new(kp.Time, kp.Value * scale, kp.Envelope * scale))
			end
			d.Size = NumberSequence.new(newKeys)
			d.Enabled = false

			local emitDelay = tonumber(d:GetAttribute("EmitDelay")) or 0
			local emitDuration = tonumber(d:GetAttribute("EmitDuration")) or 0
			local emitCount = tonumber(d:GetAttribute("EmitCount"))
			if emitCount == nil then
				emitCount = d.Rate > 0 and d.Rate or 10
			end

			table.insert(emitters, {
				emitter = d,
				delay = math.max(0, emitDelay),
				count = math.max(0, emitCount),
				duration = math.max(0, emitDuration),
			})

			-- Durée de vie maximale d'une particule de cet emitter. NumberRange
			-- a un champ .Max ; on l'utilise pour ne pas couper de particules.
			local lifetimeMax = d.Lifetime.Max
			local finish = emitDelay + emitDuration + lifetimeMax
			if finish > maxAliveTime then maxAliveTime = finish end
		end
	end

	attach.Parent = primary

	-- Déclenche chaque emitter selon ses attributs.
	for _, e in ipairs(emitters) do
		task.delay(e.delay, function()
			if not e.emitter or not e.emitter.Parent then return end
			if e.duration > 0 then
				-- Stream continu pendant EmitDuration, + burst initial s'il y a
				-- un EmitCount (souvent utilisé pour pimenter le démarrage).
				e.emitter.Enabled = true
				if e.count > 0 then
					e.emitter:Emit(e.count)
				end
				task.delay(e.duration, function()
					if e.emitter and e.emitter.Parent then
						e.emitter.Enabled = false
					end
				end)
			elseif e.count > 0 then
				e.emitter:Emit(e.count)
			end
		end)
	end

	-- Détruit l'attachment APRÈS la fin de vie de la dernière particule pour
	-- ne pas tronquer l'animation. +0.1s de marge pour la frame de cleanup.
	task.delay(maxAliveTime + 0.1, function()
		if attach and attach.Parent then
			attach:Destroy()
		end
	end)
end

-- Applique un changement de niveau vers `newLevel` sur le slot, met à jour le
-- bouton, le modèle 3D, le label et la persistance. Factorisé pour partager la
-- logique entre upgrade cash (+1) et upgrade Robux (+3).
function BrainrotPlacementService:_applyUpgradeToLevel(player, slotPart, newLevel, fullName, info)
	newLevel = BrainrotUpgrade.ClampLevel(newLevel)
	local currentLevel = BrainrotUpgrade.ClampLevel(tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1)

	slotPart:SetAttribute(SLOT_LEVEL, newLevel)

	local button = getButtonForSlot(slotPart)
	local isExclusive = info and info.ExclusivePercent ~= nil
	if button then
		local cashMulti = getCashMulti(player)
		if isExclusive then
			-- Pour les exclusifs, le CPS réel est calculé par recomputePlotExclusives
			-- en fonction du total des autres brainrots du plot. On ne touche pas à
			-- BTN_CPS ici pour ne pas casser cette source de vérité.
		else
			local cps = math.floor(BrainrotUpgrade.GetCps(info.CashPerSecond, newLevel) * cashMulti + 0.5)
			button:SetAttribute(BTN_CPS, cps)
		end
	end

	local holder = slotPart:FindFirstChild(PLACED_MARKER_NAME)
	if holder and holder:IsA("Model") then
		holder:SetAttribute("Level", newLevel)
		local clone = holder:FindFirstChildWhichIsA("Model")
		if clone then
			local prevFactor = BrainrotUpgrade.GetScaleFactor(currentLevel)
			local newFactor = BrainrotUpgrade.GetScaleFactor(newLevel)
			local baseScale = tonumber(holder:GetAttribute("BaseScale"))
			if not baseScale then
				baseScale = clone:GetScale() / prevFactor
				holder:SetAttribute("BaseScale", baseScale)
			end
			if math.abs(newFactor - prevFactor) > 1e-4 then
				pcall(function() clone:ScaleTo(baseScale * newFactor) end)
			end
			local minY = math.huge
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then
					local y = d.Position.Y - d.Size.Y * 0.5
					if y < minY then minY = y end
				end
			end
			if minY ~= math.huge then
				local slotTopY = slotPart.Position.Y + slotPart.Size.Y * 0.5
				local liftY = (slotTopY - minY) + 0.02
				if math.abs(liftY) > 1e-3 then
					clone:PivotTo(clone:GetPivot() + Vector3.new(0, liftY, 0))
				end
			end
			local primary = clone.PrimaryPart
			if primary then
				if isExclusive then
					-- Affiche "X%% / s" plutôt qu'un montant fixe.
					BrainrotLabel.UpdateLevelAndCps(primary, newLevel, 0, info.ExclusivePercent)
				else
					BrainrotLabel.UpdateLevelAndCps(primary, newLevel, BrainrotUpgrade.GetCps(info.CashPerSecond, newLevel))
				end
				-- VFX d'upgrade scalant avec la taille du brainrot.
				playUpgradeVfxOnBrainrot(clone, primary)
			end
		end
	end

	local key = getSlotKey(slotPart)
	if key then
		DataService:SetPlacedBrainrotLevel(player, key, newLevel)
	end

	refreshUpgradeSign(slotPart)

	-- Recalcule les exclusifs : leur CPS dépend du CPS total de la base, donc
	-- l'upgrade d'un brainrot "normal" doit aussi mettre à jour les exclusifs.
	recomputePlotExclusives(player)
end

-- Handler du Developer Product d'upgrade en Robux (+3 niveaux).
function BrainrotPlacementService:HandleUpgradePurchase(player, productId)
	if productId ~= UPGRADE_ROBUX_PRODUCT_ID then return false end

	local pending = pendingUpgrades[player.UserId]
	if not pending or pending.expiresAt < os.clock() then
		warn(string.format(
			"[Upgrade] PERTE POTENTIELLE — Achat %d (Robux, +3 niveaux) reçu pour %s mais pas de pending valide. Le joueur a payé sans recevoir l'upgrade. Vérifier les logs autour de cette heure pour un refund manuel.",
			productId, player.Name
		))
		pendingUpgrades[player.UserId] = nil
		return true -- on accepte quand même pour éviter les retries Roblox
	end

	local slotPart = pending.slotPart
	if not slotPart or not slotPart.Parent then
		pendingUpgrades[player.UserId] = nil
		return true
	end

	if not slotPart:GetAttribute(SLOT_OCCUPIED) then
		pendingUpgrades[player.UserId] = nil
		return true
	end

	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	local info = BrainrotInfo.GetInfo(fullName)
	if not info then
		pendingUpgrades[player.UserId] = nil
		return true
	end

	local currentLevel = BrainrotUpgrade.ClampLevel(tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1)
	local newLevel = BrainrotUpgrade.ClampLevel(currentLevel + UPGRADE_ROBUX_LEVELS)

	self:_applyUpgradeToLevel(player, slotPart, newLevel, fullName, info)

	buyUpgradeEvent:FireClient(player, true,
		string.format("%s boosté au niveau %d (+%d) !", fullName, newLevel, newLevel - currentLevel))

	pendingUpgrades[player.UserId] = nil
	return true
end

-- ===== MAX UPGRADE (petit panneau carré droite) =====

-- Demande au joueur d'acheter le produit MAX en Robux. Stocké dans
-- pendingMaxUpgrades ; validé et appliqué dans HandleMaxUpgradePurchase.
function BrainrotPlacementService:_performMaxUpgrade(player, slotPart)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end

	local plot = getPlayerPlot(player)
	if not plot then return end
	if not slotPart:IsDescendantOf(plot) then return end
	if not slotPart:GetAttribute(SLOT_OCCUPIED) then return end

	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	if type(fullName) ~= "string" or fullName == "" then return end
	local exclusiveInfo = BrainrotInfo.GetInfo(fullName)
	if not exclusiveInfo then return end
	-- Les brainrots exclusifs ne sont pas upgradables (CPS = pourcentage fixe).
	if exclusiveInfo.ExclusivePercent then
		buyUpgradeEvent:FireClient(player, false, "Les brainrots exclusifs ne peuvent pas \195\170tre am\195\169lior\195\169s.")
		return
	end
	if not BrainrotInfo.GetInfo(fullName) then return end

	local currentLevel = BrainrotUpgrade.ClampLevel(tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1)
	if BrainrotUpgrade.IsMax(currentLevel) then
		buyUpgradeEvent:FireClient(player, false, "Déjà au niveau maximum !")
		return
	end

	pendingMaxUpgrades[player.UserId] = {
		slotPart  = slotPart,
		expiresAt = os.clock() + PENDING_UPGRADE_TIMEOUT,
	}
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, UPGRADE_MAX_ROBUX_PRODUCT_ID)
	end)
	if not ok then
		pendingMaxUpgrades[player.UserId] = nil
		warn("[MaxUpgrade] PromptProductPurchase a échoué : " .. tostring(err))
	end
end

-- Handler du Developer Product MAX : upgrade jusqu'au MAX_LEVEL.
function BrainrotPlacementService:HandleMaxUpgradePurchase(player, productId)
	if productId ~= UPGRADE_MAX_ROBUX_PRODUCT_ID then return false end

	local pending = pendingMaxUpgrades[player.UserId]
	if not pending or pending.expiresAt < os.clock() then
		warn(string.format(
			"[MaxUpgrade] PERTE POTENTIELLE — Achat %d (Robux, MAX) reçu pour %s mais pas de pending valide. Le joueur a payé sans recevoir l'upgrade MAX. Vérifier les logs autour de cette heure pour un refund manuel.",
			productId, player.Name
		))
		pendingMaxUpgrades[player.UserId] = nil
		return true
	end

	local slotPart = pending.slotPart
	if not slotPart or not slotPart.Parent then
		pendingMaxUpgrades[player.UserId] = nil
		return true
	end

	if not slotPart:GetAttribute(SLOT_OCCUPIED) then
		pendingMaxUpgrades[player.UserId] = nil
		return true
	end

	local fullName = slotPart:GetAttribute(SLOT_BRAINROT)
	local info = BrainrotInfo.GetInfo(fullName)
	if not info then
		pendingMaxUpgrades[player.UserId] = nil
		return true
	end

	local currentLevel = BrainrotUpgrade.ClampLevel(tonumber(slotPart:GetAttribute(SLOT_LEVEL)) or 1)
	local newLevel = BrainrotUpgrade.MAX_LEVEL
	if newLevel <= currentLevel then
		pendingMaxUpgrades[player.UserId] = nil
		return true
	end

	self:_applyUpgradeToLevel(player, slotPart, newLevel, fullName, info)

	buyUpgradeEvent:FireClient(player, true,
		string.format("%s boosté au niveau MAX (%d) !", fullName, newLevel))

	pendingMaxUpgrades[player.UserId] = nil
	return true
end

local function onBuyUpgrade(player, slotPart)
	-- D3 : rate limit + validation stricte du type avant de descendre.
	if not rateLimitUpgrade(player) then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end
	BrainrotPlacementService:_performUpgrade(player, slotPart)
end

local function onBuyMaxUpgrade(player, slotPart)
	-- D3 : rate limit + validation stricte du type avant de descendre.
	if not rateLimitUpgrade(player) then return end
	if typeof(slotPart) ~= "Instance" or not slotPart:IsA("BasePart") then return end
	BrainrotPlacementService:_performMaxUpgrade(player, slotPart)
end

-- ===== LIFECYCLE =====

function BrainrotPlacementService:Init()
	plotsFolder = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")
	brainrotsFolder = ReplicatedStorage:WaitForChild(BRAINROT_ROOT_NAME)
	buyUpgradeEvent = RemotesAPI.GetEvent("BuyUpgradeBrainrotEvent")
	buyMaxUpgradeEvent = RemotesAPI.GetEvent("BuyMaxUpgradeBrainrotEvent")
	stealNotifyEvent = RemotesAPI.GetEvent("BrainrotStolenNotifyEvent")

	-- Capture un UpgradeSign legacy comme template, puis on s'en sert pour
	-- fabriquer les signs dynamiques. Le template est parenté à ReplicatedStorage
	-- pour qu'il soit accessible à tout moment.
	local function findLegacyTemplate()
		for _, plot in ipairs(plotsFolder:GetChildren()) do
			for _, d in ipairs(plot:GetDescendants()) do
				if d.Name == UPGRADE_SIGN_NAME and d:IsA("BasePart") and d:FindFirstChild(UPGRADE_GUI_NAME) then
					return d
				end
			end
		end
		return nil
	end

	local src = findLegacyTemplate()
	if src then
		upgradeSignTemplate = src:Clone()
		upgradeSignTemplate.Name = UPGRADE_SIGN_NAME .. "_Template"
		upgradeSignTemplate.Anchored = true
		upgradeSignTemplate.CanCollide = false
		upgradeSignTemplate.CanTouch = false
		upgradeSignTemplate.CanQuery = true
		upgradeSignTemplate.Transparency = 1
		upgradeSignTemplate.Parent = ReplicatedStorage
	else
		warn("[BrainrotPlacementService] Aucun UpgradeSign legacy trouvé pour servir de template")
	end
end

function BrainrotPlacementService:Start()
	DataService = Loader.GetService("DataService")

	-- D8 : guard d'idempotence sur le bind par joueur. waitForPlotAndInit
	-- contient un WaitForChild qui yield ; sans cette protection, un même
	-- joueur peut être bindé deux fois (race PlayerAdded vs GetPlayers Studio)
	-- → deux passes de placeBrainrot en parallèle sur le même slot → brainrots
	-- dupliqués qui rapportent du cash en double.
	local hookedPlayers = {}
	local function hookPlayerOnce(p)
		if hookedPlayers[p.UserId] then return end
		hookedPlayers[p.UserId] = true
		onPlayerAdded(p)
	end

	Players.PlayerAdded:Connect(hookPlayerOnce)
	Players.PlayerRemoving:Connect(function(p)
		hookedPlayers[p.UserId] = nil
		onPlayerRemoving(p)
	end)

	if buyUpgradeEvent then
		buyUpgradeEvent.OnServerEvent:Connect(onBuyUpgrade)
	end
	if buyMaxUpgradeEvent then
		buyMaxUpgradeEvent.OnServerEvent:Connect(onBuyMaxUpgrade)
	end

	-- Nettoyage des pending steals quand un joueur part (évite la fuite mémoire).
	Players.PlayerRemoving:Connect(function(plr)
		pendingSteals[plr.UserId] = nil
		pendingUpgrades[plr.UserId] = nil
		pendingMaxUpgrades[plr.UserId] = nil
		lastUpgradeRequestAt[plr.UserId] = nil
	end)

	-- Studio / Replay: handle already-connected players.
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayerOnce(player)
	end

	-- Démarre la boucle d'auto-claim pour les joueurs avec le gamepass
	-- AutoCollect. Une seule task globale ; elle filtre les joueurs avec
	-- le flag à chaque tick.
	startAutoCollectLoop()

	print("[BrainrotPlacementService] Prêt")
end

return BrainrotPlacementService
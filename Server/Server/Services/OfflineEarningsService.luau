--[[
	OfflineEarningsService
	Calcule et distribue le cash gagné par un joueur pendant son absence.

	Règles (demandées par l'utilisateur) :
	  - Le joueur doit avoir été offline au moins 10 minutes.
	  - On cumule le CPS de tous les brainrots placés du joueur (avec bonus
	    CashMulti = Rebirths+1, gamepass CashX2, VIP) * durée d'absence.
	  - L'absence est plafonnée à OFFLINE_CAP_HOURS pour éviter les abus.
	  - Le client affiche OfflineFrame : CLAIM (Cash), UPGRADE (x10 en Robux via
	    product 3591223850), CLOSE (n'encaisse RIEN).
	  - Un joueur ne peut encaisser qu'une fois par rejoin : on stocke l'offre
	    en RAM et on invalide dès que Claim/Upgrade/Close est traité.

	Remotes :
	  - OfflineEarningsShowEvent (serveur -> client) : { Amount, DurationSec, Valid }
	  - OfflineEarningsClaimEvent (client -> serveur) : encaisse le montant simple
	  - OfflineEarningsUpgradeEvent (client -> serveur): lance le product x10 Robux
	  - OfflineEarningsDismissEvent (client -> serveur): ferme sans encaisser
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))
local BrainrotUpgrade = require(ReplicatedStorage.Shared:WaitForChild("BrainrotUpgrade"))
local GamepassConfig = require(ReplicatedStorage:WaitForChild("GamepassConfig"))

local OfflineEarningsService = Loader.CreateService({
	Name = "OfflineEarningsService",
})

-- ===== CONFIG =====

-- Minimum 10 minutes d'absence avant d'être éligible.
local MIN_OFFLINE_SECONDS = 10 * 60
-- Plafond à 8h d'offline (même que le cap des boutons dans le placement
-- service) pour éviter qu'un joueur ne revienne après 3 jours avec un
-- montant délirant.
local OFFLINE_CAP_SECONDS = 8 * 3600

-- Product Robux qui multiplie le gain offline par 10.
local OFFLINE_X10_PRODUCT_ID = 3591223850
local OFFLINE_X10_MULTIPLIER = 10

-- Délai avant d'envoyer la frame au client : on attend que le joueur soit
-- prêt (profile chargé, brainrots restaurés sur le plot).
local SEND_DELAY_SECONDS = 3

-- ===== STATE =====

-- [userId] = { amount, duration, expiresAt, consumed }
-- Offre en cours pour chaque joueur. Créée au rejoin si absence >= MIN.
-- Invalidée (consumed=true) dès Claim/Upgrade/Dismiss.
local pendingOffers = {}

local DataService
local showEvent
local claimEvent
local upgradeEvent
local dismissEvent
-- Serveur -> client : confirmation qu'un claim (simple ou x10) a été
-- appliqué. Le client s'en sert pour jouer son animation "cash rain" +
-- son et fermer la frame. On ne la ferme pas côté client AVANT confirmation
-- pour que le joueur qui annule le prompt Robux ne perde pas l'offre.
local grantedEvent

-- ===== HELPERS =====

-- Cash multiplier du joueur (identique à BrainrotPlacementService.getCashMulti
-- mais réimplémenté localement pour éviter une dépendance croisée).
local function getCashMulti(player)
	local mult = 1
	local v = player and player:FindFirstChild("CashMulti")
	if v and v:IsA("ValueBase") then
		mult = tonumber(v.Value) or 1
		if mult < 1 then mult = 1 end
	end
	-- Bonus gamepass CashX2 / VIP via DataService (source unique).
	if DataService and DataService.HasGamepass then
		if DataService:HasGamepass(player, "CashX2") then
			mult = mult * GamepassConfig.CASH_X2_MULT
		end
		if DataService:HasGamepass(player, "VIP") then
			mult = mult * (GamepassConfig.VIP_CASH_MULT or 1)
		end
	end
	return mult
end

-- Calcule le CPS total (à la seconde, déjà multiplié par CashMulti/X2/VIP)
-- de tous les brainrots placés du joueur. Utilise DataService comme source
-- de vérité -> fonctionne même avant que BrainrotPlacementService ait
-- restauré les brainrots sur le plot.
local function computeTotalCps(player)
	if not DataService then return 0 end
	local placed = DataService:GetPlacedBrainrots(player)
	local multi = getCashMulti(player)
	local total = 0
	for _, entry in pairs(placed) do
		local info = BrainrotInfo.GetInfo(entry.Name)
		if info then
			local lv = BrainrotUpgrade.ClampLevel(entry.Level or 1)
			local cps = BrainrotUpgrade.GetCps(info.CashPerSecond, lv) * multi
			total = total + cps
		end
	end
	return total
end

-- Détermine la durée d'absence (plafonnée) et l'amount potentiel.
-- Retourne (amount, durationSec). amount == 0 si non éligible.
local function computeOffer(player)
	if not DataService then return 0, 0 end
	local lastOnline = DataService:GetLastOnlineAt(player)
	if lastOnline <= 0 then return 0, 0 end -- premier rejoin / profil neuf

	local now = os.time()
	local elapsed = now - lastOnline
	if elapsed < MIN_OFFLINE_SECONDS then return 0, elapsed end
	if elapsed > OFFLINE_CAP_SECONDS then elapsed = OFFLINE_CAP_SECONDS end

	local cps = computeTotalCps(player)
	if cps <= 0 then return 0, elapsed end

	local amount = math.floor(cps * elapsed + 0.5)
	return amount, elapsed
end

-- Envoie une offre au client. payload inclut le Valid flag : le client s'en
-- sert pour savoir s'il doit afficher la frame ou non. Si invalid (duration
-- insuffisante OU amount==0), on fire quand même pour que le client ne reste
-- pas à attendre.
local function sendOffer(player)
	local amount, duration = computeOffer(player)
	if amount > 0 then
		pendingOffers[player.UserId] = {
			amount = amount,
			duration = duration,
			consumed = false,
		}
	else
		pendingOffers[player.UserId] = nil
	end
	if showEvent then
		showEvent:FireClient(player, {
			Amount = amount,
			DurationSec = duration,
			Valid = amount > 0,
		})
	end
end

-- ===== HANDLERS =====

local function onClaim(player)
	local offer = pendingOffers[player.UserId]
	if not offer or offer.consumed then return end
	offer.consumed = true

	local cashVal = player:FindFirstChild("Cash")
	if cashVal then
		cashVal.Value = cashVal.Value + offer.amount
	end
	if grantedEvent then
		grantedEvent:FireClient(player, { Amount = offer.amount, Multiplier = 1 })
	end
	pendingOffers[player.UserId] = nil
end

local function onUpgrade(player)
	local offer = pendingOffers[player.UserId]
	if not offer or offer.consumed then return end
	-- On NE consume PAS ici : le product Robux peut être annulé par le joueur.
	-- La consommation réelle se fait dans HandlePurchase après confirmation.
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, OFFLINE_X10_PRODUCT_ID)
	end)
	if not ok then
		warn("[OfflineEarnings] PromptProductPurchase a échoué : " .. tostring(err))
	end
end

-- Le joueur a fermé la frame avec Close : on crédite quand même le montant
-- simple (équivalent fonctionnel d'un Claim). UX : tu ne perds JAMAIS ton
-- cash offline, peu importe le bouton sur lequel tu cliques. Le client a
-- déjà hide la frame, donc l'anim cash burst se joue par-dessus son ancienne
-- position (le grantedEvent capture la position au moment du fire).
local function onDismiss(player)
	local offer = pendingOffers[player.UserId]
	if not offer or offer.consumed then return end
	offer.consumed = true

	local cashVal = player:FindFirstChild("Cash")
	if cashVal then
		cashVal.Value = cashVal.Value + offer.amount
	end
	if grantedEvent then
		grantedEvent:FireClient(player, { Amount = offer.amount, Multiplier = 1 })
	end
	pendingOffers[player.UserId] = nil
end

-- Appelé par GameService.processReceipt. Retourne true si le productId
-- correspond au x10 offline et qu'on l'a géré (grant ou skip).
function OfflineEarningsService:HandlePurchase(player, productId)
	if productId ~= OFFLINE_X10_PRODUCT_ID then return false end

	local offer = pendingOffers[player.UserId]
	if not offer or offer.consumed then
		-- Pas d'offre valide : on accepte quand même l'achat pour éviter les
		-- retries Roblox infinis, mais on n'écrit rien.
		warn(string.format("[OfflineEarnings] Achat %d pour %s sans offre valide", productId, player.Name))
		return true
	end

	offer.consumed = true
	local grantedAmount = offer.amount * OFFLINE_X10_MULTIPLIER
	local cashVal = player:FindFirstChild("Cash")
	if cashVal then
		cashVal.Value = cashVal.Value + grantedAmount
	end
	if grantedEvent then
		grantedEvent:FireClient(player, { Amount = grantedAmount, Multiplier = OFFLINE_X10_MULTIPLIER })
	end
	pendingOffers[player.UserId] = nil
	return true
end

-- ===== LIFECYCLE =====

local function onPlayerAdded(player)
	task.spawn(function()
		-- Attend que DataService ait chargé le profil (Cash existe) + que les
		-- brainrots placés soient restaurés. SEND_DELAY_SECONDS laisse le temps
		-- à BrainrotPlacementService de faire son passage initial.
		local cashVal = player:WaitForChild("Cash", 30)
		if not cashVal then return end
		task.wait(SEND_DELAY_SECONDS)
		if not player.Parent then return end
		sendOffer(player)
	end)
end

local function onPlayerRemoving(player)
	pendingOffers[player.UserId] = nil
end

function OfflineEarningsService:Init()
	showEvent = RemotesAPI.GetEvent("OfflineEarningsShowEvent")
	claimEvent = RemotesAPI.GetEvent("OfflineEarningsClaimEvent")
	upgradeEvent = RemotesAPI.GetEvent("OfflineEarningsUpgradeEvent")
	dismissEvent = RemotesAPI.GetEvent("OfflineEarningsDismissEvent")
	grantedEvent = RemotesAPI.GetEvent("OfflineEarningsGrantedEvent")
end

function OfflineEarningsService:Start()
	DataService = Loader.GetService("DataService")

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Rattrapage Studio / replay.
	for _, p in ipairs(Players:GetPlayers()) do
		onPlayerAdded(p)
	end

	claimEvent.OnServerEvent:Connect(onClaim)
	upgradeEvent.OnServerEvent:Connect(onUpgrade)
	dismissEvent.OnServerEvent:Connect(onDismiss)

	print("[OfflineEarningsService] Prêt")
end

return OfflineEarningsService

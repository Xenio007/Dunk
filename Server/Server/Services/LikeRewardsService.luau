--[[
	LikeRewardsService (Global / Cross-Server)
	Board "Like Rewards" (Workspace.Spawn.Lobby.LikeBoard).

	Architecture :
	  - 1 source de vérité partagée par TOUS les serveurs : DataStoreService.
	    Clé unique "GlobalState" qui contient { NextMilestone, NextRewardMultiplier }.
	    Écrite par UpdateAsync (CAS) pour sérialiser les avancées de palier
	    quand plusieurs serveurs détectent le crossing en même temps.
	  - Election de leader (best effort) via MemoryStoreService.HashMap : un
	    seul serveur poll l'API likes à la fois pour économiser le quota HTTP.
	  - Fan-out cross-server via MessagingService : quand un serveur a fait
	    avancer le palier dans le DataStore, il publie le nouvel état global +
	    ExpiresAt (timestamp absolu) sur le topic. TOUS les serveurs y réagissent
	    de manière identique : application du boost EVENT (15 min), refresh UI.

	Déroulement d'un palier (likes >= NextMilestone) :
	  1. Leader tente UpdateAsync("GlobalState") : transitionne au palier
	     suivant avec un random pair (math.random(1,4)*2 = 2/4/6/8) généré
	     CÔTÉ SERVER. Une fois committé, la valeur est PERSISTENTE.
	  2. Sur succès, le leader appelle MessagingService:PublishAsync avec
	     la récompense à appliquer + ExpiresAt = now + 900s.
	  3. Tous les serveurs (y compris le leader) consomment le message :
	     - ServerLuckService:SetEventMultiplierUntil(reward, expiresAt)
	     - Lecture du nouveau GlobalState pour rafraîchir l'UI partout.

	Format exact demandé :
	  - Multiplier event : math.random(1, 4) * 2  (2 / 4 / 6 / 8)
	  - Durée du boost  : 15 min (900 s) timestamp absolu
	  - Persistence     : DataStore (même valeur après shutdown)
	  - Empilement      : ServerLuckService combine SHOP * EVENT (multiplicatif)
]]

local HttpService     = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService    = game:GetService("TweenService")
local Workspace       = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local LikeRewardsService = Loader.CreateService({
	Name = "LikeRewardsService",
})

-- ===== Constantes =====

local POLL_INTERVAL_SECONDS = 90       -- 1 min 30, pour le LEADER seulement.
local NON_LEADER_REFRESH    = 30       -- les non-leaders re-lisent le DataStore 1x toutes les 30s.
local MILESTONE_STEP        = 50       -- palier exact à chaque +50 likes (50, 100, 150, ...).
local LUCK_DURATION_SECONDS = 15 * 60  -- 900s pile, comme demandé.
local JUICE_TWEEN_TIME = 0.6
local JUICE_TWEEN_INFO = TweenInfo.new(JUICE_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- DataStore + MemoryStore + Messaging keys.
local DATASTORE_NAME = "LikeRewards_v1"
local STATE_KEY      = "GlobalState"
local LEADER_MAP     = "LikeRewardsLeader_v1"
local LEADER_KEY     = "leader"
local LEADER_TTL     = 120 -- secondes : > POLL_INTERVAL_SECONDS pour ne pas perdre le lock entre 2 polls.
local MSG_TOPIC      = "LikeRewards_Milestone_v1"

-- HTTP / Roblox API.
local VOTES_URL_TEMPLATE = "https://games.roproxy.com/v1/games/%d/votes"
local FALLBACK_PLACE_ID = 70891021105035
local PLACE_TO_UNIVERSE_URL = "https://apis.roproxy.com/universes/v1/places/%d/universe"

-- ===== État partagé (cache local du DataStore) =====

local globalNextMilestone = MILESTONE_STEP
local globalNextReward    = 2
local lastKnownLikes = 0
local cachedUniverseId = nil
local jobId = (game.JobId ~= "" and game.JobId) or ("studio_" .. tostring(math.random(1, 1e9)))

local datastore
local leaderMap
local isLeader = false
local ServerLuckService

local function now()
	return Workspace:GetServerTimeNow()
end

-- ===== UI =====

local frame, progressLabel, eventNameLabel, juice, bar

local function findUI()
	local spawn = Workspace:FindFirstChild("Spawn")
	local lobby = spawn and spawn:FindFirstChild("Lobby")
	local board = lobby and lobby:FindFirstChild("LikeBoard")
	local likeUI = board and board:FindFirstChild("LikeUI")
	local f = likeUI and likeUI:FindFirstChild("Frame")
	if not f then return false end
	frame          = f
	progressLabel  = f:FindFirstChild("Progress")
	local eventIcon = f:FindFirstChild("EventIcon")
	eventNameLabel = eventIcon and eventIcon:FindFirstChild("EventName")
	bar            = f:FindFirstChild("Bar")
	juice          = bar and bar:FindFirstChild("Juice")
	return (progressLabel ~= nil) and (eventNameLabel ~= nil) and (juice ~= nil)
end

local currentJuiceTween
local function updateUI()
	if not frame and not findUI() then return end

	local lastMilestone = math.max(0, globalNextMilestone - MILESTONE_STEP)
	progressLabel.Text  = string.format("%d / %d", math.max(0, lastKnownLikes), globalNextMilestone)
	eventNameLabel.Text = string.format("x%d Luck", globalNextReward)

	local progressFromLast = lastKnownLikes - lastMilestone
	local pct = math.clamp(progressFromLast / MILESTONE_STEP, 0, 1)

	local yScale = juice.Size.Y.Scale
	local yOffset = juice.Size.Y.Offset
	local goal = UDim2.new(pct, 0, yScale, yOffset)

	if currentJuiceTween then
		currentJuiceTween:Cancel()
		currentJuiceTween = nil
	end
	currentJuiceTween = TweenService:Create(juice, JUICE_TWEEN_INFO, { Size = goal })
	currentJuiceTween:Play()
end

-- ===== Random pair (specs : math.random(1, 4) * 2) =====

local function rollEvenReward()
	return math.random(1, 4) * 2
end

-- ===== HTTP =====

local function resolveUniverseFromPlace(placeId)
	local url = string.format(PLACE_TO_UNIVERSE_URL, placeId)
	local okReq, response = pcall(HttpService.GetAsync, HttpService, url, true)
	if not okReq then
		warn("[LikeRewardsService] place->universe GET failed:", response)
		return nil
	end
	local okJson, decoded = pcall(HttpService.JSONDecode, HttpService, response)
	if not okJson or type(decoded) ~= "table" then
		warn("[LikeRewardsService] place->universe JSON decode failed:",
			tostring(response):sub(1, 200))
		return nil
	end
	return tonumber(decoded.universeId)
end

local function getUniverseId()
	if cachedUniverseId and cachedUniverseId > 0 then return cachedUniverseId end
	local direct = game.GameId
	if direct and direct > 0 then
		cachedUniverseId = direct
		return direct
	end
	if FALLBACK_PLACE_ID and FALLBACK_PLACE_ID > 0 then
		local id = resolveUniverseFromPlace(FALLBACK_PLACE_ID)
		if id then cachedUniverseId = id end
		return id
	end
	return nil
end

local function fetchLikes()
	local universeId = getUniverseId()
	if not universeId then
		warn("[LikeRewardsService] Universe id unavailable")
		return nil
	end
	local url = string.format(VOTES_URL_TEMPLATE, universeId)
	local okReq, response = pcall(HttpService.GetAsync, HttpService, url, true)
	if not okReq then
		warn(string.format("[LikeRewardsService] GetAsync failed for %s : %s", url, tostring(response)))
		return nil
	end
	local okJson, decoded = pcall(HttpService.JSONDecode, HttpService, response)
	if not okJson or type(decoded) ~= "table" then
		warn("[LikeRewardsService] JSON decode failed:", tostring(response):sub(1, 200))
		return nil
	end
	local up = tonumber(decoded.upVotes)
	if up == nil then
		warn("[LikeRewardsService] upVotes missing in response")
		return nil
	end
	return up
end

-- ===== DataStore : lecture =====

local function readGlobalState()
	if not datastore then return end
	local ok, data = pcall(function()
		return datastore:GetAsync(STATE_KEY)
	end)
	if not ok then
		warn("[LikeRewardsService] DataStore GetAsync failed:", data)
		return
	end
	if type(data) == "table" then
		globalNextMilestone = math.max(MILESTONE_STEP, tonumber(data.NextMilestone) or MILESTONE_STEP)
		globalNextReward    = tonumber(data.NextRewardMultiplier) or globalNextReward
	end
end

-- ===== DataStore : avancement de palier (CAS) =====

local function tryAdvanceMilestone(currentLikes)
	if not datastore then return nil end

	local advancedFromMilestone = nil
	local rewardThatWasJustHit  = nil
	local newMilestone           = nil
	local newReward              = nil

	local ok, err = pcall(function()
		datastore:UpdateAsync(STATE_KEY, function(old)
			local nextMilestone, nextReward
			if type(old) == "table" then
				nextMilestone = tonumber(old.NextMilestone) or MILESTONE_STEP
				nextReward    = tonumber(old.NextRewardMultiplier) or rollEvenReward()
			else
				nextMilestone = MILESTONE_STEP
				nextReward    = rollEvenReward()
			end

			if currentLikes < nextMilestone then
				return nil -- pas atteint, on annule l'écriture
			end

			advancedFromMilestone = nextMilestone
			rewardThatWasJustHit  = nextReward
			newMilestone          = nextMilestone + MILESTONE_STEP
			newReward             = rollEvenReward()

			return { NextMilestone = newMilestone, NextRewardMultiplier = newReward }
		end)
	end)

	if not ok then
		warn("[LikeRewardsService] UpdateAsync failed:", err)
		return nil
	end

	if advancedFromMilestone then
		globalNextMilestone = newMilestone
		globalNextReward    = newReward
		return advancedFromMilestone, rewardThatWasJustHit
	end
	return nil
end

-- ===== MessagingService =====

local function publishMilestoneMessage(milestone, reward, expiresAtAbs, likes)
	local payload = {
		Milestone = milestone,
		Reward    = reward,
		ExpiresAt = expiresAtAbs,
		Likes     = likes,
		FromJobId = jobId,
	}
	local okPub, pubErr = pcall(function()
		MessagingService:PublishAsync(MSG_TOPIC, payload)
	end)
	if not okPub then
		warn("[LikeRewardsService] PublishAsync failed:", pubErr)
	end
end

local function applyEventBoostFromPayload(payload)
	if type(payload) ~= "table" then return end
	local reward = tonumber(payload.Reward)
	local expAbs = tonumber(payload.ExpiresAt)
	if not reward or not expAbs then return end
	if ServerLuckService and ServerLuckService.SetEventMultiplierUntil then
		local ok, err = pcall(function()
			ServerLuckService:SetEventMultiplierUntil(reward, expAbs)
		end)
		if not ok then
			warn("[LikeRewardsService] SetEventMultiplierUntil failed:", err)
		end
	end
	local likes = tonumber(payload.Likes)
	if likes then lastKnownLikes = likes end
	readGlobalState()
	updateUI()
end

local function subscribeMessaging()
	local okSub, sub = pcall(function()
		return MessagingService:SubscribeAsync(MSG_TOPIC, function(message)
			applyEventBoostFromPayload(message and message.Data)
		end)
	end)
	if not okSub then
		warn("[LikeRewardsService] SubscribeAsync failed:", sub)
		return nil
	end
	return sub
end

-- ===== Leader election (MemoryStore.HashMap + TTL) =====

local function tryAcquireLeadership()
	if not leaderMap then return false end
	local becameLeader = false
	local ok, err = pcall(function()
		leaderMap:UpdateAsync(LEADER_KEY, function(old)
			if type(old) == "table" and old.JobId and old.JobId ~= jobId then
				return nil -- un autre serveur détient le lock, on ne le vole pas
			end
			becameLeader = true
			return { JobId = jobId, At = now() }
		end, LEADER_TTL)
	end)
	if not ok then
		warn("[LikeRewardsService] Leader UpdateAsync failed:", err)
		return false
	end
	return becameLeader
end

local function renewLeadership()
	if not leaderMap then return false end
	local stillLeader = false
	local ok = pcall(function()
		leaderMap:UpdateAsync(LEADER_KEY, function(old)
			if type(old) == "table" and old.JobId == jobId then
				stillLeader = true
				return { JobId = jobId, At = now() }
			end
			return nil
		end, LEADER_TTL)
	end)
	return ok and stillLeader
end

-- ===== Boucles =====

local function leaderPollLoop()
	while true do
		isLeader = renewLeadership()
		if not isLeader then
			isLeader = tryAcquireLeadership()
		end

		if isLeader then
			local likes = fetchLikes()
			if likes ~= nil then
				lastKnownLikes = likes
				while likes >= globalNextMilestone do
					local advanced, reward = tryAdvanceMilestone(likes)
					if not advanced then break end
					local expAbs = now() + LUCK_DURATION_SECONDS
					print(string.format(
						"[LikeRewardsService] Milestone %d hit (likes=%d) -> x%d Luck for %ds (broadcasting)",
						advanced, likes, reward, LUCK_DURATION_SECONDS))
					publishMilestoneMessage(advanced, reward, expAbs, likes)
				end
				updateUI()
			end
		end

		task.wait(POLL_INTERVAL_SECONDS)
	end
end

local function nonLeaderRefreshLoop()
	while true do
		task.wait(NON_LEADER_REFRESH)
		if not isLeader then
			readGlobalState()
			updateUI()
		end
	end
end

-- ===== Cycle de vie =====

function LikeRewardsService:Init()
	if findUI() then
		updateUI()
	end
end

function LikeRewardsService:Start()
	ServerLuckService = Loader.GetService("ServerLuckService")

	local okDs, dsOrErr = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if okDs then
		datastore = dsOrErr
	else
		warn("[LikeRewardsService] DataStore unavailable:", dsOrErr)
	end

	local okMs, msOrErr = pcall(function()
		return MemoryStoreService:GetHashMap(LEADER_MAP)
	end)
	if okMs then
		leaderMap = msOrErr
	else
		warn("[LikeRewardsService] MemoryStore unavailable:", msOrErr)
	end

	readGlobalState()
	updateUI()
	subscribeMessaging()

	task.spawn(leaderPollLoop)
	task.spawn(nonLeaderRefreshLoop)

	game:BindToClose(function()
		if not leaderMap then return end
		pcall(function()
			leaderMap:UpdateAsync(LEADER_KEY, function(old)
				if type(old) == "table" and old.JobId == jobId then
					return nil
				end
				return old
			end, 1)
		end)
	end)

	print("[LikeRewardsService] Prêt (cross-server, jobId=" .. jobId .. ")")
end

return LikeRewardsService

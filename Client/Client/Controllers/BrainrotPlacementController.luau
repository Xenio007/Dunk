--[[
	BrainrotPlacementController
	Local visual layer for the brainrot placement system.

	Responsibilities (100% client, zero network cost):
	  - Keep each button's "$X" label in sync with the server-computed
	    cash accumulation (CashPerSecond * elapsed since AccumStart),
	    capped by AccumCap.
	  - Play a quick "press" animation (button dips down then springs back)
	    when the server increments ClaimTick on that button.
	  - Enable / disable the cash label based on whether the slot is occupied.

	Design notes:
	  - We use a single Heartbeat for ALL buttons, updating only those whose
	    label is currently enabled. A set { button -> state } keeps per-button
	    data without touching the instance tree each frame.
	  - We track buttons lazily via CollectionService-like auto-discovery on
	    the plot the player currently owns, and via DescendantAdded for
	    newly-placed floors / slots.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local BrainrotInfo = require(ReplicatedStorage.Shared:WaitForChild("BrainrotInfo"))

local BrainrotPlacementController = Loader.CreateController({
	Name = "BrainrotPlacementController",
})

-- ===== CONSTANTS =====

local CASH_LABEL_NAME    = "CashLabel"
local BTN_CPS            = "CashPerSecond"
local BTN_ACCUM_START    = "AccumStart"
local BTN_ACCUM_CAP      = "AccumCap"
local BTN_CLAIM_TICK     = "ClaimTick"
local BTN_BASE_Y         = "BaseY"
local SLOT_OCCUPIED      = "SlotOccupied"

local PLACE_PROMPT_NAME  = "PlaceBrainrotPrompt"

local PRESS_DIP          = 0.12   -- studs the button visually sinks
local PRESS_TIME_DOWN    = 0.05
local PRESS_TIME_UP      = 0.15
local POST_CLAIM_FREEZE  = 1.0    -- seconds the label stays at $0 after a claim
local LABEL_UPDATE_HZ    = 0.1    -- poll rate for detecting 1s tick boundaries

local PRESS_TWEEN_DOWN = TweenInfo.new(PRESS_TIME_DOWN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_UP   = TweenInfo.new(PRESS_TIME_UP,   Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Small "bump" played on the label each time a new second of cash ticks in.
local TICK_TWEEN_INFO  = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TICK_POP_SCALE   = 1.18

-- Count-up animation: when a new second ticks in, the displayed number climbs
-- smoothly from the previous value to the new one over COUNT_UP_DURATION
-- seconds (capped well below 1s so it always finishes before the next tick).
local COUNT_UP_DURATION = 0.45
local COUNT_UP_EASE     = Enum.EasingStyle.Quad
local COUNT_UP_DIR      = Enum.EasingDirection.Out

-- Label flash colors (green range for a shimmering effect).
local FLASH_COLOR_A = Color3.fromRGB(180, 255, 140)
local FLASH_COLOR_B = Color3.fromRGB(100, 230, 80)
local FLASH_STROKE  = Color3.fromRGB(10, 40, 10)

-- Claim popup ("+$XXX" floating text that rises and fades on collection).
local POPUP_RISE_STUDS   = 6        -- how far the "+$" text rises
local POPUP_DURATION     = 1.1      -- total popup lifetime (rise + fade)
local POPUP_COLOR        = Color3.fromRGB(110, 255, 120)   -- bright green
local POPUP_STROKE_COLOR = Color3.fromRGB(5, 55, 10)
local POPUP_FONT = Font.new(
	"rbxasset://fonts/families/FredokaOne.json",
	Enum.FontWeight.Regular,
	Enum.FontStyle.Normal
)

-- Dollar logo used instead of a plain "$" character for the burst particles.
local DOLLAR_ICON_ASSET  = "rbxassetid://106254793390209"

-- Burst particles (dollar icons that fan out from the button on claim).
local BURST_COUNT        = 8
local BURST_SPREAD_STUDS = 3.2
local BURST_RISE_STUDS   = 4.5
local BURST_DURATION     = 0.85

-- Sound joué à chaque claim : asset unique, pitch qui monte à chaque claim
-- consécutif, puis redécroit vers la base si le joueur ne claim pas pendant 1s.
local CLAIM_SOUND_ID = "rbxassetid://111773238101465"
local CLAIM_SOUND_VOLUME = 0.55
local CLAIM_PITCH_BASE = 1.0       -- pitch de départ
local CLAIM_PITCH_MAX = 2.2        -- pitch le plus aigu (quand streak saturé)
local CLAIM_PITCH_STEP = 0.12      -- hausse par claim consécutif
local CLAIM_STREAK_RESET_TIME = 1.0 -- secondes sans claim avant retour à CLAIM_PITCH_BASE

-- POLISH (player feedback) : on doit savoir, quand un ClaimTick fire sur un
-- bouton, si ce bouton appartient au plot du LOCAL player. Sans ce filtre,
-- chaque joueur entendait les sons de claim et voyait les popups/bursts des
-- claims des AUTRES joueurs (parce que la barre des cash labels track tous
-- les plots). On garde le tracking universel pour la barre `$X` qui tick
-- silencieusement, mais on bloque les juicy effets (sound, +$XXX popup,
-- burst de pièces) qui sont strictement locaux au joueur qui claim.
local localPlayerPlot = nil
local function isLocalPlayerButton(button)
	if not localPlayerPlot or not localPlayerPlot.Parent then return false end
	return button:IsDescendantOf(localPlayerPlot)
end

-- ===== STATE =====
-- button -> {
--   label            : TextLabel,
--   gui              : BillboardGui,
--   connections      : { RBXScriptConnection, ... },
--   lastTick         : number,
--   pressTween       : Tween?,
--   tickTween        : Tween?,
--   basePos          : Vector3,
--   lastSecondsShown : number, -- integer seconds currently reflected on the label
--   countUpValue     : NumberValue, -- drives the smooth number climb animation
--   countUpTween     : Tween?,
--   lastDisplayedAmount : number, -- cash currently visible on the label
--   pendingClaimAmount  : number?, -- amount snapshotted on AccumStart reset
-- }
local tracked = {}
local activeCount = 0

-- Per-plot connection bookkeeping. We now track cash labels on EVERY plot
-- (not just the local player's), so non-owners also see the cash climbing
-- on buttons of plots they visit. The server is already authoritative —
-- the label is just a client-side visualization of attributes (CPS,
-- AccumStart, AccumCap) which replicate to all clients equally.
local plotConnections = {} -- plot -> { RBXScriptConnection, ... }

-- ===== UTILS =====

local function formatCash(n)
	n = n or 0
	if n < 1000 then
		return "$" .. tostring(math.floor(n))
	end
	return "$" .. BrainrotInfo.FormatShort(n)
end

-- Returns the integer number of FULL seconds of accumulation on this button,
-- bounded by the cap. The displayed cash is always `cps * fullSeconds` so the
-- label only ever jumps in clean per-second increments synced on AccumStart.
local function computeFullSeconds(button)
	local accumStart = button:GetAttribute(BTN_ACCUM_START) or 0
	if accumStart <= 0 then return 0 end
	local cap = button:GetAttribute(BTN_ACCUM_CAP) or (8 * 3600)
	local elapsed = Workspace:GetServerTimeNow() - accumStart
	if elapsed < 0 then elapsed = 0 end
	if elapsed > cap then elapsed = cap end
	return math.floor(elapsed)
end

local function playTickBump(state)
	local ui = state.label:FindFirstChildOfClass("UIScale")
	if not ui then return end
	if state.tickTween then state.tickTween:Cancel() end
	ui.Scale = TICK_POP_SCALE
	state.tickTween = TweenService:Create(ui, TICK_TWEEN_INFO, { Scale = 1 })
	state.tickTween:Play()
end

-- Smoothly animate the label text from `fromAmount` to `toAmount`. We tween a
-- NumberValue driven by TweenService and rewrite the label on each Changed
-- event, which gives a fluid "counting up" feel for free.
local function playCountUp(state, fromAmount, toAmount)
	if state.countUpTween then
		state.countUpTween:Cancel()
	end
	local nv = state.countUpValue
	nv.Value = fromAmount
	local tween = TweenService:Create(
		nv,
		TweenInfo.new(COUNT_UP_DURATION, COUNT_UP_EASE, COUNT_UP_DIR),
		{ Value = toAmount }
	)
	state.countUpTween = tween
	tween:Play()
end

-- Updates the label in place. Only triggers a bump animation when the integer
-- second bucket advances (i.e. one real second of cash has ticked in).
local function updateLabel(state, button)
	-- Freeze window after a claim: keep the label at $0 until the freeze ends.
	if state.freezeUntil and os.clock() < state.freezeUntil then
		if state.label.Text ~= "$0" then
			state.label.Text = "$0"
		end
		state.lastSecondsShown = 0
		return
	end

	local cps = button:GetAttribute(BTN_CPS) or 0
	if cps <= 0 then
		if state.label.Text ~= "$0" then
			state.label.Text = "$0"
		end
		state.lastSecondsShown = 0
		return
	end

	local seconds = computeFullSeconds(button)
	if seconds == state.lastSecondsShown then return end

	local previousSeconds = state.lastSecondsShown
	local advanced = seconds > previousSeconds
	state.lastSecondsShown = seconds

	local newAmount = cps * seconds

	if advanced and seconds > 0 then
		-- Smooth climb from the previously displayed value to the new one.
		playCountUp(state, cps * previousSeconds, newAmount)
		playTickBump(state)
	else
		-- Skip animation when rewinding (reset to 0 etc.).
		if state.countUpTween then state.countUpTween:Cancel() end
		state.countUpValue.Value = newAmount
		state.label.Text = formatCash(newAmount)
	end
end

local function playPress(state, button)
	if state.pressTween then state.pressTween:Cancel() end

	local basePos = state.basePos
	local down = CFrame.new(basePos - Vector3.new(0, PRESS_DIP, 0)) * button.CFrame.Rotation
	local up   = CFrame.new(basePos) * button.CFrame.Rotation

	local t1 = TweenService:Create(button, PRESS_TWEEN_DOWN, { CFrame = down })
	t1.Completed:Connect(function()
		if not tracked[button] then return end
		local t2 = TweenService:Create(button, PRESS_TWEEN_UP, { CFrame = up })
		state.pressTween = t2
		t2:Play()
	end)
	state.pressTween = t1
	t1:Play()

	-- Pop the label for extra emphasis.
	local ui = state.label:FindFirstChildOfClass("UIScale")
	if ui then
		if state.tickTween then state.tickTween:Cancel() end
		ui.Scale = 1.35
		state.tickTween = TweenService:Create(ui, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		state.tickTween:Play()
	end
end

-- ===== CLAIM JUICE =====

-- Builds a standalone BillboardGui attached to `anchor` carrying a single
-- TextLabel. Returns the gui, label, and a UIScale for pop-in animations.
local function buildFloatingLabel(anchor, text, sizeUdim, textSize)
	local bb = Instance.new("BillboardGui")
	bb.Name = "ClaimPopup"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = sizeUdim or UDim2.fromScale(6, 2)
	bb.ClipsDescendants = false
	bb.MaxDistance = 250

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = POPUP_FONT
	label.Text = text
	label.TextColor3 = POPUP_COLOR
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	if textSize then
		label.TextScaled = false
		label.TextSize = textSize
	else
		label.TextScaled = true
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = POPUP_STROKE_COLOR
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.4
	scale.Parent = label

	label.Parent = bb
	bb.Parent = anchor
	return bb, label, scale
end

-- Big central "+$XXX" popup that jumps out of the button, rises and fades.
local function playClaimPopup(button, amount)
	local text = "+$" .. BrainrotInfo.FormatShort(amount)
	local bb, label, scale = buildFloatingLabel(button, text, UDim2.fromScale(8, 2.4))
	bb.StudsOffset = Vector3.new(0, 1.5, 0)

	-- Pop in (scale bounce).
	TweenService:Create(
		scale,
		TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.0 }
	):Play()

	-- Rise up with a touch of horizontal drift for character.
	local drift = Vector3.new(math.random(-30, 30) * 0.02, POPUP_RISE_STUDS, 0)
	local riseInfo = TweenInfo.new(POPUP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(bb, riseInfo, {
		StudsOffset = Vector3.new(0, 1.5, 0) + drift,
	}):Play()

	-- Fade during the second half.
	task.delay(POPUP_DURATION * 0.45, function()
		if not bb.Parent then return end
		local fadeInfo = TweenInfo.new(POPUP_DURATION * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()
		local s = label:FindFirstChildOfClass("UIStroke")
		if s then
			TweenService:Create(s, fadeInfo, { Transparency = 1 }):Play()
		end
	end)

	Debris:AddItem(bb, POPUP_DURATION + 0.2)
end

-- A burst of small dollar logos that scatter outward from the button.
local function playClaimBurst(button)
	for i = 1, BURST_COUNT do
		local angle = (i / BURST_COUNT) * math.pi * 2 + math.random() * 0.4
		local dist = BURST_SPREAD_STUDS * (0.6 + math.random() * 0.6)
		local offset = Vector3.new(math.cos(angle) * dist, 0.4, math.sin(angle) * dist)
		local target = offset + Vector3.new(0, BURST_RISE_STUDS * (0.7 + math.random() * 0.5), 0)

		local bb = Instance.new("BillboardGui")
		bb.Name = "ClaimBurst"
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.Size = UDim2.fromScale(2, 2)
		bb.ClipsDescendants = false
		bb.MaxDistance = 250
		bb.StudsOffset = Vector3.new(0, 0.5, 0)

		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromScale(1, 1)
		icon.Image = DOLLAR_ICON_ASSET
		icon.ImageColor3 = Color3.new(1, 1, 1)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = bb

		local scale = Instance.new("UIScale")
		scale.Scale = 0.3
		scale.Parent = icon

		bb.Parent = button

		-- Snappy pop-in.
		TweenService:Create(
			scale,
			TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 0.9 + math.random() * 0.3 }
		):Play()

		-- Outward arc.
		TweenService:Create(
			bb,
			TweenInfo.new(BURST_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ StudsOffset = Vector3.new(0, 0.5, 0) + target }
		):Play()

		-- Fade during the second half.
		task.delay(BURST_DURATION * 0.4, function()
			if not bb.Parent then return end
			TweenService:Create(
				icon,
				TweenInfo.new(BURST_DURATION * 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ ImageTransparency = 1 }
			):Play()
		end)

		Debris:AddItem(bb, BURST_DURATION + 0.2)
	end
end

-- One-shot claim sound avec pitch escalant :
--   - Chaque claim consécutif augmente le pitch par CLAIM_PITCH_STEP
--     jusqu'à CLAIM_PITCH_MAX (à partir de là c'est verrouillé en haut tant
--     que le joueur continue à claim).
--   - Si le joueur ne claim pas pendant CLAIM_STREAK_RESET_TIME secondes,
--     le pitch redécroit à CLAIM_PITCH_BASE au prochain claim.
local _claimCurrentPitch = CLAIM_PITCH_BASE
local _claimLastAt = 0

local function playClaimSound()
	local now = os.clock()
	if (now - _claimLastAt) >= CLAIM_STREAK_RESET_TIME then
		-- Reset de streak : retombe au pitch de base.
		_claimCurrentPitch = CLAIM_PITCH_BASE
	else
		_claimCurrentPitch = math.min(CLAIM_PITCH_MAX, _claimCurrentPitch + CLAIM_PITCH_STEP)
	end
	_claimLastAt = now

	local s = Instance.new("Sound")
	s.SoundId = CLAIM_SOUND_ID
	s.Volume = CLAIM_SOUND_VOLUME
	s.PlaybackSpeed = _claimCurrentPitch
	s.PlayOnRemove = false
	s.Parent = SoundService
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	Debris:AddItem(s, math.max(s.TimeLength + 0.5, 3))
end

local function refreshGuiEnabled(state, button)
	local cps = button:GetAttribute(BTN_CPS) or 0
	local enabled = cps > 0
	if state.gui.Enabled ~= enabled then
		state.gui.Enabled = enabled
	end
	if enabled then
		if not state.active then
			state.active = true
			activeCount += 1
		end
		updateLabel(state, button)
	else
		if state.active then
			state.active = false
			activeCount -= 1
		end
		state.label.Text = "$0"
	end
end

-- ===== TRACKING =====

local function untrack(button)
	local state = tracked[button]
	if not state then return end
	for _, c in ipairs(state.connections) do c:Disconnect() end
	if state.pressTween then state.pressTween:Cancel() end
	if state.tickTween then state.tickTween:Cancel() end
	if state.countUpTween then state.countUpTween:Cancel() end
	if state.countUpValue then state.countUpValue:Destroy() end
	if state.active then activeCount -= 1 end
	tracked[button] = nil
end

local function track(button)
	if tracked[button] then return end
	if not button:IsA("BasePart") then return end

	-- Non-blocking: if the CashLabel isn't there yet (plot may not have an
	-- owner yet, so the server hasn't created it), just bail. The watcher
	-- below listens for CashLabel additions and calls track() again once
	-- the label appears. Blocking here with WaitForChild would stall the
	-- whole plot-watching loop for 3s PER empty button, which can easily
	-- exceed a minute on a server with many unowned plots and freezes every
	-- label from refreshing (including on the owner's plot).
	local gui = button:FindFirstChild(CASH_LABEL_NAME)
	if not gui then return end
	local label = gui:FindFirstChild("Text")
	if not label or not label:IsA("TextLabel") then return end

	-- Upgrade the label to a flashier look (done once, idempotent).
	label.TextColor3 = FLASH_COLOR_A
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = FLASH_STROKE
		stroke.Thickness = 3.5
	end
	if not label:FindFirstChildOfClass("UIScale") then
		local s = Instance.new("UIScale")
		s.Scale = 1
		s.Parent = label
	end

	local baseY = button:GetAttribute(BTN_BASE_Y) or button.Position.Y

	-- Hidden NumberValue used to drive the count-up animation. Tweening a
	-- NumberValue and reacting on Changed is the cheapest and smoothest way
	-- to animate an integer display in Roblox.
	local countUpValue = Instance.new("NumberValue")
	countUpValue.Name = "_CashCountUp"
	countUpValue.Value = 0

	local state = {
		label = label,
		gui = gui,
		connections = {},
		lastTick = button:GetAttribute(BTN_CLAIM_TICK) or 0,
		basePos = Vector3.new(button.Position.X, baseY, button.Position.Z),
		active = false,
		colorState = 0, -- 0 = A, 1 = B for flashing
		flashTween = nil,
		tickTween = nil,
		countUpValue = countUpValue,
		countUpTween = nil,
		freezeUntil = 0,
		lastSecondsShown = 0,
		lastDisplayedAmount = 0,
		pendingClaimAmount = nil,
	}

	-- Rewrite the label every time the tweened value changes. math.floor keeps
	-- the number clean (no decimals during the climb).
	countUpValue.Changed:Connect(function(v)
		local amount = math.floor(v + 0.5)
		state.label.Text = formatCash(amount)
		state.lastDisplayedAmount = amount
	end)
	tracked[button] = state

	refreshGuiEnabled(state, button)

	-- Attribute change -> re-arm / update immediately.
	table.insert(state.connections, button:GetAttributeChangedSignal(BTN_CPS):Connect(function()
		refreshGuiEnabled(state, button)
	end))
	table.insert(state.connections, button:GetAttributeChangedSignal(BTN_ACCUM_START):Connect(function()
		-- AccumStart was reset (placement / claim). Snapshot the previously
		-- displayed amount so the ClaimTick callback (which may fire AFTER
		-- this reset due to attribute replication order) still knows what
		-- the player just collected.
		state.pendingClaimAmount = state.lastDisplayedAmount
		-- Force the label back to $0 immediately so the visual restarts on the
		-- exact second, regardless of the polling loop's phase.
		if state.countUpTween then state.countUpTween:Cancel() end
		state.countUpValue.Value = 0
		state.lastSecondsShown = 0
		state.lastDisplayedAmount = 0
		if state.active and not (state.freezeUntil and os.clock() < state.freezeUntil) then
			state.label.Text = "$0"
		end
	end))
	table.insert(state.connections, button:GetAttributeChangedSignal(BTN_CLAIM_TICK):Connect(function()
		local tick = button:GetAttribute(BTN_CLAIM_TICK) or 0
		if tick ~= state.lastTick then
			state.lastTick = tick

			-- Prefer the amount captured when AccumStart was reset; fall back
			-- to whatever is currently displayed (covers edge cases where the
			-- two attribute changes arrive in a different order).
			local claimed = state.pendingClaimAmount
			if not claimed or claimed <= 0 then
				claimed = state.lastDisplayedAmount or 0
			end
			state.pendingClaimAmount = nil

			-- Freeze and hard-reset the displayed amount so the player can't see
			-- any transient number coming from replication ordering.
			state.freezeUntil = os.clock() + POST_CLAIM_FREEZE
			state.lastSecondsShown = 0
			if state.countUpTween then state.countUpTween:Cancel() end
			state.countUpValue.Value = 0
			state.label.Text = "$0"
			state.lastDisplayedAmount = 0
			playPress(state, button)

			-- Juice: floating "+$XXX" popup + $ burst particles + sfx.
			-- POLISH : juice STRICTEMENT local au joueur. Si le bouton n'est pas
			-- sur le plot du local player, on saute toute l'animation visuelle
			-- + sonore. Le label $0 / count-up reste en place pour que les
			-- visiteurs voient la cash bar des autres plots se mettre à jour
			-- normalement, mais sans le bruit / popup intrusif.
			if claimed > 0 and isLocalPlayerButton(button) then
				playClaimPopup(button, claimed)
				playClaimBurst(button)
				playClaimSound()
			end
		end
	end))
	table.insert(state.connections, button.AncestryChanged:Connect(function(_, parent)
		if not parent then untrack(button) end
	end))
end

local function isButton(inst)
	return inst:IsA("BasePart") and inst.Parent and inst.Parent.Name == "Buttons"
end

local function stopWatchingPlot(plot)
	local conns = plotConnections[plot]
	if conns then
		for _, c in ipairs(conns) do c:Disconnect() end
		plotConnections[plot] = nil
	end
	-- Untrack any buttons that still reference this plot.
	for btn in pairs(tracked) do
		if btn:IsDescendantOf(plot) then untrack(btn) end
	end
end

local function startWatchingPlot(plot)
	if plotConnections[plot] then return end
	local conns = {}
	plotConnections[plot] = conns

	for _, desc in ipairs(plot:GetDescendants()) do
		if isButton(desc) then track(desc) end
	end

	table.insert(conns, plot.DescendantAdded:Connect(function(desc)
		if isButton(desc) then
			-- Small defer so the server-created CashLabel has time to replicate.
			task.defer(track, desc)
		elseif desc.Name == CASH_LABEL_NAME then
			-- A CashLabel just got added to an already-existing button (happens
			-- when a plot gets assigned to a player during our session and the
			-- server finally creates its CashLabels). Track the parent now.
			local parent = desc.Parent
			if parent and parent:IsA("BasePart") and parent.Parent and parent.Parent.Name == "Buttons" then
				task.defer(track, parent)
			end
		end
	end))
	table.insert(conns, plot.DescendantRemoving:Connect(function(desc)
		if tracked[desc] then untrack(desc) end
	end))
end

-- ===== LIFECYCLE =====

function BrainrotPlacementController:Start()
	local player = Players.LocalPlayer
	local plots = Workspace:WaitForChild("Spawn"):WaitForChild("Plots")

	local plotNumVal = player:WaitForChild("PlotNumber", 60)
	if not plotNumVal then
		warn("[BrainrotPlacementController] Aucun plot assigné")
		return
	end

	-- ===== Cash labels: track EVERY plot, not just our own =====
	-- The owner of a plot sees their cash climb; non-owners must also see
	-- it climb when they visit another player's plot. All the data we need
	-- (CPS / AccumStart / AccumCap / ClaimTick) lives in replicated
	-- attributes, so every client can reconstruct the label identically.
	for _, plot in ipairs(plots:GetChildren()) do
		startWatchingPlot(plot)
	end
	plots.ChildAdded:Connect(function(plot)
		startWatchingPlot(plot)
	end)
	plots.ChildRemoved:Connect(function(plot)
		stopWatchingPlot(plot)
	end)

	-- ===== Owner-specific: place prompts & tool handling =====
	local currentPlot = nil
	local function resolveCurrentPlot()
		local plot = plots:FindFirstChild("Plot" .. plotNumVal.Value)
		if not plot then return end
		currentPlot = plot
		-- POLISH : expose le plot du local player au filtre de juice (sound /
		-- popup / burst). Tant que cette ref n'est pas posée, AUCUN juice ne
		-- joue (aucun risque d'entendre les claims des autres plots avant que
		-- le PlotNumber soit résolu).
		localPlayerPlot = plot
	end

	plotNumVal:GetPropertyChangedSignal("Value"):Connect(resolveCurrentPlot)
	resolveCurrentPlot()

	-- ===== Flashing label color loop (1 loop for all labels) =====
	task.spawn(function()
		while true do
			task.wait(0.45)
			if activeCount > 0 then
				for _, state in pairs(tracked) do
					if state.active then
						state.colorState = 1 - state.colorState
						local target = (state.colorState == 0) and FLASH_COLOR_A or FLASH_COLOR_B
						if state.flashTween then state.flashTween:Cancel() end
						state.flashTween = TweenService:Create(
							state.label,
							TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
							{ TextColor3 = target }
						)
						state.flashTween:Play()
					end
				end
			end
		end
	end)

	-- ===== Cash label refresh =====
	-- Poll at LABEL_UPDATE_HZ so we catch each 1s tick boundary with minimal
	-- latency. updateLabel() is a no-op when the integer-second bucket hasn't
	-- advanced, so this stays cheap (a handful of attribute reads per button).
	task.spawn(function()
		while true do
			task.wait(LABEL_UPDATE_HZ)
			if activeCount > 0 then
				for btn, state in pairs(tracked) do
					if state.active then
						updateLabel(state, btn)
					end
				end
			end
		end
	end)

	-- ===== Place-prompt visibility (owner-only, toggled by equipped brainrot) =====
	-- Débounce : sur un plot avec beaucoup de slots/floors, refreshPlacePrompts
	-- itère tout currentPlot:GetDescendants() ce qui est cher. Quand un buy
	-- de poids cause une cascade Tool.Destroy/Add (cascade qui déclenche ces
	-- callbacks N fois en une frame), on ne lance qu'UN seul refresh différé.
	local placePromptDirty = false
	local function refreshPlacePromptsImmediate()
		if not currentPlot then return end
		local char = player.Character
		local hasBrainrot = false
		if char then
			for _, t in ipairs(char:GetChildren()) do
				if t:IsA("Tool") and BrainrotInfo.GetInfo(t.Name) then
					hasBrainrot = true
					break
				end
			end
		end

		for _, desc in ipairs(currentPlot:GetDescendants()) do
			if desc.Name == PLACE_PROMPT_NAME and desc:IsA("ProximityPrompt") then
				local slot = desc.Parent
				if slot and slot:IsA("BasePart") then
					local usable = slot.Transparency < 0.95
					local empty = not slot:GetAttribute(SLOT_OCCUPIED)
					desc.Enabled = hasBrainrot and usable and empty
				end
			end
		end
	end
	local function refreshPlacePrompts()
		if placePromptDirty then return end
		placePromptDirty = true
		task.defer(function()
			placePromptDirty = false
			refreshPlacePromptsImmediate()
		end)
	end

	local function hookCharacter(char)
		refreshPlacePrompts()
		char.ChildAdded:Connect(function(c)
			if c:IsA("Tool") then refreshPlacePrompts() end
		end)
		char.ChildRemoved:Connect(function(c)
			if c:IsA("Tool") then refreshPlacePrompts() end
		end)
	end

	player.CharacterAdded:Connect(hookCharacter)
	if player.Character then hookCharacter(player.Character) end

	-- Slot occupancy or prompt (newly-created on a new floor) -> refresh too.
	local function wirePromptWatcher(plot)
		plot.DescendantAdded:Connect(function(desc)
			if desc.Name == PLACE_PROMPT_NAME and desc:IsA("ProximityPrompt") then
				task.defer(refreshPlacePrompts)
			elseif desc:IsA("BasePart") and desc.Parent and desc.Parent.Name == "Slots" then
				desc:GetAttributeChangedSignal(SLOT_OCCUPIED):Connect(refreshPlacePrompts)
			end
		end)
		for _, desc in ipairs(plot:GetDescendants()) do
			if desc:IsA("BasePart") and desc.Parent and desc.Parent.Name == "Slots" then
				desc:GetAttributeChangedSignal(SLOT_OCCUPIED):Connect(refreshPlacePrompts)
			end
		end
	end
	if currentPlot then wirePromptWatcher(currentPlot) end
	plotNumVal:GetPropertyChangedSignal("Value"):Connect(function()
		if currentPlot then wirePromptWatcher(currentPlot) end
		refreshPlacePrompts()
	end)

	-- ===== Inventory sound: when a brainrot Tool is added to the local
	-- player's Backpack (i.e. received into inventory), play the first Sound
	-- found inside the Tool. Local-only: we parent the transient sound to
	-- PlayerGui so only this player hears it. Does nothing if the Tool has
	-- no Sound descendant. =====
	local playerGui = player:WaitForChild("PlayerGui")

	local function playInventorySoundFor(tool)
		if not tool:IsA("Tool") then return end
		if not BrainrotInfo.GetInfo(tool.Name) then return end

		-- Deferred: children of the Tool may arrive a frame after the Tool
		-- itself (Roblox replication).
		task.defer(function()
			if not tool.Parent then return end
			local source
			for _, d in ipairs(tool:GetDescendants()) do
				if d:IsA("Sound") then source = d break end
			end
			if not source then return end
			local s = source:Clone()
			s.PlayOnRemove = false
			s.Parent = playerGui -- local-only: server / other clients don't hear it
			s:Play()
			s.Ended:Once(function() s:Destroy() end)
			-- Safety cleanup in case Ended never fires (streamed / short sound).
			task.delay(math.max(s.TimeLength + 0.2, 1.0), function()
				if s.Parent then s:Destroy() end
			end)
		end)
	end

	local function hookBackpack(backpack)
		backpack.ChildAdded:Connect(playInventorySoundFor)
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then hookBackpack(backpack) end
	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then hookBackpack(c) end
	end)

	print("[BrainrotPlacementController] Prêt")
end

return BrainrotPlacementController

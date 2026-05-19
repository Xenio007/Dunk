--[[
	KickReadyAnimLoopController (Controller module)
	Quand le joueur est dans la part Workspace.Spawn.Areas.KickReady :
	  - Force les bras tendus devant lui en écrivant chaque frame dans
	    Motor6D.Transform des épaules (et identité sur coudes/poignets).
	  - Place un lucky block (ReplicatedStorage.LUCKBLOCK.Basic) entre les
	    deux mains (visuel pur, ancré, client only).

	Stop à la sortie de la zone OU quand la séquence Dunk démarre.
--]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local Loader     = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared.RemotesAPI)

local KickReadyAnimLoopController = Loader.CreateController({
	Name = "KickReadyAnimLoopController",
})

-- Modèle source du lucky block tenu dans les mains.
local LUCKY_BLOCK_TEMPLATE_PATH = { "LUCKBLOCK", "Basic" }

-- Angle des épaules. 90° = horizontal pile au niveau de l'épaule.
-- 75° = bras un peu plus bas que l'épaule.
local ARM_FORWARD_ANGLE_DEG = 75
-- Angle inward : positif rapproche les mains, négatif les écarte.
local ARM_INWARD_ANGLE_DEG = 10
-- Distance supplémentaire vers l'avant pour le bloc tenu (en studs).
-- Augmente pour éloigner le bloc du visage du joueur.
local BLOCK_FORWARD_OFFSET = 0.6

local function isPointInsidePart(point, part)
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(localPoint.X) <= half.X
		and math.abs(localPoint.Y) <= half.Y
		and math.abs(localPoint.Z) <= half.Z
end

function KickReadyAnimLoopController:Start()
	local player    = Players.LocalPlayer
	local dunkEvent = RemotesAPI.GetEvent("DunkSequenceEvent")

	local spawnFolder = Workspace:WaitForChild("Spawn")
	local areas       = spawnFolder:WaitForChild("Areas")
	local kickReady   = areas:WaitForChild("KickReady")

	local luckBlockFolder = ReplicatedStorage:WaitForChild(LUCKY_BLOCK_TEMPLATE_PATH[1], 30)
	local blockTemplate   = luckBlockFolder and luckBlockFolder:WaitForChild(LUCKY_BLOCK_TEMPLATE_PATH[2], 30)

	local sequenceLock = false
	local heldBlock = nil
	local armsConn = nil   -- Stepped: pose des bras (après anims, avant rendu)
	local blockBindName = nil  -- RenderStep bind: pose du bloc juste avant le rendu
	local motors = nil  -- { rightShoulder, leftShoulder, rightSign, leftSign, extras }

	local function destroyBlock()
		if armsConn then
			armsConn:Disconnect()
			armsConn = nil
		end
		if blockBindName then
			pcall(function() RunService:UnbindFromRenderStep(blockBindName) end)
			blockBindName = nil
		end
		if heldBlock and heldBlock.Parent then
			heldBlock:Destroy()
		end
		heldBlock = nil
		motors = nil
	end

	-- Récupère les Motor6D des épaules + des coudes/poignets pour les forcer
	-- en avant chaque frame. Compatible R15 et R6.
	local function collectMotors(character)
		local m = { extras = {} }

		-- R15
		local rightUpper = character:FindFirstChild("RightUpperArm")
		local leftUpper  = character:FindFirstChild("LeftUpperArm")
		if rightUpper and leftUpper then
			m.right = rightUpper:FindFirstChild("RightShoulder")
			m.left  = leftUpper:FindFirstChild("LeftShoulder")
			m.rightSign = 1
			m.leftSign  = -1

			local rLower = character:FindFirstChild("RightLowerArm")
			local lLower = character:FindFirstChild("LeftLowerArm")
			local rHand  = character:FindFirstChild("RightHand")
			local lHand  = character:FindFirstChild("LeftHand")
			local function add(motor)
				if motor and motor:IsA("Motor6D") then
					table.insert(m.extras, motor)
				end
			end
			if rLower then add(rLower:FindFirstChild("RightElbow")) end
			if lLower then add(lLower:FindFirstChild("LeftElbow")) end
			if rHand  then add(rHand:FindFirstChild("RightWrist"))  end
			if lHand  then add(lHand:FindFirstChild("LeftWrist"))   end
			return m
		end

		-- R6 fallback
		local torso = character:FindFirstChild("Torso")
		if torso then
			m.right = torso:FindFirstChild("Right Shoulder")
			m.left  = torso:FindFirstChild("Left Shoulder")
			m.rightSign = 1
			m.leftSign  = -1
			return m
		end
		return nil
	end

	-- Applique l'override des bras chaque frame. Doit être appelé après
	-- l'étape d'animation Roblox pour que notre Transform soit la dernière
	-- valeur appliquée avant le rendu. RenderStepped tourne AVANT l'évaluation
	-- des animations donc il est écrasé. Stepped (PreSimulation) tourne APRÈS
	-- les animations et notre écriture survit jusqu'à la frame suivante.
	local function applyArmsForward()
		if not motors then return end
		local forwardRad = math.rad(ARM_FORWARD_ANGLE_DEG)
		local inwardRad  = math.rad(ARM_INWARD_ANGLE_DEG)

		if motors.right and motors.right.Parent then
			motors.right.Transform = CFrame.Angles(forwardRad, motors.rightSign * -inwardRad, 0)
		end
		if motors.left and motors.left.Parent then
			motors.left.Transform = CFrame.Angles(forwardRad, motors.leftSign * -inwardRad, 0)
		end
		-- Coudes et poignets bloqués droits.
		for _, m in ipairs(motors.extras) do
			if m.Parent then
				m.Transform = CFrame.identity
			end
		end
	end

	local function spawnBlock(character)
		destroyBlock()
		if not blockTemplate then
			motors = collectMotors(character)
			return
		end

		local clone = blockTemplate:Clone()
		clone.Name = "KickReadyHeldLuckyBlock"

		if not clone.PrimaryPart then
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then
					clone.PrimaryPart = d
					break
				end
			end
		end

		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.PivotOffset = CFrame.new()
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
			end
		end
		clone.WorldPivot = clone:GetBoundingBox()
		clone.Parent = Workspace
		heldBlock = clone

		motors = collectMotors(character)

		local leftHand  = character:FindFirstChild("LeftHand")  or character:FindFirstChild("Left Arm")
		local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")

		-- 1) Stepped (PreSimulation) tourne APRÈS l'évaluation des animations,
		--    donc notre Transform survit jusqu'au rendu. RenderStepped serait
		--    écrasé par l'animation idle.
		armsConn = RunService.Stepped:Connect(function()
			applyArmsForward()
		end)

		-- 2) Le bloc est repositionné juste AVANT le rendu (RenderStep priorité
		--    Camera+1) pour utiliser la position des mains à jour cette frame.
		--    Sinon le bloc traîne d'une frame derrière le character qui bouge.
		local bindName = "KickReadyHeldBlock_" .. tostring(math.random(1, 1e9))
		blockBindName = bindName
		RunService:BindToRenderStep(bindName, Enum.RenderPriority.Camera.Value + 1, function()
			if not heldBlock or not heldBlock.Parent then return end
			local hrp = character:FindFirstChild("HumanoidRootPart")
			if not hrp then return end

			local mid
			if leftHand and leftHand.Parent and rightHand and rightHand.Parent then
				mid = (leftHand.Position + rightHand.Position) * 0.5
			else
				mid = (hrp.CFrame * CFrame.new(0, 0.5, -2)).Position
			end

			local look = hrp.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			if forward.Magnitude > 0.001 then
				forward = forward.Unit
			else
				forward = look
			end
			heldBlock:PivotTo(CFrame.lookAt(mid, mid + forward, Vector3.yAxis) * CFrame.new(0, 0, -BLOCK_FORWARD_OFFSET))
		end)
	end

	local function startHold()
		if sequenceLock then return end
		local character = player.Character
		if not character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end
		if heldBlock and heldBlock.Parent then return end
		spawnBlock(character)
	end

	local inZone = false

	RunService.Heartbeat:Connect(function()
		local character = player.Character
		if not character then
			if inZone then
				inZone = false
				destroyBlock()
			end
			return
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp or not kickReady or not kickReady.Parent then
			if inZone then
				inZone = false
				destroyBlock()
			end
			return
		end

		local inside = isPointInsidePart(hrp.Position, kickReady)
		if inside and not inZone then
			inZone = true
			startHold()
		elseif not inside and inZone then
			inZone = false
			destroyBlock()
		elseif inside and inZone then
			-- Si le block a disparu, on le respawn.
			startHold()
		end
	end)

	player.CharacterAdded:Connect(function()
		if armsConn then armsConn:Disconnect() armsConn = nil end
		if blockBindName then
			pcall(function() RunService:UnbindFromRenderStep(blockBindName) end)
			blockBindName = nil
		end
		heldBlock = nil
		motors = nil
		inZone = false
	end)

	dunkEvent.OnClientEvent:Connect(function(phase, _data)
		if phase == "Start" then
			sequenceLock = true
			destroyBlock()
		elseif phase == "End" or phase == "BrainrotLost" or phase == "BrainrotSold" then
			task.delay(0.1, function()
				sequenceLock = false
			end)
		end
	end)

	-- Le DunkGameController set _G.DunkSequenceInProgress AVANT même que la
	-- séquence serveur ne soit lancée (anim cliente joue d'abord 1.55s).
	-- On surveille ce flag pour stopper le hold avant que notre KFS soit
	-- écrasée par le force-bras-devant.
	RunService.Heartbeat:Connect(function()
		if _G.DunkSequenceInProgress and (heldBlock or armsConn) then
			sequenceLock = true
			destroyBlock()
		end
	end)

	print("[KickReadyAnimLoopController] Prêt")
end

return KickReadyAnimLoopController


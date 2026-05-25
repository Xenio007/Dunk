--[[
	UpgradeVfxController
	POLISH (player feedback) : les particules d'upgrade des autres joueurs
	polluaient la vue de chaque joueur (parce qu'elles étaient spawnées côté
	serveur et répliquées à tous les clients).

	Ce controller écoute le RemoteEvent PlayUpgradeVfxEvent que le serveur fire
	UNIQUEMENT au plot owner concerné. Il recrée localement le VFX en clonant
	le template ReplicatedStorage.VFX.UpgradeVFX et en attachant les emitters
	selon leurs attributs (EmitDelay / EmitCount / EmitDuration).

	Conséquence :
	  - L'owner voit ses particules d'upgrade comme avant.
	  - Les autres joueurs ne voient absolument rien (zéro réplication).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))
local RemotesAPI = require(ReplicatedStorage.Shared:WaitForChild("RemotesAPI"))

local UpgradeVfxController = Loader.CreateController({
	Name = "UpgradeVfxController",
})

-- Spawne le VFX d'upgrade local sur la PrimaryPart cible. Reproduit à
-- l'identique l'ancienne logique server-side (cf. ancien playUpgradeVfxOnBrainrot
-- dans BrainrotPlacementService) :
--   * scale des Sizes en fonction de la BB du brainrot,
--   * lecture des attributs EmitDelay / EmitCount / EmitDuration,
--   * cleanup de l'attachment après la fin de vie de la dernière particule.
local function spawnLocalUpgradeVfx(primary)
	if not primary or not primary.Parent then return end

	local vfxFolder = ReplicatedStorage:FindFirstChild("VFX")
	local vfxTemplate = vfxFolder and vfxFolder:FindFirstChild("UpgradeVFX")
	if not vfxTemplate then return end

	local attach = vfxTemplate:Clone()
	attach.Name = "UpgradeVFX_LocalActive"
	attach.Visible = true

	-- Taille du brainrot : on prend la plus grande diménsion de la BB du Model
	-- parent (si dispo) pour scaler le VFX. Fallback : taille de la primary.
	local bbSize = primary.Size
	local parentModel = primary:FindFirstAncestorOfClass("Model")
	if parentModel then
		local _, modelSize = parentModel:GetBoundingBox()
		bbSize = modelSize
	end
	local maxDim = math.max(bbSize.X, bbSize.Y, bbSize.Z)
	local scale = math.clamp(maxDim / 6, 0.5, 4)

	local emitters = {}
	local maxAliveTime = 0
	for _, d in ipairs(attach:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			local oldSeq = d.Size
			local newKeys = {}
			for _, kp in ipairs(oldSeq.Keypoints) do
				table.insert(newKeys, NumberSequenceKeypoint.new(
					kp.Time, kp.Value * scale, kp.Envelope * scale
				))
			end
			d.Size = NumberSequence.new(newKeys)
			d.Enabled = false

			local emitDelay = tonumber(d:GetAttribute("EmitDelay")) or 0
			local emitDuration = tonumber(d:GetAttribute("EmitDuration")) or 0
			local emitCount = tonumber(d:GetAttribute("EmitCount"))
			if emitCount == nil then
				emitCount = (d.Rate and d.Rate > 0) and d.Rate or 10
			end

			table.insert(emitters, {
				emitter = d,
				delay = math.max(0, emitDelay),
				count = math.max(0, emitCount),
				duration = math.max(0, emitDuration),
			})

			local lifetimeMax = d.Lifetime.Max
			local finish = emitDelay + emitDuration + lifetimeMax
			if finish > maxAliveTime then maxAliveTime = finish end
		end
	end

	attach.Parent = primary

	for _, e in ipairs(emitters) do
		task.delay(e.delay, function()
			if not e.emitter or not e.emitter.Parent then return end
			if e.duration > 0 then
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

	task.delay(maxAliveTime + 0.1, function()
		if attach and attach.Parent then
			attach:Destroy()
		end
	end)
end

function UpgradeVfxController:Start()
	local evt = RemotesAPI.GetEvent("PlayUpgradeVfxEvent")
	if not evt then
		warn("[UpgradeVfxController] PlayUpgradeVfxEvent introuvable")
		return
	end

	evt.OnClientEvent:Connect(function(primary)
		-- Le serveur peut envoyer une référence à une part qui n'a pas encore
		-- replicate son parent côté client (rare mais possible). On défre d'une
		-- frame pour laisser la réplication se stabiliser, puis on spawn.
		if typeof(primary) ~= "Instance" or not primary:IsA("BasePart") then return end
		if not primary:IsDescendantOf(Workspace) then
			task.wait()
			if not primary or not primary:IsDescendantOf(Workspace) then return end
		end
		spawnLocalUpgradeVfx(primary)
	end)

	print("[UpgradeVfxController] Prêt")
end

return UpgradeVfxController

--[[
	PlayerBrainrotTransform
	Helper serveur (pas un Service Loader : c'est juste un module utilitaire)
	qui transforme le character d'un joueur en brainrot. Utilisé par
	DunkLuckyBlockService (après le spin reveal) et BrainrotControlService
	(commande chat /c <nom>).

	Ce que la transformation fait côté serveur (donc répliquée à TOUS les
	clients, y compris le serveur en mode play) :
	  - Clone le mesh du brainrot, le weld au HRP du character du joueur.
	  - Cache le character original en mettant Transparency=1 sur ses BasePart
	    et Decal/Texture (sauf le HRP qui doit rester pour la physique).
	  - Stocke les transparences originales pour pouvoir restaurer.

	Revert :
	  - Détruit le visuel weldé.
	  - Restaure les transparences originales.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local PlayerBrainrotTransform = {}

-- [userId] = { visual = Model, savedTransparencies = { [Instance] = number } }
local active = {}

local function getWorldMinY(model)
	local minY = math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf = d.CFrame
			local hx, hy, hz = d.Size.X * 0.5, d.Size.Y * 0.5, d.Size.Z * 0.5
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local wp = cf * Vector3.new(sx * hx, sy * hy, sz * hz)
						if wp.Y < minY then minY = wp.Y end
					end
				end
			end
		end
	end
	if minY == math.huge then
		return model:GetPivot().Position.Y
	end
	return minY
end

local function getCharacterBottomY(character)
	local minY = math.huge
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			local bottom = d.Position.Y - d.Size.Y * 0.5
			if bottom < minY then minY = bottom end
		end
	end
	if minY == math.huge then return character:GetPivot().Position.Y end
	return minY
end

local function findBrainrotTemplate(name)
	local brainrotsFolder = ReplicatedStorage:FindFirstChild("Brainrots")
	if not brainrotsFolder then return nil end
	for _, rarityFolder in ipairs(brainrotsFolder:GetChildren()) do
		if rarityFolder:IsA("Folder") then
			local found = rarityFolder:FindFirstChild(name)
			if found and found:IsA("Model") then return found end
		end
	end
	local target = name:lower()
	for _, rarityFolder in ipairs(brainrotsFolder:GetChildren()) do
		if rarityFolder:IsA("Folder") then
			for _, m in ipairs(rarityFolder:GetChildren()) do
				if m:IsA("Model") and m.Name:lower() == target then
					return m
				end
			end
		end
	end
	return nil
end

-- Cache toutes les BaseParts (sauf HRP) et Decals/Textures du character.
-- Stocke les valeurs originales pour restauration ultérieure.
local function hideCharacter(character, visualToExclude)
	local saved = {}
	for _, d in ipairs(character:GetDescendants()) do
		-- Skip tout ce qui est dans le visuel brainrot (parente DANS le character
		-- comme un accessoire). Sans ce skip, on cacherait aussi le mesh brainrot.
		if visualToExclude and d:IsDescendantOf(visualToExclude) then
			continue
		end
		if d:IsA("BasePart") then
			if d.Name ~= "HumanoidRootPart" then
				saved[d] = d.Transparency
				d.Transparency = 1
			end
		elseif d:IsA("Decal") or d:IsA("Texture") then
			saved[d] = d.Transparency
			d.Transparency = 1
		end
	end
	return saved
end

local function restoreCharacter(saved)
	if not saved then return end
	for inst, originalT in pairs(saved) do
		if inst and inst.Parent then
			inst.Transparency = originalT or 0
		end
	end
end

--[[
	Apply(player, brainrotName)
	Transforme le character du joueur en ce brainrot. Le visuel est créé
	côté serveur et répliqué à tous les clients. Si le joueur est déjà
	transformé, l'ancienne transformation est revertée d'abord.

	Retourne le Model du visuel (pour reférence externe), ou nil si échec.
]]
function PlayerBrainrotTransform.Apply(player, brainrotName)
	if not player or typeof(brainrotName) ~= "string" then return nil end

	-- Cleanup d'une transformation précédente si elle existe.
	PlayerBrainrotTransform.Remove(player)

	local character = player.Character
	if not character then return nil end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local template = findBrainrotTemplate(brainrotName)
	if not template then return nil end

	local visual = template:Clone()
	visual.Name = "PlayerBrainrotVisual"

	-- PrimaryPart fallback.
	if not visual.PrimaryPart then
		for _, d in ipairs(visual:GetDescendants()) do
			if d:IsA("BasePart") then
				visual.PrimaryPart = d
				break
			end
		end
	end
	local visualPrimary = visual.PrimaryPart
	if not visualPrimary then visual:Destroy(); return nil end

	-- Strip Humanoid + AnimationController : on ne veut que le visuel.
	local oldHum = visual:FindFirstChildOfClass("Humanoid")
	if oldHum then oldHum:Destroy() end
	local oldAC = visual:FindFirstChildOfClass("AnimationController")
	if oldAC then oldAC:Destroy() end
	for _, d in ipairs(visual:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end

	-- Re-active tous les BillboardGui du template ("Billy" : nom / rarete / CPS).
	-- Souvent ces GUIs sont controles par un script local du template qu'on vient
	-- de detruire ; sans cette boucle, ils restent invisibles ou non-attaches.
	-- On force Enabled=true et Adornee=visualPrimary pour qu'ils s'affichent
	-- au-dessus du mesh weldé au character.
	for _, d in ipairs(visual:GetDescendants()) do
		if d:IsA("BillboardGui") then
			d.Enabled = true
			if not d.Adornee or not d.Adornee.Parent then
				d.Adornee = visualPrimary
			end
		end
	end

	-- Parts setup : non-ancrées, no-collide, massless. PivotOffset zeroed pour
	-- que le pivot soit le centre des parts (évite les décalages bizarres).
	for _, d in ipairs(visual:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			-- Toutes massless SAUF la primaire, pour que l'assembly ait une masse
			-- non-nulle apres weld au HRP. Sans cela Roblox peut traiter l'assembly
			-- comme vide et le weld se comporte de maniere erratique.
			d.Massless = (d ~= visualPrimary)
		end
	end

	-- Place le visuel à la position du HRP avec la BONNE orientation :
	--   1) yaw du HRP (autour de Y) pour que le brainrot regarde dans la même
	--      direction que le joueur,
	--   2) rotation NATIVE du template (template:GetPivot() - position) pour
	--      que le brainrot soit dans son orientation naturelle (debout, etc.).
	-- Sans (2), beaucoup de templates apparaissent couchés ou de travers parce
	-- que leur pivot a une rotation interne pour les redresser dans le monde.
	local hrpLook = hrp.CFrame.LookVector
	local hrpYaw = math.atan2(-hrpLook.X, -hrpLook.Z)
	local yawCF = CFrame.Angles(0, hrpYaw, 0)
	-- Calcule le yaw du brainrot pour qu'il regarde vers une BlockPart de la
	-- zone Sell (la cible du joueur). On ignore la composante Y (regard dans
	-- le plan horizontal seulement) pour que le brainrot reste droit, sans
	-- pitcher vers le centre vertical de la part. Fallback : si aucune
	-- BlockPart trouvee, on garde le yaw du HRP du joueur.
	local targetYaw = hrpYaw
	local spawnFolder = Workspace:FindFirstChild("Spawn")
	local sellModel = spawnFolder and spawnFolder:FindFirstChild("Sell")
	if sellModel then
		for _, d in ipairs(sellModel:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "BlockPart" then
				local dx = d.Position.X - hrp.Position.X
				local dz = d.Position.Z - hrp.Position.Z
				if dx*dx + dz*dz > 0.01 then
					targetYaw = math.atan2(-dx, -dz)
				end
				break
			end
		end
	end
	local yawForVisual = CFrame.Angles(0, targetYaw, 0)

	local templateRot = template:GetPivot() - template:GetPivot().Position

	-- ===== PANNEAU DE CONTRÔLE D'ORIENTATION DU BRAINROT =====
	-- Le pivot natif des templates de brainrots n'est pas standardisé : certains
	-- modèles sont importés couchés sur le flanc, d'autres face contre terre,
	-- d'autres à l'envers. Ces trois offsets (en DEGRÉS) sont appliqués
	-- localement APRÈS le yaw du HRP. Joue avec les valeurs 0, 90, -90, 180
	-- jusqu'à ce que le brainrot soit DEBOUT et REGARDE DEVANT.

	-- Axe X : bascule d'avant en arrière (pencher la tête vers les pieds ou
	-- vers le ciel). Change ça si le modèle est "face contre terre" ou
	-- "sur le dos".
	local offsetRotationX = 180

	-- Axe Y : pivote sur lui-même comme une toupie (rotation autour de l'axe
	-- vertical). Change ça si le modèle est debout mais regarde sur le côté
	-- ou complètement vers l'arrière.
	local offsetRotationY = 180

	-- Axe Z : bascule sur le côté (comme une crêpe qu'on retourne).
	-- C'est GÉNÉRALEMENT celui-ci qu'il faut ajuster quand le brainrot est
	-- couché sur le flanc.
	local offsetRotationZ = 180

	local offsetCF = CFrame.Angles(
		math.rad(offsetRotationX),
		math.rad(offsetRotationY),
		math.rad(offsetRotationZ)
	)
	visual:PivotTo(CFrame.new(hrp.Position) * yawForVisual * templateRot * offsetCF)

	-- Aligne le bas du mesh sur les pieds du character (correction Y).
	local visualBottomY = getWorldMinY(visual)
	local charBottomY = getCharacterBottomY(character)
	local yOffset = charBottomY - visualBottomY
	visual:PivotTo(visual:GetPivot() + Vector3.new(0, yOffset, 0))

	-- Weld TOUTES les parts non-primaires à la primaire AVANT de welder la
	-- primaire au HRP. Sans ça, les parts sans Motor6D entre elles tombent
	-- au sol dès qu'on parente au Workspace.
	for _, d in ipairs(visual:GetDescendants()) do
		if d:IsA("BasePart") and d ~= visualPrimary then
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = visualPrimary
			wc.Part1 = d
			wc.Parent = visualPrimary
		end
	end

	-- Weld la PrimaryPart au HRP du character via Weld classique. Le visuel
	-- est ensuite parente DANS le character (comme un accessoire). Avec un
	-- Weld classique parente DANS le character, le visuel suit le HRP
	-- naturellement sans interferer avec le Humanoid ni le mouvement.
	local weld = Instance.new("Weld")
	weld.Name = "BrainrotVisualWeld"
	weld.Part0 = hrp
	weld.Part1 = visualPrimary
	weld.C0 = hrp.CFrame:ToObjectSpace(visualPrimary.CFrame)
	weld.C1 = CFrame.new()
	weld.Parent = visualPrimary

	-- Animator : joue l'idle du brainrot en boucle si dispo.
	local ac = Instance.new("AnimationController")
	ac.Parent = visual
	local animator = Instance.new("Animator")
	animator.Parent = ac

	local animsFolder = visual:FindFirstChild("Anims") or visual:FindFirstChild("Animations")
	if animsFolder then
		local idleAnim = animsFolder:FindFirstChild("Idle") or animsFolder:FindFirstChildWhichIsA("Animation")
		if idleAnim and idleAnim:IsA("Animation") then
			local track = animator:LoadAnimation(idleAnim)
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Idle
			track:Play()
		end
	end

	-- IMPORTANT : parent au Workspace AVANT de cacher le character. Si on
	-- parentère au Workspace après, le visuel apparait pendant 1-2 frames
	-- en même temps que le character original visible.
	visual.Parent = character

	-- Cache le character d'origine.
	local saved = hideCharacter(character, visual)

	active[player.UserId] = {
		visual = visual,
		savedTransparencies = saved,
	}

	-- Marqueur d'etat lu par les controllers client (SatchelController, etc.)
	-- pour cacher l'UI inventaire / bloquer les raccourcis tant que le joueur
	-- est sous forme brainrot. Repliqué automatiquement à tous les clients.
	player:SetAttribute("IsBrainrot", true)

	return visual
end

--[[
	Remove(player, skipRestore)
	Detruit le visuel brainrot welde. Restaure la visibilite du character
	SAUF si skipRestore=true (utilise quand on appelle player:LoadCharacter()
	juste apres : pas la peine de rendre l'ancien character visible une frame
	avant qu'il soit detruit, ce qui causait un flash visuel du skin original).
]]
function PlayerBrainrotTransform.Remove(player, skipRestore)
	if not player then return end
	-- On ecrit toujours l'attribut a false, meme si aucune entree active n'existe :
	-- garantit qu'un IsBrainrot orphelin (player respawn pendant la transformation)
	-- soit nettoye et que le SatchelController reactive l'inventaire.
	pcall(function() player:SetAttribute("IsBrainrot", false) end)

	local entry = active[player.UserId]
	if not entry then return end
	active[player.UserId] = nil

	if entry.visual and entry.visual.Parent then
		entry.visual:Destroy()
	end
	if not skipRestore then
		restoreCharacter(entry.savedTransparencies)
	end
end

--[[
	IsActive(player) -> bool
	Retourne true si le joueur est actuellement transformé en brainrot.
]]
function PlayerBrainrotTransform.IsActive(player)
	return player and active[player.UserId] ~= nil
end

-- Filet de securite : si un character se reset (respawn, mort, /c suivi de
-- mort, etc.), on nettoie systematiquement la transformation. Sans ca,
-- l'attribut IsBrainrot pourrait rester a true sur le Player apres un reset
-- (le visuel etait parente DANS le character donc deja detruit), bloquant
-- l'UI inventaire indefiniment cote client.
local function hookPlayer(player)
	player.CharacterAdded:Connect(function()
		-- skipRestore = true : le nouveau character est tout neuf, rien a
		-- restaurer (les references stockees pointent sur l'ancien character).
		PlayerBrainrotTransform.Remove(player, true)
	end)
	player.CharacterRemoving:Connect(function()
		-- Nettoie l'entree avant que le character ne soit detruit pour eviter
		-- les references pendantes dans `active`.
		PlayerBrainrotTransform.Remove(player, true)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	hookPlayer(player)
end
Players.PlayerAdded:Connect(hookPlayer)
Players.PlayerRemoving:Connect(function(player)
	active[player.UserId] = nil
end)

return PlayerBrainrotTransform

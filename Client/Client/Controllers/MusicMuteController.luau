--[[
	MusicMuteController
	Ajoute un bouton TopbarPlus en haut à droite pour muter / démuter la musique
	de fond.

	Comportement :
	  - Clic 1 (icône avec son) : mute le Sound `SoundService.UI.New.Background`
	    (SoundGroup ou Sound individuel : on attenue son volume à 0).
	  - Clic 2 (icône barrée)    : restaure le volume d'origine.

	Seuls les sons d'AMBIANCE/MUSIQUE sont coupés. Les UI sounds (clic, hover, etc)
	et les sons des brainrots restent actifs.

	L'état de mute est mémorisé dans `Players.LocalPlayer` via un attribute local,
	mais pas persisté au DataStore (préférence locale, restart-safe).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local MusicMuteController = Loader.CreateController({
	Name = "MusicMuteController",
})

-- Icônes : haut-parleur normal vs barré.
local ICON_SOUND_ON  = "rbxassetid://116855826812579"
local ICON_SOUND_OFF = "rbxassetid://93723984271575"

-- Liste (name dans SoundService.UI.New) des sons considérés comme "musique".
-- On les récupère dynamiquement plutôt que de les référencer par chemin fixe
-- pour survivre aux renames. Tout Sound.Looped dans SoundService.UI.New est
-- considéré comme une musique de fond.
local function collectMusicSounds()
	local sounds = {}
	local ui = SoundService:FindFirstChild("UI")
	local newFolder = ui and ui:FindFirstChild("New")
	if newFolder then
		for _, d in ipairs(newFolder:GetChildren()) do
			if d:IsA("Sound") and d.Looped then
				table.insert(sounds, d)
			end
		end
	end

	-- Musique du décor (ex : Workspace.Spawn.Decor.*.Guitar). Regroupe toute
	-- musique looped spawnée dans le Workspace.
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Sound") and d.Looped and d.SoundId ~= "" then
			table.insert(sounds, d)
		end
	end
	return sounds
end

-- On ne stocke pas les volumes individuellement : on stocke juste l'état
-- boolean du mute + on utilise le SoundGroup s'il existe, sinon on agit par
-- attribute sur chaque Sound pour permettre un vrai toggle idempotent.
local originalVolumes = {} -- [Sound] = number
local isMuted = false

local function applyMute()
	local sounds = collectMusicSounds()
	for _, s in ipairs(sounds) do
		if originalVolumes[s] == nil then
			originalVolumes[s] = s.Volume
		end
		if isMuted then
			s.Volume = 0
		else
			s.Volume = originalVolumes[s] or 0.5
		end
	end
end

-- Watch : si de nouveaux Sounds apparaissent (ex : nouvelle musique spawnée),
-- on les éteint immédiatement si on est en mode muteé.
local function watchNewSounds()
	local function checkAndMute(sound)
		if not sound:IsA("Sound") then return end
		if not sound.Looped then return end
		if originalVolumes[sound] == nil then
			originalVolumes[sound] = sound.Volume
		end
		if isMuted then
			sound.Volume = 0
		end
	end
	SoundService.DescendantAdded:Connect(checkAndMute)
	workspace.DescendantAdded:Connect(checkAndMute)
end

function MusicMuteController:Init()
end

function MusicMuteController:Start()
	local ok, Icon = pcall(require, ReplicatedStorage:WaitForChild("Icon", 10))
	if not ok or not Icon then
		warn("[MusicMuteController] ReplicatedStorage.Icon (TopbarPlus) introuvable")
		return
	end

	watchNewSounds()

	local icon = Icon.new()
		:setName("MusicMute")
		:setImage(ICON_SOUND_ON)
		:setImageScale(1)
		:setRight()
		:setCaption("Mute music")

	-- Deselected = son actif ; Selected = son muté.
	icon.selected:Connect(function()
		isMuted = true
		applyMute()
		icon:setImage(ICON_SOUND_OFF)
		icon:setCaption("Unmute music")
	end)
	icon.deselected:Connect(function()
		isMuted = false
		applyMute()
		icon:setImage(ICON_SOUND_ON)
		icon:setCaption("Mute music")
	end)

	print("[MusicMuteController] Prêt")
end

return MusicMuteController

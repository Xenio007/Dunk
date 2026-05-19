--[[
	VipChatTagController
	Préfixe automatiquement les messages des joueurs VIP dans le chat avec un
	tag coloré "[VIP]" (doré). Utilise le hook client de TextChatService :
	`OnIncomingMessage` pour décorer le message avant son rendu.

	Source de vérité : l'attribute `HasVIP` posé par GamepassService sur chaque
	Player qui possède le gamepass VIP. Les attributes sont répliqués à TOUS
	les clients, donc n'importe qui peut savoir qui est VIP pour afficher le tag.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local VipChatTagController = Loader.CreateController({
	Name = "VipChatTagController",
})

local VIP_PREFIX = "<font color=\"#FFD84A\"><b>[VIP]</b></font> "

function VipChatTagController:Start()
	-- Hook CLIENT : décore chaque message à l'affichage. S'applique aussi aux
	-- messages du LocalPlayer lui-même.
	TextChatService.OnIncomingMessage = function(message)
		local props = Instance.new("TextChatMessageProperties")

		-- Les system messages (SYSTEM) n'ont pas de TextSource ; on les laisse passer.
		local textSource = message.TextSource
		if not textSource then return props end

		local userId = textSource.UserId
		local player = Players:GetPlayerByUserId(userId)
		if not player then return props end

		if player:GetAttribute("HasVIP") == true then
			local prefix = message.PrefixText or ""
			props.PrefixText = VIP_PREFIX .. prefix
		end

		return props
	end

	print("[VipChatTagController] Prêt")
end

return VipChatTagController

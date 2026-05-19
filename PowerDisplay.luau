--[[
	PowerDisplay - Module partagé entre UI et PowerPopup
	Gère la valeur affichée de la power (découplée de la valeur réelle)
]]

local PowerDisplay = {}

-- La power affichée (ce que le label montre)
PowerDisplay.DisplayedPower = 0

-- Callback appelé quand la power affichée change
PowerDisplay._onUpdate = nil

function PowerDisplay:SetDisplayedPower(value)
	self.DisplayedPower = value
	if self._onUpdate then
		self._onUpdate(value)
	end
end

function PowerDisplay:AddDisplayedPower(amount)
	self.DisplayedPower = self.DisplayedPower + amount
	if self._onUpdate then
		self._onUpdate(self.DisplayedPower)
	end
end

function PowerDisplay:OnUpdate(callback)
	self._onUpdate = callback
end

return PowerDisplay
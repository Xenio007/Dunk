--[[
	CrashLogController (TEMPORAIRE - debug only)
	Capture toutes les erreurs Lua client + trace les events Tool autour du
	crash weight shop. Les logs sont sauvegardés dans une StringValue dans
	ReplicatedStorage qu'on peut lire même après un crash Studio.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext = game:GetService("ScriptContext")

local Loader = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Loader"))

local CrashLogController = Loader.CreateController({
	Name = "CrashLogController",
})

local MAX_LOG_LINES = 200
local logBuffer = {}
local logValue

local function flushLog()
	if logValue then
		logValue.Value = table.concat(logBuffer, "\n")
	end
end

local function addLog(line)
	table.insert(logBuffer, string.format("[%.3f] %s", os.clock(), tostring(line)))
	if #logBuffer > MAX_LOG_LINES then
		table.remove(logBuffer, 1)
	end
	flushLog()
end

function CrashLogController:Start()
	local player = Players.LocalPlayer

	-- StringValue partagée visible même après le crash via Studio explorer.
	logValue = Instance.new("StringValue")
	logValue.Name = "_CrashLog_" .. player.Name
	logValue.Value = ""
	logValue.Parent = ReplicatedStorage

	addLog("=== Crash log started ===")

	-- Capture toutes les erreurs Lua.
	ScriptContext.Error:Connect(function(msg, trace, scr)
		addLog("ERROR: " .. tostring(msg))
		if scr then addLog("  Script: " .. scr:GetFullName()) end
		if trace then addLog("  Trace: " .. tostring(trace)) end
	end)

	-- Hook les events Tool dans le Backpack et le Character.
	local function hookContainer(container, label)
		container.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				addLog(string.format("%s ChildAdded: %s", label, child.Name))
			end
		end)
		container.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then
				addLog(string.format("%s ChildRemoved: %s", label, child.Name))
			end
		end)
	end

	local function hookBackpack()
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then hookContainer(bp, "Backpack") end
	end
	hookBackpack()
	player.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then
			addLog("New Backpack appeared")
			hookContainer(c, "Backpack")
		end
	end)

	local function hookCharacter(char)
		addLog("CharacterAdded: " .. char.Name)
		hookContainer(char, "Character")
	end
	if player.Character then hookCharacter(player.Character) end
	player.CharacterAdded:Connect(hookCharacter)

	print("[CrashLogController] Capture activée (logs dans ReplicatedStorage._CrashLog_" .. player.Name .. ")")
end

return CrashLogController
--!strict
--[[
	Roblox's own fade of the local character, held off while Player/CameraRig draws the body.

	PlayerModule's CameraModule fades the character its camera looks from (its TransparencyController,
	updated right after the camera at Camera priority) once the camera is within 2 studs of its
	focus. Under the rig's permanent LockFirstPerson that is every frame, and at its full fade the
	controller marks itself dirty again on every update, so it writes LocalTransparencyModifier on
	every part of the character every frame; Player/FirstPersonBody (Camera + 2), which decides what
	is drawn, then wrote most of them back: about two writes a part a frame, three for a dead body
	under Player/SpectatorView.

	`hook(suppressed)` wraps the controller's Update (the method of the TransparencyController
	module's class table, which CameraModule requires once and makes its controller from): while
	`suppressed()` holds, Update writes nothing and only marks the controller dirty, so it fades
	everything again the first frame it runs. Player/CameraRig suppresses it while it places the
	camera for a player who isn't a spectator, which is when FirstPersonBody writes the character:
	FirstPersonBody then writes only what changes. Spectating someone (the rig inactive, Roblox's
	first person on their eyes), a spectator, and the rig off keep Roblox's fade as before.

	Like Player/MouseLook's hook of the camera's input, it is tried once Roblox's control scripts are
	there (joining: waited for); a PlayerModule without this method (a fork, a future change) is
	left alone (`hooked` false) and FirstPersonBody still puts every part right each frame (it
	compares each part with what it should be), at the old cost.
]]

local Players = game:GetService("Players")

local CameraFade = {}

-- nil: not tried yet; true / false: Roblox's controller could / couldn't be hooked.
local hooked: boolean? = nil
local waiting = false
local suppressed: () -> boolean = function()
	return false
end

-- Wraps the controller's Update (once). Returns whether it is hooked.
local function hook(): boolean
	if hooked ~= nil then
		return hooked
	end
	local scripts = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
	local playerModule = scripts and scripts:FindFirstChild("PlayerModule")
	local cameraModule = playerModule and playerModule:FindFirstChild("CameraModule")
	local fadeModule = cameraModule and cameraModule:FindFirstChild("TransparencyController")
	if fadeModule == nil or not fadeModule:IsA("ModuleScript") then
		-- (The control scripts may not be there yet: tried again once they are.)
		return false
	end
	local ok = pcall(function()
		local Controller = (require :: any)(fadeModule)
		local update = Controller.Update
		assert(type(update) == "function", "no TransparencyController.Update")
		Controller.Update = function(self: any, ...: any): ...any
			if suppressed() then
				-- (Everything is written again the first frame it runs.)
				self.transparencyDirty = true
				return
			end
			return update(self, ...)
		end
	end)
	hooked = ok
	if not ok then
		warn("[IceVoxel] Roblox's character fade could not be held off: the first-person body writes over it")
	end
	return ok
end

--[[
	Holds Roblox's fade of the local character off while `isSuppressed()` (Player/CameraRig: placing
	the camera for a player who isn't a spectator); hooked now, or as soon as Roblox's control
	scripts arrive.
]]
function CameraFade.hook(isSuppressed: () -> boolean)
	suppressed = isSuppressed
	if hook() or hooked ~= nil or waiting then
		return
	end
	waiting = true
	task.spawn(function()
		local player = Players.LocalPlayer
		local scripts = player:WaitForChild("PlayerScripts", 10)
		local playerModule = scripts and scripts:WaitForChild("PlayerModule", 10)
		local cameraModule = playerModule and playerModule:WaitForChild("CameraModule", 10)
		if cameraModule then
			cameraModule:WaitForChild("TransparencyController", 10)
		end
		waiting = false
		if not hook() then
			hooked = false
		end
	end)
end

-- Is Roblox's fade held off when asked (its controller hooked)?
function CameraFade.hooked(): boolean
	return hooked == true
end

return CameraFade

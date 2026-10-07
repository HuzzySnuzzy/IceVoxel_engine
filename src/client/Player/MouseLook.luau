--!strict
--[[
	The Mouse Settings that turn the camera (Options > Controls > Mouse Settings, Minecraft's
	MouseSettingsScreen), on Roblox's own camera:

	  Sensitivity   UserInputService.MouseDeltaSensitivity = PlayerSettings.mouseSensitivity
	                (Minecraft's curve: 100% is 1, Roblox's own feel; 0% 0.064, 200% 4.1). It scales
	                the mouse's movement for the camera on top of the player's Roblox camera
	                sensitivity (Roblox's menu).
	  Invert Mouse  Roblox's camera scripts (PlayerModule's CameraModule) take their turn from
	                CameraInput.getRotation every frame; while inverted, its vertical part is turned
	                round when the keyboard and mouse are the input in use (Settings/Keybinds.
	                usingKeys): a gamepad's stick and a touch drag keep their direction, as
	                Minecraft inverts only the mouse. Hooked once, the first time it is switched
	                on; a game without Roblox's camera scripts can't invert (`available` false,
	                and the Mouse Settings page says so).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Keybinds = require(script.Parent.Parent.Settings.Keybinds)

local MouseLook = {}

local inverted = false
-- nil: not tried yet; true / false: the camera's input could / couldn't be hooked.
local hooked: boolean? = nil

-- Hooks Roblox's CameraInput.getRotation (once). Returns whether it is hooked.
local function hook(): boolean
	if hooked ~= nil then
		return hooked
	end
	local scripts = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
	local playerModule = scripts and scripts:FindFirstChild("PlayerModule")
	local cameraModule = playerModule and playerModule:FindFirstChild("CameraModule")
	local inputModule = cameraModule and cameraModule:FindFirstChild("CameraInput")
	if inputModule == nil or not inputModule:IsA("ModuleScript") then
		-- (The control scripts may not be there yet: tried again at the next change.)
		return false
	end
	local ok = pcall(function()
		local CameraInput = (require :: any)(inputModule)
		local original = CameraInput.getRotation
		assert(type(original) == "function", "no CameraInput.getRotation")
		CameraInput.getRotation = function(...)
			local rotation = original(...)
			if inverted and typeof(rotation) == "Vector2" and Keybinds.usingKeys() then
				return Vector2.new(rotation.X, -rotation.Y)
			end
			return rotation
		end
	end)
	hooked = ok
	if not ok then
		warn("[IceVoxel] Invert Mouse: Roblox's camera scripts could not be hooked")
	end
	return ok
end

-- The Sensitivity setting as a multiplier (PlayerSettings.mouseSensitivity).
function MouseLook.setSensitivity(multiplier: number)
	UserInputService.MouseDeltaSensitivity = math.max(multiplier, 0.01)
end

local waiting = false

-- The Invert Mouse setting.
function MouseLook.setInverted(on: boolean)
	inverted = on
	if on and not hook() and hooked == nil and not waiting then
		-- (Joining: Roblox's control scripts may arrive after this; hooked when they do.)
		waiting = true
		task.spawn(function()
			local player = Players.LocalPlayer
			local scripts = player:WaitForChild("PlayerScripts", 10)
			local playerModule = scripts and scripts:WaitForChild("PlayerModule", 10)
			local cameraModule = playerModule and playerModule:WaitForChild("CameraModule", 10)
			if cameraModule then
				cameraModule:WaitForChild("CameraInput", 10)
			end
			waiting = false
			if not hook() then
				hooked = false
			end
		end)
	end
end

-- Can the mouse be inverted here (false once hooking Roblox's camera failed)?
function MouseLook.available(): boolean
	return hooked ~= false
end

return MouseLook

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

	A raised firearm (Interaction/Firearms, Player/AimCamera) uses the same hook, taken as the
	weapons start (`hookCamera`):
	  Recoil        `kick` turns the camera by a shot's kick (and back by its recovery) through the
	                camera's own input: the next CameraInput.getRotation adds it, so Roblox's camera
	                keeps the turn as if the mouse had made it (a kick never waits more than
	                MAX_KICK degrees). Without the hook `kicks` is false and Player/AimCamera shows
	                the recoil as a passing turn of the view instead.
	  Zoom          `setZoomSensitivity`: the turn's share in the sights (1 / zoom), so the view
	                moves as fast on the screen however far it is zoomed; every input's turn (mouse,
	                stick, touch) is scaled in the hook, else (no hook) the mouse's alone through
	                MouseDeltaSensitivity on top of the Sensitivity setting.

	The camera rig (Player/CameraRig) uses it for freelook and focus:
	  Turn          `turn` queues a turn (radians: x right, y down) that the next getRotation adds
	                in full (no cap, unlike a kick): freelook's snap back, while the input still
	                moves the aim.
	  Room          `setRoom`: the radians the camera has left to turn each way while freelooking;
	                the input's turn is clamped to it (math.huge each way: no limit).
	  Focus         `setFocusShare`: the turn's share while the eyes focus (the focus field of view
	                over the setting's), multiplied with the zoom's share.
	`hooked` says whether all this reaches the camera (freelook needs it).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Keybinds = require(script.Parent.Parent.Settings.Keybinds)

local MouseLook = {}

local inverted = false
-- nil: not tried yet; true / false: the camera's input could / couldn't be hooked.
local hooked: boolean? = nil
-- The Sensitivity setting (MouseDeltaSensitivity without the zoom), the zoom's share of every
-- turn, and the kick waiting for the camera (radians: Roblox's turn, x right, y down).
local sensitivity = 1
local zoomShare = 1
local kickX, kickY = 0, 0
-- Freelook (Player/CameraRig): the turn waiting for the camera (radians: x right, y down), the
-- room left each way (radians; math.huge: none), and the focus' share of every turn.
local turnX, turnY = 0, 0
local roomLeft, roomRight, roomUp, roomDown = math.huge, math.huge, math.huge, math.huge
local roomed = false
local focusShare = 1
-- The most a kick waits for the camera (degrees each way).
local MAX_KICK = 30

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
			if typeof(rotation) ~= "Vector2" then
				return rotation
			end
			if inverted and Keybinds.usingKeys() then
				rotation = Vector2.new(rotation.X, -rotation.Y)
			end
			local share = zoomShare * focusShare
			if share ~= 1 then
				rotation *= share
			end
			if roomed then
				-- (Freelook: the input turns no further than the room left.)
				local x, y = rotation.X, rotation.Y
				local cx, cy = math.clamp(x, -roomLeft, roomRight), math.clamp(y, -roomUp, roomDown)
				if cx ~= x or cy ~= y then
					rotation = Vector2.new(cx, cy)
				end
			end
			if kickX ~= 0 or kickY ~= 0 then
				-- (A firearm's recoil: Player/AimCamera.)
				rotation += Vector2.new(kickX, kickY)
				kickX, kickY = 0, 0
			end
			if turnX ~= 0 or turnY ~= 0 then
				-- (Freelook's snap back: Player/CameraRig.)
				rotation += Vector2.new(turnX, turnY)
				turnX, turnY = 0, 0
			end
			return rotation
		end
	end)
	hooked = ok
	if not ok then
		warn("[IceVoxel] Invert Mouse, recoil: Roblox's camera scripts could not be hooked")
	end
	return ok
end

-- MouseDeltaSensitivity: the setting, times the zoom's and focus' shares when the camera isn't
-- hooked.
local function applySensitivity()
	local share = if hooked then 1 else zoomShare * focusShare
	UserInputService.MouseDeltaSensitivity = math.max(sensitivity * share, 0.01)
end

-- The Sensitivity setting as a multiplier (PlayerSettings.mouseSensitivity).
function MouseLook.setSensitivity(multiplier: number)
	sensitivity = multiplier
	applySensitivity()
end

local waiting = false

-- Hooks the camera's input now, or as soon as Roblox's control scripts arrive (joining).
local function hookSoon()
	if not hook() and hooked == nil and not waiting then
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
			applySensitivity()
		end)
	end
end

-- The Invert Mouse setting.
function MouseLook.setInverted(on: boolean)
	inverted = on
	if on then
		hookSoon()
	end
end

-- Hooks Roblox's camera input for the weapons' recoil and zoom (see the header).
function MouseLook.hookCamera()
	hookSoon()
	applySensitivity()
end

-- Do kicks reach the camera (its input is hooked)?
function MouseLook.kicks(): boolean
	return hooked == true
end

--[[
	Turns the camera by `yaw` degrees right and `pitch` degrees up at its next update (a firearm's
	recoil and its recovery); nothing without the hook (`kicks`).
]]
function MouseLook.kick(yaw: number, pitch: number)
	if hooked ~= true then
		return
	end
	local limit = math.rad(MAX_KICK)
	kickX = math.clamp(kickX + math.rad(yaw), -limit, limit)
	kickY = math.clamp(kickY - math.rad(pitch), -limit, limit)
end

-- The camera's turn share while zoomed (1 / zoom; 1 out of the sights).
function MouseLook.setZoomSensitivity(share: number)
	share = math.clamp(share, 0.01, 1)
	if share == zoomShare then
		return
	end
	zoomShare = share
	if not hooked then
		applySensitivity()
	end
end

-- The camera's turn share while the eyes focus (the focus field of view over the setting's; 1:
-- none), multiplied with the zoom's.
function MouseLook.setFocusShare(share: number)
	share = math.clamp(share, 0.01, 1)
	if share == focusShare then
		return
	end
	focusShare = share
	if not hooked then
		applySensitivity()
	end
end

--[[
	Turns the camera by (`dx` right, `dy` down) radians at its next update, all of it (freelook's
	snap back: Player/CameraRig); nothing without the hook (`hooked`).
]]
function MouseLook.turn(dx: number, dy: number)
	if hooked ~= true then
		return
	end
	turnX += dx
	turnY += dy
end

--[[
	The room the camera has left to turn while freelooking (radians each way, never below 0;
	math.huge: no limit): the input's turn is clamped to it (a turn queued by `turn` is not).
]]
function MouseLook.setRoom(left: number, right: number, up: number, down: number)
	roomLeft, roomRight = math.max(left, 0), math.max(right, 0)
	roomUp, roomDown = math.max(up, 0), math.max(down, 0)
	roomed = roomLeft ~= math.huge or roomRight ~= math.huge or roomUp ~= math.huge or roomDown ~= math.huge
end

-- Is Roblox's camera input hooked (turns, room and kicks reach the camera)?
function MouseLook.hooked(): boolean
	return hooked == true
end

-- Can the mouse be inverted here (false once hooking Roblox's camera failed)?
function MouseLook.available(): boolean
	return hooked ~= false
end

return MouseLook

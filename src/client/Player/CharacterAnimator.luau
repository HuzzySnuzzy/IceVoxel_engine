--!strict
--[[
	Animates the local (cosmetic) character from the movement hull, replacing Roblox's default
	Animate script, which only reacts to Humanoid states the character no longer goes through.

	The avatar's own animations are used: their ids are read from the Animate script the character
	spawns with (so avatar animation packs keep working), with Roblox's defaults as a fallback. The
	choices and numbers are the Animate script's:

	  on the ground  idle, or walk / run blended by speed (R15: idle up to 0.75 studs/s times the
	                 height scale; speed / 16 * 1.25 / height scale is walking at 0.5 and running
	                 at 1, blended between; R6 walks at speed / 14.5),
	  in the air     jump for 0.31 s after a jump, then fall,
	  lying down     swim, at speed / 10 (the swimming / crawling pose: MovementController tilts the
	                 body as Roblox's Swimming state does, which the swim animation is made for),
	  deep water     swim idle while upright (R6 rigs have no swim animations: walk / idle),
	  holding a tool the arm pose of `toolnone` on top.

	Tracks played on the owning client by the Humanoid's Animator replicate to other players.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local MovementController = require(script.Parent.MovementController)

local BLOCK = Config.BlockSize
-- After a jump the jump animation plays this long before falling takes over.
local JUMP_TIME = 0.31
-- Fade time (s) into each mode.
local FADES: { [string]: number } = { idle = 0.2, walk = 0.2, jump = 0.1, fall = 0.2, swim = 0.4, swimidle = 0.4 }
local TOOL_FADE = 0.1
-- Standing below this speed (studs/s; R15: times the height scale).
local R15_IDLE_SPEED = 0.75
local R6_IDLE_SPEED = 0.01
-- R15 walk / run blend: normalised speeds where walking ends and running is full.
local WALK_SPEED, RUN_SPEED = 0.5, 1
-- Weight of the track blended out (Animate's "small but not zero", so it keeps its place).
local ALMOST_ZERO = 1e-4
-- Hip height of an unscaled R15 character.
local R15_HIP_HEIGHT = 2

-- Roblox's default animations per rig.
local DEFAULTS = {
	R15 = {
		idle = "rbxassetid://507766666",
		walk = "rbxassetid://913402848",
		run = "rbxassetid://913376220",
		jump = "rbxassetid://507765000",
		fall = "rbxassetid://507767968",
		swim = "rbxassetid://913384386",
		swimidle = "rbxassetid://913389285",
		toolnone = "rbxassetid://507768375",
	},
	R6 = {
		idle = "rbxassetid://180435571",
		walk = "rbxassetid://180426354",
		run = "rbxassetid://180426354",
		jump = "rbxassetid://125750702",
		fall = "rbxassetid://180436148",
		toolnone = "rbxassetid://182393478",
	},
}

local CharacterAnimator = {}

-- First Animation under the Animate script's value `name` (e.g. walk.WalkAnim), or the default id.
local function animationFor(animate: Instance?, name: string, rig: string): Animation?
	local holder = animate and animate:FindFirstChild(name)
	if holder then
		for _, child in holder:GetChildren() do
			if child:IsA("Animation") and child.AnimationId ~= "" then
				return child
			end
		end
	end
	local id = (DEFAULTS :: any)[rig][name]
	if id == nil then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	return animation
end

-- The R15 Animate script's height scale: how much bigger than default the character is.
local function heightScale(humanoid: Humanoid, animate: Instance?): number
	if not humanoid.AutomaticScalingEnabled then
		return 1
	end
	local dampening = animate and animate:FindFirstChild("ScaleDampeningPercent")
	if dampening and dampening:IsA("NumberValue") then
		return 1 + (humanoid.HipHeight - R15_HIP_HEIGHT) * dampening.Value / R15_HIP_HEIGHT
	end
	return humanoid.HipHeight / R15_HIP_HEIGHT
end

function CharacterAnimator.start()
	local player = Players.LocalPlayer
	local connection: RBXScriptConnection? = nil

	local function onCharacter(character: Model)
		if connection then
			connection:Disconnect()
			connection = nil
		end
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid == nil or not humanoid:IsA("Humanoid") then
			return
		end
		local hum: Humanoid = humanoid
		local animator = hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 10)
		if animator == nil or not animator:IsA("Animator") then
			return
		end

		-- Take over from the default Animate script (its ids stay readable).
		local animate = character:FindFirstChild("Animate")
		if animate and animate:IsA("LocalScript") then
			animate.Enabled = false
		end
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end

		local rig = if hum.RigType == Enum.HumanoidRigType.R15 then "R15" else "R6"
		local tracks: { [string]: AnimationTrack } = {}
		for _, name in { "idle", "walk", "run", "jump", "fall", "swim", "swimidle", "toolnone" } do
			local animation = animationFor(animate, name, rig)
			if animation then
				local ok, track = pcall(function()
					return animator:LoadAnimation(animation)
				end)
				if ok and track then
					track.Looped = name ~= "jump"
					-- As the Animate script: movement under everything, the tool pose above it.
					track.Priority = if name == "toolnone"
						then Enum.AnimationPriority.Idle
						else Enum.AnimationPriority.Core
					tracks[name] = track
				end
			end
		end

		local playing: { [string]: boolean } = {}
		local weights: { [string]: number } = {}
		local function set(name: string, on: boolean, fade: number, weight: number?, speed: number?)
			local track = tracks[name]
			if not track then
				return
			end
			if on then
				local w = weight or 1
				if not playing[name] then
					-- Play fades the weight in itself; adjusting it again would cut the fade short.
					track:Play(fade, w)
					playing[name] = true
					weights[name] = w
				elseif weights[name] ~= w then
					track:AdjustWeight(w, fade)
					weights[name] = w
				end
				track:AdjustSpeed(speed or 1)
			elseif playing[name] then
				track:Stop(fade)
				playing[name] = false
			end
		end

		local mode = "idle"
		connection = RunService.RenderStepped:Connect(function()
			local view = MovementController.current
			if view == nil or hum.Health <= 0 then
				for name in tracks do
					set(name, false, FADES.idle)
				end
				return
			end
			local state = view.state
			local speed = if view.frozen then 0 else view.speed * BLOCK
			local scale = if rig == "R15" then heightScale(hum, animate) else 1
			local moving = if rig == "R15" then speed > R15_IDLE_SPEED * scale else speed > R6_IDLE_SPEED

			local nextMode
			if view.tilt > 0.5 and tracks.swim then
				nextMode = "swim"
			elseif state.inWater and state.waterHeight > 0.9 and not state.onGround and tracks.swimidle then
				nextMode = "swimidle"
			elseif state.onGround or state.flying or view.frozen or view.tilt > 0.5 or state.inWater then
				nextMode = if moving then "walk" else "idle"
			else
				nextMode = if os.clock() - view.jumpedAt < JUMP_TIME then "jump" else "fall"
			end
			mode = nextMode
			local fade = FADES[mode]

			set("idle", mode == "idle", fade)
			set("jump", mode == "jump", fade)
			set("fall", mode == "fall", fade)
			set("swim", mode == "swim", fade, 1, speed / 10)
			set("swimidle", mode == "swimidle", fade)
			if mode == "walk" and rig == "R15" then
				-- The Animate script's setRunSpeed.
				local runSpeed = speed / 16 * 1.25 / scale
				if runSpeed <= WALK_SPEED then
					set("walk", true, fade, 1, runSpeed / WALK_SPEED)
					set("run", true, fade, ALMOST_ZERO, runSpeed / RUN_SPEED)
				elseif runSpeed < RUN_SPEED then
					local blend = (runSpeed - WALK_SPEED) / (RUN_SPEED - WALK_SPEED)
					set("walk", true, fade, 1 - blend, 1)
					set("run", true, fade, blend, 1)
				else
					set("walk", true, fade, ALMOST_ZERO, runSpeed / WALK_SPEED)
					set("run", true, fade, 1, runSpeed / RUN_SPEED)
				end
			else
				set("walk", mode == "walk", fade, 1, speed / 14.5)
				set("run", false, fade)
			end
			local tool = character:FindFirstChildOfClass("Tool")
			set("toolnone", tool ~= nil and tool:FindFirstChild("Handle") ~= nil, TOOL_FADE)
		end)
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return CharacterAnimator

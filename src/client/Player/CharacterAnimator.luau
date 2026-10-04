--!strict
--[[
	Animates the local (cosmetic) character from the movement hull, replacing Roblox's default
	Animate script, which only reacts to Humanoid states the character no longer goes through.

	The avatar's own animations are used: their ids are read from the Animate script the character
	spawns with (so avatar animation packs keep working), with Roblox's defaults as a fallback.

	  on the ground  idle, or walk / run blended by speed (as the R15 Animate script does: walk up to
	                 8 studs/s, run from 16; R6 walks at speed / 14.5),
	  in the air     jump right after a jump, then fall,
	  in water       swim when moving, swim idle when not (R6 rigs have neither: walk / idle),
	  holding a tool the arm pose of `toolnone` on top.

	Tracks played on the owning client by the Humanoid's Animator replicate to other players.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MovementController = require(script.Parent.MovementController)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local BLOCK = Config.BlockSize
-- After a jump the jump animation plays this long before falling takes over.
local JUMP_TIME = 0.31
-- Horizontal speed (studs/s) below which the character stands.
local MOVING = 0.5
local FADE = 0.2

-- Roblox's default animations per rig: { Animate child, Animation name, id }.
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
					tracks[name] = track
				end
			end
		end

		local playing: { [string]: boolean } = {}
		local function set(name: string, on: boolean, weight: number?, speed: number?)
			local track = tracks[name]
			if not track then
				return
			end
			if on then
				if not playing[name] then
					track:Play(FADE)
					playing[name] = true
				end
				track:AdjustWeight(math.max(weight or 1, 1e-4), FADE)
				track:AdjustSpeed(speed or 1)
			elseif playing[name] then
				track:Stop(FADE)
				playing[name] = false
			end
		end

		local lastFeet: Vector3? = nil
		local speed = 0
		local jumpedAt = -math.huge
		local wasOnGround = true
		connection = RunService.RenderStepped:Connect(function(dt: number)
			local view = MovementController.current
			if view == nil or hum.Health <= 0 then
				for name in tracks do
					set(name, false)
				end
				return
			end
			local state = view.state
			local feet = view.feet
			if lastFeet and dt > 0 then
				local delta = (feet - lastFeet) * BLOCK
				local instant = Vector3.new(delta.X, 0, delta.Z).Magnitude / dt
				speed += (instant - speed) * math.min(1, dt * 10)
			end
			lastFeet = feet
			if wasOnGround and not state.onGround and state.vy > 0 then
				jumpedAt = os.clock()
			end
			wasOnGround = state.onGround

			local moving = speed > MOVING
			local mode
			if state.inWater and state.waterHeight > 0.9 and not state.onGround then
				mode = if moving then "swim" else "swimidle"
				if not tracks[mode] then
					mode = if moving then "walk" else "idle"
				end
			elseif state.onGround or view.frozen then
				mode = if moving then "walk" else "idle"
			else
				mode = if os.clock() - jumpedAt < JUMP_TIME then "jump" else "fall"
			end

			set("idle", mode == "idle")
			set("jump", mode == "jump")
			set("fall", mode == "fall")
			set("swim", mode == "swim", 1, math.max(speed / 10, 0.3))
			set("swimidle", mode == "swimidle")
			if mode == "walk" then
				if rig == "R15" then
					-- Walk at 8 studs/s, run at 16 and blend between (as the R15 Animate script).
					local s = speed / 16
					if s <= 0.5 then
						set("walk", true, 1, s / 0.5)
						set("run", true, 1e-4, s)
					elseif s < 1 then
						local blend = (s - 0.5) / 0.5
						set("walk", true, 1 - blend, 1)
						set("run", true, blend, 1)
					else
						set("walk", true, 1e-4, s / 0.5)
						set("run", true, 1, s)
					end
				else
					set("walk", true, 1, speed / 14.5)
					set("run", false)
				end
			else
				set("walk", false)
				set("run", false)
			end
			local tool = character:FindFirstChildOfClass("Tool")
			set("toolnone", tool ~= nil and tool:FindFirstChild("Handle") ~= nil)
		end)
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
end

return CharacterAnimator

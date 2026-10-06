--!strict
--[[
	The sounds of moving about, as Minecraft makes them (SoundRules.move, after Entity.move):
	footsteps on the block under the feet every 1.67 blocks walked, swimming in water, a splash on
	falling in, and a landing that hurts.

	  This player  Player/MovementController calls `tick` after every tick of the hull, with what
	               happened (PlayerPhysics events). A landing that hurts (survival, fall damage on,
	               ceil(distance - 3) half hearts) plays Minecraft's small or big fall and the fall
	               sound of the block landed on (Sounds.fall, Sounds.block "fall") at once: the
	               server sends them to everyone else (predicted events).
	  Others       other players' characters near the listener are followed every frame (their feet,
	               Rig.feet): the same rules from how far they moved, whether they stand on
	               something and whether they are in water (SoundRules.observe), swimming when
	               their body lies down in water. Whether they sneak is not known, so they always
	               make footsteps. The server never sends footsteps, so every client makes
	               everyone's.

	Footsteps follow Config.Sounds.Footsteps and the player's Footsteps setting (SoundPlayer.
	allows); swimming and splashes always play. Spectators make no sound at all (Player/
	SpectatorRules: no physics in Minecraft), this player included.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)
local Sounds = require(Shared.Sounds)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local SpectatorRules = require(script.Parent.Parent.Player.SpectatorRules)
local SoundPlayer = require(script.Parent.SoundPlayer)
local SoundRules = require(script.Parent.SoundRules)

local TICK_RATE = PlayerPhysics.TICK_RATE
-- Other characters are followed within this many blocks of the listener (hearing distance
-- plus some slack).
local FOLLOW_DISTANCE = Sounds.DEFAULT_DISTANCE + 8
-- A character moving further than this (blocks) in one frame was teleported: no steps for it.
local TELEPORT_DISTANCE = 4
-- A character whose body leans further than 45 degrees lies down (swims, in water).
local LYING_UP = math.cos(math.rad(45))

type GetBlock = SoundRules.GetBlock

local MovementSounds = {}

-- This player's walker, and the hull state it belongs to (a new character starts over).
local walker = SoundRules.newWalker()
local walkerState: PlayerPhysics.State? = nil

local function playSounds(x: number, y: number, z: number, step: number?, swim: number?, splash: number?)
	if step and SoundPlayer.allows("footsteps") then
		SoundPlayer.play(Sounds.block(step, "step"), x, y, z)
	end
	if swim then
		SoundPlayer.play("entity.generic.swim", x, y, z, swim)
	end
	if splash then
		SoundPlayer.play("entity.generic.splash", x, y, z, splash)
	end
end

--[[
	One tick of this player's hull: `state` after it, `events` what happened, `previous` the feet
	before it (blocks) and `getBlock` the client's blocks.
]]
function MovementSounds.tick(
	state: PlayerPhysics.State,
	events: PlayerPhysics.Events,
	previous: Vector3,
	getBlock: GetBlock
)
	-- (Spectators pass through everything: Entity.move without physics makes no sound.)
	if not SoundPlayer.isEnabled() or state.noClip then
		return
	end
	if state ~= walkerState then
		walkerState = state
		walker = SoundRules.newWalker()
	end
	local x, y, z = state.x, state.y, state.z
	-- The block stepped on: the one the hull stands on (Entity.getOnPos), else under the feet.
	local below = getBlock(
		state.supportX or math.floor(x),
		math.floor(y - SoundRules.STEP_BELOW),
		state.supportZ or math.floor(z)
	)
	local step, swim, splash = SoundRules.move(walker, {
		dx = x - previous.X,
		-- (A step up is a climb, not speed.)
		dy = y - previous.Y - events.stepUp,
		dz = z - previous.Z,
		ticks = 1,
		onGround = state.onGround,
		inWater = state.inWater,
		swimming = state.swimming,
		silent = state.flying or (state.onGround and state.sneaking),
		below = below,
	})
	playSounds(x, y, z, step, swim, splash)

	-- A landing that hurts (LivingEntity.causeFallDamage): the server reports it to the others.
	if events.landed and events.damage > 0 and Config.Movement.FallDamage then
		SoundPlayer.play(Sounds.fall(events.damage), x, y, z)
		local landedOn = getBlock(math.floor(x), math.floor(y - SoundRules.STEP_BELOW), math.floor(z))
		if landedOn then
			SoundPlayer.play(Sounds.block(landedOn, "fall"), x, y, z)
		end
	end
end

-- A followed character: its walker and where its feet were last frame.
type Followed = { character: Model, walker: SoundRules.Walker, feet: Vector3? }

-- Starts following other players' characters for their footsteps, swimming and splashes.
function MovementSounds.start(world: ClientWorld.ClientWorld)
	local localPlayer = Players.LocalPlayer
	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end
	-- By player (not a weak table keyed by the character: Roblox may collect an Instance's Lua
	-- object between frames, which would start the walker over); a new character starts over, and
	-- players who leave are forgotten.
	local followed: { [Player]: Followed } = {}
	Players.PlayerRemoving:Connect(function(player: Player)
		followed[player] = nil
	end)
	-- One motion reused for every character (SoundRules.move keeps none of it).
	local motion: SoundRules.Motion = {
		dx = 0,
		dy = 0,
		dz = 0,
		ticks = 1,
		onGround = false,
		inWater = false,
		swimming = false,
		silent = false,
		below = nil,
	}

	RunService.Heartbeat:Connect(function(dt: number)
		if not SoundPlayer.isEnabled() then
			return
		end
		local listener = SoundPlayer.listener()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local audible = SpectatorRules.audible(GameMode.of(player))
			if player ~= localPlayer and (character == nil or not audible) then
				followed[player] = nil
			elseif player ~= localPlayer and character then
				local record = followed[player]
				if record == nil or record.character ~= character then
					record = { character = character, walker = SoundRules.newWalker(), feet = nil }
					followed[player] = record
				end
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				local feet = if humanoid and humanoid.Health > 0 then Rig.feet(character) else nil
				local last = record.feet
				record.feet = feet
				local delta = if feet and last then feet - last else nil
				if
					feet
					and delta
					and listener
					and (feet - listener).Magnitude <= FOLLOW_DISTANCE
					and delta.X * delta.X + delta.Z * delta.Z <= TELEPORT_DISTANCE * TELEPORT_DISTANCE
				then
					local onGround, inWater, below = SoundRules.observe(getBlock, feet.X, feet.Y, feet.Z)
					-- Swimming: lying down in water (MovementController pitches the body forward).
					local root = character:FindFirstChild("HumanoidRootPart")
					local lying = root ~= nil and root:IsA("BasePart") and root.CFrame.UpVector.Y < LYING_UP
					motion.dx, motion.dy, motion.dz = delta.X, delta.Y, delta.Z
					motion.ticks = dt * TICK_RATE
					motion.onGround, motion.inWater, motion.swimming = onGround, inWater, inWater and lying
					motion.below = below
					local step, swim, splash = SoundRules.move(record.walker, motion)
					playSounds(feet.X, feet.Y, feet.Z, step, swim, splash)
				else
					-- Not followed this frame (far, teleported, dead): no splash when it comes back
					-- already in water.
					record.walker.inWater = nil
				end
			end
		end
	end)
end

return MovementSounds

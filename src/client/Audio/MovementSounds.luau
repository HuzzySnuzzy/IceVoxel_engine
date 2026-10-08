--!strict
--[[
	The sounds of moving about, as Minecraft makes them (SoundRules.move, after Entity.move):
	footsteps on the block under the feet every 1.67 blocks walked, swimming in water, a splash on
	falling in, and a landing that hurts; climbing a ladder, vine or rope steps on it every 1.67
	blocks climbed (the hull's `climbing`, off the ground), sneaking or not.

	  This player  Player/MovementController calls `tick` after every tick of the hull, with what
	               happened (PlayerPhysics events). A landing that hurts (survival, fall damage on,
	               ceil(distance - 3) half hearts) plays Minecraft's small or big fall and the fall
	               sound of the block landed on (Sounds.fall, Sounds.block "fall") at once: the
	               server sends them to everyone else (predicted events).
	  Others       other players near the listener are followed every frame (their feet in world
	               blocks, Player/RemotePlayers: only those the client is told about): the same
	               rules from how far they moved, whether they stand on something and whether they
	               are in water (SoundRules.observe), swimming when their body lies down in water.
	               Whether they sneak is not known, so they always make footsteps. The server
	               never sends footsteps, so every client makes everyone's. World blocks all the
	               way: a move of the floating origin (Shared/World/Origin) is no step.

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
local Sounds = require(Shared.Sounds)

local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local RemotePlayers = require(script.Parent.Parent.Player.RemotePlayers)
local SpectatorRules = require(script.Parent.Parent.Player.SpectatorRules)
local SoundPlayer = require(script.Parent.SoundPlayer)
local SoundRules = require(script.Parent.SoundRules)

local TICK_RATE = PlayerPhysics.TICK_RATE
-- Other characters are followed within this many blocks of the listener (hearing distance
-- plus some slack).
local FOLLOW_DISTANCE = Sounds.DEFAULT_DISTANCE + 8
-- A character moving further than this (blocks) in one frame was teleported: no steps for it.
local TELEPORT_DISTANCE = 4
-- A body leaning further than 45 degrees (RemotePlayers' tilt: 1 lying flat) lies down (swims,
-- in water).
local LYING_TILT = 0.5

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
		climbing = state.climbing and not state.onGround,
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

-- A followed player: their character, walker, where their feet were last frame (world blocks;
-- nil x: unknown) and the frame they were last seen.
type Followed = {
	character: Model?,
	walker: SoundRules.Walker,
	known: boolean,
	x: number,
	y: number,
	z: number,
	seen: number,
}

-- Starts following other players' characters for their footsteps, swimming and splashes.
function MovementSounds.start(world: ClientWorld.ClientWorld)
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
		climbing = false,
	}

	local frame = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if not SoundPlayer.isEnabled() then
			return
		end
		frame += 1
		local listener = SoundPlayer.listener()
		for player, remote in RemotePlayers.each() do
			if not SpectatorRules.audible(GameMode.of(player)) then
				followed[player] = nil
				continue
			end
			local record = followed[player]
			if record == nil or record.character ~= remote.character then
				record = {
					character = remote.character,
					walker = SoundRules.newWalker(),
					known = false,
					x = 0,
					y = 0,
					z = 0,
					seen = frame,
				}
				followed[player] = record
			end
			record.seen = frame
			local alive = remote.alive
			local x, y, z = remote.x, remote.y, remote.z
			local known = record.known
			local dx, dy, dz = x - record.x, y - record.y, z - record.z
			record.known = alive
			record.x, record.y, record.z = x, y, z
			local near = false
			if listener then
				local lx, ly, lz = x - listener.X, y - listener.Y, z - listener.Z
				near = lx * lx + ly * ly + lz * lz <= FOLLOW_DISTANCE * FOLLOW_DISTANCE
			end
			if alive and known and near and dx * dx + dz * dz <= TELEPORT_DISTANCE * TELEPORT_DISTANCE then
				local onGround, inWater, below, climbing = SoundRules.observe(getBlock, x, y, z)
				-- Swimming: lying down in water (the body pitched forward).
				local lying = remote.tilt > LYING_TILT
				motion.dx, motion.dy, motion.dz = dx, dy, dz
				motion.ticks = dt * TICK_RATE
				motion.onGround, motion.inWater, motion.swimming = onGround, inWater, inWater and lying
				motion.below = below
				motion.climbing = climbing
				local step, swim, splash = SoundRules.move(record.walker, motion)
				playSounds(x, y, z, step, swim, splash)
			else
				-- Not followed this frame (far, teleported, dead): no splash when it comes back
				-- already in water.
				record.walker.inWater = nil
			end
		end
		-- (Players the client is no longer told about start over when they come back.)
		for player, record in followed do
			if record.seen ~= frame then
				followed[player] = nil
			end
		end
	end)
end

return MovementSounds

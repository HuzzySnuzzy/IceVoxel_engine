--!strict
--[[
	Mobs on the server: runs Mobs/MobWorld (the rules) and Mobs/MobSpawning at 20 ticks a second on
	Heartbeat against the server's loaded blocks, and connects them to the rest of the game.

	  Ticking    mobs tick only in the chunks World/Simulation keeps around players (loaded and
	             within Config.Server.SimulationRadius chunks), refreshed every 10 ticks; blocks
	             come from `world:peekBlock`, which never generates terrain; the day time from
	             World/TimeOfDay and the open sky from World/Skylight.open. Players are their
	             characters' feet (Rig.feet), standing eyes (1.62), game mode and health.
	  Effects    what MobWorld reports each tick: sounds (Audio/Sounds), deaths (the `died` event),
	             loot (Entities.spawnItem: popping out of the body), hits on players
	             (Characters.hurt: the hurt cooldown and armor; a fresh one knocks the player back
	             through a `push` op the client adds to its movement, as an explosion's), a
	             creeper's blast (World/Explosions.explode, power 3, at its feet: blocks, items,
	             players and other mobs as any blast) and arrows (an `arrow` op for everyone near).
	  Attacks    Protocol Attack (mob id), at most Config.Mobs.AttacksPerSecond a player:
	             MobWorld.attack checks the player (alive, not a spectator), the reach from their
	             eyes (Shared/Entities/Combat: 3 blocks, 6 in creative, plus a block of leeway) and
	             the line of sight, then hits with the held item at its attack strength (ticks
	             since the player's last attack or change of held item); a hit plays
	             entity.player.attack.strong or .weak and wears a tool (swords 1, other tools 2;
	             not in creative).
	  Tracking   every SyncTicks (2: 10 a second) each player gets the mobs within
	             Config.Mobs.TrackingDistance of their feet: a spawn when one comes into range, its
	             state when it changed (position in 1/32 block, facing, health, the hurt flash,
	             burning, dying, a creeper's fuse), a remove when it leaves range or is gone; all
	             in one Mobs message with that period's arrows and the player's knockback.
	  Commands   /summon <kind> [x y z] and /kill @e[type=<kind>] (Mobs/SummonCommand), for those
	             who may change the time (Config.Gameplay.Admins, the owner, Studio).
	  Off        with Config.Mobs.Enabled false nothing spawns, ticks or is sent.

	For other server scripts (the integration hooks):
	  Mobs.died            Event (killer: Player?, kind: string, x, y, z, id): a mob died; the
	                       killer is the player whose hit counts (the last within 5 s), nil for
	                       anything else (fire, falls, blasts, /kill)
	  Mobs.damage(id, amount, attacker?, x?, z?)   hurts a mob (half hearts) through its cooldown
	                       and armor, knocked back from (x, z) when given; returns what landed
	  Mobs.near(x, y, z, radius)   the live mobs around a point (MobView: id, kind, position,
	                       box, health)
	  Mobs.spawn(kind, x, y, z)    a mob of a MobList name at a position (0 when it can't)
	  Mobs.explode(x, y, z, power, getBlock)   what a blast does to mobs (World/Explosions'
	                       handler, set by the boot script)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Combat = require(Shared.Entities.Combat)
local Coords = require(Shared.World.Coords)
local GameMode = require(Shared.GameMode)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Simulation = require(script.Parent.Parent.World.Simulation)
local Skylight = require(script.Parent.Parent.World.Skylight)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local Explosions = require(script.Parent.Parent.World.Explosions)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Entities = require(script.Parent.Parent.Entities.Entities)
local Characters = require(script.Parent.Parent.Players.Characters)
local GameModes = require(script.Parent.Parent.Players.GameModes)
local Inventories = require(script.Parent.Parent.Players.Inventories)
local TimeCommand = require(script.Parent.Parent.Players.TimeCommand)
local MobWorld = require(script.Parent.MobWorld)
local MobSpawning = require(script.Parent.MobSpawning)
local SummonCommand = require(script.Parent.SummonCommand)

-- Only what Mobs uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
	on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> (),
}

export type MobView = {
	id: number,
	kind: string,
	x: number,
	y: number,
	z: number,
	width: number,
	height: number,
	health: number,
}

local Settings = Config.Mobs
local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4
-- Ticks between refreshes of the ticking chunks.
local ACTIVE_INTERVAL = 10
-- Mobs spawned on one client per message; the rest follow at the next sync.
local MAX_SPAWNS_PER_MESSAGE = 128
local EYE = Combat.EYE
local LIMIT = Protocol.MAX_COORDINATE + 64
local MAX_HEIGHT = 4096
local FLAGS = Protocol.MobFlag

local Mobs = {}

local diedEvent = Instance.new("BindableEvent")
-- Fires (killer: Player?, kind: string, x: number, y: number, z: number, id: number) when a mob
-- dies (see the header).
Mobs.died = diedEvent.Event

local mobWorld: MobWorld.MobWorld? = nil
local serverWorld: WorldServer.World? = nil
local random = Random.new()
-- Per player: the last state sent of each mob their client knows (quantized), and ops waiting
-- for the next sync (arrows, their knockback).
type Sent = { x: number, y: number, z: number, yaw: number, health: number, flags: number, fuse: number }
local known: { [Player]: { [number]: Sent } } = {}
local pending: { [Player]: { Protocol.MobOp } } = {}
-- Per player: the tick of their last swing and of their last change of held item, and that item.
type Swing = { swing: number, changed: number, item: number? }
local swings: { [Player]: Swing } = {}
local attackBuckets: { [Player]: { tokens: number, last: number } } = {}
local tickCount = 0

local function finite(x: number, y: number, z: number): boolean
	return x == x and y == y and z == z and math.abs(x) <= LIMIT and math.abs(z) <= LIMIT and math.abs(y) <= MAX_HEIGHT
end

-- A character's feet, if they are a sane position.
local function feetOf(player: Player): Vector3?
	local character = player.Character
	local feet = if character then Rig.feet(character) else nil
	if feet and finite(feet.X, feet.Y, feet.Z) then
		return feet
	end
	return nil
end

local function aliveOf(player: Player): boolean
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil and humanoid.Health > 0
end

-- The players as mobs see them.
local function playerViews(): { MobWorld.PlayerView }
	local views = {}
	for _, player in Players:GetPlayers() do
		local feet = feetOf(player)
		if feet then
			table.insert(views, {
				key = player,
				x = feet.X,
				y = feet.Y,
				z = feet.Z,
				eye = EYE,
				mode = GameMode.of(player),
				alive = aliveOf(player),
			})
		end
	end
	return views
end

local function queue(player: Player, op: Protocol.MobOp)
	local list = pending[player]
	if list == nil then
		list = {}
		pending[player] = list
	end
	table.insert(list, op)
end

local function flagsOf(mob: MobWorld.Mob): number
	return (if mob.hurtTime > 0 then FLAGS.Hurt else 0)
		+ (if mob.burn.fire > 0 then FLAGS.Burning else 0)
		+ (if mob.dead then FLAGS.Dying else 0)
		+ (if mob.ai.swell > 0 then FLAGS.Fuse else 0)
end

local function snapshot(mob: MobWorld.Mob): Sent
	local body = mob.body
	local scale = Protocol.MOB_POSITION_SCALE
	return {
		x = math.round(body.x * scale),
		y = math.round(body.y * scale),
		z = math.round(body.z * scale),
		yaw = Protocol.mobYaw(body.yaw),
		health = math.clamp(math.ceil(mob.health), 0, 255),
		flags = flagsOf(mob),
		fuse = math.clamp(mob.ai.swell, 0, 255),
	}
end

local function same(a: Sent, b: Sent): boolean
	return a.x == b.x
		and a.y == b.y
		and a.z == b.z
		and a.yaw == b.yaw
		and a.health == b.health
		and a.flags == b.flags
		and a.fuse == b.fuse
end

-- Sends every player the mobs around them (see the header).
local function replicate(net: Net, mobs: MobWorld.MobWorld)
	local range = Settings.TrackingDistance
	local rangeSq = range * range
	local all = mobs:each()
	local scale = Protocol.MOB_POSITION_SCALE
	-- (Each mob's state once, shared by every player's record of it: never changed after.)
	local states: { [number]: Sent } = {}
	for _, mob in all do
		states[mob.id] = snapshot(mob)
	end
	for _, player in Players:GetPlayers() do
		local seen = known[player]
		if seen == nil then
			seen = {}
			known[player] = seen
		end
		local ops: { Protocol.MobOp } = pending[player] or {}
		pending[player] = nil
		local feet = feetOf(player)
		local inRange: { [number]: boolean } = {}
		local spawns = 0
		if feet then
			local px, py, pz = feet.X, feet.Y, feet.Z
			for _, mob in all do
				local body = mob.body
				local dx, dy, dz = body.x - px, body.y - py, body.z - pz
				if dx * dx + dy * dy + dz * dz <= rangeSq then
					local now = states[mob.id]
					local last = seen[mob.id]
					if last == nil then
						if spawns < MAX_SPAWNS_PER_MESSAGE then
							spawns += 1
							inRange[mob.id] = true
							seen[mob.id] = now
							table.insert(ops, {
								op = "spawn",
								id = mob.id,
								kind = mob.kind.id,
								variant = mob.variant,
								x = now.x / scale,
								y = now.y / scale,
								z = now.z / scale,
								yaw = body.yaw,
								health = now.health,
								flags = now.flags,
								fuse = now.fuse,
							})
						end
					else
						inRange[mob.id] = true
						if not same(last, now) then
							seen[mob.id] = now
							table.insert(ops, {
								op = "state",
								id = mob.id,
								x = now.x / scale,
								y = now.y / scale,
								z = now.z / scale,
								yaw = body.yaw,
								health = now.health,
								flags = now.flags,
								fuse = now.fuse,
							})
						end
					end
				end
			end
		end
		for id in seen do
			if not inRange[id] then
				seen[id] = nil
				table.insert(ops, { op = "remove", id = id })
			end
		end
		if #ops > 0 then
			net.send(player, Protocol.ServerMessage.Mobs, Protocol.encodeMobs(ops))
		end
	end
end

-- What the tick's changes do to the rest of the game (see the header).
local function apply(mobs: MobWorld.MobWorld, world: WorldServer.World)
	local changes = mobs:takeChanges()
	for _, cue in changes.sounds do
		Sounds.play(cue.name, cue.x, cue.y, cue.z)
	end
	for _, death in changes.deaths do
		local killer = death.killer
		diedEvent:Fire(
			if typeof(killer) == "Instance" and killer:IsA("Player") then killer else nil,
			death.kind,
			death.x,
			death.y,
			death.z,
			death.id
		)
	end
	for _, drop in changes.drops do
		Entities.spawnItem({ item = drop.item, count = drop.count }, drop.x, drop.y, drop.z)
	end
	for _, hit in changes.hits do
		local player = hit.key
		if typeof(player) == "Instance" and player:IsA("Player") and player.Parent then
			local _, fresh = Characters.hurt(player, hit.damage)
			if fresh then
				queue(player, { op = "push", id = hit.id, kx = hit.kx, ky = hit.ky, kz = hit.kz })
			end
		end
	end
	for _, blast in changes.explosions do
		Explosions.explode(world, blast.x, blast.y, blast.z, blast.power)
	end
	if #changes.arrows > 0 then
		local range = Settings.TrackingDistance
		for _, player in Players:GetPlayers() do
			local feet = feetOf(player)
			if feet then
				for _, arrow in changes.arrows do
					if (Vector3.new(arrow.x, arrow.y, arrow.z) - feet).Magnitude <= range then
						queue(player, {
							op = "arrow",
							id = arrow.id,
							x = arrow.x,
							y = arrow.y,
							z = arrow.z,
							tx = arrow.tx,
							ty = arrow.ty,
							tz = arrow.tz,
						})
					end
				end
			end
		end
	end
end

-- Notes changes of each player's held item (Minecraft's attack strength starts over then).
local function watchHeld()
	for _, player in Players:GetPlayers() do
		local held = Inventories.heldTool(player)
		local swing = swings[player]
		if swing == nil then
			swings[player] = { swing = -math.huge, changed = tickCount, item = held }
		elseif swing.item ~= held then
			swing.item = held
			swing.changed = tickCount
		end
	end
end

local function onAttack(player: Player, payload: buffer)
	local mobs = mobWorld
	local id = Protocol.decodeAttack(payload)
	if mobs == nil or id == nil or not Settings.Enabled then
		return
	end
	local now = os.clock()
	local bucket = attackBuckets[player]
	if bucket == nil then
		bucket = { tokens = Settings.AttacksPerSecond, last = now }
		attackBuckets[player] = bucket
	end
	bucket.tokens = math.min(Settings.AttacksPerSecond, bucket.tokens + (now - bucket.last) * Settings.AttacksPerSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return
	end
	bucket.tokens -= 1
	local feet = feetOf(player)
	if feet == nil then
		return
	end
	local mode = GameMode.of(player)
	local held = Inventories.heldTool(player)
	local swing: Swing = swings[player] or { swing = -math.huge, changed = -math.huge, item = held }
	swings[player] = swing
	if swing.item ~= held then
		swing.item = held
		swing.changed = tickCount
	end
	local since = tickCount - math.max(swing.swing, swing.changed)
	local landed, result = mobs:attack(id, {
		key = player,
		x = feet.X,
		y = feet.Y,
		z = feet.Z,
		eye = EYE,
		mode = mode,
		alive = aliveOf(player),
		item = held,
		ticks = since,
	})
	if landed == nil then
		return
	end
	swing.swing = tickCount
	local mob = mobs:get(id)
	if mob then
		local body = mob.body
		Sounds.play(
			if result == true then "entity.player.attack.strong" else "entity.player.attack.weak",
			body.x,
			body.y + mob.kind.height / 2,
			body.z
		)
	end
	if landed > 0 and not GameMode.instabuild(mode) then
		local wear = Combat.wear(held)
		if wear > 0 then
			Inventories.wearTool(player, wear)
		end
	end
end

-- Runs a chat message as /summon or /kill (ignores anything else).
local function runCommand(net: Net, player: Player, text: string)
	if not SummonCommand.matches(text) then
		return
	end
	local studio = RunService:IsStudio()
	local mayUse =
		TimeCommand.mayUse(player.UserId, Config.Gameplay.Admins, studio or GameModes.isOwner(player), studio)
	local feet = feetOf(player) or Vector3.zero
	local result = SummonCommand.run(text, {
		mayUse = mayUse,
		enabled = Settings.Enabled and mobWorld ~= nil,
		x = feet.X,
		y = feet.Y,
		z = feet.Z,
	})
	if result == nil or player.Parent == nil then
		return
	end
	local mobs = mobWorld
	local feedback = result.feedback
	if mobs and result.summon then
		local summon = result.summon
		if mobs:spawn(summon.kind, summon.x, summon.y, summon.z) == 0 then
			feedback = { "Unable to summon entity" }
		end
	end
	if mobs and result.kill then
		local kind = result.kill.kind
		local count = 0
		for _, mob in mobs:each() do
			if (kind == nil or mob.kind.id == kind) and mobs:kill(mob.id) then
				count += 1
			end
		end
		table.insert(feedback, SummonCommand.killed(count))
	end
	for _, message in feedback do
		net.send(player, Protocol.ServerMessage.Notice, Protocol.encodeNotice(message))
	end
end

local function startCommands(net: Net)
	if TextChatService.ChatVersion == Enum.ChatVersion.LegacyChatService then
		local function onPlayer(player: Player)
			player.Chatted:Connect(function(message: string)
				runCommand(net, player, message)
			end)
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, player in Players:GetPlayers() do
			onPlayer(player)
		end
		return
	end
	local commands: { [string]: string } = { IceVoxelSummon = "/summon", IceVoxelKill = "/kill" }
	for name, alias in commands do
		local instance = Instance.new("TextChatCommand")
		instance.Name = name
		instance.PrimaryAlias = alias
		instance.Triggered:Connect(function(source: TextSource, text: string)
			local player = Players:GetPlayerByUserId(source.UserId)
			if player then
				runCommand(net, player, text)
			end
		end)
		instance.Parent = TextChatService
	end
end

-- Starts the mobs (see the header). `net` is the ServerNet.
function Mobs.start(net: Net, world: WorldServer.World)
	assert(serverWorld == nil, "Mobs.start was already called")
	serverWorld = world
	startCommands(net)
	net.on(Protocol.ClientMessage.Attack, onAttack)
	Players.PlayerRemoving:Connect(function(player)
		known[player] = nil
		pending[player] = nil
		swings[player] = nil
		attackBuckets[player] = nil
	end)
	if not Settings.Enabled then
		return
	end
	local function getBlock(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end
	local mobs = MobWorld.new(getBlock, {
		maxMobs = Settings.MaxMobs,
		forgetTicks = Settings.ForgetTicks,
		random = function(): number
			return random:NextNumber()
		end,
	})
	mobWorld = mobs
	local spawnState = MobSpawning.new()
	local active: { [number]: boolean } = {}
	local function isActive(cx: number, cz: number): boolean
		return active[Coords.chunkKey(cx, cz)] == true
	end
	local function skyOpen(x: number, y: number, z: number): boolean?
		return Skylight.open(world, x, y, z)
	end

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tickCount += 1
			if tickCount % ACTIVE_INTERVAL == 1 then
				table.clear(active)
				for _, chunk in Simulation.activeChunks(world) do
					active[Coords.chunkKey(chunk.cx, chunk.cz)] = true
				end
			end
			watchHeld()
			local context = {
				players = playerViews(),
				dayTime = TimeOfDay.get(),
				skyOpen = skyOpen,
				active = isActive,
			}
			mobs:tick(context)
			MobSpawning.step(mobs, spawnState, context, Settings)
			apply(mobs, world)
			if tickCount % math.max(1, Settings.SyncTicks) == 0 then
				replicate(net, mobs)
			end
		end
	end)
end

--[[ Hooks for other server scripts (see the header) ]]

function Mobs.damage(id: number, amount: number, attacker: Player?, x: number?, z: number?): number
	local mobs = mobWorld
	if mobs == nil then
		return 0
	end
	return mobs:hurt(id, amount, {
		player = attacker,
		x = x,
		z = z,
		knockback = if x and z then Combat.KNOCKBACK else nil,
	})
end

function Mobs.near(x: number, y: number, z: number, radius: number): { MobView }
	local mobs = mobWorld
	local views: { MobView } = {}
	if mobs == nil then
		return views
	end
	for _, mob in mobs:near(x, y, z, radius) do
		local body, kind = mob.body, mob.kind
		table.insert(views, {
			id = mob.id,
			kind = kind.name,
			x = body.x,
			y = body.y,
			z = body.z,
			width = kind.width,
			height = kind.height,
			health = mob.health,
		})
	end
	return views
end

function Mobs.spawn(kind: string, x: number, y: number, z: number): number
	local mobs = mobWorld
	local id = MobList.find(kind)
	if mobs == nil or id == nil then
		return 0
	end
	return mobs:spawn(id, x, y, z)
end

-- World/Explosions' handler: a blast of `power` at (x, y, z) hurts and pushes the mobs near it.
function Mobs.explode(x: number, y: number, z: number, power: number): number
	local mobs = mobWorld
	return if mobs then mobs:explode(x, y, z, power) else 0
end

-- Mobs in the world (for the debug overlay and tests).
function Mobs.count(): number
	local mobs = mobWorld
	return if mobs then mobs:count() else 0
end

return Mobs

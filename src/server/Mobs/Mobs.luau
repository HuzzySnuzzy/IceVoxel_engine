--!strict
--[[
	Mobs on the server: runs Mobs/MobWorld (the rules) and Mobs/MobSpawning at 20 ticks a second on
	Heartbeat against the server's loaded blocks, and connects them to the rest of the game.

	  Ticking    mobs tick only in the chunks World/Simulation keeps around players (loaded and
	             within Config.Server.SimulationRadius chunks), refreshed every 10 ticks; blocks
	             come from `world:peekBlock`, which never generates terrain; the day time from
	             World/TimeOfDay and the open sky from World/Skylight (`open`, and `clear` for
	             burning in daylight: leaves shade), the rain and the weather's darkening from
	             World/WeatherServer (`rainingAt`, `isDayAt`: no burning in the rain or a
	             thunderstorm). Players are their
	             feet (Players/PlayerPositions), standing eyes (1.62), game mode and health.
	  Zombies    each tick the zombie apocalypse's (Config.Apocalypse) context: the noises heard
	             (Apocalypse/NoiseBus.take, 1.25 times as far at night and 0.7 times where it
	             rains at the noise), whether it is night (DayCycle.isDay) and whether zombies
	             break blocks (Breaking.Enabled), how much a column is in a city (the generator's
	             cityAt) and its ground (the generator's column: waves keep off roofs), each
	             player's monster cap and the world's limits (Mobs/ZombieDirector:
	             by day, at night, in a city, in a blood moon; maxMobs and MaxHostile are worked
	             out again every tick, so /time set or a restart in a blood moon never leaves them
	             raised), day spawning (Zombies.DaySpawning) and the blood moon's pause of natural
	             monster spawning; then the director runs (waves, hunts, leave rounds). The
	             server script chains `blockChanged` onto WorldServer.onChanged, so zombies'
	             damage on a block broken and replaced starts over (MobWorld.blockChanged).
	  Effects    what MobWorld reports each tick: sounds (Audio/Sounds), deaths (the `died` event),
	             loot (Entities.spawnItem: popping out of the body), hits on players
	             (Characters.hurt: the hurt cooldown, armor and Resistance; a fresh one knocks the
	             player back through a `push` op the client adds to its movement, as an
	             explosion's, which the server's speed checks are told to allow:
	             Characters.knockedBack; less the player's knockback resistance, a Cobalt
	             Shield's all of it: Characters.knockbackShare); each hit that lands fires
	             `playerHit` (the apocalypse's bites and wounds: server Apocalypse/Survival).
	             Zombies' blocks: a hit on a block thuds (entity.zombie.attack_wooden_door; glass
	             block.glass.hit), a block broken goes (`world:setBlock` to air, so every block
	             rule hears of it) with nothing dropped: a door with both its halves at once (or
	             Behaviours/Door would pop the other half as an item) and the door breaking sound
	             (entity.zombie.break_wooden_door), glass shattering (block.glass.break), anything
	             else its own break sound (those are noises too: Audio/Sounds.play; a door, whose
	             zombie sound is none, makes Noise.Break's 10 through Apocalypse/NoiseBus). A
	             screamer's shriek goes to Apocalypse/NoiseBus, heard next tick.
	  Attacks    Protocol Attack (mob id), at most Config.Mobs.AttacksPerSecond a player:
	             MobWorld.attack checks the player (alive, not a spectator), the reach from their
	             eyes (Shared/Entities/Combat: 3 blocks, 6 in creative, plus a block of leeway) and
	             the line of sight, then hits with the held item at its attack strength (ticks
	             since the player's last attack or change of held item; Feral Claws' attack speed
	             recharges it faster: Items/Accessories.hasteTicks), with the player's
	             Strength and Weakness (Players/Effects.levels); a hit plays
	             entity.player.attack.strong or .weak and wears a tool (swords 1, other tools 2;
	             not in creative).
	  Tracking   every SyncTicks (2: 10 a second) each player gets the mobs around their feet
	             (Mobs/MobTracking): a spawn when one comes within Config.Mobs.TrackingDistance, a
	             remove when it is more than 8 blocks beyond that or gone (so a mob at the edge
	             isn't spawned and removed over and over), and in between what changed (facing,
	             health, the flags: hurt flash, burning, dying, aggressive (a target or a hunt),
	             attacking (a swing in the last 8 ticks), breaking a block, screaming) as a move
	             (op 6: the change of its position from the one last sent to this player, in
	             whole 1/32 block steps, so it never drifts; a state, op 2, when a step would not
	             fit an i16). Mobs more than 32 blocks away are looked at every other sync (by
	             their id), five times a second. All in one Mobs message with the player's
	             knockback: 60 zombies on the move cost 2 + 60 x 14 bytes.
	  Commands   /summon <kind> [x y z] and /kill @e[type=<kind>] (Mobs/SummonCommand), for those
	             who may change the time (the operators' permission: Players/Operators).
	  Off        with Config.Mobs.Enabled false nothing spawns, ticks or is sent; a world type
	             with `mobs = false` (the void and the debug worlds: Generation/WorldTypes) has no
	             natural spawning and no blood moon waves, and Peaceful no monsters
	             (World/WorldInfo.apply sets Config.Mobs.Spawning / the hostile caps before the
	             world starts; /summon still works).

	For other server scripts (the integration hooks):
	  Mobs.died            Event (killer: Player?, kind: string, x, y, z, id): a mob died; the
	                       killer is the player whose hit counts (the last within 5 s), nil for
	                       anything else (fire, falls, blasts, /kill)
	  Mobs.playerHit       Event (player: Player, kind: string, damage: number, fresh: boolean,
	                       mobId: number): a mob's hit on a player landed (Characters.hurt: the
	                       half hearts after armor and Resistance, and whether it was a fresh
	                       hurt, not under the cooldown)
	  Mobs.damage(id, amount, attacker?, x?, z?)   hurts a mob (half hearts) through its cooldown
	                       and armor, knocked back from (x, z) when given; returns what landed
	  Mobs.near(x, y, z, radius)   the live mobs around a point (MobView: id, kind, position,
	                       box, health)
	  Mobs.magicDamage(id, amount, attacker?, x?, z?, knockback?)   a magic projectile's hit
	                       (Players/Magic): as `damage`, with the weapon's own knockback, never
	                       refused by the hurt cooldown (a projectile strikes a mob once:
	                       MobWorld's `ownImmunity`)
	  Mobs.ignite(id, ticks)   sets a mob burning for at least `ticks` (the spark's fire)
	  Mobs.spawn(kind, x, y, z, variant?)    a mob of a MobList name at a position, in a variant
	                       (a zombie's look and skin: MobList.lookVariant; random when nil), or 0
	                       when it can't
	  Mobs.explode(x, y, z, power, getBlock)   what a blast does to mobs (World/Explosions'
	                       handler, set by the boot script)
	  Mobs.lightning(x, y, z)   what a lightning bolt does to mobs (World/WeatherServer's strike
	                       handler, set by the boot script): burning and Lightning.Damage
	  Mobs.occupied(block, x, y, z)   would `block` placed at (x, y, z) overlap a mob (its
	                       Blocks.obstruction: solid blocks and lanterns, not torches)?
	                       (Network/ServerNet's `occupied` rule: no block goes inside a mob)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local SharedSounds = require(Shared.Sounds)
local WorldSettings = require(Shared.WorldSettings)
local Combat = require(Shared.Entities.Combat)
local Accessories = require(Shared.Items.Accessories)
local Coords = require(Shared.World.Coords)
local GameMode = require(Shared.GameMode)
local MobList = require(Shared.Entities.MobList)
local Protocol = require(Shared.Net.Protocol)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Simulation = require(script.Parent.Parent.World.Simulation)
local Skylight = require(script.Parent.Parent.World.Skylight)
local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
local WeatherServer = require(script.Parent.Parent.World.WeatherServer)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Entities = require(script.Parent.Parent.Entities.Entities)
local Characters = require(script.Parent.Parent.Players.Characters)
local Effects = require(script.Parent.Parent.Players.Effects)
local Operators = require(script.Parent.Parent.Players.Operators)
local Inventories = require(script.Parent.Parent.Players.Inventories)
local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions)
local NoiseBus = require(script.Parent.Parent.Apocalypse.NoiseBus)
local MobWorld = require(script.Parent.MobWorld)
local MobSpawning = require(script.Parent.MobSpawning)
local MobTracking = require(script.Parent.MobTracking)
local SummonCommand = require(script.Parent.SummonCommand)
local ZombieDirector = require(script.Parent.ZombieDirector)

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
local EYE = Combat.EYE
local LIMIT = Protocol.MAX_COORDINATE + 64
local MAX_HEIGHT = 4096
local AIR = Blocks.AIR
local GLASS_BREAK = SharedSounds.id["block.glass.break"]
local GLASS_HIT = SharedSounds.id["block.glass.hit"]
local DOOR_HIT = "entity.zombie.attack_wooden_door"
local DOOR_BREAK = "entity.zombie.break_wooden_door"

local Mobs = {}

local diedEvent = Instance.new("BindableEvent")
-- Fires (killer: Player?, kind: string, x: number, y: number, z: number, id: number) when a mob
-- dies (see the header).
Mobs.died = diedEvent.Event
local playerHitEvent = Instance.new("BindableEvent")
-- Fires (player: Player, kind: string, damage: number, fresh: boolean, mobId: number) when a
-- mob's hit on a player lands (see the header).
Mobs.playerHit = playerHitEvent.Event

local mobWorld: MobWorld.MobWorld? = nil
local serverWorld: WorldServer.World? = nil
local random = Random.new()
-- Per player: the last state sent of each mob their client knows (quantized), and ops waiting
-- for the next sync (their knockback).
local known: { [Player]: { [number]: MobTracking.Sent } } = {}
local pending: { [Player]: { Protocol.MobOp } } = {}
-- Per player: the tick of their last swing and of their last change of held item, and that item.
type Swing = { swing: number, changed: number, item: number? }
local swings: { [Player]: Swing } = {}
local attackBuckets: { [Player]: { tokens: number, last: number } } = {}
local tickCount = 0
local syncCount = 0

local function finite(x: number, y: number, z: number): boolean
	return x == x and y == y and z == z and math.abs(x) <= LIMIT and math.abs(z) <= LIMIT and math.abs(y) <= MAX_HEIGHT
end

-- A player's feet (Players/PlayerPositions), if they are a sane position; nil, 0, 0 else.
local function feetOf(player: Player): (number?, number, number)
	local x, y, z = PlayerPositions.feet(player)
	if x and finite(x, y, z) then
		return x, y, z
	end
	return nil, 0, 0
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
		local fx, fy, fz = feetOf(player)
		if fx then
			table.insert(views, {
				key = player,
				x = fx,
				y = fy,
				z = fz,
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

-- Sends every player the mobs around them (see the header).
local function replicate(net: Net, mobs: MobWorld.MobWorld)
	syncCount += 1
	local all = mobs:each()
	-- (Each mob's state once, shared by every player's record of it: never changed after.)
	local states: { [number]: MobTracking.Sent } = {}
	for _, mob in all do
		states[mob.id] = MobTracking.snapshot(mob)
	end
	for _, player in Players:GetPlayers() do
		local seen = known[player]
		if seen == nil then
			seen = {}
			known[player] = seen
		end
		local ops: { Protocol.MobOp } = pending[player] or {}
		pending[player] = nil
		local px, py, pz = feetOf(player)
		MobTracking.ops(ops, seen, all, states, px, py, pz, Settings.TrackingDistance, syncCount)
		if #ops > 0 then
			net.send(player, Protocol.ServerMessage.Mobs, Protocol.encodeMobs(ops))
		end
	end
end

--[[
	A block a zombie broke (MobWorld's `breaks`; see the header): it goes, both halves of a door,
	with nothing dropped and its sound. Nothing happens when the block changed meanwhile.
]]
local function breakBlock(world: WorldServer.World, x: number, y: number, z: number, block: number)
	if world:peekBlock(x, y, z) ~= block then
		return
	end
	if Blocks.isDoor(block) then
		local dy = Blocks.otherHalf(block)
		local partner = if dy == nil then nil elseif dy > 0 then Blocks.plantTop(block) else Blocks.plantBottom(block)
		world:setBlock(x, y, z, AIR)
		if dy ~= nil and partner ~= nil and world:peekBlock(x, y + dy, z) == partner then
			world:setBlock(x, y + dy, z, AIR)
		end
		Sounds.play(DOOR_BREAK, x + 0.5, y + 0.5, z + 0.5)
		-- (The zombie's own door sound is no noise, Apocalypse/NoiseRules: a block broken is.)
		NoiseBus.emit(x + 0.5, y + 0.5, z + 0.5, Config.Apocalypse.Noise.Break)
		return
	end
	world:setBlock(x, y, z, AIR)
	Sounds.playBlock(block, "break", x, y, z)
end

-- What the tick's changes do to the rest of the game (see the header).
local function apply(mobs: MobWorld.MobWorld)
	local changes = mobs:takeChanges()
	for _, cue in changes.sounds do
		Sounds.play(cue.name, cue.x, cue.y, cue.z)
	end
	for _, hit in changes.blockHits do
		local glass = SharedSounds.block(hit.block, "break") == GLASS_BREAK
		Sounds.play(if glass then GLASS_HIT else DOOR_HIT, hit.x + 0.5, hit.y + 0.5, hit.z + 0.5)
	end
	local world = serverWorld
	if world then
		for _, broken in changes.breaks do
			breakBlock(world, broken.x, broken.y, broken.z, broken.block)
		end
	end
	for _, noise in changes.noises do
		NoiseBus.emit(noise.x, noise.y, noise.z, noise.radius)
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
			local landed, fresh = Characters.hurt(player, hit.damage)
			if landed > 0 then
				playerHitEvent:Fire(player, hit.kind, landed, fresh, hit.id)
			end
			-- (Knockback resistance takes its share off: a Cobalt Shield all of it.)
			local share = Characters.knockbackShare(player)
			if fresh and share > 0 then
				local kx, ky, kz = hit.kx * share, hit.ky * share, hit.kz * share
				queue(player, { op = "push", id = hit.id, kx = kx, ky = ky, kz = kz })
				Characters.knockedBack(player, kx, ky, kz)
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
	local fx, fy, fz = feetOf(player)
	if fx == nil then
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
	-- (Feral Claws: the weapon recovers attackSpeed faster.)
	since = Accessories.hasteTicks(since, Inventories.accessories(player).attackSpeed)
	local landed, result = mobs:attack(id, {
		key = player,
		x = fx,
		y = fy,
		z = fz,
		eye = EYE,
		mode = mode,
		alive = aliveOf(player),
		item = held,
		ticks = since,
		-- (Strength and Weakness.)
		levels = Effects.levels(player),
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
	-- (Relative coordinates from the feet; from 0, 0, 0 without a position.)
	local fx, fy, fz = feetOf(player)
	local result = SummonCommand.run(text, {
		mayUse = Operators.permitted(player),
		enabled = Settings.Enabled and mobWorld ~= nil,
		x = fx or 0,
		y = if fx then fy else 0,
		z = if fx then fz else 0,
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
		-- (The operators' permission: the chat suggests them to those who have it.)
		instance:SetAttribute(WorldSettings.COMMAND_ATTRIBUTE, WorldSettings.COMMAND_PERMITTED)
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
	local director = ZombieDirector.new()
	local generator = (world :: any).generator
	local generatorCityAt = if generator then generator.cityAt else nil
	local function cityAt(x: number, z: number): number
		return if generatorCityAt then generatorCityAt(x, z) else 0
	end
	-- (The generator's ground: blood moon waves keep off the cities' roofs, ZombieDirector.)
	local generatorColumn = if generator then generator.column else nil
	local ground: ((x: number, z: number) -> number)? = nil
	if generatorColumn then
		ground = function(x: number, z: number): number
			return (generatorColumn(x, z))
		end
	end
	local active: { [number]: boolean } = {}
	local function isActive(cx: number, cz: number): boolean
		return active[Coords.chunkKey(cx, cz)] == true
	end
	local function skyOpen(x: number, y: number, z: number): boolean?
		return Skylight.open(world, x, y, z)
	end
	local function skyClear(x: number, y: number, z: number): boolean?
		return Skylight.clear(world, x, y, z)
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
			local dayTime = TimeOfDay.get()
			local apocalypse = Config.Apocalypse
			local on = apocalypse.Enabled
			local night = not DayCycle.isDay(dayTime)
			local moonUp, moon = ZombieDirector.moon(apocalypse, dayTime)
			local maxMobs, maxHostile = ZombieDirector.limits(Settings, apocalypse, dayTime)
			mobs.options.maxMobs = maxMobs
			local spawnSettings: MobSpawning.Settings = {
				Spawning = Settings.Spawning,
				PassiveCap = Settings.PassiveCap,
				HostileCap = Settings.HostileCap,
				MaxPassive = Settings.MaxPassive,
				MaxHostile = maxHostile,
				PassiveInterval = Settings.PassiveInterval,
				HostileInterval = Settings.HostileInterval,
				Attempts = Settings.Attempts,
				SpawnDistance = Settings.SpawnDistance,
			}
			-- (Off, the old zombie's rules: nothing heard.)
			local noises: { NoiseBus.Noise }? = nil
			if on then
				noises = ZombieDirector.hear(NoiseBus.take(), night, WeatherServer.rainingAt, apocalypse.Noise)
			else
				NoiseBus.take()
			end
			local context = {
				players = playerViews(),
				dayTime = dayTime,
				skyOpen = skyOpen,
				skyClear = skyClear,
				active = isActive,
				rainingAt = WeatherServer.rainingAt,
				isDay = function(x: number, z: number): boolean
					return WeatherServer.isDayAt(x, z, dayTime)
				end,
				noises = noises,
				night = night,
				breaking = on and apocalypse.Breaking.Enabled,
				cityAt = cityAt,
				hostileCap = function(player: MobWorld.PlayerView): number
					return ZombieDirector.cap(Settings, apocalypse, night, cityAt(player.x, player.z), moon)
				end,
				daySpawn = on and apocalypse.Zombies.DaySpawning,
				hostilePaused = moonUp,
				ground = ground,
			}
			mobs:tick(context)
			MobSpawning.step(mobs, spawnState, context, spawnSettings)
			ZombieDirector.step(mobs, director, context, Settings, apocalypse)
			apply(mobs)
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

--[[
	A magic projectile's hit (Players/Magic): hurts mob `id` by `amount` half hearts through its
	armor (Terraria's defense against magic), credited to `attacker`, pushed away from (x, z) by
	`knockback` blocks a tick (0: no push; the weapon's own, not a melee hit's 0.4). The hurt
	cooldown doesn't refuse it (each projectile strikes a mob once, Terraria's projectile immunity:
	a Wand of Sparking's 9 tick casts all land on one mob); it starts one, as any hurt. Returns what
	landed.
]]
function Mobs.magicDamage(
	id: number,
	amount: number,
	attacker: Player?,
	x: number?,
	z: number?,
	knockback: number?
): number
	local mobs = mobWorld
	if mobs == nil then
		return 0
	end
	return mobs:hurt(id, amount, { player = attacker, x = x, z = z, knockback = knockback or 0, ownImmunity = true })
end

--[[
	Sets mob `id` burning for at least `ticks` (Minecraft's Entity.setSecondsOnFire: a longer fire
	already burning stays): the Wand of Sparking's spark (Players/Magic). Water and rain put it out
	as any fire. Whether it is burning now.
]]
function Mobs.ignite(id: number, ticks: number): boolean
	local mobs = mobWorld
	local mob = if mobs then mobs:get(id) else nil
	if mob == nil or mob.dead or not (ticks > 0) or mob.kind.fireImmune then
		return false
	end
	mob.burn.fire = math.max(mob.burn.fire, math.floor(ticks))
	return true
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

function Mobs.spawn(kind: string, x: number, y: number, z: number, variant: number?): number
	local mobs = mobWorld
	local id = MobList.find(kind)
	if mobs == nil or id == nil then
		return 0
	end
	return mobs:spawn(id, x, y, z, variant)
end

--[[
	World/WeatherServer's strike handler (set by the boot script): a lightning bolt at (x, y, z)
	(blocks: the bottom centre of the struck cell) burns and hurts the mobs it reaches
	(MobWorld.lightning: Config.Weather.Lightning's Damage and BurnSeconds). Returns how many.
]]
function Mobs.lightning(x: number, y: number, z: number): number
	local mobs = mobWorld
	local settings = Config.Weather.Lightning
	return if mobs then mobs:lightning(x, y, z, settings.Damage, math.floor(settings.BurnSeconds / TICK + 0.5)) else 0
end

-- World/Explosions' handler: a blast of `power` at (x, y, z) hurts and pushes the mobs near it.
function Mobs.explode(x: number, y: number, z: number, power: number): number
	local mobs = mobWorld
	return if mobs then mobs:explode(x, y, z, power) else 0
end

-- Would `block` placed at (x, y, z) overlap a mob's box (dying ones too)? ServerNet refuses such
-- a placement (its `occupied` rule), as Minecraft's Level.isUnobstructed refuses a block inside a
-- living entity: otherwise a block in a monster's head cell would blind it (no melee) until the
-- wall smothers it.
function Mobs.occupied(block: number, x: number, y: number, z: number): boolean
	local mobs = mobWorld
	local box = Blocks.obstruction(block)
	return mobs ~= nil
		and box ~= nil
		and mobs:overlaps(x + box[1], y + box[2], z + box[3], x + box[4], y + box[5], z + box[6])
end

-- For WorldServer.onChanged: block (x, y, z) changed from `old` to `new` (zombies' damage on a
-- block replaced starts over: MobWorld.blockChanged).
function Mobs.blockChanged(x: number, y: number, z: number, old: number, new: number)
	local mobs = mobWorld
	if mobs then
		mobs:blockChanged(x, y, z, old, new)
	end
end

-- The mobs' simulation (nil before `start`): World/WorldSave saves and restores farm animals
-- through it.
function Mobs.world(): MobWorld.MobWorld?
	return mobWorld
end

-- Mobs in the world (for the debug overlay and tests).
function Mobs.count(): number
	local mobs = mobWorld
	return if mobs then mobs:count() else 0
end

return Mobs

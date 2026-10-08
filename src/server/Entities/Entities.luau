--!strict
--[[
	Dropped items on the server: runs EntityWorld (the Minecraft rules) at 20 ticks per second on
	Heartbeat, against the server's block data, and replicates the items to players.

	  Blocks    `world:peekBlock`, which never generates chunks: an item in a chunk the server has
	            not generated (or evicted) is frozen; unloaded neighbours count as solid.
	  Pickups   living characters (Humanoid.Health > 0) pick items up at their feet
	            (Players/PlayerPositions, as every position of a player here),
	            but not spectators' (Players/GameModeRules.picksUp); the pickup handler
	            (Players/Inventories) says how many fit in the inventory.
	            Everyone near hears it, the collector too (entity.item.pickup at the item,
	            Audio/Sounds; Minecraft's clients play it on the take packet).
	  Spawning  `dropBlock` is Minecraft's Block.popResource, `dropContents` its
	            Containers.dropItemStack (chest contents, in random handfuls), `throwFromPlayer`
	            its Player.drop (thrown forwards from the eyes, or scattered around on death).
	  Lava      items touching lava burn away (EntityWorld, Players/Burning), each lava hurt with
	            Minecraft's entity.generic.burn at the item (at the event's own volume 0.4 and
	            pitch 2 to 2.4) once Shared/Sounds has the event.
	  Blasts    `explode` (World/Explosions' handler, the boot script): items near an explosion
	            are destroyed or pushed away (EntityWorld.explode), and pushed ones resync at once.
	  Damage    items keep their stack's `damage` and item data (a worn tool stays worn, a Fluid
	            Tank keeps its water, when thrown, dropped from a chest, broken or scattered on
	            death, and is picked up as it was; only equal data merges). Clients do not need
	            either: they only draw the item.
	  Tracking  every player sees the items within Config.Entities.TrackingDistance blocks of their
	            feet. An item is spawned on their client when it comes into range (with its current
	            state and age) and removed when it leaves; ranges are checked every half second, and
	            new items at once. Clients simulate the items themselves (ItemPhysics), so they only
	            get the server's state every 20 ticks while an item moves and once when it comes to
	            rest, plus count changes, and removals with the collecting player's UserId (0 when
	            nobody collected it). Everything a player gets in one tick goes in one message.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local ItemPhysics = require(Shared.Entities.ItemPhysics)
local SharedSounds = require(Shared.Sounds)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local EntityWorld = require(script.Parent.EntityWorld)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local GameModeRules = require(script.Parent.Parent.Players.GameModeRules)
local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions)

type Stack = Items.Stack
type EntityOp = Protocol.EntityOp

-- Only what Entities uses of ServerNet.ServerNet (no require, so ServerNet may require this).
type Net = { send: (player: Player, kind: number, payload: buffer) -> () }

local TICK_RATE = ItemPhysics.TICK_RATE
local TICK = 1 / TICK_RATE
-- Ticks run at most per frame (a long hitch does not fast-forward the items).
local MAX_TICKS_PER_FRAME = 4
-- Ticks between full tracking range checks.
local SCAN_INTERVAL = 10
-- Items spawned on one client per message; the rest follow at the next range check.
local MAX_SPAWNS_PER_MESSAGE = 256
-- Minecraft: thrown items leave 0.3 below the eyes (eye height 1.62).
local THROW_HEIGHT = 1.62 - 0.3
local MAX_COUNT = 255
-- Minecraft's Entity.lavaHurt sound (nil until Shared/Sounds has it).
local BURN = SharedSounds.find("entity.generic.burn")

local Entities = {}

local entityWorld: EntityWorld.EntityWorld? = nil
local pickupHandler: ((player: Player, stack: Stack) -> number)? = nil
local random = Random.new()
-- Per player: the ids their client knows, and their last known feet position (blocks: x, y, z).
local tracked: { [Player]: { [number]: boolean } } = {}
local lastFeet: { [Player]: { number } } = {}

local function finite(...: number): boolean
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if value ~= value or value == math.huge or value == -math.huge then
			return false
		end
	end
	return true
end

-- Only finite positions within the world's coordinate range count (EntityWorld's grids and Hull
-- would otherwise loop forever).
local MAX_SPEED = 4
local LIMIT = Protocol.MAX_COORDINATE + 64
local MAX_HEIGHT = 4096
local function sane(x: number, y: number, z: number): boolean
	return finite(x, y, z) and math.abs(x) <= LIMIT and math.abs(z) <= LIMIT and math.abs(y) <= MAX_HEIGHT
end

-- A player's feet (PlayerPositions: only finite ones within the world's coordinate range, or
-- EntityWorld's grids and Hull would loop forever), else where they were last seen.
local function feetOf(player: Player): (number?, number, number)
	local x, y, z = PlayerPositions.feet(player)
	if x then
		return x, y, z
	end
	local last = lastFeet[player]
	if last then
		return last[1], last[2], last[3]
	end
	return nil, 0, 0
end

local function tryPickup(
	key: any,
	item: number,
	count: number,
	damage: number?,
	x: number,
	y: number,
	z: number,
	data: Items.Data?
): number
	local handler = pickupHandler
	local player = key :: Player
	if handler == nil or player.Parent == nil then
		return 0
	end
	local ok, taken = pcall(handler, player, { item = item, count = count, damage = damage, data = data })
	if not ok then
		warn(`[IceVoxel] the item pickup handler failed: {taken}`)
		return 0
	end
	local amount = if type(taken) == "number" then taken else 0
	if amount >= 1 then
		Sounds.play("entity.item.pickup", x, y, z)
	end
	return amount
end

local function spawnOp(entity: EntityWorld.Entity): EntityOp
	local body = entity.body
	return {
		op = "spawn",
		id = entity.id,
		item = entity.item,
		count = math.min(entity.count, MAX_COUNT),
		x = body.x,
		y = body.y,
		z = body.z,
		vx = body.vx,
		vy = body.vy,
		vz = body.vz,
		age = body.age,
	}
end

-- Sends every player what changed about the items around them this tick.
local function userIdOf(collector: any): number
	return if typeof(collector) == "Instance" and collector:IsA("Player") then collector.UserId else 0
end

local function replicate(net: Net, entities: EntityWorld.EntityWorld, scan: boolean)
	local changes = entities:takeChanges()
	if BURN then
		for _, at in changes.burnt do
			-- (The event carries Minecraft's volume and pitch already: no cue on top.)
			Sounds.play(BURN, at.x, at.y, at.z)
		end
	end
	local range = Config.Entities.TrackingDistance
	local rangeSq = range * range
	local all = if scan then entities:each() else nil

	for _, player in Players:GetPlayers() do
		local known = tracked[player]
		if known == nil then
			known = {}
			tracked[player] = known
		end
		local ops: { EntityOp } = {}

		-- Partial pickups fly to the collector too (the count op that follows shrinks the rest),
		-- sent first: another player may have taken the rest in the same tick.
		for _, take in changes.taken do
			if known[take.id] then
				table.insert(ops, {
					op = "take",
					id = take.id,
					count = math.min(take.count, 255),
					collector = userIdOf(take.collector),
				})
			end
		end
		for _, removal in changes.removed do
			if known[removal.id] then
				known[removal.id] = nil
				table.insert(ops, { op = "remove", id = removal.id, collector = userIdOf(removal.collector) })
			end
		end

		local px, py, pz = feetOf(player)
		if px then
			local function inRange(entity: EntityWorld.Entity): boolean
				local body = entity.body
				local dx, dy, dz = body.x - px, body.y - py, body.z - pz
				return dx * dx + dy * dy + dz * dz <= rangeSq
			end
			local fresh: { [number]: boolean } = {}
			local spawns = 0
			local function spawn(entity: EntityWorld.Entity)
				if spawns < MAX_SPAWNS_PER_MESSAGE then
					spawns += 1
					known[entity.id] = true
					fresh[entity.id] = true
					table.insert(ops, spawnOp(entity))
				end
			end

			if all then
				-- Items leaving and entering the range.
				for id in known do
					local entity = entities:get(id)
					if entity == nil or not inRange(entity) then
						known[id] = nil
						table.insert(ops, { op = "remove", id = id, collector = 0 })
					end
				end
				for _, entity in all do
					if not known[entity.id] and inRange(entity) then
						spawn(entity)
					end
				end
			else
				for _, id in changes.spawned do
					local entity = entities:get(id)
					if entity and not known[id] and inRange(entity) then
						spawn(entity)
					end
				end
			end

			-- (A spawn already carries the current state.)
			for _, id in changes.moved do
				local entity = entities:get(id)
				if entity and known[id] and not fresh[id] then
					local body = entity.body
					table.insert(ops, {
						op = "sync",
						id = id,
						x = body.x,
						y = body.y,
						z = body.z,
						vx = body.vx,
						vy = body.vy,
						vz = body.vz,
					})
				end
			end
			for _, id in changes.counts do
				local entity = entities:get(id)
				if entity and known[id] and not fresh[id] then
					table.insert(ops, { op = "count", id = id, count = math.min(entity.count, MAX_COUNT) })
				end
			end
		end

		if #ops > 0 then
			net.send(player, Protocol.ServerMessage.Entities, Protocol.encodeEntities(ops))
		end
	end
end

local function step(net: Net, entities: EntityWorld.EntityWorld, tick: number)
	-- Living players pick items up (not spectators); everyone's position is remembered for
	-- tracking and throws.
	local pickers: { EntityWorld.PlayerBox } = {}
	for player, x, y, z in PlayerPositions.each() do
		local character = player.Character
		local last = lastFeet[player]
		if last == nil then
			last = { x, y, z }
			lastFeet[player] = last
		else
			last[1], last[2], last[3] = x, y, z
		end
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid and humanoid.Health > 0 and GameModeRules.picksUp(GameMode.of(player)) then
			table.insert(pickers, { key = player, x = x, y = y, z = z })
		end
	end
	entities:tick(pickers, tryPickup)
	replicate(net, entities, tick % SCAN_INTERVAL == 0)
end

-- Starts ticking and replicating the items. `net` is the ServerNet.
function Entities.start(net: Net, world: WorldServer.World)
	assert(entityWorld == nil, "Entities.start was already called")
	local entities = EntityWorld.new(function(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end, {
		maxItems = Config.Entities.MaxItems,
		lifetimeTicks = math.floor(Config.Entities.ItemLifetime * TICK_RATE),
		random = random,
	})
	entityWorld = entities

	Players.PlayerRemoving:Connect(function(player)
		tracked[player] = nil
		lastFeet[player] = nil
	end)

	local accumulator = 0
	local tick = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tick += 1
			step(net, entities, tick)
		end
	end)
end

--[[
	Sets who decides what a player picking up `stack` takes (Players/Inventories): it returns how
	many of the items it took (0 = none, e.g. a full inventory).
]]
function Entities.setPickupHandler(handler: (player: Player, stack: Stack) -> number)
	pickupHandler = handler
end

--[[
	Drops an item at (x, y, z) (blocks: the bottom centre of the item) with a velocity in blocks
	per tick (Minecraft's random pop when left out) and a pickup delay in ticks (10 by default).
	Returns the item's id, 0 if nothing was spawned. Stacks larger than a full stack become
	several items (the first one's id is returned), each with the stack's damage and data.
]]
function Entities.spawnItem(
	stack: Stack,
	x: number,
	y: number,
	z: number,
	vx: number?,
	vy: number?,
	vz: number?,
	pickupDelay: number?
): number
	local entities = entityWorld
	assert(entities, "Entities.start must run before items spawn")
	local count = math.floor(stack.count)
	if not Items.isValid(stack.item) or count < 1 or not sane(x, y, z) or not finite(vx or 0, vy or 0, vz or 0) then
		return 0
	end
	-- (Blocks per tick; far faster than anything throws, small enough to keep collision cheap.)
	vx = if vx then math.clamp(vx, -MAX_SPEED, MAX_SPEED) else nil
	vy = if vy then math.clamp(vy, -MAX_SPEED, MAX_SPEED) else nil
	vz = if vz then math.clamp(vz, -MAX_SPEED, MAX_SPEED) else nil
	local max = Items.maxStack(stack.item)
	local first = 0
	while count > 0 do
		local part = math.min(count, max)
		count -= part
		local id = entities:spawnItem(stack.item, part, x, y, z, vx, vy, vz, pickupDelay, stack.damage, stack.data)
		if first == 0 then
			first = id
		end
	end
	return first
end

--[[
	The drop of a broken block (Block.popResource): somewhere around the block's centre (+-0.25),
	popping up at 0.2 blocks per tick and a little sideways, pickable after 10 ticks.
]]
function Entities.dropBlock(x: number, y: number, z: number, stack: Stack)
	local sink = ItemPhysics.HEIGHT / 2
	Entities.spawnItem(
		stack,
		x + 0.5 + random:NextNumber(-0.25, 0.25),
		y + 0.5 + random:NextNumber(-0.25, 0.25) - sink,
		z + 0.5 + random:NextNumber(-0.25, 0.25),
		random:NextNumber(-0.1, 0.1),
		0.2,
		random:NextNumber(-0.1, 0.1),
		EntityWorld.DEFAULT_PICKUP_DELAY
	)
end

-- Minecraft's Mth.triangle: mode +- spread, more likely near the mode.
local function triangle(mode: number, spread: number): number
	return mode + spread * (random:NextNumber() - random:NextNumber())
end

--[[
	The contents of a broken container at block (x, y, z) (Containers.dropItemStack): from one
	random spot in the block, in handfuls of 10 to 30 flying out in random directions, pickable at
	once.
]]
function Entities.dropContents(x: number, y: number, z: number, stack: Stack)
	local width = ItemPhysics.WIDTH
	local px = math.floor(x) + random:NextNumber() * (1 - width) + width / 2
	local py = math.floor(y) + random:NextNumber() * (1 - width)
	local pz = math.floor(z) + random:NextNumber() * (1 - width) + width / 2
	local left = math.floor(stack.count)
	while left > 0 do
		local part = math.min(left, random:NextInteger(10, 30))
		left -= part
		Entities.spawnItem(
			Items.withCount(stack, part) :: Stack,
			px,
			py,
			pz,
			triangle(0, 0.11485000171139836),
			triangle(0.2, 0.11485000171139836),
			triangle(0, 0.11485000171139836),
			0
		)
	end
end

--[[
	A stack leaving a player (Player.drop), from 0.3 below their eyes, pickable after 40 ticks:
	  scatter = false  thrown (Q, clicking outside the inventory): 0.3 blocks per tick towards
	                   where the character faces, 0.1 up, plus a little randomness;
	  scatter = true   death drops: in a random direction at up to 0.5, 0.2 up.
	Returns the item's id (nil if the player was never seen in the world).
]]
function Entities.throwFromPlayer(player: Player, stack: Stack, scatter: boolean): number?
	local fx, fy, fz = feetOf(player)
	if fx == nil then
		return nil
	end
	local vx, vy, vz
	if scatter then
		local speed = random:NextNumber() * 0.5
		local angle = random:NextNumber() * math.pi * 2
		vx, vy, vz = -math.sin(angle) * speed, 0.2, math.cos(angle) * speed
	else
		-- Items fly level, like looking straight ahead (reading characters, the server can't know
		-- the camera's pitch), towards where the player faces.
		local lx, _, lz = PlayerPositions.look(player)
		local flat = Vector3.new(lx, 0, lz)
		flat = if flat.Magnitude > 1e-6 then flat.Unit else Vector3.zAxis
		local angle = random:NextNumber() * math.pi * 2
		local jitter = 0.02 * random:NextNumber()
		vx = flat.X * 0.3 + math.cos(angle) * jitter
		vy = 0.1 + (random:NextNumber() - random:NextNumber()) * 0.1
		vz = flat.Z * 0.3 + math.sin(angle) * jitter
	end
	return Entities.spawnItem(stack, fx, fy + THROW_HEIGHT, fz, vx, vy, vz, EntityWorld.THROWN_PICKUP_DELAY)
end

-- An explosion of `power` at (x, y, z) (blocks): items near it are destroyed or pushed away
-- (EntityWorld.explode). Returns how many were destroyed.
function Entities.explode(x: number, y: number, z: number, power: number): number
	local entities = entityWorld
	return if entities then entities:explode(x, y, z, power) else 0
end

-- Number of dropped items in the world.
-- The items' simulation (nil before `start`): World/WorldSave saves and restores items through it.
function Entities.world(): EntityWorld.EntityWorld?
	return entityWorld
end

function Entities.count(): number
	local entities = entityWorld
	return if entities then entities:count() else 0
end

return Entities

--!strict
--[[
	Rooms on the server (Shared/Seasons/Rooms; Config.Seasons.Rooms): which cells are enclosed,
	insulated spaces, and their air's temperature, for the players in them (Players/ToughAsNails,
	once a second), the machines next to them (Shared/Machines' TickContext.climate, through
	Machines/Machines' env) and the snow on and in them (Seasons/SnowWorld). Rooms are entirely
	the server's; players learn of theirs through the Survival message (room and outside).

	  Cache      `roomOf[cellKey]` maps interior cells and `wallsOf[cellKey]` wall and opening
	             cells (World/Coords pos keys) to their rooms (a wall between two rooms to both).
	             A change at a room's cell or wall (`blockChanged`, from WorldServer.onChanged:
	             door toggles and every edit) marks it dirty and it is filled again from its seed
	             (a cell of it still passable when the seed no longer is); changes that keep a
	             cell's insulation and are no heat source either way (a torch put down, stone for
	             cobblestone) change nothing. The new room's air is the volume-weighted mean of
	             the rooms it overlaps, its cells no room had counted at the outside value: a
	             torch never resets the heat, a door opened onto a porch cools the room by the
	             porch's share. Cells of the old room the new one does not take (a wall built
	             across it) stay the old room's, which is filled again from one of them, so both
	             halves keep its air.
	  Seeds      each player's feet (`sample`, once a second with ToughAsNails' sample; the head's
	             cell when the feet's is a wall) and each room-source machine (`climateAt`, which
	             machines call every tick, and room sources placed: a campfire, a furnace, the
	             generators and heaters; not fire or lava) every MachineSeedSeconds when a player
	             is within Range blocks (sideways). A fill that finds no room marks every passable
	             cell it went through as no room for NotRoomSeconds (they are one open, too big or
	             unloaded space), unless a block there changes. A room nobody visited (a player
	             in it, a machine asking) for ForgetSeconds whose sources give nothing is
	             forgotten.
	  Budget     at most FillsPerFrame fills and FillMs a frame (`step`; dirty rooms and players'
	             seeds before machines'); a fill is at most MaxVolume x 6 block reads and a sky
	             scan per column. The air steps at 1 Hz (Rooms.step over the time since the last
	             step): its heat the room sources' (Players/Climate.roomSource: what each block
	             in the room or its walls gives, machines their `heat` field, at most a source's
	             limit of each kind) and PLAYER_HU for each player whose feet are in it; its
	             outside value (`outside`) the sheltered outdoor value at its seed's column
	             (Tough As Nails' Temperature.outside under a roof, with the season's shift and
	             night drop), kept within OutsideLimit. Nothing else runs per frame: O(rooms +
	             sources + players) a second.
	  Snow       `temperatureAt` (Seasons/SnowWorld: a snow cell and the block under it, up to 32
	             a visit, several visits a tick) is a lookup only, never a fill and nothing made:
	             the air of the room holding the cell, else of the warmest room it walls (a roof
	             block, a wall, a floor) or is an opening of; nil for cells of no room.
	  Machines   `climateAt` answers a machine's every tick: the room of the first of its cell and
	             its neighbours (above, below, then the sides) that is in one, its heat summed
	             again for the call (so a thermostat's `others`, the room's heat less its own,
	             is exact however often it changes), else nil and the outdoor value there
	             (worked out once a second per machine). `playerNear` says whether a player
	             stands within a radius of a cell (the positions of the last 1 Hz step): a space
	             heater's standby (Machines' TickContext `near`).

	The rooms' state is `RoomWorld.new(env)` (pure over its Env, so tests run it on a fake world);
	`start(world)` makes the game's one over World/WorldServer (loaded chunks only, never
	generating terrain; the sky height per column from the chunk's crop height down, the first
	block with an insulation) and the module functions answer from it. Nothing is saved: a
	loaded world's rooms are found again as players come back, their air starting at the outside
	value. Config.Seasons.Enabled or Rooms.Enabled off: no rooms anywhere.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Biomes = require(Shared.Biomes)
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local DayCycle = require(Shared.DayCycle)
local Fluids = require(Shared.Fluids)
local Rooms = require(Shared.Seasons.Rooms)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)
local Temperature = require(Shared.ToughAsNails.Temperature)

local Climate = require(script.Parent.Parent.Players.Climate)

-- A room as reported (Shared/Seasons/Rooms.Sample): id, air temperature and outside value
-- (Temperature's scale), losses, volume and the HU of its sources now.
export type Sample = Rooms.Sample

-- What a room source gives (Players/Climate.RoomOutput) and how many of it count in one room.
export type RoomSource = (block: number) -> (Climate.RoomOutput?, number?)

-- What the rooms need of the game (see the header).
export type Env = {
	-- The block at a cell, nil when unknown (not loaded). Never generates terrain.
	getBlock: (x: number, y: number, z: number) -> number?,
	-- The first height of column (x, z) open to the sky (math.huge: not loaded).
	skyAbove: (x: number, z: number) -> number,
	-- The column's terrain height (first air block) and surface biome (Biomes index).
	column: (x: number, z: number) -> (number, number),
	-- Minecraft's day time now (ticks).
	dayTime: () -> number,
	-- Calls `each` with every player's feet (blocks).
	players: (each: (x: number, y: number, z: number) -> ()) -> (),
	-- A clock in seconds (the frame's fill budget).
	clock: () -> number,
	-- The world's seed (heat waves).
	seed: number,
	-- Room sources (default Players/Climate.roomSource) and each player's HU (Climate.PLAYER_HU).
	roomSource: RoomSource?,
	playerHU: number?,
	-- The outdoor value a room at (x, y, z) loses to (nil: Tough As Nails' sheltered value, see
	-- the header). Tests give their own.
	outside: ((x: number, y: number, z: number) -> number)?,
}

-- A room the world follows.
type Record = {
	room: Rooms.Room,
	sample: Sample,
	-- Where it was filled from (again from there when dirty), and its column's terrain.
	seedX: number,
	seedY: number,
	seedZ: number,
	surface: number,
	biome: number,
	-- Its sources' positions, three numbers each (Rooms.Room `sources` decoded).
	sourceAt: { number },
	-- Players with their feet in it at the last step, the HU its sources gave (players aside)
	-- at the last step, when it was last visited, and whether it waits to be filled again.
	players: number,
	sourceHeat: number,
	visited: number,
	dirty: boolean,
	-- Gone (forgotten, or taken over by other rooms): queued refills skip it.
	gone: boolean,
}

-- Cells a fill found no room in, until `expires`.
type Failure = { cells: { [number]: true }, expires: number }

-- A seed waiting for a fill: a cell, or a dirty room (`record`).
type Seed = { x: number, y: number, z: number, record: Record? }

export type RoomWorld = {
	env: Env,
	limits: Rooms.Limits,
	-- Seconds of steps so far.
	time: number,
	rooms: { [number]: Record },
	count: number,
	nextId: number,
	roomOf: { [number]: Record },
	wallsOf: { [number]: Record | { [Record]: true } },
	failed: { [number]: Failure },
	failures: { Failure },
	-- Dirty rooms and players' seeds; machines' seeds; what is queued (cell keys).
	urgent: { Seed },
	later: { Seed },
	queued: { [number]: boolean },
	-- Room-source machines by cell key: their position.
	machines: { [number]: { number } },
	-- Outdoor values of machines outdoors: value and when.
	outdoor: { [number]: { number } },
	-- Players' feet at the last step (three numbers each).
	feet: { number },
	-- Seconds until the next air step, machine seeds and failure sweep.
	airIn: number,
	airDt: number,
	machinesIn: number,
	sweepIn: number,
	-- Statistics: fills run, the last frame's and the longest fill's time (ms).
	fills: number,
	frameMs: number,
	longestMs: number,
}

local settings = Config.Seasons.Rooms

local RoomWorld = {}

-- Coords.posKey's packing (World/Coords).
local OFFSET = 1048576
local SPAN = 2097152

local function posKey(x: number, y: number, z: number): number
	return ((x + OFFSET) * SPAN + (z + OFFSET)) * 1024 + y
end

local function decode(key: number): (number, number, number)
	local y = key % 1024
	local xz = key // 1024
	local xo = xz // SPAN
	return xo - OFFSET, y, xz - xo * SPAN - OFFSET
end

-- A machine's cell and its neighbours, in the order `climateAt` looks (self, above, below, sides).
local AROUND = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

-- The room sources `env` reads (Players/Climate's unless it gives its own).
local function sourcesOf(env: Env): RoomSource
	local own = env.roomSource
	if own then
		return own
	end
	return Climate.roomSource
end

--[[ Walls (a wall may belong to several rooms) ]]

local function addWall(world: RoomWorld, key: number, record: Record)
	local held = world.wallsOf[key]
	if held == nil then
		world.wallsOf[key] = record
	elseif held ~= record then
		if (held :: any).room ~= nil then
			local set: { [Record]: true } = {}
			set[held :: Record] = true
			set[record] = true
			world.wallsOf[key] = set
		else
			(held :: { [Record]: true })[record] = true
		end
	end
end

local function removeWall(world: RoomWorld, key: number, record: Record)
	local held = world.wallsOf[key]
	if held == nil then
		return
	elseif held == record then
		world.wallsOf[key] = nil
	elseif (held :: any).room == nil then
		local set = held :: { [Record]: true }
		set[record] = nil
		local first = next(set)
		if first == nil then
			world.wallsOf[key] = nil
		elseif next(set, first) == nil then
			world.wallsOf[key] = first
		end
	end
end

-- Calls `each` with every room cell `key` walls.
local function eachWalled(world: RoomWorld, key: number, each: (record: Record) -> ())
	local held = world.wallsOf[key]
	if held == nil then
		return
	elseif (held :: any).room ~= nil then
		each(held :: Record)
	else
		for record in held :: { [Record]: true } do
			each(record)
		end
	end
end

--[[ The outside ]]

-- One Temperature.Environment for the sheltered outdoor value (only climate, height and night
-- change; the player's own parts stay off).
local shelter: Temperature.Environment = {
	climate = 0,
	y = 0,
	surface = 0,
	skyOpen = false,
	night = false,
	wet = false,
	sprinting = false,
	heated = false,
	nearHeat = false,
	cooled = false,
	burning = false,
	armorWarmth = 0,
	armorCooling = 0,
}
local seasonSample: SeasonClimate.Sample? = nil

--[[
	The outdoor value a room loses to at height `y` of a column with terrain height `surface` and
	surface biome `biome`, at day time `dayTime` (see the header): Temperature.outside under a
	roof, with the season's shift and night drop while the calendar counts, within OutsideLimit.
]]
function RoomWorld.outsideValue(y: number, surface: number, biome: number, dayTime: number, seed: number): number
	local record = Biomes.get(biome)
	shelter.climate = if record then record.temperature else 0
	shelter.y = y
	shelter.surface = surface
	shelter.night = not DayCycle.isDay(dayTime)
	if SeasonClimate.active() then
		local season = SeasonClimate.sample(dayTime, SeasonClimate.classOf(biome), seed, nil, seasonSample)
		seasonSample = season
		shelter.seasonShift = season.shift
		shelter.nightDrop = season.nightDrop
	else
		shelter.seasonShift = nil
		shelter.nightDrop = nil
	end
	local value = Temperature.outside(shelter)
	local limit = settings.OutsideLimit
	return math.clamp(if value == value then value else 0, -limit, limit)
end

local function outsideAt(world: RoomWorld, x: number, y: number, z: number, surface: number, biome: number): number
	local env = world.env
	local custom = env.outside
	if custom then
		return custom(x, y, z)
	end
	return RoomWorld.outsideValue(y, surface, biome, env.dayTime(), env.seed)
end

--[[ Heat ]]

local counting: { [any]: number } = {}

-- What a room's sources give now (players aside), each kind at most its limit.
local function sourceHeat(world: RoomWorld, record: Record): number
	local env = world.env
	local roomSource = sourcesOf(env)
	local getBlock = env.getBlock
	local at = record.sourceAt
	local total = 0
	for i = 1, #at, 3 do
		local x, y, z = at[i], at[i + 1], at[i + 2]
		local block = getBlock(x, y, z)
		if block then
			local output, limit = roomSource(block)
			if output then
				local counted = (counting[output] or 0) + 1
				counting[output] = counted
				if limit == nil or counted <= limit then
					local hu = output(x, y, z, block)
					if type(hu) == "number" and hu == hu and math.abs(hu) < math.huge then
						total += hu
					end
				end
			end
		end
	end
	table.clear(counting)
	return total
end

-- A room's heat now: its sources' and its players' (at the last step).
local function heatOf(world: RoomWorld, record: Record): number
	local heat = sourceHeat(world, record)
	record.sourceHeat = heat
	return heat + record.players * (world.env.playerHU or Climate.PLAYER_HU)
end

--[[ Rooms coming and going ]]

local function destroy(world: RoomWorld, record: Record)
	if record.gone then
		return
	end
	record.gone = true
	local room = record.room
	for key in room.cells do
		if world.roomOf[key] == record then
			world.roomOf[key] = nil
		end
	end
	for key in room.walls do
		removeWall(world, key, record)
	end
	world.rooms[record.sample.id] = nil
	world.count -= 1
end

-- Queues room `record` to be filled again (see the header).
local function markDirty(world: RoomWorld, record: Record)
	if record.dirty or record.gone then
		return
	end
	record.dirty = true
	table.insert(world.urgent, { x = record.seedX, y = record.seedY, z = record.seedZ, record = record })
end

-- Is cell `key` known to be no room (a failed fill's, not expired)?
local function noRoom(world: RoomWorld, key: number): boolean
	local failure = world.failed[key]
	if failure == nil then
		return false
	elseif failure.expires > world.time then
		return true
	end
	world.failed[key] = nil
	return false
end

-- Queues a fill from cell (x, y, z) (players' first, `urgent`), unless it is known already.
local function enqueue(world: RoomWorld, x: number, y: number, z: number, urgent: boolean): boolean
	local key = posKey(x, y, z)
	if world.roomOf[key] or world.queued[key] or noRoom(world, key) then
		return false
	end
	world.queued[key] = true
	table.insert(if urgent then world.urgent else world.later, { x = x, y = y, z = z, record = nil })
	return true
end

-- The view Rooms.fill reads (the world's blocks, the sky, room sources).
local function viewOf(world: RoomWorld): Rooms.View
	local env = world.env
	local roomSource = sourcesOf(env)
	return {
		getBlock = env.getBlock,
		skyAbove = env.skyAbove,
		source = function(block: number): boolean
			return (roomSource(block)) ~= nil
		end,
	}
end

-- A filled room becomes the world's (see the header for the air it takes over).
local function adopt(world: RoomWorld, room: Rooms.Room, x: number, y: number, z: number): Record
	local env = world.env
	local surface, biome = env.column(x, z)
	local outside = outsideAt(world, x, y, z, surface, biome)
	-- The air: what the rooms it overlaps held, the cells no room had at the outside value.
	local weights: { [Record]: number } = {}
	local total, unknown = 0, 0
	for key in room.cells do
		local old = world.roomOf[key]
		if old then
			weights[old] = (weights[old] or 0) + 1
		else
			unknown += 1
		end
	end
	for old, weight in weights do
		total += old.sample.temperature * weight
	end
	local temperature = (total + unknown * outside) / room.volume
	world.nextId += 1
	local id = world.nextId
	room.id = id
	local sourceAt: { number } = {}
	for _, key in room.sources do
		local sx, sy, sz = decode(key)
		table.insert(sourceAt, sx)
		table.insert(sourceAt, sy)
		table.insert(sourceAt, sz)
	end
	local record: Record = {
		room = room,
		sample = {
			id = id,
			temperature = temperature,
			outside = outside,
			uaOut = room.uaOut,
			uaGround = room.uaGround,
			volume = room.volume,
			heat = 0,
		},
		seedX = x,
		seedY = y,
		seedZ = z,
		surface = surface,
		biome = biome,
		sourceAt = sourceAt,
		players = 0,
		sourceHeat = 0,
		visited = world.time,
		dirty = false,
		gone = false,
	}
	-- The rooms it took cells from keep the rest (filled again) or go.
	for old in weights do
		local cells = old.room.cells
		for key in room.cells do
			if world.roomOf[key] == old then
				cells[key] = nil
			end
		end
		if next(cells) == nil then
			destroy(world, old)
		else
			markDirty(world, old)
		end
	end
	for key in room.cells do
		world.roomOf[key] = record
		world.queued[key] = nil
	end
	for key in room.walls do
		addWall(world, key, record)
	end
	world.rooms[id] = record
	world.count += 1
	-- (Its players are counted at the next step; its heat now.)
	record.sample.heat = heatOf(world, record)
	return record
end

-- A fill found no room: its cells are no room for a while, and no room's any more.
local function refuse(world: RoomWorld, cells: { [number]: true })
	local failure: Failure = { cells = cells, expires = world.time + settings.NotRoomSeconds }
	local touched: { [Record]: boolean } = {}
	for key in cells do
		world.failed[key] = failure
		world.queued[key] = nil
		local old = world.roomOf[key]
		if old then
			world.roomOf[key] = nil
			old.room.cells[key] = nil
			touched[old] = true
		end
	end
	table.insert(world.failures, failure)
	for old in touched do
		if next(old.room.cells) == nil then
			destroy(world, old)
		else
			markDirty(world, old)
		end
	end
end

-- Where a dirty room is filled again from: its seed while still its passable cell, else another
-- of its cells that is (cells no longer passable are dropped). nil: none left.
local function refillSeed(world: RoomWorld, record: Record): (number?, number, number)
	local cells = record.room.cells
	local getBlock = world.env.getBlock
	local seedKey = posKey(record.seedX, record.seedY, record.seedZ)
	if cells[seedKey] then
		local block = getBlock(record.seedX, record.seedY, record.seedZ)
		if block ~= nil and Rooms.passable(block) then
			return record.seedX, record.seedY, record.seedZ
		end
	end
	while true do
		local key = next(cells)
		if key == nil then
			return nil, 0, 0
		end
		local x, y, z = decode(key)
		local block = getBlock(x, y, z)
		if block ~= nil and Rooms.passable(block) then
			return x, y, z
		end
		cells[key] = nil
		if world.roomOf[key] == record then
			world.roomOf[key] = nil
		end
	end
end

-- Fills from `seed` (see the header). true when a fill ran.
local function process(world: RoomWorld, seed: Seed): boolean
	local record = seed.record
	local x, y, z = seed.x, seed.y, seed.z
	if record then
		if record.gone or not record.dirty then
			return false
		end
		local sx, sy, sz = refillSeed(world, record)
		if sx == nil then
			destroy(world, record)
			return false
		end
		x, y, z = sx :: number, sy, sz
		record.dirty = false
	else
		local key = posKey(x, y, z)
		world.queued[key] = nil
		if world.roomOf[key] or noRoom(world, key) then
			return false
		end
	end
	local cells: { [number]: true } = {}
	local room = Rooms.fillCells(viewOf(world), x, y, z, world.limits, cells)
	world.fills += 1
	if room then
		-- (A dirty room's cells the new one did not take keep its air: `adopt` queues them.)
		adopt(world, room, x, y, z)
	else
		if next(cells) == nil then
			-- (The seed itself is open to the sky, or a wall.)
			cells[posKey(x, y, z)] = true
		end
		refuse(world, cells)
	end
	return true
end

--[[ Creating ]]

-- A world of no rooms over `env` (see the header).
function RoomWorld.new(env: Env, limits: Rooms.Limits?): RoomWorld
	return {
		env = env,
		limits = limits or Rooms.limits(),
		time = 0,
		rooms = {},
		count = 0,
		nextId = 0,
		roomOf = {},
		wallsOf = {},
		failed = {},
		failures = {},
		urgent = {},
		later = {},
		queued = {},
		machines = {},
		outdoor = {},
		feet = {},
		airIn = settings.SeedSeconds,
		airDt = 0,
		machinesIn = settings.MachineSeedSeconds,
		sweepIn = settings.NotRoomSeconds,
		fills = 0,
		frameMs = 0,
		longestMs = 0,
	}
end

--[[ Steps ]]

-- Is (x, z) within Range blocks (sideways) of a player's feet at the last step?
local function inRange(world: RoomWorld, x: number, z: number): boolean
	local feet = world.feet
	local range = settings.Range
	for i = 1, #feet, 3 do
		if math.abs(feet[i] - x) <= range and math.abs(feet[i + 2] - z) <= range then
			return true
		end
	end
	return false
end

-- The room of a machine's cell or its neighbours (see the header).
local function roomAround(world: RoomWorld, x: number, y: number, z: number): Record?
	local roomOf = world.roomOf
	for _, d in AROUND do
		local record = roomOf[posKey(x + d[1], y + d[2], z + d[3])]
		if record then
			return record
		end
	end
	return nil
end

-- Room-source machines with a player in range and no room yet seed fills from their neighbours.
local function seedMachines(world: RoomWorld)
	local getBlock = world.env.getBlock
	for _, at in world.machines do
		local x, y, z = at[1], at[2], at[3]
		if inRange(world, x, z) and roomAround(world, x, y, z) == nil then
			for i = 2, #AROUND do
				local d = AROUND[i]
				local nx, ny, nz = x + d[1], y + d[2], z + d[3]
				local block = getBlock(nx, ny, nz)
				if block ~= nil and Rooms.passable(block) then
					enqueue(world, nx, ny, nz, false)
				end
			end
		end
	end
end

-- Expired failures' cells are let go (a lookup lets them go one by one too).
local function sweepFailures(world: RoomWorld)
	local kept: { Failure } = {}
	for _, failure in world.failures do
		if failure.expires <= world.time then
			for key in failure.cells do
				if world.failed[key] == failure then
					world.failed[key] = nil
				end
			end
		else
			table.insert(kept, failure)
		end
	end
	world.failures = kept
	-- (Outdoor values of machines no longer asking.)
	for key, value in world.outdoor do
		if world.time - value[2] > settings.ForgetSeconds then
			world.outdoor[key] = nil
		end
	end
end

--[[
	The air's step (once a second): the players' feet, each room's players, heat, outside and air,
	and the rooms nobody visited whose sources give nothing are forgotten.
]]
local function stepAir(world: RoomWorld, dt: number)
	local env = world.env
	local feet = world.feet
	table.clear(feet)
	for _, record in world.rooms do
		record.players = 0
	end
	local roomOf = world.roomOf
	env.players(function(x: number, y: number, z: number)
		local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
		table.insert(feet, x)
		table.insert(feet, y)
		table.insert(feet, z)
		local record = roomOf[posKey(fx, fy, fz)] or roomOf[posKey(fx, fy + 1, fz)]
		if record then
			record.players += 1
		end
	end)
	local forget = settings.ForgetSeconds
	local gone: { Record } = {}
	for _, record in world.rooms do
		local sample = record.sample
		local outside = outsideAt(world, record.seedX, record.seedY, record.seedZ, record.surface, record.biome)
		local heat = heatOf(world, record)
		sample.outside = outside
		sample.heat = heat
		sample.temperature = Rooms.step(sample.temperature, record.room, outside, Rooms.GROUND, heat, dt)
		if record.players > 0 then
			record.visited = world.time
		elseif world.time - record.visited > forget and record.sourceHeat == 0 then
			table.insert(gone, record)
		end
	end
	for _, record in gone do
		destroy(world, record)
	end
end

local function popSeed(world: RoomWorld): Seed?
	local urgent = world.urgent
	if #urgent > 0 then
		return table.remove(urgent, 1)
	end
	local later = world.later
	if #later > 0 then
		return table.remove(later, 1)
	end
	return nil
end

-- A frame's work (see the header): fills within the budget, the air at 1 Hz.
function RoomWorld.stepWorld(world: RoomWorld, dt: number)
	world.time += dt
	world.airDt += dt
	world.airIn -= dt
	if world.airIn <= 0 then
		world.airIn = math.max(world.airIn + settings.SeedSeconds, 0)
		local elapsed = world.airDt
		world.airDt = 0
		stepAir(world, elapsed)
	end
	world.machinesIn -= dt
	if world.machinesIn <= 0 then
		world.machinesIn = math.max(world.machinesIn + settings.MachineSeedSeconds, 0)
		seedMachines(world)
	end
	world.sweepIn -= dt
	if world.sweepIn <= 0 then
		world.sweepIn = math.max(world.sweepIn + settings.NotRoomSeconds, 0)
		sweepFailures(world)
	end
	local clock = world.env.clock
	local start = clock()
	local budget = settings.FillMs / 1000
	local fills = 0
	while fills < settings.FillsPerFrame and clock() - start < budget do
		local seed = popSeed(world)
		if seed == nil then
			break
		end
		local before = clock()
		if process(world, seed) then
			fills += 1
			world.longestMs = math.max(world.longestMs, (clock() - before) * 1000)
		end
	end
	world.frameMs = (clock() - start) * 1000
end

--[[ Block changes ]]

-- Is `block` a room source a placed block seeds rooms from (not fluids, nor ones with a limit:
-- fire and lava)?
local function seedsRooms(world: RoomWorld, block: number): boolean
	local output, limit = sourcesOf(world.env)(block)
	return output ~= nil and limit == nil and Fluids.ofBlock(block) == 0
end

-- Block (x, y, z) went from `old` to `new` (see the header).
function RoomWorld.changed(world: RoomWorld, x: number, y: number, z: number, old: number, new: number)
	if old == new then
		return
	end
	local key = posKey(x, y, z)
	world.outdoor[key] = nil
	if seedsRooms(world, new) then
		world.machines[key] = { x, y, z }
	else
		world.machines[key] = nil
	end
	local roomSource = sourcesOf(world.env)
	local same = Rooms.passable(old) == Rooms.passable(new)
		and (Rooms.passable(old) or Blocks.insulation(old) == Blocks.insulation(new))
		and roomSource(old) == nil
		and roomSource(new) == nil
	if same then
		return
	end
	local failure = world.failed[key]
	if failure then
		-- (What was found open may be closed now: look again.)
		failure.expires = 0
		world.failed[key] = nil
	end
	local record = world.roomOf[key]
	if record then
		markDirty(world, record)
	end
	eachWalled(world, key, function(walled: Record)
		markDirty(world, walled)
	end)
end

--[[ Answers ]]

-- The room of the cell at the player's feet (x, y, z), seeding it (see the header).
function RoomWorld.sampleIn(world: RoomWorld, x: number, y: number, z: number): Sample?
	local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
	local key = posKey(fx, fy, fz)
	local record = world.roomOf[key]
	if record == nil then
		local block = world.env.getBlock(fx, fy, fz)
		if block ~= nil and not Rooms.passable(block) then
			-- (Feet in a wall's cell: the head's.)
			fy += 1
			key += 1
			record = world.roomOf[key]
		end
	end
	if record then
		record.visited = world.time
		return record.sample
	end
	enqueue(world, fx, fy, fz, true)
	return nil
end

-- The room next to a machine at (x, y, z) and the outdoor value there (see the header).
function RoomWorld.climateIn(world: RoomWorld, x: number, y: number, z: number): (Sample?, number)
	local record = roomAround(world, x, y, z)
	local key = posKey(x, y, z)
	if world.machines[key] == nil then
		world.machines[key] = { x, y, z }
	end
	if record then
		record.visited = world.time
		local sample = record.sample
		sample.heat = heatOf(world, record)
		return sample, sample.outside
	end
	local cached = world.outdoor[key]
	if cached == nil or world.time - cached[2] >= settings.SeedSeconds then
		local surface, biome = world.env.column(x, z)
		local value = outsideAt(world, x, y, z, surface, biome)
		if cached then
			cached[1], cached[2] = value, world.time
		else
			world.outdoor[key] = { value, world.time }
		end
		return nil, value
	end
	return nil, cached[1]
end

-- The air of the room holding cell (x, y, z), or the warmest walled by it (nil: none).
function RoomWorld.temperatureIn(world: RoomWorld, x: number, y: number, z: number): number?
	-- (Table lookups only, nothing made: Seasons/SnowWorld asks for up to 32 cells a visit.)
	local key = posKey(x, y, z)
	local record = world.roomOf[key]
	if record then
		return record.sample.temperature
	end
	local held = world.wallsOf[key]
	if held == nil then
		return nil
	elseif (held :: any).room ~= nil then
		return (held :: Record).sample.temperature
	end
	local warmest = -math.huge
	for walled in held :: { [Record]: true } do
		local t = walled.sample.temperature
		if t > warmest then
			warmest = t
		end
	end
	return if warmest > -math.huge then warmest else nil
end

-- Is a player's feet within `radius` blocks of cell (x, y, z)'s centre (at the last step)?
function RoomWorld.nearIn(world: RoomWorld, x: number, y: number, z: number, radius: number): boolean
	local feet = world.feet
	local limit = radius * radius
	local cx, cy, cz = x + 0.5, y + 0.5, z + 0.5
	for i = 1, #feet, 3 do
		local dx, dy, dz = feet[i] - cx, feet[i + 1] + 0.9 - cy, feet[i + 2] - cz
		if dx * dx + dy * dy + dz * dz <= limit then
			return true
		end
	end
	return false
end

-- The room with id `id` (tests, F3), nil when it is gone.
function RoomWorld.room(world: RoomWorld, id: number): Rooms.Room?
	local record = world.rooms[id]
	return if record then record.room else nil
end

--[[ The game's ]]

local current: RoomWorld? = nil
local started = false

-- The game's rooms (nil before `start`, and with the rooms off).
function RoomWorld.world(): RoomWorld?
	return current
end

-- Starts following rooms in `world` (World/WorldServer).
function RoomWorld.start(world: any)
	assert(not started, "RoomWorld.start was already called")
	started = true
	if not (Config.Seasons.Enabled and settings.Enabled) then
		return
	end
	-- (Roblox glue, required here so the tests load this module without it.)
	local ChunkLayout = require(Shared.World.ChunkLayout)
	local PlayerPositions = require(script.Parent.Parent.Players.PlayerPositions) :: any
	local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay) :: any
	local SIZE = ChunkLayout.SIZE
	local get = ChunkLayout.get
	local passable = Rooms.passable
	current = RoomWorld.new({
		getBlock = function(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end,
		skyAbove = function(x: number, z: number): number
			local cx, cz = x // SIZE, z // SIZE
			local chunk = world:peekChunk(cx, cz)
			if chunk == nil then
				return math.huge
			end
			local data = chunk.data
			local lx, lz = x - cx * SIZE, z - cz * SIZE
			for y = chunk.height - 1, 0, -1 do
				if not passable(get(data, lx, y, lz)) then
					return y + 1
				end
			end
			return 0
		end,
		column = function(x: number, z: number): (number, number)
			local height, biome = world.generator.column(x, z)
			return height, biome
		end,
		dayTime = TimeOfDay.get,
		players = function(each: (x: number, y: number, z: number) -> ())
			for _, x, y, z in PlayerPositions.each() do
				each(x, y, z)
			end
		end,
		clock = os.clock,
		seed = (world.generator :: any).seed or 0,
	})
end

-- WorldServer.onChanged: block (x, y, z) went from `old` to `new` (a room there or walled by it
-- is filled again).
function RoomWorld.blockChanged(x: number, y: number, z: number, old: number, new: number)
	local world = current
	if world then
		RoomWorld.changed(world, x, y, z, old, new)
	end
end

-- A frame's work after the machines (World boot: after Machines.update): fills within the budget,
-- the air at 1 Hz.
function RoomWorld.step(dt: number)
	local world = current
	if world then
		RoomWorld.stepWorld(world, dt)
	end
end

-- The room of the cell at the player's feet (x, y, z) (seeding it), nil when none.
function RoomWorld.sample(x: number, y: number, z: number): Sample?
	local world = current
	return if world then RoomWorld.sampleIn(world, x, y, z) else nil
end

--[[
	The room next to a machine at (x, y, z) (the cell itself or a neighbour's; nil outdoors) and the
	outdoor value there (Temperature's scale, the sheltered value a room loses to).
]]
function RoomWorld.climateAt(x: number, y: number, z: number): (Sample?, number)
	local world = current
	if world == nil then
		return nil, 0
	end
	return RoomWorld.climateIn(world, x, y, z)
end

--[[
	The air temperature of the room holding cell (x, y, z), or of the warmest room it is a wall
	(roof, floor) or opening of (nil: none): snow melts in and on a warm room (Seasons/SnowWorld,
	for a snow cell and the block under it, many times a tick). A cache lookup: no fill, nothing
	made.
]]
function RoomWorld.temperatureAt(x: number, y: number, z: number): number?
	local world = current
	return if world then RoomWorld.temperatureIn(world, x, y, z) else nil
end

-- Is a player within `radius` blocks of cell (x, y, z) (a space heater's standby)?
function RoomWorld.playerNear(x: number, y: number, z: number, radius: number): boolean
	local world = current
	return world ~= nil and RoomWorld.nearIn(world, x, y, z, radius)
end

return RoomWorld

--!strict
--[[
	Snow on the server (Shared/Seasons/SnowLayers' tile rules, Shared/Seasons/SeasonClimate's caps
	and melting; Config.Seasons.Snow), and the seasons' other world effects: snow layers pile up
	where it snows and melt where it is warm, still water freezes from its edges in the cold and
	thaws when it warms, plants grow by the season and snowfall muffles what zombies hear.

	  Visits     every tick (`tick`, with Simulation.activeChunks: the chunks around players) each
	             active chunk is visited with chance TileChance, at most MaxTilesPerTick a tick
	             (from a random chunk of the list, so no player's area is favoured): one of its
	             sixteen 4 x 4 tiles (SnowLayers.TILE). So each column is looked at about every
	             200 s, Minecraft's pace of snowfall (a chunk's column a tick, 1 in 16).
	  Columns    a tile's columns are read once a visit: the top cell (World/WeatherRules.top: the
	             first cell above the highest block that stops rain, so only columns open to the
	             sky take snow, on roofs, leaves and glass too), the blocks at and below it, and
	             the cap (SeasonClimate.snowCap of the biome class at the tile's centre, its
	             altitude and drift). A column whose top is 0 (nothing in it: the void) takes none.
	  Weather    at the tile's centre (the biome cached per tile): precipitation over it
	             (World/WeatherServer.sample) and Minecraft's temperature there (Shared/Weather
	             .temperatureAt of its biome, with the season's shift, Weather.seasonShift): snow
	             falls where it is below Weather.SNOW_BELOW in a biome with precipitation.
	  Snowfall   while it snows, a visit piles snow with chance = the precipitation (heavier snow,
	             faster): SnowLayers.accumulate, so a tile rises evenly to its caps. Plants,
	             torches and water in a top cell take no snow (plants are never lost to it).
	  Thaw       while it does not snow and SeasonClimate.melts there, a visit melts with chance
	             MeltChance (0.5) x MeltClear (2) by a clear day, x MeltRain (2) in rain and x
	             MeltNight (0.5) at night (the sun's night, DayCycle.isDay): SnowLayers.melt, one
	             layer off the tile's deepest columns, so roofs drain gradually.
	  Warm       a column whose snow (or the cell a first layer would go into) has a heat source
	             next to it that heats now (Players/Climate.isHeating and its check: lava, fire, a
	             campfire, a lit furnace, a working generator or heater), or is in or on a room at
	             RoomMelt or warmer (Seasons/RoomWorld.temperatureAt of the cell or the block under
	             it: a heated house's roof), takes no snow and loses a layer at every visit,
	             whatever the weather.
	  Ice        (Config.Seasons.Snow.Ice) where the temperature at the tile is below SNOW_BELOW, a
	             water source in a column's top block with air above it and a side that is no
	             water (Minecraft's mustBeAtEdge) turns to Ice: lakes freeze inwards about a column
	             a visit. Ice the weather made (the natural map says Water was there) thaws back to
	             Water with the snow's thaw roll; generated ice (frozen biomes) never does.
	  Writes     snow and ice made or melted by the weather go through WorldServer.setWeather (the
	             world's natural map: a cell melting back to what the seed made loses its edit
	             instead of keeping one, so a winter leaves no edits behind; a layer melting where
	             the seed made cave air, a cave mouth open to the sky, goes back to cave air), at
	             most MAX_WRITES (16: a change a column) a visit, sent with the frame's edits (the
	             boot's net.flush).
	  Heat       every HeatMeltSeconds (`step`) each heat source in an active chunk that heats now
	             melts a layer of every snow cell within HeatMeltRadius sideways and up or down
	             (5 x 5 x 5 cells). The sources are indexed by chunk (`blockChanged`: a heating
	             block placed or gone; a chunk's saved edits are looked through once, the first time
	             it is active, at most SCANS_PER_TICK chunks a tick); the round is spread over the
	             frames, at most SOURCES_PER_FRAME sources or HEAT_WRITES writes a frame, and at
	             most MAX_SOURCES a round (a round not done when the next is due goes on instead).
	             Lava and fire the seed made melt snow next to them when their tile is visited
	             (Warm).
	  Growth     `growth()`: the season's plant growth factor (SeasonClimate's sample: Autumn 0.5,
	             Winter 0, Spring 1.5, Summer 1, blended) at the server's day time, which
	             Behaviours/Sapling, Herb and Grass multiply their random-tick chances by; 1 with
	             the calendar off.
	  Zombies    the boot's `start` gives Mobs/ZombieDirector where snow falls (World/WeatherServer
	             .snowingAt while the calendar is on): a noise in falling snow is heard over
	             Apocalypse.Noise.SnowFactor of its radius.
	With the calendar off (Shared/Seasons/SeasonClimate.active false: Config.Seasons.Enabled false,
	the debug worlds) or Config.Seasons.Snow.Enabled false nothing is visited, piled, melted or
	frozen.

	The rules are an instance over an environment (`new(env)`: the world and the weather, the
	day, heat and rooms as functions), so the specs run them on a world of their own
	(tests/spec/SnowWorld); `start` makes the server's, and `blockChanged`, `tick` and `step`
	drive it (the boot's onChanged chain, tick loop and frame after the machines).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Biomes = require(Shared.Biomes)
local Blocks = require(Shared.Blocks)
local Calendar = require(Shared.Seasons.Calendar)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local DayCycle = require(Shared.DayCycle)
local Fluids = require(Shared.Fluids)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)
local SnowLayers = require(Shared.Seasons.SnowLayers)
local Weather = require(Shared.Weather)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local WeatherRules = require(script.Parent.Parent.World.WeatherRules)
local Climate = require(script.Parent.Parent.Players.Climate)

local SIZE = ChunkLayout.SIZE
local TILE = SnowLayers.TILE
local TILES = SIZE // TILE
local HEIGHT = Config.WorldHeight
local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local ICE = Blocks.id.Ice
local WATER = Blocks.fluidId("Water", 0)
local WATER_FLUID = Fluids.WATER

export type World = WorldServer.World
export type Chunk = WorldServer.Chunk

--[[
	What the rules read and write (see the header): the world, a random roll in [0, 1), the
	precipitation over a column (0..1), the weather's moment (its season's shift: nil, none), the
	sun's night, whether a heat source heats now, the air temperature of the room holding or
	walled by a cell (nil: none), and whether the snow runs at all now.
]]
export type Env = {
	world: World,
	random: () -> number,
	precipitation: (x: number, z: number) -> number,
	moment: () -> Weather.Moment?,
	night: () -> boolean,
	heating: (x: number, y: number, z: number, block: number) -> boolean,
	room: (x: number, y: number, z: number) -> number?,
	active: () -> boolean,
}

-- The snow of one world (`new`).
export type Snow = {
	env: Env,
	-- Heat sources by chunk key: pos key -> block (see Heat), and the chunks whose saved edits
	-- were looked through.
	heat: { [number]: { [number]: number } },
	scanned: { [number]: true },
	-- The chunks of the last tick (Simulation.activeChunks).
	chunks: { Chunk },
	-- Biome index at each tile's centre (tile key), and how many are kept.
	biomes: { [number]: number },
	biomeCount: number,
	-- Seconds to the next heat melt round, and its sources still to do (pos keys, blocks).
	heatTimer: number,
	queue: { number },
	queueBlocks: { number },
	-- A visit's columns (reused) and changes.
	columns: { SnowLayers.Column },
	-- Counts (specs, measurements): tile visits, weather writes, heat sources melted around.
	visits: number,
	writes: number,
	melted: number,
}

local SnowWorld = {}

-- The most writes of one visit (a change a column).
SnowWorld.MAX_WRITES = TILE * TILE
-- Chunks whose saved edits are looked through for heat sources, at most, a tick.
SnowWorld.SCANS_PER_TICK = 4
-- A heat melt round: at most this many sources, spread over frames of at most SOURCES_PER_FRAME
-- sources (or HEAT_WRITES writes; a source started is finished).
SnowWorld.MAX_SOURCES = 256
SnowWorld.SOURCES_PER_FRAME = 32
SnowWorld.HEAT_WRITES = 64
-- Tile biomes kept before the cache starts over.
SnowWorld.MAX_BIOMES = 16384

local floor = math.floor

local NEIGHBOURS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }
local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- The block at (x, y, z) without generating anything (nil: not loaded).
local function peek(world: World, x: number, y: number, z: number): number?
	return world:peekBlock(x, y, z)
end

--[[
	A weather write of `block` at (x, y, z) (WorldServer.setWeather): air goes back to the seed's
	own, cave air where the seed made that (see the header's Writes). Returns whether it changed.
]]
local function write(world: World, x: number, y: number, z: number, block: number): boolean
	if block == AIR and WorldServer.naturalAt(world, x, y, z) == CAVE_AIR then
		block = CAVE_AIR
	end
	return world:setWeather(x, y, z, block)
end

--[[
	Does the heat source `block` at (x, y, z) heat now? Players/Climate's: a block it counts as
	heating (Config.ToughAsNails.HeatingBlocks, and what Players/ToughAsNails registers) whose
	check, if it has one, says so (a lit furnace, a working generator or heater).
]]
local probeBlock = AIR
local probe = {
	getBlock = function(_x: number, _y: number, _z: number): number?
		return probeBlock
	end,
}
function SnowWorld.heatingNow(x: number, y: number, z: number, block: number): boolean
	if not Climate.isHeating(block) then
		return false
	end
	probeBlock = block
	-- (Its own cell alone: the check runs for it, and only it.)
	local heat = Climate.sources(probe :: any, x, y, z, 0)
	return heat ~= nil
end

function SnowWorld.new(env: Env): Snow
	local columns: { SnowLayers.Column } = {}
	for i = 1, TILE * TILE do
		columns[i] = { x = 0, z = 0, top = nil, atTop = AIR, below = AIR, cap = 0 }
	end
	return {
		env = env,
		heat = {},
		scanned = {},
		chunks = {},
		biomes = {},
		biomeCount = 0,
		heatTimer = Config.Seasons.Snow.HeatMeltSeconds,
		queue = {},
		queueBlocks = {},
		columns = columns,
		visits = 0,
		writes = 0,
		melted = 0,
	}
end

--[[ Heat sources ]]

local function addSource(snow: Snow, x: number, y: number, z: number, block: number)
	local key = Coords.chunkKey(x // SIZE, z // SIZE)
	local list = snow.heat[key]
	if list == nil then
		list = {}
		snow.heat[key] = list
	end
	list[Coords.posKey(x, y, z)] = block
end

local function removeSource(snow: Snow, x: number, y: number, z: number)
	local key = Coords.chunkKey(x // SIZE, z // SIZE)
	local list = snow.heat[key]
	if list then
		list[Coords.posKey(x, y, z)] = nil
		if next(list) == nil then
			snow.heat[key] = nil
		end
	end
end

-- Block (x, y, z) went from `old` to `new` (WorldServer.onChanged): heat sources come and go.
function SnowWorld.changed(snow: Snow, x: number, y: number, z: number, old: number, new: number)
	if Climate.isHeating(new) then
		addSource(snow, x, y, z, new)
	elseif Climate.isHeating(old) then
		removeSource(snow, x, y, z)
	end
end

-- Looks through chunk (cx, cz)'s saved edits for heat sources (once a chunk).
local function scan(snow: Snow, cx: number, cz: number)
	local key = Coords.chunkKey(cx, cz)
	snow.scanned[key] = true
	local edits = snow.env.world:chunkEdits(cx, cz)
	if edits == nil then
		return
	end
	for index, block in edits do
		if Climate.isHeating(block) then
			local lx, y, lz = ChunkLayout.fromLocalIndex(index)
			addSource(snow, cx * SIZE + lx, y, cz * SIZE + lz, block)
		end
	end
end

-- The heat sources indexed in chunk (cx, cz) (pos key -> block), nil when none.
function SnowWorld.sources(snow: Snow, cx: number, cz: number): { [number]: number }?
	return snow.heat[Coords.chunkKey(cx, cz)]
end

--[[ Visits ]]

-- The biome at (x, z), the tile's centre (the generator's, cached per tile).
local function biomeOf(snow: Snow, x: number, z: number): number
	local key = Coords.chunkKey(x // TILE, z // TILE)
	local biome = snow.biomes[key]
	if biome == nil then
		local _, index = snow.env.world.generator.column(x, z)
		biome = index
		if snow.biomeCount >= SnowWorld.MAX_BIOMES then
			table.clear(snow.biomes)
			snow.biomeCount = 0
		end
		snow.biomes[key] = index
		snow.biomeCount += 1
	end
	return biome :: number
end

-- Is the cell (x, y, z) warm (see the header): a heat source next to it that heats now, or a
-- room at RoomMelt or warmer holding or walled by it or the block under it?
local function warm(env: Env, x: number, y: number, z: number): boolean
	local world = env.world
	local heating = env.heating
	for _, offset in NEIGHBOURS do
		local nx, ny, nz = x + offset[1], y + offset[2], z + offset[3]
		local block = peek(world, nx, ny, nz)
		if block ~= nil and block ~= AIR and heating(nx, ny, nz, block) then
			return true
		end
	end
	local hot = Config.Seasons.Snow.RoomMelt
	local room = env.room
	local here = room(x, y, z)
	if here ~= nil and here >= hot then
		return true
	end
	local under = room(x, y - 1, z)
	return under ~= nil and under >= hot
end

-- Does water at (x, y, z) have a side that is no water (Minecraft's mustBeAtEdge; a side not
-- loaded counts as water)?
local function atEdge(world: World, x: number, y: number, z: number): boolean
	for _, side in SIDES do
		local block = peek(world, x + side[1], y, z + side[2])
		if block ~= nil and Fluids.ofBlock(block) ~= WATER_FLUID then
			return true
		end
	end
	return false
end

-- The melt chance of a visit (see the header's Thaw).
function SnowWorld.meltChance(raining: boolean, precipitating: boolean, night: boolean): number
	local snow = Config.Seasons.Snow
	local chance = snow.MeltChance
	if raining then
		chance *= snow.MeltRain
	elseif not precipitating and not night then
		chance *= snow.MeltClear
	end
	if night then
		chance *= snow.MeltNight
	end
	return math.min(chance, 1)
end

--[[
	One visit of tile (tx, tz) (0..3 each) of `chunk` (see the header): reads its columns and the
	weather at its centre, and writes the snow and ice that change. Returns the writes made.
]]
function SnowWorld.visit(snow: Snow, chunk: Chunk, tx: number, tz: number): number
	local env = snow.env
	local world = env.world
	snow.visits += 1
	local x0, z0 = chunk.cx * SIZE + tx * TILE, chunk.cz * SIZE + tz * TILE
	local xc, zc = x0 + TILE // 2, z0 + TILE // 2
	local biome = biomeOf(snow, xc, zc)
	local def = Biomes.get(biome)
	local class: SeasonClimate.Class = SeasonClimate.classOf(biome)
	local seed = world.generator.seed
	-- The weather at the centre (its top cell's height: the snow line).
	local centreTop = WeatherRules.top(world, xc, zc) or 0
	local base = if def then def.weatherTemperature else 0.8
	local temperature = Weather.temperatureAt(base, xc, centreTop, zc) + Weather.seasonShift(env.moment(), biome)
	local precipitation = env.precipitation(xc, zc)
	local precipitating = def ~= nil and def.precipitation and precipitation > Weather.RAINING
	local snowing = precipitating and temperature < Weather.SNOW_BELOW
	local raining = precipitating and not snowing
	local piling = snowing and env.random() < precipitation
	local thawing = not snowing
		and SeasonClimate.melts(temperature)
		and env.random() < SnowWorld.meltChance(raining, precipitating, env.night())
	-- The columns (their caps only when snow piles).
	local columns = snow.columns
	for i, column in columns do
		local x, z = x0 + (i - 1) % TILE, z0 + (i - 1) // TILE
		column.x, column.z = x, z
		local top = if x == xc and z == zc then centreTop else WeatherRules.top(world, x, z)
		if top == nil or top <= 0 or top >= HEIGHT then
			column.top = nil
			column.atTop, column.below, column.cap = AIR, AIR, 0
		else
			column.top = top
			column.atTop = peek(world, x, top, z) or AIR
			column.below = peek(world, x, top - 1, z) or AIR
			column.cap = if piling then SeasonClimate.snowCap(class, x, top, z, seed) else 0
		end
	end

	-- What changes: a change a column at most (warm columns first, then the tile's rule, then ice).
	local changes: { SnowLayers.Change } = {}
	local changed: { [number]: boolean } = {}
	for i, column in columns do
		if column.top ~= nil then
			local n, y, takes = SnowLayers.column(column)
			if (n > 0 or (piling and takes)) and warm(env, column.x, y, column.z) then
				-- (No snow forms or grows on it.)
				column.cap = 0
				local change = SnowLayers.meltColumn(column)
				if change then
					table.insert(changes, change)
					changed[i] = true
				end
			end
		end
	end
	local rule: { SnowLayers.Change }? = nil
	if piling then
		rule = SnowLayers.accumulate(columns)
	elseif thawing then
		rule = SnowLayers.melt(columns)
	end
	if rule then
		for _, change in rule do
			local i = (change.z - z0) * TILE + (change.x - x0) + 1
			if not changed[i] then
				table.insert(changes, change)
				changed[i] = true
			end
		end
	end
	if Config.Seasons.Snow.Ice then
		local freezing = temperature < Weather.SNOW_BELOW
		for i, column in columns do
			local top = column.top
			if top ~= nil and not changed[i] then
				local x, z = column.x, column.z
				if column.below == WATER then
					if freezing and column.atTop == AIR and atEdge(world, x, top - 1, z) then
						table.insert(changes, { x = x, y = top - 1, z = z, block = ICE })
						changed[i] = true
					end
				elseif column.below == ICE and thawing and WorldServer.naturalAt(world, x, top - 1, z) == WATER then
					table.insert(changes, { x = x, y = top - 1, z = z, block = WATER })
					changed[i] = true
				end
			end
		end
	end

	local writes = 0
	for _, change in changes do
		if writes >= SnowWorld.MAX_WRITES then
			break
		end
		if write(world, change.x, change.y, change.z, change.block) then
			writes += 1
		end
	end
	snow.writes += writes
	return writes
end

--[[
	One server tick over the active `chunks` (see the header's Visits): new chunks' saved edits
	looked through for heat sources, then the tile visits. Returns the writes made.
]]
function SnowWorld.tickWith(snow: Snow, chunks: { Chunk }): number
	snow.chunks = chunks
	local scans = SnowWorld.SCANS_PER_TICK
	for _, chunk in chunks do
		if scans <= 0 then
			break
		end
		if not snow.scanned[Coords.chunkKey(chunk.cx, chunk.cz)] then
			scan(snow, chunk.cx, chunk.cz)
			scans -= 1
		end
	end
	local env = snow.env
	local count = #chunks
	if count == 0 or not env.active() then
		return 0
	end
	local settings = Config.Seasons.Snow
	local chance, budget = settings.TileChance, settings.MaxTilesPerTick
	local random = env.random
	local start = floor(random() * count)
	local visits, writes = 0, 0
	for i = 0, count - 1 do
		if visits >= budget then
			break
		end
		if random() < chance then
			local tile = floor(random() * TILES * TILES)
			writes += SnowWorld.visit(snow, chunks[(start + i) % count + 1], tile % TILES, tile // TILES)
			visits += 1
		end
	end
	return writes
end

--[[ The heat melt ]]

-- One layer off every snow cell within HeatMeltRadius of (x, y, z). Returns the writes made.
local function meltAround(snow: Snow, x: number, y: number, z: number): number
	local world = snow.env.world
	local radius = Config.Seasons.Snow.HeatMeltRadius
	local writes = 0
	for dy = radius, -radius, -1 do
		for dz = -radius, radius do
			for dx = -radius, radius do
				local block = peek(world, x + dx, y + dy, z + dz)
				local less = if block ~= nil then SnowLayers.lessOne(block) else nil
				if less ~= nil and write(world, x + dx, y + dy, z + dz, less) then
					writes += 1
				end
			end
		end
	end
	return writes
end

-- Queues this round's sources: those indexed in the active chunks, at most MAX_SOURCES.
local function queueRound(snow: Snow)
	local queue, blocks = snow.queue, snow.queueBlocks
	table.clear(queue)
	table.clear(blocks)
	for _, chunk in snow.chunks do
		local list = snow.heat[Coords.chunkKey(chunk.cx, chunk.cz)]
		if list then
			for key, block in list do
				if #queue >= SnowWorld.MAX_SOURCES then
					return
				end
				table.insert(queue, key)
				table.insert(blocks, block)
			end
		end
	end
end

--[[
	A frame's share of the heat melt round in progress (see the header's Heat): sources taken off
	the queue until SOURCES_PER_FRAME of them or HEAT_WRITES writes. Returns the writes made.
]]
function SnowWorld.heatMelt(snow: Snow): number
	local env = snow.env
	local world = env.world
	local queue, blocks = snow.queue, snow.queueBlocks
	local done, writes = 0, 0
	while #queue > 0 and done < SnowWorld.SOURCES_PER_FRAME and writes < SnowWorld.HEAT_WRITES do
		local key = table.remove(queue) :: number
		local block = table.remove(blocks) :: number
		done += 1
		local x, y, z = Coords.decodePosKey(key)
		local here = peek(world, x, y, z)
		if here ~= nil and here ~= block then
			-- (Changed since it was queued: `changed` keeps the index; no source there now, none
			-- in it.)
			if not Climate.isHeating(here) then
				removeSource(snow, x, y, z)
			end
		elseif here ~= nil and env.heating(x, y, z, block) then
			snow.melted += 1
			writes += meltAround(snow, x, y, z)
		end
	end
	snow.writes += writes
	return writes
end

--[[
	A frame's work (`dt` seconds): a heat melt round every HeatMeltSeconds while the snow runs,
	its share each frame. Returns the writes made.
]]
function SnowWorld.advance(snow: Snow, dt: number): number
	snow.heatTimer -= dt
	if snow.heatTimer <= 0 then
		snow.heatTimer += math.max(Config.Seasons.Snow.HeatMeltSeconds, 0.05)
		if snow.heatTimer <= 0 then
			snow.heatTimer = Config.Seasons.Snow.HeatMeltSeconds
		end
		if not snow.env.active() then
			table.clear(snow.queue)
			table.clear(snow.queueBlocks)
		elseif #snow.queue == 0 then
			-- (A round still going on when the next is due goes on instead: none starves.)
			queueRound(snow)
		end
	end
	if #snow.queue == 0 then
		return 0
	end
	return SnowWorld.heatMelt(snow)
end

--[[ Growth ]]

-- The day time growth goes by (World/TimeOfDay.get once started).
local clock: () -> number = function(): number
	return 0
end
-- The last growth worked out: its calendar, day time and value.
local growthSample: SeasonClimate.Sample? = nil
local growthState: Calendar.State? = nil
local growthOffset, growthLock, growthTime = 0, nil :: number?, -math.huge
-- Ticks of day time one growth value serves.
local GROWTH_TICKS = 20

--[[
	The season's plant growth factor now (see the header's Growth): 1 with the calendar off, else
	SeasonClimate.sample's `growth` at the day time (`setClock`'s), worked out at most once every
	GROWTH_TICKS ticks of it.
]]
function SnowWorld.growth(): number
	local state = Calendar.state()
	if not state.enabled then
		return 1
	end
	local dayTime = clock()
	local sample = growthSample
	if
		sample == nil
		or growthState ~= state
		or growthOffset ~= state.offset
		or growthLock ~= state.lock
		or math.abs(dayTime - growthTime) >= GROWTH_TICKS
	then
		sample = SeasonClimate.sample(dayTime, "temperate", 0, state, sample)
		growthSample = sample
		growthState, growthOffset, growthLock, growthTime = state, state.offset, state.lock, dayTime
	end
	return (sample :: SeasonClimate.Sample).growth
end

-- Sets the day time `growth` goes by (`start` sets World/TimeOfDay.get; nil: 0).
function SnowWorld.setClock(get: (() -> number)?)
	clock = get or function(): number
		return 0
	end
	growthSample = nil
end

--[[ The server's snow ]]

local started: Snow? = nil

--[[
	Starts the snow in `world` (World/WorldServer) with the server's weather, day, heat and rooms
	(see the header), and gives Mobs/ZombieDirector where snow falls.
]]
function SnowWorld.start(world: World)
	assert(started == nil, "SnowWorld.start was already called")
	-- (Required here, not above: they are Roblox glue, and the rules above run in the specs.)
	local WeatherServer = require(script.Parent.Parent.World.WeatherServer)
	local TimeOfDay = require(script.Parent.Parent.World.TimeOfDay)
	local RoomWorld = require(script.Parent.RoomWorld)
	local ZombieDirector = require(script.Parent.Parent.Mobs.ZombieDirector)
	local rng = Random.new()
	local snow = Config.Seasons.Snow
	started = SnowWorld.new({
		world = world,
		random = function(): number
			return rng:NextNumber()
		end,
		precipitation = function(x: number, z: number): number
			return (WeatherServer.sample(x, z))
		end,
		moment = WeatherServer.moment,
		night = function(): boolean
			return not DayCycle.isDay(TimeOfDay.get())
		end,
		heating = SnowWorld.heatingNow,
		room = RoomWorld.temperatureAt,
		active = function(): boolean
			return snow.Enabled and SeasonClimate.active()
		end,
	})
	SnowWorld.setClock(TimeOfDay.get)
	ZombieDirector.setSnowing(function(x: number, y: number, z: number): boolean
		return SeasonClimate.active() and WeatherServer.snowingAt(x, y, z)
	end)
end

-- WorldServer.onChanged: block (x, y, z) went from `old` to `new` (heat sources come and go).
function SnowWorld.blockChanged(x: number, y: number, z: number, old: number, new: number)
	local snow = started
	if snow then
		SnowWorld.changed(snow, x, y, z, old, new)
	end
end

-- One server tick's tile visits over the active `chunks` (Simulation.activeChunks).
function SnowWorld.tick(chunks: { any })
	local snow = started
	if snow then
		SnowWorld.tickWith(snow, chunks)
	end
end

-- A frame's work after the machines (the heat melt every HeatMeltSeconds).
function SnowWorld.step(dt: number)
	local snow = started
	if snow then
		SnowWorld.advance(snow, dt)
	end
end

-- The server's snow (nil before `start`): its counts and heat sources, for measuring.
function SnowWorld.current(): Snow?
	return started
end

return SnowWorld

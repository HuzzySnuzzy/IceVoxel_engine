--[[
	Snow on the server (server Seasons/SnowWorld) over a world of its own: a flat WorldServer whose
	seed makes plains (x < 64), taiga (to 128) and desert, a pond and a sheet of generated ice,
	with the weather, the day, heat and rooms given as functions.

	Snowfall piling a tile evenly to each column's cap and stopping there, only under the open sky
	(on a roof, not under it; never into a plant or a torch), deeper in cold biomes, none in autumn
	plains, in a desert or with the snow off; the thaw taking a layer a visit off the deepest
	columns, back to the seed's air with no edit left (the natural map), at the weather's pace, and
	never while winter holds; warm columns (fire beside them, a heated room's roof) shedding their
	snow at every visit and taking none; the heat melt round every HeatMeltSeconds within
	HeatMeltRadius, its sources indexed from changes and saved edits; still water freezing from its
	edges and the weather's ice thawing back while generated ice stays; the tick's pace and budget;
	the SnowLayer behaviour (a layer whose support goes vanishes, no drops); placing (stacking,
	support, drops); the season's growth factor; and what it costs (ms a visit, a tick, a heat
	melt round; a winter's region bytes).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local Calendar = require(shared.Seasons.Calendar)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Items = require(shared.Items)
	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local SnowLayers = require(shared.Seasons.SnowLayers)
	local WorldServer = require(server.World.WorldServer)
	local WeatherRules = require(server.World.WeatherRules)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Drops = require(server.Behaviours.Drops)
	local EditRules = require(server.Network.EditRules)
	local RegionCodec = require(server.Save.RegionCodec)
	local SnowWorld = require(server.Seasons.SnowWorld)

	local B = Blocks.id
	local AIR, STONE, GRASS, ICE, PLANKS = Blocks.AIR, B.Stone, B.Grass, B.Ice, B.Planks
	local WATER = Blocks.fluidId("Water", 0)
	local CAMPFIRE = B.Campfire
	local SIZE = ChunkLayout.SIZE
	-- The first air cell over the grass, the terrain's crop, the seed.
	local FLOOR = 10
	local CROP = 32
	local SEED = 4242
	local PLAINS = (Biomes.byName("Plains") :: any).index
	local TAIGA = (Biomes.byName("Taiga") :: any).index
	local DESERT = (Biomes.byName("Desert") :: any).index
	-- Seasons' weather shifts (Config.Seasons.Climate.WeatherShift): winter's makes plains snow.
	local WINTER, AUTUMN, SUMMER = -0.8, -0.2, 0.2

	local function layer(n: number): number
		return SnowLayers.block(n) :: number
	end

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	--[[ The seed's world ]]

	local function biomeAt(x: number): number
		return if x < 64 then PLAINS elseif x < 128 then TAIGA else DESERT
	end
	-- The block at FLOOR - 1: a pond (x 4..7, z 4..7: tile (1, 1) of chunk (0, 0)), generated ice
	-- (x 8..11, z 4..7: a frozen biome's), grass elsewhere.
	local function surfaceAt(x: number, z: number): number
		if z >= 4 and z <= 7 then
			if x >= 4 and x <= 7 then
				return WATER
			elseif x >= 8 and x <= 11 then
				return ICE
			end
		end
		return GRASS
	end
	local generator = {
		seed = SEED,
		generate = function(level: number, cx: number, cz: number)
			local data = ChunkLayout.create(CROP)
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					for y = 0, FLOOR - 2 do
						ChunkLayout.set(data, lx, y, lz, STONE)
					end
					ChunkLayout.set(data, lx, FLOOR - 1, lz, surfaceAt(cx * SIZE + lx, cz * SIZE + lz))
					-- (A cave mouth open to the sky: the seed's cave air over x 44..47, z 12..15.)
					local x, z = cx * SIZE + lx, cz * SIZE + lz
					if x >= 44 and x <= 47 and z >= 12 and z <= 15 then
						ChunkLayout.set(data, lx, FLOOR, lz, Blocks.CAVE_AIR)
						ChunkLayout.set(data, lx, FLOOR + 1, lz, Blocks.CAVE_AIR)
					end
				end
			end
			return {
				data = data,
				level = level,
				nx = cx,
				nz = cz,
				height = CROP,
				solidBelow = FLOOR - 1,
				emptyAbove = FLOOR,
			}
		end,
		column = function(x: number, _z: number)
			return FLOOR, biomeAt(x), 0, GRASS
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	--[[
		A world with its snow: `h.precipitation`, `h.weatherShift`, `h.night`, `h.active` and
		`h.rooms` (pos key -> room temperature) are what the snow's environment says; `h.roll`, when
		set, replaces the random rolls. Block updates run (`h.settle()`), drops land in `h.drops`.
	]]
	local function newSnow(): any
		local h: any = {
			precipitation = 1,
			weatherShift = WINTER,
			night = false,
			active = true,
			rooms = {},
			roll = nil,
			drops = {},
		}
		local world = WorldServer.new(generator :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		local rng = lcg(17)
		local snow = SnowWorld.new({
			world = world,
			random = function(): number
				return if h.roll then h.roll() else rng()
			end,
			precipitation = function(_x: number, _z: number): number
				return h.precipitation
			end,
			moment = function(): any
				return { weatherShift = h.weatherShift }
			end,
			night = function(): boolean
				return h.night
			end,
			heating = SnowWorld.heatingNow,
			room = function(x: number, y: number, z: number): number?
				return h.rooms[Coords.posKey(x, y, z)]
			end,
			active = function(): boolean
				return h.active
			end,
		})
		world.onChanged = function(x, y, z, old, new)
			ticker:blockChanged(x, y, z)
			SnowWorld.changed(snow, x, y, z, old, new)
		end
		Drops.set(function(x, y, z, stack)
			table.insert(h.drops, { x = x, y = y, z = z, item = stack.item, count = stack.count })
		end)
		function h.settle()
			for _ = 1, 200 do
				ticker:step()
				if ticker:pendingCount() == 0 then
					return
				end
			end
			error("block updates never settled")
		end
		-- One visit of the tile holding (x, z); the writes made.
		function h.visit(x: number, z: number): number
			local chunk = world:getChunk(x // SIZE, z // SIZE)
			return SnowWorld.visit(snow, chunk, (x % SIZE) // 4, (z % SIZE) // 4)
		end
		-- Visits the tile holding (x, z) until a visit writes nothing (at most `most`): the visits.
		function h.until_(x: number, z: number, most: number?): number
			local visits = 0
			repeat
				local writes = h.visit(x, z)
				visits += 1
			until writes == 0 or visits >= (most or 20)
			return visits
		end
		h.world, h.snow, h.ticker = world, snow, ticker
		return h
	end

	-- The snow layers of column (x, z) (from its top cell, as the rules see them).
	local function depth(world: any, x: number, z: number): number
		local top = WeatherRules.top(world, x, z)
		if top == nil or top <= 0 then
			return 0
		end
		return (SnowLayers.layersAt(world:getBlock(x, top, z), world:getBlock(x, top - 1, z)))
	end
	-- Each column's depth over [x0, x0 + 3] x [z0, z0 + 3], as text.
	local function tileDepths(world: any, x0: number, z0: number): string
		local out = {}
		for z = z0, z0 + 3 do
			for x = x0, x0 + 3 do
				table.insert(out, tostring(depth(world, x, z)))
			end
		end
		return table.concat(out, ",")
	end
	local function editCount(world: any): number
		local n = 0
		for _, edits in world.edits do
			for _ in edits do
				n += 1
			end
		end
		return n
	end

	t.test("snow world: the boot's API (start, blockChanged, tick, step) does nothing before start", function()
		for _, name in { "start", "blockChanged", "tick", "step", "growth", "setClock" } do
			t.eq(type((SnowWorld :: any)[name]), "function", name)
		end
		t.eq(SnowWorld.current(), nil, "not started in the specs")
		SnowWorld.blockChanged(0, FLOOR, 0, AIR, CAMPFIRE)
		SnowWorld.tick({})
		SnowWorld.step(10)
		t.eq(SnowWorld.current(), nil)
	end)

	--[[ Snowfall ]]

	t.test("snow world: snowfall piles a tile evenly to each column's cap, then stops", function()
		local h = newSnow()
		local world = h.world
		local visits = h.until_(32, 0)
		local deepest = 0
		for z = 0, 3 do
			for x = 32, 35 do
				local cap = SeasonClimate.snowCap("temperate", x, FLOOR, z, SEED)
				t.eq(depth(world, x, z), cap, `column {x}, {z} at its cap`)
				deepest = math.max(deepest, cap)
				t.ok(cap >= 2 and cap <= 4, "temperate caps 3 +- the drift")
				-- (One or two layers in the top cell, deeper ones in the same cell: the floor's.)
				t.ok(SnowLayers.isLayer(world:getBlock(x, FLOOR, z)), "the layers sit on the grass")
				t.eq(world:getBlock(x, FLOOR - 1, z), GRASS, "which stays grass (snow is no opaque cover)")
				t.eq(WorldServer.naturalAt(world, x, FLOOR, z), AIR, "the seed's air is remembered")
			end
		end
		t.eq(visits, deepest + 1, "a layer a visit, then a visit with nothing to do")
		t.eq(h.visit(32, 0), 0, "nothing more falls on a full tile")
		t.eq(h.snow.visits, visits + 1)
	end)

	t.test("snow world: only under the open sky, on a roof and not under it; plants and torches stay", function()
		local h = newSnow()
		local world = h.world
		-- A roof of planks over tile x 36..39, z 0..3 (an edit), a poppy and a torch on tile 32..35.
		for x = 36, 39 do
			for z = 0, 3 do
				world:setBlock(x, FLOOR + 2, z, PLANKS)
			end
		end
		world:setBlock(33, FLOOR, 1, B.Poppy)
		world:setBlock(34, FLOOR, 2, B.Torch)
		h.until_(32, 0)
		h.until_(36, 0)
		for x = 36, 39 do
			for z = 0, 3 do
				t.eq(world:getBlock(x, FLOOR, z), AIR, "nothing under the roof")
				t.ok(SnowLayers.isLayer(world:getBlock(x, FLOOR + 3, z)), "snow on it")
				t.eq(depth(world, x, z), SeasonClimate.snowCap("temperate", x, FLOOR + 3, z, SEED))
			end
		end
		t.eq(world:getBlock(33, FLOOR, 1), B.Poppy, "the poppy stands")
		t.eq(depth(world, 33, 1), 0, "with no snow in its cell")
		t.eq(world:getBlock(34, FLOOR, 2), B.Torch, "the torch stays")
		t.ok(depth(world, 32, 1) > 0, "the plant held nobody back")
	end)

	t.test("snow world: deeper in cold biomes; none in autumn plains, a desert or with the snow off", function()
		local h = newSnow()
		local world = h.world
		h.until_(64, 0)
		for z = 0, 3 do
			for x = 64, 67 do
				local cap = SeasonClimate.snowCap("cold", x, FLOOR, z, SEED)
				t.ok(cap >= 5 and cap <= 7, "cold caps 6 +- the drift")
				t.eq(depth(world, x, z), cap, "a taiga's column at its cap")
			end
		end
		t.eq(h.until_(128, 0), 1, "a desert: nothing falls")
		t.eq(tileDepths(world, 128, 0), "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0")
		h.weatherShift = AUTUMN
		t.eq(h.visit(32, 0), 0, "autumn plains: rain, no snow")
		h.weatherShift = WINTER
		h.precipitation = 0.1
		t.eq(h.visit(32, 0), 0, "too light to fall (Weather.RAINING)")
		-- Off: no visits at all, but heat sources are still looked for.
		h.precipitation = 1
		h.active = false
		h.roll = function()
			return 0
		end
		local before = h.snow.visits
		t.eq(SnowWorld.tickWith(h.snow, { world:getChunk(2, 0) }), 0)
		t.eq(h.snow.visits, before, "no visit with the snow off")
		t.ok(h.snow.scanned[Coords.chunkKey(2, 0)], "the chunk's edits were looked through")
	end)

	t.test("snow world: the snowfall's chance is the precipitation", function()
		local h = newSnow()
		h.precipitation = 0.5
		local rolls = { 0.6, 0.4 }
		local i = 0
		h.roll = function()
			i += 1
			return rolls[i] or 0.99
		end
		t.eq(h.visit(32, 0), 0, "a roll over the precipitation: nothing")
		t.ok(h.visit(32, 0) > 0, "under it: a layer")
	end)

	--[[ The thaw ]]

	t.test("snow world: the thaw's chance (clear day x2, rain x2, night x0.5)", function()
		t.eq(Config.Seasons.Snow.MeltChance, 0.5)
		t.eq(SnowWorld.meltChance(false, false, false), 1, "a clear day")
		t.eq(SnowWorld.meltChance(false, false, true), 0.25, "a clear night")
		t.eq(SnowWorld.meltChance(true, true, false), 1, "rain by day")
		t.eq(SnowWorld.meltChance(true, true, true), 0.5, "rain at night")
		t.eq(SnowWorld.meltChance(false, true, false), 0.5, "overcast, nothing falling here")
	end)

	t.test("snow world: the thaw takes a layer a visit off the deepest, back to no edits", function()
		local h = newSnow()
		local world = h.world
		h.until_(32, 0)
		local deepest = 0
		for z = 0, 3 do
			for x = 32, 35 do
				deepest = math.max(deepest, depth(world, x, z))
			end
		end
		t.ok(editCount(world) == 16, "a snow edit a column")
		-- Winter holds: nothing melts on a clear day.
		h.precipitation = 0
		t.eq(h.visit(32, 0), 0, "winter: no thaw")
		-- Summer's warmth: a layer off the deepest each visit.
		h.weatherShift = SUMMER
		local most = deepest
		while most > 0 do
			t.ok(h.visit(32, 0) > 0, "a visit melts")
			local now = 0
			for z = 0, 3 do
				for x = 32, 35 do
					now = math.max(now, depth(world, x, z))
				end
			end
			t.eq(now, most - 1, "one layer at a time")
			most = now
		end
		t.eq(tileDepths(world, 32, 0), "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0")
		t.eq(editCount(world), 0, "melted back to the seed's air: no edit left")
		t.eq(next(world.natural), nil, "nor any natural entry")
		-- A clear night melts a quarter as often: a roll of 0.5 thaws by day, not by night.
		h.weatherShift = WINTER
		h.precipitation = 1
		h.until_(32, 0)
		h.weatherShift = SUMMER
		h.precipitation = 0
		h.night = true
		h.roll = function()
			return 0.5
		end
		t.eq(h.visit(32, 0), 0, "a clear night: 0.25")
		h.night = false
		t.ok(h.visit(32, 0) > 0, "a clear day: 1")
	end)

	t.test("snow world: a player's digging melts nothing back into an edit (the natural map)", function()
		local h = newSnow()
		local world = h.world
		h.until_(32, 0)
		for z = 0, 3 do
			for x = 32, 35 do
				world:setBlock(x, FLOOR, z, AIR)
			end
		end
		t.eq(editCount(world), 0, "dug back to the seed's air: no edits")
		world:setBlock(32, FLOOR, 0, layer(3))
		t.eq(editCount(world), 1, "a player's layer is an edit")
	end)

	t.test("snow world: a cave mouth's cave air takes snow and gets it back, with no edit", function()
		local h = newSnow()
		local world = h.world
		h.until_(44, 12)
		for z = 12, 15 do
			for x = 44, 47 do
				t.ok(depth(world, x, z) > 0, "snow in the cave mouth")
				t.eq(WorldServer.naturalAt(world, x, FLOOR, z), Blocks.CAVE_AIR, "the seed's cave air")
			end
		end
		h.weatherShift = SUMMER
		h.precipitation = 0
		h.until_(44, 12)
		for z = 12, 15 do
			for x = 44, 47 do
				t.eq(world:getBlock(x, FLOOR, z), Blocks.CAVE_AIR, "cave air again")
			end
		end
		t.eq(editCount(world), 0, "no edits left")
		-- A layer whose support goes leaves the seed's cave air too.
		world:setWeather(45, FLOOR, 13, layer(1))
		world:setBlock(45, FLOOR - 1, 13, AIR)
		h.settle()
		t.eq(world:getBlock(45, FLOOR, 13), Blocks.CAVE_AIR)
	end)

	--[[ Warm columns and the heat melt ]]

	t.test("snow world: fire beside snow melts it at every visit; it takes none while it burns", function()
		local h = newSnow()
		local world = h.world
		h.until_(32, 0)
		local others = depth(world, 34, 0)
		-- A campfire just outside the tile, beside column (35, 0)'s snow.
		world:setBlock(36, FLOOR, 0, CAMPFIRE)
		local before = depth(world, 35, 0)
		t.ok(before > 0, "snow beside it")
		for visit = 1, before + 2 do
			h.visit(32, 0)
			t.eq(depth(world, 35, 0), math.max(0, before - visit), "a layer a visit, while it snows")
		end
		t.eq(depth(world, 34, 0), others, "the rest of the tile keeps its snow")
		-- Put out: it snows there again.
		world:setBlock(36, FLOOR, 0, AIR)
		h.visit(32, 0)
		t.ok(depth(world, 35, 0) > 0, "snow again")
	end)

	t.test("snow world: a heated room's roof sheds its snow and takes none", function()
		local h = newSnow()
		local world = h.world
		for x = 36, 39 do
			for z = 0, 3 do
				world:setBlock(x, FLOOR + 2, z, PLANKS)
			end
		end
		h.until_(36, 0)
		t.ok(depth(world, 37, 1) > 0, "a snowy roof")
		-- The room under it at 2 (below RoomMelt): the snow stays.
		local hot = Config.Seasons.Snow.RoomMelt
		for x = 36, 39 do
			for z = 0, 3 do
				h.rooms[Coords.posKey(x, FLOOR + 2, z)] = hot - 1
			end
		end
		local stay = tileDepths(world, 36, 0)
		h.visit(36, 0)
		t.eq(tileDepths(world, 36, 0), stay, "a cool room keeps its roof's snow")
		for x = 36, 39 do
			for z = 0, 3 do
				h.rooms[Coords.posKey(x, FLOOR + 2, z)] = hot
			end
		end
		h.until_(36, 0)
		t.eq(tileDepths(world, 36, 0), "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0", "a warm room's roof melts bare, snowing")
		t.eq(world:getBlock(37, FLOOR + 3, 1), AIR)
	end)

	t.test("snow world: the heat melt: a lit source melts a layer within 2 every HeatMeltSeconds", function()
		local h = newSnow()
		local world = h.world
		for tz = 0, 3 do
			for tx = 0, 3 do
				h.until_(32 + tx * 4, tz * 4)
			end
		end
		local before: { [string]: number } = {}
		for z = 4, 12 do
			for x = 36, 44 do
				before[`{x},{z}`] = depth(world, x, z)
			end
		end
		world:setBlock(40, FLOOR, 8, CAMPFIRE)
		local sources = SnowWorld.sources(h.snow, 2, 0)
		t.ok(sources ~= nil and sources[Coords.posKey(40, FLOOR, 8)] == CAMPFIRE, "indexed when placed")
		-- The chunk is active (a tick that visits nothing), then the round.
		h.roll = function()
			return 0.99
		end
		SnowWorld.tickWith(h.snow, { world:getChunk(2, 0) })
		t.eq(SnowWorld.advance(h.snow, 1), 0, "not yet")
		local writes = SnowWorld.advance(h.snow, Config.Seasons.Snow.HeatMeltSeconds)
		t.ok(writes > 0, "a round")
		t.eq(h.snow.melted, 1, "one source melted around")
		local radius = Config.Seasons.Snow.HeatMeltRadius
		for z = 4, 12 do
			for x = 36, 44 do
				local was = before[`{x},{z}`]
				local within = math.max(math.abs(x - 40), math.abs(z - 8)) <= radius
				if x == 40 and z == 8 then
					t.eq(world:getBlock(x, FLOOR, z), CAMPFIRE)
				elseif within then
					t.eq(depth(world, x, z), was - 1, `a layer less at {x}, {z}`)
				else
					t.eq(depth(world, x, z), was, `untouched at {x}, {z}`)
				end
			end
		end
		-- Saved edits are looked through once a chunk becomes active.
		local fresh = SnowWorld.new(h.snow.env)
		t.eq(SnowWorld.sources(fresh, 2, 0), nil)
		SnowWorld.tickWith(fresh, { world:getChunk(2, 0) })
		local found = SnowWorld.sources(fresh, 2, 0)
		t.ok(found ~= nil and found[Coords.posKey(40, FLOOR, 8)] == CAMPFIRE, "found in the saved edits")
		-- Gone: out of the index; with the snow off no round runs.
		world:setBlock(40, FLOOR, 8, AIR)
		t.eq(SnowWorld.sources(h.snow, 2, 0), nil, "dropped when it goes")
		world:setBlock(40, FLOOR, 8, CAMPFIRE)
		h.active = false
		t.eq(SnowWorld.advance(h.snow, Config.Seasons.Snow.HeatMeltSeconds), 0, "the snow off: no round")
	end)

	--[[ Ice ]]

	t.test("snow world: still water freezes from its edges; the weather's ice thaws, generated ice stays", function()
		local h = newSnow()
		local world = h.world
		h.precipitation = 0
		local function pond(): string
			local out = {}
			for z = 4, 7 do
				for x = 4, 7 do
					local block = world:getBlock(x, FLOOR - 1, z)
					table.insert(out, if block == ICE then "I" elseif block == WATER then "W" else "?")
				end
			end
			return table.concat(out)
		end
		t.eq(pond(), "WWWWWWWWWWWWWWWW")
		h.visit(4, 4)
		t.eq(pond(), "IIIIIWWIIWWIIIII", "the edges first (mustBeAtEdge)")
		h.visit(4, 4)
		t.eq(pond(), "IIIIIIIIIIIIIIII", "then inwards")
		t.eq(WorldServer.naturalAt(world, 5, FLOOR - 1, 5), WATER, "water was there")
		-- Snow never lies on ice.
		h.precipitation = 1
		h.until_(4, 4)
		t.eq(depth(world, 5, 5), 0, "no snow on the ice")
		t.eq(world:getBlock(5, FLOOR, 5), AIR)
		-- Spring: the weather's ice thaws back to water, its edits gone; the seed's ice stays.
		h.precipitation = 0
		h.weatherShift = SUMMER
		h.visit(4, 4)
		t.eq(pond(), "WWWWWWWWWWWWWWWW", "thawed")
		t.eq(editCount(world), 0, "no edits left")
		h.visit(8, 4)
		for z = 4, 7 do
			for x = 8, 11 do
				t.eq(world:getBlock(x, FLOOR - 1, z), ICE, "generated ice never thaws")
			end
		end
		-- Autumn plains are not cold enough to freeze.
		h.weatherShift = AUTUMN
		h.visit(4, 4)
		t.eq(pond(), "WWWWWWWWWWWWWWWW", "autumn: no ice")
	end)

	--[[ The tick ]]

	t.test("snow world: TileChance a chunk a tick, at most MaxTilesPerTick, none with the snow off", function()
		local h = newSnow()
		local world = h.world
		local chunks = {}
		for cx = -3, 3 do
			for cz = -3, 3 do
				table.insert(chunks, world:getChunk(cx, cz))
			end
		end
		h.precipitation = 0
		h.weatherShift = AUTUMN
		h.roll = function()
			return 0
		end
		SnowWorld.tickWith(h.snow, chunks)
		t.eq(h.snow.visits, Config.Seasons.Snow.MaxTilesPerTick, "every chunk rolled a visit: the budget")
		h.roll = nil
		local before = h.snow.visits
		local ticks = 5000
		for _ = 1, ticks do
			SnowWorld.tickWith(h.snow, chunks)
		end
		local visits = h.snow.visits - before
		local expected = #chunks * ticks * Config.Seasons.Snow.TileChance
		t.ok(math.abs(visits - expected) < expected * 0.15, `{visits} visits for {expected} expected`)
		-- A tile (so each column) is looked at every 16 / TileChance ticks: 200 s at 20 Hz.
		t.near(16 / Config.Seasons.Snow.TileChance / 20, 200, 1e-9)
	end)

	--[[ The SnowLayer behaviour, placing and breaking ]]

	t.test("snow layer behaviour: a layer whose support goes vanishes, without drops", function()
		local h = newSnow()
		local world = h.world
		world:setWeather(40, FLOOR, 0, layer(2))
		h.settle()
		t.eq(world:getBlock(40, FLOOR, 0), layer(2), "on grass it stays")
		world:setBlock(40, FLOOR - 1, 0, AIR)
		h.settle()
		t.eq(world:getBlock(40, FLOOR, 0), AIR, "its grass dug out: gone")
		t.eq(#h.drops, 0, "without a drop")
		t.eq(WorldServer.naturalAt(world, 40, FLOOR, 0), nil, "back to the seed's air, no edit there")
		-- On a full layer: a layer more stays until the full one melts to fewer.
		world:setBlock(41, FLOOR, 0, layer(8))
		world:setBlock(41, FLOOR + 1, 0, layer(1))
		h.settle()
		t.eq(world:getBlock(41, FLOOR + 1, 0), layer(1), "a full layer holds snow")
		world:setBlock(41, FLOOR, 0, layer(7))
		h.settle()
		t.eq(world:getBlock(41, FLOOR + 1, 0), AIR, "seven layers don't")
		-- Never on ice; snowfall's own writes schedule no block ticks.
		world:setBlock(42, FLOOR, 0, ICE)
		world:setBlock(42, FLOOR + 1, 0, layer(1))
		h.settle()
		t.eq(world:getBlock(42, FLOOR + 1, 0), AIR, "ice holds none")
		t.eq(h.ticker:pendingCount(), 0)
		h.visit(32, 0)
		t.eq(h.ticker:pendingCount(), 0, "a snowfall visit leaves no block ticks behind (nor does its grass)")
		t.eq(#h.drops, 0)
	end)

	t.test("snow layers: placing stacks onto a layer below 8, needs support; breaking drops Snowballs", function()
		for n = 1, 7 do
			t.ok(EditRules.mayPlace(layer(n + 1), layer(n)), `a layer onto {n}`)
		end
		t.ok(EditRules.mayPlace(layer(1), AIR), "a single layer into air")
		t.ok(EditRules.mayPlace(layer(1), B.ShortGrass), "or a replaceable plant")
		t.eq(EditRules.mayPlace(layer(3), AIR), false, "a deep layer never into air")
		t.eq(EditRules.mayPlace(layer(3), layer(1)), false, "nor two layers at once")
		t.eq(EditRules.mayPlace(layer(5), STONE), false)
		t.eq(EditRules.mayPlace(layer(1), layer(1)), false, "a single layer onto one stacks instead")
		t.eq(EditRules.mayPlace(layer(8), layer(8)), false, "eight is full")
		local function on(below: number): (number, number, number) -> number?
			return function(_x: number, y: number, _z: number): number?
				return if y == FLOOR - 1 then below else AIR
			end
		end
		t.ok(EditRules.supported(layer(1), on(STONE), 0, FLOOR, 0), "on stone")
		t.ok(EditRules.supported(layer(1), on(B.OakLeaves), 0, FLOOR, 0), "on leaves")
		t.ok(EditRules.supported(layer(1), on(layer(8)), 0, FLOOR, 0), "on a full layer")
		t.ok(EditRules.supported(layer(4), on(GRASS), 0, FLOOR, 0), "stacking")
		t.eq(EditRules.supported(layer(1), on(ICE), 0, FLOOR, 0), false, "never on ice")
		t.eq(EditRules.supported(layer(1), on(layer(3)), 0, FLOOR, 0), false, "nor on a partial layer")
		t.eq(EditRules.supported(layer(1), on(B.Torch), 0, FLOOR, 0), false)
		t.eq(EditRules.supported(layer(1), on(AIR), 0, FLOOR, 0), false, "nor in the air")
		t.eq(
			EditRules.supported(layer(1), function(_x, y, _z)
				return if y == FLOOR - 1 then nil else AIR
			end, 0, FLOOR, 0),
			false,
			"nor on an unloaded block"
		)
		local item = Items.ofBlock(layer(1))
		for n = 1, 8 do
			t.eq(Items.ofBlock(layer(n)), item, "one Snow Layer used up, whatever the depth")
			local drop = EditRules.drops(layer(n), false, nil)
			t.ok(drop ~= nil and drop.item == Items.id.Snowball and drop.count == n, `{n} Snowballs by hand`)
			local shovel = EditRules.drops(layer(n), false, Items.id.WoodenShovel)
			t.ok(shovel ~= nil and shovel.count == n, "with a shovel too")
			t.eq(EditRules.drops(layer(n), true, nil), nil, "none in creative")
		end
	end)

	--[[ Growth ]]

	t.test("snow world: the season's growth: autumn 0.5, winter 0, spring 1.5, summer 1; 1 off", function()
		local saved = Calendar.state()
		t.eq(SnowWorld.growth(), 1, "the calendar off")
		local state = Calendar.newState()
		state.enabled = true
		state.offset = 0
		Calendar.setState(state)
		local day = 24000
		local now = 0
		SnowWorld.setClock(function()
			return now
		end)
		local ok, err = pcall(function()
			local lengths = Config.Seasons.Lengths
			local function middle(season: number): number
				local start = 0
				for s = 1, season - 1 do
					start += lengths[s]
				end
				return (start + math.floor(lengths[season] / 2)) * day + 6000
			end
			local growth = Config.Seasons.Climate.Growth
			for season = 1, 4 do
				now = middle(season)
				t.near(SnowWorld.growth(), growth[season], 1e-9, Calendar.NAMES[season])
			end
			-- Off again: 1.
			state.enabled = false
			t.eq(SnowWorld.growth(), 1)
		end)
		Calendar.setState(saved)
		SnowWorld.setClock(nil)
		assert(ok, err)
	end)

	--[[ What it costs ]]

	t.test("snow world: cost (ms a visit and a tick for a player's 7 x 7 chunks, a heat round)", function()
		local h = newSnow()
		local world = h.world
		local chunks = {}
		for cx = 0, 6 do
			for cz = 0, 6 do
				table.insert(chunks, world:getChunk(cx, cz))
			end
		end
		-- Piling: every tile visited until full.
		local started = os.clock()
		local visits, writes = 0, 0
		for round = 1, 6 do
			for _, chunk in chunks do
				for tile = 0, 15 do
					writes += SnowWorld.visit(h.snow, chunk, tile % 4, tile // 4)
					visits += 1
				end
			end
			if round == 1 then
				t.ok(writes > 0, "it piles")
			end
		end
		local piling = (os.clock() - started) * 1000 / visits
		-- Quiet: autumn rain over a winter's snow (reads only).
		h.weatherShift = AUTUMN
		h.precipitation = 1
		started = os.clock()
		local quiet = 0
		for _, chunk in chunks do
			for tile = 0, 15 do
				SnowWorld.visit(h.snow, chunk, tile % 4, tile // 4)
				quiet += 1
			end
		end
		local reading = (os.clock() - started) * 1000 / quiet
		-- Ticks at the real pace (one player's area), snowing.
		h.weatherShift = WINTER
		local ticks = 4000
		started = os.clock()
		for _ = 1, ticks do
			SnowWorld.tickWith(h.snow, chunks)
		end
		local perTick = (os.clock() - started) * 1000 / ticks
		-- A heat melt round: 256 campfires in the snow, 32 a frame.
		local placed = 0
		for cx = 0, 6 do
			for cz = 0, 6 do
				for i = 0, 5 do
					if placed < SnowWorld.MAX_SOURCES then
						world:setBlock(cx * SIZE + 2 + i * 2, FLOOR, cz * SIZE + 8, CAMPFIRE)
						placed += 1
					end
				end
			end
		end
		started = os.clock()
		local frames = 0
		SnowWorld.advance(h.snow, Config.Seasons.Snow.HeatMeltSeconds)
		frames += 1
		while #h.snow.queue > 0 do
			SnowWorld.advance(h.snow, 1 / 60)
			frames += 1
		end
		local round = (os.clock() - started) * 1000
		-- What a winter of snow on those chunks adds to their region's save.
		local region = RegionCodec.new(0, 0)
		for key, edits in world.edits do
			region.chunks[key] = edits
		end
		for key, natural in world.natural do
			region.natural[key] = natural
		end
		local bytes = buffer.len(RegionCodec.encode(region))
		print(
			string.format(
				"         a visit: %.4f ms piling, %.4f ms with nothing to do; a tick of 49 chunks: %.4f ms",
				piling,
				reading,
				perTick
			)
		)
		print(
			string.format(
				"         a heat round of %d sources: %.3f ms over %d frames; a snowy 7 x 7 chunks' region: %d bytes",
				placed,
				round,
				frames,
				bytes
			)
		)
		t.ok(piling < 1, `a piling visit under 1 ms ({piling})`)
		t.ok(perTick < 0.5, `a tick under 0.5 ms ({perTick})`)
		t.ok(round / frames < 4, `a heat round's frame under 4 ms ({round / frames})`)
	end)
end

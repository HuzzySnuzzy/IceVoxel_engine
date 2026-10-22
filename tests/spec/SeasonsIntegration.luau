--[[
	The seasons' four parts run together, each the real module (the parts' own specs test them
	against fakes of the others): a world of the server's (World/WorldServer over a flat plains
	seed) with its rooms (Seasons/RoomWorld), machines (Machines/MachineWorld), snow
	(Seasons/SnowWorld) and windows (Players/InventoryState), bound to each other the way the
	server's boot, Machines/Machines and Players/ToughAsNails bind them, in a winter of
	Shared/Seasons/Calendar.

	Snow and rooms: in a winter snowstorm both plank houses' roofs pile up to their caps; two
	campfires (Players/Climate's room sources) heat one past RoomMelt, and the roof over its room
	sheds its snow and takes none while the cold house's (someone at home, so RoomWorld knows it)
	keeps its own; its door opened, the step in front of it (an opening of the room) is bare too,
	and so is the roof over its walls (the eaves: RoomWorld answers them for the room). Heaters: an Electric Heater on a Creative Energy Cube, ticked by MachineWorld with
	the climate and players near of RoomWorld, stands by outdoors with nobody within StandbyRadius
	and heats as a space heater with someone near; in a room it runs its thermostat to its set
	point with nobody near. The panel: the buttons a client's window (Ui/MenuLayout over the
	decoded snapshot) sends, as Players/Inventories routes them to Machines.button, move the set
	point and switch it off and on (spectators and a stale window can't), MenuLayout reads it back
	from the next snapshot, and the set point stays in the item broken and placed again
	(MachineWorld's sustained data). The calendar: after /time set (TimeCommand's keepCalendar, as
	server World/SeasonClock applies it) /season query, the clock's face (Ui/SeasonClock: the year
	marker's tick, the day ring's split, the day number), its caption (Ui/SeasonLine) and the
	foliage palette (Shared/Seasons/Foliage, as Rendering/SeasonTint picks its step) agree on the
	calendar's position, and /time add 8d moves every one of them a season on. With
	Config.Seasons.Enabled false: no snow, the authored foliage, no climate shift, the sun
	unwarped.

	What can't start in Lune (World/TimeOfDay and World/SeasonClock make Instances when they load,
	Players/Inventories needs ServerNet, Players/ToughAsNails.start the game's players), the spec
	does as they do, in the comments where it does: RoomWorld.temperatureAt, climateAt and
	playerNear answer from the one RoomWorld that `start` makes over the server's world; here the
	same RoomWorld.new over this world answers them (temperatureIn, climateIn, nearIn), as `start`
	builds it.
]]

return function(t, shared, require, server, client)
	local Biomes = require(shared.Biomes)
	local Blocks = require(shared.Blocks)
	local Calendar = require(shared.Seasons.Calendar)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local Foliage = require(shared.Seasons.Foliage)
	local HeatStates = require(shared.Seasons.HeatStates)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Menu = require(shared.Inventory.Menu)
	local Protocol = require(shared.Net.Protocol)
	local Rooms = require(shared.Seasons.Rooms)
	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local SnowLayers = require(shared.Seasons.SnowLayers)
	local Temperature = require(shared.ToughAsNails.Temperature)
	local Weather = require(shared.Weather)
	local Climate = require(server.Players.Climate)
	local Containers = require(server.Players.Containers)
	local EditRules = require(server.Network.EditRules)
	local InventoryState = require(server.Players.InventoryState)
	local MachineWorld = require(server.Machines.MachineWorld)
	local RoomWorld = require(server.Seasons.RoomWorld)
	local SeasonCommand = require(server.Players.SeasonCommand)
	local SnowWorld = require(server.Seasons.SnowWorld)
	local TimeCommand = require(server.Players.TimeCommand)
	local WeatherRules = require(server.World.WeatherRules)
	local WorldServer = require(server.World.WorldServer)
	local MenuLayout = require(client.Ui.MenuLayout)
	local SeasonClock = require(client.Ui.SeasonClock)
	local SeasonLine = require(client.Ui.SeasonLine)

	local B = Blocks.id
	local I = Items.id
	local AIR, GRASS, STONE, PLANKS = Blocks.AIR, B.Grass, B.Stone, B.Planks
	local HEATER, CUBE, CAMPFIRE = B.ElectricHeater, B.CreativeEnergyCube, B.Campfire
	local SIZE = ChunkLayout.SIZE
	local HEAT = Config.Seasons.Heat
	local ROOM_MELT = Config.Seasons.Snow.RoomMelt
	local PLAINS = (Biomes.byName("Plains") :: any).index
	local DAY = Calendar.TICKS_PER_DAY
	-- The first air cell over the grass, the terrain's crop, the seed.
	local G = 10
	local CROP = 32
	local SEED = 4242
	-- Winter's fourth day at noon (calendar day 11 of a calendar from day 0: Winter is days 8..15),
	-- a day away from any turn's blend.
	local WINTER_NOON = 11 * DAY + Calendar.NOON

	-- A calendar that counts from day 0 (as SeasonClock publishes it while the seasons are on).
	local function counting(): Calendar.State
		local s = Calendar.newState()
		s.enabled = true
		s.offset = 0
		return s
	end

	-- Runs `fn` with `s` as the calendar's module state (as SeasonClock sets it on the server and
	-- LightingController on the client: the sun, the rooms' outside value and the snow read it).
	local function with(s: Calendar.State, fn: () -> ())
		local before = Calendar.state()
		Calendar.setState(s)
		local ok, err = pcall(fn)
		Calendar.setState(before)
		if not ok then
			error(err, 0)
		end
	end

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	--[[ The world ]]

	-- Flat plains: stone, grass at G - 1, air above.
	local generator = {
		seed = SEED,
		generate = function(level: number, cx: number, cz: number)
			local data = ChunkLayout.create(CROP)
			for lz = 0, SIZE - 1 do
				for lx = 0, SIZE - 1 do
					for y = 0, G - 2 do
						ChunkLayout.set(data, lx, y, lz, STONE)
					end
					ChunkLayout.set(data, lx, G - 1, lz, GRASS)
				end
			end
			return {
				data = data,
				level = level,
				nx = cx,
				nz = cz,
				height = CROP,
				solidBelow = G - 1,
				emptyAbove = G,
			}
		end,
		column = function(_x: number, _z: number)
			return G, PLAINS, 0, GRASS
		end,
		findSpawn = function()
			return 0, G, 0
		end,
	}

	--[[
		A game: the world (chunks -1..4 loaded) and its rooms, machines, snow and windows, bound as
		the server binds them. `g.dayTime` is the server's clock, `g.players` the players' feet,
		`g.precipitation` the weather's over every column; `g.run(seconds)` runs the server's
		frames (20 ticks a second: the machines, the rooms, the snow's heat melt, and Tough As
		Nails' room sample of each player once a second).
	]]
	local function newGame(): any
		local g: any = { dayTime = WINTER_NOON, players = {}, precipitation = 1, ticks = 0 }
		local world = WorldServer.new(generator :: any)
		for cx = -1, 4 do
			for cz = -1, 4 do
				world:getChunk(cx, cz)
			end
		end
		local containers = Containers.new()
		local machines: any
		--[[
			The heaters' room source as Players/ToughAsNails.start registers it (Climate.addRoomSource
			with what they deliver, their `heat` field, read through Machines' world); the others are
			Players/Climate's own (a campfire's 20 HU).
		]]
		local function heatOf(x: number, y: number, z: number): number
			local machine = MachineWorld.machine(machines, x, y, z)
			local container = if machine then machine.container else nil
			local index = if container then Machines.field(container.block, "heat") else nil
			local data = if container then container.data else nil
			local value = if data and index then data[index] else nil
			return if type(value) == "number" and value == value then value else 0
		end
		local function roomSource(block: number): (any, number?)
			if block == HEATER then
				return heatOf, nil
			end
			return Climate.roomSource(block)
		end
		-- RoomWorld.start's environment over this world.
		local rooms = RoomWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
			skyAbove = function(x: number, z: number): number
				local cx, cz = x // SIZE, z // SIZE
				local chunk = world:peekChunk(cx, cz)
				if chunk == nil then
					return math.huge
				end
				local lx, lz = x - cx * SIZE, z - cz * SIZE
				for y = chunk.height - 1, 0, -1 do
					if not Rooms.passable(ChunkLayout.get(chunk.data, lx, y, lz)) then
						return y + 1
					end
				end
				return 0
			end,
			column = function(x: number, z: number): (number, number)
				local height, biome = generator.column(x, z)
				return height, biome
			end,
			dayTime = function(): number
				return g.dayTime
			end,
			players = function(each: (number, number, number) -> ())
				for _, feet in g.players do
					each(feet[1], feet[2], feet[3])
				end
			end,
			-- (A clock that stands: only FillsPerFrame limits a frame's fills, whatever the load.)
			clock = function(): number
				return 0
			end,
			seed = SEED,
			roomSource = roomSource,
		})
		-- Machines.start's environment: the climate and the players near a machine are RoomWorld's.
		machines = MachineWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
			containers = containers,
			dayTime = function(): number
				return g.dayTime
			end,
			climate = function(x: number, y: number, z: number): (any, number)
				return RoomWorld.climateIn(rooms, x, y, z)
			end,
			near = function(x: number, y: number, z: number, radius: number): boolean
				return RoomWorld.nearIn(rooms, x, y, z, radius)
			end,
		})
		-- SnowWorld.start's environment: the weather's moment carries the season's weather shift
		-- (World/WeatherServer's season sample), the rooms are RoomWorld's.
		local random = lcg(17)
		local snow = SnowWorld.new({
			world = world,
			random = random,
			precipitation = function(_x: number, _z: number): number
				return g.precipitation
			end,
			moment = function(): any
				return { weatherShift = SeasonClimate.sample(g.dayTime, "temperate", SEED).weatherShift }
			end,
			night = function(): boolean
				return not DayCycle.isDay(g.dayTime)
			end,
			heating = SnowWorld.heatingNow,
			room = function(x: number, y: number, z: number): number?
				return RoomWorld.temperatureIn(rooms, x, y, z)
			end,
			active = function(): boolean
				return Config.Seasons.Snow.Enabled and SeasonClimate.active()
			end,
		})
		local inventories = InventoryState.new(containers)
		-- The boot's onChanged chain (Inventories, Machines, RoomWorld, SnowWorld).
		world.onChanged = function(x: number, y: number, z: number, old: number, new: number)
			if old ~= new and Blocks.isValid(old) and Blocks.get(old).menu ~= nil then
				inventories:removeContainer(x, y, z)
			end
			MachineWorld.blockChanged(machines, x, y, z, old, new)
			RoomWorld.changed(rooms, x, y, z, old, new)
			SnowWorld.changed(snow, x, y, z, old, new)
		end
		function g.run(seconds: number)
			for _ = 1, math.round(seconds * 20) do
				if g.ticks % 20 == 0 then
					for _, feet in g.players do
						RoomWorld.sampleIn(rooms, feet[1], feet[2], feet[3])
					end
				end
				g.ticks += 1
				MachineWorld.step(machines)
				RoomWorld.stepWorld(rooms, 1 / 20)
				SnowWorld.advance(snow, 1 / 20)
			end
		end
		-- One visit of every tile over [x0, x1] x [z0, z1] (what the tick does to one tile 1 in 250
		-- ticks a chunk); the writes made.
		function g.visit(x0: number, z0: number, x1: number, z1: number): number
			local writes = 0
			for tz = z0 // 4, z1 // 4 do
				for tx = x0 // 4, x1 // 4 do
					local x, z = tx * 4, tz * 4
					writes += SnowWorld.visit(
						snow,
						world:getChunk(x // SIZE, z // SIZE),
						(x % SIZE) // 4,
						(z % SIZE) // 4
					)
				end
			end
			return writes
		end
		-- Visits until a round writes nothing (at most 20 rounds): the rounds.
		function g.settle(x0: number, z0: number, x1: number, z1: number): number
			local rounds = 0
			repeat
				rounds += 1
			until g.visit(x0, z0, x1, z1) == 0 or rounds >= 20
			return rounds
		end
		-- The heater (or any machine) at a cell, and its container.
		function g.machine(x: number, y: number, z: number): any
			local machine = MachineWorld.machine(machines, x, y, z)
			return if machine then machine.container else nil
		end
		g.world, g.rooms, g.machines, g.snow, g.inventories, g.containers =
			world, rooms, machines, snow, inventories, containers
		return g
	end

	-- A 5 x 5 x 3 plank house on the grass: its interior from (x0, G, z0), walls and a roof over
	-- them all at G + 3, a closed oak door in the front wall (z0 - 1) at x0 + 2.
	local function house(world: any, x0: number, z0: number)
		for x = x0 - 1, x0 + 5 do
			for z = z0 - 1, z0 + 5 do
				for y = G, G + 3 do
					if x == x0 - 1 or x == x0 + 5 or z == z0 - 1 or z == z0 + 5 or y == G + 3 then
						world:setBlock(x, y, z, PLANKS)
					end
				end
			end
		end
		world:setBlock(x0 + 2, G, z0 - 1, B.OakDoor)
		world:setBlock(x0 + 2, G + 1, z0 - 1, B.OakDoorTop)
	end

	-- The snow layers of column (x, z), from its top cell as the rules see them.
	local function depth(world: any, x: number, z: number): number
		local top = WeatherRules.top(world, x, z)
		if top == nil or top <= 0 then
			return 0
		end
		return (SnowLayers.layersAt(world:getBlock(x, top, z), world:getBlock(x, top - 1, z)))
	end

	-- Each column's depth over a house's roof (x0 - 1 .. x0 + 5, z0 - 1 .. z0 + 5), as text.
	local function roofDepths(world: any, x0: number, z0: number): string
		local out = {}
		for z = z0 - 1, z0 + 5 do
			for x = x0 - 1, x0 + 5 do
				table.insert(out, tostring(depth(world, x, z)))
			end
		end
		return table.concat(out, ",")
	end

	--[[ Rooms x snow ]]

	--[[
		Two plank houses in a winter snowstorm, both roofs piled up to their caps: house A (interior
		x 2..6, z 2..6) with someone at home, so RoomWorld knows it and finds it cold; house B (x
		18..22) heated past RoomMelt by two campfires lit inside (Players/Climate's room sources: its
		room is seeded from them, a player being within Range), five minutes on.
	]]
	local function snowedHouses(): (any, string)
		local g = newGame()
		local world = g.world
		house(world, 2, 2)
		house(world, 18, 2)
		g.players = { { 4.5, G, 4.5 } }
		g.run(3)
		local home = assert(RoomWorld.sampleIn(g.rooms, 4.5, G, 4.5), "house A is a room")
		t.eq(home.volume, 75)
		t.eq(RoomWorld.temperatureIn(g.rooms, 20, G + 1, 4), nil, "house B: nobody found it yet")
		local rounds = g.settle(0, 0, 7, 7) + g.settle(16, 0, 23, 7)
		t.ok(rounds > 2, "a layer a visit")
		for _, x0 in { 2, 18 } do
			for z = 1, 7 do
				for x = x0 - 1, x0 + 5 do
					local cap = SeasonClimate.snowCap("temperate", x, G + 4, z, SEED)
					t.eq(depth(world, x, z), cap, `roof {x}, {z} at its cap`)
					t.ok(cap >= 2, "temperate caps 3 +- the drift")
					t.ok(SnowLayers.isLayer(world:getBlock(x, G + 4, z)), "on the roof")
				end
			end
			for z = 2, 6 do
				for x = x0, x0 + 4 do
					t.eq(world:getBlock(x, G, z), AIR, "none under it")
				end
			end
		end
		local coldRoof = roofDepths(world, 2, 2)
		world:setBlock(19, G, 4, CAMPFIRE)
		world:setBlock(21, G, 4, CAMPFIRE)
		g.run(300)
		local hot = assert(RoomWorld.temperatureIn(g.rooms, 20, G + 1, 4), "house B is a room now")
		t.ok(hot >= ROOM_MELT, `house B at {hot}`)
		t.eq(RoomWorld.temperatureIn(g.rooms, 20, G + 3, 4), hot, "its roof block reads its air")
		local sample = assert(RoomWorld.sampleIn(g.rooms, 20.5, G, 4.5))
		t.eq(sample.heat, 2 * HEAT.Campfire, "two campfires' 20 HU")
		t.near(
			hot,
			Rooms.steady(sample, sample.outside, Rooms.GROUND, sample.heat),
			0.1,
			"settled (tau under a minute)"
		)
		local cold = assert(RoomWorld.temperatureIn(g.rooms, 4, G + 3, 4), "house A's roof")
		t.ok(cold < ROOM_MELT, `house A at {cold}`)
		return g, coldRoof
	end

	t.test("seasons together: a heated room's roof and doorstep shed their snow, a cold house keeps its own", function()
		with(counting(), function()
			local g, coldRoof = snowedHouses()
			local world = g.world
			-- Still snowing: the roof over house B's room melts a layer a visit, bare, and takes
			-- none; house A's keeps its snow; the ground beside B keeps its own.
			local before = depth(world, 20, 4)
			g.visit(16, 0, 23, 7)
			t.eq(depth(world, 20, 4), before - 1, "a layer a visit")
			g.settle(16, 0, 23, 7)
			for z = 2, 6 do
				for x = 18, 22 do
					t.eq(depth(world, x, z), 0, `B's roof bare at {x}, {z}`)
					t.eq(world:getBlock(x, G + 4, z), AIR)
				end
			end
			for _ = 1, 5 do
				t.eq(g.visit(16, 0, 23, 7), 0, "snowing on: nothing more falls on B's roof or beside it")
			end
			t.eq(depth(world, 20, 4), 0)
			g.settle(0, 0, 7, 7)
			t.eq(roofDepths(world, 2, 2), coldRoof, "A's roof keeps its snow")
			t.eq(depth(world, 16, 4), SeasonClimate.snowCap("temperate", 16, G, 4, SEED), "the ground beside B")
			-- B's door opened: its doorway reaches the step in front (an opening of the room under
			-- the open sky: the one place snow falls into a room), whose snow then melts too, while
			-- the step's neighbours keep theirs.
			local step = SeasonClimate.snowCap("temperate", 20, G, 0, SEED)
			t.eq(depth(world, 20, 0), step, "the doorstep's snow")
			world:setBlock(20, G, 1, B.OakDoorOpen)
			world:setBlock(20, G + 1, 1, B.OakDoorOpenTop)
			g.run(5)
			local opened = assert(RoomWorld.sampleIn(g.rooms, 20.5, G, 4.5))
			t.eq(opened.volume, 77, "the doorway's two cells")
			local doorstep = assert(RoomWorld.temperatureIn(g.rooms, 20, G, 0), "the step: an opening of the room")
			t.ok(doorstep >= ROOM_MELT, `still warm: {doorstep}`)
			g.settle(16, 0, 23, 3)
			t.eq(depth(world, 20, 0), 0, "the doorstep melts bare")
			t.eq(depth(world, 19, 0), SeasonClimate.snowCap("temperate", 19, G, 0, SEED), "beside it: snow")
			t.eq(depth(world, 21, 0), SeasonClimate.snowCap("temperate", 21, G, 0, SEED))
			t.eq(roofDepths(world, 2, 2), coldRoof, "and A's roof still")
		end)
	end)

	--[[
		A house's roof covers its walls too (the roof over the walls, as every Minecraft house and
		tests/lib/FakeRooms build it), and snow on a heated house should melt from all of it (the
		docs: snow "in or on a room at RoomMelt or warmer ... takes none"). The roof's blocks over the
		walls (the eaves, corners included) touch no room cell, so Rooms.fill adds them to the room's
		walls for lookups only (no U, no sources): temperatureAt answers them with the room's air,
		and SnowWorld melts them as the rest of the roof. Without that a heated 5 x 5 house kept a
		rim of snow on 24 of its roof's 49 columns.
	]]
	t.test("seasons together: the roof over a heated house's walls sheds its snow too", function()
		with(counting(), function()
			local g = snowedHouses()
			local world = g.world
			g.settle(16, 0, 23, 7)
			t.eq(depth(world, 20, 4), 0, "the roof over the room is bare")
			local rim = 0
			for z = 1, 7 do
				for x = 17, 23 do
					if (x == 17 or x == 23 or z == 1 or z == 7) and depth(world, x, z) > 0 then
						rim += 1
					end
				end
			end
			local eave = RoomWorld.temperatureIn(g.rooms, 17, G + 3, 4)
			local wall = RoomWorld.temperatureIn(g.rooms, 17, G + 2, 4)
			t.eq(
				rim,
				0,
				`roof columns over B's walls still snowed: {rim} of 24 (temperatureAt of the west eave {eave}, of the wall under it {wall})`
			)
		end)
	end)

	--[[ Heaters ]]

	t.test("seasons together: a heater stands by outdoors with nobody near, heats with one, holds its room", function()
		with(counting(), function()
			local g = newGame()
			local world = g.world
			-- Outdoors, on a Creative Energy Cube.
			world:setBlock(40, G, 40, CUBE)
			world:setBlock(40, G + 1, 40, HEATER)
			local outdoor = assert(g.machine(40, G + 1, 40))
			local radius = HEAT.StandbyRadius
			g.players = { { 40.5 + radius + 8, G, 40.5 } }
			g.run(3)
			t.eq(RoomWorld.nearIn(g.rooms, 40, G + 1, 40, radius), false, "nobody within StandbyRadius")
			t.eq(Machines.state(outdoor), HeatStates.STANDBY)
			t.eq(Machines.get(outdoor, "heat"), 0)
			t.eq(Machines.view(outdoor).rate, 0, "takes nothing")
			t.eq(MenuLayout.statusText(outdoor), "Standby")
			t.ok(Machines.energy(outdoor) > 0, "powered all the same")
			-- A player walks up: from RoomWorld's next 1 Hz step on, it heats as a space heater.
			g.players = { { 40.5 + radius - 6, G, 40.5 } }
			g.run(2)
			t.ok(RoomWorld.nearIn(g.rooms, 40, G + 1, 40, radius))
			t.eq(Machines.state(outdoor), HeatStates.HEATING)
			t.eq(Machines.get(outdoor, "heat"), HEAT.SpaceHeater)
			t.eq(-Machines.view(outdoor).rate, HEAT.SpaceHeater * HEAT.HeaterJoules, "4 J/t per HU")
			t.eq(MenuLayout.statusText(outdoor), `Heating {HEAT.SpaceHeater} HU`)
			local _, outside = RoomWorld.climateIn(g.rooms, 40, G + 1, 40)
			t.near(
				outside,
				RoomWorld.outsideValue(G + 1, G, PLAINS, WINTER_NOON, SEED),
				1e-12,
				"no room: the outside's"
			)
			-- And away again: standby.
			g.players = { { 40.5 + radius + 8, G, 40.5 } }
			g.run(2)
			t.eq(Machines.state(outdoor), HeatStates.STANDBY)
			-- In a house, nobody within StandbyRadius (but within the rooms' Range): its room is
			-- found from it (a room source machine), and its thermostat holds its set point.
			house(world, 50, 50)
			world:setBlock(54, G, 54, CUBE)
			world:setBlock(54, G + 1, 54, HEATER)
			local indoor = assert(g.machine(54, G + 1, 54))
			Machines.set(indoor, "setPoint", 3)
			g.players = { { 52.5 - 40, G, 52.5 } }
			g.run(10)
			local room = assert((RoomWorld.climateIn(g.rooms, 54, G + 1, 54)), "the heater's room")
			t.eq(room.volume, 75 - 2, "the cube and the heater stand in it")
			t.eq(RoomWorld.nearIn(g.rooms, 54, G + 1, 54, radius), false, "nobody near")
			local outsideHere = room.outside
			g.run(400)
			t.ok(math.abs(room.temperature - 3) <= 0.5, `held at {room.temperature}`)
			t.eq(Machines.state(indoor), HeatStates.AT_SET_POINT)
			local heat = Machines.get(indoor, "heat")
			t.near(heat, room.uaOut * (3 - outsideHere) + room.uaGround * 3, 0.5, "what holding it takes")
			t.near(room.heat, heat, 1e-6, "the room counts what it delivers (its room source)")
			t.eq(Machines.state(outdoor), HeatStates.STANDBY, "the one outdoors still stands by")
		end)
	end)

	--[[ The panel's buttons ]]

	t.test("seasons together: panel buttons move a heater's set point and switch it; its item keeps it", function()
		with(counting(), function()
			local g = newGame()
			local world, inventories = g.world, g.inventories
			house(world, 2, 2)
			world:setBlock(6, G, 6, CUBE)
			world:setBlock(6, G + 1, 6, HEATER)
			g.players = { { 3.5, G, 3.5 } }
			g.run(6)
			local container = assert(g.machine(6, G + 1, 6))
			-- The player opens it: the window holds the machine's own container.
			inventories:join("p")
			inventories:open("p", 6, G + 1, 6, HEATER)
			local window = assert(inventories:window("p"))
			t.eq(window.container, container, "the machine's container")
			-- What the client shows: the snapshot as it decodes there.
			local function shown(): (any, any)
				local snapshot = assert(Protocol.decodeInventory(Protocol.encodeInventory(inventories:snapshot("p"))))
				return { id = snapshot.window, container = snapshot.container }, snapshot.container
			end
			local clientWindow, view = shown()
			local panel = MenuLayout.panel(view)
			local minus, plus, mode = panel.buttons[1], panel.buttons[2], panel.buttons[3]
			t.ok(minus.id == HeatStates.BUTTON_DOWN and plus.id == HeatStates.BUTTON_UP, "- and +")
			t.eq(mode.id, HeatStates.BUTTON_MODE)
			t.eq(MenuLayout.setPointText(view), "Set 0")
			t.eq(MenuLayout.buttonLabel(view, mode), "On")
			-- A click: the action the client sends, decoded on the server, applied as
			-- Players/Inventories does (InventoryState.applyAs, then its window's machine's button
			-- when the action names the window and the game mode allows it).
			local seq = 0
			local function click(from: any, spot: any, gameMode: string?)
				seq += 1
				local mode_ = gameMode or "Survival"
				local payload = Protocol.encodeInventoryAction(seq, MenuLayout.buttonAction(from, spot))
				local got, action = Protocol.decodeInventoryAction(payload)
				assert(action, "decodes")
				local open = inventories:window("p")
				inventories:applyAs("p", got :: number, action, mode_)
				if action.kind ~= "button" or open == nil or open.id ~= action.window then
					return
				end
				local machine = open.container
				if machine == nil or not Machines.isContainer(machine) or not Menu.allows(action, mode_) then
					return
				end
				Machines.button(machine, machine.block, action.button)
			end
			for _ = 1, 3 do
				click(clientWindow, plus)
			end
			click(clientWindow, minus)
			g.run(1)
			clientWindow, view = shown()
			t.eq(Machines.get(container, "setPoint"), 2, "three up, one down")
			t.eq(MenuLayout.setPointText(view), "Set +2", "the panel's set point")
			t.ok(Machines.get(container, "heat") > 0, "heating to it")
			-- Off and on again.
			click(clientWindow, mode)
			g.run(1)
			clientWindow, view = shown()
			t.eq(Machines.get(container, "on"), 0)
			t.eq(MenuLayout.buttonLabel(view, mode), "Off")
			t.eq(MenuLayout.statusText(view), "Off")
			t.eq(Machines.get(container, "heat"), 0, "off: delivers nothing")
			click(clientWindow, mode)
			g.run(1)
			clientWindow, view = shown()
			t.eq(MenuLayout.buttonLabel(view, mode), "On")
			t.ok(Machines.get(container, "heat") > 0, "on: heats again")
			-- A spectator's click, or one from a window the server has closed since, does nothing.
			click(clientWindow, plus, "Spectator")
			t.eq(Machines.get(container, "setPoint"), 2, "spectators can't")
			local stale = clientWindow
			inventories:close("p")
			inventories:open("p", 6, G + 1, 6, HEATER)
			click(stale, plus)
			t.eq(Machines.get(container, "setPoint"), 2, "a stale window's click")
			clientWindow, view = shown()
			click(clientWindow, plus)
			t.eq(Machines.get(container, "setPoint"), 3, "the open window's")
			-- Broken (its window closes, the item keeps the set point) and placed again.
			local blockData = EditRules.newBlockData()
			blockData:add(MachineWorld.blockDataHooks(g.machines))
			local drop = assert(EditRules.breakDrop(blockData, 6, G + 1, 6, HEATER, false, I.IronPickaxe))
			world:setBlock(6, G + 1, 6, AIR)
			t.eq(g.machine(6, G + 1, 6), nil, "gone")
			t.eq((inventories:window("p") :: any).id, 0, "its window closed")
			t.eq(drop.item, Items.ofBlock(HEATER))
			t.eq((drop.data :: any).setPoint, 3, "the item keeps the set point")
			world:setBlock(5, G, 6, HEATER)
			blockData:placed("p", 5, G, 6, HEATER, drop)
			local placed = assert(g.machine(5, G, 6))
			t.eq(Machines.get(placed, "setPoint"), 3, "placed again: its set point")
			t.eq(Machines.get(placed, "on"), 1, "and on")
			inventories:open("p", 5, G, 6, HEATER)
			local _, again = shown()
			t.eq(MenuLayout.setPointText(again), "Set +3", "its panel says so")
			t.eq(MenuLayout.buttonLabel(again, mode), "On")
		end)
	end)

	--[[ The calendar ]]

	-- What TimeCommands does with a command at `now` (TimeCommand, then World/SeasonClock's
	-- keepCalendar for /time set and TimeOfDay's new time): the new calendar and day time.
	local function apply(text: string, s: Calendar.State, now: number): (Calendar.State, number)
		local result = TimeCommand.run(text, { mayUse = true, dayTime = now, gameTime = 0, cycle = true }) :: any
		assert(result and result.dayTime, text)
		local next = s
		if result.keepCalendar then
			next = table.clone(s)
			next.offset = Calendar.keep(now, result.dayTime, s)
		end
		return next, result.dayTime
	end

	-- Everything that shows the season at `dayTime` with calendar `s`: the command, the clock's
	-- face and caption (Ui/SeasonHud's draw), the foliage palette (Rendering/SeasonTint's step).
	local function look(s: Calendar.State, dayTime: number): any
		local seen: any = {}
		with(s, function()
			local position = Calendar.position(dayTime)
			seen.position = position
			seen.query = (SeasonCommand.run("/season query", {
				mayUse = false,
				enabled = true,
				dayTime = dayTime,
				state = s,
			}) :: any).feedback[1]
			seen.caption = SeasonLine.caption(position, SeasonLine.heatWaveShown(dayTime, SEED, s), s.lock ~= nil)
			-- The year marker and the tick it stands on.
			local angle = SeasonClock.yearAngle(position)
			seen.angle = angle
			local tick = math.floor(angle / (360 / SeasonClock.YEAR_TICKS)) + 1
			seen.dial = SeasonClock.yearSeasons(s.lengths)[tick]
			local split = { day = 0, dusk = 0, night = 0 }
			for _, segment in SeasonClock.daySegments(dayTime) do
				split[segment] += 1
			end
			seen.split = `{split.day}/{split.dusk}/{split.night}`
			seen.dayText = SeasonClock.dayText(dayTime, 40)
			-- SeasonTint: the near step of the calendar time, drawn at its midpoint.
			local targets = assert(Foliage.targets(Foliage.midpoint(Foliage.stepOf(Calendar.time(dayTime))), s))
			seen.targets = targets
			seen.p = targets.p
			seen.foliage = math.floor(targets.p * Calendar.SEASONS) + 1
		end)
		return seen
	end

	local SPLITS = { "8/2/6", "6/2/8", "8/2/6", "10/2/4" }

	-- Do the parts in `seen` agree with each other on the season `season`?
	local function agree(seen: any, season: number, label: string)
		local position = seen.position
		local name = Calendar.NAMES[season]
		t.eq(position.season, season, `{label}: the calendar`)
		t.eq(seen.dial, season, `{label}: the clock's marker on {name}'s ticks`)
		t.eq(seen.foliage, season, `{label}: the foliage palette's season`)
		t.ok(string.find(seen.caption, string.upper(name), 1, true) ~= nil, `{label}: the caption {seen.caption}`)
		t.ok(
			string.find(seen.query, `It is {name}, day {position.day + 1} of`, 1, true) ~= nil,
			`{label}: {seen.query}`
		)
		t.eq(seen.split, SPLITS[season], `{label}: the day ring`)
		-- The marker and the palette at the same share of the year (equal seasons: the year's
		-- progress is the palette's p), within half a palette step.
		local share = Foliage.stepDays() / 2 / Calendar.yearLength(Calendar.newState())
		local apart = math.abs((seen.angle / 360 - seen.p + 0.5) % 1 - 0.5)
		t.ok(apart <= share + 1e-9, `{label}: marker {seen.angle / 360}, palette {seen.p}`)
		-- The palette's colours are the clock's position's (snow dust by its cover too).
		local cover = SeasonClimate.snowCover(position, "temperate")
		t.near(seen.targets.covers[Foliage.TEMPERATE], cover, 0.05, `{label}: the snow cover`)
		for _, name_ in { "Grass", "OakLeaves", "BirchLeaves" } do
			local appearance = Blocks.get(B[name_]).appearance
			local colour = Foliage.colour(appearance, Foliage.TEMPERATE, Foliage.progress(position), cover) :: any
			local drawn = seen.targets.colours[Foliage.TEMPERATE][appearance]
			t.ok(Foliage.deltaE(drawn, colour) <= Foliage.MAX_STEP_DELTA, `{label}: {name_}'s colour`)
		end
	end

	t.test("seasons together: after /time set clock, caption, command and foliage agree; 8d moves them on", function()
		-- A world saved without seasons: Autumn's first day when it loads (SeasonClock.fresh).
		local now = 5 * DAY + 2000
		local s = Calendar.fresh(now)
		t.eq(s.enabled, true, "Config's switch")
		local autumn = look(s, now)
		agree(autumn, Calendar.AUTUMN, "a fresh world")
		t.eq(autumn.position.calendarDay, 0)
		-- Eleven days on, then /time set noon: day 0 of the clock, the calendar's Winter kept.
		s, now = apply("/time add 11d", s, now)
		local winterMorning = look(s, now)
		s, now = apply("/time set noon", s, now)
		t.eq(now, 6000)
		t.eq(DayCycle.day(now), 0, "the clock's day count starts over")
		local winter = look(s, now)
		agree(winter, Calendar.WINTER, "after /time set")
		t.eq(winter.position.calendarDay, 11, "the calendar day kept")
		t.eq(winter.position.day, 3)
		t.eq(winter.query, "It is Winter, day 4 of 8 (5 days left), year 1")
		t.eq(winter.caption, "WINTER · 5 DAYS LEFT")
		t.eq(winter.dayText, "1", "the dial's day number is the clock's")
		t.ok(Foliage.drift(winterMorning.targets, winter.targets) <= 3 * Foliage.MAX_STEP_DELTA, "the foliage stays")
		t.ok(Foliage.drift(autumn.targets, winter.targets) > 10, "never back to autumn's")
		-- /time add 8d: the offset stays, every part a season on.
		local before = s.offset
		s, now = apply("/time add 8d", s, now)
		t.eq(s.offset, before)
		local spring = look(s, now)
		agree(spring, Calendar.SPRING, "after /time add 8d")
		t.eq(spring.position.day, winter.position.day, "the same day of the season")
		t.near((spring.angle - winter.angle) % 360, 90, 1e-6, "the marker a quarter round")
		t.near(spring.p - winter.p, 0.25, 1e-9, "the palette a quarter year")
		t.eq(spring.query, "It is Spring, day 4 of 8 (5 days left), year 1")
		t.eq(spring.dayText, "9")
		t.ok(Foliage.drift(winter.targets, spring.targets) > 10, "the foliage changed with it")
		-- And once more to summer.
		s, now = apply("/time add 8d", s, now)
		agree(look(s, now), Calendar.SUMMER, "a season later")
	end)

	--[[ Seasons off ]]

	t.test("seasons together: seasons off: no snow, the authored foliage, no climate shift", function()
		-- (With them on, the same winter noon's palette is not the authored one.)
		local on = counting()
		local palette = assert(Foliage.targets(Calendar.time(WINTER_NOON, on), on))
		t.ok(Foliage.drift(nil, palette) > 10, "seasons on: winter's colours")
		local enabled = Config.Seasons.Enabled
		Config.Seasons.Enabled = false
		local ok, err = pcall(function()
			-- The server's clock publishes the calendar off (SeasonClock's switch is Config's), even
			-- for a world saved with seasons (Calendar.decode keeps the new state's switch).
			local saved = Calendar.encode(on, WINTER_NOON)
			local s = assert(Calendar.decode(saved, Calendar.newState()))
			t.eq(s.enabled, false)
			t.eq(Calendar.position(WINTER_NOON, s).season, Calendar.WINTER, "the calendar counts on")
			with(s, function()
				-- No climate shift anywhere, the sun unwarped.
				for _, class in SeasonClimate.CLASSES do
					local sample = SeasonClimate.sample(WINTER_NOON, class :: any, SEED)
					t.eq(sample.shift, 0, `{class}: no shift`)
					t.eq(sample.weatherShift, 0)
					t.eq(sample.nightDrop, SeasonClimate.NIGHT)
					t.eq(sample.growth, 1)
					t.eq(sample.snowCover, 0)
				end
				local moment: any = { weatherShift = SeasonClimate.sample(WINTER_NOON, "temperate", SEED).weatherShift }
				t.eq(Weather.seasonShift(moment, PLAINS), 0)
				local night = WINTER_NOON + 12000
				t.eq(DayCycle.solarTime(night), night, "the sun's time")
				local env: any = {
					climate = (Biomes.get(PLAINS) :: any).temperature,
					y = G,
					surface = G,
					skyOpen = false,
					night = not DayCycle.isDay(night),
					wet = false,
					sprinting = false,
					heated = false,
					nearHeat = false,
					cooled = false,
					burning = false,
					armorWarmth = 0,
					armorCooling = 0,
				}
				t.near(
					RoomWorld.outsideValue(G, G, PLAINS, night, SEED),
					Temperature.outside(env),
					1e-12,
					"rooms' outside"
				)
				-- The server's snow, in a snowstorm over a house: nothing is visited, nothing piles,
				-- and a campfire melts no snow a player put beside it (no heat melt round).
				local g = newGame()
				house(g.world, 2, 2)
				g.world:setBlock(10, G, 10, CAMPFIRE)
				local placed = SnowLayers.block(3) :: number
				g.world:setBlock(11, G, 10, placed)
				local chunks = {}
				for cx = -1, 4 do
					for cz = -1, 4 do
						table.insert(chunks, g.world:getChunk(cx, cz))
					end
				end
				for _ = 1, 500 do
					SnowWorld.tickWith(g.snow, chunks)
				end
				t.eq(g.snow.visits, 0, "no visits (on, TileChance a chunk a tick)")
				t.eq(SnowWorld.advance(g.snow, Config.Seasons.Snow.HeatMeltSeconds), 0, "no heat melt")
				t.eq(g.snow.melted, 0)
				t.eq(g.world:getBlock(11, G, 10), placed, "the player's snow stays")
				-- (Even a visit the tick never makes: no season shift, so plains rain.)
				t.eq(g.settle(0, 0, 7, 7), 1, "a visit writes nothing")
				for z = 0, 7 do
					for x = 0, 7 do
						t.eq(depth(g.world, x, z), 0, `no snow at {x}, {z}`)
					end
				end
				-- The foliage: no targets (callers keep the authored colours), even for a calendar
				-- left on.
				t.eq(Foliage.targets(Calendar.time(WINTER_NOON, s), s), nil, "the authored colours")
				t.eq(Foliage.targets(Calendar.time(WINTER_NOON, on), on), nil, "Config's switch first")
				t.eq(Foliage.drift(nil, nil), 0)
			end)
		end)
		Config.Seasons.Enabled = enabled
		assert(ok, err)
	end)
end
